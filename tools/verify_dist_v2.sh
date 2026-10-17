#!/usr/bin/env bash
# Installs the v2 extensions from a `dist` tree (a local repository, `file://`) into a DuckDB CLI and checks that they
# load and work: the same steps a user takes with `INSTALL ... FROM '<url>'`, without a web server.
#
#   tools/verify_dist_v2.sh <duckdb-cli> [dist-dir]      (dist-dir defaults to ./dist)
#
# The CLI must be the DuckDB version the tree was built for: the tree is keyed by it (dist/<version>/<platform>/).
# Run `zig build dist-v2` first. An empty HOME keeps the CLI's own extension directory out of it.
set -euo pipefail

cli=$(realpath "${1:?usage: verify_dist_v2.sh <duckdb-cli> [dist-dir]}")
dist=$(realpath "${2:-dist}")
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

run() { HOME="$home" "$cli" -unsigned -no-init -list -noheader "$@"; }

version=$(run -c "SELECT version()" | tail -1)
echo "DuckDB $version, repository $dist"
[ -d "$dist/$version" ] || { echo "FAILED: $dist/$version does not exist (the tree is not for this DuckDB)"; exit 1; }

out=$(run -c "
INSTALL zig_ext_v2 FROM 'file://$dist';
INSTALL zig_ext_cookbook FROM 'file://$dist';
LOAD zig_ext_v2;
LOAD zig_ext_cookbook;
SELECT ct_add_numbers(40, 2);
SELECT zig_cookbook_qname_render('a.\"b c\"');
SELECT array_to_string(parameters, ',') || '|' || description FROM duckdb_functions() WHERE function_name = 'ct_add_numbers';
" 2>&1)
echo "$out"

expect() { echo "$out" | grep -qxF "$1" || { echo "FAILED: expected a line: $1"; exit 1; }; }
expect "42"
expect 'a."b c"'
expect 'a,b|Adds two BIGINT values. Overflow is an error of the query.'
echo "verify_dist_v2: PASSED — both v2 extensions install from the tree and work"
