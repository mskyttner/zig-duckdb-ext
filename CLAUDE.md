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
duckdb_capi/        — vendored DuckDB C headers (v1.2.0); consumed via @cImport
build.zig           — builds shared lib + runs post-build metadata appender → .duckdb_extension
```

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

**Memory**: Pass allocators explicitly; use `defer`/`errdefer` for all cleanup; never leak on error paths. Choose `ArenaAllocator` for request-scoped work, `GeneralPurposeAllocator` for long-lived allocations.

**C interop**: Every `@ptrCast`/`@alignCast` at the C boundary requires a `// SAFETY:` comment. DuckDB owns memory it allocates; Zig owns memory it allocates — never cross ownership boundaries. Strings to C must be null-terminated (`[:0]const u8`).

**Error handling**: No `catch unreachable` in non-test code; no panics in extension code — convert Zig errors to DuckDB error results at the boundary via `access.set_error`.

**Vectorized execution**: All functions process entire `DataChunk`s, not row-at-a-time. The inner loop caches raw data pointers and validity masks before iterating rows.

**VARCHAR vectors**: `duckdb_string_t` uses a 12-byte inline buffer for short strings and a heap pointer for longer ones. Always branch on `str_t.value.inlined.length <= 12` — see `functions/hello.zig` for the canonical decode pattern.

**Named parameters via SQL macro**: The DuckDB C API has no named-parameter support for scalar functions. Provide named params and defaults by registering a `CREATE OR REPLACE MACRO` wrapper at init time via `db.query(conn, sql, &result)`. The Zig scalar is registered as `fn_impl`; the macro is registered as `fn`. See `functions/tp_bar.zig` for the pattern.

**Table function cardinality hints**: Call `db.bindSetCardinality(info, estimated_rows, false)` in the bind callback when the row count is knowable. Without this, DuckDB cannot push down `LIMIT` into the scan, so `SELECT ... LIMIT 1` will still evaluate all rows.

**Tests**: Use `std.testing` in `test` blocks within the same file as the code under test. Run `task check:all` before every commit.

**Commits**: Conventional Commits (`feat`, `fix`, `refactor`, etc.). Separate structural from behavioral changes (Tidy First). Run `task check:all` and ensure zero warnings before committing.

## Architecture decision records

`docs/rationale/` holds ADRs numbered `000n_<slug>.md`:
- ADR-0001: Why Zig over C++ (direct `@cImport`, no ABI coupling to DuckDB C++ internals)
- ADR-0002: Comptime registration — zero-cost vs hand-written (identical machine code, 3× less boilerplate)
