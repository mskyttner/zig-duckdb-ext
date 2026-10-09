///! Scalar function: tp_bar(value DOUBLE, on VARCHAR := '█', off VARCHAR := '░', width BIGINT := 15) -> VARCHAR
///!
///! v2 port of tp_bar.zig. v1 can't express named parameters or defaults
///! on a scalar function at all — tp_bar.zig works around this by
///! registering a plain `tp_bar_impl` function plus a `CREATE OR REPLACE
///! MACRO tp_bar(...)` wrapper providing the named/defaulted call surface.
///! v2 has real named parameters and per-parameter defaults
///! (`functionSignatureAddParameter`'s `default_value`), so this port
///! registers a single `tp_bar` function directly — no macro, no `_impl`
///! split, no `db.query()` string execution at init time.
///!
///! Reuses `buildBar` from tp_bar.zig unchanged: it's pure Zig (allocator +
///! slices in, slice out), with no DuckDB API dependency either version
///! needs to duplicate.
const std = @import("std");
const db = @import("duckdb_v2");
const buildBar = @import("tp_bar.zig").buildBar;

fn exec(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    var row_count: db.idx_t = 0;
    if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var views: [4]db.VectorView = undefined;
    inline for (0..4) |i| {
        var arg_vec: db.VectorHandle = undefined;
        if (db.scalarFunctionExecGetArg(info, i, &arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        if (db.vectorFlatten(arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        if (db.vectorGetView(arg_vec, &views[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    }

    var result_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    // SAFETY: the signature registered these as (DOUBLE, VARCHAR, VARCHAR, BIGINT).
    const val_data: [*]const f64 = @ptrCast(@alignCast(views[0].data));
    const on_data: [*]const db.BytesValue = @ptrCast(@alignCast(views[1].data));
    const off_data: [*]const db.BytesValue = @ptrCast(@alignCast(views[2].data));
    const width_data: [*]const i64 = @ptrCast(@alignCast(views[3].data));

    var row: db.idx_t = 0;
    while (row < row_count) : (row += 1) {
        if (!rowIsValid(&views, row)) {
            if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            continue;
        }

        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const result = buildBar(
            fba.allocator(),
            val_data[row],
            db.bytesSlice(&on_data[row]),
            db.bytesSlice(&off_data[row]),
            width_data[row],
        ) catch "";

        var value: db.ValueHandle = undefined;
        if (db.valueCreateVarcharWithContext(context, result, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = db.valueDestroy(&value);
        if (db.vectorSetValue(result_vec, row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    }
}

inline fn rowIsValid(views: *const [4]db.VectorView, row: db.idx_t) bool {
    inline for (0..4) |i| {
        if (views.*[i].validity) |validity| {
            const entry_idx = row / 64;
            const bit_idx: u6 = @intCast(row % 64);
            if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return false;
        }
    }
    return true;
}

/// Register the tp_bar scalar function against the v2 extension being loaded.
pub fn register(input: *const db.ExtensionInput) !void {
    var err: db.ErrorInfoHandle = undefined;

    var function: db.ScalarFunctionHandle = undefined;
    if (db.scalarFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = db.scalarFunctionDestroy(&function);

    const fn_name = db.str("tp_bar");
    if (db.scalarFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetName;
    }

    var double_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_DOUBLE, &double_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&double_type);
    var varchar_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&varchar_type);
    var bigint_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&bigint_type);

    var sig: db.FunctionSignatureHandle = undefined;
    if (db.scalarFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const value_name = db.str("value");
    if (db.functionSignatureAddParameter(sig, &value_name, double_type, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    var on_default: db.ValueHandle = undefined;
    if (db.valueCreateVarcharWithContext(input.context, "█", &on_default, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateDefault;
    }
    defer _ = db.valueDestroy(&on_default);
    const on_name = db.str("on");
    if (db.functionSignatureAddParameter(sig, &on_name, varchar_type, on_default, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    var off_default: db.ValueHandle = undefined;
    if (db.valueCreateVarcharWithContext(input.context, "░", &off_default, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateDefault;
    }
    defer _ = db.valueDestroy(&off_default);
    const off_name = db.str("off");
    if (db.functionSignatureAddParameter(sig, &off_name, varchar_type, off_default, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    var width_default: db.ValueHandle = undefined;
    if (db.valueCreateBigintWithContext(input.context, 15, &width_default, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateDefault;
    }
    defer _ = db.valueDestroy(&width_default);
    const width_name = db.str("width");
    if (db.functionSignatureAddParameter(sig, &width_name, bigint_type, width_default, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
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
