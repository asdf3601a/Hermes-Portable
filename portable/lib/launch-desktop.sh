#!/usr/bin/env bash
# Hermes Portable: run Hermes Desktop in the portable environment.
# Hermes-Desktop.cmd starts this through the bundled mintty with a hidden window.

if [ "${HP_SCRUBBED:-}" != 1 ]; then
  # shellcheck source=scrub.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scrub.sh"
  hp_reexec_clean /usr/bin/bash --noprofile --norc "${BASH_SOURCE[0]}" "$@"
fi
# shellcheck source=env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh" || exit

log="$HP_DATA_U/logs/desktop-launcher.log"
exe_name=$(basename "$HP_DESKTOP_EXE_U")
{
  printf '=== %s start %s\n' "$(date '+%F %T')" "$exe_name"
  printf 'args: %s\n' "${HP_DESKTOP_ARGS[*]}"
} >> "$log"

# Electron's Chromium reads its own switches for proxy and certificate checks.
"$HP_DESKTOP_EXE_U" "${HP_DESKTOP_ARGS[@]}" "$@" >> "$log" 2>&1
status=$?
printf '=== %s exit %s\n' "$(date '+%F %T')" "$status" >> "$log"

# The desktop starts a detached gateway that outlives the window. Stop it once
# no desktop instance is left, so nothing keeps the portable folder locked.
if hp_truthy "${HP_STOP_GATEWAY_ON_EXIT:-1}"; then
  if ! tasklist.exe //FI "IMAGENAME eq $exe_name" //NH 2>/dev/null | grep -qiF "$exe_name"; then
    hermes gateway stop --all --yes >> "$log" 2>&1
  fi
fi
exit "$status"
