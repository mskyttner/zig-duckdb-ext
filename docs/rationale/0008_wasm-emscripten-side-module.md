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

  **A second, previously-latent `u64`-on-wasm32 bug found along the way, same class as the
  first but a different code path**: a benchmark probe using a plain scalar `i64` argument
  (`zig_v2_spawn_n_ct(n)`) hit `invoke`'s own `typed[row]` indexing — none of the LIST-argument
  matmul functions ever exercise that particular decode path, so the earlier fix (loop-counter
  declarations only) missed it. `row` is also threaded through as a `u64` *parameter* to ten
  other functions (`writeResult`/`rowIsValid`/`call`/`invoke`/`decodeEnumArg`/
  `structRowIsValid`/`buildStructArgs`/`listRowIsValid`/`writeStructResult`/`readUnionArg`/
  `writeUnionResult`), and every one of their own indexing sites hits the identical narrowing
  problem, independent of the loop variable's own (already-fixed) type. Retyped all eleven
  parameters to `usize` — confirmed every call site already passes the loop variable directly,
  never an actual `u64` value, so this is a pure simplification (removes an implicit widen at
  the call boundary) rather than a behavior change. Re-ran the full native suite, including all
  three real SQL logic suites (820 blocks total), before trusting it.

  **Benchmarked, honestly — real speedup is minimal so far, and the reason isn't known yet**:
  added `zig_v2_matmul_ct` (the single-threaded kernel) to the same `wasm_threads`-stamped
  module too, needed because DuckDB's loader checks an extension's footer `platform` field
  against the connecting engine's own platform and refuses a mismatch — not just descriptive
  metadata, as it first appeared; a `wasm_eh`-stamped module can't be loaded by a
  `wasm_threads` engine at all, so a fair comparison needs both kernels inside one module.

  | matrix (m×k×n) | single-threaded | 4-thread parallel | speedup |
  |---|---|---|---|
  | 64×64×64 (4096 output elems, the LIST-return cap) | 75.2ms | 74.3ms | 1.01x |
  | 64×2048×64 (32x the compute, same output size) | 2248.0ms | 2128.9ms | 1.06x |

  Results agree exactly in both cases (correctness holds). Raw thread dispatch itself is cheap
  — a dedicated probe (`zig_v2_spawn_n_ct`, spawn+join N empty threads, no compute at all)
  measured ~0.25ms per thread on top of a ~2ms baseline call, nowhere near expensive enough to
  explain either result — not the "fresh Web Worker every time" the `PTHREAD_POOL_SIZE is only
  valid when generating JavaScript output` emcc warning first suggested (that flag is ignored
  for a `SIDE_MODULE` build, but Emscripten's pthread implementation apparently still reuses
  workers without it). The 64×64×64 case's lack of speedup has a plausible explanation (LIST-
  result marshaling likely dominates a 75ms call, swamping whatever the parallel compute
  saves) — but the 64×2048×64 case doesn't: at 2+ seconds of compute, dispatch overhead and
  marshaling are both negligible fractions of the total, yet parallelism still barely helps,
  despite 24 real CPU cores on the host and confirmed-cheap dispatch. **Not yet diagnosed**:
  candidates not yet checked are whether headless Chromium's pthread-emulation workers
  actually execute concurrently under test automation, memory-bandwidth contention across the
  shared `SharedArrayBuffer`, or something in the SIMD kernel itself. Recorded here to
  continue later, deliberately not guessed at further in the meantime.

  **Resolved, 2026-11-06: the "minimal real speedup" finding above was a benchmark
  methodology flaw, not a wasm/threading problem.** Two targeted probes, each testing exactly
  one candidate before moving to the next:
  1. **Concurrency candidate, ruled out.** A busy-wait probe (`zig_v2_spin_n_ct`: N threads
     each spin through 200 million iterations of a volatile-store loop — forced non-eliminable
     by writing through a `*volatile u64` every iteration, since a plain wrapping-add loop is
     exactly the kind of thing LLVM can fold into one closed-form store, silently defeating the
     probe) with *no shared data at all* between threads. 1 thread: 137ms. 4 threads doing 4x
     the total spin-work: 115ms (ratio 0.84 — genuinely *faster*, not just "not 4x slower").
     `navigator.hardwareConcurrency` reported 24. Real OS-level concurrent execution under
     Playwright/headless Chromium, conclusively — not serialized, not fake.
  2. **Argument-decode cost, confirmed as the actual answer.** A no-op kernel
     (`zig_v2_matmul_noop_ct`: takes the identical `a`/`b`/`m`/`k`/`n` arguments as the real
     matmul functions, touches just the first/last element of each slice so the decode can't
     be proven dead, does zero `O(m·k·n)` work) run alongside the real single-threaded and
     parallel kernels at the same `m=64, k=2048, n=64` size used above: the no-op call alone
     took **1118ms** — essentially identical to both the single-threaded (1189ms) and parallel
     (1148ms) *full* matmul calls. Subtracting that fixed cost: single-threaded compute alone
     is 71.1ms, parallel compute alone is 29.8ms — a genuine **2.38x speedup** at 4 threads.
     Converting a 262,144-element inline SQL array literal into DuckDB's LIST representation
     (SQL parsing + binding, then `comptime_scalar_v2`'s own LIST-to-`[]f64` decode) costs
     roughly 15-37x more than the matmul compute itself at this problem size — a fixed cost
     identical regardless of which kernel runs afterward, which is exactly why every earlier
     measurement showed near-1.0x: both sides of every comparison were dominated by the same
     threading-independent cost, not by anything wrong with the parallel kernel.

  **Lesson for any future wasm (or native) benchmark through this comptime_scalar_v2 LIST-
  argument path**: a no-op kernel sharing the exact argument shape is cheap to add and is the
  right first move whenever a benchmark result looks suspiciously flat — isolate marshaling
  cost from compute cost before concluding a kernel itself doesn't scale. Not yet checked:
  whether a cheaper argument-delivery mechanism (a bound prepared-statement parameter, or a
  DuckDB table scan, instead of a giant inline literal) would shrink this fixed cost — out of
  scope for this PoC's own benchmarking, worth knowing if `zig_v2_matmul_*_ct` is ever
  benchmarked for real rather than as a wasm-threading feasibility check.

  **Follow-up, 2026-11-06: the "cheaper argument delivery" question above has an answer, and
  it's a dead end on this engine build.** Tested whether a prepared statement with a bound
  array parameter (`conn.prepare('SELECT ...(?, ...)'); stmt.query(someArray, ...)`) avoids
  the SQL-parsing/LIST-construction cost a giant inline literal pays. It doesn't — because
  duckdb-wasm's prepared-statement API doesn't support binding array/LIST parameters at all
  in this build. Confirmed independent of this project's own extension entirely, with a
  minimal test against nothing but `list_sum(?)`: a scalar bind parameter (`SELECT
  ?::INTEGER`) works; a plain JS array, a `Float64Array`, and a plain array with an explicit
  `::DOUBLE[]` cast all fail identically — `Invalid column type encountered for argument 0`.
  Not tested: whether this is wasm-specific or a general gap in DuckDB's client-API bind
  surface (didn't check a native driver). Either way, a bound-parameter path isn't available
  for `zig_v2_matmul_*_ct`'s `a`/`b` arguments today; the inline-literal cost this PoC's own
  benchmarks pay is the only option this engine build offers.

  **Also checked, prompted directly: would `stylearcade/zaw` help?** No, and not a close
  call — it solves a different problem. `zaw::conduit` is a zero-allocation fixed-buffer
  protocol between a *custom TypeScript host* and a *custom wasm module*, both written by the
  same application, bypassing ordinary JS↔wasm argument marshaling entirely. Here, the "host"
  calling our extension is duckdb-wasm's own compiled C++ engine — not something this project
  writes or could get to adopt a different host protocol — and the actual cost found above
  (SQL parsing + LIST-vector construction) happens entirely *inside* that engine, before our
  extension's exported function is ever reached at all. Adopting zaw would mean routing
  around DuckDB's SQL interface entirely, which is a different interop model, not a cheaper
  path through the one actually being used.

  **A real answer to "cheaper argument delivery," found 2026-11-06: route the matrix through
  DuckDB's own virtual file system instead of SQL at all.** duckdb-wasm has real `opfs://`
  support — paths matching that scheme are auto-detected in SQL text and resolved for read or
  write (`config.opfs.fileHandling: 'auto'`, `registerOPFSFileName`) before a query runs, and
  separately `registerFileBuffer(name, Uint8Array)` hands the engine an in-memory buffer
  directly. Both populate DuckDB's own internal `WebFileSystem`, a C++ `FileSystem` subclass
  that calls out to JS (`duckdb_web_fs_file_open` etc.) rather than going through Emscripten's
  libc FS layer — so a plain `fopen()`/`std.fs.openFile()` from the extension would NOT see
  these files. The public C API has the right hook anyway: both v1.5.6 and the v2 API expose a
  `client_context → file_system → open/read/seek/size/close` chain
  (`duckdb_client_context_get_file_system`/`duckdb_v2_context_get_file_system` +
  `duckdb_file_system_open`/`duckdb_v2_file_system_open` + `duckdb_file_handle_read`/
  `duckdb_v2_file_read`), and a v2 table function's `bind` callback already receives the
  `duckdb_v2_context_handle` it needs directly as its third argument — no extra "get client
  context" step.

  Proven live, in order:
  1. **Minimal header read** (`zig_v2_read_opfs_head(path) -> (byte_count, first_f64)`,
     `src/functions/read_opfs_head_v2.zig`): opened a real OPFS file written from the browser's
     own File System Access API (`navigator.storage.getDirectory()`), read its size and first 8
     bytes through the chain above. Result matched exactly: a 32-byte, 4-`f64` file reported
     `byte_count=32, first_f64=42.5`.
  2. **Full matrix decode** (`zig_v2_read_matrix_opfs(path) -> (row_index, value)`,
     `src/functions/read_matrix_opfs_v2.zig`): reads the whole file, then decodes it as a
     single-column `data: DOUBLE` Arrow IPC stream with `zarrow` (`tylitianrui/zarrow`, a
     Zig-native Arrow implementation — confirmed separately to build and test clean under this
     project's pinned Zig 0.17.0 stable, despite `build.zig.zon` still naming a pre-release
     `0.17.0-dev` floor). A known 6-value fixture round-tripped exactly:
     `[42.5, 1, 2, 3, 100.25, -7]` in, same values out, in order, via a real `wasm_eh`
     (non-threaded) duckdb-wasm engine. A pure in-process Zig roundtrip of the same encoding at
     the 64×2048 (131,072-element) size used throughout this investigation —
     `examples/matrix_ipc_roundtrip.zig` in a throwaway `zarrow` checkout — took **~4ms**
     (`ReleaseFast`: build=1ms, write=1ms, read_setup=1ms, verify=0ms) versus the ~1.1s the
     SQL-literal path pays at the identical size: roughly a **275x** reduction in marshaling
     overhead, measured outside DuckDB entirely (the ceiling case — no SQL parser, no LIST
     binder, no per-row validity-mask bookkeeping at all).

  **A second instance of the wasm32 multithreading wall, found via `zarrow` specifically.**
  `zig_v2_read_matrix_opfs` could not be linked into the *threaded* (`wasm_threads`,
  `single_threaded = false`) module alongside the real parallel matmul kernel — only into the
  non-threaded `wasm_eh` one. Root-caused via `-freference-trace`, not guessed:
  `zarrow`'s `nextRecordBatch` unconditionally reaches a zstd-body-decompression branch (even
  for our always-uncompressed streams — it's not comptime-gated), and `std.compress.zstd`'s
  own panic-on-invalid-input path needs `page_allocator`, which is the exact same
  `WasmAllocator`/`page_allocator`-unimplemented-for-non-single-threaded-wasm32 wall that
  blocked `std.Io.Threaded` earlier in this file. Same root cause, different trigger.

  **That wall has a real, merged fix — just not upstream, and not in any numbered Zig
  release.** `cataggar/zig` issue #52 is the identical repro (`WasmAllocator` `@compileError`
  for any non-single-threaded wasm target), closed by that repo's own PR #102: make
  `WasmAllocator` always resolve to `BrkAllocator`, guarded by a spin-lock mutex when not
  single-threaded, instead of refusing to compile. Checked thoroughly before trusting it:
  - Not in `ziglang/zig` at all — no matching issue or PR found there, at any version.
  - Not in Zig 0.17.1 either, despite `zvm` listing it as installed: `0.17.1`'s own
    `lib/std/heap.zig` still has the unpatched `@compileError("unimplemented")` line,
    confirmed by reading it directly.
  - Not in `cataggar/zig`'s own tagged `v0.17.0` release binaries — that release was
    published 2026-10-03, three weeks *before* PR #102 merged (2026-10-28), onto a different
    commit than the tag points to.
  - **Hand-patched and verified anyway** (`lib/std/heap.zig` + 3 `heap/*.zig` files, applied
    directly to the local `zvm`-managed 0.17.0 install, backed up first): unblocked the
    threaded build immediately, `zig build test` stayed clean, and a combined threaded module
    running both the parallel matmul kernel *and* `zig_v2_read_matrix_opfs` in one binary
    verified correct in a real browser (`matmul_result` on a 4×4 case, `matrix_values` on the
    6-value fixture, both exact). **Reverted afterward** — this patches a shared, machine-wide
    toolchain install (`/home/markus/.zvm/0.17.0`) affecting every Zig project on the machine,
    not just this repo, and isn't reproducible for anyone else (no CI, no other contributor,
    no future `zvm install` would have it) without separately fetching and applying the same
    diff. Kept as a confirmed, available option, not as this project's working state.

  **The actual resolution needed no patch at all: split "loading" from "computing" into two
  separate wasm modules.** `single_threaded` is a per-*compile-unit* setting (one
  `zig build-lib` invocation), not a per-engine-connection one — and the footer's `platform`
  field (what the loader actually checks, confirmed earlier in this file) is independent of
  it. So a `zarrow`-based loader module that never spawns a thread itself can keep Zig's
  single-threaded default and still be stamped `wasm_threads`, loadable into the very same
  engine connection as the real thread-spawning matmul module — just as a second, separately
  linked `.wasm` file. Built as `src/ext/init_v2_poc_read_matrix_opfs_wasm_threads.zig` /
  the `wasm-ext-v2-read-matrix-opfs-threads` build step (reuses the existing
  `wasm-ext-v2-matmul-eh-threads` block's module graph; its own root module simply omits the
  `.single_threaded = false` the matmul lib needs). Compiled clean against the **unpatched**
  stdlib on the first try — confirming the hypothesis directly rather than assuming it.
  Verified end to end in a real threaded duckdb-wasm engine, both extensions loaded into one
  connection:

  ```sql
  LOAD zig_ext_v2_poc_read_matrix_opfs_wasm_threads;  -- single-threaded internally
  LOAD zig_ext_v2_poc_matmul_wasm_threads;             -- real threads internally

  CREATE TABLE matrix_a AS SELECT row_index, value FROM zig_v2_read_matrix_opfs('opfs://a.arrow');
  CREATE TABLE matrix_b AS SELECT row_index, value FROM zig_v2_read_matrix_opfs('opfs://b.arrow');

  SELECT zig_v2_matmul_parallel_ct(
      (SELECT list(value ORDER BY row_index) FROM matrix_a),
      (SELECT list(value ORDER BY row_index) FROM matrix_b),
      m, k, n
  );
  ```

  A hand-computed 2×3 × 3×2 case (`[1,2,3,4,5,6]` × `[7,8,9,10,11,12]`) returned
  `[58, 64, 139, 154]` exactly. The "compute" stage's `LIST(...)` arguments now come from
  DuckDB's own native `list()` aggregate over an already-materialized table column — never
  through SQL-literal parsing at all. This is the real-world shape the "cheaper argument
  delivery" question was actually asking about, not a prepared-statement bind parameter.

  **`wazig` (`cataggar/zig@v0.17.0-wazig.3`), surfaced while chasing the above — a real
  option, deliberately not adopted here.** It's Zig's own compiler rebuilt as a pure
  `wasm64-wasip3` binary (runs under Wasmtime, no LLVM dependency), and `zigar`'s own PR #20
  confirms its `lib/std` ships with this exact `WasmAllocator` fix pre-applied — zero manual
  patching, plus a ~5x smaller toolchain download and much faster cold builds (no
  compile-LLVM-translate-c-on-first-use). The real cost: without LLVM, `wazig` compiles
  through Zig's self-hosted `stage2_wasm` backend, which `zigar`'s own benchmarks show
  running **7-9x slower at runtime** than LLVM-optimized code on compute-heavy workloads
  (`nbody`: 301ms vs 33ms; `fannkuch-redux`: 2046ms vs 117ms) — directly the kind of
  numeric/SIMD workload this matmul kernel is. Not worth switching the matmul build to it as
  things stand; worth revisiting if the fix ever lands upstream some other way, or if `wazig`
  gains an LLVM-backed mode.

  **wasm vs. native CLI throughput, same kernel, same problem size (2026-11-06).** Ran the
  existing native benchmark table function (`zig_v2_matmul_bench_ct`, `src/ext/init_v2_poc.zig`
  — real `std.Thread`/`std.Io.Group` dispatch via `matmulSimdParallel`, `max_tasks =
  std.Thread.getCpuCount()`) through the real `duckdb` v2.0.0 CLI, at the same `m=64, k=2048,
  n=64` size, 20 iterations, on a 24-core machine (the same `navigator.hardwareConcurrency`
  the browser probes reported):

  | kernel | native CLI (24 threads) | wasm, isolated from decode cost (4 threads) | ratio |
  | --- | --- | --- | --- |
  | single-threaded SIMD | 9.02 ms/iter (1.86 GFLOPS) | 71.1 ms (0.236 GFLOPS) | native ~7.9x faster |
  | parallel SIMD | 1.97 ms/iter (8.52 GFLOPS) | 29.8 ms (0.562 GFLOPS) | native ~15.2x faster |

  Two different things are mixed into that second ratio, not one: raw per-thread throughput
  (native LLVM-optimized AVX-width SIMD vs. Zig's wasm32-emscripten codegen at `simd128`,
  plus wasm's extra bounds-checking and call overhead) accounts for the single-threaded ~7.9x
  on its own; the rest comes from thread-count, not environment — native's kernel used all 24
  cores the machine has, while both wasm init files hardcode `matmulSimdParallelRawThreads`'s
  task count to 4 (`matmul.matmulSimdParallelRawThreads(matmul.default_rm, 4, ...)`), not the
  engine's own `hardwareConcurrency`. Looking at *speedup from parallelism alone*, within each
  environment, is the fairer comparison: native goes 9.02ms → 1.97ms, a 4.58x speedup from 24
  threads; wasm goes 71.1ms → 29.8ms, a 2.38x speedup from 4 threads — the same order of
  magnitude once thread count is accounted for, not a sign that wasm's threading itself scales
  worse.

  **Matched thread count, done (2026-11-06).** `init_v2_poc_matmul_wasm_threads.zig`'s
  hardcoded `4` is gone — `zig_v2_matmul_parallel_ct` now calls `std.Thread.getCpuCount()`
  (cached in a plain, deliberately non-atomic `var`: a benign race, since the result is
  deterministic for a given engine). This "just works" on `wasm32-emscripten`: Zig's own
  `PosixThreadImpl.getCpuCount()` already has an `.emscripten` branch calling
  `std.os.emscripten.emscripten_num_logical_cores()` — the Emscripten JS binding for
  `navigator.hardwareConcurrency` — the same mechanism the *native* benchmark
  (`zig_v2_matmul_bench_ct`) already used via `std.Thread.getCpuCount()` on Linux. Verified
  live: a real browser reported `navigator.hardwareConcurrency: 24`, and
  `zig_v2_matmul_parallel_ct` on a 4×4 case still returned the exact expected result —
  correctness held across the change. `matmulSimdParallelRawThreads`'s own internal clamp to
  its fixed 32-slot thread array (with inline fallback beyond that) makes this safe without
  any clamping at the call site.

  **The blocked tiling kernels, benchmarked wasm vs. native CLI (2026-11-06).** `matmul.zig`
  has two tiers of "blocked" kernel: `matmulSimdBlocked`/`matmulSimdBlockedMc` (single-
  threaded, no `std.Io`) and `matmulSimdParallelBlocked`/`matmulSimdParallelBlockedMc` (real
  parallel dispatch via `std.Io.Group`, which needs a constructed `std.Io` instance). Only the
  single-threaded pair can exist in wasm at all: the parallel ones take `io: std.Io` and hit
  the exact same `std.Io.Threaded.io()`-can't-compile-for-multithreaded-wasm32 wall this file
  already found blocking `matmulSimdParallel` directly — porting them would need the same
  `matmulSimdParallelRawThreads`-style raw-`std.Thread` rewrite the non-blocked parallel
  kernel already got, not yet done for the blocked tiling. Added `zig_v2_matmul_blocked_ct`
  (wraps `matmulSimdBlocked`) and a tracked, reusable `zig_v2_matmul_noop_ct` (previously only
  ever written as a throwaway scratch probe) to `init_v2_poc_matmul_wasm.zig`, and benchmarked
  decode-isolated at the same `m=64, k=2048, n=64` size:

  | kernel | native CLI (`iterations=20`) | wasm, decode-isolated |
  | --- | --- | --- |
  | `simd` (plain SIMD) | 9.02 ms/iter | 57.6 ms |
  | `simd_blocked` | 9.31 ms/iter | 61.4 ms |

  Consistent on both sides: at this problem size, tiling doesn't help — `simd_blocked` is
  marginally *slower* than plain `simd`, natively and in wasm alike (the tiling's benefit
  likely needs a larger working set than 64×2048×64's matrices fit in cache for either
  environment to show up). The `simd`-vs-`simd_blocked` wasm/native ratio (~6.4x/~6.6x) also
  lines up with the earlier plain-`simd` single-threaded ratio (~7.9x) — same raw per-thread
  codegen gap, not something specific to blocking. `simd_parallel_blocked`/
  `simd_parallel_blocked_mc` remain CLI-only for now (1.67ms/iter and 1.71ms/iter at 24
  threads respectively) until/unless a raw-thread rewrite ports them to wasm.
