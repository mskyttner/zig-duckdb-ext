#!/bin/sh
# Runs inside a real Alpine container (musl libc) under QEMU for arm64.
# Downloads the real musl DuckDB CLI and installs the extension from the
# published GitHub Pages custom repository — end-to-end against the
# actual deploy step's output, not a locally mounted build artifact.
#
# Required env: DUCKDB_VERSION, EXTENSION_NAME, REPO_URL, ARCH (amd64|arm64)
set -eu

apk add --no-cache curl unzip libstdc++ libgcc >/dev/null

curl -fsSL -o /tmp/duckdb_cli.zip \
  "https://install.duckdb.org/${DUCKDB_VERSION}/duckdb_cli-linux-${ARCH}-musl.zip"
unzip -q /tmp/duckdb_cli.zip -d /tmp
chmod +x /tmp/duckdb

OUTPUT="$(/tmp/duckdb -unsigned -csv -c "
INSTALL ${EXTENSION_NAME} FROM '${REPO_URL}';
LOAD ${EXTENSION_NAME};
SELECT zig_hello('ci');
SELECT zig_add_numbers(2, 3);
")"

echo "$OUTPUT"
# -csv quotes any field containing a comma, so the greeting comes back
# as a quoted CSV field, not a bare string (confirmed live: unquoted
# `grep -qx "Hello, ci!"` false-negatived against real -csv output).
echo "$OUTPUT" | grep -qx '"Hello, ci!"' || { echo "FAILED: zig_hello('ci') did not return the expected greeting"; exit 1; }
echo "$OUTPUT" | grep -qx "5" || { echo "FAILED: zig_add_numbers(2,3) did not return 5"; exit 1; }
echo "verify-musl-e2e PASSED for linux_${ARCH}_musl"
