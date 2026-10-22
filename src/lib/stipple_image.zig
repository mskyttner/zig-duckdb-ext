///! Image loading/pre-processing glue for `stipple.zig`'s weighted-
///! Voronoi-stippling algorithm — the image-I/O counterpart to
///! `braille_image.zig`, following the same shape: load grayscale via
///! `zignal` (local path or http(s) URL), then here additionally
///! Gaussian-blur via `zigcv` before deriving the density field
///! `stipple.zig`'s pure algorithm core actually consumes.
const std = @import("std");
const zignal = @import("zignal");
const zigcv = @import("zigcv");
const stipple = @import("stipple.zig");

/// Re-exported so callers that only have this module wired in (e.g.
/// `init_v2_poc_stipple.zig`, which build.zig only imports as
/// `stipple_image`) can still reach `stipple.default_shade_chars` without
/// a separate `addImport("stipple", ...)`.
pub const stipple_lib = stipple;

/// Contrast boost applied to density during Lloyd relaxation's weighted-
/// centroid sum (see `stipple.relaxOnce`'s own doc comment) — matches
/// the reference `Weighted-Voronoi-Stippling` C++ tool (OpenCV's
/// `Subdiv2D` + `cv::moments`), which raises its own density crop to the
/// 8th power before computing each cell's weighted centroid. `4.0` here
/// is a deliberately milder version of that: enough to visibly sharpen
/// points onto edges/veins instead of spreading diffusely across a
/// cell, without the instability an 8th-power boost could cause on
/// lower-resolution/lower-iteration POC-sized renders (vs. the
/// reference tool's full-image-resolution, 100-iteration default).
const contrast_gamma: f32 = 4.0;

/// Converts the image at `url` (http(s) URL or local path) into a
/// weighted-Voronoi stipple rendering, as `height` lines of `width`
/// characters (mixed Braille/shade glyphs per `stipple.CellGlyph`),
/// each line terminated by `'\n'`. Caller owns the returned slice.
///
/// `n_points` is the target stipple-point count and `iterations` the
/// number of Lloyd-relaxation passes (Secord's paper suggests tens of
/// iterations for visual convergence; a POC-sized render converges
/// visibly within ~10-20).
pub fn stippleFromUrl(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    width: u32,
    height: u32,
    n_points: usize,
    iterations: usize,
    seed: u64,
    shade_chars: [4]u21,
) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidDimensions;

    var source = try loadGray(io, allocator, url);
    defer source.deinit(allocator);

    // Render at 2 px wide x 4 px tall per output character — matching
    // braille_image.zig's own correspondence, since the sparsest bin
    // reuses that exact 2x4 Braille sub-cell packing.
    const w: usize = @as(usize, width) * 2;
    const h: usize = @as(usize, height) * 4;

    var image = try zignal.Image(u8).init(allocator, @intCast(h), @intCast(w));
    defer image.deinit(allocator);

    // Fit the source into the w x h box preserving its own aspect ratio
    // (letterboxed), instead of force-stretching to exactly w x h.
    // Confirmed live: stretching a perfectly square source image (e.g.
    // `500circle.jpg`) into a w:h box that doesn't itself happen to be
    // square (e.g. `-Dstipple-width=80 -Dstipple-height=50` -> a
    // 160x200, 4:5 box) turns a circle into a visibly elongated oval.
    // zignal's own `Image.letterbox` does this resize-preserving-aspect
    // + centering, but pads with black (zero) — the wrong color for
    // this project's "dark pixel -> high density" convention, since
    // padding should mean "no ink here" (bright/low-density), not
    // maximum density. So this does the same fit-and-center computation
    // manually, filling the padding with white (255) first instead.
    image.fill(255);
    const src_cols: f32 = @floatFromInt(source.cols);
    const src_rows: f32 = @floatFromInt(source.rows);
    const fit_scale = @min(@as(f32, @floatFromInt(w)) / src_cols, @as(f32, @floatFromInt(h)) / src_rows);
    const fit_w: u32 = @max(1, @as(u32, @intFromFloat(@round(src_cols * fit_scale))));
    const fit_h: u32 = @max(1, @as(u32, @intFromFloat(@round(src_rows * fit_scale))));
    const off_x: u32 = (@as(u32, @intCast(w)) - fit_w) / 2;
    const off_y: u32 = (@as(u32, @intCast(h)) - fit_h) / 2;
    const fit_rect: zignal.Rectangle(u32) = .init(off_x, off_y, off_x + fit_w, off_y + fit_h);
    const fit_view = image.view(fit_rect);
    source.resize(io, allocator, fit_view, .bilinear);

    const pixels = image.data[0 .. w * h];

    // zigcv's buffers are plain slices with separately-passed
    // width/height/channel-count — confirmed via its own README
    // ("decode to an 8-bit grey ... slice and hand it to zigcv") and
    // `gauss.zig`'s actual signatures: no zigcv-specific image type, no
    // conversion needed from zignal's own `.data` field.
    // `Params{}`'s all-zero defaults (kx=ky=0, sigma_x=sigma_y=0) give
    // `resolve()` nothing to derive a valid kernel size from — confirmed
    // live, it hits `assert(kx % 2 == 1 and ky % 2 == 1)` and crashes.
    // An explicit odd kernel size sidesteps that; 5x5 is a mild
    // pre-smoothing pass, enough to merge single-pixel noise without
    // erasing the image's real intensity structure.
    const blurred = try zigcv.gaussianBlur(allocator, pixels, w, h, 1, .{ .kx = 5, .ky = 5 });
    defer allocator.free(blurred);

    // Density field: dark pixels (low grayscale value) get high density
    // — the same "ink where the image is dark" convention
    // braille_image.zig's own thresholding uses, just continuous instead
    // of binarized. Normalized to [0, 1] against the blurred image's own
    // min/max so the stipple density adapts to each image's actual
    // contrast range rather than assuming full 0-255 range is used.
    const density = try allocator.alloc(f32, w * h);
    defer allocator.free(density);

    var min_val: u8 = 255;
    var max_val: u8 = 0;
    for (blurred) |p| {
        if (p < min_val) min_val = p;
        if (p > max_val) max_val = p;
    }
    const range: f32 = @floatFromInt(@max(1, @as(u16, max_val) - min_val));
    for (blurred, 0..) |p, i| {
        const normalized = @as(f32, @floatFromInt(p - min_val)) / range;
        density[i] = 1.0 - normalized; // invert: dark -> high density
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const points = try stipple.throwDarts(allocator, density, w, h, n_points, prng.random(), n_points * 2000);
    defer allocator.free(points);

    try stipple.relax(allocator, points, density, w, h, iterations, contrast_gamma);

    const glyphs = try stipple.renderCells(allocator, points, w, h, width, height, shade_chars);
    defer allocator.free(glyphs);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    for (0..height) |row| {
        for (0..width) |col| {
            const g = glyphs[row * width + col];
            const cp: u21 = switch (g) {
                .braille => |c| c,
                .shade => |c| c,
            };
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            try writer.writeAll(buf[0..len]);
        }
        try writer.writeAll("\n");
    }
    return out.toOwnedSlice();
}

fn loadGray(io: std.Io, allocator: std.mem.Allocator, url: []const u8) !zignal.Image(u8) {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return zignal.Image(u8).load(io, allocator, url);
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
    if (result.status != .ok) return error.HttpRequestFailed;

    return zignal.Image(u8).loadFromBytes(io, allocator, body.written());
}
