///! Minimal v2-ABI wasm32-emscripten SIDE_MODULE, built only to carry `matmul.zig`'s two
///! non-threaded kernels (`zig_v2_matmul_naive_ct`/`zig_v2_matmul_ct`) across the gap
///! docs/rationale/0008's "Can a v2-ABI extension be loaded by a wasm engine at all" entry
///! closed with a minimal probe — this is the first *real* v2-ABI wasm extension, not the
///! probe's empty-trap stand-in. Deliberately narrow, same full-isolation reasoning as every
///! other `init_v2_poc_*.zig`: this is the only place in the project building a v2-ABI wasm
///! target, so nothing else is affected if it has trouble.
///!
///! `MatmulNaiveCt`/`MatmulCt` only — not `MatmulBenchCt` (not registered at all here), which
///! calls `matmulSimdParallel`/`matmulSimdParallelBlocked` (real `std.Thread`/`std.Io.Group`
///! dispatch): a first v2-wasm port targets the non-threaded `wasm_eh` platform on purpose,
///! so threading isn't a second unknown stacked on the first.
///!
///! Uses `duckdb_v2_dynamic` (the "get_api" bindings — calls go through the function-pointer
///! table DuckDB hands the extension at init time), not `duckdb_v2_static` (the "direct-link"
///! bindings, plain externs resolved at link time): checked both files' own doc comments
///! before choosing — `duckdb_v2_static` is for `addEmbedExe`'s opposite scenario (a *host*
///! program linking DuckDB's own static libraries directly into itself), not a loadable
///! extension. `duckdb_v2_dynamic` is the same function-pointer-table mechanism this
///! project's v1 wasm builds already use successfully (see ADR-0008): the host passes data,
///! never something requiring the OS/Emscripten loader to resolve symbols against the host's
///! own exports, which is also why this needs no `-sMAIN_MODULE` setup on the engine side.
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const matmul = @import("matmul");
const read_matrix_opfs_v2 = @import("read_matrix_opfs_v2");

/// See `init_v2_poc.zig`'s own identical buffer for the full CAUTION on why this must be
/// `threadlocal` (DuckDB may call a scalar function from multiple worker threads
/// concurrently) and why `eval` must bound its own slice rather than trusting the framework's
/// `list_return_max_elems` cap to run first. `threadlocal` compiles for a non-pthread wasm
/// target too (there is exactly one logical thread when `-sUSE_PTHREADS` is never passed, so
/// this degenerates to ordinary static storage) — not yet exercised with a real second
/// thread here, since the `wasm_eh` platform this file targets has none.
threadlocal var matmul_scratch: [4096]f64 = undefined;

fn matmulOutputSlice(mu: usize, nu: usize) ?[]f64 {
    const want = mu * nu;
    if (want > matmul_scratch.len) return null;
    return matmul_scratch[0..want];
}

const MatmulNaiveCt = comptime_scalar_v2.FunctionNamed("zig_v2_matmul_naive_ct", struct {
    fn eval(a: []const f64, b: []const f64, m: i64, k: i64, n: i64) []const f64 {
        const mu: usize = @intCast(@max(m, 0));
        const ku: usize = @intCast(@max(k, 0));
        const nu: usize = @intCast(@max(n, 0));
        const out = matmulOutputSlice(mu, nu) orelse return &.{};
        matmul.matmulNaive(a, b, out, mu, ku, nu);
        return out;
    }
}.eval, &.{ "a", "b", "m", "k", "n" });

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

/// `matmulSimdBlocked` only — not `matmulSimdParallelBlocked`, which takes a real `std.Io`
/// (for its `std.Io.Group` dispatch) and so hits the exact same wall `std.Io.Threaded.io()`
/// does on a multithreaded wasm32 target (this file's own target has no threads at all, but
/// the *parallel* blocked kernel still can't be ported here as-is — it would need the same
/// `matmulSimdParallelRawThreads`-style raw-`std.Thread` rewrite the non-blocked parallel
/// kernel already got, which hasn't been done for the blocked tiling). Single-threaded only,
/// matching this module's `wasm_eh` (non-threaded) platform.
const MatmulBlockedCt = comptime_scalar_v2.FunctionNamed("zig_v2_matmul_blocked_ct", struct {
    fn eval(a: []const f64, b: []const f64, m: i64, k: i64, n: i64) []const f64 {
        const mu: usize = @intCast(@max(m, 0));
        const ku: usize = @intCast(@max(k, 0));
        const nu: usize = @intCast(@max(n, 0));
        const out = matmulOutputSlice(mu, nu) orelse return &.{};
        matmul.matmulSimdBlocked(matmul.default_rm, a, b, out, mu, ku, nu);
        return out;
    }
}.eval, &.{ "a", "b", "m", "k", "n" });

/// Same `a`/`b`/`m`/`k`/`n` argument shape as the real kernels, zero `O(m·k·n)` work — touches
/// only the first/last element of each slice so the decode can't be proven dead. Isolates
/// SQL-literal/LIST-argument marshaling cost from compute cost in a benchmark; see
/// docs/rationale/0008's "Resolved, 2026-11-06" entry for why this matters (a flat-looking
/// benchmark result was a fixed marshaling cost masking a real 2.38x speedup, not a sign the
/// kernel under test doesn't scale).
const MatmulNoopCt = comptime_scalar_v2.FunctionNamed("zig_v2_matmul_noop_ct", struct {
    fn eval(a: []const f64, b: []const f64, m: i64, k: i64, n: i64) []const f64 {
        _ = k;
        const mu: usize = @intCast(@max(m, 0));
        const nu: usize = @intCast(@max(n, 0));
        const out = matmulOutputSlice(mu, nu) orelse return &.{};
        if (a.len > 0 and b.len > 0 and out.len > 0) {
            out[0] = a[0] + b[0];
            out[out.len - 1] = a[a.len - 1] + b[b.len - 1];
        }
        return out;
    }
}.eval, &.{ "a", "b", "m", "k", "n" });

export fn zig_ext_v2_poc_matmul_wasm_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;
    MatmulNaiveCt.register(input) catch {};
    MatmulCt.register(input) catch {};
    MatmulBlockedCt.register(input) catch {};
    MatmulNoopCt.register(input) catch {};
    read_matrix_opfs_v2.register(input) catch {};
}
