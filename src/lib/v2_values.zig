///! The value types a user function of the comptime frameworks (`comptime_scalar_v2`,
///! `comptime_table_v2`, `comptime_cast_v2`, `comptime_aggregate_v2`, `comptime_appender_v2`) takes or
///! returns where a plain Zig type would be ambiguous: DATE/TIME/TIMESTAMP/INTERVAL, BLOB and
///! DECIMAL(width, scale). They have no DuckDB calls of their own.
const std = @import("std");
const v2 = @import("duckdb_v2_dynamic");

// ─── DATE/TIME/TIMESTAMP/INTERVAL: fixed-width, no Value boxing needed ──────
//
// Unlike VARCHAR/BLOB/VARIANT, these are plain fixed-width vector storage
// (the C API has no `duckdb_v2_date_t`/`duckdb_v2_time_t`/
// `duckdb_v2_timestamp_t` struct at all — DATE is a raw `int32_t` (days
// since 1970-01-01), TIME/TIMESTAMP a raw `int64_t` (micros since midnight/
// epoch), same physical layout as INTEGER/BIGINT), so the comptime scalar
// framework's existing direct-buffer read/write path handles them with no
// new exec-path code — only a distinct Zig type is needed so
// `duckdbV2TypeId` can tell them apart from plain `i32`/`i64`. A
// non-exhaustive enum wrapping the same backing int is a zero-cost way to
// get a distinct type with identical layout.
pub const Date = enum(i32) { _ };
pub const Time = enum(i64) { _ };
pub const Timestamp = enum(i64) { _ };

/// INTERVAL's vector storage is the raw `duckdb_v2_interval_t` struct
/// (months/days/micros) inline, same reasoning as DATE/TIME/TIMESTAMP
/// above — a direct type alias (not a wrapper) since the C struct is
/// already a distinct Zig type.
pub const Interval = v2.duckdb_v2_interval_t;

/// BLOB marker type for `comptime_scalar_v2`: wraps a byte slice, decoded/
/// encoded exactly like VARCHAR's `BytesValue`/boxed-`Value` machinery, but
/// a distinct Zig type so it maps to SQL BLOB, not VARCHAR. NOTE: this is a
/// Zig `struct`, so framework code that distinguishes "is this a STRUCT
/// argument" from "is this some other framework-provided marker type" must
/// special-case `Blob` explicitly (see `comptime_scalar_v2.zig`'s
/// `isStructType`) — it must never be treated as a one-field SQL STRUCT.
pub const Blob = struct { bytes: []const u8 };

/// The storage int DECIMAL(width, _) uses in vector storage, per
/// `vector_get_view`'s own doc comment (a documented contract, not an
/// inference): width <= 4 -> int16, <= 9 -> int32, <= 18 -> int64,
/// <= 38 -> int128, boundaries inclusive.
pub fn DecimalStorageInt(comptime width: u8) type {
    return if (width <= 4) i16 else if (width <= 9) i32 else if (width <= 18) i64 else i128;
}

/// DECIMAL(width, scale) marker type for `comptime_scalar_v2`: a one-field
/// wrapper around the storage int the width selects (see
/// `DecimalStorageInt`), so the vector is read/written as that raw int
/// directly — DECIMAL is a typed leaf array in vector storage, same as any
/// numeric type, once the right width is picked, per the same doc comment.
/// `raw` is the value scaled by 10^scale (e.g. `10.5` as `DECIMAL(8, 3)`
/// is stored as `10500`), matching `value_create_decimal`'s own
/// convention. NOTE: this is a Zig `struct`, so framework code
/// distinguishing "is this a STRUCT argument" from "is this some other
/// framework-provided marker type" must special-case it explicitly (see
/// `comptime_scalar_v2.zig`'s `isStructType`), same reasoning as `Blob`.
pub fn Decimal(comptime width: u8, comptime scale: u8) type {
    return struct {
        pub const v2_decimal_width: u8 = width;
        pub const v2_decimal_scale: u8 = scale;
        pub const Raw = DecimalStorageInt(width);
        raw: Raw,
    };
}

test "DecimalStorageInt picks the storage int by width, boundaries inclusive" {
    try std.testing.expect(DecimalStorageInt(1) == i16);
    try std.testing.expect(DecimalStorageInt(4) == i16);
    try std.testing.expect(DecimalStorageInt(5) == i32);
    try std.testing.expect(DecimalStorageInt(9) == i32);
    try std.testing.expect(DecimalStorageInt(10) == i64);
    try std.testing.expect(DecimalStorageInt(18) == i64);
    try std.testing.expect(DecimalStorageInt(19) == i128);
    try std.testing.expect(DecimalStorageInt(38) == i128);
}

test "Decimal carries its width and scale and the storage int" {
    const D = Decimal(10, 2);
    try std.testing.expectEqual(@as(u8, 10), D.v2_decimal_width);
    try std.testing.expectEqual(@as(u8, 2), D.v2_decimal_scale);
    try std.testing.expect(D.Raw == i64);
    try std.testing.expectEqual(@sizeOf(i64), @sizeOf(D));
}

test "Date, Time and Timestamp are distinct types with the layout of their backing int" {
    try std.testing.expect(Date != i32 and Time != i64 and Timestamp != i64 and Time != Timestamp);
    try std.testing.expectEqual(@sizeOf(i32), @sizeOf(Date));
    try std.testing.expectEqual(@sizeOf(i64), @sizeOf(Timestamp));
}

test "Interval is the C struct of months, days and micros" {
    const iv: Interval = .{ .months = 1, .days = 2, .micros = 3 };
    try std.testing.expectEqual(@as(i32, 1), iv.months);
    try std.testing.expectEqual(@as(i32, 2), iv.days);
    try std.testing.expectEqual(@as(i64, 3), iv.micros);
}
