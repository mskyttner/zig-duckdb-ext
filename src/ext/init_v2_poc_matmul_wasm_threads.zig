///! A second, threaded v2-ABI wasm32-emscripten SIDE_MODULE, carrying `matmul.zig`'s
///! *parallel* kernel — the non-threaded one lives in `init_v2_poc_matmul_wasm.zig`. Split
///! into its own file because real thread spawning needs `-fno-single-threaded` at the Zig
///! compile level, which the non-threaded build must not have (Zig defaults to
///! single-threaded unless told otherwise, and this file's own `std.Thread.spawn` call would
///! be a compile error without it) — one source file, one compile-time threading mode,
///! matching every other `init_v2_poc_*.zig` in this project's "narrow, single-purpose demo
///! file" convention.
///!
///! See docs/rationale/0008_wasm-emscripten-side-module.md's "Can matmul run in multithreaded
///! wasm" entry for the full trace. Three things confirmed live before this file reached its
///! current shape, none assumed:
///!
///! 1. **Zig never set `.single_threaded = false` for the `eh_threads`/`coi` wasm variants.**
///!    `addWasmEmscriptenBuild` links them with `-sUSE_PTHREADS=1`/`-pthread` already, but
///!    every function ever registered for them (`zig_hello`, `tp_bar`, `zig_tokenize`, the
///!    non-threaded matmul kernels) is single-threaded Zig code, so this never surfaced: a
///!    minimal probe (`std.Thread.spawn` + `.join()`, nothing else) failed to *compile* with
///!    "Cannot spawn thread when building in single-threaded mode" until built with
///!    `-fno-single-threaded` explicitly — `build.zig`'s own wasm-threads step sets this now.
///! 2. **`-Wl,--wrap=pthread_create` (copied onto `eh_threads`'s link args from duckdb-wasm's
///!    own CMake recipe for its *main module*) crashes `wasm-ld` outright (SIGSEGV) when
///!    linking a *SIDE_MODULE* with real thread-spawning code in it** — reproduced directly,
///!    not inferred from the crash alone: removing just that one flag links cleanly, with
///!    `-pthread`/`-sUSE_PTHREADS=1` otherwise unchanged.
///! 3. **`std.Io.Threaded.io()` cannot be built at all for a multi-threaded `wasm32-emscripten`
///!    target in Zig 0.17.0** — found via the real compile error, not guessed: its vtable
///!    construction requires `netInterfaceName` to compile, which has no wasm32
///!    implementation and falls through to a `@panic` whose stack-trace machinery needs
///!    `page_allocator`, whose `WasmAllocator` is itself `@compileError("unimplemented")` for
///!    a non-single-threaded build. This rules out calling `matmul.matmulSimdParallel`
///!    directly (it requires a real `std.Io`), independent of which wasm engine would load
///!    the result — the blocker is in the *target*, not the engine. Registered here instead:
///!    `matmul.matmulSimdParallelRawThreads`, a sibling kernel added specifically for this —
///!    same tiling, dispatched with raw `std.Thread.spawn`/`.join()`, no `std.Io` involved.
///!
///! With all three addressed, real parallel SIMD matmul — multiple OS threads, not just a
///! probe that spawns and joins one — works end to end inside a real multithreaded
///! `duckdb-wasm` engine (`wasm_threads` platform), confirmed via a hand-computed matrix
///! product, not just "doesn't crash."
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const matmul = @import("matmul");
const read_opfs_head_v2 = @import("read_opfs_head_v2");

threadlocal var matmul_scratch: [4096]f64 = undefined;

fn matmulOutputSlice(mu: usize, nu: usize) ?[]f64 {
    const want = mu * nu;
    if (want > matmul_scratch.len) return null;
    return matmul_scratch[0..want];
}

const MatmulParallelCt = comptime_scalar_v2.FunctionNamed("zig_v2_matmul_parallel_ct", struct {
    fn eval(a: []const f64, b: []const f64, m: i64, k: i64, n: i64) []const f64 {
        const mu: usize = @intCast(@max(m, 0));
        const ku: usize = @intCast(@max(k, 0));
        const nu: usize = @intCast(@max(n, 0));
        const out = matmulOutputSlice(mu, nu) orelse return &.{};
        matmul.matmulSimdParallelRawThreads(matmul.default_rm, 4, a, b, out, mu, ku, nu);
        return out;
    }
}.eval, &.{ "a", "b", "m", "k", "n" });

/// The single-threaded SIMD kernel, registered here too (not just in
/// `init_v2_poc_matmul_wasm.zig`) specifically so it's a fair single-vs-parallel baseline:
/// DuckDB's own loader checks an extension's footer `platform` field against the connecting
/// engine's own platform and refuses a mismatch (confirmed live — not just descriptive
/// metadata, as it first appeared) — a `wasm_eh`-stamped module can't be loaded by a
/// `wasm_threads` engine at all, so comparing the two kernels needs both inside one module
/// built for the one platform actually being connected to.
const MatmulCt = comptime_scalar_v2.FunctionNamed("zig_v2_matmul_ct", struct {
    fn eval(a: []const f64, b: []const f64, m: i64, k: i64, n: i64) []const f64 {
        const mu: usize = @intCast(@max(m, 0));
        const ku: usize = @intCast(@max(k, 0));
        const nu: usize = @intCast(@max(n, 0));
        const out = matmulOutputSlice(mu, nu) orelse return &.{};
        matmul.matmulSimd(matmul.default_rm, a, b, out, mu, ku, nu);
        return out;
    }
}.eval, &.{ "a", "b", "m", "k", "n" });

export fn zig_ext_v2_poc_matmul_wasm_threads_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;
    MatmulParallelCt.register(input) catch {};
    MatmulCt.register(input) catch {};
    read_opfs_head_v2.register(input) catch {};
}
