///! Scalar function: tp_line(data DOUBLE[], height DOUBLE := 10.0) -> VARCHAR
///!
///! v2 port of tp_line.zig — first LIST support in the v2 layer. Drops the
///! SQL-macro default-param workaround the same way tp_bar_v2 did (v2 has
///! real defaults natively).
///!
///! v2 exposes LIST through the same generic "nested vector" mechanism as
///! STRUCT/MAP/UNION (`vector_get_child`/`vector_get_child_count`), unlike
///! v1's LIST-specific `listVectorGetChild`: index 0 of a flattened LIST
///! vector's child is the flat element vector, addressed per row via the
///! LIST vector's own `duckdb_v2_list_entry{offset, length}` records in its
///! `VectorView.data` — otherwise the same vector-view/validity pattern
///! every other type in this codebase already uses.
///!
///! Reuses renderLine from tp_line.zig unchanged (pure Zig, no DuckDB API
///! dependency either version needs to duplicate).
const std = @import("std");
const db = @import("duckdb_v2");
const renderLine = @import("tp_line.zig").renderLine;

fn exec(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    var row_count: db.idx_t = 0;
    if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var list_vec: db.VectorHandle = undefined;
    var height_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetArg(info, 0, &list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 1, &height_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(list_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(height_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var list_view: db.VectorView = undefined;
    var height_view: db.VectorView = undefined;
    if (db.vectorGetView(list_vec, &list_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(height_vec, &height_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var child_vec: db.VectorHandle = undefined;
    if (db.vectorGetChild(list_vec, 0, &child_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(child_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    var child_view: db.VectorView = undefined;
    if (db.vectorGetView(child_vec, &child_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    // SAFETY: the signature registered these as (LIST(DOUBLE), DOUBLE) -> VARCHAR.
    const entries: [*]const db.ListEntry = @ptrCast(@alignCast(list_view.data));
    const height_data: [*]const f64 = @ptrCast(@alignCast(height_view.data));
    const child_data: [*]const f64 = @ptrCast(@alignCast(child_view.data));

    var row: db.idx_t = 0;
    while (row < row_count) : (row += 1) {
        if ((list_view.validity != null and !isValid(list_view.validity.?, row)) or
            (height_view.validity != null and !isValid(height_view.validity.?, row)))
        {
            if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            continue;
        }

        const entry = entries[row];
        if (entry.length == 0) {
            var value: db.ValueHandle = undefined;
            if (db.valueCreateVarcharWithContext(context, "", &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            defer _ = db.valueDestroy(&value);
            if (db.vectorSetValue(result_vec, row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            continue;
        }

        // The rendered string must be boxed into a Value (and the Value
        // written) while the arena backing it is still alive — consuming
        // it before arena.deinit() runs, the same way v1's writeRow copies
        // into DuckDB's own string vector before its function returns.
        // Returning the slice out of this scope first (e.g. via a block
        // expression) would use it after the arena already freed it.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const len = @min(entry.length, 255);
        const text = blk: {
            const values = allocator.alloc(f64, len) catch break :blk @as([]const u8, "");
            for (0..len) |i| {
                const ci = entry.offset + i;
                values[i] = if (child_view.validity == null or isValid(child_view.validity.?, ci))
                    child_data[ci]
                else
                    std.math.nan(f64);
            }
            break :blk renderLine(allocator, values, height_data[row]) catch @as([]const u8, "");
        };

        var value: db.ValueHandle = undefined;
        if (db.valueCreateVarcharWithContext(context, text, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = db.valueDestroy(&value);
        if (db.vectorSetValue(result_vec, row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    }
}

inline fn isValid(validity: [*]const u64, row: db.idx_t) bool {
    const entry_idx = row / 64;
    const bit_idx: u6 = @intCast(row % 64);
    return (validity[entry_idx] & (@as(u64, 1) << bit_idx)) != 0;
}

/// Register the tp_line scalar function against the v2 extension being loaded.
pub fn register(input: *const db.ExtensionInput) !void {
    var err: db.ErrorInfoHandle = undefined;

    var function: db.ScalarFunctionHandle = undefined;
    if (db.scalarFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = db.scalarFunctionDestroy(&function);

    const fn_name = db.str("tp_line");
    if (db.scalarFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetName;
    }

    var double_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_DOUBLE, &double_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&double_type);
    var list_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateListType(input.context, double_type, &list_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&list_type);
    var varchar_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&varchar_type);

    var sig: db.FunctionSignatureHandle = undefined;
    if (db.scalarFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const data_name = db.str("data");
    if (db.functionSignatureAddParameter(sig, &data_name, list_type, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    var height_default: db.ValueHandle = undefined;
    if (db.valueCreateDoubleWithContext(input.context, 10.0, &height_default, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateDefault;
    }
    defer _ = db.valueDestroy(&height_default);
    const height_name = db.str("height");
    if (db.functionSignatureAddParameter(sig, &height_name, double_type, height_default, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }

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
