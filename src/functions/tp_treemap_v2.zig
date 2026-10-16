///! Scalar function: tp_treemap(values DOUBLE[], labels VARCHAR[], width BIGINT := 80, height BIGINT := 24) -> VARCHAR
///!
///! v2 port of tp_treemap.zig. Drops the SQL-macro default-param workaround
///! (same as tp_bar_v2/tp_line_v2 — v2 has real defaults natively).
///! Combines LIST(DOUBLE) (proven in tp_line_v2) with LIST(VARCHAR) — same
///! vector_get_child + list_entry mechanism, decoding the child as
///! `duckdb_v2_bytes`/`bytesSlice` instead of raw f64. Reuses canvas/snake unchanged
///! (pure Zig, no DuckDB API dependency either version needs to duplicate).
///!
///! Written against the generated bindings (`duckdb_v2_dynamic`), like hello_v2.zig.
const std = @import("std");
const v2 = @import("duckdb_v2_dynamic");
const helpers = @import("v2_helpers");
const canvas_lib = @import("../lib/canvas.zig");
const snake = @import("../lib/snake.zig");

fn exec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var args: [4]v2.duckdb_v2_vector_handle = undefined;
    var views: [4]v2.duckdb_v2_vector_view = undefined;
    inline for (0..4) |i| {
        if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &args[i], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_flatten(args[i], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_get_view(args[i], &views[i], err) != .ERROR_NONE) return;
    }

    // The two list arguments' elements live in child vectors.
    var children: [2]v2.duckdb_v2_vector_handle = undefined;
    var child_views: [2]v2.duckdb_v2_vector_view = undefined;
    inline for (0..2) |i| {
        if (v2.duckdb_v2_vector_get_child(args[i], 0, &children[i], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_flatten(children[i], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_get_view(children[i], &child_views[i], err) != .ERROR_NONE) return;
    }

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    // SAFETY: the signature registered these as (LIST(DOUBLE), LIST(VARCHAR), BIGINT, BIGINT) -> VARCHAR.
    const val_entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(views[0].data orelse return));
    const lbl_entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(views[1].data orelse return));
    const width_data: [*]const i64 = @ptrCast(@alignCast(views[2].data orelse return));
    const height_data: [*]const i64 = @ptrCast(@alignCast(views[3].data orelse return));
    const val_data: [*]const f64 = @ptrCast(@alignCast(child_views[0].data orelse return));
    const lbl_data: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(child_views[1].data orelse return));

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (anyInvalid(&views, row)) {
            if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            continue;
        }
        if (!writeRow(val_entries, val_data, lbl_entries, lbl_data, width_data, height_data, row, result_vec, context, err)) return;
    }
}

fn writeRow(
    val_entries: [*]const v2.duckdb_v2_list_entry,
    val_data: [*]const f64,
    lbl_entries: [*]const v2.duckdb_v2_list_entry,
    lbl_data: [*]const v2.duckdb_v2_bytes,
    width_data: [*]const i64,
    height_data: [*]const i64,
    row: u64,
    result_vec: v2.duckdb_v2_vector_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) bool {
    const w_raw = width_data[row];
    const h_raw = height_data[row];
    const ve = val_entries[row];
    if (w_raw <= 0 or h_raw <= 0 or ve.length == 0) return writeText(result_vec, row, context, "", err);

    const cw: usize = @intCast(@min(w_raw, 512));
    const ch: usize = @intCast(@min(h_raw, 256));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const n = ve.length;
    const labels_buf = allocator.alloc([]const u8, n) catch return writeText(result_vec, row, context, "", err);
    const le = lbl_entries[row];
    for (0..n) |i| {
        labels_buf[i] = if (i < le.length) helpers.bytesSlice(&lbl_data[le.offset + i]) else "";
    }

    const values = val_data[ve.offset .. ve.offset + n];

    var c = canvas_lib.Canvas.init(allocator, cw, ch) catch return writeText(result_vec, row, context, "", err);
    const coils = snake.layout(values, cw, ch, allocator) catch return writeText(result_vec, row, context, "", err);
    snake.renderCoils(&c, coils, labels_buf, allocator) catch return writeText(result_vec, row, context, "", err);
    const rendered = c.render(allocator) catch return writeText(result_vec, row, context, "", err);

    return writeText(result_vec, row, context, rendered, err);
}

fn writeText(result_vec: v2.duckdb_v2_vector_handle, row: u64, context: v2.duckdb_v2_context_handle, text: []const u8, err: *v2.duckdb_v2_error_info_handle) bool {
    var value: v2.duckdb_v2_value_handle = undefined;
    if (helpers.createVarcharValue(context, text, &value, err) != .ERROR_NONE) return false;
    defer _ = v2.duckdb_v2_value_destroy(&value);
    return v2.duckdb_v2_vector_set_value(result_vec, row, value, err) == .ERROR_NONE;
}

fn anyInvalid(views: []const v2.duckdb_v2_vector_view, row: u64) bool {
    for (views) |v| {
        if (!helpers.isValid(v.validity, row)) return true;
    }
    return false;
}

/// Register the tp_treemap scalar function against the v2 extension being loaded. A failure leaves
/// DuckDB's error info in the entrypoint's error slot, so the load reports why.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;

    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("tp_treemap");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) {
        return error.FailedToSetName;
    }

    var double_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_DOUBLE, &double_type, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&double_type);
    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);
    var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);
    var double_list: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createListType(input.context, double_type, &double_list, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&double_list);
    var varchar_list: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createListType(input.context, varchar_type, &varchar_list, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_list);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) {
        return error.FailedToGetSignature;
    }

    const vals_name = helpers.str("vals");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &vals_name, double_list, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    const labels_name = helpers.str("labels");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &labels_name, varchar_list, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    var width_default: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_bigint_with_context(input.context, 80, &width_default, err) != .ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = v2.duckdb_v2_value_destroy(&width_default);
    const width_name = helpers.str("width");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &width_name, bigint_type, width_default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

    var height_default: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_bigint_with_context(input.context, 24, &height_default, err) != .ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = v2.duckdb_v2_value_destroy(&height_default);
    const height_name = helpers.str("height");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &height_name, bigint_type, height_default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

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
