///! Cookbook: a parallel table function (v2 C API, `function/table`): global state, local state, user data,
///! how many threads, and the ordering of the output.
///!
///!   zig_cookbook_parallel_range(n BIGINT, max_threads BIGINT := 4) -> (value, block, worker)
///!
///! produces 0 .. n-1 in blocks of 1000 rows, and several threads can scan it at once. The callbacks, in order:
///!
///!   bind            reads the arguments (constants), declares the columns, the cardinality and the **order the
///!                   rows come in**, leaves bind data
///!   init_global     once per scan: the state every thread shares (here the next block to hand out) and
///!                   **how many threads** may scan (`set_max_threads`; the default is one)
///!   init_local      once per thread: that thread's **local state**, needing no locks (here a worker number and
///!                   the block it works on), derived from the global state
///!   exec            per chunk, on any thread: claims a block from the global state, fills the chunk
///!   partition_data  after each exec, on the same thread: reports the **batch index** of the chunk, its position
///!                   in the output order. With insertion order kept (the default), the engine needs it to let
///!                   INSERT, COPY and query results run in parallel and still get the rows in order.
///!
///! The function's **user data** is the block size: set once at registration, read in exec.
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

/// Rows per block: a chunk holds at most 2048 rows, so one block is one chunk. Function-level user data.
const block_rows: u64 = 1000;

const columns = [_][]const u8{ "value", "block", "worker" };

const BindData = struct { n: u64, max_threads: u64 };

fn destroyBindData(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `bind` stored a `*BindData`.
    std.heap.c_allocator.destroy(@as(*BindData, @ptrCast(@alignCast(ptr))));
}

/// Shared by every thread of one scan.
const GlobalState = struct {
    next_block: std.atomic.Value(u64) = .init(0),
    next_worker: std.atomic.Value(u64) = .init(0),
};

fn destroyGlobalState(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `initGlobal` stored a `*GlobalState`.
    std.heap.c_allocator.destroy(@as(*GlobalState, @ptrCast(@alignCast(ptr))));
}

/// One thread's.
const LocalState = struct {
    worker: u64,
    /// The block claimed by the latest exec; the partition data callback reports it.
    block: u64 = 0,
};

fn destroyLocalState(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `initLocal` stored a `*LocalState`.
    std.heap.c_allocator.destroy(@as(*LocalState, @ptrCast(@alignCast(ptr))));
}

fn argInt(info: v2.duckdb_v2_function_bind_info_handle, index: u64, err: Err) ?i64 {
    var value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, index, &value, err) != .ERROR_NONE) return null;
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var out: i64 = 0;
    if (v2.duckdb_v2_value_get_bigint(value, &out, err) != .ERROR_NONE) return null;
    return out;
}

fn bind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    const n = argInt(info, 0, err) orelse return;
    const max_threads = argInt(info, 1, err) orelse return;
    if (n < 0) return fail(err, .ERROR_INPUT_PARAMETER_INVALID, "zig_cookbook_parallel_range: n must not be negative, got {d}", .{n});
    if (max_threads < 1 or max_threads > 64) return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "zig_cookbook_parallel_range: max_threads must be between 1 and 64, got {d}", .{max_threads});

    var bigint: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_BIGINT, &bigint, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint);
    inline for (columns) |column| {
        const column_name = helpers.str(column);
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &column_name, bigint, err) != .ERROR_NONE) return;
    }
    if (v2.duckdb_v2_table_function_bind_set_cardinality(result, @intCast(n), true, err) != .ERROR_NONE) return;
    // The rows come in insertion order: block 0 first. This is the default; saying so is the point.
    if (v2.duckdb_v2_table_function_bind_set_order_preservation(result, .ORDER_PRESERVATION_INSERTION_ORDER, err) != .ERROR_NONE) return;

    const data = std.heap.c_allocator.create(BindData) catch return;
    data.* = .{ .n = @intCast(n), .max_threads = @intCast(max_threads) };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyBindData, .equals = null };
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) destroyBindData(data);
}

fn initGlobal(
    info: v2.duckdb_v2_table_function_init_global_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_init_global_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `bind` stored a `*BindData`.
    const bound: *const BindData = @ptrCast(@alignCast(bind_ptr.?));
    // An upper bound: the engine may use fewer threads, and creates at most this many local states.
    if (v2.duckdb_v2_table_function_init_global_set_max_threads(info, bound.max_threads, err) != .ERROR_NONE) return;

    const state = std.heap.c_allocator.create(GlobalState) catch return;
    state.* = .{};
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
    if (v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyGlobalState(state);
}

fn initLocal(
    info: v2.duckdb_v2_table_function_init_local_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var global_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_init_local_get_global_state(info, &global_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `initGlobal` stored a `*GlobalState`.
    const global: *GlobalState = @ptrCast(@alignCast(global_ptr.?));

    const local = std.heap.c_allocator.create(LocalState) catch return;
    local.* = .{ .worker = global.next_worker.fetchAdd(1, .monotonic) };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = local, .destroy = destroyLocalState, .equals = null };
    if (v2.duckdb_v2_table_function_init_local_set_local_state(info, &boxed, err) != .ERROR_NONE) destroyLocalState(local);
}

fn exec(
    info: v2.duckdb_v2_table_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    var global_ptr: ?*anyopaque = null;
    var local_ptr: ?*anyopaque = null;
    var user_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &global_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_local_state(info, &local_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_user_data(info, &user_ptr, err) != .ERROR_NONE) return;
    // SAFETY: these are the types the callbacks above stored; `registerParallelRange` set `&block_rows` as user data.
    const bound: *const BindData = @ptrCast(@alignCast(bind_ptr.?));
    const global: *GlobalState = @ptrCast(@alignCast(global_ptr.?));
    const local: *LocalState = @ptrCast(@alignCast(local_ptr.?));
    const rows_per_block: u64 = @as(*const u64, @ptrCast(@alignCast(user_ptr.?))).*;

    // Claim the next block; past the end, produce no rows, which ends this thread's scan.
    local.block = global.next_block.fetchAdd(1, .monotonic);
    const start = local.block * rows_per_block;
    const rows: u64 = if (start >= bound.n) 0 else @min(rows_per_block, bound.n - start);

    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
    inline for (0..columns.len) |c| {
        var vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(vec, rows, err) != .ERROR_NONE) return;
        var data: ?*anyopaque = null;
        if (v2.duckdb_v2_vector_get_data_mutable(vec, &data, err) != .ERROR_NONE) return;
        // SAFETY: all three columns were declared BIGINT.
        const out: [*]i64 = @ptrCast(@alignCast(data orelse return));
        for (0..rows) |i| out[i] = switch (c) {
            0 => @intCast(start + i),
            1 => @intCast(local.block),
            else => @intCast(local.worker),
        };
    }
}

/// After each exec, on the same thread: where the chunk belongs in the output.
fn partitionData(
    info: v2.duckdb_v2_table_function_partition_data_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var local_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_partition_data_get_local_state(info, &local_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `initLocal` stored a `*LocalState`.
    const local: *const LocalState = @ptrCast(@alignCast(local_ptr.?));
    // The block number is the batch index: unique across threads and increasing along each thread's chunks.
    // It is reported even when nothing downstream asks for it (`partition_data_requires_batch_index`).
    _ = v2.duckdb_v2_table_function_partition_data_set_batch_index(info, local.block, err);
}

fn registerParallelRange(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);
    const name = helpers.str("zig_cookbook_parallel_range");
    if (v2.duckdb_v2_table_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;

    var bigint: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const n_name = helpers.str("n");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &n_name, bigint, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    var default_threads: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_bigint_with_context(input.context, 4, &default_threads, err) != .ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = v2.duckdb_v2_value_destroy(&default_threads);
    const threads_name = helpers.str("max_threads");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &threads_name, bigint, default_threads, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = @constCast(&block_rows), .destroy = null, .equals = null };
    if (v2.duckdb_v2_table_function_set_user_data(function, &boxed, err) != .ERROR_NONE) return error.FailedToSetUserData;
    if (v2.duckdb_v2_table_function_set_bind_callback(function, &bind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &initGlobal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_init_local_callback(function, &initLocal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_partition_data_callback(function, &partitionData, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_register(function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the example. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerParallelRange(input, err);
}
