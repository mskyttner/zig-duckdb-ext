/// Level-of-detail (LOD) reduction for tabular tree data, prior to layout.
///
/// Input is a flat, tabular tree projection in parent-pointer form — akin to
/// duckent's `_parent`/`_level` projection columns
/// (https://github.com/teaguesterling/duckent). This module never infers
/// hierarchy; it only reduces an already-shaped tree so that layout (snake.zig)
/// only ever sees nodes that can actually be drawn.
///
/// Two independent collapse operations, both reducing to the same primitive —
/// folding an entire subtree into one synthetic aggregate leaf:
///
///   - `collapseDepth`: static, canvas-independent. Box-drawing containment
///     encodes nesting depth as a border weight (box.zig: THIN/HEAVY/DOUBLE —
///     a u2 field, so at most 3 distinguishable levels exist and never will
///     grow). Any subtree past that depth budget can never get its own
///     container box, so it is folded into one leaf attached to the deepest
///     ancestor that still had a weight to spare.
///
///   - `collapseSmall`: dynamic, canvas-dependent. Given the canvas area a
///     group of siblings must share, a sibling whose proportional share
///     rounds below one visible glyph can't be drawn as its own tile. All
///     such siblings are folded together into one "…other" residual leaf.
///
/// `collapseSmall` above has two sharp edges once you go beyond a single
/// flat sibling bucket: it takes one `area` for the whole call, applied
/// uniformly no matter how deep a bucket sits (wrong — a nested bucket
/// should get a fraction of its ancestor's area, not the whole canvas), and
/// it never renumbers `.parent` in its output, so a surviving node whose
/// *ancestor* got folded ends up pointing at an index that no longer means
/// anything in the output slice. `layoutTree` is the fix: one recursive,
/// top-down walk that derives each node's area from its parent's area and
/// its own share of the local sibling bucket, combines the depth budget and
/// the area threshold into a single pass, and always emits a self-consistent
/// output tree (every `.parent` is a valid index into that same output
/// slice). Because each node's area is computed purely from its own local
/// sibling bucket — never normalized against the true root — "zoom to node
/// X" is just calling `layoutTree` again with a different `root`.
///
/// All of these are pure data transforms — no canvas, no box-drawing, no
/// layout math.
const std = @import("std");
const testing = std.testing;

/// Sentinel: node has no parent (a root of the forest).
pub const NO_PARENT: usize = std.math.maxInt(usize);

/// `placeRects`/`placeRectsWrapped`'s `border_depth`, meaning "every level
/// draws its own border" (the classic nested-containment look: a
/// `interiorRect` inset at every depth, matching this module's original,
/// only behavior). See `border_depth`'s own doc comment at each call site
/// for the alternative.
pub const ALWAYS_BORDERED: u16 = std.math.maxInt(u16);

/// One row of the tabular tree projection.
///
/// Required ordering: `parent[i] < i` for every non-root `i` (parent always
/// appears earlier in the slice than its children — true of any pre-order
/// tree projection, e.g. duckent's `_pre`/`_parent`).
pub const Node = struct {
    parent: usize,
    level: u16,
    /// Own scalar weight. Zero for a pure container whose weight is entirely
    /// derived from its descendants.
    value: f64,
    label: []const u8,
};

/// Computes each node's subtree total (own value + all descendants' values).
/// `nodes.len == out.len`; caller owns `out`.
///
/// Relies only on `parent[i] < i`, not full pre-order: processing indices in
/// reverse guarantees every child has already folded its total into its
/// parent's slot by the time the parent itself is finalized.
pub fn subtreeTotals(nodes: []const Node, out: []f64) void {
    for (0..out.len) |i| out[i] = nodes[i].value;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        const p = nodes[i].parent;
        if (p != NO_PARENT) out[p] += out[i];
    }
}

/// Folds an entire subtree rooted at `root` into one synthetic leaf.
/// `nodes[root].level` and `.parent` are kept; value/label are replaced.
fn foldSubtree(root: Node, total: f64, other_label: []const u8) Node {
    return .{
        .parent = root.parent,
        .level = root.level,
        .value = total,
        .label = other_label,
    };
}

/// Folds every subtree whose root sits one level past `max_depth` into a
/// single leaf reattached to its `max_depth` ancestor. Nodes at or above
/// `max_depth` pass through unchanged; nodes strictly inside a folded
/// subtree are dropped (their value already lives in the fold's total).
///
/// `max_depth` is a property of the *renderer's* weight budget (box.zig has
/// 3 distinguishable weights: root=DOUBLE, group=HEAVY, leaf=THIN — so a
/// caller drawing one root + N group panels + leaves passes `max_depth = 1`,
/// meaning only level-0 and level-1 nodes may still be containers).
///
/// Caller owns the returned slice.
pub fn collapseDepth(
    nodes: []const Node,
    max_depth: u16,
    allocator: std.mem.Allocator,
) ![]Node {
    const totals = try allocator.alloc(f64, nodes.len);
    defer allocator.free(totals);
    subtreeTotals(nodes, totals);

    var out: std.ArrayList(Node) = .empty;
    errdefer out.deinit(allocator);

    for (nodes, 0..) |n, i| {
        if (n.level <= max_depth) {
            try out.append(allocator, n);
        } else if (n.level == max_depth + 1) {
            // First node past the budget: fold its whole subtree here.
            try out.append(allocator, foldSubtree(n, totals[i], n.label));
        }
        // Deeper nodes (level > max_depth + 1) are interior to a fold
        // already emitted above — skip without visiting their children,
        // satisfying goal (b): no layout work for undrawable nodes.
    }

    return out.toOwnedSlice(allocator);
}

/// Cells a value would occupy out of `area`, given the bucket it shares
/// `bucket_total` with. A non-positive value, or a non-positive bucket total
/// (e.g. all-negative or cancelling-to-zero siblings), yields 0 — negative
/// cell counts are meaningless and would panic on the float→usize cast.
fn shareCells(value: f64, bucket_total: f64, area: usize) usize {
    if (bucket_total <= 0 or value <= 0) return 0;
    const raw = @round(value / bucket_total * @as(f64, @floatFromInt(area)));
    return @intFromFloat(raw);
}

/// Folds siblings (nodes sharing the same `parent`) whose proportional share
/// of `area` cells would round below `min_cells` — the smallest footprint
/// the renderer can still draw as an individual tile (e.g. border + one
/// label glyph). All folded siblings become one "…other" leaf per parent,
/// inserted at the position of the first folded sibling (preserving
/// traversal-order locality for the survivors on either side, so a
/// boustrophedon layout downstream doesn't get one giant gap).
///
/// `nodes` need not be depth-collapsed first, but typically will be —
/// `collapseSmall` only looks at `.parent`/`.value`, not `.level`.
///
/// Caller owns the returned slice.
pub fn collapseSmall(
    nodes: []const Node,
    area: usize,
    min_cells: usize,
    other_label: []const u8,
    allocator: std.mem.Allocator,
) ![]Node {
    // Grand total per parent bucket (root pseudo-key = NO_PARENT).
    var parent_totals = std.AutoHashMap(usize, f64).init(allocator);
    defer parent_totals.deinit();
    for (nodes) |n| {
        const gop = try parent_totals.getOrPutValue(n.parent, 0);
        gop.value_ptr.* += n.value;
    }

    var out: std.ArrayList(Node) = .empty;
    errdefer out.deinit(allocator);

    var folded_for_parent = std.AutoHashMap(usize, void).init(allocator);
    defer folded_for_parent.deinit();

    for (nodes) |n| {
        const bucket_total = parent_totals.get(n.parent).?;
        const share_cells = shareCells(n.value, bucket_total, area);

        if (share_cells >= min_cells) {
            try out.append(allocator, n);
            continue;
        }

        if (folded_for_parent.contains(n.parent)) continue; // already emitted this parent's "other"

        // Sum every remaining too-small sibling under the same parent.
        var other_total: f64 = 0;
        for (nodes) |m| {
            if (m.parent != n.parent) continue;
            const m_share = shareCells(m.value, bucket_total, area);
            if (m_share < min_cells) other_total += m.value;
        }

        try out.append(allocator, foldSubtree(n, other_total, other_label));
        try folded_for_parent.put(n.parent, {});
    }

    return out.toOwnedSlice(allocator);
}

/// A node as placed by `layoutTree`: same shape as `Node`, plus the cell
/// area actually allotted to it at the requested canvas size.
///
/// `.parent` is an index into the *same output slice* — unlike `Node`,
/// where `.parent` indexes the caller's original tabular input. This is
/// what makes the output self-consistent: it can be walked, re-laid-out, or
/// rendered without ever referring back to the input `nodes` slice.
pub const LaidOutNode = struct {
    parent: usize,
    level: u16,
    value: f64,
    label: []const u8,
    area: usize,
    /// Index of the originating row in `layoutTree`'s input `nodes` slice —
    /// `NO_PARENT` for a `"…other"` aggregate, which merges several original
    /// nodes and so has no single origin. A caller that wants to zoom in on
    /// a node the user picked on screen re-roots at this index; it must not
    /// be treated as an index into this output slice (that's what `.parent`
    /// is for).
    orig_index: usize = NO_PARENT,
};

/// CSR-style (compressed sparse row) children-adjacency index: `start[i]..
/// start[i+1]` in `list` gives node `i`'s direct children, in their
/// original relative order. Lets `layoutChildren`/`foldedChildren` look up
/// "which rows have parent == i" in O(children) instead of scanning the
/// whole `nodes` slice per call — the difference between a few dozen
/// comparisons and hundreds of thousands at real-filesystem tree sizes,
/// since the naive scan used to run once per node visited during the
/// recursive layout walk.
///
/// `pub` (and `buildChildIndex` below) so a caller doing many `layoutTree`/
/// `foldedChildren` calls against the *same* `nodes` across frames (e.g. an
/// interactive UI re-laying-out on every redraw) can build this once and
/// pass it to `layoutTreeWithIndex`/`foldedChildrenWithIndex` instead of
/// paying its build cost — itself O(nodes.len) — again on every call.
/// `layoutTree`/`foldedChildren` remain as before for a caller that doesn't
/// need to amortize that cost across repeated calls.
pub const ChildIndex = struct {
    start: []usize, // len == nodes.len + 1
    list: []usize, // len == nodes.len (a node with NO_PARENT contributes no entry, so this can be a slight over-allocation; never read past start[nodes.len])

    fn childrenOf(self: ChildIndex, idx: usize) []const usize {
        return self.list[self.start[idx]..self.start[idx + 1]];
    }

    pub fn deinit(self: ChildIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.start);
        allocator.free(self.list);
    }
};

/// Counting-sort build: one pass to count each parent's children, a prefix
/// sum to turn counts into offsets, then one pass to place each node into
/// its parent's bucket. `parent[i] < i` isn't required for correctness here
/// (unlike `subtreeTotals`), just for the *output* to preserve each
/// parent's children in their original relative order.
pub fn buildChildIndex(nodes: []const Node, allocator: std.mem.Allocator) !ChildIndex {
    const start = try allocator.alloc(usize, nodes.len + 1);
    errdefer allocator.free(start);
    @memset(start, 0);
    for (nodes) |n| {
        if (n.parent != NO_PARENT) start[n.parent + 1] += 1;
    }
    for (1..start.len) |i| start[i] += start[i - 1];

    const list = try allocator.alloc(usize, nodes.len);
    errdefer allocator.free(list);
    const cursor = try allocator.dupe(usize, start[0..nodes.len]);
    defer allocator.free(cursor);
    for (nodes, 0..) |n, i| {
        if (n.parent != NO_PARENT) {
            list[cursor[n.parent]] = i;
            cursor[n.parent] += 1;
        }
    }
    return .{ .start = start, .list = list };
}

/// Lays out the subtree rooted at `root` into `area` cells, combining the
/// depth budget and the area-visibility threshold into one top-down walk.
///
/// `totals` must be `subtreeTotals(nodes, ...)` computed over the *whole*
/// input tree beforehand (not just the subtree) — the caller supplies it so
/// repeated calls (e.g. zooming to different nodes) don't recompute it.
///
/// `root`'s own area is always exactly `area` — it never competes for space
/// with siblings, since as far as this call is concerned, it has none. This
/// is what makes "zoom to node X" free: call `layoutTree` again with
/// `root = X` and whatever new `area` the zoomed view gets; nothing about
/// `X`'s or its descendants' shares depends on what is above `X` in the
/// full tree.
///
/// `max_depth` means the same thing as in `collapseDepth`: the deepest
/// level (relative to `root`, which is level 0) still allowed to act as a
/// container. `min_cells` and `other_label` mean the same as in
/// `collapseSmall`.
///
/// Caller owns the returned slice.
pub fn layoutTree(
    nodes: []const Node,
    totals: []const f64,
    root: usize,
    area: usize,
    max_depth: u16,
    min_cells: usize,
    other_label: []const u8,
    allocator: std.mem.Allocator,
) ![]LaidOutNode {
    const index = try buildChildIndex(nodes, allocator);
    defer index.deinit(allocator);
    return layoutTreeWithIndex(nodes, totals, index, root, area, max_depth, min_cells, other_label, allocator);
}

/// Same as `layoutTree`, but takes an already-built `ChildIndex` (see its
/// own doc comment) instead of building one internally — for a caller
/// re-laying-out the same `nodes` repeatedly (e.g. once per frame) that can
/// build the index once and reuse it, rather than paying its O(nodes.len)
/// build cost again on every call.
pub fn layoutTreeWithIndex(
    nodes: []const Node,
    totals: []const f64,
    index: ChildIndex,
    root: usize,
    area: usize,
    max_depth: u16,
    min_cells: usize,
    other_label: []const u8,
    allocator: std.mem.Allocator,
) ![]LaidOutNode {
    var out: std.ArrayList(LaidOutNode) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, .{
        .parent = NO_PARENT,
        .level = 0,
        .value = totals[root],
        .label = nodes[root].label,
        .area = area,
        .orig_index = root,
    });

    try layoutChildren(nodes, totals, index, root, 0, 0, area, max_depth, min_cells, other_label, &out, allocator);

    return out.toOwnedSlice(allocator);
}

/// Appends `node_idx`'s direct children (and, budget permitting, recurses
/// into theirs) under `out_pos` — `node_idx`'s own already-appended position
/// in `out`, at `level` and holding `area` cells. `index` is `nodes`'
/// precomputed children-adjacency (see `ChildIndex`), built once by the
/// `layoutTree` caller and threaded through the recursion rather than
/// rebuilt per call.
fn layoutChildren(
    nodes: []const Node,
    totals: []const f64,
    index: ChildIndex,
    node_idx: usize,
    level: u16,
    out_pos: usize,
    area: usize,
    max_depth: u16,
    min_cells: usize,
    other_label: []const u8,
    out: *std.ArrayList(LaidOutNode),
    allocator: std.mem.Allocator,
) !void {
    const children = index.childrenOf(node_idx);

    var bucket_total: f64 = 0;
    for (children) |i| bucket_total += totals[i];

    var other_total: f64 = 0;
    var other_seen = false;

    for (children) |i| {
        const n = nodes[i];
        const share = shareCells(totals[i], bucket_total, area);
        if (share < min_cells) {
            other_total += totals[i];
            other_seen = true;
            continue;
        }

        const child_pos = out.items.len;
        try out.append(allocator, .{
            .parent = out_pos,
            .level = level + 1,
            .value = totals[i],
            .label = n.label,
            .area = share,
            .orig_index = i,
        });

        // Recurse only while the child itself still has a container-weight
        // budget left; a child sitting past `max_depth` was already emitted
        // above as a single leaf carrying its whole subtree's total, so its
        // own descendants need no further visiting (no wasted layout work).
        if (level + 1 <= max_depth) {
            try layoutChildren(nodes, totals, index, i, level + 1, child_pos, share, max_depth, min_cells, other_label, out, allocator);
        }
    }

    if (other_seen) {
        try out.append(allocator, .{
            .parent = out_pos,
            .level = level + 1,
            .value = other_total,
            .label = other_label,
            .area = shareCells(other_total, bucket_total, area),
        });
    }
}

/// Recovers which of `node_idx`'s direct children `layoutTree` would fold
/// into one `"…"` leaf at this `area`/`min_cells` — the exact set a caller
/// needs to let a user "drill into" that leaf, since the leaf itself only
/// carries an aggregate value and `NO_PARENT` as its `.orig_index` (there is
/// no single node to re-root at). Mirrors `layoutChildren`'s own fold
/// decision exactly, so it only ever returns what that call would actually
/// fold, never more or less.
///
/// Caller owns the returned slice.
pub fn foldedChildren(
    nodes: []const Node,
    totals: []const f64,
    node_idx: usize,
    area: usize,
    min_cells: usize,
    allocator: std.mem.Allocator,
) ![]usize {
    const index = try buildChildIndex(nodes, allocator);
    defer index.deinit(allocator);
    return foldedChildrenWithIndex(totals, index, node_idx, area, min_cells, allocator);
}

/// Same as `foldedChildren`, but takes an already-built `ChildIndex` — see
/// `layoutTreeWithIndex`'s doc comment for why a repeat-calling caller would
/// want this instead.
pub fn foldedChildrenWithIndex(
    totals: []const f64,
    index: ChildIndex,
    node_idx: usize,
    area: usize,
    min_cells: usize,
    allocator: std.mem.Allocator,
) ![]usize {
    const children = index.childrenOf(node_idx);

    var bucket_total: f64 = 0;
    for (children) |i| bucket_total += totals[i];

    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    for (children) |i| {
        if (shareCells(totals[i], bucket_total, area) < min_cells) {
            try out.append(allocator, i);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// An on-screen rectangle, in cells.
pub const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

/// Places each node of a `layoutTree` result into an actual rectangle,
/// recursively subdividing `root_rect` by each node's `.area` share of its
/// siblings' combined area.
///
/// `layoutTree` only ever decides *how many cells* a node deserves (a
/// scalar budget, relative to its siblings) — it has no notion of where
/// those cells sit on screen, since that depends on the parent's actual
/// shape, which `layoutTree` never sees. `placeRects` is that missing
/// bridge: it turns the budget tree into a rectangle tree. `rects[i]`
/// corresponds to `laid_out[i]`; caller owns `rects`.
///
/// `laid_out` must carry `layoutTree`'s own invariants: emitted parent-
/// before-child (`laid_out[i].parent < i` for every non-root `i`), and
/// `.parent` indexing this same slice.
///
/// Splitting alternates axis with depth (classic slice-and-dice: the root's
/// children split horizontally, its grandchildren vertically, and so on) so
/// a chain of single-child containers doesn't collapse into a sliver.
/// This is deliberately the simplest possible bridge — `snake.zig`'s
/// boustrophedon multi-row arrangement is a richer alternative for one flat
/// level's own children, not yet extended to recurse into nested
/// rectangles the way this does.
///
/// `border_depth`: a node at `.level <= border_depth` gets its children
/// placed inside `interiorRect(rects[i])` (leaving room for its own
/// drawn border); deeper than that, children are placed in the node's
/// *full* rect instead, flush against its edges — for a renderer that
/// (like `treemap`'s "classical" style) only actually draws a
/// border down to `border_depth` and wants leaves placed edge-to-edge
/// below it, not carved smaller for a border that will never be drawn.
/// Pass `ALWAYS_BORDERED` for the original, every-level-insets behavior.
pub fn placeRects(
    laid_out: []const LaidOutNode,
    root_rect: Rect,
    border_depth: u16,
    allocator: std.mem.Allocator,
) ![]Rect {
    const rects = try allocator.alloc(Rect, laid_out.len);
    errdefer allocator.free(rects);
    if (laid_out.len == 0) return rects;

    rects[0] = root_rect;

    // Group children by parent, preserving emission order. Siblings are not
    // necessarily contiguous in `laid_out` — layoutTree emits a child's
    // entire subtree before moving on to its next sibling — so we can't
    // just scan runs; we need each parent's full child list up front.
    var children_of = std.AutoHashMap(usize, std.ArrayList(usize)).init(allocator);
    defer {
        var it = children_of.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        children_of.deinit();
    }
    for (laid_out, 0..) |n, i| {
        if (n.parent == NO_PARENT) continue;
        const gop = try children_of.getOrPut(n.parent);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, i);
    }

    // A parent's rect is always ready before its children are placed:
    // layoutTree guarantees parent_idx < i for every node i.
    for (0..laid_out.len) |i| {
        const children = children_of.get(i) orelse continue;
        const parent_rect = if (laid_out[i].level <= border_depth) interiorRect(rects[i]) else rects[i];
        placeSiblings(rects, laid_out, children.items, parent_rect, laid_out[i].level, false);
    }

    return rects;
}

/// The space inside a node's own drawn border. Every renderer this module
/// targets (box.zig's THIN/HEAVY/DOUBLE weights, and any renderer built on
/// them) draws a 1-cell-thick border regardless of weight — only the glyph
/// changes, never the thickness — so a node's children must be placed
/// strictly inside that border, not across the outer ring where it will be
/// drawn. Without this, a child whose rect reaches the parent's edge
/// collides with the parent's own border row/column when both get drawn.
/// Saturating subtraction: a rect too small for any interior collapses to a
/// 0-area rect rather than underflowing.
fn interiorRect(r: Rect) Rect {
    return .{
        .x = r.x + 1,
        .y = r.y + 1,
        .w = r.w -| 2,
        .h = r.h -| 2,
    };
}

/// `reverse`: visually place `children` back-to-front (last child leftmost
/// in a horizontal split, first child rightmost) while every other aspect
/// — proportional sizing, the adjacent-border overlap adjustment, which
/// `ci` gets which rect — stays the same. Only `placeSiblingsWrapped`'s
/// per-row call ever passes `true` (alternating rows for a "snake"/
/// boustrophedon layout — see its own doc comment for why); every other
/// caller passes `false`, the previous unconditional left-to-right/
/// top-to-bottom behavior.
fn placeSiblings(
    rects: []Rect,
    laid_out: []const LaidOutNode,
    children: []const usize,
    parent_rect: Rect,
    parent_level: u16,
    reverse: bool,
) void {
    var bucket_area: usize = 0;
    for (children) |ci| bucket_area += laid_out[ci].area;
    // A zero bucket total (or a zero-area parent_rect, from a degenerate
    // caller) has no meaningful proportional split — but every child in
    // `children` still needs *some* rect written. `rects` is
    // caller-allocated and uninitialized, so skipping a child here would
    // leave it as garbage memory, read back later. Substituting 1 avoids
    // a division by zero and falls through to the same loop below, which
    // then assigns a (typically zero-sized, since parent_rect itself is
    // usually degenerate too in this case) rect to every child.
    const safe_bucket_area = if (bucket_area == 0) 1 else bucket_area;

    const horizontal = parent_level % 2 == 0; // alternate axis with depth
    const total_len: usize = if (horizontal) parent_rect.w else parent_rect.h;

    var offset: usize = 0;
    var walk: usize = 0;
    while (walk < children.len) : (walk += 1) {
        // `idx` is "position along the drawn axis, left/top to right/
        // bottom" — the only thing `reverse` changes is which element of
        // `children` occupies that position, by walking the array
        // back-to-front instead of front-to-back. Every computation below
        // (`is_last`, the overlap adjustment) still just means "first/last
        // position drawn", unaffected by which child that happens to be.
        const idx = if (reverse) children.len - 1 - walk else walk;
        const ci = children[idx];
        const is_last = walk == children.len - 1;
        const remaining = total_len -| offset;
        const len = if (is_last)
            remaining // last child absorbs rounding
        else
            @min(remaining, @as(usize, @intFromFloat(@round(
                @as(f64, @floatFromInt(laid_out[ci].area)) / @as(f64, @floatFromInt(safe_bucket_area)) * @as(f64, @floatFromInt(total_len)),
            ))));

        // Every child but the first is drawn 1 cell into its predecessor's
        // territory, and 1 cell wider to compensate — its own *far* edge
        // still lands exactly on `offset`'s natural (non-overlapping)
        // boundary, only its *near* edge moves. This is what lets a
        // renderer merge two adjacent boxes' borders into one shared
        // wall/junction glyph: both sides need to agree the shared
        // column/row belongs to both of them, which only works if the
        // *layout* says so — a render-time-only adjustment would move a
        // box's border without moving its own children, who were already
        // placed relative to the unadjusted rect. `offset` itself keeps
        // accumulating the natural (non-overlapping) `len`, so this
        // doesn't compound across siblings.
        const draw_offset = if (walk == 0) offset else offset -| 1;
        const draw_len = if (walk == 0) len else len + 1;

        rects[ci] = if (horizontal)
            .{ .x = parent_rect.x + draw_offset, .y = parent_rect.y, .w = draw_len, .h = parent_rect.h }
        else
            .{ .x = parent_rect.x, .y = parent_rect.y + draw_offset, .w = parent_rect.w, .h = draw_len };

        offset += len;
    }
}

/// Alternative to `placeRects`: wraps a large sibling set into several rows
/// instead of `placeSiblings`' single-axis split, order-preserving.
///
/// `placeSiblings` only ever divides one axis per level (children of an
/// even-depth node split its full width; children of an odd-depth node
/// split its full height), which produces increasingly thin slivers as a
/// sibling count grows — exactly the "long thin tile" problem a snake/
/// boustrophedon layout exists to avoid. This gets that same benefit
/// without `snake.zig`'s actual coil geometry: a coil's footprint isn't a
/// rectangle (an item spanning multiple rows gets a stepped/L-shaped
/// region), so it has no well-defined sub-rectangle to recursively place a
/// coil's own children into — which an interactive drill-down explorer
/// needs for every visible node. Every child here still gets a genuine
/// axis-aligned rectangle, just arranged in a row-wrapped grid instead of
/// one strip.
///
/// Row count is chosen to *maximize average item width*, not to produce
/// "square" tiles the way classic squarified treemaps do: since labels
/// read horizontally, a wide-short rectangle shows more of a label than a
/// narrow-tall one of the same area. Because `rect.w / ceil(n / rows)`
/// only ever grows as `rows` grows, the best choice is always as many rows
/// as fit — down to `min_row_height` per row, and never more than one row
/// per child.
/// `border_depth`: see `placeRects`'s own doc comment — identical meaning
/// here. Pass `ALWAYS_BORDERED` for the original, every-level-insets
/// behavior.
pub fn placeRectsWrapped(
    laid_out: []const LaidOutNode,
    root_rect: Rect,
    min_row_height: usize,
    border_depth: u16,
    allocator: std.mem.Allocator,
) ![]Rect {
    const rects = try allocator.alloc(Rect, laid_out.len);
    errdefer allocator.free(rects);
    if (laid_out.len == 0) return rects;

    rects[0] = root_rect;

    var children_of = std.AutoHashMap(usize, std.ArrayList(usize)).init(allocator);
    defer {
        var it = children_of.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        children_of.deinit();
    }
    for (laid_out, 0..) |n, i| {
        if (n.parent == NO_PARENT) continue;
        const gop = try children_of.getOrPut(n.parent);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, i);
    }

    for (0..laid_out.len) |i| {
        const children = children_of.get(i) orelse continue;
        const parent_rect = if (laid_out[i].level <= border_depth) interiorRect(rects[i]) else rects[i];
        placeSiblingsWrapped(rects, laid_out, children.items, parent_rect, min_row_height);
    }

    return rects;
}

/// Rows alternate reading direction — left-to-right, then right-to-left,
/// then left-to-right again (a "snake"/boustrophedon layout) — rather than
/// every row reading the same way. This is purely cosmetic when nothing
/// changes between layouts, but it matters once the underlying data does
/// (e.g. a live-reloading data source — see treemap's own
/// auto-refresh): when a sibling near a row boundary gains or loses just
/// enough share to cross it, same-direction wrapping (like left-justified
/// text reflowing at a new page width) moves that sibling from the far
/// right of one row to the far left of the next — a large, disorienting
/// jump for a small underlying change. With alternating direction, a row's
/// trailing edge and the next row's leading edge are the *same* screen
/// edge, so that same crossing only ever moves the sibling a short
/// distance, not across the whole width. Sibling *order* itself is
/// unaffected either way — only which screen position each occupies.
fn placeSiblingsWrapped(
    rects: []Rect,
    laid_out: []const LaidOutNode,
    children: []const usize,
    parent_rect: Rect,
    min_row_height: usize,
) void {
    if (children.len == 0) return;

    var total_area: usize = 0;
    for (children) |ci| total_area += laid_out[ci].area;

    // Degenerate cases — a zero-area bucket, or a parent rect too small to
    // subdivide into more than one row — still need every child to get
    // SOME rect, even a zero-sized one. Never skip assignment entirely:
    // `rects` is caller-allocated and uninitialized, so any child left
    // unassigned here reads back as garbage later. `placeSiblings` already
    // handles all of this safely (a zero-width/height rect or a zero
    // bucket total just yields zero-sized rects for everyone, never a
    // skip), so degenerate cases fall back to it directly.
    const max_rows_by_height = parent_rect.h / @max(min_row_height, 1);
    const target_rows = @max(1, @min(max_rows_by_height, children.len));
    if (total_area == 0 or target_rows <= 1) {
        placeSiblings(rects, laid_out, children, parent_rect, 0, false);
        return;
    }

    const target_per_row = @as(f64, @floatFromInt(total_area)) / @as(f64, @floatFromInt(target_rows));

    // The greedy row-grouping below depends only on each child's `.area`
    // share and `target_rows` — never on where rows actually get drawn —
    // so a placement-free pass can count how many rows it actually
    // produces before committing to a row height. That count can be
    // *fewer* than `target_rows`: item weights are often lumpy (a run of
    // similarly small items can all land in one row before their combined
    // weight even reaches one row's target share), so the greedy
    // assignment can finish (every child placed) well before reaching the
    // row cap. Sizing rows off `target_rows` regardless would leave the
    // rows that never got used as a dead gap at the bottom of the parent's
    // interior, instead of letting the rows that DO exist claim that
    // height — exactly the "screen real estate not fully used" bug this
    // fixes.
    const actual_rows = blk: {
        var rows: usize = 1;
        var row_accum: f64 = 0;
        for (children, 0..) |ci, i| {
            row_accum += @as(f64, @floatFromInt(laid_out[ci].area));
            const is_last_item = i == children.len - 1;
            const is_last_row = rows == target_rows;
            if ((row_accum >= target_per_row and !is_last_row) or is_last_item) {
                if (!is_last_item) rows += 1;
                row_accum = 0;
            }
        }
        break :blk rows;
    };

    var row_start: usize = 0;
    var row_accum: f64 = 0;
    var row_idx: usize = 0;
    var row_y: usize = parent_rect.y;

    for (children, 0..) |ci, i| {
        row_accum += @as(f64, @floatFromInt(laid_out[ci].area));
        const is_last_item = i == children.len - 1;
        const is_last_row = row_idx == actual_rows - 1;
        // Close the row once it's carrying its fair share of the total
        // weight (or this is the tree's very last item) — rows fill up in
        // sibling order, so this stays order-preserving.
        if ((row_accum >= target_per_row and !is_last_row) or is_last_item) {
            // Each row's height reflects its own share of `total_area` —
            // `row_accum` here is exactly that row's own accumulated
            // area, since it's been summing since `row_start` — not an
            // equal split across however many rows there are. Two
            // children with wildly different totals can still each land
            // in their own row (see this function's own "lumpy weights"
            // comment above); without this, a row holding a tiny
            // fraction of the total value claimed the same screen space
            // as a row holding nearly all of it (an almost-2000x-lopsided
            // real case — a `9.4M`-total group's row and a `5K`-total
            // group's row rendering at the same height — is what exposed
            // this). `min_row_height` floors it the way the old flat
            // `parent_rect.h / actual_rows` guaranteed implicitly via
            // `max_rows_by_height` above — needed explicitly now, since a
            // per-row proportional share can undercut that in a way a
            // flat division never could.
            const h = if (is_last_row)
                (parent_rect.y + parent_rect.h) -| row_y
            else
                @max(
                    @max(min_row_height, 1),
                    @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(parent_rect.h)) * row_accum / @as(f64, @floatFromInt(total_area))))),
                );
            // Same shared-edge adjustment as `placeSiblings`' own column
            // split, applied here to the row axis: every row but the
            // first is drawn 1 cell into the previous row's territory (and
            // 1 cell taller) so a merged border lands on a row both sides
            // agree on. `row_y` itself keeps accumulating the natural
            // (unadjusted) `h`.
            const draw_row_y = if (row_idx == 0) row_y else row_y -| 1;
            const draw_h = if (row_idx == 0) h else h + 1;
            placeSiblings(rects, laid_out, children[row_start .. i + 1], .{
                .x = parent_rect.x,
                .y = draw_row_y,
                .w = parent_rect.w,
                .h = draw_h,
            }, 0, row_idx % 2 == 1);
            row_y += h;
            row_start = i + 1;
            row_accum = 0;
            row_idx += 1;
        }
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "subtreeTotals sums a simple two-level tree" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 3, .label = "a" },
        .{ .parent = 0, .level = 1, .value = 4, .label = "b" },
    };
    var totals: [3]f64 = undefined;
    subtreeTotals(&nodes, &totals);
    try testing.expectEqual(@as(f64, 7), totals[0]);
    try testing.expectEqual(@as(f64, 3), totals[1]);
    try testing.expectEqual(@as(f64, 4), totals[2]);
}

test "subtreeTotals sums through three levels" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "group" },
        .{ .parent = 1, .level = 2, .value = 5, .label = "leaf1" },
        .{ .parent = 1, .level = 2, .value = 2, .label = "leaf2" },
    };
    var totals: [4]f64 = undefined;
    subtreeTotals(&nodes, &totals);
    try testing.expectEqual(@as(f64, 7), totals[0]);
    try testing.expectEqual(@as(f64, 7), totals[1]);
}

test "collapseDepth keeps a tree within budget untouched" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 5, .label = "a" },
    };
    const out = try collapseDepth(&nodes, 1, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
}

test "collapseDepth folds a subtree one level past budget" {
    // root(0) -> group(1) -> sub(2) -> leaf(3, value=9), leaf(4, value=1)
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "group" },
        .{ .parent = 1, .level = 2, .value = 0, .label = "sub" },
        .{ .parent = 2, .level = 3, .value = 9, .label = "leaf1" },
        .{ .parent = 2, .level = 3, .value = 1, .label = "leaf2" },
    };
    // Budget = 1: only root + group survive as containers; "sub" and its
    // children collapse into one leaf attached to "group".
    const out = try collapseDepth(&nodes, 1, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 3), out.len); // root, group, folded(sub)
    const folded = out[2];
    try testing.expectEqualStrings("sub", folded.label);
    try testing.expectEqual(@as(f64, 10), folded.value); // 9 + 1
    try testing.expectEqual(@as(usize, 1), folded.parent); // reattached to "group"
}

test "collapseDepth on an empty tree returns an empty slice" {
    const nodes = [_]Node{};
    const out = try collapseDepth(&nodes, 1, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "collapseDepth is a no-op when max_depth exceeds the tree's actual depth" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 5, .label = "a" },
    };
    // Budget of 5 is far deeper than this 2-level tree ever reaches.
    const out = try collapseDepth(&nodes, 5, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("root", out[0].label);
    try testing.expectEqualStrings("a", out[1].label);
}

test "collapseDepth folds a bare root with max_depth = 0" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 4, .label = "a" },
        .{ .parent = 0, .level = 1, .value = 6, .label = "b" },
    };
    const out = try collapseDepth(&nodes, 0, testing.allocator);
    defer testing.allocator.free(out);

    // Only the root survives as a container; "a" and "b" each fold
    // individually — they are siblings at the same level, not merged
    // into one bucket the way collapseSmall would.
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("root", out[0].label);
    try testing.expectEqualStrings("a", out[1].label);
    try testing.expectEqual(@as(f64, 4), out[1].value);
    try testing.expectEqualStrings("b", out[2].label);
    try testing.expectEqual(@as(f64, 6), out[2].value);
}

test "collapseDepth folds two subtrees under different parents independently" {
    // root(0) -> groupA(1) -> subA(2, leaf value 9)
    //         -> groupB(3) -> subB(4, leaf value 7)
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "groupA" },
        .{ .parent = 1, .level = 2, .value = 9, .label = "subA" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "groupB" },
        .{ .parent = 3, .level = 2, .value = 7, .label = "subB" },
    };
    const out = try collapseDepth(&nodes, 1, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 5), out.len); // root, groupA, subA, groupB, subB
    try testing.expectEqualStrings("subA", out[2].label);
    try testing.expectEqual(@as(f64, 9), out[2].value);
    try testing.expectEqual(@as(usize, 1), out[2].parent); // reattached to groupA
    try testing.expectEqualStrings("subB", out[4].label);
    try testing.expectEqual(@as(f64, 7), out[4].value);
    try testing.expectEqual(@as(usize, 3), out[4].parent); // reattached to groupB
}

test "collapseDepth handles a forest of independent roots" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "rootA" },
        .{ .parent = 0, .level = 1, .value = 3, .label = "a" },
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "rootB" },
        .{ .parent = 2, .level = 1, .value = 4, .label = "b" },
    };
    const out = try collapseDepth(&nodes, 1, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 4), out.len); // fully within budget, untouched
}

test "collapseDepth passes a negative subtree total through unclamped" {
    // Unlike collapseSmall, collapseDepth never casts to an unsigned cell
    // count — negative sums are carried through as-is; clamping is a
    // layout-time concern, not a tree-reduction concern.
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "group" },
        .{ .parent = 1, .level = 2, .value = -5, .label = "leaf" },
    };
    const out = try collapseDepth(&nodes, 1, testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(f64, -5), out[2].value);
}

test "collapseSmall bundles siblings below the visibility threshold" {
    // Four siblings sharing 100 cells; min_cells = 5.
    // Shares: 60, 25, 10, 5 cells → last two (10, 5) still individually >= 5,
    // so use values that make two of them fall below the threshold instead.
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 60, .label = "big" },
        .{ .parent = NO_PARENT, .level = 0, .value = 25, .label = "medium" },
        .{ .parent = NO_PARENT, .level = 0, .value = 3, .label = "tiny1" },
        .{ .parent = NO_PARENT, .level = 0, .value = 2, .label = "tiny2" },
    };
    const out = try collapseSmall(&nodes, 100, 5, "…other", testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 3), out.len); // big, medium, …other
    try testing.expectEqualStrings("…other", out[2].label);
    try testing.expectEqual(@as(f64, 5), out[2].value); // 3 + 2
}

test "collapseSmall folds a negative sibling instead of panicking on the cast" {
    // bucket_total = 10 + (-2) = 8 > 0, but the -2 sibling's own share is
    // negative — must clamp to 0 cells, not crash the float→usize cast.
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 10, .label = "a" },
        .{ .parent = NO_PARENT, .level = 0, .value = -2, .label = "b" },
    };
    const out = try collapseSmall(&nodes, 100, 5, "…other", testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 2), out.len); // a (125 cells), folded(b)
    try testing.expectEqualStrings("…other", out[1].label);
    try testing.expectEqual(@as(f64, -2), out[1].value);
}

test "collapseSmall treats an all-negative bucket as entirely too small" {
    // bucket_total = -8 <= 0 → every sibling gets share_cells = 0.
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = -5, .label = "a" },
        .{ .parent = NO_PARENT, .level = 0, .value = -3, .label = "b" },
    };
    const out = try collapseSmall(&nodes, 100, 5, "…other", testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("…other", out[0].label);
    try testing.expectEqual(@as(f64, -8), out[0].value);
}

test "collapseSmall leaves everything alone when all siblings clear the bar" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 50, .label = "a" },
        .{ .parent = NO_PARENT, .level = 0, .value = 50, .label = "b" },
    };
    const out = try collapseSmall(&nodes, 100, 5, "…other", testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
}

test "layoutTree produces self-consistent parent indices, unlike collapseSmall" {
    // root(0) -> list(1) -> item(2, value=0) -> link(3, v=2), text(4, v=2)
    //                    -> item(5, value=0) -> link(6, v=2), text(7, v=2)
    // Both items have the same subtree total (4), splitting list's bucket
    // (8) evenly — each would get 40 of area=80. min_cells=41 puts both
    // just under the threshold, so both fold into one "…other" under
    // list(1) — exactly the scenario that broke collapseSmall's flat,
    // whole-tree call (item's own `.value` is 0; only its *subtree* total
    // determines its share here).
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "list" },
        .{ .parent = 1, .level = 2, .value = 0, .label = "item" },
        .{ .parent = 2, .level = 3, .value = 2, .label = "link" },
        .{ .parent = 2, .level = 3, .value = 2, .label = "text" },
        .{ .parent = 1, .level = 2, .value = 0, .label = "item" },
        .{ .parent = 5, .level = 3, .value = 2, .label = "link" },
        .{ .parent = 5, .level = 3, .value = 2, .label = "text" },
    };
    var totals: [8]f64 = undefined;
    subtreeTotals(&nodes, &totals);

    const out = try layoutTree(&nodes, &totals, 0, 80, 3, 41, "…other", testing.allocator);
    defer testing.allocator.free(out);

    // root, list, …other(item+item) — the folded items' own children
    // (link/text) must NOT appear at all: they were absorbed into the fold,
    // not left dangling with a parent index that no longer resolves.
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("root", out[0].label);
    try testing.expectEqualStrings("list", out[1].label);
    try testing.expectEqualStrings("…other", out[2].label);
    try testing.expectEqual(@as(f64, 8), out[2].value); // 2+2+2+2

    // Every emitted node's `.parent` must be a valid index into `out` itself.
    for (out) |n| {
        try testing.expect(n.parent == NO_PARENT or n.parent < out.len);
    }
    try testing.expectEqual(@as(usize, 1), out[2].parent); // reattached to "list"
}

test "foldedChildren recovers exactly the set layoutTree would fold" {
    // Same tree/threshold as the test above: both "item" nodes (2 and 5)
    // fold into list's "…other" at min_cells=41, area=80.
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "list" },
        .{ .parent = 1, .level = 2, .value = 0, .label = "item" },
        .{ .parent = 2, .level = 3, .value = 2, .label = "link" },
        .{ .parent = 2, .level = 3, .value = 2, .label = "text" },
        .{ .parent = 1, .level = 2, .value = 0, .label = "item" },
        .{ .parent = 5, .level = 3, .value = 2, .label = "link" },
        .{ .parent = 5, .level = 3, .value = 2, .label = "text" },
    };
    var totals: [8]f64 = undefined;
    subtreeTotals(&nodes, &totals);

    const members = try foldedChildren(&nodes, &totals, 1, 80, 41, testing.allocator);
    defer testing.allocator.free(members);

    try testing.expectEqual(@as(usize, 2), members.len);
    try testing.expectEqual(@as(usize, 2), members[0]);
    try testing.expectEqual(@as(usize, 5), members[1]);
}

test "foldedChildren returns nothing when no sibling actually folds" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 50, .label = "a" },
        .{ .parent = 0, .level = 1, .value = 50, .label = "b" },
    };
    var totals: [3]f64 = undefined;
    subtreeTotals(&nodes, &totals);

    const members = try foldedChildren(&nodes, &totals, 0, 80, 5, testing.allocator);
    defer testing.allocator.free(members);
    try testing.expectEqual(@as(usize, 0), members.len);
}

test "layoutTree derives each level's area from its parent's area, not a global fixed one" {
    // root(0) -> a(1, value=1), b(2, value=1)   [2-way bucket]
    //         -> c(3, value=98)                  [dominates root's bucket]
    // c(3)   -> x(4, value=1), y(5, value=1)     [c's own 2-way bucket]
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 1, .label = "a" },
        .{ .parent = 0, .level = 1, .value = 1, .label = "b" },
        .{ .parent = 0, .level = 1, .value = 98, .label = "c" },
        .{ .parent = 3, .level = 2, .value = 1, .label = "x" },
        .{ .parent = 3, .level = 2, .value = 1, .label = "y" },
    };
    var totals: [6]f64 = undefined;
    subtreeTotals(&nodes, &totals);

    // area=100 at the root: c gets ~98 cells. x and y then split c's 98
    // cells roughly evenly (~49 each) — not root's full 100, and not a
    // flat area=100 applied uniformly at every depth.
    const out = try layoutTree(&nodes, &totals, 0, 100, 5, 1, "…other", testing.allocator);
    defer testing.allocator.free(out);

    var c_area: ?usize = null;
    var x_area: ?usize = null;
    for (out) |n| {
        if (std.mem.eql(u8, n.label, "c")) c_area = n.area;
        if (std.mem.eql(u8, n.label, "x")) x_area = n.area;
    }
    try testing.expect(c_area.? > 90);
    try testing.expect(x_area.? < c_area.?); // x's share is of c's area, not root's
}

test "layoutTree zoom: re-rooting at a non-root node needs no renormalization" {
    // A deeply unequal tree: node 2 owns a tiny sliver of the whole tree's
    // total, but its own children split evenly. Zooming to node 2 with a
    // full-size area should lay out its children the same way regardless of
    // how small node 2's share of the *global* root was.
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 9999, .label = "huge" },
        .{ .parent = 0, .level = 1, .value = 1, .label = "tiny" },
        .{ .parent = 2, .level = 2, .value = 5, .label = "left" },
        .{ .parent = 2, .level = 2, .value = 5, .label = "right" },
    };
    var totals: [5]f64 = undefined;
    subtreeTotals(&nodes, &totals);

    const zoomed = try layoutTree(&nodes, &totals, 2, 100, 5, 1, "…other", testing.allocator);
    defer testing.allocator.free(zoomed);

    try testing.expectEqual(@as(usize, 3), zoomed.len); // tiny(re-rooted), left, right
    try testing.expectEqualStrings("tiny", zoomed[0].label);
    try testing.expectEqual(@as(usize, 100), zoomed[0].area); // full canvas, not tiny's global sliver
    try testing.expectEqual(@as(usize, NO_PARENT), zoomed[0].parent);
    try testing.expectEqual(@as(usize, 50), zoomed[1].area); // even split of 100, not of root's 100
    try testing.expectEqual(@as(usize, 50), zoomed[2].area);
}

test "placeRects splits a two-level tree horizontally then vertically" {
    // root(0) -> a(1, area=60), b(2, area=40)      [level 1: horizontal]
    // a(1)   -> x(3, area=1), y(4, area=1)          [level 2: vertical]
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 60 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "b", .area = 40 },
        .{ .parent = 1, .level = 2, .value = 0, .label = "x", .area = 1 },
        .{ .parent = 1, .level = 2, .value = 0, .label = "y", .area = 1 },
    };
    const root_rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 10 };
    const rects = try placeRects(&laid_out, root_rect, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);

    try testing.expectEqual(root_rect, rects[0]);

    // Level 1 (even depth) splits horizontally, inside root's interior
    // (root's own 1-cell border reserved: {1,1,98,8}): a gets 60% of that
    // interior's width, b the rest, both spanning its full height.
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .w = 59, .h = 8 }, rects[1]);
    try testing.expectEqual(Rect{ .x = 60, .y = 1, .w = 39, .h = 8 }, rects[2]);

    // Level 2 (odd depth) splits vertically within a's *interior*
    // ({2,2,57,6} — a's own border reserved too): x and y evenly share
    // that interior's height, full width of it, not root's or a's outer rect.
    try testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 57, .h = 3 }, rects[3]);
    try testing.expectEqual(Rect{ .x = 2, .y = 5, .w = 57, .h = 3 }, rects[4]);
}

test "placeRects: last sibling absorbs rounding, never underflows" {
    // Three children with an uneven 100-cell root width: 33/33/33 areas
    // over a 100-wide rect can't split evenly; the last child must absorb
    // whatever is left rather than panicking on a negative width.
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 33 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "b", .area = 33 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "c", .area = 33 },
    };
    // h=3 (not 1): a 1-row root would have a zero-height interior after its
    // own border is reserved, degenerately collapsing every child — not
    // what this test is about, which is purely the width-rounding case.
    const rects = try placeRects(&laid_out, .{ .x = 0, .y = 0, .w = 100, .h = 3 }, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);

    // Root's interior width is 98 (100 minus its own 1-cell border on each
    // side), not 100.
    try testing.expectEqual(@as(usize, 98), rects[1].w + rects[2].w + rects[3].w);
    try testing.expect(rects[3].w > 0);
}

test "placeRects: every child's rect fits within its parent's, on a 3-level tree" {
    // root -> a, b   (level 1, horizontal)
    // a    -> x, y   (level 2, vertical)
    // x    -> p, q   (level 3, horizontal again)
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 70 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "b", .area = 30 },
        .{ .parent = 1, .level = 2, .value = 0, .label = "x", .area = 40 },
        .{ .parent = 1, .level = 2, .value = 0, .label = "y", .area = 30 },
        .{ .parent = 3, .level = 3, .value = 0, .label = "p", .area = 20 },
        .{ .parent = 3, .level = 3, .value = 0, .label = "q", .area = 20 },
    };
    const rects = try placeRects(&laid_out, .{ .x = 0, .y = 0, .w = 100, .h = 10 }, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);

    for (laid_out, 0..) |n, i| {
        if (n.parent == NO_PARENT) continue;
        const p = rects[n.parent];
        const r = rects[i];
        // Strictly inside the parent's own border, not just inside its
        // outer rect — a child touching the parent's edge would collide
        // with the parent's own drawn border there.
        try testing.expect(r.x > p.x and r.y > p.y);
        try testing.expect(r.x + r.w < p.x + p.w);
        try testing.expect(r.y + r.h < p.y + p.h);
    }
}

test "placeRectsWrapped: a short-and-wide area keeps everything in one wide row" {
    // root's interior is 80x3 (root_rect 82x5, minus its own 1-cell border
    // on each side). At min_row_height=2, only 1 row fits (3/2=1), so all 4
    // equal-weight children share that single row by width: 80/4 = 20 each
    // — exactly the "3 row x 80 col -> four 3x20 sections" example.
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 25 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "b", .area = 25 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "c", .area = 25 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "d", .area = 25 },
    };
    const rects = try placeRectsWrapped(&laid_out, .{ .x = 0, .y = 0, .w = 82, .h = 5 }, 2, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);

    try testing.expectEqual(Rect{ .x = 1, .y = 1, .w = 20, .h = 3 }, rects[1]);
    try testing.expectEqual(Rect{ .x = 21, .y = 1, .w = 20, .h = 3 }, rects[2]);
    try testing.expectEqual(Rect{ .x = 41, .y = 1, .w = 20, .h = 3 }, rects[3]);
    try testing.expectEqual(Rect{ .x = 61, .y = 1, .w = 20, .h = 3 }, rects[4]);
}

test "placeRectsWrapped: a tall-enough area wraps into multiple rows, order-preserving" {
    // root's interior is 40x16 (root_rect 42x18, so 16 divides evenly by 8
    // rows with no remainder for the "last row absorbs rounding" rule to
    // complicate the check). 8 equal-weight children, min_row_height=2:
    // max_rows_by_height = 16/2 = 8, capped at children.len=8, so 8 rows of
    // 1 item each — each item gets the FULL 40-wide row rather than
    // splitting width 8 ways, which is the whole point (maximize width
    // over "squareness"). Order must be preserved: item i lands in row i,
    // top to bottom.
    var laid_out: [9]LaidOutNode = undefined;
    laid_out[0] = .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 };
    var labels: [8][2]u8 = undefined;
    for (0..8) |i| {
        labels[i] = .{ 'a' + @as(u8, @intCast(i)), 0 };
        laid_out[i + 1] = .{ .parent = 0, .level = 1, .value = 0, .label = labels[i][0..1], .area = 1 };
    }
    const rects = try placeRectsWrapped(&laid_out, .{ .x = 0, .y = 0, .w = 42, .h = 18 }, 2, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);

    for (0..8) |i| {
        const r = rects[i + 1];
        try testing.expectEqual(@as(usize, 1), r.x);
        try testing.expectEqual(@as(usize, 40), r.w); // full width, not split 8 ways
        try testing.expectEqual(@as(usize, 1 + i * 2), r.y); // stacked in order, 2 rows tall each
        try testing.expectEqual(@as(usize, 2), r.h);
    }
}

test "placeRectsWrapped falls back to a single row when the wrap degenerates" {
    // min_row_height larger than the whole available height: max_rows=0,
    // clamped to 1 — must not panic or produce a zero-row layout.
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 50 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "b", .area = 50 },
    };
    const rects = try placeRectsWrapped(&laid_out, .{ .x = 0, .y = 0, .w = 20, .h = 5 }, 100, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);
    // No crash, and both children get real (nonzero) width in the one row.
    try testing.expect(rects[1].w > 0);
    try testing.expect(rects[2].w > 0);
    try testing.expectEqual(rects[1].y, rects[2].y); // same single row
}

test "placeRectsWrapped never leaves a grandchild's rect uninitialized when a row squeezes its parent to zero height" {
    // root_rect 20x4 -> interior {1,1,18,2}. min_row_height=2 forces a
    // single row (max_rows_by_height = 2/2 = 1), so a/b each get the full
    // interior height (2). Their OWN interior (via interiorRect, -2) is
    // then height=0 — the exact degenerate case that used to leave
    // "grandchild"'s rect completely unassigned (read back later as
    // uninitialized memory, previously surfaced as a crash rendering the
    // real README.md tree) instead of falling through to a valid,
    // zero-height-but-written rect.
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 50 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "b", .area = 50 },
        .{ .parent = 2, .level = 2, .value = 0, .label = "grandchild", .area = 10 },
    };
    const rects = try placeRectsWrapped(&laid_out, .{ .x = 0, .y = 0, .w = 20, .h = 4 }, 2, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);

    try testing.expectEqual(@as(usize, 2), rects[2].h); // b's own height, sane
    try testing.expectEqual(@as(usize, 0), rects[3].h); // grandchild: degenerate but WRITTEN, not garbage
    try testing.expect(rects[3].w < 1000); // bounded — not uninitialized-memory-sized
    try testing.expect(rects[3].x < 1000);
    try testing.expect(rects[3].y < 1000);
}

test "placeRectsWrapped uses the full height even when actual rows < the height-based target" {
    // root_rect 12x6 -> interior {1,1,10,4}. min_row_height=1 gives
    // max_rows_by_height = 4, capped at children.len=5, so target_rows=4.
    // But 5 EQUAL-weight children greedily group into only 3 rows
    // (2, 2, 1 — target_per_row = 5/4 = 1.25 of a unit, so accumulating
    // two equal-weight items always crosses that before a third would):
    // rows[0]=children 0-1, rows[1]=children 2-3, rows[2]=child 4. Sizing
    // row height off the *planned* 4 rows (interior_h/4 = 1) would only
    // ever place rects in the first 3 of the interior's 4 available rows,
    // leaving the 4th completely blank — exactly the "screen real estate
    // not fully used" bug. Row height must instead be sized off the 3
    // rows that actually get used (interior_h/3), so the last row reaches
    // the full interior height.
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 1 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "b", .area = 1 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "c", .area = 1 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "d", .area = 1 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "e", .area = 1 },
    };
    const rects = try placeRectsWrapped(&laid_out, .{ .x = 0, .y = 0, .w = 12, .h = 6 }, 1, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);

    // The last child's row must reach all the way to the interior's
    // bottom edge (root_rect.y + root_rect.h - 1 = 5) — no dead gap below it.
    const last_row_bottom = rects[5].y + rects[5].h;
    try testing.expectEqual(@as(usize, 5), last_row_bottom);

    // And confirm it really did use only 3 rows, not 4 — three distinct y
    // values among the five children.
    var seen_ys: [5]usize = undefined;
    var seen_count: usize = 0;
    outer: for (rects[1..6]) |r| {
        for (seen_ys[0..seen_count]) |y| if (y == r.y) continue :outer;
        seen_ys[seen_count] = r.y;
        seen_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen_count);
}

test "placeRectsWrapped border_depth=0: only the root loses space to interiorRect" {
    // root (level 0) <= border_depth(0): its children ("a") get placed
    // inside interiorRect(root_rect) — inset by 1 on every side, exactly
    // as ALWAYS_BORDERED would. "a" (level 1) is NOT <= 0, so ITS OWN
    // child ("leaf") is placed in "a"'s full rect, flush — no second
    // inset "a" would otherwise cost if a border were drawn around it too.
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 100 },
        .{ .parent = 1, .level = 2, .value = 0, .label = "leaf", .area = 100 },
    };
    const rects = try placeRectsWrapped(&laid_out, .{ .x = 0, .y = 0, .w = 20, .h = 10 }, 1, 0, testing.allocator);
    defer testing.allocator.free(rects);

    // "a" sits in root's interior: 1-cell inset from the 20x10 root_rect.
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .w = 18, .h = 8 }, rects[1]);
    // "leaf" fills "a"'s rect exactly — no further inset, unlike
    // ALWAYS_BORDERED which would shrink it by 1 on every side again.
    try testing.expectEqual(rects[1], rects[2]);
}

test "placeRectsWrapped border_depth=ALWAYS_BORDERED matches the original every-level-insets behavior" {
    // Same tree as above, but with the legacy constant: "leaf" should now
    // be inset a second time, inside "a"'s own interior.
    const laid_out = [_]LaidOutNode{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root", .area = 100 },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a", .area = 100 },
        .{ .parent = 1, .level = 2, .value = 0, .label = "leaf", .area = 100 },
    };
    const rects = try placeRectsWrapped(&laid_out, .{ .x = 0, .y = 0, .w = 20, .h = 10 }, 1, ALWAYS_BORDERED, testing.allocator);
    defer testing.allocator.free(rects);

    try testing.expectEqual(Rect{ .x = 1, .y = 1, .w = 18, .h = 8 }, rects[1]);
    try testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 16, .h = 6 }, rects[2]);
}
