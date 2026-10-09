///! Comptime scalar function framework for the DuckDB v2 C Extension API.
///!
///! A v2 port of `comptime_scalar.zig`'s `Function(name, implFn)` pattern,
///! generating the same vectorized-callback-from-a-per-row-function
///! boilerplate, adapted to v2's error-returning, out-param calling
///! convention and extension-based (not connection-based) registration.
///! Supports the same numeric types as the v1 framework (i8, i16, i32, i64,
///! f32, f64, bool), plus `[]const u8` for VARCHAR parameters and/or return
///! type — see duckdb_v2.zig's `bytesSlice`/`valueCreateVarcharWithContext`
///! doc comments for how vector-stored strings differ from numeric types.
///!
///! CAUTION: a `[]const u8`-returning `implFn` must return a slice that
///! outlives the call — one borrowed from its own arguments (a substring,
///! or an argument unchanged), a string literal, or heap/static memory.
///! It must NOT return a slice into its own local stack buffer: the result
///! is boxed into a Value immediately after `implFn` returns, by which
///! point a local buffer's storage is already gone. (The hand-written
///! `zig_v2_hello` example in duckdb_v2.zig sidesteps this by building and
///! consuming its buffer inline, before returning — not available to a
///! plain per-row function passed through this framework.)
///!
///! Usage:
///!   const MyFn = comptime_scalar_v2.Function("my_double", struct {
///!       fn eval(a: i64) i64 { return a * 2; }
///!   }.eval);
///!   try MyFn.register(input); // input: *const db2.ExtensionInput
const std = @import("std");
const db = @import("duckdb_v2");

fn duckdbV2TypeId(comptime T: type) db.LogicalTypeId {
    return switch (T) {
        i8 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_TINYINT,
        i16 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_SMALLINT,
        i32 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_INTEGER,
        i64 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT,
        f32 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_FLOAT,
        f64 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_DOUBLE,
        bool => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BOOLEAN,
        []const u8 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR,
        else => @compileError("unsupported type for DuckDB v2 mapping: " ++ @typeName(T)),
    };
}

/// Define a v2 DuckDB scalar function from a comptime-known Zig function.
pub fn Function(comptime name: [:0]const u8, comptime implFn: anytype) type {
    const fn_info = @typeInfo(@TypeOf(implFn)).@"fn";
    const param_types = fn_info.param_types;
    const ReturnType = fn_info.return_type.?;

    inline for (param_types) |t| _ = duckdbV2TypeId(t.?);
    _ = duckdbV2TypeId(ReturnType);

    return struct {
        /// Register this scalar function against the extension being loaded.
        /// Must be called from inside the v2 extension entrypoint, which is
        /// handed both an `extension` handle (to create the function) and a
        /// `context` handle (to create logical types — v2 has no
        /// handle-less type constructor, see `duckdb_v2.zig`'s own note).
        pub fn register(input: *const db.ExtensionInput) !void {
            var err: db.ErrorInfoHandle = undefined;

            var function: db.ScalarFunctionHandle = undefined;
            if (db.scalarFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = db.scalarFunctionDestroy(&function);

            const fn_name = db.str(name);
            if (db.scalarFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetName;
            }

            var sig: db.FunctionSignatureHandle = undefined;
            if (db.scalarFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToGetSignature;
            }

            inline for (param_types, 0..) |t, i| {
                var param_type: db.LogicalTypeHandle = undefined;
                if (db.contextCreateTypeFromId(input.context, duckdbV2TypeId(t.?), &param_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToCreateParamType;
                }
                defer _ = db.logicalTypeDestroy(&param_type);

                // Zig function parameters carry no names at the ABI level —
                // synthesize positional names ("a0", "a1", ...) since v2's
                // signature requires one per parameter.
                const param_name_buf = std.fmt.comptimePrint("a{d}", .{i});
                const param_name = db.str(param_name_buf);
                if (db.functionSignatureAddParameter(
                    sig,
                    &param_name,
                    param_type,
                    null,
                    db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD,
                    &err,
                ) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToAddParameter;
                }
            }

            var return_type: db.LogicalTypeHandle = undefined;
            if (db.contextCreateTypeFromId(input.context, duckdbV2TypeId(ReturnType), &return_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateReturnType;
            }
            defer _ = db.logicalTypeDestroy(&return_type);
            if (db.functionSignatureSetReturnType(sig, return_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetReturnType;
            }

            if (db.scalarFunctionSetExecCallback(function, execute, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetExecCallback;
            }

            if (db.scalarFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }

        const return_is_varchar = ReturnType == []const u8;

        /// Vectorized exec callback invoked by DuckDB for each batch of rows.
        fn execute(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var row_count: db.idx_t = 0;
            if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            // Cache each argument's view (flattened first — sequence/FSST/
            // dictionary-encoded args aren't directly readable otherwise,
            // see duckdb_v2.zig's vectorFlatten doc comment).
            var views: [param_types.len]db.VectorView = undefined;
            inline for (0..param_types.len) |i| {
                var arg_vec: db.VectorHandle = undefined;
                if (db.scalarFunctionExecGetArg(info, i, &arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                if (db.vectorFlatten(arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                if (db.vectorGetView(arg_vec, &views[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            }

            var result_vec: db.VectorHandle = undefined;
            if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var has_nulls = false;
            inline for (0..param_types.len) |i| {
                if (views[i].validity != null) has_nulls = true;
            }

            // VARCHAR results can't be written through a flat typed buffer
            // (variable width) — each row boxes through a Value instead, via
            // duckdb_v2.zig's valueCreateVarcharWithContext + vectorSetValue.
            if (return_is_varchar) {
                var row: db.idx_t = 0;
                while (row < row_count) : (row += 1) {
                    if (has_nulls and !rowIsValid(&views, row)) {
                        if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        continue;
                    }
                    const text = invoke(&views, row);
                    var value: db.ValueHandle = undefined;
                    if (db.valueCreateVarcharWithContext(context, text, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    defer _ = db.valueDestroy(&value);
                    if (db.vectorSetValue(result_vec, row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                }
                return;
            }

            var out_data: ?*anyopaque = null;
            if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            // SAFETY: types were validated at comptime against the registered signature.
            const result: [*]ReturnType = @ptrCast(@alignCast(out_data));

            if (has_nulls) {
                var row: db.idx_t = 0;
                while (row < row_count) : (row += 1) {
                    if (rowIsValid(&views, row)) {
                        result[row] = invoke(&views, row);
                    } else {
                        if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    }
                }
            } else {
                var row: db.idx_t = 0;
                while (row < row_count) : (row += 1) {
                    result[row] = invoke(&views, row);
                }
            }
        }

        inline fn rowIsValid(views: *const [param_types.len]db.VectorView, row: db.idx_t) bool {
            inline for (0..param_types.len) |i| {
                if (views.*[i].validity) |validity| {
                    const entry_idx = row / 64;
                    const bit_idx: u6 = @intCast(row % 64);
                    if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return false;
                }
            }
            return true;
        }

        fn MakeArgsTuple() type {
            var types: [param_types.len]type = undefined;
            for (0..param_types.len) |i| types[i] = param_types[i].?;
            return @Tuple(&types);
        }
        const ArgsTuple = MakeArgsTuple();

        inline fn invoke(views: *const [param_types.len]db.VectorView, row: db.idx_t) ReturnType {
            var args: ArgsTuple = undefined;
            inline for (0..param_types.len) |i| {
                const T = param_types[i].?;
                if (T == []const u8) {
                    // SAFETY: views[i].data points to a flattened VARCHAR vector's
                    // duckdb_v2_bytes elements (the signature registered this param as VARCHAR).
                    const typed: [*]const db.BytesValue = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = db.bytesSlice(&typed[row]);
                } else {
                    // SAFETY: views[i].data points to a flattened, type-matched vector buffer.
                    const typed: [*]const T = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = typed[row];
                }
            }
            return @call(.auto, implFn, args);
        }
    };
}

test "Function generates a valid Zig type" {
    const Double = Function("v2_test_double", struct {
        fn eval(a: i64) i64 {
            return a * 2;
        }
    }.eval);
    // Referencing .register forces Zig to semantically analyze its body
    // (the comptime-unrolled signature-building loop) even though nothing
    // calls it in this test; .execute is separately forced below by
    // matching it against the exact callback type.
    _ = &Double.register;
    const exec_cb: db.ScalarFunctionExecCallback = Double.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports multiple parameters of different types" {
    const Mix = Function("v2_test_mix", struct {
        fn eval(a: i64, b: f64, c: bool) f64 {
            return if (c) @as(f64, @floatFromInt(a)) + b else b;
        }
    }.eval);
    _ = &Mix.register;
    const exec_cb: db.ScalarFunctionExecCallback = Mix.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports VARCHAR parameter and return type" {
    // Safe per the CAUTION above: returns a slice borrowed from its own
    // argument, never a local buffer.
    const FirstChar = Function("v2_test_first_char", struct {
        fn eval(s: []const u8) []const u8 {
            return s[0..@min(1, s.len)];
        }
    }.eval);
    _ = &FirstChar.register;
    const exec_cb: db.ScalarFunctionExecCallback = FirstChar.execute;
    try std.testing.expect(exec_cb != null);
}
