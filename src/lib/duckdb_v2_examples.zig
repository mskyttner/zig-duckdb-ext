///! Worked examples for the generated v2 bindings (`duckdb_v2_dynamic`) — hand-written
///! proofs-of-concept for each function kind (scalar numeric, scalar
///! VARCHAR, table, aggregate), written before the comptime frameworks
///! existed to prove each piece of the vtable by hand first. Kept
///! separate from the bindings themselves (which are real bindings only, no
///! demo code — matching v1's `duckdb.zig`) purely so
///! `src/ext/init_v2_poc.zig`'s disposable experimentation harness has
///! something to register; not part of the permanent extension.
const std = @import("std");
const v2 = @import("duckdb_v2_dynamic");
const helpers = @import("v2_helpers");

// ─── Worked example ──────────────────────────────────────────────────────
//
// A v2 port of the v1 `hello.zig`-style trivial scalar function, written by
// hand (not through the comptime framework yet) to prove the exec callback
// round trip: read one BIGINT arg through a `VectorView`, double it, write
// through `vectorGetDataMutable`. NULL propagation uses `view.validity`
// (null = "no NULLs present", matching v1's `vectorGetValidity` convention)
// and `vectorSetNull` for the slow path.
//
// Not registered against a real connection anywhere yet — `v2-check` only
// type-checks this against the vtable's declared signatures.
const example = struct {
    // `err` must match the callback typedef's pointer type exactly — assigning a fn literal to
    // a function-pointer-typed field requires an exact type match.
    fn doubleExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        _ = context;
        var row_count: u64 = 0;
        if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

        var arg_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_scalar_function_exec_get_arg(info, 0, &arg_vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_flatten(arg_vec, err) != .ERROR_NONE) return;

        var view: v2.duckdb_v2_vector_view = undefined;
        if (v2.duckdb_v2_vector_get_view(arg_vec, &view, err) != .ERROR_NONE) return;

        var result_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
        // The result vector starts at whatever size it was last used at (often
        // 1) — must grow it to row_count before writing/nulling past index 0,
        // or duckdb_v2_vector_set_null rejects out-of-range rows.
        if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

        var out_data: ?*anyopaque = null;
        if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
        // SAFETY: the signature registered this function as (BIGINT) -> BIGINT,
        // so the arg view and result buffer are both i64-typed by construction.
        const in: [*]const i64 = @ptrCast(@alignCast(view.data));
        const out: [*]i64 = @ptrCast(@alignCast(out_data));

        var row: u64 = 0;
        while (row < row_count) : (row += 1) {
            if (view.validity != null and !isValid(view.validity.?, row)) {
                if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                continue;
            }
            out[row] = in[row] * 2;
        }
    }

    inline fn isValid(validity: [*]const u64, row: u64) bool {
        const entry_idx = row / 64;
        const bit_idx: u6 = @intCast(row % 64);
        return (validity[entry_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }
};

/// Re-export of `example.doubleExec` for `src/ext/init_v2_poc.zig`'s live
/// registration test.
pub const exampleDoubleExecForPoc = example.doubleExec;

// ─── Worked example: VARCHAR scalar function ─────────────────────────────
//
// A v2 port of the v1 `hello.zig` example: `zig_v2_hello(name VARCHAR) ->
// VARCHAR`, proving the first-cut VARCHAR read/write path by hand before
// generalizing it into comptime_scalar_v2. Reads via `bytesSlice` directly
// off the flattened arg vector (zero-copy, same as any numeric read);
// writes via `valueCreateVarcharWithContext` + `vectorSetValue` (boxed,
// simpler than hand-rolling the inline/arena encoding — see those
// functions' own doc comments for the tradeoff).
const varchar_example = struct {
    fn helloExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        var row_count: u64 = 0;
        if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

        var arg_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_scalar_function_exec_get_arg(info, 0, &arg_vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_flatten(arg_vec, err) != .ERROR_NONE) return;
        var view: v2.duckdb_v2_vector_view = undefined;
        if (v2.duckdb_v2_vector_get_view(arg_vec, &view, err) != .ERROR_NONE) return;

        var result_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

        // SAFETY: the signature registered this function as (VARCHAR) -> VARCHAR.
        const in: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(view.data));

        var row: u64 = 0;
        while (row < row_count) : (row += 1) {
            if (view.validity != null and !example.isValid(view.validity.?, row)) {
                if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                continue;
            }
            const name = helpers.bytesSlice(&in[row]);
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

            var value: v2.duckdb_v2_value_handle = undefined;
            if (helpers.createVarcharValue(context, greeting, &value, err) != .ERROR_NONE) return;
            defer _ = v2.duckdb_v2_value_destroy(&value);
            if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
        }
    }
};

pub const exampleHelloExecForPoc = varchar_example.helloExec;

// ─── Worked example: table function ──────────────────────────────────────
//
// `zig_v2_range3()`: a fixed-arity, non-parallel table function returning
// one BIGINT column `n` over 3 rows (0, 1, 2) — proves bind → init_global →
// exec against a live runtime. Global state is a single heap-allocated
// `GlobalState.emitted` flag, boxed in a `duckdb_v2_opaque` (ptr + destroy +
// equals) via `table_function_init_global_set_global_state` so DuckDB frees
// it itself when the query ends — see `duckdb_v2_opaque`'s doc comment in the generated types.
const table_example = struct {
    const GlobalState = struct { emitted: bool };

    fn destroyGlobalState(data: ?*anyopaque) callconv(.c) void {
        const state: *GlobalState = @ptrCast(@alignCast(data.?));
        std.heap.c_allocator.destroy(state);
    }

    fn bind(info: v2.duckdb_v2_function_bind_info_handle, result: v2.duckdb_v2_table_function_bind_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        _ = info;
        var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);

        const col_name = helpers.str("n");
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &col_name, bigint_type, err) != .ERROR_NONE) return;
        _ = v2.duckdb_v2_table_function_bind_set_cardinality(result, 3, true, err);
    }

    fn initGlobal(info: v2.duckdb_v2_table_function_init_global_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        _ = context;
        const state = std.heap.c_allocator.create(GlobalState) catch return;
        state.* = .{ .emitted = false };
        var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
        _ = v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err);
    }

    fn exec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        _ = context;
        var state_ptr: ?*anyopaque = null;
        if (v2.duckdb_v2_table_function_exec_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
        // SAFETY: the pointer stored in initGlobal is always a *GlobalState.
        const state: *GlobalState = @ptrCast(@alignCast(state_ptr.?));

        var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
        if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
        var col0: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, 0, &col0, err) != .ERROR_NONE) return;

        // A table function signals end-of-scan by returning a 0-size chunk.
        if (state.emitted) {
            _ = v2.duckdb_v2_vector_set_size(col0, 0, err);
            return;
        }

        if (v2.duckdb_v2_vector_set_size(col0, 3, err) != .ERROR_NONE) return;
        var out_data: ?*anyopaque = null;
        if (v2.duckdb_v2_vector_get_data_mutable(col0, &out_data, err) != .ERROR_NONE) return;
        const out: [*]i64 = @ptrCast(@alignCast(out_data));
        out[0] = 0;
        out[1] = 1;
        out[2] = 2;
        state.emitted = true;
    }
};

pub const exampleTableBindForPoc = table_example.bind;
pub const exampleTableInitGlobalForPoc = table_example.initGlobal;
pub const exampleTableExecForPoc = table_example.exec;

// ─── Worked example: aggregate function ──────────────────────────────────
//
// `zig_v2_agg_sum(x BIGINT) -> BIGINT`: proves the full size → init →
// update → combine → finalize lifecycle, v2's biggest structural departure
// from v1 — every stage is batched over an array of state pointers rather
// than one state at a time. No bind callback needed (return type is fixed
// via the signature, not dynamic), no destroy callback needed (the state
// owns no resources).
const aggregate_example = struct {
    const SumState = struct { sum: i64 };

    fn size(info: v2.duckdb_v2_aggregate_function_size_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        _ = v2.duckdb_v2_aggregate_function_size_set_state_size(info, @sizeOf(SumState), err);
    }

    fn init(info: v2.duckdb_v2_aggregate_function_init_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        var count: u64 = 0;
        if (v2.duckdb_v2_aggregate_function_init_get_state_count(info, &count, err) != .ERROR_NONE) return;
        var states: [*]?*anyopaque = undefined;
        if (v2.duckdb_v2_aggregate_function_init_get_states(info, &states, err) != .ERROR_NONE) return;

        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const state: *SumState = @ptrCast(@alignCast(states[i].?));
            state.* = .{ .sum = 0 };
        }
    }

    fn update(info: v2.duckdb_v2_aggregate_function_update_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        var row_count: u64 = 0;
        if (v2.duckdb_v2_aggregate_function_update_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

        var arg_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_aggregate_function_update_get_arg(info, 0, &arg_vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_flatten(arg_vec, err) != .ERROR_NONE) return;
        var view: v2.duckdb_v2_vector_view = undefined;
        if (v2.duckdb_v2_vector_get_view(arg_vec, &view, err) != .ERROR_NONE) return;

        var states: [*]?*anyopaque = undefined;
        if (v2.duckdb_v2_aggregate_function_update_get_states(info, &states, err) != .ERROR_NONE) return;

        // SAFETY: the signature registered this function as (BIGINT) -> BIGINT.
        const values: [*]const i64 = @ptrCast(@alignCast(view.data));
        var row: u64 = 0;
        while (row < row_count) : (row += 1) {
            if (view.validity != null and !example.isValid(view.validity.?, row)) continue;
            const state: *SumState = @ptrCast(@alignCast(states[row].?));
            state.sum += values[row];
        }
    }

    fn combine(info: v2.duckdb_v2_aggregate_function_combine_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        var count: u64 = 0;
        if (v2.duckdb_v2_aggregate_function_combine_get_state_count(info, &count, err) != .ERROR_NONE) return;
        var sources: [*]?*anyopaque = undefined;
        if (v2.duckdb_v2_aggregate_function_combine_get_sources(info, &sources, err) != .ERROR_NONE) return;
        var targets: [*]?*anyopaque = undefined;
        if (v2.duckdb_v2_aggregate_function_combine_get_targets(info, &targets, err) != .ERROR_NONE) return;

        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const source: *SumState = @ptrCast(@alignCast(sources[i].?));
            const target: *SumState = @ptrCast(@alignCast(targets[i].?));
            target.sum += source.sum;
        }
    }

    fn finalize(info: v2.duckdb_v2_aggregate_function_finalize_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
        var count: u64 = 0;
        if (v2.duckdb_v2_aggregate_function_finalize_get_state_count(info, &count, err) != .ERROR_NONE) return;
        var states: [*]?*anyopaque = undefined;
        if (v2.duckdb_v2_aggregate_function_finalize_get_states(info, &states, err) != .ERROR_NONE) return;
        var result_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_aggregate_function_finalize_get_result(info, &result_vec, err) != .ERROR_NONE) return;
        var offset: u64 = 0;
        if (v2.duckdb_v2_aggregate_function_finalize_get_result_offset(info, &offset, err) != .ERROR_NONE) return;

        var out_data: ?*anyopaque = null;
        if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
        const out: [*]i64 = @ptrCast(@alignCast(out_data));

        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const state: *SumState = @ptrCast(@alignCast(states[i].?));
            out[offset + i] = state.sum;
        }
    }
};

pub const exampleAggregateSizeForPoc = aggregate_example.size;
pub const exampleAggregateInitForPoc = aggregate_example.init;
pub const exampleAggregateUpdateForPoc = aggregate_example.update;
pub const exampleAggregateCombineForPoc = aggregate_example.combine;
pub const exampleAggregateFinalizeForPoc = aggregate_example.finalize;

// ─── Tests ────────────────────────────────────────────────────────────────
//
// These examples are also verified against a real, live DuckDB v2.0 alpha
// runtime via `src/ext/init_v2_poc.zig` + `zig build v2-poc` — see that file.

test "example.doubleExec matches the exec callback signature" {
    // Taking the function's address forces Zig to semantically analyze its
    // body (analysis is lazy per-function) — this is the only thing that
    // actually type-checks the worked example above, since nothing calls it.
    const cb: v2.duckdb_v2_scalar_function_exec_callback_fn = example.doubleExec;
    try std.testing.expect(@intFromPtr(cb) != 0);
}

test "varchar_example.helloExec matches the exec callback signature" {
    const cb: v2.duckdb_v2_scalar_function_exec_callback_fn = varchar_example.helloExec;
    try std.testing.expect(@intFromPtr(cb) != 0);
}

test "table_example callbacks match their callback signatures" {
    const bind_cb: v2.duckdb_v2_table_function_bind_callback_fn = table_example.bind;
    const init_cb: v2.duckdb_v2_table_function_init_global_callback_fn = table_example.initGlobal;
    const exec_cb: v2.duckdb_v2_table_function_exec_callback_fn = table_example.exec;
    try std.testing.expect(@intFromPtr(bind_cb) != 0);
    try std.testing.expect(@intFromPtr(init_cb) != 0);
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "aggregate_example callbacks match their callback signatures" {
    const size_cb: v2.duckdb_v2_aggregate_function_size_callback_fn = aggregate_example.size;
    const init_cb: v2.duckdb_v2_aggregate_function_init_callback_fn = aggregate_example.init;
    const update_cb: v2.duckdb_v2_aggregate_function_update_callback_fn = aggregate_example.update;
    const combine_cb: v2.duckdb_v2_aggregate_function_combine_callback_fn = aggregate_example.combine;
    const finalize_cb: v2.duckdb_v2_aggregate_function_finalize_callback_fn = aggregate_example.finalize;
    try std.testing.expect(@intFromPtr(size_cb) != 0);
    try std.testing.expect(@intFromPtr(init_cb) != 0);
    try std.testing.expect(@intFromPtr(update_cb) != 0);
    try std.testing.expect(@intFromPtr(combine_cb) != 0);
    try std.testing.expect(@intFromPtr(finalize_cb) != 0);
}

test "example.isValid reads validity bits correctly" {
    var bits: [1]u64 = .{0b101};
    try std.testing.expect(example.isValid(&bits, 0));
    try std.testing.expect(!example.isValid(&bits, 1));
    try std.testing.expect(example.isValid(&bits, 2));
}
