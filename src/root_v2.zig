//! Module root for the real, parallel zig_ext_v2 DuckDB extension.
//!
//! Mirrors root.zig's role for the v1 extension: re-exports the v2 entry
//! point so DuckDB can find the `zig_ext_v2_init_c_api_v2` symbol.
comptime {
    _ = @import("ext/init_v2.zig");
}
