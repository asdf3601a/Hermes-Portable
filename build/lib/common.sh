# Hermes Portable build helpers (sourced by build/*.sh; bash on Windows).

HP_REPO=${HP_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
UPSTREAM="$HP_REPO/upstream"
# portable/lib/config.sh expands ${HP_ROOT} and resolves relative paths against it.
HP_ROOT=$(cygpath -w "$HP_REPO")
export HP_REPO HP_ROOT UPSTREAM
# shellcheck source=../../portable/lib/config.sh
. "$HP_REPO/portable/lib/config.sh"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
group() { [ -n "${GITHUB_ACTIONS:-}" ] && printf '::group::%s\n' "$*"; log "$*"; }
endgroup() { [ -n "${GITHUB_ACTIONS:-}" ] && printf '::endgroup::\n'; return 0; }

# bp_load FILE: export KEY=VALUE pairs from FILE unless the variable is already set
bp_load() {
  local key value
  while IFS=$'\t' read -r key value; do
    [ -n "${!key+x}" ] || export "$key=$value"
  done < <(HP_CONFIG_WARN=1 hp_config_each "$1")
}

bp_load "$HP_REPO/build/bundle.conf"
[ -f "$HP_REPO/build/build.env" ] && bp_load "$HP_REPO/build/build.env"

BUILD_DIR=$(hp_abs "${HP_BUILD_DIR:-.build}")
export DESKTOP_WORK DESKTOP_CACHE
DESKTOP_WORK=$(hp_abs "${HP_DESKTOP_WORK:-$BUILD_DIR/desktop-job}")
DESKTOP_CACHE=$(hp_abs "${HP_DESKTOP_CACHE:-$BUILD_DIR/desktop-inputs}")
STATE_FILE="$BUILD_DIR/state.env"
mkdir -p "$BUILD_DIR"

# Host Python that drives upstream's bundle scripts (needs 3.11+).
# shellcheck disable=SC2034 # PY is used by the scripts that source this file
if [ -n "${HP_BUILD_PYTHON:-}" ]; then
  read -r -a PY <<< "$HP_BUILD_PYTHON"
elif python -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
  PY=(python)
elif py -3.13 -c '' 2>/dev/null; then
  PY=(py -3.13)
else
  die "no Python 3.11+ found; set HP_BUILD_PYTHON"
fi
export PYTHONUTF8=1

upstream_version() {
  printf '%s\n' "${UPSTREAM_TAG#v}"
}

portable_version() {
  printf '%s-p%s\n' "$(upstream_version)" "${PORTABLE_REVISION:?}"
}

# The submodule commit recorded by this repository (the gitlink), not whatever
# the submodule currently has checked out.
pinned_upstream() {
  git -C "$HP_REPO" ls-files --stage -- upstream | awk '$1 == "160000" { print $2 }'
}

load_state() {
  [ -f "$STATE_FILE" ] || die "run 'build/build.sh patch' first ($STATE_FILE missing)"
  # shellcheck source=/dev/null
  . "$STATE_FILE"
}

# Proxy / TLS / mirror variables for the build, from the same HP_* names the
# portable session uses. Generated tool files land under the build directory.
build_network_env() {
  local saved_home=$HOME
  export HOME="$BUILD_DIR/home" HP_DATA_U="$BUILD_DIR"
  mkdir -p "$HOME" "$BUILD_DIR/cache"
  # shellcheck source=../../portable/lib/network.sh
  . "$HP_REPO/portable/lib/network.sh"
  hp_network_env
  export HOME=$saved_home
  [ -n "${HP_ARTIFACT_MIRROR:-}" ] && export HERMES_ARTIFACT_MIRROR="$HP_ARTIFACT_MIRROR"
  [ -n "${HP_ELECTRON_MIRROR:-}" ] && export ELECTRON_MIRROR="$HP_ELECTRON_MIRROR"
  [ -n "${HP_ELECTRON_BUILDER_BINARIES_MIRROR:-}" ] \
    && export ELECTRON_BUILDER_BINARIES_MIRROR="$HP_ELECTRON_BUILDER_BINARIES_MIRROR"
  export ELECTRON_BUILDER_CACHE="${ELECTRON_BUILDER_CACHE:-$(cygpath -w "$BUILD_DIR/electron-builder")}"
  return 0
}

# Strip credentials before a URL is written to logs or VERSION.txt.
public_url() {
  printf '%s\n' "$1" | sed -E 's#(://)[^/@]+@#\1#'
}
