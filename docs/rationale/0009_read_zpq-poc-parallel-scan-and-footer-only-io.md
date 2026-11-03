# 0009 — read_zpq PoC: parallel row-group scanning and footer-only I/O

## Status

Accepted (for the PoC's own scope — see ADR-0003 for the general v2 C API facts this work also
surfaced, filed there instead of here since they're not specific to this function).

## Context

`src/ext/init_v2_poc_zpq.zig`, on branch `zpq-parquet-poc-main`, registers `read_zpq(path,
column)`, a DuckDB v2 table function built directly on the `chicagobuss/zpq` Zig Parquet
library's low-level `core.parquet`/`core.filter` surface (footer parsing, per-column-chunk
decode, row-group pruning) — not its `core.scan` aggregate-pipeline engine, and not its `io.*`
(S3/TLS/epoll) surface. Two design questions came up that are worth recording for whoever
continues this PoC (`PLAN-zpq-parallel.md`, `PLAN-zpq-multi.md`) or writes the next zpq-backed
function:

1. How should `read_zpq` get its parallelism — reuse zpq's own engine, or build on DuckDB v2's
   own table-function threading?
2. Should `bind` read the whole file into memory, or only what it needs?

## Decision

### 1. Parallelism: DuckDB v2's own thread-per-`init_local` pattern, not zpq's `core.scan`

Checked `engine.zig`'s own doc comment and export surface directly, not assumed: it is zpq's own
CLI/Lambda-level orchestration ("input dispatch, parallel fetch, decode, scan, output", ending in
`core.scan.runMultiAggregate`), with its own thread pool, memory-budget machinery, and S3/local
"parallel fetch". Reusing it would mean pulling in the same `io.*`/BoringSSL surface this PoC
deliberately avoids (confirmed: `io.*` never actually compiles from this file alone, per
`build.zig.zon`'s own `.zpq` comment).

Instead, `read_zpq` uses the same DuckDB-v2-threading shape this project already built and
verified for `zig_cookbook_parallel_range` (`src/cookbook/table_callbacks.zig`):
`init_global_set_max_threads(N)` (an upper bound — `@min(cpu_count, row_group_count)`, since more
threads than row groups is wasted dispatch), a per-thread `LocalState` via `init_local`, an
atomic `next_rg: std.atomic.Value(usize)` claim counter in `GlobalState` (every row group index
claimed by exactly one thread via `fetchAdd`, no locking needed anywhere in `exec`), and
`partition_data`/`set_batch_index` reporting the claimed row-group index as the batch index to
keep output in file order under `preserve_insertion_order`. See `PLAN-zpq-parallel.md` for the
full validation matrix (correctness at several thread counts, order preservation, filtered +
parallel interaction) and the benchmark numbers.

**Profiling note, since it very nearly became a wrong permanent record**: an early profiling
pass measured `read_zpq` scaling only 2.7x going 1→24 threads, versus native `read_parquet`'s
5.6x, and (after ruling out dispatch overhead inside `exec` itself — confirmed negligible, under
2%, via in-process atomic/timing instrumentation) attributed the gap to `bind` being called
*twice* per query, blaming DuckDB v2's engine. That was wrong, and caught before it was written
down as fact: a one-line counter inside `bind`, rebuilt and re-run with and without the test
CLI's own `-no-agent` flag, showed the double call was this harness's `AI_AGENT`-triggered "agent
mode" (a hidden second planning pass to print a row-count estimate) — a real end-user session
calls `bind` once. **Lesson for future profiling in this harness: always benchmark with
`-no-agent`, or any apparent "called twice" / extra-planning-pass artifact may not be real.**

### 2. `bind` reads only the footer; `exec` reads each row group's bytes on demand

Originally `bind` read the whole file into one heap buffer via `readFileAlloc`, and `exec`/
`claimNextRowGroup` sliced row-group byte ranges out of it for free (no I/O at decode time). This
was simple and correct, but turned out to be the actual bottleneck behind the 2.7x-vs-5.6x gap
above: `readFileAlloc`'s cost (~13-16ms on a 46MB SF=5 TPCH fixture) is a **fixed, serial, per-
query cost that does not shrink with more threads** — a growing fraction of wall time as thread
count rises (Amdahl's law), while native `read_parquet`'s own `bind` only ever touches the
footer and stays cheap regardless of thread count. (Checked whether native instead avoids a
would-be rebind via DuckDB's `TableFunction::serialize`/`deserialize` bind-data hooks — it
doesn't, and the v2 C API doesn't even expose that hook; what actually makes native cheap is
simply that its `bind` never reads the whole file.)

Fixed by reading only the footer at bind time: the trailing 8-byte length+magic field, the
leading 4-byte magic, then exactly the footer itself — three small positioned reads via
`std.Io.File.readPositionalAll`, regardless of file size — using zpq's own
`metadata.openFooter`/`hasEncryptedFooter`/`hasLeadingMagic`, which are built for exactly this
"footer fetched separately from the full file body" shape (their own doc comments name the
S3-range-read case explicitly; a local file's tail read is the same shape, just fetched with
`pread` instead of a ranged GET). `BindData` keeps one open `std.Io.File` instead of the whole
file in memory; `claimNextRowGroup` now does a positioned read of each row group's own
column-chunk byte range on demand, off that one shared file handle.

**Why sharing one file handle across threads for `pread` needs no locking** (verified by reading
`std/Io/Threaded.zig` directly, not assumed): `fileReadPositional` discards its `userdata`
entirely and calls `pread`/`preadv` straight through — no shared mutable state touched — and
POSIX `pread` takes its offset as an explicit argument rather than racing on the fd's shared
cursor the way plain `read` would. `std.Io.File`'s own doc comment says as much: "Positional is
more threadsafe, since the global seek position is not affected."

**Why `zio` (this project's other, io_uring-based `std.Io` implementation, see
`src/ext/init_v2_poc_zio.zig`) wasn't used here instead**, despite being a "more performant"
`Io`: its `waitForIo` only engages the event loop when the calling code is running inside a
zio-managed coroutine; called from a plain OS thread (exactly `exec`'s situation — DuckDB v2's
own thread pool calls it directly) it falls back to the same synchronous `pread`, just with
`Completion`/`Waiter` overhead on top for no benefit. zio would only pay off if `read_zpq` were
restructured so zio's own runtime, not DuckDB's `init_global_set_max_threads`/`init_local`,
drove the scan's parallelism — a materially different architecture, not attempted here.

Result: 1→24 thread speedup went from 2.7x to ~5.3x, close to native's 5.6x.

## Consequences

- **Positive**: no whole-file-in-memory ceiling (`max_file_bytes` is gone — deleted along with
  the `readFileAlloc` it guarded); lower peak memory; the remaining `bind` cost is now
  proportional to schema size, not file size.
- **Negative**: `claimNextRowGroup` now does real I/O that can fail (OOM allocating the read
  buffer, a short/failed read) — unlike the old free slice, these are genuine new failure modes,
  reported through `fail(err, ...)` rather than silently skipped the way a malformed-metadata row
  group is.
- Any future zpq-backed function that needs to read column-chunk bytes should follow this same
  "footer-only bind, positioned-read-on-demand exec" shape rather than re-introducing a
  whole-file read, and should benchmark with `-no-agent` from the start.
