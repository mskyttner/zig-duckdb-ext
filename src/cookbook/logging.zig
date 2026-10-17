///! Cookbook: writing to DuckDB's log from an extension (v2 C API, `logging`: one function, `context_log`).
///!
///!   zig_cookbook_log(level VARCHAR, log_type VARCHAR, message VARCHAR) -> VARCHAR
///!
///! writes `message` to the log and returns it, so a call can sit inside an expression:
///!
///!   CALL enable_logging(level = 'info');
///!   SELECT zig_cookbook_log('info', 'my_extension', 'row ' || i) FROM range(3) t(i);
///!   SELECT log_level, type, message FROM duckdb_logs WHERE type = 'my_extension';
///!
///! What `context_log` does and does not do, which is the whole recipe:
///!   - The entry is attributed to the context's connection, so it carries that connection's ids (`connection_id`,
///!     `query_id`, `thread_id` in `duckdb_logs`).
///!   - **Whether it is recorded is the database's decision.** With logging off, with a `level` below the configured
///!     `logging_level`, or a `log_type` that the log configuration does not enable, the call *succeeds and writes
///!     nothing*. The extension cannot ask whether anyone is listening, so it should not build an expensive message
///!     only to have it dropped.
///!   - `log_type` is matched case-sensitively; an empty one is the default type, recorded as the empty string. A type of
///!     your own is recorded like any other, but `CALL enable_logging('my_extension')` rejects it ("Unknown log type"):
///!     the types that logging can be limited to are DuckDB's own, so an extension's entries are told apart by
///!     filtering `duckdb_logs`, not by the configuration.
///!   - The entry's scope is CONNECTION: `connection_id`, `transaction_id` and `query_id` are set, `thread_id` is NULL.
///!   - The levels are DuckDB's: TRACE 10, DEBUG 20, INFO 30, WARNING 40, ERROR 50, FATAL 60. A log entry is not an
///!     error: even FATAL does not fail the query. Failing the query is the callback's `err`.
///!
///! The function is VOLATILE: logging is its effect, and DuckDB must not fold a call with constant arguments to its
///! value at planning, or run it once for a thousand equal rows (the test sees one entry instead of a thousand without it).
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const Err = *v2.duckdb_v2_error_info_handle;

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [300]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    const text = helpers.str(msg);
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = v2.duckdb_v2_error_info_set_text(err.*, &text);
}

fn levelOf(name: []const u8) ?v2.DUCKDB_V2_LOG_LEVEL {
    const levels = .{
        .{ "trace", v2.DUCKDB_V2_LOG_LEVEL.LOG_LEVEL_TRACE },
        .{ "debug", .LOG_LEVEL_DEBUG },
        .{ "info", .LOG_LEVEL_INFO },
        .{ "warning", .LOG_LEVEL_WARNING },
        .{ "error", .LOG_LEVEL_ERROR },
        .{ "fatal", .LOG_LEVEL_FATAL },
    };
    inline for (levels) |l| {
        if (std.ascii.eqlIgnoreCase(name, l[0])) return l[1];
    }
    return null;
}

fn flatArg(info: v2.duckdb_v2_scalar_function_exec_info_handle, index: u64, view: *v2.duckdb_v2_vector_view, err: Err) bool {
    var vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_arg(info, index, &vec, err) != .ERROR_NONE) return false;
    if (v2.duckdb_v2_vector_flatten(vec, err) != .ERROR_NONE) return false;
    return v2.duckdb_v2_vector_get_view(vec, view, err) == .ERROR_NONE;
}

fn exec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var views: [3]v2.duckdb_v2_vector_view = undefined;
    for (&views, 0..) |*view, i| {
        if (!flatArg(info, i, view, err)) return;
    }
    var result: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result, row_count, err) != .ERROR_NONE) return;
    var out_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(result, &out_ptr, err) != .ERROR_NONE) return;
    var arena: v2.duckdb_v2_arena_handle = undefined;
    if (v2.duckdb_v2_vector_get_arena(result, &arena, err) != .ERROR_NONE) return;
    const out: [*]v2.duckdb_v2_bytes = @ptrCast(@alignCast(out_ptr.?));
    const args: [3][*]const v2.duckdb_v2_bytes = .{ @ptrCast(@alignCast(views[0].data orelse return)), @ptrCast(@alignCast(views[1].data orelse return)), @ptrCast(@alignCast(views[2].data orelse return)) };

    for (0..row_count) |row| {
        // A NULL argument makes the result NULL, and nothing is logged.
        if (!helpers.isValid(views[0].validity, row) or !helpers.isValid(views[1].validity, row) or !helpers.isValid(views[2].validity, row)) {
            if (v2.duckdb_v2_vector_set_null(result, row, err) != .ERROR_NONE) return;
            continue;
        }
        const level_name = helpers.bytesSlice(&args[0][row]);
        const log_type = helpers.str(helpers.bytesSlice(&args[1][row]));
        const message = helpers.str(helpers.bytesSlice(&args[2][row]));
        const level = levelOf(level_name) orelse
            return fail(err, .ERROR_INPUT_PARAMETER_INVALID, "zig_cookbook_log: unknown level '{s}' (trace, debug, info, warning, error or fatal)", .{level_name});
        // Succeeds whether or not the entry was recorded.
        if (v2.duckdb_v2_context_log(context, level, &log_type, &message, err) != .ERROR_NONE) return;
        out[row] = helpers.makeBytesValue(arena, helpers.bytesSlice(&args[2][row]), err) catch return;
    }
}

fn addVarchar(sig: v2.duckdb_v2_function_signature_handle, name: []const u8, input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var ty: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &ty, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&ty);
    const param = helpers.str(name);
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &param, ty, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
}

/// Registers the function. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);
    const name = helpers.str("zig_cookbook_log");
    if (v2.duckdb_v2_scalar_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    try addVarchar(sig, "level", input, err);
    try addVarchar(sig, "log_type", input, err);
    try addVarchar(sig, "message", input, err);
    var varchar: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar);
    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar, err) != .ERROR_NONE) return error.FailedToSetReturnType;

    if (v2.duckdb_v2_scalar_function_set_property(function, .FUNCTION_PROPERTY_STABILITY, .FUNCTION_PROPERTY_STABILITY_VOLATILE, err) != .ERROR_NONE) return error.FailedToSetProperty;
    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_scalar_function_register(function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}
