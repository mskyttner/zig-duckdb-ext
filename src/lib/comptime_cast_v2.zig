///! Comptime cast-function framework for the DuckDB v2 C Extension API.
///!
///! Registers a custom CAST between two SQL types from a plain Zig per-row
///! conversion function, the same "generate the vectorized plumbing from a
///! per-row shape" pattern `comptime_scalar_v2.zig` uses for scalar
///! functions. There is no v1 port to generalize from here — v1's cast
///! function API (`duckdb_create_cast_function`) was never wrapped in this
///! project, so this is new ground on both sides, not a v1→v2 port.
///!
///! The caller supplies a function `fn(SourceT) ?TargetT`:
///!   - returning a value writes it into the output row;
///!   - returning `null` means "this row failed to convert" — what that
///!     does depends on the cast's mode (`db.CastMode`, read via
///!     `castFunctionExecGetMode`, see its own doc comment for the full
///!     contract): in **TRY** mode (SQL `TRY_CAST`, or an implicit cast
///!     DuckDB is speculatively probing) a `null` writes NULL for that row
///!     and the batch continues; in **NORMAL** mode (an explicit
///!     `CAST`/`::`) a `null` aborts the whole query with an error, via
///!     `errorInfoSetCode`/`errorInfoSetText` on the exec callback's own
///!     error slot — a normal cast must either succeed for every row or
///!     fail outright, it can never silently produce NULL.
///!   - a NULL *input* row always produces a NULL output row, in both
///!     modes, without `castFn` ever being called at all — this is
///!     ordinary SQL NULL propagation through a cast, not something
///!     `castFn` gets a say in (mirrors every other framework's row-
///!     skip-on-NULL convention in this codebase).
///!
///! CAUTION, confirmed live against `v2.0.0-alpha46057`: a registered
///! custom cast's exec callback is reliably invoked for an explicit
///! `CAST`/`::` (NORMAL mode) — proven with debug instrumentation that
///! unconditionally errors out before even calling `castFn`, surfacing
///! exactly where it ran. The SAME instrumentation never fires at all for
///! `TRY_CAST`, on a literal constant OR a table column — `TRY_CAST` does
///! not appear to route through a custom-registered cast's exec callback
///! on this alpha build at all. An early, uninstrumented test seemed to
///! show `TRY_CAST('three' AS BIGINT)` working (returning the word-parsed
///! value) — that was a false positive: DuckDB vector buffers get reused
///! across queries in the same session, and an EARLIER explicit `CAST`
///! query in the same multi-statement run had coincidentally written that
///! exact value into the same backing memory, which `TRY_CAST` then read
///! back unmodified (never having written anything itself). Confirmed
///! with fresh, isolated invocations: TRY_CAST through a custom cast
///! consistently returns leftover/uninitialized vector memory, not NULL,
///! not an error — the TRY-mode branch in this file's `execute` is
///! therefore unexercised and unverified on this build, not "working." Not
///! investigated further (whether this is a v2.0 alpha gap expected to
///! close before release, or a real design restriction); treat NORMAL
///! mode as the only currently-provable path for a custom v2 cast.
///!
///! Supports the same leaf types as `comptime_scalar_v2.zig`'s plain
///! numeric/VARCHAR path: i8/i16/i32/i64/f32/f64/bool/`[]const u8`.
///! STRUCT/VARIANT/DECIMAL/ENUM/etc. aren't wired up — a cast between two
///! of those would need its own child-vector-aware read/write path, the
///! same way `comptime_scalar_v2.Function` has dedicated paths for them,
///! not attempted here (a reasonable first target: the common leaf types).
///!
///! No bind-time `implicit_cast_cost` is set, so a registered cast is only
///! ever used for an *explicit* `CAST`/`::` — it never participates in
///! DuckDB's implicit-cast overload resolution. Call
///! `castFunctionSetImplicitCastCost` directly on the handle inside a
///! custom `register` if a future caller needs that; not exposed as a
///! `Function` parameter yet since nothing needs it.
///!
///! Usage:
///!   const VarcharToInt = comptime_cast_v2.Function([]const u8, i64, struct {
///!       fn cast(s: []const u8) ?i64 {
///!           return std.fmt.parseInt(i64, s, 10) catch null;
///!       }
///!   }.cast);
///!   try VarcharToInt.register(input); // input: *const db.ExtensionInput
const std = @import("std");
const db = @import("duckdb_v2");

fn duckdbV2TypeId(comptime T: type) db.LogicalTypeId {
    return switch (T) {
        i8 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_TINYINT,
        i16 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_SMALLINT,
        i32 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_INTEGER,
        i64 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT,
        f32 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_FLOAT,
        f64 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_DOUBLE,
        bool => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BOOLEAN,
        []const u8 => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR,
        else => @compileError("unsupported type for DuckDB v2 cast mapping: " ++ @typeName(T)),
    };
}

/// Define a v2 CAST function from `SourceT` to `TargetT`, from a
/// comptime-known per-row conversion function. See this file's module doc
/// comment for `castFn`'s `?TargetT` return convention.
pub fn Function(comptime SourceT: type, comptime TargetT: type, comptime castFn: fn (SourceT) ?TargetT) type {
    _ = duckdbV2TypeId(SourceT);
    _ = duckdbV2TypeId(TargetT);
    const source_is_varchar = SourceT == []const u8;
    const target_is_varchar = TargetT == []const u8;

    return struct {
        /// Register this cast against the extension being loaded. Must be
        /// called from inside the v2 extension entrypoint, same as every
        /// other comptime framework's `register`.
        pub fn register(input: *const db.ExtensionInput) !void {
            var err: db.ErrorInfoHandle = undefined;

            var function: db.CastFunctionHandle = undefined;
            if (db.castFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = db.castFunctionDestroy(&function);

            var source_type: db.LogicalTypeHandle = undefined;
            if (db.contextCreateTypeFromId(input.context, duckdbV2TypeId(SourceT), &source_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateSourceType;
            }
            defer _ = db.logicalTypeDestroy(&source_type);
            if (db.castFunctionSetSourceType(function, source_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetSourceType;
            }

            var target_type: db.LogicalTypeHandle = undefined;
            if (db.contextCreateTypeFromId(input.context, duckdbV2TypeId(TargetT), &target_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateTargetType;
            }
            defer _ = db.logicalTypeDestroy(&target_type);
            if (db.castFunctionSetTargetType(function, target_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetTargetType;
            }

            if (db.castFunctionSetExecCallback(function, execute, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetExecCallback;
            }

            if (db.castFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }

        fn execute(info: db.CastFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var row_count: db.idx_t = 0;
            if (db.castFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var mode: db.CastMode = undefined;
            if (db.castFunctionExecGetMode(info, &mode, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var input_vec: db.VectorHandle = undefined;
            if (db.castFunctionExecGetInput(info, &input_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            if (db.vectorFlatten(input_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            var in_view: db.VectorView = undefined;
            if (db.vectorGetView(input_vec, &in_view, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var output_vec: db.VectorHandle = undefined;
            if (db.castFunctionExecGetOutput(info, &output_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var out: [*]TargetT = undefined;
            if (comptime !target_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (db.vectorGetDataMutable(output_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: db.idx_t = 0;
            while (row < row_count) : (row += 1) {
                if (in_view.validity) |validity| {
                    const entry_idx = row / 64;
                    const bit_idx: u6 = @intCast(row % 64);
                    if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) {
                        if (db.vectorSetNull(output_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        continue;
                    }
                }

                const source_value: SourceT = if (comptime source_is_varchar) blk: {
                    // SAFETY: the signature registered the source type as VARCHAR.
                    const typed: [*]const db.BytesValue = @ptrCast(@alignCast(in_view.data));
                    break :blk db.bytesSlice(&typed[row]);
                } else blk: {
                    // SAFETY: the signature registered the source type as `SourceT`.
                    const typed: [*]const SourceT = @ptrCast(@alignCast(in_view.data));
                    break :blk typed[row];
                };

                if (castFn(source_value)) |value| {
                    if (comptime target_is_varchar) {
                        var v: db.ValueHandle = undefined;
                        if (db.valueCreateVarcharWithContext(context, value, &v, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        defer _ = db.valueDestroy(&v);
                        if (db.vectorSetValue(output_vec, row, v, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    } else {
                        out[row] = value;
                    }
                } else if (mode == db.c.DUCKDB_V2_CAST_MODE_TRY) {
                    if (db.vectorSetNull(output_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                } else {
                    // NORMAL mode: a failed conversion aborts the query —
                    // populate the already-live error slot and stop, rather
                    // than silently producing NULL (see this file's module
                    // doc comment on castFn's return convention).
                    const msg = db.str("cast failed");
                    _ = db.errorInfoSetCode(err.*, db.c.DUCKDB_V2_ERROR_API);
                    _ = db.errorInfoSetText(err.*, &msg);
                    return;
                }
            }
        }
    };
}

test "Function generates a valid Zig type for a numeric-to-numeric cast" {
    const DoubleToBigint = Function(f64, i64, struct {
        fn cast(x: f64) ?i64 {
            return @intFromFloat(@round(x));
        }
    }.cast);
    // Referencing .register forces analysis of its comptime-unrolled body.
    _ = &DoubleToBigint.register;
    const exec_cb: db.CastFunctionExecCallback = DoubleToBigint.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports VARCHAR as either source or target type" {
    const VarcharToInt = Function([]const u8, i64, struct {
        fn cast(s: []const u8) ?i64 {
            return std.fmt.parseInt(i64, s, 10) catch null;
        }
    }.cast);
    _ = &VarcharToInt.register;

    const IntToVarchar = Function(i64, []const u8, struct {
        fn cast(n: i64) ?[]const u8 {
            return if (n == 0) "zero" else null;
        }
    }.cast);
    _ = &IntToVarchar.register;
}

test "Function supports a conversion that can fail (null return)" {
    const StrictVarcharToInt = Function([]const u8, i64, struct {
        fn cast(s: []const u8) ?i64 {
            return std.fmt.parseInt(i64, s, 10) catch null;
        }
    }.cast);
    _ = &StrictVarcharToInt.register;
    const exec_cb: db.CastFunctionExecCallback = StrictVarcharToInt.execute;
    try std.testing.expect(exec_cb != null);
}
