///! Scalar function: tp_snakemap_impl(values DOUBLE[], labels VARCHAR[], groups VARCHAR[], width BIGINT, height BIGINT, no_color BOOLEAN) → VARCHAR
///!
///! Two-level hierarchical treemap rendered with a boustrophedon (snake) layout.
///! Items are grouped by the groups[] array; each unique group (first-appearance
///! order) gets a heavy-border panel whose height is proportional to the group's
///! total value. Inside each panel the leaves are rendered with the snake layout.
///! All panels are wrapped in a double-border root box.
///!
///! SQL-level function tp_snakemap wraps with named params and defaults:
///!
///!   tp_snakemap(vals, labels, groups)
///!   tp_snakemap(vals, labels, groups, width := 80, height := 24, no_color := false)
const std = @import("std");
const db = @import("../lib/duckdb.zig");
const canvas_lib = @import("../lib/canvas.zig");
const snake = @import("../lib/snake.zig");
const box = @import("../lib/box.zig");

pub fn tpSnakemapExec(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
    _ = info;
    const chunk_size = db.dataChunkGetSize(input);

    const val_list_vec = db.dataChunkGetVector(input, 0);
    const lbl_list_vec = db.dataChunkGetVector(input, 1);
    const grp_list_vec = db.dataChunkGetVector(input, 2);
    const width_vec = db.dataChunkGetVector(input, 3);
    const height_vec = db.dataChunkGetVector(input, 4);
    const no_color_vec = db.dataChunkGetVector(input, 5);

    // SAFETY: DuckDB guarantees list vector data layout is [*]duckdb_list_entry.
    const val_entries: [*]db.ListEntry = @ptrCast(@alignCast(db.vectorGetData(val_list_vec)));
    const lbl_entries: [*]db.ListEntry = @ptrCast(@alignCast(db.vectorGetData(lbl_list_vec)));
    const grp_entries: [*]db.ListEntry = @ptrCast(@alignCast(db.vectorGetData(grp_list_vec)));
    // SAFETY: BIGINT data is [*]i64; BOOLEAN data is [*]u8 (0=false, 1=true).
    const width_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(width_vec)));
    const height_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(height_vec)));
    const no_color_data: [*]u8 = @ptrCast(@alignCast(db.vectorGetData(no_color_vec)));

    const val_child = db.listVectorGetChild(val_list_vec);
    const lbl_child = db.listVectorGetChild(lbl_list_vec);
    const grp_child = db.listVectorGetChild(grp_list_vec);
    // SAFETY: DOUBLE child data is [*]f64; VARCHAR child data is [*]duckdb_string_t.
    const val_data: [*]f64 = @ptrCast(@alignCast(db.vectorGetData(val_child)));
    const lbl_data: [*]db.StringT = @ptrCast(@alignCast(db.vectorGetData(lbl_child)));
    const grp_data: [*]db.StringT = @ptrCast(@alignCast(db.vectorGetData(grp_child)));

    const val_v = db.vectorGetValidity(val_list_vec);
    const lbl_v = db.vectorGetValidity(lbl_list_vec);
    const grp_v = db.vectorGetValidity(grp_list_vec);
    const w_v = db.vectorGetValidity(width_vec);
    const h_v = db.vectorGetValidity(height_vec);
    const nc_v = db.vectorGetValidity(no_color_vec);
    const has_nulls = val_v != null or lbl_v != null or grp_v != null or
        w_v != null or h_v != null or nc_v != null;

    if (has_nulls) {
        db.vectorEnsureValidityWritable(output);
        const out_v = db.vectorGetValidity(output).?;
        for (0..chunk_size) |row| {
            if (db.validityRowIsValid(val_v, row) and
                db.validityRowIsValid(lbl_v, row) and
                db.validityRowIsValid(grp_v, row) and
                db.validityRowIsValid(w_v, row) and
                db.validityRowIsValid(h_v, row) and
                db.validityRowIsValid(nc_v, row))
            {
                writeRow(val_entries, val_data, lbl_entries, lbl_data, grp_entries, grp_data, width_data, height_data, no_color_data, row, output);
            } else {
                db.validitySetRowInvalid(out_v, row);
            }
        }
    } else {
        for (0..chunk_size) |row| {
            writeRow(val_entries, val_data, lbl_entries, lbl_data, grp_entries, grp_data, width_data, height_data, no_color_data, row, output);
        }
    }
}

/// Per-group accumulator. Built with ArenaAllocator — no explicit deinit needed.
/// Uses unmanaged ArrayList (Zig 0.16): all mutating calls take an explicit allocator.
const GroupData = struct {
    name: []const u8,
    vals: std.ArrayList(f64),
    labs: std.ArrayList([]const u8),
    total: f64,

    fn init(name: []const u8) GroupData {
        return .{
            .name = name,
            .vals = .empty,
            .labs = .empty,
            .total = 0.0,
        };
    }
};

fn writeRow(
    val_entries: [*]db.ListEntry,
    val_data: [*]f64,
    lbl_entries: [*]db.ListEntry,
    lbl_data: [*]db.StringT,
    grp_entries: [*]db.ListEntry,
    grp_data: [*]db.StringT,
    width_data: [*]i64,
    height_data: [*]i64,
    no_color_data: [*]u8,
    row: usize,
    output: db.Vector,
) void {
    const w_raw = width_data[row];
    const h_raw = height_data[row];
    if (w_raw <= 0 or h_raw <= 0) {
        db.vectorAssignStringElement(output, row, "");
        return;
    }
    const cw: usize = @intCast(@min(w_raw, 512));
    const ch: usize = @intCast(@min(h_raw, 256));
    const no_color = no_color_data[row] != 0;

    const ve = val_entries[row];
    if (ve.length == 0) {
        db.vectorAssignStringElement(output, row, "");
        return;
    }
    const n = ve.length;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const le = lbl_entries[row];
    const ge = grp_entries[row];

    const values = allocator.alloc(f64, n) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };
    const labels = allocator.alloc([]const u8, n) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };
    const groups = allocator.alloc([]const u8, n) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };
    for (0..n) |i| {
        values[i] = val_data[ve.offset + i];
        labels[i] = if (i < le.length) db.stringSlice(&lbl_data[le.offset + i]) else "";
        groups[i] = if (i < ge.length) db.stringSlice(&grp_data[ge.offset + i]) else "";
    }

    const rendered = renderSnakemap(allocator, values, labels, groups, cw, ch, no_color) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };
    db.vectorAssignStringElementLen(output, row, rendered.ptr, rendered.len);
}

/// Render a two-level (group > leaf) snake-layout treemap from pre-decoded
/// values. `labels`/`groups` must be the same length as `values`. Caller
/// owns the returned slice. Returns an empty slice for degenerate inputs
/// (empty values, zero groups, canvas too small for the root band) — the
/// same "" fallback vectorized callers used to write directly before this
/// was extracted out of tp_snakemap's own writeRow into a reusable,
/// DuckDB-API-free function (pure Zig, in reach of the v2 port without
/// duplicating ~150 lines of grouping/rendering logic).
pub fn renderSnakemap(
    allocator: std.mem.Allocator,
    values: []const f64,
    labels: []const []const u8,
    groups: []const []const u8,
    cw: usize,
    ch: usize,
    no_color: bool,
) ![]u8 {
    const n = values.len;
    if (n == 0) return allocator.alloc(u8, 0);

    // Collect unique groups in first-appearance order, accumulating items.
    // Zig 0.16 unmanaged ArrayList: .empty initialiser, every mutating call takes allocator.
    var groups_list: std.ArrayList(GroupData) = .empty;

    for (0..n) |i| {
        const val = @max(0.0, values[i]);
        const lbl = labels[i];
        const grp_name = groups[i];

        var found_gi: ?usize = null;
        for (groups_list.items, 0..) |g, j| {
            if (std.mem.eql(u8, g.name, grp_name)) {
                found_gi = j;
                break;
            }
        }
        if (found_gi == null) {
            found_gi = groups_list.items.len;
            try groups_list.append(allocator, GroupData.init(grp_name));
        }
        const gi = found_gi.?;
        try groups_list.items[gi].vals.append(allocator, val);
        try groups_list.items[gi].labs.append(allocator, lbl);
        groups_list.items[gi].total += val;
    }

    const n_groups = groups_list.items.len;
    if (n_groups == 0) return allocator.alloc(u8, 0);

    // Need at least 3 rows for the root border + 1 inner row, and width ≥ 4
    // so the leaf sub-canvas (cw-4) is non-zero. Groups that are too small for
    // a box simply render in fill mode.
    if (ch < 3 or cw < 4) return allocator.alloc(u8, 0);

    // Root inner dimensions (inside the double border).
    const inner_w: usize = cw - 2;
    const inner_h: usize = ch - 2;

    // Collect group totals and let snake.layout position the group panels
    // on the inner canvas, using the same boustrophedon algorithm as leaves.
    var group_totals: std.ArrayList(f64) = .empty;
    for (groups_list.items) |g| {
        try group_totals.append(allocator, g.total);
    }
    const group_coils = try snake.layout(group_totals.items, inner_w, inner_h, allocator);

    // Build master canvas.
    var master = try canvas_lib.Canvas.init(allocator, cw, ch);
    master.no_color = no_color;

    // Root: double-border box spanning the full canvas.
    canvas_lib.drawBox(&master, 0, 0, cw - 1, ch - 1, box.DOUBLE, box.DOUBLE, 7);

    // Render each group from its coil on the inner canvas.
    for (0..n_groups) |gi| {
        const g = &groups_list.items[gi];
        const coil = group_coils[gi];
        if (coil.start >= coil.end) continue;

        // Determine how many full-width rows this coil spans.
        // A "full row" is a row where the coil occupies every column.
        const first_row_coil = coil.start / inner_w;
        const last_row_coil = (coil.end - 1) / inner_w;
        const first_row_is_full = (coil.start % inner_w == 0);
        const last_row_is_full = ((coil.end - 1) % inner_w == inner_w - 1);

        const first_full_row: usize = if (first_row_is_full) first_row_coil else first_row_coil + 1;
        const last_full_row: usize = blk: {
            if (last_row_is_full) break :blk last_row_coil;
            if (last_row_coil > 0) break :blk last_row_coil - 1;
            break :blk 0; // triggers fill mode via full_row_count == 0
        };
        const full_row_count: usize = if (first_full_row <= last_full_row)
            last_full_row - first_full_row + 1
        else
            0;

        if (full_row_count < 3) {
            // Fill mode: group is too narrow for a box. Shade all coil cells and
            // write the group name on the widest row.
            renderGroupFill(&master, coil, inner_w, first_row_coil, last_row_coil, g.name, gi);
        } else {
            // Box mode: fill partial rows at coil top/bottom with the group shade
            // char, then draw a heavy box around the full-rows band and leaf-render
            // inside it.
            const fill_chars_grp = [_]u21{ '░', '▒', '▓' };
            const fill_char_grp = fill_chars_grp[gi % fill_chars_grp.len];

            // Partial first row: shade cells belonging to this group.
            if (!first_row_is_full) {
                const row_end = (first_row_coil + 1) * inner_w;
                for (coil.start..row_end) |k| {
                    const xy = snake.snakeToXY(k, inner_w);
                    master.put(xy.col + 1, xy.row + 1, fill_char_grp, 7);
                }
            }
            // Partial last row: shade cells belonging to this group.
            if (!last_row_is_full) {
                const row_start = last_row_coil * inner_w;
                for (row_start..coil.end) |k| {
                    const xy = snake.snakeToXY(k, inner_w);
                    master.put(xy.col + 1, xy.row + 1, fill_char_grp, 7);
                }
            }

            // Heavy box around the full-rows band (+1 offset for root border).
            const gy0 = first_full_row + 1;
            const gy1 = last_full_row + 1;
            canvas_lib.drawBox(&master, 1, gy0, cw - 2, gy1, box.HEAVY, box.HEAVY, 7);
            writeLabelInBorder(&master, 3, gy0, g.name, cw - 2, 7);

            // Leaf sub-canvas inside the box (height guaranteed ≥ 1 when full_row_count ≥ 3).
            const sub_w: usize = cw - 4;
            const sub_h: usize = gy1 - gy0 - 1;
            if (sub_w > 0 and sub_h > 0) {
                var sub = canvas_lib.Canvas.init(allocator, sub_w, sub_h) catch continue;
                const leaf_coils = snake.layout(g.vals.items, sub_w, sub_h, allocator) catch continue;
                snake.renderCoils(&sub, leaf_coils, g.labs.items, allocator) catch continue;
                canvas_lib.blit(&master, &sub, 2, gy0 + 1);
            }
        }
    }

    return master.render(allocator);
}

/// Fill all cells of a group coil with a shade character and write the group
/// name on the widest row. Used when the coil has fewer than 3 full rows.
fn renderGroupFill(
    c: *canvas_lib.Canvas,
    coil: snake.Coil,
    inner_w: usize,
    first_row: usize,
    last_row: usize,
    name: []const u8,
    group_index: usize,
) void {
    const fill_chars = [_]u21{ '░', '▒', '▓' };
    const fill_char = fill_chars[group_index % fill_chars.len];

    for (coil.start..coil.end) |k| {
        const xy = snake.snakeToXY(k, inner_w);
        c.put(xy.col + 1, xy.row + 1, fill_char, 7);
    }
    if (name.len == 0) return;

    // Find the widest row and its leftmost column for the label.
    var best_span: usize = 0;
    var best_row: usize = first_row;
    var best_left: usize = 0;
    for (first_row..last_row + 1) |r| {
        const row_start = r * inner_w;
        const seg_start = @max(coil.start, row_start);
        const seg_end = @min(coil.end, row_start + inner_w);
        if (seg_end <= seg_start) continue;
        const span = seg_end - seg_start;
        if (span > best_span) {
            best_span = span;
            best_row = r;
            // Leftmost canvas column of this row's cells.
            // Even row (L→R): first cell is at the start offset.
            // Odd row (R→L): cells run right-to-left; leftmost col = inner_w - span.
            best_left = if (r % 2 == 0)
                seg_start - row_start
            else
                inner_w - (seg_end - row_start);
        }
    }
    if (best_span < 2) return;
    // Write group name into the fill area. +1 for root border offset; the
    // label starts one cell in from the fill's left edge.
    writeLabelInBorder(c, best_left + 2, best_row + 1, name, best_left + best_span + 1, 7);
}

/// Write a group name into the top border of a heavy box.
/// Format: after corner at x0 and one ━ spacer, place the label starting at
/// label_x. Truncates with '…' if the label would overwrite the right corner.
/// right_corner_x is the x-coordinate of the '┓' corner (gx1).
fn writeLabelInBorder(c: *canvas_lib.Canvas, label_x: usize, y: usize, text: []const u8, right_corner_x: usize, color: u8) void {
    if (text.len == 0 or label_x >= right_corner_x) return;
    // Maximum columns available: from label_x up to (but not including) the right corner,
    // leaving one ━ spacer before it.
    const max_cols: usize = if (right_corner_x >= label_x + 2) right_corner_x - label_x - 1 else 0;
    if (max_cols == 0) return;

    // Count total codepoints in text.
    var cp_count: usize = 0;
    var bi: usize = 0;
    while (bi < text.len) {
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[bi]) catch 1;
        cp_count += 1;
        bi += seq_len;
    }

    var col = label_x;
    if (cp_count <= max_cols) {
        bi = 0;
        while (bi < text.len and col < c.width) {
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[bi]) catch 1;
            const safe_end = @min(bi + seq_len, text.len);
            const cp = std.unicode.utf8Decode(text[bi..safe_end]) catch '?';
            c.put(col, y, cp, color);
            col += 1;
            bi += seq_len;
        }
    } else if (max_cols >= 2) {
        bi = 0;
        var written: usize = 0;
        while (bi < text.len and written < max_cols - 1) {
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[bi]) catch 1;
            const safe_end = @min(bi + seq_len, text.len);
            const cp = std.unicode.utf8Decode(text[bi..safe_end]) catch '?';
            c.put(col, y, cp, color);
            col += 1;
            written += 1;
            bi += seq_len;
        }
        c.put(col, y, '…', color);
    } else {
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        const safe_end = @min(seq_len, text.len);
        const cp = std.unicode.utf8Decode(text[0..safe_end]) catch '?';
        c.put(col, y, cp, color);
    }
}

pub fn register(conn: db.Connection) !void {
    const function = db.createScalarFunction();
    defer db.destroyScalarFunction(@constCast(&function));

    db.scalarFunctionSetName(function, "tp_snakemap_impl");

    var double_type = db.createLogicalType(db.c.DUCKDB_TYPE_DOUBLE);
    defer db.destroyLogicalType(&double_type);
    var varchar_type = db.createLogicalType(db.c.DUCKDB_TYPE_VARCHAR);
    defer db.destroyLogicalType(&varchar_type);
    var bigint_type = db.createLogicalType(db.c.DUCKDB_TYPE_BIGINT);
    defer db.destroyLogicalType(&bigint_type);
    var bool_type = db.createLogicalType(db.c.DUCKDB_TYPE_BOOLEAN);
    defer db.destroyLogicalType(&bool_type);

    var double_list = db.createListType(double_type);
    defer db.destroyLogicalType(&double_list);
    var varchar_list = db.createListType(varchar_type);
    defer db.destroyLogicalType(&varchar_list);

    db.scalarFunctionAddParameter(function, double_list);
    db.scalarFunctionAddParameter(function, varchar_list);
    db.scalarFunctionAddParameter(function, varchar_list);
    db.scalarFunctionAddParameter(function, bigint_type);
    db.scalarFunctionAddParameter(function, bigint_type);
    db.scalarFunctionAddParameter(function, bool_type);
    db.scalarFunctionSetReturnType(function, varchar_type);
    db.scalarFunctionSetFunction(function, &tpSnakemapExec);

    if (db.registerScalarFunction(conn, function) == db.DuckDBError) {
        return error.FailedToRegisterFunction;
    }

    var result: db.Result = undefined;
    defer db.destroyResult(&result);
    if (db.query(
        conn,
        "CREATE OR REPLACE MACRO tp_snakemap(vals, labels, groups, width := 80, height := 24, no_color := false) AS tp_snakemap_impl(vals, labels, groups, width, height, no_color)",
        &result,
    ) == db.DuckDBError) {
        return error.FailedToRegisterMacro;
    }
}
