# Plan: parallel row-group scanning for read_zpq

Current state (`src/ext/init_v2_poc_zpq.zig`): single-threaded. `GlobalState` holds one shared
`arena`, one `reader: ?ColumnChunkReader(i64)`, one `rg_idx` — `exec` is called repeatedly on
whatever thread DuckDB happens to use, and `openNextRowGroup` always advances the same shared
cursor. There is no `init_local` callback and no `partition_data`/batch-index reporting at all.

This doc is a plan, not an implementation — scoping what parallelizing this actually requires,
and explicitly ruling out the wrong way to do it, before touching code.

## The wrong way: reusing zpq's own engine-level parallelism

Checked `engine.zig`'s own doc comment and export surface directly, not assumed. Its own words:
"input dispatch, **parallel fetch**, decode, scan, output" lives there, ending in
`core.scan.runMultiAggregate`. That is zpq's *own* orchestration layer — a scan→consumer protocol
(`core/consumer.zig`: "Per-RG scan→consumer protocol (decode+filter+encode)") feeding zpq's own
`AggResult`/`QueryResult`/output types, with its own thread pool and memory-budget machinery.
It is not a standalone "decode N row groups in parallel" primitive this PoC could borrow — using
it would mean pulling in the same `io.*`/BoringSSL surface `build.zig.zon`'s own `.zpq` comment
confirms this PoC currently never reaches. Not pursued.

## The right way: DuckDB's own v2 table-function threading

Same pattern this project already built and verified for `zig_cookbook_parallel_range`/
`zig_cookbook_range` (`src/cookbook/table_callbacks.zig`, `src/cookbook/table_pushdown.zig`):
`init_global_set_max_threads(N)`, a per-thread `LocalState` via `init_local`, and
`partition_data`/`set_batch_index` to keep output in file order under `preserve_insertion_order`.
It maps onto this code almost as-is, because the pieces that need to move are already shaped
right for it:

1. **`GlobalState` shrinks to a shared, read-only `bind_data` plus one atomic row-group claim
   counter** (`std.atomic.Value(usize)`, replacing the plain `rg_idx: usize`). Nothing else needs
   to be shared: `ColumnChunkReader(i64)` is already constructed fresh per row group with no
   state carried from the previous one, so there is nothing to synchronize beyond "which row
   group does this thread claim next" — `fetchAdd(1, .monotonic)` is enough, the same primitive
   `zig_cookbook_parallel_range`'s `GlobalState.next_block` already uses.
2. **`arena`/`reader`/`row_group_always_match`/`done` move to a new `LocalState`**, one per
   thread, built in a new `init_local` callback. Each thread decodes only the row groups it
   claims, into its own output chunk — no cross-thread access to any of these fields, so no
   locking anywhere in `exec` itself.
3. **`bind_data.file_bytes` already supports this for free.** It is one immutable slice; every
   thread reads a disjoint byte range out of it (each row group's own `chunk_bytes` slice) with
   no overlap and no mutation — the same "shared read-only data, disjoint ranges, no
   synchronization needed" shape this project's matmul row-split work already established.
4. **`openNextRowGroup` becomes `claimNextRowGroup(local: *LocalState, global: *GlobalState,
   bind_data: *const BindData)`**: claim the next index via `fetchAdd`, bounds-check against
   `bind_data.meta.row_groups.items.len`, then the rest of today's function body (prune check,
   byte-range slicing, `ColumnChunkReader.init`) is unchanged, just writing into `local.*`
   instead of `state.*`.
5. **`partition_data`**: report `local.block` (the claimed row-group index) as the batch index —
   row groups already have a well-defined, stable order in the file (`meta.row_groups.items`),
   so the index *is* the natural batch index, no separate counter needed. Required if
   `preserve_insertion_order` should keep rows in file order across threads; if the caller is
   fine with `read_parquet`-style unordered output, this step is skippable (document the choice
   either way, don't default to one silently).
6. **`max_threads`**: a reasonable default is "number of row groups, capped at the CPU count" —
   more threads than row groups is wasted dispatch (the same lesson the matmul row-split
   benchmarking already learned: dispatch overhead dominates once a thread's share of the work
   is too small). `bind` already knows `meta.row_groups.items.len` by the time `init_global`
   runs, so this is a straightforward `@min(cpu_count, row_group_count)`, not a guess.

### What does NOT need to change

- `BindData`, `resolveSupportedColumn`, the filter-pushdown recognizer (`recognize`/`pushdown`)
  — all already per-query, read-only after `bind`, safe to share across threads unmodified.
  `FilterSpec`/`filters`/`filter_count` are read-only once `bind` returns (pushdown only runs
  during planning, before any thread starts scanning).
- `writeValidityBits`, `filterCompact`, `evalFilters` — pure functions over per-call buffers
  already; nothing about making `exec` run on multiple threads changes what happens inside one
  call to them.
- The whole-file-in-memory approach (`bind`'s `readFileAlloc`) — orthogonal to this plan. Still
  a real limitation (see `PLAN-zpq-multi.md`'s sibling concerns), just not one parallelism
  changes either way: every thread already reads from the same in-memory `file_bytes`.

## Validate with

A multi-row-group fixture (at least 3 row groups, large enough that single-threaded vs.
`max_threads > 1` actually produces a measurable wall-clock difference — the matmul
cache-blocking work this session already found that "more threads" can lose to serial when a
thread's share of the work is small, so this needs a real fixture, not just "it runs"). Check,
in order:
1. **Correctness first**: full-scan row count and values match the single-threaded path exactly,
   at `max_threads` = 1, 2, and more threads than row groups (exercises the claim-counter's
   bounds check cleanly running out).
2. **Order**, if `partition_data` is wired: `SELECT * FROM read_zpq(...)` returns rows
   in the same order as today's single-threaded version, with `preserve_insertion_order` at its
   default.
3. **Filtered + parallel together**: a pushed-down filter that prunes some row groups entirely
   and leaves others needing the per-row recheck, run at `max_threads > 1` — the row-group-level
   `row_group_always_match` decision and the `SelectionVector` compaction are both still
   per-thread-local state under this plan, so this should Just Work, but is exactly the kind of
   interaction worth a dedicated test rather than assuming from the individual pieces working.

## Implemented and benchmarked (done, 2026-11-03)

All three validation steps above passed, re-checked against a real 30M-row, 60-row-group file
generated by the real `tpch` extension's `dbgen`, column `l_orderkey` — not a synthetic
`range()` fixture. `SUM(value)` (forces full decode on both sides) against the pinned v2.0.0
CLI's own native `read_parquet`, same session, repeated runs for stability:

| | `threads=1` | `threads=24` | speedup (1->24) |
|---|---|---|---|
| native `read_parquet` | 0.144-0.146s | 0.026-0.027s | **5.6x** |
| `read_zpq` | 0.121-0.126s | 0.044-0.046s | **2.7x** |

Single-threaded, `read_zpq` is actually ~1.2x *faster* than native — a single hardcoded INT64
column with a tight, specialized decode loop straight into the output vector has no general
type-dispatch cost to pay. But its parallel scaling is weaker (2.7x vs 5.6x going 1->24
threads), so native ends up ~1.7x ahead at full parallelism.

**Follow-up tried: larger batches per `exec` call** (`max_rows_per_batch`: 2048 -> 122880, see
that constant's own doc comment for why 122880 specifically). Hypothesis: per-call decode
overhead inside zpq (page/dictionary setup, bounds checks) was a bigger fraction of the work at
2048 rows/call than at row-group granularity, so fewer/bigger calls should amortize it. Tested,
not assumed: correctness, row order, and filtered-row counts all still match exactly at this
size — but it made **no measurable difference** to wall-clock time or `user` CPU time at either
thread count. So per-call decode overhead was never the bottleneck; whatever explains the
weaker 1->24 scaling is somewhere else — plausibly how the engine schedules/dispatches `exec`
calls across the claimed threads, not in this file's own decode loop. Kept at 122880 anyway
(still correct, still fewer round-trips), but this specific fix attempt didn't pan out.
**Profiled where the scaling gap actually comes from.** `perf record` is blocked on this machine
(`perf_event_paranoid=4`, needs a privileged sysctl change not made here), so profiled via direct
in-process instrumentation instead: atomic counters for `init_local` calls (threads actually
spun up), `exec` call count and total time, and time specifically inside `decode`/
`decodeWithLevels`, plus separate timing around `bind`'s `readFileAlloc` and footer parse —
temporary code, reverted after collecting the numbers below.

Against the same SF=5 fixture:

| | `threads=1` | `threads=24` |
|---|---|---|
| wall time | ~0.120-0.131s | ~0.048-0.051s |
| `bind` (whole-file `readFileAlloc`) | ~13-16ms | ~13-16ms (unchanged) |
| summed `exec` time across all threads | ~72-75ms | ~280-313ms (÷24 threads ≈ 12-13ms wall-equivalent) |
| time inside `exec` NOT spent in `decode`/`decodeWithLevels` | <1ms | 2-17ms |

(Benchmarked via this project's `~/.duckdb/cli/2.0.0/duckdb`. **Correction**: an earlier pass of
this measurement, run without `-no-agent`, saw `bind` called twice per query and reported it as
a DuckDB-v2-engine property. Checked directly — rebuilt with a one-line counter inside `bind`,
ran the same query with and without `-no-agent` — and it's actually this CLI build's own
`AI_AGENT`-triggered "agent mode" (prints a row-count estimate per query, see its own
`-no-agent`/`.help agent` banner) silently doing a second planning pass. A real end-user session,
with no `AI_AGENT` env var set, calls `bind` exactly once per query. Not a real cost to engineer
around; the table above and the `bind` cost below are both single-call numbers.)

Two things fall out of real numbers, not guesses: (1) dispatch overhead inside our own `exec` is
negligible at any thread count — under 2% of `exec`'s own time is spent on anything other than
`decode`/`decodeWithLevels` (vector/validity API calls, filter compaction, claiming the next row
group). The weaker scaling is not caused by anything in this file's per-call dispatch path.
(2) `bind`'s whole-file `readFileAlloc` is a **fixed, serial, per-query cost that does not shrink
with more threads** — same ~13-16ms at `threads=1` and `threads=24`. At `threads=1` that's
~11% of wall time; at `threads=24` it's roughly a quarter to a third of wall time and the single
biggest piece DuckDB itself doesn't parallelize, which is a real contributor to the Amdahl's-law
reason `read_zpq`'s speedup caps out lower than native `read_parquet`'s. (Checked whether native
sidesteps this via DuckDB's `TableFunction::serialize`/`deserialize` bind-data hooks — it
doesn't; neither the v2 C API nor DuckDB's own `MultiFileFunction` framework that backs
`read_parquet` wires those up. What actually differs is that native's own `bind` only touches
the Parquet footer, never the whole file, so *each* call is cheap regardless of how many times
the engine makes it.) Closing this gap means moving away from "read the whole file into memory
up front" toward reading only the footer at bind time, then only the row-group byte ranges each
thread actually needs during `exec` (same shape `PLAN-zpq-multi.md` already flags as a separate,
real limitation).

**Implemented.** `bind` now reads only the trailing 8-byte length+magic field, the leading
4-byte magic, and exactly the footer itself (three small `pread`-style positioned reads via
`std.Io.File.readPositionalAll`, regardless of file size) instead of `readFileAlloc`-ing the
whole file — `zpq`'s own `metadata.openFooter`/`hasEncryptedFooter`/`hasLeadingMagic` are built
for exactly this "footer fetched separately from the full file body" shape (its own doc comment
names the S3-range-read case; a local file's tail read is the same shape). `BindData` keeps one
open `std.Io.File` instead of the whole-file buffer; `claimNextRowGroup` now does a positioned
read of each row group's own column-chunk byte range on demand, off that one shared file handle
— safe with no locking, confirmed by reading `Threaded.zig`'s `fileReadPositional`: it discards
its `userdata` and calls `pread`/`preadv` directly, and POSIX `pread` takes its offset as an
explicit argument rather than racing on the fd's shared cursor the way plain `read` would (also
checked `zio`, in case its io_uring-based `Io` would do better here: its own `waitForIo` falls
back to a synchronous `pread` whenever the caller isn't already running inside a zio-managed
coroutine, which `exec` — called directly by DuckDB v2's own thread pool — never is, so it would
only add `Completion`/`Waiter` overhead over `std.Io.Threaded` for no benefit; not used).

Re-benchmarked the same way (SF=5 TPCH fixture, `-no-agent` to avoid the CLI agent-mode artifact
noted above):

| | `threads=1` | `threads=24` | speedup (1->24) |
|---|---|---|---|
| before this fix | ~0.120-0.131s | ~0.048-0.051s | 2.7x |
| after this fix | ~0.095-0.101s | ~0.018-0.037s | **~5.3x** |

Now close to native `read_parquet`'s 5.6x, as expected once the one fixed serial cost was
removed. Re-verified correctness, filtered+parallel interaction, the `max_threads`-clamp edge
case (2-row-group fixture), NULL handling, order preservation (byte-identical CSV diff against
native at `threads=24`), and both new error paths (bad magic, missing file) — all still correct.

## Explicitly out of scope for this plan

**Reading from stdin, or any non-seekable input.** Deferred separately — Parquet's footer-at-
the-end layout needs random access, which stdin does not give without buffering the whole input
first; not a parallelism question at all, kept out of this doc on purpose.

**Multi-column/multi-type support** — `PLAN-zpq-multi.md`'s own scope, independent of this one.
The two interact only superficially (both touch `GlobalState`/`LocalState` shape), and
`PLAN-zpq-multi.md` already names which order to do them in if both are wanted.
