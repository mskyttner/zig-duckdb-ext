///! The cookbook extension: one small, tested example per capability of the DuckDB v2 C API.
///! `docs/cookbook.md` maps each capability to its file; the SQL tests are test/sql/zig_ext_cookbook.test.
///!
///! Exports `zig_ext_cookbook_init_c_api_v2`, the name DuckDB's loader derives from the extension name.
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const config_options = @import("../cookbook/config_options.zig");
const scalar_callbacks = @import("../cookbook/scalar_callbacks.zig");
const aggregate_callbacks = @import("../cookbook/aggregate_callbacks.zig");
const table_callbacks = @import("../cookbook/table_callbacks.zig");
const copy_format = @import("../cookbook/copy_format.zig");
const custom_type = @import("../cookbook/custom_type.zig");
const arrow_ipc = @import("../cookbook/arrow_ipc.zig");
const arrow_c_data = @import("../cookbook/arrow_c_data.zig");
const file_system = @import("../cookbook/file_system.zig");
const logging = @import("../cookbook/logging.zig");
const names = @import("../cookbook/names.zig");

export fn zig_ext_cookbook_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;

    config_options.register(input) catch return;
    scalar_callbacks.register(input) catch return;
    aggregate_callbacks.register(input) catch return;
    table_callbacks.register(input) catch return;
    copy_format.register(input) catch return;
    custom_type.register(input) catch return;
    arrow_ipc.register(input) catch return;
    arrow_c_data.register(input) catch return;
    file_system.register(input) catch return;
    logging.register(input) catch return;
    names.register(input) catch return;
}
