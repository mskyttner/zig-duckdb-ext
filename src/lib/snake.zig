/// Boustrophedon ("snake") layout and rendering for tp_treemap.
///
/// Items are assigned contiguous cells along a snake path that traverses the
/// canvas row by row, alternating left-to-right and right-to-left.  Each
/// item's contiguous region ("coil") is rendered as a box-outlined,
/// shading-filled cell block with an optional text label.
const std = @import("std");
const canvas_lib = @import("canvas.zig");
const box_lib = @import("box.zig");

const Canvas = canvas_lib.Canvas;
const testing = std.testing;

// ─── Public constants ─────────────────────────────────────────────────────────

/// Sentinel owner value: cell belongs to no item.
pub const NO_ITEM: u32 = std.math.maxInt(u32);

// ─── Public types ─────────────────────────────────────────────────────────────

/// One item's contiguous region on the snake path.
pub const Coil = struct {
    /// Index into the caller's values/labels slices.
    item_index: usize,
    /// First snake index (inclusive).
    start: usize,
    /// One past the last snake index (exclusive).
    end: usize,
};

// ─── Coordinate helpers ───────────────────────────────────────────────────────

/// Convert a snake traversal index to canvas (col, row).
/// Even rows go left→right; odd rows go right→left (boustrophedon).
pub fn snakeToXY(k: usize, width: usize) struct { col: usize, row: usize } {
    const row = k / width;
    const offset = k % width;
    const col = if (row % 2 == 0) offset else width - 1 - offset;
    return .{ .col = col, .row = row };
}

/// Convert canvas (col, row) to snake traversal index.
pub fn xyToSnake(col: usize, row: usize, width: usize) usize {
    const offset = if (row % 2 == 0) col else width - 1 - col;
    return row * width + offset;
}

// ─── Layout ───────────────────────────────────────────────────────────────────

/// Assign canvas cells proportionally to items by value.
/// Returns one Coil per item in input order. Caller owns the slice.
/// Negative or zero values receive zero cells; last item absorbs rounding.
pub fn layout(
    values: []const f64,
    width: usize,
    height: usize,
    allocator: std.mem.Allocator,
) ![]Coil {
    const coils = try allocator.alloc(Coil, values.len);
    const total_cells = width * height;

    if (values.len == 0 or total_cells == 0) return coils;

    var total_val: f64 = 0;
    for (values) |v| if (v > 0) {
        total_val += v;
    };

    var start: usize = 0;
    for (coils, 0..) |*c, i| {
        c.item_index = i;
        c.start = start;
        const end: usize = if (i == values.len - 1) blk: {
            // Last item gets all remaining cells to absorb rounding error.
            break :blk total_cells;
        } else blk: {
            const frac = if (total_val > 0 and values[i] > 0)
                values[i] / total_val
            else
                0.0;
            const count: usize = @intFromFloat(@round(frac * @as(f64, @floatFromInt(total_cells))));
            break :blk @min(start + count, total_cells);
        };
        c.end = end;
        start = end;
    }
    return coils;
}

// ─── Render ───────────────────────────────────────────────────────────────────

/// ANSI 256-color palette: 12 visually distinct hues.
const PALETTE = [_]u8{ 33, 166, 118, 208, 197, 51, 220, 69, 201, 40, 214, 87 };

/// Fill chars cycle so items remain distinguishable when no_color is true.
const FILL_CHARS = [_]u21{ '░', '▒', '▓', '░', '▒', '▓', '░', '▒', '▓', '░', '▒', '▓' };

/// Render all coils onto the canvas.
///
/// Border cells (with at least one non-item neighbour) receive box-drawing
/// characters determined by the "shared border direction" formula — adjacent
/// border cells connect only when they share the same exposed side, giving
/// correct corners and edges for all but single-cell steps at row boundaries.
///
/// Interior cells (surrounded on all four sides by the same item) receive the
/// shading fill character for that item.
///
/// A label is written at the widest row of each coil, truncated with '…' if
/// needed.  Requires avail ≥ 3 to display at all.
pub fn renderCoils(
    canvas: *Canvas,
    coils: []const Coil,
    labels: []const []const u8,
    allocator: std.mem.Allocator,
) !void {
    const w = canvas.width;
    const h = canvas.height;
    const total_cells = w * h;
    if (total_cells == 0) return;

    // Build owner map: owner[row * w + col] = item_index (u32) or NO_ITEM.
    const owner = try allocator.alloc(u32, total_cells);
    defer allocator.free(owner);
    @memset(owner, NO_ITEM);

    for (coils) |coil| {
        const item: u32 = @intCast(coil.item_index);
        for (coil.start..coil.end) |k| {
            if (k >= total_cells) break;
            const xy = snakeToXY(k, w);
            owner[xy.row * w + xy.col] = item;
        }
    }

    // Per-coil label position, computed during border drawing.
    // single_row=true means the coil is entirely on one row → centered inline label.
    const LabelPos = struct { row: ?usize, left: usize, span: usize, single_row: bool = false };
    const label_pos = try allocator.alloc(LabelPos, coils.len);
    defer allocator.free(label_pos);

    // Pass 1: draw borders/fills, collect label positions.
    // isFillMode() decides per-coil: fill + centered label vs. full bordered box.
    for (coils, 0..) |coil, ci| {
        label_pos[ci] = .{ .row = null, .left = 0, .span = 0 };
        if (coil.start >= coil.end) continue;
        const item: u32 = @intCast(coil.item_index);
        const color = PALETTE[coil.item_index % PALETTE.len];
        const fill_char = FILL_CHARS[coil.item_index % FILL_CHARS.len];

        const first_row = coil.start / w;
        const last_row = (coil.end - 1) / w;

        if (isFillMode(coil.start, coil.end, w)) {
            // ── Fill-mode item (< 3 rows): fill all cells, centered label on widest row ──
            for (coil.start..coil.end) |k| {
                if (k >= total_cells) break;
                const xy = snakeToXY(k, w);
                canvas.put(xy.col, xy.row, fill_char, color);
            }
            var best_row: ?usize = null;
            var best_left: usize = 0;
            var best_span: usize = 0;
            for (first_row..@min(last_row + 1, h)) |row| {
                var left: usize = w;
                var right: usize = 0;
                var found = false;
                for (0..w) |col| {
                    if (owner[row * w + col] == item) {
                        if (!found) {
                            left = col;
                            right = col;
                            found = true;
                        } else right = col;
                    }
                }
                if (found) {
                    const span = right - left + 1;
                    if (span > best_span) {
                        best_span = span;
                        best_left = left;
                        best_row = row;
                    }
                }
            }
            if (best_row != null) {
                label_pos[ci] = .{ .row = best_row, .left = best_left, .span = best_span, .single_row = true };
            }
        } else {
            // ── Multi-row item: find widest row for label ──
            for (first_row..@min(last_row + 1, h)) |row| {
                var left: usize = w;
                var right: usize = 0;
                var found = false;
                for (0..w) |col| {
                    if (owner[row * w + col] == item) {
                        if (!found) {
                            left = col;
                            right = col;
                            found = true;
                        } else right = col;
                    }
                }
                if (found and right > left + 1) {
                    const span = right - left - 1;
                    if (span > label_pos[ci].span) {
                        label_pos[ci] = .{ .row = row, .left = left, .span = span };
                    }
                }
            }

            // ── Multi-row item: draw borders and fills ──
            for (coil.start..coil.end) |k| {
                if (k >= total_cells) break;
                const xy = snakeToXY(k, w);
                const c = xy.col;
                const r = xy.row;

                const te = topExposed(c, r, w, owner, item);
                const be = botExposed(c, r, w, h, owner, item);
                const le = lftExposed(c, r, w, owner, item);
                const re = rgtExposed(c, r, w, owner, item);

                if (!te and !be and !le and !re) {
                    canvas.put(c, r, fill_char, color);
                    continue;
                }

                // Shared-direction connection formula.
                const cr = (c + 1 < w) and (owner[r * w + c + 1] == item) and
                    ((te and topExposed(c + 1, r, w, owner, item)) or
                        (be and botExposed(c + 1, r, w, h, owner, item)));
                const cl = (c > 0) and (owner[r * w + c - 1] == item) and
                    ((te and topExposed(c - 1, r, w, owner, item)) or
                        (be and botExposed(c - 1, r, w, h, owner, item)));
                const cd = (r + 1 < h) and (owner[(r + 1) * w + c] == item) and
                    ((le and lftExposed(c, r + 1, w, owner, item)) or
                        (re and rgtExposed(c, r + 1, w, owner, item)));
                const cu = (r > 0) and (owner[(r - 1) * w + c] == item) and
                    ((le and lftExposed(c, r - 1, w, owner, item)) or
                        (re and rgtExposed(c, r - 1, w, owner, item)));

                const connections = box_lib.encode(
                    if (cu) box_lib.THIN else 0,
                    if (cd) box_lib.THIN else 0,
                    if (cl) box_lib.THIN else 0,
                    if (cr) box_lib.THIN else 0,
                );
                const ch = box_lib.toChar(connections);
                canvas.put(c, r, if (ch != ' ') ch else fill_char, color);
            }
        }
    }

    // Pass 2: inject rounded arc corners at step boundaries.
    // Fill-mode items (< 3 rows) don't participate — their edges are fills, not borders.
    injectStepCorners(canvas, coils, owner, w, h);

    // Pass 3: write labels.
    // Single-row items get centered inline labels; multi-row items get left-aligned labels.
    for (coils, 0..) |coil, ci| {
        const lp = label_pos[ci];
        if (lp.row == null) continue;
        const color = PALETTE[coil.item_index % PALETTE.len];
        const label = if (coil.item_index < labels.len) labels[coil.item_index] else "";
        if (lp.single_row) {
            writeLabelCentered(canvas, label, lp.left, lp.row.?, lp.span, color);
        } else {
            writeLabel(canvas, label, lp.left + 1, lp.row.?, lp.span, color);
        }
    }
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

/// Returns true when a coil should render as fill+label rather than bordered box.
///
/// Two conditions both must hold for border mode:
///   1. The coil spans at least 3 rows (so it has a full interior row).
///   2. The cells on the first partial row + cells on the last partial row >= w
///      (so the combined partial rows are wide enough to include fill, not just wire-frame borders).
///
/// If either fails, fall back to fill mode (centered label, no box lines).
fn isFillMode(start: usize, end: usize, w: usize) bool {
    if (end <= start) return true;
    const first_row = start / w;
    const last_row = (end - 1) / w;
    if (last_row < first_row + 2) return true;
    // For items spanning exactly 3 rows, also require the partial first+last rows
    // to together cover at least a full row width — otherwise only wire-frame borders
    // appear on those rows with no interior fill. Items spanning 4+ rows always have
    // enough full interior rows to look correct with borders.
    if (last_row == first_row + 2) {
        const first_row_cells = w - start % w;
        const last_row_cells = (end - 1) % w + 1;
        return first_row_cells + last_row_cells < w;
    }
    return false;
}

fn topExposed(c: usize, r: usize, w: usize, owner: []const u32, item: u32) bool {
    return (r == 0) or (owner[(r - 1) * w + c] != item);
}

fn botExposed(c: usize, r: usize, w: usize, h: usize, owner: []const u32, item: u32) bool {
    return (r + 1 >= h) or (owner[(r + 1) * w + c] != item);
}

fn lftExposed(c: usize, r: usize, w: usize, owner: []const u32, item: u32) bool {
    return (c == 0) or (owner[r * w + c - 1] != item);
}

fn rgtExposed(c: usize, r: usize, w: usize, owner: []const u32, item: u32) bool {
    return (c + 1 >= w) or (owner[r * w + c + 1] != item);
}

/// Overwrite the single-direction stubs at same-row coil transitions with
/// paired arc corners that form a visible "paragraph-end step".
///
/// Each step places two ╭╯ (or ╮╰) columns, one per item:
///
///   Even-row step (L→R, A left at C_a, B right at C_b = C_a+1):
///
///       C_a   C_b
///   R-1: ╭(A)
///   R:   ╯(A)  ╭(B)
///   R+1:        ╯(B)
///
///   Odd-row step (R→L, A right at C_a, B left at C_b = C_a-1):
///
///       C_b   C_a
///   R-1:        ╮(A)
///   R:   ╮(B)  ╰(A)
///   R+1: ╰(B)
///
/// A contributes the exit arc at its last step cell (and the cell above it);
/// B contributes the entry arc at its first step cell (and the cell below it).
/// All writes are guarded by the owner map.
fn injectStepCorners(
    canvas: *Canvas,
    coils: []const Coil,
    owner: []const u32,
    w: usize,
    h: usize,
) void {
    if (coils.len < 2) return;
    const total = w * h;
    for (0..coils.len - 1) |i| {
        const a = coils[i];
        const b = coils[i + 1];
        if (a.start >= a.end or b.start >= b.end) continue;

        // A in fill mode → no border stub to clean up, skip entirely.
        // B in fill mode → still place A's exit arc (╯/╰ + ╭/╮ above), skip B's side.
        const a_fill = isFillMode(a.start, a.end, w);
        const b_fill = isFillMode(b.start, b.end, w);
        if (a_fill) continue;

        const a_last = snakeToXY(a.end - 1, w);
        const b_first = snakeToXY(b.start, w);
        if (a_last.row != b_first.row) continue;

        const R = a_last.row;
        const C_a = a_last.col;
        const C_b = b_first.col;
        const a_item: u32 = @intCast(a.item_index);
        const b_item: u32 = @intCast(b.item_index);
        const a_color = PALETTE[a.item_index % PALETTE.len];
        const b_color = PALETTE[b.item_index % PALETTE.len];

        const owns = struct {
            fn check(o: []const u32, tot: usize, r: usize, c: usize, width: usize, height: usize, it: u32) bool {
                if (r >= height or c >= width) return false;
                const idx = r * width + c;
                return idx < tot and o[idx] == it;
            }
        }.check;

        if (R % 2 == 0) {
            // Even row (L→R): A exits right at C_a, B enters at C_b = C_a+1.
            // A: ╭ one row above step col, ╯ at step.
            if (R > 0) {
                if (owns(owner, total, R - 1, C_a, w, h, a_item))
                    canvas.put(C_a, R - 1, '╭', a_color);
                // Always fix A's ╶ stub at (R-1, C_b) if A owns that cell.
                if (owns(owner, total, R - 1, C_b, w, h, a_item))
                    canvas.put(C_b, R - 1, '─', a_color);
            }
            canvas.put(C_a, R, '╯', a_color);
            // B side: only when B is also in border mode.
            if (!b_fill) {
                canvas.put(C_b, R, '╭', b_color);
                if (R + 1 < h) {
                    if (owns(owner, total, R + 1, C_a, w, h, b_item))
                        canvas.put(C_a, R + 1, '─', b_color);
                    if (owns(owner, total, R + 1, C_b, w, h, b_item))
                        canvas.put(C_b, R + 1, '╯', b_color);
                }
            }
        } else {
            // Odd row (R→L): A exits left at C_a, B enters at C_b = C_a-1.
            // A: ╮ one row above step col, ╰ at step.
            if (R > 0) {
                if (owns(owner, total, R - 1, C_a, w, h, a_item))
                    canvas.put(C_a, R - 1, '╮', a_color);
                if (owns(owner, total, R - 1, C_b, w, h, a_item))
                    canvas.put(C_b, R - 1, '─', a_color);
            }
            canvas.put(C_a, R, '╰', a_color);
            if (!b_fill) {
                canvas.put(C_b, R, '╮', b_color);
                if (R + 1 < h) {
                    if (owns(owner, total, R + 1, C_a, w, h, b_item))
                        canvas.put(C_a, R + 1, '─', b_color);
                    if (owns(owner, total, R + 1, C_b, w, h, b_item))
                        canvas.put(C_b, R + 1, '╰', b_color);
                }
            }
        }
    }
}

/// Write a label centered within `total_cells` columns starting at `x0`.
/// The cells are already filled; this overwrites the middle portion.
/// Rules: at least 1 fill cell remains on each side after centering.
///   total ≥ 3: show text or truncate; total < 3: no text.
///   If label doesn't fit with margin: truncate to (avail-1) chars + '…'.
///   If only 1 cell available for text: show '…' only.
fn writeLabelCentered(canvas: *Canvas, label: []const u8, x0: usize, y: usize, total_cells: usize, color: u8) void {
    if (total_cells < 3 or label.len == 0) return;

    const avail = total_cells - 2; // 1 fill margin each side

    var cp_count: usize = 0;
    {
        var i: usize = 0;
        while (i < label.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(label[i]) catch 1;
            i += seq_len;
            cp_count += 1;
        }
    }
    if (cp_count == 0) return;

    const needs_ellipsis = cp_count > avail;
    const show_count: usize = if (!needs_ellipsis) cp_count else if (avail >= 2) avail - 1 else 0;
    const text_width: usize = show_count + (if (needs_ellipsis) @as(usize, 1) else 0);

    // Center: integer division floors, so the extra cell goes to the right margin.
    const padding_left = (total_cells - text_width) / 2;
    var col = x0 + padding_left;

    var written: usize = 0;
    var i: usize = 0;
    while (i < label.len and written < show_count) {
        const seq_len = std.unicode.utf8ByteSequenceLength(label[i]) catch 1;
        if (i + seq_len > label.len) break;
        const cp = std.unicode.utf8Decode(label[i .. i + seq_len]) catch '?';
        canvas.put(col, y, cp, color);
        col += 1;
        written += 1;
        i += seq_len;
    }
    if (needs_ellipsis) {
        canvas.put(col, y, '…', color);
    }
}

fn writeLabel(canvas: *Canvas, label: []const u8, x: usize, y: usize, avail: usize, color: u8) void {
    if (avail < 3 or label.len == 0) return;

    // Count Unicode codepoints to determine truncation.
    var cp_count: usize = 0;
    {
        var i: usize = 0;
        while (i < label.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(label[i]) catch 1;
            i += seq_len;
            cp_count += 1;
        }
    }
    if (cp_count == 0) return;

    const needs_ellipsis = cp_count > avail;
    const show_count: usize = if (needs_ellipsis) avail - 1 else cp_count;

    var col = x;
    var written: usize = 0;
    var i: usize = 0;
    while (i < label.len and written < show_count) {
        const seq_len = std.unicode.utf8ByteSequenceLength(label[i]) catch 1;
        if (i + seq_len > label.len) break;
        const cp = std.unicode.utf8Decode(label[i .. i + seq_len]) catch '?';
        canvas.put(col, y, cp, color);
        col += 1;
        written += 1;
        i += seq_len;
    }
    if (needs_ellipsis) {
        canvas.put(col, y, '…', color);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "snakeToXY: row 0 is left-to-right" {
    const w = 6;
    try testing.expectEqual(@as(usize, 0), snakeToXY(0, w).col);
    try testing.expectEqual(@as(usize, 5), snakeToXY(5, w).col);
    try testing.expectEqual(@as(usize, 0), snakeToXY(0, w).row);
}

test "snakeToXY: row 1 is right-to-left" {
    const w = 6;
    // snake index 6 = row 1 offset 0 → col 5 (reversed)
    try testing.expectEqual(@as(usize, 5), snakeToXY(6, w).col);
    // snake index 11 = row 1 offset 5 → col 0
    try testing.expectEqual(@as(usize, 0), snakeToXY(11, w).col);
    try testing.expectEqual(@as(usize, 1), snakeToXY(6, w).row);
}

test "xyToSnake: round-trips snakeToXY" {
    const w = 7;
    for ([_]usize{ 0, 3, 7, 13, 20 }) |k| {
        const xy = snakeToXY(k, w);
        try testing.expectEqual(k, xyToSnake(xy.col, xy.row, w));
    }
}

test "layout: two equal-value items divide cells evenly" {
    const values = [_]f64{ 1.0, 1.0 };
    const coils = try layout(&values, 6, 4, testing.allocator);
    defer testing.allocator.free(coils);
    // 24 cells total → 12 each
    try testing.expectEqual(@as(usize, 0), coils[0].start);
    try testing.expectEqual(@as(usize, 12), coils[0].end);
    try testing.expectEqual(@as(usize, 12), coils[1].start);
    try testing.expectEqual(@as(usize, 24), coils[1].end);
}

test "layout: last item absorbs rounding remainder" {
    // 3 items, 10 cells: 50/30/20 → 5/3/2 (exact, no rounding issue)
    const values = [_]f64{ 5.0, 3.0, 2.0 };
    const coils = try layout(&values, 10, 1, testing.allocator);
    defer testing.allocator.free(coils);
    try testing.expectEqual(@as(usize, 10), coils[2].end);
}

test "layout: empty values returns empty coils" {
    const values = [_]f64{};
    const coils = try layout(&values, 8, 8, testing.allocator);
    defer testing.allocator.free(coils);
    try testing.expectEqual(@as(usize, 0), coils.len);
}

test "renderCoils: 6×6 canvas two full-row items have correct corners" {
    // Item 0: rows 0-2 (snake indices 0-17), item 1: rows 3-5 (18-35).
    // Each item spans 3 rows, so border mode applies.
    var c = try Canvas.init(testing.allocator, 6, 6);
    defer c.deinit();
    const values = [_]f64{ 1.0, 1.0 };
    const coils = try layout(&values, 6, 6, testing.allocator);
    defer testing.allocator.free(coils);
    const labels = [_][]const u8{ "", "" };
    try renderCoils(&c, coils, &labels, testing.allocator);
    // Item 0 corners.
    try testing.expectEqual(@as(u32, '┌'), c.cells[0 * 6 + 0]);
    try testing.expectEqual(@as(u32, '┐'), c.cells[0 * 6 + 5]);
    try testing.expectEqual(@as(u32, '└'), c.cells[2 * 6 + 0]);
    try testing.expectEqual(@as(u32, '┘'), c.cells[2 * 6 + 5]);
    // Item 1 corners.
    try testing.expectEqual(@as(u32, '┌'), c.cells[3 * 6 + 0]);
    try testing.expectEqual(@as(u32, '┐'), c.cells[3 * 6 + 5]);
    try testing.expectEqual(@as(u32, '└'), c.cells[5 * 6 + 0]);
    try testing.expectEqual(@as(u32, '┘'), c.cells[5 * 6 + 5]);
}

test "renderCoils: top/bottom edges are horizontal lines" {
    // Items must span 3+ rows to get border mode; use 6×6 (3 rows each).
    var c = try Canvas.init(testing.allocator, 6, 6);
    defer c.deinit();
    const values = [_]f64{ 1.0, 1.0 };
    const coils = try layout(&values, 6, 6, testing.allocator);
    defer testing.allocator.free(coils);
    const labels = [_][]const u8{ "", "" };
    try renderCoils(&c, coils, &labels, testing.allocator);
    // Inner cells of top row should be ─.
    for (1..5) |col| {
        try testing.expectEqual(@as(u32, '─'), c.cells[0 * 6 + col]);
    }
}

test "renderCoils: interior cells get fill char" {
    // 6×6 canvas, two items of 18 cells each (3 rows each).
    // Row 1 (middle row of item 0) should have interior fill chars.
    var c = try Canvas.init(testing.allocator, 6, 6);
    defer c.deinit();
    const values = [_]f64{ 1.0, 1.0 };
    const coils = try layout(&values, 6, 6, testing.allocator);
    defer testing.allocator.free(coils);
    const labels = [_][]const u8{ "", "" };
    try renderCoils(&c, coils, &labels, testing.allocator);
    // Cells (1..4, 1) should be fill chars (not box-drawing).
    for (1..5) |col| {
        const cp = c.cells[1 * 6 + col];
        // '░' U+2591 = 0x2591
        try testing.expectEqual(@as(u32, '░'), cp);
    }
}

test "renderCoils: label written inside coil" {
    var c = try Canvas.init(testing.allocator, 10, 4);
    defer c.deinit();
    const values = [_]f64{1.0};
    const coils = try layout(&values, 10, 4, testing.allocator);
    defer testing.allocator.free(coils);
    const labels = [_][]const u8{"Hi"};
    try renderCoils(&c, coils, &labels, testing.allocator);
    var found_h = false;
    for (c.cells) |cp| if (cp == 'H') {
        found_h = true;
    };
    try testing.expect(found_h);
}

test "injectStepCorners: even-row step — arcs and edge repairs" {
    // 10×6 canvas (60 cells). A=25 spans rows 0-2 (3 rows ✓), B=35 spans rows 2-5 (4 rows ✓).
    // Even-row step at row 2: A ends col 4, B starts col 5.
    // Expected 6 cells:
    //   (1,4)=╭(A),  (1,5)=─(A)
    //   (2,4)=╯(A),  (2,5)=╭(B)
    //   (3,4)=─(B),  (3,5)=╯(B)
    var c = try Canvas.init(testing.allocator, 10, 6);
    defer c.deinit();
    const values = [_]f64{ 25.0, 35.0 };
    const coils = try layout(&values, 10, 6, testing.allocator);
    defer testing.allocator.free(coils);
    const a_last = snakeToXY(coils[0].end - 1, 10);
    const b_first = snakeToXY(coils[1].start, 10);
    try testing.expectEqual(@as(usize, 2), a_last.row);
    try testing.expectEqual(@as(usize, 2), b_first.row);
    const labels = [_][]const u8{ "", "" };
    try renderCoils(&c, coils, &labels, testing.allocator);
    const C_a = a_last.col;
    const C_b = b_first.col;
    try testing.expectEqual(@as(u32, '╭'), c.cells[1 * 10 + C_a]);
    try testing.expectEqual(@as(u32, '─'), c.cells[1 * 10 + C_b]);
    try testing.expectEqual(@as(u32, '╯'), c.cells[2 * 10 + C_a]);
    try testing.expectEqual(@as(u32, '╭'), c.cells[2 * 10 + C_b]);
    try testing.expectEqual(@as(u32, '─'), c.cells[3 * 10 + C_a]);
    try testing.expectEqual(@as(u32, '╯'), c.cells[3 * 10 + C_b]);
}

test "injectStepCorners: border-to-fill boundary — only A's exit arc placed" {
    // 10×5 canvas (50 cells). A=35 (rows 0-3, 4 rows, border mode).
    // B=15 (rows 3-4, 2 rows, fill mode). Odd-row step at row 3.
    // A ends col 5, B starts col 4 (odd row: C_a=5, C_b=4).
    // Expected: ╮ at (2,5) and ╰ at (3,5). B's side (col 4) must NOT receive arc glyphs.
    var c = try Canvas.init(testing.allocator, 10, 5);
    defer c.deinit();
    const values = [_]f64{ 35.0, 15.0 };
    const coils = try layout(&values, 10, 5, testing.allocator);
    defer testing.allocator.free(coils);
    const a_last = snakeToXY(coils[0].end - 1, 10);
    const b_first = snakeToXY(coils[1].start, 10);
    try testing.expectEqual(@as(usize, 3), a_last.row); // odd row
    try testing.expectEqual(@as(usize, 3), b_first.row);
    const labels = [_][]const u8{ "", "" };
    try renderCoils(&c, coils, &labels, testing.allocator);
    const C_a = a_last.col; // 5
    const C_b = b_first.col; // 4
    // A's exit arc must be placed.
    try testing.expectEqual(@as(u32, '╮'), c.cells[2 * 10 + C_a]);
    try testing.expectEqual(@as(u32, '╰'), c.cells[3 * 10 + C_a]);
    // B's side: fill cells, not arc characters.
    try testing.expect(c.cells[3 * 10 + C_b] != '╮');
    try testing.expect(c.cells[4 * 10 + C_b] != '╰');
}

test "injectStepCorners: odd-row step — arcs and edge repairs" {
    // 10×6 canvas (60 cells). A=35 spans rows 0-3 (4 rows ✓), B=25 spans rows 3-5 (3 rows ✓).
    // Odd-row step at row 3: A ends col 5, B starts col 4.
    // Expected 6 cells:
    //   (2,5)=╮(A),  (2,4)=─(A)
    //   (3,5)=╰(A),  (3,4)=╮(B)
    //   (4,5)=─(B),  (4,4)=╰(B)
    var c = try Canvas.init(testing.allocator, 10, 6);
    defer c.deinit();
    const values = [_]f64{ 35.0, 25.0 };
    const coils = try layout(&values, 10, 6, testing.allocator);
    defer testing.allocator.free(coils);
    const a_last = snakeToXY(coils[0].end - 1, 10);
    const b_first = snakeToXY(coils[1].start, 10);
    try testing.expectEqual(@as(usize, 3), a_last.row);
    try testing.expectEqual(@as(usize, 3), b_first.row);
    const labels = [_][]const u8{ "", "" };
    try renderCoils(&c, coils, &labels, testing.allocator);
    const C_a = a_last.col;
    const C_b = b_first.col;
    try testing.expectEqual(@as(u32, '╮'), c.cells[2 * 10 + C_a]);
    try testing.expectEqual(@as(u32, '─'), c.cells[2 * 10 + C_b]);
    try testing.expectEqual(@as(u32, '╰'), c.cells[3 * 10 + C_a]);
    try testing.expectEqual(@as(u32, '╮'), c.cells[3 * 10 + C_b]);
    try testing.expectEqual(@as(u32, '─'), c.cells[4 * 10 + C_a]);
    try testing.expectEqual(@as(u32, '╰'), c.cells[4 * 10 + C_b]);
}
