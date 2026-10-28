#!/usr/bin/env bash
# =============================================================================
# Tests for resolve-version.sh. Each case builds a throwaway git repo (real
# commits + tags) so the suite exercises real `git tag --sort=-v:refname` and
# `git describe` behaviour, not a stub.
#
# Run: actions/resolve-version/resolve-version-test.sh   (exit 0 = all pass)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="${SCRIPT_DIR}/resolve-version.sh"
unset GITHUB_OUTPUT GITHUB_REF_NAME IN_VERSION IN_BUMP

pass=0
fail=0

new_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q -b development
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  git -C "$d" config tag.gpgsign false
  echo "$d"
}
commit() { git -C "$1" commit -q --allow-empty -m "$2"; }
tag() { git -C "$1" tag "$2"; }

# run <repo> <mode> [base] -> the `tag=` value
run() { local repo="$1"; shift; ( cd "$repo" && "$RESOLVE" "$@" ) 2>/dev/null | sed -n 's/^tag=//p'; }
run_released() { local repo="$1"; shift; ( cd "$repo" && "$RESOLVE" "$@" ) 2>/dev/null | sed -n 's/^released=//p'; }
run_level() { local repo="$1"; shift; ( cd "$repo" && "$RESOLVE" "$@" ) 2>/dev/null | sed -n 's/^level=//p'; }

expect_eq() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL: %s\n        got:  %s\n        want: %s\n' "$1" "$2" "$3"
  fi
}
expect_fail() { # label, repo, args...
  local label="$1" repo="$2"; shift 2
  if ( cd "$repo" && "$RESOLVE" "$@" ) >/dev/null 2>&1; then
    fail=$((fail + 1)); printf '  FAIL: %s (expected non-zero exit)\n' "$label"
  else
    pass=$((pass + 1))
  fi
}

# ---------------------------------------------------------------- alpha: basics
r="$(new_repo)"; commit "$r" "feat: thing"
expect_eq "alpha no-tags feat -> v0.1.0-alpha.1" "$(run "$r" alpha)" "v0.1.0-alpha.1"
expect_eq "alpha level output" "$(run_level "$r" alpha)" "alpha"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.1; commit "$r" "feat: b"
expect_eq "alpha second feat -> alpha.2" "$(run "$r" alpha)" "v0.1.0-alpha.2"

r="$(new_repo)"; commit "$r" "fix: only"
expect_eq "alpha no-tags fix -> v0.0.1-alpha.1" "$(run "$r" alpha)" "v0.0.1-alpha.1"

r="$(new_repo)"; commit "$r" "feat: base"; tag "$r" v0.1.0; commit "$r" "fix: y"
expect_eq "alpha fix since stable -> v0.1.1-alpha.1" "$(run "$r" alpha)" "v0.1.1-alpha.1"

r="$(new_repo)"; commit "$r" "feat: base"; tag "$r" v0.1.0; commit "$r" "perf: faster"
expect_eq "alpha perf -> v0.1.1-alpha.1" "$(run "$r" alpha)" "v0.1.1-alpha.1"

r="$(new_repo)"; commit "$r" "feat: base"; tag "$r" v0.1.0; commit "$r" "docs: readme"
expect_eq "alpha docs-only released" "$(run_released "$r" alpha)" "false"
expect_eq "alpha docs-only tag empty" "$(run "$r" alpha)" ""

# --------------------------------------------------- alpha: breaking + pre-1.0
r="$(new_repo)"; commit "$r" "feat: base"; tag "$r" v0.1.0; commit "$r" "feat!: drop field"
expect_eq "pre-1.0 breaking -> minor v0.2.0-alpha.1" "$(run "$r" alpha)" "v0.2.0-alpha.1"

r="$(new_repo)"; commit "$r" "feat!: first breaking, no stable"
expect_eq "pre-1.0 breaking, no stable -> v0.1.0-alpha.1" "$(run "$r" alpha)" "v0.1.0-alpha.1"

r="$(new_repo)"; commit "$r" "feat: base"; tag "$r" v0.1.0
git -C "$r" commit -q --allow-empty -m "feat: x" -m "BREAKING CHANGE: wire"
expect_eq "pre-1.0 BREAKING CHANGE body -> v0.2.0-alpha.1" "$(run "$r" alpha)" "v0.2.0-alpha.1"

r="$(new_repo)"; commit "$r" "feat: base"; tag "$r" v1.2.0; commit "$r" "feat(api)!: drop field"
expect_eq "post-1.0 breaking -> major v2.0.0-alpha.1" "$(run "$r" alpha)" "v2.0.0-alpha.1"

r="$(new_repo)"; commit "$r" "feat: base"; tag "$r" v1.2.0; commit "$r" "feat!(ble): misplaced bang"
expect_eq "misplaced bang feat!(scope): still breaking" "$(run "$r" alpha)" "v2.0.0-alpha.1"

r="$(new_repo)"; commit "$r" "feat: base"; tag "$r" v0.1.0; commit "$r" "docs: x"
expect_eq "IN_BUMP=major at 0.x is literal -> v1.0.0-alpha.1" \
  "$(IN_BUMP="major" run "$r" alpha)" "v1.0.0-alpha.1"
expect_eq "IN_BUMP=minor -> v0.2.0-alpha.1" "$(IN_BUMP="minor" run "$r" alpha)" "v0.2.0-alpha.1"
expect_eq "IN_BUMP=patch -> v0.1.1-alpha.1" "$(IN_BUMP="patch" run "$r" alpha)" "v0.1.1-alpha.1"

r="$(new_repo)"; commit "$r" "feat: a"
( cd "$r" && IN_BUMP=hotfix "$RESOLVE" alpha ) >/dev/null 2>&1 \
  && { fail=$((fail + 1)); echo "  FAIL: IN_BUMP=hotfix accepted"; } || pass=$((pass + 1))

# ------------------------------------------------------------- alpha: overrides
r="$(new_repo)"; commit "$r" "docs: nothing releasable"
expect_eq "IN_VERSION seed -> v0.1.0-alpha.1" "$(IN_VERSION=v0.1.0 run "$r" alpha)" "v0.1.0-alpha.1"

r="$(new_repo)"; commit "$r" "feat: a"
expect_eq "IN_VERSION beats IN_BUMP" "$(IN_VERSION=v0.2.0 IN_BUMP="major" run "$r" alpha)" "v0.2.0-alpha.1"
( cd "$r" && IN_VERSION=0.1.0 "$RESOLVE" alpha ) >/dev/null 2>&1 \
  && { fail=$((fail + 1)); echo "  FAIL: malformed IN_VERSION accepted"; } || pass=$((pass + 1))

# ------------------------------------------------------------- alpha: counters
r="$(new_repo)"; commit "$r" "feat: a"
for n in 1 2 9 10; do tag "$r" "v0.1.0-alpha.$n"; done
commit "$r" "feat: more"
expect_eq "numeric precedence -> alpha.11" "$(run "$r" alpha)" "v0.1.0-alpha.11"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.2; tag "$r" v0.1.0-alpha.x
commit "$r" "feat: b"
expect_eq "ignores non-numeric .x counter -> alpha.3" "$(run "$r" alpha)" "v0.1.0-alpha.3"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.9; tag "$r" v0.1.0-alpha.10.2
commit "$r" "feat: b"
expect_eq "ignores multi-dot alpha.10.2 -> alpha.10" "$(run "$r" alpha)" "v0.1.0-alpha.10"

# ------------------------------------------------------------ alpha: mint gate
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.1
expect_eq "gate: nothing new -> released=false" "$(run_released "$r" alpha)" "false"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.1; commit "$r" "docs: x"
expect_eq "gate: docs-only since alpha (pre-stable) -> false" "$(run_released "$r" alpha)" "false"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.1; commit "$r" "feat: b"
expect_eq "gate: feat since alpha -> true" "$(run_released "$r" alpha)" "true"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.1; commit "$r" "docs: x"
expect_eq "gate: IN_VERSION bypasses" "$(IN_VERSION=v0.2.0 run "$r" alpha)" "v0.2.0-alpha.1"

# A tag on another branch must not count as this line's last mint point.
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.1
git -C "$r" switch -q -c side; commit "$r" "fix: side"; tag "$r" v9.9.9-alpha.1
git -C "$r" switch -q development; commit "$r" "docs: only docs here"
expect_eq "gate: foreign-branch tag ignored -> false" "$(run_released "$r" alpha)" "false"

r="$(new_repo)"
big="$(head -c 70000 </dev/zero | tr '\0' x)"
git -C "$r" commit -q --allow-empty -m "chore: bulky old commit" -m "$big"
commit "$r" "feat: recent"
expect_eq "large-log SIGPIPE regression -> true" "$(run_released "$r" alpha)" "true"

# ---------------------------------------------------------- alpha: release floor
# release/0.1.0 is open (betas, no stable): development builds 0.2.0.
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.3
git -C "$r" switch -q -c release/0.1.0; tag "$r" v0.1.0-beta.1; commit "$r" "fix: rb"; tag "$r" v0.1.0-beta.2
git -C "$r" switch -q development; commit "$r" "feat: next"
expect_eq "floor: open 0.1.0 -> v0.2.0-alpha.1" "$(run "$r" alpha)" "v0.2.0-alpha.1"

# rc tags also mark the release as open.
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-rc.1; commit "$r" "fix: b"
expect_eq "floor: rc-only open release -> v0.2.0-alpha.1" "$(run "$r" alpha)" "v0.2.0-alpha.1"

# Once v0.1.0 ships, the floor disappears and the bump is from stable.
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-beta.1; tag "$r" v0.1.0-rc.1; tag "$r" v0.1.0
commit "$r" "fix: z"
expect_eq "floor: shipped release ignored -> v0.1.1-alpha.1" "$(run "$r" alpha)" "v0.1.1-alpha.1"

# A bigger Conventional-Commit bump wins over the floor.
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v1.0.0; commit "$r" "feat: b"; tag "$r" v1.1.0-beta.1
commit "$r" "feat!: big"
expect_eq "floor: major bump beats floor -> v2.0.0-alpha.1" "$(run "$r" alpha)" "v2.0.0-alpha.1"

# The floor follows the highest open release.
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v1.0.0; tag "$r" v1.1.0-beta.4; tag "$r" v1.2.0-beta.1
commit "$r" "fix: c"
expect_eq "floor: two open releases -> v1.3.0-alpha.1" "$(run "$r" alpha)" "v1.3.0-alpha.1"

# Existing alphas of the floor base continue their counter.
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-beta.1; tag "$r" v0.2.0-alpha.4; commit "$r" "feat: b"
expect_eq "floor: continues alpha counter -> v0.2.0-alpha.5" "$(run "$r" alpha)" "v0.2.0-alpha.5"

# ------------------------------------------------------------------ release mode
r="$(new_repo)"; commit "$r" "feat: a"
expect_eq "release first -> beta.1" "$(run "$r" release 0.1.0)" "v0.1.0-beta.1"
expect_eq "release level beta" "$(run_level "$r" release 0.1.0)" "beta"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-beta.27
expect_eq "release continues beta -> beta.28" "$(run "$r" release 0.1.0)" "v0.1.0-beta.28"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-beta.5; tag "$r" v0.1.0-rc.1
expect_eq "release in rc phase -> rc.2" "$(run "$r" release 0.1.0)" "v0.1.0-rc.2"
expect_eq "release level rc" "$(run_level "$r" release 0.1.0)" "rc"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.2.0-rc.3
expect_eq "rc phase is per base -> v0.1.0-beta.1" "$(run "$r" release 0.1.0)" "v0.1.0-beta.1"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-beta.2
expect_eq "release from GITHUB_REF_NAME" "$(cd "$r" && GITHUB_REF_NAME=release/0.1.0 "$RESOLVE" release | sed -n 's/^tag=//p')" "v0.1.0-beta.3"
expect_fail "release on non-release branch without base" "$r" release

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-rc.2; tag "$r" v0.1.0
expect_fail "release refuses an already shipped version" "$r" release 0.1.0
expect_fail "rc refuses an already shipped version" "$r" rc 0.1.0

# --------------------------------------------------------------- beta / rc mode
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-beta.1
expect_eq "beta second -> beta.2" "$(run "$r" beta 0.1.0)" "v0.1.0-beta.2"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-alpha.5
expect_eq "beta ignores alpha counter" "$(run "$r" beta 0.1.0)" "v0.1.0-beta.1"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.2.0-beta.3
expect_eq "beta ignores other base" "$(run "$r" beta 0.1.0)" "v0.1.0-beta.1"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-beta.4; tag "$r" v0.1.0-beta.x
expect_eq "beta ignores malformed counter" "$(run "$r" beta 0.1.0)" "v0.1.0-beta.5"

r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-beta.9
expect_eq "rc first -> rc.1" "$(run "$r" rc 0.1.0)" "v0.1.0-rc.1"
tag "$r" v0.1.0-rc.1
expect_eq "rc second -> rc.2" "$(run "$r" rc 0.1.0)" "v0.1.0-rc.2"

expect_fail "beta malformed base" "$r" beta "release/0.1.0"

# ------------------------------------------------------------------ stable mode
r="$(new_repo)"; commit "$r" "feat: a"; tag "$r" v0.1.0-rc.2
expect_eq "stable -> v0.1.0" "$(run "$r" stable 0.1.0)" "v0.1.0"
expect_eq "stable level" "$(run_level "$r" stable 0.1.0)" "stable"
expect_fail "stable missing base" "$r" stable
( cd "$r" && GITHUB_REF_NAME=release/0.1.0 "$RESOLVE" stable ) >/dev/null 2>&1 \
  && { fail=$((fail + 1)); echo "  FAIL: stable used GITHUB_REF_NAME"; } || pass=$((pass + 1))

# --------------------------------------------------------------------- outputs
r="$(new_repo)"; commit "$r" "feat: a"
expect_eq "alpha released=true" "$(run_released "$r" alpha)" "true"
expect_eq "release released=true" "$(run_released "$r" release 0.1.0)" "true"
gho="$(mktemp)"
( cd "$r" && GITHUB_OUTPUT="$gho" "$RESOLVE" alpha ) >/dev/null
if grep -qx 'tag=v0.1.0-alpha.1' "$gho" && grep -qx 'released=true' "$gho" && grep -qx 'level=alpha' "$gho"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf '  FAIL: GITHUB_OUTPUT keys not written\n'
fi
expect_fail "invalid mode" "$r" bogus

echo
echo "resolve-version: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
