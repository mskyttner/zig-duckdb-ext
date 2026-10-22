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
///! - `stipple_from_url_ct(url, width, height, n_points, iterations, shade_glyphs) -> VARCHAR`:
///!   the whole rendered image as one multi-line string. `shade_glyphs` is a VARCHAR of
///!   exactly 4 codepoints, ascending density (see `stipple.renderCells`'s own doc comment on
///!   `shade_chars` — any 4 codepoints work, there's no fill-specific meaning attached); a
///!   wrong codepoint count falls back to `stipple.default_shade_chars` (░▒▓█) rather than
///!   erroring, since a bad 6th argument shouldn't sink an otherwise-fine render. Same
///!   leak-one-allocation-per-call caveat `init_v2_poc_braille.zig`'s own `braille_from_url_ct`
///!   already documents (no allocator-aware VARCHAR-return convention in
///!   `comptime_scalar_v2.zig` yet) — acceptable for this POC.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const stipple_image = @import("stipple_image");
const stipple = stipple_image.stipple_lib;

/// Decodes `s` into exactly 4 codepoints for `renderCells`'s `shade_chars`, or
/// `stipple.default_shade_chars` if `s` isn't valid UTF-8 or doesn't contain exactly 4.
fn decodeShadeChars(s: []const u8) [4]u21 {
    var out: [4]u21 = stipple.default_shade_chars;
    var it: std.unicode.Utf8Iterator = (std.unicode.Utf8View.init(s) catch return stipple.default_shade_chars).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (i >= 4) return stipple.default_shade_chars; // more than 4
        out[i] = cp;
        i += 1;
    }
    if (i != 4) return stipple.default_shade_chars; // fewer than 4
    return out;
}

const StippleFromUrlCt = comptime_scalar_v2.FunctionNamed("stipple_from_url_ct", struct {
    fn eval(url: []const u8, width: i64, height: i64, n_points: i64, iterations: i64, shade_glyphs: []const u8) []const u8 {
        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        const w: u32 = @intCast(@max(width, 1));
        const h: u32 = @intCast(@max(height, 1));
        const n: usize = @intCast(@max(n_points, 1));
        const iters: usize = @intCast(@max(iterations, 0));
        const shade_chars = decodeShadeChars(shade_glyphs);
        return stipple_image.stippleFromUrl(threaded.io(), std.heap.c_allocator, url, w, h, n, iters, 42, shade_chars) catch |err| {
            return @errorName(err);
        };
    }
}.eval, &.{ "url", "width", "height", "n_points", "iterations", "shade_glyphs" });

export fn zig_ext_v2_poc_stipple_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;
    StippleFromUrlCt.register(input) catch {};
}
