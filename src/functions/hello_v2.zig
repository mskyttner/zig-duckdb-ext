///! Scalar function: zig_hello(name VARCHAR) -> VARCHAR
///!
///! v2 port of hello.zig, and the first function module written against the generated bindings
///! (`duckdb_v2_dynamic`, see tools/gen_v2_bindings.zig) rather than the hand-written
///! `duckdb_v2.zig`: C names, enums for the error codes, handle types that cannot be mixed up.
///!
///! Hand-written rather than through comptime_scalar_v2: that framework's VARCHAR-return path
///! requires `implFn` to return a slice that outlives the call (borrowed from an argument, a
///! literal, or static/heap memory) because nothing frees allocator-backed memory after boxing —
///! but this function needs to *construct* new text ("Hello, " ++ name ++ "!"), which a local stack
///! buffer can do safely only if built and boxed inline, before the exec callback returns, the same
///! way v1's hand-written hello.zig built and consumed its buffer inline. Not a gap worth closing
///! in the framework yet — most real functions either transform existing text or produce it like
///! this one does, and the two need different plumbing.
const v2 = @import("duckdb_v2_dynamic");
const helpers = @import("../lib/v2_helpers.zig");

fn exec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
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

    // SAFETY: the signature registered this function as (VARCHAR) -> VARCHAR, and a flattened
    // VARCHAR vector is an array of `duckdb_v2_bytes`.
    const in: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(view.data orelse return));

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (!helpers.isValid(view.validity, row)) {
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

        const text: v2.duckdb_v2_str = .{ .ptr = greeting.ptr, .len = greeting.len };
        var value: v2.duckdb_v2_value_handle = undefined;
        if (v2.duckdb_v2_value_create_varchar_with_context(context, &text, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

/// Register the zig_hello scalar function against the v2 extension being loaded. A failure leaves
/// DuckDB's error info in the entrypoint's error slot, so the load reports why.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err;

    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name: v2.duckdb_v2_str = .{ .ptr = "zig_hello", .len = "zig_hello".len };
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) {
        return error.FailedToSetName;
    }

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (v2.duckdb_v2_context_create_type_from_id(input.context, .LOGICAL_TYPE_ID_VARCHAR, null, null, 0, &varchar_type, err) != .ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const param_name: v2.duckdb_v2_str = .{ .ptr = "name", .len = "name".len };
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &param_name, varchar_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }
    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar_type, err) != .ERROR_NONE) {
        return error.FailedToSetReturnType;
    }

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) {
        return error.FailedToSetExecCallback;
    }

    if (v2.duckdb_v2_scalar_function_register(function, err) != .ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}
