///! Scalar function: tp_treemap_impl(values DOUBLE[], labels VARCHAR[], width BIGINT, height BIGINT) → VARCHAR
///!
///! Renders LIST(DOUBLE) values as a boustrophedon treemap on a Unicode Canvas.
///! Each item's area is proportional to its value.  Outlined with thin box-drawing
///! chars, interior filled with block shading, label truncated with '…' to fit.
///!
///! SQL-level function tp_treemap wraps with named params and defaults:
///!
///!   tp_treemap([1.0, 2.0, 3.0], ['small', 'medium', 'large'])
///!   tp_treemap([1.0, 2.0], ['a', 'b'], width := 40, height := 12)
const std = @import("std");
const db = @import("../lib/duckdb.zig");
const canvas_lib = @import("../lib/canvas.zig");
const snake = @import("../lib/snake.zig");

/// Vectorized execute callback for tp_treemap_impl.
pub fn tpTreemapExec(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
    _ = info;
    const chunk_size = db.dataChunkGetSize(input);

    const val_list_vec = db.dataChunkGetVector(input, 0);
    const lbl_list_vec = db.dataChunkGetVector(input, 1);
    const width_vec = db.dataChunkGetVector(input, 2);
    const height_vec = db.dataChunkGetVector(input, 3);

    // SAFETY: DuckDB guarantees list vector data layout is [*]duckdb_list_entry.
    const val_entries: [*]db.ListEntry = @ptrCast(@alignCast(db.vectorGetData(val_list_vec)));
    const lbl_entries: [*]db.ListEntry = @ptrCast(@alignCast(db.vectorGetData(lbl_list_vec)));
    // SAFETY: BIGINT vector data is [*]i64.
    const width_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(width_vec)));
    const height_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(height_vec)));

    const val_child = db.listVectorGetChild(val_list_vec);
    const lbl_child = db.listVectorGetChild(lbl_list_vec);
    // SAFETY: DOUBLE child data is [*]f64; VARCHAR child data is [*]duckdb_string_t.
    const val_data: [*]f64 = @ptrCast(@alignCast(db.vectorGetData(val_child)));
    const lbl_data: [*]db.StringT = @ptrCast(@alignCast(db.vectorGetData(lbl_child)));

    const val_v = db.vectorGetValidity(val_list_vec);
    const lbl_v = db.vectorGetValidity(lbl_list_vec);
    const w_v = db.vectorGetValidity(width_vec);
    const h_v = db.vectorGetValidity(height_vec);
    const has_nulls = val_v != null or lbl_v != null or w_v != null or h_v != null;

    if (has_nulls) {
        db.vectorEnsureValidityWritable(output);
        const out_v = db.vectorGetValidity(output).?;
        for (0..chunk_size) |row| {
            if (db.validityRowIsValid(val_v, row) and
                db.validityRowIsValid(lbl_v, row) and
                db.validityRowIsValid(w_v, row) and
                db.validityRowIsValid(h_v, row))
            {
                writeRow(val_entries, val_data, lbl_entries, lbl_data, width_data, height_data, row, output);
            } else {
                db.validitySetRowInvalid(out_v, row);
            }
        }
    } else {
        for (0..chunk_size) |row| {
            writeRow(val_entries, val_data, lbl_entries, lbl_data, width_data, height_data, row, output);
        }
    }
}

fn writeRow(
    val_entries: [*]db.ListEntry,
    val_data: [*]f64,
    lbl_entries: [*]db.ListEntry,
    lbl_data: [*]db.StringT,
    width_data: [*]i64,
    height_data: [*]i64,
    row: usize,
    output: db.Vector,
) void {
    const w_raw = width_data[row];
    const h_raw = height_data[row];
    if (w_raw <= 0 or h_raw <= 0) {
        db.vectorAssignStringElement(output, row, "");
        return;
    }
    // Cap to reasonable maxima to bound arena allocation size.
    const cw: usize = @intCast(@min(w_raw, 512));
    const ch: usize = @intCast(@min(h_raw, 256));

    const ve = val_entries[row];
    if (ve.length == 0) {
        db.vectorAssignStringElement(output, row, "");
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build labels slice, aligning length to the values slice.
    const n = ve.length;
    const labels_buf = allocator.alloc([]const u8, n) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };
    const le = lbl_entries[row];
    for (0..n) |i| {
        labels_buf[i] = if (i < le.length)
            db.stringSlice(&lbl_data[le.offset + i])
        else
            "";
    }

    const values = val_data[ve.offset .. ve.offset + n];

    var c = canvas_lib.Canvas.init(allocator, cw, ch) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };

    const coils = snake.layout(values, cw, ch, allocator) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };

    snake.renderCoils(&c, coils, labels_buf, allocator) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };

    const rendered = c.render(allocator) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };

    db.vectorAssignStringElementLen(output, row, rendered.ptr, rendered.len);
}

/// Register tp_treemap_impl (scalar) and tp_treemap (SQL macro with named params/defaults).
pub fn register(conn: db.Connection) !void {
    const function = db.createScalarFunction();
    defer db.destroyScalarFunction(@constCast(&function));

    db.scalarFunctionSetName(function, "tp_treemap_impl");

    var double_type = db.createLogicalType(db.c.DUCKDB_TYPE_DOUBLE);
    defer db.destroyLogicalType(&double_type);
    var varchar_type = db.createLogicalType(db.c.DUCKDB_TYPE_VARCHAR);
    defer db.destroyLogicalType(&varchar_type);
    var bigint_type = db.createLogicalType(db.c.DUCKDB_TYPE_BIGINT);
    defer db.destroyLogicalType(&bigint_type);

    var double_list = db.createListType(double_type);
    defer db.destroyLogicalType(&double_list);
    var varchar_list = db.createListType(varchar_type);
    defer db.destroyLogicalType(&varchar_list);

    db.scalarFunctionAddParameter(function, double_list);
    db.scalarFunctionAddParameter(function, varchar_list);
    db.scalarFunctionAddParameter(function, bigint_type);
    db.scalarFunctionAddParameter(function, bigint_type);
    db.scalarFunctionSetReturnType(function, varchar_type);
    db.scalarFunctionSetFunction(function, &tpTreemapExec);

    if (db.registerScalarFunction(conn, function) == db.DuckDBError) {
        return error.FailedToRegisterFunction;
    }

    var result: db.Result = undefined;
    defer db.destroyResult(&result);
    if (db.query(
        conn,
        "CREATE OR REPLACE MACRO tp_treemap(vals, labels, width := 80, height := 24) AS tp_treemap_impl(vals, labels, width, height)",
        &result,
    ) == db.DuckDBError) {
        return error.FailedToRegisterMacro;
    }
}
