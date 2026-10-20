///! Scalar function: tp_bar_impl(value DOUBLE, on VARCHAR, off VARCHAR, width BIGINT) -> VARCHAR
///!
///! Generates a text progress bar. The SQL-level function tp_bar wraps this
///! with named parameters and defaults via a macro registered at init time:
///!
///!   tp_bar(0.7, "on" := '█', "off" := '░', width := 15) → '███████████░░░░'
const std = @import("std");
const db = @import("../lib/duckdb.zig");

/// Build a text progress bar string.
///
/// value is clamped to [0.0, 1.0]. width is the character count.
/// on and off are the fill/empty glyphs (may be multi-byte UTF-8).
/// Caller owns the returned slice.
pub fn buildBar(
    allocator: std.mem.Allocator,
    value: f64,
    on: []const u8,
    off: []const u8,
    width: i64,
) ![]u8 {
    if (width <= 0 or on.len == 0 or off.len == 0) return allocator.alloc(u8, 0);
    // Cap width so filled*on.len + empty*off.len always fits in the 4096-byte FixedBufferAllocator.
    const max_w: i64 = @intCast(4096 / @max(on.len, off.len));
    const w: usize = @intCast(@min(width, max_w));
    // NaN is unrepresentable as a fraction; treat as 0 (empty bar) rather than silently becoming 1.
    if (std.math.isNan(value)) return allocator.alloc(u8, 0);
    const clamped = std.math.clamp(value, 0.0, 1.0);
    const filled: usize = @intFromFloat(@round(clamped * @as(f64, @floatFromInt(w))));
    const empty = w - filled;
    const buf = try allocator.alloc(u8, filled * on.len + empty * off.len);
    var pos: usize = 0;
    for (0..filled) |_| {
        @memcpy(buf[pos..][0..on.len], on);
        pos += on.len;
    }
    for (0..empty) |_| {
        @memcpy(buf[pos..][0..off.len], off);
        pos += off.len;
    }
    return buf;
}

/// Extract a []const u8 slice from a DuckDB inline/pointer string.
/// Vectorized execute callback for tp_bar_impl.
pub fn tpBarExec(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
    _ = info;
    // SAFETY: DuckDB vectors are capped at STANDARD_VECTOR_SIZE (2048), far under `usize`'s
    // range even on 32-bit targets (wasm32).
    const chunk_size: usize = @intCast(db.dataChunkGetSize(input));

    const val_vec = db.dataChunkGetVector(input, 0);
    const on_vec = db.dataChunkGetVector(input, 1);
    const off_vec = db.dataChunkGetVector(input, 2);
    const width_vec = db.dataChunkGetVector(input, 3);

    // SAFETY: DuckDB guarantees vector data types match registered parameter types.
    const val_data: [*]f64 = @ptrCast(@alignCast(db.vectorGetData(val_vec)));
    const on_data: [*]db.StringT = @ptrCast(@alignCast(db.vectorGetData(on_vec)));
    const off_data: [*]db.StringT = @ptrCast(@alignCast(db.vectorGetData(off_vec)));
    const width_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(width_vec)));

    const val_v = db.vectorGetValidity(val_vec);
    const on_v = db.vectorGetValidity(on_vec);
    const off_v = db.vectorGetValidity(off_vec);
    const width_v = db.vectorGetValidity(width_vec);
    const has_nulls = val_v != null or on_v != null or off_v != null or width_v != null;

    if (has_nulls) {
        db.vectorEnsureValidityWritable(output);
        const out_v = db.vectorGetValidity(output).?;
        for (0..chunk_size) |row| {
            if (db.validityRowIsValid(val_v, row) and
                db.validityRowIsValid(on_v, row) and
                db.validityRowIsValid(off_v, row) and
                db.validityRowIsValid(width_v, row))
            {
                writeRow(val_data, on_data, off_data, width_data, row, output);
            } else {
                db.validitySetRowInvalid(out_v, row);
            }
        }
    } else {
        for (0..chunk_size) |row| {
            writeRow(val_data, on_data, off_data, width_data, row, output);
        }
    }
}

fn writeRow(
    val_data: [*]f64,
    on_data: [*]db.StringT,
    off_data: [*]db.StringT,
    width_data: [*]i64,
    row: usize,
    output: db.Vector,
) void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = buildBar(
        fba.allocator(),
        val_data[row],
        db.stringSlice(&on_data[row]),
        db.stringSlice(&off_data[row]),
        width_data[row],
    ) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };
    db.vectorAssignStringElementLen(output, row, result.ptr, result.len);
}

/// Register tp_bar_impl (scalar) and tp_bar (SQL macro with named params/defaults).
pub fn register(conn: db.Connection) !void {
    const function = db.createScalarFunction();
    defer db.destroyScalarFunction(@constCast(&function));

    db.scalarFunctionSetName(function, "tp_bar_impl");

    var double_type = db.createLogicalType(db.c.DUCKDB_TYPE_DOUBLE);
    defer db.destroyLogicalType(&double_type);
    var varchar_type = db.createLogicalType(db.c.DUCKDB_TYPE_VARCHAR);
    defer db.destroyLogicalType(&varchar_type);
    var bigint_type = db.createLogicalType(db.c.DUCKDB_TYPE_BIGINT);
    defer db.destroyLogicalType(&bigint_type);

    db.scalarFunctionAddParameter(function, double_type);
    db.scalarFunctionAddParameter(function, varchar_type);
    db.scalarFunctionAddParameter(function, varchar_type);
    db.scalarFunctionAddParameter(function, bigint_type);
    db.scalarFunctionSetReturnType(function, varchar_type);
    db.scalarFunctionSetFunction(function, &tpBarExec);

    if (db.registerScalarFunction(conn, function) == db.DuckDBError) {
        return error.FailedToRegisterFunction;
    }

    // SQL macro provides named parameters and defaults over tp_bar_impl.
    var result: db.Result = undefined;
    defer db.destroyResult(&result);
    if (db.query(
        conn,
        "CREATE OR REPLACE MACRO tp_bar(value, \"on\" := '\xe2\x96\x88', \"off\" := '\xe2\x96\x91', width := 15) AS tp_bar_impl(value, \"on\", \"off\", width)",
        &result,
    ) == db.DuckDBError) {
        return error.FailedToRegisterMacro;
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "buildBar: 70% fill width 15 → 11 on + 4 off" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), 0.7, "X", ".", 15);
    try std.testing.expectEqualStrings("XXXXXXXXXXX....", result);
}

test "buildBar: 0.0 → all empty" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), 0.0, "X", ".", 5);
    try std.testing.expectEqualStrings(".....", result);
}

test "buildBar: 1.0 → all filled" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), 1.0, "X", ".", 5);
    try std.testing.expectEqualStrings("XXXXX", result);
}

test "buildBar: value > 1.0 clamped to full bar" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), 2.0, "X", ".", 4);
    try std.testing.expectEqualStrings("XXXX", result);
}

test "buildBar: value < 0.0 clamped to empty bar" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), -1.0, "X", ".", 4);
    try std.testing.expectEqualStrings("....", result);
}

test "buildBar: multi-byte UTF-8 glyphs" {
    // '█' = 3 bytes, '░' = 3 bytes; 11×3 + 4×3 = 45 bytes total
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), 0.7, "█", "░", 15);
    try std.testing.expectEqualStrings("███████████░░░░", result);
}

test "buildBar: width 0 → empty string" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), 0.5, "X", ".", 0);
    try std.testing.expectEqualStrings("", result);
}

test "buildBar: NaN value → empty string (no panic)" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), std.math.nan(f64), "X", ".", 10);
    try std.testing.expectEqualStrings("", result);
}

test "buildBar: +Inf value clamped to full bar (no panic)" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), std.math.inf(f64), "X", ".", 4);
    try std.testing.expectEqualStrings("XXXX", result);
}

test "buildBar: maxInt(i64) width capped, no overflow" {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const result = try buildBar(fba.allocator(), 0.5, "X", ".", std.math.maxInt(i64));
    try std.testing.expect(result.len > 0);
}
