# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
zig build                    # debug build → zig-out/lib/zig_ext.duckdb_extension
zig build -Doptimize=ReleaseSafe  # release build
zig build test               # run all unit tests
task check:all               # format + build + unit tests (MUST pass before every commit)
task sqllogictest            # end-to-end SQL tests against the real v1 extension (test/sql/zig_ext.test)
task sqllogictest:v2         # same, against the real v2 extension (test/sql/zig_ext_v2.test)
task bench                   # benchmark hand-written vs comptime implementations
task audit                   # check for compiler warnings and deprecated patterns
task format                  # zig fmt src/
task clean                   # remove build artifacts
```

To load the extension manually:
```sh
duckdb -unsigned -c "LOAD 'zig-out/lib/zig_ext.duckdb_extension'; SELECT zig_hello('world');"
```

## Architecture

### Module layout

```
src/
  root.zig          — shared-lib root; re-exports ext entry point, exposes submodules for test
  ext/init.zig      — DuckDB entry point: zig_ext_init_c_api; registers all functions at load time
  functions/        — individual scalar/table function implementations
  lib/duckdb.zig    — thin Zig wrappers around the vendored DuckDB C API
  lib/comptime_scalar.zig — comptime framework: generates vectorized callbacks from per-row fns
  lib/comptime_table.zig  — comptime framework: generates table function boilerplate
build.zig           — builds shared lib + runs post-build metadata appender → .duckdb_extension
```

DuckDB's C API headers (`duckdb.h`/`duckdb_extension.h` for v1,
`duckdb_v2.h`/`duckdb_extension_v2.h` for v2) aren't committed locally —
they're fetched as content-hash-pinned `build.zig.zon` dependencies
(v1.5.6's real tagged release; the exact commit the staged v2 alpha CLI
itself reports) and translated at build time via `b.addTranslateC`.

### Extension entry point

DuckDB calls `zig_ext_init_c_api` (exported from `src/ext/init.zig`). It calls `db.initApi` to get the C API vtable, opens a connection, then calls each function module's `register(conn)`. All registrations happen synchronously at init — no lazy registration.

### Comptime function framework

`src/lib/comptime_scalar.zig` uses `@typeInfo` to introspect a per-row Zig function at compile time and generate a vectorized callback with fast-path (no NULLs) and slow-path (NULL propagation). Zero runtime overhead — benchmarks identically to hand-written code.

To add a comptime scalar function:
```zig
const comptime_scalar = @import("lib/comptime_scalar.zig");
fn myFn(a: i64) i64 { return a * 2; }
const MyFn = comptime_scalar.Function("sql_name", myFn);
pub fn register(conn: db.Connection) !void { return MyFn.register(conn); }
```

Supported types: `i8`, `i16`, `i32`, `i64`, `f32`, `f64`, `bool`.

### Build pipeline

`build.zig` produces two artifacts: (1) the shared `.so` library, (2) a host-native `append_metadata` executable that appends extension version metadata, producing the final `.duckdb_extension` file installed into `zig-out/lib/`.

### Rule system

Read `rules/INDEX.yaml` at the start of every task to identify which rule files apply to the files you're modifying:
- `**/*.zig` → `rules/specifics/zig.md`
- `**/*.zig` with `@cImport` → `rules/concerns/c-interop-safety.md`
- `build.zig` → `rules/specifics/build-zig.md`
- `src/ext/**/*.zig` → `rules/specifics/duckdb-ext.md`
- Always load: `.reins/rules/principles/quality.md`

## Key conventions

**Memory**: Pass allocators explicitly; use `defer`/`errdefer` for all cleanup; never leak on error paths. Choose `ArenaAllocator` for request-scoped work, `std.heap.DebugAllocator` for long-lived allocations (`GeneralPurposeAllocator` was removed in Zig 0.17 — `DebugAllocator` is its direct successor; `SafeAllocator`, new in 0.17, wraps safety checks around an arbitrary backing allocator instead).

**C interop**: Every `@ptrCast`/`@alignCast` at the C boundary requires a `// SAFETY:` comment. DuckDB owns memory it allocates; Zig owns memory it allocates — never cross ownership boundaries. Strings to C must be null-terminated (`[:0]const u8`).

**Error handling**: No `catch unreachable` in non-test code; no panics in extension code — convert Zig errors to DuckDB error results at the boundary via `access.set_error`.

**Vectorized execution**: All functions process entire `DataChunk`s, not row-at-a-time. The inner loop caches raw data pointers and validity masks before iterating rows.

**VARCHAR vectors**: `duckdb_string_t` uses a 12-byte inline buffer for short strings and a heap pointer for longer ones. Always branch on `str_t.value.inlined.length <= 12` — see `functions/hello.zig` for the canonical decode pattern.

**Named parameters via SQL macro**: The DuckDB C API has no named-parameter support for scalar functions. Provide named params and defaults by registering a `CREATE OR REPLACE MACRO` wrapper at init time via `db.query(conn, sql, &result)`. The Zig scalar is registered as `fn_impl`; the macro is registered as `fn`. See `functions/tp_bar.zig` for the pattern.

**Table function cardinality hints**: Call `db.bindSetCardinality(info, estimated_rows, false)` in the bind callback when the row count is knowable. Without this, DuckDB cannot push down `LIMIT` into the scan, so `SELECT ... LIMIT 1` will still evaluate all rows.

**Tests**: Use `std.testing` in `test` blocks within the same file as the code under test. Run `task check:all` before every commit.

**Commits**: Conventional Commits (`feat`, `fix`, `refactor`, etc.). Separate structural from behavioral changes (Tidy First). Run `task check:all` and ensure zero warnings before committing.

## Zig 0.17 `std.Io`, v2 PoC gotchas, and benchmarking conventions

Learned on `zpq-parquet-poc-main` (`src/ext/init_v2_poc_zpq.zig`, a DuckDB v2 table function built
on `chicagobuss/zpq`'s low-level Parquet surface); see ADR-0009 for the full writeup and ADR-0003
sections 9-12 for the durable v2-C-API facts pulled out of it.

**`std.Io.Threaded.global_single_threaded.io()` is safe to share across real OS threads for
positioned file I/O.** `fileReadPositional`/clock `now()` both discard their `userdata` and go
straight to a stateless syscall (`pread`/`preadv`, `clock_gettime`) — confirmed by reading
`std/Io/Threaded.zig` directly, not assumed. `pread` takes its offset as an explicit argument
rather than racing on the fd's shared cursor, so one open file handle, read concurrently by every
thread of a scan, needs no locking. Zig 0.17 has no `std.time.Timer` any more — use
`std.Io.Timestamp.now(io, .awake)` + `.nanoseconds` subtraction instead.

**`zio` (this project's other, io_uring-based `std.Io`, `src/ext/init_v2_poc_zio.zig`) is not a
drop-in swap for `std.Io.Threaded` when the caller is a plain OS thread DuckDB itself spawned**
(e.g. a table function's `exec`, called directly by DuckDB v2's thread pool). `zio`'s `waitForIo`
only uses its event loop inside a zio-managed coroutine; otherwise it falls back to the same
synchronous `pread`, just with extra `Completion`/`Waiter` overhead. Only worth it if `zio`'s own
runtime — not DuckDB's — drives the parallelism.

**Reading a Parquet footer without the whole file**: `zpq`'s `metadata.openFooter`/
`hasEncryptedFooter`/`hasLeadingMagic` are built for exactly "footer bytes fetched separately from
the full file body" (their own doc comments name the S3-range-read case). Read the trailing
8 bytes (4-byte little-endian footer length + "PAR1" magic) to learn the footer's size and
location, then read exactly that many bytes — two or three small positioned reads regardless of
file size, instead of `readFileAlloc`-ing everything. A `BindData` built this way keeps an open
`std.Io.File` instead of a whole-file buffer, and each row group's bytes get a positioned read on
demand at decode time.

**A table function's batch size above `STANDARD_VECTOR_SIZE` (2048) is only safe when every
filter is either absent or actually pushed down and accepted.** A larger `vector_set_size` crashes
DuckDB (`Vector::SetSize out of range`) the moment a filter gets *declined* and DuckDB's own
executor applies it after the scan — the FILTER operator it inserts ties the scan's own chunk to
2048 regardless of what was reserved. Test any batch size larger than 2048 against a
declined-filter query specifically, not just no-filter/accepted-filter cases — they're not
equivalent, and this one took a multi-column prototype's forced pushdown-decline to actually
surface (see ADR-0009's addendum).

**Benchmarking this CLI build**: always pass `-no-agent`. Without it, the CLI's own
`AI_AGENT`-triggered "agent mode" (it prints a row-count estimate per query) runs a hidden second
planning pass, so `bind` gets called twice per query — an artifact of this test harness, not a
real DuckDB v2 engine cost, and easy to mistake for one (it was, once, before being caught and
corrected). `.timer on` dot-commands only work when SQL is fed via stdin (`duckdb ... < script.sql`),
not via `-c` (which parses the whole argument as one SQL blob and errors on dot-commands). The
`tpch` extension's `CALL dbgen(sf=N)` + `COPY (...) TO '...parquet' (FORMAT PARQUET, ROW_GROUP_SIZE
n)` makes realistic multi-row-group fixtures for this kind of work, preferred over synthetic
`range()` data once correctness is established.

## Architecture decision records

`docs/rationale/` holds ADRs numbered `000n_<slug>.md`:
- ADR-0001: Why Zig over C++ (direct `@cImport`, no ABI coupling to DuckDB C++ internals)
- ADR-0002: Comptime registration — zero-cost vs hand-written (identical machine code, 3× less boilerplate)
- ADR-0003: DuckDB v2 C API shape differences from v1 (calling convention, type construction,
  state lifecycle, VARCHAR shapes, nested-type access, named parameters, batched aggregates,
  static linking; sections 9-12 added for value-level nested-type introspection,
  `create_type_from_text`, the absent bind-data serialize hook, and multi-vector batch sizing)
- ADR-0004: Extension distribution and signing (skip extension-ci-tools' Make/CMake/S3 pipeline)
- ADR-0005: Making the repo a Zig package for extension authors (modules + build functions + template)
- ADR-0006: Proposed sqllogictest runner improvements (error attribution, partial runs, JSON unescaping) — mostly unimplemented
- ADR-0007: Generated (not hand-written) v2 C API bindings, static and dynamic backends
- ADR-0008: A separate, opt-in `wasm32-emscripten` `SIDE_MODULE` build step
- ADR-0009: `read_zpq` PoC — DuckDB-v2-threading over zpq's own `core.scan` engine; footer-only
  `bind` + positioned-read-on-demand `exec` over a whole-file `readFileAlloc`
