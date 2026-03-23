# Zig — Specific Rules

These rules apply when modifying `.zig` files in this project.
Loaded via `rules/INDEX.yaml` trigger: `**/*.zig`.

**Minimum version: Zig 0.15.2+.** The `build.zig.zon` `.minimum_zig_version`
field is the single source of truth. All code MUST compile and pass
`zig build test` with the declared version.

---

## Language

- **S-ZIG-01** — MUST use the Zig version declared in `build.zig.zon` or the project README.
- **S-ZIG-02** — MUST handle all error unions explicitly. Use `try` for propagation, `catch` for recovery. Do not discard errors with `_ = expr`.
- **S-ZIG-03** — MUST use `defer` and `errdefer` for resource cleanup. Never rely on manual cleanup at every return point.
- **S-ZIG-04** — MUST prefer slices and iterators over raw pointer arithmetic. Use `@ptrCast` and `@alignCast` only when interfacing with C.
- **S-ZIG-05** — MUST use `comptime` for compile-time validation and generic programming. Do not use runtime checks for invariants that can be verified at compile time.
- **S-ZIG-06** — MUST choose the appropriate allocator for the context (arena for request-scoped, GPA for long-lived, page allocator for large blocks). Do not hardcode a single allocator.
- **S-ZIG-07** — MUST format all code with `zig fmt`. Do not disable formatting directives without justification.
- **S-ZIG-08** — MUST use `std.log` for diagnostic output. Do not use `std.debug.print` in production code.
- **S-ZIG-09** — MUST prefer tagged unions over separate type + value fields for variant data.
- **S-ZIG-10** — MUST use `std.testing` for tests. Place tests in the same file as the code they test using `test` blocks.

## Memory Management

- **S-ZIG-20** — MUST pass allocators explicitly to all functions that allocate. No global allocator usage outside of `main()` or top-level setup.
- **S-ZIG-21** — MUST pair every `alloc` / `create` with a corresponding `free` / `destroy` via `defer`. Every allocation site must have a visible cleanup path.
- **S-ZIG-22** — MUST use `errdefer` for partial initialization cleanup. When a function allocates multiple resources and a later allocation fails, `errdefer` must free the earlier ones.
- **S-ZIG-23** — MUST NOT leak memory in error paths. When building a struct that allocates multiple fields, each field allocation must have its own `errdefer` so that early returns after partial allocation properly free resources.
- **S-ZIG-24** — MUST choose the right allocator for the scope:
  - `std.heap.ArenaAllocator` for request-scoped or batch work (free all at once).
  - `std.heap.GeneralPurposeAllocator` for long-lived allocations with leak detection.
  - `std.heap.page_allocator` for large, infrequent blocks.
  - `std.testing.allocator` in test blocks (detects leaks automatically).

## Error Handling

- **S-ZIG-30** — MUST NOT use `catch unreachable` in non-test code. Use `catch |err|` with proper handling or `try` for propagation.
- **S-ZIG-31** — MUST NOT use `unreachable` in non-test code unless the invariant is documented with a comment explaining why the branch is impossible.
- **S-ZIG-32** — MUST NOT use `@panic()` outside of tests or `unreachable` branches. Panics in production code must have a documented invariant.
- **S-ZIG-33** — MUST use explicit error sets in public function signatures instead of `anyerror`. Reserve `anyerror` for internal helper functions where the full set is impractical.

## Safety

- **S-ZIG-40** — MUST add a `// SAFETY:` comment on every `@ptrCast` and `@intToPtr` explaining why the cast is valid.
- **S-ZIG-41** — MUST add a performance justification comment on every `@setRuntimeSafety(false)` call explaining why safety checks are being disabled.
- **S-ZIG-42** — MUST prefer slices over raw pointers. Use `[*]T` and `@ptrCast` only for C interop boundaries. Internal APIs must use `[]T` or `[]const T`.

## Style

- **S-ZIG-50** — MUST use doc comments (`///`) on all public declarations (`pub fn`, `pub const`, `pub var`, `pub` struct fields).
- **S-ZIG-51** — MUST use `_` prefix for intentionally unused variables. Do not use bare `_` to suppress important return values.
- **S-ZIG-52** — MUST NOT shadow variables from outer scopes. Use distinct names even when the inner variable has a narrower type.

## Verification

- **S-ZIG-11** — MUST run `task check:all` (fmt, build, test) before every commit.
- **S-ZIG-12** — MUST fix all warnings reported by the Zig compiler before committing.
