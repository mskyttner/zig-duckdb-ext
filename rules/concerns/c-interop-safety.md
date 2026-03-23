# C Interop Safety — Concern Rules

These rules activate when a `.zig` file contains `@cImport`. They govern
safe interaction with C APIs (DuckDB C API, system headers, etc.).

---

## Pointer Safety

- **C-INT-01** — MUST add a `// SAFETY:` comment on every `@ptrCast`,
  `@alignCast`, and `@intFromPtr` at the C boundary explaining why the
  cast is valid and what invariant guarantees correctness.
- **C-INT-02** — MUST check for null before dereferencing optional C
  pointers (`[*c]T`). Use `orelse return error.NullPointer` or an
  equivalent check.
- **C-INT-03** — MUST NOT store C pointers beyond the lifetime guaranteed
  by the C API. Document the ownership model in a comment.

## Memory Ownership

- **C-INT-10** — MUST document who owns memory at every C boundary
  crossing. If DuckDB allocates it, DuckDB frees it. If Zig allocates
  it, Zig must free it.
- **C-INT-11** — MUST NOT pass Zig-allocated memory to C functions that
  will free it (unless using a C-compatible allocator).
- **C-INT-12** — MUST use `errdefer` to clean up C resources on error
  paths, just like Zig resources.

## String Handling

- **C-INT-20** — MUST ensure strings passed to C are null-terminated.
  Use `[:0]const u8` or `std.mem.sliceTo` for conversion.
- **C-INT-21** — MUST NOT assume C strings returned by DuckDB outlive
  the current API call unless documented otherwise.

## Type Translation

- **C-INT-30** — MUST use `c.` prefixed types from `@cImport` rather
  than manually defining C structs.
- **C-INT-31** — MUST NOT use `@bitCast` between Zig and C types unless
  layout equivalence is proven and documented.
