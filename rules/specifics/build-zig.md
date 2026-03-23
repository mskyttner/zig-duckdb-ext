# build.zig — Specific Rules

These rules apply when modifying `build.zig` — the Zig build system
configuration for the DuckDB extension.

---

- **S-BLD-01** — MUST produce a shared library (`.so`/`.dylib`/`.dll`)
  as the primary build artifact. DuckDB loads extensions as shared objects.
- **S-BLD-02** — MUST link against the DuckDB C headers. Use `@cImport`
  with the correct include path, configured via `build.zig` options.
- **S-BLD-03** — MUST expose build options for DuckDB include/library
  paths so the extension can be built against different DuckDB versions.
- **S-BLD-04** — MUST set the output filename to match DuckDB extension
  naming conventions (e.g., `<name>.duckdb_extension`).
- **S-BLD-05** — MUST include a `test` step that runs all `test` blocks
  in the source tree.
- **S-BLD-06** — SHOULD support both debug and release-safe build modes
  via `-Doptimize`.
