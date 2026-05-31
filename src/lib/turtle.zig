/// Turtle graphics interpreter and Lindenmayer system expander.
/// Draws onto a Canvas using Bresenham lines. No DuckDB dependency.
const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const testing = std.testing;

// ─── Types ────────────────────────────────────────────────────────────────────

/// A single rewrite rule: replace character `from` with string `to`.
pub const Rule = struct { from: u8, to: []const u8 };

/// Atomic turtle command. Store in a caller-managed ArrayList(TurtleOp).
pub const TurtleOp = union(enum) {
    pen_down,
    pen_up,
    forward: f64,
    turn_right: f64,
    turn_left: f64,
    color: u8,
};

/// Mutable turtle state. Create with Turtle.init; pass *Turtle to execute/interpret.
pub const Turtle = struct {
    x: f64,
    y: f64,
    heading_deg: f64, // screen-space: 0=right, 90=down, 180=left, 270=up
    pen: bool,
    color: u8,

    pub fn init(x: f64, y: f64) Turtle {
        return .{ .x = x, .y = y, .heading_deg = 0.0, .pen = false, .color = 7 };
    }

    /// Walk `ops` in order. `forward` draws with Bresenham when `pen` is true.
    pub fn execute(self: *Turtle, canvas: *Canvas, ops: []const TurtleOp) void {
        for (ops) |op| {
            switch (op) {
                .pen_down => self.pen = true,
                .pen_up => self.pen = false,
                .color => |c| self.color = c,
                .forward => |steps| self.stepForward(canvas, steps),
                .turn_right => |deg| self.heading_deg = normalizeAngle(self.heading_deg + deg),
                .turn_left => |deg| self.heading_deg = normalizeAngle(self.heading_deg - deg),
            }
        }
    }

    fn stepForward(self: *Turtle, canvas: *Canvas, steps: f64) void {
        const rad = self.heading_deg * std.math.pi / 180.0;
        const new_x = self.x + std.math.cos(rad) * steps;
        const new_y = self.y + std.math.sin(rad) * steps;
        if (self.pen) {
            const x0: i64 = @intFromFloat(@round(self.x));
            const y0: i64 = @intFromFloat(@round(self.y));
            const x1: i64 = @intFromFloat(@round(new_x));
            const y1: i64 = @intFromFloat(@round(new_y));
            bresenhamSigned(canvas, x0, y0, x1, y1, self.color);
        }
        self.x = new_x;
        self.y = new_y;
    }
};

/// Immutable L-system definition. Rules are applied in order; first match wins.
pub const LSystem = struct {
    start: []const u8,
    rules: []const Rule,
    angle: f64, // fraction of a full turn (0.25 → 90°, 1.0/6.0 → 60°)
    implicit_f: bool, // if true, any non-symbol letter acts as forward

    /// Apply rewrite rules `iterations` times from `self.start`. Caller owns result.
    pub fn expand(self: LSystem, iterations: usize, allocator: std.mem.Allocator) ![]u8 {
        var current = try allocator.dupe(u8, self.start);
        for (0..iterations) |_| {
            var next = std.ArrayList(u8).empty;
            for (current) |ch| {
                var found = false;
                for (self.rules) |rule| {
                    if (rule.from == ch) {
                        try next.appendSlice(allocator, rule.to);
                        found = true;
                        break;
                    }
                }
                if (!found) try next.append(allocator, ch);
            }
            allocator.free(current);
            current = try next.toOwnedSlice(allocator);
        }
        return current;
    }
};

/// Set `turtle.heading_deg = start_angle`, then interpret each byte of `string`:
///   f / F  → forward `step` canvas cells
///   +      → turn left (CCW), heading -= angle*360°
///   -      → turn right (CW), heading += angle*360°
///   other letter → forward if `system.implicit_f`, else skip
pub fn interpretLSystem(
    turtle: *Turtle,
    canvas: *Canvas,
    string: []const u8,
    step: f64,
    system: LSystem,
    start_angle: f64,
) void {
    turtle.heading_deg = start_angle;
    const angle_deg = system.angle * 360.0;
    for (string) |ch| {
        switch (ch) {
            'f', 'F' => turtle.stepForward(canvas, step),
            '+' => turtle.heading_deg = normalizeAngle(turtle.heading_deg - angle_deg),
            '-' => turtle.heading_deg = normalizeAngle(turtle.heading_deg + angle_deg),
            else => {
                if (system.implicit_f and ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z')))
                    turtle.stepForward(canvas, step);
            },
        }
    }
}

// ─── Bounding box / auto-fit ─────────────────────────────────────────────────

/// Axis-aligned bounding box of all positions visited during a dry-run walk.
pub const Bounds = struct {
    min_x: f64,
    max_x: f64,
    min_y: f64,
    max_y: f64,

    pub fn width(self: Bounds) f64 {
        return self.max_x - self.min_x;
    }
    pub fn height(self: Bounds) f64 {
        return self.max_y - self.min_y;
    }
};

/// Walk `string` without a canvas and return the bounding box of all visited
/// positions. Interpretation rules are identical to `interpretLSystem`.
/// Starting position is treated as (0, 0); translate results as needed.
pub fn boundingBox(string: []const u8, system: LSystem, start_angle: f64, step: f64) Bounds {
    var x: f64 = 0.0;
    var y: f64 = 0.0;
    var heading: f64 = start_angle;
    var min_x: f64 = 0.0;
    var max_x: f64 = 0.0;
    var min_y: f64 = 0.0;
    var max_y: f64 = 0.0;
    const angle_deg = system.angle * 360.0;
    for (string) |ch| {
        switch (ch) {
            'f', 'F' => {
                const rad = heading * std.math.pi / 180.0;
                x += std.math.cos(rad) * step;
                y += std.math.sin(rad) * step;
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            },
            '+' => heading = normalizeAngle(heading - angle_deg),
            '-' => heading = normalizeAngle(heading + angle_deg),
            else => {
                if (system.implicit_f and ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z'))) {
                    const rad = heading * std.math.pi / 180.0;
                    x += std.math.cos(rad) * step;
                    y += std.math.sin(rad) * step;
                    if (x < min_x) min_x = x;
                    if (x > max_x) max_x = x;
                    if (y < min_y) min_y = y;
                    if (y > max_y) max_y = y;
                }
            },
        }
    }
    return .{ .min_x = min_x, .max_x = max_x, .min_y = min_y, .max_y = max_y };
}

/// Turtle start position and step size that scales `bounds` (computed at step=1)
/// to fill a canvas of size `canvas_width × canvas_height` with `margin` cell padding.
/// Pass the returned `x`, `y` to `Turtle.init` and `step` to `interpretLSystem`.
pub const FitResult = struct { x: f64, y: f64, step: f64 };

pub fn fitToCanvas(
    bounds: Bounds,
    canvas_width: usize,
    canvas_height: usize,
    margin: usize,
) FitResult {
    const avail_w: f64 = @floatFromInt(if (canvas_width > 2 * margin) canvas_width - 2 * margin else 1);
    const avail_h: f64 = @floatFromInt(if (canvas_height > 2 * margin) canvas_height - 2 * margin else 1);
    const span_x = bounds.width();
    const span_y = bounds.height();
    const scale: f64 = if (span_x == 0 and span_y == 0)
        1.0
    else if (span_x == 0)
        avail_h / span_y
    else if (span_y == 0)
        avail_w / span_x
    else
        @min(avail_w / span_x, avail_h / span_y);
    const m: f64 = @floatFromInt(margin);
    return .{
        .x = m + (-bounds.min_x) * scale,
        .y = m + (-bounds.min_y) * scale,
        .step = scale,
    };
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

fn normalizeAngle(deg: f64) f64 {
    const d = @rem(deg, 360.0);
    return if (d < 0) d + 360.0 else d;
}

fn lineChar(adx: i64, ady: i64, sx: i64, sy: i64) u21 {
    if (ady == 0) return '─';
    if (adx == 0) return '│';
    if (adx > ady * 2) return '─';
    if (ady > adx * 2) return '│';
    return if (sx == sy) '╲' else '╱';
}

/// Bresenham line with signed i64 coordinates so the turtle can walk to negative
/// positions. Out-of-bounds pixels are dropped by Canvas.put.
fn bresenhamSigned(canvas: *Canvas, x0: i64, y0: i64, x1: i64, y1: i64, color: u8) void {
    var cx: i64 = x0;
    var cy: i64 = y0;
    const adx: i64 = @intCast(@abs(x1 - x0));
    const ady: i64 = @intCast(@abs(y1 - y0));
    const sx: i64 = if (x0 <= x1) 1 else -1;
    const sy: i64 = if (y0 <= y1) 1 else -1;
    var err: i64 = adx - ady;
    while (true) {
        if (cx >= 0 and cy >= 0)
            canvas.put(@intCast(cx), @intCast(cy), lineChar(adx, ady, sx, sy), color);
        if (cx == x1 and cy == y1) break;
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

// ─── Tests ────────────────────────────────────────────────────────────────────

test "Turtle.init: position, heading, pen, color" {
    const t = Turtle.init(3.0, 7.0);
    try testing.expectEqual(@as(f64, 3.0), t.x);
    try testing.expectEqual(@as(f64, 7.0), t.y);
    try testing.expectEqual(@as(f64, 0.0), t.heading_deg);
    try testing.expect(!t.pen);
    try testing.expectEqual(@as(u8, 7), t.color);
}

test "Turtle.execute: pen_down enables drawing" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    const ops = [_]TurtleOp{.pen_down};
    t.execute(&c, &ops);
    try testing.expect(t.pen);
}

test "Turtle.execute: pen_up disables drawing" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    t.pen = true;
    const ops = [_]TurtleOp{.pen_up};
    t.execute(&c, &ops);
    try testing.expect(!t.pen);
}

test "Turtle.execute: color op changes turtle colour" {
    var c = try Canvas.init(testing.allocator, 10, 6);
    defer c.deinit();
    var t = Turtle.init(1, 1);
    const ops = [_]TurtleOp{ .{ .color = 12 }, .pen_down, .{ .forward = 5 } };
    t.execute(&c, &ops);
    for (c.cells, c.attrs) |cell, attr| {
        if (cell != ' ') try testing.expectEqual(@as(u8, 12), attr);
    }
}

test "Turtle.execute: forward pen-up leaves canvas empty" {
    var c = try Canvas.init(testing.allocator, 10, 5);
    defer c.deinit();
    var t = Turtle.init(1, 2);
    const ops = [_]TurtleOp{.{ .forward = 7 }};
    t.execute(&c, &ops);
    for (c.cells) |cell| try testing.expectEqual(@as(u32, ' '), cell);
}

test "Turtle.execute: forward pen-down draws cells" {
    var c = try Canvas.init(testing.allocator, 12, 5);
    defer c.deinit();
    var t = Turtle.init(1, 2);
    const ops = [_]TurtleOp{ .pen_down, .{ .forward = 8 } };
    t.execute(&c, &ops);
    var drawn: usize = 0;
    for (c.cells) |cell| if (cell != ' ') {
        drawn += 1;
    };
    try testing.expect(drawn >= 5);
}

test "Turtle.execute: turn_right increases heading (CW)" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    const ops = [_]TurtleOp{.{ .turn_right = 90 }};
    t.execute(&c, &ops);
    try testing.expectApproxEqAbs(@as(f64, 90.0), t.heading_deg, 1e-9);
}

test "Turtle.execute: turn_left decreases heading (CCW, wraps)" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    const ops = [_]TurtleOp{.{ .turn_left = 90 }};
    t.execute(&c, &ops);
    try testing.expectApproxEqAbs(@as(f64, 270.0), t.heading_deg, 1e-9);
}

test "Turtle.execute: heading wraps at 360" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    const ops = [_]TurtleOp{ .{ .turn_right = 270 }, .{ .turn_right = 180 } };
    t.execute(&c, &ops);
    try testing.expectApproxEqAbs(@as(f64, 90.0), t.heading_deg, 1e-9);
}

test "Turtle.execute: rectangle path via ArrayList draws perimeter" {
    var c = try Canvas.init(testing.allocator, 20, 14);
    defer c.deinit();
    var t = Turtle.init(2.0, 2.0);
    var ops = std.ArrayList(TurtleOp).empty;
    defer ops.deinit(testing.allocator);
    try ops.append(testing.allocator, .pen_down);
    try ops.append(testing.allocator, .{ .forward = 6 });
    try ops.append(testing.allocator, .{ .turn_right = 90 });
    try ops.append(testing.allocator, .{ .forward = 4 });
    try ops.append(testing.allocator, .{ .turn_right = 90 });
    try ops.append(testing.allocator, .{ .forward = 6 });
    try ops.append(testing.allocator, .{ .turn_right = 90 });
    try ops.append(testing.allocator, .{ .forward = 4 });
    try ops.append(testing.allocator, .pen_up);
    t.execute(&c, ops.items);
    var drawn: usize = 0;
    for (c.cells) |cell| if (cell != ' ') {
        drawn += 1;
    };
    try testing.expect(drawn >= 15);
}

test "LSystem.expand: 0 iterations returns start unchanged" {
    const sys = LSystem{ .start = "AB", .rules = &[_]Rule{.{ .from = 'A', .to = "X" }}, .angle = 0.25, .implicit_f = false };
    const result = try sys.expand(0, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("AB", result);
}

test "LSystem.expand: 1 iteration applies rules" {
    const hilbert = LSystem{
        .start = "A",
        .rules = &[_]Rule{
            .{ .from = 'A', .to = "+Bf-AfA-fB+" },
            .{ .from = 'B', .to = "-Af+BfB+fA-" },
        },
        .angle = 0.25,
        .implicit_f = false,
    };
    const result = try hilbert.expand(1, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("+Bf-AfA-fB+", result);
}

test "LSystem.expand: 2 iterations applies rules twice" {
    const hilbert = LSystem{
        .start = "A",
        .rules = &[_]Rule{
            .{ .from = 'A', .to = "+Bf-AfA-fB+" },
            .{ .from = 'B', .to = "-Af+BfB+fA-" },
        },
        .angle = 0.25,
        .implicit_f = false,
    };
    const result = try hilbert.expand(2, testing.allocator);
    defer testing.allocator.free(result);
    // "+Bf-AfA-fB+" with B→"-Af+BfB+fA-" and A→"+Bf-AfA-fB+" = 51 chars
    try testing.expectEqual(@as(usize, 51), result.len);
    try testing.expect(std.mem.startsWith(u8, result, "+-Af+BfB+fA-"));
}

test "LSystem.expand: chars with no rule are copied unchanged" {
    const sys = LSystem{ .start = "A+B-f", .rules = &[_]Rule{.{ .from = 'A', .to = "X" }}, .angle = 0.25, .implicit_f = false };
    const result = try sys.expand(1, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("X+B-f", result);
}

test "interpretLSystem: f draws cells on canvas" {
    var c = try Canvas.init(testing.allocator, 12, 4);
    defer c.deinit();
    var t = Turtle.init(1, 1);
    t.pen = true;
    const sys = LSystem{ .start = "", .rules = &[_]Rule{}, .angle = 0.25, .implicit_f = false };
    interpretLSystem(&t, &c, "fffff", 1.0, sys, 0.0);
    var drawn: usize = 0;
    for (c.cells) |cell| if (cell != ' ') {
        drawn += 1;
    };
    try testing.expect(drawn >= 4);
}

test "interpretLSystem: + turns left (CCW), heading decreases" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    const sys = LSystem{ .start = "", .rules = &[_]Rule{}, .angle = 0.25, .implicit_f = false };
    interpretLSystem(&t, &c, "+", 1.0, sys, 0.0);
    // + is CCW: 0 - 90 = 270
    try testing.expectApproxEqAbs(@as(f64, 270.0), t.heading_deg, 1e-9);
}

test "interpretLSystem: - turns right (CW), heading increases" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    const sys = LSystem{ .start = "", .rules = &[_]Rule{}, .angle = 0.25, .implicit_f = false };
    interpretLSystem(&t, &c, "-", 1.0, sys, 0.0);
    // - is CW: 0 + 90 = 90
    try testing.expectApproxEqAbs(@as(f64, 90.0), t.heading_deg, 1e-9);
}

test "interpretLSystem: start_angle sets initial heading" {
    var c = try Canvas.init(testing.allocator, 4, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    t.heading_deg = 42.0;
    const sys = LSystem{ .start = "", .rules = &[_]Rule{}, .angle = 0.25, .implicit_f = false };
    interpretLSystem(&t, &c, "", 1.0, sys, 270.0);
    try testing.expectApproxEqAbs(@as(f64, 270.0), t.heading_deg, 1e-9);
}

test "interpretLSystem: implicit_f=false skips non-f letters" {
    var c = try Canvas.init(testing.allocator, 8, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    t.pen = true;
    const sys = LSystem{ .start = "", .rules = &[_]Rule{}, .angle = 0.25, .implicit_f = false };
    interpretLSystem(&t, &c, "AAAA", 1.0, sys, 0.0);
    for (c.cells) |cell| try testing.expectEqual(@as(u32, ' '), cell);
}

test "interpretLSystem: implicit_f=true draws for non-f letters" {
    var c = try Canvas.init(testing.allocator, 8, 4);
    defer c.deinit();
    var t = Turtle.init(0, 0);
    t.pen = true;
    const sys = LSystem{ .start = "", .rules = &[_]Rule{}, .angle = 0.25, .implicit_f = true };
    interpretLSystem(&t, &c, "AAAA", 1.0, sys, 0.0);
    var drawn: usize = 0;
    for (c.cells) |cell| if (cell != ' ') {
        drawn += 1;
    };
    try testing.expect(drawn >= 3);
}

test "interpretLSystem: Hilbert curve depth 5 draws non-empty canvas" {
    const hilbert = LSystem{
        .start = "A",
        .rules = &[_]Rule{
            .{ .from = 'A', .to = "+Bf-AfA-fB+" },
            .{ .from = 'B', .to = "-Af+BfB+fA-" },
        },
        .angle = 0.25,
        .implicit_f = false,
    };
    const expanded = try hilbert.expand(5, testing.allocator);
    defer testing.allocator.free(expanded);
    var c = try Canvas.init(testing.allocator, 36, 36);
    defer c.deinit();
    const bounds = boundingBox(expanded, hilbert, 270.0, 1.0);
    const fit = fitToCanvas(bounds, c.width, c.height, 1);
    var t = Turtle.init(fit.x, fit.y);
    t.pen = true;
    interpretLSystem(&t, &c, expanded, fit.step, hilbert, 270.0);
    var drawn: usize = 0;
    for (c.cells) |cell| if (cell != ' ') {
        drawn += 1;
    };
    try testing.expect(drawn > 100);
}

test "boundingBox: horizontal line step=1 has correct span" {
    const sys = LSystem{ .start = "", .rules = &[_]Rule{}, .angle = 0.25, .implicit_f = false };
    const b = boundingBox("fffff", sys, 0.0, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), b.min_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.0), b.max_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), b.min_y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), b.max_y, 1e-9);
}

test "fitToCanvas: step scales to fill available width" {
    // span_x=10, span_y=0 → scale = avail_w / 10
    const b = Bounds{ .min_x = 0.0, .max_x = 10.0, .min_y = 0.0, .max_y = 0.0 };
    const fit = fitToCanvas(b, 22, 10, 1); // avail_w=20, avail_h=8
    try testing.expectApproxEqAbs(@as(f64, 2.0), fit.step, 1e-9); // 20/10
    try testing.expectApproxEqAbs(@as(f64, 1.0), fit.x, 1e-9); // margin
    try testing.expectApproxEqAbs(@as(f64, 1.0), fit.y, 1e-9);
}
