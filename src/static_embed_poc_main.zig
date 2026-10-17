///! Real link-test for DuckDB v2.0 alpha's static-extension registration
///! mechanism (`duckdb_register_static_extension`, from
///! `duckdb_static_extension.h`) — see docs/v2-migration-plan.md's
///! "Static linking" section for the full investigation.
///!
///! Unlike `src/lib/duckdb_static.zig`'s type-level-only prototype (which
///! only proves this project's real v2 entrypoint signature casts
///! cleanly into the descriptor, at compile time, against a stub
///! callback), THIS executable actually links the real, pinned
///! `libduckdb_static.a` for the exact same `v2.0.0-alpha46057` build
///! this project already targets, registers the REAL `zig_ext_v2` entry
///! point (`root_v2.zig`'s `zig_ext_v2_init_c_api_v2` — completely
///! unmodified, no stub), opens a real in-memory database via plain
///! `duckdb_open`/`duckdb_connect` (the host-embedding C API from the
///! real `duckdb.h`, NOT the extension vtable API the dynamic bindings wrap),
///! and runs a query against a function only the static extension
///! provides. No `.duckdb_extension` file, no `dlopen`, no `LOAD` from a
///! file path, no `-unsigned` — exactly the use case this mechanism
///! exists for (a single self-contained embedding binary).
///!
///! The extension is built against the STATIC generated bindings
///! (`duckdb_v2_static`, plain `extern fn`s resolved at link time), because
///! `build.zig` binds `duckdb_v2_api` for this graph to that backend: for the
///! static-extension path DuckDB's own source passes `get_api = nullptr`
///! (`src/main/capi/v2/capi_v2_extension.cpp`: `input.get_api = statically_linked
///! ? nullptr : ExtensionGetAPIV2;`), which the dynamic bindings cannot work
///! without. The same function modules that `ext-v2` builds against the dynamic
///! backend therefore register here, unchanged, and the queries below run them.
const std = @import("std");
const v2_types = @import("duckdb_v2_types");
const duckdb_static = @import("duckdb_static");
const c = @import("duckdb_full_c");

// `root_v2.zig`'s top-level `comptime { _ = @import("ext/init_v2.zig"); }`
// exports `zig_ext_v2_init_c_api_v2` as a side effect of the module being
// reachable from this binary — the `_ = &root_v2` line in `main` below
// forces that, since nothing else here calls into `root_v2` directly.
// This `extern fn` declaration doesn't define a new function; it just
// gives this file a typed reference to that same real, already-exported
// symbol, to take its address for the descriptor below.
const root_v2 = @import("root_v2");
extern fn zig_ext_v2_init_c_api_v2(input: *const v2_types.duckdb_v2_extension_input) callconv(.c) void;

fn describe(descriptor: *duckdb_static.ExtensionDescriptor) callconv(.c) i32 {
    descriptor.version = duckdb_static.descriptor_version;
    descriptor.name = "zig_ext_v2";
    descriptor.extension_version = "v0.1.0";
    descriptor.api_version = "v2.0.0";
    descriptor.entry_cpp = null;
    descriptor.entry_capi_v1 = null;
    descriptor.entry_capi_v2 = @ptrCast(&zig_ext_v2_init_c_api_v2);
    descriptor.database_callback = null;
    return 0;
}

pub fn main() !void {
    _ = &root_v2; // see comment above

    const register_result = duckdb_static.registerStaticExtension(@ptrCast(&describe));
    std.debug.print("duckdb_register_static_extension -> {d}\n", .{register_result});

    var database: c.duckdb_database = null;
    if (c.duckdb_open(null, &database) != c.DuckDBSuccess) {
        std.debug.print("duckdb_open FAILED\n", .{});
        return error.OpenFailed;
    }
    defer c.duckdb_close(&database);

    var connection: c.duckdb_connection = null;
    if (c.duckdb_connect(database, &connection) != c.DuckDBSuccess) {
        std.debug.print("duckdb_connect FAILED\n", .{});
        return error.ConnectFailed;
    }
    defer c.duckdb_disconnect(&connection);

    try expectVarchar(connection, "LOAD zig_ext_v2; SELECT zig_hello('static world')", "Hello, static world!");
    try expectVarchar(connection, "SELECT tp_bar(0.5, width := 4, \"on\" := 'X', \"off\" := '.')", "XX..");
    try expectVarchar(connection, "SELECT token FROM zig_tokenize('a,b,c', ',') WHERE token_pos = 2", "c");
    try expectVarchar(connection, "SELECT ct_add_numbers(40, 2)::VARCHAR", "42");
    std.debug.print("all static-extension queries returned the expected result\n", .{});
}

fn expectVarchar(connection: c.duckdb_connection, query: [*:0]const u8, expected: []const u8) !void {
    var result: c.duckdb_result = undefined;
    const state = c.duckdb_query(connection, query, &result);
    defer c.duckdb_destroy_result(&result);
    if (state != c.DuckDBSuccess) {
        std.debug.print("query FAILED: {s}\n  {s}\n", .{ query, c.duckdb_result_error(&result) });
        return error.QueryFailed;
    }
    const value = c.duckdb_value_varchar(&result, 0, 0);
    defer c.duckdb_free(value);
    const got = std.mem.span(value);
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("query {s}: expected \"{s}\", got \"{s}\"\n", .{ query, expected, got });
        return error.WrongResult;
    }
}
