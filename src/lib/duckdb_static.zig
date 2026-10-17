///! Speculative prototype for DuckDB v2.0 alpha's static-extension
///! registration mechanism (`duckdb_static_extension.h`, vendored
///! alongside this file — see that file's own header comment for
///! provenance). See docs/v2-migration-plan.md's "Static linking"
///! section for the full investigation this came out of.
///!
///! NOTE — this file is type-level only: it checks, at compile time, that the header vendors and translates cleanly and
///! that this project's real v2 entrypoint signature (`fn (*const ExtensionInput) callconv(.c) void`) casts into the
///! descriptor's generic `entry_capi_v2` slot. It was written when no compiled DuckDB was thought to be available for
///! the staged alpha; there is one (`duckdb-static-libs-*`, pinned in build.zig.zon), and `src/static_embed_poc_main.zig`
///! links it, registers the real extension and runs SQL against it. Read that file for the runtime proof.
const std = @import("std");
const c = @import("duckdb_c_static");
const v2_types = @import("duckdb_v2_types");

pub const ExtensionDescriptor = c.duckdb_extension_descriptor;
pub const DescribeFn = c.duckdb_extension_describe_t;

pub const descriptor_version: u32 = c.DUCKDB_EXTENSION_DESCRIPTOR_VERSION;

/// Thin wrapper around the real C symbol. Declared for completeness —
/// see the module doc comment for why this can't actually be called
/// (linked) against anything in this project's current test/check
/// pipeline.
pub fn registerStaticExtension(describe_fn: DescribeFn) i32 {
    return c.duckdb_register_static_extension(describe_fn);
}

/// The exact signature this project's real v2 entrypoint
/// (`zig_ext_v2_init_c_api_v2` in src/ext/init_v2.zig) has today.
const EntryCApiV2Fn = *const fn (*const v2_types.duckdb_v2_extension_input) callconv(.c) void;

fn exampleEntryCApiV2(input: *const v2_types.duckdb_v2_extension_input) callconv(.c) void {
    _ = input;
}

/// Mirrors what a real `duckdb_extension_<name>_describe` implementation
/// would do: fill in the descriptor DuckDB handed it, casting a function
/// matching this project's real v2 entrypoint signature into the
/// generic `void (*)(void)` slot the header declares `entry_capi_v2` as.
fn describe(descriptor: *ExtensionDescriptor) callconv(.c) i32 {
    descriptor.version = descriptor_version;
    descriptor.name = "zig_ext_v2";
    descriptor.extension_version = "v0.1.0";
    descriptor.api_version = "v2.0.0";
    descriptor.entry_cpp = null;
    descriptor.entry_capi_v1 = null;
    // SAFETY: the header declares this field as a generic `void (*)(void)`
    // since C can't express a union of incompatible function-pointer
    // signatures in one struct field; DuckDB casts it back to
    // `void (*)(duckdb_v2_extension_input*)` before calling it (per the
    // header's own comment on this field) — the same cast this project's
    // real loadable-extension path already relies on implicitly via
    // dlsym, just explicit here.
    descriptor.entry_capi_v2 = @ptrCast(@as(EntryCApiV2Fn, &exampleEntryCApiV2));
    descriptor.database_callback = null;
    return 0;
}

test "entry_capi_v2 signature casts into the static-extension descriptor" {
    var descriptor: ExtensionDescriptor = std.mem.zeroes(ExtensionDescriptor);
    const result = describe(&descriptor);
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect(descriptor.entry_capi_v2 != null);
    try std.testing.expectEqual(descriptor_version, descriptor.version);
}
