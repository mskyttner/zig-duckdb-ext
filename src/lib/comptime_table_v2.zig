///! Comptime table function framework for the DuckDB v2 C Extension API.
///!
///! A generalization of the original thin registration-boilerplate helper
///! (which required the caller to hand-write bind/init_global/exec), in the
///! same spirit as `comptime_scalar_v2.Function`: derive the vectorized
///! plumbing from a plain Zig shape instead of C-API callbacks.
///!
///! The caller supplies a State type with:
///!   - `pub const Row = struct { field: T, ... };` — the output columns, in
///!     declaration order. Unlike `comptime_scalar_v2`/`comptime_aggregate_v2`
///!     (whose Zig function parameters carry no names at the ABI level), a
///!     struct's field names ARE available at comptime, so Row's field names
///!     become the real SQL column names — no `a0`/`a1` synthesis needed.
///!   - `pub fn init(<args>) State` — constructs per-scan state from the
///!     table function's own call arguments (e.g. `range(n)`'s `n`). `init`'s
///!     parameters become the SQL function's parameters (named `a0`/`a1`/...,
///!     same synthesis `comptime_scalar_v2`/`comptime_aggregate_v2` already
///!     do, since here it's a plain function's parameters, not a struct's
///!     fields).
///!   - `pub fn next(self: *State) ?Row` — pull one row; return `null` once
///!     exhausted. May keep returning `null` on every subsequent call within
///!     the same batch. Every output vector's size must be set (to its final
///!     row count) before any row is written into it — confirmed live — so
///!     `exec` pulls a whole batch of rows via `next` before writing any of
///!     them out. This means a `Row` field's `[]const u8` must stay valid
///!     for the rest of that `exec` call, not just until the next `next`
///!     call: safe when it borrows from stable, unchanging backing storage
///!     (e.g. `ct_tokenize_v2.zig`'s `State.input`), NOT safe if `next`
///!     reuses one mutable scratch buffer across calls.
///!   - `pub fn deinit(self: *State) void` — optional. Called once before
///!     the framework frees `State`, for any resources `init` or `next`
///!     allocated (e.g. a `[]const u8` argument the framework copied onto
///!     the heap before calling `init` — see the note on VARCHAR arguments
///!     below).
///!
///! No bind-time result-column cardinality hint is set (the row count isn't
///! knowable ahead of a pull iterator) and no `init_global`/local-init
///! callback is used — `State` lives entirely in the table function's bind
///! data, forcing the same single-threaded-scan model `tokenize_v2.zig`/
///! `ct_tokenize_v2.zig` already use by hand.
///!
///! VARCHAR arguments: since a bind-time argument `Value` is destroyed
///! before `bind` returns, a `[]const u8` argument is copied onto the heap
///! (`std.heap.c_allocator`) before being passed to `init` — `State` must
///! free any such slice it keeps, in `deinit`.
///!
///! Usage:
///!   const Range = comptime_table_v2.Function("zig_v2_range_ct", struct {
///!       pub const Row = struct { value: i64 };
///!       n: i64,
///!       i: i64,
///!       pub fn init(n: i64) @This() { return .{ .n = n, .i = 0 }; }
///!       pub fn next(self: *@This()) ?Row {
///!           if (self.i >= self.n) return null;
///!           defer self.i += 1;
///!           return .{ .value = self.i };
///!       }
///!   });
///!   try Range.register(input); // input: *const db.ExtensionInput
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
        else => @compileError("unsupported type for DuckDB v2 mapping: " ++ @typeName(T)),
    };
}

/// Maximum rows produced per `exec` call — matches `tokenize_v2.zig`'s
/// hand-written batching (DuckDB's own standard vector size).
const max_rows_per_batch = 2048;

/// Define a v2 DuckDB table function from a comptime-known `State` type.
/// See this file's module doc comment for `State`'s required shape.
pub fn Function(comptime name: [:0]const u8, comptime State: type) type {
    const Row = State.Row;
    const row_info = @typeInfo(Row).@"struct";
    const row_field_names = row_info.field_names;
    const row_field_types = row_info.field_types;
    const num_row_fields = row_field_names.len;
    const init_info = @typeInfo(@TypeOf(State.init)).@"fn";
    const arg_types = init_info.param_types;
    const has_deinit = @hasDecl(State, "deinit");

    inline for (row_field_types) |t| _ = duckdbV2TypeId(t);
    inline for (arg_types) |t| _ = duckdbV2TypeId(t.?);

    return struct {
        pub fn register(input: *const db.ExtensionInput) !void {
            var err: db.ErrorInfoHandle = undefined;

            var function: db.TableFunctionHandle = undefined;
            if (db.tableFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = db.tableFunctionDestroy(&function);

            const fn_name = db.str(name);
            if (db.tableFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetName;
            }

            if (arg_types.len > 0) {
                var sig: db.FunctionSignatureHandle = undefined;
                if (db.tableFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToGetSignature;
                }
                inline for (arg_types, 0..) |t, i| {
                    var param_type: db.LogicalTypeHandle = undefined;
                    if (db.contextCreateTypeFromId(input.context, duckdbV2TypeId(t.?), &param_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                        return error.FailedToCreateParamType;
                    }
                    defer _ = db.logicalTypeDestroy(&param_type);

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
            }

            if (db.tableFunctionSetBindCallback(function, bindCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetBindCallback;
            }
            if (db.tableFunctionSetExecCallback(function, execCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetExecCallback;
            }

            if (db.tableFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }

        fn destroyState(ptr: ?*anyopaque) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(ptr.?));
            if (has_deinit) state.deinit();
            std.heap.c_allocator.destroy(state);
        }

        fn MakeArgsTuple() type {
            var types: [arg_types.len]type = undefined;
            for (0..arg_types.len) |i| types[i] = arg_types[i].?;
            return @Tuple(&types);
        }
        const ArgsTuple = MakeArgsTuple();

        fn bindCallback(info: db.FunctionBindInfoHandle, result: db.TableFunctionBindInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            inline for (row_field_names, row_field_types) |name_, type_| {
                var col_type: db.LogicalTypeHandle = undefined;
                if (db.contextCreateTypeFromId(context, duckdbV2TypeId(type_), &col_type, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                defer _ = db.logicalTypeDestroy(&col_type);
                const col_name = db.str(name_);
                if (db.tableFunctionBindAddResultColumn(result, &col_name, col_type, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            }

            var args: ArgsTuple = undefined;
            inline for (0..arg_types.len) |i| {
                const T = arg_types[i].?;
                var value: db.ValueHandle = undefined;
                if (db.functionBindGetArgValue(info, i, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                defer _ = db.valueDestroy(&value);

                if (T == []const u8) {
                    var s: db.Str = undefined;
                    if (db.valueGetVarchar(value, &s, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    // SAFETY: `s` borrows from `value`, destroyed above once
                    // this iteration ends — copy the bytes out so `State`
                    // can keep them past `bind`'s return (see this file's
                    // doc comment on VARCHAR arguments).
                    const slice: []const u8 = @as([*]const u8, @ptrCast(s.ptr))[0..s.len];
                    args[i] = std.heap.c_allocator.dupe(u8, slice) catch return;
                } else {
                    switch (T) {
                        i8 => {
                            if (db.valueGetTinyint(value, &args[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        },
                        i16 => {
                            if (db.valueGetSmallint(value, &args[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        },
                        i32 => {
                            if (db.valueGetInt(value, &args[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        },
                        i64 => {
                            if (db.valueGetBigint(value, &args[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        },
                        f32 => {
                            if (db.valueGetFloat(value, &args[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        },
                        f64 => {
                            if (db.valueGetDouble(value, &args[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        },
                        bool => {
                            if (db.valueGetBool(value, &args[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        },
                        else => comptime unreachable,
                    }
                }
            }

            const state = std.heap.c_allocator.create(State) catch return;
            state.* = @call(.auto, State.init, args);
            var boxed: db.Opaque = .{ .ptr = state, .destroy = destroyState, .equals = null };
            _ = db.functionBindSetBindData(info, &boxed, err);
        }

        fn ColumnPtr(comptime T: type) type {
            return if (T == []const u8) void else [*]T;
        }
        fn MakeColumnPtrsTuple() type {
            var types: [num_row_fields]type = undefined;
            for (row_field_types, 0..) |t, i| types[i] = ColumnPtr(t);
            return @Tuple(&types);
        }
        const ColumnPtrsTuple = MakeColumnPtrsTuple();

        fn execCallback(info: db.TableFunctionExecInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var bind_data_ptr: ?*anyopaque = null;
            if (db.tableFunctionExecGetBindData(info, &bind_data_ptr, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            const state: *State = @ptrCast(@alignCast(bind_data_ptr.?));

            var chunk: db.DataChunkHandle = undefined;
            if (db.tableFunctionExecGetOutputChunk(info, &chunk, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var vecs: [num_row_fields]db.VectorHandle = undefined;
            inline for (0..num_row_fields) |i| {
                if (db.dataChunkGetVector(chunk, i, &vecs[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            }

            // Pull the whole batch before writing anything: each output
            // vector's size must be set (to its final row count) before any
            // `vectorSetValue`/write into it — confirmed live (`row out of
            // range` otherwise) — so the final count must be known first.
            // A Row's `[]const u8` field must stay valid for the rest of
            // this call (i.e. until written out below), which holds as long
            // as `next` borrows from stable backing storage (as
            // `ct_tokenize_v2.zig`'s `State.input` does) rather than a
            // scratch buffer it overwrites on its next call.
            var rows: [max_rows_per_batch]Row = undefined;
            var row_count: db.idx_t = 0;
            while (row_count < max_rows_per_batch) {
                rows[row_count] = state.next() orelse break;
                row_count += 1;
            }

            inline for (0..num_row_fields) |i| {
                if (db.vectorSetSize(vecs[i], row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            }

            var ptrs: ColumnPtrsTuple = undefined;
            inline for (0..num_row_fields) |i| {
                const T = row_field_types[i];
                if (T != []const u8) {
                    var out_data: ?*anyopaque = null;
                    if (db.vectorGetDataMutable(vecs[i], &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    // SAFETY: column `i` was declared with this exact type in bindCallback.
                    ptrs[i] = @ptrCast(@alignCast(out_data));
                }
            }

            var row: db.idx_t = 0;
            while (row < row_count) : (row += 1) {
                inline for (0..num_row_fields) |i| {
                    const T = row_field_types[i];
                    const field_value = @field(rows[row], row_field_names[i]);
                    if (T == []const u8) {
                        var value: db.ValueHandle = undefined;
                        if (db.valueCreateVarcharWithContext(context, field_value, &value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        defer _ = db.valueDestroy(&value);
                        if (db.vectorSetValue(vecs[i], row, value, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    } else {
                        ptrs[i][row] = field_value;
                    }
                }
            }
        }
    };
}

test "Function generates a valid Zig type for a zero-argument range-like source" {
    const Range = Function("v2_test_table_range", struct {
        n: i64,
        i: i64,
        pub const Row = struct { value: i64 };
        pub fn init(n: i64) @This() {
            return .{ .n = n, .i = 0 };
        }
        pub fn next(self: *@This()) ?Row {
            if (self.i >= self.n) return null;
            defer self.i += 1;
            return .{ .value = self.i };
        }
    });
    // Referencing .register forces analysis of its comptime-unrolled body.
    _ = &Range.register;
    const bind_cb: db.c.duckdb_v2_table_function_bind_callback_fn = Range.bindCallback;
    const exec_cb: db.c.duckdb_v2_table_function_exec_callback_fn = Range.execCallback;
    try std.testing.expect(bind_cb != null);
    try std.testing.expect(exec_cb != null);
}

test "Function supports multiple output columns of different types" {
    const Pairs = Function("v2_test_table_pairs", struct {
        n: i64,
        i: i64,
        pub const Row = struct { idx: i64, is_even: bool };
        pub fn init(n: i64) @This() {
            return .{ .n = n, .i = 0 };
        }
        pub fn next(self: *@This()) ?Row {
            if (self.i >= self.n) return null;
            defer self.i += 1;
            return .{ .idx = self.i, .is_even = @mod(self.i, 2) == 0 };
        }
    });
    _ = &Pairs.register;
}

test "Function supports a VARCHAR argument and a VARCHAR output column" {
    const Repeat = Function("v2_test_table_repeat", struct {
        text: []const u8,
        n: i64,
        i: i64,
        pub const Row = struct { value: []const u8 };
        pub fn init(text: []const u8, n: i64) @This() {
            return .{ .text = text, .n = n, .i = 0 };
        }
        pub fn next(self: *@This()) ?Row {
            if (self.i >= self.n) return null;
            defer self.i += 1;
            return .{ .value = self.text };
        }
        pub fn deinit(self: *@This()) void {
            std.heap.c_allocator.free(self.text);
        }
    });
    _ = &Repeat.register;
}
