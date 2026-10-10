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
VARCHAR, a one-level STRUCT argument, and VARIANT as an argument or return
type), `comptime_table_v2.zig` (full bind/exec generation from a
`Row`/`init`/`next` `State` type, including VARCHAR arguments/columns),
`comptime_aggregate_v2.zig` (full init/update/combine/finalize generation
from a `State` type, including an optional-return convention for NULL
output, VARCHAR as an argument or return type, and an optional `deinit`
hook for states owning growable/heap-allocated resources).

Proven against a live `v2.0.0-alpha46057` runtime (installed via
`DUCKDB_VERSION=alpha bash <(curl https://install.duckdb.org)`, not
vendored — see "Testing infrastructure gaps" below): scalar, table, and
aggregate functions; native named parameters + defaults; VARCHAR (inline
and pointer/arena encoding); LIST(T) including parallel multi-LIST
arguments; STRUCT (scalar argument direction only); VARIANT (scalar
argument and return); BOOLEAN; non-additive aggregate `combine`; NULL
propagation throughout, including VARIANT's deliberate opt-out of it.

Two real bugs found and fixed along the way (both documented in their
commit messages and the relevant file's doc comments): a use-after-free
from returning a rendered string out of its own arena's scope
(`tp_line_v2.zig`), and a missing NULL-output path in the aggregate
framework before `finalize`'s optional-return convention was added.

## Patterns established this session (worth keeping consistent going forward)

### NULL propagation

Every port this session follows the same NULL-handling shape, worth
stating explicitly so future functions don't reinvent or drift from it:

- **Row-level: skip the row if *any* argument is invalid.** Every scalar/
  table/aggregate `update` callback checks all of its argument vectors'
  `VectorView.validity` for the current row before doing any work, via a
  small per-file `isValid`/`rowIsValid`/`anyInvalid` helper (duplicated by
  hand in each `*_v2.zig` file rather than factored out — a candidate for
  the "Cleanup" consolidation above). `comptime_scalar_v2.zig` generates
  this check automatically from the registered parameter list;
  hand-written functions (`add_numbers_v2`, `tp_bar_v2`, `tokenize_v2`,
  `tp_line_v2`, `tp_treemap_v2`, `tp_snakemap_v2`) each re-derive it.
- **Fast/slow path split**: when *no* argument vector has a validity
  bitmap at all (`view.validity == null` for every arg), skip the
  per-row validity check entirely rather than calling a no-op check
  `row_count` times — carried over faithfully from v1's equivalent
  optimization in `comptime_scalar.zig`.
- **Result-level, for aggregates: a `has_value`-style flag distinguishes
  "legitimately computed a zero/default" from "never updated."**
  `zig_v2_weighted_avg_ct` and `zig_v2_arg_max_ct` both carry this in
  their `State` (`weight_sum == 0` and `has_value`, respectively) so an
  empty or degenerate group's `finalize` can return SQL `NULL` via the
  framework's `?ReturnType` convention, instead of a bogus or
  IEEE-754-leaked value.
- **Concrete evidence this matters**: DuckDB's own built-in `weighted_avg`
  macro — `sum(v*w) / sum(CASE WHEN v IS NOT NULL THEN w ELSE 0 END)` —
  returns `-nan` for an all-zero-weight group, because both sums are
  genuinely `0.0` (not SQL NULL) and float division leaks the IEEE-754
  bit pattern straight into the result column. Our `zig_v2_weighted_avg_ct`
  returns proper `NULL` for the identical input, confirmed side-by-side.
  `NaN`-vs-`NULL` is invisible until you specifically test the degenerate
  case — anything with a division (ratios, averages) should get this test
  deliberately, not as an afterthought.

### Function parameter naming & catalog discoverability

Investigated with an eye to
[posit-dev/ggsql-duckdb#16](https://github.com/posit-dev/ggsql-duckdb/issues/16)
(DuckDB extension functions should be discoverable — real parameter
names, descriptions, examples — from `duckdb_functions()`, since an
agent connected to a database can't read a README). Findings, confirmed
live:

- **v2's native named-parameter support means every hand-registered
  function already gets real parameter names in the catalog, for free.**
  `functionSignatureAddParameter` requires a real name per parameter, so
  anything registered by hand (`tp_bar_v2`, `hello_v2`, ...) shows real
  names: `SELECT parameters FROM duckdb_functions() WHERE function_name =
  'tp_bar'` → `[value, on, off, width]`. No macro wrapper needed, unlike
  v1 (see next point).
- **`comptime_scalar_v2.Function(name, implFn)` synthesizes `a0`/`a1`**
  (documented in its own doc comment, since Zig function parameters carry
  no names at the ABI level) — confirmed live: `ct_add_numbers` shows
  `[a0, a1]` in the catalog, exactly the anti-pattern the issue flags.
  **Fix, not yet done**: extend `Function()` (and `comptime_table_v2`/
  `comptime_aggregate_v2`) to accept real names, e.g. a `Cfg`-style struct
  like `comptime_table_v2` already uses, or a parallel tuple argument.
  Small, concrete, matches the issue's stated highest-leverage ask
  ("if you only do one thing, do parameter names").
- **`description`/`examples`/`categories` are unreachable from the C
  extension API in both v1 and v2** — grepped both vendored headers for
  anything resembling C++'s `FunctionDescription`; nothing exists. Not a
  comptime-solvable gap; it's a missing C-API hook in DuckDB itself.
- **The one partially-reachable field, SQL `COMMENT ON FUNCTION`, only
  works on real catalog objects (macros), not raw C-API-registered
  functions** — confirmed live on both versions: `COMMENT ON FUNCTION
  zig_add_numbers ...` fails with `"Can not comment on System Catalog
  entries"` whether registered via v1 or v2, hand-written or comptime.
  It *does* work on v1's macro-wrapped functions (`tp_bar`, `tp_line`,
  `tp_treemap`, `tp_snakemap`) — confirmed: `comment` populates correctly
  in `duckdb_functions()` after `COMMENT ON FUNCTION tp_bar IS '...'`.
- **v2 extensions have no way to run SQL at init time at all** — checked
  the `context` handle's full function surface for anything
  query/execute-shaped; nothing exists (consistent with its own doc
  comment: "for constructing values and types, not for registration").
  v1's `db.query(conn, "CREATE OR REPLACE MACRO ...")` has no v2
  equivalent. This means v2 can't self-register a `COMMENT ON FUNCTION`
  the way a v1 extension's macro-wrapper step could — a genuine,
  previously-unnoted tradeoff of eliminating the macro-wrapper
  requirement: v2 wins on parameter names without a macro, but loses the
  one mechanism that let v1 attach a `comment` at all.
- **Possible follow-on** (not scoped in detail, not started): a comptime
  macro+comment emitter for v1-targeted extensions — four of the nine v1
  functions (`tp_bar`, `tp_line`, `tp_treemap`, `tp_snakemap`) already
  hand-write a near-identical `CREATE OR REPLACE MACRO` string purely for
  named-parameter calling convenience; a `comptime_scalar.FunctionWithMacro`-
  style helper could generate that SQL *and* a `COMMENT ON FUNCTION` from
  a declared description, from the same param-name/default info the
  framework already has — real deduplication and ggsql#16 compliance in
  one change, for v1. No v2 equivalent is possible until/unless v2 gains
  an init-time SQL-execution capability.

## Patterns worth reusing (from reviewing `quack-zig`)

[`quack-zig`](https://github.com/duckdb/duckdb) (a Zig-built port of
DuckDB's official "quack" example extension — plain C extension source,
`build.zig` doing cross-compilation/matrix orchestration rather than
language-level API bindings) has several techniques directly relevant to
gaps already identified above.

### Version × platform build matrix

Their `build.zig` loops `for (duckdb_versions) |v| for (platforms) |p|`,
each combination its own `b.addLibrary`, selectable via repeatable
`-Dduckdb-version=`/`-Dplatform=` options (default: build everything).
Applied to this project, the matrix would be **DuckDB v1.5.6 and v2.0
alpha × {linux, windows, macos}** (amd64/arm64 each, so really 2×6):

```zig
const DuckDBVersion = enum {
    v1_5_6,
    v2_0_alpha,
    // headers(self, b) -> Build.LazyPath, same shape as quack-zig's,
    // but v2.0-alpha has no tagged GitHub release to fetch from yet —
    // would need to stay a local/untracked header set (see "Testing
    // infrastructure gaps") until DuckDB actually tags v2.0.
};
const Platform = enum {
    linux_amd64, linux_arm64,
    windows_amd64, windows_arm64,
    macos_amd64, macos_arm64,
    // target(self, b) -> Build.ResolvedTarget via resolveTargetQuery,
    // identical mechanism to quack-zig's.
};
```

This is a bigger lift than it looks for us specifically, because unlike
`quack_extension.c` (single C file, no OS-specific code), our `*_v2.zig`
files use `std.heap.page_allocator`/`std.heap.c_allocator` and arena
allocators throughout — worth a quick check that cross-compiled Windows/
macOS targets don't hit a libc or allocator availability snag before
assuming the matrix "just works" the way it does for quack-zig's pure-C
code. Scope as: get `linux_amd64` × both DuckDB versions working first
(already true today, just not expressed as a matrix), then add the other
5 platform combinations one at a time, not all at once.

### Git-derived extension version

```zig
fn detectGitVersion(b: *std.Build) ![]const u8 {
    return b.runAllowFail(&.{"git", "-C", ..., "describe", "--tags",
        "--match", "v[0-9]*", "--always"}, &code, .Ignore);
}
```

Replaces our hardcoded `extension_version = "v0.1.0"` constant in
`build.zig`. Small, worth adopting whenever this project starts tagging
releases — no value before then.

### Version-pinned DuckDB header vendoring

`build.zig.zon` dependencies with real content hashes, fetched from
DuckDB's own tagged GitHub releases:

```zig
.libduckdb_1_5_6 = .{
    .url = "https://github.com/duckdb/duckdb/releases/download/v1.5.6/libduckdb-src.zip",
    .hash = "...", // from `zig fetch`
},
```

Directly addresses the "Testing infrastructure gaps" complaint below:
this project's `duckdb_capi/duckdb.h`/`duckdb_extension.h` (v1.2.0) are
committed as plain vendored files with no provenance/hash, and the
v1.5.6/v2.0-alpha headers used for comparison this session were manually
`curl`'d into a scratchpad and never pinned anywhere. Applies cleanly to
v1.5.6 (tagged release exists); **does not yet apply to v2.0-alpha** —
`install.duckdb.org`'s staged alpha build isn't a tagged GitHub release,
so there's nothing a `url`+`hash` pair could point at yet. Revisit once
DuckDB publishes an actual v2.0 release artifact.

### sqllogictest adoption

Covered in detail in the prior findings (`require <ext>` / `statement ok`
/ `query I` + `----` + expected output, run via `uv run --with
sqllogictest --with duckdb==X python3 -m duckdb_sqllogictest`). This is
the concrete mechanism to close the "No automated v1-vs-v2 parity test"
gap below — replace the planned `test/sql/v2_parity.sql` ad-hoc script
with real `.test` files, one set run against `zig_ext.duckdb_extension`
and the same set run against `zig_ext_v2.duckdb_extension`, asserting
identical output DuckDB-natively rather than via a hand-rolled diff.

### Metadata appender checkup — done, no drift found

Fetched DuckDB's own `extension-ci-tools@v1.2.0`
`scripts/append_extension_metadata.py` directly and ran both it and our
`append_metadata_main.zig` against the identical raw, pre-metadata
`libzig_ext.so`, with matching arguments (`zig_ext`, `v1.2.0`, `v0.1.0`,
`C_STRUCT`, platform `linux_amd64`). Compared outputs with `cmp` and
`sha256sum`, not just "does DuckDB load it": **byte-for-byte identical**,
same SHA256. Our hand-rolled implementation has accumulated no drift from
the real format — nothing to fix, no reason to switch to shelling out to
the official script the way `quack-zig` does.

## Patterns worth reusing (from reviewing `habedi/template-duckdb-extension-zig`)

A third DuckDB-extension-in-Zig project, structured differently from both
this one and `quack-zig`: C owns all DuckDB API interaction
(registration, vector iteration, validity masks), Zig is reduced to
`export fn`s doing isolated pure computation, called from C via FFI. Named
explicitly to confirm this project's all-Zig approach (including the
vectorized/validity-mask code, not just leaf computations) is a
deliberate choice consistent with ADR-0001/0002, not a missed simpler
option. Two of its ideas were worth adopting directly, done this round:

### `zig build duckdb-extension` / `duckdb-extension-v1` — interactive REPL with the extension pre-loaded

Added. The template computes the installed extension's path as a plain
string at configure time (`b.getInstallPath`) and writes an init script
via `addWriteFiles()`. **That doesn't carry over to this project's Zig
version**: 0.17 split build.zig execution into a "Configurer" (evaluates
the build graph) and a "Maker" (actually runs steps) — `b.getInstallPath`
doesn't exist at all in 0.17's `std.Build` (confirmed: removed), because
no concrete filesystem path is known until make time. Adapted instead
with `-cmd` (DuckDB CLI runs one command, then drops into the REPL,
unlike `-c` which exits afterward) combined with `Step.Run.addFileArg2`'s
`prefix`/`suffix` options, which build `"LOAD '<path>';"` as a single argv
token with the path substituted lazily, at the point the step actually
runs — no string available, or needed, at configure time. Verified
correct directly: the exact command Zig printed when the step hit an
unrelated, pre-existing `~/.duckdbrc` issue (`LOAD
'./.zig-cache/.../zig_ext.duckdb_extension';`) was byte-correct, and
running that same `-cmd` manually with the dotfile bypassed loaded the
extension and ran `zig_add_numbers(2,3)` correctly.

### `zig build docs` / `docs-v2` — Zig's built-in autodoc

Added, via the existing `lib`/`ext_v2_lib` compile steps'
`getEmittedDocs()` + `addInstallDirectory`, rather than the template's
separate `zig build-lib -fno-emit-bin -femit-docs=...` shell-out — reusing
the real compile step means the actual module graph (`duckdb_c`/
`duckdb_v2` imports, etc.) is picked up automatically instead of needing
to be reconstructed by hand for a standalone invocation. Output:
`zig-out/docs/index.html` (v1), `zig-out/docs-v2/index.html` (v2) — free
documentation given how extensively this project already uses `///!` doc
comments.

## What's NOT done

### 1. Cleanup / consolidation — done

- **Examples moved out of `duckdb_v2.zig`.** `example`, `varchar_example`,
  `table_example`, `aggregate_example` and their `*ForPoc` re-exports now
  live in `src/lib/duckdb_v2_examples.zig`, importing `duckdb_v2` as a
  module rather than sharing its namespace. `duckdb_v2.zig` keeps only
  the two tests that exercise its own bindings. Pure move, verified via
  identical live behavior before/after against the v2.0.0-alpha46057
  runtime.
- **`build.zig` duplication factored out.** The "metadata-tool-executable
  + run + 4 args + output-file-arg" pattern, hand-copied three times
  (v1's real extension, the real v2 extension, the v2 proof-of-concept),
  is now `addDuckdbExtensionMetadata(b, lib, name, duckdb_version,
  ext_version, abi) -> LazyPath`. ~35 lines removed; metadata tool names
  are now derived from the extension name instead of three independently
  chosen literals.
- **ADR-0003 written** — `docs/rationale/0003_duckdb-v2-c-api-differences.md`,
  mirroring 0001/0002's format: the error-code + out-param calling
  convention, context-based (not handle-less) type construction, the
  `Opaque{ptr, destroy, equals}` box for state requiring cleanup,
  VARCHAR's `duckdb_v2_bytes` inline/arena layout vs the plain
  `duckdb_v2_str` used for API in/out params, LIST's `vector_get_child` +
  `list_entry` mechanism (shared with STRUCT/MAP/UNION), native named
  parameters/defaults (and the comment-ability tradeoff that comes with
  dropping macros), aggregate batching, and static linking.
- **Automated sqllogictest adoption for v1 — done; v2 confirmed blocked,
  not a bug.** `zig build sqllogictest` runs DuckDB's native `.test`
  format (`test/sql/zig_ext.test`) via `uv run --with
  duckdb-sqllogictest@<github-zip> --with duckdb==1.2.0 python3 -m
  duckdb_sqllogictest`, the same mechanism `quack-zig` uses. Two real
  findings along the way, both confirmed by testing rather than assumed:
  - The pip-distributed `duckdb` package enforces a stricter platform tag
    (`linux_amd64_gcc4`) than this project's `append_metadata_main.zig`
    emits (plain `linux_amd64`) — an axis entirely orthogonal to
    code-signing (`-unsigned` doesn't touch it). Fixed by `SET
    allow_extensions_metadata_mismatch=true` in the test file itself, a
    real DuckDB setting for exactly this case — not a workaround specific
    to this project, and not something to "fix" by changing our platform
    string (which is accurate; the gcc4 tag is about glibc-compat
    maximalism this project's Zig/clang-built `.so` doesn't need to
    claim).
  - **v2 cannot be sqllogictest'd via this mechanism at all right now**:
    there is no v2-capable `duckdb` PyPI package (v2.0 is a staged alpha,
    not released), and the v1-era package that does exist looks for the
    old `<name>_init_c_api` symbol, not `_init_c_api_v2` — confirmed
    directly: `duckdb.duckdb.IOException: ... did not contain function
    "zig_ext_v2_init_c_api"`. `test/sql/zig_ext_v2.test` is written and
    kept (same cases as the v1 file) for the moment a v2-capable package
    exists, but has no working `zig build` step yet. Until then, v2
    verification stays the live-runtime-CLI comparisons this branch
    already relies on.

### 2. STRUCT support — argument direction done; VARIANT also added

`comptime_scalar_v2.Function` now accepts a one-level Zig `struct`
parameter type, mapped to SQL STRUCT. Each increment from this section's
original scope landed as expected:

- **Logical type construction**: `contextCreateStructType` in
  `duckdb_v2.zig` takes real field names (unlike `contextCreateListType`'s
  single positional child) — builds one named TYPE-kind `Value` parameter
  per field via the same `value_create_type_with_context` dance, then
  calls `context_create_type_from_id(ctx, STRUCT, names, values, n, ...)`.
- **Reading**: confirmed no `list_entry`-style indirection — each field's
  child vector (`vectorGetChild(vec, field_index, ...)`) is already
  aligned 1:1 with the parent's rows, flattened and view-cached exactly
  like a plain argument. DuckDB's nested-NULL invariant (a NULL STRUCT row
  implies NULL field rows) means per-field validity checks are sufficient
  on their own — no separate STRUCT-level validity check needed.
- **Writing**: confirmed `value_create_struct_with_context` exists, but
  **not implemented** — STRUCT-typed *return* values stay out of scope, as
  originally planned ("a reasonable first target: argument only").
- A new, dedicated exec path (`executeStruct`) handles STRUCT arguments —
  the existing numeric/VARCHAR path is untouched, kept simple by not
  trying to unify the two.

Verified live against `v2.0.0-alpha46057`: `zig_v2_point_dist2_ct`
(`STRUCT(x BIGINT, y BIGINT)` → BIGINT, including a NULL struct row
propagating to NULL output) and `zig_v2_person_greet_ct` (a STRUCT with a
VARCHAR field, mixed with a plain BIGINT argument).

**Also added while investigating this, not originally scoped: VARIANT.**
`db.ValueHandle` as a parameter or return type maps to SQL VARIANT.
VARIANT has no committed view layout at all (confirmed: `vectorGetView`
doesn't support it), so a third dedicated path (`executeDynamic`) reads/
writes one boxed `Value` per row via `vectorGetValue`/`vectorSetValue`
instead of the flatten+view machinery every other type uses. Two
load-bearing, non-obvious findings, both confirmed live, both documented
in `comptime_scalar_v2.zig`'s module doc comment and `duckdb_v2.zig`'s
wrapper comments so they aren't rediscovered the hard way again:

- `context_create_type_from_id(ctx, VARIANT, null, null, 0, ...)`
  **segfaults** in DuckDB's own C++ internals on this alpha build, despite
  VARIANT needing no parameters at the SQL level (`SELECT 1::VARIANT`
  works fine from the CLI). Worked around with the new
  `contextCreateTypeFromText(ctx, "VARIANT", ...)`, which parses the type
  from SQL text instead and doesn't hit the bug.
- A VARIANT argument's NULL does **not** participate in the framework's
  usual "any NULL argument skips the row" convention — SQL NULL is
  ordinary data VARIANT can hold, not an absent argument, so `implFn`
  always runs and decides what NULL means itself via the new
  `valueIsNull` wrapper. This also required declaring
  `FUNCTION_PROPERTY_NULL_HANDLING_SPECIAL` (new
  `scalarFunctionSetNullHandlingSpecial` wrapper) for any VARIANT-involving
  function — without it, DuckDB constant-folds a literal NULL argument
  straight to a NULL result without ever calling the function at all,
  confirmed live (`SELECT my_fn(NULL::VARIANT, ...)` never reached our
  code until this was set).
- Constructing any `Value` needs a context, which `implFn` has no other
  way to reach — so a VARIANT-involving `implFn` takes
  `context: db.ContextHandle` as its first parameter, not counted as a SQL
  parameter.

Verified live: `zig_v2_variant_default_ct(v VARIANT, fallback BIGINT) ->
VARIANT` — decodes `v` when non-NULL, substitutes `fallback` otherwise,
always returning a freshly created `Value` (never the same handle received
as the argument — the framework destroys the argument and the return
value independently, so returning the same handle would double-free it,
confirmed live and documented as a CAUTION). Exercised over a literal
constant, a table column with real NULLs, and 20k rows.

### 3. Comptime table-function framework generalization — done

`comptime_table_v2.Function(name, State)` now generates bind/exec from a
plain `State` type instead of requiring hand-written callbacks:

```zig
comptime_table_v2.Function("my_source", struct {
    pub const Row = struct { a: i64, b: []const u8 };
    pub fn init(n: i64) @This() { ... }       // constructor args -> SQL params
    pub fn next(self: *@This()) ?Row { ... }  // pull-iterator shape
    pub fn deinit(self: *@This()) void { ... } // optional cleanup
});
```

`Row`'s field names become the real output column names directly — unlike
`comptime_scalar_v2`/`comptime_aggregate_v2`, a struct's field names ARE
available at comptime, so no `a0`/`a1` synthesis is needed there (`init`'s
own parameters still get synthesized names, same as everywhere else, since
those are plain function parameters). `State` lives entirely in bind data
(no `init_global`/local-init callback used), forcing the same
single-threaded-scan model the hand-written v1/v2 table functions already
assume.

Proved against a real, non-trivial function, not just a toy example:
`ct_tokenize_v2.zig` (one of the 9 ported functions) was rewritten against
this framework — its custom, stateful tokenizing logic now expressed as a
plain `Row`/`init`/`next` `State`, bind/exec fully generated — verified
live, byte-identical output to the hand-written version it replaced.

One real bug found and fixed along the way: an output vector's size must
be set to its final row count *before* any row is written into it
(`vector_set_value` returns `"row out of range"` otherwise) — so `exec`
must pull a whole batch via `next()` first, then set sizes, then write,
not interleave pull-and-write per row as an earlier draft attempted. This
means a `Row`'s `[]const u8` field must stay valid for the whole `exec`
call, not just until the next `next()` call — safe when it borrows from
stable backing storage (`ct_tokenize_v2.zig`'s `State.input`), unsafe if
`next` reused one mutable scratch buffer across calls (documented as a
constraint in `comptime_table_v2.zig`'s module doc comment, not currently
enforced by the framework).

Not done: STRUCT-typed `Row` fields or arguments (naturally blocked on
item 2), and no cardinality hint (`tableFunctionBindSetCardinality`) is
set — the row count isn't knowable ahead of a pull iterator in general; a
`State` that can report an estimate up front could opt in later via an
optional declaration, not scoped here.

### 4. VARCHAR support for comptime aggregates — first two increments done

`comptime_aggregate_v2.zig`'s `duckdbV2TypeId` now has a `[]const u8` case.
Two increments landed; a third remains out of scope:

- **VARCHAR as an `update` argument — done.** `buildArgs` mirrors
  `comptime_scalar_v2`'s arg-decode branch exactly (`BytesValue`/
  `bytesSlice`); no new state-ownership concerns, as expected.
- **VARCHAR as `finalize`'s return type — done, but not as this section
  originally assumed.** The original plan said this would "box through
  `Value`, mirroring `comptime_scalar_v2`'s `return_is_varchar` branch" —
  **wrong**: confirmed via direct header grep that none of the aggregate
  callbacks (`size`/`init`/`update`/`combine`/`finalize`) take a `context`
  or `connection` parameter, unlike `bind` (the only aggregate callback
  that does). `value_create_varchar_with_context` needs a context, so the
  boxed-`Value` approach `comptime_scalar_v2` uses is unavailable here.
  The actual fix: `finalize` writes directly into the result vector's own
  arena. `duckdb_v2_vector_get_arena` only needs a vector handle (no
  context), so `duckdb_v2.zig` gained `ArenaHandle`/`vectorGetArena`/
  `arenaAllocate`/`makeBytesValue` wrappers that hand-construct a
  `duckdb_v2_bytes` directly — inlined for ≤12 bytes, arena-allocated
  otherwise — bypassing `Value` boxing entirely for this one case.
  Verified against the live v2.0.0-alpha46057 runtime (`zig_v2_total_len_ct`,
  `zig_v2_last_seen_ct`), including GROUP BY to exercise both the inline
  and arena-pointer `BytesValue` encodings under real parallel `combine`.
- **A `State` that owns growable string/list data — done.**
  `comptime_aggregate_v2.Function` accepts an optional fifth `State` decl,
  `pub fn deinit(self: *State) void`, for a state that holds a
  heap-allocated resource (`@sizeOf(State)` is fixed at registration time,
  so growable data can only live behind a separately allocated pointer —
  confirmed with a real `string_agg`-style aggregate,
  `zig_v2_string_agg_ct`, whose `State` holds a growable
  `std.ArrayList(u8)`). `deinit` is wired up as the aggregate's destroy
  callback, via new `aggregateFunctionSetDestroyCallback`/
  `DestroyGetStateCount`/`DestroyGetStates` wrappers in `duckdb_v2.zig` —
  the vtable function this plan previously noted as "exists, nothing calls
  it" is now exercised.

  **Real finding, the hard way**: an earlier version additionally called
  `deinit` right after `finalize` produced its result, on the assumption
  (matching the header's own doc comment on `set_destroy_callback`: "runs
  on states that are discarded without being finalized") that finalize and
  destroy are mutually exclusive per state. That crashed immediately on an
  ungrouped aggregate — a double-free caught by Zig 0.17's `ArrayList`
  pointer-stability assertion. Confirmed live: DuckDB's v2.0 alpha calls
  `destroy` on **every** allocated state, including ones `finalize`
  already ran on, not just the ones the header doc comment describes.
  `destroy` is the one and only place a state's resources may be
  released; `finalize` may read a resource `destroy` will later free
  (copying it out first — `makeBytesValue` already does this, into the
  result vector's arena) but must never free it itself. Verified against
  `v2.0.0-alpha46057`: ungrouped aggregation, `GROUP BY` (exercising
  `combine`'s discarded-source states), empty groups, and 50k rows across
  100 groups, all without a crash or leak.

### 4a. Real-scale aggregate benchmark: 1BRC — done

The plan's "Testing infrastructure gaps" section used to note that nothing
in this branch had been tested past ~1M rows / 1000 groups. Closed one
instance of that gap using
[nubskr/1BRC](https://github.com/nubskr/1BRC) (a hand-optimized Zig
solution to the "One Billion Row Challenge": mmap + 16-thread morsels +
custom hashmap, computing min/mean/max per weather station across a
billion `station;temperature` rows) as a real, independently-written
workload:

- Generated a 1-billion-row `measurements.txt` (13GB, 413 stations) with a
  small throwaway Zig generator, since that repo doesn't ship one.
- Built `zig_v2_1brc_stats_ct(temp DOUBLE) -> VARCHAR` via
  `comptime_aggregate_v2`: `State{sum, count, min, max}` plus an inline
  `buf: [32]u8` for `finalize` to format `"<min>/<mean>/<max>"` into,
  matching 1BRC's own output format exactly — the first test of
  non-additive `min`/`max` combine alongside additive `sum`/`count` in one
  aggregate, and the first VARCHAR-return `finalize` exercised at real
  (not toy) scale.
- **Correctness**: ran `SELECT station, zig_v2_1brc_stats_ct(temp) FROM
  read_csv(...) GROUP BY station` over all 1B rows — all 413 stations
  matched the hand-rolled Zig program's own output byte-for-byte, zero
  mismatches.
- **Performance**: ~3.15s for this one aggregate vs. ~3.22s for DuckDB's
  three separate built-in aggregates (`min`/`avg`/`max`) doing the
  equivalent work, both against the same `v2.0.0-alpha46057` runtime and
  CSV file — no measurable overhead from the comptime-generated code at
  this scale, slightly faster than built-ins doing the same work. (The
  hand-rolled Zig 1BRC program itself: ~0.39s — the gap there is
  mmap+custom-hashmap vs. a generic CSV reader + hash-aggregate, not
  specific to this framework.)
- **Real bug found via this test, not a toy case**: `finalize(self:
  @This())` copies the whole state by value; `zig_v2_last_seen_ct` (an
  existing VARCHAR-return aggregate from item 4 above) returned a slice
  into that copy's inline `buf` array — a dangling pointer the instant
  `finalize` returned, undetected until now because it only "worked" by
  luck of a Debug build's stack layout at small scale. Fixed by taking
  `self` by pointer instead (`*const`, or `*` when `finalize` needs to
  format into the buffer, as `zig_v2_1brc_stats_ct` does) — documented as
  a CAUTION in `comptime_aggregate_v2.zig`'s module doc comment, since a
  heap-backed slice return (e.g. `std.ArrayList(u8)`'s `.items`, as
  `zig_v2_string_agg_ct` uses) doesn't have this problem and by-value is
  still fine there.

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

### 6. Static linking (speculative, not started)

Everything built so far targets a **loadable** extension (`dlopen`ed
`.duckdb_extension`, entrypoint found by symbol name). Investigated static
linking as a different question — not reused from either reference
project: neither `quack-zig` nor `habedi/template-duckdb-extension-zig`
attempt it; both hardcode `DUCKDB_BUILD_LOADABLE_EXTENSION=1`
unconditionally. Confirmed absent from this project's vendored v1.2.0
header — this is v2.0-alpha-only territory, at least in what we have
vendored.

Two genuinely distinct mechanisms exist in the v2.0 alpha headers, easy to
conflate:

1. **A low-level macro branch inside `duckdb_extension_v2.h` itself**:
   ```c
   #ifdef DUCKDB_BUILD_STATIC_EXTENSION
   // No vtable global needed for static builds - DuckDB symbols are
   // resolved directly at link time
   #define DUCKDB_EXTENSION_GLOBAL
   #define DUCKDB_EXTENSION_API_INIT(input, minimum_api_version)
   #else
   ...
   ```
   Collapses the entrypoint macros to nothing, implying direct extern-
   linked DuckDB symbols — no `get_api`/vtable fetch at all, because the
   extension is compiled straight into the same binary as DuckDB (or
   linked against `libduckdb.a`). This would mean `duckdb_v2.zig`'s entire
   design (the `getApi()` singleton, copying the vtable by value in
   `initApi`) doesn't apply under this mode at all — a static build on
   this path needs a parallel binding layer built against the *full*
   `duckdb.h`/`duckdb_v2.h` (not the extension-specific vtable headers),
   linked directly against `libduckdb.a`. A substantial rewrite, not a
   toggle.
2. **A separate, richer mechanism — `duckdb_static_extension.h`'s
   `duckdb_register_static_extension()`**:
   ```c
   struct duckdb_extension_descriptor {
       uint32_t version;              // versioned layout, extensible
       const char *name;
       const char *extension_version;
       const char *api_version;
       void (*entry_cpp)(void);
       void (*entry_capi_v1)(void);   // bool (duckdb_extension_info, duckdb_extension_access*)
       void (*entry_capi_v2)(void);   // void (duckdb_v2_extension_input*) — same signature as our loadable entrypoint
       void (*database_callback)(void);
   };
   int32_t duckdb_register_static_extension(duckdb_extension_describe_t describe);
   ```
   `entry_capi_v2`'s signature is **identical** to
   `zig_ext_v2_init_c_api_v2`'s — same `duckdb_v2_extension_input*`
   parameter, same vtable-fetch-via-`get_api` convention running inside
   it. Only the *discovery* mechanism differs: instead of `dlopen`+`dlsym`
   finding a symbol named `<name>_init_c_api_v2`, the extension calls
   `duckdb_register_static_extension(describe)` once at startup, where
   `describe()` fills in `entry_capi_v2 = zig_ext_v2_init_c_api_v2`.
   **This project's existing `init_v2.zig` logic would very likely work
   unchanged under this path** — a thin wrapper, not a rewrite.

**If this is ever pursued, start with mechanism 2** — it reuses real,
already-verified code. Mechanism 1 is a different project in its own
right (direct-link bindings bypassing the vtable entirely) and only
worth it if a specific embedding scenario demands avoiding the vtable
indirection. Neither has been prototyped against a live runtime —
treat the "our entrypoint just works" claim for mechanism 2 as a
hypothesis to verify, not a confirmed fact, before relying on it. Not
urgent: nothing currently requires shipping this extension statically:
the use case would be embedding DuckDB+extension into another
application, or distributing a single self-contained `duckdb` binary
without the `LOAD`/`-unsigned`/signing friction a loadable extension
carries.

### 7. The real cutover decision

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
