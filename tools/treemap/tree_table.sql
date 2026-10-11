-- Tree <-> table crosswalk macros, prototyping a "materialized path" SQL
-- interface before any decision to promote it into the compiled zig_ext
-- extension itself (the way PIVOT/UNPIVOT eventually became first-class
-- relational operators) — see the design discussion this followed.
--
-- The tabular side uses one VARCHAR column (conventionally `path`) holding
-- the full path from root to the node, '/'-joined (configurable `sep`) —
-- the standard "materialized path" tree encoding. An INTERIOR node's path
-- carries a trailing separator ("a/b/"); a LEAF's does not ("a/b/c") — so
-- the two are distinguishable from the string alone, matching how a real
-- filesystem path already works. `tree_to_table`/`table_to_tree` convert
-- between this and the adjacency-list shape (`id`, `parent_id`, `label`,
-- plus arbitrary other attribute columns) every other macro in this
-- directory (tree_scan.sql/ps_scan.sql) and treemap itself already use.
--
-- Table macro arguments can't be column names used as identifiers (macro
-- parameters are substituted as values, not spliced into identifier
-- position — this is why tree_scan.sql/ps_scan.sql also hard-code their
-- own column names rather than taking them as parameters) — so both
-- macros here fix the id/parent_id/label/path column names and instead
-- let *other* attribute columns (value, shade, ...) pass through
-- unnamed via `* EXCLUDE (...)`, whatever they happen to be.
--
-- A table-valued macro argument is itself passed as a *string* table name
-- and read back via `query_table(tbl)`, not a bare `FROM tbl` — confirmed
-- directly; DuckDB only resolves the former for a macro's own table
-- parameter.
LOAD shellfs;

-- ─── tree_to_table: adjacency-list -> materialized-path table ──────────────
CREATE OR REPLACE MACRO tree_to_table(tbl, sep := '/') AS TABLE
WITH RECURSIVE
has_children AS (
    SELECT DISTINCT parent_id AS id FROM query_table(tbl) WHERE parent_id IS NOT NULL
),
paths AS (
    SELECT id, label AS path
    FROM query_table(tbl)
    WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, p.path || sep || c.label
    FROM query_table(tbl) c
    JOIN paths p ON c.parent_id = p.id
)
-- `label` isn't re-emitted as its own column: `path`'s own last segment
-- already recovers it (table_to_tree does exactly that), and keeping a
-- redundant copy alongside `path` only gets in the way of the other
-- direction's generic, type-agnostic attribute handling.
SELECT t.* EXCLUDE (id, parent_id, label),
       paths.path || CASE WHEN h.id IS NOT NULL THEN sep ELSE '' END AS path
FROM query_table(tbl) t
JOIN paths ON paths.id = t.id
LEFT JOIN has_children h ON h.id = t.id;

-- ─── table_to_tree: materialized-path table -> adjacency-list ──────────────
-- Pure structural reconstruction only: id/parent_id/label/path, plus an
-- explicit row's own attributes passed through unchanged (`* EXCLUDE`) —
-- but a *synthesized* node (one with no explicit row of its own, because
-- only its descendant leaves were given) gets no attribute columns at
-- all. Deliberately decoupled from attribute aggregation (which an
-- earlier version of this macro did internally via a `agg` parameter and
-- `COLUMNS()`/`list_aggregate` wildcarding) — composing this with an
-- ordinary follow-up query is simpler and more flexible than any fixed
-- set of built-in aggregation modes could be. See `weighted_avg` below,
-- and the worked example in its own doc comment, for the pattern: join
-- `table_to_tree`'s bare skeleton against the original leaves, grouped by
-- which synthesized ancestor each leaf rolls up under, using whatever
-- aggregate expression — built-in or a small reusable macro like
-- `weighted_avg` — actually fits the attribute in question. Different
-- columns calling for different aggregations (sum one, weighted-average
-- another) was the whole reason the old `agg` parameter could only ever
-- apply one named mode uniformly to everything.
--
-- A row whose path already appears as another row's exact path collides
-- (ambiguous: which one's attributes win?) — not guarded against here,
-- same as this directory's other macros assume well-formed input.
CREATE OR REPLACE MACRO table_to_tree(tbl, sep := '/') AS TABLE
WITH RECURSIVE
normalized AS (
    -- Strip exactly one trailing separator (the explicit-interior marker)
    -- if present; every other column passes through unchanged.
    SELECT
        (CASE WHEN path LIKE '%' || sep THEN left(path, length(path) - length(sep)) ELSE path END) AS norm_path,
        * EXCLUDE (path)
    FROM query_table(tbl)
),
segments AS (
    SELECT norm_path, string_split(norm_path, sep) AS segs FROM normalized
),
-- Every path and all of its ancestor prefixes (including itself) — the
-- full node set this tree needs, whether or not each one had its own
-- explicit row in `tbl`.
node_paths AS (
    SELECT DISTINCT array_to_string(segs[1:i], sep) AS path
    FROM segments, generate_series(1, len(segs)) AS g(i)
),
-- Ordering by length(path) before numbering guarantees a parent always
-- gets a lower id than its children (a strictly shorter string can never
-- come after a longer one that contains it as a prefix) — same trick
-- tree_scan.sql/ps_scan.sql already use for the same reason.
indexed AS (
    SELECT row_number() OVER (ORDER BY length(path), path) - 1 AS id, path
    FROM node_paths
),
has_children AS (
    SELECT DISTINCT p.id
    FROM indexed c
    JOIN indexed p
        ON p.path = regexp_replace(c.path, sep || '[^' || sep || ']+$', '')
        AND p.path != c.path
),
tree AS (
    SELECT
        c.id, p.id AS parent_id,
        regexp_extract(c.path, '([^' || sep || ']+)$', 1) AS label,
        -- A trailing separator marks an interior node, same as
        -- tree_to_table's own output — without this, table_to_tree's
        -- `path` can't be safely prefix-matched at all: a directory
        -- named "build" and a sibling *file* "build.zig" both start with
        -- the literal string "build", so `LIKE 'build%'` (no separator)
        -- falsely matches the file as if it were inside the directory.
        -- Confirmed directly against real data (zig-pkg/aro's own
        -- build.zig/build.zig.zon sitting next to a build/ directory) —
        -- this is exactly what made the old LIKE-prefix composition
        -- pattern silently wrong, not just slow.
        c.path || CASE WHEN h.id IS NOT NULL THEN sep ELSE '' END AS path
    FROM indexed c
    LEFT JOIN indexed p
        ON p.path = regexp_replace(c.path, sep || '[^' || sep || ']+$', '')
        AND p.path != c.path
    LEFT JOIN has_children h ON h.id = c.id
)
-- `path` is included in the output (not just id/parent_id/label) — useful
-- on its own for prefix-based follow-up joins (see `weighted_avg`'s own
-- doc comment above for exactly that pattern), and it's already computed
-- internally regardless.
SELECT tree.id, tree.parent_id, tree.label, tree.path, normalized.* EXCLUDE (norm_path)
FROM tree
LEFT JOIN normalized ON normalized.norm_path = tree.path
ORDER BY tree.id;

-- ─── weighted_avg: reusable aggregate-style scalar macro ────────────────────
-- `sum(x * y) / sum(y)` — DuckDB has no built-in weighted-average
-- aggregate (unlike avg/sum/min/max, all usable directly). A *scalar*
-- macro works here specifically because DuckDB macros are pure text
-- substitution at expansion time: calling `weighted_avg(shade, value)`
-- inside a `GROUP BY` query expands to literally `sum(shade * value) /
-- sum(value)` before binding, which is then a perfectly ordinary
-- aggregate expression in the enclosing query — confirmed directly. The
-- macro itself never "aggregates" anything; it just supplies the
-- per-group formula textually, with `x`/`y` substituted for whatever
-- column expressions the caller passes.
--
-- Typical use alongside `table_to_tree`: reattach aggregated attributes
-- to synthesized (structural-only) ancestor nodes. The join has to walk
-- `table_to_tree`'s own `parent_id` links (an "ancestor expansion" —
-- the exact recursive-CTE pattern tree_scan.sql/ps_scan.sql already use
-- for their own total/group/leaf rollups), not a `path`-prefix `LIKE`
-- match: a `LIKE s.path || '%'` join is both an O(skeleton_rows ×
-- leaf_rows) nested-loop scan (confirmed directly via EXPLAIN ANALYZE —
-- fine on ~800 nodes, catastrophic at a real tree's scale of ~500K) *and*
-- silently wrong — a directory "build" and a sibling *file* "build.zig"
-- both start with the literal string "build", so a plain `LIKE` falsely
-- treats the file as the directory's descendant (confirmed directly
-- against real data: zig-pkg/aro's own build.zig/build.zig.zon next to
-- a build/ directory). The ancestor-expansion join below only ever
-- follows real `parent_id` edges, so it's immune to that class of bug
-- and runs in O(nodes × depth), not O(nodes × leaves):
--   CREATE TABLE skeleton AS FROM table_to_tree('leaves_only');
--   WITH RECURSIVE ancestors AS (
--       SELECT id, id AS ancestor FROM skeleton
--       UNION ALL
--       SELECT a.id, s.parent_id AS ancestor
--       FROM ancestors a JOIN skeleton s ON a.ancestor = s.id
--       WHERE s.parent_id IS NOT NULL
--   ),
--   agg AS (
--       SELECT anc.ancestor AS id,
--              sum(sk.value) AS total_value,
--              weighted_avg(sk.shade, sk.value) AS avg_shade
--       FROM ancestors anc
--       JOIN skeleton sk ON sk.id = anc.id
--       WHERE sk.value IS NOT NULL   -- only rows with real leaf attributes
--       GROUP BY anc.ancestor
--   )
--   SELECT skeleton.id, skeleton.parent_id, skeleton.label,
--          COALESCE(skeleton.value, agg.total_value) AS value,
--          COALESCE(skeleton.shade, agg.avg_shade) AS shade
--   FROM skeleton
--   LEFT JOIN agg ON agg.id = skeleton.id;
CREATE OR REPLACE MACRO weighted_avg(x, y) AS sum(x * y) / NULLIF(sum(y), 0);

-- ─── tree_diff / tree_diff_counts: how does a tree change between two ──────
-- ─── snapshots? ─────────────────────────────────────────────────────────
-- Both take two *already path-keyed* tables (e.g. two `tree_to_table()`
-- outputs, or two snapshots loaded straight from a live source like
-- ps_scan.sql) and classify every distinct `path` as `added` (only in
-- `tbl1`), `removed` (only in `tbl0`), `changed` (same path, different
-- attributes), or `unchanged`.
--
-- Directly modeled on ../../../demetrius/tabular_diff.sql's `diff_pk`/
-- `diff_pk_counts` (a general-purpose PK-based row-diff toolkit for any
-- two tables) — `path` stands in for their `_pk` here, since a
-- materialized path *is* already a tree node's natural, stable identity
-- across two snapshots (see tree_scan.sql's own `key` field for the same
-- idea applied to treemap's own live-reload matching). The changed-column
-- unnesting (`unnest(json_keys(...))` + `map_from_entries`) is their
-- technique, reused as-is rather than reinvented.
--
-- Unlike `tabular_diff.sql`'s own `md5(row::json::varchar)` (which hashes
-- JSON keys in column-definition order, so two schemas differing only in
-- column order spuriously look "different" — confirmed directly, twice,
-- while benchmarking this at scale), `canonical_row_hash` sorts the keys
-- first. Type coercion differences (`1` vs `1.0`) can still cause false
-- positives either way — ensure both snapshots agree on column types.
--
-- What this does *not* detect: a node that moved to a different parent
-- gets a different path (paths are built from ancestor labels), so it
-- shows up as a `removed` old path plus an `added` new path, never a
-- `changed` or a tracked "move" — the same class of limitation
-- `tabular_diff.sql` itself doesn't attempt to solve for arbitrary
-- tables (that's rename/move detection, a genuinely harder problem, out
-- of scope here too).
-- Row-hash helper shared by both macros below: sorts a row's own JSON
-- keys before hashing, so two tables with the same columns in a
-- different order still compare as identical (confirmed directly: a
-- naive `md5(row::json::varchar)`, same as tabular_diff.sql's own
-- method, gave two different hashes for `(id, label, value)` vs
-- `(value, id, label)` on otherwise-identical data).
CREATE OR REPLACE MACRO canonical_row_hash(j) AS md5(array_to_string(
    list_transform(list_sort(json_keys(j)), lambda k: k || '=' || COALESCE(json_extract_string(j, k), 'NULL')),
    '|'
));

CREATE OR REPLACE MACRO tree_diff_counts(tbl0, tbl1) AS TABLE (
    WITH
    _s_raw AS (FROM query_table(tbl0)),
    _t_raw AS (FROM query_table(tbl1)),
    s AS (FROM _s_raw SELECT path, canonical_row_hash(_s_raw::json) AS _rh),
    t AS (FROM _t_raw SELECT path, canonical_row_hash(_t_raw::json) AS _rh),
    joined AS (
        SELECT CASE
            WHEN s.path IS NULL THEN 'added'
            WHEN t.path IS NULL THEN 'removed'
            WHEN s._rh != t._rh THEN 'changed'
            ELSE 'unchanged'
        END AS _diff
        FROM s FULL OUTER JOIN t ON s.path = t.path
    )
    SELECT
        count(*) FILTER (_diff = 'added')     AS added,
        count(*) FILTER (_diff = 'removed')   AS removed,
        count(*) FILTER (_diff = 'changed')   AS changed,
        count(*) FILTER (_diff = 'unchanged') AS unchanged,
        count(*)                               AS total
    FROM joined
);

-- Row-level detail: one row per non-unchanged path, with `changed_cols`/
-- `changes` (a `{col: "old -> new"}` map) for `changed` rows, and the
-- full `t0`/`t1` row JSON always included either way.
CREATE OR REPLACE MACRO tree_diff(tbl0, tbl1, n := 100) AS TABLE (
    WITH
    _s_raw AS (FROM query_table(tbl0)),
    _t_raw AS (FROM query_table(tbl1)),
    s AS (FROM _s_raw SELECT *, _s_raw::json::varchar AS _rj, canonical_row_hash(_s_raw::json) AS _rh),
    t AS (FROM _t_raw SELECT *, _t_raw::json::varchar AS _rj, canonical_row_hash(_t_raw::json) AS _rh),
    joined AS (
        SELECT
            COALESCE(s.path, t.path) AS path,
            CASE
                WHEN s.path IS NULL THEN 'added'
                WHEN t.path IS NULL THEN 'removed'
                WHEN s._rh != t._rh THEN 'changed'
                ELSE 'unchanged'
            END AS _diff,
            s._rj::json AS _sj, t._rj::json AS _tj,
            s._rj AS t0, t._rj AS t1
        FROM s FULL OUTER JOIN t ON s.path = t.path
    ),
    -- For changed rows: unnest keys, find per-column diffs, re-aggregate.
    changed_keys AS (
        SELECT j.path, j._diff, j._sj, j._tj, j.t0, j.t1, unnest(json_keys(j._sj)) AS col_name
        FROM joined j
        WHERE j._diff = 'changed'
    ),
    changed_agg AS (
        SELECT
            path, _diff, t0, t1,
            list(col_name ORDER BY col_name) AS changed_cols,
            map_from_entries(list(
                (col_name, json_extract_string(_sj, col_name) || ' -> ' || json_extract_string(_tj, col_name))
                ORDER BY col_name
            )) AS changes
        FROM changed_keys
        WHERE col_name != 'path'
          AND json_extract_string(_sj, col_name) IS DISTINCT FROM json_extract_string(_tj, col_name)
        GROUP BY path, _diff, t0, t1
    ),
    result AS (
        SELECT path, _diff, changed_cols, changes, t0, t1
        FROM changed_agg

        UNION ALL

        SELECT path, _diff, NULL, NULL, t0, t1
        FROM joined
        WHERE _diff IN ('added', 'removed')
    )
    FROM result
    ORDER BY
        CASE _diff WHEN 'changed' THEN 1 WHEN 'added' THEN 2 WHEN 'removed' THEN 3 END,
        path
    LIMIT n
);
