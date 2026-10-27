# Hermes Portable session environment (sourced; bash, after scrub.sh).
#
# Builds everything Hermes sees from the portable folder alone: data
# directories, the bundled tool PATH, enforced policy and the network settings
# of config/portable.env. Paths handed to native Windows programs are exported
# in Windows form.

HP_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.sh
. "$HP_LIB/config.sh"
HP_ROOT_U=$(hp_root_unix)
if [ ! -f "$HP_ROOT_U/portable/paths.sh" ]; then
  echo "Hermes Portable: portable/paths.sh is missing; this folder is not a complete build." >&2
  return 2 2>/dev/null || exit 2
fi
# shellcheck source=/dev/null
. "$HP_ROOT_U/portable/paths.sh"
hp_load_config

HP_PAYLOAD_U="$HP_ROOT_U/$HP_PAYLOAD_REL"
HP_GIT_U="$HP_ROOT_U/$HP_GIT_REL"
HP_PYTHON_U="$HP_ROOT_U/$HP_PYTHON_EXE_REL"
HP_DESKTOP_EXE_U="$HP_ROOT_U/$HP_DESKTOP_EXE_REL"
HP_DATA_U=$(hp_data_unix)
export HP_ROOT HP_ROOT_U HP_PAYLOAD_U HP_GIT_U HP_PYTHON_U HP_DESKTOP_EXE_U HP_DATA_U

mkdir -p "$HP_DATA_U"/{hermes,home/AppData/Roaming,home/AppData/Local,desktop,cache/npm,cache/hf,cache/node-compile,logs,state}

# --- data locations -------------------------------------------------------------
export HERMES_HOME="$(cygpath -w "$HP_DATA_U/hermes")"
export HOME="$HP_DATA_U/home"
export USERPROFILE="$(cygpath -w "$HP_DATA_U/home")"
export APPDATA="$(cygpath -w "$HP_DATA_U/home/AppData/Roaming")"
export LOCALAPPDATA="$(cygpath -w "$HP_DATA_U/home/AppData/Local")"
export HERMES_DESKTOP_USER_DATA_DIR="$(cygpath -w "$HP_DATA_U/desktop")"
export npm_config_cache="$(cygpath -w "$HP_DATA_U/cache/npm")"
export HF_HOME="$(cygpath -w "$HP_DATA_U/cache/hf")"
# Node keeps its module compile cache in the system %TEMP% unless told otherwise.
export NODE_COMPILE_CACHE="$(cygpath -w "$HP_DATA_U/cache/node-compile")"
export GIT_CONFIG_GLOBAL="$(cygpath -w "$HP_DATA_U/home/.gitconfig")"
# A fresh HERMES_HOME starts from the shipped templates, as the installers prepare it
# (install.ps1; hermes_cli.config.seed_config_file). Without config.yaml no model is
# set, and every new session's stored policy is refused ("storage_unavailable").
for hp_seed in config.yaml:cli-config.yaml.example .env:.env.example; do
  if [ ! -e "$HP_DATA_U/hermes/${hp_seed%%:*}" ] && [ -f "$HP_PAYLOAD_U/hermes-agent/${hp_seed#*:}" ]; then
    cp "$HP_PAYLOAD_U/hermes-agent/${hp_seed#*:}" "$HP_DATA_U/hermes/${hp_seed%%:*}"
  fi
done
unset hp_seed
if [ ! -f "$HP_DATA_U/home/.gitconfig" ]; then
  printf '[core]\n\tlongpaths = true\n' > "$HP_DATA_U/home/.gitconfig"
fi

# --- enforced policy --------------------------------------------------------------
export HERMES_MANAGED_DIR="$(cygpath -w "$HP_ROOT_U/portable/managed")"
export HERMES_GIT_BASH_ONLY=1
export HERMES_GIT_BASH_PATH="$(cygpath -w "$HP_GIT_U/usr/bin/bash.exe")"
export HERMES_DESKTOP_SKIP_PROTOCOL_REGISTRATION=1
export HERMES_DESKTOP_SHELL="$HERMES_GIT_BASH_PATH"
export PYTHONUTF8=1
export LANG="${LANG:-C.UTF-8}"
export DO_NOT_TRACK=1 HF_HUB_DISABLE_TELEMETRY=1 ANONYMIZED_TELEMETRY=false
if [ -n "${HP_ALLOW_LAZY_INSTALLS:-}" ] && ! hp_truthy "$HP_ALLOW_LAZY_INSTALLS"; then
  export HERMES_DISABLE_LAZY_INSTALLS=1
fi
[ -n "${HP_ARTIFACT_MIRROR:-}" ] && export HERMES_ARTIFACT_MIRROR="$HP_ARTIFACT_MIRROR"
[ -n "${HP_HF_ENDPOINT:-}" ] && export HF_ENDPOINT="$HP_HF_ENDPOINT"

# --- start directory ----------------------------------------------------------------
if [ -n "${HP_START_DIR:-}" ]; then
  HP_START_U=$(hp_abs "$HP_START_DIR")
elif [ -n "${HP_LAUNCH_CWD:-}" ] && [ "$(cygpath -u "$HP_LAUNCH_CWD")" != "$HP_ROOT_U" ]; then
  HP_START_U=$(cygpath -u "$HP_LAUNCH_CWD")
elif [ -n "${HP_REAL_USERPROFILE:-}" ]; then
  HP_START_U=$(cygpath -u "$HP_REAL_USERPROFILE")
else
  HP_START_U=$HP_DATA_U/home
fi
export HP_START_U
export HERMES_DESKTOP_CWD="$(cygpath -w "$HP_START_U")"

# --- PATH: bundled tools only ---------------------------------------------------------
hp_path=("$HP_PAYLOAD_U/bin" "$HP_ROOT_U/portable/bin")
for rel in "$HP_NODE_DIR_REL" "$HP_NPM_DIR_REL" "$HP_UV_DIR_REL" "$HP_RG_DIR_REL" "$HP_FFMPEG_DIR_REL"; do
  [ -n "$rel" ] && hp_path+=("$HP_ROOT_U/$rel")
done
hp_path+=("$HP_GIT_U/cmd" /mingw64/bin /usr/bin)
hp_sysroot=$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")
hp_path+=("$hp_sysroot/System32" "$hp_sysroot" "$hp_sysroot/System32/Wbem"
          "$hp_sysroot/System32/WindowsPowerShell/v1.0" "$hp_sysroot/System32/OpenSSH")
if hp_truthy "${HP_INHERIT_PATH:-0}" && [ -n "${HP_REAL_PATH:-}" ]; then
  hp_path+=("$(cygpath -u -p "$HP_REAL_PATH")")
fi
PATH=$(IFS=:; printf '%s' "${hp_path[*]}")
export PATH
# uv's own discovery would take a host Python (Windows registry) or download one from
# GitHub; default it to the bundled interpreter, as PM does for its own uv calls.
# A project that asks for another version still gets one (into data\, never the host's).
[ -n "${UV_PYTHON:-}" ] || export UV_PYTHON="$(cygpath -w "$HP_PYTHON_U")"
unset hp_path hp_sysroot rel

# --- network: proxy, Nexus sources, TLS ------------------------------------------------
# shellcheck source=network.sh
. "$HP_LIB/network.sh"
hp_network_env

# MSYS rewrites arguments that look like POSIX paths (/model) for native
# programs; Hermes arguments are passed through untouched.
hermes() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command hermes.exe "$@"
}
export -f hermes
