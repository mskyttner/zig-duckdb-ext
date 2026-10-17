//! Module root of the extension in src/ext/init_bad_ext.zig, whose registration is meant to fail.
comptime {
    _ = @import("ext/init_bad_ext.zig");
}
