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
