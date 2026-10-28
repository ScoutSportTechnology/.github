#!/usr/bin/env bash
# =============================================================================
# promote.sh — promote an existing prerelease to the next level WITHOUT
# rebuilding: same bytes, verified against their recorded SHA-256.
#
#   TO=rc      highest vX.Y.Z-beta.N  -> vX.Y.Z-rc.1, tag on the SAME commit as
#              the beta. Run after the beta passed the hardware test (button
#              today, hardware-rig job later). Refuses if an rc already exists:
#              from then on release/X.Y.Z merges mint rc.N on their own.
#   TO=stable  highest vX.Y.Z-rc.N    -> vX.Y.Z, tag on TARGET (the merge commit
#              on main). Refuses if no rc exists: only a hardware-validated
#              candidate may ship.
#
# Inputs (env):
#   TO        required  rc | stable
#   BASE      X.Y.Z; optional. rc: defaults from GITHUB_REF_NAME release/X.Y.Z.
#             stable: defaults from `release/X.Y.Z` in the TARGET commit
#             message, else the highest rc tag merged into TARGET.
#   TARGET    stable only; commit to tag (default GITHUB_SHA, else HEAD)
#   ASSETS    glob of source asset names to carry over (default '*')
#   NOTES     free text above the digest block; {tag} -> new tag
#   GH_TOKEN, GH_REPO  for gh
# Must run inside a full-history checkout (fetch-depth: 0) of the repo.
#
# Asset names that contain the source tag are renamed to the new tag
# (sst-cam-app-v0.1.0-beta.4-production.apk -> ...-v0.1.0-rc.1-...).
# Digest lookup: the `sha256: <hex>  <name>` line for the asset; for legacy
# notes with no names, a single sha256 line is accepted only when exactly one
# asset is promoted. Anything else fails closed.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="${HERE}/../resolve-version/resolve-version.sh"
PUBLISH="${HERE}/../publish-release/publish-release.sh"

TO="${TO:-}"
BASE="${BASE:-}"; BASE="${BASE#v}"
ASSETS="${ASSETS:-*}"
NOTES="${NOTES:-}"

die() { echo "::error::$*" >&2; exit 1; }

highest() { # base rung -> highest strictly-formed tag or ""
  local re_base="${1//./\\.}"
  git tag -l "v$1-$2."'*' --sort=-v:refname | grep -E "^v${re_base}-$2\.[0-9]+\$" | head -1 || true
}

valid_base() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

case "$TO" in
  rc)
    if [ -z "$BASE" ]; then
      case "${GITHUB_REF_NAME:-}" in release/*) BASE="${GITHUB_REF_NAME#release/}" ;; esac
    fi
    valid_base "$BASE" || die "promote to rc needs X.Y.Z (input version, or run on release/X.Y.Z)"
    [ -z "$(highest "$BASE" rc)" ] \
      || die "v${BASE} is already in the rc phase ($(highest "$BASE" rc)); merges to release/${BASE} mint rc.N themselves"
    SRC="$(highest "$BASE" beta)"
    [ -n "$SRC" ] || die "no v${BASE}-beta.* tag to promote"
    NEW="$("$RESOLVE" rc "$BASE" | sed -n 's/^tag=//p')"
    TARGET="$(git rev-list -n 1 "$SRC")"
    PRERELEASE=true
    ;;
  stable)
    TARGET="${TARGET:-${GITHUB_SHA:-$(git rev-parse HEAD)}}"
    if [ -z "$BASE" ]; then
      BASE="$(git log -1 --format='%s%n%b' "$TARGET" \
        | grep -oE 'release/[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's#release/##' || true)"
    fi
    if [ -z "$BASE" ]; then
      cand="$(git tag --merged "$TARGET" -l 'v*-rc.*' --sort=-v:refname \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' | head -1 || true)"
      cand="${cand#v}"; BASE="${cand%-rc.*}"
    fi
    valid_base "$BASE" || die "cannot derive X.Y.Z for stable promotion; pass the version input"
    SRC="$(highest "$BASE" rc)"
    [ -n "$SRC" ] || die "no v${BASE}-rc.* tag exists; only a hardware-validated rc can become stable"
    NEW="$("$RESOLVE" stable "$BASE" | sed -n 's/^tag=//p')"
    PRERELEASE=false
    ;;
  *) die "TO must be rc or stable (got '${TO}')" ;;
esac

echo "Promoting ${SRC} -> ${NEW} at ${TARGET}"

work="$(mktemp -d)"
src_dir="${work}/src"; out_dir="${work}/out"
mkdir -p "$src_dir" "$out_dir"

notes="$(gh release view "$SRC" --json body --jq '.body' 2>/dev/null || true)"
mapfile -t names < <(gh release view "$SRC" --json assets --jq '.assets[].name' 2>/dev/null || true)

selected=()
for n in "${names[@]}"; do
  [ -z "$n" ] && continue
  # shellcheck disable=SC2053  # glob match on purpose
  [[ "$n" == $ASSETS ]] && selected+=("$n")
done

sha_lines="$(grep -oiE 'sha256:[[:space:]]*[0-9a-f]{64}([^0-9a-f].*)?$' <<<"$notes" || true)"
sha_count="$(grep -c . <<<"$sha_lines" || true)"

files=""
for n in "${selected[@]}"; do
  gh release download "$SRC" --dir "$src_dir" --pattern "$n" --clobber
  [ -f "${src_dir}/${n}" ] || die "asset '${n}' missing from ${SRC}; refusing to rebuild"

  line="$(awk -v n="$n" '$NF == n { print; exit }' <<<"$sha_lines")"
  if [ -z "$line" ] && [ "$sha_count" = 1 ] && [ "${#selected[@]}" = 1 ]; then
    line="$sha_lines"   # legacy notes: one digest, one asset, no name
  fi
  want="$(grep -oiE '[0-9a-f]{64}' <<<"$line" | head -1 | tr 'A-F' 'a-f' || true)"
  [ -n "$want" ] || die "no recorded sha256 for '${n}' in ${SRC} notes; failing closed"
  got="$(sha256sum "${src_dir}/${n}" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || die "sha256 mismatch for '${n}': recorded ${want}, downloaded ${got}"
  echo "verified ${n} ${got}"

  dst="${n//${SRC}/${NEW}}"
  cp "${src_dir}/${n}" "${out_dir}/${dst}"
  files+="${out_dir}/${dst}"$'\n'
done

TAG="$NEW" TARGET="$TARGET" PRERELEASE="$PRERELEASE" FILES="$files" NOTES="$NOTES" \
  GENERATE_NOTES=true "$PUBLISH"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "tag=${NEW}"; echo "source=${SRC}"; echo "base=${BASE}"; } >>"$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Promoted ${SRC} -> ${NEW} (no rebuild)"
    echo ""
    echo "${#selected[@]} asset(s) copied and verified against their recorded SHA-256."
    if [ "$TO" = stable ]; then
      echo ""
      echo "Follow-up: delete \`release/${BASE}\` and open a PR \`main -> development\`."
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi
