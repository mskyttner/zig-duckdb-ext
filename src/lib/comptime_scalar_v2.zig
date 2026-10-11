///! Comptime scalar function framework for the DuckDB v2 C Extension API.
///!
///! A v2 port of `comptime_scalar.zig`'s `Function(name, implFn)` pattern,
///! generating the same vectorized-callback-from-a-per-row-function
///! boilerplate, adapted to v2's error-returning, out-param calling
///! convention and extension-based (not connection-based) registration.
///! Supports the same numeric types as the v1 framework (i8, i16, i32, i64,
///! f32, f64, bool), plus `[]const u8` for VARCHAR parameters and/or return
///! type — see duckdb_v2.zig's `bytesSlice`/`valueCreateVarcharWithContext`
///! doc comments for how vector-stored strings differ from numeric types.
///! Also: `db.Date`/`db.Time`/`db.Timestamp`/`db.Interval` (fixed-width,
///! same direct-buffer path as the numeric types — see their doc comments
///! in duckdb_v2.zig for why no new exec-path code was needed) and
///! `db.Blob` (VARCHAR's `BytesValue`/boxed-`Value` machinery, reused as-is,
///! just tagged as BLOB instead of VARCHAR at registration).
///!
///! CAUTION: a `[]const u8`-returning `implFn` must return a slice that
///! outlives the call — one borrowed from its own arguments (a substring,
///! or an argument unchanged), a string literal, or heap/static memory.
///! It must NOT return a slice into its own local stack buffer: the result
///! is boxed into a Value immediately after `implFn` returns, by which
///! point a local buffer's storage is already gone. (The hand-written
///! `zig_v2_hello` example in duckdb_v2.zig sidesteps this by building and
///! consuming its buffer inline, before returning — not available to a
///! plain per-row function passed through this framework.)
///!
///! Two more parameter/return shapes, each handled by its own dedicated
///! exec path (the common numeric/VARCHAR path above is untouched by
///! either):
///!
///! - A plain Zig `struct` parameter type (one level deep — fields must be
///!   a numeric/bool/`[]const u8` type, not another struct) maps to SQL
///!   STRUCT, with the struct's own field names used as the real STRUCT
///!   field names (available at comptime, unlike a function parameter's
///!   name). Read-only: a STRUCT-typed *return* isn't supported yet (the
///!   natural next step once this is needed — see `docs/v2-migration-plan.md`).
///! - `db.ValueHandle` as a parameter or return type maps to SQL VARIANT:
///!   `implFn` receives/returns a boxed `Value` directly rather than a
///!   decoded Zig value, since VARIANT's dynamic, runtime-chosen content
///!   type has no single Zig type to decode into. Unlike every other
///!   parameter type, a VARIANT argument does NOT participate in the
///!   automatic "any NULL argument skips the row" convention — SQL NULL is
///!   ordinary data VARIANT can hold, not an absent argument, so `implFn`
///!   always runs and decides what NULL means itself, via `db.valueIsNull`
///!   (see `zig_v2_variant_default_ct` in `init_v2_poc.zig` for the
///!   pattern: substitute a fallback when NULL, decode otherwise). A
///!   VARIANT argument value is borrowed for the call only (the framework
///!   destroys it after `implFn` returns); a VARIANT return value is
///!   consumed the same way (the framework destroys it after writing it
///!   out). CAUTION: a
///!   VARIANT-returning `implFn` must return a freshly created `Value`
///!   (e.g. via `valueCreateBigintWithContext`), never a VARIANT argument
///!   it was handed unchanged — the framework destroys the return value
///!   AND every VARIANT argument independently, so returning the same
///!   handle it received double-frees it.
///!
///! Usage:
///!   const MyFn = comptime_scalar_v2.Function("my_double", struct {
///!       fn eval(a: i64) i64 { return a * 2; }
///!   }.eval);
///!   try MyFn.register(input); // input: *const db2.ExtensionInput
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
        db.ValueHandle => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARIANT,
        db.Blob => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_BLOB,
        db.Date => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_DATE,
        db.Time => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_TIME,
        db.Timestamp => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_TIMESTAMP,
        db.Interval => db.c.DUCKDB_V2_LOGICAL_TYPE_ID_INTERVAL,
        else => @compileError("unsupported type for DuckDB v2 mapping: " ++ @typeName(T)),
    };
}

fn isStructType(comptime T: type) bool {
    // db.Blob is a Zig struct (wraps a []const u8) but must never be
    // treated as a one-field SQL STRUCT — it has its own VARCHAR-like
    // Value-boxing path instead (see the `return_is_blob`/`T == db.Blob`
    // branches below).
    if (T == db.Blob) return false;
    return @typeInfo(T) == .@"struct";
}

/// Build the logical type for a plain (non-struct) Zig type T. VARIANT
/// goes through `contextCreateTypeFromText` instead of
/// `contextCreateTypeFromId` — see that function's doc comment for why.
fn createLogicalType(ctx: db.ContextHandle, comptime T: type, out_type: *db.LogicalTypeHandle, err: *db.ErrorInfoHandle) db.ErrorCode {
    if (comptime T == db.ValueHandle) {
        return db.contextCreateTypeFromText(ctx, "VARIANT", out_type, err);
    }
    return db.contextCreateTypeFromId(ctx, duckdbV2TypeId(T), out_type, err);
}

/// Define a v2 DuckDB scalar function from a comptime-known Zig function.
///
/// If `implFn` involves VARIANT anywhere (a `db.ValueHandle` parameter or
/// return type), its FIRST parameter must be `context: db.ContextHandle`,
/// not counted as a SQL parameter — constructing a `Value` to return
/// always needs a context in v2 (see `duckdb_v2.zig`'s own note on type/
/// value construction being context-scoped), and `implFn` has no other way
/// to reach one.
pub fn Function(comptime name: [:0]const u8, comptime implFn: anytype) type {
    const fn_info = @typeInfo(@TypeOf(implFn)).@"fn";
    const raw_param_types = fn_info.param_types;
    const ReturnType = fn_info.return_type.?;

    const return_is_variant = ReturnType == db.ValueHandle;
    const raw_has_variant_arg = blk: {
        inline for (raw_param_types) |t| {
            if (t.? == db.ValueHandle) break :blk true;
        }
        break :blk false;
    };
    const needs_context = return_is_variant or raw_has_variant_arg;
    if (needs_context and (raw_param_types.len == 0 or raw_param_types[0].? != db.ContextHandle)) {
        @compileError("a VARIANT-involving Function's implFn must take `context: db.ContextHandle` as its first parameter");
    }
    const param_types = if (needs_context) raw_param_types[1..] else raw_param_types;

    inline for (param_types) |t| {
        if (comptime !isStructType(t.?)) _ = duckdbV2TypeId(t.?);
    }
    _ = duckdbV2TypeId(ReturnType);

    const has_variant_arg = raw_has_variant_arg;
    const has_struct_arg = blk: {
        inline for (param_types) |t| {
            if (comptime isStructType(t.?)) break :blk true;
        }
        break :blk false;
    };

    return struct {
        /// Register this scalar function against the extension being loaded.
        /// Must be called from inside the v2 extension entrypoint, which is
        /// handed both an `extension` handle (to create the function) and a
        /// `context` handle (to create logical types — v2 has no
        /// handle-less type constructor, see `duckdb_v2.zig`'s own note).
        pub fn register(input: *const db.ExtensionInput) !void {
            var err: db.ErrorInfoHandle = undefined;

            var function: db.ScalarFunctionHandle = undefined;
            if (db.scalarFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = db.scalarFunctionDestroy(&function);

            const fn_name = db.str(name);
            if (db.scalarFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetName;
            }

            var sig: db.FunctionSignatureHandle = undefined;
            if (db.scalarFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToGetSignature;
            }

            inline for (param_types, 0..) |t, i| {
                const T = t.?;
                var param_type: db.LogicalTypeHandle = undefined;
                if (comptime isStructType(T)) {
                    const fields = @typeInfo(T).@"struct";
                    const n = fields.field_types.len;
                    var field_logical_types: [n]db.LogicalTypeHandle = undefined;
                    inline for (0..n) |f| {
                        if (createLogicalType(input.context, fields.field_types[f], &field_logical_types[f], &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                            return error.FailedToCreateParamType;
                        }
                    }
                    defer inline for (0..n) |f| {
                        _ = db.logicalTypeDestroy(&field_logical_types[f]);
                    };
                    var field_names: [n]db.IdentifierT = undefined;
                    inline for (0..n) |f| {
                        field_names[f] = db.str(fields.field_names[f]);
                    }
                    var field_type_values: [n]db.ValueHandle = undefined;
                    if (db.contextCreateStructType(input.context, &field_names, &field_logical_types, &field_type_values, &param_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                        return error.FailedToCreateParamType;
                    }
                    defer inline for (0..n) |f| {
                        _ = db.valueDestroy(&field_type_values[f]);
                    };
                } else {
                    if (createLogicalType(input.context, T, &param_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                        return error.FailedToCreateParamType;
                    }
                }
                defer _ = db.logicalTypeDestroy(&param_type);

                // Zig function parameters carry no names at the ABI level —
                // synthesize positional names ("a0", "a1", ...) since v2's
                // signature requires one per parameter.
                const param_name_buf = std.fmt.comptimePrint("a{d}", .{i});
                const param_name = db.str(param_name_buf);
                if (db.functionSignatureAddParameter(
                    sig,
                    &param_name,
                    param_type,
                    null,
                    db.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD,
                    &err,
                ) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToAddParameter;
                }
            }

            var return_type: db.LogicalTypeHandle = undefined;
            if (createLogicalType(input.context, ReturnType, &return_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateReturnType;
            }
            defer _ = db.logicalTypeDestroy(&return_type);
            if (db.functionSignatureSetReturnType(sig, return_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetReturnType;
            }

            if (db.scalarFunctionSetExecCallback(function, execute, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetExecCallback;
            }

            if (comptime has_variant_arg) {
                if (db.scalarFunctionSetNullHandlingSpecial(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToSetNullHandling;
                }
            }

            if (db.scalarFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }

        const return_is_varchar = ReturnType == []const u8;
        const return_is_blob = ReturnType == db.Blob;

        /// Vectorized exec callback invoked by DuckDB for each batch of rows.
        fn execute(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var row_count: db.idx_t = 0;
            if (db.scalarFunctionExecGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var result_vec: db.VectorHandle = undefined;
            if (db.scalarFunctionExecGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            if (db.vectorSetSize(result_vec, row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            if (comptime has_variant_arg or return_is_variant) {
                return executeDynamic(info, context, result_vec, row_count, err);
            }
            if (comptime has_struct_arg) {
                return executeStruct(info, context, result_vec, row_count, err);
            }

            // Cache each argument's view (flattened first — sequence/FSST/
            // dictionary-encoded args aren't directly readable otherwise,
            // see duckdb_v2.zig's vectorFlatten doc comment).
            var views: [param_types.len]db.VectorView = undefined;
            inline for (0..param_types.len) |i| {
                var arg_vec: db.VectorHandle = undefined;
                if (db.scalarFunctionExecGetArg(info, i, &arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                if (db.vectorFlatten(arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                if (db.vectorGetView(arg_vec, &views[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            }

            var has_nulls = false;
            inline for (0..param_types.len) |i| {
                if (views[i].validity != null) has_nulls = true;
            }

            // VARCHAR/BLOB results can't be written through a flat typed
            // buffer (variable width) — each row boxes through a Value
            // instead, via duckdb_v2.zig's valueCreateVarcharWithContext/
            // valueCreateBlobWithContext + vectorSetValue.
            if (comptime return_is_varchar or return_is_blob) {
                var row: db.idx_t = 0;
                while (row < row_count) : (row += 1) {
                    if (has_nulls and !rowIsValid(&views, row)) {
                        if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        continue;
                    }
                    const produced = invoke(&views, row);
                    const bytes = if (comptime return_is_blob) produced.bytes else produced;
                    var value: db.ValueHandle = undefined;
                    const create_err = if (comptime return_is_blob)
                        db.valueCreateBlobWithContext(context, bytes, &value, err)
                    else
                        db.valueCreateVarcharWithContext(context, bytes, &value, err);
                    if (create_err != db.c.DUCKDB_V2_ERROR_NONE) return;
                    defer _ = db.valueDestroy(&value);
                    if (db.vectorSetValue(result_vec, row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                }
                return;
            }

            var out_data: ?*anyopaque = null;
            if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            // SAFETY: types were validated at comptime against the registered signature.
            const result: [*]ReturnType = @ptrCast(@alignCast(out_data));

            if (has_nulls) {
                var row: db.idx_t = 0;
                while (row < row_count) : (row += 1) {
                    if (rowIsValid(&views, row)) {
                        result[row] = invoke(&views, row);
                    } else {
                        if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    }
                }
            } else {
                var row: db.idx_t = 0;
                while (row < row_count) : (row += 1) {
                    result[row] = invoke(&views, row);
                }
            }
        }

        inline fn rowIsValid(views: *const [param_types.len]db.VectorView, row: db.idx_t) bool {
            inline for (0..param_types.len) |i| {
                if (views.*[i].validity) |validity| {
                    const entry_idx = row / 64;
                    const bit_idx: u6 = @intCast(row % 64);
                    if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return false;
                }
            }
            return true;
        }

        fn MakeArgsTuple() type {
            var types: [param_types.len]type = undefined;
            for (0..param_types.len) |i| types[i] = param_types[i].?;
            return @Tuple(&types);
        }
        const ArgsTuple = MakeArgsTuple();

        inline fn invoke(views: *const [param_types.len]db.VectorView, row: db.idx_t) ReturnType {
            var args: ArgsTuple = undefined;
            inline for (0..param_types.len) |i| {
                const T = param_types[i].?;
                if (T == []const u8) {
                    // SAFETY: views[i].data points to a flattened VARCHAR vector's
                    // duckdb_v2_bytes elements (the signature registered this param as VARCHAR).
                    const typed: [*]const db.BytesValue = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = db.bytesSlice(&typed[row]);
                } else if (T == db.Blob) {
                    // SAFETY: same duckdb_v2_bytes storage shape as VARCHAR,
                    // registered as BLOB instead (see duckdbV2TypeId).
                    const typed: [*]const db.BytesValue = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = .{ .bytes = db.bytesSlice(&typed[row]) };
                } else {
                    // SAFETY: views[i].data points to a flattened, type-matched vector buffer.
                    const typed: [*]const T = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = typed[row];
                }
            }
            return @call(.auto, implFn, args);
        }

        /// Dedicated exec path for any VARIANT argument or return type.
        /// VARIANT has no committed view layout (no `vectorGetView` support)
        /// — each VARIANT cell is read/written one at a time as a boxed
        /// `Value` via `vectorGetValue`/`vectorSetValue` instead, so this
        /// path skips the shared view-caching machinery entirely rather
        /// than bolting VARIANT's row-by-row shape onto it.
        fn executeDynamic(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, result_vec: db.VectorHandle, row_count: db.idx_t, err: [*c]db.ErrorInfoHandle) void {
            var arg_vecs: [param_types.len]db.VectorHandle = undefined;
            var views: [param_types.len]db.VectorView = undefined;
            inline for (0..param_types.len) |i| {
                if (db.scalarFunctionExecGetArg(info, i, &arg_vecs[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                if (comptime param_types[i].? != db.ValueHandle) {
                    if (db.vectorFlatten(arg_vecs[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    if (db.vectorGetView(arg_vecs[i], &views[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                }
            }

            var out: [*]ReturnType = undefined;
            if (comptime !return_is_variant and !return_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: db.idx_t = 0;
            while (row < row_count) : (row += 1) {
                var args: ArgsTuple = undefined;
                var fetched: [param_types.len]?db.ValueHandle = undefined;
                inline for (0..param_types.len) |i| fetched[i] = null;
                var row_valid = true;

                inline for (0..param_types.len) |i| {
                    const T = param_types[i].?;
                    if (comptime T == db.ValueHandle) {
                        // Deliberately does NOT participate in the automatic
                        // NULL-skip every other type gets: VARIANT's NULL is
                        // ordinary data (SQL NULL is a value VARIANT can
                        // hold), not an absent argument, so implFn decides
                        // what it means — calling `valueIsNull` itself if it
                        // cares, same as `zig_v2_variant_default_ct` does.
                        var value: db.ValueHandle = undefined;
                        if (db.vectorGetValue(arg_vecs[i], row, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        fetched[i] = value;
                        args[i] = value;
                    } else {
                        if (views[i].validity) |validity| {
                            const entry_idx = row / 64;
                            const bit_idx: u6 = @intCast(row % 64);
                            if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) row_valid = false;
                        }
                        if (comptime T == []const u8) {
                            const typed: [*]const db.BytesValue = @ptrCast(@alignCast(views[i].data));
                            args[i] = db.bytesSlice(&typed[row]);
                        } else {
                            const typed: [*]const T = @ptrCast(@alignCast(views[i].data));
                            args[i] = typed[row];
                        }
                    }
                }

                defer inline for (0..param_types.len) |i| {
                    if (comptime param_types[i].? == db.ValueHandle) {
                        if (fetched[i]) |v| {
                            var vv = v;
                            _ = db.valueDestroy(&vv);
                        }
                    }
                };

                if (!row_valid) {
                    if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    continue;
                }

                // executeDynamic only runs when needs_context is true (see
                // the branch in `execute`), so implFn always takes context first.
                const result = @call(.auto, implFn, .{context} ++ args);
                if (comptime return_is_variant) {
                    var rv = result;
                    if (db.vectorSetValue(result_vec, row, rv, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    _ = db.valueDestroy(&rv);
                } else if (comptime return_is_varchar) {
                    var value: db.ValueHandle = undefined;
                    if (db.valueCreateVarcharWithContext(context, result, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    defer _ = db.valueDestroy(&value);
                    if (db.vectorSetValue(result_vec, row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                } else {
                    out[row] = result;
                }
            }
        }

        fn StructFieldCount(comptime T: type) usize {
            return @typeInfo(T).@"struct".field_types.len;
        }

        fn ViewsFor(comptime T: type) type {
            return if (comptime isStructType(T)) [StructFieldCount(T)]db.VectorView else db.VectorView;
        }

        fn MakeViewsTuple() type {
            var types: [param_types.len]type = undefined;
            for (0..param_types.len) |i| types[i] = ViewsFor(param_types[i].?);
            return @Tuple(&types);
        }
        const ViewsTuple = MakeViewsTuple();

        /// Dedicated exec path for a STRUCT-typed argument: each field's
        /// child vector is addressed directly via `vectorGetChild`/index
        /// (no `ListEntry`-style offset/length indirection, unlike LIST —
        /// a STRUCT field is already aligned 1:1 with the parent's rows),
        /// flattened and view-cached the same way a plain argument is.
        /// DuckDB's nested-NULL invariant (a NULL STRUCT row implies NULL
        /// field rows) means checking each field's own validity bit is
        /// sufficient — no separate STRUCT-level validity check is needed.
        fn executeStruct(info: db.ScalarFunctionExecInfoHandle, context: db.ContextHandle, result_vec: db.VectorHandle, row_count: db.idx_t, err: [*c]db.ErrorInfoHandle) void {
            var arg_vecs: [param_types.len]db.VectorHandle = undefined;
            var views: ViewsTuple = undefined;
            inline for (0..param_types.len) |i| {
                if (db.scalarFunctionExecGetArg(info, i, &arg_vecs[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                const T = param_types[i].?;
                if (comptime isStructType(T)) {
                    const fields = @typeInfo(T).@"struct";
                    inline for (0..fields.field_types.len) |f| {
                        var child_vec: db.VectorHandle = undefined;
                        if (db.vectorGetChild(arg_vecs[i], f, &child_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        if (db.vectorFlatten(child_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        if (db.vectorGetView(child_vec, &views[i][f], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    }
                } else {
                    if (db.vectorFlatten(arg_vecs[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    if (db.vectorGetView(arg_vecs[i], &views[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                }
            }

            var out: [*]ReturnType = undefined;
            if (comptime !return_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: db.idx_t = 0;
            while (row < row_count) : (row += 1) {
                if (!structRowIsValid(&views, row)) {
                    if (db.vectorSetNull(result_vec, row, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    continue;
                }
                const args = buildStructArgs(&views, row);
                const result = @call(.auto, implFn, args);
                if (comptime return_is_varchar) {
                    var value: db.ValueHandle = undefined;
                    if (db.valueCreateVarcharWithContext(context, result, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    defer _ = db.valueDestroy(&value);
                    if (db.vectorSetValue(result_vec, row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                } else {
                    out[row] = result;
                }
            }
        }

        inline fn structRowIsValid(views: *const ViewsTuple, row: db.idx_t) bool {
            inline for (0..param_types.len) |i| {
                const T = param_types[i].?;
                if (comptime isStructType(T)) {
                    const fields = @typeInfo(T).@"struct";
                    inline for (0..fields.field_types.len) |f| {
                        if (views.*[i][f].validity) |validity| {
                            const entry_idx = row / 64;
                            const bit_idx: u6 = @intCast(row % 64);
                            if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return false;
                        }
                    }
                } else {
                    if (views.*[i].validity) |validity| {
                        const entry_idx = row / 64;
                        const bit_idx: u6 = @intCast(row % 64);
                        if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return false;
                    }
                }
            }
            return true;
        }

        inline fn buildStructArgs(views: *const ViewsTuple, row: db.idx_t) ArgsTuple {
            var args: ArgsTuple = undefined;
            inline for (0..param_types.len) |i| {
                const T = param_types[i].?;
                if (comptime isStructType(T)) {
                    const fields = @typeInfo(T).@"struct";
                    var val: T = undefined;
                    inline for (0..fields.field_types.len) |f| {
                        const FT = fields.field_types[f];
                        const fname = fields.field_names[f];
                        if (comptime FT == []const u8) {
                            const typed: [*]const db.BytesValue = @ptrCast(@alignCast(views.*[i][f].data));
                            @field(val, fname) = db.bytesSlice(&typed[row]);
                        } else {
                            const typed: [*]const FT = @ptrCast(@alignCast(views.*[i][f].data));
                            @field(val, fname) = typed[row];
                        }
                    }
                    args[i] = val;
                } else if (comptime T == []const u8) {
                    const typed: [*]const db.BytesValue = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = db.bytesSlice(&typed[row]);
                } else {
                    const typed: [*]const T = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = typed[row];
                }
            }
            return args;
        }
    };
}

test "Function generates a valid Zig type" {
    const Double = Function("v2_test_double", struct {
        fn eval(a: i64) i64 {
            return a * 2;
        }
    }.eval);
    // Referencing .register forces Zig to semantically analyze its body
    // (the comptime-unrolled signature-building loop) even though nothing
    // calls it in this test; .execute is separately forced below by
    // matching it against the exact callback type.
    _ = &Double.register;
    const exec_cb: db.ScalarFunctionExecCallback = Double.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports multiple parameters of different types" {
    const Mix = Function("v2_test_mix", struct {
        fn eval(a: i64, b: f64, c: bool) f64 {
            return if (c) @as(f64, @floatFromInt(a)) + b else b;
        }
    }.eval);
    _ = &Mix.register;
    const exec_cb: db.ScalarFunctionExecCallback = Mix.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports VARCHAR parameter and return type" {
    // Safe per the CAUTION above: returns a slice borrowed from its own
    // argument, never a local buffer.
    const FirstChar = Function("v2_test_first_char", struct {
        fn eval(s: []const u8) []const u8 {
            return s[0..@min(1, s.len)];
        }
    }.eval);
    _ = &FirstChar.register;
    const exec_cb: db.ScalarFunctionExecCallback = FirstChar.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports a one-level STRUCT argument" {
    const Point = struct { x: i64, y: i64 };
    const Dist2 = Function("v2_test_struct_dist2", struct {
        fn eval(p: Point) i64 {
            return p.x * p.x + p.y * p.y;
        }
    }.eval);
    _ = &Dist2.register;
    const exec_cb: db.ScalarFunctionExecCallback = Dist2.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports a STRUCT argument with a VARCHAR field, mixed with a plain argument" {
    const Named = struct { label: []const u8, count: i64 };
    const Describe = Function("v2_test_struct_varchar_field", struct {
        fn eval(n: Named, scale: i64) i64 {
            return @as(i64, @intCast(n.label.len)) + n.count * scale;
        }
    }.eval);
    _ = &Describe.register;
    const exec_cb: db.ScalarFunctionExecCallback = Describe.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports VARIANT as a parameter and return type" {
    // Per the CAUTION above: returns a freshly created Value, never `v`
    // itself (which would double-free, since the framework destroys both
    // the argument and the return value independently).
    const IsNull = Function("v2_test_variant_is_null", struct {
        fn eval(context: db.ContextHandle, v: db.ValueHandle) bool {
            _ = context;
            var err: db.ErrorInfoHandle = undefined;
            var is_null: bool = false;
            _ = db.valueIsNull(v, &is_null, &err);
            return is_null;
        }
    }.eval);
    _ = &IsNull.register;
    const exec_cb: db.ScalarFunctionExecCallback = IsNull.execute;
    try std.testing.expect(exec_cb != null);
}

test "Function supports the smaller integer/float types" {
    const Narrow = Function("v2_test_narrow_types", struct {
        fn eval(a: i8, b: i16, c: i32, d: f32) f32 {
            return @as(f32, @floatFromInt(@as(i32, a) + @as(i32, b) + c)) + d;
        }
    }.eval);
    _ = &Narrow.register;
}

test "Function supports DATE/TIME/TIMESTAMP/INTERVAL" {
    const DateTimeStuff = Function("v2_test_date_time", struct {
        fn eval(d: db.Date, t: db.Time, ts: db.Timestamp, iv: db.Interval) db.Timestamp {
            _ = d;
            _ = t;
            _ = iv;
            return ts;
        }
    }.eval);
    _ = &DateTimeStuff.register;
}

test "Function supports BLOB as a parameter and return type" {
    const FirstByte = Function("v2_test_blob_first_byte", struct {
        fn eval(b: db.Blob) db.Blob {
            return .{ .bytes = b.bytes[0..@min(1, b.bytes.len)] };
        }
    }.eval);
    _ = &FirstByte.register;
    const exec_cb: db.ScalarFunctionExecCallback = FirstByte.execute;
    try std.testing.expect(exec_cb != null);
}
