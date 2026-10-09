///! Scalar function: tp_treemap(values DOUBLE[], labels VARCHAR[], width BIGINT := 80, height BIGINT := 24) -> VARCHAR
///!
///! v2 port of tp_treemap.zig. Drops the SQL-macro default-param workaround
///! (same as tp_bar_v2/tp_line_v2 — v2 has real defaults natively).
///! Combines LIST(DOUBLE) (proven in tp_line_v2) with LIST(VARCHAR) — same
///! vector_get_child + list_entry mechanism, decoding the child as
///! BytesValue/bytesSlice instead of raw f64. Reuses canvas/snake unchanged
///! (pure Zig, no DuckDB API dependency either version needs to duplicate).
const std = @import("std");
const db = @import("duckdb_v2");
const canvas_lib = @import("../lib/canvas.zig");
const snake = @import("../lib/snake.zig");

fn exec(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    var row_count: db.idx_t = 0;
    if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var val_list_vec: db.VectorHandle = undefined;
    var lbl_list_vec: db.VectorHandle = undefined;
    var width_vec: db.VectorHandle = undefined;
    var height_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetArg(info, 0, &val_list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 1, &lbl_list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 2, &width_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 3, &height_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(val_list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(lbl_list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(width_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(height_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var val_list_view: db.VectorView = undefined;
    var lbl_list_view: db.VectorView = undefined;
    var width_view: db.VectorView = undefined;
    var height_view: db.VectorView = undefined;
    if (db.vectorGetView(val_list_vec, &val_list_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(lbl_list_vec, &lbl_list_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(width_vec, &width_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(height_vec, &height_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var val_child: db.VectorHandle = undefined;
    var lbl_child: db.VectorHandle = undefined;
    if (db.vectorGetChild(val_list_vec, 0, &val_child, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetChild(lbl_list_vec, 0, &lbl_child, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(val_child, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(lbl_child, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    var val_child_view: db.VectorView = undefined;
    var lbl_child_view: db.VectorView = undefined;
    if (db.vectorGetView(val_child, &val_child_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(lbl_child, &lbl_child_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    // SAFETY: the signature registered these as (LIST(DOUBLE), LIST(VARCHAR), BIGINT, BIGINT) -> VARCHAR.
    const val_entries: [*]const db.ListEntry = @ptrCast(@alignCast(val_list_view.data));
    const lbl_entries: [*]const db.ListEntry = @ptrCast(@alignCast(lbl_list_view.data));
    const width_data: [*]const i64 = @ptrCast(@alignCast(width_view.data));
    const height_data: [*]const i64 = @ptrCast(@alignCast(height_view.data));
    const val_data: [*]const f64 = @ptrCast(@alignCast(val_child_view.data));
    const lbl_data: [*]const db.BytesValue = @ptrCast(@alignCast(lbl_child_view.data));

    var row: db.idx_t = 0;
    while (row < row_count) : (row += 1) {
        if ((val_list_view.validity != null and !isValid(val_list_view.validity.?, row)) or
            (lbl_list_view.validity != null and !isValid(lbl_list_view.validity.?, row)) or
            (width_view.validity != null and !isValid(width_view.validity.?, row)) or
            (height_view.validity != null and !isValid(height_view.validity.?, row)))
        {
            if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            continue;
        }
        if (!writeRow(val_entries, val_data, lbl_entries, lbl_data, width_data, height_data, row, result_vec, context, err)) return;
    }
}

fn writeRow(
    val_entries: [*]const db.ListEntry,
    val_data: [*]const f64,
    lbl_entries: [*]const db.ListEntry,
    lbl_data: [*]const db.BytesValue,
    width_data: [*]const i64,
    height_data: [*]const i64,
    row: db.idx_t,
    result_vec: db.VectorHandle,
    context: db.ContextHandle,
    err: [*c]db.ErrorInfoHandle,
) bool {
    const w_raw = width_data[row];
    const h_raw = height_data[row];
    const ve = val_entries[row];
    if (w_raw <= 0 or h_raw <= 0 or ve.length == 0) return writeText(result_vec, row, context, "", err);

    const cw: usize = @intCast(@min(w_raw, 512));
    const ch: usize = @intCast(@min(h_raw, 256));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const n = ve.length;
    const labels_buf = allocator.alloc([]const u8, n) catch return writeText(result_vec, row, context, "", err);
    const le = lbl_entries[row];
    for (0..n) |i| {
        labels_buf[i] = if (i < le.length) db.bytesSlice(&lbl_data[le.offset + i]) else "";
    }

    const values = val_data[ve.offset .. ve.offset + n];

    var c = canvas_lib.Canvas.init(allocator, cw, ch) catch return writeText(result_vec, row, context, "", err);
    const coils = snake.layout(values, cw, ch, allocator) catch return writeText(result_vec, row, context, "", err);
    snake.renderCoils(&c, coils, labels_buf, allocator) catch return writeText(result_vec, row, context, "", err);
    const rendered = c.render(allocator) catch return writeText(result_vec, row, context, "", err);

    return writeText(result_vec, row, context, rendered, err);
}

fn writeText(result_vec: db.VectorHandle, row: db.idx_t, context: db.ContextHandle, text: []const u8, err: [*c]db.ErrorInfoHandle) bool {
    var value: db.ValueHandle = undefined;
    if (db.valueCreateVarcharWithContext(context, text, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return false;
    defer _ = db.valueDestroy(&value);
    return db.vectorSetValue(result_vec, row, value, err) == db.c.DUCKDB_V2_ERROR_NONE;
}

inline fn isValid(validity: [*]const u64, row: db.idx_t) bool {
    const entry_idx = row / 64;
    const bit_idx: u6 = @intCast(row % 64);
    return (validity[entry_idx] & (@as(u64, 1) << bit_idx)) != 0;
}

/// Register the tp_treemap scalar function against the v2 extension being loaded.
pub fn register(input: *const db.ExtensionInput) !void {
    var err: db.ErrorInfoHandle = undefined;

    var function: db.ScalarFunctionHandle = undefined;
    if (db.scalarFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = db.scalarFunctionDestroy(&function);

    const fn_name = db.str("tp_treemap");
    if (db.scalarFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetName;
    }

    var double_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_DOUBLE, &double_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateType;
    defer _ = db.logicalTypeDestroy(&double_type);
    var varchar_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateType;
    defer _ = db.logicalTypeDestroy(&varchar_type);
    var bigint_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateType;
    defer _ = db.logicalTypeDestroy(&bigint_type);
    var double_list: db.LogicalTypeHandle = undefined;
    if (db.contextCreateListType(input.context, double_type, &double_list, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateType;
    defer _ = db.logicalTypeDestroy(&double_list);
    var varchar_list: db.LogicalTypeHandle = undefined;
    if (db.contextCreateListType(input.context, varchar_type, &varchar_list, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateType;
    defer _ = db.logicalTypeDestroy(&varchar_list);

    var sig: db.FunctionSignatureHandle = undefined;
    if (db.scalarFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const vals_name = db.str("vals");
    if (db.functionSignatureAddParameter(sig, &vals_name, double_list, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToAddParameter;
    const labels_name = db.str("labels");
    if (db.functionSignatureAddParameter(sig, &labels_name, varchar_list, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToAddParameter;

    var width_default: db.ValueHandle = undefined;
    if (db.valueCreateBigintWithContext(input.context, 80, &width_default, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = db.valueDestroy(&width_default);
    const width_name = db.str("width");
    if (db.functionSignatureAddParameter(sig, &width_name, bigint_type, width_default, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToAddParameter;

    var height_default: db.ValueHandle = undefined;
    if (db.valueCreateBigintWithContext(input.context, 24, &height_default, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = db.valueDestroy(&height_default);
    const height_name = db.str("height");
    if (db.functionSignatureAddParameter(sig, &height_name, bigint_type, height_default, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToAddParameter;

    if (db.functionSignatureSetReturnType(sig, varchar_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetReturnType;
    }

    if (db.scalarFunctionSetExecCallback(function, exec, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetExecCallback;
    }

    if (db.scalarFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}
