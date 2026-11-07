# Release builds

`tools/build_release.sh` creates the installable mod archive and the release
metadata used by the published downloads:

- `rls_career_overhaul_v<version>.zip`
- `rls_career_overhaul_v<version>.zip.manifest.json`
- `v<version>-SHA256SUMS.txt`
- `v<version>-developer-changelog.md` when a changelog is requested

`tools/build_map_zips.sh` does the same for the map mods under `maps/`:

- `rls_career_overhaul_<map>_v<version>.zip`
- `rls_career_overhaul_<map>_v<version>.zip.manifest.json`
- `v<version>-maps-SHA256SUMS.txt`

The scripts need `bash`, `zip`, `git`, and the usual coreutils tools (`find`,
`sed`, `awk`, `sha256sum`). `zipinfo` (from the `zip` package) is used to verify
each archive against its source tree.

## Build

Run from the repository root:

```sh
tools/build_release.sh --version 2.8.1-scf
```

The files are written to `dist/`. To derive the version from a tag:

```sh
tools/build_release.sh --tag v2.8.1-scf --changelog-from-git
```

To include a curated changelog instead of generating one from `git log`:

```sh
tools/build_release.sh --version 2.8.1-scf --changelog path/to/changelog.md
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

## Map archives

The maps under `maps/` ship as their own mod archives, built from the same
version tag:

```sh
tools/build_map_zips.sh --version 2.8.1-scf
tools/build_map_zips.sh --tag v2.8.1-scf --map utah
tools/build_map_zips.sh --list
```

The output layout matches the map ZIPs those folders were extracted from: the
map's own content roots (`gameplay/`, `levels/`, `lua/`, `scripts/`, `ui/`,
`vehicles/`, `challenges/`) sit at the archive root. There is no wrapper folder
and no `mod_info/`, so the archive goes straight into the mods directory. Each
map is verified against its source tree before the manifest is written.

## Bundling the maps into the base archive

`--with-maps` folds the map trees into the release ZIP for builds that must be
a single mod:

```sh
tools/build_release.sh --version 2.8.1-scf --with-maps
tools/build_release.sh --version 2.8.1-scf --with-maps=utah
```

The merge aborts if a map would overwrite a file that is already packaged. The
combined archive is about 3 GB, well past GitHub's 2 GiB per-asset release
limit, and it forces the Utah level re-export plus the Skeleton Coast traffic
definitions on every player, so the published releases keep the maps separate.

## GitHub Actions

`.github/workflows/release.yml` runs both scripts on `v*` tags and on manual
dispatch:

- checks out the Git LFS map assets (roughly 5 GB) and fails early if any of
  them is still a pointer file
- builds `rls_career_overhaul_v<version>.zip` and one archive per map
- uploads everything as a workflow artifact and, for tag builds, publishes the
  same files on the GitHub release

Manual dispatch accepts an optional version and source SHA. The runner frees the
unused SDK directories first because the LFS checkout plus a staged map copy and
the archives do not fit in the default 14 GB of disk.
