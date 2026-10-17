///! Scalar function: tp_bar(value DOUBLE, on VARCHAR := '█', off VARCHAR := '░', width BIGINT := 15) -> VARCHAR
///!
///! v2 port of tp_bar.zig. v1 can't express named parameters or defaults
///! on a scalar function at all — tp_bar.zig works around this by
///! registering a plain `tp_bar_impl` function plus a `CREATE OR REPLACE
///! MACRO tp_bar(...)` wrapper providing the named/defaulted call surface.
///! v2 has real named parameters and per-parameter defaults
///! (`functionSignatureAddParameter`'s `default_value`), so this port
///! registers a single `tp_bar` function directly — no macro, no `_impl`
///! split, no `db.query()` string execution at init time.
///!
///! Written against the generated bindings (`duckdb_v2_dynamic`), like hello_v2.zig.
///!
///! Reuses `buildBar` from tp_bar.zig unchanged: it's pure Zig (allocator +
///! slices in, slice out), with no DuckDB API dependency either version
///! needs to duplicate.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const buildBar = @import("tp_bar.zig").buildBar;

fn exec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var views: [4]v2.duckdb_v2_vector_view = undefined;
    inline for (0..4) |i| {
        var arg_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &arg_vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_flatten(arg_vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_get_view(arg_vec, &views[i], err) != .ERROR_NONE) return;
    }

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    // SAFETY: the signature registered these as (DOUBLE, VARCHAR, VARCHAR, BIGINT).
    const val_data: [*]const f64 = @ptrCast(@alignCast(views[0].data orelse return));
    const on_data: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views[1].data orelse return));
    const off_data: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views[2].data orelse return));
    const width_data: [*]const i64 = @ptrCast(@alignCast(views[3].data orelse return));

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (!rowIsValid(&views, row)) {
            if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            continue;
        }

        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const result = buildBar(
            fba.allocator(),
            val_data[row],
            helpers.bytesSlice(&on_data[row]),
            helpers.bytesSlice(&off_data[row]),
            width_data[row],
        ) catch "";

        var value: v2.duckdb_v2_value_handle = undefined;
        if (helpers.createVarcharValue(context, result, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

inline fn rowIsValid(views: *const [4]v2.duckdb_v2_vector_view, row: u64) bool {
    inline for (0..4) |i| {
        if (!helpers.isValid(views.*[i].validity, row)) return false;
    }
    return true;
}

/// Register the tp_bar scalar function against the v2 extension being loaded. A failure leaves
/// DuckDB's error info in the entrypoint's error slot, so the load reports why.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;

    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("tp_bar");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) {
        return error.FailedToSetName;
    }

    var double_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_DOUBLE, &double_type, err) != .ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = v2.duckdb_v2_logical_type_destroy(&double_type);
    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);
    var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != .ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const value_name = helpers.str("value");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &value_name, double_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    var on_default: v2.duckdb_v2_value_handle = undefined;
    if (helpers.createVarcharValue(input.context, "█", &on_default, err) != .ERROR_NONE) {
        return error.FailedToCreateDefault;
    }
    defer _ = v2.duckdb_v2_value_destroy(&on_default);
    const on_name = helpers.str("on");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &on_name, varchar_type, on_default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    var off_default: v2.duckdb_v2_value_handle = undefined;
    if (helpers.createVarcharValue(input.context, "░", &off_default, err) != .ERROR_NONE) {
        return error.FailedToCreateDefault;
    }
    defer _ = v2.duckdb_v2_value_destroy(&off_default);
    const off_name = helpers.str("off");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &off_name, varchar_type, off_default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    var width_default: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_bigint(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, 15, &width_default, err) != .ERROR_NONE) {
        return error.FailedToCreateDefault;
    }
    defer _ = v2.duckdb_v2_value_destroy(&width_default);
    const width_name = helpers.str("width");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &width_name, bigint_type, width_default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar_type, err) != .ERROR_NONE) {
        return error.FailedToSetReturnType;
    }

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) {
        return error.FailedToSetExecCallback;
    }

    if (v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err) != .ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}
