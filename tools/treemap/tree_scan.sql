-- Table macro version of duckdir.sh: scans a real directory tree and
-- returns rows in the same shape treemap's tree.json expects
-- (parent, level, value, label, total, groups, leaves), without needing a
-- separate script or an intermediate file.
--
-- Load this once (e.g. via `-init`) then query it directly:
--   duckdb -unsigned -init tree_scan.sql -c "
--       COPY (FROM tree_scan(scan_path := '~/repos')) TO '/dev/stdout' (FORMAT JSON, ARRAY true);
--   "
-- ...which is itself the full "launched command" string for
-- treemap's own command-as-data-source mode:
--   ./treemap "duckdb -unsigned -init tree_scan.sql -c \"COPY (FROM tree_scan(scan_path := '~/repos')) TO '/dev/stdout' (FORMAT JSON, ARRAY true);\" |"
--
-- Parameters:
--   scan_path      Directory to scan. A leading `~` is expanded against
--                  $HOME here (getenv), since it reaches `find` inside a
--                  quoted shellfs command string and would not otherwise
--                  be shell-expanded.
--   name_glob      Shell glob applied to filenames only (find's own -name
--                  semantics). Default '*' (everything).
--   recent_days    When > 0, a file's value is its size only if modified
--                  within the last N days; older files (and all folders)
--                  get value=0. Default 0: disabled.
--
-- Same approach as duckdir.sh (see its own top-of-file comment for the
-- full rationale): shellfs reads `find -printf`'s structured output as a
-- CSV-like stream so DuckDB never has to stat files itself, and the
-- parent/total/group/leaf-count computation happens here in SQL via a
-- recursive ancestor-expansion CTE.
--
-- Parameter named `scan_path`, not `path`: a macro parameter sharing a
-- name with a column produced inside its own body (the `path` column read
-- from `find`'s output) causes DuckDB to misbind references to it
-- ("Values list ... does not have a column named ..."/wrong-source
-- errors) — give the parameter a distinct name instead of fighting that.
--
-- Caveat shared with duckdir.sh: `scan_path`/`name_glob` are quoted
-- naively (wrapped in '...') before being spliced into the shell command
-- string — fine for trusted/local paths, not for untrusted input.
LOAD shellfs;

CREATE OR REPLACE MACRO tree_scan(scan_path, name_glob := '*', recent_days := 0) AS TABLE
WITH RECURSIVE
-- parallel = false and reading mtime as VARCHAR (cast to BIGINT below,
-- after splitting off %T@'s fractional part) work around a shellfs
-- segfault reproduced with a 4th CSV column read straight off its own
-- live pipe under DuckDB's parallel scanner or DOUBLE parsing — a
-- shellfs/DuckDB bug, not a query issue.
--
-- auto_detect = false matters more than it looks like it should, given
-- delim/columns are already both fully specified here: without it,
-- read_csv still runs its own sniffing pre-pass over the pipe even
-- though there's nothing left for it to detect — reproduced directly at
-- real scale (a ~570k-file scan_path): that pre-pass stops early after
-- sampling, leaving `find` mid-write when its pipe closes, so it logs
-- "Broken pipe" — and shellfs's own ShellFileHandle destructor, cleaning
-- up that still-open handle, writes an "Exception in ShellFileHandle
-- destructor: {...}" message straight to **stdout**, not stderr — which
-- corrupts the JSON this macro is piped into as a command source (the
-- documented failure mode: a `SyntaxError` with garbage text where the
-- JSON array should start). A small scan_path never surfaces this: the
-- whole `find` output fits inside the sniff sample, so that pre-pass
-- reads to its own natural EOF instead of stopping early. Confirmed
-- directly: stderr goes fully silent and the output parses as valid
-- JSON with `auto_detect = false` set, on the same scan_path that
-- reproduced the corruption without it.
--
-- read_csv's path argument can't be a subquery (DuckDB: "Table function
-- cannot contain subqueries"), so the `~`-expansion has to happen inline
-- in the same concatenation expression rather than via a separate CTE.
raw AS (
    SELECT * FROM read_csv(
        'find ''' || regexp_replace(scan_path, '^~', getenv('HOME')) || ''' \( -type d -o \( -type f -name ''' || name_glob || ''' \) \) -printf "%y\t%s\t%T@\t%p\n" |',
        delim = '\t', header = false, ignore_errors = true, parallel = false, auto_detect = false,
        columns = {'kind': 'VARCHAR', 'bytes': 'BIGINT', 'mtime': 'VARCHAR', 'path': 'VARCHAR'}
    )
),
indexed AS (
    SELECT
        row_number() OVER (ORDER BY length(path), path) - 1 AS idx,
        regexp_replace(path, '/[^/]+$', '') AS parent_path,
        CASE
            WHEN kind != 'f' THEN 0
            WHEN recent_days <= 0 OR CAST(split_part(mtime, '.', 1) AS BIGINT) >= epoch(now()) - recent_days * 86400 THEN bytes
            ELSE 0
        END AS value,
        regexp_extract(path, '([^/]+)$', 1) AS label,
        path
    FROM raw
),
tree AS (
    -- `p.path != c.path` guards against `scan_path` itself: when it's
    -- given as '.' (vs. an absolute path), find's root entry is printed
    -- as the literal path ".", which has no '/' for the parent_path
    -- regexp to strip — parent_path comes out equal to its own path,
    -- making the root its own parent. Left unguarded, that self-loop
    -- makes the `ancestors` recursive CTE below (which stops only when
    -- `t.parent IS NOT NULL` goes false) recurse forever.
    SELECT c.idx AS id, p.idx AS parent, c.value AS value, c.label AS label
    FROM indexed c
    LEFT JOIN indexed p ON p.path = c.parent_path AND p.path != c.path
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
