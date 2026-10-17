const std = @import("std");
const canvas_lib = @import("src/lib/canvas.zig");
const box = @import("src/lib/box.zig");

const Canvas = canvas_lib.Canvas;

/// Draw a filled rectangle border. vw = vertical line weight, hw = horizontal.
/// Corners are computed automatically from vw and hw.
fn drawBox(c: *Canvas, x0: usize, y0: usize, x1: usize, y1: usize, vw: u2, hw: u2) void {
    c.putMerge(x0, y0, box.encode(0, vw, 0, hw), 7);
    c.putMerge(x1, y0, box.encode(0, vw, hw, 0), 7);
    c.putMerge(x0, y1, box.encode(vw, 0, 0, hw), 7);
    c.putMerge(x1, y1, box.encode(vw, 0, hw, 0), 7);
    const hconn = box.encode(0, 0, hw, hw);
    for (x0 + 1..x1) |x| {
        c.putMerge(x, y0, hconn, 7);
        c.putMerge(x, y1, hconn, 7);
    }
    const vconn = box.encode(vw, vw, 0, 0);
    for (y0 + 1..y1) |y| {
        c.putMerge(x0, y, vconn, 7);
        c.putMerge(x1, y, vconn, 7);
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var c = try Canvas.init(allocator, 42, 16);

    // ─── Four line-weight styles ──────────────────────────────────────────────
    drawBox(&c, 0,  0, 7,  4, box.THIN,   box.THIN);   // ┌───┐  thin/thin
    drawBox(&c, 10, 0, 17, 4, box.HEAVY,  box.HEAVY);  // ┏━━━┓  heavy/heavy
    drawBox(&c, 20, 0, 27, 4, box.DOUBLE, box.DOUBLE); // ╔═══╗  double/double
    drawBox(&c, 30, 0, 37, 4, box.DOUBLE, box.THIN);   // ╓───╖  double-V thin-H

    // ─── Overlapping boxes: junctions auto-compute from putMerge ─────────────
    // inner thin box protrudes two rows above the outer heavy box.
    // where inner V walls cross outer top H the merge produces ┿ (thin V + heavy H).
    // where inner top edge meets double-box bottoms, coverage gaps keep the
    // existing double-corner rather than blanking it.
    drawBox(&c, 10,  3, 30,  7, box.THIN,  box.THIN);  // inner
    drawBox(&c, 4,  7, 36, 14, box.HEAVY, box.HEAVY); // outer

    c.no_color = true;
    const output = try c.render(allocator);
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}
