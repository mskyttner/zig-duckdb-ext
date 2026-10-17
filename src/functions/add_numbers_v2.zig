///! Scalar function: zig_add_numbers(a BIGINT, b BIGINT) -> BIGINT
///!
///! v2 port of add_numbers.zig (hand-written, not the comptime framework — see
///! ct_add_numbers_v2.zig for that style), adapted to v2's error-returning calling convention and
///! extension-based registration, and written against the generated bindings
///! (`duckdb_v2_dynamic`, see tools/gen_v2_bindings.zig) like hello_v2.zig.
///! Adds two 64-bit integers. Propagates NULL if either input is NULL. A sum that does not fit is an
///! error of the query ("Overflow in addition of INT64 (a + b)!", as for DuckDB's own `+`), not a
///! trap that would take the whole process down.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

/// Reports `a + b` overflowing as the error of the query running the callback.
fn reportOverflow(err: *v2.duckdb_v2_error_info_handle, a: i64, b: i64) void {
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Overflow in addition of INT64 ({d} + {d})!", .{ a, b }) catch
        "Overflow in addition of INT64!";
    const text: v2.duckdb_v2_str = .{ .ptr = msg.ptr, .len = msg.len };
    // There is nowhere to report a failure to report: DuckDB fails the query either way.
    _ = v2.duckdb_v2_error_info_set_code(err.*, .ERROR_INPUT_OUT_OF_RANGE);
    _ = v2.duckdb_v2_error_info_set_text(err.*, &text);
}

fn exec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    _ = context;
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var a_vec: v2.duckdb_v2_vector_handle = undefined;
    var b_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_arg(info, 0, &a_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_scalar_function_exec_get_arg(info, 1, &b_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(a_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(b_vec, err) != .ERROR_NONE) return;

    var a_view: v2.duckdb_v2_vector_view = undefined;
    var b_view: v2.duckdb_v2_vector_view = undefined;
    if (v2.duckdb_v2_vector_get_view(a_vec, &a_view, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_get_view(b_vec, &b_view, err) != .ERROR_NONE) return;

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
    // SAFETY: the signature registered this function as (BIGINT, BIGINT) -> BIGINT, so the data of
    // each flattened vector is an array of i64.
    const a_data: [*]const i64 = @ptrCast(@alignCast(a_view.data orelse return));
    const b_data: [*]const i64 = @ptrCast(@alignCast(b_view.data orelse return));
    const result: [*]i64 = @ptrCast(@alignCast(out_data));

    if (a_view.validity != null or b_view.validity != null) {
        var row: u64 = 0;
        while (row < row_count) : (row += 1) {
            if (helpers.isValid(a_view.validity, row) and helpers.isValid(b_view.validity, row)) {
                const sum, const overflowed = @addWithOverflow(a_data[row], b_data[row]);
                if (overflowed != 0) return reportOverflow(err, a_data[row], b_data[row]);
                result[row] = sum;
            } else {
                if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            }
        }
    } else {
        var row: u64 = 0;
        while (row < row_count) : (row += 1) {
            const sum, const overflowed = @addWithOverflow(a_data[row], b_data[row]);
            if (overflowed != 0) return reportOverflow(err, a_data[row], b_data[row]);
            result[row] = sum;
        }
    }
}

/// Register the zig_add_numbers scalar function against the v2 extension being loaded. A failure
/// leaves DuckDB's error info in the entrypoint's error slot, so the load reports why.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err;

    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name: v2.duckdb_v2_str = .{ .ptr = "zig_add_numbers", .len = "zig_add_numbers".len };
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) {
        return error.FailedToSetName;
    }

    var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (v2.duckdb_v2_context_create_type_from_id(input.context, .LOGICAL_TYPE_ID_BIGINT, null, null, 0, &bigint_type, err) != .ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const a_name: v2.duckdb_v2_str = .{ .ptr = "a", .len = 1 };
    const b_name: v2.duckdb_v2_str = .{ .ptr = "b", .len = 1 };
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &a_name, bigint_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &b_name, bigint_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }
    if (v2.duckdb_v2_function_signature_set_return_type(sig, bigint_type, err) != .ERROR_NONE) {
        return error.FailedToSetReturnType;
    }

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) {
        return error.FailedToSetExecCallback;
    }

    if (v2.duckdb_v2_scalar_function_register(function, err) != .ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}
