/// demo_tree_lod.zig — before/after showcase for the tree LOD reduction module.
///
/// Run with:   zig run demo_tree_lod.zig
///
/// Prints synthetic tabular-tree scenarios before and after `collapseDepth`
/// and `collapseSmall`, so the folding behaviour can be eyeballed as plain
/// text — no canvas or DuckDB involved at this stage.
const std = @import("std");
const tree_lod = @import("src/lib/tree_lod.zig");

const Node = tree_lod.Node;
const NO_PARENT = tree_lod.NO_PARENT;

fn printNodes(out: std.Io.File, io: std.Io, nodes: []const Node) !void {
    var buf: [256]u8 = undefined;
    for (nodes, 0..) |n, i| {
        var indent_buf: [64]u8 = undefined;
        const indent = indent_buf[0 .. @as(usize, n.level) * 2];
        @memset(indent, ' ');
        const parent_str = if (n.parent == NO_PARENT) "-" else blk: {
            break :blk std.fmt.bufPrint(buf[128..], "{d}", .{n.parent}) catch "?";
        };
        const line = try std.fmt.bufPrint(&buf, "  [{d}] {s}{s:<12} level={d} parent={s: <3} value={d:.1}\n", .{ i, indent, n.label, n.level, parent_str, n.value });
        try out.writeStreamingAll(io, line);
    }
}

fn printLaidOut(out: std.Io.File, io: std.Io, nodes: []const tree_lod.LaidOutNode) !void {
    var buf: [256]u8 = undefined;
    for (nodes, 0..) |n, i| {
        var indent_buf: [64]u8 = undefined;
        const indent = indent_buf[0 .. @as(usize, n.level) * 2];
        @memset(indent, ' ');
        const parent_str = if (n.parent == NO_PARENT) "-" else blk: {
            break :blk std.fmt.bufPrint(buf[128..], "{d}", .{n.parent}) catch "?";
        };
        const line = try std.fmt.bufPrint(&buf, "  [{d}] {s}{s:<12} level={d} parent={s: <3} value={d:.1} area={d}\n", .{ i, indent, n.label, n.level, parent_str, n.value, n.area });
        try out.writeStreamingAll(io, line);
    }
}

fn section(out: std.Io.File, io: std.Io, title: []const u8) !void {
    try out.writeStreamingAll(io, "\n── ");
    try out.writeStreamingAll(io, title);
    try out.writeStreamingAll(io, " ──\n");
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const out = std.Io.File.stdout();
    const io = init.io;

    // ── 1. collapseDepth: a 4-level tree, budget = 1 (root + one group tier) ──
    try section(out, io, "collapseDepth: 4-level tree, max_depth=1 (root + group only)");
    {
        // root(0) -> group(1) -> sub(2) -> leaf1(3, v=9), leaf2(4, v=1)
        const nodes = [_]Node{
            .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
            .{ .parent = 0, .level = 1, .value = 0, .label = "group" },
            .{ .parent = 1, .level = 2, .value = 0, .label = "sub" },
            .{ .parent = 2, .level = 3, .value = 9, .label = "leaf1" },
            .{ .parent = 2, .level = 3, .value = 1, .label = "leaf2" },
        };
        try out.writeStreamingAll(io, "before:\n");
        try printNodes(out, io, &nodes);

        const out_nodes = try tree_lod.collapseDepth(&nodes, 1, alloc);
        try out.writeStreamingAll(io, "after (max_depth=1):\n");
        try printNodes(out, io, out_nodes);
    }

    // ── 2. collapseDepth: two sibling subtrees, each folds independently ─────
    try section(out, io, "collapseDepth: two subtrees under different parents");
    {
        // root -> groupA -> subA -> leafA1, leafA2 (2 levels too deep)
        //      -> groupB -> subB -> leafB1          (2 levels too deep)
        const nodes = [_]Node{
            .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
            .{ .parent = 0, .level = 1, .value = 0, .label = "groupA" },
            .{ .parent = 1, .level = 2, .value = 0, .label = "subA" },
            .{ .parent = 2, .level = 3, .value = 6, .label = "leafA1" },
            .{ .parent = 2, .level = 3, .value = 3, .label = "leafA2" },
            .{ .parent = 0, .level = 1, .value = 0, .label = "groupB" },
            .{ .parent = 5, .level = 2, .value = 0, .label = "subB" },
            .{ .parent = 6, .level = 3, .value = 7, .label = "leafB1" },
        };
        try out.writeStreamingAll(io, "before:\n");
        try printNodes(out, io, &nodes);

        const out_nodes = try tree_lod.collapseDepth(&nodes, 1, alloc);
        try out.writeStreamingAll(io, "after (max_depth=1):\n");
        try printNodes(out, io, out_nodes);
    }

    // ── 3. collapseSmall: a long tail bundled into "…other" ──────────────────
    try section(out, io, "collapseSmall: long-tail siblings, area=100, min_cells=5");
    {
        const nodes = [_]Node{
            .{ .parent = NO_PARENT, .level = 0, .value = 60, .label = "Large" },
            .{ .parent = NO_PARENT, .level = 0, .value = 25, .label = "Medium" },
            .{ .parent = NO_PARENT, .level = 0, .value = 8, .label = "Small1" },
            .{ .parent = NO_PARENT, .level = 0, .value = 4, .label = "Small2" },
            .{ .parent = NO_PARENT, .level = 0, .value = 2, .label = "Tiny1" },
            .{ .parent = NO_PARENT, .level = 0, .value = 1, .label = "Tiny2" },
        };
        try out.writeStreamingAll(io, "before:\n");
        try printNodes(out, io, &nodes);

        const out_nodes = try tree_lod.collapseSmall(&nodes, 100, 5, "…other", alloc);
        try out.writeStreamingAll(io, "after (area=100, min_cells=5):\n");
        try printNodes(out, io, out_nodes);
    }

    // ── 4. collapseSmall: a negative sibling folds instead of crashing ───────
    try section(out, io, "collapseSmall: mixed-sign siblings");
    {
        const nodes = [_]Node{
            .{ .parent = NO_PARENT, .level = 0, .value = 10, .label = "Gain" },
            .{ .parent = NO_PARENT, .level = 0, .value = -2, .label = "Loss" },
        };
        try out.writeStreamingAll(io, "before:\n");
        try printNodes(out, io, &nodes);

        const out_nodes = try tree_lod.collapseSmall(&nodes, 100, 5, "…other", alloc);
        try out.writeStreamingAll(io, "after (area=100, min_cells=5):\n");
        try printNodes(out, io, out_nodes);
    }

    // ── 5. layoutTree on real data: README.md's markdown block tree ─────────
    // 175 nodes (174 real + 1 synthetic root), 4 levels, laid out top-down in
    // one recursive pass. Compare with the flat collapseSmall(nodes, area=80)
    // call from before: that call assigned every bucket the *same* area=80
    // regardless of depth, and left folded ancestors' surviving descendants
    // pointing at dangling original indices. layoutTree derives each bucket's
    // area from its actual parent's area, and every `.parent` below is a
    // valid index into this same output — no dangling references.
    try section(out, io, "layoutTree on README.md's real markdown-block tree (175 nodes)");
    {
        const readme = @import("demo_readme_tree_fixture.zig");
        try out.writeStreamingAll(io, std.fmt.comptimePrint("before: {d} nodes\n", .{readme.nodes.len}));

        const totals = try alloc.alloc(f64, readme.nodes.len);
        tree_lod.subtreeTotals(&readme.nodes, totals);

        const out_nodes = try tree_lod.layoutTree(&readme.nodes, totals, 0, 80, 3, 3, "…other", alloc);
        const msg = try std.fmt.allocPrint(alloc, "after (root area=80, max_depth=3, min_cells=3): {d} nodes\n", .{out_nodes.len});
        try out.writeStreamingAll(io, msg);
        try printLaidOut(out, io, out_nodes);

        // ── 6. placeRects: bounded viewport (rows × columns), not a scrollable
        // document. Unlike tp_snakemap's own canvas — fixed width, height grows
        // unboundedly to fit everything, like text reflow — a live TUI "zoom to
        // node" view has a fixed terminal frame on BOTH axes: nothing to scroll
        // to, so root_rect.w and root_rect.h are both bounded from the start.
        // That's exactly why layoutTree's folding (collapseDepth/collapseSmall)
        // is mandatory here but only optional for tp_snakemap: a document can
        // dodge the "too much to show" problem by growing taller; a fixed
        // viewport cannot, so bundling into "…other" is the only way to fit.
        try section(out, io, "placeRects: same tree into a bounded 80x24 viewport");
        const rects = try tree_lod.placeRects(out_nodes, .{ .x = 0, .y = 0, .w = 80, .h = 24 }, alloc);
        for (out_nodes, rects, 0..) |n, r, i| {
            const line = try std.fmt.allocPrint(alloc, "  [{d}] {s:<12} rect=({d},{d} {d}x{d})\n", .{ i, n.label, r.x, r.y, r.w, r.h });
            try out.writeStreamingAll(io, line);
        }
    }

    try out.writeStreamingAll(io, "\n");
}
