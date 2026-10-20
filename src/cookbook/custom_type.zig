///! Cookbook: a custom type with casts and functions (v2 C API, `logical_type/custom_type` and `function/cast`).
///!
///!   zig_cookbook_celsius      a temperature in degrees Celsius, stored as a DOUBLE
///!
///!   SELECT '21.5C'::zig_cookbook_celsius;            -- VARCHAR  -> celsius (parses, rejects below absolute zero)
///!   SELECT 21.5::zig_cookbook_celsius::VARCHAR;      -- celsius  -> VARCHAR  ('21.5°C')
///!   SELECT zig_cookbook_to_fahrenheit('100C');       -- a function that takes the type
///!   SELECT zig_cookbook_from_fahrenheit(212.0);      -- and one that returns it
///!
///! A custom type is a **name bound to a base type**. It borrows the base type's physical layout, so the engine needs
///! no special handling and its vectors are read and written like the base type's (here DOUBLE); it is
///! logically distinct, so it can carry its own casts, be a column type, and tell the user what a value is.
///!
///!   custom_type_create_with_extension / set_name / set_base_type / register   the type itself
///!   context_create_type_with_alias(DOUBLE, "zig_cookbook_celsius")            a type *instance*, for signatures
///!   context_create_type_from_name(qname)                                      the same, looked up by name
///!   cast functions (source type, target type, exec, implicit cost)            what makes the type usable from SQL
///!
///! Without casts a custom type is an island: nothing converts to it or from it, not even its own base type.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const Err = *v2.duckdb_v2_error_info_handle;

const type_name = "zig_cookbook_celsius";
const absolute_zero: f64 = -273.15;

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [240]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = helpers.setErrorText(err.*, msg);
}

// --- the type ---------------------------------------------------------------------------------------------------------

fn registerType(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var custom: v2.duckdb_v2_custom_type_handle = undefined;
    if (v2.duckdb_v2_custom_type_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &custom, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_custom_type_destroy(&custom);
    const name = helpers.str(type_name);
    if (v2.duckdb_v2_custom_type_set_name(custom, &name, err) != .ERROR_NONE) return error.FailedToSetName;

    var base: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_DOUBLE, &base, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&base);
    // A fully defined concrete type: ANY, a wildcard of function signatures, cannot be a base.
    if (v2.duckdb_v2_custom_type_set_base_type(custom, base, err) != .ERROR_NONE) return error.FailedToSetBaseType;
    // Registered on the extension being loaded. The handle stays ours, to destroy; the registration does not need it.
    if (v2.duckdb_v2_extension_register_custom_type(input.extension, custom, err) != .ERROR_NONE) return error.FailedToRegisterType;
}

/// The custom type as a logical type, by looking it up in the catalog: what a user's `::zig_cookbook_celsius` resolves to.
fn celsiusByName(ctx: v2.duckdb_v2_context_handle, out: *v2.duckdb_v2_logical_type_handle, err: Err) v2.DUCKDB_V2_ERROR {
    const parts = [_]v2.duckdb_v2_identifier_t{helpers.str(type_name)};
    var qname: v2.duckdb_v2_qname_handle = undefined;
    const created = v2.duckdb_v2_qname_create(&parts, parts.len, &qname, err);
    if (created != .ERROR_NONE) return created;
    defer _ = v2.duckdb_v2_qname_destroy(&qname);
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_from_name(f, qname, null, null, 0, out, err);
}

/// The same type made from its base type and its name: no lookup, so it also works where the catalog is out of reach
/// (a custom type's bind callback is the intended place).
fn celsiusByAlias(ctx: v2.duckdb_v2_context_handle, out: *v2.duckdb_v2_logical_type_handle, err: Err) v2.DUCKDB_V2_ERROR {
    var base: v2.duckdb_v2_logical_type_handle = undefined;
    const created = helpers.createTypeFromId(ctx, .LOGICAL_TYPE_ID_DOUBLE, &base, err);
    if (created != .ERROR_NONE) return created;
    defer _ = v2.duckdb_v2_logical_type_destroy(&base);
    const alias = helpers.str(type_name);
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_with_alias(f, base, &alias, out, err);
}

// --- casts --------------------------------------------------------------------------------------------------------------

/// Parses '21.5', '21.5C', ' -3 °C ': a number, optionally followed by C or °C.
fn parseCelsius(raw: []const u8) ?f64 {
    var s = std.mem.trim(u8, raw, " \t");
    if (std.mem.endsWith(u8, s, "C") or std.mem.endsWith(u8, s, "c")) s = s[0 .. s.len - 1];
    if (std.mem.endsWith(u8, s, "\u{b0}")) s = s[0 .. s.len - "\u{b0}".len];
    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0) return null;
    const value = std.fmt.parseFloat(f64, s) catch return null;
    if (!std.math.isFinite(value) or value < absolute_zero) return null;
    return value;
}

/// What a cast does with a value it cannot convert: NULL in TRY_CAST, an error of the query otherwise.
fn rejected(mode: v2.DUCKDB_V2_CAST_MODE, output: v2.duckdb_v2_vector_handle, row: u64, err: Err, comptime fmt: []const u8, args: anytype) bool {
    if (mode == .CAST_MODE_TRY) return v2.duckdb_v2_vector_set_null(output, row, err) == .ERROR_NONE;
    fail(err, .ERROR_TYPE_CONVERSION, fmt, args);
    return false;
}

const CastIo = struct {
    rows: u64,
    mode: v2.DUCKDB_V2_CAST_MODE,
    input: v2.duckdb_v2_vector_view,
    output: v2.duckdb_v2_vector_handle,

    /// The input flattened and viewed, the output sized.
    fn open(info: v2.duckdb_v2_cast_function_exec_info_handle, err: Err) ?CastIo {
        var io: CastIo = undefined;
        if (v2.duckdb_v2_cast_function_exec_get_row_count(info, &io.rows, err) != .ERROR_NONE) return null;
        if (v2.duckdb_v2_cast_function_exec_get_mode(info, &io.mode, err) != .ERROR_NONE) return null;
        var input: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_cast_function_exec_get_input(info, &input, err) != .ERROR_NONE) return null;
        if (v2.duckdb_v2_vector_flatten(input, err) != .ERROR_NONE) return null;
        if (v2.duckdb_v2_vector_get_view(input, &io.input, err) != .ERROR_NONE) return null;
        if (v2.duckdb_v2_cast_function_exec_get_output(info, &io.output, err) != .ERROR_NONE) return null;
        if (v2.duckdb_v2_vector_set_size(io.output, io.rows, err) != .ERROR_NONE) return null;
        return io;
    }
};

fn varcharToCelsius(info: v2.duckdb_v2_cast_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    const io = CastIo.open(info, err) orelse return;
    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(io.output, &out_data, err) != .ERROR_NONE) return;
    // SAFETY: the source is VARCHAR (an array of `duckdb_v2_bytes`) and the target has DOUBLE storage.
    const texts: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(io.input.data orelse return));
    const out: [*]f64 = @ptrCast(@alignCast(out_data.?));
    for (0..io.rows) |row| {
        if (!helpers.isValid(io.input.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(io.output, row, err) != .ERROR_NONE) return;
            continue;
        }
        const text = helpers.bytesSlice(&texts[row]);
        out[row] = parseCelsius(text) orelse {
            if (!rejected(io.mode, io.output, row, err, "Could not convert string '{s}' to " ++ type_name ++ " (a number, optionally followed by C, not below -273.15)", .{text})) return;
            continue;
        };
    }
}

fn celsiusToVarchar(info: v2.duckdb_v2_cast_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    const io = CastIo.open(info, err) orelse return;
    // SAFETY: the source has DOUBLE storage.
    const values: [*]const f64 = @ptrCast(@alignCast(io.input.data orelse return));
    for (0..io.rows) |row| {
        if (!helpers.isValid(io.input.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(io.output, row, err) != .ERROR_NONE) return;
            continue;
        }
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}\u{b0}C", .{values[row]}) catch unreachable;
        var value: v2.duckdb_v2_value_handle = undefined;
        if (helpers.createVarcharValue(context, text, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(io.output, row, value, err) != .ERROR_NONE) return;
    }
}

/// DOUBLE -> celsius: the same bits, checked against absolute zero.
fn doubleToCelsius(info: v2.duckdb_v2_cast_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    const io = CastIo.open(info, err) orelse return;
    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(io.output, &out_data, err) != .ERROR_NONE) return;
    // SAFETY: both sides have DOUBLE storage.
    const values: [*]const f64 = @ptrCast(@alignCast(io.input.data orelse return));
    const out: [*]f64 = @ptrCast(@alignCast(out_data.?));
    for (0..io.rows) |row| {
        if (!helpers.isValid(io.input.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(io.output, row, err) != .ERROR_NONE) return;
            continue;
        }
        const v = values[row];
        if (!std.math.isFinite(v) or v < absolute_zero) {
            if (!rejected(io.mode, io.output, row, err, "Could not convert {d} to " ++ type_name ++ ": below absolute zero (-273.15)", .{v})) return;
            continue;
        }
        out[row] = v;
    }
}

/// celsius -> DOUBLE: the same bits. Registered with an implicit cost, so that a celsius value goes where a DOUBLE is
/// asked for (`abs(c)`, `c + 1`) without a cast written out; the other directions stay explicit.
fn celsiusToDouble(info: v2.duckdb_v2_cast_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    const io = CastIo.open(info, err) orelse return;
    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(io.output, &out_data, err) != .ERROR_NONE) return;
    // SAFETY: both sides have DOUBLE storage.
    const values: [*]const f64 = @ptrCast(@alignCast(io.input.data orelse return));
    const out: [*]f64 = @ptrCast(@alignCast(out_data.?));
    for (0..io.rows) |row| {
        if (!helpers.isValid(io.input.validity, row)) {
            if (v2.duckdb_v2_vector_set_null(io.output, row, err) != .ERROR_NONE) return;
            continue;
        }
        out[row] = values[row];
    }
}

const Side = enum { varchar, double, celsius };

fn sideType(side: Side, input: *const v2.duckdb_v2_extension_input, out: *v2.duckdb_v2_logical_type_handle, err: Err) v2.DUCKDB_V2_ERROR {
    return switch (side) {
        .varchar => helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, out, err),
        .double => helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_DOUBLE, out, err),
        .celsius => celsiusByName(input.context, out, err),
    };
}

fn registerCast(input: *const v2.duckdb_v2_extension_input, err: Err, from: Side, to: Side, exec: v2.duckdb_v2_cast_function_exec_callback_fn, implicit_cost: ?i64) !void {
    var function: v2.duckdb_v2_cast_function_handle = undefined;
    if (v2.duckdb_v2_cast_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_cast_function_destroy(&function);

    var source: v2.duckdb_v2_logical_type_handle = undefined;
    if (sideType(from, input, &source, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&source);
    var target: v2.duckdb_v2_logical_type_handle = undefined;
    if (sideType(to, input, &target, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&target);
    if (v2.duckdb_v2_cast_function_set_source_type(function, source, err) != .ERROR_NONE) return error.FailedToSetSourceType;
    if (v2.duckdb_v2_cast_function_set_target_type(function, target, err) != .ERROR_NONE) return error.FailedToSetTargetType;
    if (implicit_cost) |cost| {
        if (v2.duckdb_v2_cast_function_set_implicit_cast_cost(function, cost, err) != .ERROR_NONE) return error.FailedToSetCost;
    }
    if (v2.duckdb_v2_cast_function_set_exec_callback(function, exec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_extension_register_cast_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterCast;
}

// --- functions that take and return the type -------------------------------------------------------------------------------

/// Reads and writes DOUBLE storage on both sides, whichever of the two is the custom type.
fn convertExec(comptime to_fahrenheit: bool) fn (v2.duckdb_v2_scalar_function_exec_info_handle, v2.duckdb_v2_context_handle, Err) callconv(.c) void {
    return struct {
        fn exec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
            _ = context;
            var row_count: u64 = 0;
            if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
            var arg: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_scalar_function_exec_get_arg(info, 0, &arg, err) != .ERROR_NONE) return;
            if (v2.duckdb_v2_vector_flatten(arg, err) != .ERROR_NONE) return;
            var view: v2.duckdb_v2_vector_view = undefined;
            if (v2.duckdb_v2_vector_get_view(arg, &view, err) != .ERROR_NONE) return;
            var result: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result, err) != .ERROR_NONE) return;
            if (v2.duckdb_v2_vector_set_size(result, row_count, err) != .ERROR_NONE) return;
            var out_data: ?*anyopaque = null;
            if (v2.duckdb_v2_vector_get_data_mutable(result, &out_data, err) != .ERROR_NONE) return;
            // SAFETY: the argument and the result are DOUBLE or the custom type, which has DOUBLE storage.
            const xs: [*]const f64 = @ptrCast(@alignCast(view.data orelse return));
            const ys: [*]f64 = @ptrCast(@alignCast(out_data.?));
            for (0..row_count) |row| {
                if (!helpers.isValid(view.validity, row)) {
                    if (v2.duckdb_v2_vector_set_null(result, row, err) != .ERROR_NONE) return;
                    continue;
                }
                if (to_fahrenheit) {
                    ys[row] = xs[row] * 9.0 / 5.0 + 32.0;
                } else {
                    const c = (xs[row] - 32.0) * 5.0 / 9.0;
                    if (c < absolute_zero) return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "{d} degrees Fahrenheit is below absolute zero", .{xs[row]});
                    ys[row] = c;
                }
            }
        }
    }.exec;
}

fn registerConversion(input: *const v2.duckdb_v2_extension_input, err: Err, name: []const u8, comptime to_fahrenheit: bool) !void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);
    const fn_name = helpers.str(name);
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return error.FailedToSetName;

    var celsius: v2.duckdb_v2_logical_type_handle = undefined;
    if (celsiusByAlias(input.context, &celsius, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&celsius);
    var double: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_DOUBLE, &double, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&double);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const param = helpers.str("t");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &param, if (to_fahrenheit) celsius else double, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, if (to_fahrenheit) double else celsius, err) != .ERROR_NONE) return error.FailedToSetReturnType;
    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, &convertExec(to_fahrenheit), err) != .ERROR_NONE) return error.FailedToSetCallback;
    // What duckdb_functions() shows besides the signature.
    var function_docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_docs(function, &function_docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(function_docs, if (to_fahrenheit) .{
        .description = "A temperature of the custom type zig_cookbook_celsius in degrees Fahrenheit, as DOUBLE; a string such as '100C' casts to the type.",
        .examples = &.{.{ .sql = "SELECT zig_cookbook_to_fahrenheit('100C');" }},
        .categories = &.{"temperature"},
    } else .{
        .description = "A temperature in degrees Fahrenheit (DOUBLE) as the custom type zig_cookbook_celsius.",
        .examples = &.{.{ .sql = "SELECT zig_cookbook_from_fahrenheit(212.0)::DOUBLE;" }},
        .categories = &.{"temperature"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the type, then what needs it: the casts and the functions. A failure leaves DuckDB's error info in the
/// entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerType(input, err);
    try registerCast(input, err, .varchar, .celsius, &varcharToCelsius, null);
    try registerCast(input, err, .celsius, .varchar, &celsiusToVarchar, null);
    try registerCast(input, err, .double, .celsius, &doubleToCelsius, null);
    // The one implicit direction: a celsius value is accepted where a DOUBLE is expected.
    try registerCast(input, err, .celsius, .double, &celsiusToDouble, 10);
    try registerConversion(input, err, "zig_cookbook_to_fahrenheit", true);
    try registerConversion(input, err, "zig_cookbook_from_fahrenheit", false);
}
