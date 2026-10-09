///! Scalar function: zig_hello(name VARCHAR) -> VARCHAR
///!
///! v2 port of hello.zig. Hand-written rather than through
///! comptime_scalar_v2: that framework's VARCHAR-return path requires
///! `implFn` to return a slice that outlives the call (borrowed from an
///! argument, a literal, or static/heap memory) because nothing frees
///! allocator-backed memory after boxing — but this function needs to
///! *construct* new text ("Hello, " ++ name ++ "!"), which a local stack
///! buffer can do safely only if built and boxed inline, before the
///! exec callback returns, the same way v1's hand-written hello.zig built
///! and consumed its buffer inline. Not a gap worth closing in the
///! framework yet — most real functions either transform existing text or
///! produce it like this one does, and the two need different plumbing.
const db = @import("duckdb_v2");

fn exec(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    var row_count: db.idx_t = 0;
    if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var arg_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetArg(info, 0, &arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorFlatten(arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    var view: db.VectorView = undefined;
    if (db.vectorGetView(arg_vec, &view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: db.VectorHandle = undefined;
    if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    // SAFETY: the signature registered this function as (VARCHAR) -> VARCHAR.
    const in: [*]const db.BytesValue = @ptrCast(@alignCast(view.data));

    var row: db.idx_t = 0;
    while (row < row_count) : (row += 1) {
        if (view.validity != null and !isValid(view.validity.?, row)) {
            if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            continue;
        }
        const name = db.bytesSlice(&in[row]);
        var buf: [1024]u8 = undefined;
        const prefix = "Hello, ";
        const suffix = "!";
        const total = prefix.len + name.len + suffix.len;
        const greeting = if (total <= buf.len) blk: {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len .. prefix.len + name.len], name);
            @memcpy(buf[prefix.len + name.len .. total], suffix);
            break :blk buf[0..total];
        } else "Hello, world!";

        var value: db.ValueHandle = undefined;
        if (db.valueCreateVarcharWithContext(context, greeting, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = db.valueDestroy(&value);
        if (db.vectorSetValue(result_vec, row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    }
}

inline fn isValid(validity: [*]const u64, row: db.idx_t) bool {
    const entry_idx = row / 64;
    const bit_idx: u6 = @intCast(row % 64);
    return (validity[entry_idx] & (@as(u64, 1) << bit_idx)) != 0;
}

/// Register the zig_hello scalar function against the v2 extension being loaded.
pub fn register(input: *const db.ExtensionInput) !void {
    var err: db.ErrorInfoHandle = undefined;

    var function: db.ScalarFunctionHandle = undefined;
    if (db.scalarFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = db.scalarFunctionDestroy(&function);

    const fn_name = db.str("zig_hello");
    if (db.scalarFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetName;
    }

    var varchar_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&varchar_type);

    var sig: db.FunctionSignatureHandle = undefined;
    if (db.scalarFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const param_name = db.str("name");
    if (db.functionSignatureAddParameter(sig, &param_name, varchar_type, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
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
