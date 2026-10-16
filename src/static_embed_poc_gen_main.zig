///! Link-and-run check for the generated static (direct-link) bindings in
///! `src/lib/duckdb_v2_static.zig`: registers a zero-argument scalar function through plain
///! `duckdb_v2_*` externs and calls it from SQL, against the pinned `libduckdb_static.a`.
///!
///! Same vertical slice as `static_embed_poc_direct_main.zig`, which declares its calls through a
///! translate-c of `duckdb_v2.h`; here every `duckdb_v2_*` declaration comes from the generator
///! (`tools/gen_v2_static.zig`), so the enum values, handle types and nullability it infers are
///! exercised by a real call chain rather than only compared with the header.
const std = @import("std");
const log = std.log.scoped(.static_embed_poc_gen);
const v2 = @import("duckdb_v2_static");
const duckdb_static = @import("duckdb_static");
const c = @import("duckdb_full_c");

const expected = "Hello, generated bindings!";

fn helloExec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: ?*v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    const str: v2.duckdb_v2_str = .{ .ptr = expected.ptr, .len = expected.len };

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        var value: v2.duckdb_v2_value_handle = undefined;
        if (v2.duckdb_v2_value_create_varchar_with_context(context, &str, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

fn entry(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    const err = input.err;

    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const name: v2.duckdb_v2_str = .{ .ptr = "gen_hello", .len = "gen_hello".len };
    if (v2.duckdb_v2_scalar_function_set_name(function, &name, err) != .ERROR_NONE) return;

    var signature: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &signature, err) != .ERROR_NONE) return;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (v2.duckdb_v2_context_create_type_from_id(input.context, .LOGICAL_TYPE_ID_VARCHAR, null, null, 0, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);
    if (v2.duckdb_v2_function_signature_set_return_type(signature, varchar_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &helloExec, err) != .ERROR_NONE) return;
    _ = v2.duckdb_v2_scalar_function_register(function, err);
}

fn describe(descriptor: *duckdb_static.ExtensionDescriptor) callconv(.c) i32 {
    descriptor.version = duckdb_static.descriptor_version;
    descriptor.name = "zig_ext_gen";
    descriptor.extension_version = "v0.1.0";
    descriptor.api_version = "v2.0.0";
    descriptor.entry_cpp = null;
    descriptor.entry_capi_v1 = null;
    // SAFETY: the header declares this field as a generic `void (*)(void)`; DuckDB casts it back to
    // `void (*)(duckdb_v2_extension_input *)` before calling it, which is what `entry` is.
    descriptor.entry_capi_v2 = @ptrCast(&entry);
    descriptor.database_callback = null;
    return 0;
}

pub fn main() !void {
    const registered = duckdb_static.registerStaticExtension(@ptrCast(&describe));
    log.info("duckdb_register_static_extension -> {d}", .{registered});

    var database: c.duckdb_database = null;
    if (c.duckdb_open(null, &database) != c.DuckDBSuccess) return error.OpenFailed;
    defer c.duckdb_close(&database);

    var connection: c.duckdb_connection = null;
    if (c.duckdb_connect(database, &connection) != c.DuckDBSuccess) return error.ConnectFailed;
    defer c.duckdb_disconnect(&connection);

    var result: c.duckdb_result = undefined;
    const state = c.duckdb_query(connection, "LOAD zig_ext_gen; SELECT gen_hello() AS msg;", &result);
    defer c.duckdb_destroy_result(&result);
    if (state != c.DuckDBSuccess) {
        log.err("query failed: {s}", .{c.duckdb_result_error(&result)});
        return error.QueryFailed;
    }

    const value = c.duckdb_value_varchar(&result, 0, 0);
    defer c.duckdb_free(value);
    log.info("query result: {s}", .{value});
    if (!std.mem.eql(u8, std.mem.span(value), expected)) return error.WrongResult;
}
