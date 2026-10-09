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
///! `update`'s parameters (after `self`) and `finalize`'s return type are
///! introspected at comptime to build the function signature, the same way
///! `comptime_scalar_v2.Function` reads a per-row function's shape. No size,
///! bind, or destroy callback is needed from the caller: size is
///! `@sizeOf(State)`, there's no dynamic return type, and State owns no
///! resources requiring a destructor.
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
        else => @compileError("unsupported type for DuckDB v2 mapping: " ++ @typeName(T)),
    };
}

pub fn Function(comptime name: [:0]const u8, comptime State: type) type {
    const update_info = @typeInfo(@TypeOf(State.update)).@"fn";
    // update_info.param_types[0] is *State (self); the rest are the
    // per-row arguments to expose as the SQL function's parameters.
    const arg_types = update_info.param_types[1..];
    const finalize_info = @typeInfo(@TypeOf(State.finalize)).@"fn";
    const ReturnType = finalize_info.return_type.?;

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

            var row: db.idx_t = 0;
            while (row < row_count) : (row += 1) {
                // Standard SQL aggregate semantics: a row with any NULL
                // argument is skipped, not folded in as a zero/default.
                if (!rowIsValid(&views, row)) continue;
                const state: *State = @ptrCast(@alignCast(states[row].?));
                @call(.auto, State.update, .{state} ++ buildArgs(&views, row));
            }
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

            var out_data: ?*anyopaque = null;
            if (db.vectorGetDataMutable(result_vec, &out_data, err) != db.c.DUCKDB_V2_ERROR_NONE) return;
            const out: [*]ReturnType = @ptrCast(@alignCast(out_data));

            var i: db.idx_t = 0;
            while (i < count) : (i += 1) {
                const state: *State = @ptrCast(@alignCast(states[i].?));
                out[offset + i] = state.finalize();
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
                // SAFETY: views[i].data points to a flattened, type-matched vector buffer.
                const typed: [*]const T = @ptrCast(@alignCast(views.*[i].data));
                args[i] = typed[row];
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
