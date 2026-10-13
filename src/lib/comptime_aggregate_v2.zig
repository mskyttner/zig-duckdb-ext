///! Comptime aggregate function framework for the DuckDB v2 C Extension API.
///!
///! There is no v1 equivalent to port — v1's aggregate API is one-state-at-
///! a-time, while v2 batches every stage (init/update/combine/finalize) over
///! an array of state pointers, so this is new design rather than a port,
///! following `comptime_scalar_v2.zig`'s "generate the vectorized plumbing
///! from a plain per-row shape" philosophy.
///!
///! The caller supplies a State type with four decls:
///!   - `pub fn init() State` — the identity/zero state
///!   - `pub fn update(self: *State, <args>) void` — fold one row's args into state
///!   - `pub fn combine(self: *State, other: State) void` — merge a parallel partial state
///!   - `pub fn finalize(self: State) ReturnType` — produce the result
///!
///! `finalize` may instead return `?ReturnType`: returning `null` produces
///! SQL NULL for that group (e.g. a weighted average whose total weight is
///! zero), rather than forcing every group through a fallback numeric value.
///!
///! CAUTION: if `finalize` returns a `[]const u8` borrowed from a field
///! stored INLINE in State (a fixed-size array, not a pointer to separately
///! heap-allocated memory), it must take `self: *const State` or
///! `self: *State`, not `self: State`. `self: State` copies the whole
///! struct onto `finalize`'s own stack frame, and a slice into an inline
///! field of that copy dangles the moment `finalize` returns — a real bug
///! this framework shipped with briefly (found only once something
///! exercised it at scale, not caught by small tests or a Debug build).
///! Use `*State` (not `*const`) if `finalize` needs to format INTO the
///! buffer first (e.g. `std.fmt.bufPrint`) — mutating here is harmless,
///! nothing reads the state again before it's discarded. `self: State` is
///! fine whenever the return value is a plain scalar, or a `[]const u8`
///! borrowed from a heap-backed field (e.g. `std.ArrayList(u8)`'s
///! `.items`, where copying the struct copies the pointer, not the buffer
///! it points to) — only an inline-array-backed slice return needs a
///! pointer receiver.
///!
///! `update`'s parameters (after `self`) and `finalize`'s return type are
///! introspected at comptime to build the function signature, the same way
///! `comptime_scalar_v2.Function` reads a per-row function's shape. No size
///! or bind callback is needed from the caller: size is `@sizeOf(State)`,
///! and there's no dynamic return type.
///!
///! Optional fifth decl, for a `State` that owns a resource (e.g. a
///! growable buffer backing a `string_agg`-style aggregate — `@sizeOf(State)`
///! is fixed at registration time, so growable data can only live behind a
///! separately heap-allocated pointer the state holds):
///!   - `pub fn deinit(self: *State) void` — release it.
///!
///! Optional sixth decl, for a batch-at-a-time fast path over the
///! *ungrouped* case (`SELECT my_agg(x) FROM t`, no `GROUP BY`):
///!   - `pub fn updateBatch(self: *State, views: *const [N]db.VectorView, row_count: db.idx_t) void`
///!     where N is `arg_types.len` (the same count `update`'s own
///!     parameters have, after `self`).
///!
///! `update` is called once per row, every time — DuckDB's v2 update
///! callback hands it one state pointer per row regardless of GROUP BY,
///! so for an ungrouped aggregate every one of those pointers is the SAME
///! pointer, and the per-row dispatch (NULL-check + function call +
///! tuple-unpack) is pure overhead the row loop pays 2048 times a chunk
///! for what is, underneath, one reduction over a contiguous column.
///! `updateBatch`, when present, is tried FIRST: the framework checks
///! whether every state pointer in the current chunk is identical, and if
///! so calls `updateBatch` ONCE with the chunk's raw argument
///! `VectorView`s instead of looping `update` per row — the whole point
///! being to fold the chunk's NULL-masking and reduction into one SIMD
///! pass (`@Vector`/`@select`/`@reduce`) rather than 2048 scalar calls.
///! Falls back to the ordinary `update` per-row loop whenever the
///! pointers differ (a GROUP BY query) or `updateBatch` isn't declared at
///! all — every existing `State` with no `updateBatch` is completely
///! unaffected. `updateBatch` must apply the same "skip a row where any
///! argument is NULL" rule `update`'s per-row path gets for free via
///! `rowIsValid` — decode `views[i].validity` directly (see
///! `isValid`-style helpers; same 64-bit-word layout `rowIsValid` already
///! uses) since there is no row-by-row call to skip through instead.
///!
///! Wired up as the aggregate's destroy callback ONLY — `finalize` must not
///! call `deinit` itself. Confirmed live (crashed otherwise, a double-free
///! caught by Zig 0.17's `ArrayList` pointer-stability assertion): DuckDB's
///! v2.0 alpha calls `destroy` on every state that was ever allocated,
///! including ones `finalize` already ran on, not just states discarded
///! without being finalized the way the header's own doc comment on
///! `duckdb_v2_aggregate_function_set_destroy_callback` suggests — `destroy`
///! is the one and only place a state's resources may be released.
///! `finalize` may read a resource `deinit` will later free (e.g. return a
///! `[]const u8` borrowed from the state's own buffer) as long as the
///! caller copies it out before `destroy` runs, which it does here (see
///! `makeBytesValue`'s immediate-copy-into-arena below). `combine`'s
///! `other` argument must NOT be freed by `combine` itself — `other`'s
///! owning state gets its own, separate `deinit` call from `destroy` later.
///!
///! Usage:
///!   const Sum = comptime_aggregate_v2.Function("my_sum", struct {
///!       sum: i64,
///!       pub fn init() @This() { return .{ .sum = 0 }; }
///!       pub fn update(self: *@This(), x: i64) void { self.sum += x; }
///!       pub fn combine(self: *@This(), other: @This()) void { self.sum += other.sum; }
///!       pub fn finalize(self: @This()) i64 { return self.sum; }
///!   });
///!   try Sum.register(input); // input: *const db.ExtensionInput
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

/// Define a v2 DuckDB aggregate function from a comptime-known `State`
/// type, with synthesized `a0`/`a1`/... names for `State.update`'s
/// per-row arguments (Zig function parameters carry no names at the ABI
/// level). Use `FunctionNamed` instead for real argument names.
pub fn Function(comptime name: [:0]const u8, comptime State: type) type {
    return FunctionImpl(name, State, null);
}

/// Like `Function`, but `arg_names` supplies `State.update`'s per-row
/// argument names in order instead of synthesizing `a0`/`a1`/.... Must
/// have exactly one name per `update` argument (not counting its leading
/// `self` parameter).
pub fn FunctionNamed(comptime name: [:0]const u8, comptime State: type, comptime arg_names: []const [:0]const u8) type {
    return FunctionImpl(name, State, arg_names);
}

fn FunctionImpl(comptime name: [:0]const u8, comptime State: type, comptime arg_names: ?[]const [:0]const u8) type {
    const update_info = @typeInfo(@TypeOf(State.update)).@"fn";
    // update_info.param_types[0] is *State (self); the rest are the
    // per-row arguments to expose as the SQL function's parameters.
    const arg_types = update_info.param_types[1..];
    if (arg_names) |names| {
        if (names.len != arg_types.len) {
            @compileError(std.fmt.comptimePrint(
                "FunctionNamed(\"{s}\", ...): arg_names has {d} entries but update takes {d} arguments",
                .{ name, names.len, arg_types.len },
            ));
        }
    }
    const finalize_info = @typeInfo(@TypeOf(State.finalize)).@"fn";
    const RawReturnType = finalize_info.return_type.?;
    // `finalize` may return `?T` instead of `T` to produce SQL NULL for a
    // group it can't meaningfully reduce (e.g. a weighted average whose
    // total weight is zero) — mirrors update's per-row "skip on NULL arg"
    // semantics at the finalize stage instead.
    const finalize_is_optional = @typeInfo(RawReturnType) == .optional;
    const ReturnType = if (finalize_is_optional) @typeInfo(RawReturnType).optional.child else RawReturnType;
    const return_is_varchar = ReturnType == []const u8;
    // Optional: a State that owns a resource (e.g. a growable buffer
    // backing a string_agg-style aggregate) declares `deinit` to release
    // it. Called once per state, exactly once: after `finalize` produces
    // its result for states that get finalized, or from `destroyCallback`
    // for states discarded without being finalized (combine's merged-away
    // sources, states abandoned on error/cancellation) — see
    // `duckdb_v2.zig`'s `aggregateFunctionSetDestroyCallback` doc comment.
    const has_deinit = @hasDecl(State, "deinit");
    // Optional ungrouped batch fast path — see this file's module doc
    // comment on `updateBatch`.
    const has_update_batch = @hasDecl(State, "updateBatch");

    inline for (arg_types) |t| _ = duckdbV2TypeId(t.?);
    _ = duckdbV2TypeId(ReturnType);

    return struct {
        pub fn register(input: *const db.ExtensionInput) !void {
            var err: db.ErrorInfoHandle = undefined;

            var function: db.AggregateFunctionHandle = undefined;
            if (db.aggregateFunctionCreateWithExtension(input.extension, &function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = db.aggregateFunctionDestroy(&function);

            const fn_name = db.str(name);
            if (db.aggregateFunctionSetName(function, &fn_name, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetName;
            }

            var sig: db.FunctionSignatureHandle = undefined;
            if (db.aggregateFunctionGetSignature(function, &sig, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToGetSignature;
            }

            inline for (arg_types, 0..) |t, i| {
                var param_type: db.LogicalTypeHandle = undefined;
                if (db.contextCreateTypeFromId(input.context, duckdbV2TypeId(t.?), &param_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToCreateParamType;
                }
                defer _ = db.logicalTypeDestroy(&param_type);

                const param_name_buf = if (arg_names) |names| names[i] else std.fmt.comptimePrint("a{d}", .{i});
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
            if (db.contextCreateTypeFromId(input.context, duckdbV2TypeId(ReturnType), &return_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToCreateReturnType;
            }
            defer _ = db.logicalTypeDestroy(&return_type);
            if (db.functionSignatureSetReturnType(sig, return_type, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetReturnType;
            }

            if (db.aggregateFunctionSetSizeCallback(function, sizeCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetSizeCallback;
            }
            if (db.aggregateFunctionSetInitCallback(function, initCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetInitCallback;
            }
            if (db.aggregateFunctionSetUpdateCallback(function, updateCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetUpdateCallback;
            }
            if (db.aggregateFunctionSetCombineCallback(function, combineCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetCombineCallback;
            }
            if (db.aggregateFunctionSetFinalizeCallback(function, finalizeCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToSetFinalizeCallback;
            }
            if (comptime has_deinit) {
                if (db.aggregateFunctionSetDestroyCallback(function, destroyCallback, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                    return error.FailedToSetDestroyCallback;
                }
            }

            if (db.aggregateFunctionRegister(function, &err) != db.c.DUCKDB_V2_ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }

        fn sizeCallback(info: db.AggregateFunctionSizeInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            _ = db.aggregateFunctionSizeSetStateSize(info, @sizeOf(State), err);
        }

        fn initCallback(info: db.AggregateFunctionInitInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var count: db.idx_t = 0;
            if (db.aggregateFunctionInitGetStateCount(info, &count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            var states: [*c]?*anyopaque = null;
            if (db.aggregateFunctionInitGetStates(info, &states, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var i: db.idx_t = 0;
            while (i < count) : (i += 1) {
                const state: *State = @ptrCast(@alignCast(states[i].?));
                state.* = State.init();
            }
        }

        fn updateCallback(info: db.AggregateFunctionUpdateInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var row_count: db.idx_t = 0;
            if (db.aggregateFunctionUpdateGetRowCount(info, &row_count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var views: [arg_types.len]db.VectorView = undefined;
            inline for (0..arg_types.len) |i| {
                var arg_vec: db.VectorHandle = undefined;
                if (db.aggregateFunctionUpdateGetArg(info, i, &arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                if (db.vectorFlatten(arg_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                if (db.vectorGetView(arg_vec, &views[i], err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            }

            var states: [*c]?*anyopaque = null;
            if (db.aggregateFunctionUpdateGetStates(info, &states, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            if (comptime has_update_batch) {
                if (row_count > 0 and allStatesEqual(states, row_count)) {
                    const state: *State = @ptrCast(@alignCast(states[0].?));
                    State.updateBatch(state, &views, row_count);
                    return;
                }
            }

            var row: db.idx_t = 0;
            while (row < row_count) : (row += 1) {
                // Standard SQL aggregate semantics: a row with any NULL
                // argument is skipped, not folded in as a zero/default.
                if (!rowIsValid(&views, row)) continue;
                const state: *State = @ptrCast(@alignCast(states[row].?));
                @call(.auto, State.update, .{state} ++ buildArgs(&views, row));
            }
        }

        /// True when every row in this chunk targets the same state — the
        /// case `updateBatch` exists for (an ungrouped aggregate; a GROUP
        /// BY query's rows target different states and always fail this).
        inline fn allStatesEqual(states: [*c]?*anyopaque, row_count: db.idx_t) bool {
            const first = states[0];
            var row: db.idx_t = 1;
            while (row < row_count) : (row += 1) {
                if (states[row] != first) return false;
            }
            return true;
        }

        fn combineCallback(info: db.AggregateFunctionCombineInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var count: db.idx_t = 0;
            if (db.aggregateFunctionCombineGetStateCount(info, &count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            var sources: [*c]?*anyopaque = null;
            if (db.aggregateFunctionCombineGetSources(info, &sources, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            var targets: [*c]?*anyopaque = null;
            if (db.aggregateFunctionCombineGetTargets(info, &targets, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var i: db.idx_t = 0;
            while (i < count) : (i += 1) {
                const source: *State = @ptrCast(@alignCast(sources[i].?));
                const target: *State = @ptrCast(@alignCast(targets[i].?));
                target.combine(source.*);
            }
        }

        fn finalizeCallback(info: db.AggregateFunctionFinalizeInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var count: db.idx_t = 0;
            if (db.aggregateFunctionFinalizeGetStateCount(info, &count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            var states: [*c]?*anyopaque = null;
            if (db.aggregateFunctionFinalizeGetStates(info, &states, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            var result_vec: db.VectorHandle = undefined;
            if (db.aggregateFunctionFinalizeGetResult(info, &result_vec, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            var offset: db.idx_t = 0;
            if (db.aggregateFunctionFinalizeGetResultOffset(info, &offset, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            if (comptime return_is_varchar) {
                // No context handle is available in any aggregate callback
                // (unlike scalar/table `bind`), so the usual
                // valueCreateVarcharWithContext + vectorSetValue boxing path
                // is unavailable here — write BytesValue directly into the
                // vector's own arena instead. See `vectorGetArena`'s doc
                // comment in duckdb_v2.zig.
                var arena: db.ArenaHandle = undefined;
                if (db.vectorGetArena(result_vec, &arena, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                var out_data: ?*anyopaque = null;
                if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                const out: [*]db.BytesValue = @ptrCast(@alignCast(out_data));

                var i: db.idx_t = 0;
                while (i < count) : (i += 1) {
                    const state: *State = @ptrCast(@alignCast(states[i].?));
                    if (finalize_is_optional) {
                        if (state.finalize()) |value| {
                            out[offset + i] = db.makeBytesValue(arena, value, err) catch return;
                        } else {
                            if (db.vectorSetNull(result_vec, offset + i, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                        }
                    } else {
                        out[offset + i] = db.makeBytesValue(arena, state.finalize(), err) catch return;
                    }
                }
                return;
            }

            var out_data: ?*anyopaque = null;
            if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            const out: [*]ReturnType = @ptrCast(@alignCast(out_data));

            var i: db.idx_t = 0;
            while (i < count) : (i += 1) {
                const state: *State = @ptrCast(@alignCast(states[i].?));
                if (finalize_is_optional) {
                    if (state.finalize()) |value| {
                        out[offset + i] = value;
                    } else {
                        if (db.vectorSetNull(result_vec, offset + i, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
                    }
                } else {
                    out[offset + i] = state.finalize();
                }
            }
        }

        fn destroyCallback(info: db.AggregateFunctionDestroyInfoHandle, err: [*c]db.ErrorInfoHandle) callconv(.c) void {
            var count: db.idx_t = 0;
            if (db.aggregateFunctionDestroyGetStateCount(info, &count, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            var states: [*c]?*anyopaque = null;
            if (db.aggregateFunctionDestroyGetStates(info, &states, err) != db.c.DUCKDB_V2_ERROR_NONE) return;

            var i: db.idx_t = 0;
            while (i < count) : (i += 1) {
                const state: *State = @ptrCast(@alignCast(states[i].?));
                state.deinit();
            }
        }

        inline fn rowIsValid(views: *const [arg_types.len]db.VectorView, row: db.idx_t) bool {
            inline for (0..arg_types.len) |i| {
                if (views.*[i].validity) |validity| {
                    const entry_idx = row / 64;
                    const bit_idx: u6 = @intCast(row % 64);
                    if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return false;
                }
            }
            return true;
        }

        fn MakeArgsTuple() type {
            var types: [arg_types.len]type = undefined;
            for (0..arg_types.len) |i| types[i] = arg_types[i].?;
            return @Tuple(&types);
        }
        const ArgsTuple = MakeArgsTuple();

        inline fn buildArgs(views: *const [arg_types.len]db.VectorView, row: db.idx_t) ArgsTuple {
            var args: ArgsTuple = undefined;
            inline for (0..arg_types.len) |i| {
                const T = arg_types[i].?;
                if (T == []const u8) {
                    // SAFETY: views[i].data points to a flattened VARCHAR vector buffer
                    // of duckdb_v2_bytes elements; see BytesValue's own doc comment.
                    const typed: [*]const db.BytesValue = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = db.bytesSlice(&typed[row]);
                } else {
                    // SAFETY: views[i].data points to a flattened, type-matched vector buffer.
                    const typed: [*]const T = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = typed[row];
                }
            }
            return args;
        }
    };
}

test "Function generates a valid Zig type for a sum aggregate" {
    const Sum = Function("v2_test_agg_sum", struct {
        sum: i64,
        pub fn init() @This() {
            return .{ .sum = 0 };
        }
        pub fn update(self: *@This(), x: i64) void {
            self.sum += x;
        }
        pub fn combine(self: *@This(), other: @This()) void {
            self.sum += other.sum;
        }
        pub fn finalize(self: @This()) i64 {
            return self.sum;
        }
    });
    // Referencing .register forces analysis of its comptime-unrolled body.
    _ = &Sum.register;
    const size_cb: db.c.duckdb_v2_aggregate_function_size_callback_fn = Sum.sizeCallback;
    const init_cb: db.c.duckdb_v2_aggregate_function_init_callback_fn = Sum.initCallback;
    const update_cb: db.c.duckdb_v2_aggregate_function_update_callback_fn = Sum.updateCallback;
    const combine_cb: db.c.duckdb_v2_aggregate_function_combine_callback_fn = Sum.combineCallback;
    const finalize_cb: db.c.duckdb_v2_aggregate_function_finalize_callback_fn = Sum.finalizeCallback;
    try std.testing.expect(size_cb != null);
    try std.testing.expect(init_cb != null);
    try std.testing.expect(update_cb != null);
    try std.testing.expect(combine_cb != null);
    try std.testing.expect(finalize_cb != null);
}

test "FunctionNamed supports a real per-row argument name" {
    const Sum = FunctionNamed("v2_test_agg_sum_named", struct {
        sum: i64,
        pub fn init() @This() {
            return .{ .sum = 0 };
        }
        pub fn update(self: *@This(), x: i64) void {
            self.sum += x;
        }
        pub fn combine(self: *@This(), other: @This()) void {
            self.sum += other.sum;
        }
        pub fn finalize(self: @This()) i64 {
            return self.sum;
        }
    }, &.{"x"});
    _ = &Sum.register;
}

test "Function supports multiple arguments" {
    const WeightedSum = Function("v2_test_agg_weighted_sum", struct {
        total: f64,
        pub fn init() @This() {
            return .{ .total = 0 };
        }
        pub fn update(self: *@This(), x: f64, weight: f64) void {
            self.total += x * weight;
        }
        pub fn combine(self: *@This(), other: @This()) void {
            self.total += other.total;
        }
        pub fn finalize(self: @This()) f64 {
            return self.total;
        }
    });
    _ = &WeightedSum.register;
}

test "Function supports an optional finalize return (NULL on empty/zero-weight groups)" {
    const WeightedAvg = Function("v2_test_agg_weighted_avg", struct {
        weighted_sum: f64,
        weight_sum: f64,
        pub fn init() @This() {
            return .{ .weighted_sum = 0, .weight_sum = 0 };
        }
        pub fn update(self: *@This(), x: f64, weight: f64) void {
            self.weighted_sum += x * weight;
            self.weight_sum += weight;
        }
        pub fn combine(self: *@This(), other: @This()) void {
            self.weighted_sum += other.weighted_sum;
            self.weight_sum += other.weight_sum;
        }
        pub fn finalize(self: @This()) ?f64 {
            if (self.weight_sum == 0) return null;
            return self.weighted_sum / self.weight_sum;
        }
    });
    _ = &WeightedAvg.register;
    const finalize_cb: db.c.duckdb_v2_aggregate_function_finalize_callback_fn = WeightedAvg.finalizeCallback;
    try std.testing.expect(finalize_cb != null);
}

test "Function supports VARCHAR as an update argument" {
    const TotalLen = Function("v2_test_agg_total_len", struct {
        len: i64,
        pub fn init() @This() {
            return .{ .len = 0 };
        }
        pub fn update(self: *@This(), s: []const u8) void {
            self.len += @intCast(s.len);
        }
        pub fn combine(self: *@This(), other: @This()) void {
            self.len += other.len;
        }
        pub fn finalize(self: @This()) i64 {
            return self.len;
        }
    });
    _ = &TotalLen.register;
}

test "Function supports VARCHAR as finalize's return type" {
    const LastSeen = Function("v2_test_agg_last_seen", struct {
        buf: [64]u8,
        len: usize,
        pub fn init() @This() {
            return .{ .buf = undefined, .len = 0 };
        }
        pub fn update(self: *@This(), s: []const u8) void {
            self.len = @min(s.len, self.buf.len);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }
        pub fn combine(self: *@This(), other: @This()) void {
            if (other.len != 0) {
                self.len = other.len;
                @memcpy(self.buf[0..self.len], other.buf[0..other.len]);
            }
        }
        pub fn finalize(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    });
    _ = &LastSeen.register;
}

test "Function supports a State that owns growable string data, freed via deinit/destroy" {
    const StringAgg = Function("v2_test_agg_string_agg", struct {
        buf: std.ArrayList(u8),
        pub fn init() @This() {
            return .{ .buf = .empty };
        }
        pub fn update(self: *@This(), s: []const u8) void {
            if (self.buf.items.len != 0) self.buf.append(std.heap.c_allocator, ',') catch return;
            self.buf.appendSlice(std.heap.c_allocator, s) catch return;
        }
        pub fn combine(self: *@This(), other: @This()) void {
            // `other`'s own backing buffer is NOT freed here — its owning
            // state gets its own `deinit` call later (see this file's
            // module doc comment on `deinit`'s contract).
            if (other.buf.items.len == 0) return;
            if (self.buf.items.len != 0) self.buf.append(std.heap.c_allocator, ',') catch return;
            self.buf.appendSlice(std.heap.c_allocator, other.buf.items) catch return;
        }
        pub fn finalize(self: @This()) []const u8 {
            return self.buf.items;
        }
        pub fn deinit(self: *@This()) void {
            self.buf.deinit(std.heap.c_allocator);
        }
    });
    _ = &StringAgg.register;
    const destroy_cb: db.c.duckdb_v2_aggregate_function_destroy_callback_fn = StringAgg.destroyCallback;
    try std.testing.expect(destroy_cb != null);
}

test "Function supports an optional updateBatch fast path" {
    const WeightedAvgSimd = Function("v2_test_agg_weighted_avg_simd", struct {
        weighted_sum: f64,
        weight_sum: f64,
        pub fn init() @This() {
            return .{ .weighted_sum = 0, .weight_sum = 0 };
        }
        pub fn update(self: *@This(), x: f64, weight: f64) void {
            self.weighted_sum += x * weight;
            self.weight_sum += weight;
        }
        pub fn updateBatch(self: *@This(), views: *const [2]db.VectorView, row_count: db.idx_t) void {
            // Trivial scalar stand-in for the test — the real SIMD kernel
            // lives in init_v2_poc.zig's live example.
            const x: [*]const f64 = @ptrCast(@alignCast(views[0].data));
            const w: [*]const f64 = @ptrCast(@alignCast(views[1].data));
            var row: db.idx_t = 0;
            while (row < row_count) : (row += 1) {
                self.weighted_sum += x[row] * w[row];
                self.weight_sum += w[row];
            }
        }
        pub fn combine(self: *@This(), other: @This()) void {
            self.weighted_sum += other.weighted_sum;
            self.weight_sum += other.weight_sum;
        }
        pub fn finalize(self: @This()) ?f64 {
            if (self.weight_sum == 0) return null;
            return self.weighted_sum / self.weight_sum;
        }
    });
    _ = &WeightedAvgSimd.register;
}
