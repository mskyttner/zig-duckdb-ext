//! Module root for the cookbook extension (zig_ext_cookbook): re-exports its entry point so DuckDB can find
//! `zig_ext_cookbook_init_c_api_v2`. Lives in src/ so that the examples under src/cookbook/ are in the module.
comptime {
    _ = @import("ext/init_cookbook.zig");
}
