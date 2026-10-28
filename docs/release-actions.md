# Shared release actions

Composite actions used by `sst-cam-proto`, `sst-cam-app` and `sst-cam-firmware`
(and any future repo) to version and publish releases the same way. Each repo
keeps its own check jobs (their names are the required status checks in the
rulesets) and its own build jobs; only the version math, the publishing and the
promotion live here.

| Action | Does |
|---|---|
| `actions/resolve-version` | Computes the next tag from the branch and the existing tags. |
| `actions/publish-release` | Creates the Release (draft → upload assets → publish) and records each asset's SHA-256 in the notes. |
| `actions/promote` | beta → rc.1, or rc → stable. Same bytes, verified against the recorded SHA-256, renamed to the new tag. No rebuild. |

Callers pin an exact tag of this repo: `ScoutSportTechnology/.github/actions/<name>@v1.1.0`.
The actions share scripts through relative paths, so one pinned tag always
gives a consistent set.

## Release ladder

Levels are tags, not branches.

| Branch | Tag | Minted when | Meaning |
|---|---|---|---|
| `development` | `vX.Y.Z-alpha.N` | each merge with a releasable Conventional Commit | construction |
| `release/X.Y.Z` | `vX.Y.Z-beta.N` | each merge, until the first rc | feature freeze, fixes only |
| `release/X.Y.Z` | `vX.Y.Z-rc.N` | `promote` to=rc (rc.1), then each merge | hardware-validated candidate |
| `main` | `vX.Y.Z` | merge `release/X.Y.Z → main` (`promote` to=stable) | shipped |

Version rules (`resolve-version.sh`):

- **Alpha base** = the higher of (a) the Conventional-Commit bump from the
  latest stable tag and (b) the release floor: if `X.Y.Z` is an open release
  (beta/rc tags, no stable tag, and the `release/X.Y.Z` branch still exists),
  development builds `X.(Y+1).0`. Deleting a release branch without shipping
  (an abandoned cut) drops the floor; its prerelease tags stay, and a later
  `release/X.Y.Z` continues their counters.
- **Pre-1.0:** a breaking change bumps the minor while the major is 0
  (`v0.1.0` + `feat!:` → `v0.2.0`). `bump: major` is honoured literally and is
  how `1.0.0` is cut.
- **Breaking** = `type!:`, `type(scope)!:`, the misplaced `type!(scope):`, or a
  `BREAKING CHANGE:` footer.
- **Mint gate:** an alpha is minted only if a `feat`/`fix`/`perf`/breaking
  commit landed since the nearest version tag in the branch's own history.
- **release/X.Y.Z** mints `rc.N` once any `vX.Y.Z-rc.*` exists, else `beta.N`.
  It refuses to mint for a version that already has its stable tag.
- **Stable** requires an rc: only a hardware-validated candidate ships.

## Caller examples

All jobs that use these actions need `actions/checkout@v4` with
`fetch-depth: 0` (tags and history) and `permissions: contents: write`.

### development → alpha

```yaml
  alpha:
    if: ${{ github.event_name != 'pull_request' }}
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: ver
        uses: ScoutSportTechnology/.github/actions/resolve-version@v1.1.0
        with:
          mode: alpha
      # ... build the asset(s) here, only if steps.ver.outputs.released == 'true'
      - if: steps.ver.outputs.released == 'true'
        uses: ScoutSportTechnology/.github/actions/publish-release@v1.1.0
        with:
          tag: ${{ steps.ver.outputs.tag }}
          files: dist/*.apk          # omit for proto (no assets)
```

When the build runs in another job (self-hosted runner, matrix), resolve the
version in a first job, expose `tag`/`released` as job outputs, build in the
next job, then publish in a final job after `actions/download-artifact`.

### release/X.Y.Z → beta or rc

Same as alpha with `mode: release` (the base comes from the branch name).
`steps.ver.outputs.level` is `beta` or `rc` if the build or notes depend on it.

### promote-rc.yml (button today, hardware rig later)

```yaml
name: promote-rc
on:
  workflow_dispatch:
    inputs:
      version:
        description: "X.Y.Z (default: the release/X.Y.Z branch it runs on)"
        required: false
        default: ""
permissions:
  contents: write
concurrency:
  group: promote
  cancel-in-progress: false
jobs:
  promote:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: ScoutSportTechnology/.github/actions/promote@v1.1.0
        with:
          to: rc
          version: ${{ inputs.version }}
```

Run it from the `release/X.Y.Z` branch after the newest beta passed the
hardware test. A hardware-rig job can trigger the same workflow through the
API (`gh workflow run promote-rc.yml --ref release/X.Y.Z`).

### release.yml on main → stable

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      version:
        description: "X.Y.Z to promote (overrides detection)"
        required: false
        default: ""
jobs:
  promote:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: ScoutSportTechnology/.github/actions/promote@v1.1.0
        with:
          to: stable
          version: ${{ inputs.version }}
          assets: "*-production.apk"   # app ships production only; default '*'
          notes: ""                     # e.g. firmware install command, {tag} = new tag
```

## Asset digest contract

`publish-release` writes one line per asset in the Release notes:

```
    sha256: <64 hex>  <asset file name>
```

`promote` downloads each selected asset, recomputes its SHA-256, and fails
closed on a missing or mismatched digest. Legacy notes with a single unnamed
`sha256: <hex>` line are accepted only when exactly one asset is promoted.

## Development

```bash
shellcheck -x actions/*/*.sh
actions/resolve-version/resolve-version-test.sh
actions/promote/promote-test.sh      # uses a fake gh; no network
```

A change ships to callers only when a new tag is cut (`v1.0.1`, `v1.1.0`, ...)
and each caller moves its pin in a PR. Tags are never moved.
