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
const std = @import("std");
const db = @import("duckdb_v2");

const BindData = struct {
    input: []u8,
    delim: []u8,
};

fn destroyBindData(ptr: ?*anyopaque) callconv(.c) void {
    const data: *BindData = @ptrCast(@alignCast(ptr.?));
    std.heap.c_allocator.free(data.input);
    std.heap.c_allocator.free(data.delim);
    std.heap.c_allocator.destroy(data);
}

const GlobalState = struct {
    pos: usize,
    ordinal: i64,
    done: bool,
};

fn destroyGlobalState(ptr: ?*anyopaque) callconv(.c) void {
    const state: *GlobalState = @ptrCast(@alignCast(ptr.?));
    std.heap.c_allocator.destroy(state);
}

fn copyArgString(info: db.FunctionBindInfoHandle, index: db.idx_t, err: [*c]db.ErrorInfoHandle) ![]u8 {
    var value: db.ValueHandle = undefined;
    if (db.functionBindGetArgValue(info, index, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToGetArgValue;
    }
    defer _ = db.valueDestroy(&value);
    var out: db.Str = undefined;
    if (db.valueGetVarchar(value, &out, err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToGetVarchar;
    }
    const slice: []const u8 = @as([*]const u8, @ptrCast(out.ptr))[0..out.len];
    return std.heap.c_allocator.dupe(u8, slice);
}

fn bind(info: db.FunctionBindInfoHandle, result: db.TableFunctionBindInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    var bigint_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db.logicalTypeDestroy(&bigint_type);
    var varchar_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db.logicalTypeDestroy(&varchar_type);

    const pos_col_name = db.str("token_pos");
    if (db.tableFunctionBindAddResultColumn(result, &pos_col_name, bigint_type, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    const tok_col_name = db.str("token");
    if (db.tableFunctionBindAddResultColumn(result, &tok_col_name, varchar_type, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    const input = copyArgString(info, 0, err) catch return;
    const delim = copyArgString(info, 1, err) catch {
        std.heap.c_allocator.free(input);
        return;
    };

    const data = std.heap.c_allocator.create(BindData) catch return;
    data.* = .{ .input = input, .delim = delim };
    var boxed: db.Opaque = .{ .ptr = data, .destroy = destroyBindData, .equals = null };
    _ = db.functionBindSetBindData(info, &boxed, err);
}

fn initGlobal(info: db.TableFunctionInitGlobalInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    _ = context;
    const state = std.heap.c_allocator.create(GlobalState) catch return;
    state.* = .{ .pos = 0, .ordinal = 0, .done = false };
    var boxed: db.Opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
    _ = db.tableFunctionInitGlobalSetGlobalState(info, &boxed, err);
}

fn exec(info: db.TableFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
    var bind_data_ptr: ?*anyopaque = null;
    if (db.tableFunctionExecGetBindData(info, &bind_data_ptr, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    const bind_data: *BindData = @ptrCast(@alignCast(bind_data_ptr.?));

    var state_ptr: ?*anyopaque = null;
    if (db.tableFunctionExecGetGlobalState(info, &state_ptr, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    const state: *GlobalState = @ptrCast(@alignCast(state_ptr.?));

    var chunk: db.DataChunkHandle = undefined;
    if (db.tableFunctionExecGetOutputChunk(info, &chunk, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    var pos_vec: db.VectorHandle = undefined;
    var tok_vec: db.VectorHandle = undefined;
    if (db.dataChunkGetVector(chunk, 0, &pos_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.dataChunkGetVector(chunk, 1, &tok_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    if (state.done) {
        if (db.vectorSetSize(pos_vec, 0, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        if (db.vectorSetSize(tok_vec, 0, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
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

    if (db.vectorSetSize(pos_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    if (db.vectorSetSize(tok_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

    var out_data: ?*anyopaque = null;
    if (db.vectorGetDataMutable(pos_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    const pos_out: [*]i64 = @ptrCast(@alignCast(out_data));

    var i: usize = 0;
    while (i < row) : (i += 1) {
        pos_out[i] = ordinals[i];
        var value: db.ValueHandle = undefined;
        if (db.valueCreateVarcharWithContext(context, tokens[i], &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = db.valueDestroy(&value);
        if (db.vectorSetValue(tok_vec, i, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
    }
}

/// Register the zig_tokenize table function against the v2 extension being loaded.
pub fn register(input: *const db.ExtensionInput) !void {
    var err: db.ErrorInfoHandle = undefined;

    var function: db.TableFunctionHandle = undefined;
    if (db.tableFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = db.tableFunctionDestroy(&function);

    const fn_name = db.str("zig_tokenize");
    if (db.tableFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetName;
    }

    var varchar_type: db.LogicalTypeHandle = undefined;
    if (db.contextCreateTypeFromId(input.context, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = db.logicalTypeDestroy(&varchar_type);

    var sig: db.FunctionSignatureHandle = undefined;
    if (db.tableFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToGetSignature;
    }
    const input_name = db.str("input");
    if (db.functionSignatureAddParameter(sig, &input_name, varchar_type, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }
    const delim_name = db.str("delim");
    if (db.functionSignatureAddParameter(sig, &delim_name, varchar_type, null, db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    if (db.tableFunctionSetBindCallback(function, bind, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetBindCallback;
    }
    if (db.tableFunctionSetInitGlobalCallback(function, initGlobal, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetInitGlobalCallback;
    }
    if (db.tableFunctionSetExecCallback(function, exec, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToSetExecCallback;
    }

    if (db.tableFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}

// Re-exposed so ct_tokenize_v2.zig can register the same bind/init_global/
// exec callbacks through comptime_table_v2 instead of by hand.
pub const bindForCt = bind;
pub const initGlobalForCt = initGlobal;
pub const execForCt = exec;
