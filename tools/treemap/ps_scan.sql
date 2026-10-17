-- Table macro that turns `ps`'s process table into a treemap tree:
-- user > process-state-group > individual process, sized by RSS memory and
-- shaded by %CPU. Prototype for live-resampling: re-run this one-shot query
-- (see tree_scan.sql's own doc comment for why a shared/persistent db isn't
-- needed here — a fresh `duckdb -c "COPY (FROM ps_scan()) TO '/dev/stdout'
-- (FORMAT JSON, ARRAY true);"` each tick is cheap enough on its own).
--
-- This isn't a real parent/child process tree (that would need ppid, which
-- `ps`'s synthetic rows below don't track) — it's a 3-level grouping
-- (user, then coarse state, then one leaf per process), built with the
-- same row_number()+self-join trick as tree_scan.sql.
--
-- Output also carries `key`, the same synthetic hierarchy string used
-- internally for the self-join below (user, `user/state`, or
-- `user/state/pid` for a leaf) — a stable identity for matching the same
-- real-world user/state-group/process across two independently-run
-- snapshots. `label` can't serve that role: it's display text, and
-- several sibling leaves commonly share one (e.g. several Firefox
-- "Isolated" content processes) — see `JsonNode.key`'s doc comment in
-- main.zig for what this enables (a future live-reload tween).
LOAD shellfs;

CREATE OR REPLACE MACRO ps_scan() AS TABLE
-- auto_detect = false, parallel = false: see tree_scan.sql's own `raw` CTE
-- for the full story (a shellfs bug: its ShellFileHandle destructor logs
-- an exception straight to stdout, not stderr, when read_csv's own
-- sniffing pre-pass stops early on a pipe `find`/`ps` hasn't finished
-- writing to yet — corrupting this macro's own JSON output when piped
-- into treemap). Not yet reproduced here (a `ps` listing is small enough
-- to fit in one sniff sample even on a busy system), but there's no
-- reason to leave this one load-bearing on "the process table never
-- gets big enough to hit it".
WITH RECURSIVE raw AS (
    SELECT * FROM read_csv(
        'ps -eo user,pid,stat,pcpu,pmem,rss,comm --no-headers | awk ''{print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7}'' |',
        delim = '\t', header = false, ignore_errors = true, parallel = false, auto_detect = false,
        columns = {
            'ps_user': 'VARCHAR', 'pid': 'BIGINT', 'stat': 'VARCHAR',
            'pcpu': 'DOUBLE', 'pmem': 'DOUBLE', 'rss': 'BIGINT', 'comm': 'VARCHAR'
        }
    )
),
-- First letter of `stat` is the actual process state (S/R/D/Z/T/I/...);
-- the rest are modifier flags (<,N,s,l,+,...) that would fragment the
-- grouping into dozens of near-duplicate buckets if left in.
tagged AS (
    SELECT
        ps_user, pid, left(stat, 1) AS state, pcpu, rss, comm,
        CASE WHEN pcpu < 1 THEN 1 WHEN pcpu < 10 THEN 2 ELSE 3 END AS shade
    FROM raw
),
-- Synthetic hierarchy keyed by strings (not real paths): root -> user ->
-- user/state -> user/state/pid. Each child key is its parent key plus one
-- more '/'-separated segment, so ordering by length(key) before numbering
-- (as tree_scan.sql also does) guarantees a parent always gets a lower id
-- than its children, letting the self-join below resolve in one pass.
nodes AS (
    SELECT '' AS key, CAST(NULL AS VARCHAR) AS parent_key, 'processes' AS label,
           CAST(NULL AS BIGINT) AS value, CAST(NULL AS TINYINT) AS shade
    UNION ALL
    SELECT DISTINCT ps_user, '', ps_user, NULL, NULL FROM tagged
    UNION ALL
    SELECT DISTINCT ps_user || '/' || state, ps_user, state, NULL, NULL FROM tagged
    UNION ALL
    SELECT ps_user || '/' || state || '/' || pid, ps_user || '/' || state, comm, rss, shade FROM tagged
),
indexed AS (
    SELECT row_number() OVER (ORDER BY length(key), key) - 1 AS idx, *
    FROM nodes
),
tree AS (
    SELECT c.idx AS id, p.idx AS parent, c.value AS value, c.label AS label, c.shade AS shade,
           NULLIF(c.key, '') AS key
    FROM indexed c
    LEFT JOIN indexed p ON p.key = c.parent_key AND p.key != c.key
),
-- Same ancestor-expansion pattern as tree_scan.sql, for subtree totals and
-- group/leaf counts (total RSS per user/state group, process counts).
ancestors AS (
    SELECT id, id AS ancestor FROM tree
    UNION ALL
    SELECT a.id, t.parent AS ancestor
    FROM ancestors a JOIN tree t ON a.ancestor = t.id
    WHERE t.parent IS NOT NULL
),
totals AS (
    SELECT a.ancestor AS id, CAST(SUM(COALESCE(t.value, 0)) AS DOUBLE) AS total
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
SELECT tree.parent, 0 AS level, tree.value, tree.label, tree.shade, tree.key,
       totals.total, counts.groups, counts.leaves
FROM tree
JOIN totals ON totals.id = tree.id
JOIN counts ON counts.id = tree.id
ORDER BY tree.id;
