///! Scalar function: tp_snakemap(values DOUBLE[], labels VARCHAR[], groups VARCHAR[], width BIGINT := 80, height BIGINT := 24, no_color BOOLEAN := false) -> VARCHAR
///!
///! v2 port of tp_snakemap.zig. Drops the SQL-macro default-param workaround
///! (same as the other tp_* ports). Adds a third parallel LIST(VARCHAR) and
///! the first live v2 BOOLEAN test (comptime_scalar_v2 maps `bool` already,
///! but this is the first time a bool-typed argument actually runs against
///! the real runtime) — otherwise the same vector_get_child + list_entry
///! mechanism tp_treemap_v2 already proved for parallel LIST arguments.
///!
///! Calls renderSnakemap (extracted out of tp_snakemap.zig's own writeRow
///! into a reusable, DuckDB-API-free function as part of this port — see
///! that function's doc comment) instead of duplicating ~150 lines of
///! grouping/rendering logic.
const std = @import("std");
const db = @import("duckdb_v2");
const renderSnakemap = @import("tp_snakemap.zig").renderSnakemap;

fn exec(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    var row_count: db.idx_t = 0;
    if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var val_list_vec: db.VectorHandle = undefined;
    var lbl_list_vec: db.VectorHandle = undefined;
    var grp_list_vec: db.VectorHandle = undefined;
    var width_vec: db.VectorHandle = undefined;
    var height_vec: db.VectorHandle = undefined;
    var no_color_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetArg(info, 0, &val_list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 1, &lbl_list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 2, &grp_list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 3, &width_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 4, &height_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 5, &no_color_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    inline for (.{ val_list_vec, lbl_list_vec, grp_list_vec, width_vec, height_vec, no_color_vec }) |v| {
        if (db.vectorFlatten(v, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    }

    var val_list_view: db.VectorView = undefined;
    var lbl_list_view: db.VectorView = undefined;
    var grp_list_view: db.VectorView = undefined;
    var width_view: db.VectorView = undefined;
    var height_view: db.VectorView = undefined;
    var no_color_view: db.VectorView = undefined;
    if (db.vectorGetView(val_list_vec, &val_list_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(lbl_list_vec, &lbl_list_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(grp_list_vec, &grp_list_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(width_vec, &width_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(height_vec, &height_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(no_color_vec, &no_color_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var val_child: db.VectorHandle = undefined;
    var lbl_child: db.VectorHandle = undefined;
    var grp_child: db.VectorHandle = undefined;
    if (db.vectorGetChild(val_list_vec, 0, &val_child, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetChild(lbl_list_vec, 0, &lbl_child, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetChild(grp_list_vec, 0, &grp_child, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    inline for (.{ val_child, lbl_child, grp_child }) |v| {
        if (db.vectorFlatten(v, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    }
    var val_child_view: db.VectorView = undefined;
    var lbl_child_view: db.VectorView = undefined;
    var grp_child_view: db.VectorView = undefined;
    if (db.vectorGetView(val_child, &val_child_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(lbl_child, &lbl_child_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(grp_child, &grp_child_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    // SAFETY: the signature registered these as
    // (LIST(DOUBLE), LIST(VARCHAR), LIST(VARCHAR), BIGINT, BIGINT, BOOLEAN) -> VARCHAR.
    const val_entries: [*]const db.ListEntry = @ptrCast(@alignCast(val_list_view.data));
    const lbl_entries: [*]const db.ListEntry = @ptrCast(@alignCast(lbl_list_view.data));
    const grp_entries: [*]const db.ListEntry = @ptrCast(@alignCast(grp_list_view.data));
    const width_data: [*]const i64 = @ptrCast(@alignCast(width_view.data));
    const height_data: [*]const i64 = @ptrCast(@alignCast(height_view.data));
    const no_color_data: [*]const bool = @ptrCast(@alignCast(no_color_view.data));
    const val_data: [*]const f64 = @ptrCast(@alignCast(val_child_view.data));
    const lbl_data: [*]const db.BytesValue = @ptrCast(@alignCast(lbl_child_view.data));
    const grp_data: [*]const db.BytesValue = @ptrCast(@alignCast(grp_child_view.data));

    var row: db.idx_t = 0;
    while (row < row_count) : (row += 1) {
        if (anyInvalid(&.{ val_list_view, lbl_list_view, grp_list_view, width_view, height_view, no_color_view }, row)) {
            if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            continue;
        }

        const w_raw = width_data[row];
        const h_raw = height_data[row];
        const ve = val_entries[row];
        if (w_raw <= 0 or h_raw <= 0 or ve.length == 0) {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        }

        const cw: usize = @intCast(@min(w_raw, 512));
        const ch: usize = @intCast(@min(h_raw, 256));
        const no_color = no_color_data[row];

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const n = ve.length;
        const le = lbl_entries[row];
        const ge = grp_entries[row];

        const values = allocator.alloc(f64, n) catch {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        };
        const labels = allocator.alloc([]const u8, n) catch {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        };
        const groups = allocator.alloc([]const u8, n) catch {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        };
        for (0..n) |i| {
            values[i] = val_data[ve.offset + i];
            labels[i] = if (i < le.length) db.bytesSlice(&lbl_data[le.offset + i]) else "";
            groups[i] = if (i < ge.length) db.bytesSlice(&grp_data[ge.offset + i]) else "";
        }

        const rendered = renderSnakemap(allocator, values, labels, groups, cw, ch, no_color) catch {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        };
        if (!writeText(result_vec, row, context, rendered, err)) return;
    }
}

fn writeText(result_vec: db.VectorHandle, row: db.idx_t, context: db.ContextHandle, text: []const u8, err: [*c]db.ErrorInfoHandle) bool {
    var value: db.ValueHandle = undefined;
    if (db.valueCreateVarcharWithContext(context, text, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return false;
    defer _ = db.valueDestroy(&value);
    return db.vectorSetValue(result_vec, row, value, err) == db.c.DUCKDB_V2_ERROR_NONE;
}

fn anyInvalid(views: []const db.VectorView, row: db.idx_t) bool {
    for (views) |v| {
        if (v.validity) |validity| {
            const entry_idx = row / 64;
            const bit_idx: u6 = @intCast(row % 64);
            if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return true;
        }
    }
    return false;
}

/// Register the tp_snakemap scalar function against the v2 extension being loaded.
pub fn register(input: *const db.ExtensionInput) !void {
    var err: db.ErrorInfoHandle = undefined;

    var function: db.ScalarFunctionHandle = undefined;
    if (db.scalarFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = db.scalarFunctionDestroy(&function);

    const fn_name = db.str("tp_snakemap");
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
    var bool_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BOOLEAN, &bool_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateType;
    defer _ = db.logicalTypeDestroy(&bool_type);
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
    const groups_name = db.str("groups");
    if (db.functionSignatureAddParameter(sig, &groups_name, varchar_list, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToAddParameter;

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

    var no_color_default: db.ValueHandle = undefined;
    if (db.valueCreateBoolWithContext(input.context, false, &no_color_default, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = db.valueDestroy(&no_color_default);
    const no_color_name = db.str("no_color");
    if (db.functionSignatureAddParameter(sig, &no_color_name, bool_type, no_color_default, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) return error.FailedToAddParameter;

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
