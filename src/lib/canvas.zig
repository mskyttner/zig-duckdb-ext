/// Standalone text-mode canvas for terminal plot rendering.
/// No DuckDB dependency. Layers write Unicode codepoints into a 2-D cell
/// buffer; render() serialises the buffer to a UTF-8 / ANSI string.
const std = @import("std");
const box = @import("box.zig");
const testing = std.testing;

// ─── Canvas ──────────────────────────────────────────────────────────────────

const EMPTY: u32 = ' ';

pub const Canvas = struct {
    /// Row-major flat array of Unicode codepoints: cells[row * width + col]
    cells: []u32,
    /// Parallel ANSI 256-colour index for each cell
    attrs: []u8,
    width: usize,
    height: usize,
    no_color: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        const cells = try allocator.alloc(u32, width * height);
        const attrs = try allocator.alloc(u8, width * height);
        @memset(cells, EMPTY);
        @memset(attrs, 0);
        return .{
            .cells = cells,
            .attrs = attrs,
            .width = width,
            .height = height,
            .no_color = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.attrs);
    }

    /// Write a Unicode codepoint at (col, row). Out-of-bounds writes are silently dropped.
    pub fn put(self: *Canvas, col: usize, row: usize, cp: u21, color: u8) void {
        if (col >= self.width or row >= self.height) return;
        const i = row * self.width + col;
        self.cells[i] = cp;
        self.attrs[i] = color;
    }

    /// Merge a box-drawing connection encoding into the cell at (col, row).
    /// Decodes the existing character, merges with `connections` via per-direction
    /// max, and writes back the resulting box-drawing character.
    /// Out-of-bounds writes are silently dropped.
    pub fn putMerge(self: *Canvas, col: usize, row: usize, connections: u8, color: u8) void {
        if (col >= self.width or row >= self.height) return;
        const i = row * self.width + col;
        const existing_cp: u21 = @truncate(self.cells[i]);
        const existing: u8 = box.fromChar(existing_cp) orelse 0;
        const merged = box.merge(existing, connections);
        const ch = box.toChar(merged);
        if (ch != ' ' or merged == 0) {
            // Stage 1: max-merge produced a valid glyph (or both encodings were zero).
            self.cells[i] = ch;
            self.attrs[i] = color;
            return;
        }
        // Coverage gap: max-merge has no Unicode glyph.
        // Stage 2: override-merge — incoming weight wins for directions it touches (> 0),
        // existing weight kept for directions the incoming layer doesn't reach (= 0).
        // Recovers e.g. ╚ + ─ → ╨ instead of discarding the double-up stroke.
        const ch2 = box.toChar(box.overrideMerge(existing, connections));
        if (ch2 != ' ') {
            self.cells[i] = ch2;
            self.attrs[i] = color;
            return;
        }
        // Stage 3: incoming glyph alone — new layer wins outright.
        self.cells[i] = box.toChar(connections);
        self.attrs[i] = color;
    }

    /// Serialise the canvas to a UTF-8 string with ANSI 256-colour escape codes.
    /// When no_color is true, escapes are omitted.
    /// Caller owns the returned slice.
    pub fn render(self: *Canvas, allocator: std.mem.Allocator) ![]u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        var last_color: ?u8 = null;
        for (0..self.height) |row| {
            for (0..self.width) |col| {
                const i = row * self.width + col;
                const cp: u21 = @truncate(self.cells[i]);
                const color = self.attrs[i];
                if (!self.no_color) {
                    if (last_color == null or last_color.? != color) {
                        try aw.writer.print("\x1b[38;5;{d}m", .{color});
                        last_color = color;
                    }
                }
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &utf8) catch blk: {
                    utf8[0] = '?';
                    break :blk 1;
                };
                try aw.writer.writeAll(utf8[0..len]);
            }
            try aw.writer.writeByte('\n');
        }
        if (!self.no_color) try aw.writer.writeAll("\x1b[0m");
        var result = aw.toArrayList();
        return result.toOwnedSlice(allocator);
    }
};

// ─── DataRange ───────────────────────────────────────────────────────────────

/// Maps a data-space rectangle to canvas cell coordinates.
/// The canvas layout reserves col 0 for the y-axis and row (height-1) for
/// the x-axis, so the plot area is cols [1, width-1] × rows [0, height-2].
pub const DataRange = struct {
    min_x: f64,
    max_x: f64,
    min_y: f64,
    max_y: f64,

    pub fn toCol(self: DataRange, canvas: *const Canvas, x: f64) usize {
        if (canvas.width < 2) return 0;
        const plot_cols: f64 = @floatFromInt(canvas.width - 2); // cols 1..width-1
        const frac = if (self.max_x == self.min_x) 0.5 else std.math.clamp((x - self.min_x) / (self.max_x - self.min_x), 0.0, 1.0);
        return 1 + @as(usize, @intFromFloat(@round(frac * plot_cols)));
    }

    pub fn toRow(self: DataRange, canvas: *const Canvas, y: f64) usize {
        if (canvas.height < 2) return 0;
        const plot_rows: f64 = @floatFromInt(canvas.height - 2); // rows 0..height-2
        const frac = if (self.max_y == self.min_y) 0.5 else std.math.clamp((y - self.min_y) / (self.max_y - self.min_y), 0.0, 1.0);
        // Invert: higher data value → lower row index (row 0 is top of screen)
        return @as(usize, @intFromFloat(@round((1.0 - frac) * plot_rows)));
    }
};

// ─── Layer primitives ────────────────────────────────────────────────────────

/// Draw y-axis (col 0, │) and x-axis (row height-1, ─) with a ┼ at the origin.
pub fn drawAxes(canvas: *Canvas) void {
    const bottom = canvas.height - 1;
    for (0..canvas.height - 1) |row| canvas.put(0, row, '│', 7);
    for (1..canvas.width) |col| canvas.put(col, bottom, '─', 7);
    canvas.put(0, bottom, '┼', 7);
}

/// Plot (xs[i], ys[i]) pairs as individual glyph characters.
pub fn drawScatter(
    canvas: *Canvas,
    xs: []const f64,
    ys: []const f64,
    range: DataRange,
    glyph: u21,
    color: u8,
) void {
    for (xs, ys) |x, y| {
        canvas.put(range.toCol(canvas, x), range.toRow(canvas, y), glyph, color);
    }
}

/// Connect consecutive (xs[i], ys[i]) pairs with Bresenham line segments.
/// Characters are chosen from the dominant direction of each segment.
pub fn drawLine(
    canvas: *Canvas,
    xs: []const f64,
    ys: []const f64,
    range: DataRange,
    color: u8,
) void {
    if (xs.len < 2) return;
    for (0..xs.len - 1) |i| {
        const x0 = range.toCol(canvas, xs[i]);
        const y0 = range.toRow(canvas, ys[i]);
        const x1 = range.toCol(canvas, xs[i + 1]);
        const y1 = range.toRow(canvas, ys[i + 1]);
        bresenham(canvas, x0, y0, x1, y1, color);
    }
}

/// Set a single sub-cell dot in the Braille block at canvas pixel (px, py).
/// Each terminal cell is a 2×4 pixel tile (Unicode U+2800–U+28FF).
/// Dots from multiple calls to the same cell accumulate (bitwise OR).
pub fn setBrailleDot(canvas: *Canvas, px: usize, py: usize, color: u8) void {
    const col = px / 2;
    const row = py / 4;
    if (col >= canvas.width or row >= canvas.height) return;
    const dot_col = px % 2;
    const dot_row = py % 4;
    // Unicode Braille bit layout: rows 0-2 use bits 0-2 (left) and 3-5 (right);
    // row 3 uses bits 6 (left) and 7 (right).
    const bit: u8 = if (dot_row < 3)
        @as(u8, 1) << @intCast(dot_row + dot_col * 3)
    else
        @as(u8, 1) << @intCast(6 + dot_col);
    const i = row * canvas.width + col;
    // Only OR in existing dots if the cell already holds a Braille codepoint;
    // otherwise start from the blank pattern (0x2800) to avoid inheriting
    // the low byte of whatever character was there before (e.g. space = 0x20).
    const current = canvas.cells[i];
    const existing: u32 = if (current >= 0x2800 and current <= 0x28FF) current & 0xFF else 0;
    canvas.cells[i] = 0x2800 | (existing | @as(u32, bit));
    canvas.attrs[i] = color;
}

/// Post-process a canvas by replacing box-drawing characters at bends with
/// rounded arc corners (U+256D–U+2570: ╭╮╯╰). Each non-space, non-Braille cell
/// is re-classified by looking at its four cardinal neighbours:
///
///   neighbours  →  character
///   R + D        ╭   right + down (arc, top-left of a curve)
///   L + D        ╮   left  + down
///   L + U        ╯   left  + up
///   R + U        ╰   right + up
///   L + R        ─   horizontal (both or either side)
///   U + D        │   vertical
///   3-way        ┬ ┴ ├ ┤   T-junctions
///   4-way        ┼   cross
///   isolated     (unchanged)
///
/// Call after turtle drawing to smooth 90° turns into arcs.
pub fn smoothCorners(canvas: *Canvas) void {
    const w = canvas.width;
    const h = canvas.height;
    for (0..h) |row| {
        for (0..w) |col| {
            const i = row * w + col;
            const cp = canvas.cells[i];
            if (cp == ' ') continue;
            if (cp >= 0x2800 and cp <= 0x28FF) continue; // leave Braille untouched

            // Check whether each neighbour has a connection *pointing toward* this
            // cell — e.g. the left neighbour must have a non-zero R weight.
            // This prevents adjacent-but-unconnected segments (e.g. parallel ─
            // lines in a dense Hilbert curve) from generating spurious junctions.
            const enc_l: u8 = if (col > 0) box.fromChar(@truncate(canvas.cells[i - 1])) orelse 0 else 0;
            const enc_r: u8 = if (col + 1 < w) box.fromChar(@truncate(canvas.cells[i + 1])) orelse 0 else 0;
            const enc_u: u8 = if (row > 0) box.fromChar(@truncate(canvas.cells[i - w])) orelse 0 else 0;
            const enc_d: u8 = if (row + 1 < h) box.fromChar(@truncate(canvas.cells[i + w])) orelse 0 else 0;

            const has_l: bool = box.decodeR(enc_l) > 0;
            const has_r: bool = box.decodeL(enc_r) > 0;
            const has_u: bool = box.decodeD(enc_u) > 0;
            const has_d: bool = box.decodeU(enc_d) > 0;

            // Encode as 4-bit pattern: [L R U D]
            const p: u4 = (@as(u4, @intFromBool(has_l)) << 3) |
                (@as(u4, @intFromBool(has_r)) << 2) |
                (@as(u4, @intFromBool(has_u)) << 1) |
                (@as(u4, @intFromBool(has_d)));
            canvas.cells[i] = switch (p) {
                0b0000 => cp, // isolated — keep
                0b1000, 0b0100, 0b1100 => '─',
                0b0010, 0b0001, 0b0011 => '│',
                0b0101 => '╭', // R + D  (U+256D)
                0b1001 => '╮', // L + D  (U+256E)
                0b1010 => '╯', // L + U  (U+256F)
                0b0110 => '╰', // R + U  (U+2570)
                0b1101 => '┬', // L + R + D
                0b1110 => '┴', // L + R + U
                0b0111 => '├', // R + U + D
                0b1011 => '┤', // L + U + D
                0b1111 => '┼', // all four
            };
        }
    }
}

/// Draw a rectangle border using box-drawing characters via putMerge.
/// vw = vertical line weight, hw = horizontal line weight. Corners are
/// derived automatically from vw and hw. No-op when x1 ≤ x0 or y1 ≤ y0.
pub fn drawBox(c: *Canvas, x0: usize, y0: usize, x1: usize, y1: usize, vw: u2, hw: u2, color: u8) void {
    if (x1 <= x0 or y1 <= y0) return;
    c.putMerge(x0, y0, box.encode(0, vw, 0, hw), color);
    c.putMerge(x1, y0, box.encode(0, vw, hw, 0), color);
    c.putMerge(x0, y1, box.encode(vw, 0, 0, hw), color);
    c.putMerge(x1, y1, box.encode(vw, 0, hw, 0), color);
    const hconn = box.encode(0, 0, hw, hw);
    for (x0 + 1..x1) |x| {
        c.putMerge(x, y0, hconn, color);
        c.putMerge(x, y1, hconn, color);
    }
    const vconn = box.encode(vw, vw, 0, 0);
    for (y0 + 1..y1) |y| {
        c.putMerge(x0, y, vconn, color);
        c.putMerge(x1, y, vconn, color);
    }
}

/// Copy src into dst at offset (ox, oy). Cells that fall outside dst are clipped.
/// Copies all cells including spaces, so src fully overwrites the destination region.
pub fn blit(dst: *Canvas, src: *const Canvas, ox: usize, oy: usize) void {
    for (0..src.height) |row| {
        for (0..src.width) |col| {
            const dx = ox + col;
            const dy = oy + row;
            if (dx >= dst.width or dy >= dst.height) continue;
            const si = row * src.width + col;
            const di = dy * dst.width + dx;
            dst.cells[di] = src.cells[si];
            dst.attrs[di] = src.attrs[si];
        }
    }
}

/// Write UTF-8 text left-to-right starting at (x, y), one codepoint per cell.
/// Overwrites whatever is already in the cells. Stops at the canvas right edge.
pub fn writeText(c: *Canvas, x: usize, y: usize, text: []const u8, color: u8) void {
    var col = x;
    var i: usize = 0;
    while (i < text.len and col < c.width) {
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const safe_end = @min(i + seq_len, text.len);
        const cp = std.unicode.utf8Decode(text[i..safe_end]) catch '?';
        c.put(col, y, cp, color);
        col += 1;
        i += seq_len;
    }
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

fn bresenham(canvas: *Canvas, x0: usize, y0: usize, x1: usize, y1: usize, color: u8) void {
    var cx: i64 = @intCast(x0);
    var cy: i64 = @intCast(y0);
    const ex: i64 = @intCast(x1);
    const ey: i64 = @intCast(y1);
    const adx: i64 = @intCast(if (x1 >= x0) x1 - x0 else x0 - x1);
    const ady: i64 = @intCast(if (y1 >= y0) y1 - y0 else y0 - y1);
    const sx: i64 = if (x0 <= x1) 1 else -1;
    const sy: i64 = if (y0 <= y1) 1 else -1;
    var err: i64 = adx - ady;
    while (true) {
        canvas.put(@intCast(cx), @intCast(cy), lineChar(adx, ady, sx, sy), color);
        if (cx == ex and cy == ey) break;
        const e2 = 2 * err;
        if (e2 > -ady) {
            err -= ady;
            cx += sx;
        }
        if (e2 < adx) {
            err += adx;
            cy += sy;
        }
    }
}

fn lineChar(adx: i64, ady: i64, sx: i64, sy: i64) u21 {
    if (ady == 0) return '─';
    if (adx == 0) return '│';
    if (adx > ady * 2) return '─';
    if (ady > adx * 2) return '│';
    return if (sx == sy) '╲' else '╱';
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "Canvas.init: dimensions stored correctly" {
    var c = try Canvas.init(testing.allocator, 10, 5);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 10), c.width);
    try testing.expectEqual(@as(usize, 5), c.height);
}

test "Canvas.init: all cells start as space" {
    var c = try Canvas.init(testing.allocator, 4, 3);
    defer c.deinit();
    for (c.cells) |cell| try testing.expectEqual(EMPTY, cell);
    for (c.attrs) |attr| try testing.expectEqual(@as(u8, 0), attr);
}

test "Canvas.put: writes codepoint and colour at position" {
    var c = try Canvas.init(testing.allocator, 5, 3);
    defer c.deinit();
    c.put(2, 1, '★', 9);
    try testing.expectEqual(@as(u32, '★'), c.cells[1 * 5 + 2]);
    try testing.expectEqual(@as(u8, 9), c.attrs[1 * 5 + 2]);
}

test "Canvas.put: out-of-bounds is silently ignored" {
    var c = try Canvas.init(testing.allocator, 3, 3);
    defer c.deinit();
    c.put(99, 99, 'X', 0); // must not crash or corrupt
    for (c.cells) |cell| try testing.expectEqual(EMPTY, cell);
}

test "Canvas.render (no_color): written char appears in output" {
    var c = try Canvas.init(testing.allocator, 3, 1);
    defer c.deinit();
    c.no_color = true;
    c.put(1, 0, 'Z', 0);
    const out = try c.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Z") != null);
}

test "Canvas.render (no_color): rows are newline-separated" {
    var c = try Canvas.init(testing.allocator, 2, 2);
    defer c.deinit();
    c.no_color = true;
    const out = try c.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
}

test "Canvas.render (color): ANSI escape present for non-zero colour" {
    var c = try Canvas.init(testing.allocator, 1, 1);
    defer c.deinit();
    c.put(0, 0, 'A', 4);
    const out = try c.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null);
}

test "Canvas.render (color): reset sequence present at end" {
    var c = try Canvas.init(testing.allocator, 1, 1);
    defer c.deinit();
    const out = try c.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "\x1b[0m"));
}

test "DataRange.toCol: min value maps to first plot column" {
    var c = try Canvas.init(testing.allocator, 10, 5);
    defer c.deinit();
    const r = DataRange{ .min_x = 0, .max_x = 10, .min_y = 0, .max_y = 10 };
    try testing.expectEqual(@as(usize, 1), r.toCol(&c, 0));
}

test "DataRange.toCol: max value maps to last plot column" {
    var c = try Canvas.init(testing.allocator, 10, 5);
    defer c.deinit();
    const r = DataRange{ .min_x = 0, .max_x = 10, .min_y = 0, .max_y = 10 };
    try testing.expectEqual(@as(usize, 9), r.toCol(&c, 10));
}

test "DataRange.toRow: max data y maps to top row (row 0)" {
    var c = try Canvas.init(testing.allocator, 10, 5);
    defer c.deinit();
    const r = DataRange{ .min_x = 0, .max_x = 10, .min_y = 0, .max_y = 10 };
    try testing.expectEqual(@as(usize, 0), r.toRow(&c, 10));
}

test "DataRange.toRow: min data y maps to bottom plot row (row height-2)" {
    var c = try Canvas.init(testing.allocator, 10, 5);
    defer c.deinit();
    const r = DataRange{ .min_x = 0, .max_x = 10, .min_y = 0, .max_y = 10 };
    try testing.expectEqual(c.height - 2, r.toRow(&c, 0));
}

test "drawAxes: y-axis column uses vertical bar char" {
    var c = try Canvas.init(testing.allocator, 8, 5);
    defer c.deinit();
    drawAxes(&c);
    // col 0 rows 0..3 should be │
    for (0..c.height - 1) |row|
        try testing.expectEqual(@as(u32, '│'), c.cells[row * c.width + 0]);
}

test "drawAxes: x-axis row uses horizontal dash char" {
    var c = try Canvas.init(testing.allocator, 8, 5);
    defer c.deinit();
    drawAxes(&c);
    const bottom = c.height - 1;
    for (1..c.width) |col|
        try testing.expectEqual(@as(u32, '─'), c.cells[bottom * c.width + col]);
}

test "drawAxes: origin corner is ┼" {
    var c = try Canvas.init(testing.allocator, 8, 5);
    defer c.deinit();
    drawAxes(&c);
    try testing.expectEqual(@as(u32, '┼'), c.cells[(c.height - 1) * c.width + 0]);
}

test "drawScatter: each data point places a glyph on the canvas" {
    var c = try Canvas.init(testing.allocator, 12, 8);
    defer c.deinit();
    const r = DataRange{ .min_x = 0, .max_x = 1, .min_y = 0, .max_y = 1 };
    const xs = [_]f64{ 0.0, 0.5, 1.0 };
    const ys = [_]f64{ 0.0, 0.5, 1.0 };
    drawScatter(&c, &xs, &ys, r, '●', 3);
    var count: usize = 0;
    for (c.cells) |cell| if (cell == '●') {
        count += 1;
    };
    try testing.expect(count >= 3);
}

test "drawLine: horizontal segment fills cells with ─" {
    var c = try Canvas.init(testing.allocator, 12, 6);
    defer c.deinit();
    const r = DataRange{ .min_x = 0, .max_x = 10, .min_y = 0, .max_y = 4 };
    const xs = [_]f64{ 0, 10 };
    const ys = [_]f64{ 2, 2 }; // flat horizontal line
    drawLine(&c, &xs, &ys, r, 7);
    var count: usize = 0;
    for (c.cells) |cell| if (cell == '─') {
        count += 1;
    };
    try testing.expect(count >= 5);
}

test "drawLine: vertical segment fills cells with │" {
    var c = try Canvas.init(testing.allocator, 12, 8);
    defer c.deinit();
    const r = DataRange{ .min_x = 0, .max_x = 4, .min_y = 0, .max_y = 10 };
    const xs = [_]f64{ 2, 2 }; // flat vertical line
    const ys = [_]f64{ 0, 10 };
    drawLine(&c, &xs, &ys, r, 7);
    var count: usize = 0;
    for (c.cells) |cell| if (cell == '│') {
        count += 1;
    };
    try testing.expect(count >= 3);
}

test "drawLine: fewer than 2 points draws nothing" {
    var c = try Canvas.init(testing.allocator, 8, 5);
    defer c.deinit();
    const r = DataRange{ .min_x = 0, .max_x = 1, .min_y = 0, .max_y = 1 };
    const xs = [_]f64{0.5};
    const ys = [_]f64{0.5};
    drawLine(&c, &xs, &ys, r, 7);
    for (c.cells) |cell| try testing.expectEqual(EMPTY, cell);
}

test "setBrailleDot: cell gets a codepoint in Braille range" {
    var c = try Canvas.init(testing.allocator, 8, 8);
    defer c.deinit();
    setBrailleDot(&c, 0, 0, 7);
    try testing.expect(c.cells[0] >= 0x2800);
    try testing.expect(c.cells[0] <= 0x28FF);
}

test "setBrailleDot: two dots in same cell accumulate" {
    var c = try Canvas.init(testing.allocator, 8, 8);
    defer c.deinit();
    setBrailleDot(&c, 0, 0, 7); // dot at pixel (0,0)
    setBrailleDot(&c, 1, 0, 7); // dot at pixel (1,0) — same cell, different column
    const dots: u8 = @intCast(c.cells[0] & 0xFF);
    try testing.expect(@popCount(dots) == 2); // two distinct bits set
}

test "smoothCorners: L-shape corner becomes ╮" {
    // Layout (3×3): '─' at (0,1) and (1,1), '│' at (1,2)
    // After smooth: (1,1) has left='─' and down='│' → pattern L+D = ╮
    var c = try Canvas.init(testing.allocator, 3, 3);
    defer c.deinit();
    c.put(0, 1, '─', 7);
    c.put(1, 1, '─', 7);
    c.put(1, 2, '│', 7);
    smoothCorners(&c);
    try testing.expectEqual(@as(u32, '╮'), c.cells[1 * 3 + 1]);
}

test "smoothCorners: straight run stays ─" {
    var c = try Canvas.init(testing.allocator, 5, 1);
    defer c.deinit();
    for (0..5) |col| c.put(col, 0, '─', 7);
    smoothCorners(&c);
    for (0..5) |col| try testing.expectEqual(@as(u32, '─'), c.cells[col]);
}

test "smoothCorners: isolated cell is unchanged" {
    var c = try Canvas.init(testing.allocator, 5, 5);
    defer c.deinit();
    c.put(2, 2, '│', 7);
    smoothCorners(&c);
    try testing.expectEqual(@as(u32, '│'), c.cells[2 * 5 + 2]);
}

test "smoothCorners: adjacent parallel ─ segments don't create T-junctions" {
    // Two rows of ─ stacked directly on top of each other.
    // Without the connection-aware fix this would produce ┬/┴ at interior cells.
    var c = try Canvas.init(testing.allocator, 5, 2);
    defer c.deinit();
    for (0..5) |col| c.put(col, 0, '─', 7);
    for (0..5) |col| c.put(col, 1, '─', 7);
    smoothCorners(&c);
    for (0..5) |col| {
        try testing.expectEqual(@as(u32, '─'), c.cells[0 * 5 + col]);
        try testing.expectEqual(@as(u32, '─'), c.cells[1 * 5 + col]);
    }
}

test "smoothCorners: braille cells are untouched" {
    var c = try Canvas.init(testing.allocator, 3, 3);
    defer c.deinit();
    c.cells[4] = 0x2801; // a Braille cell in the middle
    c.cells[3] = '─'; // left neighbour
    c.cells[5] = '─'; // right neighbour
    smoothCorners(&c);
    try testing.expectEqual(@as(u32, 0x2801), c.cells[4]);
}

test "drawBox: corners are correct for thin/thin" {
    var c = try Canvas.init(testing.allocator, 5, 5);
    defer c.deinit();
    drawBox(&c, 0, 0, 4, 4, box.THIN, box.THIN, 7);
    try testing.expectEqual(@as(u32, '┌'), c.cells[0]);
    try testing.expectEqual(@as(u32, '┐'), c.cells[4]);
    try testing.expectEqual(@as(u32, '└'), c.cells[4 * 5 + 0]);
    try testing.expectEqual(@as(u32, '┘'), c.cells[4 * 5 + 4]);
}

test "drawBox: top edge filled with horizontal char" {
    var c = try Canvas.init(testing.allocator, 5, 3);
    defer c.deinit();
    drawBox(&c, 0, 0, 4, 2, box.THIN, box.THIN, 7);
    for (1..4) |x| try testing.expectEqual(@as(u32, '─'), c.cells[x]);
}

test "drawBox: no-op when x1 <= x0" {
    var c = try Canvas.init(testing.allocator, 5, 5);
    defer c.deinit();
    drawBox(&c, 2, 0, 1, 4, box.THIN, box.THIN, 7);
    for (c.cells) |cell| try testing.expectEqual(EMPTY, cell);
}

test "blit: copies src cells into dst at offset" {
    var src = try Canvas.init(testing.allocator, 2, 2);
    defer src.deinit();
    src.put(0, 0, 'A', 1);
    src.put(1, 1, 'B', 2);
    var dst = try Canvas.init(testing.allocator, 5, 5);
    defer dst.deinit();
    blit(&dst, &src, 1, 1);
    try testing.expectEqual(@as(u32, 'A'), dst.cells[1 * 5 + 1]);
    try testing.expectEqual(@as(u32, 'B'), dst.cells[2 * 5 + 2]);
}

test "blit: out-of-bounds cells are clipped" {
    var src = try Canvas.init(testing.allocator, 3, 3);
    defer src.deinit();
    for (src.cells) |*cell| cell.* = 'X';
    var dst = try Canvas.init(testing.allocator, 4, 4);
    defer dst.deinit();
    blit(&dst, &src, 3, 3); // only cell (0,0) of src fits at dst (3,3)
    try testing.expectEqual(@as(u32, 'X'), dst.cells[3 * 4 + 3]);
    try testing.expectEqual(EMPTY, dst.cells[3 * 4 + 2]); // not overwritten
}

test "writeText: ASCII text placed left-to-right" {
    var c = try Canvas.init(testing.allocator, 6, 1);
    defer c.deinit();
    writeText(&c, 1, 0, "hi", 7);
    try testing.expectEqual(@as(u32, 'h'), c.cells[1]);
    try testing.expectEqual(@as(u32, 'i'), c.cells[2]);
    try testing.expectEqual(EMPTY, c.cells[0]);
    try testing.expectEqual(EMPTY, c.cells[3]);
}

test "writeText: clipped at right edge" {
    var c = try Canvas.init(testing.allocator, 3, 1);
    defer c.deinit();
    writeText(&c, 2, 0, "XY", 7);
    try testing.expectEqual(@as(u32, 'X'), c.cells[2]);
    try testing.expectEqual(EMPTY, c.cells[0]);
}

test "setBrailleDot: out-of-bounds is silently ignored" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    setBrailleDot(&c, 999, 999, 7);
    for (c.cells) |cell| try testing.expectEqual(EMPTY, cell);
}

test "Canvas.putMerge: empty cell becomes the given connection char" {
    var c = try Canvas.init(testing.allocator, 5, 5);
    defer c.deinit();
    c.putMerge(2, 2, box.encode(0, 0, 1, 1), 7); // thin horizontal → ─
    try testing.expectEqual(@as(u32, '─'), c.cells[2 * 5 + 2]);
}

test "Canvas.putMerge: VLT then HLT merges into ┼" {
    var c = try Canvas.init(testing.allocator, 5, 5);
    defer c.deinit();
    c.putMerge(2, 2, box.encode(1, 1, 0, 0), 7); // VLT
    c.putMerge(2, 2, box.encode(0, 0, 1, 1), 7); // HLT
    try testing.expectEqual(@as(u32, '┼'), c.cells[2 * 5 + 2]);
}

test "Canvas.putMerge: coverage gap uses override-merge (╝ + thin-H → ╨)" {
    // Max-merge gives encode(3,0,3,1) — no Unicode glyph.
    // Stage 2 override-merge: thin-H wins for L+R, existing double-U kept → ╨.
    var c = try Canvas.init(testing.allocator, 3, 3);
    defer c.deinit();
    c.putMerge(1, 1, box.encode(3, 0, 3, 0), 7); // ╝
    c.putMerge(1, 1, box.encode(0, 0, 1, 1), 7); // thin-H → gap → override → ╨
    try testing.expectEqual(@as(u32, '╨'), c.cells[1 * 3 + 1]);
}

test "Canvas.putMerge: coverage gap uses override-merge (╚ + thin-H → ╨)" {
    var c = try Canvas.init(testing.allocator, 3, 3);
    defer c.deinit();
    c.putMerge(1, 1, box.encode(3, 0, 0, 3), 7); // ╚
    c.putMerge(1, 1, box.encode(0, 0, 1, 1), 7); // thin-H → gap → override → ╨
    try testing.expectEqual(@as(u32, '╨'), c.cells[1 * 3 + 1]);
}

test "Canvas.putMerge: out-of-bounds is silently ignored" {
    var c = try Canvas.init(testing.allocator, 3, 3);
    defer c.deinit();
    c.putMerge(99, 99, box.encode(0, 0, 1, 1), 7);
    for (c.cells) |cell| try testing.expectEqual(EMPTY, cell);
}
