///! Scalar function: tp_line_impl(data DOUBLE[], height DOUBLE) -> VARCHAR
///!
///! Renders a LIST(DOUBLE) as a multi-line ASCII line graph string.
///! The SQL-level function tp_line wraps this with named params/defaults:
///!
///!   tp_line([1.0, 3.0, 2.0, 4.0, 2.0]) → multi-line ASCII graph
const std = @import("std");
const db = @import("../lib/duckdb.zig");
const ag = @import("../lib/asciigraph/asciigraph.zig");

/// Render a slice of f64 values as an ASCII line graph.
/// Caller owns the returned slice (allocated with allocator).
/// Returns an empty slice for empty input.
/// Truncates series to 255 points (the u8 column limit of the library).
pub fn renderLine(allocator: std.mem.Allocator, values: []const f64, height: f64) ![]u8 {
    if (values.len == 0) return allocator.alloc(u8, 0);
    const cols: u8 = if (values.len > 255) 255 else @intCast(values.len);
    // Normalise non-finite values: infinity is unplottable; treat as a gap (NaN).
    const safe = try allocator.alloc(f64, cols);
    for (0..cols) |i| {
        safe[i] = if (std.math.isInf(values[i])) std.math.nan(f64) else values[i];
    }
    // Cap height so the scaled coordinate never overflows i32 in the library.
    const safe_height = @min(@max(height, 1.0), 100.0);
    var aw = std.Io.Writer.Allocating.init(allocator);
    const graph = try ag.init(.{
        .allocator = allocator,
        .out = &aw.writer,
        .config = .{ .rows = 1, .columns = cols, .height = safe_height, .no_color = true },
    });
    const matrix = try graph.prepareMatrix(1, cols);
    for (0..cols) |i| {
        matrix[0][i] = safe[i];
    }
    try graph.PlotGraph(matrix);
    var result = aw.toArrayList();
    return result.toOwnedSlice(allocator);
}

/// Vectorized execute callback for tp_line_impl.
pub fn tpLineExec(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
    _ = info;
    // SAFETY: DuckDB vectors are capped at STANDARD_VECTOR_SIZE (2048), far under `usize`'s
    // range even on 32-bit targets (wasm32).
    const chunk_size: usize = @intCast(db.dataChunkGetSize(input));

    const list_vec = db.dataChunkGetVector(input, 0);
    const height_vec = db.dataChunkGetVector(input, 1);

    // SAFETY: DuckDB guarantees list vector data is [*]duckdb_list_entry.
    const list_entries: [*]db.ListEntry = @ptrCast(@alignCast(db.vectorGetData(list_vec)));
    // SAFETY: DuckDB guarantees height vector data is [*]f64 for DOUBLE.
    const height_data: [*]f64 = @ptrCast(@alignCast(db.vectorGetData(height_vec)));

    const child_vec = db.listVectorGetChild(list_vec);
    // SAFETY: child vector holds the flat DOUBLE values.
    const child_data: [*]f64 = @ptrCast(@alignCast(db.vectorGetData(child_vec)));
    const child_validity = db.vectorGetValidity(child_vec);

    const list_validity = db.vectorGetValidity(list_vec);
    const height_validity = db.vectorGetValidity(height_vec);
    const has_nulls = list_validity != null or height_validity != null;

    if (has_nulls) {
        db.vectorEnsureValidityWritable(output);
        const out_v = db.vectorGetValidity(output).?;
        for (0..chunk_size) |row| {
            if (db.validityRowIsValid(list_validity, row) and
                db.validityRowIsValid(height_validity, row))
            {
                writeRow(list_entries, child_data, child_validity, height_data, row, output);
            } else {
                db.validitySetRowInvalid(out_v, row);
            }
        }
    } else {
        for (0..chunk_size) |row| {
            writeRow(list_entries, child_data, child_validity, height_data, row, output);
        }
    }
}

fn writeRow(
    list_entries: [*]db.ListEntry,
    child_data: [*]f64,
    child_validity: ?[*]u64,
    height_data: [*]f64,
    row: usize,
    output: db.Vector,
) void {
    const entry = list_entries[row];
    if (entry.length == 0) {
        db.vectorAssignStringElement(output, row, "");
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // SAFETY: `entry.length`/`entry.offset` are idx_t (u64); list entries are capped at 255
    // values here regardless, far under `usize`'s range even on 32-bit targets (wasm32).
    const offset: usize = @intCast(entry.offset);
    const len: usize = @intCast(@min(entry.length, 255));
    const values = allocator.alloc(f64, len) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };
    for (0..len) |i| {
        const ci = offset + i;
        values[i] = if (db.validityRowIsValid(child_validity, ci)) child_data[ci] else std.math.nan(f64);
    }

    const result = renderLine(allocator, values, height_data[row]) catch {
        db.vectorAssignStringElement(output, row, "");
        return;
    };
    db.vectorAssignStringElementLen(output, row, result.ptr, result.len);
}

/// Register tp_line_impl (scalar) and tp_line (SQL macro with named params/defaults).
pub fn register(conn: db.Connection) !void {
    const function = db.createScalarFunction();
    defer db.destroyScalarFunction(@constCast(&function));

    db.scalarFunctionSetName(function, "tp_line_impl");

    var double_type = db.createLogicalType(db.c.DUCKDB_TYPE_DOUBLE);
    defer db.destroyLogicalType(&double_type);
    var list_type = db.createListType(double_type);
    defer db.destroyLogicalType(&list_type);
    var varchar_type = db.createLogicalType(db.c.DUCKDB_TYPE_VARCHAR);
    defer db.destroyLogicalType(&varchar_type);

    db.scalarFunctionAddParameter(function, list_type);
    db.scalarFunctionAddParameter(function, double_type);
    db.scalarFunctionSetReturnType(function, varchar_type);
    db.scalarFunctionSetFunction(function, &tpLineExec);

    if (db.registerScalarFunction(conn, function) == db.DuckDBError) {
        return error.FailedToRegisterFunction;
    }

    var result: db.Result = undefined;
    defer db.destroyResult(&result);
    if (db.query(
        conn,
        "CREATE OR REPLACE MACRO tp_line(data, height := 10.0) AS tp_line_impl(data, height)",
        &result,
    ) == db.DuckDBError) {
        return error.FailedToRegisterMacro;
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "renderLine: non-empty output for valid series" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]f64{ 1.0, 2.0, 3.0, 2.0, 1.0 };
    const result = try renderLine(arena.allocator(), &values, 5.0);
    try std.testing.expect(result.len > 0);
    // y-axis tick character is always present in non-empty graphs
    try std.testing.expect(std.mem.indexOf(u8, result, "┤") != null);
}

test "renderLine: empty input returns empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try renderLine(arena.allocator(), &[_]f64{}, 5.0);
    try std.testing.expectEqualStrings("", result);
}

test "renderLine: flat series renders without panic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]f64{ 5.0, 5.0, 5.0, 5.0, 5.0 };
    const result = try renderLine(arena.allocator(), &values, 5.0);
    try std.testing.expect(result.len > 0);
}

test "renderLine: series longer than 255 is truncated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var values: [300]f64 = undefined;
    for (&values, 0..) |*v, i| v.* = @floatFromInt(i % 10);
    const result = try renderLine(arena.allocator(), &values, 10.0);
    try std.testing.expect(result.len > 0);
}

test "renderLine: +Infinity treated as gap (no panic)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]f64{ 1.0, std.math.inf(f64), 2.0 };
    const result = try renderLine(arena.allocator(), &values, 10.0);
    try std.testing.expect(result.len > 0);
}

test "renderLine: all-NaN values (no panic)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nan = std.math.nan(f64);
    const values = [_]f64{ nan, nan, nan };
    const result = try renderLine(arena.allocator(), &values, 10.0);
    _ = result; // length may be 0 or non-zero; no panic is the requirement
}

test "renderLine: all-negative values (no panic)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]f64{ -1e15, -2e15, -1.5e15 };
    const result = try renderLine(arena.allocator(), &values, 10.0);
    try std.testing.expect(result.len > 0);
}

test "renderLine: large height clamped (no i32 overflow)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]f64{ 0.0, 1.0, 0.5 };
    const result = try renderLine(arena.allocator(), &values, 200.0);
    try std.testing.expect(result.len > 0);
}
