#!/usr/bin/env bash
# Hermes Portable smoke tests on an assembled folder. The folder itself is not
# touched: tests run on a copy, which is then moved to a path with spaces and
# CJK characters for the relocation round.
#
#   build/smoke-test.sh DIST_FOLDER
#
# HP_SMOKE_SKIP="desktop tls ..." skips groups; HP_SMOKE_LONGPATHS_OFF=1 (CI)
# disables Windows long-path support for the relocation round.
# shellcheck disable=SC2015,SC2016 # pass/fail always succeed; single-quoted scripts run in the portable shell
set -uo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SRC=$(cd "${1:?usage: smoke-test.sh DIST_FOLDER}" && pwd)
WORK="$BUILD_DIR/smoke"
TESTS="$HP_REPO/build/tests"
failures=0
pids=()

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
soft() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
skip() { [[ " ${HP_SMOKE_SKIP:-} " == *" $1 "* ]]; }
check() {  # check NAME COMMAND...: PASS when the command succeeds
  local name=$1; shift
  if "$@" > "$WORK/last.log" 2>&1; then pass "$name"; else fail "$name"; sed 's/^/      /' "$WORK/last.log" | tail -n 25; fi
}

cleanup() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  [ -n "${DIST:-}" ] && [ -d "$DIST" ] && prun hermes gateway stop --all --yes > /dev/null 2>&1
  return 0
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK/plain"
log "copy $(basename "$SRC") for testing"
cp -a "$SRC" "$WORK/plain/"
DIST="$WORK/plain/$(basename "$SRC")"
PAYLOAD="$DIST/desktop/resources/agent-payload"

# shellcheck source=/dev/null
. "$DIST/portable/paths.sh"
bundled_bash() { printf '%s\n' "$DIST/$HP_GIT_REL/usr/bin/bash.exe"; }
# prun COMMAND...: run inside the portable environment (bundled bash + scrub + env.sh),
# through a native hop (build/lib/spawn.py): started straight from the runner's Git
# Bash, the bundled bash gets no environment and its caller waits for every background
# descendant, so a running desktop would block the step forever.
prun() {
  # HP_ROOT from build/lib/common.sh names the repository, not the folder under test.
  (unset HP_ROOT; cd "$WORK" && MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    "${PY[@]}" -I "$(cygpath -w "$HP_REPO/build/lib/spawn.py")" \
    "$(cygpath -w "$(bundled_bash)")" --noprofile --norc "$(cygpath -w "$DIST/portable/lib/run.sh")" "$@")
}
set_config() { printf '%s\n' "$@" > "$DIST/config/portable.env"; }
venv_site() { cygpath -w "$PAYLOAD/venv/Lib/site-packages"; }

# --- 1. upstream payload contract (relocation, offline, pm doctor, browser-harness) --
if ! skip payload; then
  log "1. upstream payload smoke"
  mkdir -p "$WORK/node"
  cp "$DIST/$HP_NODE_DIR_REL/node.exe" "$WORK/node/"  # node must not run from inside the payload it renames
  check "scripts/smoke-payload.sh" env PATH="$WORK/node:$PATH" bash "$UPSTREAM/scripts/smoke-payload.sh" "$PAYLOAD"
fi

# Everything from here runs through the portable launchers: none of it may write to
# the real profile (checked in group 8).
"${PY[@]}" -I -X utf8 "$TESTS/profile_watch.py" mark "$(cygpath -w "$WORK/profile.stamp")"

# --- 2. launchers and environment isolation -----------------------------------------
log "2. launchers and isolation"
set_config "# smoke"
check "Hermes-Shell.cmd hermes --version" \
  bash -c "cd '$WORK' && cmd //c '$(cygpath -w "$DIST/Hermes-Shell.cmd")' hermes --version"
leaks=$(OPENAI_API_KEY=leak-key PYTHONPATH=leak NODE_OPTIONS=--leak npm_config_registry=https://leak.invalid/ \
        UV_INDEX_URL=https://leak.invalid/ HERMES_HOME='C:\leak' PYTHONPYCACHEPREFIX='C:\leak' \
        HTTPS_PROXY=http://leak.invalid:1 HP_DATA_DIR='C:\leak' prun env 2>&1 | grep -i leak || true)
[ -z "$leaks" ] && pass "host variables do not leak" || fail "host variables leaked: $leaks"
set_config "HP_ENV_PASSTHROUGH=SMOKE_PASS"
SMOKE_PASS=through prun env | grep -qx 'SMOKE_PASS=through' && pass "HP_ENV_PASSTHROUGH" || fail "HP_ENV_PASSTHROUGH"
set_config "# smoke"
dist_unix=$(cygpath -u "$DIST")
tools=$(prun bash -c 'for t in hermes.exe node npm uv git rg ffmpeg; do printf "%s=%s\n" "$t" "$(command -v "$t")"; done')
foreign=$(printf '%s\n' "$tools" | grep -v "=$dist_unix/" || true)
[ -z "$foreign" ] && pass "bundled tools resolve inside the folder" || fail "tools from outside: $foreign"
staged_bash=$(prun bash -c 'cd "$HP_PAYLOAD_U/hermes-agent" && "$HP_PYTHON_U" -I -c "import sys; sys.path[:0] = [\".\", sys.argv[1]]; import pm.shell; print(pm.shell.bash())" "$(cygpath -w "$HP_PAYLOAD_U/venv/Lib/site-packages")"' 2>&1 | tail -n1)
[[ $(cygpath -u "$staged_bash" 2>/dev/null) == "$dist_unix"/* ]] && pass "Hermes uses the bundled Git Bash" \
  || fail "pm.shell.bash() -> $staged_bash"
check "hermes tools list" prun hermes tools list
if prun hermes pm install cua-driver > "$WORK/cua.log" 2>&1; then
  fail "cua-driver install was not refused"
elif grep -q "disabled in Hermes Portable" "$WORK/cua.log"; then
  pass "cua-driver install refused"
else
  fail "cua-driver install failed for another reason"; tail -n 10 "$WORK/cua.log"
fi
if prun hermes update < /dev/null > "$WORK/update.log" 2>&1; then
  grep -qiE 'manag|not supported|refus|desktop|external|portable' "$WORK/update.log" \
    && pass "hermes update refused" || { fail "hermes update ran"; tail -n 10 "$WORK/update.log"; }
else
  pass "hermes update refused (exit $?)"
fi
check "hermes-portable doctor" prun hermes-portable doctor

# --- 3. package source switch on the real payload locks -----------------------------
log "3. source switch (payload locks)"
digest() {
  prun bash -c 'cd "$HP_PAYLOAD_U/hermes-agent" && "$HP_PYTHON_U" -I -c "import sys; sys.path[:0] = [\".\", sys.argv[1]]; from pathlib import Path; from pm.packages import _uv_lock_digest; print(_uv_lock_digest(Path(\"uv.lock\")).hex())" "$(cygpath -w "$HP_PAYLOAD_U/venv/Lib/site-packages")"' 2>&1 | tail -n1
}
lock="$PAYLOAD/hermes-agent/uv.lock"
had_backup=$([ -f "$lock.upstream" ] && echo 1 || echo 0)
before=$(digest)
check "sources pypi use-nexus (rewrite)" prun hermes-portable sources pypi use-nexus --mode rewrite --no-probe \
  --index-url https://nexus.invalid/repository/pypi-proxy/simple
check "sources verify" prun hermes-portable sources verify
after=$(digest)
[ -n "$before" ] && [ "$before" = "$after" ] && pass "venv stamp unchanged by the switch" \
  || fail "venv stamp changed ($before -> $after)"
check "hermes --version on switched locks" prun hermes --version
check "sources pypi use-original" prun hermes-portable sources pypi use-original
if [ "$had_backup" = 0 ]; then
  cmp -s "$lock" "$lock.upstream" && pass "original lock restored byte for byte" || fail "restored lock differs"
fi

# --- 4. Nexus-layout mirror end to end (fixtures) -----------------------------------
start_server() {  # start_server PORT [CERT KEY]
  local ready="$WORK/ready-$1"
  rm -f "$ready"
  "${PY[@]}" -I "$TESTS/serve.py" --root "$(cygpath -w "$WORK/mirror")" --port "$1" \
    --log "$(cygpath -w "$WORK/requests-$1.log")" --ready "$(cygpath -w "$ready")" \
    ${2:+--cert "$(cygpath -w "$2")" --key "$(cygpath -w "$3")"} &
  pids+=($!)
  for _ in $(seq 1 50); do [ -f "$ready" ] && return 0; sleep 0.2; done
  return 1
}
fixtures() {
  rm -rf "$WORK/fx"
  cp -r "$TESTS/fixtures" "$WORK/fx"
}
sources_fx() {  # sources_fx pypi|npm HP_SOURCES_ARGS...: hp_sources on a fixture project
  local project=$1; shift
  prun bash -c '"$HP_PYTHON_U" -I -X utf8 "$HP_ROOT_U/portable/python/hp_sources.py" --root "$1" "${@:2}"' _ \
    "$(cygpath -w "$WORK/fx/$project-project")" "$@"
}
if ! skip mirror; then
  log "4. Nexus-layout mirror"
  "${PY[@]}" -I "$TESTS/mkmirror.py" --out "$(cygpath -w "$WORK/mirror")" \
    --uv-lock "$(cygpath -w "$TESTS/fixtures/pypi-project/uv.lock")" \
    --npm-lock "$(cygpath -w "$TESTS/fixtures/npm-project/package-lock.json")" > /dev/null \
    && start_server 18080 || fail "mirror setup"
  fixtures
  # A black-hole proxy: anything not served by 127.0.0.1 fails.
  set_config "HP_PYPI_INDEX_URL=http://127.0.0.1:18080/pypi/simple" \
             "HP_NPM_REGISTRY=http://127.0.0.1:18080/npm/" \
             "HP_HTTP_PROXY=http://127.0.0.1:9" "HP_NO_PROXY=127.0.0.1"
  check "fixture: sources pypi use-nexus (discover)" sources_fx pypi pypi use-nexus
  check "fixture: uv sync --frozen from the mirror" \
    prun bash -c 'cd "$1" && UV_CACHE_DIR="$2" uv sync --frozen' _ "$(cygpath -w "$WORK/fx/pypi-project")" "$(cygpath -w "$WORK/uv-cache-1")"
  grep -q 'GET /pypi/packages/six/1.17.0/six-1.17.0-py2.py3-none-any.whl' "$WORK/requests-18080.log" \
    && pass "wheels downloaded from the mirror" || fail "mirror log has no wheel download"
  check "fixture: sources npm use-nexus" sources_fx npm npm use-nexus
  check "fixture: npm ci from the mirror" \
    prun bash -c 'cd "$1" && npm ci --no-audit --no-fund --ignore-scripts' _ "$(cygpath -w "$WORK/fx/npm-project")"
  check "fixture: sources verify" sources_fx pypi verify
fi

# --- 5. TLS: corporate-style private CA ----------------------------------------------
if ! skip tls; then
  log "5. TLS with a private CA"
  PATH="$DIST/$HP_GIT_REL/mingw64/bin:$PATH" bash "$TESTS/mkcert.sh" "$WORK/pki" && start_server 18443 "$WORK/pki/server.pem" "$WORK/pki/server.key" \
    || fail "TLS server setup"
  url=https://127.0.0.1:18443/pypi/simple/six/
  tls_clients() {  # every client must reach the private-CA server
    prun hermes-portable sources check-url "$url" \
      && prun curl -fsS -o /dev/null "$url" \
      && prun node -e 'fetch(process.argv[1]).then(r => process.exit(r.ok ? 0 : 1), e => { console.error(e); process.exit(2) })' "$url" \
      && prun bash -c '"$HP_PYTHON_U" -c "import site, sys; site.addsitedir(sys.argv[1]); import httpx, requests; httpx.get(sys.argv[2]).raise_for_status(); requests.get(sys.argv[2]).raise_for_status()" "$1" "$2"' _ "$(venv_site)" "$url" \
      && { fixtures; sources_fx pypi pypi use-nexus; } \
      && prun bash -c 'cd "$1" && UV_CACHE_DIR="$2" uv sync --frozen' _ "$(cygpath -w "$WORK/fx/pypi-project")" "$(cygpath -w "$WORK/uv-cache-$RANDOM")"
  }
  base=("HP_PYPI_INDEX_URL=https://127.0.0.1:18443/pypi/simple" "HP_HTTP_PROXY=http://127.0.0.1:9" "HP_NO_PROXY=127.0.0.1")
  set_config "${base[@]}"
  if prun hermes-portable sources check-url "$url" > /dev/null 2>&1; then
    fail "private CA trusted without configuration"
  else
    pass "untrusted private CA is rejected by default"
  fi
  set_config "${base[@]}" "HP_SSL_CA_FILE=$(cygpath -w "$WORK/pki/ca.pem")"
  check "HP_SSL_CA_FILE: uv, curl, node, httpx, requests, sources" tls_clients
  set_config "${base[@]}" "HP_SSL_INSECURE=1"
  check "HP_SSL_INSECURE: uv, curl, node, httpx, requests, sources" tls_clients
  set_config "# smoke"
fi

# --- 6. Hermes Desktop (best effort: hosted runners have a limited desktop) -----------
if ! skip desktop; then
  log "6. Hermes Desktop"
  exe=$(basename "$HP_DESKTOP_EXE_REL")
  prun bash -c '"$HP_DESKTOP_EXE_U" > "$HP_DATA_U/logs/desktop-smoke.log" 2>&1 &
    for i in $(seq 1 45); do sleep 2; [ -s "$(cygpath -u "$HERMES_HOME")/logs/desktop.log" ] && break; done'
  if tasklist.exe //FI "IMAGENAME eq $exe" //NH | grep -qiF "$exe"; then
    pass "desktop process running"
  else
    soft "desktop process not running (see data/logs/desktop-smoke.log)"
  fi
  [ -s "$DIST/data/hermes/logs/desktop.log" ] && pass "desktop wrote data/hermes/logs/desktop.log" \
    || soft "no desktop.log yet"
  taskkill.exe //IM "$exe" //F //T > /dev/null 2>&1
  prun hermes gateway stop --all --yes > /dev/null 2>&1
  if reg.exe query 'HKCU\Software\Classes\hermes' > /dev/null 2>&1; then
    fail "hermes:// protocol was registered in HKCU"
  else
    pass "no hermes:// registry entry"
  fi
fi

# --- 7. relocation to a path with spaces and CJK characters -----------------------------
if ! skip relocate; then
  log "7. relocation"
  prun hermes gateway stop --all --yes > /dev/null 2>&1
  if [ -n "${HP_SMOKE_LONGPATHS_OFF:-}" ]; then
    reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' //v LongPathsEnabled //t REG_DWORD //d 0 //f > /dev/null \
      && log "LongPathsEnabled=0"
  fi
  # Short on purpose: the long-path check below needs a folder within VERSION.txt's
  # max_extract_folder_chars, like a user's C:\HP.
  moved="$BUILD_DIR/測試 路徑"
  rm -rf "$moved"
  mkdir -p "$moved"
  if mv "$DIST" "$moved/"; then
    DIST="$moved/$(basename "$SRC")"
    PAYLOAD="$DIST/desktop/resources/agent-payload"
    dist_unix=$(cygpath -u "$DIST")
    check "relocated: hermes --version" prun hermes --version
    check "relocated: hermes tools list" prun hermes tools list
    tools=$(prun bash -c 'for t in hermes.exe node npm uv git; do command -v "$t"; done')
    foreign=$(printf '%s\n' "$tools" | grep -v "^$dist_unix/" || true)
    [ -z "$foreign" ] && pass "relocated: tools resolve inside the folder" || fail "relocated tools: $foreign"
    check "relocated: sources status" prun hermes-portable sources status
    # Without long-path support, the longest payload source must still be readable from
    # a folder within the documented limit (its .pyc may have been dropped by assemble).
    # Output stays ASCII: the folder name is not, the path inside site-packages is.
    longest_src=$(prun bash -c '"$HP_PYTHON_U" -I -c "
import os, sys
site = sys.argv[1]
path = max((os.path.join(d, f) for d, _, fs in os.walk(site) for f in fs if f.endswith(\".py\")), key=len)
where = f\"{len(path)} chars, site-packages/{os.path.relpath(path, site)}\"
if len(path) > 259:
    print(\"SKIP\", where); sys.exit(0)
compile(open(path, \"rb\").read(), path, \"exec\")
print(\"OK\", where)" "$1"' _ "$(venv_site)" 2>&1 | tail -n1)
    case $longest_src in
      OK*) pass "relocated: longest payload source readable without long paths (${longest_src#OK })" ;;
      SKIP*) soft "long-path check skipped: build folder too deep (${longest_src#SKIP })" ;;
      *) fail "relocated: longest payload source not readable: $longest_src" ;;
    esac
  else
    fail "could not move the folder (files in use?)"
  fi
fi

# --- 8. nothing written to the real profile -------------------------------------------
log "8. real profile untouched"
prun hermes gateway stop --all --yes > /dev/null 2>&1
"${PY[@]}" -I -X utf8 "$TESTS/profile_watch.py" report "$(cygpath -w "$WORK/profile.stamp")" \
  --exclude "$(cygpath -w "$BUILD_DIR")" --exclude "$(cygpath -w "$HP_REPO")" \
  "${USERPROFILE:-}" "${APPDATA:-}" "${LOCALAPPDATA:-}" > "$WORK/profile.log" 2>&1
if grep -q '^HARD ' "$WORK/profile.log"; then
  fail "files written to the real profile:"; sed -n 's/^HARD /      /p' "$WORK/profile.log"
else
  pass "no files written to %USERPROFILE%, %APPDATA% or %LOCALAPPDATA%"
fi
grep -q '^SOFT ' "$WORK/profile.log" \
  && { soft "Windows-owned profile entries changed meanwhile:"; sed -n 's/^SOFT /      /p' "$WORK/profile.log"; }
sed -n 's/^TEMP /  info: %TEMP%: /p' "$WORK/profile.log"

echo
if [ "$failures" -eq 0 ]; then
  log "smoke tests passed"
else
  die "$failures smoke test(s) failed"
fi
