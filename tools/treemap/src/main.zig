/// Interactive tree explorer: renders a tree_lod.layoutTree/placeRects result
/// live in the terminal, using zigtui for terminal control and drawing.
///
/// Run with:   zig build run
///             zig build run -- path/to/tree.json   (load real data)
///             zig build run -- './duckdir.sh ~/repos |'   (load from a
///                              launched command instead of a file — the
///                              trailing `|` is the whole signal, same
///                              convention shellfs/duckdir.sh's own SQL
///                              uses; see `loadNodesFromCommand`. Runs
///                              through `sh -c`, so pipelines/redirects in
///                              the command string work too.)
///
/// Input file format: a JSON array of {parent, level, value, label}, where
/// `parent` is either an integer index into this same array or `null` for a
/// root. Deliberately JSON, not CSV: CSV is untyped (every field comes back
/// as a string), so `value`/`level`/`parent` would need hand-rolled numeric
/// parsing with its own error cases; JSON gives typed numbers and null for
/// free via `std.json` (already in the standard library — no new
/// dependency), and DuckDB emits it natively via `-json`. Generate one from
/// this project's own README, e.g.:
///
///   duckdb -json -c "
///     LOAD markdown;
///     WITH t AS (FROM read_markdown_blocks('README.md') SELECT *)
///     SELECT (SELECT max(p.element_order) FROM t p
///             WHERE p.element_order < t.element_order AND p.level = t.level - 1) AS parent,
///            t.level - 1 AS level,
///            coalesce(length(t.content), 0) AS value,
///            t.element_type AS label
///     FROM t ORDER BY t.element_order" > tree.json
///
/// Controls:  up/down     change level: down zooms in (re-roots at the
///                        selected child), up zooms out (back to the
///                        previous root) — enter/backspace do the same,
///                        as aliases
///            left/right  change selection among siblings at the current
///                        level
///            v           toggle "containment" vs. "classical" border
///                        style — see `AppState.classical_style`
///            c           copy the selected node's on-screen box (as
///                        currently rendered) to the clipboard
///            d           copy the selected node's own subtree, as a
///                        standalone tree.json, to the clipboard
///            u           toggle plain-number vs. SI-suffixed
///                        ("2M" vs. "2000000") value labels — see
///                        `formatValue`
///            s           toggle real-size vs. equal-weight layout —
///                        every leaf gets the same on-screen area
///                        regardless of `value`, and value labels go
///                        blank — see `AppState.equal_weight`
///            q / esc     quit
///
/// The whole point of this tool: layoutTree/placeRects are cheap enough to
/// recompute on every keypress, using whatever (root, area) the terminal and
/// the user's navigation currently call for. "Zoom to node X" costs nothing
/// beyond changing `root` and calling layoutTree again — no renormalization,
/// because tree_lod's area shares are always local to a node's own siblings.
const std = @import("std");
const tui = @import("zigtui");
const tree_lod = @import("tree_lod");

const Node = tree_lod.Node;
const NO_PARENT = tree_lod.NO_PARENT;
const LaidOutNode = tree_lod.LaidOutNode;
const Rect = tree_lod.Rect;

const Terminal = tui.Terminal;
const Buffer = tui.Buffer;
const Canvas = tui.widgets.Canvas;
const Style = tui.Style;

/// Containment border weight by depth, matching test_snakemap.sh's own
/// convention (and box.zig's THIN/HEAVY/DOUBLE u2 field, which is why
/// there are exactly three tiers and not more: a 2-bit weight can't
/// distinguish a fourth). Root = double, next level = heavy, everything
/// from the third level down = thin — `n.level` here is already relative
/// to whatever the *current* root is (layoutTree always starts it at 0),
/// so this naturally resets correctly after every zoom, not just at launch.
const BoxWeight = enum { thin, heavy, double };

fn weightForLevel(level: u16) BoxWeight {
    return switch (level) {
        0 => .double,
        1 => .heavy,
        else => .thin,
    };
}

const BoxGlyphs = struct { tl: u21, tr: u21, bl: u21, br: u21, h: u21, v: u21 };

fn boxGlyphs(weight: BoxWeight) BoxGlyphs {
    return switch (weight) {
        .thin => .{ .tl = 0x250C, .tr = 0x2510, .bl = 0x2514, .br = 0x2518, .h = 0x2500, .v = 0x2502 }, // ┌┐└┘─│
        .heavy => .{ .tl = 0x250F, .tr = 0x2513, .bl = 0x2517, .br = 0x251B, .h = 0x2501, .v = 0x2503 }, // ┏┓┗┛━┃
        .double => .{ .tl = 0x2554, .tr = 0x2557, .bl = 0x255A, .br = 0x255D, .h = 0x2550, .v = 0x2551 }, // ╔╗╚╝═║
    };
}

/// Thin weight, rounded corners — distinguishes a leaf (nothing further to
/// contain) from a group node at the same depth, which always uses one of
/// `boxGlyphs`' square-cornered weights.
const LEAF_GLYPHS = BoxGlyphs{ .tl = 0x256D, .tr = 0x256E, .bl = 0x2570, .br = 0x256F, .h = 0x2500, .v = 0x2502 }; // ╭╮╰╯─│

/// zigtui v0.1.0's Canvas.drawBox breaks for width==2 or height==2: it draws
/// the four corners, then unconditionally calls drawHLine(x1+1, x2-1, ...)
/// and drawVLine(y1+1, y2-1, ...) meant to draw nothing when there's no gap
/// between the corners on that axis (e.g. y1+1 > y2-1 when height==2). But
/// drawHLine/drawVLine reorder their two endpoints via min/max with no
/// "empty range" check, so an inverted range like (y1+1, y2-1) = (y2, y1)
/// gets reinterpreted as "draw from y1 to y2" — overwriting both corner rows
/// with a plain side character. This node-box tree renders 2-row/2-col
/// leaves constantly (that's the minimum size `layoutTree`/`placeRects`
/// still bothers to lay out), so we can't rely on the library's own helper.
fn drawNodeBox(canvas: Canvas, rect: tui.Rect, g: BoxGlyphs, s: Style) void {
    if (rect.width < 2 or rect.height < 2) return;
    const x1 = rect.x;
    const y1 = rect.y;
    const x2 = rect.x + rect.width - 1;
    const y2 = rect.y + rect.height - 1;

    canvas.setPixel(x1, y1, g.tl, s);
    canvas.setPixel(x2, y1, g.tr, s);
    canvas.setPixel(x1, y2, g.bl, s);
    canvas.setPixel(x2, y2, g.br, s);
    if (x2 > x1 + 1) {
        canvas.drawHLine(x1 + 1, x2 - 1, y1, g.h, s);
        if (y2 != y1) canvas.drawHLine(x1 + 1, x2 - 1, y2, g.h, s);
    }
    if (y2 > y1 + 1) {
        canvas.drawVLine(x1, y1 + 1, y2 - 1, g.v, s);
        canvas.drawVLine(x2, y1 + 1, y2 - 1, g.v, s);
    }
}

/// Leaf interior fill glyphs, indexed by `shade - 1` (shade is 1..3 — see
/// `JsonNode.shade`). A node with no shade (or an out-of-range one) gets no
/// fill at all, per `leafFillChar` below — no cycled-by-position default.
const LEAF_FILL_CHARS = [_]u21{ '░', '▒', '▓' };

/// The fill glyph for a leaf, read from the source JSON's own `shade`
/// (1..3) rather than derived from screen position — `null` (blank
/// interior, no fill drawn) for a node with no `shade` set, one outside
/// 1..3, or a "…" aggregate (`NO_PARENT`, no single source row to read a
/// shade from).
fn leafFillChar(shades: []const u8, orig_index: usize) ?u21 {
    if (orig_index == NO_PARENT or orig_index >= shades.len) return null;
    const v = shades[orig_index];
    if (v < 1 or v > 3) return null;
    return LEAF_FILL_CHARS[v - 1];
}

/// Whether a laid-out entry should draw as a container (border weight by
/// depth) rather than a leaf (shaded fill, rounded border) — read straight
/// off `Derived.has_children` (full-tree, indexed by original node index)
/// rather than recomputed per frame from the current `laid_out` slice's own
/// `.parent` positions. A "…" aggregate (`NO_PARENT`) is always a leaf: it
/// has no single source row of its own to look up.
fn isGroup(has_children: []const bool, orig_index: usize) bool {
    return orig_index != NO_PARENT and orig_index < has_children.len and has_children[orig_index];
}

/// Cubic ease-in-out, `t` in `[0, 1]` — slow start and finish with faster
/// motion through the middle, instead of the constant-speed motion a plain
/// linear `t` gives `lerpRect`. Cheap stand-in for van Wijk & Nuij's actual
/// zoom-easing curve ("Smooth and Efficient Zooming and Panning", InfoVis
/// 2003 — the basis for d3.js's `interpolateZoom`), which shapes the path
/// itself around perceived constant velocity rather than just easing a
/// fixed linear path; good enough here since every tweened rect already
/// shares the same duration/step count, not a distance-dependent one.
fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) return 4 * t * t * t;
    const f = -2 * t + 2;
    return 1 - (f * f * f) / 2;
}

/// Linear interpolation between two placed rects, `t` in `[0, 1]` — used
/// for the zoom-in "tween" animation (see `animateZoomIn`): the same node
/// growing from its small pre-zoom box to its post-zoom (possibly
/// full-screen) one over several intermediate frames instead of blinking
/// straight to the final layout. Callers pass an eased `t` (see
/// `easeInOutCubic`), not the raw step fraction, for the actual motion.
fn lerpRect(a: Rect, b: Rect, t: f64) Rect {
    const lerp = struct {
        fn f(x0: usize, x1: usize, tt: f64) usize {
            const v0: f64 = @floatFromInt(x0);
            const v1: f64 = @floatFromInt(x1);
            return @intFromFloat(@round(v0 + (v1 - v0) * tt));
        }
    }.f;
    return .{
        .x = lerp(a.x, b.x, t),
        .y = lerp(a.y, b.y, t),
        .w = lerp(a.w, b.w, t),
        .h = lerp(a.h, b.h, t),
    };
}

/// Bit for each of the 4 directions a box-drawing line can run from a cell
/// — used to merge two touching boxes' borders into one shared wall
/// instead of drawing two separate columns/rows side by side (see
/// `drawEntries`'s wall-mask passes). Two adjacent boxes' rects already
/// share their touching column/row exactly (`tree_lod.placeSiblings`/
/// `placeSiblingsWrapped` place every non-first sibling 1 cell into its
/// predecessor's own territory, specifically so this works), so marking
/// both boxes' own border cells into the same scratch grid naturally makes
/// the shared cells pick up bits from both sides. A cell's final glyph is
/// whatever `wallGlyph` maps its *combined* (OR'd) mask to, indexing
/// straight into a 16-entry table — no switch needed, since the bit
/// values already are the table index.
const WALL_UP: u4 = 1;
const WALL_DOWN: u4 = 2;
const WALL_LEFT: u4 = 4;
const WALL_RIGHT: u4 = 8;

/// All 16 possible combinations of up/down/left/right, indexed by the
/// `WALL_*` mask, for light-weight borders (leaves) — a complete table,
/// not an approximation, since the light box-drawing block has all 16
/// combinations as single codepoints.
const LIGHT_WALL_GLYPHS = [16]u21{
    ' ',
    '╵',
    '╷',
    '│',
    '╴',
    '┘',
    '┐',
    '┤',
    '╶',
    '└',
    '┌',
    '├',
    '─',
    '┴',
    '┬',
    '┼',
};

/// Same table, heavy weight — for depth-1 group borders (`weightForLevel`
/// gives every depth-1 node the same weight, so this is just as complete
/// a merge as the leaf one).
const HEAVY_WALL_GLYPHS = [16]u21{
    ' ',
    '╹',
    '╻',
    '┃',
    '╸',
    '┛',
    '┓',
    '┫',
    '╺',
    '┗',
    '┏',
    '┣',
    '━',
    '┻',
    '┳',
    '╋',
};

fn wallGlyph(glyphs: *const [16]u21, mask: u4) u21 {
    return glyphs[mask];
}

/// Combines a cell's light and heavy masks into one glyph — the mixed
/// case `wallGlyph` alone can't handle. Unicode's box-drawing block does
/// have per-arm light/heavy glyphs for *every* arm combination (not just
/// all-light or all-heavy); this covers the two shapes this app's own
/// geometry actually produces, both from the same source — in "classical"
/// style, a depth-1 group's own heavy edge sits flush against its
/// children (see `borderDepth`), so a lighter child wall can touch it
/// from the inside:
///
///   - a straight heavy edge meeting one perpendicular light arm (a
///     3-arm T) — e.g. the depth-1 box's own top/bottom edge with a
///     child wall reaching up/down into it;
///   - that same edge ALSO continuing past this cell as a heavy
///     row-wrap boundary shared with a sibling depth-1 box (see
///     `tree_lod.placeSiblingsWrapped`), making it a 4-arm cross:
///     3 arms heavy (the continuing edge/boundary) and 1 arm light
///     (the child wall) — this is the case a flat T/cross table alone
///     would otherwise collapse into a wrong, needlessly-all-heavy `╋`.
///
/// The depth-1 box's 4 *corners* stay pure heavy regardless (a light
/// corner landing there loses outright via `resolveWallConflicts`' "bold
/// wins" rule, since a corner's 2 arms are already heavy), and nothing in
/// this app's own geometry produces anything busier (2 light arms mixed
/// with 2 heavy, or a light arm opposite another light arm straddling a
/// heavy pair) — `light`/`heavy` must already be conflict-free
/// (`light & heavy == 0`).
fn combinedWallGlyph(light: u4, heavy: u4) u21 {
    if (heavy == 0) return LIGHT_WALL_GLYPHS[light];
    if (light == 0) return HEAVY_WALL_GLYPHS[heavy];
    // 3-arm T: 2 heavy (a straight line) + 1 light (perpendicular stub).
    if (heavy == (WALL_LEFT | WALL_RIGHT) and light == WALL_DOWN) return '┯';
    if (heavy == (WALL_LEFT | WALL_RIGHT) and light == WALL_UP) return '┷';
    if (heavy == (WALL_UP | WALL_DOWN) and light == WALL_RIGHT) return '┠';
    if (heavy == (WALL_UP | WALL_DOWN) and light == WALL_LEFT) return '┨';
    // 4-arm cross: 3 heavy (the straight line continues past this cell
    // too, e.g. a row-wrap boundary shared with a sibling) + 1 light.
    if (heavy == (WALL_UP | WALL_LEFT | WALL_RIGHT) and light == WALL_DOWN) return '╇';
    if (heavy == (WALL_DOWN | WALL_LEFT | WALL_RIGHT) and light == WALL_UP) return '╈';
    if (heavy == (WALL_UP | WALL_DOWN | WALL_LEFT) and light == WALL_RIGHT) return '╉';
    if (heavy == (WALL_UP | WALL_DOWN | WALL_RIGHT) and light == WALL_LEFT) return '╊';
    // A combination this app's own geometry shouldn't produce — fall back
    // to drawing every present arm heavy, rather than guessing at a
    // mixed glyph that might not exist or might be wrong.
    return HEAVY_WALL_GLYPHS[light | heavy];
}

/// "Bold wins": when the same direction at the same cell would otherwise
/// carry both a light and a heavy line (a child wall's stub landing
/// exactly on the depth-1 box's own heavy edge, continuing in the *same*
/// direction the edge already runs), the heavy line wins outright — the
/// light bit for that direction is dropped. Must run before
/// `combinedWallGlyph`, which assumes its two masks are already
/// conflict-free.
fn resolveWallConflicts(light: u4, heavy: u4) u4 {
    return light & ~heavy;
}

/// ORs `rect`'s own 4 border lines into a `mask_w`-wide scratch grid, cell
/// by cell — a corner cell picks up bits from both the horizontal and
/// vertical line passing through it, an edge cell from just one. Two boxes
/// whose rects share a column/row this way end up with each contributing
/// their own bits to the *same* cells, so `wallGlyph` naturally renders
/// the correct combined junction there instead of one box's line silently
/// overwriting the other's.
/// Weight-agnostic — the caller's own `walls`/`selected` scratch grids
/// only ever accumulate bits from one merge pass (one weight) at a time,
/// so which glyph table eventually reads them back is entirely up to the
/// caller (see the two `wallGlyph` calls in `drawEntries`).
///
/// `selected`, parallel to `walls`, is OR'd with `is_selected` at every
/// cell this call touches — so a shared wall between a selected and an
/// unselected box still highlights (the alternative, tracking a style per
/// box per cell, would need actual `Style` values here instead of a
/// single flag; not worth it when the only style this app ever applies to
/// a border is "plain" or "selected yellow").
fn markBorderWalls(walls: []u4, selected: []bool, mask_w: u16, rect: tui.Rect, is_selected: bool) void {
    if (rect.width < 2 or rect.height < 2) return;
    const x0 = rect.x;
    const x1 = rect.x + rect.width - 1;
    const y0 = rect.y;
    const y1 = rect.y + rect.height - 1;

    const mark = struct {
        fn f(w: []u4, sel: []bool, idx: usize, bit: u4, is_sel: bool) void {
            w[idx] |= bit;
            if (is_sel) sel[idx] = true;
        }
    }.f;

    var col: u16 = 0;
    while (col < rect.width) : (col += 1) {
        const x = x0 + col;
        if (col > 0) mark(walls, selected, @as(usize, y0) * mask_w + x, WALL_LEFT, is_selected);
        if (col < rect.width - 1) mark(walls, selected, @as(usize, y0) * mask_w + x, WALL_RIGHT, is_selected);
        if (y1 != y0) {
            if (col > 0) mark(walls, selected, @as(usize, y1) * mask_w + x, WALL_LEFT, is_selected);
            if (col < rect.width - 1) mark(walls, selected, @as(usize, y1) * mask_w + x, WALL_RIGHT, is_selected);
        }
    }
    var row: u16 = 0;
    while (row < rect.height) : (row += 1) {
        const y = y0 + row;
        if (row > 0) mark(walls, selected, @as(usize, y) * mask_w + x0, WALL_UP, is_selected);
        if (row < rect.height - 1) mark(walls, selected, @as(usize, y) * mask_w + x0, WALL_DOWN, is_selected);
        if (x1 != x0) {
            if (row > 0) mark(walls, selected, @as(usize, y) * mask_w + x1, WALL_UP, is_selected);
            if (row < rect.height - 1) mark(walls, selected, @as(usize, y) * mask_w + x1, WALL_DOWN, is_selected);
        }
    }
}

/// Whole-tree data derived from `nodes` alone (root/selection-independent),
/// computed once per `nodes` generation rather than every frame. With a
/// real filesystem tree this can be hundreds of thousands of rows — before
/// this cache existed, every one of these four arrays was recomputed from
/// scratch on *every* redraw (subtreeTotals directly, the other three via
/// the status bar's group/leaf count), which pegged a full CPU core
/// redoing identical whole-tree work ~10 times a second and made the UI
/// feel unresponsive to input at that scale, though it was never an actual
/// infinite loop.
const Derived = struct {
    /// subtreeTotals(nodes, ...): each node's own value plus every
    /// descendant's, indexed by original node index.
    totals: []f64,
    /// Whether node i has at least one child — same test the render pass
    /// needs to decide group vs. leaf styling, but for every original
    /// node, not just the currently-visible/folded ones.
    has_children: []bool,
    /// How many descendants (not counting the node itself) are groups vs.
    /// leaves — exactly what the status bar's "(G10,L3)" reports, read
    /// straight off here. Same field names/shape as duckdir.sh's own
    /// `groups`/`leaves` SQL output (see its doc comment) so a tree.json
    /// that already supplies them can be used as-is, with no conversion.
    subtree_groups: []usize,
    subtree_leaves: []usize,
    /// Same shape as `totals` (each node's own value plus every
    /// descendant's), but every leaf counts as exactly 1 regardless of its
    /// real `value` — i.e. a node's slot here is just its contained leaf
    /// count including itself: `subtree_leaves[i] + (0 if it has children
    /// else 1)`. Used in place of `totals` for layout (not display) when
    /// `AppState.equal_weight` is set, so every leaf gets equal on-screen
    /// area regardless of size — see `activeTotals`.
    equal_totals: []f64,
    /// `tree_lod`'s own children-adjacency index — built once here and
    /// threaded into `layoutTreeWithIndex`/`foldedChildrenWithIndex` at
    /// every call site instead of letting `layoutTree`/`foldedChildren`
    /// rebuild it (an O(nodes.len) counting sort) on every single frame.
    child_index: tree_lod.ChildIndex,

    fn deinit(self: Derived, gpa: std.mem.Allocator) void {
        gpa.free(self.totals);
        gpa.free(self.has_children);
        gpa.free(self.subtree_groups);
        gpa.free(self.subtree_leaves);
        gpa.free(self.equal_totals);
        self.child_index.deinit(gpa);
    }
};

fn computeDerived(nodes: []const Node, gpa: std.mem.Allocator) !Derived {
    const totals = try gpa.alloc(f64, nodes.len);
    errdefer gpa.free(totals);
    tree_lod.subtreeTotals(nodes, totals);

    const child_index = try tree_lod.buildChildIndex(nodes, gpa);
    errdefer child_index.deinit(gpa);

    const has_children = try gpa.alloc(bool, nodes.len);
    errdefer gpa.free(has_children);
    @memset(has_children, false);
    for (nodes) |n| {
        if (n.parent != NO_PARENT) has_children[n.parent] = true;
    }

    // Bottom-up accumulation (same shape as `subtreeTotals`, relying on
    // `parent[i] < i`): each slot starts as its own group/leaf tally, then
    // folds into its parent's, so a node's slot ends up self-included —
    // its own tally is subtracted back out below to store descendants
    // only, matching duckdir.sh's own SQL output.
    const subtree_groups = try gpa.alloc(usize, nodes.len);
    errdefer gpa.free(subtree_groups);
    const subtree_leaves = try gpa.alloc(usize, nodes.len);
    errdefer gpa.free(subtree_leaves);
    for (nodes, 0..) |_, i| {
        subtree_groups[i] = if (has_children[i]) 1 else 0;
        subtree_leaves[i] = if (has_children[i]) 0 else 1;
    }
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const p = nodes[i].parent;
        if (p != NO_PARENT) {
            subtree_groups[p] += subtree_groups[i];
            subtree_leaves[p] += subtree_leaves[i];
        }
    }
    for (nodes, 0..) |_, idx| {
        if (has_children[idx]) subtree_groups[idx] -= 1 else subtree_leaves[idx] -= 1;
    }

    const equal_totals = try gpa.alloc(f64, nodes.len);
    errdefer gpa.free(equal_totals);
    for (nodes, 0..) |_, idx| {
        const own: usize = if (has_children[idx]) 0 else 1;
        equal_totals[idx] = @floatFromInt(subtree_leaves[idx] + own);
    }

    return .{
        .totals = totals,
        .has_children = has_children,
        .subtree_groups = subtree_groups,
        .subtree_leaves = subtree_leaves,
        .equal_totals = equal_totals,
        .child_index = child_index,
    };
}

/// One row of the input JSON file. `parent` is nullable (root has no
/// parent) — converted to `tree_lod.NO_PARENT` right after parsing, since
/// that's the sentinel `Node`/`layoutTree` actually expect. `shade` is
/// optional and defaults to `null` (blank) when the key is missing from a
/// row entirely, not just when it's JSON `null`. `total`/`groups`/`leaves`
/// are optional precomputed `Derived` values — see `loadNodesFromFile`'s
/// fast path below and duckdir.sh's own doc comment for where they come
/// from and what they mean.
const JsonNode = struct {
    parent: ?usize,
    level: u16,
    value: ?f64 = null,
    label: []const u8,
    shade: ?u8 = null,
    total: ?f64 = null,
    groups: ?usize = null,
    leaves: ?usize = null,
    /// A stable identity for matching the same real-world entity (a
    /// filesystem path, a pid) across two independently-loaded trees —
    /// e.g. a live-reload tween needs this to tell "this box moved/
    /// resized" from "this is an unrelated new box", since `label` isn't
    /// unique (ps_scan.sql alone can emit several sibling nodes labeled
    /// "Isolated") and a node's index into this array isn't stable across
    /// a reload the way it is across a same-array zoom (see
    /// `LaidOutNode.orig_index`). `null` when the source doesn't provide
    /// one (tree_scan.sql/duckdir.sh don't yet) — reload-tweening falls
    /// back to no animation for a tree with no keys, same as it would for
    /// any other missing optional field.
    key: ?[]const u8 = null,
};

/// What `loadNodesFromFile`/`loadNodesFromCommand`/`parseTreeJson` all
/// return — named (not an inline anonymous `struct {...}` repeated at
/// each site) specifically so the three are interchangeable: an inline
/// struct literal type is distinct per declaration site even when every
/// field matches, which would stop `loadNodesFromCommand` from simply
/// returning whatever `parseTreeJson` gives it.
const LoadedTree = struct { nodes: []Node, shades: []u8, keys: []?[]const u8, derived: ?Derived, parsed: std.json.Parsed([]JsonNode) };

/// Loads and converts a tree from a JSON file (see the file-format doc
/// comment above `main`) — just reads `path` and hands off to
/// `parseTreeJson`. See `loadNodesFromCommand` for the other source this
/// app reads a tree from.
fn loadNodesFromFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) !LoadedTree {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(contents);
    return parseTreeJson(gpa, contents);
}

/// Runs `command` through the shell (`sh -c`) and parses its stdout as a
/// tree, the same `'cmd |'` convention duckdir.sh's own SQL already uses
/// for shellfs — so `zig build run -- './duckdir.sh ~/repos |'` works the
/// same way a `read_csv('cmd |', ...)` call does there. A non-zero exit
/// prints the command's stderr (otherwise silently lost — this app never
/// has a terminal to show it on once it's in raw mode) and fails loading,
/// rather than trying to parse whatever partial stdout a broken command
/// produced.
fn loadNodesFromCommand(
    io: std.Io,
    gpa: std.mem.Allocator,
    command: []const u8,
) !LoadedTree {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "sh", "-c", command } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exited_cleanly = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_cleanly) {
        std.debug.print("error: command failed: {s}\n{s}", .{ command, result.stderr });
        return error.CommandFailed;
    }

    return parseTreeJson(gpa, result.stdout);
}

/// Parses `contents` (a whole tree.json's worth of bytes, from a file or a
/// launched command's stdout) into nodes/shades/an optional precomputed
/// `Derived` fast path. Caller owns all returned slices/`Derived`; keeps
/// the `std.json.Parsed` wrapper's arena alive for the label strings,
/// which are never copied out of it, so `contents` itself doesn't need to
/// outlive this call.
fn parseTreeJson(
    gpa: std.mem.Allocator,
    contents: []const u8,
) !LoadedTree {
    // `.allocate = .alloc_always` is required, not optional: the default
    // (`.alloc_if_needed`) lets unescaped string fields (every `label` here
    // has no JSON escapes) come back as slices pointing *into `contents`*
    // instead of being copied. Since `contents` is freed the moment this
    // function returns, every label would become a dangling pointer —
    // decoding as garbage bytes wherever it's later rendered (surfaced as
    // literal U+FFFD replacement characters in the terminal).
    const parsed = try std.json.parseFromSlice([]JsonNode, gpa, contents, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();

    // A row with no `value` gets 1 if it's a leaf, 0 if it's a container —
    // never a flat 1 for every row regardless of position. `subtreeTotals`
    // sums each node's own value plus every descendant's, so a container
    // defaulting to 1 would count itself alongside its leaves; defaulting
    // it to 0 (matching this format's own container convention — see the
    // duckdir.sh doc comment) keeps a node's total exactly its leaf count.
    const has_children = try gpa.alloc(bool, parsed.value.len);
    defer gpa.free(has_children);
    @memset(has_children, false);
    for (parsed.value) |jn| {
        if (jn.parent) |p| has_children[p] = true;
    }

    const nodes = try gpa.alloc(Node, parsed.value.len);
    errdefer gpa.free(nodes);
    const shades = try gpa.alloc(u8, parsed.value.len);
    errdefer gpa.free(shades);
    const keys = try gpa.alloc(?[]const u8, parsed.value.len);
    for (parsed.value, 0..) |jn, i| {
        nodes[i] = .{
            .parent = jn.parent orelse NO_PARENT,
            .level = jn.level,
            .value = jn.value orelse if (has_children[i]) 0 else 1,
            .label = jn.label,
        };
        shades[i] = jn.shade orelse 0;
        keys[i] = jn.key;
    }

    // Fast path: when every row already carries `total`/`groups`/`leaves`
    // (duckdir.sh's own SQL computes these now — see its doc comment),
    // skip `computeDerived`'s O(nodes.len) aggregate passes and just copy
    // them in; only `ChildIndex` still has to be built here; it's needed
    // for the interactive per-frame layout regardless of where the
    // aggregates came from. `main` falls back to calling `computeDerived`
    // itself when this is `null` — a hand-authored or otherwise-generated
    // tree.json without these fields still works, just without the
    // load-time speedup.
    var derived: ?Derived = null;
    var all_have_aggregates = true;
    for (parsed.value) |jn| {
        if (jn.total == null or jn.groups == null or jn.leaves == null) {
            all_have_aggregates = false;
            break;
        }
    }
    if (all_have_aggregates) {
        const totals = try gpa.alloc(f64, nodes.len);
        errdefer gpa.free(totals);
        const subtree_groups = try gpa.alloc(usize, nodes.len);
        errdefer gpa.free(subtree_groups);
        const subtree_leaves = try gpa.alloc(usize, nodes.len);
        errdefer gpa.free(subtree_leaves);
        for (parsed.value, 0..) |jn, i| {
            totals[i] = jn.total.?;
            subtree_groups[i] = jn.groups.?;
            subtree_leaves[i] = jn.leaves.?;
        }
        const has_children_owned = try gpa.dupe(bool, has_children);
        errdefer gpa.free(has_children_owned);
        const equal_totals = try gpa.alloc(f64, nodes.len);
        errdefer gpa.free(equal_totals);
        for (nodes, 0..) |_, i| {
            const own: usize = if (has_children_owned[i]) 0 else 1;
            equal_totals[i] = @floatFromInt(subtree_leaves[i] + own);
        }
        const child_index = try tree_lod.buildChildIndex(nodes, gpa);
        derived = .{
            .totals = totals,
            .has_children = has_children_owned,
            .subtree_groups = subtree_groups,
            .subtree_leaves = subtree_leaves,
            .equal_totals = equal_totals,
            .child_index = child_index,
        };
    }

    return .{ .nodes = nodes, .shades = shades, .keys = keys, .derived = derived, .parsed = parsed };
}

/// A small, self-contained fixture used when no file is given on the
/// command line — same shape as demo_readme_tree_fixture.zig, trimmed down.
const default_fixture = [_]Node{
    .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "docs" },
    .{ .parent = 0, .level = 1, .value = 0, .label = "guide" },
    .{ .parent = 1, .level = 2, .value = 120, .label = "intro" },
    .{ .parent = 1, .level = 2, .value = 340, .label = "setup" },
    .{ .parent = 1, .level = 2, .value = 90, .label = "faq" },
    .{ .parent = 0, .level = 1, .value = 0, .label = "api" },
    .{ .parent = 5, .level = 2, .value = 210, .label = "scalar" },
    .{ .parent = 5, .level = 2, .value = 180, .label = "table" },
    .{ .parent = 5, .level = 2, .value = 15, .label = "misc" },
    .{ .parent = 0, .level = 1, .value = 400, .label = "changelog" },
};

/// The narrowest a node's label is still worth showing at — just a bare
/// 1-column sliver (see `drawNodeOrLabel` below). Not `OTHER_LABEL`: this
/// is zigtui's own `setStringTruncated`, which appends a plain "…" to
/// *any* label it has to cut short, real or synthetic — unrelated to
/// which glyph identifies the aggregate itself.
const MIN_LABEL_WIDTH_CELLS: usize = 1;

/// The "other"/fold aggregate's own label — a synthetic bucket standing
/// in for every sibling too small to get its own box (see
/// `tree_lod.layoutTree`'s `other_label` param and `foldedChildren`).
/// `┉` (box drawings light quadruple dash horizontal) rather than "…" so
/// it reads as a distinct kind of thing at a glance, not just another
/// label zigtui's own `setStringTruncated` cut short to fit — that
/// ordinary truncation (any real label too long for its box) still ends
/// in a plain "…", unrelated to this.
const OTHER_LABEL = "┉";

/// The area-cell threshold below which a node folds into "…" instead of
/// getting its own space (see tree_lod.layoutTree). This has to scale with
/// the terminal's actual size to mean anything, and it isn't a flat
/// fraction of the total area either: `layoutTree`'s `area` is a
/// width*height product, but `placeRects` only ever divides ONE axis per
/// level — root's direct children split the width, fully *inheriting*
/// height; their own children split height, fully inheriting width; and so
/// on, alternating. So a level-1 child's actual rendered width only ever
/// comes from `value_share * width` — the height component of its area
/// share is never used as a divisor at all. To guarantee a node gets at
/// least `MIN_LABEL_WIDTH_CELLS` columns once `placeRects` actually divides
/// the width axis, the fold threshold needs to be
/// `MIN_LABEL_WIDTH_CELLS * height`, not a flat constant — a count tuned
/// for one terminal size is either too strict at a bigger terminal or
/// leaves everything invisible at a smaller one. This is exact for
/// even-depth (horizontal) splits and an approximation for odd-depth
/// (vertical) ones, since `layoutTree`/`foldedChildren` take one threshold
/// for the whole traversal, not a value per split axis.
fn minCells(height: u16) usize {
    return MIN_LABEL_WIDTH_CELLS * @as(usize, height);
}

/// The row height `placeRectsWrapped` targets when wrapping a large
/// sibling set. In "containment" style (`AppState.classical_style` false,
/// `borderDepth` returns `tree_lod.ALWAYS_BORDERED`), `interiorRect`
/// (tree_lod.zig) eats 1 cell of border on each side *at every depth*, so
/// a row of height H leaves a node H-2 cells of interior for its own
/// children — meaning the row height directly controls how much of the
/// tree's structure is visible without drilling in further:
///
///   2 (the bare `drawNodeBox` floor): interior = 0 — children invisible.
///   3: interior = 1 — children show as a bare label, never a box.
///   6: interior = 4 — a child gets up to height 4, so *its own* interior
///      is 4-2=2, enough for a real box: two full levels of nesting
///      visible without drilling in, not just one.
///
/// In "classical" style, that -2 only ever happens once, for the root's
/// own children (depth-1 nodes) — depth-1 nodes place *their* children
/// flush, at their own full size, so this budget only really shapes how
/// the root's direct children fit; everything deeper gets whatever its
/// own row's height already was, undiminished.
///
/// 3 is the safe minimum (nothing silently disappears). Larger values
/// trade breadth for depth: `placeRectsWrapped` fits `height/min_row_height`
/// rows, so a taller minimum means fewer, taller rows and fewer top-level
/// items visible per screen — a real cost given this is an interactive
/// drill-down tool where "zoom in for more detail" is always available.
const MIN_ROW_HEIGHT: usize = 5;

/// Rows reserved at the bottom of the terminal for the status bar (selected
/// node's name, its contained group/leaf counts, and its value) — kept out
/// of the treemap's own layout area, rather than folded into the breadcrumb,
/// so the breadcrumb only ever shows the actual navigation path with no
/// "preview of what down/enter would do" suffix duplicating this.
const STATUS_BAR_HEIGHT: u16 = 1;

const AppState = struct {
    nodes: []const Node,
    // Parallel to `nodes` (same length, same indexing) — each entry is 0
    // ("no shade set") or 1..3, read from that row's own `JsonNode.shade`.
    // Kept as a separate array rather than a `Node` field since `Node` is
    // shared with the rest of the extension (tree_lod.zig, comptime
    // function framework, etc.) and shading is purely this tool's own
    // rendering concern.
    shades: []const u8 = &.{},
    // Parallel to `nodes` like `shades` above, same reasoning — a stable
    // identity per node (see `JsonNode.key`'s doc comment) for matching
    // nodes across an independently-reloaded tree, which a future
    // live-reload tween needs since `orig_index` isn't stable across that
    // boundary the way it is across a same-array zoom. `null` entries are
    // normal (most sources don't emit a key yet).
    keys: []const ?[]const u8 = &.{},
    // Cached `Derived` fields (see its own doc comment) — recomputed only
    // when `nodes` itself is reassigned (initial load, or a "…" fold-in
    // splice inside `zoomIn`), never per frame.
    totals: []const f64 = &.{},
    equal_totals: []const f64 = &.{},
    has_children: []const bool = &.{},
    subtree_groups: []const usize = &.{},
    subtree_leaves: []const usize = &.{},
    child_index: tree_lod.ChildIndex = .{ .start = &.{}, .list = &.{} },
    root: usize = 0,
    selected: usize = 0, // index among root's current children, for zoom
    history: std.ArrayList(usize) = .empty, // previous roots, for zoom-out
    // Breadcrumb of labels from the true original root down to the current
    // one, e.g. ["README.md", "list"] displayed as "README.md/list". Kept
    // as its own stack, pushed/popped in lockstep with `history`, rather
    // than derived by walking `.parent` pointers each frame — walking
    // wouldn't work uniformly once a "…" drill-in has spliced in a
    // synthetic root (see `zoomIn` below), since a folded member's
    // `.parent` is deliberately re-pointed at the synthetic root, severing
    // its link back through its true original ancestors.
    path: std.ArrayList([]const u8) = .empty,
    // `selected` defaults to 0, but that's not a real selection until the
    // user actually moves it — without this flag the breadcrumb's "preview
    // the selected child" suffix (see the render pass) would show
    // "README.md/<whatever the first child happens to be>" from the very
    // first frame, before any input at all.
    has_selected: bool = false,
    // For double-click detection: mouse.down doesn't come with a "double"
    // kind of its own, so it's reconstructed from timing + position
    // against the previous click.
    last_click_ts: ?std.Io.Timestamp = null,
    last_click_x: u16 = 0,
    last_click_y: u16 = 0,
    // Status-bar/highlight selection, tracked separately from `selected`
    // (which stays purely "rank among direct children" for down/enter
    // zoom). Holds an *original* node index — `orig_index`, from
    // `LaidOutNode` — rather than a screen position, so it survives
    // relayout: the root's own entry always carries `orig_index == root`
    // (see tree_lod.layoutTree), so this same field and the same
    // by-orig_index lookup in the render pass covers the root, a direct
    // child, or any deeper visible node uniformly, with no special case
    // per kind. `null` for a "…" aggregate (it has no stable original
    // index — see `LaidOutNode.orig_index`'s own doc comment) or for "no
    // selection yet".
    click_selected_orig_index: ?usize = null,
    // Toggled by 'v' (view style). false ("containment"): every interior
    // node at every depth draws its own border and insets its children
    // for it — good for reading the tree structure itself. true
    // ("classical"): only the root (double) and its direct children
    // (heavy) draw borders; only the root insets its own children —
    // depth-1 nodes place *their* children flush against their own
    // border, so a heavy depth-1 edge merges with a lighter child wall
    // touching it (see `drawEntries`'s own doc comment) instead of
    // leaving a gap. Trades containment legibility for giving leaf-size
    // comparison more of the screen, closer to Shneiderman's original
    // treemap. See `borderDepth`.
    classical_style: bool = false,
    // Toggled by 'u' (units). false: every value/size label prints the
    // full number, e.g. "2000000". true (the default): `formatSI` compacts
    // it with an SI-style suffix, e.g. "2M" — much more readable once a
    // subtree total reaches the sizes a real filesystem tree produces
    // (duckdir.sh's own byte sums routinely run into the billions).
    si_units: bool = true,
    // Toggled by 's' (sizing). false: layout uses each leaf's real
    // `value` (`totals`), and leaf boxes/the status bar show it. true:
    // layout uses `equal_totals` instead — every leaf gets the same
    // weight, so leaf area reflects only tree structure (how many
    // siblings it has), not size — and the value label is left blank
    // rather than showing the now-meaningless leaf-count numbers
    // `equal_totals` actually holds. See `activeTotals`.
    equal_weight: bool = false,
    running: bool = true,
    // Set once at startup (see `main`) only when the tree was loaded via a
    // launched command (the trailing-`|` convention), never for a static
    // file or the built-in fixture — a command is, by construction,
    // something that can be re-run to get fresh data; a file just sits
    // there. Its presence alone is what gates the auto-reload check in
    // the main loop; `null` means "never reload". The string itself
    // aliases argv's own backing memory (stable for the process's whole
    // lifetime), not a copy.
    reload_command: ?[]const u8 = null,
    // When the auto-reload check last actually *finished* (not when it
    // started — see the main loop's own comment on why that distinction
    // matters) — compared against the next required-wait each loop
    // iteration. `null` only before the first check.
    last_reload_ts: ?std.Io.Timestamp = null,
    // How long the last reload attempt actually took, wall-clock —
    // scales how long the main loop waits before the next one is "due".
    // 0 before the first attempt, same as a cheap source's own steady-state.
    last_reload_duration_ms: i64 = 0,
    // Toggled by 'p' (pause). Only meaningful alongside `reload_command`
    // being set at all. Lets a "…" fold-in drill-down (which has no
    // identity to survive a reload — see `resolveAcrossReload`'s own doc
    // comment) be inspected for as long as needed instead of resetting on
    // the next scheduled reload.
    reload_paused: bool = false,
};

/// The totals array `layoutTreeWithIndex`/`foldedChildrenWithIndex` should
/// use for the current `AppState.equal_weight` — see its own doc comment.
fn activeTotals(s: *const AppState) []const f64 {
    return if (s.equal_weight) s.equal_totals else s.totals;
}

/// The `border_depth` to pass to `placeRectsWrapped` for the current
/// `AppState.classical_style`. In classical style this is `0`: only the
/// root insets its own children (depth-1 nodes, so they sit cleanly
/// inside its double border); depth-1 nodes *themselves* no longer inset
/// *their* children. A depth-1 group still draws its own heavy border —
/// that's a render-time decision (`drawEntries`'s classical-skip
/// condition), independent of this — but its children now sit flush
/// against that border instead of 1 cell inside it, which is exactly what
/// lets the wall-mask pass merge the heavy depth-1 edge with a lighter
/// child wall touching it (see `drawEntries`'s own doc comment) instead
/// of leaving a visible gap.
fn borderDepth(s: *const AppState) u16 {
    return if (s.classical_style) 0 else tree_lod.ALWAYS_BORDERED;
}

/// Formats `value` as a plain integer, or with an SI-style suffix
/// (K/M/G/T, decimal — 1000-based, not 1024) when `si_units` is set —
/// "2M" instead of "2000000". One decimal place only when the scaled
/// value isn't already a whole number ("1.5K", but "2M" not "2.0M"), so
/// round numbers stay short. Values under 1000 are never suffixed either
/// way, since there's nothing to compact.
fn formatValue(buf: []u8, value: f64, si_units: bool) []const u8 {
    if (!si_units) return std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "";

    const Unit = struct { threshold: f64, suffix: u8 };
    const units = [_]Unit{
        .{ .threshold = 1e12, .suffix = 'T' },
        .{ .threshold = 1e9, .suffix = 'G' },
        .{ .threshold = 1e6, .suffix = 'M' },
        .{ .threshold = 1e3, .suffix = 'K' },
    };
    const abs_value = @abs(value);
    for (units) |u| {
        if (abs_value < u.threshold) continue;
        const scaled = @round(value / u.threshold * 10) / 10; // 1 decimal of precision
        if (scaled == @round(scaled)) {
            return std.fmt.bufPrint(buf, "{d:.0}{c}", .{ scaled, u.suffix }) catch "";
        }
        return std.fmt.bufPrint(buf, "{d:.1}{c}", .{ scaled, u.suffix }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "";
}

/// "" for 0/out-of-range (no shade set — see `JsonNode.shade`'s own doc
/// comment), otherwise the 1..3 bucket spelled out as low/medium/high
/// rather than the raw number, matching the darkening fill density
/// (`LEAF_FILL_CHARS`) a leaf box already shows for the same value.
fn shadeLabel(shades: []const u8, orig_index: usize) []const u8 {
    if (orig_index == NO_PARENT or orig_index >= shades.len) return "";
    return switch (shades[orig_index]) {
        1 => "  shade=low",
        2 => "  shade=medium",
        3 => "  shade=high",
        else => "",
    };
}

/// Shared by the main per-frame render and `animateReload`'s own tween
/// frames (see `buildStatusLine`'s own doc comment for why both need
/// this) — a tiny ASCII liveness/pause indicator for the status bar's far
/// right. "" when the tree wasn't loaded from a live command at all (no
/// "connection" to indicate — see `AppState.reload_command`'s own doc
/// comment), a static "[PAUSED]" while paused ('p' — `reload_paused`), or
/// else a slowly-cycling classic ASCII spinner (`-\|/`, not any of this
/// app's own Unicode box-drawing glyphs, so it reads unambiguously as "a
/// different kind of indicator" at a glance) tied to wall-clock time —
/// continuing to change frame to frame is itself the signal that the
/// reload loop is still alive, not stuck.
fn connectionIndicator(s: *const AppState, elapsed_ms: i64) []const u8 {
    if (s.reload_command == null) return "";
    if (s.reload_paused) return "[PAUSED]";
    const frames = [_][]const u8{ "-", "\\", "|", "/" };
    const idx: usize = @intCast(@mod(@divFloor(elapsed_ms, 200), frames.len));
    return frames[idx];
}

/// Builds the status-bar text for whichever node is currently selected
/// (`AppState.click_selected_orig_index`, falling back to `.selected`'s
/// ranked child — same two-step lookup the render pass always used), now
/// shared with `animateReload`'s tween frames instead of being inlined
/// only in the main render: a tween frame that never drew a status line
/// at all left the *previous* one on screen with nothing underneath it in
/// the new buffer, which erased it for the tween's duration rather than
/// merely leaving it stale — the same class of "vanishes instead of just
/// not updating" bug already fixed for the root/breadcrumb/"…" cases.
/// Returns "" exactly when the original inline logic did (nothing
/// selected, or a `laid_out` that doesn't contain the selection this
/// frame — e.g. a selected node that isn't one of a reload tween's
/// matched entries this particular step).
fn buildStatusLine(s: *const AppState, laid_out: []const LaidOutNode, buf: []u8) []const u8 {
    var selected_node: ?LaidOutNode = null;
    if (s.click_selected_orig_index) |sel_idx| {
        for (laid_out) |n| {
            if (n.orig_index == sel_idx) {
                selected_node = n;
                break;
            }
        }
    }
    if (selected_node == null and s.has_selected) {
        var rank: usize = 0;
        for (laid_out) |n| {
            if (n.level != 1) continue;
            if (rank == s.selected) {
                selected_node = n;
                break;
            }
            rank += 1;
        }
    }
    const sel = selected_node orelse return "";
    if (sel.orig_index == NO_PARENT or sel.orig_index >= s.subtree_groups.len) return sel.label;

    const idx = sel.orig_index;
    const shade_str = shadeLabel(s.shades, idx);
    if (s.equal_weight) {
        // Blank value, same reasoning as the leaf box's own value label:
        // `sel.value` here is the synthetic equal-weight number, not a
        // real size.
        return std.fmt.bufPrint(
            buf,
            "{s}  (G{d},L{d}){s}",
            .{ sel.label, s.subtree_groups[idx], s.subtree_leaves[idx], shade_str },
        ) catch "";
    }
    var value_buf: [32]u8 = undefined;
    const value_str = formatValue(&value_buf, sel.value, s.si_units);
    return std.fmt.bufPrint(
        buf,
        "{s}  (G{d},L{d})  value={s}{s}",
        .{ sel.label, s.subtree_groups[idx], s.subtree_leaves[idx], value_str, shade_str },
    ) catch "";
}

/// Draws the status bar row: `text` left-aligned, `indicator` (see
/// `connectionIndicator`) right-aligned in the same row with a 1-cell gap
/// — `text` is truncated to make room rather than letting the two
/// overlap. A no-op if `indicator` is empty beyond the plain truncated
/// `text` draw, so callers never need their own branch for "not in live
/// mode".
fn drawStatusBar(buf: *Buffer, x: u16, y: u16, width: u16, text: []const u8, indicator: []const u8) void {
    if (indicator.len == 0) {
        buf.setStringTruncated(x, y, text, width, Style{});
        return;
    }
    const indicator_w: u16 = @intCast(@min(indicator.len, width));
    const text_w = width -| (indicator_w + 1);
    buf.setStringTruncated(x, y, text, text_w, Style{});
    buf.setStringTruncated(x + width - indicator_w, y, indicator, indicator_w, Style{});
}

/// Resolves "the currently selected node" the same way the status bar
/// does (see its own comment in the render pass) — `click_selected_orig_index`
/// first, falling back to the rank-based keyboard selection — but returns
/// a position *into* `laid_out` (so callers can read `.orig_index` for the
/// underlying tree, or index a parallel `rects` array for on-screen
/// geometry) rather than the `LaidOutNode` itself.
fn findSelectedIndex(s: *const AppState, laid_out: []const LaidOutNode) ?usize {
    if (s.click_selected_orig_index) |sel_idx| {
        for (laid_out, 0..) |n, i| {
            if (n.orig_index == sel_idx) return i;
        }
    }
    if (s.has_selected) {
        var rank: usize = 0;
        for (laid_out, 0..) |n, i| {
            if (n.level != 1) continue;
            if (rank == s.selected) return i;
            rank += 1;
        }
    }
    return null;
}

/// Best-effort: writes `ESC ] 52 ; c ; <base64> BEL` (OSC 52) directly to
/// the raw terminal stream — the standard terminal-level "set system
/// clipboard" escape, honored locally and over SSH by most modern
/// terminals (iTerm2, kitty, WezTerm, Windows Terminal, tmux with
/// passthrough enabled, …) with no external clipboard tool
/// (`xclip`/`wl-copy`/`pbcopy`, which vary by platform and may not even be
/// installed) needed. Silently no-ops on any failure — a clipboard write
/// is never worth crashing the app or interrupting the render loop over.
fn oscCopyToClipboard(gpa: std.mem.Allocator, be: tui.Backend, text: []const u8) void {
    const b64_len = std.base64.standard.Encoder.calcSize(text.len);
    const b64 = gpa.alloc(u8, b64_len) catch return;
    defer gpa.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, text);

    const seq = std.fmt.allocPrint(gpa, "\x1b]52;c;{s}\x07", .{b64}) catch return;
    defer gpa.free(seq);
    be.write(seq) catch return;
    be.flush() catch return;
}

/// 'c': copies the selected node's currently-rendered on-screen box, row
/// by row, exactly as it looks right now — a plain-text snapshot of its
/// glyphs (box-drawing borders included), read straight back out of the
/// terminal buffer rather than re-rendered at some other size.
fn copyVisualToClipboard(gpa: std.mem.Allocator, be: tui.Backend, buf: *Buffer, rect: Rect) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var y = rect.y;
    while (y < rect.y + rect.h) : (y += 1) {
        var x = rect.x;
        while (x < rect.x + rect.w) : (x += 1) {
            const ch: u21 = if (buf.get(@intCast(x), @intCast(y))) |cell| cell.char else ' ';
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(ch, &enc) catch continue;
            text.appendSlice(gpa, enc[0..n]) catch return;
        }
        text.append(gpa, '\n') catch return;
    }
    oscCopyToClipboard(gpa, be, text.items);
}

/// 'd': copies the selected node's own subtree — itself plus every
/// descendant — as a JSON array in the same `{parent,level,value,label}`
/// shape `loadNodesFromFile` reads (see the file-format doc comment above
/// `main`), `parent` re-indexed to the subtree's own 0-based numbering
/// (the root's own parent becomes `null`) so the result is a standalone,
/// reloadable tree.json on its own — `zig build run -- <path>` on
/// whatever this pastes to should show exactly this subtree, re-rooted.
/// Relies on `parent[i] < i`, same as `subtreeTotals`: one forward pass
/// from `root_idx` classifies every descendant, since a node's parent is
/// always already classified by the time its own turn comes up.
fn copySubtreeToClipboard(gpa: std.mem.Allocator, be: tui.Backend, nodes: []const Node, root_idx: usize) void {
    const in_subtree = gpa.alloc(bool, nodes.len) catch return;
    defer gpa.free(in_subtree);
    @memset(in_subtree, false);
    in_subtree[root_idx] = true;
    for (nodes, 0..) |n, i| {
        if (i > root_idx and n.parent != NO_PARENT and in_subtree[n.parent]) in_subtree[i] = true;
    }

    const new_index = gpa.alloc(usize, nodes.len) catch return;
    defer gpa.free(new_index);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    text.append(gpa, '[') catch return;
    var count: usize = 0;
    for (nodes, 0..) |n, i| {
        if (!in_subtree[i]) continue;
        new_index[i] = count;
        if (count > 0) text.append(gpa, ',') catch return;

        var head_buf: [96]u8 = undefined;
        const head = if (i == root_idx)
            std.fmt.bufPrint(&head_buf, "{{\"parent\":null,\"level\":{d},\"value\":{d:.0},\"label\":\"", .{ n.level, n.value }) catch return
        else
            std.fmt.bufPrint(&head_buf, "{{\"parent\":{d},\"level\":{d},\"value\":{d:.0},\"label\":\"", .{ new_index[n.parent], n.level, n.value }) catch return;
        text.appendSlice(gpa, head) catch return;
        for (n.label) |ch| {
            if (ch == '"' or ch == '\\') text.append(gpa, '\\') catch return;
            text.append(gpa, ch) catch return;
        }
        text.appendSlice(gpa, "\"}") catch return;
        count += 1;
    }
    text.append(gpa, ']') catch return;
    oscCopyToClipboard(gpa, be, text.items);
}

const DOUBLE_CLICK_MS: i64 = 400;

/// Re-roots at `chosen` — the same action whether it came from pressing
/// down/enter on the selected sibling or double-clicking a node directly:
/// both ultimately just need a `LaidOutNode` to zoom into. `laid_out` is
/// only needed to resolve a "…" fold's *immediate* parent — for a
/// keyboard-driven zoom that's always the current root (selection only
/// ever lands on a root's direct child), but a mouse click can land on a
/// "…" nested several levels deep, whose immediate parent isn't `state.root`.
fn zoomIn(
    allocator: std.mem.Allocator,
    frame_alloc: std.mem.Allocator,
    state: *AppState,
    owned_nodes: *?[]Node,
    owned_shades: *?[]u8,
    owned_keys: *?[]?[]const u8,
    owned_derived: *?Derived,
    laid_out: []const LaidOutNode,
    totals: []const f64,
    area_cells: usize,
    min_cells: usize,
    chosen: LaidOutNode,
) !void {
    if (chosen.orig_index != NO_PARENT) {
        try state.history.append(allocator, state.root);
        try state.path.append(allocator, chosen.label);
        state.root = chosen.orig_index;
        state.selected = 0;
        state.click_selected_orig_index = null;
        return;
    }

    // Selected/clicked entry is the "…" fold — there is no single node to
    // re-root at, so recover exactly which original children it stands
    // for and splice in a synthetic root that re-parents just that
    // subset. Every other node's parent pointer only shifts by +1 to make
    // room; the rest of navigation (further zoom, zoom back out via
    // history) works on the result completely unchanged, since it's still
    // just a self-consistent tabular tree.
    const parent_node_idx = laid_out[chosen.parent].orig_index;
    const members = try tree_lod.foldedChildrenWithIndex(totals, state.child_index, parent_node_idx, area_cells, min_cells, frame_alloc);
    if (members.len == 0) return;

    const new_nodes = try allocator.alloc(Node, state.nodes.len + 1);
    new_nodes[0] = .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = OTHER_LABEL };
    for (state.nodes, 0..) |n, i| {
        new_nodes[i + 1] = .{
            .parent = if (n.parent == NO_PARENT) NO_PARENT else n.parent + 1,
            .level = n.level,
            .value = n.value,
            .label = n.label,
        };
    }
    for (members) |m| new_nodes[m + 1].parent = 0;

    if (owned_nodes.*) |old| allocator.free(old);
    owned_nodes.* = new_nodes;
    state.nodes = new_nodes;

    // Shift `shades` the same way, in lockstep with `new_nodes` above — the
    // synthetic "…" root gets no shade (0), and every original row's shade
    // (or 0 if `state.shades` doesn't cover it, e.g. the built-in fixture)
    // moves to the same +1 offset its node did.
    const new_shades = try allocator.alloc(u8, new_nodes.len);
    new_shades[0] = 0;
    for (0..state.nodes.len - 1) |i| {
        new_shades[i + 1] = if (i < state.shades.len) state.shades[i] else 0;
    }
    if (owned_shades.*) |old| allocator.free(old);
    owned_shades.* = new_shades;
    state.shades = new_shades;

    // Same reindex again for `keys` — the synthetic "…" root has no
    // source row, so no key either.
    const new_keys = try allocator.alloc(?[]const u8, new_nodes.len);
    new_keys[0] = null;
    for (0..state.nodes.len - 1) |i| {
        new_keys[i + 1] = if (i < state.keys.len) state.keys[i] else null;
    }
    if (owned_keys.*) |old| allocator.free(old);
    owned_keys.* = new_keys;
    state.keys = new_keys;

    // `Derived` (totals + group/leaf tallies) has to be recomputed from
    // scratch here — unlike `shades`, it's not a simple reindex, since the
    // synthetic root and the re-parented fold members change subtree
    // membership itself. This is the *only* place it's ever recomputed
    // outside the initial load, so it stays off the per-frame hot path.
    const new_derived = try computeDerived(new_nodes, allocator);
    if (owned_derived.*) |old| old.deinit(allocator);
    owned_derived.* = new_derived;
    state.totals = new_derived.totals;
    state.equal_totals = new_derived.equal_totals;
    state.has_children = new_derived.has_children;
    state.subtree_groups = new_derived.subtree_groups;
    state.subtree_leaves = new_derived.subtree_leaves;
    state.child_index = new_derived.child_index;

    // Every existing index (current root, and every entry already in
    // history) refers to the old array — shift by one to stay valid now
    // that the synthetic root sits at position 0.
    state.root += 1;
    for (state.history.items) |*h| h.* += 1;

    try state.history.append(allocator, state.root);
    try state.path.append(allocator, OTHER_LABEL);
    state.root = 0;
    state.selected = 0;
    state.click_selected_orig_index = null;
}

/// Zooms back out to the previous root, whether triggered by up/backspace
/// or by clicking the breadcrumb.
fn zoomOut(
    frame_alloc: std.mem.Allocator,
    state: *AppState,
    totals: []const f64,
    area_cells: usize,
    min_cells: usize,
) !void {
    const prev = state.history.pop() orelse return;
    // The node we're zooming out *of* — restore selection to it among the
    // new root's direct children, so drilling down then immediately going
    // back up leaves the same node selected, instead of always resetting
    // to the first child.
    const came_from = state.root;
    state.root = prev;
    state.selected = 0;
    state.click_selected_orig_index = null;
    if (state.path.items.len > 1) _ = state.path.pop(); // keep the true root's own segment

    const parent_laid_out = tree_lod.layoutTreeWithIndex(state.nodes, totals, state.child_index, state.root, area_cells, 3, min_cells, OTHER_LABEL, frame_alloc) catch &.{};
    var rank: usize = 0;
    for (parent_laid_out) |n| {
        if (n.level != 1) continue;
        if (n.orig_index == came_from) {
            state.selected = rank;
            break;
        }
        rank += 1;
    }
}

/// Jumps straight back to the true original root, collapsing the whole
/// history stack in one go — used for double-clicking the breadcrumb, as
/// opposed to a single click's one-step zoomOut. `history.items[0]` is
/// always the true root's own index at the time it was first zoomed away
/// from (every subsequent push only ever adds intermediate roots on top),
/// so it's already exactly what's needed here, "…" drill-ins included.
fn zoomToRoot(state: *AppState) void {
    if (state.history.items.len == 0) return;
    state.root = state.history.items[0];
    state.history.clearRetainingCapacity();
    if (state.path.items.len > 1) state.path.shrinkRetainingCapacity(1);
    state.selected = 0;
    state.click_selected_orig_index = null;
}

/// Maps each index in `old_keys` to its counterpart in `new_keys` sharing
/// the same key string — the core of diffing two independently-loaded
/// trees across a live reload (see `JsonNode.key`'s doc comment for why
/// `orig_index` alone can't do this the way it does across a same-array
/// zoom). `result[i]` is `null` when `old_keys[i]` is itself `null` (no
/// identity to match on) or when that key doesn't appear anywhere in
/// `new_keys` (the node didn't survive the reload — a file deleted, a
/// process that exited). Caller owns the returned slice.
///
/// Swap the argument order to get the reverse (new -> old) direction —
/// e.g. for a future reload-tween, which needs "what was this *new*
/// node's old rect, if any" rather than what this is built for here
/// (remapping `AppState`'s own old indices forward).
///
/// A key repeated within `new_keys` resolves to its last occurrence.
/// Neither `tree_scan.sql` nor `ps_scan.sql` can produce that (their keys
/// are built to be unique — a filesystem path, a pid), so this is a
/// silent best-effort fallback for a malformed source, not a case either
/// macro is expected to hit.
fn matchByKey(gpa: std.mem.Allocator, old_keys: []const ?[]const u8, new_keys: []const ?[]const u8) ![]?usize {
    var index = std.StringHashMap(usize).init(gpa);
    defer index.deinit();
    for (new_keys, 0..) |k, i| {
        if (k) |key| try index.put(key, i);
    }

    const result = try gpa.alloc(?usize, old_keys.len);
    for (old_keys, 0..) |k, i| {
        result[i] = if (k) |key| index.get(key) else null;
    }
    return result;
}

/// Resolves `old_idx` (an index into the *old* tree) to its counterpart in
/// the *new* one, falling back to the nearest surviving ancestor — walking
/// `old_nodes[...].parent` — when the node itself has no match in
/// `old_to_new` (see `matchByKey`): a directory that got deleted, a
/// process that exited between samples. Falls all the way back to the
/// true root (index `0`, always the root in both trees — see
/// `tree_scan.sql`/`ps_scan.sql`'s own `ORDER BY length(key), key`
/// convention) when nothing in the chain survived either, which also
/// covers `old_idx` naming a synthetic "…" fold-in root: that node's own
/// `.parent` is `NO_PARENT` and it never had a key (see `zoomIn`'s
/// fold-in branch), so the loop ends immediately and falls through to the
/// true root — there's no way to reconstruct an equivalent fold against
/// the new tree's own (possibly quite different) size distribution, so a
/// reload while drilled into a "…" aggregate intentionally resets to the
/// true root rather than guessing.
fn resolveAcrossReload(old_nodes: []const Node, old_to_new: []const ?usize, old_idx: usize) usize {
    var idx = old_idx;
    while (idx != NO_PARENT) {
        if (old_to_new[idx]) |new_idx| return new_idx;
        idx = old_nodes[idx].parent;
    }
    return 0;
}

/// Rewires `state`'s identity-dependent fields — `root`, `history`,
/// `click_selected_orig_index`, `path` — after a live reload has already
/// swapped in `state.nodes`/`.keys` for a freshly-loaded tree, so the
/// user's drill-down location and highlight survive a refresh instead of
/// snapping back to the true root every tick. `old_nodes`/`old_keys` must
/// be the tree exactly as it was *before* that swap (the caller has to
/// hang onto them long enough to pass in here, then free them itself).
///
/// `selected` (rank among the new root's own direct children — see its
/// own doc comment) is reset to `0` rather than carried forward: that
/// ranking is recomputed from a fresh layout on the very next frame
/// regardless, and "same rank" has no stable meaning when the child list
/// itself may have reordered or changed size across the reload.
/// `has_selected`/`classical_style`/`si_units`/`equal_weight` aren't
/// touched at all — exactly like `zoomIn`'s own field-by-field updates,
/// this never reconstructs `state.*` wholesale, so any field it doesn't
/// explicitly mention is untouched by construction, not by special-casing
/// each one here.
///
/// `path` is rebuilt from scratch rather than remapped in place: its old
/// entries are label slices from the *old* loaded tree (ultimately the
/// old JSON parse's own arena, for a command/file source), which the
/// caller is about to free once this returns — keeping them would leave
/// `path` holding dangling slices. Every position in the old root/history
/// chain already resolved to a real new index via `resolveAcrossReload`
/// (worst case, the true root), so re-reading each one's label from
/// `state.nodes` (already the *new* array by this point) is both safe
/// and simpler than trying to carry the old text forward.
fn remapStateAfterReload(
    gpa: std.mem.Allocator,
    state: *AppState,
    old_nodes: []const Node,
    old_keys: []const ?[]const u8,
) !void {
    // A synthetic "…" fold-in root (`zoomIn`'s fold branch) has no key AND
    // no parent to walk up to, by construction — exactly like the *true*
    // root, which also always has `parent == NO_PARENT` and (per both SQL
    // macros' convention) no key either. `resolveAcrossReload` can't tell
    // these apart: both independently fall back to the same sentinel (0),
    // whether the entry being resolved is `state.root` itself or a stale
    // `history` entry left over from drilling into the fold. Unhandled,
    // that means a history entry can *silently* resolve to the same index
    // `state.root` already resolved to — observed concretely as the root's
    // own label appearing twice ("processes/processes"), since the
    // path-rebuild loop below has no way to know that entry no longer
    // represents a real, distinct drill-down step.
    //
    // `label == OTHER_LABEL` is what actually distinguishes a synthetic
    // fold root from the true root — a real source row's label is never
    // literally equal to it. Rather than patch a chain that's lost its one
    // unrecoverable link, treat any synthetic root anywhere in the old
    // root+history chain as "this whole drill-down session is gone" and
    // reset outright, the same thing `zoomToRoot` already does for a
    // deliberate jump back — a reload while drilled into (or past) a "…"
    // fold has no equivalent to reconstruct in the new tree's own, quite
    // possibly different, size distribution anyway (see
    // `resolveAcrossReload`'s own doc comment).
    const is_synthetic_fold_root = struct {
        fn f(nodes: []const Node, idx: usize) bool {
            return idx < nodes.len and nodes[idx].parent == NO_PARENT and std.mem.eql(u8, nodes[idx].label, OTHER_LABEL);
        }
    }.f;
    var chain_has_synthetic = is_synthetic_fold_root(old_nodes, state.root);
    for (state.history.items) |h| {
        if (is_synthetic_fold_root(old_nodes, h)) chain_has_synthetic = true;
    }
    if (chain_has_synthetic) {
        state.root = 0;
        state.history.clearRetainingCapacity();
        state.path.clearRetainingCapacity();
        try state.path.append(gpa, state.nodes[0].label);
        state.click_selected_orig_index = null;
        state.selected = 0;
        return;
    }

    const old_to_new = try matchByKey(gpa, old_keys, state.keys);
    defer gpa.free(old_to_new);

    const old_root = state.root;
    const old_history = try gpa.dupe(usize, state.history.items);
    defer gpa.free(old_history);

    state.history.clearRetainingCapacity();
    for (old_history) |h| {
        try state.history.append(gpa, resolveAcrossReload(old_nodes, old_to_new, h));
    }
    state.root = resolveAcrossReload(old_nodes, old_to_new, old_root);

    // `path[0]` is always the true original root's own label — a
    // permanent baseline segment pushed once at startup (`main`) and
    // never popped by `zoomOut` (`if (path.items.len > 1) pop()`
    // specifically protects it). It is *not* derived from `history`: with
    // an empty history (never drilled down — the common case right after
    // startup, and for every reload tick until the user actually zooms
    // in), the loop below contributes nothing, and without this line
    // `path` would end up completely empty instead of keeping that one
    // permanent segment — the root's own breadcrumb/border label
    // vanishing after the very first reload, not just during its tween.
    state.path.clearRetainingCapacity();
    try state.path.append(gpa, state.nodes[0].label);
    for (0..state.history.items.len) |i| {
        const next = if (i + 1 < state.history.items.len) state.history.items[i + 1] else state.root;
        try state.path.append(gpa, state.nodes[next].label);
    }

    if (state.click_selected_orig_index) |sel| {
        state.click_selected_orig_index = resolveAcrossReload(old_nodes, old_to_new, sel);
    }
    state.selected = 0;
}

const testing = std.testing;

test "zoomToRoot collapses a multi-level history stack in one call, unlike zoomOut" {
    // root(0) -> a(1) -> b(2), a straight 3-node chain so each level's
    // "direct child" is unambiguous.
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a" },
        .{ .parent = 1, .level = 2, .value = 5, .label = "b" },
    };
    var totals: [3]f64 = undefined;
    tree_lod.subtreeTotals(&nodes, &totals);
    const child_index = try tree_lod.buildChildIndex(&nodes, testing.allocator);
    defer child_index.deinit(testing.allocator);

    var state = AppState{ .nodes = &nodes, .child_index = child_index };
    defer state.history.deinit(testing.allocator);
    defer state.path.deinit(testing.allocator);
    try state.path.append(testing.allocator, nodes[0].label);

    var owned_nodes: ?[]Node = null;
    defer if (owned_nodes) |n| testing.allocator.free(n);
    var owned_shades: ?[]u8 = null;
    defer if (owned_shades) |s| testing.allocator.free(s);
    var owned_keys: ?[]?[]const u8 = null;
    defer if (owned_keys) |k| testing.allocator.free(k);
    var owned_derived: ?Derived = null;
    defer if (owned_derived) |d| d.deinit(testing.allocator);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frame_alloc = arena.allocator();

    // Zoom in twice: root -> a -> b. This is exactly what two separate
    // double-clicks (or down/enter presses) produce — two history pushes,
    // not one.
    const laid_out1 = try tree_lod.layoutTree(&nodes, &totals, 0, 100, 3, 1, OTHER_LABEL, frame_alloc);
    try zoomIn(testing.allocator, frame_alloc, &state, &owned_nodes, &owned_shades, &owned_keys, &owned_derived, laid_out1, &totals, 100, 1, laid_out1[1]);
    try testing.expectEqual(@as(usize, 1), state.root);
    try testing.expectEqual(@as(usize, 1), state.history.items.len);

    const laid_out2 = try tree_lod.layoutTree(state.nodes, &totals, state.root, 100, 3, 1, OTHER_LABEL, frame_alloc);
    try zoomIn(testing.allocator, frame_alloc, &state, &owned_nodes, &owned_shades, &owned_keys, &owned_derived, laid_out2, &totals, 100, 1, laid_out2[1]);
    try testing.expectEqual(@as(usize, 2), state.root);
    try testing.expectEqual(@as(usize, 2), state.history.items.len);
    try testing.expectEqual(@as(usize, 3), state.path.items.len); // root, a, b

    // zoomOut (single click on breadcrumb / up key) only pops ONE level.
    try zoomOut(frame_alloc, &state, &totals, 100, 1);
    try testing.expectEqual(@as(usize, 1), state.root); // back at "a", not "root"
    try testing.expectEqual(@as(usize, 1), state.history.items.len);

    // Re-zoom back in to rebuild a 2-deep stack, then confirm zoomToRoot
    // (right-click on breadcrumb) collapses it all in ONE call.
    const laid_out3 = try tree_lod.layoutTree(state.nodes, &totals, state.root, 100, 3, 1, OTHER_LABEL, frame_alloc);
    try zoomIn(testing.allocator, frame_alloc, &state, &owned_nodes, &owned_shades, &owned_keys, &owned_derived, laid_out3, &totals, 100, 1, laid_out3[1]);
    try testing.expectEqual(@as(usize, 2), state.history.items.len);

    zoomToRoot(&state);
    try testing.expectEqual(@as(usize, 0), state.root);
    try testing.expectEqual(@as(usize, 0), state.history.items.len);
    try testing.expectEqual(@as(usize, 1), state.path.items.len);
    try testing.expectEqualStrings("root", state.path.items[0]);
}

test "zoomToRoot on a fresh, never-zoomed state is a safe no-op" {
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
    };
    var state = AppState{ .nodes = &nodes };
    defer state.history.deinit(testing.allocator);
    defer state.path.deinit(testing.allocator);
    try state.path.append(testing.allocator, nodes[0].label);

    zoomToRoot(&state); // history is empty — must not underflow/crash
    try testing.expectEqual(@as(usize, 0), state.root);
    try testing.expectEqual(@as(usize, 1), state.path.items.len);
}

test "matchByKey matches by key string, nulls and misses resolve to null" {
    const old_keys = [_]?[]const u8{ "root", "root/a", "root/a/b", null };
    const new_keys = [_]?[]const u8{ "root/x", "root", "root/a" };
    const result = try matchByKey(testing.allocator, &old_keys, &new_keys);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(?usize, 1), result[0]); // "root" moved to new idx 1
    try testing.expectEqual(@as(?usize, 2), result[1]); // "root/a" moved to new idx 2
    try testing.expectEqual(@as(?usize, null), result[2]); // "root/a/b" no longer exists
    try testing.expectEqual(@as(?usize, null), result[3]); // no key to match on at all
}

test "resolveAcrossReload walks up to the nearest surviving ancestor, falling back to the true root" {
    // root(0) -> a(1) -> b(2); "b" vanishes in the new tree but "a" (now
    // relabeled "A", same key) survives at a different index — and a
    // fourth, disconnected node simulates a "…" fold-in root: no key of
    // its own, parent already NO_PARENT, so nothing to walk up to.
    const old_nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a" },
        .{ .parent = 1, .level = 2, .value = 5, .label = "b" },
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = OTHER_LABEL },
    };
    const old_keys = [_]?[]const u8{ "root", "root/a", "root/a/b", null };
    const new_keys = [_]?[]const u8{ "root", "root/x", "root/a" };
    const old_to_new = try matchByKey(testing.allocator, &old_keys, &new_keys);
    defer testing.allocator.free(old_to_new);

    try testing.expectEqual(@as(usize, 0), resolveAcrossReload(&old_nodes, old_to_new, 0)); // direct hit
    try testing.expectEqual(@as(usize, 2), resolveAcrossReload(&old_nodes, old_to_new, 1)); // direct hit, new position
    try testing.expectEqual(@as(usize, 2), resolveAcrossReload(&old_nodes, old_to_new, 2)); // miss -> falls back to "a"
    try testing.expectEqual(@as(usize, 0), resolveAcrossReload(&old_nodes, old_to_new, 3)); // no key, no parent -> true root
}

test "remapStateAfterReload rewires root/history/path/selection by key, not array position" {
    // Same root(0) -> a(1) -> b(2) chain, drilled into "a" with "b"
    // highlighted. The reload reorders the array, renames "a" to "A" (key
    // unchanged), and drops "b" entirely.
    const old_nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "a" },
        .{ .parent = 1, .level = 2, .value = 5, .label = "b" },
    };
    const old_keys = [_]?[]const u8{ "root", "root/a", "root/a/b" };
    const new_nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "x" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "A" },
    };
    const new_keys = [_]?[]const u8{ "root", "root/x", "root/a" };

    var state = AppState{ .nodes = &old_nodes, .keys = &old_keys, .root = 1, .click_selected_orig_index = 2 };
    defer state.history.deinit(testing.allocator);
    defer state.path.deinit(testing.allocator);
    try state.history.append(testing.allocator, 0);
    try state.path.append(testing.allocator, old_nodes[1].label);

    // The (not-yet-built) reload call site swaps these in before fixing up
    // the rest — mirrored here rather than calling through `main`'s own
    // loader, which this test has no JSON/command source to feed.
    state.nodes = &new_nodes;
    state.keys = &new_keys;

    try remapStateAfterReload(testing.allocator, &state, &old_nodes, &old_keys);

    try testing.expectEqual(@as(usize, 2), state.root); // "a"/"A" is now at index 2
    try testing.expectEqual(@as(usize, 1), state.history.items.len);
    try testing.expectEqual(@as(usize, 0), state.history.items[0]); // "root" unchanged at index 0
    try testing.expectEqual(@as(usize, 2), state.path.items.len);
    try testing.expectEqualStrings("root", state.path.items[0]); // permanent true-root segment, not derived from history
    try testing.expectEqualStrings("A", state.path.items[1]); // rebuilt from the *new* label
    try testing.expectEqual(@as(?usize, 2), state.click_selected_orig_index); // "b" gone -> falls back to "A"
    try testing.expectEqual(@as(usize, 0), state.selected);
}

test "remapStateAfterReload keeps the true root's own breadcrumb segment when never drilled down" {
    // Reproduces the bug directly: an empty `history` (the common case —
    // right after startup, and on every reload tick until the user
    // actually zooms in) must not leave `path` empty.
    const old_nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "processes" },
    };
    const old_keys = [_]?[]const u8{null};
    const new_nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "processes" },
    };
    const new_keys = [_]?[]const u8{null};

    var state = AppState{ .nodes = &old_nodes, .keys = &old_keys };
    defer state.history.deinit(testing.allocator);
    defer state.path.deinit(testing.allocator);
    try state.path.append(testing.allocator, old_nodes[0].label);

    state.nodes = &new_nodes;
    state.keys = &new_keys;

    try remapStateAfterReload(testing.allocator, &state, &old_nodes, &old_keys);

    try testing.expectEqual(@as(usize, 1), state.path.items.len);
    try testing.expectEqualStrings("processes", state.path.items[0]);
}

test "remapStateAfterReload resets wholesale (no duplicated root label) after drilling into a \"…\" fold" {
    // Reproduces the exact reported bug: drill into a "…" fold-in
    // aggregate (zoomIn's fold branch splices a synthetic root at index 0,
    // shifts everything else +1, pushes the *shifted* true root onto
    // history, and pushes OTHER_LABEL onto path), then reload. The
    // synthetic root and the shifted-but-still-keyless true root are
    // indistinguishable to a plain key/ancestor resolve, so without the
    // synthetic-chain detection this produced path == ["processes",
    // "processes"] instead of correctly collapsing back to ["processes"].
    const old_nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = OTHER_LABEL }, // synthetic fold root
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "processes" }, // true root, shifted +1
        .{ .parent = 0, .level = 1, .value = 1, .label = "a" },
        .{ .parent = 0, .level = 1, .value = 1, .label = "b" },
    };
    const old_keys = [_]?[]const u8{ null, null, "a", "b" };
    const new_nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "processes" },
        .{ .parent = 0, .level = 1, .value = 1, .label = "a" },
        .{ .parent = 0, .level = 1, .value = 1, .label = "b" },
    };
    const new_keys = [_]?[]const u8{ null, "a", "b" };

    var state = AppState{ .nodes = &old_nodes, .keys = &old_keys, .root = 0 };
    defer state.history.deinit(testing.allocator);
    defer state.path.deinit(testing.allocator);
    try state.history.append(testing.allocator, 1); // the shifted true root
    try state.path.append(testing.allocator, "processes");
    try state.path.append(testing.allocator, OTHER_LABEL);

    state.nodes = &new_nodes;
    state.keys = &new_keys;

    try remapStateAfterReload(testing.allocator, &state, &old_nodes, &old_keys);

    try testing.expectEqual(@as(usize, 0), state.root);
    try testing.expectEqual(@as(usize, 0), state.history.items.len);
    try testing.expectEqual(@as(usize, 1), state.path.items.len);
    try testing.expectEqualStrings("processes", state.path.items[0]);
}

test "resolveWallConflicts: heavy wins over light on the same direction" {
    try testing.expectEqual(@as(u4, 0), resolveWallConflicts(WALL_DOWN, WALL_LEFT | WALL_RIGHT | WALL_DOWN));
    try testing.expectEqual(@as(u4, WALL_DOWN), resolveWallConflicts(WALL_DOWN, WALL_LEFT | WALL_RIGHT));
    try testing.expectEqual(@as(u4, 0), resolveWallConflicts(0, WALL_UP));
}

test "combinedWallGlyph: pure light or pure heavy match the plain tables" {
    try testing.expectEqual(LIGHT_WALL_GLYPHS[WALL_UP | WALL_DOWN | WALL_RIGHT], combinedWallGlyph(WALL_UP | WALL_DOWN | WALL_RIGHT, 0));
    try testing.expectEqual(HEAVY_WALL_GLYPHS[WALL_LEFT | WALL_RIGHT], combinedWallGlyph(0, WALL_LEFT | WALL_RIGHT));
}

test "combinedWallGlyph: the 4 mixed cases a depth-1 edge can actually produce" {
    // A depth-1 box's heavy top/bottom edge meeting a lighter child wall
    // reaching up/down into it, and the same for its left/right edge.
    try testing.expectEqual(@as(u21, '┯'), combinedWallGlyph(WALL_DOWN, WALL_LEFT | WALL_RIGHT));
    try testing.expectEqual(@as(u21, '┷'), combinedWallGlyph(WALL_UP, WALL_LEFT | WALL_RIGHT));
    try testing.expectEqual(@as(u21, '┠'), combinedWallGlyph(WALL_RIGHT, WALL_UP | WALL_DOWN));
    try testing.expectEqual(@as(u21, '┨'), combinedWallGlyph(WALL_LEFT, WALL_UP | WALL_DOWN));
}

test "combinedWallGlyph: 4-arm cross, 3 heavy + 1 light" {
    // A depth-1 box's own heavy edge, ALSO continuing past this cell as a
    // row-wrap boundary shared with a sibling (so left+right, or up+down,
    // stay heavy on both sides), meeting a lighter child wall reaching
    // into it from the remaining direction — not collapsed into a plain
    // heavy `╋`.
    try testing.expectEqual(@as(u21, '╇'), combinedWallGlyph(WALL_DOWN, WALL_UP | WALL_LEFT | WALL_RIGHT));
    try testing.expectEqual(@as(u21, '╈'), combinedWallGlyph(WALL_UP, WALL_DOWN | WALL_LEFT | WALL_RIGHT));
    try testing.expectEqual(@as(u21, '╉'), combinedWallGlyph(WALL_RIGHT, WALL_UP | WALL_DOWN | WALL_LEFT));
    try testing.expectEqual(@as(u21, '╊'), combinedWallGlyph(WALL_LEFT, WALL_UP | WALL_DOWN | WALL_RIGHT));
}

test "computeDerived: equal_totals counts leaves, ignoring real value" {
    // root -> group(has 3 leaf children, wildly different sizes) -> also a
    // lone top-level leaf. equal_totals should report leaf *counts*
    // (1 for any leaf, 3 for the group), completely ignoring `value`.
    const nodes = [_]Node{
        .{ .parent = NO_PARENT, .level = 0, .value = 0, .label = "root" },
        .{ .parent = 0, .level = 1, .value = 0, .label = "group" },
        .{ .parent = 1, .level = 2, .value = 1, .label = "tiny" },
        .{ .parent = 1, .level = 2, .value = 1_000_000, .label = "huge" },
        .{ .parent = 1, .level = 2, .value = 50, .label = "mid" },
        .{ .parent = 0, .level = 1, .value = 999, .label = "lone_leaf" },
    };
    const derived = try computeDerived(&nodes, testing.allocator);
    defer derived.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 1), derived.equal_totals[2]); // tiny
    try testing.expectEqual(@as(f64, 1), derived.equal_totals[3]); // huge
    try testing.expectEqual(@as(f64, 1), derived.equal_totals[4]); // mid
    try testing.expectEqual(@as(f64, 3), derived.equal_totals[1]); // group: 3 leaves
    try testing.expectEqual(@as(f64, 1), derived.equal_totals[5]); // lone_leaf
    try testing.expectEqual(@as(f64, 4), derived.equal_totals[0]); // root: 4 leaves total

    // Meanwhile the real `totals` still reflects actual value sums, unlike
    // equal_totals — confirms the two arrays diverge as intended.
    try testing.expect(derived.totals[0] != derived.equal_totals[0]);
}

test "formatValue: si_units=false always prints the plain integer" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("2000000", formatValue(&buf, 2_000_000, false));
    try testing.expectEqualStrings("42", formatValue(&buf, 42, false));
}

test "formatValue: si_units=true suffixes round numbers with no decimal" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("2M", formatValue(&buf, 2_000_000, true));
    try testing.expectEqualStrings("1K", formatValue(&buf, 1_000, true));
    try testing.expectEqualStrings("3G", formatValue(&buf, 3_000_000_000, true));
}

test "formatValue: si_units=true keeps one decimal for non-round scaled values" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.5K", formatValue(&buf, 1_500, true));
    try testing.expectEqualStrings("2.3M", formatValue(&buf, 2_300_000, true));
}

test "formatValue: si_units=true leaves sub-1000 values unsuffixed" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("999", formatValue(&buf, 999, true));
    try testing.expectEqualStrings("0", formatValue(&buf, 0, true));
}

/// Draws one already-placed set of nodes — a full frame's `(laid_out,
/// rects)` in the steady-state render, or a filtered, tweened subset
/// during `animateZoomIn`'s intermediate frames. Pulled out of the main
/// render pass so both call sites share the exact same per-node drawing
/// logic (leaf vs. group styling, selection highlight, label/value
/// placement) instead of two copies drifting apart. `path_label`, when
/// non-null, replaces `laid_out[0]`'s own label (the breadcrumb) — tween
/// frames pass `null` and just show the root's plain label, since the
/// breadcrumb's own path-so-far isn't really meaningful mid-animation.
///
/// Marks every `mergeable` box's own border into `walls`/`selected` —
/// `markBorderWalls` per box, nothing flushed yet. Safe to do directly off
/// `all_rects` with no adjustment, since `tree_lod.placeSiblings`/
/// `placeSiblingsWrapped` already place every non-first sibling 1 cell
/// into its predecessor's territory specifically so two adjacent boxes'
/// rects share their touching edge exactly — and, in "classical" style, so
/// does `borderDepth`'s root-only inset, letting a depth-1 box's own edge
/// touch its (otherwise flush) children the same way.
fn markWalls(walls: []u4, selected: []bool, mask_w: u16, all_rects: []const tui.Rect, mergeable: []const bool, is_selected_of: []const bool) void {
    for (all_rects, mergeable, is_selected_of) |rect, is_mergeable, is_selected| {
        if (is_mergeable) markBorderWalls(walls, selected, mask_w, rect, is_selected);
    }
}

/// Leaf borders merge with an immediately touching leaf neighbor, and
/// depth-1 group borders merge with an immediately touching depth-1
/// neighbor — most visible in "classical" style, where many leaves end up
/// flush against each other with no group border between them, but
/// depth-1's own top-level boxes touch each other in either style. In
/// "classical" style specifically, a depth-1 box's own heavy edge also
/// merges with a lighter child wall touching it from the inside (see
/// `combinedWallGlyph`), since `borderDepth` leaves depth-1's children
/// flush against it rather than inset. The root (double) and thin
/// depth-2+ borders (containment style only) still always draw
/// independently — double doesn't mix with anything here.
fn drawEntries(canvas: Canvas, buf: *Buffer, s: *AppState, laid_out: []const LaidOutNode, rects: []const Rect, path_label: ?[]const u8) void {
    const gpa = std.heap.page_allocator;

    // Precompute every entry's `tui.Rect`, selection state, and which pool
    // (if any) it's eligible to merge in — reused below instead of
    // recomputed per branch, and needed up front here since the wall-mask
    // passes have to know an entry's selection state before the main
    // per-entry loop below would otherwise compute it.
    const all_rects = gpa.alloc(tui.Rect, laid_out.len) catch null;
    defer if (all_rects) |ar| gpa.free(ar);
    const is_leaf = gpa.alloc(bool, laid_out.len) catch null;
    defer if (is_leaf) |il| gpa.free(il);
    const is_depth1_group = gpa.alloc(bool, laid_out.len) catch null;
    defer if (is_depth1_group) |idg| gpa.free(idg);
    const is_selected_of = gpa.alloc(bool, laid_out.len) catch null;
    defer if (is_selected_of) |isa| gpa.free(isa);
    // Light and heavy walls, marked into separate scratch grids rather
    // than flushed independently — a combined pass below reads both so a
    // cell touched by *both* (a depth-1 box's own heavy edge and a flush
    // child's lighter wall, in "classical" style) gets the one correct
    // mixed glyph instead of whichever weight happened to draw last
    // silently overwriting the other. Kept alive through the whole
    // function (not freed until `drawEntries` returns), not just the
    // marking pass below: the main per-entry loop further down checks
    // `wallsOccupy` before drawing a too-small entry's bare label, so a
    // tiny leaf/aggregate landing on what's *also* a shared wall cell
    // (not its own box — it has none) can't stomp the wall glyph there
    // with plain text.
    const cells = @as(usize, canvas.area.width) * @as(usize, canvas.area.height);
    const light_walls = gpa.alloc(u4, cells) catch null;
    defer if (light_walls) |w| gpa.free(w);
    const heavy_walls = gpa.alloc(u4, cells) catch null;
    defer if (heavy_walls) |w| gpa.free(w);
    const light_selected = gpa.alloc(bool, cells) catch null;
    defer if (light_selected) |sel| gpa.free(sel);
    const heavy_selected = gpa.alloc(bool, cells) catch null;
    defer if (heavy_selected) |sel| gpa.free(sel);

    // Only attempted when every scratch array above actually allocated —
    // a rare failure just falls back to every entry drawing its own
    // unmerged border independently, exactly as before this feature.
    const merging = all_rects != null and is_leaf != null and is_depth1_group != null and
        is_selected_of != null and light_walls != null and heavy_walls != null and
        light_selected != null and heavy_selected != null;
    if (merging) {
        var direct_child_rank: usize = 0;
        for (laid_out, rects, 0..) |n, r, i| {
            const rect = tui.Rect{
                .x = @intCast(r.x),
                .y = @intCast(r.y),
                .width = @intCast(r.w),
                .height = @intCast(r.h),
            };
            all_rects.?[i] = rect;
            const is_group = isGroup(s.has_children, n.orig_index);
            is_leaf.?[i] = i != 0 and !is_group and rect.width >= 2 and rect.height >= 2;
            is_depth1_group.?[i] = is_group and n.level == 1 and rect.width >= 2 and rect.height >= 2;

            var sel = false;
            if (s.click_selected_orig_index) |sel_idx| {
                sel = n.orig_index == sel_idx;
            } else if (n.level == 1) {
                sel = direct_child_rank == s.selected;
            }
            if (n.level == 1) direct_child_rank += 1;
            is_selected_of.?[i] = sel;
        }

        @memset(light_walls.?, 0);
        @memset(heavy_walls.?, 0);
        @memset(light_selected.?, false);
        @memset(heavy_selected.?, false);
        markWalls(light_walls.?, light_selected.?, canvas.area.width, all_rects.?, is_leaf.?, is_selected_of.?);
        markWalls(heavy_walls.?, heavy_selected.?, canvas.area.width, all_rects.?, is_depth1_group.?, is_selected_of.?);
        for (0..canvas.area.height) |yy| {
            for (0..canvas.area.width) |xx| {
                const idx = yy * canvas.area.width + xx;
                const heavy = heavy_walls.?[idx];
                const light = resolveWallConflicts(light_walls.?[idx], heavy);
                if (light == 0 and heavy == 0) continue;
                const selected = (heavy != 0 and heavy_selected.?[idx]) or (light != 0 and light_selected.?[idx]);
                const wall_style = if (selected) Style{ .fg = .yellow } else Style{};
                canvas.setPixel(@intCast(xx), @intCast(yy), combinedWallGlyph(light, heavy), wall_style);
            }
        }
    }

    // True when `(x, y)` is already part of a merged wall glyph — see the
    // main loop's too-small branches below, which check this before
    // drawing a bare label (they have no border of their own, so there's
    // nothing legitimately theirs to overwrite there; unlike a normal
    // bordered box's own title, which *is* allowed to overwrite part of
    // its own border row).
    const wallsOccupy = struct {
        fn f(lw: ?[]const u4, hw: ?[]const u4, mask_w: u16, x: u16, y: u16) bool {
            const idx = @as(usize, y) * mask_w + x;
            const l = if (lw) |a| a[idx] else 0;
            const h = if (hw) |a| a[idx] else 0;
            return l != 0 or h != 0;
        }
    }.f;

    var direct_child_rank: usize = 0;
    for (laid_out, rects, 0..) |n, r, i| {
        // Same override-then-fallback priority as `selected_node` in the
        // caller: a click-selected node (root or any depth) is
        // highlighted regardless of level, and only when there's no click
        // override does the plain rank-based keyboard selection get the
        // highlight. `direct_child_rank` still has to advance for every
        // level-1 entry unconditionally, or a later fallback frame's rank
        // comparisons would drift.
        var is_selected = false;
        if (s.click_selected_orig_index) |sel_idx| {
            is_selected = n.orig_index == sel_idx;
        } else if (n.level == 1) {
            is_selected = direct_child_rank == s.selected;
        }
        if (n.level == 1) direct_child_rank += 1;
        const label = if (i == 0 and path_label != null) path_label.? else n.label;
        const rect = tui.Rect{
            .x = @intCast(r.x),
            .y = @intCast(r.y),
            .width = @intCast(r.w),
            .height = @intCast(r.h),
        };
        const style = if (is_selected) Style{ .fg = .yellow } else Style{};
        const is_group = isGroup(s.has_children, n.orig_index);
        if (i != 0 and !is_group and rect.width >= 2 and rect.height >= 2) {
            // Leaf: thin rounded border (vs. a group's square corners at
            // the same depth) around an interior shaded per the source
            // JSON's own `shade` field (blank when unset), with the label
            // on top. The border itself was already drawn by the
            // wall-mask pass above when merging succeeded; fall back to
            // drawing it here, unmerged, only when that pass couldn't run
            // at all.
            if (!merging) drawNodeBox(canvas, rect, LEAF_GLYPHS, style);
            if (leafFillChar(s.shades, n.orig_index)) |fill_char| {
                var yy = rect.y + 1;
                while (yy < rect.y + rect.height - 1) : (yy += 1) {
                    var xx = rect.x + 1;
                    while (xx < rect.x + rect.width - 1) : (xx += 1) {
                        canvas.setPixel(xx, yy, fill_char, style);
                    }
                }
            }
            // Label and size, both horizontally centered in the interior,
            // label stacked directly above size — a centered pair rather
            // than the label pinned to the border row. Needs two interior
            // rows of its own (height > 3: row 0 is the top border, so
            // height 3 has only one interior row — not enough for both,
            // so the label alone goes there instead — and height 2 has
            // none at all, so the label falls back to the border row, as
            // it always has). Size is left blank in `equal_weight` mode:
            // `n.value` there is the synthetic equal-weight number layout
            // used, not a real size — showing it would be misleading.
            if (rect.width > 2) {
                const interior_w = rect.width - 2;
                const centered_x = struct {
                    fn f(rx: u16, iw: u16, text_len: usize) u16 {
                        return rx + 1 + (iw -| @as(u16, @intCast(@min(text_len, iw)))) / 2;
                    }
                }.f;
                if (rect.height > 3) {
                    const mid = rect.y + rect.height / 2;
                    buf.setStringTruncated(centered_x(rect.x, interior_w, label.len), mid - 1, label, interior_w, style);
                    if (!s.equal_weight) {
                        var value_buf: [32]u8 = undefined;
                        const value_str = formatValue(&value_buf, n.value, s.si_units);
                        buf.setStringTruncated(centered_x(rect.x, interior_w, value_str.len), mid, value_str, interior_w, style);
                    }
                } else if (rect.height > 2) {
                    buf.setStringTruncated(centered_x(rect.x, interior_w, label.len), rect.y + 1, label, interior_w, style);
                } else {
                    buf.setStringTruncated(rect.x + 1, rect.y, label, interior_w, style);
                }
            }
        } else if (i != 0 and !is_group and rect.width >= 1 and rect.height >= 1) {
            // Leaf too small for a border at all — same borderless
            // shade-if-set fallback as before. Has no border of its own,
            // so if `(rect.x, rect.y)` is already part of a *different*
            // box's merged wall (e.g. a tiny aggregate landing on a
            // row-wrap boundary another box's border runs through), skip
            // the label rather than stomp a wall glyph with plain text.
            if (leafFillChar(s.shades, n.orig_index)) |fill_char| {
                var yy = rect.y;
                while (yy < rect.y + rect.height) : (yy += 1) {
                    var xx = rect.x;
                    while (xx < rect.x + rect.width) : (xx += 1) {
                        canvas.setPixel(xx, yy, fill_char, style);
                    }
                }
            }
            if (!wallsOccupy(light_walls, heavy_walls, canvas.area.width, rect.x, rect.y)) {
                buf.setStringTruncated(rect.x, rect.y, label, rect.width, style);
            }
        } else if (s.classical_style and i != 0 and is_group and n.level > 1) {
            // "Classical" style: no border or label for an interior node
            // below depth 1 — its rect was already placed flush (see
            // `borderDepth`), so drawing nothing here just lets its own
            // children's boxes (leaves, or a further-nested group) show
            // directly, with no enclosing line "overwriting" theirs. Grouping
            // beyond depth 1 reads purely from adjacency, the way it does in
            // a classic Shneiderman treemap.
        } else if (rect.width >= 2 and rect.height >= 2) {
            // Group with a border: root (double) and thin depth-2+
            // (containment style) always draw their own independently, as
            // before. A depth-1 group's border was already drawn by the
            // heavy wall-mask pass above when merging succeeded; fall back
            // to drawing it here, unmerged, only when that pass couldn't
            // run at all.
            const merges_here = merging and n.level == 1;
            if (!merges_here) drawNodeBox(canvas, rect, boxGlyphs(weightForLevel(n.level)), style);
            if (rect.width > 2) {
                // canvas.drawText truncates against the whole canvas's
                // right edge, not this box's — a label longer than the
                // box's own interior would overwrite the box's own "┐"
                // corner (and spill into whatever sits to its right)
                // instead of stopping at it. buf.setStringTruncated,
                // called directly, lets the width bound be this box's
                // interior instead.
                buf.setStringTruncated(rect.x + 1, rect.y, label, rect.width - 2, style);
            }
        } else if (rect.width >= 1 and rect.height >= 1) {
            // Too small for a box at all — matches MIN_LABEL_WIDTH_CELLS:
            // still show at least a sliver of the label (down to a single
            // "…") rather than nothing, which is what a bare `width < 2`
            // guard on `drawNodeBox` alone would do. Same
            // whole-canvas-vs-this-rect width issue applies here, and the
            // same "don't stomp a wall glyph that isn't ours" guard as
            // the too-small-leaf branch above.
            if (!wallsOccupy(light_walls, heavy_walls, canvas.area.width, rect.x, rect.y)) {
                buf.setStringTruncated(rect.x, rect.y, label, rect.width, style);
            }
        }
    }
}

const ZOOM_TWEEN_STEPS: usize = 10;
const ZOOM_TWEEN_FRAME_MS: i64 = 30;

/// Animates a zoom-in as a "FLIP" transition (First/Last/Invert/Play):
/// `before_laid_out`/`before_rects` are the layout the caller already had
/// on screen right before calling `zoomIn`; this computes the *new* root's
/// own layout once, matches every entry the two layouts have in common by
/// `.orig_index`, and draws `ZOOM_TWEEN_STEPS - 1` intermediate frames
/// linearly interpolating each matched entry's rect from its old position
/// to its new one — a node's box visibly grows (or, for a sibling that
/// shrinks into view, shrinks) into place instead of the whole screen
/// blinking straight to the new layout. Only two real layout passes ever
/// run (before was already computed by the caller; after is computed once
/// here) — the tween itself is pure interpolation, no relayout per step.
///
/// A node only in the *after* layout (children the zoom just revealed)
/// isn't drawn at all during the tween — it simply appears once this
/// returns and the normal render loop draws the real, final frame. Skips
/// entirely for a "…" aggregate zoom: `chosen.orig_index == NO_PARENT`
/// there, so nothing could be matched anyway — the caller checks this
/// before calling, so a fold-in zoom just blinks as before.
fn animateZoomIn(
    io: std.Io,
    terminal: *Terminal,
    state: *AppState,
    before_laid_out: []const LaidOutNode,
    before_rects: []const Rect,
    area: Rect,
    area_cells: usize,
    min_cells: usize,
) void {
    const gpa = std.heap.page_allocator;
    const after_laid_out = tree_lod.layoutTreeWithIndex(
        state.nodes,
        activeTotals(state),
        state.child_index,
        state.root,
        area_cells,
        3,
        min_cells,
        OTHER_LABEL,
        gpa,
    ) catch return;
    defer gpa.free(after_laid_out);
    const after_rects = tree_lod.placeRectsWrapped(after_laid_out, area, MIN_ROW_HEIGHT, borderDepth(state), gpa) catch return;
    defer gpa.free(after_rects);

    const Ctx = struct { s: *AppState, laid_out: []const LaidOutNode, rects: []const Rect };

    var step: usize = 1;
    while (step < ZOOM_TWEEN_STEPS) : (step += 1) {
        const t = easeInOutCubic(@as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(ZOOM_TWEEN_STEPS)));

        var f_laid: std.ArrayList(LaidOutNode) = .empty;
        defer f_laid.deinit(gpa);
        var f_rects: std.ArrayList(Rect) = .empty;
        defer f_rects.deinit(gpa);

        for (after_laid_out, after_rects) |an, ar| {
            if (an.orig_index == NO_PARENT) continue;
            for (before_laid_out, before_rects) |bn, br| {
                if (bn.orig_index == an.orig_index) {
                    f_laid.append(gpa, an) catch continue;
                    f_rects.append(gpa, lerpRect(br, ar, t)) catch continue;
                    break;
                }
            }
        }

        var ctx = Ctx{ .s = state, .laid_out = f_laid.items, .rects = f_rects.items };
        terminal.draw(&ctx, struct {
            fn render(c: *Ctx, buf: *Buffer) !void {
                const a = buf.getArea();
                const canvas = Canvas.init(a, buf, Style{});
                drawEntries(canvas, buf, c.s, c.laid_out, c.rects, null);
            }
        }.render) catch return;

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ZOOM_TWEEN_FRAME_MS), .awake) catch return;
    }
}

/// How often the main loop re-checks `AppState.reload_command` (only ever
/// set for a command-loaded tree — see its own doc comment). Comfortably
/// longer than the ~68ms a real `ps_scan()`/`tree_scan()` one-shot query
/// takes end to end (measured directly, not estimated) and the ~300ms the
/// reload tween itself runs (`ZOOM_TWEEN_STEPS * ZOOM_TWEEN_FRAME_MS`), so
/// there's no risk of a reload still being in flight when the next one
/// comes due.
const RELOAD_INTERVAL_MS: i64 = 2000;

/// Reload counterpart to `animateZoomIn` — the same FLIP-style rect tween
/// (reuses `lerpRect`/`easeInOutCubic`/`ZOOM_TWEEN_STEPS`/
/// `ZOOM_TWEEN_FRAME_MS` verbatim), but matching entries by `key` instead
/// of `.orig_index`: a reload replaces the whole node array, so an
/// `.orig_index` that happens to land on the same number before and after
/// means nothing (see `JsonNode.key`'s doc comment for why). Must run
/// *after* `state.nodes`/`.keys`/`.root` already reflect the new tree
/// (same calling convention as `animateZoomIn`) but *before* `old_keys`'s
/// backing storage is freed — this only ever reads `old_keys`, never
/// copies it.
///
/// Only the rect is tweened, not the value label or shade. A node's
/// *size* visibly changing is exactly the motion this exists to make
/// legible; its displayed number or shade jumping straight to the new
/// value on the last frame is a much smaller discontinuity than its box
/// jumping would be. Tweening those too would need either a temporary
/// synthetic node array carrying interpolated values (for the label
/// text) or a continuous driver value threaded through from SQL instead
/// of a pre-bucketed shade (`ps_scan.sql` buckets `%cpu` into 1..3 before
/// this ever sees it) — deferred rather than built speculatively ahead of
/// seeing whether the discrete jump actually looks bad in practice.
///
/// A node with no match in `old_keys` (its key is `null`, or genuinely
/// new) isn't drawn during the tween — same treatment `animateZoomIn`
/// already gives a zoom revealing new children — it simply appears whole
/// once this returns. A node that *disappeared* (key only in `old_keys`)
/// is, also like `animateZoomIn`, never drawn during the tween either,
/// since the loop only ever walks the *after* layout — it just vanishes
/// rather than shrinking out. Both are the documented simplifications
/// from the design discussion this followed, not accidental gaps.
fn animateReload(
    io: std.Io,
    terminal: *Terminal,
    state: *AppState,
    before_laid_out: []const LaidOutNode,
    before_rects: []const Rect,
    old_keys: []const ?[]const u8,
    area: Rect,
    area_cells: usize,
    min_cells: usize,
    start_ts: std.Io.Timestamp,
) void {
    const gpa = std.heap.page_allocator;
    const after_laid_out = tree_lod.layoutTreeWithIndex(
        state.nodes,
        activeTotals(state),
        state.child_index,
        state.root,
        area_cells,
        3,
        min_cells,
        OTHER_LABEL,
        gpa,
    ) catch return;
    defer gpa.free(after_laid_out);
    const after_rects = tree_lod.placeRectsWrapped(after_laid_out, area, MIN_ROW_HEIGHT, borderDepth(state), gpa) catch return;
    defer gpa.free(after_rects);

    // For each *new* orig_index, which *old* orig_index shares its key
    // (if any) — the reverse direction of `matchByKey`'s usual
    // old-to-new one, per its own doc comment on swapping argument order.
    const new_to_old = matchByKey(gpa, state.keys, old_keys) catch return;
    defer gpa.free(new_to_old);

    // A "…" aggregate has no `orig_index`/key of its own — it's not a row
    // from the source data at all, but a runtime-derived fold of whichever
    // of its parent's children didn't individually clear `min_cells` at
    // *this* screen size (see `layoutChildren`'s own doc comment) — so the
    // generic key matching above can never match one across a reload; it
    // would vanish and reappear on every single tween otherwise, the one
    // kind of node a real, stable key could never attach to. But there's
    // at most one "…" leaf per parent (`layoutChildren`'s `other_seen` is
    // a single flag per call), so the *parent's* own stable key is a sound
    // proxy identity for its "…" child: two "…" leaves across a reload are
    // "the same" aggregate exactly when their parents are. Built here from
    // `before_laid_out` as parent-key -> old rect, consulted by the main
    // loop below instead of the unconditional skip a "…" entry used to get.
    var old_other_by_parent_key = std.StringHashMap(Rect).init(gpa);
    defer old_other_by_parent_key.deinit();
    for (before_laid_out, before_rects) |bn, br| {
        if (bn.orig_index != NO_PARENT) continue;
        const parent_orig = before_laid_out[bn.parent].orig_index;
        if (parent_orig == NO_PARENT or parent_orig >= old_keys.len) continue;
        const parent_key = old_keys[parent_orig] orelse continue;
        old_other_by_parent_key.put(parent_key, br) catch {};
    }

    // Unlike `animateZoomIn` (where the breadcrumb is left `null` during
    // the tween because the root's identity is itself mid-change — see
    // that function's own doc comment), a reload never changes *which*
    // node is conceptually the root, only what it contains — so the
    // breadcrumb string is exactly as valid during the tween as before or
    // after it. Built once here and passed through every frame instead of
    // `null`, the same construction the real per-frame render uses.
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    for (state.path.items, 0..) |seg, idx| {
        if (idx > 0) path_buf.appendSlice(gpa, "/") catch break;
        path_buf.appendSlice(gpa, seg) catch break;
    }
    const path_label = path_buf.items;

    const Ctx = struct { s: *AppState, laid_out: []const LaidOutNode, rects: []const Rect, path: []const u8, elapsed_ms: i64, content_h: usize };

    var step: usize = 1;
    while (step < ZOOM_TWEEN_STEPS) : (step += 1) {
        const t = easeInOutCubic(@as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(ZOOM_TWEEN_STEPS)));

        var f_laid: std.ArrayList(LaidOutNode) = .empty;
        defer f_laid.deinit(gpa);
        var f_rects: std.ArrayList(Rect) = .empty;
        defer f_rects.deinit(gpa);

        for (after_laid_out, after_rects, 0..) |an, ar, ai| {
            if (an.orig_index == NO_PARENT) {
                // See `old_other_by_parent_key`'s own comment above —
                // matched via the parent's key, not the leaf's own (it
                // has none).
                const parent_orig = after_laid_out[an.parent].orig_index;
                if (parent_orig != NO_PARENT and parent_orig < state.keys.len) {
                    if (state.keys[parent_orig]) |parent_key| {
                        if (old_other_by_parent_key.get(parent_key)) |br| {
                            f_laid.append(gpa, an) catch continue;
                            f_rects.append(gpa, lerpRect(br, ar, t)) catch continue;
                        }
                    }
                }
                continue;
            }
            if (an.orig_index >= new_to_old.len) continue;
            // The root entry (always index 0 — `layoutTreeWithIndex`
            // always sets it to `state.root`/the old root respectively)
            // carries no `key` of its own by convention (both
            // tree_scan.sql and ps_scan.sql emit `NULL`, not an empty
            // string, for it — see their own doc comments), so the
            // generic key lookup below always treats it as "no match" —
            // without this, the root's own box (border + breadcrumb)
            // vanished for the *entire* tween on every single reload,
            // which reads as the root disappearing, not as the brief,
            // expected blink a genuinely-unmatched node gets. Root always
            // persists across a reload by construction, so it's matched
            // structurally here instead of through `new_to_old`.
            if (ai == 0) {
                if (before_laid_out.len > 0) {
                    f_laid.append(gpa, an) catch continue;
                    f_rects.append(gpa, lerpRect(before_rects[0], ar, t)) catch continue;
                }
                continue;
            }
            const old_idx = new_to_old[an.orig_index] orelse continue;
            for (before_laid_out, before_rects) |bn, br| {
                if (bn.orig_index == old_idx) {
                    f_laid.append(gpa, an) catch continue;
                    f_rects.append(gpa, lerpRect(br, ar, t)) catch continue;
                    break;
                }
            }
        }

        var ctx = Ctx{
            .s = state,
            .laid_out = f_laid.items,
            .rects = f_rects.items,
            .path = path_label,
            .elapsed_ms = start_ts.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds(),
            .content_h = area.h,
        };
        terminal.draw(&ctx, struct {
            fn render(c: *Ctx, buf: *Buffer) !void {
                const a = buf.getArea();
                const canvas = Canvas.init(a, buf, Style{});
                drawEntries(canvas, buf, c.s, c.laid_out, c.rects, c.path);

                // Status bar during the tween too — see `buildStatusLine`'s
                // own doc comment for why this can't just be left out the
                // way the old behavior effectively did.
                var status_buf: [256]u8 = undefined;
                const status_line = buildStatusLine(c.s, c.laid_out, &status_buf);
                const indicator = connectionIndicator(c.s, c.elapsed_ms);
                const content_h: u16 = @intCast(c.content_h);
                if (a.height > content_h) {
                    drawStatusBar(buf, a.x, a.y + content_h, a.width, status_line, indicator);
                }
            }
        }.render) catch return;

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ZOOM_TWEEN_FRAME_MS), .awake) catch return;
    }
}

/// Re-runs `state.reload_command` and, on success, swaps the result into
/// `state`, remaps drill-down/selection state across the identity change
/// (`remapStateAfterReload`), and runs the reload tween (`animateReload`)
/// — all before anything belonging to the *old* tree is freed, since both
/// of those steps still need to read it. Returns `false` with `state`
/// completely untouched when the command fails or produces a tree that
/// can't even have its aggregates computed — a transient hiccup (a
/// process that raced its own exit mid-`ps`, a momentarily-unreadable
/// path) shouldn't crash a live view or blank out what's already on
/// screen; the next scheduled check tries again.
///
/// `before_laid_out`/`before_rects` must be the layout already on screen
/// for the *old* `state.root` (exactly what the main loop already
/// computes once per iteration for its own event handling) — this never
/// recomputes them itself, the same contract `animateZoomIn`'s own
/// callers already follow.
fn reloadFromCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    terminal: *Terminal,
    state: *AppState,
    loaded: *?std.json.Parsed([]JsonNode),
    owned_nodes: *?[]Node,
    owned_shades: *?[]u8,
    owned_keys: *?[]?[]const u8,
    owned_derived: *?Derived,
    before_laid_out: []const LaidOutNode,
    before_rects: []const Rect,
    area: Rect,
    area_cells: usize,
    min_cells: usize,
    start_ts: std.Io.Timestamp,
) !bool {
    const command = state.reload_command orelse return false;
    const result = loadNodesFromCommand(io, allocator, command) catch |err| {
        std.debug.print("error: reload failed: {s}\n", .{@errorName(err)});
        return false;
    };

    // Compute aggregates *before* touching `state` at all, so a failure
    // here leaves everything exactly as it was — nothing to roll back.
    var new_derived = result.derived;
    if (new_derived == null) {
        new_derived = computeDerived(result.nodes, allocator) catch |err| {
            allocator.free(result.nodes);
            allocator.free(result.shades);
            allocator.free(result.keys);
            result.parsed.deinit();
            std.debug.print("error: reload failed computing aggregates: {s}\n", .{@errorName(err)});
            return false;
        };
    }

    const old_nodes = state.nodes;
    const old_keys = state.keys;
    const old_loaded = loaded.*;
    const old_owned_nodes = owned_nodes.*;
    const old_owned_shades = owned_shades.*;
    const old_owned_keys = owned_keys.*;
    const old_owned_derived = owned_derived.*;

    state.nodes = result.nodes;
    state.shades = result.shades;
    state.keys = result.keys;
    state.totals = new_derived.?.totals;
    state.equal_totals = new_derived.?.equal_totals;
    state.has_children = new_derived.?.has_children;
    state.subtree_groups = new_derived.?.subtree_groups;
    state.subtree_leaves = new_derived.?.subtree_leaves;
    state.child_index = new_derived.?.child_index;

    try remapStateAfterReload(allocator, state, old_nodes, old_keys);
    animateReload(io, terminal, state, before_laid_out, before_rects, old_keys, area, area_cells, min_cells, start_ts);

    loaded.* = result.parsed;
    owned_nodes.* = result.nodes;
    owned_shades.* = result.shades;
    owned_keys.* = result.keys;
    owned_derived.* = new_derived;

    if (old_loaded) |l| l.deinit();
    if (old_owned_nodes) |n| allocator.free(n);
    if (old_owned_shades) |s| allocator.free(s);
    if (old_owned_keys) |k| allocator.free(k);
    if (old_owned_derived) |d| d.deinit(allocator);

    return true;
}

/// Printed once, to stderr, only when `treemap` is launched with no
/// argument at all (the built-in fixture shows instead) — before the
/// terminal ever switches to raw/alt-screen mode, so it lands in the
/// user's ordinary scrollback and is still there after quitting (leaving
/// alt-screen mode restores whatever was on screen before entering it,
/// per how every other terminal app's alt-screen behaves). Once in raw
/// mode there's no good way to show this at all — see
/// `loadNodesFromCommand`'s own doc comment on the same limitation for a
/// failed command's stderr.
///
/// Points at the two bundled macros' own canonical one-liners (copied
/// from their own top-of-file doc comments, not re-derived here) rather
/// than re-explaining what each does — `tree_scan.sql`/`ps_scan.sql`
/// already carry that explanation.
fn printBareUsageExamples() void {
    std.debug.print(
        \\treemap: no data source given — showing the built-in fixture.
        \\
        \\Try a real one instead (run from this directory):
        \\  ./zig-out/bin/treemap "duckdb -unsigned -init tree_scan.sql -c \"COPY (FROM tree_scan(scan_path := '~/repos')) TO '/dev/stdout' (FORMAT JSON, ARRAY true);\" |"
        \\  ./zig-out/bin/treemap "duckdb -unsigned -init ps_scan.sql -c \"COPY (FROM ps_scan()) TO '/dev/stdout' (FORMAT JSON, ARRAY true);\" |"
        \\
        \\...or a plain tree.json file:
        \\  ./zig-out/bin/treemap path/to/tree.json
        \\
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Optional first argument: a JSON tree file (see doc comment above).
    // Falls back to the small built-in fixture when none is given.
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next(); // argv[0]
    var loaded: ?std.json.Parsed([]JsonNode) = null;
    defer if (loaded) |l| l.deinit();
    var owned_nodes: ?[]Node = null;
    defer if (owned_nodes) |n| allocator.free(n);
    var owned_shades: ?[]u8 = null;
    defer if (owned_shades) |s| allocator.free(s);
    var owned_keys: ?[]?[]const u8 = null;
    defer if (owned_keys) |k| allocator.free(k);
    var owned_derived: ?Derived = null;
    var reload_command: ?[]const u8 = null;
    const maybe_arg = args_it.next();
    if (maybe_arg == null) printBareUsageExamples();
    const nodes: []const Node = if (maybe_arg) |arg| blk: {
        // Same trailing-`|` convention shellfs/duckdir.sh's own SQL already
        // uses for "this is a command to run, not a file to open" — see
        // `loadNodesFromCommand`. `std.mem.trimEnd` first so a trailing
        // space before the `|` (easy to type by accident) doesn't hide it.
        const trimmed = std.mem.trimEnd(u8, arg, " \t");
        const is_command = std.mem.endsWith(u8, trimmed, "|");
        const result = if (is_command) blk2: {
            const command = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t");
            reload_command = command; // enables the main loop's auto-reload check
            break :blk2 try loadNodesFromCommand(init.io, allocator, command);
        } else try loadNodesFromFile(init.io, allocator, arg);
        loaded = result.parsed;
        owned_nodes = result.nodes;
        owned_shades = result.shades;
        owned_keys = result.keys;
        owned_derived = result.derived;
        break :blk result.nodes;
    } else &default_fixture;
    const shades: []const u8 = owned_shades orelse &.{};
    const keys: []const ?[]const u8 = owned_keys orelse &.{};
    defer if (owned_derived) |d| d.deinit(allocator);

    // Computed once here, not per frame — see `Derived`'s own doc comment
    // for why that matters at real-filesystem tree sizes. Skipped when
    // `loadNodesFromFile` already found precomputed aggregates in the
    // file itself (see its own fast-path comment).
    if (owned_derived == null) owned_derived = try computeDerived(nodes, allocator);

    var backend = try tui.backend.init(allocator, init.io);
    defer backend.deinit();

    var terminal = try Terminal.init(allocator, backend.interface());
    defer terminal.deinit();

    // Reference point for the status bar's connection-indicator spinner
    // (see `connectionIndicator`) — captured once so the spinner's phase
    // stays continuous across ordinary frames and reload tweens alike,
    // rather than resetting whenever one starts.
    const start_ts = std.Io.Clock.awake.now(init.io);

    try terminal.enableMouse();
    defer terminal.disableMouse() catch {};

    var state = AppState{
        .nodes = nodes,
        .shades = shades,
        .keys = keys,
        .totals = owned_derived.?.totals,
        .equal_totals = owned_derived.?.equal_totals,
        .has_children = owned_derived.?.has_children,
        .subtree_groups = owned_derived.?.subtree_groups,
        .subtree_leaves = owned_derived.?.subtree_leaves,
        .child_index = owned_derived.?.child_index,
        .reload_command = reload_command,
        // Starting the interval clock now, not leaving it `null`, means
        // the first auto-reload fires after a full `RELOAD_INTERVAL_MS`
        // of actually looking at the initial load — not immediately on
        // the next loop tick.
        .last_reload_ts = if (reload_command != null) std.Io.Clock.awake.now(init.io) else null,
    };
    defer state.history.deinit(allocator);
    defer state.path.deinit(allocator);
    try state.path.append(allocator, nodes[0].label);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (state.running) {
        _ = arena.reset(.retain_capacity);
        const frame_alloc = arena.allocator();

        const totals = activeTotals(&state);

        // Same terminal area the render pass below will use (via
        // buf.getArea()) — needed here too so "which node is selected"
        // refers to the same layout the user is currently looking at.
        const term_area = terminal.current_buffer.getArea();
        const content_height = if (term_area.height > STATUS_BAR_HEIGHT) term_area.height - STATUS_BAR_HEIGHT else term_area.height;
        const area_cells = @as(usize, term_area.width) * @as(usize, content_height);
        const min_cells = minCells(content_height);
        const laid_out = try tree_lod.layoutTreeWithIndex(state.nodes, totals, state.child_index, state.root, area_cells, 3, min_cells, OTHER_LABEL, frame_alloc);

        // `selected` indexes only the current root's *direct* children
        // (laid_out entries at level == 1) — not raw positions in
        // `laid_out`, which interleaves a sibling's entire subtree before
        // its next sibling (layoutTree emits parent-then-full-subtree, not
        // parent-then-next-sibling). Indexing raw positions would make
        // "down" walk into a grandchild instead of the next sibling.
        var direct_children: std.ArrayList(usize) = .empty;
        for (laid_out, 0..) |n, i| {
            if (n.level == 1) try direct_children.append(frame_alloc, i);
        }

        // Geometry for mouse hit-testing, mirroring what the render pass
        // below will draw. Cheap enough to recompute every frame, same as
        // everything else here.
        const event_rects = tree_lod.placeRectsWrapped(
            laid_out,
            .{ .x = 0, .y = 0, .w = term_area.width, .h = content_height },
            MIN_ROW_HEIGHT,
            borderDepth(&state),
            frame_alloc,
        ) catch &.{};

        const event = try backend.interface().pollEvent(100);
        if (event == .key or event == .mouse) state.has_selected = true;
        switch (event) {
            .key => |key| switch (key.code) {
                .char => |c| if (c == 'q' or c == 'Q') {
                    state.running = false;
                } else if (c == 'v' or c == 'V') {
                    // Toggle "containment" (every level bordered) vs.
                    // "classical" (only root/depth-1 bordered, leaves
                    // flush) — see `AppState.classical_style`.
                    state.classical_style = !state.classical_style;
                } else if (c == 'c' or c == 'C') {
                    // Copy the selected node's on-screen box, as currently
                    // rendered, to the system clipboard.
                    if (findSelectedIndex(&state, laid_out)) |idx| {
                        copyVisualToClipboard(allocator, backend.interface(), &terminal.current_buffer, event_rects[idx]);
                    }
                } else if (c == 'd' or c == 'D') {
                    // Copy the selected node's own subtree (itself plus
                    // every descendant) to the system clipboard, as a
                    // standalone tree.json.
                    if (findSelectedIndex(&state, laid_out)) |idx| {
                        const orig = laid_out[idx].orig_index;
                        if (orig != NO_PARENT) copySubtreeToClipboard(allocator, backend.interface(), state.nodes, orig);
                    }
                } else if (c == 'p' or c == 'P') {
                    // Pause/resume auto-reload (only meaningful when
                    // `reload_command` is set at all — see its own doc
                    // comment). Lets a drilled-into "…" fold-in aggregate
                    // (see `resolveAcrossReload`'s doc comment on why it
                    // can't survive a reload at all — it has no identity
                    // in the source data to reconstruct) be inspected for
                    // as long as needed, instead of resetting on the next
                    // scheduled reload.
                    state.reload_paused = !state.reload_paused;
                } else if (c == 'u' or c == 'U') {
                    // Toggle plain-number vs. SI-suffixed value labels —
                    // see `formatValue`.
                    state.si_units = !state.si_units;
                } else if (c == 's' or c == 'S') {
                    // Toggle real-size vs. equal-weight layout — see
                    // `AppState.equal_weight`.
                    state.equal_weight = !state.equal_weight;
                },
                .esc => state.running = false,
                // Down/enter zoom in a level: re-root at the currently
                // selected child, if any. `.orig_index` is exactly the
                // bridge for this — it's the index into the loaded tree that
                // layoutTree can be re-rooted at, and NO_PARENT for a
                // "…" aggregate, which has no single node to zoom into.
                .down, .enter => {
                    if (state.selected < direct_children.items.len) {
                        const chosen = laid_out[direct_children.items[state.selected]];
                        const animate = chosen.orig_index != NO_PARENT;
                        try zoomIn(allocator, frame_alloc, &state, &owned_nodes, &owned_shades, &owned_keys, &owned_derived, laid_out, totals, area_cells, min_cells, chosen);
                        if (animate) {
                            animateZoomIn(init.io, &terminal, &state, laid_out, event_rects, .{ .x = 0, .y = 0, .w = term_area.width, .h = content_height }, area_cells, min_cells);
                        }
                    }
                },
                // Up/backspace zoom out a level: back to the previous root.
                .up, .backspace => try zoomOut(frame_alloc, &state, totals, area_cells, min_cells),
                // Left/right cycle the selection among siblings at the
                // current level. Clears any click-based override (root or a
                // deeper node picked by mouse) so the status bar and
                // highlight go back to following plain rank-based keyboard
                // selection.
                .left => if (state.selected > 0) {
                    state.selected -= 1;
                    state.click_selected_orig_index = null;
                },
                .right => if (state.selected + 1 < direct_children.items.len) {
                    state.selected += 1;
                    state.click_selected_orig_index = null;
                },
                else => {},
            },
            // Left click: on the root's own box (its border/title row,
            // where the breadcrumb is drawn — never covered by a child's
            // rect, since every child sits strictly inside its parent's
            // border) zooms out immediately, one click. On any other node,
            // a double-click (same cell, within DOUBLE_CLICK_MS) zooms in
            // directly to whatever was clicked, at whatever depth it's at
            // — not restricted to the current root's direct children the
            // way keyboard selection is; a single click instead *selects*
            // whatever was clicked (any depth, leaf or group) for the
            // status bar/highlight, via `click_selected_orig_index`.
            // Middle click on the root selects the root itself the same
            // way — left/right are already both spoken for on the root
            // (zoom out / jump to true root), so root selection needs its
            // own button rather than fighting the single-vs-double-click
            // timing zoomOut's immediate-fire relies on (see the note
            // below).
            .mouse => |m| if (m.kind == .down and (m.button == .left or m.button == .right or m.button == .middle)) {
                var hit: ?usize = null;
                for (event_rects, 0..) |r, i| {
                    if (@as(usize, m.x) >= r.x and @as(usize, m.x) < r.x + r.w and
                        @as(usize, m.y) >= r.y and @as(usize, m.y) < r.y + r.h)
                    {
                        if (hit == null or laid_out[i].level >= laid_out[hit.?].level) hit = i;
                    }
                }
                if (hit) |hi| {
                    if (hi == 0) {
                        // Breadcrumb: left click steps out one level (same
                        // as up/backspace); right click jumps straight to
                        // the true original root. These can't both be
                        // "left click, but double vs single" — a single
                        // click's zoomOut fires immediately for
                        // responsiveness, so by the time a real second
                        // click could be recognized as a double-click, the
                        // first click's zoom has *already happened* and
                        // changed the root out from under it. Two buttons
                        // sidesteps that entirely: each one commits
                        // immediately, no waiting to see if another click
                        // is coming.
                        if (m.button == .right) {
                            zoomToRoot(&state);
                        } else if (m.button == .middle) {
                            state.click_selected_orig_index = laid_out[0].orig_index;
                        } else {
                            try zoomOut(frame_alloc, &state, totals, area_cells, min_cells);
                        }
                    } else if (m.button == .left) {
                        const now = std.Io.Clock.awake.now(init.io);
                        const is_double_click = if (state.last_click_ts) |lt|
                            lt.durationTo(now).toMilliseconds() < DOUBLE_CLICK_MS and state.last_click_x == m.x and state.last_click_y == m.y
                        else
                            false;
                        state.last_click_ts = now;
                        state.last_click_x = m.x;
                        state.last_click_y = m.y;

                        if (is_double_click) {
                            const animate = laid_out[hi].orig_index != NO_PARENT;
                            try zoomIn(allocator, frame_alloc, &state, &owned_nodes, &owned_shades, &owned_keys, &owned_derived, laid_out, totals, area_cells, min_cells, laid_out[hi]);
                            if (animate) {
                                animateZoomIn(init.io, &terminal, &state, laid_out, event_rects, .{ .x = 0, .y = 0, .w = term_area.width, .h = content_height }, area_cells, min_cells);
                            }
                        } else {
                            // Single click on any node: select it for the
                            // status bar/highlight. A "…" aggregate has no
                            // stable original index (`NO_PARENT` — see
                            // `LaidOutNode.orig_index`'s doc comment), so
                            // it's left out of `click_selected_orig_index`
                            // rather than storing a sentinel that would be
                            // indistinguishable from "nothing selected".
                            if (laid_out[hi].orig_index != NO_PARENT) {
                                state.click_selected_orig_index = laid_out[hi].orig_index;
                            }
                            if (laid_out[hi].level == 1) {
                                // Also keep the rank in sync (same index
                                // space left/right already navigate), so
                                // arrow-key navigation continues from
                                // whatever direct child was just clicked.
                                for (direct_children.items, 0..) |di, rank| {
                                    if (di == hi) {
                                        state.selected = rank;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .resize => |size| try terminal.resize(.{ .width = size.width, .height = size.height }),
            else => {},
        }

        // Auto-reload, only ever armed for a command-loaded tree (see
        // `AppState.reload_command`'s own doc comment) — `laid_out`/
        // `event_rects` above are this same iteration's *pre-event*
        // layout, exactly the "before" picture `reloadFromCommand`/
        // `animateReload` need; a user action landing in the very same
        // ~100ms tick a reload also comes due in would tween from that
        // slightly stale layout rather than the zoom it just performed —
        // rare enough (reloads are seconds apart, input is instantaneous)
        // not to be worth the extra bookkeeping to avoid.
        if (state.reload_command != null and !state.reload_paused) {
            const now = std.Io.Clock.awake.now(init.io);
            // Required wait scales with how long the *previous* reload
            // actually took (doubled, as headroom), not a flat
            // `RELOAD_INTERVAL_MS` regardless of cost — a `ps_scan()`
            // sample (~70ms) keeps the normal cadence, but a multi-second
            // filesystem scan (`tree_scan()` against a large tree) would
            // otherwise come due again the instant it finishes: this
            // main loop only ever checks for new input between
            // iterations, so back-to-back multi-second reloads with no
            // idle gap between them made 'p'/'q' feel completely hung —
            // not literally unresponsive (a keypress sits buffered in the
            // pty and is read the moment the current reload returns),
            // but with no bound on how long that wait could be.
            const required_wait_ms = @max(RELOAD_INTERVAL_MS, state.last_reload_duration_ms * 2);
            const due = if (state.last_reload_ts) |lt|
                lt.durationTo(now).toMilliseconds() >= required_wait_ms
            else
                true;
            if (due) {
                const reload_area = Rect{ .x = 0, .y = 0, .w = term_area.width, .h = content_height };
                _ = try reloadFromCommand(
                    init.io,
                    allocator,
                    &terminal,
                    &state,
                    &loaded,
                    &owned_nodes,
                    &owned_shades,
                    &owned_keys,
                    &owned_derived,
                    laid_out,
                    event_rects,
                    reload_area,
                    area_cells,
                    min_cells,
                    start_ts,
                );
                // Stamped from *after* the (possibly multi-second,
                // blocking) reload call returns, not the stale
                // pre-call `now` — otherwise the elapsed time the scan
                // itself took already counted against the next
                // interval, defeating the whole point of pacing by it.
                const finished = std.Io.Clock.awake.now(init.io);
                state.last_reload_duration_ms = now.durationTo(finished).toMilliseconds();
                state.last_reload_ts = finished;
            }
        }

        const RenderCtx = struct { s: *AppState, elapsed_ms: i64 };
        var render_ctx = RenderCtx{ .s = &state, .elapsed_ms = start_ts.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds() };
        try terminal.draw(&render_ctx, struct {
            fn render(ctx: *RenderCtx, buf: *Buffer) !void {
                const s = ctx.s;
                const area = buf.getArea(); // rows x columns, read from the real terminal
                const render_content_height = if (area.height > STATUS_BAR_HEIGHT) area.height - STATUS_BAR_HEIGHT else area.height;
                const render_min_cells = minCells(render_content_height);
                const frame_totals = activeTotals(s);

                const render_laid_out = tree_lod.layoutTreeWithIndex(
                    s.nodes,
                    frame_totals,
                    s.child_index,
                    s.root,
                    area.width * render_content_height,
                    3,
                    render_min_cells,
                    OTHER_LABEL,
                    std.heap.page_allocator,
                ) catch return;
                defer std.heap.page_allocator.free(render_laid_out);

                // Row-wrapped rather than single-axis: a bucket with many
                // siblings (like README.md's 56-way root level) gets
                // wrapped into several rows instead of one strip of
                // ever-thinner slivers, and each row favors width over
                // squareness since labels read horizontally.
                const rects = tree_lod.placeRectsWrapped(
                    render_laid_out,
                    .{ .x = area.x, .y = area.y, .w = area.width, .h = render_content_height },
                    MIN_ROW_HEIGHT,
                    borderDepth(s),
                    std.heap.page_allocator,
                ) catch return;
                defer std.heap.page_allocator.free(rects);

                // Breadcrumb path for the root's own label, e.g.
                // "README.md/list" — every other node still shows its own
                // plain label. The currently *selected* child (what
                // down/enter would zoom into) is reported in the status
                // bar below instead of appended here — appending it here
                // too would just duplicate that, and unlike the status
                // bar's own name field, the breadcrumb has to stay a pure
                // navigation path since it's also literally what a click
                // on it zooms back out of one segment at a time.
                //
                // `click_selected_orig_index`, when set, takes priority: a
                // click on the root or on any node other than a fresh
                // rank-0 default should keep showing what was actually
                // clicked, not silently fall back to "whatever's at rank
                // 0" while it's still in scope. It's matched here by
                // `.orig_index`, the one thing that's stable across a
                // relayout — root included, since layoutTree always sets
                // the root entry's `.orig_index` to `s.root` itself.
                var path_buf: std.ArrayList(u8) = .empty;
                defer path_buf.deinit(std.heap.page_allocator);
                for (s.path.items, 0..) |seg, idx| {
                    if (idx > 0) path_buf.appendSlice(std.heap.page_allocator, "/") catch return;
                    path_buf.appendSlice(std.heap.page_allocator, seg) catch return;
                }
                const path_label = path_buf.items;

                // Status bar: the selected node's own label, how many
                // groups (interior/container nodes) and leaves it contains
                // — "G10,L3" — its own value, and its shade (see
                // `buildStatusLine`/`shadeLabel`) — plus, on the far
                // right, a live/paused indicator when auto-reload is
                // armed at all (see `connectionIndicator`).
                var status_buf: [256]u8 = undefined;
                const status_line = buildStatusLine(s, render_laid_out, &status_buf);
                const indicator = connectionIndicator(s, ctx.elapsed_ms);

                const canvas = Canvas.init(area, buf, Style{});
                drawEntries(canvas, buf, s, render_laid_out, rects, path_label);

                if (render_content_height < area.height) {
                    drawStatusBar(buf, area.x, area.y + render_content_height, area.width, status_line, indicator);
                }
            }
        }.render);
    }
}
