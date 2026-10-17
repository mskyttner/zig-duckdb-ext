///! Comptime scalar function: ct_add_numbers(a BIGINT, b BIGINT) -> BIGINT
///!
///! v2 port of ct_add_numbers.zig — same one-line per-row function, now
///! generated and registered by comptime_scalar_v2 instead of comptime_scalar.
///! Uses `FunctionNamed` for real parameter names ("a", "b") instead of
///! comptime_scalar_v2's default `a0`/`a1` synthesis — confirmed live this
///! is what was showing up in `duckdb_functions()` before this fix (see
///! docs/v2-migration-plan.md's "Function parameter naming & catalog
///! discoverability" section).
const std = @import("std");
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const v2 = @import("duckdb_v2_api");

/// Overflow is an error of the query (`ct_add_numbers: Overflow`), not a trap of the process.
fn add(a: i64, b: i64) !i64 {
    return std.math.add(i64, a, b);
}

const CtAddNumbers = comptime_scalar_v2.FunctionDocumented("ct_add_numbers", add, &.{ "a", "b" }, .{
    .description = "Adds two BIGINT values. Overflow is an error of the query.",
    .examples = &.{
        .{ .title = "Two numbers", .sql = "SELECT ct_add_numbers(40, 2);" },
        .{ .sql = "SELECT ct_add_numbers(i, 1) FROM range(3) t(i);" },
    },
    .categories = &.{"numeric"},
});

pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    return CtAddNumbers.register(input);
}
