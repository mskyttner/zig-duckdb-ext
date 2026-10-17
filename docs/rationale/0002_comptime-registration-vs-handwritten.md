# 0002 — Comptime Registration vs. Hand-Written Callbacks

## Status

Accepted

## Context

The current extension registers each function manually in `src/ext/init.zig`.
Each function requires ~15 lines of setup: create, set name, add parameters,
set return type, set callback, register, destroy. The vectorized callback
implementations in `src/functions/` are also hand-written, directly
operating on `DataChunk` pointers, validity masks, and `duckdb_string_t`.

DuckDB.ExtensionKit (C#/.NET) demonstrates that a higher-level registration
API can reduce a function definition to a single line:

```csharp
connection.RegisterScalarFunction<string, string, string?>("name", Fn);
```

Zig's `comptime` generics could achieve similar ergonomics — a wrapper that
accepts a Zig function signature and generates the vectorized callback,
parameter registration, and type mapping at compile time. Because `comptime`
is evaluated before codegen, the resulting binary should be identical to the
hand-written version.

The open question is whether this is actually true in practice.

## Decision

Build a `comptime` registration layer and benchmark it against the
hand-written equivalents. Adopt it as the primary API if no hot-path
overhead is measured.

### What to Benchmark

| Dimension         | Metric                                   | Acceptable delta |
|-------------------|------------------------------------------|------------------|
| Hot-path throughput | Rows/sec for a scalar function over 10M+ rows via `generate_series` | < 2% regression |
| Binary size       | `.duckdb_extension` file size            | < 5% increase    |
| Compile time      | `zig build` wall-clock time              | Documented, no hard limit |
| Ergonomics        | Lines of code per function registration  | Strict reduction  |

### Methodology

1. Implement `comptime` wrappers for one scalar function (`ct_add_numbers`)
   and one table function (`ct_tokenize`).
2. Keep the hand-written originals alongside the `comptime` versions.
3. Benchmark both using DuckDB SQL queries over large synthetic datasets,
   using `SUM` to force evaluation (not `count(*)` which DuckDB can
   short-circuit).
4. Run 3 iterations per function in separate DuckDB processes.
5. Compare binary size with `ls -lh` on the `.duckdb_extension` output.

## Results

**Environment:** macOS arm64 (Apple Silicon), Zig 0.15.2, DuckDB v1.2.0,
ReleaseSafe optimization.

### Hot-Path Throughput

`SELECT sum(fn(i, i)) FROM generate_series(0, 9999999) t(i)` — 3 runs each.

| Function | Run 1 | Run 2 | Run 3 | Median |
|---|---|---|---|---|
| `zig_add_numbers` (hand-written) | 0.024s | 0.025s | 0.024s | **0.024s** |
| `ct_add_numbers` (comptime) | 0.025s | 0.025s | 0.025s | **0.025s** |
| **Delta** | | | | **+4% (within noise)** |

Table function (`count(*)` over 100K × 5 tokens = 500K rows):

| Function | Run 1 | Run 2 | Run 3 | Median |
|---|---|---|---|---|
| `zig_tokenize` (hand-written) | 0.001s | 0.001s | 0.001s | **0.001s** |
| `ct_tokenize` (comptime) | 0.001s | 0.001s | 0.002s | **0.001s** |
| **Delta** | | | | **0% (identical)** |

**Verdict:** No measurable regression. The 1ms difference on the scalar
function is within run-to-run variance. Both versions produce identical
results (`sum = 99999990000000`).

### Binary Size

| Version | Size |
|---|---|
| Before comptime (hand-written only) | 278K |
| After comptime (both versions registered) | 278K |
| **Delta** | **0%** |

The comptime-generated code compiles to the same machine code as the
hand-written version. No binary bloat.

### Ergonomics

**Scalar function (add_numbers):**

| Metric | Hand-written | Comptime |
|---|---|---|
| Total lines | 60 | 20 |
| Registration lines | 18 | 3 |
| Callback lines | 32 | 0 (generated) |
| User logic | 1 line (buried in callback) | 3 lines (standalone `fn add`) |

**Table function (tokenize):**

| Metric | Hand-written | Comptime |
|---|---|---|
| Registration lines | 19 | 3 |
| Callbacks | Same (user-provided) | Same (referenced) |

## Consequences

**Adopted.** The `comptime` registration layer is the recommended API for
new scalar functions with numeric types. The hand-written path remains
available for:

- VARCHAR and other non-numeric types (not yet supported by the comptime
  scalar wrapper)
- Custom chunk-level batching or multi-output functions
- Table functions where only registration boilerplate is saved

### Implementation

- `src/lib/comptime_scalar.zig` — `Function(name, implFn)` generates
  vectorized callback + registration from a per-row Zig function.
- `src/lib/comptime_table.zig` — `Function(Config)` generates registration
  from a config struct with user-provided bind/init/exec callbacks.
- Supported scalar types: `i8`, `i16`, `i32`, `i64`, `f32`, `f64`, `bool`.
- NULL propagation is automatic (any NULL input → NULL output).

### Future Work

- Extend `comptime_scalar` to support VARCHAR parameters and return types
  (requires `duckdb_string_t` extraction and `vectorAssignStringElementLen`).
- Consider a `comptime` table function wrapper that auto-generates bind/init
  callbacks from declarative column/state definitions.

## Update (2026-10-17): the table function numbers above did not measure the work

The scalar result stands. The table function row does not: it ran `zig_tokenize('a,b,c,d,e', ',')` in a `LATERAL`
subquery, and a table function here takes constants (DuckDB rejects a column as an argument: "does not support lateral
join column parameters"), so the subquery was uncorrelated and ran once, with `count(*)` over the cross join. The
0.001s was the time of one call, not of 500K rows. The binary size row is also out of date: the extension now holds all
of the v1 functions (4.0 MB), so the size of the hand-written and comptime versions can no longer be told apart, and
that table never compared the machine code, only the file size.

Re-measured with `task bench` (Linux x86-64, DuckDB v1.5.6, Zig 0.17.0, ReleaseSafe): `zig_add_numbers` 0.015s against
`ct_add_numbers` 0.014s over 10M rows, and `zig_tokenize` 0.024s against `ct_tokenize` 0.024s over one input of 1M
tokens. The conclusion (no measurable cost) holds on the same grounds: the differences are within run-to-run variance.

The line counts in the ergonomics table (60 and 20) are now 74 and 23: both versions of `add_numbers` report overflow as
an error of the query.

Found on the way, and fixed: `tokenizeExec` called `std.mem.span` on the input in every exec call, which measures the whole
string each time, so the cost grew with the square of the input (1M tokens: 0.5s, 5M tokens: 12s), in the hand-written
and the comptime version alike. The lengths are now measured once in bind: 5M tokens take 0.09s. `test/sql/zig_ext.test`
has a test with 2M tokens.
