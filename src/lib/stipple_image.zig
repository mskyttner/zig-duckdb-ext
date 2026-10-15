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
    source.resize(io, allocator, image, .bilinear);

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

    try stipple.relax(allocator, points, density, w, h, iterations);

    const glyphs = try stipple.renderCells(allocator, points, w, h, width, height);
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
