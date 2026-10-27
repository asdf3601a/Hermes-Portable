#!/usr/bin/env bash
# Hermes Portable: lay out the distributable folder from the packaged desktop
# (upstream/apps/desktop/release/win-unpacked) and the portable layer.
# Runs after `build.sh package`; nothing here re-enters upstream's pipeline.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_state

dist="$BUILD_DIR/dist/${DIST_DIR_PREFIX}-$PORTABLE_VERSION"
unpacked=$(find "$UPSTREAM/apps/desktop/release" -maxdepth 2 -type d -name 'win*-unpacked' | head -n1)
[ -n "$unpacked" ] && [ -f "$unpacked/resources/agent-payload/manifest.json" ] \
  || die "no packaged desktop with resources/agent-payload under apps/desktop/release"

log "folder: $dist"
rm -rf "$dist"
mkdir -p "$dist"
mv "$unpacked" "$dist/desktop" 2>/dev/null || cp -a "$unpacked" "$dist/desktop"
payload="$dist/desktop/resources/agent-payload"

# --- payload post-processing (after finish_native: nothing re-verifies these) ----
if ! hp_truthy "${INCLUDE_UV_CACHE:-0}"; then
  log "drop uv-cache ($(du -sh "$payload/uv-cache" 2>/dev/null | cut -f1))"
  rm -rf "$payload/uv-cache"
fi

site="$payload/venv/Lib/site-packages"
[ -d "$site" ] || die "payload venv site-packages not found: $site"
cp "$HP_REPO/portable/python/hp_sslhook.py" "$HP_REPO/portable/python/zz_hermes_portable.pth" "$site/"

# Hand-off of the original lock files: a Nexus-built payload carries switched
# locks, `hermes-portable sources ... use-original` restores these copies.
if [ "$PYPI_SOURCE" != original ] || [ "$NPM_SOURCE" != original ]; then
  while IFS= read -r lock; do
    relpath=${lock#"$payload/hermes-agent/"}
    if git -C "$UPSTREAM" cat-file -e "$UPSTREAM_SHA:$relpath" 2>/dev/null; then
      git -C "$UPSTREAM" show "$UPSTREAM_SHA:$relpath" > "$lock.upstream"
      log "original kept: hermes-agent/$relpath.upstream"
    fi
  done < <(find "$payload/hermes-agent" \( -name uv.lock -o -name package-lock.json \) -not -path '*/node_modules/*')
fi

# --- portable layer ---------------------------------------------------------------
cp "$HP_REPO"/portable/*.cmd "$dist/"
mkdir -p "$dist/portable" "$dist/config" "$dist/licenses"
cp -r "$HP_REPO/portable/lib" "$HP_REPO/portable/bin" "$HP_REPO/portable/python" \
      "$HP_REPO/portable/managed" "$dist/portable/"
find "$dist/portable" -name __pycache__ -prune -exec rm -rf {} +
cp "$HP_REPO/portable/config/portable.env.example" "$dist/config/"
cp -r "$HP_REPO/docs" "$dist/docs"
cp "$HP_REPO/README.md" "$dist/README.md"

tool_lines=$("${PY[@]}" -I "$HP_REPO/build/lib/payload_paths.py" "$(cygpath -w "$dist")")
log "paths: $(tr '\n' ' ' < "$dist/portable/paths.sh")"

# --- VERSION.txt -------------------------------------------------------------------
{
  printf 'portable=%s\n' "$PORTABLE_VERSION"
  printf 'upstream_version=%s\n' "$UPSTREAM_VERSION"
  printf 'upstream_commit=%s\n' "$UPSTREAM_SHA"
  printf 'patched_commit=%s\n' "$PATCHED_SHA"
  printf 'portable_commit=%s\n' "$(git -C "$HP_REPO" rev-parse --verify -q HEAD || echo unknown)"
  printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'pypi_source=%s\n' "$PYPI_SOURCE"
  printf 'npm_source=%s\n' "$NPM_SOURCE"
  printf 'bundle_exclude=%s\n' "${BUNDLE_EXCLUDE:-}"
  printf 'uv_cache=%s\n' "$(hp_truthy "${INCLUDE_UV_CACHE:-0}" && echo included || echo dropped)"
  printf '%s\n' "$tool_lines"
} > "$dist/VERSION.txt"
cat "$dist/VERSION.txt"

# --- licenses ------------------------------------------------------------------------
cp "$UPSTREAM/LICENSE" "$dist/licenses/hermes-agent-LICENSE.txt"
for file in "$dist"/desktop/LICENSE* "$dist"/desktop/LICENSES.chromium.html; do
  [ -f "$file" ] && cp "$file" "$dist/licenses/electron-$(basename "$file")"
done
for tool in "$payload"/tools/*/; do
  name=$(basename "$tool")
  for file in "$tool"LICENSE* "$tool"COPYING* "$tool"NOTICE* "$tool"*/LICENSE.txt; do
    [ -f "$file" ] || continue
    mkdir -p "$dist/licenses/$name"
    cp "$file" "$dist/licenses/$name/"
  done
done
cp "$HP_REPO/docs/THIRD-PARTY-NOTICES.md" "$dist/licenses/"

# --- release hygiene -----------------------------------------------------------------
bad=$(find "$dist" \( -type l -o -name .git \) -print | head -n5)
[ -z "$bad" ] || die "symlinks/junctions or .git entries in the folder:\n$bad"
compgen -G "$payload/tools/cua-driver*" > /dev/null && die "cua-driver must not be in the payload"
log "assembled $(du -sh "$dist" | cut -f1)"
