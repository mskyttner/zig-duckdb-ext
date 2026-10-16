///! Real link-test for DuckDB v2.0 alpha's *direct*, non-vtable static-
///! extension binding mode — the actual fix `src/static_embed_poc_main.zig`
///! identified as missing ("a second, non-vtable v2 binding layer... out
///! of scope for this prototype"). See docs/v2-migration-plan.md's
///! "Static linking" section for the full chain of findings this builds on.
///!
///! Confirmed by reading DuckDB's own source at the exact pinned commit:
///! `duckdb_extension_v2.h` wraps EVERY `duckdb_v2_*` call site in
///! `#ifndef DUCKDB_BUILD_STATIC_EXTENSION` — under that define, the
///! `#define duckdb_v2_xxx duckdb_ext_api.duckdb_v2_xxx` vtable redirection
///! doesn't exist at all, and `DUCKDB_EXTENSION_API_INIT` (the macro that
///! calls `get_api` and populates the vtable) becomes a no-op. A
///! statically-linked C-API extension is meant to call `duckdb_v2_*`
///! functions as plain, directly-linked C symbols instead — confirmed
///! these are real, defined, globally-exported symbols in the real
///! `libduckdb_static.a` via `nm`. `extension/extension_build_tools.cmake`'s
///! `build_static_extension_capi[_v2|_unstable]` is the official CMake
///! machinery that applies this (`target_compile_definitions(... PRIVATE
///! DUCKDB_BUILD_STATIC_EXTENSION)`) for an in-tree C-API extension.
///!
///! This file is the direct-link counterpart to `static_embed_poc_main.zig`:
///! instead of going through `duckdb_v2.zig`'s vtable-based bindings (which
///! intentionally only implement the dynamic path), it declares and calls
///! the real `duckdb_v2_*` symbols directly via `duckdb_v2_full_c`
///! (translated from the real, full `duckdb_v2.h` — the host-embedding
///! header, which has real top-level `extern` prototypes for every
///! function, unlike `duckdb_extension_v2.h`, which only ever declares them
///! as vtable struct fields). No `getApi`/`get_api` call anywhere in this
///! file — matching `DUCKDB_EXTENSION_API_INIT`'s own no-op definition
///! under static linking.
///!
///! CONFIRMED, EXPECTED RESULT: registration, open, connect, `LOAD
///! zig_ext_v2_direct;`, AND the query all succeed — `direct_hello()`
///! actually returns a real value, unlike `static_embed_poc_main.zig`'s
///! `zig_v2_hello` (which fails with "Scalar Function ... does not
///! exist" under the vtable-based binding). This is the first real,
///! working statically-linked v2 C-API scalar function this project has
///! produced — proof the direct-link mechanism genuinely works, not just
///! that it's documented. Still only a minimal vertical slice (one
///! zero-arg VARCHAR scalar function); porting the rest of this project's
///! real functions to this binding mode is a separate, larger follow-up,
///! out of scope here.
const std = @import("std");
const duckdb_v2_full_c = @import("duckdb_v2_full_c");
const duckdb_static = @import("duckdb_static");
const c = @import("duckdb_full_c");

const v2c = duckdb_v2_full_c;

fn directHelloExec(info: v2c.duckdb_v2_scalar_function_exec_info_handle, context: v2c.duckdb_v2_context_handle, err: [*c]v2c.duckdb_v2_error_info_handle) callconv(.c) void {
    var row_count: v2c.idx_t = 0;
    if (v2c.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != v2c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: v2c.duckdb_v2_vector_handle = undefined;
    if (v2c.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != v2c.DUCKDB_V2_ERROR_NONE) return;
    if (v2c.duckdb_v2_vector_set_size(result_vec, row_count, err) != v2c.DUCKDB_V2_ERROR_NONE) return;

    const greeting = "Hello, static-direct world!";
    const str: v2c.duckdb_v2_str = .{ .ptr = greeting.ptr, .len = greeting.len };

    var row: v2c.idx_t = 0;
    while (row < row_count) : (row += 1) {
        var value: v2c.duckdb_v2_value_handle = undefined;
        if (v2c.duckdb_v2_value_create_varchar_with_context(context, &str, &value, err) != v2c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = v2c.duckdb_v2_value_destroy(&value);
        if (v2c.duckdb_v2_vector_set_value(result_vec, row, value, err) != v2c.DUCKDB_V2_ERROR_NONE) return;
    }
}

export fn zig_ext_v2_direct_init_c_api_v2(input: *const v2c.duckdb_v2_extension_input) callconv(.c) void {
    // NOTE: deliberately never touches `input.get_api` — under static
    // linking there is no vtable to fetch; every `duckdb_v2_*` call below
    // resolves as a plain linked symbol instead.
    const extension = input.extension;
    const context = input.context;
    const err = input.err;

    var function: v2c.duckdb_v2_scalar_function_handle = undefined;
    if (v2c.duckdb_v2_scalar_function_create_with_extension(extension, &function, err) != v2c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = v2c.duckdb_v2_scalar_function_destroy(&function);

    const name: v2c.duckdb_v2_str = .{ .ptr = "direct_hello", .len = "direct_hello".len };
    if (v2c.duckdb_v2_scalar_function_set_name(function, &name, err) != v2c.DUCKDB_V2_ERROR_NONE) return;

    var signature: v2c.duckdb_v2_function_signature_handle = undefined;
    if (v2c.duckdb_v2_scalar_function_get_signature(function, &signature, err) != v2c.DUCKDB_V2_ERROR_NONE) return;

    var varchar_type: v2c.duckdb_v2_logical_type_handle = undefined;
    if (v2c.duckdb_v2_context_create_type_from_id(context, v2c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, null, null, 0, &varchar_type, err) != v2c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = v2c.duckdb_v2_logical_type_destroy(&varchar_type);
    if (v2c.duckdb_v2_function_signature_set_return_type(signature, varchar_type, err) != v2c.DUCKDB_V2_ERROR_NONE) return;

    if (v2c.duckdb_v2_scalar_function_set_exec_callback(function, &directHelloExec, err) != v2c.DUCKDB_V2_ERROR_NONE) return;

    _ = v2c.duckdb_v2_scalar_function_register(function, err);
}

fn describe(descriptor: *duckdb_static.ExtensionDescriptor) callconv(.c) i32 {
    descriptor.version = duckdb_static.descriptor_version;
    descriptor.name = "zig_ext_v2_direct";
    descriptor.extension_version = "v0.1.0";
    descriptor.api_version = "v2.0.0";
    descriptor.entry_cpp = null;
    descriptor.entry_capi_v1 = null;
    descriptor.entry_capi_v2 = @ptrCast(&zig_ext_v2_direct_init_c_api_v2);
    descriptor.database_callback = null;
    return 0;
}

pub fn main() !void {
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
    const query = "LOAD zig_ext_v2_direct; SELECT direct_hello() AS msg;";
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
