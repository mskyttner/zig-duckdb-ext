///! Table function: zig_tokenize(input VARCHAR, delim VARCHAR) -> (token_pos BIGINT, token VARCHAR)
///!
///! v2 port of tokenize.zig. Behavior identical (see that file's doc
///! comment for examples); the port differs in a few real ways:
///!
///!   - v1's bind reads parameter values via `duckdb_get_varchar`, which
///!     returns a DuckDB-allocated, DuckDB-owned string freed via
///!     `db.free`. v2's `function_bind_get_arg_value` + `value_get_varchar`
///!     instead BORROWS from the Value handle (valid only until the Value
///!     is destroyed, which happens before bind returns) — so this port
///!     copies the bytes into its own heap allocation instead.
///!   - v2 exposes no generic malloc/free at all (confirmed: no such
///!     function anywhere in the vtable) — bind/init state is allocated via
///!     `std.heap.c_allocator` and freed through the `Opaque{ptr, destroy,
///!     equals}` box, the same pattern `comptime_aggregate_v2.zig`'s
///!     global state uses.
///!   - v1's `init` is a true per-thread callback feeding one shared,
///!     mutable `InitData` across every `exec` call for that thread. v2's
///!     closest equivalent for a single-threaded scan is `init_global` +
///!     `exec` sharing one global state the same way — this port forces
///!     single-threaded execution by simply never supporting more than one
///!     thread's worth of state (the bind step doesn't call
///!     `init_global_set_max_threads` at all, which v2's doc comments say
///!     defaults to 1).
///!   - v1 sets the whole output chunk's row count in one
///!     `dataChunkSetSize` call. v2 has no chunk-level size setter at all
///!     (confirmed absent from the vtable) — each output VECTOR's size must
///!     be set independently, proven here for the first time with a
///!     genuinely multi-column (BIGINT + VARCHAR) table function.
///!
///! Written against the generated bindings (`duckdb_v2_dynamic`), like hello_v2.zig.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const BindData = struct {
    input: []u8,
    delim: []u8,
};

fn destroyBindData(ptr: *anyopaque) callconv(.c) void {
    const data: *BindData = @ptrCast(@alignCast(ptr));
    std.heap.c_allocator.free(data.input);
    std.heap.c_allocator.free(data.delim);
    std.heap.c_allocator.destroy(data);
}

const GlobalState = struct {
    pos: usize,
    ordinal: i64,
    done: bool,
};

fn destroyGlobalState(ptr: *anyopaque) callconv(.c) void {
    const state: *GlobalState = @ptrCast(@alignCast(ptr));
    std.heap.c_allocator.destroy(state);
}

fn copyArgString(info: v2.duckdb_v2_function_bind_info_handle, index: u64, err: *v2.duckdb_v2_error_info_handle) ![]u8 {
    var value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, index, &value, err) != .ERROR_NONE) {
        return error.FailedToGetArgValue;
    }
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var out: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_value_get_varchar(value, &out, err) != .ERROR_NONE) {
        return error.FailedToGetVarchar;
    }
    const ptr = out.ptr orelse return std.heap.c_allocator.dupe(u8, "");
    return std.heap.c_allocator.dupe(u8, ptr[0..out.len]);
}

fn bind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);
    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    const pos_col_name = helpers.str("token_pos");
    if (v2.duckdb_v2_table_function_bind_add_result_column(result, &pos_col_name, bigint_type, err) != .ERROR_NONE) return;
    const tok_col_name = helpers.str("token");
    if (v2.duckdb_v2_table_function_bind_add_result_column(result, &tok_col_name, varchar_type, err) != .ERROR_NONE) return;

    const input = copyArgString(info, 0, err) catch return;
    const delim = copyArgString(info, 1, err) catch {
        std.heap.c_allocator.free(input);
        return;
    };

    const data = std.heap.c_allocator.create(BindData) catch return;
    data.* = .{ .input = input, .delim = delim };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyBindData, .equals = null };
    _ = v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err);
}

fn initGlobal(
    info: v2.duckdb_v2_table_function_init_global_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    _ = context;
    const state = std.heap.c_allocator.create(GlobalState) catch return;
    state.* = .{ .pos = 0, .ordinal = 0, .done = false };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
    _ = v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err);
}

fn exec(
    info: v2.duckdb_v2_table_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var bind_data_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_data_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `bind` stored a `BindData` as this function's bind data.
    const bind_data: *BindData = @ptrCast(@alignCast(bind_data_ptr.?));

    var state_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `initGlobal` stored a `GlobalState` as this function's global state.
    const state: *GlobalState = @ptrCast(@alignCast(state_ptr.?));

    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
    var pos_vec: v2.duckdb_v2_vector_handle = undefined;
    var tok_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_data_chunk_get_vector(chunk, 0, &pos_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_data_chunk_get_vector(chunk, 1, &tok_vec, err) != .ERROR_NONE) return;

    if (state.done) {
        if (v2.duckdb_v2_vector_set_size(pos_vec, 0, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(tok_vec, 0, err) != .ERROR_NONE) return;
        return;
    }

    const input = bind_data.input;
    const delim = bind_data.delim;
    const max_rows = 2048;
    var tokens: [max_rows][]const u8 = undefined;
    var ordinals: [max_rows]i64 = undefined;
    var row: usize = 0;

    while (row < max_rows and !state.done) {
        const remaining = input[state.pos..];
        if (delim.len == 0) {
            tokens[row] = remaining;
            ordinals[row] = state.ordinal;
            row += 1;
            state.ordinal += 1;
            state.done = true;
        } else if (std.mem.indexOf(u8, remaining, delim)) |delim_pos| {
            tokens[row] = remaining[0..delim_pos];
            ordinals[row] = state.ordinal;
            row += 1;
            state.ordinal += 1;
            state.pos += delim_pos + delim.len;
        } else {
            tokens[row] = remaining;
            ordinals[row] = state.ordinal;
            row += 1;
            state.ordinal += 1;
            state.done = true;
        }
    }

    if (v2.duckdb_v2_vector_set_size(pos_vec, row, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(tok_vec, row, err) != .ERROR_NONE) return;

    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(pos_vec, &out_data, err) != .ERROR_NONE) return;
    // SAFETY: the first result column was declared BIGINT in `bind`.
    const pos_out: [*]i64 = @ptrCast(@alignCast(out_data.?));

    var i: usize = 0;
    while (i < row) : (i += 1) {
        pos_out[i] = ordinals[i];
        var value: v2.duckdb_v2_value_handle = undefined;
        if (helpers.createVarcharValue(context, tokens[i], &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(tok_vec, i, value, err) != .ERROR_NONE) return;
    }
}

/// Register the zig_tokenize table function against the v2 extension being loaded. A failure
/// leaves DuckDB's error info in the entrypoint's error slot, so the load reports why.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;

    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_table_function_destroy(&function);

    const fn_name = helpers.str("zig_tokenize");
    if (v2.duckdb_v2_table_function_set_name(function, &fn_name, err) != .ERROR_NONE) {
        return error.FailedToSetName;
    }

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) {
        return error.FailedToGetSignature;
    }
    const input_name = helpers.str("input");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &input_name, varchar_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }
    const delim_name = helpers.str("delim");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &delim_name, varchar_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    if (v2.duckdb_v2_table_function_set_bind_callback(function, &bind, err) != .ERROR_NONE) {
        return error.FailedToSetBindCallback;
    }
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &initGlobal, err) != .ERROR_NONE) {
        return error.FailedToSetInitGlobalCallback;
    }
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) {
        return error.FailedToSetExecCallback;
    }

    // What duckdb_functions() shows besides the signature.
    var docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_table_function_get_docs(function, &docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(docs, .{
        .description = "Splits the input at every occurrence of the delimiter, one row per token with its 0-based position. Empty tokens are kept; an empty delimiter gives the whole input as one token.",
        .examples = &.{
            .{ .sql = "SELECT * FROM zig_tokenize('a,b,c', ',');" },
            .{ .title = "A longer delimiter", .sql = "SELECT * FROM zig_tokenize('x::y::z', '::');" },
        },
        .categories = &.{"string"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}
