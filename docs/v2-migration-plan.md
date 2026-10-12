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
functions) plus four comptime frameworks — `comptime_scalar_v2.zig`
(full per-row-function → vectorized-callback generation, including
VARCHAR, a one-level STRUCT argument, VARIANT as an argument or return
type, the smaller integer/float types, DATE/TIME/TIMESTAMP/INTERVAL,
BLOB, and DECIMAL/ENUM as an argument or return type),
`comptime_table_v2.zig` (full bind/exec generation from a
`Row`/`init`/`next` `State` type, including VARCHAR arguments/columns and
optional `pushdown`/`progress` hooks for filter pushdown and progress
reporting), `comptime_aggregate_v2.zig`
(full init/update/combine/finalize generation from a `State` type,
including an optional-return convention for NULL output, VARCHAR as an
argument or return type, an optional `deinit` hook for states owning
growable/heap-allocated resources, and an optional `updateBatch` SIMD fast
path for ungrouped aggregation), and `comptime_appender_v2.zig` (the same
Row-struct-driven pattern for v2's bulk-append-only Appender API, which
has no row-based Appender at all — primitives, VARCHAR, LIST, one-level
STRUCT, ARRAY, and ENUM).

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

### Version × platform build matrix — platform axis done (v1 only)

The platform half of the matrix landed as the new `zig build cross` step:
loops over a `cross_targets: []const std.Target.Query` array (currently
linux amd64/arm64, windows amd64, macos amd64/arm64 — the 5 combinations
beyond the host build this plan already had), each its own fully
self-contained `addCrossBuild(b, translate_c_dep, optimize, query)` call
(its own header translation, its own `b.addLibrary`, its own metadata
step) rather than threading a `target` parameter through the host build's
existing `duckdb_c`/`lib`, which are also used for the docs/v2-check/etc
steps that only make sense for the host target. Output lands under
`zig-out/lib/<platform>/zig_ext.duckdb_extension`.

Scoped to the real v1 extension only, not the matrix's original
DuckDB-version axis (v1.2.0 × v2.0-alpha) — v2.0-alpha has no tagged
release to version-pin against yet (see "Testing infrastructure gaps"
below), and cross-building the still-parallel, still-unreleased v2
extension is lower priority than the one that would actually ship. Revisit
once DuckDB 2.0 ships and header vendoring can be pinned the way v1's is.

**Real bug found immediately, not after the fact**: the metadata-appender
tool self-detected its platform string from its own compile target
(`builtin.target`) — always the build host, since the tool has to run
during the build and so is never itself cross-compiled. Every
cross-compiled extension would have silently gotten the HOST's platform
baked in, not the target's — a correctness bug invisible until someone
actually inspected the bytes, not something `zig build cross` succeeding
would have caught on its own. Fixed by making `append_metadata_main.zig`
take `platform` as an explicit CLI argument, computed per-target in
`build.zig` instead of self-detected. Verified past "it compiled": each
of the 5 cross targets produces the correct native binary format (ELF
x86_64/aarch64, Mach-O x86_64/arm64, PE32+) AND the correct, distinct
platform string read back out of its own metadata footer bytes.

Not yet checked: whether these cross-compiled binaries actually *load* in
a real DuckDB on their target platform — only the build host (linux
amd64) could be verified that way here. The `std.heap.page_allocator`/
`std.heap.c_allocator`/arena-allocator concern this section originally
raised (a libc/allocator availability snag on Windows/macOS) didn't
surface as a *build* failure, but a build succeeding doesn't rule out a
runtime-only snag — treat "builds cross-platform" and "verified to load
and run cross-platform" as two different claims until someone can
actually test on those platforms.

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

- ~~**Table-function filter pushdown**~~ — **done.** `comptime_table_v2`
  gained an optional `pushdown` hook on `State` (mirroring the existing
  optional `deinit`), plus the `Expression` introspection surface
  (`expressionGetType`/`GetReturnType`/`GetChild`/`expressionConstantGetValue`/
  `expressionColumnRefGetIndex`/`expressionFunctionGetName`/
  `expressionCastGetMode`) and `table_function_filter_pushdown_*` bindings
  in `duckdb_v2.zig`. Live-verified: a test table function recognizes
  `col = constant`, accepts it, and filters rows itself; the
  unrecognized-predicate and no-predicate fallback cases both confirmed
  correct too.
- ~~**Progress reporting**~~ — **done.** `comptime_table_v2` gained an
  optional `progress(self: *const State) f64` hook on `State`, mirroring
  `pushdown`/`deinit`. Confirmed live, worth remembering: the progress
  callback runs CONCURRENTLY with the scan's own `next`/`exec` even for
  this framework's single-threaded scans — a separate query-progress
  monitoring mechanism, not tied to the scan's own thread count — so
  whatever `progress` reads that `next` also mutates needs to be safe to
  read from another thread (`std.atomic.Value`, not a bare field, if
  precision matters). Verified against a 3-billion-row scan with the CLI's
  own progress bar enabled, showing real mid-scan percentages (14%, 28%,
  ...) sourced from the callback.
- **Partitioning/batch-claiming hooks — deliberately not built**, for two
  separable reasons, not just "never got to it": (1) `partition_data`/
  `partitioning` only unlock an optimization (the partitioned-aggregate
  path) for scans that run on **more than one thread**; this framework's
  `State` lives entirely in bind data with no `init_global`/local-init
  callback, forcing single-threaded scans by design (see "No bind-time
  result-column cardinality hint..." above) — building against a
  multi-thread-only feature on a framework that can't run multi-threaded
  would be unverifiable. (2) the batch-claiming callback itself is gated
  behind `DUCKDB_V2_API_ALLOW_UNSTABLE` in the header and marked
  "unstable: v2.0.0" — not even part of the stable v2.0.0 contract this
  branch otherwise targets. Revisit both once/if the framework grows
  multi-threaded scan support (a bigger, separate undertaking) and the
  claim-batch API stabilizes.
- ~~**Other scalar numeric types untested live**~~ — **mostly done.**
  `i8`/`i16`/`i32`/`f32` are now registered and called live
  (`zig_v2_narrow_sum_ct`). `DATE`/`TIME`/`TIMESTAMP`/`INTERVAL` are
  mapped via new `db.Date`/`db.Time`/`db.Timestamp`/`db.Interval` marker
  types in `duckdb_v2.zig` — these are plain fixed-width vector storage
  (confirmed: the C API has no `duckdb_v2_date_t`/etc. struct; DATE is a
  raw `int32_t`, TIME/TIMESTAMP a raw `int64_t`, same physical layout as
  INTEGER/BIGINT), so the comptime framework's existing direct-buffer
  read/write path needed no new exec-path code, just a distinct Zig type
  per logical type so `duckdbV2TypeId` can tell them apart from plain
  `i32`/`i64` (a non-exhaustive enum wrapping the same backing int is a
  zero-cost way to get that). `BLOB` is mapped via a new `db.Blob` marker
  (reuses VARCHAR's `BytesValue`/boxed-`Value` machinery as-is, just
  tagged BLOB at registration) — live-verified
  (`zig_v2_timestamp_add_ct`, `zig_v2_blob_prefix_ct`). **Still open:
  DECIMAL and ENUM** — both are parameterized (width/scale; a dictionary),
  unlike everything above, so deliberately scoped out of this pass; see
  item 8 below, in progress.
- ~~**Aggregate `destroy` callback** — never wired up~~ — **done**, see
  item 4's growable-state-aggregate entry
  (`aggregateFunctionSetDestroyCallback`, exercised by `zig_v2_string_agg_ct`).

### 5a. Appender (`comptime_appender_v2.zig`) — new, not originally scoped

v2 has no row-based Appender at all (v1's `duckdb_appender_*` API is gone
entirely — confirmed by grepping the header), only bulk
`column_data_collection_append` against a caller-built `DataChunk`.
Generalizes that into the same Row-struct-driven pattern
`comptime_table_v2` uses: primitives (direct-buffer write), VARCHAR, LIST,
one-level STRUCT, ARRAY (`[N]E` → `E[N]`), and ENUM (a plain Zig `enum` →
`ENUM('member0', ...)`, member names from the Zig enum's own variant
names). Live-verified for every supported shape, including a 2500-row
multi-flush stress test.

Two findings worth carrying into any other v2 work that touches
ARRAY/ENUM/parameterized types:

- **No `duckdb_v2_value_create_enum_*` function exists at all** (confirmed
  by grepping the header) — an ENUM `Value` is built the way SQL does it:
  box the member name as VARCHAR, then `valueCastWithContext` it to the
  column's own ENUM type. Casting needs that type at write-time, so
  (unlike every other field shape) `Appender` retains its built
  `LogicalTypeHandle`s for its whole lifetime, not just long enough to
  create the `DataChunk`.
- **ARRAY's and ENUM's logical types are built via
  `contextCreateTypeFromText`, not `contextCreateTypeFromId`**: the header
  confirms `array(T, size)`/`enum(entries)` are reachable the `_from_id`
  way too (as positional `Value` parameters), but the exact `Value` shape
  `size` needs isn't documented, while the SQL-text forms (`"BIGINT[3]"`,
  `"ENUM('a','b')"`) are both given as worked examples on
  `context_create_type_from_text`'s own doc comment.

VARIANT is NOT supported by the Appender (no `Value` constructor exists
for it either, and no SQL-text form for an unparameterized dynamic type
makes sense the way ARRAY/ENUM's text forms do).

### 5b. SIMD batch fast path for ungrouped aggregates — new, not originally scoped

`comptime_aggregate_v2.zig` gained an optional `State.updateBatch` hook,
tried before the per-row `update` loop whenever every state pointer in a
chunk is identical (the ungrouped case — `GROUP BY` always falls back to
the existing scalar per-row path, since SIMD doesn't help a scatter-add
across many different states). States without `updateBatch` are
unaffected. Proved with `zig_v2_weighted_avg_simd_ct`, a `@Vector`-
accelerated twin of `zig_v2_weighted_avg_ct`, folding a whole chunk's
NULL-masked Σ(x·w)/Σw into one SIMD pass via `@splat`/`@select`/`@reduce`
(lane-count remainder handled by a masked final vector pass, not a scalar
tail loop). Live-verified identical to the scalar version across
ungrouped, grouped, NULLs in either argument landing in and out of the
tail, all-NULL weight, and row counts both above and below one lane
width. ~25% faster over 10M rows in `ReleaseSafe` (0.048s vs 0.064s, 3
runs each).

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

### 7. DECIMAL and ENUM support — done

The two parameterized types deliberately left out of item 5's otherwise-
done scalar-types pass. Both need something no other supported type does:
a type-level parameter only known at registration time (DECIMAL's
width/scale; ENUM's member dictionary), which a plain Zig type can't
carry on its own the way `i32`/`db.Date`/etc. do. `comptime_scalar_v2.zig`
now supports both as a parameter or return type.

Findings from the C API, confirmed against the header (not assumed — see
[the C API vector docs](https://duckdb.org/docs/preview/clients/c/vector)
for the v1-era version of the same contract):

- **DECIMAL's vector storage is a typed leaf array, contract-documented
  directly on `vector_get_view`'s own doc comment**: width ≤4 → `int16`,
  ≤9 → `int32`, ≤18 → `int64`, ≤38 → `int128`, boundaries inclusive — the
  same direct-buffer path every numeric type already uses, once the right
  storage width is picked. No dedicated exec path was needed (unlike
  STRUCT/VARIANT): `db.Decimal(width, scale)` (a comptime type generator —
  a one-field wrapper around whichever storage int the width selects,
  `db.DecimalStorageInt`) plugs into the EXISTING flat-buffer read/write
  path, just unwrapping/wrapping `.raw` first. Width and scale cross as
  plain UTINYINT `Value`s to `context_create_type_from_id(ctx, DECIMAL,
  null, [width, scale], 2, ...)` (confirmed: not TYPE-kind values, since
  they aren't child types, unlike LIST/STRUCT's children) via the new
  `contextCreateDecimalType`. Verified live at both the i16/i32/i64 tiers
  and the i128 tier (`zig_v2_apply_tax_ct`, `zig_v2_big_decimal_double_ct`).
- **ENUM's vector storage is also a typed leaf array**, same doc comment:
  dictionary size ≤255 → `uint8`, ≤65535 → `uint16`, beyond → `uint32`
  (boundaries inclusive, empty dictionary → `uint8`; only the `uint8` tier
  was live-verified — `@Type` reification isn't available the expected
  way in this Zig 0.17.0 install, so a quick >255-member live check was
  skipped rather than chased further, and the u16/u32 tiers rest on the
  header's own documented contract plus the same decode/encode code path
  the u8 tier already proved). A plain Zig `enum` maps to SQL
  `ENUM('member0', ...)` (same convention `comptime_appender_v2.zig`
  already established for the Appender — member names from the Zig
  enum's own variant names, via `contextCreateTypeFromText` since there's
  no `value_create_enum_*` constructor to call either for reading or
  writing). **Reading** decodes the vector's dictionary ordinal into a Zig
  enum value via the enum's own `field_values` in declaration order
  (matching the dictionary order the `ENUM(...)` type was built with),
  not `@enumFromInt(ordinal)` directly — verified live specifically with
  manually-numbered variants (`enum(u8) { sad = 1, neutral = 5, happy = 9
  }`), not just the default-auto-numbered case, since that's exactly the
  assumption a naive `@enumFromInt` decode would get wrong. **Writing**
  boxes the Zig value's tag name as VARCHAR, then `valueCastWithContext`s
  it to the result vector's own ENUM type (via the new
  `vectorGetLogicalType` wrapper) — the same way `'a'::my_enum` works in
  SQL, the same trick `comptime_appender_v2.zig` already used for writing.

**Real bug found and fixed before anything else could be tested**: the
first `isEnumType` implementation (`@typeInfo(T) == .@"enum"`) also
matched `db.Date`/`db.Time`/`db.Timestamp` from item 5, since those are
themselves non-exhaustive enums (a zero-cost way to get a distinct type
with the same layout as their backing int) — not an unlikely edge case,
it segfaulted DuckDB's own `context_create_type_from_text` immediately on
extension load, building an empty `ENUM()` dictionary for the first
`db.Timestamp` parameter it saw. Fixed by excluding the three marker
types explicitly, the same way `db.Blob`/`db.Decimal` are excluded from
`isStructType`. Worth remembering for any future marker type built the
same "wrap a backing type in a distinct enum/struct" way: a generic
`@typeInfo(T) == .@"foo"` check needs an explicit exclusion list, not an
assumption that only "real" STRUCTs/ENUMs will ever satisfy it.

### 8. The real cutover decision

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
