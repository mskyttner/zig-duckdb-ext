# 0007 — Generated v2 C API bindings, with a static and a dynamic backend

## Status

Accepted. Implemented and in use: `src/lib/duckdb_v2_{types,static,dynamic}.zig` are generated, committed, and
every function module, cookbook recipe and comptime framework is built against them. `v2-static-embed-poc` links
`libduckdb_static.a` and runs the real `zig_ext_v2` extension's functions through the static backend — not a
toy, the actual extension.

## Context

The v2 C API is unstable and large: 609 functions across 38 spec modules (27 of the functions unstable), compared
to the ~74 this project had hand-wrapped in the original `duckdb_v2.zig`. Hand-writing more of it does not scale,
and DuckDB's own staged alpha moves: the last port from one alpha to the next touched 177 call sites in this
repository alone (ADR-0005's own count).

Separately, static linking turned out to need a second binding shape, not a flag. Tracing DuckDB's real source
(`duckdb_extension_v2.h`) showed that `DUCKDB_BUILD_STATIC_EXTENSION` strips the `get_api`/vtable macro layer
entirely: every `duckdb_v2_xxx(...)` call becomes a plain, directly-linked C symbol instead of a struct-field
macro redirection, and the `get_api`-fetch init macro collapses to nothing. `static_embed_poc_main.zig` confirmed
`get_api` is unconditionally null under static registration (so the hand-written, vtable-only `duckdb_v2.zig`
cannot work there at all); `static_embed_poc_direct_main.zig` then hand-wrote one function
(`direct_hello() -> VARCHAR`) the other way, calling the real linked symbols directly, and it worked — proving
the shape but making it obvious that hand-porting ~600 functions twice, once per backend, was not viable.

DuckDB itself turned out to already publish the input its own header generator uses: `api_spec/v2`, a tree of
YAML files (one per module — `function/scalar.yaml`, `function/table.yaml`, and so on) giving every function's
parameters (name, type, pointer depth, in/out), return type, and lifecycle (stable / unstable / deprecated, with
version and date) — confirmed to be the real source, not just a plausible one, by the `capigen:begin/end
appended` markers already present in the real header around exactly the declarations the spec describes.

Parsing it needed a YAML library. Two were evaluated directly, not assumed: `nektro/zig-yaml` (a thin binding to
real libyaml — works after two small, mechanical Zig 0.17 fixes, `@cImport`'s removal and `Allocator.dupeZ`'s
rename, but has no `build.zig.zon`, so it cannot be `zig fetch`-pinned the way every other dependency here is) and
`kubkon/zig-yaml` (pure Zig, YAML 1.2, a proper package — but its parser didn't yet handle the spec's own block
scalars and flow maps, or plain scalars in block context). The sibling checkout at `../zig-yaml` now carries those
additions.

## Decision

**Generate, don't hand-write**, via a new tool, `tools/gen_v2_bindings.zig`:

```
gen_v2_bindings <spec-dir> <out-dir> [--unstable] [--source <text>]
```

It walks the whole `api_spec/v2` tree (not a hand-picked subset) and emits, per run:

- `duckdb_v2_types.zig` — constants, enums, handles, structs, aliases and callback types, shared by both backends.
- `duckdb_v2_static.zig` — the types, plus every function as a plain `extern fn`, resolved at link time against
  `libduckdb` (the direct-link mode `DUCKDB_BUILD_STATIC_EXTENSION` needs).
- `duckdb_v2_dynamic.zig` — the types, plus the `get_api` function-pointer table (`Api`), an `init` to fill it, and
  a wrapper per function that calls through it (what the original hand-written file did, now complete and
  generated).
- `duckdb_v2_index.tsv` — module, name and lifecycle state of every function, feeding the coverage report
  (`docs/api-v2-coverage.md`, `task coverage:api-v2`).

Declaration names are the C name in both backends, so code is written once, against an import named
`duckdb_v2_api`, and works against either by swapping which concrete module answers to that name.

**`zig build gen-v2-bindings -Dv2-api-spec=<duckdb checkout>/api_spec/v2`** runs the tool and overwrites the four
files in `src/lib/`, which are then **committed**. A normal build needs neither the generator nor `zig-yaml`
(a `lazy = true` dependency — only this one step ever resolves it).

**Correctness is checked, not assumed**: `duckdb_v2_{static,dynamic}_parity.zig` comptime-compare every generated
declaration (function, enum, struct) against what `@cImport`/translate-c produces from the real, pinned
`duckdb_v2.h` — bidirectionally, so a function missing from either side fails the build. This is what would catch
the generator drifting from the spec, or the spec drifting from the header, the next time the pinned DuckDB
commit changes — at compile time, without running anything.

**Backend selection is a build-graph choice, not a runtime or comptime-bool branch inside hand-written code**:
`build.zig`'s `v2Graph(b, target, optimize, api)` instantiates the whole stack that function modules, cookbook
recipes and the five comptime frameworks (`comptime_scalar_v2`, `_table_v2`, `_aggregate_v2`, `_appender_v2`,
`_cast_v2`) are built against — `v2_helpers`, `v2_values`, each framework — parameterized by a single module
argument, `api`. It is called once against the dynamic generated module (the real loadable extension, and every
unit test) and again against the static one (`v2-static-embed-poc`). Every file above that layer imports
`duckdb_v2_api` by name and never knows which backend answers to it; nothing in the function or framework source
branches on a mode.

With this, every function and framework was ported off the original hand-written `duckdb_v2.zig` onto the
generated bindings (five commits, each documented in `docs/v2-migration-plan.md`'s "generated bindings" section),
and `v2-static-embed-poc` was rebuilt to link `src/root_v2.zig` — the real extension's own entrypoint, not a
stand-in — against the static backend: `LOAD zig_ext_v2` now actually registers its functions in a process with
`libduckdb_static.a` linked, and the step checks four of them for real.

## Consequences

- The hand-written `duckdb_v2.zig` (~74 of 609 functions, dynamic-only) is retired. The generated files cover the
  whole spec, so using a function this project hadn't previously wrapped by hand is now "it's already there," not
  "wrap it first."
- Porting to the next DuckDB alpha is, in the ordinary case, re-running `gen-v2-bindings` against the new
  checkout and letting the parity files name every real incompatibility at compile time — not re-reading the
  whole header by hand. ADR-0005's own plan leans on this directly: "the cost of the port from one alpha to the
  next stays with the package."
- Static linking's remaining limitation (the real extension's functions need the direct-link backend, which the
  original architecture could not produce at all) is closed for the functions this project already uses — proven
  with the real `zig_ext_v2` entrypoint, not a one-function demo.
- New dependency: a build-time-only, lazy dependency on a locally patched `kubkon/zig-yaml`, pinned via
  `git+https://codeberg.org/mskyttner/zig-yaml#09ae7053845155aa14dbe0322bd21c7b07e536fe` — a fork's `master`
  branch carrying the block-scalar/flow-map additions upstream doesn't have, the same pinning convention every
  other git dependency in `build.zig.zon` already uses. Re-running the generator against this pin reproduces the
  committed `duckdb_v2_{types,static,dynamic}.zig`/`duckdb_v2_index.tsv` byte-for-byte — confirmed directly, not
  assumed.
- The generated files are large (`duckdb_v2_static.zig` and `duckdb_v2_dynamic.zig` are ~9k and ~11k lines) and
  are not meant to be hand-edited; the generator and the spec are the source of truth, the committed files are
  its build artifact, kept in the repository only so a normal build needs neither.

## Open questions

- **Static linking as a first-class, documented product path.** `v2-static-embed-poc` proves the mechanism;
  nothing yet packages "build the whole extension statically for host embedding" as a supported `addExtension`-style
  step the way ADR-0005 sketches for the dynamic case. Natural next step once that package work starts.
- **Windows static embedding** (MinGW archives, a libstdc++ shim for `httplib`, Wine-based CI verification) builds
  directly on the static backend this ADR describes, but is its own separate body of work and isn't detailed here.
