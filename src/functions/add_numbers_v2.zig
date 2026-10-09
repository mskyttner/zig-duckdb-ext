///! Scalar function: zig_add_numbers(a BIGINT, b BIGINT) -> BIGINT
///!
///! v2 port of add_numbers.zig (hand-written, not the comptime framework —
///! see ct_add_numbers_v2.zig for that style), adapted to v2's
///! error-returning calling convention and extension-based registration.
///! Adds two 64-bit integers. Propagates NULL if either input is NULL.
const db = @import("duckdb_v2");

fn exec(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    _ = context;
    var row_count: db.idx_t = 0;
    if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var a_vec: db.VectorHandle = undefined;
    var b_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetArg(info, 0, &a_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.scalarFunctionExecGetArg(info, 1, &b_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(a_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(b_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var a_view: db.VectorView = undefined;
    var b_view: db.VectorView = undefined;
    if (db.vectorGetView(a_vec, &a_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorGetView(b_vec, &b_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var out_data: ?*anyopaque = null;
    if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    // SAFETY: the signature registered this function as (BIGINT, BIGINT) -> BIGINT.
    const a_data: [*]const i64 = @ptrCast(@alignCast(a_view.data));
    const b_data: [*]const i64 = @ptrCast(@alignCast(b_view.data));
    const result: [*]i64 = @ptrCast(@alignCast(out_data));

    if (a_view.validity != null or b_view.validity != null) {
        var row: db.idx_t = 0;
        while (row < row_count) : (row += 1) {
            if (isValid(a_view.validity, row) and isValid(b_view.validity, row)) {
                result[row] = a_data[row] + b_data[row];
            } else {
                if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            }
        }
    } else {
        var row: db.idx_t = 0;
        while (row < row_count) : (row += 1) {
            result[row] = a_data[row] + b_data[row];
        }
    }
}

inline fn isValid(validity: ?[*]const u64, row: db.idx_t) bool {
    const v = validity orelse return true;
    const entry_idx = row / 64;
    const bit_idx: u6 = @intCast(row % 64);
    return (v[entry_idx] & (@as(u64, 1) << bit_idx)) != 0;
}

/// Register the zig_add_numbers scalar function against the v2 extension being loaded.
pub fn register(input: *const db.ExtensionInput) !void {
    var err: db.ErrorInfoHandle = undefined;

    var function: db.ScalarFunctionHandle = undefined;
    if (db.scalarFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = db.scalarFunctionDestroy(&function);

    const fn_name = db.str("zig_add_numbers");
    if (db.scalarFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetName;
    }

    var bigint_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&bigint_type);

    var sig: db.FunctionSignatureHandle = undefined;
    if (db.scalarFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const a_name = db.str("a");
    const b_name = db.str("b");
    if (db.functionSignatureAddParameter(sig, &a_name, bigint_type, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }
    if (db.functionSignatureAddParameter(sig, &b_name, bigint_type, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }
    if (db.functionSignatureSetReturnType(sig, bigint_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetReturnType;
    }

    if (db.scalarFunctionSetExecCallback(function, exec, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetExecCallback;
    }

    if (db.scalarFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}
