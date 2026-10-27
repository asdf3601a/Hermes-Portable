# Hermes Portable: start every session from a clean environment (sourced; bash).
#
# hp_reexec_clean PROGRAM [ARGS...] re-executes PROGRAM under `env -i` with only
# the allowlisted host variables (env-allowlist.txt + HP_ENV_PASSTHROUGH) and
# the portable HOME/USERPROFILE, then never returns. Once the environment is
# clean (HP_SCRUBBED=1) it returns immediately. `env -i` is used because bash
# cannot unset Windows names such as ProgramFiles(x86).

hp_reexec_clean() {
  [ "${HP_SCRUBBED:-}" = 1 ] && return 0
  local lib
  lib=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -z "${HP_ROOT:-}" ]; then
    HP_ROOT=$(cd "$lib/../.." && pwd -W)
  fi
  # shellcheck source=config.sh
  . "$lib/config.sh"

  local patterns=() line name upper pattern kv
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] || patterns+=("${line^^}")
  done < "$lib/env-allowlist.txt"
  for name in $(hp_config_value HP_ENV_PASSTHROUGH | tr ',;' '  '); do
    patterns+=("${name^^}")
  done

  local keep=()
  while IFS= read -r -d '' kv; do
    name=${kv%%=*}
    upper=${name^^}
    for pattern in "${patterns[@]}"; do
      # shellcheck disable=SC2053 # glob match on purpose
      if [[ $upper == $pattern ]]; then
        keep+=("$kv")
        break
      fi
    done
  done < <(/usr/bin/env -0)

  # The portable home exists before bash or /etc/profile ever look for one.
  local data home
  data=$(hp_data_unix)
  home="$data/home"
  mkdir -p "$home"
  exec /usr/bin/env -i "${keep[@]}" \
    HP_ROOT="$HP_ROOT" HP_SCRUBBED=1 \
    HOME="$home" USERPROFILE="$(cygpath -w "$home")" \
    MSYSTEM="${MSYSTEM:-MINGW64}" CHERE_INVOKING=1 \
    "$@"
}
