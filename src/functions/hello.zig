///! Scalar function: zig_hello(name VARCHAR) -> VARCHAR
///!
///! Returns "Hello, <name>!" for the given input string. Propagates NULL.
const db = @import("../lib/duckdb.zig");

/// Vectorized implementation of the zig_hello function.
/// Processes an entire DataChunk of VARCHAR inputs, producing VARCHAR outputs.
pub fn zigHello(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
    _ = info;
    // SAFETY: DuckDB vectors are capped at STANDARD_VECTOR_SIZE (2048), far under `usize`'s
    // range even on 32-bit targets (wasm32).
    const input_size: usize = @intCast(db.dataChunkGetSize(input));
    const name_vec = db.dataChunkGetVector(input, 0);
    const name_validity = db.vectorGetValidity(name_vec);

    // SAFETY: DuckDB guarantees vectors contain duckdb_string_t data for VARCHAR parameters.
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

/// Build "Hello, <name>!" from a duckdb_string_t and assign it to the output vector.
fn writeHelloResult(name_data: [*]db.StringT, row: usize, output: db.Vector) void {
    const src = db.stringSlice(&name_data[row]);
    const len = src.len;

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

/// Register the zig_hello scalar function with DuckDB.
pub fn register(connection: db.Connection) !void {
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
