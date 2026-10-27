#!/usr/bin/env bash
# Hermes Portable non-interactive entry: run one command in the portable
# environment and exit with its status.
#
#   <PortableGit>\usr\bin\bash.exe --noprofile --norc portable/lib/run.sh hermes --version
#   Hermes-Shell.cmd hermes chat -q "hello"      (same thing, from cmd)

if [ "${HP_SCRUBBED:-}" != 1 ]; then
  # shellcheck source=scrub.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scrub.sh"
  hp_reexec_clean /usr/bin/bash --noprofile --norc "${BASH_SOURCE[0]}" "$@"
fi
# shellcheck source=env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh" || exit
[ $# -gt 0 ] || { echo "usage: run.sh COMMAND [ARGS...]" >&2; exit 2; }
"$@"
