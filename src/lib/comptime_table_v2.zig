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
///!   - `pub fn pushdown(self: *State, info: db.TableFunctionFilterPushdownInfoHandle, err: [*c]db.ErrorInfoHandle) void`
///!     — optional. Called during optimization, after `bind` and before
///!     any `next`, with the filter predicates the query applies to this
///!     function's rows (see `duckdb_v2.zig`'s
///!     `tableFunctionSetFilterPushdownCallback` doc comment for the full
///!     accept/not-accept contract). Inspect predicates via
///!     `tableFunctionFilterPushdownGetFilter` + the `expression*`
///!     functions, mutate `self` to record what to filter, and
///!     `tableFunctionFilterPushdownAccept` each one `next` now promises
///!     to enforce itself. A `State` with no `pushdown` decl gets no
///!     filter-pushdown callback at all — every predicate is then applied
///!     by the engine as usual, same as today.
///!   - `pub const supports_projection_pushdown = true;` — optional. Opts
///!     into projection pushdown (`tableFunctionSetProjectionPushdown`):
///!     `exec` then only creates/writes the `Row` columns the query
///!     actually selected (per `tableFunctionExecGetColumnCount`/
///!     `GetColumnIndex`), leaving the rest untouched in the output chunk
///!     DuckDB hands back. `next` still computes a full `Row` every call —
///!     this only skips the write side, not per-field compute in `next`
///!     itself (see the optional `onProjection` hook below for that). A
///!     `State` without this decl gets no projection-pushdown callback at
///!     all, and `exec` always writes every declared column, same as today.
///!   - `pub fn onProjection(self: *State, selected_fields: []const usize) void`
///!     — optional, only consulted when `supports_projection_pushdown` is
///!     also set. Called once per `exec` call with the `Row` field indices
///!     (declaration order) the query actually selected, before `next` is
///!     called for that batch — lets `State` skip expensive per-field work
///!     in `next` for columns nobody asked for. Not calling it (no decl)
///!     costs nothing: `next` just keeps computing every field regardless.
///!   - `pub fn progress(self: *const State) f64` — optional. Called on
///!     demand to report how far the scan has advanced, in `[0.0, 1.0]`.
///!     CAUTION, confirmed live: this runs CONCURRENTLY with `next`/`exec`
///!     even for this framework's single-threaded scans — it's a separate
///!     query-progress monitoring mechanism, not tied to scan thread
///!     count — so any field `progress` reads that `next` also mutates
///!     needs to be safe to read from another thread (e.g.
///!     `std.atomic.Value`, not a bare field, if precision matters). A
///!     `State` with no `progress` decl gets no progress callback at all;
///!     the query simply reports no progress for it, same as today.
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
    const has_pushdown = @hasDecl(State, "pushdown");
    const has_progress = @hasDecl(State, "progress");
    const has_projection_pushdown = @hasDecl(State, "supports_projection_pushdown");
    const has_on_projection = @hasDecl(State, "onProjection");

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
            if (has_pushdown) {
                if (db.tableFunctionSetFilterPushdownCallback(function, pushdownCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToSetFilterPushdownCallback;
                }
            }
            if (has_progress) {
                if (db.tableFunctionSetProgressCallback(function, progressCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToSetProgressCallback;
                }
            }
            if (has_projection_pushdown) {
                if (db.tableFunctionSetProjectionPushdown(function, true, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToSetProjectionPushdown;
                }
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

        fn pushdownCallback(info: db.TableFunctionFilterPushdownInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            _ = context;
            var bind_data_ptr: ?*anyopaque = null;
            if (db.tableFunctionFilterPushdownGetBindData(info, &bind_data_ptr, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            const state: *State = @ptrCast(@alignCast(bind_data_ptr.?));
            State.pushdown(state, info, err);
        }

        fn progressCallback(info: db.TableFunctionProgressInfoHandle, context: db.ContextHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            _ = context;
            var bind_data_ptr: ?*anyopaque = null;
            if (db.tableFunctionProgressGetBindData(info, &bind_data_ptr, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            const state: *const State = @ptrCast(@alignCast(bind_data_ptr.?));
            _ = db.tableFunctionProgressSetProgress(info, State.progress(state), err);
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

            // `position_for_field[i]` is the output chunk's vector index for
            // `Row` field `i`, or `null` if the query didn't select it (only
            // possible when `supports_projection_pushdown` is set — without
            // it every field maps to itself, same as before this existed).
            var position_for_field: [num_row_fields]?db.idx_t = undefined;
            if (has_projection_pushdown) {
                for (&position_for_field) |*p| p.* = null;
                var selected_count: db.idx_t = 0;
                if (db.tableFunctionExecGetColumnCount(info, &selected_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                var pos: db.idx_t = 0;
                while (pos < selected_count) : (pos += 1) {
                    var field_idx: db.idx_t = undefined;
                    if (db.tableFunctionExecGetColumnIndex(info, pos, &field_idx, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    if (field_idx < num_row_fields) position_for_field[field_idx] = pos;
                }
                if (has_on_projection) {
                    var selected_fields: [num_row_fields]usize = undefined;
                    var selected_len: usize = 0;
                    inline for (0..num_row_fields) |i| {
                        if (position_for_field[i] != null) {
                            selected_fields[selected_len] = i;
                            selected_len += 1;
                        }
                    }
                    State.onProjection(state, selected_fields[0..selected_len]);
                }
            } else {
                inline for (0..num_row_fields) |i| position_for_field[i] = i;
            }

            var vecs: [num_row_fields]db.VectorHandle = undefined;
            inline for (0..num_row_fields) |i| {
                if (position_for_field[i]) |pos| {
                    if (db.dataChunkGetVector(chunk, pos, &vecs[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                }
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
                if (position_for_field[i] != null) {
                    if (db.vectorSetSize(vecs[i], row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                }
            }

            var ptrs: ColumnPtrsTuple = undefined;
            inline for (0..num_row_fields) |i| {
                const T = row_field_types[i];
                if (T != []const u8 and position_for_field[i] != null) {
                    var out_data: ?*anyopaque = null;
                    if (db.vectorGetDataMutable(vecs[i], &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    // SAFETY: column `i` was declared with this exact type in bindCallback.
                    ptrs[i] = @ptrCast(@alignCast(out_data));
                }
            }

            var row: db.idx_t = 0;
            while (row < row_count) : (row += 1) {
                inline for (0..num_row_fields) |i| {
                    if (position_for_field[i] != null) {
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

test "Function supports an optional pushdown hook" {
    const RangeFiltered = Function("v2_test_table_range_filtered", struct {
        n: i64,
        i: i64,
        predicate: ?i64 = null,
        pub const Row = struct { value: i64 };
        pub fn init(n: i64) @This() {
            return .{ .n = n, .i = 0 };
        }
        pub fn next(self: *@This()) ?Row {
            while (self.i < self.n) {
                const v = self.i;
                self.i += 1;
                if (self.predicate) |p| {
                    if (v != p) continue;
                }
                return .{ .value = v };
            }
            return null;
        }
        pub fn pushdown(self: *@This(), info: db.TableFunctionFilterPushdownInfoHandle, err: [*c]db.ErrorInfoHandle) void {
            _ = self;
            _ = info;
            _ = err;
        }
    });
    // Referencing .register forces analysis of the pushdown-callback body too.
    _ = &RangeFiltered.register;
}

test "Function supports an optional progress hook" {
    const RangeWithProgress = Function("v2_test_table_range_progress", struct {
        n: i64,
        // Atomic, not a bare field: progress() runs concurrently with
        // next() even for this single-threaded scan (see this file's
        // module doc comment on `progress`'s thread-safety requirement).
        i: std.atomic.Value(i64),
        pub const Row = struct { value: i64 };
        pub fn init(n: i64) @This() {
            return .{ .n = n, .i = std.atomic.Value(i64).init(0) };
        }
        pub fn next(self: *@This()) ?Row {
            const v = self.i.load(.monotonic);
            if (v >= self.n) return null;
            self.i.store(v + 1, .monotonic);
            return .{ .value = v };
        }
        pub fn progress(self: *const @This()) f64 {
            if (self.n == 0) return 1.0;
            const i_val: f64 = @floatFromInt(self.i.load(.monotonic));
            const n_val: f64 = @floatFromInt(self.n);
            return i_val / n_val;
        }
    });
    // Referencing .register forces analysis of the progress-callback body too.
    _ = &RangeWithProgress.register;
    const progress_cb: db.c.duckdb_v2_table_function_progress_callback_fn = RangeWithProgress.progressCallback;
    try std.testing.expect(progress_cb != null);
}

test "Function supports optional projection-pushdown opt-in and onProjection hook" {
    const Pairs = Function("v2_test_table_projection", struct {
        n: i64,
        i: i64,
        pub const supports_projection_pushdown = true;
        pub const Row = struct { a: i64, b: i64 };
        pub fn init(n: i64) @This() {
            return .{ .n = n, .i = 0 };
        }
        pub fn next(self: *@This()) ?Row {
            if (self.i >= self.n) return null;
            defer self.i += 1;
            return .{ .a = self.i, .b = self.i * 2 };
        }
        pub fn onProjection(self: *@This(), selected_fields: []const usize) void {
            _ = self;
            _ = selected_fields;
        }
    });
    // Referencing .register forces analysis of the exec-callback body's
    // projection-pushdown branch (has_projection_pushdown == true) too.
    _ = &Pairs.register;
}

test "Function omitting supports_projection_pushdown keeps writing every column" {
    const Pairs = Function("v2_test_table_no_projection", struct {
        n: i64,
        i: i64,
        pub const Row = struct { a: i64, b: i64 };
        pub fn init(n: i64) @This() {
            return .{ .n = n, .i = 0 };
        }
        pub fn next(self: *@This()) ?Row {
            if (self.i >= self.n) return null;
            defer self.i += 1;
            return .{ .a = self.i, .b = self.i * 2 };
        }
    });
    _ = &Pairs.register;
}
