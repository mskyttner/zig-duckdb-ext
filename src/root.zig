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
    pub const tokenize = @import("functions/tokenize.zig");
    pub const ct_add_numbers = @import("functions/ct_add_numbers.zig");
    pub const ct_tokenize = @import("functions/ct_tokenize.zig");
    pub const tp_bar = @import("functions/tp_bar.zig");
    pub const tp_line = @import("functions/tp_line.zig");
    pub const tp_treemap = @import("functions/tp_treemap.zig");
    pub const tp_snakemap = @import("functions/tp_snakemap.zig");
};

/// Internal libraries.
pub const lib = struct {
    pub const comptime_scalar = @import("lib/comptime_scalar.zig");
    pub const comptime_table = @import("lib/comptime_table.zig");
    pub const asciigraph = @import("lib/asciigraph/asciigraph.zig");
    pub const box = @import("lib/box.zig");
    pub const canvas = @import("lib/canvas.zig");
    pub const turtle = @import("lib/turtle.zig");
    pub const snake = @import("lib/snake.zig");
    pub const tree_lod = @import("lib/tree_lod.zig");
};

// Force the compiler to include the extension entry point export in the shared library.
comptime {
    _ = @import("ext/init.zig");
}
