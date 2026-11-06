///! Table function: zig_v2_read_opfs_head(path VARCHAR) -> (byte_count BIGINT, first_f64 DOUBLE)
///!
///! Prototype only (not wired into the real extension build steps) proving that a v2 table
///! function can read bytes through DuckDB's own virtual file system — the same VFS
///! duckdb-wasm routes `opfs://`, `registerFileBuffer`-registered names, and HTTP/S3 paths
///! through — rather than through SQL argument marshaling. The bind callback already receives
///! a `duckdb_v2_context_handle`; `duckdb_v2_context_get_file_system` borrows that context's
///! file system directly, with no separate "get client context" step needed.
///!
///! See docs/rationale/0008_wasm-emscripten-side-module.md's OPFS entry for why this matters:
///! the SQL-literal/LIST-argument path for a large matrix costs roughly 1.1s at 131,072
///! elements, dwarfing the matmul compute itself. Reading the same bytes through this VFS path
///! instead sidesteps SQL parsing and LIST construction entirely.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const BindData = struct {
    byte_count: i64,
    first_f64: f64,
};

fn destroyBindData(ptr: *anyopaque) callconv(.c) void {
    const data: *BindData = @ptrCast(@alignCast(ptr));
    std.heap.c_allocator.destroy(data);
}

const GlobalState = struct {
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
    const len: usize = @intCast(out.len);
    return std.heap.c_allocator.dupe(u8, ptr[0..len]);
}

fn readHead(
    context: v2.duckdb_v2_context_handle,
    path: []const u8,
    err: *v2.duckdb_v2_error_info_handle,
) !BindData {
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

    var head: [8]u8 = @splat(0);
    var bytes_read: u64 = 0;
    const want: u64 = @min(size, 8);
    if (want > 0) {
        if (v2.duckdb_v2_file_read(file, &head, want, &bytes_read, err) != .ERROR_NONE) return error.FailedToReadFile;
    }

    const first_f64: f64 = if (bytes_read >= 8) @bitCast(head) else 0;
    return .{ .byte_count = @intCast(size), .first_f64 = first_f64 };
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

    const byte_count_col = helpers.str("byte_count");
    if (v2.duckdb_v2_table_function_bind_add_result_column(result, &byte_count_col, bigint_type, err) != .ERROR_NONE) return;
    const first_f64_col = helpers.str("first_f64");
    if (v2.duckdb_v2_table_function_bind_add_result_column(result, &first_f64_col, double_type, err) != .ERROR_NONE) return;

    const path = copyArgString(info, 0, err) catch return;
    defer std.heap.c_allocator.free(path);

    const head = readHead(context, path, err) catch return;

    const data = std.heap.c_allocator.create(BindData) catch return;
    data.* = head;
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
    state.* = .{ .done = false };
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
    var byte_count_vec: v2.duckdb_v2_vector_handle = undefined;
    var first_f64_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_data_chunk_get_vector(chunk, 0, &byte_count_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_data_chunk_get_vector(chunk, 1, &first_f64_vec, err) != .ERROR_NONE) return;

    if (state.done) {
        if (v2.duckdb_v2_vector_set_size(byte_count_vec, 0, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(first_f64_vec, 0, err) != .ERROR_NONE) return;
        return;
    }
    state.done = true;

    if (v2.duckdb_v2_vector_set_size(byte_count_vec, 1, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(first_f64_vec, 1, err) != .ERROR_NONE) return;

    var byte_count_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(byte_count_vec, &byte_count_data, err) != .ERROR_NONE) return;
    // SAFETY: the first result column was declared BIGINT in `bind`.
    const byte_count_out: [*]i64 = @ptrCast(@alignCast(byte_count_data.?));
    byte_count_out[0] = bind_data.byte_count;

    var first_f64_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(first_f64_vec, &first_f64_data, err) != .ERROR_NONE) return;
    // SAFETY: the second result column was declared DOUBLE in `bind`.
    const first_f64_out: [*]f64 = @ptrCast(@alignCast(first_f64_data.?));
    first_f64_out[0] = bind_data.first_f64;
}

/// Register the zig_v2_read_opfs_head table function against the v2 extension being loaded.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;

    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_table_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_read_opfs_head");
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
        .description = "Prototype: reads a file through DuckDB's own virtual file system (opfs://, registered buffers, HTTP, local disk, ...) and reports its size and first 8 bytes as a double.",
        .examples = &.{
            .{ .sql = "SELECT * FROM zig_v2_read_opfs_head('opfs://matrix.bin');" },
        },
        .categories = &.{"table"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}
