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
const comptime_appender_v2 = @import("comptime_appender_v2");
const comptime_cast_v2 = @import("comptime_cast_v2");
const matmul = @import("matmul");

export fn zig_ext_v2_poc_init_c_api_v2(input: *const db2.ExtensionInput) callconv(.c) void {
    if (!db2.initApi(input, "v2.0.0")) return;

    var err: db2.ErrorInfoHandle = undefined;

    registerDouble(input, &err);
    registerRange3(input, &err);
    registerAggSum(input, &err);
    registerHello(input, &err);
    registerAppenderTest(input, &err);
    registerAppenderNestedTest(input, &err);
    registerAppenderArrayEnumTest(input, &err);
    registerFilterPushdownTest(input);
    registerProjectionPushdownTest(input);
    registerComptimeExamples(input);
    registerReplacementScanTest(input);
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

/// Live test for `comptime_cast_v2.zig`: a custom VARCHAR -> BIGINT cast
/// that recognizes a small set of English number words ("one".."five") in
/// addition to plain digit strings, falling through to `std.fmt.parseInt`
/// otherwise. Deliberately a type pair DuckDB already has a built-in cast
/// for, to confirm live what registering a competing one actually does
/// (shadow it, error at registration, or something else) rather than
/// picking an exotic pair that sidesteps the question.
const WordOrDigitsToBigint = comptime_cast_v2.Function([]const u8, i64, struct {
    fn cast(s: []const u8) ?i64 {
        const words = [_][]const u8{ "one", "two", "three", "four", "five" };
        for (words, 1..) |w, i| {
            if (std.mem.eql(u8, s, w)) return @intCast(i);
        }
        return std.fmt.parseInt(i64, s, 10) catch null;
    }
}.cast);

/// Proves comptime_cast_v2's DECIMAL support: CAST(price AS DOUBLE)
/// dividing out the DECIMAL(10,2)'s own scale, and the reverse direction.
const CastPrice = db2.Decimal(10, 2);
const PriceToDoubleCast = comptime_cast_v2.Function(CastPrice, f64, struct {
    fn cast(p: CastPrice) ?f64 {
        return @as(f64, @floatFromInt(p.raw)) / 100.0;
    }
}.cast);
const DoubleToPriceCast = comptime_cast_v2.Function(f64, CastPrice, struct {
    fn cast(d: f64) ?CastPrice {
        return .{ .raw = @intFromFloat(@round(d * 100.0)) };
    }
}.cast);

/// Proves comptime_cast_v2's ENUM support. `MoodToIntCast` (ENUM source
/// to a flat BIGINT target) is live-verified working correctly, including
/// over a real multi-row table column. `MoodToVarcharCast` (ENUM source
/// to VARCHAR, a `vectorSetValue`-boxed target) is registered to prove
/// registration itself succeeds, but is confirmed BROKEN at exec time on
/// this alpha build — see comptime_cast_v2.zig's module doc comment for
/// the precise repro (not a bug in this framework's decode/registration
/// logic, confirmed via debug instrumentation). `VarcharToMoodCast`
/// (VARCHAR source to ENUM target) is live-verified working correctly.
const CastMood = enum(u8) { sad = 1, neutral = 5, happy = 9 };
const MoodToIntCast = comptime_cast_v2.Function(CastMood, i64, struct {
    fn cast(m: CastMood) ?i64 {
        return @backingInt(m);
    }
}.cast);
const MoodToVarcharCast = comptime_cast_v2.Function(CastMood, []const u8, struct {
    fn cast(m: CastMood) ?[]const u8 {
        return @tagName(m);
    }
}.cast);
const VarcharToMoodCast = comptime_cast_v2.Function([]const u8, CastMood, struct {
    fn cast(s: []const u8) ?CastMood {
        return std.meta.stringToEnum(CastMood, s);
    }
}.cast);

/// Proves comptime_cast_v2's STRUCT support, both directions (one level
/// deep, numeric/bool/VARCHAR fields).
const CastPoint = struct { x: i64, y: i64 };
const PointToVarcharCast = comptime_cast_v2.Function(CastPoint, []const u8, struct {
    fn cast(p: CastPoint) ?[]const u8 {
        _ = p;
        return "point";
    }
}.cast);
const IntToPointCast = comptime_cast_v2.Function(i64, CastPoint, struct {
    fn cast(n: i64) ?CastPoint {
        return .{ .x = n, .y = n * 2 };
    }
}.cast);

/// Proves comptime_cast_v2's VARIANT-as-source-type support (target is a
/// compile error — see that file's module doc comment for why): NULL
/// VARIANT cells cast to -1, non-NULL cells cast to 1 (not decoding the
/// held value, just distinguishing NULL from not — the smallest check
/// that proves castFn received a real, usable `db.ValueHandle`).
const VariantToIntCast = comptime_cast_v2.Function(db2.ValueHandle, i64, struct {
    fn cast(v: db2.ValueHandle) ?i64 {
        var err: db2.ErrorInfoHandle = undefined;
        var is_null: bool = false;
        _ = db2.valueIsNull(v, &is_null, &err);
        return if (is_null) -1 else 1;
    }
}.cast);

/// Proves comptime_scalar_v2's STRUCT *return* support: constructs a fresh
/// `STRUCT(x BIGINT, y BIGINT)` point from a single scalar.
const PointMake = comptime_scalar_v2.Function("zig_v2_point_make_ct", struct {
    const Point = struct { x: i64, y: i64 };
    fn eval(n: i64) Point {
        return .{ .x = n, .y = n * 2 };
    }
}.eval);

/// Proves STRUCT argument and STRUCT return together, including a VARCHAR
/// field on the return side: takes a `STRUCT(name VARCHAR, age BIGINT)`
/// and returns a new one with `age` incremented and `name` unchanged.
const PersonBirthday = comptime_scalar_v2.Function("zig_v2_person_birthday_ct", struct {
    const Person = struct { name: []const u8, age: i64 };
    fn eval(p: Person) Person {
        return .{ .name = p.name, .age = p.age + 1 };
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

/// Proves DECIMAL as a parameter and return type: applies a tax rate
/// (as a plain double) to a DECIMAL(10,2) price, returning DECIMAL(10,2).
const Price = db2.Decimal(10, 2);
const ApplyTaxCt = comptime_scalar_v2.Function("zig_v2_apply_tax_ct", struct {
    fn eval(price: Price, rate: f64) Price {
        const scaled: f64 = @as(f64, @floatFromInt(price.raw)) * (1.0 + rate);
        return .{ .raw = @intFromFloat(@round(scaled)) };
    }
}.eval);

/// Proves DECIMAL at the i128 storage tier (width 38).
const BigDecimal = db2.Decimal(38, 10);
const BigDecimalDoubleCt = comptime_scalar_v2.Function("zig_v2_big_decimal_double_ct", struct {
    fn eval(d: BigDecimal) BigDecimal {
        return .{ .raw = d.raw * 2 };
    }
}.eval);

/// Proves ENUM as a parameter and return type, including a NULL row
/// (skipped via the generic "any NULL argument skips the row" convention,
/// unaffected by ENUM's own dictionary-ordinal decode) and manually-
/// numbered variants (decoded via the enum's own declaration order, not
/// `@enumFromInt(ordinal)` — see comptime_scalar_v2.zig's `decodeEnumArg`).
const Mood = enum(u8) { sad = 1, neutral = 5, happy = 9 };
const NextMoodCt = comptime_scalar_v2.Function("zig_v2_next_mood_ct", struct {
    fn eval(m: Mood) Mood {
        return switch (m) {
            .sad => .neutral,
            .neutral => .happy,
            .happy => .happy,
        };
    }
}.eval);

/// Proves LIST(BIGINT) as a parameter type: zero-copy slice decode via
/// ListEntry{offset,length} into the flattened child vector.
const ListSumCt = comptime_scalar_v2.Function("zig_v2_list_sum_ct", struct {
    fn eval(xs: []const i64) i64 {
        var total: i64 = 0;
        for (xs) |x| total += x;
        return total;
    }
}.eval);

/// Proves LIST(BIGINT) as a return type: boxed element-by-element via
/// valueCreateListWithContext, a dynamic (per-row) length. Slices a
/// file-scope `const` array (static storage) rather than a local stack
/// buffer — per comptime_scalar_v2.zig's own CAUTION on VARCHAR returns,
/// a slice into implFn's own stack frame is unsafe, since the Value box
/// happens after implFn returns.
const list_range_values = [16]i64{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const ListRangeCt = comptime_scalar_v2.Function("zig_v2_list_range_ct", struct {
    fn eval(n: i64) []const i64 {
        const len = @min(@as(usize, @intCast(@max(n, 0))), list_range_values.len);
        return list_range_values[0..len];
    }
}.eval);

/// Proves ARRAY(DOUBLE, 3) as a parameter and return type: fixed-size,
/// contiguous-per-row decode/encode, no ListEntry needed.
const ArrayScale3Ct = comptime_scalar_v2.Function("zig_v2_array_scale3_ct", struct {
    fn eval(xs: [3]f64, factor: f64) [3]f64 {
        return .{ xs[0] * factor, xs[1] * factor, xs[2] * factor };
    }
}.eval);

/// Proves MAP(BIGINT, BIGINT) as a parameter type: zero-copy-ish decode
/// (zipped into a bounded per-row stack buffer, since db.Map's `entries`
/// field is an array of structs but the source storage is two parallel
/// flat key/value arrays) from the parent MAP vector's own
/// ListEntry{offset,length} plus its nested entries-STRUCT child.
const MapSumValuesCt = comptime_scalar_v2.Function("zig_v2_map_sum_values_ct", struct {
    fn eval(m: comptime_scalar_v2.Map(i64, i64)) i64 {
        var total: i64 = 0;
        for (m.entries) |e| total += e.value;
        return total;
    }
}.eval);

/// Proves MAP(BIGINT, BIGINT) as a return type: boxed via
/// valueCreateMapWithContext (parallel key/value Value arrays). Returns
/// a slice into a file-scope `const` array (static storage), same
/// safety reasoning as `ListRangeCt`.
const map_range_entries = [4]comptime_scalar_v2.Map(i64, i64).Entry{
    .{ .key = 1, .value = 10 },
    .{ .key = 2, .value = 20 },
    .{ .key = 3, .value = 30 },
    .{ .key = 4, .value = 40 },
};
const MapRangeCt = comptime_scalar_v2.Function("zig_v2_map_range_ct", struct {
    fn eval(n: i64) comptime_scalar_v2.Map(i64, i64) {
        const len = @min(@as(usize, @intCast(@max(n, 0))), map_range_entries.len);
        return .{ .entries = map_range_entries[0..len] };
    }
}.eval);

/// Proves UNION as a parameter and return type (round-trip), including
/// a VARCHAR member — a plain Zig tagged union, no wrapper type needed
/// (unlike MAP), since it's already a 1:1 match for SQL UNION.
/// Proves UNION as a parameter and return type (round-trip) — a plain
/// Zig tagged union, no wrapper type needed (unlike MAP), since it's
/// already a 1:1 match for SQL UNION. Live-verified over a real
/// multi-row table with MIXED tags per row, not just a single constant
/// value — see `UnionMakeCt`'s own doc comment for why that distinction
/// mattered here.
const NumOrText = union(enum) { num: i64, text: []const u8 };
const UnionRoundtripCt = comptime_scalar_v2.Function("zig_v2_union_roundtrip_ct", struct {
    fn eval(u: NumOrText) NumOrText {
        return u;
    }
}.eval);

/// Proves UNION as an argument type specifically (decode via the tag
/// child + the active member's own child, `@unionInit`).
const UnionTagCt = comptime_scalar_v2.Function("zig_v2_union_tag_ct", struct {
    fn eval(u: NumOrText) i64 {
        return switch (u) {
            .num => |n| n,
            .text => |t| @intCast(t.len),
        };
    }
}.eval);

/// Proves UNION as a return type over a real multi-row batch with
/// MIXED tags (alternating num/text per row) — the case that caught a
/// real bug: writing only the active member's child vector per row and
/// leaving every other member's row untouched worked fine when every
/// member was a flat numeric type (see `UnionMakeNumNumCt` below, which
/// never crashed), but segfaulted as soon as one member was VARCHAR —
/// confirmed narrowed to exactly that combination by testing both
/// shapes independently. Fixed in `comptime_scalar_v2.zig`'s
/// `writeUnionResult` by explicitly `vectorSetNull`-ing every
/// *inactive* member's row, not just leaving it alone.
const UnionMakeCt = comptime_scalar_v2.Function("zig_v2_union_make_ct", struct {
    fn eval(n: i64) NumOrText {
        return if (@mod(n, 2) == 0) .{ .num = n } else .{ .text = "odd" };
    }
}.eval);

/// The control case for `UnionMakeCt`'s bug: two flat numeric members,
/// mixed tags across rows — worked correctly even before the
/// `vectorSetNull`-the-inactive-members fix, narrowing the real bug to
/// specifically a VARCHAR member combined with mixed tags.
const NumOrNum = union(enum) { a: i64, b: f64 };
const UnionMakeNumNumCt = comptime_scalar_v2.Function("zig_v2_union_make_numnum_ct", struct {
    fn eval(n: i64) NumOrNum {
        return if (@mod(n, 2) == 0) .{ .a = n } else .{ .b = @floatFromInt(n) };
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

/// Proves comptime_table_v2's optional `progress` hook. `i` is atomic, not
/// a bare field, since `progress` runs concurrently with `next` even for
/// this single-threaded scan (confirmed live — see comptime_table_v2.zig's
/// module doc comment on `progress`).
const RangeProgressCt = comptime_table_v2.Function("zig_v2_range_progress_ct", struct {
    n: i64,
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

/// `@Vector`-accelerated twin of `WeightedAvgCt`, identical SQL semantics
/// (including NULL handling), differing ONLY in `updateBatch`: the
/// `comptime_aggregate_v2.zig` framework tries it first for an ungrouped
/// `SELECT zig_v2_weighted_avg_simd_ct(x, w) FROM t` (every row's state
/// pointer the same), folding the whole chunk's NULL-masked `Σ(x·w)`/`Σw`
/// into one SIMD pass instead of 2048 scalar `update` calls — see
/// `comptime_aggregate_v2.zig`'s module doc comment on `updateBatch` for
/// the full contract, and `task bench` / this file's own benchmark note
/// for the live comparison against `WeightedAvgCt`.
const lanes = std.simd.suggestVectorLength(f64) orelse 1;
const V = @Vector(lanes, f64);

inline fn simdIsValid(bits: [*]const u64, i: db2.idx_t) bool {
    const entry_idx = i / 64;
    const bit_idx: u6 = @intCast(i % 64);
    return (bits[entry_idx] >> bit_idx) & 1 == 1;
}

const WeightedAvgSimdCt = comptime_aggregate_v2.Function("zig_v2_weighted_avg_simd_ct", struct {
    weighted_sum: f64,
    weight_sum: f64,
    pub fn init() @This() {
        return .{ .weighted_sum = 0, .weight_sum = 0 };
    }
    pub fn update(self: *@This(), x: f64, weight: f64) void {
        self.weighted_sum += x * weight;
        self.weight_sum += weight;
    }
    pub fn updateBatch(self: *@This(), views: *const [2]db2.VectorView, row_count: db2.idx_t) void {
        // SAFETY: the signature registered this function's args as (DOUBLE, DOUBLE).
        const x: [*]const f64 = @ptrCast(@alignCast(views[0].data));
        const w: [*]const f64 = @ptrCast(@alignCast(views[1].data));
        const x_valid = views[0].validity;
        const w_valid = views[1].validity;

        var wsum_acc: V = @splat(0);
        var w_acc: V = @splat(0);
        var i: db2.idx_t = 0;
        while (i + lanes <= row_count) : (i += lanes) {
            const xv: V = x[i..][0..lanes].*;
            const wv: V = w[i..][0..lanes].*;
            var mask: @Vector(lanes, bool) = @splat(true);
            inline for (0..lanes) |l| {
                if (x_valid) |b| {
                    if (!simdIsValid(b, i + l)) mask[l] = false;
                }
                if (w_valid) |b| {
                    if (!simdIsValid(b, i + l)) mask[l] = false;
                }
            }
            wsum_acc += @select(f64, mask, xv * wv, @as(V, @splat(0)));
            w_acc += @select(f64, mask, wv, @as(V, @splat(0)));
        }
        // Masked final partial vector instead of a scalar tail: gather
        // the remaining 0..lanes-1 rows into a zero-padded local buffer
        // (`inline for` unrolls at comptime — no runtime loop — and never
        // reads past `row_count`, so this needs no assumption about what
        // lies beyond it in the vector's own backing storage) and fold
        // them in through the SAME vector op, with out-of-range lanes
        // masked off exactly like NULL lanes are.
        const remaining = row_count - i;
        if (remaining > 0) {
            var x_buf: [lanes]f64 = @splat(0);
            var w_buf: [lanes]f64 = @splat(0);
            var mask: @Vector(lanes, bool) = @splat(false);
            inline for (0..lanes) |l| {
                if (l < remaining) {
                    const row = i + l;
                    var valid = true;
                    if (x_valid) |b| {
                        if (!simdIsValid(b, row)) valid = false;
                    }
                    if (w_valid) |b| {
                        if (!simdIsValid(b, row)) valid = false;
                    }
                    if (valid) {
                        x_buf[l] = x[row];
                        w_buf[l] = w[row];
                        mask[l] = true;
                    }
                }
            }
            const xv: V = x_buf;
            const wv: V = w_buf;
            wsum_acc += @select(f64, mask, xv * wv, @as(V, @splat(0)));
            w_acc += @select(f64, mask, wv, @as(V, @splat(0)));
        }

        self.weighted_sum += @reduce(.Add, wsum_acc);
        self.weight_sum += @reduce(.Add, w_acc);
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
    PointMake.register(input) catch {};
    PersonBirthday.register(input) catch {};
    WordOrDigitsToBigint.register(input) catch {};
    PriceToDoubleCast.register(input) catch {};
    DoubleToPriceCast.register(input) catch {};
    MoodToVarcharCast.register(input) catch {};
    MoodToIntCast.register(input) catch {};
    VarcharToMoodCast.register(input) catch {};
    PointToVarcharCast.register(input) catch {};
    IntToPointCast.register(input) catch {};
    VariantToIntCast.register(input) catch {};
    VariantDefault.register(input) catch {};
    NarrowSum.register(input) catch {};
    TimestampAddCt.register(input) catch {};
    BlobPrefixCt.register(input) catch {};
    ApplyTaxCt.register(input) catch {};
    BigDecimalDoubleCt.register(input) catch {};
    NextMoodCt.register(input) catch {};
    ListSumCt.register(input) catch {};
    ListRangeCt.register(input) catch {};
    ArrayScale3Ct.register(input) catch {};
    MapSumValuesCt.register(input) catch {};
    MapRangeCt.register(input) catch {};
    UnionRoundtripCt.register(input) catch {};
    UnionTagCt.register(input) catch {};
    UnionMakeCt.register(input) catch {};
    UnionMakeNumNumCt.register(input) catch {};
    MatmulNaiveCt.register(input) catch {};
    MatmulCt.register(input) catch {};
    MatmulBenchCt.register(input) catch {};
    RangeCt.register(input) catch {};
    RangeProgressCt.register(input) catch {};
    RepeatCt.register(input) catch {};
    ArgMaxCt.register(input) catch {};
    AggSumCt.register(input) catch {};
    WeightedAvgCt.register(input) catch {};
    WeightedAvgSimdCt.register(input) catch {};
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

/// Live round-trip test for `comptime_appender_v2.Appender`: builds three
/// rows with it, `finish`es into a `ColumnDataCollection`, scans the
/// collection back out, and formats what it reads as the result string —
/// proof (run against a real v2.0 alpha, not just `v2-check`'s
/// type-checking) that append → finish → scan round-trips BIGINT/VARCHAR/
/// DOUBLE correctly. `zig_v2_appender_test()` takes no arguments; its
/// result should read exactly
/// "1:alice:1.50|2:bob:2.75|3:carol:-4.00" if the round trip is intact.
fn registerAppenderTest(input: *const db2.ExtensionInput, err: *db2.ErrorInfoHandle) void {
    var function: db2.ScalarFunctionHandle = undefined;
    if (db2.scalarFunctionCreateWithExtension(input.extension, &function, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.scalarFunctionDestroy(&function);

    const fn_name = db2.str("zig_v2_appender_test");
    if (db2.scalarFunctionSetName(function, &fn_name, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var varchar_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.logicalTypeDestroy(&varchar_type);

    var sig: db2.FunctionSignatureHandle = undefined;
    if (db2.scalarFunctionGetSignature(function, &sig, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.functionSignatureSetReturnType(sig, varchar_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    if (db2.scalarFunctionSetExecCallback(function, appenderTestExec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    _ = db2.scalarFunctionRegister(function, err);
}

const AppenderTestRow = struct { id: i64, name: []const u8, score: f64 };

fn appenderTestExec(info: db2.ScalarFunctionExecInfoHandle, context: db2.ContextHandle, err: [*c]db2.ErrorInfoHandle) callconv(.c) void {
    var row_count: db2.idx_t = 0;
    if (db2.scalarFunctionExecGetRowCount(info, &row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: db2.VectorHandle = undefined;
    if (db2.scalarFunctionExecGetResult(info, &result_vec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.vectorSetSize(result_vec, row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var buf: [256]u8 = undefined;
    const text = appenderTestRoundTrip(context, &buf, err) catch "appender round-trip FAILED";

    var row: db2.idx_t = 0;
    while (row < row_count) : (row += 1) {
        var value: db2.ValueHandle = undefined;
        if (db2.valueCreateVarcharWithContext(context, text, &value, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = db2.valueDestroy(&value);
        if (db2.vectorSetValue(result_vec, row, value, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    }
}

const Appender = comptime_appender_v2.Appender(AppenderTestRow);

fn appenderTestRoundTrip(context: db2.ContextHandle, buf: []u8, err: [*c]db2.ErrorInfoHandle) ![]const u8 {
    var e: db2.ErrorInfoHandle = undefined;

    var appender = Appender.create(context, &e) catch return error.CreateFailed;
    defer appender.destroy();

    appender.append(.{ .id = 1, .name = "alice", .score = 1.5 }, &e) catch return error.AppendFailed;
    appender.append(.{ .id = 2, .name = "bob", .score = 2.75 }, &e) catch return error.AppendFailed;
    appender.append(.{ .id = 3, .name = "carol", .score = -4.0 }, &e) catch return error.AppendFailed;

    var collection = appender.finish(&e) catch return error.FinishFailed;
    defer _ = db2.columnDataCollectionDestroy(&collection);

    var types: [3]db2.LogicalTypeHandle = undefined;
    inline for (.{ i64, []const u8, f64 }, 0..) |T, i| {
        if (db2.contextCreateTypeFromId(context, comptime_appender_v2.duckdbV2TypeId(T), &types[i], &e) != db2.c.DUCKDB_V2_ERROR_NONE) {
            return error.TypeFailed;
        }
    }
    defer {
        for (&types) |*ty| _ = db2.logicalTypeDestroy(ty);
    }

    var scan_chunk: db2.DataChunkHandle = undefined;
    if (db2.dataChunkCreateWithContext(context, &types, &scan_chunk, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ChunkFailed;
    defer _ = db2.dataChunkDestroy(&scan_chunk);

    var shared_state: db2.ColumnDataCollectionSharedScanStateHandle = undefined;
    if (db2.columnDataCollectionSharedScanStateCreate(collection, &shared_state, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanStateFailed;
    defer _ = db2.columnDataCollectionSharedScanStateDestroy(&shared_state);

    var worker_state: db2.ColumnDataCollectionWorkerScanStateHandle = undefined;
    if (db2.columnDataCollectionWorkerScanStateCreate(collection, &worker_state, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanStateFailed;
    defer _ = db2.columnDataCollectionWorkerScanStateDestroy(&worker_state);

    var pos: usize = 0;
    var wrote_any = false;

    while (true) {
        var did_produce = false;
        if (db2.columnDataCollectionScan(collection, shared_state, worker_state, scan_chunk, &did_produce, &e) != db2.c.DUCKDB_V2_ERROR_NONE) {
            return error.ScanFailed;
        }
        if (!did_produce) break;

        var chunk_size: db2.idx_t = 0;
        if (db2.dataChunkGetSize(scan_chunk, &chunk_size, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

        var id_vec: db2.VectorHandle = undefined;
        var name_vec: db2.VectorHandle = undefined;
        var score_vec: db2.VectorHandle = undefined;
        if (db2.dataChunkGetVector(scan_chunk, 0, &id_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.dataChunkGetVector(scan_chunk, 1, &name_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.dataChunkGetVector(scan_chunk, 2, &score_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorFlatten(id_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorFlatten(name_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorFlatten(score_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

        var id_view: db2.VectorView = undefined;
        var name_view: db2.VectorView = undefined;
        var score_view: db2.VectorView = undefined;
        if (db2.vectorGetView(id_vec, &id_view, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorGetView(name_vec, &name_view, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorGetView(score_vec, &score_view, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

        // SAFETY: `scan_chunk`'s columns were declared BIGINT/VARCHAR/DOUBLE above.
        const ids: [*]const i64 = @ptrCast(@alignCast(id_view.data));
        const names: [*]const db2.BytesValue = @ptrCast(@alignCast(name_view.data));
        const scores: [*]const f64 = @ptrCast(@alignCast(score_view.data));

        var row: db2.idx_t = 0;
        while (row < chunk_size) : (row += 1) {
            if (wrote_any) {
                if (pos >= buf.len) return error.FormatFailed;
                buf[pos] = '|';
                pos += 1;
            }
            const segment = std.fmt.bufPrint(buf[pos..], "{d}:{s}:{d:.2}", .{ ids[row], db2.bytesSlice(&names[row]), scores[row] }) catch return error.FormatFailed;
            pos += segment.len;
            wrote_any = true;
        }
    }

    // Stress the auto-flush path: 2500 rows forces two flushes (2048 + 452)
    // through the SAME scratch chunk, live-confirming assumption 2 (`append`
    // copies rather than taking ownership, so the chunk is safe to reuse).
    var stress = Appender.create(context, &e) catch return error.CreateFailed;
    defer stress.destroy();
    var i: i64 = 0;
    while (i < 2500) : (i += 1) {
        stress.append(.{ .id = i, .name = "x", .score = 0.0 }, &e) catch return error.AppendFailed;
    }
    var stress_collection = stress.finish(&e) catch return error.FinishFailed;
    defer _ = db2.columnDataCollectionDestroy(&stress_collection);
    var stress_count: db2.idx_t = 0;
    if (db2.columnDataCollectionRowCount(stress_collection, &stress_count, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

    const suffix = std.fmt.bufPrint(buf[pos..], "|stress:{d}", .{stress_count}) catch return error.FormatFailed;
    pos += suffix.len;

    _ = err;
    return buf[0..pos];
}

/// Live round-trip test for `comptime_appender_v2.Appender`'s LIST and
/// STRUCT support: builds two rows (`tags LIST(BIGINT)`, `point
/// STRUCT(x DOUBLE, y DOUBLE)`), `finish`es, scans back, and formats what
/// it reads. `zig_v2_appender_nested_test()` takes no arguments; its
/// result should read exactly "[1,2,3]:(1.5,2.5)|[]:(-1.0,0.0)" if the
/// round trip is intact.
fn registerAppenderNestedTest(input: *const db2.ExtensionInput, err: *db2.ErrorInfoHandle) void {
    var function: db2.ScalarFunctionHandle = undefined;
    if (db2.scalarFunctionCreateWithExtension(input.extension, &function, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.scalarFunctionDestroy(&function);

    const fn_name = db2.str("zig_v2_appender_nested_test");
    if (db2.scalarFunctionSetName(function, &fn_name, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var varchar_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.logicalTypeDestroy(&varchar_type);

    var sig: db2.FunctionSignatureHandle = undefined;
    if (db2.scalarFunctionGetSignature(function, &sig, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.functionSignatureSetReturnType(sig, varchar_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    if (db2.scalarFunctionSetExecCallback(function, appenderNestedTestExec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    _ = db2.scalarFunctionRegister(function, err);
}

const NestedTestRow = struct { tags: []const i64, point: struct { x: f64, y: f64 } };
const NestedAppender = comptime_appender_v2.Appender(NestedTestRow);

fn appenderNestedTestExec(info: db2.ScalarFunctionExecInfoHandle, context: db2.ContextHandle, err: [*c]db2.ErrorInfoHandle) callconv(.c) void {
    var row_count: db2.idx_t = 0;
    if (db2.scalarFunctionExecGetRowCount(info, &row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: db2.VectorHandle = undefined;
    if (db2.scalarFunctionExecGetResult(info, &result_vec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.vectorSetSize(result_vec, row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var buf: [256]u8 = undefined;
    const text = nestedTestRoundTrip(context, &buf, err) catch "appender nested round-trip FAILED";

    var row: db2.idx_t = 0;
    while (row < row_count) : (row += 1) {
        var value: db2.ValueHandle = undefined;
        if (db2.valueCreateVarcharWithContext(context, text, &value, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = db2.valueDestroy(&value);
        if (db2.vectorSetValue(result_vec, row, value, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    }
}

fn nestedTestRoundTrip(context: db2.ContextHandle, buf: []u8, err: [*c]db2.ErrorInfoHandle) ![]const u8 {
    var e: db2.ErrorInfoHandle = undefined;

    var appender = NestedAppender.create(context, &e) catch return error.CreateFailed;
    defer appender.destroy();

    appender.append(.{ .tags = &[_]i64{ 1, 2, 3 }, .point = .{ .x = 1.5, .y = 2.5 } }, &e) catch return error.AppendFailed;
    appender.append(.{ .tags = &[_]i64{}, .point = .{ .x = -1.0, .y = 0.0 } }, &e) catch return error.AppendFailed;

    var collection = appender.finish(&e) catch return error.FinishFailed;
    defer _ = db2.columnDataCollectionDestroy(&collection);

    // Rebuild the LIST(BIGINT)/STRUCT(x DOUBLE, y DOUBLE) types by hand for
    // the scan output chunk — `Appender` doesn't expose the ones it built
    // internally (they're destroyed once `create` returns).
    var list_child_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &list_child_type, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.TypeFailed;
    defer _ = db2.logicalTypeDestroy(&list_child_type);
    var list_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateListType(context, list_child_type, &list_type, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.TypeFailed;
    defer _ = db2.logicalTypeDestroy(&list_type);

    var x_type: db2.LogicalTypeHandle = undefined;
    var y_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_DOUBLE, &x_type, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.TypeFailed;
    if (db2.contextCreateTypeFromId(context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_DOUBLE, &y_type, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.TypeFailed;
    var struct_names = [_]db2.IdentifierT{ db2.str("x"), db2.str("y") };
    var struct_field_types = [_]db2.LogicalTypeHandle{ x_type, y_type };
    var struct_field_type_values: [2]db2.ValueHandle = undefined;
    var struct_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateStructType(context, &struct_names, &struct_field_types, &struct_field_type_values, &struct_type, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.TypeFailed;
    defer _ = db2.logicalTypeDestroy(&struct_type);
    defer {
        for (&struct_field_types) |*ty| _ = db2.logicalTypeDestroy(ty);
    }

    var types = [_]db2.LogicalTypeHandle{ list_type, struct_type };
    var scan_chunk: db2.DataChunkHandle = undefined;
    if (db2.dataChunkCreateWithContext(context, &types, &scan_chunk, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ChunkFailed;
    defer _ = db2.dataChunkDestroy(&scan_chunk);

    var shared_state: db2.ColumnDataCollectionSharedScanStateHandle = undefined;
    if (db2.columnDataCollectionSharedScanStateCreate(collection, &shared_state, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanStateFailed;
    defer _ = db2.columnDataCollectionSharedScanStateDestroy(&shared_state);
    var worker_state: db2.ColumnDataCollectionWorkerScanStateHandle = undefined;
    if (db2.columnDataCollectionWorkerScanStateCreate(collection, &worker_state, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanStateFailed;
    defer _ = db2.columnDataCollectionWorkerScanStateDestroy(&worker_state);

    var pos: usize = 0;
    var wrote_any = false;

    while (true) {
        var did_produce = false;
        if (db2.columnDataCollectionScan(collection, shared_state, worker_state, scan_chunk, &did_produce, &e) != db2.c.DUCKDB_V2_ERROR_NONE) {
            return error.ScanFailed;
        }
        if (!did_produce) break;

        var chunk_size: db2.idx_t = 0;
        if (db2.dataChunkGetSize(scan_chunk, &chunk_size, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

        var tags_vec: db2.VectorHandle = undefined;
        var point_vec: db2.VectorHandle = undefined;
        if (db2.dataChunkGetVector(scan_chunk, 0, &tags_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.dataChunkGetVector(scan_chunk, 1, &point_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorFlatten(tags_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorFlatten(point_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

        var tags_view: db2.VectorView = undefined;
        if (db2.vectorGetView(tags_vec, &tags_view, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        // SAFETY: `tags_vec` is LIST(BIGINT); a LIST vector's own data is `[*]ListEntry`.
        const list_entries: [*]const db2.ListEntry = @ptrCast(@alignCast(tags_view.data));

        var tags_child: db2.VectorHandle = undefined;
        if (db2.vectorGetChild(tags_vec, 0, &tags_child, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorFlatten(tags_child, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        var tags_child_view: db2.VectorView = undefined;
        if (db2.vectorGetView(tags_child, &tags_child_view, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        // SAFETY: the LIST's child vector is BIGINT.
        const tag_elems: [*]const i64 = @ptrCast(@alignCast(tags_child_view.data));

        var x_vec: db2.VectorHandle = undefined;
        var y_vec: db2.VectorHandle = undefined;
        if (db2.vectorGetChild(point_vec, 0, &x_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorGetChild(point_vec, 1, &y_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorFlatten(x_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorFlatten(y_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        var x_view: db2.VectorView = undefined;
        var y_view: db2.VectorView = undefined;
        if (db2.vectorGetView(x_vec, &x_view, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.vectorGetView(y_vec, &y_view, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        // SAFETY: STRUCT fields x/y are both DOUBLE.
        const xs: [*]const f64 = @ptrCast(@alignCast(x_view.data));
        const ys: [*]const f64 = @ptrCast(@alignCast(y_view.data));

        var row: db2.idx_t = 0;
        while (row < chunk_size) : (row += 1) {
            if (wrote_any) {
                if (pos >= buf.len) return error.FormatFailed;
                buf[pos] = '|';
                pos += 1;
            }
            if (pos >= buf.len) return error.FormatFailed;
            buf[pos] = '[';
            pos += 1;
            const le = list_entries[row];
            var k: db2.idx_t = 0;
            while (k < le.length) : (k += 1) {
                if (k > 0) {
                    if (pos >= buf.len) return error.FormatFailed;
                    buf[pos] = ',';
                    pos += 1;
                }
                const seg = std.fmt.bufPrint(buf[pos..], "{d}", .{tag_elems[le.offset + k]}) catch return error.FormatFailed;
                pos += seg.len;
            }
            const tail = std.fmt.bufPrint(buf[pos..], "]:({d:.1},{d:.1})", .{ xs[row], ys[row] }) catch return error.FormatFailed;
            pos += tail.len;
            wrote_any = true;
        }
    }

    _ = err;
    return buf[0..pos];
}

/// Live round-trip test for `comptime_appender_v2.Appender`'s ARRAY and
/// ENUM support: builds two rows (`coords DOUBLE[3]`, `status` an ENUM
/// built from a Zig `enum`), `finish`es, scans back, and formats what it
/// reads. Reads nested-type columns via the generic `vectorGetValue` +
/// `valueGetChild`/`valueCastWithContext` fallback rather than ARRAY's raw
/// vector layout, which `duckdb_v2.zig`'s own `vectorGetChild` doc comment
/// leaves ambiguous for ARRAY specifically (groups it with LIST's
/// `ListEntry` addressing, which doesn't obviously fit a fixed-size type).
/// `zig_v2_appender_array_enum_test()` takes no arguments; its result
/// should read exactly "[1.5,2.5,3.5]:active|[4.0,5.0,6.0]:done" if the
/// round trip is intact.
fn registerAppenderArrayEnumTest(input: *const db2.ExtensionInput, err: *db2.ErrorInfoHandle) void {
    var function: db2.ScalarFunctionHandle = undefined;
    if (db2.scalarFunctionCreateWithExtension(input.extension, &function, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.scalarFunctionDestroy(&function);

    const fn_name = db2.str("zig_v2_appender_array_enum_test");
    if (db2.scalarFunctionSetName(function, &fn_name, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var varchar_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.logicalTypeDestroy(&varchar_type);

    var sig: db2.FunctionSignatureHandle = undefined;
    if (db2.scalarFunctionGetSignature(function, &sig, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.functionSignatureSetReturnType(sig, varchar_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    if (db2.scalarFunctionSetExecCallback(function, appenderArrayEnumTestExec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    _ = db2.scalarFunctionRegister(function, err);
}

const Status = enum { pending, active, done };
const ArrayEnumRow = struct { coords: [3]f64, status: Status };
const ArrayEnumAppender = comptime_appender_v2.Appender(ArrayEnumRow);

fn appenderArrayEnumTestExec(info: db2.ScalarFunctionExecInfoHandle, context: db2.ContextHandle, err: [*c]db2.ErrorInfoHandle) callconv(.c) void {
    var row_count: db2.idx_t = 0;
    if (db2.scalarFunctionExecGetRowCount(info, &row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var result_vec: db2.VectorHandle = undefined;
    if (db2.scalarFunctionExecGetResult(info, &result_vec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.vectorSetSize(result_vec, row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var buf: [256]u8 = undefined;
    const text = arrayEnumRoundTrip(context, &buf, err) catch "appender array/enum round-trip FAILED";

    var row: db2.idx_t = 0;
    while (row < row_count) : (row += 1) {
        var value: db2.ValueHandle = undefined;
        if (db2.valueCreateVarcharWithContext(context, text, &value, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = db2.valueDestroy(&value);
        if (db2.vectorSetValue(result_vec, row, value, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    }
}

fn arrayEnumRoundTrip(context: db2.ContextHandle, buf: []u8, err: [*c]db2.ErrorInfoHandle) ![]const u8 {
    var e: db2.ErrorInfoHandle = undefined;

    var appender = ArrayEnumAppender.create(context, &e) catch return error.CreateFailed;
    defer appender.destroy();

    appender.append(.{ .coords = .{ 1.5, 2.5, 3.5 }, .status = .active }, &e) catch return error.AppendFailed;
    appender.append(.{ .coords = .{ 4.0, 5.0, 6.0 }, .status = .done }, &e) catch return error.AppendFailed;

    var collection = appender.finish(&e) catch return error.FinishFailed;
    defer _ = db2.columnDataCollectionDestroy(&collection);

    var coords_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromText(context, "DOUBLE[3]", &coords_type, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.TypeFailed;
    defer _ = db2.logicalTypeDestroy(&coords_type);
    var status_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromText(context, "ENUM('pending','active','done')", &status_type, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.TypeFailed;
    defer _ = db2.logicalTypeDestroy(&status_type);
    var varchar_type: db2.LogicalTypeHandle = undefined;
    if (db2.contextCreateTypeFromId(context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, &varchar_type, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.TypeFailed;
    defer _ = db2.logicalTypeDestroy(&varchar_type);

    var types = [_]db2.LogicalTypeHandle{ coords_type, status_type };
    var scan_chunk: db2.DataChunkHandle = undefined;
    if (db2.dataChunkCreateWithContext(context, &types, &scan_chunk, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ChunkFailed;
    defer _ = db2.dataChunkDestroy(&scan_chunk);

    var shared_state: db2.ColumnDataCollectionSharedScanStateHandle = undefined;
    if (db2.columnDataCollectionSharedScanStateCreate(collection, &shared_state, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanStateFailed;
    defer _ = db2.columnDataCollectionSharedScanStateDestroy(&shared_state);
    var worker_state: db2.ColumnDataCollectionWorkerScanStateHandle = undefined;
    if (db2.columnDataCollectionWorkerScanStateCreate(collection, &worker_state, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanStateFailed;
    defer _ = db2.columnDataCollectionWorkerScanStateDestroy(&worker_state);

    var pos: usize = 0;
    var wrote_any = false;

    while (true) {
        var did_produce = false;
        if (db2.columnDataCollectionScan(collection, shared_state, worker_state, scan_chunk, &did_produce, &e) != db2.c.DUCKDB_V2_ERROR_NONE) {
            return error.ScanFailed;
        }
        if (!did_produce) break;

        var chunk_size: db2.idx_t = 0;
        if (db2.dataChunkGetSize(scan_chunk, &chunk_size, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

        var coords_vec: db2.VectorHandle = undefined;
        var status_vec: db2.VectorHandle = undefined;
        if (db2.dataChunkGetVector(scan_chunk, 0, &coords_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
        if (db2.dataChunkGetVector(scan_chunk, 1, &status_vec, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

        var row: db2.idx_t = 0;
        while (row < chunk_size) : (row += 1) {
            if (wrote_any) {
                if (pos >= buf.len) return error.FormatFailed;
                buf[pos] = '|';
                pos += 1;
            }

            var coords_value: db2.ValueHandle = undefined;
            if (db2.vectorGetValue(coords_vec, row, &coords_value, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
            defer _ = db2.valueDestroy(&coords_value);
            var n: db2.idx_t = 0;
            if (db2.valueGetChildCount(coords_value, &n, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;

            if (pos >= buf.len) return error.FormatFailed;
            buf[pos] = '[';
            pos += 1;
            var k: db2.idx_t = 0;
            while (k < n) : (k += 1) {
                if (k > 0) {
                    if (pos >= buf.len) return error.FormatFailed;
                    buf[pos] = ',';
                    pos += 1;
                }
                var elem_value: db2.ValueHandle = undefined;
                if (db2.valueGetChild(coords_value, k, &elem_value, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
                defer _ = db2.valueDestroy(&elem_value);
                var elem: f64 = 0;
                if (db2.valueGetDouble(elem_value, &elem, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
                const seg = std.fmt.bufPrint(buf[pos..], "{d:.1}", .{elem}) catch return error.FormatFailed;
                pos += seg.len;
            }
            if (pos >= buf.len) return error.FormatFailed;
            buf[pos] = ']';
            pos += 1;

            var status_value: db2.ValueHandle = undefined;
            if (db2.vectorGetValue(status_vec, row, &status_value, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
            defer _ = db2.valueDestroy(&status_value);
            var status_text_value: db2.ValueHandle = undefined;
            if (db2.valueCastWithContext(context, status_value, varchar_type, &status_text_value, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
            defer _ = db2.valueDestroy(&status_text_value);
            var status_text: db2.Str = undefined;
            if (db2.valueGetVarchar(status_text_value, &status_text, &e) != db2.c.DUCKDB_V2_ERROR_NONE) return error.ScanFailed;
            const status_slice: []const u8 = @as([*]const u8, @ptrCast(status_text.ptr))[0..status_text.len];

            const tail = std.fmt.bufPrint(buf[pos..], ":{s}", .{status_slice}) catch return error.FormatFailed;
            pos += tail.len;
            wrote_any = true;
        }
    }

    _ = err;
    return buf[0..pos];
}

/// Live test for `comptime_table_v2.zig`'s optional `pushdown` hook:
/// `zig_v2_range_pushdown_ct(n)` produces `value` 0..n, same as
/// `zig_v2_range_ct`, except its `pushdown` recognizes `value = <constant>`
/// and filters rows itself. `pushdown_hit_count` increments once per
/// accepted predicate — a side channel to observe, from SQL, that the
/// pushdown callback actually fired and accepted (not just that the final
/// row count happens to be right, which the engine's own un-accepted-filter
/// fallback would also produce). `zig_v2_pushdown_hit_count()` reads it;
/// `zig_v2_pushdown_hit_count_reset()` zeroes it so repeated test queries
/// in the same session don't accumulate.
var pushdown_hit_count: i64 = 0;

const RangeFilterState = struct {
    n: i64,
    i: i64,
    predicate: ?i64 = null,

    pub const Row = struct { value: i64 };

    pub fn init(n: i64) @This() {
        return .{ .n = n, .i = 0 };
    }

    /// Filters rows itself when `predicate` is set — the actual promise
    /// `pushdown`'s `accept` makes good on. Wrong filtering here (not just
    /// wrong pushdown recognition) would show up as wrong query results.
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

    /// Recognizes `value = <constant>` (COMPARE_EQUAL over a
    /// BOUND_COLUMN_REF and a VALUE_CONSTANT, column 0) and accepts it;
    /// anything else it leaves for the engine, per the framework's
    /// documented contract.
    pub fn pushdown(self: *@This(), info: db2.TableFunctionFilterPushdownInfoHandle, err: [*c]db2.ErrorInfoHandle) void {
        var count: db2.idx_t = 0;
        if (db2.tableFunctionFilterPushdownGetFilterCount(info, &count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

        var i: db2.idx_t = 0;
        while (i < count) : (i += 1) {
            var expr: db2.ExpressionHandle = undefined;
            if (db2.tableFunctionFilterPushdownGetFilter(info, i, &expr, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;

            var expr_type: db2.ExpressionType = undefined;
            if (db2.expressionGetType(expr, &expr_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;
            if (expr_type != db2.c.DUCKDB_V2_EXPRESSION_TYPE_COMPARE_EQUAL) continue;

            var lhs: db2.ExpressionHandle = undefined;
            var rhs: db2.ExpressionHandle = undefined;
            if (db2.expressionGetChild(expr, 0, &lhs, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;
            if (db2.expressionGetChild(expr, 1, &rhs, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;

            var lhs_type: db2.ExpressionType = undefined;
            var rhs_type: db2.ExpressionType = undefined;
            if (db2.expressionGetType(lhs, &lhs_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;
            if (db2.expressionGetType(rhs, &rhs_type, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;
            if (lhs_type != db2.c.DUCKDB_V2_EXPRESSION_TYPE_BOUND_COLUMN_REF) continue;
            if (rhs_type != db2.c.DUCKDB_V2_EXPRESSION_TYPE_VALUE_CONSTANT) continue;

            var col_ref_idx: db2.idx_t = 0;
            if (db2.expressionColumnRefGetIndex(lhs, &col_ref_idx, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;
            var declared_col: db2.idx_t = 0;
            if (db2.tableFunctionFilterPushdownGetColumnIndex(info, col_ref_idx, &declared_col, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;
            if (declared_col != 0) continue; // only "value" (column 0) is recognized

            var constant: db2.ValueHandle = undefined;
            if (db2.expressionConstantGetValue(rhs, &constant, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;
            defer _ = db2.valueDestroy(&constant);
            var value: i64 = 0;
            if (db2.valueGetBigint(constant, &value, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;

            self.predicate = value;
            if (db2.tableFunctionFilterPushdownAccept(info, i, err) != db2.c.DUCKDB_V2_ERROR_NONE) continue;
            pushdown_hit_count += 1;
        }
    }
};

const RangeFilterTable = comptime_table_v2.Function("zig_v2_range_pushdown_ct", RangeFilterState);

fn registerFilterPushdownTest(input: *const db2.ExtensionInput) void {
    RangeFilterTable.register(input) catch {};

    var err: db2.ErrorInfoHandle = undefined;

    var get_fn: db2.ScalarFunctionHandle = undefined;
    if (db2.scalarFunctionCreateWithExtension(input.extension, &get_fn, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
        defer _ = db2.scalarFunctionDestroy(&get_fn);
        const get_name = db2.str("zig_v2_pushdown_hit_count");
        _ = db2.scalarFunctionSetName(get_fn, &get_name, &err);
        var bigint_type: db2.LogicalTypeHandle = undefined;
        if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
            defer _ = db2.logicalTypeDestroy(&bigint_type);
            var sig: db2.FunctionSignatureHandle = undefined;
            if (db2.scalarFunctionGetSignature(get_fn, &sig, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
                _ = db2.functionSignatureSetReturnType(sig, bigint_type, &err);
                _ = db2.scalarFunctionSetExecCallback(get_fn, pushdownHitCountExec, &err);
                _ = db2.scalarFunctionRegister(get_fn, &err);
            }
        }
    }

    var reset_fn: db2.ScalarFunctionHandle = undefined;
    if (db2.scalarFunctionCreateWithExtension(input.extension, &reset_fn, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
        defer _ = db2.scalarFunctionDestroy(&reset_fn);
        const reset_name = db2.str("zig_v2_pushdown_hit_count_reset");
        _ = db2.scalarFunctionSetName(reset_fn, &reset_name, &err);
        var bigint_type: db2.LogicalTypeHandle = undefined;
        if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
            defer _ = db2.logicalTypeDestroy(&bigint_type);
            var sig: db2.FunctionSignatureHandle = undefined;
            if (db2.scalarFunctionGetSignature(reset_fn, &sig, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
                _ = db2.functionSignatureSetReturnType(sig, bigint_type, &err);
                _ = db2.scalarFunctionSetExecCallback(reset_fn, pushdownHitCountResetExec, &err);
                _ = db2.scalarFunctionRegister(reset_fn, &err);
            }
        }
    }
}

fn pushdownHitCountExec(info: db2.ScalarFunctionExecInfoHandle, context: db2.ContextHandle, err: [*c]db2.ErrorInfoHandle) callconv(.c) void {
    _ = context;
    var row_count: db2.idx_t = 0;
    if (db2.scalarFunctionExecGetRowCount(info, &row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    var result_vec: db2.VectorHandle = undefined;
    if (db2.scalarFunctionExecGetResult(info, &result_vec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.vectorSetSize(result_vec, row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    var out_data: ?*anyopaque = null;
    if (db2.vectorGetDataMutable(result_vec, &out_data, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    const ptr: [*]i64 = @ptrCast(@alignCast(out_data));
    var row: db2.idx_t = 0;
    while (row < row_count) : (row += 1) ptr[row] = pushdown_hit_count;
}

fn pushdownHitCountResetExec(info: db2.ScalarFunctionExecInfoHandle, context: db2.ContextHandle, err: [*c]db2.ErrorInfoHandle) callconv(.c) void {
    _ = context;
    pushdown_hit_count = 0;
    var row_count: db2.idx_t = 0;
    if (db2.scalarFunctionExecGetRowCount(info, &row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    var result_vec: db2.VectorHandle = undefined;
    if (db2.scalarFunctionExecGetResult(info, &result_vec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.vectorSetSize(result_vec, row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    var out_data: ?*anyopaque = null;
    if (db2.vectorGetDataMutable(result_vec, &out_data, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    const ptr: [*]i64 = @ptrCast(@alignCast(out_data));
    var row: db2.idx_t = 0;
    while (row < row_count) : (row += 1) ptr[row] = 0;
}

/// Live test for `comptime_table_v2.zig`'s optional
/// `supports_projection_pushdown`/`onProjection` hooks:
/// `zig_v2_project_ct(n)` produces two columns, `a` (0..n) and
/// `b` (0..2n step 2), same values regardless of which columns a query
/// selects — correctness of the column-index remapping is the real risk
/// here, not just whether the callback fires. `onProjection` records a
/// bitmask of which `Row` fields the last `exec` call was actually asked
/// for (bit 0 = `a`, bit 1 = `b`) into `projection_last_mask`, a side
/// channel to observe from SQL that pushdown is really reporting the
/// query's own column selection, not just "everything" regardless of what
/// was asked for. `zig_v2_project_last_mask()` reads it.
var projection_last_mask: i64 = 0;

const ProjectionTestState = struct {
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

    /// `selected_fields` holds `Row` field indices in declaration order
    /// (0 = `a`, 1 = `b`) — build the observable bitmask from exactly that,
    /// not from any assumption about what the query "should" have asked for.
    pub fn onProjection(self: *@This(), selected_fields: []const usize) void {
        _ = self;
        var mask: i64 = 0;
        for (selected_fields) |field_idx| mask |= @as(i64, 1) << @intCast(field_idx);
        projection_last_mask = mask;
    }
};

const ProjectionTestTable = comptime_table_v2.Function("zig_v2_project_ct", ProjectionTestState);

fn registerProjectionPushdownTest(input: *const db2.ExtensionInput) void {
    ProjectionTestTable.register(input) catch {};

    var err: db2.ErrorInfoHandle = undefined;

    var mask_fn: db2.ScalarFunctionHandle = undefined;
    if (db2.scalarFunctionCreateWithExtension(input.extension, &mask_fn, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
        defer _ = db2.scalarFunctionDestroy(&mask_fn);
        const mask_name = db2.str("zig_v2_project_last_mask");
        _ = db2.scalarFunctionSetName(mask_fn, &mask_name, &err);
        var bigint_type: db2.LogicalTypeHandle = undefined;
        if (db2.contextCreateTypeFromId(input.context, db2.c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
            defer _ = db2.logicalTypeDestroy(&bigint_type);
            var sig: db2.FunctionSignatureHandle = undefined;
            if (db2.scalarFunctionGetSignature(mask_fn, &sig, &err) == db2.c.DUCKDB_V2_ERROR_NONE) {
                _ = db2.functionSignatureSetReturnType(sig, bigint_type, &err);
                _ = db2.scalarFunctionSetExecCallback(mask_fn, projectionLastMaskExec, &err);
                _ = db2.scalarFunctionRegister(mask_fn, &err);
            }
        }
    }
}

fn projectionLastMaskExec(info: db2.ScalarFunctionExecInfoHandle, context: db2.ContextHandle, err: [*c]db2.ErrorInfoHandle) callconv(.c) void {
    _ = context;
    var row_count: db2.idx_t = 0;
    if (db2.scalarFunctionExecGetRowCount(info, &row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    var result_vec: db2.VectorHandle = undefined;
    if (db2.scalarFunctionExecGetResult(info, &result_vec, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    if (db2.vectorSetSize(result_vec, row_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    var out_data: ?*anyopaque = null;
    if (db2.vectorGetDataMutable(result_vec, &out_data, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    const ptr: [*]i64 = @ptrCast(@alignCast(out_data));
    var row: db2.idx_t = 0;
    while (row < row_count) : (row += 1) ptr[row] = projection_last_mask;
}

/// Live test for `duckdb_v2.zig`'s replacement-scan wrappers: recognizes
/// an unresolved table reference of the form `zig_v2_range_<N>` (e.g.
/// `FROM zig_v2_range_7`) and claims it by redirecting to
/// `zig_v2_range_ct(N)` — proves both the name-recognition path and
/// argument-threading (`replacementScanAddArgument`), not just that the
/// callback fires. Anything else is declined (no claim, no mutation) and
/// falls through to DuckDB's normal "no such table" error, same as if
/// this scan weren't registered at all.
fn registerReplacementScanTest(input: *const db2.ExtensionInput) void {
    var err: db2.ErrorInfoHandle = undefined;

    var scan: db2.ReplacementScanHandle = undefined;
    if (db2.replacementScanCreateWithExtension(input.extension, &scan, &err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.replacementScanDestroy(&scan);

    if (db2.replacementScanSetCallback(scan, replacementScanCallback, &err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    _ = db2.replacementScanRegister(scan, &err);
}

const range_prefix = "zig_v2_range_";

fn replacementScanCallback(info: db2.ReplacementScanInfoHandle, context: db2.ContextHandle, err: [*c]db2.ErrorInfoHandle) callconv(.c) void {
    var qname: db2.QnameHandle = undefined;
    if (db2.replacementScanGetName(info, &qname, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.qnameDestroy(&qname);

    var part_count: db2.idx_t = 0;
    if (db2.qnameGetPartCount(qname, &part_count, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var object_name: db2.IdentifierT = undefined;
    if (db2.qnameGetPart(qname, part_count - 1, &object_name, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    // SAFETY: `object_name` borrows from `qname`, valid until it's destroyed above.
    const name_slice: []const u8 = @as([*]const u8, @ptrCast(object_name.ptr))[0..object_name.len];

    if (!std.mem.startsWith(u8, name_slice, range_prefix)) return; // decline — not our pattern
    const n = std.fmt.parseInt(i64, name_slice[range_prefix.len..], 10) catch return; // decline — not `..._<N>`

    var target: db2.QnameHandle = undefined;
    const target_name = db2.str("zig_v2_range_ct");
    if (db2.qnameCreate((&target_name)[0..1], &target, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.qnameDestroy(&target);
    if (db2.replacementScanSetFunctionName(info, target, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;

    var n_value: db2.ValueHandle = undefined;
    if (db2.valueCreateBigintWithContext(context, n, &n_value, err) != db2.c.DUCKDB_V2_ERROR_NONE) return;
    defer _ = db2.valueDestroy(&n_value);
    _ = db2.replacementScanAddArgument(info, n_value, err);
}

/// Thread-local scratch buffer for a LIST(DOUBLE) matmul return. Must be
/// thread-safe storage (DuckDB may call a scalar function from multiple
/// worker threads concurrently) that outlives the call (the framework
/// boxes the returned slice into a `Value` immediately after this
/// function returns — see `comptime_scalar_v2.zig`'s own CAUTION on
/// LIST/VARCHAR returns), so neither a shared `var` nor a function-local
/// stack array would be safe here.
///
/// CAUTION, confirmed live (a real bug, since fixed): sizing this to
/// match `comptime_scalar_v2.zig`'s own `list_return_max_elems` cap
/// isn't enough on its own — that cap is only checked by the framework
/// *after* `eval` returns, by inspecting `result.len`. A naive
/// `matmul_scratch[0 .. mu * nu]` slice panics first, for any `m*n`
/// bigger than this buffer (confirmed live: a 101×101 result panicked
/// with "index out of bounds," crashing the CLI, before the framework's
/// own cap check ever ran). `eval` must bound its own slice to this
/// buffer's capacity itself, never trusting the framework's cap to run
/// first.
threadlocal var matmul_scratch: [4096]f64 = undefined;

/// Clamp `mu * nu` to `matmul_scratch`'s capacity, returning `null` if
/// the true result wouldn't fit — never slicing past the buffer's own
/// length. Shared by `MatmulNaiveCt`/`MatmulCt`.
fn matmulOutputSlice(mu: usize, nu: usize) ?[]f64 {
    const want = mu * nu;
    if (want > matmul_scratch.len) return null;
    return matmul_scratch[0..want];
}

/// Naive O(m·n·k) triple-loop baseline — what `MatmulCt` (the SIMD
/// kernel) is checked and benchmarked against. Row-major flat
/// LIST(DOUBLE) arguments: A is m×k, B is k×n, result is m×n. Returns
/// an empty list — not a crash, not a truncated/wrong-looking partial
/// matrix — if `m*n` exceeds the scratch buffer's capacity.
const MatmulNaiveCt = comptime_scalar_v2.FunctionNamed("zig_v2_matmul_naive_ct", struct {
    fn eval(a: []const f64, b: []const f64, m: i64, k: i64, n: i64) []const f64 {
        const mu: usize = @intCast(@max(m, 0));
        const ku: usize = @intCast(@max(k, 0));
        const nu: usize = @intCast(@max(n, 0));
        const out = matmulOutputSlice(mu, nu) orelse return &.{};
        matmul.matmulNaive(a, b, out, mu, ku, nu);
        return out;
    }
}.eval, &.{ "a", "b", "m", "k", "n" });

/// Register-blocked SIMD kernel — see `src/lib/matmul.zig`'s own doc
/// comment for the full llamafile-tinyBLAS-vs-Zig comparison this POC
/// is built around. Same shape and oversized-input handling as
/// `MatmulNaiveCt`.
const MatmulCt = comptime_scalar_v2.FunctionNamed("zig_v2_matmul_ct", struct {
    fn eval(a: []const f64, b: []const f64, m: i64, k: i64, n: i64) []const f64 {
        const mu: usize = @intCast(@max(m, 0));
        const ku: usize = @intCast(@max(k, 0));
        const nu: usize = @intCast(@max(n, 0));
        const out = matmulOutputSlice(mu, nu) orelse return &.{};
        matmul.matmulSimd(matmul.default_rm, a, b, out, mu, ku, nu);
        return out;
    }
}.eval, &.{ "a", "b", "m", "k", "n" });

/// Benchmarks `matmulNaive` against `matmulSimd` on an m×k × k×n
/// multiplication, run `iterations` times each, timed via
/// `std.Io.Clock` (`std.time.Timer` no longer exists in Zig 0.17 — timing
/// moved under the unified `Io` interface, same `std.Io.Threaded`
/// construction the braille v2-poc demo already uses to get an `Io`
/// instance outside of `std.process.Init`). Test data is a fixed
/// deterministic pattern, not random — this is a throughput comparison,
/// not a correctness fuzz test (that's `matmul.zig`'s own unit tests).
const MatmulBenchState = struct {
    kernel_names: [2][]const u8,
    elapsed_ms: [2]f64,
    gflops: [2]f64,
    idx: usize,

    pub const Row = struct { kernel: []const u8, elapsed_ms: f64, gflops: f64 };

    pub fn init(m: i64, k: i64, n: i64, iterations: i64) @This() {
        const failed: @This() = .{ .kernel_names = undefined, .elapsed_ms = undefined, .gflops = undefined, .idx = 2 };

        const mu: usize = @intCast(@max(m, 1));
        const ku: usize = @intCast(@max(k, 1));
        const nu: usize = @intCast(@max(n, 1));
        const iters: usize = @intCast(@max(iterations, 1));

        const a = std.heap.c_allocator.alloc(f64, mu * ku) catch return failed;
        defer std.heap.c_allocator.free(a);
        const b = std.heap.c_allocator.alloc(f64, ku * nu) catch return failed;
        defer std.heap.c_allocator.free(b);
        const c = std.heap.c_allocator.alloc(f64, mu * nu) catch return failed;
        defer std.heap.c_allocator.free(c);
        for (a, 0..) |*v, i| v.* = @floatFromInt(i % 13);
        for (b, 0..) |*v, i| v.* = @floatFromInt((i % 7) + 1);

        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const flops: f64 = 2.0 * @as(f64, @floatFromInt(mu)) * @as(f64, @floatFromInt(nu)) * @as(f64, @floatFromInt(ku)) * @as(f64, @floatFromInt(iters));

        const naive_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulNaive(a, b, c, mu, ku, nu);
        const naive_ns: f64 = @floatFromInt(naive_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        const simd_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulSimd(matmul.default_rm, a, b, c, mu, ku, nu);
        const simd_ns: f64 = @floatFromInt(simd_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        return .{
            .kernel_names = .{ "naive", "simd" },
            .elapsed_ms = .{ naive_ns / 1e6, simd_ns / 1e6 },
            .gflops = .{ flops / naive_ns, flops / simd_ns },
            .idx = 0,
        };
    }

    pub fn next(self: *@This()) ?Row {
        if (self.idx >= 2) return null;
        defer self.idx += 1;
        return .{ .kernel = self.kernel_names[self.idx], .elapsed_ms = self.elapsed_ms[self.idx], .gflops = self.gflops[self.idx] };
    }
};
const MatmulBenchCt = comptime_table_v2.FunctionNamed("zig_v2_matmul_bench_ct", MatmulBenchState, &.{ "m", "k", "n", "iterations" });

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
