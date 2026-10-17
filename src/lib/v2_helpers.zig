///! Small helpers over the generated v2 types (`duckdb_v2_dynamic`) that more than one function
///! module needs.
const std = @import("std");
const v2 = @import("duckdb_v2_dynamic");

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

// --- Slice forms of calls that take a pointer and a count, or a `str` ----------------------------

/// A logical type that needs no parameters, by id.
pub fn createTypeFromId(
    ctx: v2.duckdb_v2_context_handle,
    type_id: v2.DUCKDB_V2_LOGICAL_TYPE_ID,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    return v2.duckdb_v2_context_create_type_from_id(ctx, type_id, null, null, 0, out_type, err);
}

/// A logical type from its SQL text, e.g. "VARIANT" or "ENUM('a', 'b')".
pub fn createTypeFromText(
    ctx: v2.duckdb_v2_context_handle,
    text: []const u8,
    out_type: *v2.duckdb_v2_logical_type_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const view = str(text);
    return v2.duckdb_v2_context_create_type_from_text(ctx, &view, out_type, err);
}

/// A VARCHAR value; the text is copied.
pub fn createVarcharValue(
    ctx: v2.duckdb_v2_context_handle,
    text: []const u8,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const view = str(text);
    return v2.duckdb_v2_value_create_varchar_with_context(ctx, &view, out_value, err);
}

/// A BLOB value; the bytes are copied.
pub fn createBlobValue(
    ctx: v2.duckdb_v2_context_handle,
    bytes: []const u8,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    const view = str(bytes);
    return v2.duckdb_v2_value_create_blob_with_context(ctx, &view, out_value, err);
}

/// A LIST value of `children`, which are copied.
pub fn createListValue(
    ctx: v2.duckdb_v2_context_handle,
    child_type: v2.duckdb_v2_logical_type_handle,
    children: []const v2.duckdb_v2_value_handle,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    return v2.duckdb_v2_value_create_list_with_context(ctx, child_type, children.ptr, children.len, out_value, err);
}

/// An ARRAY value of `children`, which are copied.
pub fn createArrayValue(
    ctx: v2.duckdb_v2_context_handle,
    child_type: v2.duckdb_v2_logical_type_handle,
    children: []const v2.duckdb_v2_value_handle,
    out_value: *v2.duckdb_v2_value_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    return v2.duckdb_v2_value_create_array_with_context(ctx, child_type, children.ptr, children.len, out_value, err);
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
    return v2.duckdb_v2_value_create_map_with_context(ctx, key_type, value_type, keys.ptr, values.ptr, keys.len, out_value, err);
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
    return v2.duckdb_v2_value_create_struct_with_context(ctx, names.ptr, children.ptr, names.len, out_value, err);
}

/// A column data collection with one column per entry of `types`.
pub fn createColumnDataCollection(
    ctx: v2.duckdb_v2_context_handle,
    types: []const v2.duckdb_v2_logical_type_handle,
    out_collection: *v2.duckdb_v2_column_data_collection_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    return v2.duckdb_v2_column_data_collection_create_with_context(ctx, types.ptr, types.len, out_collection, err);
}

/// A data chunk with one column per entry of `types`.
pub fn createDataChunk(
    ctx: v2.duckdb_v2_context_handle,
    types: []const v2.duckdb_v2_logical_type_handle,
    out_chunk: *v2.duckdb_v2_data_chunk_handle,
    err: *v2.duckdb_v2_error_info_handle,
) v2.DUCKDB_V2_ERROR {
    return v2.duckdb_v2_data_chunk_create_with_context(ctx, types.ptr, types.len, out_chunk, err);
}

// --- Parametrised logical types -----------------------------------------------------------------
//
// LIST, ARRAY, MAP, STRUCT, UNION and DECIMAL types are created by one call, `context_create_type_from_id`,
// whose parameters are VALUES: a type goes in boxed as a value of that type, a size or a width as an
// integer value. These helpers do the boxing. A failure of the boxing is reported as ERROR_API, with
// the details in `err`.

fn boxType(ctx: v2.duckdb_v2_context_handle, ty: v2.duckdb_v2_logical_type_handle, out: *v2.duckdb_v2_value_handle, err: *v2.duckdb_v2_error_info_handle) bool {
    return v2.duckdb_v2_value_create_type_with_context(ctx, ty, out, err) == .ERROR_NONE;
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
    return v2.duckdb_v2_context_create_type_from_id(ctx, .LOGICAL_TYPE_ID_LIST, null, &params, params.len, out_type, err);
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
    if (v2.duckdb_v2_value_create_bigint_with_context(ctx, size, &size_value, err) != .ERROR_NONE) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&size_value);
    const params = [_]v2.duckdb_v2_value_handle{ child_value, size_value };
    return v2.duckdb_v2_context_create_type_from_id(ctx, .LOGICAL_TYPE_ID_ARRAY, null, &params, params.len, out_type, err);
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
    return v2.duckdb_v2_context_create_type_from_id(ctx, .LOGICAL_TYPE_ID_MAP, null, &params, params.len, out_type, err);
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
    if (v2.duckdb_v2_value_create_utinyint_with_context(ctx, width, &width_value, err) != .ERROR_NONE) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&width_value);
    var scale_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_utinyint_with_context(ctx, scale, &scale_value, err) != .ERROR_NONE) return .ERROR_API;
    defer _ = v2.duckdb_v2_value_destroy(&scale_value);
    const params = [_]v2.duckdb_v2_value_handle{ width_value, scale_value };
    return v2.duckdb_v2_context_create_type_from_id(ctx, .LOGICAL_TYPE_ID_DECIMAL, null, &params, params.len, out_type, err);
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
    return v2.duckdb_v2_context_create_type_from_id(ctx, type_id, names.ptr, type_values.ptr, names.len, out_type, err);
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
    var b = std.mem.zeroes(v2.duckdb_v2_bytes);
    if (text.len <= v2.DUCKDB_V2_BYTES_INLINE_LENGTH) {
        b.value.inlined.length = @intCast(text.len);
        @memcpy(b.value.inlined.inlined[0..text.len], text);
    } else {
        var out_ptr: [*]u8 = undefined;
        if (v2.duckdb_v2_arena_allocate(arena, text.len, &out_ptr, err) != .ERROR_NONE) return error.DuckDbError;
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
    try std.testing.expect(!v2.init(&input, "v2.0.0"));
}
