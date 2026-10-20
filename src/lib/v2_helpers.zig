///! Small helpers over the generated v2 types (`duckdb_v2_dynamic`) that more than one function
///! module needs.
const std = @import("std");
const v2 = @import("duckdb_v2_api");

/// Gets the backend ready, whichever one `duckdb_v2_api` is bound to. The dynamic backend fetches
/// the function table through `get_api` (returns false if DuckDB refuses the version); the static
/// backend links the functions directly and has nothing to fetch. Call it first in the entrypoint.
pub fn init(input: *const v2.duckdb_v2_extension_input, minimum_api_version: [*:0]const u8) bool {
    if (comptime @hasDecl(v2, "init")) return v2.init(input, minimum_api_version);
    return true;
}

/// `try helpers.ok(v2.duckdb_v2_X(...), error.Y)` instead of
/// `if (v2.duckdb_v2_X(...) != .ERROR_NONE) return error.Y;` — same control flow, one call
/// instead of an `if`. `failure` can be any error already in scope, so the descriptive name
/// each call site already used (`error.FailedToGetDocs`, `error.DuckDbError`, ...) survives;
/// this only removes the repeated `if (... != .ERROR_NONE) return ...` shape, confirmed to
/// repeat 23 times across this file and the five comptime_*_v2 frameworks before this existed.
/// `DuckDB's own `error_info_handle` already carries the real message for the engine to show
/// the user — none of these call sites read it back, so there's nothing lost by not doing so
/// here either (prompted by comparing against `duckdb-neo`'s own single-point error
/// conversion, `Error::from_code_and_handle`, which does read the message — this project's own
/// `cookbook/embed_sql.zig`'s `Call`/`ok`/`err` already does exactly that, for the one
/// embedding-host use case that actually needs to report a message back to a human).
pub inline fn ok(code: v2.DUCKDB_V2_ERROR, comptime failure: anytype) @TypeOf(failure)!void {
    if (code != .ERROR_NONE) return failure;
}

/// Whether `row` is valid according to a vector's validity mask. A missing mask means every row is.
pub fn isValid(validity: ?[*]const u64, row: u64) bool {
    const mask = validity orelse return true;
    const bit: u6 = @intCast(row % 64);
    return (mask[row / 64] & (@as(u64, 1) << bit)) != 0;
}

/// The bytes of a VARCHAR (or BLOB) value, borrowed from `b`.
pub fn bytesSlice(b: *const v2.duckdb_v2_bytes) []const u8 {
    const len = b.value.inlined.length;
    if (len <= v2.DUCKDB_V2_BYTES_INLINE_LENGTH) return b.value.inlined.inlined[0..len];
    // Longer bytes live behind a pointer that DuckDB guarantees is set.
    const ptr = b.value.pointer.ptr orelse return "";
    return ptr[0..len];
}

/// A `duckdb_v2_str` view of `s`, borrowed.
pub fn str(s: []const u8) v2.duckdb_v2_str {
    return .{ .ptr = s.ptr, .len = s.len };
}

/// Makes the scalar function handle NULL arguments itself instead of getting NULL for any NULL
/// argument without being called.
pub fn setNullHandlingSpecial(function: v2.duckdb_v2_scalar_function_handle, err: *v2.duckdb_v2_error_info_handle) v2.DUCKDB_V2_ERROR {
    return v2.duckdb_v2_scalar_function_set_property(function, .FUNCTION_PROPERTY_NULL_HANDLING, .FUNCTION_PROPERTY_NULL_HANDLING_SPECIAL, err);
}

/// The factory of a context: the handle that the API's `create` calls (types, values, chunks, functions) take. It is
/// borrowed and valid as long as the context is. Null after failing, with the reason in `err`.
pub fn factory(ctx: v2.duckdb_v2_context_handle, err: ?*v2.duckdb_v2_error_info_handle) ?v2.duckdb_v2_factory_handle {
    var f: v2.duckdb_v2_factory_handle = undefined;
    if (v2.duckdb_v2_context_get_factory(ctx, &f, err) != .ERROR_NONE) return null;
    return f;
}

/// What `duckdb_functions()` shows about a function besides its signature.
pub const Docs = struct {
    description: ?[]const u8 = null,
    examples: []const Example = &.{},
    categories: []const []const u8 = &.{},

    pub const Example = struct {
        /// Optional; DuckDB keeps it, but `duckdb_functions().examples` lists only the `sql`.
        title: ?[]const u8 = null,
        sql: []const u8,
    };
};

/// Fills a function's docs (from `<kind>_function_get_docs`). The texts are copied.
pub fn setDocs(docs: v2.duckdb_v2_function_docs_handle, d: Docs, err: ?*v2.duckdb_v2_error_info_handle) !void {
    if (d.description) |text| {
        const view = str(text);
        try ok(v2.duckdb_v2_function_docs_set_description(docs, &view, err), error.DuckDbError);
    }
    for (d.examples) |example| {
        const sql = str(example.sql);
        if (example.title) |t| {
            const title = str(t);
            try ok(v2.duckdb_v2_function_docs_add_example(docs, &title, &sql, err), error.DuckDbError);
        } else {
            try ok(v2.duckdb_v2_function_docs_add_example(docs, null, &sql, err), error.DuckDbError);
        }
    }
    for (d.categories) |c| {
        const category = str(c);
        try ok(v2.duckdb_v2_function_docs_add_category(docs, &category, err), error.DuckDbError);
    }
}

// --- Slice forms of calls that take a pointer and a count, or a `str` ----------------------------

/// A logical type that needs no parameters, by id.
pub fn createTypeFromId(
    ctx: v2.duckdb_v2_context_handle,
    type_id: v2.DUCKDB_V2_LOGICAL_TYPE_ID,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_from_id(f, type_id, null, null, 0, out_type, err);
}

/// A logical type from its SQL text, e.g. "VARIANT" or "ENUM('a', 'b')".
pub fn createTypeFromText(
    ctx: v2.duckdb_v2_context_handle,
    text: []const u8,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const view = str(text);
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_from_text(f, &view, out_type, err);
}

/// A VARCHAR value; the text is copied.
pub fn createVarcharValue(
    ctx: v2.duckdb_v2_context_handle,
    text: []const u8,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const view = str(text);
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_value_create_varchar(f, &view, out_value, err);
}

/// A BLOB value; the bytes are copied.
pub fn createBlobValue(
    ctx: v2.duckdb_v2_context_handle,
    bytes: []const u8,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const view = str(bytes);
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_value_create_blob(f, &view, out_value, err);
}

/// A LIST value of `children`, which are copied.
pub fn createListValue(
    ctx: v2.duckdb_v2_context_handle,
    child_type: v2.duckdb_v2_logical_type_handle,
    children: []const v2.duckdb_v2_value_handle,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_value_create_list(f, child_type, children.ptr, children.len, out_value, err);
}

/// An ARRAY value of `children`, which are copied.
pub fn createArrayValue(
    ctx: v2.duckdb_v2_context_handle,
    child_type: v2.duckdb_v2_logical_type_handle,
    children: []const v2.duckdb_v2_value_handle,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_value_create_array(f, child_type, children.ptr, children.len, out_value, err);
}

/// A MAP value of `keys[i]` -> `values[i]`, which are copied.
pub fn createMapValue(
    ctx: v2.duckdb_v2_context_handle,
    key_type: v2.duckdb_v2_logical_type_handle,
    value_type: v2.duckdb_v2_logical_type_handle,
    keys: []const v2.duckdb_v2_value_handle,
    values: []const v2.duckdb_v2_value_handle,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    std.debug.assert(keys.len == values.len);
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_value_create_map(f, key_type, value_type, keys.ptr, values.ptr, keys.len, out_value, err);
}

/// A STRUCT value of `children`, named `names`; both are copied.
pub fn createStructValue(
    ctx: v2.duckdb_v2_context_handle,
    names: []const v2.duckdb_v2_identifier_t,
    children: []const v2.duckdb_v2_value_handle,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    std.debug.assert(names.len == children.len);
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_value_create_struct(f, names.ptr, children.ptr, names.len, out_value, err);
}

/// A column data collection with one column per entry of `types`.
pub fn createColumnDataCollection(
    ctx: v2.duckdb_v2_context_handle,
    types: []const v2.duckdb_v2_logical_type_handle,
    out_collection: *v2.duckdb_v2_column_data_collection_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_column_data_collection_create(f, types.ptr, types.len, out_collection, err);
}

/// A data chunk with one column per entry of `types`.
pub fn createDataChunk(
    ctx: v2.duckdb_v2_context_handle,
    types: []const v2.duckdb_v2_logical_type_handle,
    out_chunk: *v2.duckdb_v2_data_chunk_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_data_chunk_create(f, types.ptr, types.len, out_chunk, err);
}

// --- Parametrised logical types -----------------------------------------------------------------
//
// LIST, ARRAY, MAP, STRUCT, UNION and DECIMAL types are created by one call, `context_create_type_from_id`,
// whose parameters are VALUES: a type goes in boxed as a value of that type, a size or a width as an
// integer value. These helpers do the boxing. A failure of the boxing is reported as ERROR_API, with
// the details in `err`.

fn boxType(ctx: v2.duckdb_v2_context_handle, ty: v2.duckdb_v2_logical_type_handle, out: *v2.duckdb_v2_value_handle, err: *v2.duckdb_v2_error_info_handle) bool {
    return v2.duckdb_v2_value_create_type(factory(ctx, err) orelse return false, ty, out, err) == .ERROR_NONE;
}

/// LIST(child_type).
pub fn createListType(
    ctx: v2.duckdb_v2_context_handle,
    child_type: v2.duckdb_v2_logical_type_handle,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var child_value: v2.duckdb_v2_value_handle = undefined;
    if (!boxType(ctx, child_type, &child_value, err)) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&child_value);
    const params = [_]v2.duckdb_v2_value_handle{child_value};
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_from_id(f, .LOGICAL_TYPE_ID_LIST, null, &params, params.len, out_type, err);
}

/// ARRAY(child_type, size).
pub fn createArrayType(
    ctx: v2.duckdb_v2_context_handle,
    child_type: v2.duckdb_v2_logical_type_handle,
    size: i64,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var child_value: v2.duckdb_v2_value_handle = undefined;
    if (!boxType(ctx, child_type, &child_value, err)) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&child_value);
    var size_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_bigint(factory(ctx, err) orelse return .ERROR_API, size, &size_value, err) != .ERROR_NONE) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&size_value);
    const params = [_]v2.duckdb_v2_value_handle{ child_value, size_value };
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_from_id(f, .LOGICAL_TYPE_ID_ARRAY, null, &params, params.len, out_type, err);
}

/// MAP(key_type, value_type).
pub fn createMapType(
    ctx: v2.duckdb_v2_context_handle,
    key_type: v2.duckdb_v2_logical_type_handle,
    value_type: v2.duckdb_v2_logical_type_handle,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var key_value: v2.duckdb_v2_value_handle = undefined;
    if (!boxType(ctx, key_type, &key_value, err)) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&key_value);
    var value_value: v2.duckdb_v2_value_handle = undefined;
    if (!boxType(ctx, value_type, &value_value, err)) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&value_value);
    const params = [_]v2.duckdb_v2_value_handle{ key_value, value_value };
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_from_id(f, .LOGICAL_TYPE_ID_MAP, null, &params, params.len, out_type, err);
}

/// DECIMAL(width, scale).
pub fn createDecimalType(
    ctx: v2.duckdb_v2_context_handle,
    width: u8,
    scale: u8,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    var width_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_utinyint(factory(ctx, err) orelse return .ERROR_API, width, &width_value, err) != .ERROR_NONE) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&width_value);
    var scale_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_utinyint(factory(ctx, err) orelse return .ERROR_API, scale, &scale_value, err) != .ERROR_NONE) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&scale_value);
    const params = [_]v2.duckdb_v2_value_handle{ width_value, scale_value };
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_from_id(f, .LOGICAL_TYPE_ID_DECIMAL, null, &params, params.len, out_type, err);
}

/// STRUCT(names[i] field_types[i], ...). The field types are boxed into `field_type_values`, which
/// the caller provides and destroys after it is done with the created type.
pub fn createStructType(
    ctx: v2.duckdb_v2_context_handle,
    names: []const v2.duckdb_v2_identifier_t,
    field_types: []const v2.duckdb_v2_logical_type_handle,
    field_type_values: []v2.duckdb_v2_value_handle,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    return createNamedType(ctx, .LOGICAL_TYPE_ID_STRUCT, names, field_types, field_type_values, out_type, err);
}

/// UNION(names[i] member_types[i], ...). Boxing as for `createStructType`.
pub fn createUnionType(
    ctx: v2.duckdb_v2_context_handle,
    names: []const v2.duckdb_v2_identifier_t,
    member_types: []const v2.duckdb_v2_logical_type_handle,
    member_type_values: []v2.duckdb_v2_value_handle,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    return createNamedType(ctx, .LOGICAL_TYPE_ID_UNION, names, member_types, member_type_values, out_type, err);
}

fn createNamedType(
    ctx: v2.duckdb_v2_context_handle,
    type_id: v2.DUCKDB_V2_LOGICAL_TYPE_ID,
    names: []const v2.duckdb_v2_identifier_t,
    types: []const v2.duckdb_v2_logical_type_handle,
    type_values: []v2.duckdb_v2_value_handle,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    for (types, 0..) |ty, i| {
        if (!boxType(ctx, ty, &type_values[i], err)) return .ERROR_API;
    }
    var f: v2.duckdb_v2_factory_handle = undefined;
    const got = v2.duckdb_v2_context_get_factory(ctx, &f, err);
    if (got != .ERROR_NONE) return got;
    return v2.duckdb_v2_factory_create_type_from_id(f, type_id, names.ptr, type_values.ptr, names.len, out_type, err);
}

// --- More `[]const u8`-taking wrappers over raw `duckdb_v2_str`-based calls -----------------------
//
// DuckDB's own C API v2 feedback discussion (duckdb/duckdb#27525) states a plan to remove
// `duckdb_v2_str` entirely before stabilization, replacing every function that takes one with a
// plain `(ptr, len)` pair — "a large, but almost entirely mechanical change." These wrappers (plus
// `createTypeFromText`/`createVarcharValue`/`createBlobValue`/`setDocs` above, which already did
// this for their own calls) mean that migration touches ~9 function bodies here, not every call
// site across the codebase: when the signature changes, only `str(text)` + `&view` below becomes
// `text.ptr, text.len` at each of these, once.

/// Sets an error's text. Unlike most calls here, `duckdb_v2_error_info_set_text` takes no `err`
/// of its own — there is nothing else that can fail about setting a string into a handle the
/// caller already has.
pub fn setErrorText(info: v2.duckdb_v2_error_info_handle, text: []const u8) v2.DUCKDB_V2_ERROR {
    const view = str(text);
    return v2.duckdb_v2_error_info_set_text(info, &view);
}

/// Opens a file at `file_path` through a file system handle, with already-configured `options`.
pub fn fileSystemOpen(
    file_system: v2.duckdb_v2_file_system_handle,
    file_path: []const u8,
    options: v2.duckdb_v2_file_open_options_handle,
    out_file: *v2.duckdb_v2_file_handle,
    err: ?*v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const view = str(file_path);
    return v2.duckdb_v2_file_system_open(file_system, &view, options, out_file, err);
}

/// Sets a macro function's SQL body.
pub fn setMacroBody(function: v2.duckdb_v2_macro_function_handle, body: []const u8, err: ?*v2.duckdb_v2_error_info_handle) v2.DUCKDB_V2_ERROR {
    const view = str(body);
    return v2.duckdb_v2_macro_function_set_body(function, &view, err);
}

/// Attaches a database at `path` to `instance`, under `name` if given (DuckDB derives one from
/// `path` otherwise).
pub fn instanceAttach(
    instance: v2.duckdb_v2_instance_handle,
    name: ?[]const u8,
    path: []const u8,
    options: ?v2.duckdb_v2_attach_options_handle,
    make_default: bool,
    err: ?*v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const path_view = str(path);
    if (name) |n| {
        const name_view = str(n);
        return v2.duckdb_v2_instance_attach(instance, &name_view, &path_view, options, make_default, err);
    }
    return v2.duckdb_v2_instance_attach(instance, null, &path_view, options, make_default, err);
}

/// Sets one `key = setting` pair of attach options (`setting` is the textual form a quoted SQL
/// literal would carry, e.g. `"true"`, not a typed value).
pub fn attachOptionsSet(
    options: v2.duckdb_v2_attach_options_handle,
    key: []const u8,
    setting: []const u8,
    err: ?*v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const key_view = str(key);
    const setting_view = str(setting);
    return v2.duckdb_v2_attach_options_set(options, &key_view, &setting_view, err);
}

/// Writes a log entry through a context, tagged with `log_type`. Succeeds whether or not the
/// entry was actually recorded (that depends on the active log configuration).
pub fn contextLog(
    ctx: v2.duckdb_v2_context_handle,
    level: v2.DUCKDB_V2_LOG_LEVEL,
    log_type: []const u8,
    message: []const u8,
    err: ?*v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const type_view = str(log_type);
    const message_view = str(message);
    return v2.duckdb_v2_context_log(ctx, level, &type_view, &message_view, err);
}

/// Parses `text` as a (possibly multi-part, possibly quoted) qualified name.
pub fn qnameParse(text: []const u8, out_name: *v2.duckdb_v2_qname_handle, err: ?*v2.duckdb_v2_error_info_handle) v2.DUCKDB_V2_ERROR {
    const view = str(text);
    return v2.duckdb_v2_qname_parse(&view, out_name, err);
}

/// Tokenizes `sql` (or an empty script, if not given) over `conn`.
pub fn tokenizeSql(conn: v2.duckdb_v2_connection_handle, sql: ?[]const u8, out_iterator: *v2.duckdb_v2_token_iterator_handle, err: ?*v2.duckdb_v2_error_info_handle) v2.DUCKDB_V2_ERROR {
    const view = str(sql orelse "");
    return v2.duckdb_v2_tokenize_sql(conn, &view, out_iterator, err);
}

/// Whether `text` is valid UTF-8.
pub fn validateUtf8(text: []const u8, err: ?*v2.duckdb_v2_error_info_handle) bool {
    const view = str(text);
    return v2.duckdb_v2_validate_utf8(&view, err) == .ERROR_NONE;
}

test "str views the bytes it is given" {
    const s = str("abc");
    try std.testing.expectEqual(@as(u64, 3), s.len);
    try std.testing.expectEqualStrings("abc", s.ptr.?[0..s.len]);
}

/// A VARCHAR (or BLOB) value holding `text`, for writing straight into a result vector. Text of up to
/// `DUCKDB_V2_BYTES_INLINE_LENGTH` bytes is stored inline; longer text is copied into `arena`, which
/// the vector owns, so it lives as long as the result does.
///
/// The value starts zeroed: DuckDB compares, hashes and sorts an inline string by all of its bytes, so
/// the ones after the text must be defined (zero, as DuckDB's own constructor leaves them).
pub fn makeBytesValue(arena: v2.duckdb_v2_arena_handle, text: []const u8, err: *v2.duckdb_v2_error_info_handle) !v2.duckdb_v2_bytes {
    // Both `.length` fields below are `u32` (duckdb_v2_types.zig's `duckdb_v2_bytes`): checked
    // explicitly, not just cast, so text past 4 GiB fails loudly instead of silently
    // truncating — the same check `duckdb-neo`'s own `DuckDBBytes::new` (Rust) makes before
    // its own encode, found while comparing against it directly, not assumed needed.
    if (text.len > std.math.maxInt(u32)) return error.TextTooLong;
    var b = std.mem.zeroes(v2.duckdb_v2_bytes);
    if (text.len <= v2.DUCKDB_V2_BYTES_INLINE_LENGTH) {
        b.value.inlined.length = @intCast(text.len);
        @memcpy(b.value.inlined.inlined[0..text.len], text);
    } else {
        var out_ptr: [*]u8 = undefined;
        try ok(v2.duckdb_v2_arena_allocate(arena, text.len, &out_ptr, err), error.DuckDbError);
        @memcpy(out_ptr[0..text.len], text);
        b.value.pointer.length = @intCast(text.len);
        const prefix_len = @min(text.len, 4);
        @memcpy(b.value.pointer.prefix[0..prefix_len], text[0..prefix_len]);
        if (prefix_len < 4) @memset(b.value.pointer.prefix[prefix_len..4], 0);
        b.value.pointer.ptr = out_ptr;
    }
    return b;
}

test "isValid: no mask means every row is valid" {
    try std.testing.expect(isValid(null, 0));
    try std.testing.expect(isValid(null, 1000));
}

test "isValid reads the bit of the row, across words" {
    // Rows 0, 63 and 64 valid, 1 and 65 not.
    const mask = [_]u64{ (1 << 0) | (1 << 63), 1 << 0 };
    try std.testing.expect(isValid(&mask, 0));
    try std.testing.expect(!isValid(&mask, 1));
    try std.testing.expect(isValid(&mask, 63));
    try std.testing.expect(isValid(&mask, 64));
    try std.testing.expect(!isValid(&mask, 65));
}

test "bytesSlice reads inlined bytes" {
    var b: v2.duckdb_v2_bytes = std.mem.zeroes(v2.duckdb_v2_bytes);
    b.value.inlined.length = 3;
    @memcpy(b.value.inlined.inlined[0..3], "abc");
    try std.testing.expectEqualStrings("abc", bytesSlice(&b));
}

test "bytesSlice follows the pointer of longer bytes" {
    const text = "more than twelve bytes";
    var b: v2.duckdb_v2_bytes = std.mem.zeroes(v2.duckdb_v2_bytes);
    b.value.pointer.length = text.len;
    b.value.pointer.ptr = @constCast(text.ptr);
    try std.testing.expectEqualStrings(text, bytesSlice(&b));
}

test "bytesSlice of long bytes with no pointer is empty rather than a crash" {
    var b: v2.duckdb_v2_bytes = std.mem.zeroes(v2.duckdb_v2_bytes);
    b.value.pointer.length = 20;
    try std.testing.expectEqualStrings("", bytesSlice(&b));
}

var fake_arena: [64]u8 = undefined;

fn fakeArenaAllocate(
    arena: v2.duckdb_v2_arena_handle,
    byte_len: u64,
    out_ptr: *[*]u8,
    err: ?*v2.duckdb_v2_error_info_handle,
) callconv(.c) v2.DUCKDB_V2_ERROR {
    _ = arena;
    _ = err;
    if (byte_len > fake_arena.len) return .ERROR_RESOURCE_OUT_OF_MEMORY;
    out_ptr.* = &fake_arena;
    return .ERROR_NONE;
}

test "makeBytesValue stores short text inline and reads it back" {
    var err: v2.duckdb_v2_error_info_handle = undefined;
    const arena: v2.duckdb_v2_arena_handle = @ptrFromInt(0x10);
    const b = try makeBytesValue(arena, "short", &err);
    try std.testing.expectEqualStrings("short", bytesSlice(&b));
}

test "makeBytesValue zeroes the bytes after short text" {
    var err: v2.duckdb_v2_error_info_handle = undefined;
    const arena: v2.duckdb_v2_arena_handle = @ptrFromInt(0x10);
    const b = try makeBytesValue(arena, "ab", &err);
    const zeros: [10]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zeros, b.value.inlined.inlined[2..]);
}

test "makeBytesValue copies longer text into the arena, with its first four bytes as the prefix" {
    const saved = v2.api;
    defer v2.api = saved;
    v2.api.duckdb_v2_arena_allocate = &fakeArenaAllocate;

    var err: v2.duckdb_v2_error_info_handle = undefined;
    const arena: v2.duckdb_v2_arena_handle = @ptrFromInt(0x10);
    const text = "a string longer than twelve bytes";
    const b = try makeBytesValue(arena, text, &err);
    try std.testing.expectEqualStrings(text, bytesSlice(&b));
    try std.testing.expectEqualStrings("a st", &b.value.pointer.prefix);
    try std.testing.expect(@intFromPtr(b.value.pointer.ptr.?) == @intFromPtr(&fake_arena));
}

test "makeBytesValue reports a failed arena allocation" {
    const saved = v2.api;
    defer v2.api = saved;
    v2.api.duckdb_v2_arena_allocate = &fakeArenaAllocate;

    var err: v2.duckdb_v2_error_info_handle = undefined;
    const arena: v2.duckdb_v2_arena_handle = @ptrFromInt(0x10);
    const too_long: [100]u8 = @splat('x');
    try std.testing.expectError(error.DuckDbError, makeBytesValue(arena, &too_long, &err));
}

test "init fails cleanly when get_api is null" {
    const input: v2.duckdb_v2_extension_input = .{
        .get_api = null,
        .extension = undefined,
        .context = undefined,
        .err = undefined,
    };
    try std.testing.expect(!init(&input, "v2.0.0"));
}
