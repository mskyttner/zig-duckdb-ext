# Plan: multi-column and multi-type support for read_zpq

Current state (`src/ext/init_v2_poc_zpq.zig`): one column, one physical type (`INT64`,
`ColumnChunkReader(i64)` hardcoded), REQUIRED or singly-OPTIONAL, never repeated. Filter pushdown
(`pruneRowGroup` + `SelectionVector`) already works but assumes exactly one declared column
(`FilterSpec` has no column index — `declared != 0` is hardcoded to reject anything else).

This doc is a plan, not an implementation — scoping what each extension actually requires before
touching code, in the order that makes sense to build it.

## Why this is harder than "just loop N times"

`ColumnChunkReader(T)` is a comptime-generic type. `GlobalState.reader: ?ColumnChunkReader(i64)`
can't become `readers: []?ColumnChunkReader(T)` for varying `T`, because which physical types a
query needs isn't known until `bind` reads the file's schema at runtime, but `T` has to be fixed
at compile time. Every change below exists to bridge that gap.

## Phase 1: multi-column, still INT64-only

Smallest useful step — proves the N-columns plumbing without also solving type dispatch.

1. **Bind signature.** Either a variadic/`LIST(VARCHAR)` column-name argument, or read every leaf
   column in the file (closer to real `read_parquet`, no argument needed). Loop
   `resolveSupportedColumn` once per requested column; call `tableFunctionBindAddResultColumn`
   once per column (today: exactly once, for `"value"`).
2. **`BindData`** becomes `cols: []ColumnSpec` where `ColumnSpec = struct { col_idx: usize,
   max_def: i32 }`, not a single `col_idx`/`max_def` pair.
3. **`GlobalState.readers`**: `[]?ColumnChunkReader(i64)`, one per column — still fine at this
   phase since every column is still `i64`.
4. **`openNextRowGroup`** loops `bind_data.cols`, building one `ColumnChunkReader` per column
   from that column's own `ColumnChunk`/offset/length, for the same row group. All columns in a
   row group share the same row count, so the readers stay in lockstep — no new synchronization
   logic, just more bookkeeping than the single-column case.
5. **`exec`** loops columns: `dataChunkGetVector(chunk, i, ...)`, decode into that vector's own
   buffer (same direct-decode approach as today, repeated per column), write validity bits per
   column if nullable.
6. **Filter pushdown generalizes**: `FilterSpec` needs its own `declared_col: usize` field instead
   of the hardcoded `declared != 0` check in `recognize`. `filterCompact` changes from "filter one
   `dest: []i64`" to "build one `SelectionVector` from whichever column(s) are filtered, then
   apply the SAME kept-row-indices to compact every column's output array in the batch" — this is
   the one piece of actual new logic, not just repetition. Get this wrong and a filtered multi-
   column query returns misaligned rows (column A's value 5 paired with column B's value from a
   different row) — worth a dedicated test fixture with distinguishable per-column values
   specifically to catch misalignment, not just per-column correctness checks run separately.

Validate with: a 3-column fixture (mixed REQUIRED/OPTIONAL), unfiltered full-scan correctness,
then a filter on one column with assertions on a DIFFERENT column's values (to catch the
misalignment case phase 1.6 just flagged).

## Phase 2: more physical types, still one column at a time

Independent of phase 1 — can be done first, second, or interleaved.

1. **Physical-type dispatch**: `resolveSupportedColumn`'s `if (leaf.element.type != .INT64) return
   error.UnsupportedColumnType;` becomes a `switch` over a small supported-type enum. Follow the
   existing `duckdbV2TypeId`-style comptime dispatch table pattern already used in
   `comptime_scalar_v2.zig` for the Zig-type-to-DuckDB-logical-type mapping, applied here to
   Parquet-physical-type-to-Zig-type instead.
2. **Fixed-width types first** (`BOOLEAN→bool`, `INT32→i32`, `FLOAT→f32`, `DOUBLE→f64` alongside
   the existing `INT64→i64`) — mechanically identical to the current `i64` path, since
   `ColumnChunkReader(T)` already works for any fixed-width `T`. This is genuinely just "copy the
   `i64` code path, change the type parameter" four more times, modulo the `GlobalState.reader`
   type-erasure problem below.
3. **Type erasure for `GlobalState.reader`** (needed the moment more than one physical type can
   appear, even one column at a time across different queries): a tagged union —
   `union(enum) { int32: ColumnChunkReader(i32), int64: ColumnChunkReader(i64), float:
   ColumnChunkReader(f32), double: ColumnChunkReader(f64) }` — chosen once at bind time per
   column, switched on in `exec`'s decode step. This is the same type-erasure need phase 1's
   `readers: []?ColumnChunkReader(T)` has, so if both phases land, they share one union type
   rather than solving this twice.
4. **`BYTE_ARRAY`/`FIXED_LEN_BYTE_ARRAY` (VARCHAR, BLOB, DECIMAL-as-bytes): genuinely unverified,
   not just unimplemented.** Not yet checked whether `ColumnChunkReader([]const u8)` works the
   same way as the fixed-width case, or needs a different decode path — a fixed-width `dest: []T`
   buffer doesn't fit variable-length values the same way. **First step here is investigation, not
   coding**: read `column.zig`'s actual constraints on `T` (does it special-case byte arrays
   internally, or does `ColumnChunkReader(T)` require fixed `@sizeOf(T)`?), the same way the
   `core.scan` vs `core.parquet` question got resolved earlier by reading `decodeInner`/`worker.zig`
   directly rather than assuming. Do not commit to a VARCHAR design before that read.
5. **Logical type, not just physical type, decides the DuckDB column type.** A `BYTE_ARRAY`
   column could be VARCHAR, BLOB, or DECIMAL-encoded-as-bytes — `SchemaElement.converted_type`/
   `logical_type` (already parsed by `metadata.open`, unused by this PoC so far) has to be
   consulted, not just `ColumnMetaData.type`. `DECIMAL` additionally needs `helpers.createDecimalType`
   (width/scale) and zpq's `core/parquet/decimal.zig`, present in the dependency but untouched here.
6. **INT96** (legacy timestamp encoding): deprecated but still appears in older files. zpq has
   `core/parquet/int96.zig`, so the decode primitive exists; needs wiring plus a 12-byte →
   DuckDB-TIMESTAMP conversion. Low priority — only worth doing if a real file actually needs it.

### Phase 2 items 1-3: implemented (2026-11-03)

Verified before coding, not assumed: `column.zig`'s own `PlainDecoderFor(comptime T: type)` lists
exactly `i32`, `i64`, `f32`, `f64`, `bool`, and `[]const u8` as the types `ColumnChunkReader(T)`
supports — confirming items 1-2's "mechanically identical, modulo type erasure" claim before
writing any code, and confirming `[]const u8` (item 4's byte-array case) is a separately-gated
decode shape not touched here.

Built as scoped: `PhysicalType` enum (`boolean`/`int32`/`int64`/`float`/`double`) plus
`ZigType`/`duckdbTypeIdFor`/`sqlNameFor`/`physicalTypeOf` comptime/lookup helpers;
`ResolvedColumn` gained a `phys` field; `Reader = union(PhysicalType) { ... ColumnChunkReader(T)
... }` is the shared type-erasure both this phase and Phase 1's `readers: []?ColumnChunkReader(T)`
needed (solved once, per the plan's own suggested order) — `LocalState.readers` is now
`[]?Reader`. `bind` creates one logical type per column from its own `phys` instead of one shared
BIGINT type for all. `exec`'s per-column decode goes through one new comptime-dispatched
`decodeColumn` instead of five copy-pasted blocks; `filterAndCompactAll`'s per-column compaction
goes through `moveElement`, since `outs` is now raw `*anyopaque` (columns can have different
element sizes, so a `[*]i64`-typed move would read/write the wrong stride for anything
narrower). Filter pushdown stays implicitly INT64-only: `pushdown` now explicitly rejects a
filter whose column didn't resolve to `.int64` (previously true only by accident of
`duckdb_v2_value_get_bigint` happening to fail for non-integer constants).

An explicit `schema` entry's declared `type` now checks against the column's own *actual*
resolved physical type via `sqlNameFor` (`'INTEGER'` for INT32, `'BOOLEAN'` for BOOLEAN, etc.),
not a hardcoded `'BIGINT'` string; the empty-schema auto-select path picks up every
Phase-2-supported physical type, not just INT64.

Verified against a 5-column fixture (`BIGINT`/`INTEGER`/`BOOLEAN`/`FLOAT`/`DOUBLE`, matching
real `COPY ... TO PARQUET` output types for each, not assumed to round-trip): default (all 5
columns, mixed types) and explicit (renamed, mixed types) schemas against native `read_parquet`;
a declared-type mismatch rejected with a clear error; a cross-type misalignment check (5 distinct
per-row relationships checked at once, zero mismatches); filter pushdown declining on a non-
INT64 column but staying correct (DuckDB's own post-scan filter), and still working on an INT64
column alongside other-typed columns in the same query; `threads=1`/`24` correctness. All of
Phase 1's own regression fixtures (TPCH, `multi3`, the nullable fixture, the declined-filter
crash guard) re-checked and still passing.

**Benchmarked against real TPCH data, not a synthetic fixture**: the real `dbgen(sf=5)`
`lineitem` table, projected to `l_orderkey::BIGINT`, `l_linenumber::INTEGER`,
`l_quantity::DOUBLE`, `l_discount::FLOAT`, `(l_returnflag = 'R') AS is_returned` (`BOOLEAN`) —
29,999,795 rows, 60 row groups — so every Phase 2 type is exercised in one file, not just the
single-type fixtures above. `SUM`/`count_if` over all 5 columns (forces full decode of every
one), `-no-agent`, repeated runs for stability, same methodology as PLAN-zpq-parallel.md's own
benchmark:

| | `threads=1` | `threads=24` | speedup (1->24) |
|---|---|---|---|
| native `read_parquet` | ~0.232s | ~0.030s | ~7.6x |
| `read_zpq` | ~0.208s | ~0.030s | ~6.9x |

`read_zpq` is still ~1.1x faster single-threaded (same specialized-decode-loop advantage the
INT64-only benchmark found), and at full parallelism the two are now essentially tied in
absolute wall time — `read_zpq`'s own scaling (6.9x) is slightly weaker than native's (7.6x), the
same shape as PLAN-zpq-parallel.md's own finding, but far closer than that doc's original
2.7x-vs-5.6x gap (before the footer-only-read fix): going from one INT64 column to five mixed-
type columns didn't introduce any new scaling cost of its own.

Validate each new type against DuckDB's own `COPY ... TO PARQUET` output for that type, the same
way the INT64 OPTIONAL-by-default discovery happened — don't assume a type round-trips correctly
until checked against a real file DuckDB itself wrote.

## Phase 1: implemented (2026-11-03)

Built as a named `schema MAP(VARCHAR, STRUCT(name VARCHAR, type VARCHAR))` parameter, modeled on
native `read_parquet`'s own `schema` argument — keys are file column names, each entry's `name`
renames the output column, `type` must be `'BIGINT'` (rejected otherwise, loudly: the caller
asked for that column by name, so silently skipping it would be a correctness surprise, not an
optimization). An empty/omitted `schema` (its default, an empty MAP of the same type) selects
every INT64-eligible leaf column in the file, unrenamed, in schema order — closer to native
`read_parquet`'s own no-argument behavior than a required column list would be.

Matches the doc's own plan almost exactly: `BindData.cols: []ResolvedColumn` (`ResolvedColumn`
already had the right shape — `{col_idx, max_def}` — so no new type was needed), `LocalState`
gained `readers: []?ColumnChunkReader(i64)` and a `def_levels: []u32` scratch buffer (one
`max_rows_per_batch`-sized segment per column, allocated once in `init_local` rather than per
batch), `claimNextRowGroup` loops `bind_data.cols` building one reader per column off the same
row group (a labeled `continue :row_groups` skips the whole row group if even one column's
metadata is malformed), and `exec` decodes column 0 first (its row count/exhaustion drives this
batch's control flow), then every other column bounded to exactly that count, with a defensive
mismatch check (not expected to fire, given every column shares the row group's row count by
construction — kept anyway, since it would silently misalign output otherwise).

**Filter pushdown generalization (1.6) was NOT attempted** — correctly scoped out rather than
half-built: `pushdown` now declines every filter outright once more than one column is selected,
so DuckDB's own executor re-applies it post-scan instead. Correctness is preserved (confirmed:
a dedicated misalignment test — two renamed, distinguishable columns, checking
`renamed_c == -renamed_a` for every row — found zero mismatches at `threads=1` and `threads=24`);
only the optimization is missing for the multi-column case.

**A real, pre-existing bug surfaced along the way, unrelated to multi-column itself**: declining
a filter pushdown (which `pushdown` already did for any filter `recognize` doesn't understand,
even before this phase) crashes DuckDB outright — `Vector::SetSize out of range... capacity
2048` — whenever `max_rows_per_batch` is the `122880` this project's own earlier perf work set it
to (see PLAN-zpq-parallel.md). Reproduced on the pre-existing single-column path too (`WHERE a %
2 = 0`, a filter shape `recognize` never claimed to handle), not just the new multi-column one —
multi-column's forced pushdown decline just happened to be the first thing in this project that
actually exercised a declined filter with a real query. The physical FILTER operator DuckDB
inserts after a scan whose filter it didn't accept apparently ties that scan's own chunk to
`STANDARD_VECTOR_SIZE` (2048) regardless of what `vector_set_size` is asked to reserve. Fixed by
reverting `max_rows_per_batch` to 2048 — already known to cost nothing (the 122880 change was
itself a no-measurable-difference experiment) and now confirmed to be the only value safe in
every pipeline shape this function can end up in.

## Phase 1.6: filter pushdown generalization (implemented, 2026-11-03)

Built exactly as scoped below: `FilterSpec.declared_col`, `recognize`/`pushdown` accepting any
column, `claimNextRowGroup` building each AST leaf from its own filter's column (confirmed live,
not just by reading `prune.zig`: a row-group-pruning sanity check — `WHERE a < 10` against the
6-row-group `multi3.parquet` fixture, where only row group 0 can contain matches — returned
exactly the 10 matching rows, confirming the other 5 row groups were actually skipped). `exec`
now always decodes every selected column before any filtering, and `filterAndCompactAll`
replaces `filterCompact`: one `SelectionVector` built by checking each filter against its own
column, then every column's own output array *and* `def_levels` buffer compacted with it, then
validity bits written for every column afterward (not skipped, since a kept row can be NULL in
a column with no filter on it — exactly the gap this phase's own scoping flagged).

All five validation cases from the scoping below passed, re-checked against `multi3.parquet`
(300k rows, 6 row groups, columns `a`/`b`/`c` with `b = a*1000`, `c = -a` or NULL every 11th
row — distinguishable values chosen specifically to catch misalignment): a filter on column 0
with alignment checked on `b`/`c`; a filter on `c` (a non-zero `declared_col`, exercised for the
first time) alone and matching native `read_parquet` exactly; `a > ... AND c < ...` (two
different columns AND'd) matching native exactly; a filter on `a` only, with `c`'s own NULL count
among kept rows matching native exactly (the validity-mask case); and the same filtered query at
`threads=1` and `threads=24`, plus order preservation (byte-identical CSV diff against native at
`threads=24`). Also re-confirmed: single-column pushdown filtering is unaffected, and a filter
`recognize` doesn't understand (declined, applied by DuckDB post-scan) still doesn't crash — the
`max_rows_per_batch` fix from Phase 1 stays in effect.

## Phase 1.6 (original scoping, for reference)

The one Phase 1 item left undone on purpose (see "Phase 1: implemented" above) — a plan for it,
not an implementation. Checked against zpq's actual code rather than assumed, since the design
hinges on whether the pieces below are already column-agnostic.

### What's already fine, unmodified

**Row-group pruning already supports filters on different columns in one AND.** Read
`core/filter/prune.zig` directly: `pruneRowGroup`'s `.and_filter`/`.or_filter` case recurses into
each child independently (`pruneRowGroup(rg, child, file_meta)`) and combines the two
`Decision`s with `andCombine`/`orCombine` — pure three-valued-logic combination, no assumption
anywhere that the children share a column. Each leaf (`.int64 = .{ .col_idx, .op, .value }`)
resolves its own `col_idx`'s own statistics via `leafStats`/`valueStats`. So `ast.join`-ing
leaves that reference different file columns into one AND, and handing that to `pruneRowGroup`,
already works today — confirmed by reading the dispatch, not by running new code (worth a real
test once this is implemented, but nothing here needs to change).

**`filterCompact`'s `SelectionVector` + iterator mechanism doesn't change.** It already separates
"decide which row indices survive" (the `SelectionVector`) from "compact one array using those
indices" (the iterator walk). What's new is calling the compaction step once per column instead
of once, and building the selection from potentially several columns' values instead of one.

### What's new

1. **`FilterSpec` gains `declared_col: usize`** — the position within `bind_data.cols` the filter
   applies to (not the file's own `col_idx`; needed both to build `ast.Leaf.int64{ .col_idx =
   bind_data.cols[declared_col].col_idx, ... }` in `claimNextRowGroup` and to index the right
   decoded array in `exec`).
2. **`recognize`'s hardcoded `if (declared != 0) return null;`** becomes "accept any `declared` in
   `[0, cols.len)`, record it as `declared_col`." No other change to `recognize` — it already
   resolves "which of our declared columns does this predicate reference" generically via
   `filter_pushdown_get_column_index`.
3. **`pushdown`'s new `if (bind_data.cols.len != 1) return;` guard goes away** — filters get
   accepted again for any column count.
4. **`claimNextRowGroup`'s row-group-pruning AST build** changes from "every leaf uses
   `cols[0].col_idx`" to "leaf `i` uses `cols[bind_data.filters[i].declared_col].col_idx`" —
   confirmed above that `ast.join`/`pruneRowGroup` handle the resulting mixed-column AND
   correctly already.
5. **`exec`'s decode order inverts for the filtered case.** Today, column 0 decodes first (its
   row count drives control flow), and the filtered branch returns immediately after compacting
   column 0 alone — there's nothing else to decode. Once a filter can reference any column, this
   splits in two:
   - Unfiltered row groups (`row_group_always_match == true`, or `filter_count == 0`): unchanged
     — column 0 first, then the rest bounded to its row count, exactly as today.
   - A row group needing the per-row recheck: every selected column must be decoded in full
     *before* filtering, since the selection vector can depend on any of them. Column 0 still
     decodes first to learn the batch's row count (same as the unfiltered path, including
     end-of-row-group handling), then every other column decodes bounded to that count — this
     reuses the loop already written for the unfiltered multi-column case, just run before
     filtering instead of being the last step.
6. **`filterCompact` becomes two functions, or one with a different shape**:
   - **Build the selection** (new logic): for each decoded row, start "kept," then for every
     `FilterSpec`, check that row's validity *in that spec's own column* and evaluate the
     predicate against *that column's own decoded value* — a row with a filter on a column where
     it's NULL fails only because of that filter, not because some *other*, unfiltered column
     happens to be NULL. This is the actual correctness-sensitive new logic: today's single-
     column `filterCompact` folds "is this row valid" and "does it pass the filter" together
     because there's only one column to check; generalized, validity and predicate evaluation
     both become per-filter, per-column lookups instead of one shared `def_levels`/`dest` pair.
   - **Compact every column** (mechanical repetition of existing logic): walk the *same*
     `SelectionVector`'s iterator once per column, compacting that column's own `dest`/
     `def_levels` in place — same write-index-never-passes-read-index loop `filterCompact`
     already has, just called once per column instead of once total.
   - **Validity after compaction, per column**: today's filtered path skips `writeValidityBits`
     entirely, because the one column it handles is guaranteed non-NULL among kept rows (NULL
     rows are excluded by that same column's own filter). That guarantee doesn't generalize: a
     surviving row can still be NULL in a column that has *no* filter on it. So after compaction,
     every selected column needs the same `writeValidityBits` call the unfiltered path already
     does — the filtered path stops being validity-mask-free once more than one column is in
     play.

### Validate with

A 3+ column fixture (mixed REQUIRED/OPTIONAL, like the one `multi3.parquet` already is for Phase
1's own misalignment test), at minimum:
1. A filter on column 0 only, with assertions on a *different*, unfiltered column's surviving
   values (today's Phase 1 misalignment test, now exercised through the filtered path instead of
   around it).
2. A filter on a column other than 0 (exercises `declared_col != 0` for the first time).
3. Filters on two different columns AND'd together (`WHERE a > 100 AND c < -50`) — both the
   row-group-pruning path (does the combined AST actually skip row groups neither filter alone
   would) and the per-row path (does the kept set match applying both filters with DuckDB's own
   post-scan filtering on an *unfiltered* query, as a baseline).
4. A NULL check on the filtered-but-not-NULL-affecting case: a row whose filtered column passes
   the predicate but whose *other*, unfiltered column is NULL — confirms the validity-mask fix
   above and not just alignment.
5. Filtered + `threads > 1` together, same as Phase 1's own parallel validation.

## Explicitly out of scope for both phases

**Nested/repeated types (`LIST`/`STRUCT`/`MAP`, `max_rep > 0`)** — not a type-dispatch problem,
a different decode algorithm entirely (reconstructing DuckDB's nested vectors from Parquet
repetition levels). Deliberately excluded from this PoC since its inception; would be its own,
larger plan if ever pursued.

## Suggested order

Phase 1 (multi-column) and Phase 2 (more types) are independent — pick whichever has a concrete
use case driving it. If both are wanted eventually, do Phase 2's fixed-width types (2.1–2.3) before
Phase 1, since Phase 1's `readers` type-erasure and Phase 2's are the same problem — solving it
once, for the union type, before multiplying it across columns avoids rebuilding it twice.
