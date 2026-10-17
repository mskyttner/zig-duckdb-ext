//! An extension whose registration fails (built by `zig build load-failure-v2`), to check that a failing call fails the *load* with its reason: a function
//! with two parameters of the same name. (With an uninitialised error slot this used to crash DuckDB.)
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const comptime_scalar_v2 = @import("comptime_scalar_v2");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

const Bad = comptime_scalar_v2.FunctionNamed("bad_duplicate_names", add, &.{ "a", "a" });

export fn zig_ext_bad_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;
    Bad.register(input) catch return;
}
