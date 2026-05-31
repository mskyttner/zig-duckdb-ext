# Turtle Graphics + L-System Design

**Date:** 2026-05-31  
**File:** `src/lib/turtle.zig`  
**Depends on:** `src/lib/canvas.zig`

## Summary

Add a turtle graphics interpreter and Lindenmayer system expander as a new standalone module. The turtle walks a `Canvas`, drawing with Bresenham lines. L-system strings are expanded from rewrite rules and then fed to the turtle interpreter, enabling space-filling curves (Hilbert, Peano), fractal outlines, and other procedural patterns expressible as sequential turtle programs.

## Coordinate System

Screen-space (Option A): `x` increases right, `y` increases down, matching `Canvas` row/column layout.

| Heading (°) | Direction on screen |
|-------------|---------------------|
| 0           | right               |
| 90          | down                |
| 180         | left                |
| 270         | up                  |

`+` rotates clockwise (heading += angle), `-` rotates counter-clockwise (heading -= angle). Heading is normalised to `[0, 360)` after every turn.

## Data Types

```zig
// A single rewrite rule: replace character `from` with string `to`.
pub const Rule = struct { from: u8, to: []const u8 };

// Atomic turtle command. Stored in a caller-managed ArrayList(TurtleOp).
pub const TurtleOp = union(enum) {
    pen_down,
    pen_up,
    forward:    f64,   // canvas-cell steps (sub-cell precision held in Turtle.x/y)
    turn_right: f64,   // degrees
    turn_left:  f64,   // degrees
    color:      u8,    // ANSI 256-colour index
};

// Mutable turtle state. Caller creates with Turtle.init; pass *Turtle to execute/interpret.
pub const Turtle = struct {
    x:           f64,   // canvas column (floating-point for sub-cell accumulation)
    y:           f64,   // canvas row
    heading_deg: f64,   // screen-space degrees; 0=right, 90=down
    pen:         bool,
    color:       u8,
};

// Immutable L-system definition. Rules are applied in order; first match wins.
pub const LSystem = struct {
    start:      []const u8,
    rules:      []const Rule,
    angle:      f64,   // fraction of a full turn (0.25 → 90°, 1.0/6.0 → 60°)
    implicit_f: bool,  // if true, any non-symbol letter acts as forward
};
```

## Functions

### `Turtle.init(x: f64, y: f64) Turtle`
Returns a turtle at `(x, y)`, heading 0° (right), pen up, colour 7 (white).

### `Turtle.execute(self: *Turtle, canvas: *Canvas, ops: []const TurtleOp) void`
Walks `ops` in order. `forward` draws with Bresenham when `pen` is true; out-of-bounds pixels are silently dropped by `canvas.put`. `color` updates the turtle's colour for subsequent drawing.

### `LSystem.expand(self: LSystem, iterations: usize, allocator: Allocator) ![]u8`
Applies rewrite rules `iterations` times starting from `self.start`. Characters with no matching rule are copied unchanged. Returns the expanded string; caller owns and must free.

### `interpretLSystem(turtle: *Turtle, canvas: *Canvas, string: []const u8, step: f64, system: LSystem) void`
Interprets each byte of `string`:

| Byte | Action |
|------|--------|
| `f` or `F` | `turtle.forward(canvas, step)` |
| `+` | turn right by `system.angle × 360°` |
| `-` | turn left by `system.angle × 360°` |
| other letter | forward if `system.implicit_f`, else skip |
| anything else | skip |

Respects the turtle's current pen state — set `turtle.pen = true` before calling.

## L-System Character Convention

```
f / F   forward one step
+       turn right  (clockwise on screen)
-       turn left   (counter-clockwise)
A–Z     variables: rewritten by rules, drawn if implicit_f
```

Example — L-shape (`-f+ff`, pen down, starting right, angle 0.25):
1. `-` → turn left 90° → heading 270° (up)
2. `f` → forward 1 (up)
3. `+` → turn right 90° → heading 0° (right)
4. `f` → forward 1 (right)
5. `f` → forward 1 (right)

Result: vertical stroke up, then two cells right — an L.

## Hilbert Curve Example

```zig
const hilbert = LSystem{
    .start      = "A",
    .rules      = &[_]Rule{
        .{ .from = 'A', .to = "+Bf-AfA-fB+" },
        .{ .from = 'B', .to = "-Af+BfB+fA-" },
    },
    .angle      = 0.25,   // 90°
    .implicit_f = false,
};
const expanded = try hilbert.expand(5, allocator);
defer allocator.free(expanded);
var t = Turtle.init(1, 1);
t.pen = true;
interpretLSystem(&t, &canvas, expanded, 1.0, hilbert);
```

## File Structure

```
src/lib/
  canvas.zig   — unchanged; Canvas, DataRange, drawAxes, drawScatter, drawLine, setBrailleDot
  turtle.zig   — new; Rule, TurtleOp, Turtle, LSystem, interpretLSystem
```

`turtle.zig` imports `canvas.zig` for `Canvas` and the internal `bresenhamSigned` helper (extracted from canvas.zig as a package-visible function, or duplicated — see Implementation Notes).

## Implementation Notes

- `bresenhamSigned(canvas, i64, i64, i64, i64, color)` handles signed coordinates so the turtle can walk to negative positions without a usize underflow panic; `canvas.put` already drops out-of-bounds writes.
- Heading normalisation: `heading = @rem(heading + delta, 360.0); if (heading < 0) heading += 360.0;`
- `LSystem.expand` frees the intermediate buffer on each iteration; the final buffer is returned to the caller.
- `interpretLSystem` is stateless beyond the turtle it mutates — no allocations.

## Test Plan

| Test | What it checks |
|------|----------------|
| `Turtle.init` state | x, y, heading=0, pen=false, color=7 |
| `pen_down` / `pen_up` ops | pen field toggled |
| forward pen-up | canvas unchanged |
| forward pen-down | at least one non-empty cell |
| `turn_right` | heading += angle |
| `turn_left` | heading -= angle (wrapped) |
| heading wrap | 270 + 180 = 90 |
| colour op | all drawn cells have new colour |
| rectangle via ArrayList | exact spec example; drawn >= 15 cells |
| `LSystem.expand` 1 iter | A → "+Bf-AfA-fB+" |
| `LSystem.expand` 2 iter | A replaced again inside result |
| `interpretLSystem` forward | cells drawn |
| `interpretLSystem` `+`/`-` | heading changes correctly |
| Hilbert smoke | 5 iterations, no panic, canvas non-empty |
