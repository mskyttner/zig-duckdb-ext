///! Vendored from the sibling `../braille_image` local project (not a git
///! repo — no commit hash to pin to), as of 2026-10-13. Image-to-Braille-art
///! conversion, used only by the speculative v2-poc demo functions in
///! `src/ext/init_v2_poc.zig` — never wired into the real zig_ext/zig_ext_v2
///! extensions. The original's `pub fn main` (a CLI wrapper) is dropped here
///! since it's irrelevant as a library import; `brailleFromUrl`/`loadGray`
///! are otherwise unchanged.
const std = @import("std");

const zignal = @import("zignal");

/// Converts the image at `url` (http(s) URL or local path) to Braille art.
/// The image is resized to `width * 2` x `height * 4` pixels, so the result is
/// `height` lines of `width` Braille characters, each terminated by '\n'.
/// Caller owns the returned slice.
pub fn brailleFromUrl(io: std.Io, allocator: std.mem.Allocator, url: []const u8, width: u32, height: u32) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidDimensions;

    var source = try loadGray(io, allocator, url);
    defer source.deinit(allocator);

    const w: usize = @as(usize, width) * 2;
    const h: usize = @as(usize, height) * 4;

    var image = try zignal.Image(u8).init(allocator, @intCast(h), @intCast(w));
    defer image.deinit(allocator);
    source.resize(io, allocator, image, .bilinear);

    // Normalize the grayscale image (find min/max and stretch to 0-255)
    const pixel_slice = image.data[0 .. w * h];

    var min_val: u8 = 255;
    var max_val: u8 = 0;
    for (pixel_slice) |p| {
        if (p < min_val) min_val = p;
        if (p > max_val) max_val = p;
    }

    // Normalize pixels
    const range = @as(f32, @floatFromInt(max_val - min_val));
    if (range > 0) {
        for (pixel_slice) |*p| {
            const normalized = (@as(f32, @floatFromInt(p.* - min_val)) / range) * 255.0;
            p.* = @intFromFloat(normalized);
        }
    }

    // Calculate threshold for binarization (using mean)
    var sum: u64 = 0;
    for (pixel_slice) |p| {
        sum += p;
    }
    const threshold: u8 = @intCast(sum / (w * h));

    // Convert to binary (1 = white/light, 0 = black/dark)
    // For Braille, we want dark pixels to be "on" (raised dots)
    // So we invert: pixel < threshold means dot is on
    const binary = try allocator.alloc(u1, w * h);
    defer allocator.free(binary);

    for (pixel_slice, 0..) |p, i| {
        binary[i] = if (p < threshold) 1 else 0;
    }

    // Process 2x4 chunks and output Braille characters
    // Braille dot positions:
    //   1 4
    //   2 5
    //   3 6
    //   7 8
    //
    // The bit order for Unicode Braille is:
    // dot 1 = bit 0 (1)
    // dot 2 = bit 1 (2)
    // dot 3 = bit 2 (4)
    // dot 4 = bit 3 (8)
    // dot 5 = bit 4 (16)
    // dot 6 = bit 5 (32)
    // dot 7 = bit 6 (64)
    // dot 8 = bit 7 (128)
    //
    // Mapping from position (row, col) to dot number:
    // (0,0)=1, (1,0)=2, (2,0)=3, (3,0)=7
    // (0,1)=4, (1,1)=5, (2,1)=6, (3,1)=8

    // The weights vector corresponds to dots in order (1,4,2,5,3,6,7,8)
    // which maps to bit values (1,8,2,16,4,32,64,128)
    const weights = [8]u32{ 1, 8, 2, 16, 4, 32, 64, 128 };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const stdout = &out.writer;

    const chunks_y = h / 4;
    const chunks_x = w / 2;

    for (0..chunks_y) |cy| {
        for (0..chunks_x) |cx| {
            // Extract 2x4 chunk in the specified order (1,4,2,5,3,6,7,8)
            // which corresponds to positions:
            // (0,0), (0,1), (1,0), (1,1), (2,0), (2,1), (3,0), (3,1)
            const base_x = cx * 2;
            const base_y = cy * 4;

            const positions = [8][2]usize{
                .{ 0, 0 }, // dot 1
                .{ 0, 1 }, // dot 4
                .{ 1, 0 }, // dot 2
                .{ 1, 1 }, // dot 5
                .{ 2, 0 }, // dot 3
                .{ 2, 1 }, // dot 6
                .{ 3, 0 }, // dot 7
                .{ 3, 1 }, // dot 8
            };

            var braille_value: u32 = 0;
            for (positions, 0..) |pos, i| {
                const y = base_y + pos[0];
                const x = base_x + pos[1];
                const bit: u32 = binary[y * w + x];
                braille_value += bit * weights[i];
            }

            // Add Unicode Braille base (U+2800 = 10240)
            const braille_char: u21 = @intCast(10240 + braille_value);

            // Output as UTF-8
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(braille_char, &buf) catch unreachable;
            try stdout.writeAll(buf[0..len]);
        }
        try stdout.writeAll("\n");
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
