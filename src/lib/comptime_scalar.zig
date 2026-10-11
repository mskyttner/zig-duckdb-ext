///! Comptime scalar function framework for DuckDB.
///!
///! Generates vectorized callbacks and registration boilerplate from a simple
///! per-row Zig function. Supports automatic NULL propagation and type mapping.
///!
///! Usage:
///!   const MyFn = comptime_scalar.Function("my_add", struct {
///!       fn eval(a: i64, b: i64) i64 { return a + b; }
///!   }.eval);
///!   try MyFn.register(connection);
const std = @import("std");
const db = @import("duckdb.zig");

/// Map a Zig numeric type to the corresponding DuckDB type enum value.
fn duckdbTypeId(comptime T: type) db.c.DUCKDB_TYPE {
    return switch (T) {
        i8 => db.c.DUCKDB_TYPE_TINYINT,
        i16 => db.c.DUCKDB_TYPE_SMALLINT,
        i32 => db.c.DUCKDB_TYPE_INTEGER,
        i64 => db.c.DUCKDB_TYPE_BIGINT,
        f32 => db.c.DUCKDB_TYPE_FLOAT,
        f64 => db.c.DUCKDB_TYPE_DOUBLE,
        bool => db.c.DUCKDB_TYPE_BOOLEAN,
        else => @compileError("unsupported type for DuckDB mapping: " ++ @typeName(T)),
    };
}

/// Define a DuckDB scalar function from a comptime-known Zig function.
///
/// The wrapper generates:
///   - Type-safe parameter and return type registration
///   - A vectorized callback with fast-path (no NULLs) and slow-path (NULL propagation)
///   - Inline dispatch to the user function per row
///
/// The user function must accept only supported numeric types and return a supported
/// numeric type. NULL propagation is automatic: if any input is NULL, the output is NULL.
pub fn Function(comptime name: [:0]const u8, comptime implFn: anytype) type {
    const fn_info = @typeInfo(@TypeOf(implFn)).@"fn";
    const param_types = fn_info.param_types;
    const ReturnType = fn_info.return_type.?;

    // Validate all parameter and return types at comptime.
    inline for (param_types) |t| {
        _ = duckdbTypeId(t.?);
    }
    _ = duckdbTypeId(ReturnType);

    return struct {
        /// Register this scalar function with DuckDB.
        pub fn register(connection: db.Connection) !void {
            const function = db.createScalarFunction();
            defer db.destroyScalarFunction(@constCast(&function));

            db.scalarFunctionSetName(function, name);

            inline for (param_types) |t| {
                var lt = db.createLogicalType(duckdbTypeId(t.?));
                defer db.destroyLogicalType(&lt);
                db.scalarFunctionAddParameter(function, lt);
            }

            var ret_lt = db.createLogicalType(duckdbTypeId(ReturnType));
            defer db.destroyLogicalType(&ret_lt);
            db.scalarFunctionSetReturnType(function, ret_lt);

            db.scalarFunctionSetFunction(function, &execute);

            if (db.registerScalarFunction(connection, function) == db.DuckDBError) {
                return error.FailedToRegisterFunction;
            }
        }

        /// Vectorized callback invoked by DuckDB for each DataChunk.
        fn execute(info: db.FunctionInfo, input: db.DataChunk, output: db.Vector) callconv(.c) void {
            _ = info;
            const chunk_size = db.dataChunkGetSize(input);

            // Cache raw data pointers and validity masks before the loop (one vtable
            // call per parameter, not per row).
            var raw_data: [param_types.len]?*anyopaque = undefined;
            var valids: [param_types.len]?[*]u64 = undefined;
            inline for (0..param_types.len) |i| {
                const vec = db.dataChunkGetVector(input, i);
                raw_data[i] = db.vectorGetData(vec);
                valids[i] = db.vectorGetValidity(vec);
            }

            // SAFETY: DuckDB guarantees the output vector data type matches our registered return type.
            const result: [*]ReturnType = @ptrCast(@alignCast(db.vectorGetData(output)));

            // Runtime check: does any input column contain NULLs?
            var has_nulls = false;
            var idx: usize = 0;
            while (idx < param_types.len) : (idx += 1) {
                if (valids[idx] != null) {
                    has_nulls = true;
                    break;
                }
            }

            if (has_nulls) {
                // Slow path: check validity per row, propagate NULLs.
                db.vectorEnsureValidityWritable(output);
                const out_validity = db.vectorGetValidity(output).?;
                for (0..chunk_size) |row| {
                    if (rowIsValid(&valids, row)) {
                        result[row] = invoke(&raw_data, row);
                    } else {
                        db.validitySetRowInvalid(out_validity, row);
                    }
                }
            } else {
                // Fast path: no NULLs, skip validity checks.
                for (0..chunk_size) |row| {
                    result[row] = invoke(&raw_data, row);
                }
            }
        }

        /// Check if a row is valid across all input columns.
        inline fn rowIsValid(valids: *const [param_types.len]?[*]u64, row: usize) bool {
            inline for (0..param_types.len) |i| {
                if (!db.validityRowIsValid(valids.*[i], row)) return false;
            }
            return true;
        }

        /// Extract typed values from raw data pointers and call the user function.
        inline fn invoke(raw_data: *const [param_types.len]?*anyopaque, row: usize) ReturnType {
            return @call(.auto, implFn, makeArgs(raw_data, row));
        }

        /// Build a tuple type matching the parameter types of the user function.
        fn MakeArgsTuple() type {
            var types: [param_types.len]type = undefined;
            for (0..param_types.len) |i| {
                types[i] = param_types[i].?;
            }
            return @Tuple(&types);
        }

        const ArgsTuple = MakeArgsTuple();

        /// Build the argument tuple for one row, extracting typed values.
        inline fn makeArgs(raw_data: *const [param_types.len]?*anyopaque, row: usize) ArgsTuple {
            var args: ArgsTuple = undefined;
            inline for (0..param_types.len) |i| {
                const T = param_types[i].?;
                // SAFETY: raw_data[i] points to a DuckDB vector buffer of the registered type.
                const typed: [*]T = @ptrCast(@alignCast(raw_data.*[i]));
                args[i] = typed[row];
            }
            return args;
        }
    };
}
