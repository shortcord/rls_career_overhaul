#!/usr/bin/env bash
# RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
# Copyright (C) RLS Modding
# SPDX-License-Identifier: AGPL-3.0-only
#
# Build the installable RLS Career Overhaul release ZIP.
#
# The archive contains only the files BeamNG needs. Documentation, CI
# configuration, tooling and other development-only material stays out.
#
# Example:
#   tools/build_release.sh --version 2.8.1-scf
#   tools/build_release.sh --tag v2.8.1-scf --changelog-from-git

set -euo pipefail

PACKAGE="rls_career_overhaul"
VERSION_FILE="gameplay/overhaul/version.json"
CONTENT_DIRS=(art gameplay levels locales lua music scripts settings ui vehicles)
EXTRA_FILES=(
  "licenses/tyre-thermals-AGPL-3.0.txt"
  "licenses/tyre-thermals-NOTICE.md"
)
MAPS_DIR="maps"

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

Build the RLS Career Overhaul release ZIP and its metadata.

Options:
  --source PATH        repository root to package (default: ${DEFAULT_SOURCE})
  --out PATH           output directory (default: <source>/dist)
  --version VERSION    version to stamp, with or without a leading v
  --tag TAG            release tag to derive the version from, e.g. v2.8.1-scf
  --source-sha SHA     commit SHA to record (default: git HEAD)
  --changelog PATH     existing developer changelog to bundle
  --changelog-from-git generate a developer changelog from git log
  --previous-tag TAG   tag to diff against when generating a changelog
  --with-maps[=LIST]   also package the map mods under maps/ into the same ZIP
                       (bare flag = every map; LIST = comma-separated short names)
  -h, --help           show this help
EOF
}

source="$DEFAULT_SOURCE"
out=""
version_arg=""
tag_arg=""
source_sha_arg=""
changelog_arg=""
changelog_from_git=0
previous_tag=""
bundle_all_maps=0
bundle_map_list=""

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
    --changelog)
      changelog_arg="${2:?--changelog needs a value}"
      shift 2
      ;;
    --changelog-from-git)
      changelog_from_git=1
      shift
      ;;
    --previous-tag)
      previous_tag="${2:?--previous-tag needs a value}"
      shift 2
      ;;
    --with-maps)
      bundle_all_maps=1
      shift
      ;;
    --with-maps=*)
      bundle_map_list="${1#--with-maps=}"
      [[ -n "$bundle_map_list" ]] || die "--with-maps= needs a comma-separated map list"
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

if [[ -z "$out" ]]; then
  out="$source/dist"
fi
mkdir -p "$out"
out="$(cd -- "$out" && pwd)"

if (( changelog_from_git )) && [[ -n "$changelog_arg" ]]; then
  die "use either --changelog or --changelog-from-git, not both"
fi
if (( changelog_from_git )); then
  git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "--changelog-from-git requires a git checkout"
fi
if [[ -n "$changelog_arg" ]]; then
  [[ -f "$changelog_arg" ]] || die "changelog not found: $changelog_arg"
fi

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

for rel in "${EXTRA_FILES[@]}"; do
  [[ -f "$source/$rel" ]] || die "required bundled license is missing: $rel"
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rls-build.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
staging="$tmp/stage"
mkdir -p "$staging"

for dir in "${CONTENT_DIRS[@]}"; do
  if [[ -d "$source/$dir" ]]; then
    cp -a "$source/$dir" "$staging/"
  fi
done

for rel in "${EXTRA_FILES[@]}"; do
  mkdir -p "$(dirname -- "$staging/$rel")"
  cp -p "$source/$rel" "$staging/$rel"
done

# Optional: fold the map mods under maps/ into the same archive. Maps normally
# ship as their own ZIPs (tools/build_map_zips.sh) because the combined download
# is several gigabytes; this is for builds that must be a single mod.
bundle_maps=()
if (( bundle_all_maps )) || [[ -n "$bundle_map_list" ]]; then
  maps_root="$source/$MAPS_DIR"
  [[ -d "$maps_root" ]] || die "--with-maps requires $maps_root"

  available_maps=()
  for dir in "$maps_root"/*; do
    [[ -d "$dir" ]] || continue
    name="$(basename -- "$dir")"
    [[ "$name" == "${PACKAGE}_"* ]] || continue
    [[ -d "$dir/levels" ]] || continue
    available_maps+=("$name")
  done
  (( ${#available_maps[@]} > 0 )) || die "no map mods found under $maps_root"

  if (( bundle_all_maps )); then
    bundle_maps=("${available_maps[@]}")
  else
    IFS=',' read -r -a wanted_maps <<< "$bundle_map_list"
    for want in "${wanted_maps[@]}"; do
      [[ -n "$want" ]] || continue
      match=""
      for name in "${available_maps[@]}"; do
        if [[ "$name" == "$want" || "$name" == "${PACKAGE}_${want}" ]]; then
          match="$name"
          break
        fi
      done
      [[ -n "$match" ]] || die "unknown map '$want' for --with-maps"
      duplicate=0
      if (( ${#bundle_maps[@]} > 0 )); then
        for name in "${bundle_maps[@]}"; do
          if [[ "$name" == "$match" ]]; then
            duplicate=1
          fi
        done
      fi
      (( duplicate )) || bundle_maps+=("$match")
    done
  fi

  # A map must only add files; a clash would silently replace mod content.
  staged_list="$tmp/staged-files"
  ( cd "$staging" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort > "$staged_list" )
  for name in "${bundle_maps[@]}"; do
    map_list="$tmp/map-files-$name"
    ( cd "$maps_root/$name" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort > "$map_list" )
    collisions="$(LC_ALL=C comm -12 "$staged_list" "$map_list" || true)"
    if [[ -n "$collisions" ]]; then
      die "map $name would overwrite packaged files: $(printf '%s' "$collisions" | tr '\n' ' ')"
    fi
    cp -a "$maps_root/$name/." "$staging/"
    ( cd "$staging" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort > "$staged_list" )
  done
fi

# Remove development files that may live inside a content directory.
find "$staging" -type d \( \
  -name .git -o -name .hg -o -name .svn -o \
  -name .idea -o -name .vscode -o \
  -name __pycache__ -o -name .pytest_cache -o \
  -name .mypy_cache -o -name .ruff_cache -o \
  -name node_modules -o -name dist -o -name build \
  \) -prune -exec rm -rf {} + 2>/dev/null || true

find "$staging" -type f \( \
  -name '*.bak' -o -name '*.orig' -o -name '*.pyc' -o -name '*.pyo' -o \
  -name '*.rej' -o -name '*.swp' -o -name '*.swo' -o -name '*.tmp' -o \
  -name '*.log' -o -name '*~' -o -name .DS_Store -o -name Thumbs.db -o \
  -name desktop.ini \
  \) -delete 2>/dev/null || true

# Manual coordinate dumps live directly under levels/ during development.
if [[ -d "$staging/levels" ]]; then
  find "$staging/levels" -maxdepth 1 -type f -name '*.csv' -delete 2>/dev/null || true
fi

mkdir -p "$staging/$(dirname -- "$VERSION_FILE")"
cat > "$staging/$VERSION_FILE" <<EOF
{
  "version_string": "$version",
  "source_sha": "$source_sha"
}
EOF

# Keep timestamps stable so identical trees produce comparable archives.
find "$staging" -exec touch -t 198001010000 {} + 2>/dev/null || true

zip_name="${PACKAGE}_v${version}.zip"
manifest_name="${zip_name}.manifest.json"
sums_name="v${version}-SHA256SUMS.txt"
changelog_name="v${version}-developer-changelog.md"
zip_path="$out/$zip_name"
manifest_path="$out/$manifest_name"
sums_path="$out/$sums_name"
changelog_path="$out/$changelog_name"

rm -f "$zip_path" "$manifest_path" "$sums_path" "$changelog_path"

file_list="$tmp/files"
( cd "$staging" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort > "$file_list" )
file_count="$(wc -l < "$file_list" | tr -d ' ')"
(( file_count > 0 )) || die "no release files found"
raw_bytes="$(cd "$staging" && find . -type f -printf '%s\n' | awk '{ total += $1 } END { print total + 0 }')"

( cd "$staging" && zip -q -9 -X "$zip_path" -@ < "$file_list" )
[[ -f "$zip_path" ]] || die "ZIP file was not created"
zip -T "$zip_path" >/dev/null

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

maps_json="[]"
if (( ${#bundle_maps[@]} > 0 )); then
  maps_json="["
  for name in "${bundle_maps[@]}"; do
    maps_json+="\"${name#${PACKAGE}_}\","
  done
  maps_json="${maps_json%,}]"
fi

cat > "$manifest_path" <<EOF
{
  "package": "$PACKAGE",
  "maps": $maps_json,
  "source_sha": "$source_sha",
  "version": "$version",
  "zip": "$zip_name",
  "files": $file_count,
  "raw_bytes": $raw_bytes,
  "bytes": $zip_bytes,
  "sha256": "$zip_sha",
  "size_tier": "$size_tier",
  "compression": "zlib"
}
EOF

changelog_created=0
if (( changelog_from_git )); then
  if [[ -z "$previous_tag" ]]; then
    previous_tag="$(git -C "$source" describe --tags --abbrev=0 --exclude "v$version" HEAD 2>/dev/null || true)"
  fi

  if [[ -n "$previous_tag" ]]; then
    revision_range="$previous_tag..HEAD"
    intro="Changes since $previous_tag."
  else
    revision_range="HEAD"
    intro="Changes in this release."
  fi

  log="$(git -C "$source" log --no-merges --reverse --pretty=format:'- %s (%h)' "$revision_range")"
  if [[ -z "$log" ]]; then
    log="- No changes recorded."
  fi

  {
    echo "# RLS Career Overhaul v$version Developer Changelog"
    echo
    echo "$intro"
    echo
    echo "$log"
  } > "$changelog_path"
  changelog_created=1
elif [[ -n "$changelog_arg" ]]; then
  cp -p "$changelog_arg" "$changelog_path"
  changelog_created=1
fi

artifacts=("$zip_name" "$manifest_name")
if (( changelog_created )); then
  artifacts+=("$changelog_name")
fi
( cd "$out" && sha256sum "${artifacts[@]}" > "$sums_name" )

echo "Built $zip_path"
echo "  version:   $version"
echo "  source:    $source_sha"
echo "  files:     $file_count"
echo "  raw:       $raw_bytes bytes"
echo "  archive:   $zip_bytes bytes"
echo "  sha256:    $zip_sha"
echo "  manifest:  $manifest_path"
echo "  sums:      $sums_path"
if (( ${#bundle_maps[@]} > 0 )); then
  echo "  maps:      ${bundle_maps[*]}"
fi
if (( zip_bytes > 2147483648 )); then
  warn "$zip_name is larger than GitHub's 2 GiB release asset limit; ship the maps as separate ZIPs instead"
fi
if (( changelog_created )); then
  echo "  changelog: $changelog_path"
fi
