///! DuckDB Extension entry point — written in Zig.
///!
///! Exports `zig_ext_init_c_api` which DuckDB calls when loading the extension.
///! The function receives an `ExtensionAccess` struct containing a `get_api`
///! function pointer; we call it to obtain the full C API vtable, then open a
///! connection and register all scalar functions.
const db = @import("../lib/duckdb.zig");
const add_numbers = @import("../functions/add_numbers.zig");
const hello = @import("../functions/hello.zig");
const tokenize = @import("../functions/tokenize.zig");
const ct_add_numbers = @import("../functions/ct_add_numbers.zig");
const ct_tokenize = @import("../functions/ct_tokenize.zig");
const tp_bar = @import("../functions/tp_bar.zig");
const tp_line = @import("../functions/tp_line.zig");

const extension_api_version = "v1.2.0";

/// Extension entry point called by DuckDB when the extension is loaded.
///
/// DuckDB looks for the symbol `<extension_name>_init_c_api` in the shared
/// library. For extension_name = "zig_ext", that is `zig_ext_init_c_api`.
export fn zig_ext_init_c_api(info: db.ExtensionInfo, access: *db.ExtensionAccess) callconv(.c) bool {
    // Step 1: Initialize the API vtable
    if (!db.initApi(info, access, extension_api_version)) {
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

    return true;
}
