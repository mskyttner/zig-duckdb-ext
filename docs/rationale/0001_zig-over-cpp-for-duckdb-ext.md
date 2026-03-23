# 0001 — Zig over C++ for DuckDB Extension

## Status

Accepted

## Context

DuckDB extensions are typically written in C++ using the internal C++ API.
DuckDB also exposes a stable C extension API (`duckdb.h` +
`duckdb_extension.h`) designed for out-of-tree extensions that do not need
to link against the full C++ codebase.

We evaluated three options for implementing a custom DuckDB extension:

1. **C++** — Native language of DuckDB. Full API access, but requires
   managing the DuckDB C++ build system (CMake), header-only templates,
   and ABI coupling to a specific DuckDB release.
2. **C** — Use the C extension API directly. Stable ABI, but manual
   memory management and no type safety beyond what C provides.
3. **Zig** — Use the C extension API via `@cImport`. Stable ABI (same as
   C), but with compile-time safety, slices, tagged unions, `defer`/
   `errdefer`, and a native build system that can consume C headers
   without CMake.

## Decision

Use **Zig** with the DuckDB C extension API.

## Consequences

**Positive:**
- `@cImport` consumes `duckdb.h` directly — no manual FFI bindings.
- `defer`/`errdefer` eliminate resource leak classes common in C extensions.
- Zig's build system produces the shared library without CMake/Make.
- Compile-time safety catches type mismatches at the C boundary.
- No C++ ABI coupling — the extension is compatible with any DuckDB
  version that supports the C extension API version we target.

**Negative:**
- Cannot use DuckDB's internal C++ APIs (e.g., optimizer hooks, custom
  storage). Limited to what the C extension API exposes.
- Smaller ecosystem — fewer DuckDB extension examples in Zig.
- Developers must understand both Zig idioms and DuckDB's C API
  conventions (validity masks, vectorized execution, string_t union).

**Neutral:**
- Extension metadata (platform, version, ABI type) must be appended
  manually via a build-time tool, since we bypass DuckDB's CMake
  extension scaffolding.
