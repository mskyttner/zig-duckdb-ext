# Project Instructions

Read and follow all instructions in `.reins/METHODOLOGY.md`. That file is
your core methodology — TDD, Tidy First, commit rules, and quality standards.

## Project Overview

This project implements a **DuckDB extension written in Zig**. It uses
DuckDB's C extension API (`duckdb.h`) to register custom scalar,
aggregate, and/or table functions that can be loaded into DuckDB at
runtime via `LOAD '<path>.duckdb_extension'`.

## Tech Stack

- Language: Zig 0.15.2+ (see `build.zig.zon` for version)
- Target: DuckDB v1.5.x C extension API
- Build system: `build.zig` (Zig's native build system)
- C interop: `@cImport` of DuckDB's `duckdb.h`
- Logging: `std.log` (stdlib only)
- Allocators: explicit allocation (arena, GPA, page) — no global allocator
- Task runner: [Task](https://taskfile.dev) (see `Taskfile.yml`)
- Lines of code: [tokei](https://github.com/XAMPPRocky/tokei) (`task loc`)

## Rule System

Rules are loaded on demand based on which files you modify.

- **Principles** (always loaded): `.reins/rules/principles/`
- **Project-specific rules**: `rules/specifics/` and `rules/concerns/` (local)
- **Trigger mapping**: `rules/INDEX.yaml` (local — references both `.reins/`
  and local rule files)

Key rule files for this project:

| Trigger | Rule file | Purpose |
|---|---|---|
| `**/*.zig` | `rules/specifics/zig.md` | Zig language rules |
| `**/*.zig` + `@cImport` | `rules/concerns/c-interop-safety.md` | C interop safety |
| `build.zig` | `rules/specifics/build-zig.md` | Build system rules |
| `src/ext/**/*.zig` | `rules/specifics/duckdb-ext.md` | DuckDB extension interface |

Consult `rules/INDEX.yaml` at the start of every task (see METHODOLOGY.md L-01).

## Architecture

```
src/
  ext/          — DuckDB extension entry points and function registration
  functions/    — Individual function implementations (scalar, aggregate, table)
  lib/          — Internal utilities and helpers
build.zig      — Build configuration (shared lib output, DuckDB headers)
build.zig.zon  — Package manifest and dependency declarations
```

## Architecture Decision Records

Decision records are stored in `docs/rationale/` with sequentially numbered
filenames:

```
docs/rationale/
  0001_zig-over-cpp-for-duckdb-ext.md
  0002_c-api-interop-strategy.md
  ...
```

Use the `000n_<slug>.md` naming convention. Each record documents the
context, decision, and consequences.

## Verification

- Run `task check:all` before every commit.
- Run `task test:integration` to load the extension into DuckDB and
  execute SQL smoke tests.
- The rule-guard agent is defined in `.reins/agents/rule-guard.md`.
  Invoke it for independent verification — do not self-review.

## Audit

Run `task audit` periodically to check for compiler warnings and
deprecated patterns. Use `zig build test` to run the full test suite.

## Memory Management

Zig requires explicit memory management. Follow these conventions:

- **Allocator discipline**: Pass allocators explicitly to all functions
  that allocate. Choose the right allocator for the scope:
  - `std.heap.ArenaAllocator` for request-scoped / batch work
  - `std.heap.GeneralPurposeAllocator` for long-lived allocations
  - `std.heap.page_allocator` for large, infrequent blocks
- **Cleanup with `defer` / `errdefer`**: Every allocation must have a
  corresponding `defer allocator.free(...)` or `errdefer` for partial
  initialization cleanup. Never rely on manual free at every return point.
- **No memory leaks in error paths**: When building a struct that
  allocates multiple fields, use `errdefer` to free partially
  initialized fields on error.

## C Interop (DuckDB)

The extension communicates with DuckDB exclusively through the C API.
Key constraints:

- All pointer casts at the C boundary require `// SAFETY:` comments.
- DuckDB owns memory it allocates; Zig owns memory it allocates. Never
  cross ownership boundaries.
- Strings passed to DuckDB must be null-terminated (`[:0]const u8`).
- Extension functions must not panic — convert Zig errors to DuckDB
  error results at the boundary.

See `rules/concerns/c-interop-safety.md` for the complete rule set.

## Safety

- `@ptrCast` and `@intToPtr` must have a `// SAFETY:` comment.
- `@setRuntimeSafety(false)` requires a performance justification comment.
- Prefer slices over raw pointers. Use pointer casts only for C interop.

See `rules/specifics/zig.md` for the complete rule set.
