#!/usr/bin/env bash
# Generates a tree.json for treemap from a real directory tree,
# using file/folder size as the node "value".
#
# Usage:
#   ./duckdir.sh <path> [name-glob] [output.json] [recent-days]
#
#   path         Directory to scan (required).
#   name-glob    Optional shell glob applied to filenames only, e.g. '*.zig'
#                — matches find's own -name semantics, not a path glob.
#                Default '*' (everything).
#   output.json  Default: tree.json in the current directory. `-` writes
#                the JSON itself to stdout instead (the "wrote N nodes"
#                status line moves to stderr so it doesn't land in the
#                same stream) — for piping straight into a reader that
#                takes a tree.json on its own stdin, e.g.
#                treemap's own `'./duckdir.sh ~/repos - |'`
#                command-as-data-source mode (see its own top-of-file
#                doc comment).
#   recent-days  Optional. When set (> 0), a file's value is its size only
#                if it was modified within the last N days — anything
#                older gets value=0, same as a folder, so the treemap
#                collapses old files away and makes recent ones stand out.
#                Default 0: disabled, every file keeps its real size.
#
#                This is *modification* time, not creation time: find's
#                own -printf has no portable, single-pass way to get a
#                file's creation/birth time (no %W/%B directive on this
#                system's findutils), and shelling out to `stat` per file
#                to get it doesn't scale to a real directory tree any
#                better than the read_blob approach this script already
#                avoids for sizes (see below). mtime is the closest
#                recency signal find's own -printf can give for free in
#                the same single tree walk.
#
# How it gets sizes: DuckDB has no built-in file-stat function, and reading
# whole file contents just to measure their length (e.g. via read_blob +
# octet_length) doesn't scale to a real directory tree. Instead this uses
# the `shellfs` community extension, which lets a DuckDB table function
# read from a shell command's stdout as if it were a file
# (`read_csv('cmd |', ...)`) — so `find`'s own `-printf` does the actual
# filesystem stat call, once per entry, and DuckDB only ever parses find's
# structured (tab-delimited) output. `find <path>` already walks the whole
# tree recursively, the same reach as a recursive glob (`<path>/**`) would
# give; `name-glob` narrows that to matching filenames via find's -name.
#
# The tree shape itself comes directly from each entry's real filesystem
# path — a file/folder's parent is just its containing directory's row —
# which is far simpler and more robust than deriving structure from
# depth-only sequences (see demo_readme_tree_fixture.zig's generation
# command for that harder case, where no such explicit path existed).
# Folders get value=0 (a pure container).
#
# This script also computes each node's subtree total and contained
# group/leaf counts here in SQL (a recursive CTE expanding every node to
# each of its ancestors, then grouping by ancestor), writing them into
# `total`/`groups`/`leaves` on every row. treemap reads these
# directly when present instead of recomputing them at load time. This
# only works because real directory nesting depth is bounded regardless
# of file count (a recursive ancestor-expansion CTE is O(nodes × depth)
# rows) — measured at ~7s end-to-end for ~570k files (Sep 2026, this
# machine) and ~2s for a synthetic 3M-node/depth-20 tree, so it stays
# comfortably fast at realistic scale. A pathologically deep, near-linear
# tree (depth growing with node count, never true of a real filesystem)
# would blow this up; treemap's own Zig fallback has no such
# limit, which is why it stays in place for files without these fields.
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <path> [name-glob] [output.json] [recent-days]" >&2
    exit 1
fi

path=${1%/}          # strip a trailing slash so basename extraction works
name_glob=${2:-*}
output=${3:-tree.json}
recent_days=${4:-0}

if [ ! -e "$path" ]; then
    echo "error: no such path: $path" >&2
    exit 1
fi

# `-` writes the actual JSON to stdout; the node-count status line below
# still TRIES to read it back from there afterward for a friendly count,
# but by then it's a pipe's write end, not a reopenable file — that read
# fails harmlessly and the existing fallback below just prints '?'
# instead, same as any other read failure there.
output_target=$output
if [ "$output" = "-" ]; then
    output_target=/dev/stdout
fi

# 0 disables the cutoff entirely (every file keeps its real size) rather
# than being a valid "older than 1970" cutoff — checked as its own case
# in the SQL below instead of computing a cutoff of "now" that would zero
# out everything.
cutoff=0
if [ "$recent_days" -gt 0 ] 2>/dev/null; then
    cutoff=$(( $(date +%s) - recent_days * 86400 ))
fi

duckdb -unsigned -json -c "
LOAD shellfs;
-- parallel = false and reading mtime as VARCHAR (cast to BIGINT below,
-- after splitting off %T@'s fractional part) work around a shellfs
-- segfault reproduced with a 4th CSV column read straight off its own
-- live pipe under DuckDB's parallel scanner or DOUBLE parsing — a
-- shellfs/DuckDB bug, not a query issue; the 3-column read (no mtime)
-- above this feature never hit it.
WITH RECURSIVE raw AS (
    SELECT * FROM read_csv(
        'find ''${path}'' \( -type d -o \( -type f -name ''${name_glob}'' \) \) -printf \"%y\t%s\t%T@\t%p\n\" |',
        delim = '\t', header = false, ignore_errors = true, parallel = false,
        columns = {'kind': 'VARCHAR', 'bytes': 'BIGINT', 'mtime': 'VARCHAR', 'path': 'VARCHAR'}
    )
),
indexed AS (
    SELECT
        row_number() OVER (ORDER BY length(path), path) - 1 AS idx,
        regexp_replace(path, '/[^/]+\$', '') AS parent_path,
        CASE
            WHEN kind != 'f' THEN 0
            WHEN ${cutoff} = 0 OR CAST(split_part(mtime, '.', 1) AS BIGINT) >= ${cutoff} THEN bytes
            ELSE 0
        END AS value,
        regexp_extract(path, '([^/]+)\$', 1) AS label,
        path
    FROM raw
),
tree AS (
    SELECT c.idx AS id, p.idx AS parent, c.value AS value, c.label AS label
    FROM indexed c
    LEFT JOIN indexed p ON p.path = c.parent_path
),
-- Every node expanded to each of its ancestors (self included) — used by
-- both aggregations below so the recursion itself only runs once.
ancestors AS (
    SELECT id, id AS ancestor FROM tree
    UNION ALL
    SELECT a.id, t.parent AS ancestor
    FROM ancestors a JOIN tree t ON a.ancestor = t.id
    WHERE t.parent IS NOT NULL
),
totals AS (
    SELECT a.ancestor AS id, CAST(SUM(t.value) AS DOUBLE) AS total
    FROM ancestors a JOIN tree t ON a.id = t.id
    GROUP BY a.ancestor
),
has_children AS (
    SELECT DISTINCT parent AS id FROM tree WHERE parent IS NOT NULL
),
counts AS (
    SELECT a.ancestor AS id,
        CAST(SUM(CASE WHEN hc.id IS NOT NULL AND t.id != a.ancestor THEN 1 ELSE 0 END) AS BIGINT) AS groups,
        CAST(SUM(CASE WHEN hc.id IS NULL AND t.id != a.ancestor THEN 1 ELSE 0 END) AS BIGINT) AS leaves
    FROM ancestors a
    JOIN tree t ON a.id = t.id
    LEFT JOIN has_children hc ON hc.id = t.id
    GROUP BY a.ancestor
)
SELECT tree.parent, 0 AS level, tree.value, tree.label,
       totals.total, counts.groups, counts.leaves
FROM tree
JOIN totals ON totals.id = tree.id
JOIN counts ON counts.id = tree.id
ORDER BY tree.id;
" > "${output_target}"

if [ "$output" = "-" ]; then
    echo "wrote $(python3 -c "import json; print(len(json.load(open('$output_target'))))" 2>/dev/null || echo '?') nodes to stdout" >&2
else
    echo "wrote $(python3 -c "import json; print(len(json.load(open('$output_target'))))" 2>/dev/null || echo '?') nodes to $output"
fi
