#!/usr/bin/env bash
# Downloads the latest "loadable" wasm32 engine build from a duckdb-wasm fork's own CI
# (haybarn-wasm and official duckdb-wasm both build and publish one under this same
# artifact name) and extracts it, for verify_wasm_load.cjs to load a built extension
# into.
#
#   tools/wasm_verify/fetch_engine.sh <owner/repo> <out-dir>
#
# Always the latest successful run on the repository's own default branch — not a
# pinned run ID, which would go stale once GitHub expires its artifacts (90 days by
# default) and would drift from whichever Emscripten version that fork currently pins.
#
# Needs `gh`, authenticated with at least public-repo read access.
set -euo pipefail

repo="${1:?usage: fetch_engine.sh <owner/repo> <out-dir>}"
out_dir="${2:?usage: fetch_engine.sh <owner/repo> <out-dir>}"

default_branch=$(gh api "repos/$repo" --jq '.default_branch')
run_id=$(gh run list --repo "$repo" --workflow main.yml --branch "$default_branch" --status success --limit 1 --json databaseId --jq '.[0].databaseId')
if [ -z "$run_id" ]; then
  echo "FAILED: no successful main.yml run found on $repo@$default_branch" >&2
  exit 1
fi
echo "Fetching duckdb-wasm-packages-loadable from $repo run $run_id (branch $default_branch)"

mkdir -p "$out_dir"
download_dir=$(mktemp -d)
trap 'rm -rf "$download_dir"' EXIT
gh run download "$run_id" --repo "$repo" -n duckdb-wasm-packages-loadable -D "$download_dir"

# The artifact's own single file entry is itself a zip (confirmed directly, 2026-10-20):
# `gh run download` leaves it as `duckdb-wasm-packages.zip` rather than pre-extracting it.
# Handle that case, but fall back to a plain copy if a future artifact layout changes.
if ls "$download_dir"/*.zip >/dev/null 2>&1; then
  for z in "$download_dir"/*.zip; do unzip -q -o "$z" -d "$out_dir"; done
else
  cp -r "$download_dir"/. "$out_dir"/
fi

echo "Engine extracted to $out_dir/packages/duckdb-wasm"
