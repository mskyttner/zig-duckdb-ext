///! Cookbook: reading DuckDB's configuration from inside an extension (v2 C API, `configuration` module).
///!
///!   zig_cookbook_option(name VARCHAR) -> VARCHAR      the current setting of one option
///!   zig_cookbook_options()  -> (name, setting, default_setting, description, scope, aliases)   all of them
///!
///! What the API gives you, and what it does not:
///!
///!   * A function receives a **context**, and `context_get_config` gives the **config** through which options are read:
///!     `config_get_option_value` returns the value as the option's own type (and the scope it came from): the
///!     connection's `SET` override if it has one, otherwise the global value, otherwise the default; aliases resolve.
///!     `config_get_option_by_name` / `_by_index` / `_count` give option handles. An unknown name is an error of the query.
///!   * An option handle **borrows** its strings (name, description) until it is destroyed, so anything kept past that is
///!     copied: the table function copies every row while it binds. Values are owned by the caller, and typed: to show
///!     one as text, cast it to VARCHAR (`value_cast`, which takes a factory).
///!   * `config_set_option_value` writes through a config; `SET` in SQL does the same.
///!   * This API (alpha48730) has `custom_option_*`, a way to register an option of your own; this recipe only reads.
///!
///! Scalar functions get the context in `exec`; table functions get it in `bind` (and `init_global`), which is why
///! the table function below snapshots at bind time instead of reading while it emits rows.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

/// `value` cast to VARCHAR, owned by the caller; null after failing.
fn castToVarchar(factory: v2.duckdb_v2_factory_handle, context: v2.duckdb_v2_context_handle, value: v2.duckdb_v2_value_handle, err: *v2.duckdb_v2_error_info_handle) ?v2.duckdb_v2_value_handle {
    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return null;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);
    var out: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_cast(factory, value, varchar_type, &out, err) != .ERROR_NONE) return null;
    return out;
}

/// The text of a value of any type, copied into `arena`.
fn valueText(arena: std.mem.Allocator, context: v2.duckdb_v2_context_handle, value: v2.duckdb_v2_value_handle, err: *v2.duckdb_v2_error_info_handle) ![]const u8 {
    var is_null = false;
    if (v2.duckdb_v2_value_is_null(value, &is_null, err) != .ERROR_NONE) return error.DuckDbError;
    if (is_null) return "";
    const factory = helpers.factory(context, err) orelse return error.DuckDbError;
    var text_value = castToVarchar(factory, context, value, err) orelse return error.DuckDbError;
    defer _ = v2.duckdb_v2_value_destroy(&text_value);
    var text: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_value_get_varchar(text_value, &text, err) != .ERROR_NONE) return error.DuckDbError;
    return copyStr(arena, text);
}

// --- zig_cookbook_option(name) ---------------------------------------------------------------------

fn optionExec(
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

    // SAFETY: the signature registered this function as (VARCHAR) -> VARCHAR, and a flattened VARCHAR
    // vector is an array of `duckdb_v2_bytes`.
    const names: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(view.data orelse return));

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        if (!helpers.isValid(view.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
            continue;
        }
        const name = helpers.str(helpers.bytesSlice(&names[row]));
        var config: v2.duckdb_v2_config_handle = undefined;
        if (v2.duckdb_v2_context_get_config(context, &config, err) != .ERROR_NONE) return;
        // The value is typed as the option is (a BIGINT for `threads`); an unknown name leaves its reason in `err`,
        // which fails the query.
        var typed: v2.duckdb_v2_value_handle = undefined;
        var scope: v2.DUCKDB_V2_SETTING_SCOPE = undefined;
        if (v2.duckdb_v2_config_get_option_value(config, &name, &typed, &scope, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&typed);
        const factory = helpers.factory(context, err) orelse return;
        var value = castToVarchar(factory, context, typed, err) orelse return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

fn registerOption(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) !void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("zig_cookbook_option");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return error.FailedToSetName;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const param = helpers.str("name");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &param, varchar_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar_type, err) != .ERROR_NONE) return error.FailedToSetReturnType;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &optionExec, err) != .ERROR_NONE) return error.FailedToSetExecCallback;
    // What duckdb_functions() shows besides the signature.
    var function_docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_docs(function, &function_docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(function_docs, .{
        .description = "The current setting of a DuckDB option, as text: the connection's SET override, else the global value, else the default; aliases resolve.",
        .examples = &.{.{ .sql = "SELECT zig_cookbook_option('threads');" }},
        .categories = &.{"configuration"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

// --- zig_cookbook_options() ------------------------------------------------------------------------

const columns = [_][]const u8{ "name", "setting", "default_setting", "description", "scope", "aliases" };

/// One row per option, every string copied out of the option handle.
const Row = [columns.len][]const u8;

const BindData = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,
};

fn destroyBindData(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `bind` stored a `*BindData` as this function's bind data.
    const data: *BindData = @ptrCast(@alignCast(ptr));
    data.arena.deinit();
    std.heap.c_allocator.destroy(data);
}

const GlobalState = struct { next_row: usize = 0 };

fn destroyGlobalState(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `initGlobal` stored a `*GlobalState` as this function's global state.
    const state: *GlobalState = @ptrCast(@alignCast(ptr));
    std.heap.c_allocator.destroy(state);
}

fn copyStr(arena: std.mem.Allocator, s: v2.duckdb_v2_str) ![]const u8 {
    const ptr = s.ptr orelse return "";
    return arena.dupe(u8, ptr[0..s.len]);
}

/// Reads the option at `index` into `row`; the strings live in `arena`.
fn readOption(arena: std.mem.Allocator, context: v2.duckdb_v2_context_handle, index: u64, row: *Row, err: *v2.duckdb_v2_error_info_handle) !void {
    var config: v2.duckdb_v2_config_handle = undefined;
    if (v2.duckdb_v2_context_get_config(context, &config, err) != .ERROR_NONE) return error.DuckDbError;
    var option: v2.duckdb_v2_option_handle = undefined;
    if (v2.duckdb_v2_config_get_option_by_index(config, index, &option, err) != .ERROR_NONE) return error.DuckDbError;
    defer _ = v2.duckdb_v2_option_destroy(&option);

    var name: v2.duckdb_v2_identifier_t = undefined;
    var description: v2.duckdb_v2_str = undefined;
    var scope: v2.DUCKDB_V2_SETTING_SCOPE = undefined;
    if (v2.duckdb_v2_option_get_name(option, &name, err) != .ERROR_NONE) return error.DuckDbError;
    if (v2.duckdb_v2_option_get_description(option, &description, err) != .ERROR_NONE) return error.DuckDbError;
    if (v2.duckdb_v2_option_get_default_scope(option, &scope, err) != .ERROR_NONE) return error.DuckDbError;

    // The current value (as the connection sees it) and the default, both typed: shown as text.
    var current: v2.duckdb_v2_value_handle = undefined;
    var current_scope: v2.DUCKDB_V2_SETTING_SCOPE = undefined;
    if (v2.duckdb_v2_config_get_option_value(config, &name, &current, &current_scope, err) != .ERROR_NONE) return error.DuckDbError;
    defer _ = v2.duckdb_v2_value_destroy(&current);
    var default_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_option_get_default_value(option, &default_value, err) != .ERROR_NONE) return error.DuckDbError;
    defer _ = v2.duckdb_v2_value_destroy(&default_value);

    // The other names the option answers to, comma-separated (none for an extension option).
    var alias_count: u64 = 0;
    if (v2.duckdb_v2_option_get_alias_count(option, &alias_count, err) != .ERROR_NONE) return error.DuckDbError;
    var aliases: std.ArrayList(u8) = .empty;
    var alias_index: u64 = 0;
    while (alias_index < alias_count) : (alias_index += 1) {
        var alias: v2.duckdb_v2_identifier_t = undefined;
        if (v2.duckdb_v2_option_get_alias(option, alias_index, &alias, err) != .ERROR_NONE) return error.DuckDbError;
        if (alias_index > 0) try aliases.append(arena, ',');
        try aliases.appendSlice(arena, try copyStr(arena, alias));
    }

    row.* = .{
        try copyStr(arena, name),
        try valueText(arena, context, current, err),
        try valueText(arena, context, default_value, err),
        try copyStr(arena, description),
        @tagName(scope)["SETTING_SCOPE_".len..],
        aliases.items,
    };
}

fn bind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);
    inline for (columns) |column| {
        const column_name = helpers.str(column);
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &column_name, varchar_type, err) != .ERROR_NONE) return;
    }

    // Snapshot every option now: the context is only guaranteed to be readable during bind and exec,
    // and the option handles borrow their strings.
    var config: v2.duckdb_v2_config_handle = undefined;
    if (v2.duckdb_v2_context_get_config(context, &config, err) != .ERROR_NONE) return;
    var count: u64 = 0;
    if (v2.duckdb_v2_config_get_option_count(config, &count, err) != .ERROR_NONE) return;

    const data = std.heap.c_allocator.create(BindData) catch return;
    data.arena = .init(std.heap.c_allocator);
    var keep = false;
    defer if (!keep) destroyBindData(data);
    data.rows = data.arena.allocator().alloc(Row, count) catch return;
    for (data.rows, 0..) |*row, index| {
        readOption(data.arena.allocator(), context, index, row, err) catch return;
    }

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyBindData, .equals = null };
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

fn initGlobal(
    info: v2.duckdb_v2_table_function_init_global_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    _ = context;
    const state = std.heap.c_allocator.create(GlobalState) catch return;
    state.* = .{};
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
    if (v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyGlobalState(state);
}

/// DuckDB's vector size: a chunk holds at most this many rows.
const chunk_rows = 2048;

fn exec(
    info: v2.duckdb_v2_table_function_exec_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: *v2.duckdb_v2_error_info_handle,
) callconv(.c) void {
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    var state_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `bind` and `initGlobal` stored these types.
    const data: *BindData = @ptrCast(@alignCast(bind_ptr.?));
    const state: *GlobalState = @ptrCast(@alignCast(state_ptr.?));

    const n = @min(chunk_rows, data.rows.len - state.next_row);
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;

    // Every vector's size is set before anything is written; zero rows ends the scan.
    inline for (0..columns.len) |c| {
        var vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(vec, n, err) != .ERROR_NONE) return;
        for (data.rows[state.next_row..][0..n], 0..) |row, i| {
            var value: v2.duckdb_v2_value_handle = undefined;
            if (helpers.createVarcharValue(context, row[c], &value, err) != .ERROR_NONE) return;
            defer _ = v2.duckdb_v2_value_destroy(&value);
            if (v2.duckdb_v2_vector_set_value(vec, i, value, err) != .ERROR_NONE) return;
        }
    }
    state.next_row += n;
}

fn registerOptions(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);

    const fn_name = helpers.str("zig_cookbook_options");
    if (v2.duckdb_v2_table_function_set_name(function, &fn_name, err) != .ERROR_NONE) return error.FailedToSetName;
    if (v2.duckdb_v2_table_function_set_bind_callback(function, &bind, err) != .ERROR_NONE) return error.FailedToSetBindCallback;
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &initGlobal, err) != .ERROR_NONE) return error.FailedToSetInitGlobalCallback;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) return error.FailedToSetExecCallback;
    // What duckdb_functions() shows besides the signature.
    var function_docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_table_function_get_docs(function, &function_docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(function_docs, .{
        .description = "Every DuckDB option with its setting, default, description, default scope and aliases, read through the config.",
        .examples = &.{.{ .sql = "SELECT name, setting, scope FROM zig_cookbook_options() WHERE name = 'threads';" }},
        .categories = &.{"configuration"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers both functions. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerOption(input, err);
    try registerOptions(input, err);
}
