///! Minimal real v2 extension entrypoint, built only to prove
///! `src/lib/duckdb_v2.zig`'s bindings against a live DuckDB v2.0 alpha
///! runtime (not wired into the real `zig_ext` extension or its build
///! target — see the `v2-poc` build step).
///!
///! Registers one scalar function, `zig_v2_double(x BIGINT) -> BIGINT`, one
///! table function, `zig_v2_range3()`, one aggregate function,
///! `zig_v2_agg_sum(x BIGINT) -> BIGINT`, using the hand-written
///! exec/bind/size/init/update/combine/finalize callbacks already
///! type-checked under `v2-check` — plus `zig_v2_triple`/`zig_v2_add`,
///! registered through `comptime_scalar_v2.Function`, `zig_v2_range3_ct`,
///! registered through `comptime_table_v2.Function` (reusing the same
///! bind/init_global/exec callbacks as `zig_v2_range3`, to isolate what's
///! being tested to the framework's registration wiring, not the callback
///! logic — already proven separately by the hand-written version), and
///! `zig_v2_agg_sum_ct`, registered through `comptime_aggregate_v2.Function`.
const db2 = @import("duckdb_v2");
const examples = @import("duckdb_v2_examples");
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const comptime_table_v2 = @import("comptime_table_v2");
const comptime_aggregate_v2 = @import("comptime_aggregate_v2");

export fn zig_ext_v2_poc_init_c_api_v2(input: *const db2.ExtensionInput) callconv(.c) void {
    if (!db2.initApi(input, "v2.0.0")) return;

    var err: db2.ErrorInfoHandle = undefined;

    registerDouble(input, &err);
    registerRange3(input, &err);
    registerAggSum(input, &err);
    registerHello(input, &err);
    registerComptimeExamples(input);
}

fn registerHello(input: *const db2.ExtensionInput, err: *db2.ErrorInfoHandle) void {
    var function: db2.ScalarFunctionHandle = undefined;
    if (db2.scalarFunctionCreateWithExtension(input.extension, &function, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.scalarFunctionDestroy(&function);

    const fn_name = db2.str("zig_v2_hello");
    if (db2.scalarFunctionSetName(function, &fn_name, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var varchar_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.logicalTypeDestroy(&varchar_type);

    var sig: db2.FunctionSignatureHandle = undefined;
    if (db2.scalarFunctionGetSignature(function, &sig, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    const param_name = db2.str("name");
    if (db2.functionSignatureAddParameter(
        sig,
        &param_name,
        varchar_type,
        null,
        db2.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD,
        err,
    ) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.functionSignatureSetReturnType(sig, varchar_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    if (db2.scalarFunctionSetExecCallback(function, exampleHelloExec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    _ = db2.scalarFunctionRegister(function, err);
}

const Triple = comptime_scalar_v2.Function("zig_v2_triple", struct {
    fn eval(a: i64) i64 {
        return a * 3;
    }
}.eval);

const Add = comptime_scalar_v2.Function("zig_v2_add", struct {
    fn eval(a: i64, b: i64) i64 {
        return a + b;
    }
}.eval);

/// Proves comptime_scalar_v2's VARCHAR support through the generic
/// framework path (not the hand-written zig_v2_hello example): takes and
/// returns a string, borrowing a substring of the argument — safe per the
/// framework's documented constraint against returning local-buffer slices.
const FirstChar = comptime_scalar_v2.Function("zig_v2_first_char_ct", struct {
    fn eval(s: []const u8) []const u8 {
        return s[0..@min(1, s.len)];
    }
}.eval);

const Range3Ct = comptime_table_v2.Function(struct {
    pub const name: [:0]const u8 = "zig_v2_range3_ct";
    pub const param_types = [_]db2.LogicalTypeId{};
    pub const bind = exampleTableBind;
    pub const initGlobal = exampleTableInitGlobal;
    pub const exec = exampleTableExec;
});

const AggSumCt = comptime_aggregate_v2.Function("zig_v2_agg_sum_ct", struct {
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

const WeightedAvgCt = comptime_aggregate_v2.Function("zig_v2_weighted_avg_ct", struct {
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

/// Returns the id of the row with the largest value in each group — e.g.
/// "which leaf dominates this subtree". Unlike sum/weighted_avg, `combine`
/// isn't additive: it picks whichever side's best value wins, the first
/// non-additive-combine test of the framework. `has_value` distinguishes a
/// group that genuinely never saw a row from one whose best value happens
/// to be the type's zero value, so `finalize` can return proper SQL NULL
/// for an empty group instead of a bogus id.
const ArgMaxCt = comptime_aggregate_v2.Function("zig_v2_arg_max_ct", struct {
    best_id: i64,
    best_value: f64,
    has_value: bool,
    pub fn init() @This() {
        return .{ .best_id = 0, .best_value = 0, .has_value = false };
    }
    pub fn update(self: *@This(), id: i64, value: f64) void {
        if (!self.has_value or value > self.best_value) {
            self.best_id = id;
            self.best_value = value;
            self.has_value = true;
        }
    }
    pub fn combine(self: *@This(), other: @This()) void {
        if (!other.has_value) return;
        if (!self.has_value or other.best_value > self.best_value) {
            self.best_id = other.best_id;
            self.best_value = other.best_value;
            self.has_value = true;
        }
    }
    pub fn finalize(self: @This()) ?i64 {
        if (!self.has_value) return null;
        return self.best_id;
    }
});

/// Proves VARCHAR as an aggregate `update` argument through the generic
/// framework path: total character count across a group's strings.
const TotalLenCt = comptime_aggregate_v2.Function("zig_v2_total_len_ct", struct {
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

/// Proves VARCHAR as an aggregate `finalize` return type through the
/// generic framework path: last string seen in the group, both under and
/// over the 12-byte inline threshold (exercises both `makeBytesValue`
/// branches against the live runtime).
const LastSeenCt = comptime_aggregate_v2.Function("zig_v2_last_seen_ct", struct {
    buf: [128]u8,
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
    pub fn finalize(self: @This()) []const u8 {
        return self.buf[0..self.len];
    }
});

fn registerComptimeExamples(input: *const db2.ExtensionInput) void {
    Triple.register(input) catch {};
    Add.register(input) catch {};
    FirstChar.register(input) catch {};
    Range3Ct.register(input) catch {};
    ArgMaxCt.register(input) catch {};
    AggSumCt.register(input) catch {};
    WeightedAvgCt.register(input) catch {};
    TotalLenCt.register(input) catch {};
    LastSeenCt.register(input) catch {};
}

fn registerDouble(input: *const db2.ExtensionInput, err: *db2.ErrorInfoHandle) void {
    var function: db2.ScalarFunctionHandle = undefined;
    if (db2.scalarFunctionCreateWithExtension(input.extension, &function, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.scalarFunctionDestroy(&function);

    const fn_name = db2.str("zig_v2_double");
    if (db2.scalarFunctionSetName(function, &fn_name, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var bigint_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.logicalTypeDestroy(&bigint_type);

    var sig: db2.FunctionSignatureHandle = undefined;
    if (db2.scalarFunctionGetSignature(function, &sig, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    const param_name = db2.str("x");
    if (db2.functionSignatureAddParameter(
        sig,
        &param_name,
        bigint_type,
        null,
        db2.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD,
        err,
    ) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    if (db2.functionSignatureSetReturnType(sig, bigint_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    if (db2.scalarFunctionSetExecCallback(function, exampleDoubleExec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    _ = db2.scalarFunctionRegister(function, err);
}

fn registerRange3(input: *const db2.ExtensionInput, err: *db2.ErrorInfoHandle) void {
    var function: db2.TableFunctionHandle = undefined;
    if (db2.tableFunctionCreateWithExtension(input.extension, &function, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.tableFunctionDestroy(&function);

    const fn_name = db2.str("zig_v2_range3");
    if (db2.tableFunctionSetName(function, &fn_name, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    if (db2.tableFunctionSetBindCallback(function, exampleTableBind, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.tableFunctionSetInitGlobalCallback(function, exampleTableInitGlobal, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.tableFunctionSetExecCallback(function, exampleTableExec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    _ = db2.tableFunctionRegister(function, err);
}

fn registerAggSum(input: *const db2.ExtensionInput, err: *db2.ErrorInfoHandle) void {
    var function: db2.AggregateFunctionHandle = undefined;
    if (db2.aggregateFunctionCreateWithExtension(input.extension, &function, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.aggregateFunctionDestroy(&function);

    const fn_name = db2.str("zig_v2_agg_sum");
    if (db2.aggregateFunctionSetName(function, &fn_name, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var bigint_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.logicalTypeDestroy(&bigint_type);

    var sig: db2.FunctionSignatureHandle = undefined;
    if (db2.aggregateFunctionGetSignature(function, &sig, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    const param_name = db2.str("x");
    if (db2.functionSignatureAddParameter(
        sig,
        &param_name,
        bigint_type,
        null,
        db2.c.DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD,
        err,
    ) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.functionSignatureSetReturnType(sig, bigint_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    if (db2.aggregateFunctionSetSizeCallback(function, exampleAggSize, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.aggregateFunctionSetInitCallback(function, exampleAggInit, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.aggregateFunctionSetUpdateCallback(function, exampleAggUpdate, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.aggregateFunctionSetCombineCallback(function, exampleAggCombine, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.aggregateFunctionSetFinalizeCallback(function, exampleAggFinalize, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    _ = db2.aggregateFunctionRegister(function, err);
}

// Private test-only decls of duckdb_v2.zig, re-exposed here so this file
// can wire them up without making them a permanent public API of the
// bindings module.
const exampleDoubleExec = examples.exampleDoubleExecForPoc;
const exampleHelloExec = examples.exampleHelloExecForPoc;
const exampleTableBind = examples.exampleTableBindForPoc;
const exampleTableInitGlobal = examples.exampleTableInitGlobalForPoc;
const exampleTableExec = examples.exampleTableExecForPoc;
const exampleAggSize = examples.exampleAggregateSizeForPoc;
const exampleAggInit = examples.exampleAggregateInitForPoc;
const exampleAggUpdate = examples.exampleAggregateUpdateForPoc;
const exampleAggCombine = examples.exampleAggregateCombineForPoc;
const exampleAggFinalize = examples.exampleAggregateFinalizeForPoc;
