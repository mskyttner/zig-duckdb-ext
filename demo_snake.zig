/// demo_snake.zig — visual showcase for the boustrophedon treemap renderer.
///
/// Run with:   zig run demo_snake.zig
///
/// Shows four scenarios on progressively different value distributions to
/// demonstrate the coil outlines, arc step-corners, fill shading, and labels.
const std = @import("std");
const canvas_lib = @import("src/lib/canvas.zig");
const snake = @import("src/lib/snake.zig");

const Canvas = canvas_lib.Canvas;

fn render(
    alloc: std.mem.Allocator,
    values: []const f64,
    labels: []const []const u8,
    w: usize,
    h: usize,
    no_color: bool,
) ![]const u8 {
    var c = try Canvas.init(alloc, w, h);
    const coils = try snake.layout(values, w, h, alloc);
    try snake.renderCoils(&c, coils, labels, alloc);
    c.no_color = no_color;
    return c.render(alloc);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const out = std.Io.File.stdout();

    // Honour NO_COLOR env var and dumb terminals (init.environ_map is the
    // Zig 0.16 way to read environment variables without linking libc).
    const env = init.environ_map;
    const no_color = env.contains("NO_COLOR") or
        (env.get("TERM") != null and std.mem.eql(u8, env.get("TERM").?, "dumb"));

    // ── 1. Uniform distribution: 5 equal items ────────────────────────────────
    try out.writeStreamingAll(init.io, "\n── Equal weights (5 items, 60×10) ──\n\n");
    {
        const vals = [_]f64{ 1, 1, 1, 1, 1 };
        const lbls = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Epsilon" };
        const out_str = try render(alloc, &vals, &lbls, 60, 10, no_color);
        try out.writeStreamingAll(init.io, out_str);
    }

    // ── 2. Skewed: one dominant item, two medium, two small ───────────────────
    try out.writeStreamingAll(init.io, "\n── Skewed weights (60×12) ──\n\n");
    {
        const vals = [_]f64{ 50, 20, 15, 8, 7 };
        const lbls = [_][]const u8{ "Dominant", "Second", "Third", "sm", "xs" };
        const out_str = try render(alloc, &vals, &lbls, 60, 12, no_color);
        try out.writeStreamingAll(init.io, out_str);
    }

    // ── 3. Fibonacci-like: many small steps ───────────────────────────────────
    try out.writeStreamingAll(init.io, "\n── Fibonacci-ish (8 items, 60×16) ──\n\n");
    {
        const vals = [_]f64{ 34, 21, 13, 8, 5, 3, 2, 1 };
        const lbls = [_][]const u8{ "34", "21", "13", "8", "5", "3", "2", "1" };
        const out_str = try render(alloc, &vals, &lbls, 60, 16, no_color);
        try out.writeStreamingAll(init.io, out_str);
    }

    // ── 4. Wide canvas: two items sharing a partial row (arc corners visible) ─
    try out.writeStreamingAll(init.io, "\n── Two items, step corner showcase (40×8) ──\n\n");
    {
        const vals = [_]f64{ 3, 7 };
        const lbls = [_][]const u8{ "small", "large" };
        const out_str = try render(alloc, &vals, &lbls, 60, 12, no_color);
        try out.writeStreamingAll(init.io, out_str);
    }

    // ── 5. Three items with two step transitions ──────────────────────────────
    try out.writeStreamingAll(init.io, "\n── Three items, two steps (40×9) ──\n\n");
    {
        const vals = [_]f64{ 10, 17, 13 };
        const lbls = [_][]const u8{ "first", "second", "third" };
        const out_str = try render(alloc, &vals, &lbls, 60, 12, no_color);
        try out.writeStreamingAll(init.io, out_str);
    }

    // ── 6. Single-row canvas: all items render as fill + centered label ──────
    try out.writeStreamingAll(init.io, "\n── Single row items (40×1) ──\n\n");
    {
        const vals = [_]f64{ 11, 10, 5, 9, 3 };
        const lbls = [_][]const u8{ "first", "second", "third", "fourth", "xs" };
        const out_str = try render(alloc, &vals, &lbls, 40, 1, no_color);
        try out.writeStreamingAll(init.io, out_str);
        try out.writeStreamingAll(init.io, "\n");
    }

    try out.writeStreamingAll(init.io, "\n");
}
