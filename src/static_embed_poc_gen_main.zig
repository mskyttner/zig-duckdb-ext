///! Link-and-run check for the generated static (direct-link) bindings in
///! `src/lib/duckdb_v2_static.zig`: registers a zero-argument scalar function through plain
///! `duckdb_v2_*` externs and calls it from SQL, against the pinned `libduckdb_static.a`.
///!
///! Same vertical slice as `static_embed_poc_direct_main.zig`, which declares its calls through a
///! translate-c of `duckdb_v2.h`; here every `duckdb_v2_*` declaration comes from the generator
///! (`tools/gen_v2_bindings.zig`), so the enum values, handle types and nullability it infers are
///! exercised by a real call chain rather than only compared with the header. The function itself
///! is `src/lib/gen_hello.zig`, shared with the dynamic-backend PoC (`v2-gen-poc`).
const std = @import("std");
const log = std.log.scoped(.static_embed_poc_gen);
const v2 = @import("duckdb_v2_static");
const duckdb_static = @import("duckdb_static");
const c = @import("duckdb_full_c");
const hello = @import("gen_hello");

const expected = hello.message;

fn entry(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    hello.register(input.extension, input.context, input.err);
}

fn describe(descriptor: *duckdb_static.ExtensionDescriptor) callconv(.c) i32 {
    descriptor.version = duckdb_static.descriptor_version;
    descriptor.name = "zig_ext_gen";
    descriptor.extension_version = "v0.1.0";
    descriptor.api_version = "v2.0.0";
    descriptor.entry_cpp = null;
    descriptor.entry_capi_v1 = null;
    // SAFETY: the header declares this field as a generic `void (*)(void)`; DuckDB casts it back to
    // `void (*)(duckdb_v2_extension_input *)` before calling it, which is what `entry` is.
    descriptor.entry_capi_v2 = @ptrCast(&entry);
    descriptor.database_callback = null;
    return 0;
}

pub fn main() !void {
    const registered = duckdb_static.registerStaticExtension(@ptrCast(&describe));
    log.info("duckdb_register_static_extension -> {d}", .{registered});

    var database: c.duckdb_database = null;
    if (c.duckdb_open(null, &database) != c.DuckDBSuccess) return error.OpenFailed;
    defer c.duckdb_close(&database);

    var connection: c.duckdb_connection = null;
    if (c.duckdb_connect(database, &connection) != c.DuckDBSuccess) return error.ConnectFailed;
    defer c.duckdb_disconnect(&connection);

    var result: c.duckdb_result = undefined;
    const state = c.duckdb_query(connection, "LOAD zig_ext_gen; SELECT gen_hello() AS msg;", &result);
    defer c.duckdb_destroy_result(&result);
    if (state != c.DuckDBSuccess) {
        log.err("query failed: {s}", .{c.duckdb_result_error(&result)});
        return error.QueryFailed;
    }

    const value = c.duckdb_value_varchar(&result, 0, 0);
    defer c.duckdb_free(value);
    log.info("query result: {s}", .{value});
    if (!std.mem.eql(u8, std.mem.span(value), expected)) return error.WrongResult;
}
