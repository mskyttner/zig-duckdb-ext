# zig-duckdb-ext

A DuckDB extension written in Zig, targeting the DuckDB v1.2.0 C extension API (the stable one), with a v2 C API
port and a cookbook alongside it: see [Two C APIs, and a cookbook](#two-c-apis-and-a-cookbook).

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

## Two C APIs, and a cookbook

The repository builds the same kind of extension against **both** DuckDB C extension APIs:

- **v1**, the stable API that the LTS and stable DuckDB releases ship: the `zig_ext` extension above
  (`zig build ext`, sources in `src/functions`, tested by `test/sql/zig_ext.test`).
- **v2**, the API of DuckDB 2.0, through bindings that are generated from DuckDB's API specification
  (`src/lib/duckdb_v2_{types,static,dynamic}.zig`, `zig build gen-v2-bindings`). A dynamic backend (an extension
  loaded by DuckDB) and a static one (DuckDB linked into a program) share the types. The real v2 extension is
  `zig build ext-v2`; `zig build v2-poc` is a proof of concept that exercises the comptime frameworks over many types.

On top of v2 sits the **cookbook**, `zig_ext_cookbook` (`zig build ext-cookbook`, sources in `src/cookbook`): one small,
tested example per capability of the API, each file with a header that says what it shows and why.

| Recipe | Shows |
|---|---|
| `config_options`, `scalar_callbacks`, `aggregate_callbacks`, `table_callbacks` | settings through the context; every callback of a scalar, aggregate and parallel table function, in the order they run |
| `copy_format` | a custom `COPY` format, both directions |
| `custom_type` | a custom logical type |
| `arrow_ipc` | an Arrow IPC `COPY` format and a reader table function, over a vendored pure-Zig library (`third_party/gld-arrow-zig`, MIT, with a [patch note](third_party/gld-arrow-zig/PATCHES.md)) |
| `arrow_c_data` | the Arrow C Data Interface: an exporter and an importer, and the rules for producing `ArrowSchema` and `ArrowArray` structs |
| `file_system` | files through DuckDB's file system instead of libc (`file:` URLs, remote file systems) |
| `logging` | `context_log`, and what the log configuration does with an entry |
| `names` | identifiers, qualified names and UTF-8 validation, which work on text alone |
| `embed_sql` | a program that **hosts** DuckDB: SQL, prepared statements, Arrow results, the tokenizer and the parser |

Some calls take a connection, which an extension is never given; those are only in `embed_sql`. The capability matrix
in [docs/cookbook.md](docs/cookbook.md) lists, per capability, the file that shows it for v1 and for v2, and
[docs/api-v2-coverage.md](docs/api-v2-coverage.md) is a generated report of the v2 functions that no code references yet
(`task coverage:api-v2`; `task check:all` fails when it is stale).

```sql
LOAD 'zig-out/lib/zig_ext_cookbook.duckdb_extension';

SELECT * FROM zig_cookbook_qname_parts('main."a.b".select');
COPY (SELECT 42 AS id, 'duck' AS name) TO '/tmp/x.arrows' (FORMAT zig_cookbook_arrow_ipc);
SELECT * FROM zig_cookbook_read_arrow('/tmp/x.arrows');
```

## Wasm (Emscripten)

`zig_ext` also builds as a real Emscripten `SIDE_MODULE`, loadable by `duckdb-wasm`/`haybarn-wasm` —
DuckDB running client-side, in a browser or Node, with no native install step:

```sh
zig build wasm-ext -Demcc-path=<emcc from an activated emsdk>
```

Verified live against both forks' own CI-built engines (`task wasm:verify-haybarn` /
`task wasm:verify-duckdb-wasm`, and the `wasm-verify` job in `.github/workflows/ci-extended.yml`):
`zig_hello`/`zig_add_numbers`, loaded over the documented `custom_extension_repository` + `LOAD` path,
both return correct results. Needs the Emscripten version matching whichever engine you're targeting —
the two forks pin different, mutually incompatible ones (6.0.12 vs 3.1.71), confirmed directly: a
mismatch fails at `dlopen()`, not a warning. Deliberately not part of `cross` — see
[docs/v2-migration-plan.md](docs/v2-migration-plan.md)'s WASM section and
[ADR-0008](docs/rationale/0008_wasm-emscripten-side-module.md) for the full trace, including what's
still unverified (a real browser; `registerFileBuffer` + direct-path `LOAD`, blocked today by an
upstream Node-binding bug).

## Comptime Function Framework

The extension includes a `comptime` registration framework that generates
vectorized callbacks and DuckDB registration boilerplate from simple per-row
Zig functions. This eliminates about 50 lines of boilerplate per scalar function
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

**23 lines** vs. 74 for the hand-written equivalent (`ct_add_numbers.zig` and `add_numbers.zig`, both reporting overflow as a query error). The generated code
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

`task bench` (Linux x86-64, DuckDB v1.5.6, Zig 0.17.0, ReleaseSafe; the median of 3 runs):

| Function | Hand-written | Comptime |
|---|---|---|
| `add_numbers`, `sum` over 10M rows | 0.015s | 0.014s |
| `tokenize`, one input of 1M tokens | 0.024s | 0.024s |

The comptime layer costs nothing measurable: the differences are within run-to-run variance. (The timings are not
comparable across machines; an earlier table from macOS arm64 had 0.024s and 0.025s for `add_numbers`.) The binary
sizes of the two versions are no longer compared, because the extension holds every v1 function in one 4 MB file.
Details in [ADR-0002](docs/rationale/0002_comptime-registration-vs-handwritten.md), including a correction to its
table function and size results.

A table function takes constants, not a column, so the `tokenize` benchmark splits one long input.

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.17.0 (the version CI uses; `build.zig.zon` allows 0.16.0 as a minimum, but the code needs 0.17 syntax)
- [DuckDB](https://duckdb.org/) CLI (for running the extension)
- [Task](https://taskfile.dev/) (optional, for convenience commands)
- Optional: Python with `pyarrow` (`task verify:arrow-pyarrow`), and Docker (the Windows and QEMU checks, `task verify:static-windows`)

Writing your own extension: [docs/creating-an-extension.md](docs/creating-an-extension.md) has the steps (build, entry
point, a function with real parameter names, tests, publishing) and what `duckdb_functions()` can and cannot show.

The v2 SQL tests run a DuckDB CLI that the build fetches and pins; the v1 suite (`task sqllogictest`) runs the `duckdb` on your `PATH`, so it needs a v1 release (CI installs v1.5.6).

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

# End-to-end SQL tests (sqllogictest format), one suite per extension
task sqllogictest              # v1
task sqllogictest:v2           # v2
task sqllogictest:v2:poc       # v2 proof of concept (comptime frameworks)
task sqllogictest:cookbook     # the cookbook

# A failing registration must fail the load with its reason
task test:load-failure

# Quality gates: format + build + unit tests + a current API coverage report.
# This does NOT run the SQL suites above; CI (.github/workflows/ci.yml) runs both.
task check:all

# Benchmark hand-written vs comptime (release build)
task bench
```

## Project Structure

```
src/
  ext/                Extension entry points and function registration (v1, v2, PoC, cookbook)
  functions/          Function implementations (hand-written and comptime)
  cookbook/           One recipe per capability of the v2 API
  lib/                DuckDB C API bindings (v1 and generated v2) + comptime frameworks
third_party/          Vendored libraries (gld-arrow-zig, with its patch note)
tools/                Binding generator, coverage report, Arrow fixture generator and PyArrow check
build.zig             Build configuration
build.zig.zon         Package manifest — also pins the DuckDB C headers (v1.5.6), fetched at build time rather than committed locally
test/sql/             End-to-end SQL tests (sqllogictest .test format)
test/data/            Fixtures for the tests (Arrow files written by PyArrow)
docs/cookbook.md      Capability matrix: where each part of the C API is shown
docs/api-v2-coverage.md  Generated: v2 functions that no code references yet
docs/rationale/       Architecture decision records
.github/workflows/   ci.yml (pull requests, main), ci-extended.yml (weekly), release.yml (v* tags: v1 and v2 trees)
```

## Platform Support

| Platform       | Architecture |
|----------------|--------------|
| macOS          | arm64, amd64 |
| Linux (glibc)  | arm64, amd64 |
| Linux (musl)   | arm64, amd64 |
| Windows        | amd64        |
| Wasm (Emscripten) | wasm32 (`SIDE_MODULE`, experimental — see [Wasm (Emscripten)](#wasm-emscripten)) |

## Available Tasks

| Command              | Description                         |
|----------------------|-------------------------------------|
| `task build`         | Compile the extension (debug)       |
| `task build:release` | Compile the extension (release)     |
| `task test:unit`     | Run unit tests                      |
| `task sqllogictest`  | Run end-to-end SQL tests (v1)       |
| `task sqllogictest:v2` | Run end-to-end SQL tests (v2)     |
| `task sqllogictest:v2:poc` | SQL tests of the v2 comptime frameworks |
| `task sqllogictest:cookbook` | SQL tests of the cookbook extension |
| `task test:load-failure` | A failing registration fails the load with its reason |
| `task test:arrow-vendor` | Tests of the vendored Arrow library |
| `task verify:arrow-pyarrow` | Read the cookbook's Arrow files with PyArrow (needs `pyarrow`; run `sqllogictest:cookbook` first) |
| `task coverage:api-v2` | Rewrite the v2 API coverage report |
| `task dist:v2` | Cross-compile the v2 extensions into `dist/<alpha>/<platform>/` |
| `task verify:dist-v2` | Install them from `dist/` into the pinned alpha CLI and use them (run `dist:v2` first) |
| `task verify:static-windows` | Windows static embedding under Wine, in a container |
| `task wasm:ext` | Build the wasm32-emscripten SIDE_MODULE (needs a real `emcc`; see `-Demcc-path=`) |
| `task wasm:verify-haybarn` | Verify the wasm build loads and runs against haybarn-wasm's latest engine |
| `task wasm:verify-duckdb-wasm` | Verify the wasm build loads and runs against official duckdb-wasm's latest engine |
| `task check:all`     | Format, build, unit tests, coverage report is current (not the SQL suites) |
| `task bench`         | Benchmark hand-written vs comptime  |
| `task format`        | Format Zig source files             |
| `task demo:hello`    | Demo the zig_hello function         |
| `task demo:add-numbers` | Demo the zig_add_numbers function |
| `task demo:tokenize` | Demo the zig_tokenize function      |
| `task audit`         | Check for compiler warnings         |
| `task clean`         | Remove build artifacts              |
| `task loc`           | Count lines of code                 |

## Design Decisions

- **Zig over C++**: no ABI coupling to DuckDB's C++ internals. The v1
  extension consumes the C headers via `@cImport`; the v2 one uses Zig
  declarations generated from DuckDB's API specification. See
  [ADR-0001](docs/rationale/0001_zig-over-cpp-for-duckdb-ext.md).
- **Comptime registration**: Zero-cost `comptime` generics generate
  vectorized callbacks from per-row functions — same performance as
  hand-written code with 3x less boilerplate. See
  [ADR-0002](docs/rationale/0002_comptime-registration-vs-handwritten.md).
- **Vectorized execution**: All functions process entire DataChunks rather
  than row-at-a-time, matching DuckDB's execution model.
- **Few dependencies**: the v1 extension needs only the Zig standard library
  and the DuckDB C headers, which `build.zig.zon` pins and the build fetches
  (they are not committed). The cookbook adds one vendored library, the
  pure-Zig `gld-arrow-zig` in `third_party/` (MIT, with a patch note). The
  v2 tests fetch a pinned DuckDB CLI, and the embedding recipe fetches DuckDB's
  static libraries.
- **Explicit memory management**: Allocators are passed explicitly; `defer`
  and `errdefer` ensure cleanup on all paths.
- **Wasm as a separate, opt-in build**, not a `cross` target: it needs an
  external, unvendored Emscripten toolchain, and the two forks this project
  has verified against pin different, mutually incompatible versions of it.
  See [ADR-0008](docs/rationale/0008_wasm-emscripten-side-module.md).
