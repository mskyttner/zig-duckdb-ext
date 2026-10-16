///! One zero-argument scalar function, `gen_hello()`, written against the generated v2 bindings.
///!
///! It imports them as `duckdb_v2_api`, a name `build.zig` binds to either backend: the static
///! (direct-link) `duckdb_v2_static` or the dynamic (`get_api`) `duckdb_v2_dynamic`. Both use the C
///! names, so this one source builds against either: `v2-static-embed-poc-gen` links it statically
///! and `v2-gen-poc` loads it through `get_api` into the real CLI.
const v2 = @import("duckdb_v2_api");

/// What `gen_hello()` returns.
pub const message = "Hello, generated bindings!";

fn exec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: ?*v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    const str: v2.duckdb_v2_str = .{ .ptr = message.ptr, .len = message.len };

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        var value: v2.duckdb_v2_value_handle = undefined;
        if (v2.duckdb_v2_value_create_varchar_with_context(context, &str, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

/// Registers `gen_hello()` on the extension being loaded. Errors are reported through `err`, as the
/// C API does; there is nothing else to do with them here.
pub fn register(
    extension: v2.duckdb_v2_extension_handle,
    context: v2.duckdb_v2_context_handle,
    err: ?*v2.duckdb_v2_error_info_handle,
) void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create_with_extension(extension, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const name: v2.duckdb_v2_str = .{ .ptr = "gen_hello", .len = "gen_hello".len };
    if (v2.duckdb_v2_scalar_function_set_name(function, &name, err) != .ERROR_NONE) return;

    var signature: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &signature, err) != .ERROR_NONE) return;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (v2.duckdb_v2_context_create_type_from_id(context, .LOGICAL_TYPE_ID_VARCHAR, null, null, 0, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);
    if (v2.duckdb_v2_function_signature_set_return_type(signature, varchar_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) return;
    _ = v2.duckdb_v2_scalar_function_register(function, err);
}
