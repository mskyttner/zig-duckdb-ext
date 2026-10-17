///! Cookbook: an aggregate function with a bind callback, bind data, user data and properties
///! (v2 C API, `function/aggregate`).
///!
///! An aggregate is a set of callbacks over *states*, one per group, that DuckDB allocates for you:
///!
///!   bind      at planning, once per call site: sees the argument types, sets the **return type**, leaves
///!             **bind data**; here the result type follows the argument (BIGINT stays BIGINT, DOUBLE DOUBLE)
///!   size      how many bytes a state needs
///!   init      sets fresh states
///!   update    folds a chunk of rows into the states of their groups; **update_get_bind_data** and
///!             **update_get_user_data** give it the data of this call site and of the function
///!   combine   merges the states of parallel workers
///!   finalize  writes one result per state (it can read the bind data too)
///!
///! and of properties that tell the planner what it may do: `AGG_ORDER_DEPENDENT` (default YES: the result
///! depends on the order of the rows, so `agg(x ORDER BY y)` sorts first) and `AGG_DISTINCT_DEPENDENT` (default YES:
///! `agg(DISTINCT x)` removes duplicates first).
///!
///!   zig_cookbook_agg_sum(x), zig_cookbook_agg_sumsq(x)   one set of callbacks, two functions: the user data is
///!                                                        the power (1 or 2). Declared order independent.
///!   zig_cookbook_agg_last(x BIGINT)                      the last non-NULL value; order dependent (the default)
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const Err = *v2.duckdb_v2_error_info_handle;

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    const text = helpers.str(msg);
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = v2.duckdb_v2_error_info_set_text(err.*, &text);
}

fn typeName(id: v2.DUCKDB_V2_LOGICAL_TYPE_ID) []const u8 {
    const tag = std.enums.tagName(v2.DUCKDB_V2_LOGICAL_TYPE_ID, id) orelse return "unknown";
    return tag["LOGICAL_TYPE_ID_".len..];
}

/// The states of a chunk, as the callbacks get them.
const States = [*]?*anyopaque;

// --- zig_cookbook_agg_sum / zig_cookbook_agg_sumsq ------------------------------------------------------

const Kind = enum { integer, double };

const SumBind = struct { kind: Kind };

fn destroySumBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `sumBind` stored a `*SumBind`.
    std.heap.c_allocator.destroy(@as(*SumBind, @ptrCast(@alignCast(ptr))));
}

/// One state per group; both sums exist so that the state size does not depend on the call site. `seen` is whether any
/// non-NULL value arrived: a sum of nothing is NULL, as for SQL's own SUM.
const SumState = struct { int: i64, dbl: f64, seen: bool };

/// The powers, as user data: pointers into this array are valid for the life of the program, so the
/// opaque handle has no destructor.
const powers = [_]u8{ 1, 2 };

fn sumBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_aggregate_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var ty: v2.duckdb_v2_logical_type_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_type(info, 0, &ty, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&ty);
    var id: v2.DUCKDB_V2_LOGICAL_TYPE_ID = undefined;
    if (v2.duckdb_v2_logical_type_get_id(ty, &id, err) != .ERROR_NONE) return;

    const kind: Kind = switch (id) {
        .LOGICAL_TYPE_ID_BIGINT => .integer,
        .LOGICAL_TYPE_ID_DOUBLE => .double,
        else => return fail(err, .ERROR_INPUT_INVALID, "zig_cookbook_agg_sum: expected BIGINT or DOUBLE, got {s}", .{typeName(id)}),
    };
    // The result type of this call site is the argument's.
    if (v2.duckdb_v2_aggregate_function_bind_set_return_type(result, ty, err) != .ERROR_NONE) return;

    const data = std.heap.c_allocator.create(SumBind) catch return;
    data.* = .{ .kind = kind };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroySumBind, .equals = null };
    // Aggregates (like table functions) set their bind data through the generic function bind info.
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) destroySumBind(data);
}

fn sumSize(info: v2.duckdb_v2_aggregate_function_size_info_handle, err: Err) callconv(.c) void {
    _ = v2.duckdb_v2_aggregate_function_size_set_state_size(info, @sizeOf(SumState), err);
}

fn sumInit(info: v2.duckdb_v2_aggregate_function_init_info_handle, err: Err) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_init_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var states: States = undefined;
    if (v2.duckdb_v2_aggregate_function_init_get_states(info, &states, err) != .ERROR_NONE) return;
    for (0..count) |i| {
        // SAFETY: DuckDB hands out `@sizeOf(SumState)` bytes per state, as `sumSize` asked.
        const state: *SumState = @ptrCast(@alignCast(states[i].?));
        state.* = .{ .int = 0, .dbl = 0, .seen = false };
    }
}

fn sumUpdate(info: v2.duckdb_v2_aggregate_function_update_info_handle, err: Err) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_update_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_aggregate_function_update_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    var user_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_aggregate_function_update_get_user_data(info, &user_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `sumBind` stored a `*SumBind`; `registerSum` set a pointer into `powers` as the user data.
    const bound: *const SumBind = @ptrCast(@alignCast(bind_ptr.?));
    const power: u8 = @as(*const u8, @ptrCast(@alignCast(user_ptr.?))).*;

    var arg_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_update_get_arg(info, 0, &arg_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(arg_vec, err) != .ERROR_NONE) return;
    var view: v2.duckdb_v2_vector_view = undefined;
    if (v2.duckdb_v2_vector_get_view(arg_vec, &view, err) != .ERROR_NONE) return;
    var states: States = undefined;
    if (v2.duckdb_v2_aggregate_function_update_get_states(info, &states, err) != .ERROR_NONE) return;

    var row: u64 = 0;
    switch (bound.kind) {
        .integer => {
            // SAFETY: bind accepted BIGINT, and the vector holds i64.
            const xs: [*]const i64 = @ptrCast(@alignCast(view.data orelse return));
            while (row < row_count) : (row += 1) {
                if (!helpers.isValid(view.validity, row)) continue;
                // SAFETY: as in `sumInit`.
                const state: *SumState = @ptrCast(@alignCast(states[row].?));
                state.seen = true;
                const term = if (power == 2) std.math.mul(i64, xs[row], xs[row]) else xs[row];
                state.int = std.math.add(i64, state.int, term catch return overflow(err)) catch return overflow(err);
            }
        },
        .double => {
            // SAFETY: bind accepted DOUBLE, and the vector holds f64.
            const xs: [*]const f64 = @ptrCast(@alignCast(view.data orelse return));
            while (row < row_count) : (row += 1) {
                if (!helpers.isValid(view.validity, row)) continue;
                // SAFETY: as in `sumInit`.
                const state: *SumState = @ptrCast(@alignCast(states[row].?));
                state.seen = true;
                state.dbl += if (power == 2) xs[row] * xs[row] else xs[row];
            }
        },
    }
}

fn overflow(err: Err) void {
    fail(err, .ERROR_INPUT_OUT_OF_RANGE, "Overflow in the sum of INT64", .{});
}

fn sumCombine(info: v2.duckdb_v2_aggregate_function_combine_info_handle, err: Err) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_combine_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var sources: States = undefined;
    if (v2.duckdb_v2_aggregate_function_combine_get_sources(info, &sources, err) != .ERROR_NONE) return;
    var targets: States = undefined;
    if (v2.duckdb_v2_aggregate_function_combine_get_targets(info, &targets, err) != .ERROR_NONE) return;
    for (0..count) |i| {
        // SAFETY: as in `sumInit`.
        const source: *const SumState = @ptrCast(@alignCast(sources[i].?));
        const target: *SumState = @ptrCast(@alignCast(targets[i].?));
        target.int = std.math.add(i64, target.int, source.int) catch return overflow(err);
        target.dbl += source.dbl;
        target.seen = target.seen or source.seen;
    }
}

fn sumFinalize(info: v2.duckdb_v2_aggregate_function_finalize_info_handle, err: Err) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_finalize_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var states: States = undefined;
    if (v2.duckdb_v2_aggregate_function_finalize_get_states(info, &states, err) != .ERROR_NONE) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_finalize_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    var offset: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_finalize_get_result_offset(info, &offset, err) != .ERROR_NONE) return;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_aggregate_function_finalize_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `sumBind` stored a `*SumBind`.
    const bound: *const SumBind = @ptrCast(@alignCast(bind_ptr.?));

    var out: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out, err) != .ERROR_NONE) return;
    for (0..count) |i| {
        // SAFETY: as in `sumInit`; the result vector has the type `sumBind` set.
        const state: *const SumState = @ptrCast(@alignCast(states[i].?));
        if (!state.seen) {
            if (v2.duckdb_v2_vector_set_null(result_vec, offset + i, err) != .ERROR_NONE) return;
            continue;
        }
        switch (bound.kind) {
            .integer => @as([*]i64, @ptrCast(@alignCast(out.?)))[offset + i] = state.int,
            .double => @as([*]f64, @ptrCast(@alignCast(out.?)))[offset + i] = state.dbl,
        }
    }
}

fn registerSum(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    inline for (.{ .{ "zig_cookbook_agg_sum", 0 }, .{ "zig_cookbook_agg_sumsq", 1 } }) |spec| {
        var function: v2.duckdb_v2_aggregate_function_handle = undefined;
        if (v2.duckdb_v2_aggregate_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
        defer _ = v2.duckdb_v2_aggregate_function_destroy(&function);
        const name = helpers.str(spec[0]);
        if (v2.duckdb_v2_aggregate_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;

        var any: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_ANY, &any, err) != .ERROR_NONE) return error.FailedToCreateType;
        defer _ = v2.duckdb_v2_logical_type_destroy(&any);
        var sig: v2.duckdb_v2_function_signature_handle = undefined;
        if (v2.duckdb_v2_aggregate_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
        const param = helpers.str("x");
        if (v2.duckdb_v2_function_signature_add_parameter(sig, &param, any, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
        // ANY out: the concrete result type is set per call site by `sumBind`.
        if (v2.duckdb_v2_function_signature_set_return_type(sig, any, err) != .ERROR_NONE) return error.FailedToSetReturnType;

        var boxed: v2.duckdb_v2_opaque = .{ .ptr = @constCast(&powers[spec[1]]), .destroy = null, .equals = null };
        if (v2.duckdb_v2_aggregate_function_set_user_data(function, &boxed, err) != .ERROR_NONE) return error.FailedToSetUserData;
        // The order of the rows does not change a sum, so `sum(x ORDER BY y)` need not sort first.
        if (v2.duckdb_v2_aggregate_function_set_property(function, .FUNCTION_PROPERTY_AGG_ORDER_DEPENDENT, .FUNCTION_PROPERTY_AGG_ORDER_DEPENDENT_NO, err) != .ERROR_NONE) return error.FailedToSetProperty;

        if (v2.duckdb_v2_aggregate_function_set_bind_callback(function, &sumBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
        if (v2.duckdb_v2_aggregate_function_set_size_callback(function, &sumSize, err) != .ERROR_NONE) return error.FailedToSetCallback;
        if (v2.duckdb_v2_aggregate_function_set_init_callback(function, &sumInit, err) != .ERROR_NONE) return error.FailedToSetCallback;
        if (v2.duckdb_v2_aggregate_function_set_update_callback(function, &sumUpdate, err) != .ERROR_NONE) return error.FailedToSetCallback;
        if (v2.duckdb_v2_aggregate_function_set_combine_callback(function, &sumCombine, err) != .ERROR_NONE) return error.FailedToSetCallback;
        if (v2.duckdb_v2_aggregate_function_set_finalize_callback(function, &sumFinalize, err) != .ERROR_NONE) return error.FailedToSetCallback;
        if (v2.duckdb_v2_aggregate_function_register(function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
    }
}

// --- zig_cookbook_agg_last(x BIGINT) -> BIGINT: order dependent -----------------------------------------

const LastState = struct { value: i64, seen: bool };

fn lastSize(info: v2.duckdb_v2_aggregate_function_size_info_handle, err: Err) callconv(.c) void {
    _ = v2.duckdb_v2_aggregate_function_size_set_state_size(info, @sizeOf(LastState), err);
}

fn lastInit(info: v2.duckdb_v2_aggregate_function_init_info_handle, err: Err) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_init_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var states: States = undefined;
    if (v2.duckdb_v2_aggregate_function_init_get_states(info, &states, err) != .ERROR_NONE) return;
    for (0..count) |i| {
        // SAFETY: DuckDB hands out `@sizeOf(LastState)` bytes per state.
        const state: *LastState = @ptrCast(@alignCast(states[i].?));
        state.* = .{ .value = 0, .seen = false };
    }
}

fn lastUpdate(info: v2.duckdb_v2_aggregate_function_update_info_handle, err: Err) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_update_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var arg_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_update_get_arg(info, 0, &arg_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(arg_vec, err) != .ERROR_NONE) return;
    var view: v2.duckdb_v2_vector_view = undefined;
    if (v2.duckdb_v2_vector_get_view(arg_vec, &view, err) != .ERROR_NONE) return;
    var states: States = undefined;
    if (v2.duckdb_v2_aggregate_function_update_get_states(info, &states, err) != .ERROR_NONE) return;
    // SAFETY: the signature registered the argument as BIGINT.
    const xs: [*]const i64 = @ptrCast(@alignCast(view.data orelse return));
    for (0..row_count) |row| {
        if (!helpers.isValid(view.validity, row)) continue;
        // SAFETY: as in `lastInit`.
        const state: *LastState = @ptrCast(@alignCast(states[row].?));
        state.* = .{ .value = xs[row], .seen = true };
    }
}

/// Merging two states needs an order, which an order dependent aggregate does not have on its own; the later state wins
/// here. The callback is required, but no query in the tests reaches it (an ordered `last` runs in one state).
fn lastCombine(info: v2.duckdb_v2_aggregate_function_combine_info_handle, err: Err) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_combine_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var sources: States = undefined;
    if (v2.duckdb_v2_aggregate_function_combine_get_sources(info, &sources, err) != .ERROR_NONE) return;
    var targets: States = undefined;
    if (v2.duckdb_v2_aggregate_function_combine_get_targets(info, &targets, err) != .ERROR_NONE) return;
    for (0..count) |i| {
        // SAFETY: as in `lastInit`.
        const source: *const LastState = @ptrCast(@alignCast(sources[i].?));
        const target: *LastState = @ptrCast(@alignCast(targets[i].?));
        if (source.seen) target.* = source.*;
    }
}

fn lastFinalize(info: v2.duckdb_v2_aggregate_function_finalize_info_handle, err: Err) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_finalize_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var states: States = undefined;
    if (v2.duckdb_v2_aggregate_function_finalize_get_states(info, &states, err) != .ERROR_NONE) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_finalize_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    var offset: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_finalize_get_result_offset(info, &offset, err) != .ERROR_NONE) return;
    var out: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out, err) != .ERROR_NONE) return;
    // SAFETY: the signature registered the result as BIGINT.
    const ys: [*]i64 = @ptrCast(@alignCast(out.?));
    for (0..count) |i| {
        // SAFETY: as in `lastInit`.
        const state: *const LastState = @ptrCast(@alignCast(states[i].?));
        // A group without a non-NULL value has no last value: NULL.
        if (state.seen) ys[offset + i] = state.value else if (v2.duckdb_v2_vector_set_null(result_vec, offset + i, err) != .ERROR_NONE) return;
    }
}

fn registerLast(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_aggregate_function_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_aggregate_function_destroy(&function);
    const name = helpers.str("zig_cookbook_agg_last");
    if (v2.duckdb_v2_aggregate_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;

    var bigint: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const param = helpers.str("x");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &param, bigint, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, bigint, err) != .ERROR_NONE) return error.FailedToSetReturnType;
    // No property is set: the defaults say the result depends on the order of the rows and on DISTINCT.

    if (v2.duckdb_v2_aggregate_function_set_size_callback(function, &lastSize, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_aggregate_function_set_init_callback(function, &lastInit, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_aggregate_function_set_update_callback(function, &lastUpdate, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_aggregate_function_set_combine_callback(function, &lastCombine, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_aggregate_function_set_finalize_callback(function, &lastFinalize, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_aggregate_function_register(function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the three aggregates. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerSum(input, err);
    try registerLast(input, err);
}
