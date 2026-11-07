This folder contains the extracted versions of the extra maps that RLS releases for this mod, instead of having separate repos.

From this point forward, the maps will no longer hold their own version tag and instead will share the same version tag as the mod.

## Layout

Each map is a full mod tree, so its content roots (`gameplay/`, `levels/`, `lua/`, `scripts/`, `ui/`, `vehicles/`, `challenges/`) are the archive roots:

```text
maps/rls_career_overhaul_utah/
  challenges/ gameplay/ levels/ ui/ vehicles/
```

The prebuilt ZIPs sitting next to the folders are build output and are ignored by git (`*.zip`).

## Build

```sh
tools/build_map_zips.sh --version 2.8.1-scf
tools/build_map_zips.sh --version 2.8.1-scf --map utah
```

That writes `rls_career_overhaul_<map>_v<version>.zip` plus its manifest to `dist/`, one archive per map, stamped with the mod version. `--out maps` puts them back next to the sources. `--with-maps` on `tools/build_release.sh` folds them into the base archive instead, at the cost of a ~3 GB download.

Releases build these archives automatically: `.github/workflows/release.yml` pulls the LFS assets and publishes the map ZIPs next to the mod ZIP.
