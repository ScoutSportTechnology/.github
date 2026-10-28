#!/usr/bin/env bash
# =============================================================================
# resolve-version.sh — compute the next SemVer tag for the SST release ladder.
#
# Shared by every ScoutSportTechnology repo through the `resolve-version`
# composite action. Pure git: it reads tags and commit subjects, never the API.
#
#   resolve-version.sh alpha             development: next vBASE-alpha.N
#   resolve-version.sh release [X.Y.Z]   release/X.Y.Z: next beta.N, or rc.N once
#                                        the version has entered the rc phase
#   resolve-version.sh beta    [X.Y.Z]   force the next beta.N (legacy / manual)
#   resolve-version.sh rc      [X.Y.Z]   next rc.N (used by the promote action)
#   resolve-version.sh stable  X.Y.Z     the stable tag vX.Y.Z
#
# X.Y.Z may be omitted for release/beta/rc when GITHUB_REF_NAME is release/X.Y.Z.
#
# Ladder (one long-lived branch per row, levels are tags, never branches):
#   development    -> vX.Y.Z-alpha.N   construction
#   release/X.Y.Z  -> vX.Y.Z-beta.N    feature freeze, fixes only
#                  -> vX.Y.Z-rc.N      after the first hardware-validated
#                                      promotion (promote action, to=rc)
#   main           -> vX.Y.Z           promotion of the last rc
#
# Alpha base = max(A, B):
#   A. Conventional-Commit bump from the latest stable tag (v0.0.0 if none):
#        breaking (`type!:`, `type(scope)!:`, BREAKING CHANGE) -> major,
#        but -> minor while the major is 0 (pre-1.0 rule);
#        feat -> minor; fix/perf -> patch; anything else -> no release.
#   B. The "release floor": for the highest X.Y.Z that is an OPEN release, i.e.
#      it has beta/rc tags, no stable tag, and its release/X.Y.Z branch still
#      exists (local or origin): X.(Y+1).0. While a release is open,
#      development builds the NEXT version, so its alphas never sort below
#      the open release's betas. A release branch deleted without shipping
#      (abandoned cut) no longer raises the floor; its prerelease tags stay
#      as history and a later release/X.Y.Z continues their counters.
#      Callers must check out with fetch-depth: 0 so origin branches exist.
#
# Mint gate (alpha): mint only if a releasable commit landed since the nearest
# version tag in HEAD's ancestry. Tags on other branches (e.g. betas on the
# release branch) do not count, so they cannot hide or fake new work.
#
# Overrides (env): IN_VERSION=vX.Y.Z forces the alpha base (skips scan, floor
# and gate); IN_BUMP=major|minor|patch forces the bump level (skips the scan
# and the gate, and is honoured literally: major at 0.x yields 1.0.0).
#
# Output: tag=, released=, level= on stdout and appended to $GITHUB_OUTPUT.
# When released=false the tag is empty; callers must gate on released.
# =============================================================================
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: resolve-version.sh <alpha|release|beta|rc|stable> [X.Y.Z]
  alpha             next alpha (Conventional-Commit bump, release floor)
  release [X.Y.Z]   next beta.N, or rc.N once an rc tag exists for X.Y.Z
  beta    [X.Y.Z]   next beta.N
  rc      [X.Y.Z]   next rc.N
  stable  X.Y.Z     the stable tag vX.Y.Z
X.Y.Z defaults to GITHUB_REF_NAME when it is release/X.Y.Z (not for stable).
env: IN_VERSION=vX.Y.Z (force alpha base), IN_BUMP=major|minor|patch
EOF
}

emit() {
  local tag="$1" released="$2" level="${3:-}"
  echo "tag=${tag}"
  echo "released=${released}"
  echo "level=${level}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "tag=${tag}"; echo "released=${released}"; echo "level=${level}"; } >>"$GITHUB_OUTPUT"
  fi
}

valid_base() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

# Newest-first list of all version tags.
all_tags() { git tag -l 'v*' --sort=-v:refname; }

# Latest bare vX.Y.Z (no prerelease suffix).
latest_stable() {
  all_tags | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true
}

has_stable() { git rev-parse -q --verify "refs/tags/v$1" >/dev/null 2>&1; }

# Highest counter N for v<base>-<rung>.N (0 when none). Only strictly-formed
# counters count, so a hand-cut v<base>-alpha.x cannot break the arithmetic.
max_counter() {
  local base="$1" rung="$2" top
  local re_base="${base//./\\.}"
  top="$(git tag -l "v${base}-${rung}."'*' --sort=-v:refname \
    | grep -E "^v${re_base}-${rung}\.[0-9]+\$" \
    | head -1 || true)"
  [ -z "$top" ] && { echo 0; return; }
  echo "${top##*.}"
}

# Nearest version tag reachable from HEAD (the last mint point on this line).
nearest_tag() {
  git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true
}

range_since() {
  local tag="$1"
  if [ -n "$tag" ] && git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "${tag}..HEAD"
  else
    echo "HEAD"
  fi
}

# Highest Conventional-Commit bump across a git range: major|minor|patch or "".
# Here-strings, not `echo | grep -q`: under pipefail a grep -q early exit
# SIGPIPEs echo and a match on a >64 KB log reads as a failure.
# Breaking accepts `type!:`, `type(scope)!:` and the non-standard
# `type!(scope):`, so a misplaced `!` still counts as breaking.
highest_bump() {
  local range="$1" log
  log="$(git log --format='%s%n%b' "$range" 2>/dev/null || true)"
  if grep -qiE '^BREAKING[ -]CHANGE' <<<"$log" \
    || grep -qE '^[a-z]+(\([^)]*\))?!(\([^)]*\))?:' <<<"$log"; then
    echo major
  elif grep -qE '^feat(\([^)]*\))?:' <<<"$log"; then
    echo minor
  elif grep -qE '^(fix|perf)(\([^)]*\))?:' <<<"$log"; then
    echo patch
  fi
}

apply_bump() { # version bump -> version
  local v="$1" bump="$2" MA MI PA rest
  MA="${v%%.*}"; rest="${v#*.}"; MI="${rest%%.*}"; PA="${rest##*.}"
  case "$bump" in
    major) MA=$((MA + 1)); MI=0; PA=0 ;;
    minor) MI=$((MI + 1)); PA=0 ;;
    patch) PA=$((PA + 1)) ;;
  esac
  echo "${MA}.${MI}.${PA}"
}

# A release/X.Y.Z branch exists locally or on origin.
has_release_branch() {
  git rev-parse -q --verify "refs/heads/release/$1" >/dev/null 2>&1 \
    || git rev-parse -q --verify "refs/remotes/origin/release/$1" >/dev/null 2>&1
}

# Highest open X.Y.Z (beta/rc tags, no stable tag, release branch present)
# -> X.(Y+1).0, else "".
release_floor() {
  local b open="" MA MI rest
  while read -r b; do
    [ -z "$b" ] && continue
    has_stable "$b" && continue
    has_release_branch "$b" && open="$b"
  done < <(git tag -l 'v*' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-(beta|rc)\.[0-9]+$' \
    | sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+)-.*/\1/' \
    | sort -u -V)
  [ -z "$open" ] && return 0
  MA="${open%%.*}"; rest="${open#*.}"; MI="${rest%%.*}"
  echo "${MA}.$((MI + 1)).0"
}

max_version() { printf '%s\n%s\n' "$1" "$2" | sed '/^$/d' | sort -V | tail -1; }

resolve_base_arg() { # mode, arg -> X.Y.Z (from arg or GITHUB_REF_NAME)
  local mode="$1" base="${2:-}"
  if [ -z "$base" ] && [ "$mode" != stable ]; then
    case "${GITHUB_REF_NAME:-}" in release/*) base="${GITHUB_REF_NAME#release/}" ;; esac
  fi
  valid_base "$base" || {
    echo "::error::${mode} needs a valid X.Y.Z base (got '${base:-}'; branch '${GITHUB_REF_NAME:-}')" >&2
    usage; exit 1
  }
  echo "$base"
}

refuse_shipped() {
  if has_stable "$1"; then
    echo "::error::v$1 is already released; a release/$1 branch must not mint more prereleases" >&2
    exit 1
  fi
}

mode="${1:-}"
case "$mode" in
  alpha)
    if [ -n "${IN_VERSION:-}" ]; then
      echo "${IN_VERSION}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        || { echo "::error::invalid IN_VERSION '${IN_VERSION}' (want vX.Y.Z)" >&2; exit 1; }
      base="${IN_VERSION#v}"
    else
      stable="$(latest_stable)"; stable="${stable#v}"; stable="${stable:-0.0.0}"
      bump="${IN_BUMP:-}"
      if [ -n "$bump" ]; then
        case "$bump" in major|minor|patch) ;; *)
          echo "::error::invalid IN_BUMP '$bump' (want major|minor|patch)" >&2; exit 2 ;;
        esac
      else
        bump="$(highest_bump "$(range_since "v${stable}")")"
        [ -z "$bump" ] && { emit "" false alpha; exit 0; }
        # Pre-1.0 rule: a breaking change bumps the minor while major is 0.
        [ "$bump" = major ] && [ "${stable%%.*}" = 0 ] && bump=minor
        # Mint gate: something releasable must be new since the last tag on
        # this line, or a docs/ci push would re-mint forever.
        [ -z "$(highest_bump "$(range_since "$(nearest_tag)")")" ] \
          && { emit "" false alpha; exit 0; }
      fi
      base="$(max_version "$(apply_bump "$stable" "$bump")" "$(release_floor)")"
    fi
    n="$(max_counter "$base" alpha)"
    emit "v${base}-alpha.$((n + 1))" true alpha
    ;;
  release | beta | rc)
    base="$(resolve_base_arg "$mode" "${2:-}")"
    refuse_shipped "$base"
    rung="$mode"
    if [ "$mode" = release ]; then
      rung=beta
      [ "$(max_counter "$base" rc)" -gt 0 ] && rung=rc
    fi
    n="$(max_counter "$base" "$rung")"
    emit "v${base}-${rung}.$((n + 1))" true "$rung"
    ;;
  stable)
    base="$(resolve_base_arg stable "${2:-}")"
    emit "v${base}" true stable
    ;;
  -h | --help)
    usage; exit 0
    ;;
  *)
    echo "::error::unknown mode '${mode:-}'" >&2; usage; exit 2
    ;;
esac
