#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012,SC2016  # ok/bad never fail; ls output is test-controlled; literal backticks
# =============================================================================
# Tests for promote.sh + publish-release.sh against a fake `gh` that keeps
# releases on disk ($FAKE_GH/<tag>/{body,target,prerelease,draft,assets/}).
# Real git repos and tags, so tag selection and target commits are exercised.
#
# Run: actions/promote/promote-test.sh   (exit 0 = all pass)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMOTE="${HERE}/promote.sh"
PUBLISH="${HERE}/../publish-release/publish-release.sh"
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_REF_NAME GITHUB_SHA

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1"; }
expect_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1 (got '$2', want '$3')"; fi; }

# ---------------------------------------------------------------- fake gh
BIN="$(mktemp -d)"
cat >"${BIN}/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = release ] || { echo "fake gh: unsupported $*" >&2; exit 2; }
cmd="$2"; tag="$3"; shift 3
d="${FAKE_GH}/${tag}"
case "$cmd" in
  view)
    [ -d "$d" ] || { echo "release not found" >&2; exit 1; }
    if [ "${1:-}" = --json ]; then
      case "$2" in
        body) cat "$d/body" ;;
        assets) ls "$d/assets" 2>/dev/null || true ;;
      esac
    fi
    ;;
  create)
    [ -d "$d" ] && { echo "already exists" >&2; exit 1; }
    mkdir -p "$d/assets"; echo false >"$d/prerelease"; echo false >"$d/draft"
    while [ $# -gt 0 ]; do
      case "$1" in
        --target) echo "$2" >"$d/target"; shift ;;
        --notes-file) cp "$2" "$d/body" ;;
        --prerelease) echo true >"$d/prerelease" ;;
        --draft) echo true >"$d/draft" ;;
        --title) shift ;;
      esac
      shift
    done
    ;;
  edit)
    [ -d "$d" ] || exit 1
    while [ $# -gt 0 ]; do
      case "$1" in
        --notes-file) cp "$2" "$d/body"; shift ;;
        --prerelease) echo true >"$d/prerelease" ;;
        --prerelease=false) echo false >"$d/prerelease" ;;
        --draft=false) echo false >"$d/draft" ;;
      esac
      shift
    done
    ;;
  upload)
    [ -d "$d" ] || exit 1
    for f in "$@"; do [ "$f" = --clobber ] || cp "$f" "$d/assets/"; done
    ;;
  download)
    [ -d "$d" ] || exit 1
    dir=.; pat='*'
    while [ $# -gt 0 ]; do
      case "$1" in --dir) dir="$2"; shift ;; --pattern) pat="$2"; shift ;; esac
      shift
    done
    n=0
    for f in "$d/assets/"$pat; do [ -f "$f" ] && cp "$f" "$dir/" && n=$((n + 1)); done
    [ "$n" -gt 0 ] || { echo "no assets match" >&2; exit 1; }
    ;;
  *) echo "fake gh: unsupported release $cmd" >&2; exit 2 ;;
esac
FAKE
chmod +x "${BIN}/gh"
export PATH="${BIN}:${PATH}"

new_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q -b release/0.1.0
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  git -C "$d" config tag.gpgsign false
  echo "$d"
}
commit() { git -C "$1" commit -q --allow-empty -m "$2"; }

# Publish a release the way the beta/rc workflows do, with real assets.
seed_release() { # repo tag files...
  local repo="$1" tag="$2"; shift 2
  git -C "$repo" tag "$tag"
  local files=""
  for f in "$@"; do files+="$f"$'\n'; done
  ( cd "$repo" && TAG="$tag" TARGET="$(git rev-parse "$tag")" FILES="$files" "$PUBLISH" ) >/dev/null
}

asset() { # dir name content -> path
  printf '%s' "$3" >"$1/$2"; echo "$1/$2"
}

promote() { # repo, env assignments... ; runs promote.sh in repo
  local repo="$1"; shift
  ( cd "$repo" && env "$@" "$PROMOTE" ) >/dev/null 2>&1
}

# ------------------------------------------- publish: draft -> upload -> publish
export FAKE_GH; FAKE_GH="$(mktemp -d)"
r="$(new_repo)"; commit "$r" "feat: a"; a="$(mktemp -d)"
seed_release "$r" v0.1.0-beta.1 "$(asset "$a" app-v0.1.0-beta.1-x.apk AAA)"
expect_eq "publish: not left as draft" "$(cat "$FAKE_GH/v0.1.0-beta.1/draft")" "false"
expect_eq "publish: prerelease" "$(cat "$FAKE_GH/v0.1.0-beta.1/prerelease")" "true"
grep -q "sha256: $(printf AAA | sha256sum | cut -d' ' -f1)  app-v0.1.0-beta.1-x.apk" "$FAKE_GH/v0.1.0-beta.1/body" \
  && ok || bad "publish: digest line with asset name"
( cd "$r" && TAG=v0.1.0-beta.9 TARGET=x FILES="/nope/*.apk" "$PUBLISH" ) >/dev/null 2>&1 \
  && bad "publish: missing file must fail" || ok

# ----------------------------------------------------- rc: beta -> rc.1, 2 assets
FAKE_GH="$(mktemp -d)"
r="$(new_repo)"; commit "$r" "feat: a"; a="$(mktemp -d)"
seed_release "$r" v0.1.0-beta.3 "$(asset "$a" app-v0.1.0-beta.3-production.apk P3)" "$(asset "$a" app-v0.1.0-beta.3-developer.apk D3)"
commit "$r" "fix: b"
seed_release "$r" v0.1.0-beta.4 "$(asset "$a" app-v0.1.0-beta.4-production.apk P4)" "$(asset "$a" app-v0.1.0-beta.4-developer.apk D4)"
beta4="$(git -C "$r" rev-parse v0.1.0-beta.4)"
commit "$r" "docs: after beta.4"
if promote "$r" TO=rc GITHUB_REF_NAME=release/0.1.0; then ok; else bad "rc: promote failed"; fi
expect_eq "rc: new release exists" "$([ -d "$FAKE_GH/v0.1.0-rc.1" ] && echo yes)" "yes"
expect_eq "rc: target is beta.4 commit" "$(cat "$FAKE_GH/v0.1.0-rc.1/target" 2>/dev/null)" "$beta4"
expect_eq "rc: prerelease" "$(cat "$FAKE_GH/v0.1.0-rc.1/prerelease" 2>/dev/null)" "true"
expect_eq "rc: assets renamed" "$(ls "$FAKE_GH/v0.1.0-rc.1/assets" 2>/dev/null | tr '\n' ' ')" \
  "app-v0.1.0-rc.1-developer.apk app-v0.1.0-rc.1-production.apk "
expect_eq "rc: bytes preserved" "$(cat "$FAKE_GH/v0.1.0-rc.1/assets/app-v0.1.0-rc.1-production.apk" 2>/dev/null)" "P4"
grep -q "sha256: $(printf P4 | sha256sum | cut -d' ' -f1)  app-v0.1.0-rc.1-production.apk" "$FAKE_GH/v0.1.0-rc.1/body" 2>/dev/null \
  && ok || bad "rc: digest recorded under the new name"

# rc phase already started -> refuse
git -C "$r" tag v0.1.0-rc.1 "$beta4"
promote "$r" TO=rc BASE=0.1.0 && bad "rc: must refuse when an rc exists" || ok

# ----------------------------------------- stable: rc -> vX.Y.Z, filtered assets
git -C "$r" switch -q -c main
git -C "$r" commit -q --allow-empty -m "Merge pull request #9 from org/release/0.1.0"
main_sha="$(git -C "$r" rev-parse HEAD)"
if promote "$r" TO=stable ASSETS='*-production.apk' NOTES='Install {tag}'; then ok; else bad "stable: promote failed"; fi
expect_eq "stable: target is main merge commit" "$(cat "$FAKE_GH/v0.1.0/target" 2>/dev/null)" "$main_sha"
expect_eq "stable: not prerelease" "$(cat "$FAKE_GH/v0.1.0/prerelease" 2>/dev/null)" "false"
expect_eq "stable: only production asset" "$(ls "$FAKE_GH/v0.1.0/assets" 2>/dev/null | tr '\n' ' ')" "app-v0.1.0-production.apk "
grep -q '^Install v0.1.0$' "$FAKE_GH/v0.1.0/body" 2>/dev/null && ok || bad "stable: notes template {tag}"

# stable without any rc -> refuse
FAKE_GH="$(mktemp -d)"
r="$(new_repo)"; commit "$r" "feat: a"; a="$(mktemp -d)"
seed_release "$r" v0.2.0-beta.1 "$(asset "$a" fw-v0.2.0-beta.1-aarch64 B1)"
promote "$r" TO=stable BASE=0.2.0 && bad "stable: must refuse without rc" || ok

# ---------------------------------------------------- integrity: fail closed
FAKE_GH="$(mktemp -d)"
r="$(new_repo)"; commit "$r" "feat: a"; a="$(mktemp -d)"
seed_release "$r" v0.1.0-beta.1 "$(asset "$a" fw-v0.1.0-beta.1-aarch64 GOOD)"
printf 'SWAPPED' >"$FAKE_GH/v0.1.0-beta.1/assets/fw-v0.1.0-beta.1-aarch64"
promote "$r" TO=rc BASE=0.1.0 && bad "integrity: swapped asset must fail" || ok
expect_eq "integrity: no rc release created" "$([ -d "$FAKE_GH/v0.1.0-rc.1" ] && echo yes || echo no)" "no"

FAKE_GH="$(mktemp -d)"
r="$(new_repo)"; commit "$r" "feat: a"; a="$(mktemp -d)"
seed_release "$r" v0.1.0-beta.1 "$(asset "$a" fw-v0.1.0-beta.1-aarch64 X)"
echo "no digests here" >"$FAKE_GH/v0.1.0-beta.1/body"
promote "$r" TO=rc BASE=0.1.0 && bad "integrity: missing digest must fail" || ok

# legacy firmware notes: one unnamed digest, one asset -> accepted
FAKE_GH="$(mktemp -d)"
r="$(new_repo)"; commit "$r" "feat: a"; a="$(mktemp -d)"
seed_release "$r" v0.1.0-beta.27 "$(asset "$a" sst_cam_firmware-v0.1.0-beta.27-aarch64 FW)"
printf 'Beta prerelease for hardware sign-off.\n\nAsset: `x`\nsha256: %s\n' "$(printf FW | sha256sum | cut -d' ' -f1)" \
  >"$FAKE_GH/v0.1.0-beta.27/body"
if promote "$r" TO=rc BASE=v0.1.0; then ok; else bad "legacy: single unnamed digest"; fi
expect_eq "legacy: renamed" "$(ls "$FAKE_GH/v0.1.0-rc.1/assets" 2>/dev/null)" "sst_cam_firmware-v0.1.0-rc.1-aarch64"

# legacy notes but two assets -> ambiguous -> fail closed
FAKE_GH="$(mktemp -d)"
r="$(new_repo)"; commit "$r" "feat: a"; a="$(mktemp -d)"
seed_release "$r" v0.1.0-beta.1 "$(asset "$a" a-v0.1.0-beta.1 A)" "$(asset "$a" b-v0.1.0-beta.1 A)"
printf 'sha256: %s\n' "$(printf A | sha256sum | cut -d' ' -f1)" >"$FAKE_GH/v0.1.0-beta.1/body"
promote "$r" TO=rc BASE=0.1.0 && bad "legacy: ambiguous digest must fail" || ok

# ----------------------------------------------------- no assets (proto shape)
FAKE_GH="$(mktemp -d)"
r="$(new_repo)"; commit "$r" "feat: a"
seed_release "$r" v0.1.0-beta.5
if promote "$r" TO=rc BASE=0.1.0; then ok; else bad "proto: asset-free promotion"; fi
expect_eq "proto: rc.1 created" "$([ -d "$FAKE_GH/v0.1.0-rc.1" ] && echo yes)" "yes"

# ------------------------------------------------------------ input errors
promote "$r" TO=bogus && bad "invalid TO must fail" || ok
promote "$r" TO=rc && bad "rc without base or release branch must fail" || ok

echo
echo "promote: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
