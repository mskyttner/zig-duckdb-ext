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
///! registered through `comptime_scalar_v2.Function`, `zig_v2_range_ct`/
///! `zig_v2_repeat_ct`, registered through `comptime_table_v2.Function`'s
///! generalized Row/init/next shape (fully generated bind/exec, not
///! hand-written callbacks reused from `zig_v2_range3`), and
///! `zig_v2_agg_sum_ct`, registered through `comptime_aggregate_v2.Function`.
const std = @import("std");
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

/// Proves comptime_scalar_v2's STRUCT-argument support: squared distance
/// from the origin for a `STRUCT(x BIGINT, y BIGINT)` point.
const PointDist2 = comptime_scalar_v2.Function("zig_v2_point_dist2_ct", struct {
    const Point = struct { x: i64, y: i64 };
    fn eval(p: Point) i64 {
        return p.x * p.x + p.y * p.y;
    }
}.eval);

/// Proves a STRUCT with a VARCHAR field, mixed with a plain argument.
const PersonGreet = comptime_scalar_v2.Function("zig_v2_person_greet_ct", struct {
    const Person = struct { name: []const u8, age: i64 };
    fn eval(p: Person, excited: bool) i64 {
        return @as(i64, @intCast(p.name.len)) + p.age + @as(i64, if (excited) 1 else 0);
    }
}.eval);

/// Proves comptime_scalar_v2's VARIANT support, round-trip: decodes the
/// VARIANT argument as a BIGINT, or substitutes `fallback` when it's NULL,
/// and returns a freshly created Value either way — per the CAUTION in
/// comptime_scalar_v2.zig: never return the same Value handle received as
/// an argument, since the framework destroys the argument and the return
/// value independently, so returning the same handle would double-free it.
const VariantDefault = comptime_scalar_v2.Function("zig_v2_variant_default_ct", struct {
    fn eval(context: db2.ContextHandle, v: db2.ValueHandle, fallback: i64) db2.ValueHandle {
        var err: db2.ErrorInfoHandle = undefined;
        var is_null = false;
        _ = db2.valueIsNull(v, &is_null, &err);
        var out: db2.ValueHandle = undefined;
        if (is_null) {
            _ = db2.valueCreateBigintWithContext(context, fallback, &out, &err);
        } else {
            var n: i64 = 0;
            _ = db2.valueGetBigint(v, &n, &err);
            _ = db2.valueCreateBigintWithContext(context, n, &out, &err);
        }
        return out;
    }
}.eval);

/// Proves the smaller integer/float types (i8/i16/i32/f32) are actually
/// registered and callable live, not just type-checked — the real gap
/// `docs/v2-migration-plan.md` flagged ("mapped in duckdbV2TypeId but only
/// i64/f64/bool/[]const u8 have actually been registered and called
/// against the real runtime").
const NarrowSum = comptime_scalar_v2.Function("zig_v2_narrow_sum_ct", struct {
    fn eval(a: i8, b: i16, c: i32, d: f32) f32 {
        return @as(f32, @floatFromInt(@as(i32, a) + @as(i32, b) + c)) + d;
    }
}.eval);

/// Proves TIMESTAMP and INTERVAL: adds an INTERVAL to a TIMESTAMP and
/// returns the result, both fixed-width types read/written through the
/// same direct-buffer path as any numeric type — no new exec-path code,
/// just a new duckdbV2TypeId case each (see duckdb_v2.zig's doc comments
/// on Date/Time/Timestamp/Interval for why).
const TimestampAddCt = comptime_scalar_v2.Function("zig_v2_timestamp_add_ct", struct {
    fn eval(ts: db2.Timestamp, iv: db2.Interval) db2.Timestamp {
        const micros: i64 = @backingInt(ts);
        // Calendar-aware add (months/days need the catalog's calendar,
        // not pure arithmetic) is out of scope here — this proves the
        // type plumbing, so a pure micros-based add covers the common
        // "add a fixed duration" case without needing calendar lookups.
        const added = micros + iv.micros + @as(i64, iv.days) * 86_400_000_000 + @as(i64, iv.months) * 30 * 86_400_000_000;
        return @fromBackingInt(@intCast(added));
    }
}.eval);

/// Proves BLOB as a parameter and return type: first N bytes of a blob.
const BlobPrefixCt = comptime_scalar_v2.Function("zig_v2_blob_prefix_ct", struct {
    fn eval(b: db2.Blob, n: i64) db2.Blob {
        const len = @min(@as(usize, @intCast(@max(n, 0))), b.bytes.len);
        return .{ .bytes = b.bytes[0..len] };
    }
}.eval);

/// Proves comptime_table_v2's generalized Row/init/next framework through a
/// real table-function argument (`n`) and a real VARCHAR output column —
/// unlike zig_v2_range3 above, bind/exec are fully generated, not
/// hand-written.
const RangeCt = comptime_table_v2.Function("zig_v2_range_ct", struct {
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

/// Proves VARCHAR as both a table-function constructor argument and a Row
/// output column through the generalized framework — the two cases
/// `comptime_table_v2.zig`'s module doc comment calls out as needing the
/// extra heap-copy/`deinit` dance (a bind-time `Value` doesn't outlive `bind`).
const RepeatCt = comptime_table_v2.Function("zig_v2_repeat_ct", struct {
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
    pub fn finalize(self: *const @This()) []const u8 {
        return self.buf[0..self.len];
    }
});

/// Proves the growable-string-state case live: a real `string_agg`
/// equivalent whose `State` holds a heap-allocated, comma-growing buffer —
/// `@sizeOf(State)` can't hold that directly, so `update`/`combine` grow a
/// separately allocated `std.ArrayList(u8)`, freed via `deinit`, wired up
/// as the aggregate's destroy callback by `comptime_aggregate_v2.Function`.
const StringAggCt = comptime_aggregate_v2.Function("zig_v2_string_agg_ct", struct {
    buf: std.ArrayList(u8),
    pub fn init() @This() {
        return .{ .buf = .empty };
    }
    pub fn update(self: *@This(), s: []const u8) void {
        if (self.buf.items.len != 0) self.buf.append(std.heap.c_allocator, ',') catch return;
        self.buf.appendSlice(std.heap.c_allocator, s) catch return;
    }
    pub fn combine(self: *@This(), other: @This()) void {
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

/// A 1BRC-style "stats" aggregate: min/mean/max per group, formatted
/// exactly like https://github.com/nubskr/1BRC's own output
/// ("<min>/<mean>/<max>", one decimal each) — a real-shape stress test for
/// the framework at scale (non-additive min/max combine alongside additive
/// sum/count, and a VARCHAR-return `finalize` under heavy parallel
/// combine), benchmarked against the live measurements.txt dataset
/// generated for this project's own DuckDB-vs-hand-rolled-Zig comparison.
const Stats1BrcCt = comptime_aggregate_v2.Function("zig_v2_1brc_stats_ct", struct {
    sum: f64,
    count: i64,
    min: f64,
    max: f64,
    buf: [32]u8,
    buf_len: usize,

    pub fn init() @This() {
        return .{
            .sum = 0,
            .count = 0,
            .min = std.math.inf(f64),
            .max = -std.math.inf(f64),
            .buf = undefined,
            .buf_len = 0,
        };
    }
    pub fn update(self: *@This(), temp: f64) void {
        self.sum += temp;
        self.count += 1;
        if (temp < self.min) self.min = temp;
        if (temp > self.max) self.max = temp;
    }
    pub fn combine(self: *@This(), other: @This()) void {
        if (other.count == 0) return;
        self.sum += other.sum;
        self.count += other.count;
        if (other.min < self.min) self.min = other.min;
        if (other.max > self.max) self.max = other.max;
    }
    // `self: *@This()`, not `self: @This()`: `buf` is an inline array, so a
    // by-value `self` would copy it onto this call's own stack frame and
    // the returned slice would dangle the instant this function returns —
    // see this framework's CAUTION on inline-buffer finalize. A mutable
    // pointer (rather than `*const`) also lets finalize format directly
    // into `buf` without a const-cast; mutating here is harmless since
    // nothing reads this state again before it's discarded.
    pub fn finalize(self: *@This()) ?[]const u8 {
        if (self.count == 0) return null;
        const avg = self.sum / @as(f64, @floatFromInt(self.count));
        const text = std.fmt.bufPrint(&self.buf, "{d:.1}/{d:.1}/{d:.1}", .{ self.min, avg, self.max }) catch return null;
        self.buf_len = text.len;
        return self.buf[0..self.buf_len];
    }
});

fn registerComptimeExamples(input: *const db2.ExtensionInput) void {
    Triple.register(input) catch {};
    Add.register(input) catch {};
    FirstChar.register(input) catch {};
    PointDist2.register(input) catch {};
    PersonGreet.register(input) catch {};
    VariantDefault.register(input) catch {};
    NarrowSum.register(input) catch {};
    TimestampAddCt.register(input) catch {};
    BlobPrefixCt.register(input) catch {};
    RangeCt.register(input) catch {};
    RepeatCt.register(input) catch {};
    ArgMaxCt.register(input) catch {};
    AggSumCt.register(input) catch {};
    WeightedAvgCt.register(input) catch {};
    TotalLenCt.register(input) catch {};
    StringAggCt.register(input) catch {};
    Stats1BrcCt.register(input) catch {};
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
