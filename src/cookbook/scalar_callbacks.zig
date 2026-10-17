///! Cookbook: the life of a scalar function call site (v2 C API, `function/scalar` and `function`).
///!
///! A scalar function can have four callbacks. They run in this order, and each hands data to the next:
///!
///!   resolve types   at planning, before the arguments are cast to the signature: sees the argument types
///!                   as written, can set the return type of this call site (register the function with an
///!                   ANY return type and decide here)
///!   bind            at planning, after the cast: sees the types and the *constant* arguments, can fail
///!                   the query with a message, and leaves **bind data** for the call site
///!   init            once per thread that runs the function: leaves **init data**, mutable state of that
///!                   worker for the whole query
///!   exec            per chunk: reads bind data, init data and the function's **user data**
///!
///! Four functions show them one at a time:
///!
///!   zig_cookbook_negate(x ANY) -> typeof(x)       resolve types + bind data: the result type follows the argument
///!   zig_cookbook_round_to(x DOUBLE, digits INTEGER)   bind: reads a constant argument once, rejects a column
///!   zig_cookbook_times2 / _times3 / _times10(x BIGINT)   user data: one exec callback, three functions
///!   zig_cookbook_row_number() -> BIGINT           init data (a counter per worker) + the VOLATILE property
///!
///! Each piece of data is an `Opaque`: a pointer, an optional destructor DuckDB calls when it is done, and an
///! optional equality callback. Errors are reported by setting a code and a text on the callback's `err`.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const Err = *v2.duckdb_v2_error_info_handle;

/// Fails the query: the text and an error code go to the callback's error info.
fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    const text = helpers.str(msg);
    // There is nowhere to report a failure to report: DuckDB fails the query either way.
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = v2.duckdb_v2_error_info_set_text(err.*, &text);
}

fn typeName(id: v2.DUCKDB_V2_LOGICAL_TYPE_ID) []const u8 {
    const tag = std.enums.tagName(v2.DUCKDB_V2_LOGICAL_TYPE_ID, id) orelse return "unknown";
    return tag["LOGICAL_TYPE_ID_".len..];
}

/// The input vector `index`, flattened, and its view.
fn flatArg(info: v2.duckdb_v2_scalar_function_exec_info_handle, index: u64, view: *v2.duckdb_v2_vector_view, err: Err) bool {
    var vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_arg(info, index, &vec, err) != .ERROR_NONE) return false;
    if (v2.duckdb_v2_vector_flatten(vec, err) != .ERROR_NONE) return false;
    return v2.duckdb_v2_vector_get_view(vec, view, err) == .ERROR_NONE;
}

/// The result vector, sized for `row_count` rows, and its writable data.
fn resultData(info: v2.duckdb_v2_scalar_function_exec_info_handle, row_count: u64, vec: *v2.duckdb_v2_vector_handle, data: *?*anyopaque, err: Err) bool {
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, vec, err) != .ERROR_NONE) return false;
    if (v2.duckdb_v2_vector_set_size(vec.*, row_count, err) != .ERROR_NONE) return false;
    return v2.duckdb_v2_vector_get_data_mutable(vec.*, data, err) == .ERROR_NONE;
}

fn begin(function_name: []const u8, input: *const v2.duckdb_v2_extension_input, err: Err) !v2.duckdb_v2_scalar_function_handle {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    const name = helpers.str(function_name);
    if (v2.duckdb_v2_scalar_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;
    return function;
}

fn addParameter(sig: v2.duckdb_v2_function_signature_handle, name: []const u8, type_id: v2.DUCKDB_V2_LOGICAL_TYPE_ID, input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var ty: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, type_id, &ty, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&ty);
    const param = helpers.str(name);
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &param, ty, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
}

fn setReturn(sig: v2.duckdb_v2_function_signature_handle, type_id: v2.DUCKDB_V2_LOGICAL_TYPE_ID, input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var ty: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, type_id, &ty, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&ty);
    if (v2.duckdb_v2_function_signature_set_return_type(sig, ty, err) != .ERROR_NONE) return error.FailedToSetReturnType;
}

// --- zig_cookbook_negate(x ANY) -> typeof(x) ---------------------------------------------------------

const negatable = [_]v2.DUCKDB_V2_LOGICAL_TYPE_ID{ .LOGICAL_TYPE_ID_TINYINT, .LOGICAL_TYPE_ID_SMALLINT, .LOGICAL_TYPE_ID_INTEGER, .LOGICAL_TYPE_ID_BIGINT, .LOGICAL_TYPE_ID_FLOAT, .LOGICAL_TYPE_ID_DOUBLE };

/// The argument's type id, or null after failing the query because it cannot be negated.
fn negatableArg(info: v2.duckdb_v2_function_bind_info_handle, ty: *v2.duckdb_v2_logical_type_handle, err: Err) ?v2.DUCKDB_V2_LOGICAL_TYPE_ID {
    if (v2.duckdb_v2_function_bind_get_arg_type(info, 0, ty, err) != .ERROR_NONE) return null;
    var id: v2.DUCKDB_V2_LOGICAL_TYPE_ID = undefined;
    if (v2.duckdb_v2_logical_type_get_id(ty.*, &id, err) != .ERROR_NONE) return null;
    for (negatable) |ok| if (ok == id) return id;
    fail(err, .ERROR_INPUT_INVALID, "zig_cookbook_negate: cannot negate a value of type {s}", .{typeName(id)});
    return null;
}

/// Resolve types: the result type is the argument's type.
fn negateResolve(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_scalar_function_resolve_types_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var ty: v2.duckdb_v2_logical_type_handle = undefined;
    _ = negatableArg(info, &ty, err) orelse return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&ty);
    _ = v2.duckdb_v2_scalar_function_resolve_types_set_return_type(result, ty, err);
}

const NegateBind = struct { id: v2.DUCKDB_V2_LOGICAL_TYPE_ID };

fn destroyNegateBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `negateBind` stored a `*NegateBind`.
    std.heap.c_allocator.destroy(@as(*NegateBind, @ptrCast(@alignCast(ptr))));
}

/// Bind: remember the type, so that exec does not have to ask for it per chunk.
fn negateBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_scalar_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var ty: v2.duckdb_v2_logical_type_handle = undefined;
    const id = negatableArg(info, &ty, err) orelse return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&ty);

    const data = std.heap.c_allocator.create(NegateBind) catch return;
    data.* = .{ .id = id };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyNegateBind, .equals = null };
    if (v2.duckdb_v2_scalar_function_bind_set_bind_data(result, &boxed, err) != .ERROR_NONE) destroyNegateBind(data);
}

fn negateRows(comptime T: type, sql_name: []const u8, in: *const v2.duckdb_v2_vector_view, out: *anyopaque, result_vec: v2.duckdb_v2_vector_handle, row_count: u64, err: Err) void {
    // SAFETY: the argument and the result both have type T: the result type was set from the argument type.
    const xs: [*]const T = @ptrCast(@alignCast(in.data orelse return));
    const ys: [*]T = @ptrCast(@alignCast(out));
    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (!helpers.isValid(in.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            continue;
        }
        ys[row] = if (@typeInfo(T) == .float) -xs[row] else std.math.negate(xs[row]) catch {
            return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "Overflow in negation of {s} ({d})", .{ sql_name, xs[row] });
        };
    }
}

fn negateExec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_scalar_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `negateBind` stored a `*NegateBind`.
    const bound: *const NegateBind = @ptrCast(@alignCast(bind_ptr.?));

    var view: v2.duckdb_v2_vector_view = undefined;
    if (!flatArg(info, 0, &view, err)) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    var out: ?*anyopaque = null;
    if (!resultData(info, row_count, &result_vec, &out, err)) return;

    switch (bound.id) {
        .LOGICAL_TYPE_ID_TINYINT => negateRows(i8, "TINYINT", &view, out.?, result_vec, row_count, err),
        .LOGICAL_TYPE_ID_SMALLINT => negateRows(i16, "SMALLINT", &view, out.?, result_vec, row_count, err),
        .LOGICAL_TYPE_ID_INTEGER => negateRows(i32, "INTEGER", &view, out.?, result_vec, row_count, err),
        .LOGICAL_TYPE_ID_BIGINT => negateRows(i64, "BIGINT", &view, out.?, result_vec, row_count, err),
        .LOGICAL_TYPE_ID_FLOAT => negateRows(f32, "FLOAT", &view, out.?, result_vec, row_count, err),
        .LOGICAL_TYPE_ID_DOUBLE => negateRows(f64, "DOUBLE", &view, out.?, result_vec, row_count, err),
        else => unreachable, // bind accepted only `negatable`
    }
}

fn registerNegate(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function = try begin("zig_cookbook_negate", input, err);
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    // ANY in, ANY out: the concrete result type is decided per call site by `negateResolve`.
    try addParameter(sig, "x", .LOGICAL_TYPE_ID_ANY, input, err);
    try setReturn(sig, .LOGICAL_TYPE_ID_ANY, input, err);
    if (v2.duckdb_v2_scalar_function_set_resolve_types_callback(function, &negateResolve, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_scalar_function_set_bind_callback(function, &negateBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &negateExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

// --- zig_cookbook_round_to(x DOUBLE, digits INTEGER) -> DOUBLE ----------------------------------------

const RoundBind = struct { scale: f64 };

fn destroyRoundBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `roundBind` stored a `*RoundBind`.
    std.heap.c_allocator.destroy(@as(*RoundBind, @ptrCast(@alignCast(ptr))));
}

/// Bind: `digits` must be a constant; it is read once and turned into the factor exec multiplies by.
fn roundBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_scalar_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var value: v2.duckdb_v2_value_handle = undefined;
    // Folding fails for a column; ask without an error slot, so that the failure can be replaced by a
    // message that says what the user did wrong.
    if (v2.duckdb_v2_function_bind_get_arg_value(info, 1, &value, null) != .ERROR_NONE) {
        return fail(err, .ERROR_INPUT_PARAMETER_INVALID, "zig_cookbook_round_to: digits must be a constant, not a column", .{});
    }
    defer _ = v2.duckdb_v2_value_destroy(&value);

    var is_null = false;
    if (v2.duckdb_v2_value_is_null(value, &is_null, err) != .ERROR_NONE) return;
    var digits: i32 = 0;
    // A NULL constant: every result is NULL and exec never sees a row, so any scale will do.
    if (!is_null and v2.duckdb_v2_value_get_int(value, &digits, err) != .ERROR_NONE) return;
    if (digits < 0 or digits > 15) {
        return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "zig_cookbook_round_to: digits must be between 0 and 15, got {d}", .{digits});
    }

    const data = std.heap.c_allocator.create(RoundBind) catch return;
    data.* = .{ .scale = std.math.pow(f64, 10, @floatFromInt(digits)) };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyRoundBind, .equals = null };
    if (v2.duckdb_v2_scalar_function_bind_set_bind_data(result, &boxed, err) != .ERROR_NONE) destroyRoundBind(data);
}

fn roundExec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_scalar_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `roundBind` stored a `*RoundBind`.
    const bound: *const RoundBind = @ptrCast(@alignCast(bind_ptr.?));

    var view: v2.duckdb_v2_vector_view = undefined;
    if (!flatArg(info, 0, &view, err)) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    var out: ?*anyopaque = null;
    if (!resultData(info, row_count, &result_vec, &out, err)) return;
    // SAFETY: the signature registered the argument and the result as DOUBLE.
    const xs: [*]const f64 = @ptrCast(@alignCast(view.data orelse return));
    const ys: [*]f64 = @ptrCast(@alignCast(out.?));

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (!helpers.isValid(view.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            continue;
        }
        ys[row] = @round(xs[row] * bound.scale) / bound.scale;
    }
}

fn registerRoundTo(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function = try begin("zig_cookbook_round_to", input, err);
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    try addParameter(sig, "x", .LOGICAL_TYPE_ID_DOUBLE, input, err);
    try addParameter(sig, "digits", .LOGICAL_TYPE_ID_INTEGER, input, err);
    try setReturn(sig, .LOGICAL_TYPE_ID_DOUBLE, input, err);
    if (v2.duckdb_v2_scalar_function_set_bind_callback(function, &roundBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &roundExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

// --- zig_cookbook_times2 / _times3 / _times10 (x BIGINT) -> BIGINT: user data ------------------------

/// Function-level data lives as long as the function: here three constants, so no destructor.
const factors = [_]i64{ 2, 3, 10 };

fn timesExec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var user_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_scalar_function_exec_get_user_data(info, &user_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `registerTimes` set a pointer to one of `factors` as the user data.
    const factor: i64 = @as(*const i64, @ptrCast(@alignCast(user_ptr.?))).*;

    var view: v2.duckdb_v2_vector_view = undefined;
    if (!flatArg(info, 0, &view, err)) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    var out: ?*anyopaque = null;
    if (!resultData(info, row_count, &result_vec, &out, err)) return;
    // SAFETY: the signature registered the argument and the result as BIGINT.
    const xs: [*]const i64 = @ptrCast(@alignCast(view.data orelse return));
    const ys: [*]i64 = @ptrCast(@alignCast(out.?));

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (!helpers.isValid(view.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            continue;
        }
        ys[row] = std.math.mul(i64, xs[row], factor) catch {
            return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "Overflow in multiplication of INT64 ({d} * {d})!", .{ xs[row], factor });
        };
    }
}

fn registerTimes(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    inline for (0..factors.len) |i| {
        var function = try begin(std.fmt.comptimePrint("zig_cookbook_times{d}", .{factors[i]}), input, err);
        defer _ = v2.duckdb_v2_scalar_function_destroy(&function);
        var sig: v2.duckdb_v2_function_signature_handle = undefined;
        if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
        try addParameter(sig, "x", .LOGICAL_TYPE_ID_BIGINT, input, err);
        try setReturn(sig, .LOGICAL_TYPE_ID_BIGINT, input, err);
        var boxed: v2.duckdb_v2_opaque = .{ .ptr = @constCast(&factors[i]), .destroy = null, .equals = null };
        if (v2.duckdb_v2_scalar_function_set_user_data(function, &boxed, err) != .ERROR_NONE) return error.FailedToSetUserData;
        if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &timesExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
        if (v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
    }
}

// --- zig_cookbook_row_number() -> BIGINT: init data and a property -------------------------------------

const Worker = struct { rows_so_far: i64 = 0 };

fn destroyWorker(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `rowNumberInit` stored a `*Worker`.
    std.heap.c_allocator.destroy(@as(*Worker, @ptrCast(@alignCast(ptr))));
}

/// Init: runs once for each thread that executes the function; the counter is that worker's.
fn rowNumberInit(
    info: v2.duckdb_v2_scalar_function_init_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    const worker = std.heap.c_allocator.create(Worker) catch return;
    worker.* = .{};
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = worker, .destroy = destroyWorker, .equals = null };
    if (v2.duckdb_v2_scalar_function_init_set_init_data(info, &boxed, err) != .ERROR_NONE) destroyWorker(worker);
}

fn rowNumberExec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var init_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_scalar_function_exec_get_init_data(info, &init_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `rowNumberInit` stored a `*Worker`.
    const worker: *Worker = @ptrCast(@alignCast(init_ptr.?));

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    var out: ?*anyopaque = null;
    if (!resultData(info, row_count, &result_vec, &out, err)) return;
    // SAFETY: the signature registered the result as BIGINT.
    const ys: [*]i64 = @ptrCast(@alignCast(out.?));
    for (0..row_count) |row| {
        worker.rows_so_far += 1;
        ys[row] = worker.rows_so_far;
    }
}

fn registerRowNumber(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function = try begin("zig_cookbook_row_number", input, err);
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    try setReturn(sig, .LOGICAL_TYPE_ID_BIGINT, input, err);
    // Without this, a function without arguments is "consistent" and DuckDB may evaluate it once at planning.
    if (v2.duckdb_v2_scalar_function_set_property(function, .FUNCTION_PROPERTY_STABILITY, .FUNCTION_PROPERTY_STABILITY_VOLATILE, err) != .ERROR_NONE) return error.FailedToSetProperty;
    if (v2.duckdb_v2_scalar_function_set_init_callback(function, &rowNumberInit, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &rowNumberExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the four examples. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerNegate(input, err);
    try registerRoundTo(input, err);
    try registerTimes(input, err);
    try registerRowNumber(input, err);
}
