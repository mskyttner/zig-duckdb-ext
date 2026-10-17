# 0003 — DuckDB v2 C Extension API: Shape Differences from v1

## Status

Accepted

## Context

DuckDB 2.0 (staged alpha at the time of writing — `v2.0.0-alpha46057`,
built via `curl https://install.duckdb.org | DUCKDB_VERSION=alpha bash`)
introduces `duckdb_ext_api_v2`, a from-scratch C extension API — not an
extension of v1's `duckdb_ext_api_v1`. Confirmed directly: every function
is under a new `duckdb_v2_*` namespace with no `duckdb_*` overlap, v1's
`duckdb_ext_api_v1` struct keeps shipping unmodified (append-only — two
fields were added between v1.2.0 and v1.5.6, in the same position, same
names, nothing removed or reordered) alongside it, and both vtables
coexist in the same v2.0 binary. See ADR-0001/0002 for why this project
is in Zig at all and why comptime registration was adopted for v1 — this
ADR assumes that context and documents what changes, and what doesn't,
when writing v2 bindings instead.

The `duckdb-v2-api` branch explored v2 far enough to reach full 9/9
function parity with the real v1 extension (scalar, table, and aggregate
functions; VARCHAR; LIST; BOOLEAN), as a parallel `zig_ext_v2` extension
never replacing v1. See `docs/v2-migration-plan.md` for what's done and
what's left. This ADR is the durable record of the shape differences that
work surfaced, for whoever writes the next v2 binding.

## Decision

Document the differences below as the reference for `src/lib/duckdb_v2.zig`
and the `comptime_*_v2.zig` frameworks, and keep new v2 bindings consistent
with the patterns already established there rather than re-deriving them
per call.

### 1. Calling convention: every call returns an error code, result via out-param

v1 mixes two styles: some functions return the result directly
(`duckdb_create_scalar_function() -> ScalarFunction`), others return a
`duckdb_state` status enum with the result in an out-param
(`duckdb_open(path, *out_database) -> duckdb_state`). v2 is uniform:
every single function returns `DUCKDB_V2_ERROR` (an enum, `_NONE` on
success) and writes its actual result through one or more `out_*`
pointer parameters, down to the simplest getters. `src/lib/duckdb_v2.zig`
reflects this in nearly every wrapper's return type (`ErrorCode`) and the
ubiquitous `err: *ErrorInfoHandle` trailing parameter.

### 2. Type construction is context/connection-scoped, not handle-less

v1: `duckdb_create_logical_type(DUCKDB_TYPE_BIGINT) -> duckdb_logical_type`
— no handle needed. v2: `context_create_type_from_id(ctx, type_id, ...)`
— always needs a `ContextHandle` or `ConnectionHandle`. There is no
handle-less constructor in v2 at all (confirmed: grepped the full v2
function list for anything resembling one).

Parameterized types (LIST, STRUCT, DECIMAL, ARRAY, MAP, ...) go through
the same `context_create_type_from_id`, but with `(name, value)` parameter
pairs — a positional param uses a `{NULL, 0}` name entry. A nested child
*type* is itself passed as a value: wrap it first via
`value_create_type_with_context(ctx, child_type) -> Value`, then pass that
Value as the parameter. `duckdb_v2.zig`'s `contextCreateListType` hides
this two-step dance behind the same plain `(ctx, child_type)` shape the
primitive-type callers already use.

### 3. State lifecycle: one `Opaque` box, not a separate delete-callback argument

v1 threads a `duckdb_delete_callback_t` as a second argument alongside
whatever state pointer is being handed to DuckDB
(`duckdb_bind_set_bind_data(info, data, delete_callback)`). v2 bundles
the pointer and its cleanup into one struct, passed by reference:

```c
struct duckdb_v2_opaque { void *ptr; void (*destroy)(void*); bool (*equals)(void*, void*); };
```

Used identically everywhere DuckDB needs to take ownership of
extension-allocated state: table function bind data
(`function_bind_set_bind_data`), table function global state
(`table_function_init_global_set_global_state`), and presumably aggregate
user data (not yet exercised). `duckdb_v2.zig`'s `Opaque` type alias and
every `*_v2.zig` table function's `destroyBindData`/`destroyGlobalState`
pattern follow this box, not a bare function-pointer argument.

### 4. VARCHAR has two distinct shapes — don't confuse them

- `duckdb_v2_str` — plain `{ const char *ptr; idx_t len; }`. Used for
  ordinary API in/out string parameters: names, error text, option
  values. `duckdb_v2.zig`'s `Str`/`str()`.
- `duckdb_v2_bytes` — a 16-byte union, bytes inlined when `length <= 12`
  else a pointer + 4-byte prefix. This is **vector storage** for
  VARCHAR/BLOB/BIT/BIGNUM — the same small-string-optimization layout
  v1's `duckdb_string_t` used, fields renamed. Reading a VARCHAR
  argument's `VectorView.data` means casting to `[*]const BytesValue` and
  calling `bytesSlice()`, never `Str`. v2 has no vector-level
  string-*write* helper at all (unlike v1's
  `vectorAssignStringElementLen`) — writing a VARCHAR result means
  boxing through `value_create_varchar_with_context` +
  `vector_set_value` instead, letting DuckDB handle the inline/pointer
  encoding (see `duckdb_v2.zig`'s `valueCreateVarcharWithContext`/
  `vectorSetValue` doc comments for the tradeoff this implies).

### 5. Nested types (LIST/STRUCT/MAP/UNION) share one generic child mechanism

v1 has a LIST-specific accessor (`duckdb_list_vector_get_child`). v2 has
one generic pair, `vector_get_child`/`vector_get_child_count`, whose
meaning depends on the vector's kind (LIST/ARRAY: child 0 is the flat
element vector; STRUCT/TUPLE: child `i` is field `i`; MAP: child 0 is a
STRUCT(key, value); UNION: child 0 is the tag, 1..N the members). A LIST
vector's own `VectorView.data` is an array of
`duckdb_v2_list_entry{offset, length}` records addressing into that child
— the same vectorized read pattern as any other type, just with one more
level of indirection. STRUCT support hasn't been built in this branch
yet, but the mechanism is already visible in `duckdb_v2.zig`'s
`vectorGetChild` doc comment.

### 6. Named parameters and per-parameter defaults are native

This is the capability that originally motivated exploring v2 at all: v1
has no way to express a named or defaulted scalar-function parameter at
the C-API level, forcing the SQL-macro-wrapper workaround visible in
`tp_bar.zig`/`tp_line.zig`/`tp_treemap.zig`/`tp_snakemap.zig` (register a
plain `_impl` function, then `CREATE OR REPLACE MACRO` a named/defaulted
wrapper around it via `db.query()` at init time). v2's
`function_signature_add_parameter` takes a name and an optional default
`Value` directly, with a `DUCKDB_V2_FUNCTION_PARAMETER_KIND` (positional-
only / standard / `*args` / named-only / `**kwargs`) — every `*_v2.zig`
port of those four functions drops the macro and `_impl` split entirely
(see `tp_bar_v2.zig`'s own doc comment for the direct before/after).

One real tradeoff this surfaces: v1's macro step doubled as the only way
to attach a SQL `COMMENT` to the function (`COMMENT ON FUNCTION` only
works on catalog objects like macros, not raw C-API-registered functions
— confirmed on both v1 and v2). v2 has **no way to run SQL at init time
at all** (no query/execute function on `ContextHandle`), so a v2
extension can't self-register a comment the way a v1 macro step could.
Named parameters are free in v2; comments are not. See
`docs/v2-migration-plan.md`'s "Function parameter naming & catalog
discoverability" section for the full investigation.

**Addendum (2026-10-12), confirmed by grepping the full header rather than
re-asserting the claim above**: v2 is not entirely without a SQL-execution
API — `duckdb_v2_parse_sql`/`duckdb_v2_statement_bind`/
`duckdb_v2_statement_execute` (plus `statement_iterator_*`,
`sql_statement_*`, and a `result_*` family to consume what comes back)
form a genuine, if more involved, replacement for v1's one-shot
`duckdb_query`. But every one of those takes a `duckdb_v2_connection_handle`,
and nothing reachable from an extension's own init callback can produce
one: `ExtensionInput` (the struct `zig_ext_v2_init_c_api_v2` receives) has
exactly four fields — `get_api`, `extension`, `context`, `err` — no
`instance`, and there is no `context_get_connection`/`context_get_instance`
accessor anywhere in the header to derive one from the `context` it does
hand over. The `connection_create`/`instance_create` functions that DO
exist appear to belong to a separate, embedding-application half of the
v2 API (the moral equivalent of v1's `duckdb_open`/`duckdb_connect`), not
anything an extension being *loaded* can call on itself. Worth flagging
precisely: the header's own doc comment on `ExtensionInput.context` calls
it "a borrowed context to read and run queries through" — which reads as
if this should be possible — but no function taking a `ContextHandle`
(as opposed to a `ConnectionHandle`) to run a query exists anywhere in
this build's vtable. Either the comment describes an intended-but-not-yet-
wired capability, or the connecting accessor simply hasn't landed yet in
this alpha. Conclusion unchanged — a v2 extension still can't self-
register a comment at init time in this build — but now backed by an
exhaustive header search rather than an absence-of-evidence inference.

### 7. Aggregate functions are batched at every stage, not one-row-at-a-time

v1 aggregates process one row into one state per `update` call. v2's
`update`/`combine`/`finalize` each receive an *array* of state pointers
(one per row, or per group) to process together in one call — the
biggest structural departure from v1 this branch encountered.
`comptime_aggregate_v2.zig`'s doc comment calls this out explicitly as
"new design, not a port" for exactly this reason (there's no v1
`comptime_aggregate.zig` to port from).

### 8. A separate, versioned static-linking mechanism exists (not yet used)

`duckdb_static_extension.h`'s `duckdb_register_static_extension()` +
`duckdb_extension_descriptor` is a distinct registration path from the
loadable-extension vtable dance above — relevant only if this project
ever ships a statically-linked build. See
`docs/v2-migration-plan.md`'s "Static linking" section; not implemented,
not verified against a live runtime, kept out of this ADR's "Decision"
scope since nothing here depends on it.

## Consequences

- `src/lib/duckdb_v2.zig` mirrors `duckdb.zig`'s `getApi()`-singleton
  pattern unchanged (copy the vtable by value in `initApi`, since DuckDB
  may free the memory `get_api` returned after the entrypoint returns) —
  that part of the v1 design carries over exactly.
- Every new primitive this ADR describes (`Opaque`, `BytesValue`,
  `ListEntry`, `contextCreateListType`, `valueCreateTypeWithContext`) has
  a corresponding wrapper in `duckdb_v2.zig`, each with its own doc
  comment pointing back to the specific difference above.
- The comptime frameworks (`comptime_scalar_v2.zig`,
  `comptime_table_v2.zig`, `comptime_aggregate_v2.zig`) each had to
  rebuild VARCHAR support independently — v1's `comptime_scalar.zig` also
  never supported VARCHAR (see ADR-0002's "Future Work"), so this wasn't
  a port of existing VARCHAR-handling comptime code, it's new in both
  v1 and v2 terms, done once for v2 as part of this branch.
- Future v2 binding work (STRUCT support, VARCHAR in the aggregate
  framework, the comptime table-function generalization) should extend
  the patterns above rather than introduce new ones — see
  `docs/v2-migration-plan.md`'s "What's NOT done" for the specific,
  scoped next steps.
