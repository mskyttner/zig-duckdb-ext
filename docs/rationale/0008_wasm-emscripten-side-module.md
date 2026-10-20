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
- **Only `zig_hello`/`zig_add_numbers` were actually called.** Every other function in
  `src/root.zig` compiles into the same static lib and should work identically — nothing
  about the build is function-specific — but "should" is not "verified."
- **`wasm_mvp` only.** `eh`/`coi` (exceptions, threading) were never attempted; DuckDB's own
  loadable-extension CMake branches on all three, and this project's own `root.zig` has no
  exception-handling-dependent code path to lose by staying on `mvp`, but a `coi` build would
  need its own pass through this same recipe to confirm.
