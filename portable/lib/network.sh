# Hermes Portable network settings (sourced; bash). Shared by the portable
# session (env.sh) and the build (build/build.sh).
#
# Translates config/portable.env (or build/build.env) into what each tool
# reads: HP_HTTP(S)_PROXY / HP_NO_PROXY, HP_PYPI_INDEX_URL /
# HP_PYPI_EXTRA_INDEX_URLS, HP_NPM_REGISTRY / HP_NPM_AUTH_TOKEN,
# HP_SSL_USE_SYSTEM_STORE, HP_SSL_CA_FILE, HP_SSL_INSECURE / HP_SSL_INSECURE_HOSTS.
# Requires HOME and HP_DATA_U; runs inside a Git Bash (public roots: /mingw64/etc/ssl).

# hp_url_host URL -> host[:port]
hp_url_host() {
  local rest=${1#*://}
  rest=${rest%%/*}
  printf '%s\n' "${rest##*@}"
}

# hp_url_without_userinfo URL
hp_url_without_userinfo() {
  local scheme=${1%%://*} rest=${1#*://}
  local authority=${rest%%/*} path=
  [ "$authority" != "$rest" ] && path=/${rest#*/}
  printf '%s://%s%s\n' "$scheme" "${authority##*@}" "$path"
}

# hp_managed_block FILE [LINE...]: replace this tool's block in FILE, keep the user's lines
hp_managed_block() {
  local file=$1
  shift
  local begin='# >>> hermes-portable (generated from config/portable.env; do not edit) >>>'
  local end='# <<< hermes-portable <<<'
  local kept=
  if [ -f "$file" ]; then
    kept=$(awk -v b="$begin" -v e="$end" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$file")
  fi
  {
    [ -n "$kept" ] && printf '%s\n' "$kept"
    [ $# -gt 0 ] && printf '%s\n' "$begin" "$@" "$end"
  } > "$file.tmp"
  mv -f "$file.tmp" "$file"
}

hp_network_env() {
  local npmrc=() curlrc=() git_keys=() git_values=()
  HP_DESKTOP_ARGS=()

  # --- proxy -------------------------------------------------------------------
  local http_proxy_url=${HP_HTTP_PROXY:-} https_proxy_url=${HP_HTTPS_PROXY:-${HP_HTTP_PROXY:-}}
  if [ -n "$http_proxy_url$https_proxy_url" ]; then
    http_proxy_url=${http_proxy_url:-$https_proxy_url}
    local no_proxy_list="localhost,127.0.0.1,::1${HP_NO_PROXY:+,$HP_NO_PROXY}"
    no_proxy_list=${no_proxy_list// /}
    export HTTP_PROXY="$http_proxy_url" http_proxy="$http_proxy_url"
    export HTTPS_PROXY="$https_proxy_url" https_proxy="$https_proxy_url"
    export NO_PROXY="$no_proxy_list" no_proxy="$no_proxy_list"
    export NODE_USE_ENV_PROXY=1
    npmrc+=("proxy=$http_proxy_url" "https-proxy=$https_proxy_url" "noproxy=$no_proxy_list")
    git_keys+=(http.proxy) git_values+=("$https_proxy_url")
    HP_DESKTOP_ARGS+=("--proxy-server=$https_proxy_url" "--proxy-bypass-list=<local>;${no_proxy_list//,/;}")
  fi

  # --- PyPI mirror (Nexus) ---------------------------------------------------------
  if [ -n "${HP_PYPI_INDEX_URL:-}" ]; then
    local index=${HP_PYPI_INDEX_URL%/}
    export UV_DEFAULT_INDEX="$index" PIP_INDEX_URL="$index"
  fi
  if [ -n "${HP_PYPI_EXTRA_INDEX_URLS:-}" ]; then
    local extra
    extra=$(printf '%s' "$HP_PYPI_EXTRA_INDEX_URLS" | tr ',;' '  ' | xargs)
    export UV_INDEX="$extra" PIP_EXTRA_INDEX_URL="$extra"
  fi

  # --- npm mirror (Nexus) ------------------------------------------------------------
  if [ -n "${HP_NPM_REGISTRY:-}" ]; then
    local registry
    registry=$(hp_url_without_userinfo "${HP_NPM_REGISTRY%/}")/
    export npm_config_registry="$registry"
    npmrc+=("registry=$registry" "replace-registry-host=npmjs")
    local scope=//${registry#*://}
    if [ -n "${HP_NPM_AUTH_TOKEN:-}" ]; then
      npmrc+=("$scope:_authToken=$HP_NPM_AUTH_TOKEN")
    elif [[ ${HP_NPM_REGISTRY#*://} == *@* ]]; then
      local userinfo=${HP_NPM_REGISTRY#*://}
      userinfo=${userinfo%%@*}
      npmrc+=("$scope:_auth=$(printf '%s' "$userinfo" | base64 -w0)")
    fi
  fi

  # --- TLS -------------------------------------------------------------------------------
  # 1) Windows certificate store (default): corporate roots deployed by IT just work.
  if hp_truthy "${HP_SSL_USE_SYSTEM_STORE:-1}"; then
    export UV_SYSTEM_CERTS=1 NODE_USE_SYSTEM_CA=1
    if [ -z "${HP_SSL_CA_FILE:-}" ]; then
      git_keys+=(http.sslBackend http.schannelCheckRevoke) git_values+=(schannel false)
    fi
  fi
  # 2) An extra CA file (PEM): appended to the public roots, one bundle for every tool.
  if [ -n "${HP_SSL_CA_FILE:-}" ]; then
    local ca bundle
    ca=$(hp_abs "$HP_SSL_CA_FILE")
    bundle="$HP_DATA_U/cache/ca-bundle.pem"
    if [ -f "$ca" ]; then
      cat /mingw64/etc/ssl/certs/ca-bundle.crt "$ca" > "$bundle"
      local bundle_w
      bundle_w=$(cygpath -w "$bundle")
      export SSL_CERT_FILE="$bundle_w" REQUESTS_CA_BUNDLE="$bundle_w" CURL_CA_BUNDLE="$bundle_w"
      export GIT_SSL_CAINFO="$bundle_w" NODE_EXTRA_CA_CERTS="$(cygpath -w "$ca")"
      npmrc+=("cafile=$bundle_w")
      git_keys+=(http.sslBackend) git_values+=(openssl)
    else
      printf 'Hermes Portable: HP_SSL_CA_FILE not found: %s\n' "$HP_SSL_CA_FILE" >&2
    fi
  fi
  # 3) Last resort: no certificate verification at all.
  if hp_truthy "${HP_SSL_INSECURE:-0}"; then
    export HP_SSL_INSECURE=1 NODE_TLS_REJECT_UNAUTHORIZED=0 GIT_SSL_NO_VERIFY=1
    export PYTHONHTTPSVERIFY=0 npm_config_strict_ssl=false
    local hosts=(pypi.org files.pythonhosted.org registry.npmjs.org nodejs.org github.com
                 objects.githubusercontent.com release-assets.githubusercontent.com
                 hermes-assets.nousresearch.com) url
    for url in ${HP_PYPI_INDEX_URL:-} $(printf '%s' "${HP_PYPI_EXTRA_INDEX_URLS:-}" | tr ',;' '  ') \
               ${HP_NPM_REGISTRY:-} ${HP_ARTIFACT_MIRROR:-}; do
      hosts+=("$(hp_url_host "$url")")
    done
    local extra_hosts
    read -r -a extra_hosts <<< "$(printf '%s' "${HP_SSL_INSECURE_HOSTS:-}" | tr ',;' '  ')"
    hosts+=("${extra_hosts[@]}")
    export UV_INSECURE_HOST="$(printf '%s
' "${hosts[@]}" | awk 'NF && !seen[$0]++' | xargs)"
    npmrc+=("strict-ssl=false")
    curlrc+=("insecure")
    git_keys+=(http.sslVerify) git_values+=(false)
    HP_DESKTOP_ARGS+=("--ignore-certificate-errors")
  fi

  # --- write the per-tool views ------------------------------------------------------------
  export GIT_CONFIG_COUNT=${#git_keys[@]}
  local i
  for i in "${!git_keys[@]}"; do
    export "GIT_CONFIG_KEY_$i=${git_keys[$i]}" "GIT_CONFIG_VALUE_$i=${git_values[$i]}"
  done
  hp_managed_block "$HOME/.npmrc" "${npmrc[@]}"
  hp_managed_block "$HOME/.curlrc" "${curlrc[@]}"
}
