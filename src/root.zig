///! Module root for the zig_ext DuckDB extension.
///!
///! This file is the root source file for the shared library. It re-exports the
///! extension entry point so that DuckDB can find the `zig_ext_init_c_api` symbol,
///! and provides access to submodules for tests.
/// DuckDB C API bindings.
pub const duckdb = @import("lib/duckdb.zig");

/// Scalar function implementations.
pub const functions = struct {
    pub const add_numbers = @import("functions/add_numbers.zig");
    pub const hello = @import("functions/hello.zig");
};

// Force the compiler to include the extension entry point export in the shared library.
comptime {
    _ = @import("ext/init.zig");
}
