///! Scalar function: zig_add_numbers(a BIGINT, b BIGINT) -> BIGINT
///!
///! Adds two 64-bit integers. Propagates NULL if either input is NULL. An overflow is an error of
///! the query ("Overflow in addition of INT64 (a + b)!", as for DuckDB's own `+`), not a trap.
const std = @import("std");
const db = @import("../lib/duckdb.zig");

/// Reports `a + b` overflowing as the error of the query running the callback.
fn reportOverflow(info: db.FunctionInfo, a: i64, b: i64) void {
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0 .. buf.len - 1], "Overflow in addition of INT64 ({d} + {d})!", .{ a, b }) catch buf[0..0];
    buf[msg.len] = 0;
    // SAFETY: `buf[msg.len]` is the terminating NUL written above.
    db.scalarFunctionSetError(info, @ptrCast(&buf));
}

/// Vectorized implementation of the add_numbers function.
/// Processes an entire DataChunk, handling NULL propagation via validity masks.
pub fn addNumbers(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
    const input_size = db.dataChunkGetSize(input);

    const a_vec = db.dataChunkGetVector(input, 0);
    const b_vec = db.dataChunkGetVector(input, 1);

    // SAFETY: DuckDB guarantees vectors contain i64 data for BIGINT parameters.
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
                const sum, const overflowed = @addWithOverflow(a_data[row], b_data[row]);
                if (overflowed != 0) return reportOverflow(info, a_data[row], b_data[row]);
                result_data[row] = sum;
            } else {
                db.validitySetRowInvalid(result_validity, row);
            }
        }
    } else {
        // Fast path: no NULLs
        for (0..input_size) |row| {
            const sum, const overflowed = @addWithOverflow(a_data[row], b_data[row]);
            if (overflowed != 0) return reportOverflow(info, a_data[row], b_data[row]);
            result_data[row] = sum;
        }
    }
}

/// Register the zig_add_numbers scalar function with DuckDB.
pub fn register(connection: db.Connection) !void {
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
