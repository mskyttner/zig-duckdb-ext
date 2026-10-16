///! Scalar function: tp_snakemap(values DOUBLE[], labels VARCHAR[], groups VARCHAR[], width BIGINT := 80, height BIGINT := 24, no_color BOOLEAN := false) -> VARCHAR
///!
///! v2 port of tp_snakemap.zig. Drops the SQL-macro default-param workaround
///! (same as the other tp_* ports). Adds a third parallel LIST(VARCHAR) and
///! the first live v2 BOOLEAN test (comptime_scalar_v2 maps `bool` already,
///! but this is the first time a bool-typed argument actually runs against
///! the real runtime) — otherwise the same vector_get_child + list_entry
///! mechanism tp_treemap_v2 already proved for parallel LIST arguments.
///!
///! Calls renderSnakemap (extracted out of tp_snakemap.zig's own writeRow
///! into a reusable, DuckDB-API-free function as part of this port — see
///! that function's doc comment) instead of duplicating ~150 lines of
///! grouping/rendering logic.
///!
///! Written against the generated bindings (`duckdb_v2_dynamic`), like hello_v2.zig.
const std = @import("std");
const v2 = @import("duckdb_v2_dynamic");
const helpers = @import("v2_helpers");
const renderSnakemap = @import("tp_snakemap.zig").renderSnakemap;

fn exec(
    info: v2.duckdb_v2_scalar_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var args: [6]v2.duckdb_v2_vector_handle = undefined;
    var views: [6]v2.duckdb_v2_vector_view = undefined;
    inline for (0..6) |i| {
        if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &args[i], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_flatten(args[i], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_get_view(args[i], &views[i], err) != .ERROR_NONE) return;
    }

    // The three list arguments' elements live in child vectors.
    var children: [3]v2.duckdb_v2_vector_handle = undefined;
    var child_views: [3]v2.duckdb_v2_vector_view = undefined;
    inline for (0..3) |i| {
        if (v2.duckdb_v2_vector_get_child(args[i], 0, &children[i], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_flatten(children[i], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_get_view(children[i], &child_views[i], err) != .ERROR_NONE) return;
    }

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    // SAFETY: the signature registered these as
    // (LIST(DOUBLE), LIST(VARCHAR), LIST(VARCHAR), BIGINT, BIGINT, BOOLEAN) -> VARCHAR.
    const val_entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(views[0].data orelse return));
    const lbl_entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(views[1].data orelse return));
    const grp_entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(views[2].data orelse return));
    const width_data: [*]const i64 = @ptrCast(@alignCast(views[3].data orelse return));
    const height_data: [*]const i64 = @ptrCast(@alignCast(views[4].data orelse return));
    const no_color_data: [*]const bool = @ptrCast(@alignCast(views[5].data orelse return));
    const val_data: [*]const f64 = @ptrCast(@alignCast(child_views[0].data orelse return));
    const lbl_data: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(child_views[1].data orelse return));
    const grp_data: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(child_views[2].data orelse return));

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (anyInvalid(&views, row)) {
            if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            continue;
        }

        const w_raw = width_data[row];
        const h_raw = height_data[row];
        const ve = val_entries[row];
        if (w_raw <= 0 or h_raw <= 0 or ve.length == 0) {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        }

        const cw: usize = @intCast(@min(w_raw, 512));
        const ch: usize = @intCast(@min(h_raw, 256));
        const no_color = no_color_data[row];

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const n = ve.length;
        const le = lbl_entries[row];
        const ge = grp_entries[row];

        const values = allocator.alloc(f64, n) catch {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        };
        const labels = allocator.alloc([]const u8, n) catch {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        };
        const groups = allocator.alloc([]const u8, n) catch {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        };
        for (0..n) |i| {
            values[i] = val_data[ve.offset + i];
            labels[i] = if (i < le.length) helpers.bytesSlice(&lbl_data[le.offset + i]) else "";
            groups[i] = if (i < ge.length) helpers.bytesSlice(&grp_data[ge.offset + i]) else "";
        }

        const rendered = renderSnakemap(allocator, values, labels, groups, cw, ch, no_color) catch {
            if (!writeText(result_vec, row, context, "", err)) return;
            continue;
        };
        if (!writeText(result_vec, row, context, rendered, err)) return;
    }
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

/// Register the tp_snakemap scalar function against the v2 extension being loaded. A failure leaves
/// DuckDB's error info in the entrypoint's error slot, so the load reports why.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;

    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("tp_snakemap");
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
    var bool_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BOOLEAN, &bool_type, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bool_type);
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
    const groups_name = helpers.str("groups");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &groups_name, varchar_list, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
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

    var no_color_default: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_bool_with_context(input.context, false, &no_color_default, err) != .ERROR_NONE) return error.FailedToCreateDefault;
    defer _ = v2.duckdb_v2_value_destroy(&no_color_default);
    const no_color_name = helpers.str("no_color");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &no_color_name, bool_type, no_color_default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

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
