///! Cookbook: a table function that takes work from the engine: **filter pushdown**, **projection pushdown** and
///! **partitioning** (v2 C API, `function/table`).
///!
///!   zig_cookbook_range(n BIGINT) -> (value BIGINT, bucket BIGINT, square BIGINT)
///!   zig_cookbook_range_stats(reset := false) -> (filters_offered, filters_accepted, rows_produced, columns_mask, batches, partition_values)
///!
///! `value` is 0 .. n-1, `bucket` is `value // 1000`, `square` is `value * value`. Rows are produced in blocks of 1000 by up
///! to four threads (the parallel scan of `table_callbacks.zig`, which explains the state, the batch index and the order).
///! The three things below are optional; each lets the scan do less than the engine would otherwise ask of it, and each is
///! a **promise**: what the function accepts or claims, it must do exactly, or the query returns wrong rows.
///!
///! **Filters** (`set_filter_pushdown_callback`). At optimization, after bind and before any init, the callback is offered the
///! predicates of the query (they are ANDed; `WHERE` conjuncts) as bound expressions: it looks at each, and `accept`s the
///! ones it will apply itself, usually by recording them in the bind data. The engine then stops applying those and
///! keeps the others above the scan. Here a comparison of `value` or `bucket` with a constant (`=`, `<`, `<=`, `>`, `>=`,
///! the column on the left, as the engine writes it) narrows the range of values to produce, so a filtered scan produces only the rows it
///! needs. `bucket = 7` becomes `value` in 7000 .. 7999: a predicate on one column can be answered through another.
///! Everything else (`square`, `value % 2 = 0`, `IN`, `OR`) is left alone. The callback can run more than once for a
///! query, with the predicates not yet accepted; a column reference in a predicate indexes the columns the query reads,
///! so `filter_pushdown_get_column_index` maps it to the declared column.
///!
///! **Projection** (`set_projection_pushdown`). With it the exec callback's output chunk holds one vector per column the
///! query uses, not one per declared column, and `exec_get_column_index` says which declared column each stands for. A
///! query that needs only `value` does not compute the squares. Without it the engine drops the unused columns itself.
///!
///! **Partitioning** (`set_partitioning_callback` and `set_partition_data_callback`, which must come together). For a
///! `GROUP BY` the optimizer asks which column sets the scan can answer with *one value per partition*: here `bucket` alone,
///! because a block lies inside one bucket. When it is `TABLE_PARTITION_INFO_SINGLE_VALUE_PARTITIONS` the aggregate runs
///! per partition without a hash table (`PARTITIONED_AGGREGATE` in `EXPLAIN`), and the partition data callback then reports
///! the bucket of each batch it produced, together with the batch index (which must change when the value does).
///!
///! `zig_cookbook_range_stats()` is how a test sees all this from SQL: how many filters were offered and accepted, how many
///! rows the scan produced (fewer than n when a filter was pushed), which declared columns the last scan was asked for (a
///! bit mask: 1 value, 2 bucket, 4 square), and how many batches and partition values were reported.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const Err = *v2.duckdb_v2_error_info_handle;
const gpa = std.heap.c_allocator;

const block_rows: u64 = 1000;
const max_threads: u64 = 4;
const column_names = [_][]const u8{ "value", "bucket", "square" };

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [300]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    const text = helpers.str(msg);
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = v2.duckdb_v2_error_info_set_text(err.*, &text);
}

fn oom(err: Err) void {
    fail(err, .ERROR_RESOURCE_OUT_OF_MEMORY, "out of memory", .{});
}

// --- what the scans did, for the test ---------------------------------------------------------------------------------

const Stats = struct {
    filters_offered: std.atomic.Value(i64) = .init(0),
    filters_accepted: std.atomic.Value(i64) = .init(0),
    rows_produced: std.atomic.Value(i64) = .init(0),
    columns_mask: std.atomic.Value(i64) = .init(0),
    batches: std.atomic.Value(i64) = .init(0),
    partition_values: std.atomic.Value(i64) = .init(0),
};
var stats: Stats = .{};

// --- bind data, scan state -----------------------------------------------------------------------------------------------

/// The rows to produce are `value` in `lo .. hi`. Bind sets 0 .. n; the filter pushdown callback narrows it. Nothing else
/// reads it before the scan starts, so no lock is needed.
const BindData = struct {
    n: i64,
    lo: i64,
    hi: i64,
};

fn destroyBindData(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `bind` stored a `*BindData`.
    gpa.destroy(@as(*BindData, @ptrCast(@alignCast(ptr))));
}

const GlobalState = struct {
    next_block: std.atomic.Value(u64),
    /// The blocks that hold `lo .. hi`: `first_block .. end_block`.
    end_block: u64,
};

fn destroyGlobalState(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `initGlobal` stored a `*GlobalState`.
    gpa.destroy(@as(*GlobalState, @ptrCast(@alignCast(ptr))));
}

const LocalState = struct { block: u64 = 0 };

fn destroyLocalState(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `initLocal` stored a `*LocalState`.
    gpa.destroy(@as(*LocalState, @ptrCast(@alignCast(ptr))));
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
    if (n < 0) return fail(err, .ERROR_INPUT_PARAMETER_INVALID, "zig_cookbook_range: n must not be negative, got {d}", .{n});

    var bigint: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_BIGINT, &bigint, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint);
    inline for (column_names) |column| {
        const name = helpers.str(column);
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &name, bigint, err) != .ERROR_NONE) return;
    }
    if (v2.duckdb_v2_table_function_bind_set_cardinality(result, @intCast(n), false, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_bind_set_order_preservation(result, .ORDER_PRESERVATION_INSERTION_ORDER, err) != .ERROR_NONE) return;

    const data = gpa.create(BindData) catch return oom(err);
    data.* = .{ .n = n, .lo = 0, .hi = n };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyBindData, .equals = null };
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) destroyBindData(data);
}

// --- filter pushdown -------------------------------------------------------------------------------------------------------

/// A comparison with its column on the left: `column <op> constant`.
const Op = enum { eq, lt, le, gt, ge };

fn opOf(t: v2.DUCKDB_V2_EXPRESSION_TYPE) ?Op {
    return switch (t) {
        .EXPRESSION_TYPE_COMPARE_EQUAL => .eq,
        .EXPRESSION_TYPE_COMPARE_LESSTHAN => .lt,
        .EXPRESSION_TYPE_COMPARE_LESSTHANOREQUALTO => .le,
        .EXPRESSION_TYPE_COMPARE_GREATERTHAN => .gt,
        .EXPRESSION_TYPE_COMPARE_GREATERTHANOREQUALTO => .ge,
        else => null,
    };
}

fn typeOf(e: v2.duckdb_v2_expression_handle, err: Err) ?v2.DUCKDB_V2_EXPRESSION_TYPE {
    var t: v2.DUCKDB_V2_EXPRESSION_TYPE = undefined;
    if (v2.duckdb_v2_expression_get_type(e, &t, err) != .ERROR_NONE) return null;
    return t;
}

/// What a predicate says about the rows, if it is one this function can answer exactly: the declared column and the
/// comparison, with the constant.
const Recognized = struct { column: u64, op: Op, constant: i64 };

/// Recognizes `value|bucket <op> BIGINT constant`. Null means "not mine": the engine applies the predicate. A
/// failing call is also "not mine": the scan stays correct, only slower. `err` is a scratch slot: these failures are not
/// the query's.
fn recognize(info: v2.duckdb_v2_table_function_filter_pushdown_info_handle, filter: v2.duckdb_v2_expression_handle, scratch: Err) ?Recognized {
    const op = opOf(typeOf(filter, scratch) orelse return null) orelse return null;
    var count: u64 = 0;
    if (v2.duckdb_v2_expression_get_child_count(filter, &count, scratch) != .ERROR_NONE or count != 2) return null;
    var left: v2.duckdb_v2_expression_handle = undefined;
    var right: v2.duckdb_v2_expression_handle = undefined;
    if (v2.duckdb_v2_expression_get_child(filter, 0, &left, scratch) != .ERROR_NONE) return null;
    if (v2.duckdb_v2_expression_get_child(filter, 1, &right, scratch) != .ERROR_NONE) return null;

    // The column on the left, the constant on the right. (A constant on the left never arrives: the optimizer turns
    // `90 < value` into `value > 90` before the callback sees it, which the tests check.)
    if ((typeOf(left, scratch) orelse return null) != .EXPRESSION_TYPE_BOUND_COLUMN_REF) return null;
    if ((typeOf(right, scratch) orelse return null) != .EXPRESSION_TYPE_VALUE_CONSTANT) return null;
    const column_side = left;
    const constant_side = right;

    // The index in the expression is among the columns the query reads; this maps it to the declared one.
    var referenced: u64 = 0;
    if (v2.duckdb_v2_expression_column_ref_get_index(column_side, &referenced, scratch) != .ERROR_NONE) return null;
    var declared: u64 = 0;
    if (v2.duckdb_v2_table_function_filter_pushdown_get_column_index(info, referenced, &declared, scratch) != .ERROR_NONE) return null;
    if (declared > 1) return null; // `square` is not answered

    var constant: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_expression_constant_get_value(constant_side, &constant, scratch) != .ERROR_NONE) return null;
    defer _ = v2.duckdb_v2_value_destroy(&constant);
    var is_null = false;
    if (v2.duckdb_v2_value_is_null(constant, &is_null, scratch) != .ERROR_NONE or is_null) return null;
    var c: i64 = 0;
    if (v2.duckdb_v2_value_get_bigint(constant, &c, scratch) != .ERROR_NONE) return null;
    return .{ .column = declared, .op = op, .constant = c };
}

/// Narrows `lo .. hi` (values) by `column op c`. A bucket is a block of `block_rows` values, so a bucket bound is a value
/// bound. Saturating arithmetic keeps the bounds of `i64` from wrapping.
fn narrow(data: *BindData, r: Recognized) void {
    const scale: i64 = if (r.column == 1) @intCast(block_rows) else 1;
    const c = r.constant;
    const from = c *| scale; // the first value of the constant, or of its bucket
    const past = (c +| 1) *| scale; // the first value after it
    switch (r.op) {
        .eq => {
            data.lo = @max(data.lo, from);
            data.hi = @min(data.hi, past);
        },
        .lt => data.hi = @min(data.hi, from),
        .le => data.hi = @min(data.hi, past),
        .gt => data.lo = @max(data.lo, past),
        .ge => data.lo = @max(data.lo, from),
    }
    if (data.hi < data.lo) data.hi = data.lo;
}

fn filterPushdown(
    info: v2.duckdb_v2_table_function_filter_pushdown_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_filter_pushdown_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `bind` stored a `*BindData`.
    const data: *BindData = @ptrCast(@alignCast(bind_ptr.?));

    var count: u64 = 0;
    if (v2.duckdb_v2_table_function_filter_pushdown_get_filter_count(info, &count, err) != .ERROR_NONE) return;
    _ = stats.filters_offered.fetchAdd(@intCast(count), .monotonic);
    for (0..count) |i| {
        var filter: v2.duckdb_v2_expression_handle = undefined;
        if (v2.duckdb_v2_table_function_filter_pushdown_get_filter(info, i, &filter, err) != .ERROR_NONE) return;
        // A call that fails while looking at a predicate means "not recognized", not "fail the query": it gets a slot of its
        // own, which starts from nothing.
        var scratch_slot: ?v2.duckdb_v2_error_info_handle = null;
        const scratch: Err = @ptrCast(&scratch_slot);
        defer if (scratch_slot) |*e| {
            _ = v2.duckdb_v2_error_info_destroy(e);
        };
        const r = recognize(info, filter, scratch) orelse continue;
        narrow(data, r);
        // From here on the scan applies it: the engine does not.
        if (v2.duckdb_v2_table_function_filter_pushdown_accept(info, i, err) != .ERROR_NONE) return;
        _ = stats.filters_accepted.fetchAdd(1, .monotonic);
    }
}

// --- scan -----------------------------------------------------------------------------------------------------------------

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
    if (v2.duckdb_v2_table_function_init_global_set_max_threads(info, max_threads, err) != .ERROR_NONE) return;

    // Which declared columns the query asked for: the vectors of every exec's chunk, in this order.
    var count: u64 = 0;
    if (v2.duckdb_v2_table_function_init_global_get_column_count(info, &count, err) != .ERROR_NONE) return;
    var mask: i64 = 0;
    for (0..count) |i| {
        var declared: u64 = 0;
        if (v2.duckdb_v2_table_function_init_global_get_column_index(info, i, &declared, err) != .ERROR_NONE) return;
        mask |= @as(i64, 1) << @intCast(declared);
    }
    stats.columns_mask.store(mask, .monotonic);

    const state = gpa.create(GlobalState) catch return oom(err);
    const first: u64 = @intCast(bound.lo);
    state.* = .{
        .next_block = .init(first / block_rows),
        .end_block = if (bound.hi <= bound.lo) first / block_rows else (@as(u64, @intCast(bound.hi)) + block_rows - 1) / block_rows,
    };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
    if (v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyGlobalState(state);
}

fn initLocal(
    info: v2.duckdb_v2_table_function_init_local_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    const local = gpa.create(LocalState) catch return oom(err);
    local.* = .{};
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
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &global_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_local_state(info, &local_ptr, err) != .ERROR_NONE) return;
    // SAFETY: the types stored by `bind`, `initGlobal` and `initLocal`.
    const bound: *const BindData = @ptrCast(@alignCast(bind_ptr.?));
    const global: *GlobalState = @ptrCast(@alignCast(global_ptr.?));
    const local: *LocalState = @ptrCast(@alignCast(local_ptr.?));

    // The next block of `lo .. hi`. Past the last, no rows: this thread's scan ends.
    const block = global.next_block.fetchAdd(1, .monotonic);
    local.block = block;
    var start: u64 = 0;
    var rows: u64 = 0;
    if (block < global.end_block) {
        start = @max(block * block_rows, @as(u64, @intCast(bound.lo)));
        const stop = @min((block + 1) * block_rows, @as(u64, @intCast(bound.hi)));
        rows = if (stop > start) stop - start else 0;
    }
    _ = stats.rows_produced.fetchAdd(@intCast(rows), .monotonic);

    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
    // One vector per column the query uses, in the order `exec_get_column_index` gives.
    var count: u64 = 0;
    if (v2.duckdb_v2_table_function_exec_get_column_count(info, &count, err) != .ERROR_NONE) return;
    for (0..count) |i| {
        var declared: u64 = 0;
        if (v2.duckdb_v2_table_function_exec_get_column_index(info, i, &declared, err) != .ERROR_NONE) return;
        var vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, i, &vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(vec, rows, err) != .ERROR_NONE) return;
        var data: ?*anyopaque = null;
        if (v2.duckdb_v2_vector_get_data_mutable(vec, &data, err) != .ERROR_NONE) return;
        const out: [*]i64 = @ptrCast(@alignCast(data orelse return));
        for (0..rows) |r| {
            const value: i64 = @intCast(start + r);
            out[r] = switch (declared) {
                0 => value,
                1 => @intCast(block),
                else => value *% value, // only computed when `square` is asked for
            };
        }
    }
}

// --- partitioning ----------------------------------------------------------------------------------------------------------

/// For a candidate `GROUP BY` column set: is there exactly one value of it in every partition (batch) the scan produces?
/// `bucket` alone, yes. It runs while the query is planned, on the planning thread, and must give the same answer for the
/// same set: the plan may be thrown away and asked again.
fn partitioning(
    info: v2.duckdb_v2_table_function_partitioning_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var count: u64 = 0;
    if (v2.duckdb_v2_table_function_partitioning_get_partition_column_count(info, &count, err) != .ERROR_NONE) return;
    var only_bucket = count > 0;
    for (0..count) |i| {
        var declared: u64 = 0;
        if (v2.duckdb_v2_table_function_partitioning_get_partition_column_index(info, i, &declared, err) != .ERROR_NONE) return;
        if (declared != 1) only_bucket = false;
    }
    const answer: v2.DUCKDB_V2_TABLE_PARTITION_INFO = if (only_bucket) .TABLE_PARTITION_INFO_SINGLE_VALUE_PARTITIONS else .TABLE_PARTITION_INFO_NOT_PARTITIONED;
    _ = v2.duckdb_v2_table_function_partitioning_set_partition_info(info, answer, err);
}

/// After each exec, on the thread that ran it: the batch index, and the bucket if the engine wants partition values.
fn partitionData(
    info: v2.duckdb_v2_table_function_partition_data_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    var local_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_partition_data_get_local_state(info, &local_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `initLocal` stored a `*LocalState`.
    const local: *const LocalState = @ptrCast(@alignCast(local_ptr.?));
    // Required on every call, whether or not anything needs it. The block is unique across threads and does not
    // decrease along a thread's batches; it changes whenever the bucket does (they are the same number).
    if (v2.duckdb_v2_table_function_partition_data_set_batch_index(info, local.block, err) != .ERROR_NONE) return;
    _ = stats.batches.fetchAdd(1, .monotonic);

    var required = false;
    if (v2.duckdb_v2_table_function_partition_data_requires_partition_columns(info, &required, err) != .ERROR_NONE) return;
    if (!required) return;
    var count: u64 = 0;
    if (v2.duckdb_v2_table_function_partition_data_get_partition_column_count(info, &count, err) != .ERROR_NONE) return;
    const factory = helpers.factory(context, err) orelse return;
    for (0..count) |i| {
        var declared: u64 = 0;
        if (v2.duckdb_v2_table_function_partition_data_get_partition_column_index(info, i, &declared, err) != .ERROR_NONE) return;
        // `partitioning` claimed single values for `bucket` only, so nothing else is asked for.
        if (declared != 1) return fail(err, .ERROR_INPUT_INVALID, "zig_cookbook_range: partition values asked for column {d}", .{declared});
        var value: v2.duckdb_v2_value_handle = undefined;
        if (v2.duckdb_v2_value_create_bigint(factory, @intCast(local.block), &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_table_function_partition_data_set_partition_value(info, i, value, err) != .ERROR_NONE) return;
        _ = stats.partition_values.fetchAdd(1, .monotonic);
    }
}

fn registerRange(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);
    const name = helpers.str("zig_cookbook_range");
    if (v2.duckdb_v2_table_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;

    var bigint: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const n_name = helpers.str("n");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &n_name, bigint, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

    var docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_table_function_get_docs(function, &docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(docs, .{
        .description = "The integers 0 to n-1 as value, with bucket (value // 1000) and square. Takes filters on value and bucket, and the columns a query uses, and partitions by bucket.",
        .examples = &.{
            .{ .sql = "SELECT * FROM zig_cookbook_range(5);" },
            .{ .title = "Only the rows of one bucket are produced", .sql = "SELECT count(*) FROM zig_cookbook_range(1000000) WHERE bucket = 7;" },
        },
        .categories = &.{"numeric"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_table_function_set_bind_callback(function, &bind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &initGlobal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_init_local_callback(function, &initLocal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_projection_pushdown(function, true, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_filter_pushdown_callback(function, &filterPushdown, err) != .ERROR_NONE) return error.FailedToSetCallback;
    // The two partitioning callbacks come together: registration fails with only the first.
    if (v2.duckdb_v2_table_function_set_partition_data_callback(function, &partitionData, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_partitioning_callback(function, &partitioning, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

// --- zig_cookbook_range_stats(reset := false) ----------------------------------------------------------------------------------

const stats_columns = [_][]const u8{ "filters_offered", "filters_accepted", "rows_produced", "columns_mask", "batches", "partition_values" };

const StatsBind = struct { values: [stats_columns.len]i64, done: bool = false };

fn destroyStatsBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `statsBind` stored a `*StatsBind`.
    gpa.destroy(@as(*StatsBind, @ptrCast(@alignCast(ptr))));
}

/// Read at bind: the numbers are those of the scans that ran before this statement. `reset := true` zeroes them after.
fn statsBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    var reset_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, 0, &reset_value, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_value_destroy(&reset_value);
    var reset = false;
    if (v2.duckdb_v2_value_get_bool(reset_value, &reset, err) != .ERROR_NONE) return;

    var bigint: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_BIGINT, &bigint, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint);
    inline for (stats_columns) |column| {
        const name = helpers.str(column);
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &name, bigint, err) != .ERROR_NONE) return;
    }

    const data = gpa.create(StatsBind) catch return oom(err);
    const fields = [_]*std.atomic.Value(i64){ &stats.filters_offered, &stats.filters_accepted, &stats.rows_produced, &stats.columns_mask, &stats.batches, &stats.partition_values };
    for (fields, 0..) |field, i| data.values[i] = if (reset) field.swap(0, .monotonic) else field.load(.monotonic);
    data.done = false;
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyStatsBind, .equals = null };
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) destroyStatsBind(data);
}

fn statsExec(
    info: v2.duckdb_v2_table_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `statsBind` stored a `*StatsBind`.
    const data: *StatsBind = @ptrCast(@alignCast(bind_ptr.?));
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
    const rows: u64 = if (data.done) 0 else 1;
    data.done = true;
    for (0..stats_columns.len) |c| {
        var vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(vec, rows, err) != .ERROR_NONE) return;
        if (rows == 0) continue;
        var out: ?*anyopaque = null;
        if (v2.duckdb_v2_vector_get_data_mutable(vec, &out, err) != .ERROR_NONE) return;
        @as([*]i64, @ptrCast(@alignCast(out orelse return)))[0] = data.values[c];
    }
}

fn registerStats(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);
    const name = helpers.str("zig_cookbook_range_stats");
    if (v2.duckdb_v2_table_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;

    var boolean: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BOOLEAN, &boolean, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&boolean);
    var default: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_bool(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, false, &default, err) != .ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = v2.duckdb_v2_value_destroy(&default);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const reset_name = helpers.str("reset");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &reset_name, boolean, default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

    var docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_table_function_get_docs(function, &docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(docs, .{
        .description = "What the scans of zig_cookbook_range did since the last reset: filters offered and accepted, rows produced, the columns asked for (1 value, 2 bucket, 4 square), batches and partition values reported.",
        .examples = &.{.{ .sql = "SELECT * FROM zig_cookbook_range_stats(reset := true);" }},
        .categories = &.{"debug"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_table_function_set_bind_callback(function, &statsBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &statsExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the two functions. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerRange(input, err);
    try registerStats(input, err);
}
