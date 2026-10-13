///! DuckDB Extension entry point — written in Zig.
///!
///! Exports `<name>_init_c_api` (see `initCApi`'s doc comment) which DuckDB
///! calls when loading the extension. The function receives an
///! `ExtensionAccess` struct containing a `get_api` function pointer; we
///! call it to obtain the full C API vtable, then open a connection and
///! register all scalar functions.
const db = @import("../lib/duckdb.zig");
const build_options = @import("build_options");
const add_numbers = @import("../functions/add_numbers.zig");
const hello = @import("../functions/hello.zig");
const tokenize = @import("../functions/tokenize.zig");
const ct_add_numbers = @import("../functions/ct_add_numbers.zig");
const ct_tokenize = @import("../functions/ct_tokenize.zig");
const tp_bar = @import("../functions/tp_bar.zig");
const tp_line = @import("../functions/tp_line.zig");
const tp_treemap = @import("../functions/tp_treemap.zig");
const tp_snakemap = @import("../functions/tp_snakemap.zig");

comptime {
    @export(&initCApi, .{ .name = build_options.extension_name ++ "_init_c_api" });
}

/// Extension entry point called by DuckDB when the extension is loaded.
///
/// DuckDB looks for the symbol `<extension_name>_init_c_api` in the shared
/// library (`<extension_name>` from `-Dname=` at build time, `"zig_ext"`
/// by default). A plain `export fn <literal>` can't take a build-time
/// string, so this function is exported under that name via `@export` in
/// a comptime block instead, with `build_options.extension_name` (from
/// `build.zig`'s generated options module) supplying the name.
fn initCApi(info: db.ExtensionInfo, access: *db.ExtensionAccess) callconv(.c) bool {
    // Step 1: Initialize the API vtable
    if (!db.initApi(info, access, build_options.api_version[0..build_options.api_version.len :0])) {
        return false;
    }

    // Step 2: Get the database and open a connection
    // SAFETY: access.get_database returns a pointer to the database handle owned by DuckDB.
    const database_ptr: *db.Database = @ptrCast(@alignCast(access.get_database.?(info)));
    var conn: db.Connection = undefined;
    if (db.connect(database_ptr.*, &conn) == db.DuckDBError) {
        access.set_error.?(info, "Failed to open connection for zig_ext initialization");
        return false;
    }
    defer db.disconnect(&conn);

    // Step 3: Register all functions
    add_numbers.register(conn) catch {
        access.set_error.?(info, "Failed to register zig_add_numbers function");
        return false;
    };

    hello.register(conn) catch {
        access.set_error.?(info, "Failed to register zig_hello function");
        return false;
    };

    tokenize.register(conn) catch {
        access.set_error.?(info, "Failed to register zig_tokenize function");
        return false;
    };

    ct_add_numbers.register(conn) catch {
        access.set_error.?(info, "Failed to register ct_add_numbers function");
        return false;
    };

    ct_tokenize.register(conn) catch {
        access.set_error.?(info, "Failed to register ct_tokenize function");
        return false;
    };

    tp_bar.register(conn) catch {
        access.set_error.?(info, "Failed to register tp_bar function");
        return false;
    };

    tp_line.register(conn) catch {
        access.set_error.?(info, "Failed to register tp_line function");
        return false;
    };

    tp_treemap.register(conn) catch {
        access.set_error.?(info, "Failed to register tp_treemap function");
        return false;
    };

    tp_snakemap.register(conn) catch {
        access.set_error.?(info, "Failed to register tp_snakemap function");
        return false;
    };

    return true;
}
