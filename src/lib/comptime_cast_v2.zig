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
///!     does depends on the cast's mode (`v2.DUCKDB_V2_CAST_MODE`, read via
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
///! TRY_CAST reaches a custom cast the same way an explicit CAST does, and a `null` from
///! `castFn` becomes a NULL row there (pinned by `test/sql/zig_ext_v2_poc.test`). An earlier
///! version of this comment said it did not, and that it returned leftover vector memory: that,
///! and every other symptom listed under the next heading, was the output vector's size not
///! being set. Only the plain path's TRY branch is covered by a test; no PoC cast of the STRUCT or
///! VARIANT shape ever returns `null`, so those two branches are not exercised.
///!
///! Supports the same leaf types as `comptime_scalar_v2.zig`'s plain
///! numeric/VARCHAR path (i8/i16/i32/i64/f32/f64/bool/`[]const u8`), plus
///! DECIMAL, ENUM, and STRUCT (one level deep, numeric/bool/`[]const u8`
///! fields — same restriction `comptime_scalar_v2.zig` has) as either
///! source or target type, and VARIANT as a **source** type only (not
///! target — see the `@compileError` on `TargetT == UserValue`: a
///! VARIANT target needs `context` to build a fresh `Value`, which
///! `castFn`'s fixed `fn(SourceT) ?TargetT` signature doesn't receive,
///! unlike `comptime_scalar_v2.Function`'s `implFn`, which can opt into a
///! leading `context` parameter). MAP/UNION/LIST/ARRAY aren't wired up at
///! all. STRUCT can't be combined with VARIANT or ENUM in the same
///! function yet (compile error) — ENUM because `executeStruct` has no
///! ENUM-aware read/write path, VARIANT per `comptime_scalar_v2.zig`'s
///! identical restriction.
///!
///! CAUTION, confirmed live: writing an ENUM **target** via the
///! "box as VARCHAR, then `valueCastWithContext` to the enum type" trick
///! `comptime_scalar_v2.zig`'s scalar-function return path uses safely is
///! NOT safe here — registering a cast INTO an ENUM type means that
///! cast-to-target-type call re-enters THIS SAME cast function
///! recursively (it's now the registered VARCHAR→ENUM conversion DuckDB
///! would use for that cast). Confirmed live: infinite recursion, stack
///! overflow, segfault. Fixed by writing the dictionary ordinal directly
///! into the output vector's flat buffer instead (`encodeEnumOrdinal`),
///! never going through `valueCastWithContext` for an ENUM target at all.
///!
///! The output vector's size is set before anything is written (`vectorSetSize` right after the
///! output vector is fetched, as the scalar and table frameworks do): `vector_set_null` and
///! `vector_set_value` fail with "row out of range" on any row of an unsized vector. Until that
///! was found, every custom cast failed over any column with a NULL row, and every cast writing
///! through `vector_set_value` (ENUM -> VARCHAR, STRUCT -> VARCHAR) failed outright; this file
///! blamed DuckDB's handling of composite types, and also claimed that registering both
///! directions of a composite type corrupted DuckDB's cast dispatch. Neither is true: the
///! casts, in both directions and mixed in one session, are covered by the PoC suite.
///!
///! A custom cast on an ENUM type is not limited to the dictionary it was registered with. Observed
///! with the PoC's casts loaded: `CAST(CAST('a' AS ENUM('a','b','c')) AS BIGINT)` fails with
///! "cast failed", because the VARCHAR -> ENUM cast, which only knows the Zig enum's names, is
///! applied to the other ENUM too; and registering a deliberately wrong dictionary changes no
///! result. DuckDB appears to look the cast up by type id. Loading an extension that registers a
///! cast on ENUM therefore changes what every ENUM in the session casts to and from.
///!
///! No bind-time `implicit_cast_cost` is set, so a registered cast is only
///! ever used for an *explicit* `CAST`/`::` — it never participates in
///! DuckDB's implicit-cast overload resolution. Call
///! `castFunctionSetImplicitCastCost` directly on the handle inside a
///! custom `register` if a future caller needs that; not exposed as a
///! `Function` parameter yet since nothing needs it.
///!
///! Bindings: the framework calls DuckDB through the generated bindings
///! (`duckdb_v2_dynamic`, plus the helpers in `v2_helpers.zig`). A VARIANT source type is
///! written as `v2.duckdb_v2_value_handle`, which `castFn` receives.
///!
///! Usage:
///!   const VarcharToInt = comptime_cast_v2.Function([]const u8, i64, struct {
///!       fn cast(s: []const u8) ?i64 {
///!           return std.fmt.parseInt(i64, s, 10) catch null;
///!       }
///!   }.cast);
///!   try VarcharToInt.register(input); // input: *const v2.duckdb_v2_extension_input
const std = @import("std");
const v2_values = @import("v2_values");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const UserValue = v2.duckdb_v2_value_handle;

fn duckdbV2TypeId(comptime T: type) v2.DUCKDB_V2_LOGICAL_TYPE_ID {
    return switch (T) {
        i8 => .LOGICAL_TYPE_ID_TINYINT,
        i16 => .LOGICAL_TYPE_ID_SMALLINT,
        i32 => .LOGICAL_TYPE_ID_INTEGER,
        i64 => .LOGICAL_TYPE_ID_BIGINT,
        f32 => .LOGICAL_TYPE_ID_FLOAT,
        f64 => .LOGICAL_TYPE_ID_DOUBLE,
        bool => .LOGICAL_TYPE_ID_BOOLEAN,
        []const u8 => .LOGICAL_TYPE_ID_VARCHAR,
        UserValue => .LOGICAL_TYPE_ID_VARIANT,
        else => @compileError("unsupported type for DuckDB v2 cast mapping: " ++ @typeName(T)),
    };
}

fn isDecimalType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "v2_decimal_width");
}

fn isEnumType(comptime T: type) bool {
    if (T == v2_values.Date or T == v2_values.Time or T == v2_values.Timestamp) return false;
    return @typeInfo(T) == .@"enum";
}

fn isStructType(comptime T: type) bool {
    if (T == v2_values.Blob) return false;
    if (comptime isDecimalType(T)) return false;
    return @typeInfo(T) == .@"struct";
}

/// Build "ENUM('member0','member1',...)" from a Zig enum's own variant
/// names — mirrors `comptime_scalar_v2.zig`'s identical helper (duplicated
/// rather than shared, matching this project's existing convention of each
/// comptime framework carrying its own copy of this small set of type
/// predicates/helpers).
fn enumSqlText(comptime T: type) []const u8 {
    const info = @typeInfo(T).@"enum";
    comptime var text: []const u8 = "ENUM(";
    inline for (info.field_names, 0..) |name_, i| {
        if (i > 0) text = text ++ ",";
        text = text ++ "'" ++ name_ ++ "'";
    }
    return text ++ ")";
}

/// Build the logical type for a plain, DECIMAL, ENUM, STRUCT, or VARIANT
/// Zig type `T` — mirrors `comptime_scalar_v2.zig`'s identical function
/// (same duplication rationale as `enumSqlText`).
fn createLogicalType(ctx: v2.duckdb_v2_context_handle, comptime T: type, out_type: *v2.duckdb_v2_logical_type_handle, err: *v2.duckdb_v2_error_info_handle) v2.DUCKDB_V2_ERROR {
    if (comptime T == UserValue) {
        return helpers.createTypeFromText(ctx, "VARIANT", out_type, err);
    }
    if (comptime isDecimalType(T)) {
        return helpers.createDecimalType(ctx, T.v2_decimal_width, T.v2_decimal_scale, out_type, err);
    }
    if (comptime isEnumType(T)) {
        return helpers.createTypeFromText(ctx, comptime enumSqlText(T), out_type, err);
    }
    if (comptime isStructType(T)) {
        const fields = @typeInfo(T).@"struct";
        const n = fields.field_types.len;
        var field_logical_types: [n]v2.duckdb_v2_logical_type_handle = undefined;
        inline for (0..n) |f| {
            if (createLogicalType(ctx, fields.field_types[f], &field_logical_types[f], err) != .ERROR_NONE) {
                return .ERROR_API;
            }
        }
        defer inline for (0..n) |f| {
            _ = v2.duckdb_v2_logical_type_destroy(&field_logical_types[f]);
        };
        var field_names: [n]v2.duckdb_v2_identifier_t = undefined;
        inline for (0..n) |f| field_names[f] = helpers.str(fields.field_names[f]);
        var field_type_values: [n]v2.duckdb_v2_value_handle = undefined;
        const rc = helpers.createStructType(ctx, &field_names, &field_logical_types, &field_type_values, out_type, err);
        defer inline for (0..n) |f| {
            _ = v2.duckdb_v2_value_destroy(&field_type_values[f]);
        };
        return rc;
    }
    return helpers.createTypeFromId(ctx, duckdbV2TypeId(T), out_type, err);
}

/// Decode an ENUM value from its vector storage (a dictionary ordinal) —
/// mirrors `comptime_scalar_v2.zig`'s identical `decodeEnumArg`.
inline fn decodeEnumValue(comptime T: type, view: v2.duckdb_v2_vector_view, row: u64) T {
    const info = @typeInfo(T).@"enum";
    const n = info.field_values.len;
    const StorageT = if (n <= 255) u8 else if (n <= 65535) u16 else u32;
    const dict_values = comptime blk: {
        var vals: [n]std.meta.Tag(T) = undefined;
        for (info.field_values, 0..) |v, idx| vals[idx] = @intCast(v);
        break :blk vals;
    };
    // SAFETY: a flattened ENUM vector's view data is a dictionary-ordinal
    // array, width chosen by dictionary size.
    const typed: [*]const StorageT = @ptrCast(@alignCast(view.data));
    return @fromBackingInt(@intCast(dict_values[typed[row]]));
}

/// The raw dictionary-ordinal storage width for a Zig enum `T`'s own
/// dictionary size — matches `decodeEnumValue`'s identical derivation.
fn EnumOrdinalStorageT(comptime T: type) type {
    const n = @typeInfo(T).@"enum".field_values.len;
    return if (n <= 255) u8 else if (n <= 65535) u16 else u32;
}

/// Encode a Zig enum value as its dictionary ordinal (its index among
/// `T`'s own declared fields, in declaration order — the exact order
/// `enumSqlText` built the SQL `ENUM(...)` dictionary in, so a manually-
/// numbered Zig enum still encodes correctly, mirroring `decodeEnumValue`'s
/// reverse direction).
///
/// CAUTION, found live: writing an ENUM target via `valueCreateVarcharWithContext`
/// + `valueCastWithContext(..., target_logical_type)` (the same trick
/// `comptime_scalar_v2.zig`'s plain scalar-function return path uses
/// safely) is NOT safe here — `comptime_cast_v2.Function` registering a
/// cast INTO this exact ENUM type means that cast-to-target-type call
/// re-enters THIS SAME cast function recursively, since it's now the
/// registered VARCHAR→ENUM conversion DuckDB would use. Confirmed live:
/// infinite recursion, stack overflow, segfault — not a DuckDB bug, a
/// self-inflicted reentrancy bug in this framework's first attempt.
/// Writing the dictionary ordinal directly into the output vector's flat
/// buffer (this function + the write site using it) sidesteps the cast
/// machinery entirely, avoiding the recursion.
inline fn encodeEnumOrdinal(comptime T: type, value: T) EnumOrdinalStorageT(T) {
    const info = @typeInfo(T).@"enum";
    inline for (info.field_values, 0..) |fv, idx| {
        if (@backingInt(value) == fv) return @intCast(idx);
    }
    unreachable;
}

/// Define a v2 CAST function from `SourceT` to `TargetT`, from a
/// comptime-known per-row conversion function. See this file's module doc
/// comment for `castFn`'s `?TargetT` return convention, and for STRUCT/
/// DECIMAL/ENUM/VARIANT support's exact scope (VARIANT is source-only —
/// see the module doc comment's CAUTION on why).
pub fn Function(comptime SourceT: type, comptime TargetT: type, comptime castFn: fn (SourceT) ?TargetT) type {
    if (comptime TargetT == UserValue) {
        @compileError("comptime_cast_v2.Function: VARIANT is only supported as a source type, not a target type — boxing a fresh Value needs a context castFn's fixed `fn(SourceT) ?TargetT` signature doesn't receive (unlike comptime_scalar_v2.Function's implFn, which can opt into a leading `context` parameter)");
    }
    if (comptime !isStructType(SourceT) and !isDecimalType(SourceT) and !isEnumType(SourceT)) _ = duckdbV2TypeId(SourceT);
    if (comptime !isStructType(TargetT) and !isDecimalType(TargetT) and !isEnumType(TargetT)) _ = duckdbV2TypeId(TargetT);

    const source_is_varchar = SourceT == []const u8;
    const target_is_varchar = TargetT == []const u8;
    const source_is_variant = SourceT == UserValue;
    const source_is_decimal = isDecimalType(SourceT);
    const target_is_decimal = isDecimalType(TargetT);
    const source_is_enum = isEnumType(SourceT);
    const target_is_enum = isEnumType(TargetT);
    const source_is_struct = isStructType(SourceT);
    const target_is_struct = isStructType(TargetT);
    if ((source_is_variant) and (source_is_struct or target_is_struct)) {
        @compileError("comptime_cast_v2.Function: can't combine VARIANT with STRUCT on either side yet");
    }
    if ((source_is_enum or target_is_enum) and (source_is_struct or target_is_struct)) {
        @compileError("comptime_cast_v2.Function: can't combine ENUM with STRUCT on either side yet — executeStruct has no ENUM-aware write/read path");
    }

    return struct {
        /// Register this cast against the extension being loaded. Must be
        /// called from inside the v2 extension entrypoint, same as every
        /// other comptime framework's `register`.
        pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
            var err: v2.duckdb_v2_error_info_handle = undefined;

            var function: v2.duckdb_v2_cast_function_handle = undefined;
            if (v2.duckdb_v2_cast_function_create_with_extension(input.extension, &function, &err) != .ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = v2.duckdb_v2_cast_function_destroy(&function);

            var source_type: v2.duckdb_v2_logical_type_handle = undefined;
            if (createLogicalType(input.context, SourceT, &source_type, &err) != .ERROR_NONE) {
                return error.FailedToCreateSourceType;
            }
            defer _ = v2.duckdb_v2_logical_type_destroy(&source_type);
            if (v2.duckdb_v2_cast_function_set_source_type(function, source_type, &err) != .ERROR_NONE) {
                return error.FailedToSetSourceType;
            }

            var target_type: v2.duckdb_v2_logical_type_handle = undefined;
            if (createLogicalType(input.context, TargetT, &target_type, &err) != .ERROR_NONE) {
                return error.FailedToCreateTargetType;
            }
            defer _ = v2.duckdb_v2_logical_type_destroy(&target_type);
            if (v2.duckdb_v2_cast_function_set_target_type(function, target_type, &err) != .ERROR_NONE) {
                return error.FailedToSetTargetType;
            }

            if (v2.duckdb_v2_cast_function_set_exec_callback(function, execute, &err) != .ERROR_NONE) {
                return error.FailedToSetExecCallback;
            }

            if (v2.duckdb_v2_cast_function_register(function, &err) != .ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }

        const WriteType = if (target_is_decimal) TargetT.Raw else TargetT;
        const EnumOut = if (target_is_enum) [*]EnumOrdinalStorageT(TargetT) else void;

        fn execute(info: v2.duckdb_v2_cast_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
            var row_count: u64 = 0;
            if (v2.duckdb_v2_cast_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

            var mode: v2.DUCKDB_V2_CAST_MODE = undefined;
            if (v2.duckdb_v2_cast_function_exec_get_mode(info, &mode, err) != .ERROR_NONE) return;

            var output_vec: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_cast_function_exec_get_output(info, &output_vec, err) != .ERROR_NONE) return;

            // The output vector has no elements until its size is set: `vector_set_null` and
            // `vector_set_value` fail with "row out of range" on any row of an unsized vector, so
            // without this a NULL row, or a VARCHAR/ENUM-boxed write, aborts the query. The scalar and
            // table frameworks set their output sizes first for the same reason.
            if (v2.duckdb_v2_vector_set_size(output_vec, row_count, err) != .ERROR_NONE) return;

            if (comptime source_is_variant) {
                return executeFromVariant(info, context, mode, output_vec, row_count, err);
            }
            if (comptime source_is_struct or target_is_struct) {
                return executeStruct(info, context, mode, output_vec, row_count, err);
            }

            var input_vec: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_cast_function_exec_get_input(info, &input_vec, err) != .ERROR_NONE) return;
            if (v2.duckdb_v2_vector_flatten(input_vec, err) != .ERROR_NONE) return;
            var in_view: v2.duckdb_v2_vector_view = undefined;
            if (v2.duckdb_v2_vector_get_view(input_vec, &in_view, err) != .ERROR_NONE) return;

            var out: [*]WriteType = undefined;
            var enum_out: EnumOut = undefined;
            if (comptime target_is_enum) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(output_vec, &out_data, err) != .ERROR_NONE) return;
                enum_out = @ptrCast(@alignCast(out_data));
            } else if (comptime !target_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(output_vec, &out_data, err) != .ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                if (in_view.validity) |validity| {
                    const entry_idx = row / 64;
                    const bit_idx: u6 = @intCast(row % 64);
                    if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) {
                        if (v2.duckdb_v2_vector_set_null(output_vec, row, err) != .ERROR_NONE) return;
                        continue;
                    }
                }

                const source_value: SourceT = if (comptime source_is_varchar) blk: {
                    // SAFETY: the signature registered the source type as VARCHAR.
                    const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(in_view.data));
                    break :blk helpers.bytesSlice(&typed[row]);
                } else if (comptime source_is_decimal) blk: {
                    // SAFETY: DECIMAL is a typed leaf array over SourceT.Raw.
                    const typed: [*]const SourceT.Raw = @ptrCast(@alignCast(in_view.data));
                    break :blk .{ .raw = typed[row] };
                } else if (comptime source_is_enum) blk: {
                    break :blk decodeEnumValue(SourceT, in_view, row);
                } else blk: {
                    // SAFETY: the signature registered the source type as `SourceT`.
                    const typed: [*]const SourceT = @ptrCast(@alignCast(in_view.data));
                    break :blk typed[row];
                };

                if (castFn(source_value)) |value| {
                    if (comptime target_is_varchar) {
                        var v: v2.duckdb_v2_value_handle = undefined;
                        if (helpers.createVarcharValue(context, value, &v, err) != .ERROR_NONE) return;
                        defer _ = v2.duckdb_v2_value_destroy(&v);
                        if (v2.duckdb_v2_vector_set_value(output_vec, row, v, err) != .ERROR_NONE) return;
                    } else if (comptime target_is_enum) {
                        enum_out[row] = encodeEnumOrdinal(TargetT, value);
                    } else if (comptime target_is_decimal) {
                        out[row] = value.raw;
                    } else {
                        out[row] = value;
                    }
                } else if (mode == .CAST_MODE_TRY) {
                    if (v2.duckdb_v2_vector_set_null(output_vec, row, err) != .ERROR_NONE) return;
                } else {
                    // NORMAL mode: a failed conversion aborts the query —
                    // populate the already-live error slot and stop, rather
                    // than silently producing NULL (see this file's module
                    // doc comment on castFn's return convention).
                    const msg = helpers.str("cast failed");
                    _ = v2.duckdb_v2_error_info_set_code(err.*, .ERROR_API);
                    _ = v2.duckdb_v2_error_info_set_text(err.*, &msg);
                    return;
                }
            }
        }

        /// Dedicated path for a VARIANT source type: no committed view
        /// layout, so each cell is read one at a time as a boxed `Value`
        /// via `vectorGetValue` — `castFn` receives the `Value` directly
        /// (borrowed for the call only; the framework destroys it after),
        /// deciding for itself what a NULL VARIANT cell means (mirrors
        /// `comptime_scalar_v2.zig`'s VARIANT-argument convention). A NULL
        /// *row* (the cast input itself being SQL NULL, as opposed to a
        /// non-NULL VARIANT cell holding the value NULL) still short-
        /// circuits to a NULL output row without calling `castFn` — same
        /// as every other source type.
        fn executeFromVariant(info: v2.duckdb_v2_cast_function_exec_info_handle, context: v2.duckdb_v2_context_handle, mode: v2.DUCKDB_V2_CAST_MODE, output_vec: v2.duckdb_v2_vector_handle, row_count: u64, err: *v2.duckdb_v2_error_info_handle) void {
            var input_vec: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_cast_function_exec_get_input(info, &input_vec, err) != .ERROR_NONE) return;

            var out: [*]WriteType = undefined;
            var enum_out: EnumOut = undefined;
            if (comptime target_is_enum) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(output_vec, &out_data, err) != .ERROR_NONE) return;
                enum_out = @ptrCast(@alignCast(out_data));
            } else if (comptime !target_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(output_vec, &out_data, err) != .ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                var value: v2.duckdb_v2_value_handle = undefined;
                if (v2.duckdb_v2_vector_get_value(input_vec, row, &value, err) != .ERROR_NONE) return;
                defer _ = v2.duckdb_v2_value_destroy(&value);

                if (castFn(value)) |result| {
                    if (comptime target_is_varchar) {
                        var v: v2.duckdb_v2_value_handle = undefined;
                        if (helpers.createVarcharValue(context, result, &v, err) != .ERROR_NONE) return;
                        defer _ = v2.duckdb_v2_value_destroy(&v);
                        if (v2.duckdb_v2_vector_set_value(output_vec, row, v, err) != .ERROR_NONE) return;
                    } else if (comptime target_is_enum) {
                        enum_out[row] = encodeEnumOrdinal(TargetT, result);
                    } else if (comptime target_is_decimal) {
                        out[row] = result.raw;
                    } else {
                        out[row] = result;
                    }
                } else if (mode == .CAST_MODE_TRY) {
                    if (v2.duckdb_v2_vector_set_null(output_vec, row, err) != .ERROR_NONE) return;
                } else {
                    const msg = helpers.str("cast failed");
                    _ = v2.duckdb_v2_error_info_set_code(err.*, .ERROR_API);
                    _ = v2.duckdb_v2_error_info_set_text(err.*, &msg);
                    return;
                }
            }
        }

        fn StructFieldCount(comptime T: type) usize {
            return @typeInfo(T).@"struct".field_types.len;
        }

        /// A target STRUCT field's write handle: a cached flat-buffer
        /// pointer for a numeric/bool field, or the field's own child
        /// `VectorHandle` for `[]const u8` (boxed through `vectorSetValue`
        /// per row) — mirrors `comptime_scalar_v2.zig`'s identical
        /// `StructFieldWriteHandle`.
        fn TargetFieldWriteHandle(comptime FT: type) type {
            return if (FT == []const u8) v2.duckdb_v2_vector_handle else [*]FT;
        }

        fn MakeTargetChildPtrsTuple() type {
            if (comptime !target_is_struct) return void;
            const fields = @typeInfo(TargetT).@"struct";
            var types: [fields.field_types.len]type = undefined;
            for (fields.field_types, 0..) |ft, i| types[i] = TargetFieldWriteHandle(ft);
            return @Tuple(&types);
        }
        const TargetChildPtrs = MakeTargetChildPtrsTuple();

        /// Dedicated path for a STRUCT source and/or target type: each
        /// field is addressed directly via `vectorGetChild`/index on
        /// whichever side(s) are STRUCT, one level deep (fields must be
        /// numeric/bool/`[]const u8`) — mirrors
        /// `comptime_scalar_v2.zig`'s `executeStruct`. The non-STRUCT side
        /// (if any) still supports plain/VARCHAR/DECIMAL/ENUM, same as the
        /// main `execute` path.
        fn executeStruct(info: v2.duckdb_v2_cast_function_exec_info_handle, context: v2.duckdb_v2_context_handle, mode: v2.DUCKDB_V2_CAST_MODE, output_vec: v2.duckdb_v2_vector_handle, row_count: u64, err: *v2.duckdb_v2_error_info_handle) void {
            var input_vec: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_cast_function_exec_get_input(info, &input_vec, err) != .ERROR_NONE) return;
            if (v2.duckdb_v2_vector_flatten(input_vec, err) != .ERROR_NONE) return;

            const SourceViews = if (comptime source_is_struct) [StructFieldCount(SourceT)]v2.duckdb_v2_vector_view else v2.duckdb_v2_vector_view;
            var source_views: SourceViews = undefined;
            if (comptime source_is_struct) {
                const fields = @typeInfo(SourceT).@"struct";
                inline for (0..fields.field_types.len) |f| {
                    var child_vec: v2.duckdb_v2_vector_handle = undefined;
                    if (v2.duckdb_v2_vector_get_child(input_vec, f, &child_vec, err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_flatten(child_vec, err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_get_view(child_vec, &source_views[f], err) != .ERROR_NONE) return;
                }
            } else {
                if (v2.duckdb_v2_vector_get_view(input_vec, &source_views, err) != .ERROR_NONE) return;
            }

            var target_child_ptrs: TargetChildPtrs = undefined;
            var out: [*]WriteType = undefined;
            if (comptime target_is_struct) {
                const fields = @typeInfo(TargetT).@"struct";
                inline for (0..fields.field_types.len) |f| {
                    const FT = fields.field_types[f];
                    var child_vec: v2.duckdb_v2_vector_handle = undefined;
                    if (v2.duckdb_v2_vector_get_child(output_vec, f, &child_vec, err) != .ERROR_NONE) return;
                    if (comptime FT == []const u8) {
                        target_child_ptrs[f] = child_vec;
                    } else {
                        var out_data: ?*anyopaque = null;
                        if (v2.duckdb_v2_vector_get_data_mutable(child_vec, &out_data, err) != .ERROR_NONE) return;
                        target_child_ptrs[f] = @ptrCast(@alignCast(out_data));
                    }
                }
            } else if (comptime !target_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(output_vec, &out_data, err) != .ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                if (!structSourceRowIsValid(&source_views, row)) {
                    if (v2.duckdb_v2_vector_set_null(output_vec, row, err) != .ERROR_NONE) return;
                    continue;
                }

                const source_value = buildStructSource(&source_views, row);
                if (castFn(source_value)) |value| {
                    if (comptime target_is_struct) {
                        const fields = @typeInfo(TargetT).@"struct";
                        inline for (0..fields.field_types.len) |f| {
                            const FT = fields.field_types[f];
                            const field_value = @field(value, fields.field_names[f]);
                            if (comptime FT == []const u8) {
                                var v: v2.duckdb_v2_value_handle = undefined;
                                if (helpers.createVarcharValue(context, field_value, &v, err) != .ERROR_NONE) return;
                                defer _ = v2.duckdb_v2_value_destroy(&v);
                                if (v2.duckdb_v2_vector_set_value(target_child_ptrs[f], row, v, err) != .ERROR_NONE) return;
                            } else {
                                target_child_ptrs[f][row] = field_value;
                            }
                        }
                    } else if (comptime target_is_varchar) {
                        var v: v2.duckdb_v2_value_handle = undefined;
                        if (helpers.createVarcharValue(context, value, &v, err) != .ERROR_NONE) return;
                        defer _ = v2.duckdb_v2_value_destroy(&v);
                        if (v2.duckdb_v2_vector_set_value(output_vec, row, v, err) != .ERROR_NONE) return;
                    } else if (comptime target_is_decimal) {
                        out[row] = value.raw;
                    } else {
                        out[row] = value;
                    }
                } else if (mode == .CAST_MODE_TRY) {
                    if (v2.duckdb_v2_vector_set_null(output_vec, row, err) != .ERROR_NONE) return;
                } else {
                    const msg = helpers.str("cast failed");
                    _ = v2.duckdb_v2_error_info_set_code(err.*, .ERROR_API);
                    _ = v2.duckdb_v2_error_info_set_text(err.*, &msg);
                    return;
                }
            }
        }

        inline fn structSourceRowIsValid(views: anytype, row: u64) bool {
            if (comptime source_is_struct) {
                const fields = @typeInfo(SourceT).@"struct";
                inline for (0..fields.field_types.len) |f| {
                    if (views.*[f].validity) |validity| {
                        const entry_idx = row / 64;
                        const bit_idx: u6 = @intCast(row % 64);
                        if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return false;
                    }
                }
                return true;
            }
            if (views.*.validity) |validity| {
                const entry_idx = row / 64;
                const bit_idx: u6 = @intCast(row % 64);
                return (validity[entry_idx] & (@as(u64, 1) << bit_idx)) != 0;
            }
            return true;
        }

        inline fn buildStructSource(views: anytype, row: u64) SourceT {
            if (comptime source_is_struct) {
                const fields = @typeInfo(SourceT).@"struct";
                var val: SourceT = undefined;
                inline for (0..fields.field_types.len) |f| {
                    const FT = fields.field_types[f];
                    const fname = fields.field_names[f];
                    if (comptime FT == []const u8) {
                        const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views.*[f].data));
                        @field(val, fname) = helpers.bytesSlice(&typed[row]);
                    } else {
                        const typed: [*]const FT = @ptrCast(@alignCast(views.*[f].data));
                        @field(val, fname) = typed[row];
                    }
                }
                return val;
            }
            if (comptime SourceT == []const u8) {
                const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views.*.data));
                return helpers.bytesSlice(&typed[row]);
            }
            if (comptime source_is_decimal) {
                const typed: [*]const SourceT.Raw = @ptrCast(@alignCast(views.*.data));
                return .{ .raw = typed[row] };
            }
            if (comptime source_is_enum) {
                return decodeEnumValue(SourceT, views.*, row);
            }
            const typed: [*]const SourceT = @ptrCast(@alignCast(views.*.data));
            return typed[row];
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
    const exec_cb: v2.duckdb_v2_cast_function_exec_callback_fn = DoubleToBigint.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
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
    const exec_cb: v2.duckdb_v2_cast_function_exec_callback_fn = StrictVarcharToInt.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports DECIMAL as either source or target type" {
    const Price = v2_values.Decimal(10, 2);
    const PriceToDouble = Function(Price, f64, struct {
        fn cast(p: Price) ?f64 {
            return @as(f64, @floatFromInt(p.raw)) / 100.0;
        }
    }.cast);
    _ = &PriceToDouble.register;

    const DoubleToPrice = Function(f64, Price, struct {
        fn cast(d: f64) ?Price {
            return .{ .raw = @intFromFloat(@round(d * 100.0)) };
        }
    }.cast);
    _ = &DoubleToPrice.register;
}

test "Function supports ENUM as either source or target type" {
    const Status = enum(u8) { pending = 5, active = 10, done = 20 };
    const StatusToVarchar = Function(Status, []const u8, struct {
        fn cast(s: Status) ?[]const u8 {
            return @tagName(s);
        }
    }.cast);
    _ = &StatusToVarchar.register;

    const VarcharToStatus = Function([]const u8, Status, struct {
        fn cast(s: []const u8) ?Status {
            return std.meta.stringToEnum(Status, s);
        }
    }.cast);
    _ = &VarcharToStatus.register;
}

test "Function supports STRUCT as either source or target type" {
    const Point = struct { x: i64, y: i64 };
    const PointToVarchar = Function(Point, []const u8, struct {
        fn cast(p: Point) ?[]const u8 {
            _ = p;
            return "point";
        }
    }.cast);
    _ = &PointToVarchar.register;

    const IntToPoint = Function(i64, Point, struct {
        fn cast(n: i64) ?Point {
            return .{ .x = n, .y = n };
        }
    }.cast);
    _ = &IntToPoint.register;
}

test "Function supports VARIANT as a source type (target-only is a compile error, see module doc comment)" {
    const VariantToInt = Function(v2.duckdb_v2_value_handle, i64, struct {
        fn cast(v: v2.duckdb_v2_value_handle) ?i64 {
            var err: v2.duckdb_v2_error_info_handle = undefined;
            var is_null: bool = false;
            _ = v2.duckdb_v2_value_is_null(v, &is_null, &err);
            return if (is_null) null else 0;
        }
    }.cast);
    _ = &VariantToInt.register;
    const exec_cb: v2.duckdb_v2_cast_function_exec_callback_fn = VariantToInt.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}
