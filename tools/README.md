# Release builds

`tools/build_release.sh` creates the installable mod archive and the release
metadata used by the published downloads:

- `rls_career_overhaul_v<version>.zip`
- `rls_career_overhaul_v<version>.zip.manifest.json`
- `v<version>-SHA256SUMS.txt`
- `v<version>-developer-changelog.md` when a changelog is requested

The script needs `bash`, `zip`, `git`, and the usual coreutils tools (`find`,
`sed`, `awk`, `sha256sum`).

## Build

Run from the repository root:

```sh
tools/build_release.sh --version 2.8.0
```

The files are written to `dist/`. To derive the version from a tag:

```sh
tools/build_release.sh --tag v2.8.0 --changelog-from-git
```

To include a curated changelog instead of generating one from `git log`:

```sh
tools/build_release.sh --version 2.8.0 --changelog path/to/changelog.md
```

`--source` and `--out` select another checkout and output directory. Without
`--version` or `--tag`, the script reads `gameplay/overhaul/version.json`.

## What goes into the ZIP

Only the mod content is packaged:

```text
art/ gameplay/ levels/ locales/ lua/ music/ scripts/ settings/ ui/ vehicles/
licenses/tyre-thermals-AGPL-3.0.txt
licenses/tyre-thermals-NOTICE.md
```

Repository documentation, `.github`, `tools`, editor state, caches and build
output are left out. Manual coordinate dumps directly under `levels/` (for
example `S10_CDR.csv`) are also excluded; real level content lives in a level
directory.

The script stamps `gameplay/overhaul/version.json` with the requested version
and source commit. File timestamps are fixed so two builds of the same tree
have the same structure. The exact ZIP hash can still change between `zip`
versions because compression output is not guaranteed across tools.

## GitHub Actions

`.github/workflows/release.yml` runs this script on `v*` tags and on manual
dispatch. It uploads the artifacts and, for tag builds, publishes them as a
GitHub release. Manual dispatch accepts an optional version and source SHA.
