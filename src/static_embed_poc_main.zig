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
///! real `duckdb.h`, NOT the extension vtable API `duckdb_v2.zig` wraps),
///! and runs a query against a function only the static extension
///! provides. No `.duckdb_extension` file, no `dlopen`, no `LOAD` from a
///! file path, no `-unsigned` — exactly the use case this mechanism
///! exists for (a single self-contained embedding binary).
///!
///! CONFIRMED, EXPECTED RESULT TODAY: registration, open, connect, and
///! `LOAD zig_ext_v2;` all succeed — but the query that follows fails
///! with "Scalar Function ... zig_v2_hello does not exist". This is not
///! a bug in this file: traced to DuckDB's own C++ source
///! (`src/main/capi/v2/capi_v2_extension.cpp`, the real line
///! `input.get_api = statically_linked ? nullptr : ExtensionGetAPIV2;`)
///! — for the static-extension path, `get_api` is ALWAYS null. This
///! project's real `zig_ext_v2_init_c_api_v2` (`root_v2.zig`/`init_v2.zig`)
///! calls `duckdb_v2.initApi`, which does
///! `input.get_api orelse return false` — so it silently returns having
///! registered nothing, every time, under static loading. This
///! disproves what `docs/v2-migration-plan.md`'s "Static linking"
///! section previously assumed ("this project's existing init_v2.zig
///! logic would very likely work unchanged under this path") — that
///! assumption was reasonable but wrong, now corrected by this real
///! test plus the source-level confirmation above. Making this actually
///! register functions would need a second, non-vtable v2 binding layer
///! that calls DuckDB's C API functions directly (resolved as real
///! linked symbols at link time, matching the "mechanism 1" the
///! migration plan already described as a substantial rewrite, not a
///! toggle) — out of scope for this prototype, which exists to establish
///! exactly where the real boundary is, not to build that layer.
const std = @import("std");
const duckdb_v2 = @import("duckdb_v2");
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
extern fn zig_ext_v2_init_c_api_v2(input: *const duckdb_v2.ExtensionInput) callconv(.c) void;

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

    var result: c.duckdb_result = undefined;
    const query = "LOAD zig_ext_v2; SELECT zig_v2_hello('static world') AS msg;";
    const state = c.duckdb_query(connection, query, &result);
    defer c.duckdb_destroy_result(&result);
    if (state != c.DuckDBSuccess) {
        const err_msg = c.duckdb_result_error(&result);
        std.debug.print("query FAILED: {s}\n", .{err_msg});
        return error.QueryFailed;
    }

    const value = c.duckdb_value_varchar(&result, 0, 0);
    defer c.duckdb_free(value);
    std.debug.print("query result: {s}\n", .{value});
}
