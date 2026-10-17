//! Checks the generated dynamic bindings (duckdb_v2_dynamic.zig):
//!
//! - the function table `Api` has the layout of `duckdb_ext_api_v2` in the pinned
//!   duckdb_extension_v2.h, member by member (name, offset, signature). The order of the members is
//!   the ABI, and the generator derives it from rules it infers rather than reads, so this is the
//!   test that catches a wrong order;
//! - the dynamic and the static backend declare the same functions with the same signatures and
//!   share their types;
//! - `init` fetches the table through `get_api` and copies it, and the wrappers call through it,
//!   against a fake `get_api` (no DuckDB needed).
const std = @import("std");
const log = std.log.scoped(.v2_dynamic_parity);
const dyn = @import("duckdb_v2_dynamic");
const stat = @import("duckdb_v2_static");
const c = @import("duckdb_v2_extension_c");
const util = @import("duckdb_v2_parity_util.zig");

const fn_prefix = "duckdb_v2_";

var failures: usize = 0;

fn fail(comptime fmt: []const u8, args: anytype) void {
    failures += 1;
    if (failures <= 40) log.err(fmt, args);
}

test "the function table has the layout of duckdb_ext_api_v2" {
    @setEvalBranchQuota(10_000_000);
    failures = 0;
    const A = dyn.Api;
    const C = c.duckdb_ext_api_v2;

    const fa = comptime std.meta.fieldNames(A);
    const fb = comptime std.meta.fieldNames(C);
    if (fa.len != fb.len) fail("{d} members here, {d} in the header", .{ fa.len, fb.len });
    if (@sizeOf(A) != @sizeOf(C)) fail("size {d} here, {d} in the header", .{ @sizeOf(A), @sizeOf(C) });

    inline for (fa, 0..) |name, i| {
        if (i >= fb.len) break;
        if (!std.mem.eql(u8, name, fb[i])) {
            fail("member {d}: {s} here, {s} in the header", .{ i, name, fb[i] });
        } else {
            if (@offsetOf(A, name) != @offsetOf(C, name)) fail("{s}: offset {d} here, {d} in the header", .{ name, @offsetOf(A, name), @offsetOf(C, name) });
            if (!util.sameFnPointer(@typeInfo(@FieldType(A, name)).optional.child, @FieldType(C, name))) fail("{s}: signature differs", .{name});
        }
    }
    log.info("compared {d} members; {d} problems", .{ fa.len, failures });
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "the dynamic and the static backend agree" {
    @setEvalBranchQuota(10_000_000);
    failures = 0;
    var n_fn: usize = 0;
    var n_type: usize = 0;

    const static_decls = comptime std.meta.declarations(stat);
    inline for (static_decls) |name| {
        if (!@hasDecl(dyn, name)) {
            fail("{s}: in the static backend, not in the dynamic one", .{name});
            continue;
        }
        const ST = @TypeOf(@field(stat, name));
        if (ST == type) {
            n_type += 1;
            if (@field(stat, name) != @field(dyn, name)) fail("type {s}: not the same type in both backends", .{name});
        } else if (@typeInfo(ST) == .@"fn") {
            n_fn += 1;
            if (!@hasField(dyn.Api, name)) fail("function {s}: no member in the function table", .{name});
            const sf = @typeInfo(ST).@"fn";
            const df = @typeInfo(@TypeOf(@field(dyn, name))).@"fn";
            if (sf.param_types.len != df.param_types.len) {
                fail("function {s}: {d} parameters in the static backend, {d} in the dynamic one", .{ name, sf.param_types.len, df.param_types.len });
            } else {
                inline for (sf.param_types, df.param_types) |sp, dp| {
                    if (sp.? != dp.?) fail("function {s}: parameter types differ", .{name});
                }
            }
            if (sf.return_type.? != df.return_type.?) fail("function {s}: return types differ", .{name});
        }
    }

    // Everything else the dynamic backend declares is its own: the table, `init`, the version.
    const dynamic_decls = comptime std.meta.declarations(dyn);
    inline for (dynamic_decls) |name| {
        if (!@hasDecl(stat, name) and !std.mem.eql(u8, name, "Api") and !std.mem.eql(u8, name, "api") and
            !std.mem.eql(u8, name, "init") and !std.mem.eql(u8, name, "setTable") and
            !std.mem.eql(u8, name, "api_version"))
        {
            fail("{s}: in the dynamic backend, not in the static one", .{name});
        }
    }
    log.info("compared {d} functions and {d} types; {d} problems", .{ n_fn, n_type, failures });
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// --- init and the wrappers, against a fake get_api ---------------------------------------------

var fake_table: dyn.Api = std.mem.zeroes(dyn.Api);
var fake_version_ok = false;
var arena_calls: usize = 0;
var arena_last_len: u64 = 0;

fn fakeArenaAllocate(
    arena: dyn.duckdb_v2_arena_handle,
    byte_len: u64,
    out_ptr: *[*]u8,
    err: ?*dyn.duckdb_v2_error_info_handle,
) callconv(.c) dyn.DUCKDB_V2_ERROR {
    _ = arena;
    _ = out_ptr;
    _ = err;
    arena_calls += 1;
    arena_last_len = byte_len;
    return .ERROR_NONE;
}

fn fakeGetApi(extension: dyn.duckdb_v2_extension_handle, version: [*]const u8) callconv(.c) ?*const anyopaque {
    _ = extension;
    // The version asked for is the NUL-terminated string `init` was given.
    fake_version_ok = std.mem.eql(u8, version[0..6], "v2.0.0");
    return &fake_table;
}

fn nullGetApi(extension: dyn.duckdb_v2_extension_handle, version: [*]const u8) callconv(.c) ?*const anyopaque {
    _ = extension;
    _ = version;
    return null;
}

fn fakeInput(get_api: ?dyn.duckdb_v2_extension_get_api_fn) dyn.duckdb_v2_extension_input {
    return .{
        .get_api = get_api,
        // A handle is only ever passed back to DuckDB; the fakes never look at it.
        .extension = @ptrFromInt(0x10),
        .context = @ptrFromInt(0x10),
        .err = null,
    };
}

test "init fails without get_api, and when get_api refuses" {
    dyn.api = std.mem.zeroes(dyn.Api);
    try std.testing.expect(!dyn.init(&fakeInput(null), dyn.api_version));
    try std.testing.expect(!dyn.init(&fakeInput(&nullGetApi), dyn.api_version));
    try std.testing.expect(dyn.api.duckdb_v2_arena_allocate == null);
}

test "init copies the table and the wrappers call through it" {
    dyn.api = std.mem.zeroes(dyn.Api);
    fake_table = std.mem.zeroes(dyn.Api);
    fake_table.duckdb_v2_arena_allocate = &fakeArenaAllocate;
    fake_version_ok = false;
    arena_calls = 0;

    try std.testing.expect(dyn.init(&fakeInput(&fakeGetApi), dyn.api_version));
    try std.testing.expect(fake_version_ok);

    // DuckDB may free the table it handed out: nothing may read it after `init`.
    fake_table = std.mem.zeroes(dyn.Api);

    var out: [*]u8 = undefined;
    const arena: dyn.duckdb_v2_arena_handle = @ptrFromInt(0x10);
    try std.testing.expectEqual(dyn.DUCKDB_V2_ERROR.ERROR_NONE, dyn.duckdb_v2_arena_allocate(arena, 42, &out, null));
    try std.testing.expectEqual(@as(usize, 1), arena_calls);
    try std.testing.expectEqual(@as(u64, 42), arena_last_len);

    dyn.api = std.mem.zeroes(dyn.Api);
}

test "setTable installs a copy of the table it is given" {
    dyn.api = std.mem.zeroes(dyn.Api);
    var table = std.mem.zeroes(dyn.Api);
    table.duckdb_v2_arena_allocate = &fakeArenaAllocate;
    arena_calls = 0;

    dyn.setTable(&table);
    table = std.mem.zeroes(dyn.Api);

    var out: [*]u8 = undefined;
    const arena: dyn.duckdb_v2_arena_handle = @ptrFromInt(0x10);
    try std.testing.expectEqual(dyn.DUCKDB_V2_ERROR.ERROR_NONE, dyn.duckdb_v2_arena_allocate(arena, 7, &out, null));
    try std.testing.expectEqual(@as(usize, 1), arena_calls);

    dyn.api = std.mem.zeroes(dyn.Api);
}
