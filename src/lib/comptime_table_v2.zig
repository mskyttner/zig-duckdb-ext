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
///!   - `pub fn pushdown(self: *State, info: v2.duckdb_v2_table_function_filter_pushdown_info_handle, err: *v2.duckdb_v2_error_info_handle) void`
///!     — optional. Called during optimization, after `bind` and before
///!     any `next`, with the filter predicates the query applies to this
///!     function's rows (see `duckdb_v2_dynamic.zig`'s
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
///! Bindings: the framework calls DuckDB through the generated bindings
///! (`duckdb_v2_dynamic`, plus the helpers in `v2_helpers.zig`); the hooks a `State` may
///! define take the generated handles (the `pushdown` hook's
///! `v2.duckdb_v2_table_function_filter_pushdown_info_handle` and `*v2.duckdb_v2_error_info_handle`).
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
///!   try Range.register(input); // input: *const v2.duckdb_v2_extension_input
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

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
        else => @compileError("unsupported type for DuckDB v2 mapping: " ++ @typeName(T)),
    };
}

/// Maximum rows produced per `exec` call — matches `tokenize_v2.zig`'s
/// hand-written batching (DuckDB's own standard vector size).
const max_rows_per_batch = 2048;

/// Define a v2 DuckDB table function from a comptime-known `State` type,
/// with synthesized `a0`/`a1`/... names for `State.init`'s call arguments
/// (Zig function parameters carry no names at the ABI level). Use
/// `FunctionNamed` instead for real argument names. See this file's
/// module doc comment for `State`'s required shape.
pub fn Function(comptime name: [:0]const u8, comptime State: type) type {
    return FunctionImpl(name, State, null, null);
}

/// Like `Function`, but `arg_names` supplies `State.init`'s call-argument
/// names in order instead of synthesizing `a0`/`a1`/.... `Row`'s own
/// field names are unaffected either way — those were already real SQL
/// column names (a struct's fields carry names at comptime, unlike a
/// function's parameters), this only concerns the function's own call
/// arguments. Must have exactly one name per `State.init` parameter.
pub fn FunctionNamed(comptime name: [:0]const u8, comptime State: type, comptime arg_names: []const [:0]const u8) type {
    return FunctionImpl(name, State, arg_names, null);
}

/// Like `FunctionNamed`, and the function also gets a description, examples and categories, which
/// `duckdb_functions()` reports. Needs an API with the function docs calls (`v2.0.0-alpha48730` and later).
pub fn FunctionDocumented(comptime name: [:0]const u8, comptime State: type, comptime arg_names: []const [:0]const u8, comptime docs: helpers.Docs) type {
    return FunctionImpl(name, State, arg_names, docs);
}

fn FunctionImpl(comptime name: [:0]const u8, comptime State: type, comptime arg_names: ?[]const [:0]const u8, comptime docs: ?helpers.Docs) type {
    const Row = State.Row;
    const row_info = @typeInfo(Row).@"struct";
    const row_field_names = row_info.field_names;
    const row_field_types = row_info.field_types;
    const num_row_fields = row_field_names.len;
    const init_info = @typeInfo(@TypeOf(State.init)).@"fn";
    const arg_types = init_info.param_types;
    if (arg_names) |names| {
        if (names.len != arg_types.len) {
            @compileError(std.fmt.comptimePrint(
                "FunctionNamed(\"{s}\", ...): arg_names has {d} entries but State.init takes {d} parameters",
                .{ name, names.len, arg_types.len },
            ));
        }
    }
    const has_deinit = @hasDecl(State, "deinit");
    const has_pushdown = @hasDecl(State, "pushdown");
    const has_progress = @hasDecl(State, "progress");
    const has_projection_pushdown = @hasDecl(State, "supports_projection_pushdown");
    const has_on_projection = @hasDecl(State, "onProjection");

    inline for (row_field_types) |t| _ = duckdbV2TypeId(t);
    inline for (arg_types) |t| _ = duckdbV2TypeId(t.?);

    return struct {
        pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
            // Start from DuckDB's own slot: a failing call fills in an existing error info and writes through a
            // non-NULL slot as it finds it, so an uninitialised local would crash at the first failure, and a
            // failure reports its reason to the load this way.
            var err = (input.err orelse return error.MissingErrorSlot).*;

            var function: v2.duckdb_v2_table_function_handle = undefined;
            if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, &err) orelse return error.FailedToGetFactory, &function, &err) != .ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = v2.duckdb_v2_table_function_destroy(&function);

            const fn_name = helpers.str(name);
            if (v2.duckdb_v2_table_function_set_name(function, &fn_name, &err) != .ERROR_NONE) {
                return error.FailedToSetName;
            }

            if (arg_types.len > 0) {
                var sig: v2.duckdb_v2_function_signature_handle = undefined;
                if (v2.duckdb_v2_table_function_get_signature(function, &sig, &err) != .ERROR_NONE) {
                    return error.FailedToGetSignature;
                }
                inline for (arg_types, 0..) |t, i| {
                    var param_type: v2.duckdb_v2_logical_type_handle = undefined;
                    if (helpers.createTypeFromId(input.context, duckdbV2TypeId(t.?), &param_type, &err) != .ERROR_NONE) {
                        return error.FailedToCreateParamType;
                    }
                    defer _ = v2.duckdb_v2_logical_type_destroy(&param_type);

                    const param_name_buf = if (arg_names) |names| names[i] else std.fmt.comptimePrint("a{d}", .{i});
                    const param_name = helpers.str(param_name_buf);
                    if (v2.duckdb_v2_function_signature_add_parameter(
                        sig,
                        &param_name,
                        param_type,
                        null,
                        .FUNCTION_PARAMETER_KIND_STANDARD,
                        &err,
                    ) != .ERROR_NONE) {
                        return error.FailedToAddParameter;
                    }
                }
            }

            if (v2.duckdb_v2_table_function_set_bind_callback(function, bindCallback, &err) != .ERROR_NONE) {
                return error.FailedToSetBindCallback;
            }
            if (v2.duckdb_v2_table_function_set_exec_callback(function, execCallback, &err) != .ERROR_NONE) {
                return error.FailedToSetExecCallback;
            }
            if (has_pushdown) {
                if (v2.duckdb_v2_table_function_set_filter_pushdown_callback(function, pushdownCallback, &err) != .ERROR_NONE) {
                    return error.FailedToSetFilterPushdownCallback;
                }
            }
            if (has_progress) {
                if (v2.duckdb_v2_table_function_set_progress_callback(function, progressCallback, &err) != .ERROR_NONE) {
                    return error.FailedToSetProgressCallback;
                }
            }
            if (has_projection_pushdown) {
                if (v2.duckdb_v2_table_function_set_projection_pushdown(function, true, &err) != .ERROR_NONE) {
                    return error.FailedToSetProjectionPushdown;
                }
            }

            if (docs) |d| {
                var function_docs: v2.duckdb_v2_function_docs_handle = undefined;
                try helpers.ok(v2.duckdb_v2_table_function_get_docs(function, &function_docs, &err), error.FailedToGetDocs);
                helpers.setDocs(function_docs, d, &err) catch return error.FailedToSetDocs;
            }

            if (v2.duckdb_v2_extension_register_table_function(input.extension, function, &err) != .ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }

        fn destroyState(ptr: ?*anyopaque) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(ptr.?));
            if (has_deinit) state.deinit();
            std.heap.c_allocator.destroy(state);
        }

        fn pushdownCallback(info: v2.duckdb_v2_table_function_filter_pushdown_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
            _ = context;
            var bind_data_ptr: ?*anyopaque = null;
            if (v2.duckdb_v2_table_function_filter_pushdown_get_bind_data(info, &bind_data_ptr, err) != .ERROR_NONE) return;
            const state: *State = @ptrCast(@alignCast(bind_data_ptr.?));
            State.pushdown(state, info, err);
        }

        fn progressCallback(info: v2.duckdb_v2_table_function_progress_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
            _ = context;
            var bind_data_ptr: ?*anyopaque = null;
            if (v2.duckdb_v2_table_function_progress_get_bind_data(info, &bind_data_ptr, err) != .ERROR_NONE) return;
            const state: *const State = @ptrCast(@alignCast(bind_data_ptr.?));
            _ = v2.duckdb_v2_table_function_progress_set_progress(info, State.progress(state), err);
        }

        fn MakeArgsTuple() type {
            var types: [arg_types.len]type = undefined;
            for (0..arg_types.len) |i| types[i] = arg_types[i].?;
            return @Tuple(&types);
        }
        const ArgsTuple = MakeArgsTuple();

        fn bindCallback(info: v2.duckdb_v2_function_bind_info_handle, result: v2.duckdb_v2_table_function_bind_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
            inline for (row_field_names, row_field_types) |name_, type_| {
                var col_type: v2.duckdb_v2_logical_type_handle = undefined;
                if (helpers.createTypeFromId(context, duckdbV2TypeId(type_), &col_type, err) != .ERROR_NONE) return;
                defer _ = v2.duckdb_v2_logical_type_destroy(&col_type);
                const col_name = helpers.str(name_);
                if (v2.duckdb_v2_table_function_bind_add_result_column(result, &col_name, col_type, err) != .ERROR_NONE) return;
            }

            var args: ArgsTuple = undefined;
            inline for (0..arg_types.len) |i| {
                const T = arg_types[i].?;
                var value: v2.duckdb_v2_value_handle = undefined;
                if (v2.duckdb_v2_function_bind_get_arg_value(info, i, &value, err) != .ERROR_NONE) return;
                defer _ = v2.duckdb_v2_value_destroy(&value);

                if (T == []const u8) {
                    var s: v2.duckdb_v2_str = undefined;
                    if (v2.duckdb_v2_value_get_varchar(value, &s, err) != .ERROR_NONE) return;
                    // SAFETY: `s` borrows from `value`, destroyed above once
                    // this iteration ends — copy the bytes out so `State`
                    // can keep them past `bind`'s return (see this file's
                    // doc comment on VARCHAR arguments).
                    const slice: []const u8 = @as([*]const u8, @ptrCast(s.ptr))[0..s.len];
                    args[i] = std.heap.c_allocator.dupe(u8, slice) catch return;
                } else {
                    switch (T) {
                        i8 => {
                            if (v2.duckdb_v2_value_get_tinyint(value, &args[i], err) != .ERROR_NONE) return;
                        },
                        i16 => {
                            if (v2.duckdb_v2_value_get_smallint(value, &args[i], err) != .ERROR_NONE) return;
                        },
                        i32 => {
                            if (v2.duckdb_v2_value_get_int(value, &args[i], err) != .ERROR_NONE) return;
                        },
                        i64 => {
                            if (v2.duckdb_v2_value_get_bigint(value, &args[i], err) != .ERROR_NONE) return;
                        },
                        f32 => {
                            if (v2.duckdb_v2_value_get_float(value, &args[i], err) != .ERROR_NONE) return;
                        },
                        f64 => {
                            if (v2.duckdb_v2_value_get_double(value, &args[i], err) != .ERROR_NONE) return;
                        },
                        bool => {
                            if (v2.duckdb_v2_value_get_bool(value, &args[i], err) != .ERROR_NONE) return;
                        },
                        else => comptime unreachable,
                    }
                }
            }

            const state = std.heap.c_allocator.create(State) catch return;
            state.* = @call(.auto, State.init, args);
            var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyState, .equals = null };
            _ = v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err);
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

        fn execCallback(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
            var bind_data_ptr: ?*anyopaque = null;
            if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_data_ptr, err) != .ERROR_NONE) return;
            const state: *State = @ptrCast(@alignCast(bind_data_ptr.?));

            var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
            if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;

            // `position_for_field[i]` is the output chunk's vector index for
            // `Row` field `i`, or `null` if the query didn't select it (only
            // possible when `supports_projection_pushdown` is set — without
            // it every field maps to itself, same as before this existed).
            var position_for_field: [num_row_fields]?u64 = undefined;
            if (has_projection_pushdown) {
                for (&position_for_field) |*p| p.* = null;
                var selected_count: u64 = 0;
                if (v2.duckdb_v2_table_function_exec_get_column_count(info, &selected_count, err) != .ERROR_NONE) return;
                var pos: u64 = 0;
                while (pos < selected_count) : (pos += 1) {
                    var field_idx: u64 = undefined;
                    if (v2.duckdb_v2_table_function_exec_get_column_index(info, pos, &field_idx, err) != .ERROR_NONE) return;
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

            var vecs: [num_row_fields]v2.duckdb_v2_vector_handle = undefined;
            inline for (0..num_row_fields) |i| {
                if (position_for_field[i]) |pos| {
                    if (v2.duckdb_v2_data_chunk_get_vector(chunk, pos, &vecs[i], err) != .ERROR_NONE) return;
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
            var row_count: u64 = 0;
            while (row_count < max_rows_per_batch) {
                rows[row_count] = state.next() orelse break;
                row_count += 1;
            }

            inline for (0..num_row_fields) |i| {
                if (position_for_field[i] != null) {
                    if (v2.duckdb_v2_vector_set_size(vecs[i], row_count, err) != .ERROR_NONE) return;
                }
            }

            var ptrs: ColumnPtrsTuple = undefined;
            inline for (0..num_row_fields) |i| {
                const T = row_field_types[i];
                if (T != []const u8 and position_for_field[i] != null) {
                    var out_data: ?*anyopaque = null;
                    if (v2.duckdb_v2_vector_get_data_mutable(vecs[i], &out_data, err) != .ERROR_NONE) return;
                    // SAFETY: column `i` was declared with this exact type in bindCallback.
                    ptrs[i] = @ptrCast(@alignCast(out_data));
                }
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                inline for (0..num_row_fields) |i| {
                    if (position_for_field[i] != null) {
                        const T = row_field_types[i];
                        const field_value = @field(rows[row], row_field_names[i]);
                        if (T == []const u8) {
                            var value: v2.duckdb_v2_value_handle = undefined;
                            if (helpers.createVarcharValue(context, field_value, &value, err) != .ERROR_NONE) return;
                            defer _ = v2.duckdb_v2_value_destroy(&value);
                            if (v2.duckdb_v2_vector_set_value(vecs[i], row, value, err) != .ERROR_NONE) return;
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
    const bind_cb: v2.duckdb_v2_table_function_bind_callback_fn = Range.bindCallback;
    const exec_cb: v2.duckdb_v2_table_function_exec_callback_fn = Range.execCallback;
    try std.testing.expect(@intFromPtr(bind_cb) != 0);
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "FunctionNamed supports real call-argument names" {
    const Range = FunctionNamed("v2_test_table_range_named", struct {
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
    }, &.{"n"});
    _ = &Range.register;
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
        pub fn pushdown(self: *@This(), info: v2.duckdb_v2_table_function_filter_pushdown_info_handle, err: *v2.duckdb_v2_error_info_handle) void {
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
    const progress_cb: v2.duckdb_v2_table_function_progress_callback_fn = RangeWithProgress.progressCallback;
    try std.testing.expect(@intFromPtr(progress_cb) != 0);
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
