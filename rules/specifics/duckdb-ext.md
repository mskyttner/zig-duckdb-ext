# DuckDB Extension Interface — Specific Rules

These rules apply to files under `src/ext/` that implement the DuckDB
extension entry points and function registration.

---

## Extension Lifecycle

- **S-EXT-01** — MUST export an `extension_version` function that returns
  the DuckDB version the extension was compiled against.
- **S-EXT-02** — MUST export an `extension_init` (or equivalent) entry
  point that DuckDB calls when loading the extension.
- **S-EXT-03** — MUST register all functions, types, and tables during
  the init entry point. Do not lazily register after init returns.

## Function Registration

- **S-EXT-10** — MUST use the DuckDB C API (`duckdb.h`) to register
  scalar, aggregate, or table functions.
- **S-EXT-11** — MUST validate input types in registered functions and
  return clear error messages on type mismatch.
- **S-EXT-12** — MUST handle NULL inputs according to DuckDB conventions
  (propagate NULL unless the function explicitly handles it).

## Error Reporting

- **S-EXT-20** — MUST use DuckDB's error reporting API to surface errors
  to the user. Do not silently swallow errors.
- **S-EXT-21** — MUST NOT panic in extension code. Convert Zig errors to
  DuckDB error results at the C boundary.

## Testing

- **S-EXT-30** — MUST have unit tests for all registered functions using
  Zig `test` blocks.
- **S-EXT-31** — SHOULD have integration tests that load the extension
  into DuckDB and run SQL queries (`task test:integration`).
