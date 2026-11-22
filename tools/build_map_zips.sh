#!/usr/bin/env bash
# RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
# Copyright (C) RLS Modding
# SPDX-License-Identifier: AGPL-3.0-only
#
# Build the installable ZIP for the map mods that live under maps/.
#
# The archives are laid out like the map zips that ship next to the mod: the
# map's own content roots (gameplay/, levels/, lua/, scripts/, ui/, vehicles/,
# challenges/) sit at the archive root. There is no wrapper folder and no
# mod_info/ entry, so the archive can be dropped into the mods directory as-is.
#
# Example:
#   tools/build_map_zips.sh --version 2.8.2-scf
#   tools/build_map_zips.sh --version 2.8.2-scf --map utah
#   tools/build_map_zips.sh --tag v2.8.2-scf --out maps

set -euo pipefail

PACKAGE="rls_career_overhaul"
MAPS_DIR="maps"
VERSION_FILE="gameplay/overhaul/version.json"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE="$(cd -- "$SCRIPT_DIR/.." && pwd)"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Build one ZIP per map mod found under ${MAPS_DIR}/, plus its release metadata.

Options:
  --source PATH        repository root (default: ${DEFAULT_SOURCE})
  --out PATH           output directory (default: <source>/dist)
  --version VERSION    version to stamp into the file names, with or without a leading v
  --tag TAG            release tag to derive the version from, e.g. v2.8.2-scf
  --source-sha SHA     commit SHA to record (default: git HEAD)
  --map NAME           build only this map (repeatable); accepts the folder name
                       (${PACKAGE}_utah) or the short name (utah)
  --list               list the map mods that would be built, then exit
  -h, --help           show this help
EOF
}

source="$DEFAULT_SOURCE"
out=""
version_arg=""
tag_arg=""
source_sha_arg=""
requested_maps=()
list_only=0

while (( $# > 0 )); do
  case "$1" in
    --source)
      source="${2:?--source needs a value}"
      shift 2
      ;;
    --out)
      out="${2:?--out needs a value}"
      shift 2
      ;;
    --version)
      version_arg="${2:?--version needs a value}"
      shift 2
      ;;
    --tag)
      tag_arg="${2:?--tag needs a value}"
      shift 2
      ;;
    --source-sha)
      source_sha_arg="${2:?--source-sha needs a value}"
      shift 2
      ;;
    --map)
      requested_maps+=("${2:?--map needs a value}")
      shift 2
      ;;
    --list)
      list_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

[[ -d "$source" ]] || die "source directory not found: $source"
source="$(cd -- "$source" && pwd)"
maps_root="$source/$MAPS_DIR"
[[ -d "$maps_root" ]] || die "no map sources found: $maps_root"

# A map mod is a directory under maps/ named after the package and holding a
# levels/ tree; the prebuilt ZIPs that sit next to them are ignored.
discover_maps() {
  local dir name
  for dir in "$maps_root"/*; do
    [[ -d "$dir" ]] || continue
    name="$(basename -- "$dir")"
    [[ "$name" == "${PACKAGE}_"* ]] || continue
    if [[ ! -d "$dir/levels" ]]; then
      warn "skipping $name: no levels/ directory" >&2
      continue
    fi
    printf '%s\n' "$name"
  done | LC_ALL=C sort
}

map_dirs=()
while IFS= read -r name; do
  if [[ -n "$name" ]]; then
    map_dirs+=("$name")
  fi
done < <(discover_maps)
(( ${#map_dirs[@]} > 0 )) || die "no map mods found under $maps_root"

if (( ${#requested_maps[@]} > 0 )); then
  selected=()
  for want in "${requested_maps[@]}"; do
    match=""
    for name in "${map_dirs[@]}"; do
      if [[ "$name" == "$want" || "$name" == "${PACKAGE}_${want}" ]]; then
        match="$name"
        break
      fi
    done
    [[ -n "$match" ]] || die "unknown map '$want' (see --list)"
    already=0
    for name in "${selected[@]:-}"; do
      if [[ "$name" == "$match" ]]; then
        already=1
      fi
    done
    (( already )) || selected+=("$match")
  done
  map_dirs=("${selected[@]}")
fi

if (( list_only )); then
  for name in "${map_dirs[@]}"; do
    short="${name#${PACKAGE}_}"
    files="$(find "$maps_root/$name" -type f | wc -l | tr -d ' ')"
    raw="$(find "$maps_root/$name" -type f -printf '%s\n' | awk '{ total += $1 } END { print total + 0 }')"
    printf '%-24s %6s files  %10s bytes  (%s)\n' "$short" "$files" "$raw" "$name"
  done
  exit 0
fi

if [[ -z "$out" ]]; then
  out="$source/dist"
fi
mkdir -p "$out"
out="$(cd -- "$out" && pwd)"

command -v zip >/dev/null 2>&1 || die "zip is required"

if [[ -n "$version_arg" ]]; then
  version="$version_arg"
elif [[ -n "$tag_arg" ]]; then
  version="$tag_arg"
else
  [[ -f "$source/$VERSION_FILE" ]] || die "$VERSION_FILE not found; pass --version or --tag"
  version="$(sed -n 's/.*"version_string"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$source/$VERSION_FILE" | head -n 1)"
fi

version="${version#v}"
version="${version#V}"
if [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  die "version may only contain letters, digits, dots, underscores, plus signs and hyphens: '$version'"
fi

if [[ -n "$source_sha_arg" ]]; then
  source_sha="$source_sha_arg"
else
  source_sha="$(git -C "$source" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ -z "$source_sha" ]]; then
  warn "source is not a git checkout and --source-sha was not given; using source_sha=unknown"
  source_sha="unknown"
fi
if [[ ! "$source_sha" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  die "source SHA contains unsupported characters: '$source_sha'"
fi
if git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git -C "$source" status --porcelain)" ]]; then
    warn "source has uncommitted or untracked changes; manifest still records HEAD as source_sha"
  fi
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rls-maps-build.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

sums_name="v${version}-maps-SHA256SUMS.txt"
sums_path="$out/$sums_name"
rm -f "$sums_path"
artifacts=()

printf 'Building %d map archive(s) for version %s\n' "${#map_dirs[@]}" "$version"

for name in "${map_dirs[@]}"; do
  short="${name#${PACKAGE}_}"
  src_dir="$maps_root/$name"
  stage="$tmp/stage-$short"
  mkdir -p "$stage"
  cp -a "$src_dir/." "$stage/"

  # Same development-file pruning as tools/build_release.sh. Map content names
  # such as *.forest4.json.for_bak are content, not editor backups, and stay.
  find "$stage" -type d \( \
    -name .git -o -name .hg -o -name .svn -o \
    -name .idea -o -name .vscode -o \
    -name __pycache__ -o -name .pytest_cache -o \
    -name .mypy_cache -o -name .ruff_cache -o \
    -name node_modules -o -name dist -o -name build \
    \) -prune -exec rm -rf {} + 2>/dev/null || true

  find "$stage" -type f \( \
    -name '*.bak' -o -name '*.orig' -o -name '*.pyc' -o -name '*.pyo' -o \
    -name '*.rej' -o -name '*.swp' -o -name '*.swo' -o -name '*.tmp' -o \
    -name '*.log' -o -name '*~' -o -name .DS_Store -o -name Thumbs.db -o \
    -name desktop.ini \
    \) -delete 2>/dev/null || true

  # Keep timestamps stable so identical trees produce comparable archives.
  find "$stage" -exec touch -t 198001010000 {} + 2>/dev/null || true

  # A Git LFS pointer means the real asset was never fetched; packaging it would
  # ship a broken map, so refuse instead.
  pointer_hits="$(find "$stage" -type f -size -2k -print0 \
    | xargs -0 grep -l -m1 'git-lfs.github.com/spec/v1' 2>/dev/null | head -n 5 || true)"
  if [[ -n "$pointer_hits" ]]; then
    die "map $short contains Git LFS pointers (run 'git lfs pull' first): $(printf '%s' "$pointer_hits" | tr '\n' ' ')"
  fi

  zip_name="${PACKAGE}_${short}_v${version}.zip"
  manifest_name="${zip_name}.manifest.json"
  zip_path="$out/$zip_name"
  manifest_path="$out/$manifest_name"
  rm -f "$zip_path" "$manifest_path"

  file_list="$tmp/files-$short"
  ( cd "$stage" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort > "$file_list" )
  file_count="$(wc -l < "$file_list" | tr -d ' ')"
  (( file_count > 0 )) || die "no files found for map $short"
  raw_bytes="$(cd "$stage" && find . -type f -printf '%s\n' | awk '{ total += $1 } END { print total + 0 }')"
  roots="$(cut -d/ -f1 "$file_list" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
  roots_json="[$(cut -d/ -f1 "$file_list" | LC_ALL=C sort -u | sed 's/.*/"&"/' | paste -sd, -)]"

  ( cd "$stage" && zip -q -9 -X "$zip_path" -@ < "$file_list" )
  [[ -f "$zip_path" ]] || die "ZIP for $short was not created"
  zip -T "$zip_path" >/dev/null

  # The archive must hold exactly the staged tree, at the archive root.
  if command -v zipinfo >/dev/null 2>&1; then
    zipinfo -1 "$zip_path" | LC_ALL=C sort > "$tmp/ziplist-$short"
    if ! cmp -s "$file_list" "$tmp/ziplist-$short"; then
      die "archive for $short does not match its source tree"
    fi
    if grep -q "^${name}/" "$tmp/ziplist-$short"; then
      die "archive for $short has a wrapper folder"
    fi
  else
    warn "zipinfo not found; skipping the archive/source comparison for $short"
  fi

  zip_bytes="$(wc -c < "$zip_path" | tr -d ' ')"
  zip_sha="$(sha256sum "$zip_path" | awk '{ print $1 }')"
  mib=$(( zip_bytes / 1024 / 1024 ))
  if (( mib <= 500 )); then
    size_tier="ok"
  elif (( mib <= 1024 )); then
    size_tier="warn"
  else
    size_tier="large"
  fi

  cat > "$manifest_path" <<EOF
{
  "package": "$PACKAGE",
  "map": "$short",
  "version": "$version",
  "source_sha": "$source_sha",
  "zip": "$zip_name",
  "roots": $roots_json,
  "files": $file_count,
  "raw_bytes": $raw_bytes,
  "bytes": $zip_bytes,
  "sha256": "$zip_sha",
  "size_tier": "$size_tier",
  "compression": "zlib"
}
EOF

  artifacts+=("$zip_name" "$manifest_name")
  printf '\nBuilt %s\n' "$zip_path"
  printf '  map:       %s\n' "$short"
  printf '  roots:     %s\n' "$roots"
  printf '  files:     %s\n' "$file_count"
  printf '  raw:       %s bytes\n' "$raw_bytes"
  printf '  archive:   %s bytes\n' "$zip_bytes"
  printf '  sha256:    %s\n' "$zip_sha"
  printf '  manifest:  %s\n' "$manifest_path"
  if (( zip_bytes > 2147483648 )); then
    warn "$zip_name is larger than GitHub's 2 GiB release asset limit"
  fi

  # Free the staged copy as soon as the archive and manifest exist; CI runners
  # build the maps back to back on a small disk.
  rm -rf "$stage"
done

( cd "$out" && sha256sum "${artifacts[@]}" > "$sums_name" )
printf '\nSums: %s\n' "$sums_path"
