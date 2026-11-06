///! Table function: zig_v2_read_matrix_opfs(path VARCHAR) -> (row_index BIGINT, value DOUBLE)
///!
///! Prototype only (not wired into the real extension build steps). The real goal this chases:
///! get a whole matrix into the extension without paying the SQL-literal/LIST-argument cost
///! found in docs/rationale/0008_wasm-emscripten-side-module.md's OPFS entry (~1.1s at 131,072
///! elements, dwarfing the matmul compute itself). This reads the bytes through DuckDB's own
///! VFS — `opfs://`, a `registerFileBuffer`-registered name, HTTP, local disk, whatever the
///! path resolves to — the same way `read_opfs_head_v2.zig` does, then decodes them as a
///! single-column `data: DOUBLE` Arrow IPC stream with `zarrow` (the same schema
///! `matrix_ipc_roundtrip.zig` proved round-trips a 64x2048 matrix in ~4ms, 275x cheaper than
///! the SQL-literal path for the identical size). Emits one row per matrix element,
///! vectorized in chunks of up to 2048 rows across repeated `exec` calls — `row_index` is the
///! flat, row-major index into the original matrix; shape (m, k, n) travels separately as
///! plain scalar arguments to whatever consumes this, same as the existing SQL-argument shape.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const zarrow = @import("zarrow");

const max_rows_per_chunk = 2048;

const BindData = struct {
    values: []f64,
};

fn destroyBindData(ptr: *anyopaque) callconv(.c) void {
    const data: *BindData = @ptrCast(@alignCast(ptr));
    std.heap.c_allocator.free(data.values);
    std.heap.c_allocator.destroy(data);
}

const GlobalState = struct {
    pos: usize,
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
    const len: usize = @intCast(out.len);
    return std.heap.c_allocator.dupe(u8, ptr[0..len]);
}

/// Reads the whole file at `path` through the context's own DuckDB-managed file system.
fn readFileBytes(
    context: v2.duckdb_v2_context_handle,
    path: []const u8,
    err: *v2.duckdb_v2_error_info_handle,
) ![]u8 {
    var fs: v2.duckdb_v2_file_system_handle = undefined;
    if (v2.duckdb_v2_context_get_file_system(context, &fs, err) != .ERROR_NONE) return error.NoFileSystem;

    var options: v2.duckdb_v2_file_open_options_handle = undefined;
    if (v2.duckdb_v2_file_open_options_create(fs, &options, err) != .ERROR_NONE) return error.FailedToCreateOptions;
    defer _ = v2.duckdb_v2_file_open_options_destroy(&options);
    if (v2.duckdb_v2_file_open_options_set_flag(options, .FILE_FLAG_READ, err) != .ERROR_NONE) return error.FailedToSetFlag;

    const path_str = helpers.str(path);
    var file: v2.duckdb_v2_file_handle = undefined;
    if (v2.duckdb_v2_file_system_open(fs, &path_str, options, &file, err) != .ERROR_NONE) return error.FailedToOpenFile;
    defer {
        _ = v2.duckdb_v2_file_close(file, null);
        _ = v2.duckdb_v2_file_destroy(&file);
    }

    var size: u64 = undefined;
    if (v2.duckdb_v2_file_size(file, &size, err) != .ERROR_NONE) return error.FailedToGetSize;

    const buf = try std.heap.c_allocator.alloc(u8, @intCast(size));
    errdefer std.heap.c_allocator.free(buf);

    var total_read: usize = 0;
    while (total_read < buf.len) {
        var bytes_read: u64 = 0;
        if (v2.duckdb_v2_file_read(file, buf.ptr + total_read, buf.len - total_read, &bytes_read, err) != .ERROR_NONE) {
            return error.FailedToReadFile;
        }
        if (bytes_read == 0) break; // short file; leave the rest as read
        total_read += @intCast(bytes_read);
    }
    return buf;
}

/// Decodes an Arrow IPC stream holding a single `data: DOUBLE` column (one or more record
/// batches, concatenated) into one flat, owned `[]f64`.
fn decodeMatrix(bytes: []const u8) ![]f64 {
    var stream = std.Io.Reader.fixed(bytes);
    var reader = zarrow.IpcStreamReader(@TypeOf(&stream)).init(std.heap.c_allocator, &stream);
    defer reader.deinit();

    _ = try reader.readSchema();

    var values: std.ArrayList(f64) = .empty;
    errdefer values.deinit(std.heap.c_allocator);

    while (try reader.nextRecordBatch()) |*rb| {
        var batch = rb.*;
        defer batch.deinit();
        const col = zarrow.Float64Array{ .data = batch.columns[0].data() };
        try values.ensureUnusedCapacity(std.heap.c_allocator, col.len());
        for (0..col.len()) |i| {
            values.appendAssumeCapacity(try col.value(i));
        }
    }
    return values.toOwnedSlice(std.heap.c_allocator);
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
    var double_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_DOUBLE, &double_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&double_type);

    const row_index_col = helpers.str("row_index");
    if (v2.duckdb_v2_table_function_bind_add_result_column(result, &row_index_col, bigint_type, err) != .ERROR_NONE) return;
    const value_col = helpers.str("value");
    if (v2.duckdb_v2_table_function_bind_add_result_column(result, &value_col, double_type, err) != .ERROR_NONE) return;

    const path = copyArgString(info, 0, err) catch return;
    defer std.heap.c_allocator.free(path);

    const bytes = readFileBytes(context, path, err) catch return;
    defer std.heap.c_allocator.free(bytes);

    const values = decodeMatrix(bytes) catch return;

    if (v2.duckdb_v2_table_function_bind_set_cardinality(result, values.len, true, err) != .ERROR_NONE) {
        std.heap.c_allocator.free(values);
        return;
    }

    const data = std.heap.c_allocator.create(BindData) catch {
        std.heap.c_allocator.free(values);
        return;
    };
    data.* = .{ .values = values };
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
    state.* = .{ .pos = 0 };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
    _ = v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err);
}

fn exec(
    info: v2.duckdb_v2_table_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    _ = context;
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
    var row_index_vec: v2.duckdb_v2_vector_handle = undefined;
    var value_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_data_chunk_get_vector(chunk, 0, &row_index_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_data_chunk_get_vector(chunk, 1, &value_vec, err) != .ERROR_NONE) return;

    const remaining = bind_data.values.len - state.pos;
    const emit = @min(remaining, max_rows_per_chunk);

    if (v2.duckdb_v2_vector_set_size(row_index_vec, emit, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(value_vec, emit, err) != .ERROR_NONE) return;
    if (emit == 0) return;

    var row_index_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(row_index_vec, &row_index_data, err) != .ERROR_NONE) return;
    // SAFETY: the first result column was declared BIGINT in `bind`.
    const row_index_out: [*]i64 = @ptrCast(@alignCast(row_index_data.?));

    var value_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(value_vec, &value_data, err) != .ERROR_NONE) return;
    // SAFETY: the second result column was declared DOUBLE in `bind`.
    const value_out: [*]f64 = @ptrCast(@alignCast(value_data.?));

    for (0..emit) |i| {
        row_index_out[i] = @intCast(state.pos + i);
        value_out[i] = bind_data.values[state.pos + i];
    }
    state.pos += emit;
}

/// Register the zig_v2_read_matrix_opfs table function against the v2 extension being loaded.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;

    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_table_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_read_matrix_opfs");
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
    const path_name = helpers.str("path");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &path_name, varchar_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
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

    var docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_table_function_get_docs(function, &docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(docs, .{
        .description = "Prototype: reads a single-column `data: DOUBLE` Arrow IPC stream through DuckDB's own virtual file system (opfs://, registered buffers, HTTP, local disk, ...) and emits one row per value, in original order.",
        .examples = &.{
            .{ .sql = "SELECT * FROM zig_v2_read_matrix_opfs('opfs://matrix.arrow');" },
        },
        .categories = &.{"table"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}
