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
4. **`BYTE_ARRAY`/`FIXED_LEN_BYTE_ARRAY` (VARCHAR, BLOB, DECIMAL-as-bytes).**

   **Investigated (2026-11-04), not assumed — `[]const u8` is already a first-class `T`, not a
   different shape.** `column.zig`'s own module doc comment says it outright: "caller picks the
   right `T` based on the column's logical type (i32/i64/f32/f64 for primitives, `[]const u8` for
   BYTE_ARRAY)". The mechanical reason this works at all: `T = []const u8` is a fixed-size slice
   *header* (ptr+len), so `dest: []T` is still a uniform-stride array of fixed-size elements —
   exactly the same shape `decodeColumn`/`moveElement` already assume — only the bytes each
   header *points to* are variable-length, which this PoC never needs to store inline anyway.
   `ColumnChunkReader([]const u8).init(...)` is a real, exercised code path (zpq's own test
   suite constructs one directly). Every encoding this PoC's fixed-width types already rely on
   supports byte arrays too: `rle_dict.Decoder([]const u8)` (dictionary-encoded strings, the
   common case for real VARCHAR columns) is enabled whenever `T != bool`; `DELTA_LENGTH_BYTE_ARRAY`/
   `DELTA_BYTE_ARRAY` are gated on `T == []const u8` specifically, so they're exercised *only* by
   this path, not inherited for free from the numeric types. No encoding gap found.

   **Lifetime, checked against this PoC's own ownership model, not assumed safe**: `decodeInner`'s
   own doc comment: "everything returned lives as long as `arena`: the buffers are allocated
   there, and `[]const u8` values are slices into page bytes, which a byte-array reader never
   routes through a scratch." Our `chunk_bytes` is already `local.arena`-backed (allocated fresh
   per row group, reset only when `claimNextRowGroup` claims the next one — see ADR-0009), and we
   already pass `scratch: null` (the plain `init()`, not `initWithOptions` with a scratch
   pointer) — exactly the mode byte-array columns require. Decoded slices stay valid for the
   whole `exec` call that decoded them, which is exactly when they'd be copied out into the
   output vector — no new ownership hazard.

   **`FIXED_LEN_BYTE_ARRAY` needs one extra field set after `init`**: `type_length: usize = 0` on
   the reader itself ("Set by the caller after init (defaults to 0 so existing callers are
   unaffected)"), from the schema element's own `type_length`. `0` (the default) means "plain,
   length-prefixed BYTE_ARRAY"; non-zero means "fixed `type_length`-byte values, no prefix" —
   needed for BLOB-as-FLBA, UUID, and DECIMAL-as-FLBA.

   **Writing VARCHAR/BLOB output needs a different vector API than the fixed-width columns use**,
   checked against the real (not ADR-0003-era alpha) v2 header: `vector_get_data_mutable` still
   works for a VARCHAR/BLOB vector (it returns `duckdb_v2_bytes`/`duckdb_v2_varchar_t` cells,
   the same inline-or-pointer layout `v2_helpers.makeBytesValue` already builds for
   `comptime_scalar_v2.zig`'s own VARCHAR scalar-result path), plus `vector_get_arena` to get the
   arena a longer string's out-of-line bytes need to live in. So the write side is: for each
   decoded row, `helpers.makeBytesValue(vector_arena, text, err)` into `out[row]` — reusing an
   existing, already-proven helper in a new context, not inventing a new write mechanism. This is
   a per-row call (unlike the fixed-width columns' single bulk decode-into-buffer), a real,
   expected cost difference for variable-length output — not a design problem, just worth naming
   up front rather than discovering mid-implementation.

   **Design, now committed**: `PhysicalType` gains `.varchar`/`.blob` (not yet `.decimal_bytes` —
   see item 5's own DECIMAL note); `ZigType` maps both to `[]const u8`; `resolveSupportedColumn`
   accepts `BYTE_ARRAY`/`FIXED_LEN_BYTE_ARRAY` and picks `.varchar` vs `.blob` from
   `leaf.element.effectiveLogicalType()` (see item 5, below) rather than physical type alone;
   `claimNextRowGroup` sets `reader.type_length` after `init` when the leaf's own schema
   `type_length` is non-zero; `exec`'s per-column write gets a `[]const u8`-specific branch next
   to `decodeColumn`'s existing numeric/boolean one, using `vector_get_arena` +
   `helpers.makeBytesValue` instead of a flat buffer write. Filter pushdown on a VARCHAR/BLOB
   column (a `.string` leaf variant already exists in `ast.Filter`, confirmed, matching the
   pattern Phase 2.7 already established) is explicitly **not** part of this slice — a natural,
   separate follow-on once the type itself works, not a blocker for it.

   **Implemented (2026-11-04), matching the committed design exactly**, with two fixes the real
   compiler caught that the design didn't call out: `FilterValue` had to get its own tag enum
   (`union(enum)`, not `union(PhysicalType)`) since tying it to `PhysicalType` directly would
   require a field for `.varchar`/`.blob` too, which can never produce a filter value;
   `moveElement`'s `.varchar`/`.blob` arm casts explicitly to `[*]duckdb_v2_bytes`, not
   `ZigType`'s own `[]const u8` — the vector's real storage, not a Zig slice header that happens
   to be the same size on this platform. Verified against a VARCHAR/BLOB/nullable-VARCHAR
   fixture, with its logical-type annotations confirmed via `parquet_schema` first (`UTF8` on the
   VARCHAR columns, no `converted_type` at all on the BLOB one, exactly matching native DuckDB's
   own `COPY ... TO PARQUET` output): default and explicit (renamed) schemas against native
   `read_parquet`; a 4-condition misalignment/NULL-pattern check (zero mismatches); a full
   byte-level CSV diff against native, at both `threads=1` and `threads=24` with order preserved;
   a declined `WHERE name = ...` filter not crashing (the `max_rows_per_batch` guard from Phase 1
   still holds). Full prior regression suite (TPCH, `multi3`, `types5`, the nullable fixture, the
   declined-filter crash guard) re-run and still passing.

5. **Logical type, not just physical type, decides the DuckDB column type.** Checked
   `schema.zig`'s own `SchemaElement.effectiveLogicalType()` directly: it resolves either the
   modern `logical_type` or the legacy `converted_type` fallback into one `LogicalType` union —
   `.STRING` (from `logical_type`'s `STRING` or `converted_type`'s legacy `UTF8`) means VARCHAR;
   anything else on a `BYTE_ARRAY`/`FIXED_LEN_BYTE_ARRAY` column (no annotation, or one this PoC
   doesn't map) means BLOB; `.DECIMAL` (`DecimalType{ scale, precision }`) means DECIMAL-as-bytes,
   needing `helpers.createDecimalType` (width/scale) and zpq's `core/parquet/decimal.zig`, present
   in the dependency but untouched here — a separate sub-step from plain VARCHAR/BLOB, not
   required to land them.

6. **INT96** (legacy timestamp encoding): deprecated but still appears in older files. zpq has
   `core/parquet/int96.zig`, so the decode primitive exists; needs wiring plus a 12-byte →
   DuckDB-TIMESTAMP conversion. Low priority — only worth doing if a real file actually needs it.

7. **VARIANT output, investigated on request (2026-11-04) — low priority, not blocking anything
   above.** zpq's `LogicalType` union also recognizes Parquet's `JSON`/`BSON` logical-type
   annotations on a `BYTE_ARRAY` column (distinct from `.STRING`) — a real candidate for mapping
   to DuckDB's native VARIANT type instead of plain VARCHAR. Checked what that would actually
   cost, not assumed cheap: `comptime_scalar_v2.zig`'s own doc comment says VARIANT "has no
   committed view layout (no `vectorGetView` support)" — it's read and written exclusively
   through per-cell `duckdb_v2_value_handle` boxing (`vector_get_value`/`vector_set_value`, the
   "only way to reach a cell" for a type with no flat buffer representation), not the flat
   `duckdb_v2_bytes` array VARCHAR/BLOB get. So VARIANT output would mean one `Value`
   construction (likely a VARCHAR value cast to VARIANT, or a JSON-parsing constructor — not
   checked which) plus one `vector_set_value` call *per row*, strictly slower than every other
   column type this PoC writes, for a column annotation that's rare in real files compared to
   plain VARCHAR. Scoped as its own, separate, low-priority item — same priority tier as INT96 —
   not attempted alongside VARCHAR/BLOB.

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

## Phase 2.7: filter pushdown for non-INT64 columns (implemented, 2026-11-03)

Built exactly as scoped below. One addition the scoping didn't call out in advance:
`recognize` needed `bind_data` passed in (not just `info`/`filter`/`scratch`), since it now has
to look up the referenced column's own `phys` to pick the right `value_get_*` — a small, obvious
signature change, not a design surprise.

All five validation cases passed against `types5.parquet` (`BIGINT`/`INTEGER`/`BOOLEAN`/`FLOAT`/
`DOUBLE`): a pushed-down filter on `INTEGER`, `FLOAT`, and `DOUBLE` individually, each matching
native `read_parquet` exactly; `WHERE flag` and `WHERE flag = true` both recognized and pushed
down (DuckDB's planner apparently treats a bare boolean column reference as a `= true`
comparison by the time this callback sees it — confirmed by both forms returning the identical,
correct result, not assumed from the shape alone); `WHERE fval > ... AND dval < ...` (two
different non-INT64 types AND'd) matching native exactly; a row-group-pruning sanity check
(`WHERE int32col < 10`, same technique as Phase 1.6's) returning instantly with exactly the
expected 10 rows; and `threads=1`/`24` correctness plus order preservation under a non-INT64
filter. The full prior regression suite (TPCH single-column pushdown, `multi3`'s two-INT64-
column AND, the nullable fixture, the declined-filter crash guard) re-run and still passing.
Filter pushdown now covers every `PhysicalType` this PoC supports, not just INT64.

## Phase 2.7 (original scoping, for reference)

Checked against zpq's actual code and the v2 header, not assumed, before committing to a design
— same discipline as Phase 1.6's scoping.

**Both layers already support it.** zpq's `ast.Filter` is a union with a leaf variant per
physical type (`int32: Leaf(i32)`, `float: Leaf(f32)`, `double: Leaf(f64)`, `boolean:
Leaf(bool)`, alongside `int64`), and `prune.pruneRowGroup` already dispatches each to its own
stats-based pruning (`pruneNumeric`/`pruneBoolean`) — no changes needed there, and its AND/OR
combinator already handles a mix of leaf types in one filter (confirmed for mixed *columns* in
Phase 1.6; the union covers mixed *value types* the same way, recursively, with no extra
special-casing). The v2 C API has the value getters needed: `duckdb_v2_value_get_bool`/
`get_int`/`get_float`/`get_double`, alongside `get_bigint` already in use.

**A real gotcha that explains why Phase 2's `.phys != .int64` guard in `pushdown` was load-
bearing, not just defensive**: `duckdb_v2_value_get_bigint`'s own doc comment says "a value of a
different type is converted through the default cast set" — it does **not** fail for a
FLOAT/DOUBLE/BOOLEAN constant, it silently casts it to a truncated/rounded int64. Without that
guard, `recognize` would have kept producing a `FilterSpec` for a non-INT64 column filter all
along, just a silently wrong one (e.g. `WHERE fval > 1.5` turning into `fval > 1` internally).
Confirms the right fix is to pick the getter from the **column's own resolved `phys`**, never
from whichever getter happens not to error.

### What's new

1. **`FilterSpec.value` becomes `FilterValue = union(PhysicalType) { boolean: bool, int32: i32,
   int64: i64, float: f32, double: f64 }`** instead of a bare `i64`.
2. **`recognize` needs `bind_data` too** (not just `info`/`filter`/`scratch`), to look up
   `bind_data.cols[declared].phys` right after resolving `declared` and call the matching
   `value_get_*` instead of always `get_bigint`. For a `.boolean` column, also reject any `op`
   other than `Eq`/`NotEq` right here (declining, same as any other "not recognized" case) —
   `<`/`>` on a boolean never comes from DuckDB's own planner, but `evalFilter` below has no
   sound way to execute it if it somehow did, so the check belongs at recognition time, not
   buried as an `unreachable` deeper in.
3. **`pushdown`'s `.phys != .int64 => continue` guard goes away** — every `PhysicalType`
   `recognize` can now produce a `FilterValue` for gets pushed down.
4. **`claimNextRowGroup`'s AST leaf build** switches on `spec.value`'s own tag to pick the
   matching `ast.Filter` variant (`.boolean`/`.int32`/.../`.double`) instead of always `.int64`.
5. **`evalFilter` gains a `.boolean` arm plus an `inline` dispatch over the four ordered numeric
   types** — `bool` has no `<`/`>`/`<=`/`>=` in Zig, so it can't share the same generic switch
   over `Operator` the numeric types do; kept as its own explicit, non-generic arm (only `Eq`/
   `NotEq`, matching the recognize-time restriction) rather than a comptime-conditional branch
   inside one shared generic body.
6. **`filterAndCompactAll`'s filtered-column read** stops assuming `[*]i64` and calls the
   generalized `evalFilter(spec, outs[declared_col], row)` instead, which picks the right cast
   itself from `spec.value`'s tag.

### Validate with

The mixed-type fixture already built for Phase 2 (`types5.parquet`: BIGINT/INTEGER/BOOLEAN/
FLOAT/DOUBLE): a pushed-down filter on each of the four newly-supported types individually,
matching native `read_parquet` exactly; a filter combining two different non-INT64 types in one
AND (exercises the mixed-leaf-type AND path for the first time, not just mixed-column); a
boolean filter via both `WHERE flag` and `WHERE flag = true` shapes, to see which (if either)
`recognize` actually receives as a comparison it can match; row-group pruning actually skipping
groups for a non-INT64 filter (the same `WHERE col < small_value` sanity check Phase 1.6 used);
and the full regression suite (TPCH, `multi3`, nullable, declined-filter crash guard,
threads=1/24) re-run once more.

## Phase 2.8: filter pushdown for VARCHAR (implemented, 2026-11-04)

Built exactly as scoped below. Verified against `strings.parquet` (BIGINT/VARCHAR/BLOB/nullable-
VARCHAR): `Eq`, `Lt`, `Gt` each matching native `read_parquet` exactly — the real test of the
byte-order claim, not just that it compiles; row-group pruning actually skipping groups
(`WHERE name < 'name_00001'` against the 5-row-group fixture returned instantly with exactly the
one row that's a byte-wise prefix of the bound); a VARCHAR filter AND'd with a numeric filter on
a different column; a VARCHAR filter against a column with real NULLs elsewhere in the row (no
NULL ever passed); a declined BLOB filter still correct and not crashing; `threads=1`/`24` with
order preserved. Full prior regression suite re-run and still passing.

**Benchmarked against real TPCH data**: `dbgen(sf=5)` `lineitem`, projected to
`l_orderkey::BIGINT, l_comment::VARCHAR` (29,999,795 rows, 60 row groups, `l_comment` real free-
text averaging ~26 bytes, UTF8-annotated — confirmed via `parquet_schema` first). Correctness
re-checked on this real data too (`WHERE l_comment > 'm'`, exact match). Filtered-scan timing
(`-no-agent`, repeated runs for stability, same methodology as every other benchmark in this
plan):

| | `threads=1` | `threads=24` |
|---|---|---|
| native `read_parquet` | ~0.89s | ~0.13s |
| `read_zpq` | ~1.29s | ~0.19s |

**Honest result: native is faster here, ~1.45x at both thread counts** (so scaling itself is
comparable — `read_zpq`'s own 1→24 speedup is roughly the same ~6.8-6.9x as native's — the gap
is a fixed per-row cost, not a scaling problem). A plausible, specific reason, not just "strings
are slow": `decodeColumn`'s VARCHAR path does a double copy per row — decode into a
`local.arena` scratch slice, then `v2_helpers.makeBytesValue` copies *again* into the vector's
own arena — and `evalFilter` reads back through `bytesSlice` + `std.mem.order` per row, both
real costs the numeric types never pay (a numeric value decodes once, straight into the vector's
own flat buffer, with a native `<`/`>` for filtering). Native's own string-vector handling is
presumably more zero-copy (dictionary passthrough, fewer copies) — not confirmed by reading its
source, since the ask here was to compare and benchmark, not re-investigate the native
implementation; worth doing before optimizing this path further rather than guessing which copy
to cut.

**A separate, unrelated finding surfaced while isolating this result, worth flagging on its
own**: an *unfiltered* full-scan benchmark of the same two columns first looked far worse for
`read_zpq` (~1.09s vs native's ~0.14s, ~7.9x) — but that comparison wasn't apples-to-apples.
`duckdb_v2_table_function_set_projection_pushdown` exists and defaults to **false** (confirmed:
grepped this file for `projection` — zero matches, never called), so `read_zpq` always decodes
every column in `bind_data.cols` regardless of what the outer query's `SELECT` list actually
projects. A `SELECT count(*), sum(l_orderkey)` with no `l_comment` in the projection list means
native's `read_parquet` skips decoding `l_comment` entirely (hence its ~0.14s, matching the
single-BIGINT-column benchmarks elsewhere in this plan), while `read_zpq` decodes it uselessly
every time. This is pre-existing, present since Phase 1's multi-column work, not something this
VARCHAR filter work introduced or something VARCHAR-specific — but it would make any multi-
column `read_zpq` query that doesn't project every selected column look artificially slow next
to native, independent of per-type decode cost. Worth its own investigation and plan entry if
pursued; not attempted here, since conflating it with today's filter-pushdown work would muddy
which finding explains which number.

## Phase 2.8 (original scoping, for reference)

Currently declined outright: `recognize`'s switch over `phys` has `.varchar, .blob => return
null` (added defensively in Phase 2.7, before VARCHAR/BLOB itself even existed, anticipating
this). Not a crash risk — DuckDB's own executor applies a VARCHAR filter post-scan today, same
as any other declined filter — just an unbuilt optimization. Scoped now the same way as 1.6/2.7:
checked against the real code before committing to a design.

### Comparison semantics, verified against DuckDB's real source, not assumed

The one open question from the earlier "what about filter pushdown for VARCHAR?" discussion:
whether DuckDB's own (collation-less) VARCHAR comparison is a plain byte-wise order, matching
what `std.mem.order` would compute and what zpq's own `pruneBytes` stats-based pruning already
assumes. Checked directly in `duckdb/common/types/string_type.hpp`: `string_t`'s `operator>` (the
generic `GreaterThan::Operation<T>` template falls through to this — unlike `float`/`double`,
there is no specialization for strings) does a 4-byte prefix check as a fast path, then `memcmp`
over the shared length, breaking ties by length when the shared prefix matches. That's plain
lexicographic byte comparison — `memcmp` on raw bytes, no locale/Unicode normalization — and it
only changes if the VARCHAR type itself carries an explicit `COLLATE` annotation (a type
modifier set at the SQL level, not a global default), which a column read straight out of
Parquet never has. Confirms: (1) this matches `std.mem.order(u8, a, b)` exactly, so `evalFilter`
can use it directly; (2) zpq's `pruneBytes` (stats-based min/max byte-range pruning, already
dispatched from `ast.Filter.string`) is sound for this semantics too, with nothing to fix there.

### What's new

Row-group pruning needs nothing new — `ast.Filter` already has a `.string: Leaf([]const u8)`
variant, dispatched by `pruneRowGroup` to `pruneBytes`, and the AND/OR combinator already
verified (Phase 1.6) to handle mixed leaf types with no special-casing. Everything below is
about the per-row path and a genuinely new lifetime concern none of the other types had:

1. **`FilterValue` gains `.varchar: []const u8` — the first *owned, heap-allocated* filter
   value this file has.** Every existing variant (`bool`/`i32`/`i64`/`f32`/`f64`) is a plain
   scalar copied by value; a VARCHAR constant's bytes, from `duckdb_v2_value_get_varchar`, are
   only a *borrowed* view valid until `value_destroy` — which `pushdown` already calls on the
   constant before returning. So `recognize` must copy the bytes (`std.heap.c_allocator.dupe`,
   matching `copyArgString`'s own existing dupe-then-own pattern) into memory `BindData` owns.
2. **`destroyBindData` must free it** — walking `data.filters[0..data.filter_count]` for any
   `.varchar` entry and freeing its bytes. The first per-filter cleanup this file has needed;
   every filter before this was a plain scalar with nothing to free.
3. **`recognize`'s `.varchar, .blob => return null` arm becomes `.varchar => ...,
   `.blob => return null`,`** — `value_get_varchar` in place of a `value_get_*` scalar getter,
   duping the result. `.blob` stays declined (BLOB comparison pushdown isn't asked for here, and
   would need its own value-getter investigation — not assumed free just because VARCHAR works).
4. **`evalFilter` gains a `.varchar` arm reading through `v2_helpers.bytesSlice`, not a flat
   buffer.** VARCHAR/BLOB columns don't decode straight into a flat `[]const u8` vector buffer
   the way the numeric types do — `decodeColumn`'s own VARCHAR/BLOB branch boxes each row into
   the vector's `duckdb_v2_bytes` cell. By the time `filterAndCompactAll` runs, every column
   (including the filtered one, whatever its position) has already been decoded into its vector
   buffer — so the read is `bytesSlice(&cells[row])` (an existing helper, already used elsewhere
   in this project) to get a `[]const u8` view back out, then `std.mem.order(u8, got, want)`
   mapped onto `Eq`/`NotEq`/`Lt`/`LtEq`/`Gt`/`GtEq` the same way the numeric arm maps its own
   native operators.
5. **`claimNextRowGroup`'s AST leaf build gains a `.varchar` arm**: `.string = .{ .col_idx, .op,
   .value = spec.value.varchar }` (the borrowed bytes are fine here — the leaf's lifetime is
   just this one `pruneRowGroup` call, well within the filter's own longer-lived ownership).

### Validate with

A VARCHAR fixture with real ordering spread (not just equality-friendly values): a pushed-down
`Eq`, `Lt`, and `Gt` filter each matching native `read_parquet` exactly (the real test of the
byte-order claim above, not just that it compiles); row-group pruning actually skipping groups
for a sorted-by-value VARCHAR column (same `WHERE col < small_value` sanity check Phase 1.6/2.7
used); a VARCHAR filter combined with a numeric filter on a different column in one AND; and the
full regression suite once more, including the declined-filter crash guard (still exercised by
`.blob`, which stays declined) and a VARCHAR column with NULLs (a NULL never passes any
comparison, same semantics as every other type, but worth checking explicitly since this is the
first filterable type where "the row's own validity" and "the row's own value" are read through
two different mechanisms — `def_levels` vs `bytesSlice` — instead of one `[]T` array covering
both).

## Phase 2.9: projection pushdown (implemented, 2026-11-04)

Flagged as a separate, pre-existing finding in Phase 2.8's own benchmark writeup — `read_zpq`
never called `duckdb_v2_table_function_set_projection_pushdown`, so it always decoded every
selected column regardless of what the query's `SELECT` list actually needed. This closes it.

**A real design surprise, caught by testing live rather than assumed away**: the first, simpler
design — `local.projected` is just whatever `init_local_get_column_index` reports, 1:1 with the
output chunk's own vectors — looked right and built cleanly, but broke the very first test that
combined a filter with a non-projected column: `SELECT sum(id) FROM read_zpq(...) WHERE name <
'name_2'` (`name` filtered, never in the `SELECT` list) failed with `filtered column 1 is not in
the projected set` — a defensive check added specifically to catch this rather than silently
mis-filter if it ever happened, and it did, immediately. DuckDB does **not** automatically widen
the projected set to cover a filter it accepted pushdown for; from its side, that column is
"handled inside the scan" and never needs to come back out at all unless something else also
needs it.

**Fixed with a real redesign, not a patch**: `LocalState.projected` is now the *union* of what
DuckDB actually projects (`projected[0..output_count]`, in that order — exactly the output
chunk's own vector positions) and whatever extra declared columns a pushed-down filter needs but
the `SELECT` list doesn't (`projected[output_count..]`, appended by `initLocal`, decoded like any
other column but never handed a vector — `exec` only calls `duckdb_v2_data_chunk_get_vector` for
indices `< output_count`). `filterAndCompactAll` finds a filtered column's own slot via a new
`projectedPosOf` lookup (a linear scan over at most a handful of entries) instead of assuming
`declared_col` and `outs` share an index space.

**This also forced VARCHAR/BLOB boxing out of `decodeColumn` entirely, and it's a genuine
efficiency win, not just a refactor the redesign happened to need**: boxing used to happen
immediately after decode, for every row, into the vector's own `duckdb_v2_bytes` cells — but a
filter-only column has no vector to box into at all. Fixed by having `decodeColumn` always
decode VARCHAR/BLOB into a plain `local.arena`-owned `[]const u8` scratch array (uniform whether
projected or not — `evalFilter`/`moveElement` read/move that same shape either way, no more
`bytesSlice`-reading-a-vector-cell special case), and moving the actual `vector_get_arena` +
`makeBytesValue` boxing into `exec` itself, done once, after filtering has decided the final
`row_count` — so a row a filter discards never pays for a copy it didn't need, which the
*previous* (pre-projection-pushdown) design always did regardless of filtering.

Verified: the exact scenario that broke the first design (`WHERE name < 'name_2'`, `name` not
selected) now matches native exactly; the same for a filtered-but-unprojected *numeric* column;
`count(*)` (zero real projected columns, `initLocal`'s synthetic-driver fallback); a full
byte-level diff against native, unfiltered, every column; the cross-type misalignment check;
row-group pruning; `threads=1`/`24` with order preserved on the filtered-unprojected case. Full
prior regression suite (TPCH, `multi3`, nullable, declined-filter crash guard) re-run and still
passing.

**Benchmarked against the same real TPCH VARCHAR data as Phase 2.8**, same methodology:

| | `threads=1` before → after | `threads=24` before → after |
|---|---|---|
| unfiltered (only `l_orderkey` selected) | ~1.09s → **~0.10s** | — → ~0.02s |
| native `read_parquet`, same query | ~0.14s (unchanged) | ~0.02s (unchanged) |
| filtered on unprojected `l_comment` | ~1.29s → **~1.04s** | ~0.19s → ~0.16s |
| native `read_parquet`, same filtered query | ~0.89s (unchanged) | ~0.13s (unchanged) |

The unfiltered case goes from `read_zpq` being ~7-11x *slower* than native (decoding a column
nobody asked for) to being as fast or slightly faster — projection pushdown alone accounts for
this, confirming that finding's own diagnosis. The filtered case improves too (~19% faster at
`threads=1`, ~17% at `threads=24`) purely from no longer boxing rows a filter discards; native
is still ahead there (~1.16x, down from ~1.45x) — the remaining gap is Phase 2.8's own finding
(native's zero-copy string handling vs. this file's one real per-surviving-row copy), unrelated
to projection and not addressed by this change.

## Phase 2.10: DECIMAL (implemented, 2026-11-04)

Checked against zpq's actual `decimal.zig` and DuckDB's own real `decimal.hpp` before committing
to a design — same discipline as every other phase here, and this one turned up a real
correctness trap worth naming before any code gets written.

### The trap: zpq's own DECIMAL support is lossy, DuckDB's own DECIMAL type is not

`core/parquet/decimal.zig`'s own module doc comment is explicit about this, not something found
by surprise: it decodes every DECIMAL encoding (`INT32`/`INT64`/`FIXED_LEN_BYTE_ARRAY`/`BYTE_ARRAY`)
straight to `f64` — "reuses the existing `f64` column variant through filter/agg/expression
evaluators with zero new plumbing... The cost: f64 has ~15.95 decimal digits of precision; sums
over tens of millions of small-cent values may diverge from an exact Decimal engine." That's a
deliberate, acknowledged simplification on zpq's side — reasonable for zpq's own CLI output, but
checked directly against DuckDB's own `decimal.hpp` (`MAX_WIDTH_INT16`/`_INT32`/`_INT64`/`_INT128`):
DuckDB's `DECIMAL(p,s)` is an **exact** fixed-point integer, physically `i16`/`i32`/`i64`/`i128`
depending on precision, never a float. Decoding via zpq's `f64` path and declaring the result as
DuckDB's own `DECIMAL` type would silently misrepresent precision — exactly the kind of
correctness bug this project's own discipline exists to catch before it ships, not after. **Any
DECIMAL implementation must not reuse `core/parquet/decimal.zig`'s f64 conversion for output.**

### What's new, by physical backing — and why most of it is nearly free

Parquet's `DECIMAL` logical type sits on four physical encodings (per zpq's own doc comment):
`INT32` (≤9 digits), `INT64` (≤18 digits), `FIXED_LEN_BYTE_ARRAY` (≤38 digits), `BYTE_ARRAY`
(rare). The first two are nearly free, because the physical bits are *already* DuckDB's own
DECIMAL representation:

1. **`INT32`/`INT64`-backed DECIMAL reuses the existing wire-format readers, but not their
   direct-to-vector write (see item 4 below for why).** Per `decimal.zig`'s own doc comment,
   "INT32/INT64 backings still use parquet's standard little-endian fixed-width int wire format
   and only the *logical* interpretation differs (apply scale)" — the on-disk bytes are the exact
   same scaled integer DuckDB's own `DECIMAL(p,s)` would store for a precision that fits
   `i32`/`i64`. `bind` declares the output column via `helpers.createDecimalType(ctx, width,
   scale, ...)` (already present in `v2_helpers.zig`, unused until now) instead of
   `INTEGER`/`BIGINT`. `(precision, scale)` lives on `ResolvedColumn`, as planned — but
   `PhysicalType` ended up needing two new `Reader` variants after all (`.decimal32`/`.decimal64`,
   payload-identical to `.int32`/`.int64`), not just a field, once item 4's narrowing problem
   surfaced.
2. **`FIXED_LEN_BYTE_ARRAY`-backed DECIMAL (precision 10-38, needing `i128`) needs one real new
   function, not a new decode path.** FLBA bytes are big-endian two's-complement — the same raw
   bytes this PoC's existing `.blob`/`ColumnChunkReader([]const u8)` path already decodes
   correctly (zero-copy, per Phase 2's own investigation). **Correction (caught re-reading
   `decimal.zig` at implementation time, before writing any code against the claim below): zpq
   *does* expose this standalone, independent of its lossy `f64` path** — `pub fn
   flbaToI128(bytes: []const u8) i128` (big-endian, two's-complement, sign-extending,
   `bytes.len <= MAX_FLBA_BYTE_WIDTH == 16`) is reused directly rather than reimplemented. (zpq
   also has a higher-level `decodeColumnAsI128`/`decodeColumnAsI128WithOptions`, a one-shot
   whole-row-group decode via `filter_eval.ColumnT(i128)` — not used here: it doesn't fit this
   file's incremental per-batch `ColumnChunkReader(T).decode`/`decodeWithLevels` architecture, and
   `core/filter/eval.zig`'s own imports, while confirmed free of `io.*`/`core.scan`, are still a
   bigger dependency surface than the single low-level primitive actually needed.)
3. **Writing `i128` output: the hugeint/i128 bit-layout match is confirmed live, not just
   plausible.** `duckdb_v2_hugeint_t` (`{ lower: u64, upper: i64 }`) and Zig's native `i128` do
   share the same little-endian layout — verified by a dedicated unit test (`i128ToHugeint`/
   `hugeintToI128` round-trip, covering 0/1/-1/min/max/an arbitrary large value), not assumed
   from the struct's field order alone. One correction from the plan above: `@bitCast` directly
   between `i128` and the `extern struct` is rejected by the compiler (same bit size, not a
   bitcast-eligible pair) — `exec`'s boxing loop assembles/splits the struct by hand
   (`i128ToHugeint`/`hugeintToI128`) instead of a single `@bitCast`.
4. **A correctness gap the plan above didn't account for, found while implementing: Parquet's
   `INT32`/`INT64` physical backing does not always match DuckDB's own storage width for the
   declared precision.** A writer may back a small-precision DECIMAL (e.g. `DECIMAL(4,2)`, which
   DuckDB itself stores as `i16`) with Parquet's `INT32` physical type — reusing `.int32`'s
   existing "decode straight into the vector's own buffer" path for DECIMAL, as item 1 above
   proposed, would write 4-byte strides into what might be a 2-byte-wide vector buffer. Fixed by
   giving DECIMAL its own three `PhysicalType` tags (`.decimal32`/`.decimal64`/`.decimal128`) that
   always decode to a uniform `i128` scratch (reusing the existing `ColumnChunkReader(i32)`/`(i64)`/
   `([]const u8)` wire-format readers, just not their direct-to-vector write), then narrow into
   whichever native width `decimalStorageWidth(precision)` says DuckDB actually allocated — the
   same "decode to a uniform type, box into the real vector shape last" split VARCHAR/BLOB already
   use for `duckdb_v2_bytes`, applied here for a runtime-variable integer width instead of a
   variable-length byte array.
5. **`BYTE_ARRAY`-backed DECIMAL stays explicitly deferred within this item** — zpq's own doc
   comment calls it "rare," and it is a variable-length version of the same big-endian-bytes
   problem item 2 already solves; not worth the extra case until a real file needs it.
6. **Filter pushdown on a DECIMAL column is explicitly not part of this item** — same pattern
   VARCHAR followed (Phase 2 item 4 landed before Phase 2.8 added its own pushdown): land the
   type correctly first, consider pushdown as a later, separate phase once there's a value type
   (`i128`-based comparison, not reusing any existing `FilterValue` arm) worth designing for.

### Validated with (2026-11-04)

A real fixture via `COPY ... TO PARQUET` (10,000 rows, `range(1, 10001)`): `DECIMAL(4,2)` →
INT32, `DECIMAL(12,3)` → INT64, `DECIMAL(30,6)` → FIXED_LEN_BYTE_ARRAY (confirmed via
`parquet_schema()`, not assumed from the declared SQL type), plus a nullable INT32-backed column
(`i % 7 = 0` → NULL) to exercise validity alongside narrowing. `read_zpq`'s default (no explicit
`schema` argument) output diffed against native `read_parquet`'s own DECIMAL output both
directions (`EXCEPT` each way) — zero mismatches across all 10,000 rows and all four DECIMAL
columns, exact equality (not epsilon), confirming no float-precision loss snuck back in via the
`f64` trap this item opened by naming. The hugeint/i128 bit-layout claim and the
`decimalStorageWidth` threshold table each got their own dedicated unit test (see
`src/ext/init_v2_poc_zpq.zig`'s own `test` blocks, run via `zig build test-v2-poc-zpq` — this
file has no test step wired into `zig build test`, isolated by design like the rest of this PoC)
rather than trusting the real-file round-trip alone to have caught a layout mismatch that could
coincidentally still produce the right bytes for small values. `BYTE_ARRAY`-backed DECIMAL,
INT96-backed DECIMAL, and filter pushdown on any DECIMAL column remain deferred, per items 5-6
above — `physicalTypeOf` returns `null` for them rather than silently misreading them as BLOB.

**Benchmarked** (10M rows, `threads=1`, `-no-agent`): a DECIMAL64 column (`d_mid`) costs roughly
2.4x a plain BIGINT column of the same cardinality (0.426s vs an equivalent-sized plain INT64
column scaled from a 30M-row baseline, ~0.18s) — the extra widen-to-`i128` decode pass plus the
narrow-at-box-time pass this item's design needs. **Separately, and not something this item
introduced**: that plain-INT64 baseline itself is currently ~4x behind native `read_parquet`
(0.537s vs 0.138s on the 30M-row fixture) — a real gap from the current state of this PoC's
single-threaded per-column decode after multi-column/filter/projection-pushdown were added, stale
relative to the module doc comment's older "tuned to parity... both at 0.06s" claim (written
before any of that existed). Worth a dedicated look if single-threaded throughput becomes a goal
again, but out of scope for this item specifically.

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
