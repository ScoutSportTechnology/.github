#!/usr/bin/env bash
# =============================================================================
# publish-release.sh — create (or finish) a GitHub Release for a version tag,
# attach its assets and record each asset's SHA-256 in the release notes.
#
# Inputs (env):
#   TAG             required  version tag, e.g. v0.1.0-beta.3
#   TARGET          required  commit SHA the tag points to
#   PRERELEASE      true|false (default true)
#   FILES           newline-separated paths or globs of assets (may be empty)
#   NOTES           free text placed above the digest block; {tag} -> TAG
#   GENERATE_NOTES  true|false (default true): append GitHub-generated notes
#   GH_TOKEN, GH_REPO  for gh
#
# Digest contract (read back by the promote action, fail closed):
#   sha256: <64 hex>  <asset file name>
# one line per asset, inside the "Asset integrity (SHA-256)" block.
#
# Atomicity: a new release is created as a DRAFT, assets are uploaded, then it
# is published. A draft creates no tag, so a cancelled run never leaves an
# immutable tag without its assets. A re-run finds the draft (or the published
# release), re-uploads with --clobber and publishes.
# =============================================================================
set -euo pipefail

: "${TAG:?TAG is required}"
: "${TARGET:?TARGET is required}"
PRERELEASE="${PRERELEASE:-true}"
GENERATE_NOTES="${GENERATE_NOTES:-true}"
FILES="${FILES:-}"
NOTES="${NOTES:-}"

# Expand FILES (paths or globs, one per line) into an array; fail on no match.
assets=()
while IFS= read -r pattern; do
  pattern="${pattern#"${pattern%%[![:space:]]*}"}"; pattern="${pattern%"${pattern##*[![:space:]]}"}"
  [ -z "$pattern" ] && continue
  matched=0
  for f in $pattern; do
    [ -f "$f" ] || continue
    assets+=("$f"); matched=1
  done
  [ "$matched" = 1 ] || { echo "::error::no file matches '${pattern}'" >&2; exit 1; }
done <<<"$FILES"

notes_file="$(mktemp)"
{
  if [ -n "$NOTES" ]; then
    printf '%s\n\n' "${NOTES//\{tag\}/$TAG}"
  fi
  if [ "${#assets[@]}" -gt 0 ]; then
    echo "### Asset integrity (SHA-256)"
    echo ""
    echo "Promotion copies these bytes unchanged and verifies them against these digests."
    echo ""
    for f in "${assets[@]}"; do
      echo "    sha256: $(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")"
    done
  fi
} >"$notes_file"

pre_flag=(--prerelease=false)
[ "$PRERELEASE" = true ] && pre_flag=(--prerelease)

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release ${TAG} exists; refreshing notes and assets."
  gh release edit "$TAG" "${pre_flag[@]}" --notes-file "$notes_file"
else
  create=(gh release create "$TAG" --draft --target "$TARGET" --title "$TAG" --notes-file "$notes_file")
  [ "$GENERATE_NOTES" = true ] && create+=(--generate-notes)
  [ "$PRERELEASE" = true ] && create+=(--prerelease)
  "${create[@]}"
fi

if [ "${#assets[@]}" -gt 0 ]; then
  gh release upload "$TAG" "${assets[@]}" --clobber
fi

# Publishing the draft creates the tag at TARGET. No-op if already published.
gh release edit "$TAG" --draft=false "${pre_flag[@]}"

echo "Published ${TAG} -> ${TARGET} (${#assets[@]} asset(s))."
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "tag=${TAG}" >>"$GITHUB_OUTPUT"
fi
