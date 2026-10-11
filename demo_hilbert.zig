const std = @import("std");
const canvas_lib = @import("src/lib/canvas.zig");
const turtle = @import("src/lib/turtle.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const hilbert = turtle.LSystem{
        .start = "A",
        .rules = &[_]turtle.Rule{
            .{ .from = 'A', .to = "+Bf-AfA-fB+" },
            .{ .from = 'B', .to = "-Af+BfB+fA-" },
        },
        .angle = 0.25,
        .implicit_f = false,
    };

    const depth = 4;
    const expanded = try hilbert.expand(depth, allocator);

    // Canvas sized for a typical 80×24 terminal.
    // char_aspect=0.5 compensates for monospace chars being ~2× taller than wide,
    // producing a visually square curve with separate x_step/y_step.
    var c = try canvas_lib.Canvas.init(allocator, 80, 24);
    const bounds = turtle.boundingBox(expanded, hilbert, 270.0, 1.0);
    const fit = turtle.fitToCanvas(bounds, c.width, c.height, 1, 0.5);

    var t = turtle.Turtle.init(fit.x, fit.y);
    t.x_step = fit.x_step;
    t.y_step = fit.y_step;
    t.pen = true;
    turtle.interpretLSystem(&t, &c, expanded, 1.0, hilbert, 270.0);

    // Replace ─/│ bends with arc corners ╭╮╯╰ for a smoother look.
    canvas_lib.smoothCorners(&c);

    c.no_color = true;
    const output = try c.render(allocator);
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}
