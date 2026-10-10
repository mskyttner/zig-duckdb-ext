///! Worked examples for the v2 bindings in `duckdb_v2.zig` — hand-written
///! proofs-of-concept for each function kind (scalar numeric, scalar
///! VARCHAR, table, aggregate), written before the comptime frameworks
///! existed to prove each piece of the vtable by hand first. Kept
///! separate from `duckdb_v2.zig` itself (which is real bindings only, no
///! demo code — matching v1's `duckdb.zig`) purely so
///! `src/ext/init_v2_poc.zig`'s disposable experimentation harness has
///! something to register; not part of the permanent extension.
const std = @import("std");
const db = @import("duckdb_v2");

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
    // `err` must match the vtable's raw `[*c]ErrorInfoHandle` C-pointer type
    // exactly — assigning a fn literal to a function-pointer-typed field
    // requires an exact type match, unlike ordinary argument passing (which
    // auto-coerces `*T` to `[*c]T`, as every other wrapper above relies on).
    fn doubleExec(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        _ = context;
        var row_count: db.idx_t = 0;
        if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var arg_vec: db.VectorHandle = undefined;
        if (db.scalarFunctionExecGetArg(info, 0, &arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        if (db.vectorFlatten(arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var view: db.VectorView = undefined;
        if (db.vectorGetView(arg_vec, &view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var result_vec: db.VectorHandle = undefined;
        if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        // The result vector starts at whatever size it was last used at (often
        // 1) — must grow it to row_count before writing/nulling past index 0,
        // or duckdb_v2_vector_set_null rejects out-of-range rows.
        if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var out_data: ?*anyopaque = null;
        if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        // SAFETY: the signature registered this function as (BIGINT) -> BIGINT,
        // so the arg view and result buffer are both i64-typed by construction.
        const in: [*]const i64 = @ptrCast(@alignCast(view.data));
        const out: [*]i64 = @ptrCast(@alignCast(out_data));

        var row: db.idx_t = 0;
        while (row < row_count) : (row += 1) {
            if (view.validity != null and !isValid(view.validity.?, row)) {
                if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                continue;
            }
            out[row] = in[row] * 2;
        }
    }

    inline fn isValid(validity: [*]const u64, row: db.idx_t) bool {
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
    fn helloExec(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
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
            if (view.validity != null and !example.isValid(view.validity.?, row)) {
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
};

pub const exampleHelloExecForPoc = varchar_example.helloExec;

// ─── Worked example: table function ──────────────────────────────────────
//
// `zig_v2_range3()`: a fixed-arity, non-parallel table function returning
// one BIGINT column `n` over 3 rows (0, 1, 2) — proves bind → init_global →
// exec against a live runtime. Global state is a single heap-allocated
// `GlobalState.emitted` flag, boxed in a `duckdb_v2_opaque` (ptr + destroy +
// equals) via `table_function_init_global_set_global_state` so DuckDB frees
// it itself when the query ends — see `Opaque`'s doc comment in duckdb_v2.zig.
const table_example = struct {
    const GlobalState = struct { emitted: bool };

    fn destroyGlobalState(data: ?*anyopaque) callconv(.c) void {
        const state: *GlobalState = @ptrCast(@alignCast(data.?));
        std.heap.c_allocator.destroy(state);
    }

    fn bind(info: db.c.duckdb_v2_function_bind_info_handle, result: db.TableFunctionBindInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        _ = info;
        var bigint_type: db.LogicalTypeHandle = undefined;
        if (db.contextCreateTypeFromId(context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = db.logicalTypeDestroy(&bigint_type);

        const col_name = db.str("n");
        if (db.tableFunctionBindAddResultColumn(result, &col_name, bigint_type, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        _ = db.tableFunctionBindSetCardinality(result, 3, true, err);
    }

    fn initGlobal(info: db.TableFunctionInitGlobalInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        _ = context;
        const state = std.heap.c_allocator.create(GlobalState) catch return;
        state.* = .{ .emitted = false };
        var boxed: db.Opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
        _ = db.tableFunctionInitGlobalSetGlobalState(info, &boxed, err);
    }

    fn exec(info: db.TableFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        _ = context;
        var state_ptr: ?*anyopaque = null;
        if (db.tableFunctionExecGetGlobalState(info, &state_ptr, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        // SAFETY: the pointer stored in initGlobal is always a *GlobalState.
        const state: *GlobalState = @ptrCast(@alignCast(state_ptr.?));

        var chunk: db.DataChunkHandle = undefined;
        if (db.tableFunctionExecGetOutputChunk(info, &chunk, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var col0: db.VectorHandle = undefined;
        if (db.dataChunkGetVector(chunk, 0, &col0, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        // A table function signals end-of-scan by returning a 0-size chunk.
        if (state.emitted) {
            _ = db.vectorSetSize(col0, 0, err);
            return;
        }

        if (db.vectorSetSize(col0, 3, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var out_data: ?*anyopaque = null;
        if (db.vectorGetDataMutable(col0, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
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

    fn size(info: db.AggregateFunctionSizeInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        _ = db.aggregateFunctionSizeSetStateSize(info, @sizeOf(SumState), err);
    }

    fn init(info: db.AggregateFunctionInitInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        var count: db.idx_t = 0;
        if (db.aggregateFunctionInitGetStateCount(info, &count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var states: [*c]?*anyopaque = null;
        if (db.aggregateFunctionInitGetStates(info, &states, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var i: db.idx_t = 0;
        while (i < count) : (i += 1) {
            const state: *SumState = @ptrCast(@alignCast(states[i].?));
            state.* = .{ .sum = 0 };
        }
    }

    fn update(info: db.AggregateFunctionUpdateInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        var row_count: db.idx_t = 0;
        if (db.aggregateFunctionUpdateGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var arg_vec: db.VectorHandle = undefined;
        if (db.aggregateFunctionUpdateGetArg(info, 0, &arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        if (db.vectorFlatten(arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var view: db.VectorView = undefined;
        if (db.vectorGetView(arg_vec, &view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var states: [*c]?*anyopaque = null;
        if (db.aggregateFunctionUpdateGetStates(info, &states, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        // SAFETY: the signature registered this function as (BIGINT) -> BIGINT.
        const values: [*]const i64 = @ptrCast(@alignCast(view.data));
        var row: db.idx_t = 0;
        while (row < row_count) : (row += 1) {
            if (view.validity != null and !example.isValid(view.validity.?, row)) continue;
            const state: *SumState = @ptrCast(@alignCast(states[row].?));
            state.sum += values[row];
        }
    }

    fn combine(info: db.AggregateFunctionCombineInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        var count: db.idx_t = 0;
        if (db.aggregateFunctionCombineGetStateCount(info, &count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var sources: [*c]?*anyopaque = null;
        if (db.aggregateFunctionCombineGetSources(info, &sources, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var targets: [*c]?*anyopaque = null;
        if (db.aggregateFunctionCombineGetTargets(info, &targets, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var i: db.idx_t = 0;
        while (i < count) : (i += 1) {
            const source: *SumState = @ptrCast(@alignCast(sources[i].?));
            const target: *SumState = @ptrCast(@alignCast(targets[i].?));
            target.sum += source.sum;
        }
    }

    fn finalize(info: db.AggregateFunctionFinalizeInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
        var count: db.idx_t = 0;
        if (db.aggregateFunctionFinalizeGetStateCount(info, &count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var states: [*c]?*anyopaque = null;
        if (db.aggregateFunctionFinalizeGetStates(info, &states, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var result_vec: db.VectorHandle = undefined;
        if (db.aggregateFunctionFinalizeGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        var offset: db.idx_t = 0;
        if (db.aggregateFunctionFinalizeGetResultOffset(info, &offset, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

        var out_data: ?*anyopaque = null;
        if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        const out: [*]i64 = @ptrCast(@alignCast(out_data));

        var i: db.idx_t = 0;
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
    const cb: db.ScalarFunctionExecCallback = example.doubleExec;
    try std.testing.expect(cb != null);
}

test "varchar_example.helloExec matches the exec callback signature" {
    const cb: db.ScalarFunctionExecCallback = varchar_example.helloExec;
    try std.testing.expect(cb != null);
}

test "table_example callbacks match their callback signatures" {
    const bind_cb: db.c.duckdb_v2_table_function_bind_callback_fn = table_example.bind;
    const init_cb: db.c.duckdb_v2_table_function_init_global_callback_fn = table_example.initGlobal;
    const exec_cb: db.c.duckdb_v2_table_function_exec_callback_fn = table_example.exec;
    try std.testing.expect(bind_cb != null);
    try std.testing.expect(init_cb != null);
    try std.testing.expect(exec_cb != null);
}

test "aggregate_example callbacks match their callback signatures" {
    const size_cb: db.c.duckdb_v2_aggregate_function_size_callback_fn = aggregate_example.size;
    const init_cb: db.c.duckdb_v2_aggregate_function_init_callback_fn = aggregate_example.init;
    const update_cb: db.c.duckdb_v2_aggregate_function_update_callback_fn = aggregate_example.update;
    const combine_cb: db.c.duckdb_v2_aggregate_function_combine_callback_fn = aggregate_example.combine;
    const finalize_cb: db.c.duckdb_v2_aggregate_function_finalize_callback_fn = aggregate_example.finalize;
    try std.testing.expect(size_cb != null);
    try std.testing.expect(init_cb != null);
    try std.testing.expect(update_cb != null);
    try std.testing.expect(combine_cb != null);
    try std.testing.expect(finalize_cb != null);
}

test "example.isValid reads validity bits correctly" {
    var bits: [1]u64 = .{0b101};
    try std.testing.expect(example.isValid(&bits, 0));
    try std.testing.expect(!example.isValid(&bits, 1));
    try std.testing.expect(example.isValid(&bits, 2));
}
