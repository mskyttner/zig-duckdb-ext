///! Scalar function: tp_line(data DOUBLE[], height DOUBLE := 10.0) -> VARCHAR
///!
///! v2 port of tp_line.zig — first LIST support in the v2 layer. Drops the
///! SQL-macro default-param workaround the same way tp_bar_v2 did (v2 has
///! real defaults natively).
///!
///! v2 exposes LIST through the same generic "nested vector" mechanism as
///! STRUCT/MAP/UNION (`vector_get_child`/`vector_get_child_count`), unlike
///! v1's LIST-specific `listVectorGetChild`: index 0 of a flattened LIST
///! vector's child is the flat element vector, addressed per row via the
///! LIST vector's own `duckdb_v2_list_entry{offset, length}` records in its
///! `VectorView.data` — otherwise the same vector-view/validity pattern
///! every other type in this codebase already uses.
///!
///! Reuses renderLine from tp_line.zig unchanged (pure Zig, no DuckDB API
///! dependency either version needs to duplicate).
///!
///! Written against the generated bindings (`duckdb_v2_dynamic`), like hello_v2.zig.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const renderLine = @import("tp_line.zig").renderLine;

fn exec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var list_vec: v2.duckdb_v2_vector_handle = undefined;
    var height_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_arg(info, 0, &list_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_scalar_function_exec_get_arg(info, 1, &height_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(list_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(height_vec, err) != .ERROR_NONE) return;

    var list_view: v2.duckdb_v2_vector_view = undefined;
    var height_view: v2.duckdb_v2_vector_view = undefined;
    if (v2.duckdb_v2_vector_get_view(list_vec, &list_view, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_get_view(height_vec, &height_view, err) != .ERROR_NONE) return;

    var child_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_vector_get_child(list_vec, 0, &child_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(child_vec, err) != .ERROR_NONE) return;
    var child_view: v2.duckdb_v2_vector_view = undefined;
    if (v2.duckdb_v2_vector_get_view(child_vec, &child_view, err) != .ERROR_NONE) return;

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    // SAFETY: the signature registered these as (LIST(DOUBLE), DOUBLE) -> VARCHAR.
    const entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(list_view.data orelse return));
    const height_data: [*]const f64 = @ptrCast(@alignCast(height_view.data orelse return));
    const child_data: [*]const f64 = @ptrCast(@alignCast(child_view.data orelse return));

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (!helpers.isValid(list_view.validity, row) or !helpers.isValid(height_view.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            continue;
        }

        const entry = entries[row];
        if (entry.length == 0) {
            var value: v2.duckdb_v2_value_handle = undefined;
            if (helpers.createVarcharValue(context, "", &value, err) != .ERROR_NONE) return;
            defer _ = v2.duckdb_v2_value_destroy(&value);
            if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
            continue;
        }

        // The rendered string must be boxed into a Value (and the Value
        // written) while the arena backing it is still alive — consuming
        // it before arena.deinit() runs, the same way v1's writeRow copies
        // into DuckDB's own string vector before its function returns.
        // Returning the slice out of this scope first (e.g. via a block
        // expression) would use it after the arena already freed it.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const len = @min(entry.length, 255);
        const text = blk: {
            const values = allocator.alloc(f64, len) catch break :blk @as([]const u8, "");
            for (0..len) |i| {
                const ci = entry.offset + i;
                values[i] = if (helpers.isValid(child_view.validity, ci))
                    child_data[ci]
                else
                    std.math.nan(f64);
            }
            break :blk renderLine(allocator, values, height_data[row]) catch @as([]const u8, "");
        };

        var value: v2.duckdb_v2_value_handle = undefined;
        if (helpers.createVarcharValue(context, text, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

/// Register the tp_line scalar function against the v2 extension being loaded. A failure leaves
/// DuckDB's error info in the entrypoint's error slot, so the load reports why.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;

    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("tp_line");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) {
        return error.FailedToSetName;
    }

    var double_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_DOUBLE, &double_type, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&double_type);
    var list_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createListType(input.context, double_type, &list_type, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&list_type);
    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const data_name = helpers.str("data");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &data_name, list_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

    var height_default: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_double_with_context(input.context, 10.0, &height_default, err) != .ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = v2.duckdb_v2_value_destroy(&height_default);
    const height_name = helpers.str("height");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &height_name, double_type, height_default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

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
