///! Real v2 DuckDB extension entry point — written in Zig.
///!
///! Exports `zig_ext_v2_init_c_api_v2` (the name v2's `get_api` loader
///! convention expects: `<extension_name>_init_c_api_v2` for extension_name
///! = "zig_ext_v2"). This is the permanent, parallel-to-v1 extension named
///! in build.zig's `ext-v2` step — distinct from `src/ext/init_v2_poc.zig`,
///! which stays a disposable scratch harness for new-API experiments, not
///! a growing part of the real extension.
///!
///! Registers only the functions already ported off v1 — see each
///! function's own module for why the others (tokenize, tp_bar, tp_line,
///! tp_treemap, tp_snakemap) aren't here yet (VARCHAR support landed this
///! session; LIST support hasn't, and blocks three of them).
const db = @import("duckdb_v2");
const add_numbers = @import("../functions/add_numbers_v2.zig");
const ct_add_numbers = @import("../functions/ct_add_numbers_v2.zig");
const hello = @import("../functions/hello_v2.zig");

export fn zig_ext_v2_init_c_api_v2(input: *const db.ExtensionInput) callconv(.c) void {
    if (!db.initApi(input, "v2.0.0")) return;

    add_numbers.register(input) catch return;
    ct_add_numbers.register(input) catch return;
    hello.register(input) catch return;
}
