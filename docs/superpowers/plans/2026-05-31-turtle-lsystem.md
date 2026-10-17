# Turtle Graphics + L-System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `src/lib/turtle.zig` — a standalone turtle graphics interpreter and Lindenmayer system expander that draws onto a `Canvas`.

**Architecture:** `turtle.zig` imports `Canvas` from `canvas.zig` and adds three independent layers: (1) `Turtle` + `TurtleOp` for imperative drawing via an op-list, (2) `LSystem` + `expand` for string rewriting, (3) `interpretLSystem` that connects the two. `bresenhamSigned` is duplicated from `canvas.zig`'s private `bresenham` with signed `i64` coordinates so the turtle can walk to negative positions without a usize underflow. All tests live inline in `turtle.zig`.

**Tech Stack:** Zig 0.16.0, `std.math.cos/sin`, `std.ArrayList` (unmanaged), `std.mem.Allocator`.

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/lib/turtle.zig` | **Create** | `Rule`, `TurtleOp`, `Turtle`, `LSystem`, `interpretLSystem`, all tests |
| `src/lib/canvas.zig` | **No change** | `Canvas`, `DataRange`, draw primitives — unchanged |
| `src/root.zig` | **Modify** | Add `pub const turtle = @import("lib/turtle.zig");` so `zig build test` picks up turtle tests |

---

## Task 1: Types + `Turtle.init` + pen ops

**Files:**
- Create: `src/lib/turtle.zig`

- [ ] **Step 1: Write the file with types and failing tests**

Create `src/lib/turtle.zig` with the type definitions and tests for `init`, `pen_down`, `pen_up`, and `color` ops. No method bodies yet — leave them as stubs that compile but fail the tests.

```zig
const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const testing = std.testing;

// ─── Types ────────────────────────────────────────────────────────────────────

pub const Rule = struct { from: u8, to: []const u8 };

pub const TurtleOp = union(enum) {
    pen_down,
    pen_up,
    forward:    f64,
    turn_right: f64,
    turn_left:  f64,
    color:      u8,
};

pub const Turtle = struct {
    x:           f64,
    y:           f64,
    heading_deg: f64,
    pen:         bool,
    color:       u8,

    pub fn init(x: f64, y: f64) Turtle {
        return .{ .x = x, .y = y, .heading_deg = 0.0, .pen = false, .color = 7 };
    }

    pub fn execute(self: *Turtle, canvas: *Canvas, ops: []const TurtleOp) void {
        _ = canvas;
        for (ops) |op| {
            switch (op) {
                .pen_down    => self.pen = true,
                .pen_up      => self.pen = false,
                .color       => |c| self.color = c,
                .forward     => |_| {},   // stub
                .turn_right  => |_| {},   // stub
                .turn_left   => |_| {},   // stub
            }
        }
    }
};

pub const LSystem = struct {
    start:      []const u8,
    rules:      []const Rule,
    angle:      f64,
    implicit_f: bool,

    pub fn expand(self: LSystem, iterations: usize, allocator: std.mem.Allocator) ![]u8 {
        _ = iterations;
        return allocator.dupe(u8, self.start); // stub
    }
};

pub fn interpretLSystem(
    turtle: *Turtle,
    canvas: *Canvas,
    string: []const u8,
    step: f64,
    system: LSystem,
    start_angle: f64,
) void {
    _ = turtle; _ = canvas; _ = string; _ = step; _ = system; _ = start_angle; // stub
}

// ─── Internal helpers (stubs) ────────────────────────────────────────────────

fn normalizeAngle(deg: f64) f64 { return deg; } // stub

fn bresenhamSigned(_: *Canvas, _: i64, _: i64, _: i64, _: i64, _: u8) void {} // stub

fn lineChar(_: i64, _: i64, _: i64, _: i64) u21 { return ' '; } // stub

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
```

- [ ] **Step 2: Run — expect the color test to fail (forward is a stub)**

```bash
zig test src/lib/turtle.zig
```

Expected: first 3 tests pass, color test fails because `forward` stub draws nothing.

- [ ] **Step 3: Wire into root.zig so `zig build test` picks up turtle tests**

Open `src/root.zig` and add inside the `lib` struct:
```zig
pub const turtle = @import("lib/turtle.zig");
```

---

## Task 2: `bresenhamSigned` + `lineChar` + `normalizeAngle` + `Turtle.forward`

**Files:**
- Modify: `src/lib/turtle.zig`

- [ ] **Step 1: Add failing test for forward-pen-up (canvas unchanged)**

Append to the test section:

```zig
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
    for (c.cells) |cell| if (cell != ' ') { drawn += 1; };
    try testing.expect(drawn >= 5);
}
```

- [ ] **Step 2: Run — expect failures (forward is still a stub)**

```bash
zig test src/lib/turtle.zig
```

Expected: both new tests fail (pen-up passes vacuously, pen-down fails because nothing is drawn).

- [ ] **Step 3: Implement `normalizeAngle`, `lineChar`, `bresenhamSigned`, and `Turtle.stepForward`**

Replace the stub implementations:

```zig
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

fn bresenhamSigned(canvas: *Canvas, x0: i64, y0: i64, x1: i64, y1: i64, color: u8) void {
    var cx: i64 = x0;
    var cy: i64 = y0;
    const adx: i64 = @abs(x1 - x0);
    const ady: i64 = @abs(y1 - y0);
    const sx: i64 = if (x0 <= x1) 1 else -1;
    const sy: i64 = if (y0 <= y1) 1 else -1;
    var err: i64 = adx - ady;
    while (true) {
        if (cx >= 0 and cy >= 0)
            canvas.put(@intCast(cx), @intCast(cy), lineChar(adx, ady, sx, sy), color);
        if (cx == x1 and cy == y1) break;
        const e2 = 2 * err;
        if (e2 > -ady) { err -= ady; cx += sx; }
        if (e2 < adx)  { err += adx; cy += sy; }
    }
}
```

Add `stepForward` inside the `Turtle` struct and update `execute` to call it:

```zig
// Inside Turtle struct — replace the forward stub in execute:
.forward => |steps| self.stepForward(canvas, steps),

// New private method inside Turtle struct:
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
```

Also remove the `_ = canvas;` line from `execute` since it's now used.

- [ ] **Step 4: Run — expect all tests so far to pass**

```bash
zig test src/lib/turtle.zig
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/turtle.zig src/root.zig
git commit -m "feat: add Turtle with forward, pen, color ops and bresenhamSigned"
```

---

## Task 3: Turn ops + heading wrap + rectangle integration

**Files:**
- Modify: `src/lib/turtle.zig`

- [ ] **Step 1: Add failing tests for turn ops and rectangle**

Append to the test section:

```zig
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
    // 270 + 180 = 450 → 90
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
    for (c.cells) |cell| if (cell != ' ') { drawn += 1; };
    try testing.expect(drawn >= 15);
}
```

- [ ] **Step 2: Run — expect turn and rectangle tests to fail (stubs)**

```bash
zig test src/lib/turtle.zig
```

Expected: turn_right, turn_left, heading wrap, and rectangle tests fail.

- [ ] **Step 3: Implement turn ops in `execute`**

Replace the turn stubs inside `execute`:

```zig
.turn_right => |deg| self.heading_deg = normalizeAngle(self.heading_deg + deg),
.turn_left  => |deg| self.heading_deg = normalizeAngle(self.heading_deg - deg),
```

- [ ] **Step 4: Run — all tests pass**

```bash
zig test src/lib/turtle.zig
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/turtle.zig
git commit -m "feat: implement turn_right/turn_left and normalizeAngle; rectangle test green"
```

---

## Task 4: `LSystem.expand`

**Files:**
- Modify: `src/lib/turtle.zig`

- [ ] **Step 1: Add failing tests for expand**

Append to the test section:

```zig
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
```

- [ ] **Step 2: Run — expect all expand tests to fail (stub returns start unchanged)**

```bash
zig test src/lib/turtle.zig
```

Expected: 0-iterations test passes (coincidence), 1-iter, 2-iter, and passthrough tests fail.

- [ ] **Step 3: Implement `LSystem.expand`**

Replace the stub body of `expand`:

```zig
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
```

- [ ] **Step 4: Run — all tests pass**

```bash
zig test src/lib/turtle.zig
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/turtle.zig
git commit -m "feat: implement LSystem.expand with iterative string rewriting"
```

---

## Task 5: `interpretLSystem` + Hilbert smoke test

**Files:**
- Modify: `src/lib/turtle.zig`

- [ ] **Step 1: Add failing tests for interpretLSystem**

Append to the test section:

```zig
test "interpretLSystem: f draws cells on canvas" {
    var c = try Canvas.init(testing.allocator, 12, 4);
    defer c.deinit();
    var t = Turtle.init(1, 1);
    t.pen = true;
    const sys = LSystem{ .start = "", .rules = &[_]Rule{}, .angle = 0.25, .implicit_f = false };
    interpretLSystem(&t, &c, "fffff", 1.0, sys, 0.0);
    var drawn: usize = 0;
    for (c.cells) |cell| if (cell != ' ') { drawn += 1; };
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
    t.heading_deg = 42.0; // will be overwritten
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
    for (c.cells) |cell| if (cell != ' ') { drawn += 1; };
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
    var t = Turtle.init(1.0, 1.0);
    t.pen = true;
    interpretLSystem(&t, &c, expanded, 1.0, hilbert, 270.0);
    var drawn: usize = 0;
    for (c.cells) |cell| if (cell != ' ') { drawn += 1; };
    try testing.expect(drawn > 100);
}
```

- [ ] **Step 2: Run — all interpretLSystem tests fail (stub does nothing)**

```bash
zig test src/lib/turtle.zig
```

Expected: all 7 new tests fail.

- [ ] **Step 3: Implement `interpretLSystem`**

Replace the stub body:

```zig
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
```

- [ ] **Step 4: Run — all tests pass**

```bash
zig test src/lib/turtle.zig
```

Expected: all tests pass including the Hilbert smoke test.

- [ ] **Step 5: Commit**

```bash
git add src/lib/turtle.zig
git commit -m "feat: implement interpretLSystem with start_angle; Hilbert curve smoke test green"
```

---

## Task 6: Final integration check

**Files:**
- Modify: `src/root.zig` (confirm wired)

- [ ] **Step 1: Confirm root.zig has the turtle import**

`src/root.zig` `lib` struct should contain:
```zig
pub const turtle = @import("lib/turtle.zig");
```

- [ ] **Step 2: Run full check**

```bash
task check:all
```

Expected output ends with: `All checks passed!`

- [ ] **Step 3: Commit**

```bash
git add src/root.zig src/lib/turtle.zig
git commit -m "feat: add turtle.zig to lib exports; all checks pass"
```
