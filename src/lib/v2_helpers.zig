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
