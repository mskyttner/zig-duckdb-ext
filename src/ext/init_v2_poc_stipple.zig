///! Speculative, fully isolated v2-poc demo: weighted-Voronoi stippling
///! (Secord, 2002) of an image (local path or http(s) URL), rendered as a
///! mix of Braille (sparsest regions) and shade-block (denser regions)
///! Unicode characters — see `src/lib/stipple.zig`'s own doc comment for
///! the full algorithm writeup and why no Delaunay/Voronoi library is
///! used. Builds as its own separate `.duckdb_extension`
///! (`zig build v2-poc-stipple`), entirely independent of
///! `init_v2_poc.zig`/`init_v2_poc_braille.zig` — the only place in the
///! project pulling in `zigcv` (and, alongside `init_v2_poc_braille.zig`,
///! one of two places pulling in `zignal`), so nothing else is affected
///! if either dependency has trouble building or fetching.
///!
///! Registers one thing:
///! - `stipple_from_url_ct(url, width, height, n_points, iterations) -> VARCHAR`:
///!   the whole rendered image as one multi-line string. Same leak-one-
///!   allocation-per-call caveat `init_v2_poc_braille.zig`'s own
///!   `braille_from_url_ct` already documents (no allocator-aware VARCHAR-
///!   return convention in `comptime_scalar_v2.zig` yet) — acceptable for
///!   this POC.
const std = @import("std");
const db2 = @import("duckdb_v2");
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const stipple_image = @import("stipple_image");

const StippleFromUrlCt = comptime_scalar_v2.FunctionNamed("stipple_from_url_ct", struct {
    fn eval(url: []const u8, width: i64, height: i64, n_points: i64, iterations: i64) []const u8 {
        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        const w: u32 = @intCast(@max(width, 1));
        const h: u32 = @intCast(@max(height, 1));
        const n: usize = @intCast(@max(n_points, 1));
        const iters: usize = @intCast(@max(iterations, 0));
        return stipple_image.stippleFromUrl(threaded.io(), std.heap.c_allocator, url, w, h, n, iters, 42) catch |err| {
            return @errorName(err);
        };
    }
}.eval, &.{ "url", "width", "height", "n_points", "iterations" });

export fn zig_ext_v2_poc_stipple_init_c_api_v2(input: *const db2.ExtensionInput) callconv(.c) void {
    if (!db2.initApi(input, "v2.0.0")) return;
    StippleFromUrlCt.register(input) catch {};
}
