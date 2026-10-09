# DuckDB v2 C Extension API — Migration Plan

## Status: in progress, paused

Branch: `duckdb-v2-api`. This document picks up from the prototype work
done so far and scopes what's left before the real `zig_ext` extension
could actually cut over from v1 to v2. Nothing here is scheduled — it's a
map for whoever (or whichever future session) picks this back up.

## Where things stand

All 9 functions in the real v1 extension (`add_numbers`, `ct_add_numbers`,
`hello`, `tp_bar`, `tokenize`, `ct_tokenize`, `tp_line`, `tp_treemap`,
`tp_snakemap`) have a working, verified `*_v2.zig` counterpart, registered
by `src/ext/init_v2.zig` and built by `zig build ext-v2` into a real,
parallel `zig_ext_v2.duckdb_extension` — completely separate from the v1
`zig build` → `zig_ext.duckdb_extension` target, which this work never
modified except for one pure, verified-behavior-preserving refactor (see
"Known risk" below).

Binding layer: `src/lib/duckdb_v2.zig` (vtable singleton + wrapped
functions) plus three comptime frameworks — `comptime_scalar_v2.zig`
(full per-row-function → vectorized-callback generation, including
VARCHAR), `comptime_table_v2.zig` (thin registration helper, caller
supplies bind/exec), `comptime_aggregate_v2.zig` (full
init/update/combine/finalize generation from a `State` type, including an
optional-return convention for NULL output).

Proven against a live `v2.0.0-alpha46057` runtime (installed via
`DUCKDB_VERSION=alpha bash <(curl https://install.duckdb.org)`, not
vendored — see "Testing infrastructure gaps" below): scalar, table, and
aggregate functions; native named parameters + defaults; VARCHAR (inline
and pointer/arena encoding); LIST(T) including parallel multi-LIST
arguments; BOOLEAN; non-additive aggregate `combine`; NULL propagation
throughout.

Two real bugs found and fixed along the way (both documented in their
commit messages and the relevant file's doc comments): a use-after-free
from returning a rendered string out of its own arena's scope
(`tp_line_v2.zig`), and a missing NULL-output path in the aggregate
framework before `finalize`'s optional-return convention was added.

## What's NOT done

### 1. Cleanup / consolidation

- **`duckdb_v2.zig` mixes real bindings with throwaway worked examples.**
  `example`, `varchar_example`, `table_example`, `aggregate_example` and
  their `*ForPoc` re-exports exist purely so `src/ext/init_v2_poc.zig`
  (a disposable experimentation harness) has something to register — they
  were never meant to be part of the permanent bindings file, and v1's
  `duckdb.zig` has no equivalent clutter. Move them into a dedicated
  `src/lib/duckdb_v2_examples.zig` or delete the ones already superseded
  by a real `*_v2.zig` port (e.g. `example.doubleExec` is now redundant
  with `add_numbers_v2.zig`'s logic).
- **No automated v1-vs-v2 parity test.** Every verification this session
  was a manual, one-off `duckdb -c "..."` comparison. Before trusting this
  branch long-term, write a real test harness — e.g.
  `test/sql/v2_parity.sql` run against both `zig_ext.duckdb_extension` and
  `zig_ext_v2.duckdb_extension`, diffing output — covering at minimum the
  cases already exercised by hand in this session's commits (NULL
  handling, empty lists, defaults, named args, GROUP BY multi-state,
  scale checks).
- **`build.zig` has grown a lot of near-duplicate step boilerplate**
  (`v2_poc_lib`/`ext_v2_lib`, their metadata tools, append steps). Worth a
  small helper function once the shape stabilizes (e.g.
  `fn addDuckdbExtension(b, name, root_file, duckdb_version, ext_version,
  imports) -> step`) rather than hand-copying the ~15-line pattern a
  fourth time.
- **Write ADR-0003** documenting the v1→v2 API shape differences for
  future readers, mirroring 0001/0002's format: the error-code +
  out-param calling convention, context-based (not handle-less) type
  construction, the `Opaque{ptr, destroy, equals}` box for state requiring
  cleanup, VARCHAR's `duckdb_v2_bytes` inline/arena layout vs the plain
  `duckdb_v2_str` used for API in/out params, and LIST's
  `vector_get_child` + `list_entry` mechanism (shared with STRUCT/MAP/
  UNION, unlike v1's LIST-specific accessor).

### 2. STRUCT support

No current function needs it, but it's the natural next composite-type
gap, and several `vector_get_child`/`vector_get_child_count` semantics
already in `duckdb_v2.zig` are STRUCT-ready (per their own doc comments:
"STRUCT and TUPLE `[i]` = field `i`"). Scope:

- Logical type construction: STRUCT needs named parameters (one per
  field), unlike LIST's single positional one —
  `context_create_type_from_id`'s `param_names` array (currently always
  passed `null` by `contextCreateListType`) would need real identifiers.
- Reading: no `list_entry`-style offset/length indirection — each child
  vector is already aligned 1:1 with the parent's rows, read directly.
- Writing: likely needs the same `Value`-boxing approach VARCHAR uses
  (`value_create_struct_with_context`-equivalent, if one exists — not yet
  checked) rather than a direct-buffer write.
- A reasonable first target: a STRUCT-typed argument to a scalar function
  (read-only), before attempting a STRUCT-returning function.

### 3. Comptime table-function framework generalization

`comptime_table_v2.Function` today is deliberately thin — the caller
writes real bind/init_global/exec callbacks by hand, same as v1's
`comptime_table.zig`. A genuine generalization (mirroring what
`comptime_scalar_v2.Function` already does: derive the vectorized
plumbing from a plain per-row shape) would mean something like:

```zig
comptime_table_v2.Function("my_source", struct {
    pub const Row = struct { a: i64, b: []const u8 };
    pub fn next(state: *MyState) ?Row { ... } // pull-iterator shape
});
```

generating bind (result columns from `Row`'s fields, via the same
`duckdbV2TypeId` mapping `comptime_scalar_v2` already has), init_global,
and an exec loop that calls `next()` until it returns `null`, writing each
field through the same numeric/VARCHAR-aware machinery
`comptime_scalar_v2`'s `execute` already has. This is new design, not a
port — scope it as its own task, probably after STRUCT support (a `Row`
is structurally a STRUCT), and expect it to be more involved than any
single thing built so far this session.

### 4. VARCHAR support for comptime aggregates

`comptime_aggregate_v2.zig`'s `duckdbV2TypeId` has no `[]const u8` case,
unlike the scalar framework. Two separable increments:

- **VARCHAR as an `update` argument only** (e.g. a `count_distinct`-style
  aggregate that reads strings but accumulates a non-string state) — a
  direct mirror of `comptime_scalar_v2`'s arg-decode branch
  (`BytesValue`/`bytesSlice`), no new state-ownership concerns.
- **VARCHAR as `finalize`'s return type** (e.g. "concatenate all values in
  the group") — needs `finalize`'s write path to box through `Value`
  instead of a flat buffer, mirroring `comptime_scalar_v2`'s
  `return_is_varchar` branch, straightforward on its own.
- **A `State` that owns growable string/list data** (e.g. real
  `string_agg`, or the "collect subtree values into a list" aggregate
  discussed but deferred this session) is a different, harder problem:
  `@sizeOf(State)` is fixed at registration time, so the state can only
  hold a pointer+len to a separately heap-allocated buffer, grown in
  `update` and freed via `aggregateFunctionSetDestroyCallback` — which no
  aggregate built this session has exercised yet (confirmed unused: the
  vtable function exists, nothing calls it). This is the natural next
  frontier for the "holistic aggregates" direction raised earlier and
  explicitly deferred — do VARCHAR-as-argument and VARCHAR-as-return
  first, since they're much smaller and de-risk the type-system changes
  before adding dynamic-state lifecycle on top.

### 5. Smaller, scoped gaps (not blocking anything above)

- **Other v2-only table-function features never touched**: filter
  pushdown (`table_function_filter_pushdown_*`), progress reporting
  (`table_function_progress_*`), and partitioning/batch-claiming hooks —
  all real v2 capabilities with no v1 equivalent, identified early in this
  branch's exploration but never built against. Relevant if `tree_scan`/
  `ps_scan`-style long-running scans ever move to v2.
- **Other scalar numeric types untested live**: `i8`/`i16`/`i32`/`f32`
  are mapped in `duckdbV2TypeId` but only `i64`/`f64`/`bool`/`[]const u8`
  have actually been registered and called against the real runtime.
  DECIMAL, ENUM, BLOB, DATE/TIME/TIMESTAMP/INTERVAL are entirely
  unmapped.
- **Aggregate `destroy` callback** — exists in the vtable
  (`aggregateFunctionSetDestroyCallback`-equivalent name,
  confirm exact wrapper needed), never wired up by any aggregate built so
  far since none owned resources requiring cleanup.

### 6. The real cutover decision

Once the gaps above (or whichever subset is judged sufficient) are closed,
the actual decision point is replacing `zig build`'s real `lib`/`ext`
targets' v1 bindings with v2 — deleting `duckdb.zig`, `comptime_scalar.zig`,
`comptime_table.zig`, the v1 `duckdb_capi/duckdb.h`/`duckdb_extension.h`
headers, and every `src/functions/*.zig` (non-`_v2`) file, renaming the
`_v2` files back to their plain names. This is a one-way door this session
deliberately avoided (see the "parallel artifact, not replace" choice made
earlier in this branch) and should stay that way until:

- DuckDB 2.0 actually ships (this is all built against a staged alpha —
  `v2.0.0-alpha46057` — not a release),
- the gaps above are closed to whatever bar feels sufficient, and
- there's a real automated parity test suite (see "Cleanup" above) to
  catch regressions the manual verification this session relied on might
  miss.

## Known risk carried forward

`src/functions/tp_snakemap.zig` is untracked in git (pre-existing from
before this branch, never committed by anyone) and was refactored in this
branch to extract `renderSnakemap` as a reusable function — verified
behavior-preserving via a manual before/after output diff (not `git
stash`, since stash doesn't apply to untracked files without `-u`). If
this branch is rebased, cherry-picked, or merged in a way that touches git
history around that file, re-verify the refactor the same way: capture
`tp_snakemap` output from `main` before merging, compare after.

## Testing infrastructure gaps

- The `v2.0.0-alpha46057` CLI this entire branch was verified against
  lives at `~/.duckdb/cli/2.0.0-alpha46057/duckdb` on this machine only —
  installed via `DUCKDB_VERSION=alpha bash <(curl
  https://install.duckdb.org)`, not vendored or pinned anywhere in the
  repo. Any other machine (or CI) re-running these functions needs the
  same install step, and the alpha build number will drift over time.
  Worth deciding whether to vendor a specific build (like
  `duckdb_capi/duckdb_v2.h` already is) or document the install command
  somewhere durable (this file, or a `task` recipe).
- `zls` (Zig language server) for 0.17.0 has no tagged release yet either
  — this session built it from `zigtools/zls`'s `master` branch (versioned
  `0.17.0-dev`) and installed it to `~/.local/bin/zls`, also
  machine-local and also likely to need rebuilding once a tagged 0.17
  release exists upstream.
