///! Comptime scalar function: ct_add_numbers(a BIGINT, b BIGINT) -> BIGINT
///!
///! v2 port of ct_add_numbers.zig — same one-line per-row function, now
///! generated and registered by comptime_scalar_v2 instead of comptime_scalar.
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const db = @import("duckdb_v2");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

const CtAddNumbers = comptime_scalar_v2.Function("ct_add_numbers", add);

pub fn register(input: *const db.ExtensionInput) !void {
    return CtAddNumbers.register(input);
}
