///! Comptime scalar function: ct_add_numbers(a BIGINT, b BIGINT) -> BIGINT
///!
///! v2 port of ct_add_numbers.zig — same one-line per-row function, now
///! generated and registered by comptime_scalar_v2 instead of comptime_scalar.
///! Uses `FunctionNamed` for real parameter names ("a", "b") instead of
///! comptime_scalar_v2's default `a0`/`a1` synthesis — confirmed live this
///! is what was showing up in `duckdb_functions()` before this fix (see
///! docs/v2-migration-plan.md's "Function parameter naming & catalog
///! discoverability" section).
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const v2 = @import("duckdb_v2_dynamic");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

const CtAddNumbers = comptime_scalar_v2.FunctionNamed("ct_add_numbers", add, &.{ "a", "b" });

pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    return CtAddNumbers.register(input);
}
