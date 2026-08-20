#!/usr/bin/env bash
# Pack the plugin (QML + manifest + docs) into the GitHub Release tarball.
#
# Layout mirrors the marketplace convention: the plugin files sit flat at the
# archive root so reviewers can diff the tarball against the tagged tree.
#
# Usage: scripts/package-release.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(jq -r '.version // empty' "$repo_root/manifest.json")"
plugin_id="$(jq -r '.id // empty' "$repo_root/manifest.json")"
[[ -n "$version" && -n "$plugin_id" ]] || {
  echo "package-release: missing id or version in manifest.json" >&2
  exit 1
}

asset="${plugin_id}-${version}.tar.gz"
outdir="$repo_root/dist"

files=(BarWidget.qml Panel.qml manifest.json README.md LICENSE preview.png)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for file in "${files[@]}"; do
  [[ -f "$repo_root/$file" ]] || {
    echo "package-release: missing $file" >&2
    exit 1
  }
  install -Dm644 "$repo_root/$file" "$tmp/$file"
done

mkdir -p "$outdir"
tar -C "$tmp" -czf "$outdir/$asset" "${files[@]}"
echo "packaged: $outdir/$asset"
sha256sum "$outdir/$asset"
