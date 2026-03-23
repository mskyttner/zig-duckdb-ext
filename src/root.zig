///! DuckDB Extension entry point — written in Zig.
///!
///! This is the equivalent of the C template's `capi_quack.c` + `add_numbers.c`.
///! We export `zig_ext_init_c_api` which DuckDB calls when loading the extension.
///! The function receives an `ExtensionAccess` struct containing a `get_api`
///! function pointer; we call it to obtain the full C API vtable, then register
///! our scalar functions.
const db = @import("duckdb.zig");

// ─── Extension metadata ──────────────────────────────────────────────────────

const extension_api_version = "v1.2.0";

// ─── Scalar function: zig_add_numbers(a BIGINT, b BIGINT) → BIGINT ──────────

fn addNumbers(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
    _ = info;
    const input_size = db.dataChunkGetSize(input);

    const a_vec = db.dataChunkGetVector(input, 0);
    const b_vec = db.dataChunkGetVector(input, 1);

    const a_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(a_vec)));
    const b_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(b_vec)));
    const result_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(output)));

    const a_validity = db.vectorGetValidity(a_vec);
    const b_validity = db.vectorGetValidity(b_vec);

    if (a_validity != null or b_validity != null) {
        // There might be NULL values
        db.vectorEnsureValidityWritable(output);
        const result_validity = db.vectorGetValidity(output).?;
        for (0..input_size) |row| {
            if (db.validityRowIsValid(a_validity, row) and db.validityRowIsValid(b_validity, row)) {
                result_data[row] = a_data[row] + b_data[row];
            } else {
                db.validitySetRowInvalid(result_validity, row);
            }
        }
    } else {
        // Fast path: no NULLs
        for (0..input_size) |row| {
            result_data[row] = a_data[row] + b_data[row];
        }
    }
}

fn registerAddNumbers(connection: db.Connection) !void {
    const function = db.createScalarFunction();
    defer db.destroyScalarFunction(@constCast(&function));

    db.scalarFunctionSetName(function, "zig_add_numbers");

    var bigint_type = db.createLogicalType(db.c.DUCKDB_TYPE_BIGINT);
    defer db.destroyLogicalType(&bigint_type);

    db.scalarFunctionAddParameter(function, bigint_type);
    db.scalarFunctionAddParameter(function, bigint_type);
    db.scalarFunctionSetReturnType(function, bigint_type);
    db.scalarFunctionSetFunction(function, &addNumbers);

    if (db.registerScalarFunction(connection, function) == db.DuckDBError) {
        return error.FailedToRegisterFunction;
    }
}

// ─── Scalar function: zig_hello(name VARCHAR) → VARCHAR ──────────────────────

fn zigHello(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
    _ = info;
    const input_size = db.dataChunkGetSize(input);
    const name_vec = db.dataChunkGetVector(input, 0);
    const name_validity = db.vectorGetValidity(name_vec);

    // VARCHAR data is stored as duckdb_string_t in the vector
    const name_data: [*]db.StringT = @ptrCast(@alignCast(db.vectorGetData(name_vec)));

    if (name_validity != null) {
        db.vectorEnsureValidityWritable(output);
        const result_validity = db.vectorGetValidity(output).?;
        for (0..input_size) |row| {
            if (db.validityRowIsValid(name_validity, row)) {
                writeHelloResult(name_data, row, output);
            } else {
                db.validitySetRowInvalid(result_validity, row);
            }
        }
    } else {
        for (0..input_size) |row| {
            writeHelloResult(name_data, row, output);
        }
    }
}

fn writeHelloResult(name_data: [*]db.StringT, row: usize, output: db.Vector) void {
    // Extract the string from the duckdb_string_t.
    // The duckdb_string_t is a union: if length <= 12, data is inlined;
    // otherwise it has a pointer. We access the length from the union directly.
    const str_t = &name_data[row];
    const len = str_t.value.inlined.length;

    // Get a pointer to the actual string data
    const src: [*]const u8 = if (len <= 12)
        &str_t.value.inlined.inlined
    else
        @ptrCast(str_t.value.pointer.ptr.?);

    // Build "Hello, <name>!" using a stack buffer
    var buf: [1024]u8 = undefined;
    const prefix = "Hello, ";
    const suffix = "!";
    const total = prefix.len + len + suffix.len;

    if (total <= buf.len) {
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len .. prefix.len + len], src[0..len]);
        @memcpy(buf[prefix.len + len .. total], suffix);
        db.vectorAssignStringElementLen(output, row, &buf, total);
    } else {
        db.vectorAssignStringElement(output, row, "Hello, world!");
    }
}

fn registerZigHello(connection: db.Connection) !void {
    const function = db.createScalarFunction();
    defer db.destroyScalarFunction(@constCast(&function));

    db.scalarFunctionSetName(function, "zig_hello");

    var varchar_type = db.createLogicalType(db.c.DUCKDB_TYPE_VARCHAR);
    defer db.destroyLogicalType(&varchar_type);

    db.scalarFunctionAddParameter(function, varchar_type);
    db.scalarFunctionSetReturnType(function, varchar_type);
    db.scalarFunctionSetFunction(function, &zigHello);

    if (db.registerScalarFunction(connection, function) == db.DuckDBError) {
        return error.FailedToRegisterFunction;
    }
}

// ─── Extension entry point ───────────────────────────────────────────────────
//
// DuckDB will look for the symbol `<extension_name>_init_c_api` in the shared library.
// For extension_name = "zig_ext", that's `zig_ext_init_c_api`.
//
// The C template uses preprocessor macros (DUCKDB_EXTENSION_ENTRYPOINT) which:
// 1. Define a global `duckdb_ext_api_v1` struct
// 2. Export the `<name>_init_c_api` function with default visibility
// 3. Call `access->get_api(info, version_string)` to populate the struct
// 4. Open a connection, call the user's init function, then close the connection
//
// We replicate this logic directly in Zig.

export fn zig_ext_init_c_api(info: db.ExtensionInfo, access: *db.ExtensionAccess) callconv(.c) bool {
    // Step 1: Initialize the API vtable
    if (!db.initApi(info, access, extension_api_version)) {
        return false;
    }

    // Step 2: Get the database and open a connection
    const database_ptr: *db.Database = @ptrCast(@alignCast(access.get_database.?(info)));
    var conn: db.Connection = undefined;
    if (db.connect(database_ptr.*, &conn) == db.DuckDBError) {
        access.set_error.?(info, "Failed to open connection for zig_ext initialization");
        return false;
    }
    defer db.disconnect(&conn);

    // Step 3: Register our functions
    registerAddNumbers(conn) catch {
        access.set_error.?(info, "Failed to register zig_add_numbers function");
        return false;
    };

    registerZigHello(conn) catch {
        access.set_error.?(info, "Failed to register zig_hello function");
        return false;
    };

    return true;
}
