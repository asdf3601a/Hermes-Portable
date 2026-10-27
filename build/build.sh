#!/usr/bin/env bash
# Hermes Portable build driver (Git Bash on Windows x64). CI and local builds
# run the same steps:
#
#   build/build.sh all                       patch prepare package assemble smoke zip
#   build/build.sh patch prepare ...         any subset, in order
#
# Settings: build/bundle.conf, optional build/build.env, environment variables
# (HP_PYPI_INDEX_URL / HP_NPM_REGISTRY switch the whole build to Nexus).
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

git_commit() {
  # Deterministic identity and dates: the same inputs give the same PATCHED_SHA,
  # which keeps CI cache keys stable.
  local date
  date=$(git -C "$UPSTREAM" log -1 --format=%cI "$(pinned_upstream)")
  GIT_AUTHOR_NAME="Hermes Portable" GIT_AUTHOR_EMAIL=build@hermes-portable.invalid \
  GIT_COMMITTER_NAME="Hermes Portable" GIT_COMMITTER_EMAIL=build@hermes-portable.invalid \
  GIT_AUTHOR_DATE=$date GIT_COMMITTER_DATE=$date \
    git -C "$UPSTREAM" -c commit.gpgsign=false commit -q --no-verify "$@"
}

cmd_patch() {
  group "patch: upstream $(upstream_version) + patches/"
  local pinned
  pinned=$(pinned_upstream)
  git -C "$UPSTREAM" config core.longpaths true
  git -C "$UPSTREAM" reset -q --hard
  git -C "$UPSTREAM" clean -fdq
  git -C "$UPSTREAM" -c advice.detachedHead=false checkout -q --detach "$pinned"
  local tagged
  if tagged=$(git -C "$UPSTREAM" ls-remote origin "refs/tags/$UPSTREAM_TAG" "refs/tags/$UPSTREAM_TAG^{}" 2>/dev/null); then
    grep -q "^$pinned" <<< "$tagged" \
      || die "bundle.conf UPSTREAM_TAG=$UPSTREAM_TAG does not point at the pinned submodule commit $pinned"
  else
    warn "could not reach the upstream remote to confirm $UPSTREAM_TAG (closed network?)"
  fi
  local patch
  for patch in "$HP_REPO"/patches/*.patch; do
    log "apply $(basename "$patch")"
    git -C "$UPSTREAM" apply --cached --whitespace=nowarn "$patch" \
      || die "$(basename "$patch") no longer applies to upstream $pinned; see docs/MAINTENANCE.md"
  done
  git_commit -m "Hermes Portable patches"
  git -C "$UPSTREAM" reset -q --hard

  local pypi_source=original npm_source=original
  build_network_env
  if [ -n "${HP_PYPI_INDEX_URL:-}" ]; then
    log "switch PyPI locks to $(public_url "$HP_PYPI_INDEX_URL")"
    "${PY[@]}" -I "$HP_REPO/portable/python/hp_sources.py" --root "$(cygpath -w "$UPSTREAM")" \
      pypi use-nexus --no-backup ${HP_SOURCES_NO_PROBE:+--no-probe} --mode "${HP_PYPI_LOCK_MODE:-discover}" \
      --files-template "${HP_PYPI_FILES_TEMPLATE:-nexus}"
    pypi_source=$(public_url "${HP_PYPI_INDEX_URL%/}")
  fi
  if [ -n "${HP_NPM_REGISTRY:-}" ]; then
    log "switch npm locks to $(public_url "$HP_NPM_REGISTRY")"
    "${PY[@]}" -I "$HP_REPO/portable/python/hp_sources.py" --root "$(cygpath -w "$UPSTREAM")" \
      npm use-nexus --no-backup ${HP_SOURCES_NO_PROBE:+--no-probe}
    npm_source=$(public_url "${HP_NPM_REGISTRY%/}/")
  fi
  if [ -n "$(git -C "$UPSTREAM" status --porcelain --untracked-files=no)" ]; then
    git -C "$UPSTREAM" add -u
    git_commit -m "Hermes Portable package sources (pypi: $pypi_source, npm: $npm_source)"
  fi
  [ -z "$(git -C "$UPSTREAM" status --porcelain --untracked-files=all)" ] \
    || die "upstream checkout is not clean after patching"

  cat > "$STATE_FILE" <<EOF
UPSTREAM_SHA=$pinned
UPSTREAM_VERSION=$(upstream_version)
PATCHED_SHA=$(git -C "$UPSTREAM" rev-parse HEAD)
PORTABLE_VERSION=$(portable_version)
PYPI_SOURCE='$pypi_source'
NPM_SOURCE='$npm_source'
EOF
  cat "$STATE_FILE"
  endgroup
}

# Upstream's desktop pipeline: PM fetches pinned Python/Node/npm/tools, builds the
# sealed venv, frontends and Electron native modules (scripts/bundles/desktop.py).
desktop_py() {
  build_network_env
  HERMES_BUNDLE_EXCLUDE="${BUNDLE_EXCLUDE:-}" HERMES_DESKTOP_WIN_TARGETS=dir \
  HERMES_COMMIT_BUILD_VERSION="$(upstream_version)" \
    "${PY[@]}" "$(cygpath -w "$UPSTREAM/scripts/bundles/desktop.py")" "$@"
}

cmd_prepare() {
  load_state
  group "prepare: desktop + agent payload dependencies ($PATCHED_SHA)"
  desktop_py --repo "$(cygpath -w "$UPSTREAM")" --commit "$PATCHED_SHA" --variant bundled \
    --prepare-only --work "$(cygpath -w "$DESKTOP_WORK")" --cache "$(cygpath -w "$DESKTOP_CACHE")"
  endgroup
}

cmd_package() {
  load_state
  group "package: Hermes Desktop (unpacked) with resources/agent-payload"
  rm -rf "$UPSTREAM/apps/desktop/release"
  desktop_py --prepared "$(cygpath -w "$DESKTOP_WORK/prepared.json")" --variant bundled
  endgroup
}

cmd_assemble() {
  load_state
  group "assemble: portable folder"
  bash "$HP_REPO/build/assemble.sh"
  endgroup
}

cmd_smoke() {
  load_state
  group "smoke tests"
  bash "$HP_REPO/build/smoke-test.sh" "$BUILD_DIR/dist/${DIST_DIR_PREFIX}-$PORTABLE_VERSION"
  endgroup
}

cmd_zip() {
  load_state
  group "zip"
  local folder="${DIST_DIR_PREFIX}-$PORTABLE_VERSION"
  local zip="$BUILD_DIR/dist/${DIST_NAME}-${PORTABLE_VERSION}-win-x64.zip"
  local over
  over=$(cd "$BUILD_DIR/dist" && find "$folder" -print | awk -v max="${MAX_REL_PATH:?}" 'length($0) > max { print length($0) "\t" $0 }' | sort -rn)
  log "$(grep '^longest_path=\|^max_extract_folder_chars=' "$BUILD_DIR/dist/$folder/VERSION.txt" | tr '\n' ' ')"
  if [ -n "$over" ]; then
    printf '%s\n' "$over" | head -n 15 >&2
    die "$(printf '%s\n' "$over" | wc -l) path(s) longer than MAX_REL_PATH=$MAX_REL_PATH; extraction would hit MAX_PATH"
  fi
  rm -f "$zip" "$zip.sha256"
  local sevenzip
  sevenzip=$(command -v 7z || command -v 7z.exe || printf '%s' "/c/Program Files/7-Zip/7z.exe")
  [ -x "$sevenzip" ] || die "7-Zip not found"
  (cd "$BUILD_DIR/dist" && "$sevenzip" a -tzip -mx=7 -mm=Deflate -bso0 -bsp0 "$(cygpath -w "$zip")" "$folder")
  local size
  size=$(stat -c %s "$zip")
  log "$(basename "$zip"): $((size / 1048576)) MiB"
  [ "$size" -le "${MAX_ZIP_BYTES:?}" ] || die "zip exceeds MAX_ZIP_BYTES (GitHub release asset limit)"
  (cd "$BUILD_DIR/dist" && sha256sum "$(basename "$zip")" > "$(basename "$zip").sha256")
  cp "$BUILD_DIR/dist/$folder/VERSION.txt" "$BUILD_DIR/dist/VERSION.txt"
  endgroup
}

[ $# -gt 0 ] || set -- all
for step in "$@"; do
  case $step in
    all) cmd_patch; cmd_prepare; cmd_package; cmd_assemble; cmd_smoke; cmd_zip ;;
    patch|prepare|package|assemble|smoke|zip) "cmd_$step" ;;
    *) die "unknown step: $step (patch prepare package assemble smoke zip all)" ;;
  esac
done
