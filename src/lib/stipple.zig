///! Weighted Voronoi stippling (Secord, "Weighted Voronoi Stippling",
///! 2002: https://www.cs.ubc.ca/labs/imager/tr/2002/secord2002b/secord.2002b.pdf)
///! — pure algorithm core, no image I/O. The caller supplies a density
///! field (one `f32` per pixel, already grayscale/inverted/blurred by
///! whatever image library it used — this project's own `braille_image.zig`
///! does the equivalent prep via `zignal`); this file only does the
///! geometry: weighted dart-throwing for initial placement, Lloyd
///! relaxation to spread points according to the density field, and
///! quantizing the resulting point density per output character cell into
///! one of 5 glyphs.
///!
///! No Delaunay/Voronoi library used or needed: checked
///! github.com/guanchzhou/zig-planar (pure graph-planarity/coloring
///! library, confirmed via direct source read — zero mentions of
///! "delaunay"/"voronoi" anywhere in its code) and every other Zig
///! Voronoi repo found (all unstarred hobby projects) and found nothing
///! usable. Lloyd relaxation only needs, per iteration, "which seed is
///! each sample nearest to" and "the weighted centroid of each such
///! group" — a **rasterized nearest-seed assignment** over the density
///! field's own pixel grid gives exactly that, with no explicit Voronoi
///! polygon construction at all. This is a standard, not a makeshift,
///! way to implement discretized Lloyd relaxation.
///!
///! 5-level rendering: counts of stipple points per output character
///! cell are normalized against the busiest cell in the image, then
///! quantized into 5 bins. The sparsest bin (least ink) renders via a
///! Braille character — reusing the exact dot/bit-weight mapping
///! `braille_image.zig` already uses, since Braille's 8 independently
///! addressable sub-cell positions resolve individual point positions at
///! sub-character detail, which matters most precisely where points are
///! scarce. The 4 denser bins render as a single shade character per
///! cell (░▒▓█, ascending ink-to-data ratio) — once a cell is dense
///! enough, the aggregate fill level carries more visual information
///! than any single point's exact sub-cell position would.
const std = @import("std");

pub const Point = struct { x: f32, y: f32 };

/// Weighted dart-throwing: rejection-samples `n_points` positions from
/// `density` (row-major, `width * height` entries, each in `[0, 1]`),
/// accepting a candidate `(x, y)` with probability `density[y*width+x]`.
/// `max_attempts` bounds the loop (a density field that's all zero, or
/// nearly so, would otherwise spin forever) — returns however many
/// points it managed to place within that budget, which may be fewer
/// than `n_points` for a degenerate input; callers should treat a
/// returned slice shorter than requested as a signal the density field
/// was too sparse, not as a bug.
pub fn throwDarts(
    allocator: std.mem.Allocator,
    density: []const f32,
    width: usize,
    height: usize,
    n_points: usize,
    rng: std.Random,
    max_attempts: usize,
) ![]Point {
    var points: std.ArrayList(Point) = .empty;
    errdefer points.deinit(allocator);
    try points.ensureTotalCapacity(allocator, n_points);

    var attempts: usize = 0;
    while (points.items.len < n_points and attempts < max_attempts) : (attempts += 1) {
        const px = rng.uintLessThan(usize, width);
        const py = rng.uintLessThan(usize, height);
        const d = density[py * width + px];
        if (rng.float(f32) < d) {
            try points.append(allocator, .{ .x = @floatFromInt(px), .y = @floatFromInt(py) });
        }
    }

    return points.toOwnedSlice(allocator);
}

/// One Lloyd-relaxation step, in place: rasterizes the density field by
/// assigning each nonzero-density pixel to its nearest point (brute
/// force — O(points.len) per pixel; fine at the pixel counts a terminal-
/// sized render needs, not optimized for large point sets), accumulates
/// each point's density-weighted centroid, and moves every point there.
/// A point that captures zero pixels this step (every pixel in the
/// field ended up nearer some other point) is left where it is rather
/// than reseeded — a deliberate simplification; Secord's own algorithm
/// handles this case with Delaunay-neighbor-aware splitting, out of
/// scope for this POC.
pub fn relaxOnce(
    allocator: std.mem.Allocator,
    points: []Point,
    density: []const f32,
    width: usize,
    height: usize,
) !void {
    if (points.len == 0) return;

    const sum_x = try allocator.alloc(f64, points.len);
    defer allocator.free(sum_x);
    const sum_y = try allocator.alloc(f64, points.len);
    defer allocator.free(sum_y);
    const sum_w = try allocator.alloc(f64, points.len);
    defer allocator.free(sum_w);
    @memset(sum_x, 0);
    @memset(sum_y, 0);
    @memset(sum_w, 0);

    for (0..height) |py| {
        for (0..width) |px| {
            const w = density[py * width + px];
            if (w <= 0) continue;

            var nearest: usize = 0;
            var nearest_dist: f32 = std.math.inf(f32);
            const fx: f32 = @floatFromInt(px);
            const fy: f32 = @floatFromInt(py);
            for (points, 0..) |p, i| {
                const dx = p.x - fx;
                const dy = p.y - fy;
                const dist = dx * dx + dy * dy;
                if (dist < nearest_dist) {
                    nearest_dist = dist;
                    nearest = i;
                }
            }

            sum_x[nearest] += @as(f64, fx) * w;
            sum_y[nearest] += @as(f64, fy) * w;
            sum_w[nearest] += w;
        }
    }

    for (points, 0..) |*p, i| {
        if (sum_w[i] > 0) {
            p.x = @floatCast(sum_x[i] / sum_w[i]);
            p.y = @floatCast(sum_y[i] / sum_w[i]);
        }
    }
}

/// Runs `relaxOnce` `iterations` times.
pub fn relax(
    allocator: std.mem.Allocator,
    points: []Point,
    density: []const f32,
    width: usize,
    height: usize,
    iterations: usize,
) !void {
    for (0..iterations) |_| {
        try relaxOnce(allocator, points, density, width, height);
    }
}

/// Braille dot-bit weights, in row-major (row, col) order within a 2-wide
/// x 4-tall sub-cell — identical mapping to `braille_image.zig`'s own
/// table (not imported from there: that table is private to a specific
/// function in that file, not exported as a shared utility, and
/// duplicating 8 small constants is simpler and safer than refactoring
/// working code to share it). Position order: (0,0) (0,1) (1,0) (1,1)
/// (2,0) (2,1) (3,0) (3,1) → dots 1,4,2,5,3,6,7,8 → bit weights
/// 1,8,2,16,4,32,64,128.
const braille_weights = [8]u32{ 1, 8, 2, 16, 4, 32, 64, 128 };
const braille_base: u21 = 0x2800;

/// One of the 5 output levels a character cell renders as.
pub const CellGlyph = union(enum) {
    /// Sparsest: a real Braille codepoint, sub-cell dot positions set
    /// from exactly which of the 8 sub-regions contain a point.
    braille: u21,
    /// Denser: one of the 4 ascending-fill shade characters.
    shade: u21,
};

const shade_chars = [4]u21{ '░', '▒', '▓', '█' };

/// Counts how many of `points` fall within the pixel rectangle
/// `[cell_x*cell_w, cell_x*cell_w+cell_w) x [cell_y*cell_h, cell_y*cell_h+cell_h)`,
/// and separately which of the 8 (2-wide x 4-tall) Braille sub-positions
/// within that rectangle contain at least one point — the caller picks
/// which representation to use based on the count's quantized level.
const CellStats = struct {
    count: usize,
    braille_bits: u8,
};

fn cellStats(points: []const Point, cell_x: usize, cell_y: usize, cell_w: usize, cell_h: usize) CellStats {
    const x0: f32 = @floatFromInt(cell_x * cell_w);
    const y0: f32 = @floatFromInt(cell_y * cell_h);
    const x1: f32 = @floatFromInt(cell_x * cell_w + cell_w);
    const y1: f32 = @floatFromInt(cell_y * cell_h + cell_h);

    var count: usize = 0;
    var bits: u8 = 0;
    for (points) |p| {
        if (p.x < x0 or p.x >= x1 or p.y < y0 or p.y >= y1) continue;
        count += 1;

        // Map into Braille's 2x4 sub-grid regardless of the cell's own
        // pixel size (cell_w/cell_h need not be exactly 2x4 — a cell
        // might cover more source pixels than one Braille glyph's worth;
        // sub-positions are computed by fraction-of-cell, not raw pixel
        // offset).
        const fx = (p.x - x0) / @as(f32, @floatFromInt(cell_w));
        const fy = (p.y - y0) / @as(f32, @floatFromInt(cell_h));
        const sub_col: usize = @min(1, @as(usize, @intFromFloat(fx * 2)));
        const sub_row: usize = @min(3, @as(usize, @intFromFloat(fy * 4)));
        const idx = sub_row * 2 + sub_col;
        bits |= @intCast(braille_weights[idx]);
    }
    return .{ .count = count, .braille_bits = bits };
}

/// Renders `points` (in pixel coordinates over a `width x height` field)
/// as a `cell_cols x cell_rows` grid of `CellGlyph`s. Each cell's pixel
/// footprint is `width/cell_cols` wide by `height/cell_rows` tall. A
/// density field with no points anywhere renders every cell as the
/// emptiest Braille glyph (U+2800, no dots), not an error.
///
/// Nonzero counts are min-max normalized against the *actual observed
/// range* of nonzero counts in this image (not against 0..max_count) —
/// so the single sparsest nonzero cell always maps to the bottom of the
/// range (Braille) and the single busiest cell always maps to the top
/// (`'█'`), regardless of the image's absolute density scale. Scaling
/// against 0..max_count instead (an earlier version of this function
/// did) breaks down whenever points are sparse relative to the number
/// of cells: `max_count` itself can end up as low as 1-3, at which
/// point even a single point per cell already lands past the bottom
/// bin's cutoff and Braille is never selected anywhere in the image.
/// Min-max normalization can't suffer that failure mode, by
/// construction: the minimum observed count *is* the bottom of the
/// range it's compared against. When every nonzero cell has the exact
/// same count (no variation to normalize against), they all render as
/// Braille — there's nothing for a shade gradient to express.
pub fn renderCells(
    allocator: std.mem.Allocator,
    points: []const Point,
    width: usize,
    height: usize,
    cell_cols: usize,
    cell_rows: usize,
) ![]CellGlyph {
    const cell_w = @max(1, width / cell_cols);
    const cell_h = @max(1, height / cell_rows);

    const stats = try allocator.alloc(CellStats, cell_cols * cell_rows);
    defer allocator.free(stats);

    var min_count: usize = std.math.maxInt(usize);
    var max_count: usize = 0;
    for (0..cell_rows) |cy| {
        for (0..cell_cols) |cx| {
            const s = cellStats(points, cx, cy, cell_w, cell_h);
            stats[cy * cell_cols + cx] = s;
            if (s.count > 0 and s.count < min_count) min_count = s.count;
            if (s.count > max_count) max_count = s.count;
        }
    }

    const out = try allocator.alloc(CellGlyph, cell_cols * cell_rows);
    for (stats, 0..) |s, i| {
        if (s.count == 0 or max_count == min_count) {
            out[i] = if (s.count == 0) .{ .braille = braille_base } else .{ .braille = braille_base | s.braille_bits };
            continue;
        }
        // 5 equal-width bins of [min_count, max_count]: bin 0 (sparsest)
        // renders via Braille; bins 1-4 render via the 4 shade characters.
        const normalized = @as(f32, @floatFromInt(s.count - min_count)) / @as(f32, @floatFromInt(max_count - min_count));
        const bin: usize = @min(4, @as(usize, @intFromFloat(normalized * 5)));
        if (bin == 0) {
            out[i] = .{ .braille = braille_base | s.braille_bits };
        } else {
            out[i] = .{ .shade = shade_chars[bin - 1] };
        }
    }
    return out;
}

test "throwDarts places points only where density is nonzero" {
    const allocator = std.testing.allocator;
    const width = 10;
    const height = 10;
    var density: [width * height]f32 = @splat(0);
    // Only column 5 has any density at all.
    for (0..height) |y| density[y * width + 5] = 1.0;

    var prng = std.Random.DefaultPrng.init(42);
    const points = try throwDarts(allocator, &density, width, height, 20, prng.random(), 100_000);
    defer allocator.free(points);

    try std.testing.expectEqual(@as(usize, 20), points.len);
    for (points) |p| try std.testing.expectEqual(@as(f32, 5), p.x);
}

test "relax pulls a single point toward the weighted centroid of an asymmetric density field" {
    const allocator = std.testing.allocator;
    const width = 10;
    const height = 1;
    var density: [width]f32 = @splat(0);
    density[9] = 1.0; // all the weight is at the far right

    var points = [_]Point{.{ .x = 0, .y = 0 }}; // starts at the far left
    try relax(allocator, &points, &density, width, height, 1);

    try std.testing.expectApproxEqAbs(@as(f32, 9), points[0].x, 0.01);
}

test "relax splits two points between two separated density blobs" {
    const allocator = std.testing.allocator;
    const width = 20;
    const height = 1;
    var density: [width]f32 = @splat(0);
    density[2] = 1.0;
    density[17] = 1.0;

    var points = [_]Point{ .{ .x = 9, .y = 0 }, .{ .x = 10, .y = 0 } };
    try relax(allocator, &points, &density, width, height, 5);

    // One point should settle near x=2, the other near x=17 (order not
    // guaranteed, since both start equidistant from each blob).
    const xs = [2]f32{ points[0].x, points[1].x };
    const near_low = (xs[0] < 5 or xs[1] < 5);
    const near_high = (xs[0] > 15 or xs[1] > 15);
    try std.testing.expect(near_low and near_high);
}

test "renderCells still picks Braille for the sparsest cells when max_count is tiny" {
    const allocator = std.testing.allocator;
    // 3 cells, each 2x4 px: cells 0 and 1 get 1 point each (the image's
    // minimum nonzero count), cell 2 gets 3 (its maximum). max_count=3 is
    // tiny in absolute terms — scaling against [0, max_count] (an
    // earlier version of this function did) would already push a
    // single-point cell past the bottom bin's cutoff, rendering shade
    // everywhere and never Braille (the bug a wide/tall canvas with few
    // points triggered). Min-max normalization against the *observed*
    // range guarantees the minimum always lands at the bottom (Braille).
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 4, .y = 0 },
        .{ .x = 5, .y = 0 },
        .{ .x = 5, .y = 1 },
    };
    const glyphs = try renderCells(allocator, &points, 6, 4, 3, 1);
    defer allocator.free(glyphs);

    try std.testing.expectEqual(@as(usize, 3), glyphs.len);
    switch (glyphs[0]) {
        .braille => |cp| try std.testing.expect(cp != braille_base),
        .shade => return error.TestUnexpectedResult,
    }
    switch (glyphs[1]) {
        .braille => |cp| try std.testing.expect(cp != braille_base),
        .shade => return error.TestUnexpectedResult,
    }
    switch (glyphs[2]) {
        .shade => |cp| try std.testing.expectEqual(@as(u21, '█'), cp),
        .braille => return error.TestUnexpectedResult,
    }
}

test "renderCells picks a Braille glyph for the sparsest bin and shade characters for denser bins" {
    const allocator = std.testing.allocator;
    // A 4x4-pixel field, 2 cells wide x 1 cell tall (each cell 2x4 px):
    // cell 0 gets 1 point (sparsest -> Braille), cell 1 gets many points
    // concentrated identically (densest -> '█').
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 3 },
        .{ .x = 3, .y = 0 },
        .{ .x = 3, .y = 1 },
        .{ .x = 3, .y = 2 },
        .{ .x = 3, .y = 3 },
    };
    const glyphs = try renderCells(allocator, &points, 4, 4, 2, 1);
    defer allocator.free(glyphs);

    try std.testing.expectEqual(@as(usize, 2), glyphs.len);
    switch (glyphs[0]) {
        .braille => |cp| try std.testing.expect(cp != braille_base), // has at least one dot set
        .shade => return error.TestUnexpectedResult,
    }
    switch (glyphs[1]) {
        .shade => |cp| try std.testing.expectEqual(@as(u21, '█'), cp),
        .braille => return error.TestUnexpectedResult,
    }
}
