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
