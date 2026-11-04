# 0008 — A wasm32-emscripten `SIDE_MODULE`, as a separate build step

## Status

Accepted. Implemented and verified live: `zig build wasm-ext` produces a real Emscripten
`SIDE_MODULE` that loads and runs inside both `Query-farm-haybarn/haybarn-wasm` and official
`duckdb/duckdb-wasm`'s own CI-built engines — `zig_hello`/`zig_add_numbers` called for real,
through `dlopen()`, not a mock. `task wasm:verify-haybarn` / `task wasm:verify-duckdb-wasm`
and the `wasm-verify` job in `.github/workflows/ci-extended.yml` check this on demand and
weekly. The full investigation (every dead end, every real error message, every source file
read to get there) is logged in `docs/v2-migration-plan.md`'s WASM section; this ADR is the
decision record, not a replay of that trace.

## Context

`duckdb-wasm` (and every fork of it checked) loads extensions exactly one way: as a real
Emscripten `SIDE_MODULE`, `dlopen()`'d by an Emscripten main module. This is a proprietary
dynamic-linking ABI on top of raw wasm — its own relocation format, its own shared
table/memory conventions — not satisfied by emitting valid `wasm32` bytecode alone, and not
something Zig's own linker performs. Every real-world case of a non-Emscripten toolchain
producing a `SIDE_MODULE` (including `raylib-zig`, investigated here) still shells out to
real `emcc` for the dynamic-linking step; no exception was found.

DuckDB's own loadable-extension CMake (`extension/extension_build_tools.cmake`, read
directly from the real DuckDB source) turned out to need surprisingly little from the
non-Emscripten half: build a **static** library, then one `emcc -sSIDE_MODULE=2
-sEXPORTED_FUNCTIONS="_<name>_init_c_api"` call linking it. Zig can do the first half with no
Emscripten sysroot at all (confirmed directly — only a **dynamic** Zig output needs libc on
this target, and Zig ships none for it), which is why this works at all without vendoring a
libc port.

Two forks were tried because they disagree on something that matters: **the exact Emscripten
version**. `haybarn-wasm` pins `6.0.12`; official `duckdb-wasm` pins `3.1.71`. The
`SIDE_MODULE` dynamic-linking ABI is not guaranteed stable across that gap, and this was
confirmed the hard way, not assumed: a module built with `6.0.12` fails against the `3.1.71`
engine with `_setThrew is not defined` — a missing Emscripten runtime helper, the signature
of an ABI mismatch, not a bug in the extension. Rebuilding with the matching version also
surfaced two further things that needed fixing, not just re-trying: Zig's default `wasm32`
CPU model enables post-MVP features an older `wasm-opt` doesn't recognize, and the Zig build
cache has no way to notice `-Demcc-path=` now points at a different binary at the same path
(`emsdk` reuses its `upstream/` directory in place across installs), so it kept serving a
stale link output until marked as a side-effecting step.

Loading the built module turned out to need the **network-fetch** `LOAD` path
(`SET custom_extension_repository = '…'`, then `LOAD <name>` by bare name) rather than
`registerFileBuffer` + direct-path `LOAD`: the latter hangs unconditionally in the Node
"blocking" bindings (confirmed with a negative control — even a guaranteed-nonexistent local
path hangs the same way), and turned out to be a known, already-filed, unmerged upstream bug
(`duckdb/duckdb-wasm#2279`) rather than something to work around blindly.

## Decision

**A separate, opt-in `zig build wasm-ext` step, not a `cross` target.** `build.zig` gained
`addWasmEmscriptenBuild`, mirroring `addCrossBuild`'s shape: a static Zig library for
`wasm32-emscripten` (CPU model pinned to `std.Target.wasm.cpu.mvp` explicitly, not Zig's
default — see Context), one `emcc -sSIDE_MODULE=2` link via `b.addSystemCommand` (marked
`has_side_effects = true`, so a changed `-Demcc-path=` target is never served stale from
cache), then the existing `append_metadata` tool, unmodified — the same footer format and
tool every native build already uses.

**No Emscripten toolchain is vendored.** `-Demcc-path=` (default: a bare `emcc` on `PATH`,
i.e. after sourcing `emsdk_env.sh`) is the one external dependency, and the caller is
responsible for pointing it at the Emscripten version matching whichever engine they're
targeting — there is no one version that works for both forks as currently pinned, and
defaulting silently to one would be a trap for the other.

**Verification is a separate, reusable tool**, not folded into the build step itself:
`tools/wasm_verify/` (`fetch_engine.sh`, `serve_extension.cjs`, `verify_wasm_load.cjs`, its
own small `package.json`). `fetch_engine.sh` always pulls the *latest* successful run on a
repo's own default branch — never a pinned run ID, which would go stale once GitHub expires
artifacts (90 days by default) and would silently drift from whichever Emscripten version
that fork currently pins. The HTTP server serving the extension runs as its **own OS
process**, deliberately: the Node "blocking" bindings fetch extensions via a
`worker_threads` Worker while the main thread blocks on `Atomics.wait` (per
`duckdb/duckdb-wasm#2279`'s own description), so a server sharing that process's event loop
deadlocks every time it's asked to serve the very request that thread is frozen waiting on —
confirmed directly, not assumed, after a first version of this tool hung exactly this way.

**A second verification tool, same directory, for a real browser instead of Node's own
bindings**: `verify_wasm_load_browser.cjs` plus a minimal static page
(`tools/wasm_verify/browser/index.html`), driven by Playwright/Chromium. The engine runs
inside the browser's own separate process here, so the server can run in-process with this
script without risking the same deadlock — Node orchestrates Playwright, but never runs
`duckdb-wasm` itself in this path. The browser bundle (`duckdb-browser.mjs`) has a bare
`import ... from "apache-arrow"`, meant for a real bundler to resolve (the same thing
`duckdb-wasm`'s own webpack/vite examples show); a browser `<script type="importmap">`
pointing that one specifier at a CDN ESM build stands in for the bundler here.

## Consequences

- This project's real `zig_ext` functions are loadable inside a live `duckdb-wasm`/
  `haybarn-wasm` engine — verified in Node and in a real headless browser
  (Playwright/Chromium, `verify_wasm_load_browser.cjs`) alike — a capability that didn't
  exist at all before this (the WASM section of `docs/v2-migration-plan.md` previously
  concluded this "not currently feasible as a straight port").
- Porting to a new Emscripten version, or verifying against a third fork, is "pick the right
  `-Demcc-path=` and rerun `wasm-ext`, then `wasm:verify-*`" — not a fresh investigation,
  because the recipe and the pitfalls (CPU features, build-cache staleness, the server/
  Atomics.wait deadlock) are now named and fixed in one place.
- `wasm-verify` in CI depends on two things outside this repository's control: each fork's
  own CI staying green, and the default `GITHUB_TOKEN`'s cross-repo artifact-read access to
  two other public repositories (confirmed working in this project's own CI run, not merely
  assumed — but still a dependency this project doesn't own). It is deliberately placed in
  `ci-extended.yml`, which the file's own header already describes as not merge-blocking,
  rather than in the primary `ci.yml`.
- `tools/wasm_verify/` is this project's first Node/npm dependency. It is scoped to its own
  directory with its own `package.json` (`apache-arrow`, version-matched to what
  `duckdb-wasm` itself declares, plus `playwright` for the browser check) — nothing
  elsewhere in the repository needs Node. The browser check is a real, meaningfully heavier
  dependency than the Node-only one (Playwright's own Chromium download, ~190 MB, plus
  `--with-deps`'s OS packages in CI), which is why it's a separate CI step rather than folded
  silently into the first one.

## Open questions

- ~~**A real browser.**~~ Resolved, 2026-10-20: `verify_wasm_load_browser.cjs` drives real
  headless Chromium (Playwright) against a minimal static page using each engine's actual
  browser bundle (`duckdb-mvp.wasm` + `duckdb-browser-mvp.worker.js` + `duckdb-browser.mjs`),
  not the Node ones — `LOAD` over the same `custom_extension_repository` path, `zig_hello`/
  `zig_add_numbers` both correct, against both forks. One real wrinkle on the way: the
  browser `.mjs` bundle has a bare `import ... from "apache-arrow"`, meant to be resolved by
  a real bundler (webpack/vite, per `duckdb-wasm`'s own docs) — fixed with a browser
  `<script type="importmap">` pointing that one specifier at a CDN ESM build instead.
  `registerFileBuffer` + direct-path `LOAD` (blocked by the Node-binding bug this ADR already
  names) remains the one loading path not exercised anywhere, Node or browser, but the
  network-fetch path this ADR relies on is now verified end to end in both environments.
- ~~**Only `zig_hello`/`zig_add_numbers` were actually called.**~~ Narrowed, 2026-10-20:
  `zig_tokenize`, `ct_add_numbers`, `ct_tokenize`, and `tp_bar` (named-parameter macro call)
  all verified too, Node and browser, both engines. Found and fixed a real bug on the way —
  see `docs/v2-migration-plan.md`'s matching 2026-10-20 follow-up for the full trace, short
  version: `tp_bar` allocates per row, which captures `@returnAddress()` (part of Zig's
  `Allocator` interface, not Debug-only), which official `duckdb-wasm`'s pinned Emscripten
  aborts on without `-sUSE_OFFSET_CONVERTER` — fixed by forcing `.ReleaseFast` for this build
  unconditionally rather than chasing that flag (which made things worse). Still not
  verified: the three `LIST`-argument functions (`tp_line`/`tp_snakemap`/`tp_treemap`) —
  found, separately, to be blocked by a `duckdb-wasm`-side limitation unrelated to this
  project (any `LIST` value through this build's `query()` fails or corrupts, with or
  without an extension involved — see the migration doc).
- ~~**`wasm_mvp` only.**~~ `coi` added 2026-10-20 (`WasmVariant`, `wasm-ext-coi`), verified
  live against `haybarn-wasm`'s real `coi` engine in a real headless browser (Node has no
  `coi` bindings in either fork). Official `duckdb-wasm`'s own `coi` could not be targeted
  at all at the time: its `coi`-specific Emscripten pin (`3.1.57`, different from its
  `mvp`/`eh` pin) had a real, independently-reproduced version-skew bug — its bundled
  `wasm-opt` predated a flag `emcc`'s own driver unconditionally requests for any
  `SIDE_MODULE`+`pthread` link with real static data.
  ~~Resolved, 2026-10-22: official `duckdb-wasm` bumped to DuckDB 2.0.0 (duckdb/duckdb-wasm#2285,
  merged 2026-10-21), collapsing the platform matrix to `eh` (exceptions, no threads — the new
  default, `mvp` discontinued outright) and a rebuilt `threads` platform (same `wasm_threads`
  footer string `coi` already used, but duckdb-wasm's new CMake needs different link flags —
  `-fwasm-exceptions` plus `-sUSE_PTHREADS=1 -sPTHREAD_POOL_SIZE=8 -pthread
  -Wl,--wrap=pthread_create`, not `coi`'s old `-sSHARED_MEMORY=1` — see `WasmVariant.eh_threads`'s
  own doc comment), both on a single emsdk `6.0.9` pin (no more split `mvp`/`eh`/`coi` pins).
  Both new variants (`eh`, `eh_threads`) confirmed live against a real engine built from the
  bump PR's own merged commit (official duckdb-wasm's `main` branch itself had not produced a
  fresh green CI run yet as of this date, so `fetch_engine.sh`'s "latest success on default
  branch" was — and remained, as of this date — still serving a month-old pre-bump artifact;
  fetched the bump commit's own run directly instead, one-off, for this verification). `eh`:
  Node "blocking" bindings, `zig_hello` correct. `eh_threads`: real headless browser,
  `crossOriginIsolated` true, the full check set correct — the exact upstream bug this entry
  used to describe is fixed as of this bump; official duckdb-wasm's threaded platform is no
  longer blocked.~~
  Found and fixed on the way: `tools/wasm_verify/verify_wasm_load.cjs` hardcoded the old
  `mvp`/`duckdb-mvp.wasm` bundle key and filename; the new engine's rewritten Node bindings use
  `base`/`duckdb-base.wasm` instead and throw on the old key (not just a missing-file error) —
  now detected by which file actually exists in the target directory, verified against both
  engines, no regression. `verify_wasm_load_browser.cjs` and `tools/wasm_verify/browser/index.html`
  were not updated the same way (the `eh_threads` browser verification above used an ad hoc,
  uncommitted copy with the new filenames substituted in, not the committed tool) — a real
  remaining gap if this needs to become a repeatable, CI-driven check rather than a one-off.
- **Does ADR-0004's self-signed `CREATE EXTENSION REPOSITORY` mechanism work inside a wasm
  engine at all?** Resolved, 2026-11-04, by a live probe before writing any script changes —
  not assumed from `tobilg/duckdb-extension-self-hosting`'s README describing the same flow
  for its own, unrelated action (see that project's "DuckDB-Wasm" section). A minimal page
  ran `SET allow_extension_repositories='allowed'` then `CREATE EXTENSION REPOSITORY ... WITH
  PREFIX 'https://example.invalid/nonexistent' USING PUBLIC KEY '<inline pem>'` then `LOAD
  nonexistent_probe_ext FROM test_repo` against a real official `duckdb-wasm` engine (today's
  latest CI build, DuckDB 2.0-cored): the first two succeeded outright, and the `LOAD` failed
  with `IO Error: ... could not be fetched from
  "https://example.invalid/nonexistent/v2.0.0/wasm_eh/nonexistent_probe_ext.duckdb_extension.wasm"`
  — a real network-fetch failure against the (deliberately bogus) prefix, not a parser or
  "unsupported" error, meaning the repository mechanism, inline key pinning (no `.well-known`
  fetch attempted, matching the native-CLI finding ADR-0004 already made), and the versioned
  path resolution (`<prefix>/<engine's own core version>/<platform>/<name>.duckdb_extension.wasm`,
  matching this project's own `<version>/<platform>/<name>` convention, with `wasm_eh` as the
  platform string — the same name `WasmVariant.eh` already produces) all work exactly as the
  native CLI does. Confirmed this is core-engine-level and ABI-agnostic, not gated on the
  loaded extension's own C API version: the real test used this project's existing *v1*-ABI
  `wasm-ext-eh` build (`zig_hello` et al. — there is no v2-ABI wasm build of anything in this
  project, `read_zpq` included, and porting one is a separate, larger effort out of scope
  here), signed with the existing `sign_extension_main.zig` tool (no changes needed to it) and
  a throwaway test key, with no issue at all.

  **Implemented and verified end to end**: `verify_wasm_load_browser.cjs` gained a `--signed
  <pubkey.pem>` flag; `tools/wasm_verify/browser/index.html` branches on a `pubkey` query
  param to run the `CREATE EXTENSION REPOSITORY`/`LOAD ... FROM` flow instead of
  `allowUnsignedExtensions` + bare `LOAD` (inline key, per the probe above — no second code
  path needed for key delivery). No server change was needed at all: the static server
  already matches a request by its `.duckdb_extension.wasm` *suffix*, regardless of the full
  (versioned) path requested, so the repository mechanism's own path resolution needed no
  accommodation. Ran against a real signed `wasm_eh` artifact (built via `wasm-ext-eh`, signed
  via `sign_extension`, independently re-verified with `openssl pkeyutl -verify` before
  trusting it) in a real headless browser: `zig_hello`/`zig_add_numbers`/`zig_tokenize`/
  `ct_add_numbers`/`ct_tokenize`/`tp_bar` all correct. **Negative control, also run**: the same
  signed artifact against a *different* key's public half fails exactly as it should —
  `"...could not be loaded because its signature is either missing or invalid..."` — confirming
  the engine genuinely checks the signature rather than merely accepting any repository.
  Not yet wired into CI (the existing `wasm-verify` job only exercises the unsigned path) or
  extended to a real signed `wasm_eh` artifact of this project's actual release key — this
  entry covers the mechanism now being proven to work and implemented as a reusable flag, not
  yet that it's part of the release pipeline. See ADR-0004's own matching follow-up entry.
- **Can a v2-ABI (`_init_c_api_v2`, `C_STRUCT_UNSTABLE` footer) extension be loaded by a wasm
  engine at all** — this project has only ever built *v1*-ABI wasm extensions
  (`wasm-ext`/`wasm-ext-eh`/etc., all `addWasmEmscriptenBuild`'s `_{name}_init_c_api` symbol +
  `C_STRUCT` footer), and `matmul.zig`'s `MatmulCt`/`MatmulNaiveCt` (registered in
  `src/ext/init_v2_poc.zig`, a *v2* C API extension — pure SIMD compute, no file I/O, no
  external C library dependency, unlike `read_zpq`) came up as a candidate for actually
  exercising a v2 wasm port. Resolved, 2026-11-04, by a minimal probe *before* porting any real
  code: a standalone `wasm32-emscripten` `SIDE_MODULE` exporting nothing but
  `probe_v2_init_c_api_v2` (taking a bare `*anyopaque`, no real v2 C API struct needed for
  this), built with the `eh` variant's exact CPU features (`-mcpu=generic+exception_handling`)
  and link flags (`-fwasm-exceptions`), stamped with `abi_type=C_STRUCT_UNSTABLE` via the
  existing `append_metadata` tool, and made to `@trap()` immediately on entry so a wasm trap
  naming the function would prove it was actually called, independent of whether the real v2
  C API would otherwise work. Loaded via the ordinary unsigned `custom_extension_repository` +
  `LOAD` path against the same real official `duckdb-wasm` engine used above: `LOAD` failed
  with exactly the deliberate trap —
  ```
  RuntimeError: unreachable
      at probe_v2.wasm.probe_v2.probe_v2_init_c_api_v2 (wasm://...:wasm-function[1]:0x61)
  ```
  called several frames deep inside the engine's own native loader code. **Conclusion: the
  `C_STRUCT_UNSTABLE`/`_init_c_api_v2` dispatch is recognized and invoked by the wasm-compiled
  DuckDB core exactly as it is natively** — `addWasmEmscriptenBuild`'s C-ABI lookup comment
  ("matching `extension_load.cpp`'s C-ABI load path exactly") is core C++ loader code shared
  by every build target, wasm included, not something `duckdb-wasm`'s own JS/TS layer
  reimplements separately, confirmed rather than inferred from that comment alone. A real v2
  wasm port (new `addWasmEmscriptenBuild`-equivalent using the v2 bindings/headers and
  `_init_c_api_v2` + `C_STRUCT_UNSTABLE`, then `matmul.zig`'s non-threaded kernels specifically,
  to avoid pulling pthreads into a first attempt) is now a real, lower-risk next step rather
  than an open feasibility question — not attempted here, this entry is the probe result only.

  **Done, same day**: `src/ext/init_v2_poc_matmul_wasm.zig` + a new `wasm-ext-v2-matmul-eh`
  build step register exactly `zig_v2_matmul_naive_ct`/`zig_v2_matmul_ct` (not `MatmulBenchCt`,
  which needs threads) against `duckdb_v2_dynamic` (confirmed, by reading both files' own doc
  comments, to be the right choice over `duckdb_v2_static` — the latter is for `addEmbedExe`'s
  opposite scenario, a *host* program linking DuckDB's own static libraries into itself, not a
  loadable extension), using `v2Graph` to build a correctly-wired module graph for the wasm
  target (Zig modules are tied to the target they're created with, so the host-targeted
  `matmul_mod`/`comptime_scalar_v2_mod` etc. elsewhere in `build.zig` can't be reused as-is —
  fresh ones are built for `WasmVariant.eh.resolveTarget(b)` instead). No `.link_libc` needed:
  `comptime_scalar_v2`/`matmul` need none (unlike `comptime_table_v2`/`comptime_aggregate_v2`,
  which do for `std.heap.c_allocator`), so this avoids the "no libc for wasm32-emscripten-musl"
  problem the v1 wasm builds already had to route around, for free.

  **A real, previously-latent portability bug surfaced immediately, not something anticipated
  in the probe above**: `comptime_scalar_v2.zig`'s row/LIST-indexing code used `u64` for row
  indices and `duckdb_v2_list_entry`'s own `offset`/`length` fields directly as slice indices —
  harmless on every target this project has ever built for, since `usize` has always been 64
  bits there, but `usize` is 32 bits on `wasm32`, and Zig correctly refuses the implicit,
  potentially-lossy `u64`→`usize` narrowing at every such site. Fixed at the root (the `row`
  loop-counter declarations, `var row: u64 = 0` → `var row: usize = 0`, which widens back to
  `u64` for free at every call site still typed that way) plus two struct-field sites that
  can't change type (`duckdb_v2_list_entry.offset`/`.length` are the real C API's own `idx_t`
  fields) — explicit `@intCast` there instead, with a comment on why it's always safe (no real
  LIST/MAP in this project ever approaching `u32`'s range). This is in `comptime_scalar_v2.zig`
  itself, not `init_v2_poc_matmul_wasm.zig` — every v2 extension using LIST-returning or
  LIST/MAP-argument scalar functions through this framework benefits, not just this one.
  Re-ran the full native regression suite before trusting this: `zig build test` (silent
  pass), `zig build v2-poc` (native v2-poc extension still builds), and
  `zig build sqllogictest-v2-poc` — all 268 blocks passed, including the LIST-returning/
  LIST-argument cases these fixes directly touch.

  **Verified end to end against a real official `duckdb-wasm` engine, both paths**: unsigned
  (`custom_extension_repository` + bare `LOAD`) and signed (`CREATE EXTENSION REPOSITORY ...
  USING PUBLIC KEY` + `LOAD ... FROM`, via `sign_extension` + a throwaway test key, same as
  this ADR's earlier signed-verify entry). `SELECT zig_v2_matmul_naive_ct(...),
  zig_v2_matmul_ct(...)` on a hand-computed 2×2 case (`[[1,2],[3,4]] × [[5,6],[7,8]] =
  [[19,22],[43,50]]`, checked independently of the kernel under test) returned
  `{"naive":[19,22,43,50],"simd":[19,22,43,50]}` in both modes — the first real v2-ABI wasm
  extension doing real SIMD-computed work inside a browser engine, not just loading without
  crashing. Not yet wired into `verify_wasm_load_browser.cjs`/CI (that script's assertions are
  specific to the v1 `zig_ext` function set); a dedicated test fixture for this extension would
  need its own small script, same shape as the ad hoc one used here.
- **Can `matmul.zig` run in *multithreaded* wasm — the `coi`/`eh_threads` platforms, not just
  `eh`?** Asked directly, after the non-threaded port above landed. Three real blockers found
  and fixed, in order, each confirmed live before moving to the next — not assumed from a
  prior one's shape:
  1. **Zig defaults to single-threaded, and nothing registered for `eh_threads`/`coi` before
     this had ever spawned a real thread** (`zig_hello`, `tp_bar`, `zig_tokenize`, the
     non-threaded matmul kernels are all single-threaded code), so this never surfaced. A
     minimal probe (`std.Thread.spawn` + `.join()`, nothing else) failed to *compile* —
     "Cannot spawn thread when building in single-threaded mode" — until built with
     `.single_threaded = false` explicitly.
  2. **`-Wl,--wrap=pthread_create`** (on `WasmVariant.eh_threads.emccLinkArgs()`, copied from
     duckdb-wasm's own CMake recipe for its *main module*) **crashes `wasm-ld` outright
     (SIGSEGV) linking a *SIDE_MODULE* with real thread-spawning code in it** — reproduced
     directly: removing just that one flag links cleanly, `-pthread`/`-sUSE_PTHREADS=1`
     otherwise unchanged. Likely specific to bootstrapping the engine's own worker pool, not
     something a loaded extension needs.
  3. **`std.Io.Threaded.io()` cannot be built at all for a multi-threaded `wasm32-emscripten`
     target in this Zig version (0.17.0)** — found via the real compile error and its full
     reference trace, not guessed: its vtable construction requires every interface method to
     compile, including `netInterfaceName`, which has no wasm32 implementation and falls
     through to `@panic("unimplemented")`; that panic's stack-trace machinery needs
     `page_allocator`, whose `WasmAllocator` is itself `@compileError("unimplemented")` for a
     non-single-threaded build. This blocks `matmul.matmulSimdParallel` specifically (it
     requires a real `std.Io`) on *any* multithreaded wasm engine, `coi` included — the
     blocker is in the Zig-level target, not in which engine would load the result. Checked
     whether `zio` (this project's other `std.Io` implementation, io_uring-based) offered a
     way around it: no — its own runtime is tied to Linux kernel event backends
     (`ev.backend == .linux or .io_uring`, neither existing on wasm32), and its coroutines are
     a different kind of inapplicable: stackful, via hand-written register
     save/restore per CPU architecture (`x86_64`/`aarch64`/`arm`/`thumb`), with no `wasm32`
     case in that switch at all — structural, not an oversight, since wasm32 has no raw
     swappable stack pointer the way those architectures do.

  **Fixed by adding a sibling kernel, not by avoiding threads**: `matmul.zig` gained
  `matmulSimdParallelRawThreads` — the exact same tiling as `matmulSimdParallel`, dispatched
  with raw `std.Thread.spawn`/`.join()` (a fixed-size `[32]?std.Thread` array, no allocation,
  since this needs to run on targets with no allocator readily at hand — the same reason it
  exists at all) instead of `std.Io.Group`. A new `init_v2_poc_matmul_wasm_threads.zig` +
  `wasm-ext-v2-matmul-eh-threads` build step (own `emcc` link line, deliberately omitting
  `-Wl,--wrap=pthread_create`, `.single_threaded = false` on the module) registers
  `zig_v2_matmul_parallel_ct` against it. Verified end to end against a real multithreaded
  `duckdb-wasm` engine (`wasm_threads` platform): a 16×4 × 4×8 all-ones product (every entry
  exactly `k=4`, large enough to force `m_tiles=4` real tiles and `tasks=4` real OS threads,
  unlike a 2×2 fixture which never leaves the single-thread-inline path at all) came back
  fully correct, with `crossOriginIsolated: true` confirming real `SharedArrayBuffer`-backed
  threading was actually active, not merely available. Not yet tested against haybarn-wasm's
  `coi` specifically — the fix should apply equally there (same CPU features, same mechanism,
  no engine-specific code), but only `eh_threads`/duckdb-wasm has actually been run.
