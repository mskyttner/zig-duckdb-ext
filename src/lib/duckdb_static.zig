///! Speculative prototype for DuckDB v2.0 alpha's static-extension
///! registration mechanism (`duckdb_static_extension.h`, vendored
///! alongside this file — see that file's own header comment for
///! provenance). See docs/v2-migration-plan.md's "Static linking"
///! section for the full investigation this came out of.
///!
///! CAUTION — type-level only, not runtime-verified: this staged
///! v2.0.0-alpha46057 build does not publish a compiled `libduckdb`
///! shared/static library artifact anywhere (confirmed live: only CLI
///! binaries and a header-only `libduckdb-src.zip` are published at
///! artifacts.duckdb.org/staged/v2.0-cyanoptera/ — a `libduckdb-*.zip`
///! guess there 302-redirects to a URL that then 404s). Actually calling
///! `duckdb_register_static_extension` and opening a live database would
///! need linking against a real DuckDB build — out of reach without
///! building DuckDB from source at the pinned commit, which this
///! project's whole architecture (ADR-0001: pure Zig, no C++ toolchain)
///! deliberately avoids. What IS verified here, at compile time: the
///! header vendors and translates cleanly, and this project's real v2
///! entrypoint signature (`fn (*const ExtensionInput) callconv(.c)
///! void`) casts cleanly into the descriptor's generic `entry_capi_v2`
///! slot — the specific hypothesis docs/v2-migration-plan.md flagged as
///! unverified.
const std = @import("std");
const c = @import("duckdb_c_static");
const duckdb_v2 = @import("duckdb_v2");

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
const EntryCApiV2Fn = *const fn (*const duckdb_v2.ExtensionInput) callconv(.c) void;

fn exampleEntryCApiV2(input: *const duckdb_v2.ExtensionInput) callconv(.c) void {
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
