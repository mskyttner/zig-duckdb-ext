///! Real v2 DuckDB extension entry point — written in Zig.
///!
///! Exports `zig_ext_v2_init_c_api_v2` (the name v2's `get_api` loader
///! convention expects: `<extension_name>_init_c_api_v2` for extension_name
///! = "zig_ext_v2"). This is the permanent, parallel-to-v1 extension named
///! in build.zig's `ext-v2` step — distinct from `src/ext/init_v2_poc.zig`,
///! which stays a disposable scratch harness for new-API experiments, not
///! a growing part of the real extension.
///!
///! Registers all 9 functions ported off v1 — the full set — each written against the generated
///! bindings (`duckdb_v2_dynamic`), which keep their own copy of the function table; `db.initApi`
///! (the hand-written `duckdb_v2.zig`) fills both from its single `get_api` call.
const db = @import("duckdb_v2");
const v2 = @import("duckdb_v2_dynamic");
const add_numbers = @import("../functions/add_numbers_v2.zig");
const ct_add_numbers = @import("../functions/ct_add_numbers_v2.zig");
const hello = @import("../functions/hello_v2.zig");
const tp_bar = @import("../functions/tp_bar_v2.zig");
const tokenize = @import("../functions/tokenize_v2.zig");
const ct_tokenize = @import("../functions/ct_tokenize_v2.zig");
const tp_line = @import("../functions/tp_line_v2.zig");
const tp_treemap = @import("../functions/tp_treemap_v2.zig");
const tp_snakemap = @import("../functions/tp_snakemap_v2.zig");

export fn zig_ext_v2_init_c_api_v2(input: *const db.ExtensionInput) callconv(.c) void {
    if (!db.initApi(input, "v2.0.0")) return;
    // SAFETY: `db.ExtensionInput` is the translate-c'd `duckdb_v2_extension_input`, which the
    // generated struct mirrors field for field (checked by duckdb_v2_static_parity.zig).
    const gen_input: *const v2.duckdb_v2_extension_input = @ptrCast(input);

    add_numbers.register(gen_input) catch return;
    ct_add_numbers.register(gen_input) catch return;
    hello.register(gen_input) catch return;
    tp_bar.register(gen_input) catch return;
    tokenize.register(gen_input) catch return;
    ct_tokenize.register(gen_input) catch return;
    tp_line.register(gen_input) catch return;
    tp_treemap.register(gen_input) catch return;
    tp_snakemap.register(gen_input) catch return;
}
