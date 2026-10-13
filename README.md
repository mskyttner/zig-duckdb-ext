# zig-duckdb-ext

A DuckDB extension written in Zig, targeting the DuckDB v1.2.0 C extension API.

Demonstrates how to build scalar and table functions for DuckDB using Zig's
`@cImport` for zero-cost C interop, `defer`/`errdefer` for safe resource
management, and `comptime` generics for zero-cost function registration.

## Functions

### `zig_hello(name VARCHAR) -> VARCHAR`

Returns a greeting string.

```sql
SELECT zig_hello('Zig');
-- Hello, Zig!
```

NULL-propagating: returns NULL when the input is NULL.

### `zig_add_numbers(a BIGINT, b BIGINT) -> BIGINT`

Adds two 64-bit integers.

```sql
SELECT zig_add_numbers(2, 3);
-- 5
```

NULL-propagating: returns NULL when either input is NULL.

### `zig_tokenize(input VARCHAR, delim VARCHAR) -> TABLE(token_pos BIGINT, token VARCHAR)`

Splits a string by a delimiter and returns one row per token with a 0-based
position ordinal.

```sql
SELECT * FROM zig_tokenize('a,b,c', ',');
```

| token_pos | token |
|-----------|-------|
| 0         | a     |
| 1         | b     |
| 2         | c     |

Empty tokens are preserved:

```sql
SELECT * FROM zig_tokenize('a,,b', ',');
```

| token_pos | token |
|-----------|-------|
| 0         | a     |
| 1         |       |
| 2         | b     |

Supports multi-character delimiters:

```sql
SELECT * FROM zig_tokenize('x::y::z', '::');
```

## Comptime Function Framework

The extension includes a `comptime` registration framework that generates
vectorized callbacks and DuckDB registration boilerplate from simple per-row
Zig functions. This eliminates ~40 lines of boilerplate per scalar function
with zero runtime overhead.

### Scalar functions

Define a per-row function; the framework generates the vectorized callback,
NULL propagation, and type registration:

```zig
const comptime_scalar = @import("lib/comptime_scalar.zig");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

const AddFn = comptime_scalar.Function("my_add", add);

pub fn register(conn: db.Connection) !void {
    return AddFn.register(conn);
}
```

**20 lines** vs. 60 for the hand-written equivalent. The generated code
benchmarks identically — see [ADR-0002](docs/rationale/0002_comptime-registration-vs-handwritten.md).

Supported types: `i8`, `i16`, `i32`, `i64`, `f32`, `f64`, `bool`.

### Table functions

Provide a config struct with bind/init/exec callbacks; the framework handles
registration boilerplate:

```zig
const comptime_table = @import("lib/comptime_table.zig");

const MyTable = comptime_table.Function(struct {
    pub const name: [:0]const u8 = "my_table";
    pub const param_types = [_]DuckDBType{ .VARCHAR, .VARCHAR };
    pub const bind = myBind;
    pub const init = myInit;
    pub const exec = myExec;
});
```

### Benchmark Results

`task bench` over 10M rows (ReleaseSafe, macOS arm64):

| Function | Hand-written | Comptime | Delta |
|---|---|---|---|
| `add_numbers` (10M rows) | 0.024s | 0.025s | ~0% |
| `tokenize` (500K rows) | 0.001s | 0.001s | 0% |
| Binary size | 278K | 278K | 0% |

The comptime layer compiles away completely — identical machine code, zero
binary bloat. Details in [ADR-0002](docs/rationale/0002_comptime-registration-vs-handwritten.md).

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.15.2+
- [DuckDB](https://duckdb.org/) CLI (for running the extension)
- [Task](https://taskfile.dev/) (optional, for convenience commands)

## Build

```sh
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSafe
```

The build produces `zig-out/lib/zig_ext.duckdb_extension`.

The extension name, targeted DuckDB C extension API version, and recorded
extension version are configurable build options, each defaulting to the
values above:

```sh
zig build -Dname=my_ext -Dapi-version=v1.3.0 -Dextension-version=v0.2.0
```

produces `zig-out/lib/my_ext.duckdb_extension`, loadable via `LOAD
'zig-out/lib/my_ext.duckdb_extension';`.

With Task:

```sh
task build            # debug
task build:release    # release-safe
```

## Usage

Load the extension in DuckDB with the `-unsigned` flag (required for
extensions not signed by DuckDB Labs):

```sh
duckdb -unsigned
```

```sql
LOAD 'zig-out/lib/zig_ext.duckdb_extension';

SELECT zig_hello('world');
SELECT zig_add_numbers(40, 2);
SELECT * FROM zig_tokenize('hello world', ' ');
```

## Testing

```sh
# Unit tests
task test:unit

# End-to-end SQL tests (sqllogictest format, against the real v1 extension)
task sqllogictest

# All quality gates (format + build + unit tests)
task check:all

# Benchmark hand-written vs comptime (release build)
task bench
```

## Project Structure

```
src/
  ext/                Extension entry point and function registration
  functions/          Function implementations (hand-written and comptime)
  lib/                DuckDB C API bindings + comptime frameworks
build.zig             Build configuration
build.zig.zon         Package manifest — also pins the DuckDB C headers (v1.5.6), fetched at build time rather than committed locally
test/sql/             End-to-end SQL tests (sqllogictest .test format)
docs/rationale/       Architecture decision records
```

## Platform Support

| Platform       | Architecture |
|----------------|--------------|
| macOS          | arm64, amd64 |
| Linux (glibc)  | arm64, amd64 |
| Linux (musl)   | amd64        |
| Windows        | amd64        |

## Available Tasks

| Command              | Description                         |
|----------------------|-------------------------------------|
| `task build`         | Compile the extension (debug)       |
| `task build:release` | Compile the extension (release)     |
| `task test:unit`     | Run unit tests                      |
| `task sqllogictest`  | Run end-to-end SQL tests (v1)       |
| `task sqllogictest:v2` | Run end-to-end SQL tests (v2)     |
| `task check:all`     | Run all quality gates               |
| `task bench`         | Benchmark hand-written vs comptime  |
| `task format`        | Format Zig source files             |
| `task demo:hello`    | Demo the zig_hello function         |
| `task demo:add-numbers` | Demo the zig_add_numbers function |
| `task demo:tokenize` | Demo the zig_tokenize function      |
| `task audit`         | Check for compiler warnings         |
| `task clean`         | Remove build artifacts              |
| `task loc`           | Count lines of code                 |

## Design Decisions

- **Zig over C++**: Direct C header consumption via `@cImport`, no ABI
  coupling to DuckDB's C++ internals. See
  [ADR-0001](docs/rationale/0001_zig-over-cpp-for-duckdb-ext.md).
- **Comptime registration**: Zero-cost `comptime` generics generate
  vectorized callbacks from per-row functions — same performance as
  hand-written code with 3x less boilerplate. See
  [ADR-0002](docs/rationale/0002_comptime-registration-vs-handwritten.md).
- **Vectorized execution**: All functions process entire DataChunks rather
  than row-at-a-time, matching DuckDB's execution model.
- **No external dependencies**: Only the Zig standard library and vendored
  DuckDB C headers.
- **Explicit memory management**: Allocators are passed explicitly; `defer`
  and `errdefer` ensure cleanup on all paths.
