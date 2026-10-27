# Hermes Portable: config/portable.env reader (sourced; bash).
#
# portable.env is KEY=VALUE text edited in Notepad: CRLF is fine, `export ` is
# optional, values may be quoted, `#` starts a comment line. Nothing is
# evaluated; ${HP_ROOT} and %HP_ROOT% expand to the portable folder.

hp_root_unix() {
  cygpath -u "$HP_ROOT"
}

hp_config_file() {
  printf '%s\n' "$(hp_root_unix)/config/portable.env"
}

# hp_config_each FILE -> prints KEY<TAB>VALUE per valid line
hp_config_each() {
  local file=$1 line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      [ -n "${HP_CONFIG_WARN:-}" ] && printf '%s: ignoring malformed line: %s\n' "${file##*/}" "$line" >&2
      continue
    fi
    key=${BASH_REMATCH[2]}
    value=${BASH_REMATCH[3]}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
      value=${BASH_REMATCH[1]}
    fi
    # shellcheck disable=SC2016 # the literal text ${HP_ROOT}
    value=${value//'${HP_ROOT}'/$HP_ROOT}
    value=${value//'%HP_ROOT%'/$HP_ROOT}
    printf '%s\t%s\n' "$key" "$value"
  done < "$file"
}

# hp_config_value KEY -> last value of KEY in portable.env (empty if unset)
hp_config_value() {
  local key value result=
  while IFS=$'\t' read -r key value; do
    [ "$key" = "$1" ] && result=$value
  done < <(hp_config_each "$(hp_config_file)")
  printf '%s\n' "$result"
}

# hp_load_config: export every KEY=VALUE of portable.env (reports bad lines)
hp_load_config() {
  local key value
  while IFS=$'\t' read -r key value; do
    export "$key=$value"
  done < <(HP_CONFIG_WARN=1 hp_config_each "$(hp_config_file)")
}

# hp_abs PATH -> POSIX absolute path; relative paths are relative to HP_ROOT
hp_abs() {
  local path=$1
  case $path in
    [A-Za-z]:*|\\\\*) cygpath -u "$path" ;;
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$(hp_root_unix)" "$path" ;;
  esac
}

hp_truthy() {
  case ${1,,} in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

# hp_data_unix -> POSIX path of the portable data folder (HP_DATA_DIR in
# portable.env, default data/). Read from the file, never from an inherited
# variable, so it is identical before and after the scrub.
hp_data_unix() {
  local dir
  dir=$(hp_config_value HP_DATA_DIR)
  hp_abs "${dir:-data}"
}
