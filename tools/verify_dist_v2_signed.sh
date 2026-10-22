#!/usr/bin/env bash
# Installs the SIGNED v2 extensions from a `dist/signed` tree via `CREATE EXTENSION REPOSITORY ...
# USING PUBLIC KEY` + `LOAD ... FROM <repo>`, with NO -unsigned — the self-hosted signed-repository
# path confirmed end to end in docs/rationale/0004_extension-distribution-and-signing.md. Compare
# verify_dist_v2.sh, which uses -unsigned and a bare LOAD against the unsigned tree instead; a bare
# LOAD never trusts a user repository's key, so that script and this one are not interchangeable.
#
#   tools/verify_dist_v2_signed.sh <duckdb-cli> <public-key.pem> [dist-signed-dir]
#
# dist-signed-dir defaults to ./dist/signed. The CLI must be the DuckDB version the tree was built
# for (dist/signed/<version>/<platform>/). Run `zig build dist-v2-signed -Dsigning-key=<path>`
# first. An empty HOME keeps the CLI's own extension directory and repository pins out of it.
set -euo pipefail

cli=$(realpath "${1:?usage: verify_dist_v2_signed.sh <duckdb-cli> <public-key.pem> [dist-signed-dir]}")
pubkey_path=$(realpath "${2:?usage: verify_dist_v2_signed.sh <duckdb-cli> <public-key.pem> [dist-signed-dir]}")
dist=$(realpath "${3:-dist/signed}")
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

run() { HOME="$home" "$cli" -no-init -list -noheader "$@"; }

version=$(run -c "SELECT version()" | tail -1)
echo "DuckDB $version, signed repository $dist"
[ -d "$dist/$version" ] || { echo "FAILED: $dist/$version does not exist (the tree is not for this DuckDB)"; exit 1; }

pubkey=$(cat "$pubkey_path")

out=$(run -c "
SET allow_extension_repositories='allowed';
CREATE EXTENSION REPOSITORY myrepo WITH PREFIX 'file://$dist' USING PUBLIC KEY '$pubkey';
INSTALL zig_ext_v2 FROM myrepo;
INSTALL zig_ext_cookbook FROM myrepo;
LOAD zig_ext_v2 FROM myrepo;
LOAD zig_ext_cookbook FROM myrepo;
SELECT ct_add_numbers(40, 2);
SELECT zig_cookbook_qname_render('a.\"b c\"');
" 2>&1)
echo "$out"

expect() { echo "$out" | grep -qxF "$1" || { echo "FAILED: expected a line: $1"; exit 1; }; }
expect "42"
expect 'a."b c"'
echo "verify_dist_v2_signed: PASSED — both v2 extensions install and load from the signed repository with no -unsigned"
