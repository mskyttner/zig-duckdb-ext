///! Comptime table function framework for the DuckDB v2 C Extension API.
///!
///! A v2 port of `comptime_table.zig`'s thin registration-boilerplate
///! helper: the caller supplies bind/init_global/exec callbacks with the
///! custom row-producing logic (there is no per-row logic to generate here,
///! unlike `comptime_scalar_v2.zig` — table functions are inherently custom),
///! and this handles function handle lifecycle, parameter signature
///! construction, and registration.
///!
///! Usage:
///!   const MyTF = comptime_table_v2.Function(struct {
///!       pub const name: [:0]const u8 = "my_table_fn";
///!       pub const param_types = [_]db.LogicalTypeId{.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR};
///!       pub const bind = myBind;
///!       pub const initGlobal = myInitGlobal;
///!       pub const exec = myExec;
///!   });
///!   try MyTF.register(input); // input: *const db.ExtensionInput
const std = @import("std");
const db = @import("duckdb_v2");

/// Define a v2 DuckDB table function from a comptime configuration struct.
///
/// The Cfg type must declare:
///   - `name: [:0]const u8` — SQL function name
///   - `param_types: []const db.LogicalTypeId` — parameter types (may be empty)
///   - `bind: duckdb_v2_table_function_bind_callback_fn`
///   - `initGlobal: duckdb_v2_table_function_init_global_callback_fn`
///   - `exec: duckdb_v2_table_function_exec_callback_fn`
pub fn Function(comptime Cfg: type) type {
    return struct {
        pub fn register(input: *const db.ExtensionInput) !void {
            var err: db.ErrorInfoHandle = undefined;

            var function: db.TableFunctionHandle = undefined;
            if (db.tableFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = db.tableFunctionDestroy(&function);

            const fn_name = db.str(Cfg.name);
            if (db.tableFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetName;
            }

            if (Cfg.param_types.len > 0) {
                var sig: db.FunctionSignatureHandle = undefined;
                if (db.tableFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToGetSignature;
                }
                inline for (Cfg.param_types, 0..) |pt, i| {
                    var param_type: db.LogicalTypeHandle = undefined;
                    if (db.contextCreateTypeFromId(input.context, pt, &param_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                        return error.FailedToCreateParamType;
                    }
                    defer _ = db.logicalTypeDestroy(&param_type);

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
            }

            if (db.tableFunctionSetBindCallback(function, Cfg.bind, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetBindCallback;
            }
            if (db.tableFunctionSetInitGlobalCallback(function, Cfg.initGlobal, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetInitGlobalCallback;
            }
            if (db.tableFunctionSetExecCallback(function, Cfg.exec, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetExecCallback;
            }

            if (db.tableFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }
    };
}

test "Function generates a valid Zig type for a zero-parameter table function" {
    const RangeLike = Function(struct {
        pub const name: [:0]const u8 = "v2_test_range_like";
        pub const param_types = [_]db.LogicalTypeId{};
        pub const bind = testBind;
        pub const initGlobal = testInitGlobal;
        pub const exec = testExec;
    });
    // Referencing .register forces Zig to semantically analyze its body
    // even though nothing calls it in this test.
    _ = &RangeLike.register;
}

fn testBind(info: db.c.duckdb_v2_function_bind_info_handle, result: db.TableFunctionBindInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    _ = info;
    _ = result;
    _ = context;
    _ = err;
}

fn testInitGlobal(info: db.TableFunctionInitGlobalInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    _ = info;
    _ = context;
    _ = err;
}

fn testExec(info: db.TableFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    _ = info;
    _ = context;
    _ = err;
}
