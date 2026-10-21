///! Minimal real v2 extension entrypoint, built only to prove
///! the generated v2 bindings (`duckdb_v2_dynamic`) against a live DuckDB v2.0 alpha
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
const v2_values = @import("v2_values");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const examples = @import("duckdb_v2_examples");
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const comptime_table_v2 = @import("comptime_table_v2");
const comptime_aggregate_v2 = @import("comptime_aggregate_v2");
const comptime_appender_v2 = @import("comptime_appender_v2");
const comptime_cast_v2 = @import("comptime_cast_v2");
const matmul = @import("matmul");
const nethogs_trace = @import("nethogs_trace");

export fn zig_ext_v2_poc_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;

    // DuckDB's own slot: see comptime_scalar_v2.register for why an uninitialised one is not an option.
    var err = (input.err orelse return).*;

    registerDouble(input, &err);
    registerRange3(input, &err);
    registerAggSum(input, &err);
    registerWeightedAvgPart(input, &err);
    registerHello(input, &err);
    registerAppenderTest(input, &err);
    registerAppenderNestedTest(input, &err);
    registerAppenderArrayEnumTest(input, &err);
    registerAppenderTypesTest(input, &err);
    registerNethogsTrace(input, &err);
    registerFilterPushdownTest(input);
    registerProjectionPushdownTest(input);
    registerComptimeExamples(input);
    registerReplacementScanTest(input);
}

fn registerHello(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_hello");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return;

    const param_name = helpers.str("name");
    if (v2.duckdb_v2_function_signature_add_parameter(
        sig,
        &param_name,
        varchar_type,
        null,
        .FUNCTION_PARAMETER_KIND_STANDARD,
        err,
    ) != .ERROR_NONE) return;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, exampleHelloExec, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err);
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
const CastPrice = v2_values.Decimal(10, 2);
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

/// Proves comptime_cast_v2's ENUM support: ENUM to a flat BIGINT target
/// (`MoodToIntCast`), ENUM to VARCHAR, a `vectorSetValue`-boxed target
/// (`MoodToVarcharCast`), and VARCHAR to ENUM (`VarcharToMoodCast`), over
/// constants and columns, NULL rows included. `MoodToVarcharCast` used to
/// fail with "row out of range" and was documented as broken on this alpha;
/// the framework simply never set its output vector's size, and does now.
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
/// that proves castFn received a real, usable `v2.duckdb_v2_value_handle`).
const VariantToIntCast = comptime_cast_v2.Function(v2.duckdb_v2_value_handle, i64, struct {
    fn cast(v: v2.duckdb_v2_value_handle) ?i64 {
        var err: v2.duckdb_v2_error_info_handle = undefined;
        var is_null: bool = false;
        _ = v2.duckdb_v2_value_is_null(v, &is_null, &err);
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
    fn eval(context: v2.duckdb_v2_context_handle, v: v2.duckdb_v2_value_handle, fallback: i64) v2.duckdb_v2_value_handle {
        var err: v2.duckdb_v2_error_info_handle = undefined;
        var is_null = false;
        _ = v2.duckdb_v2_value_is_null(v, &is_null, &err);
        var out: v2.duckdb_v2_value_handle = undefined;
        var factory: v2.duckdb_v2_factory_handle = undefined;
        _ = v2.duckdb_v2_context_get_factory(context, &factory, &err);
        if (is_null) {
            _ = v2.duckdb_v2_value_create_bigint(factory, fallback, &out, &err);
        } else {
            var n: i64 = 0;
            _ = v2.duckdb_v2_value_get_bigint(v, &n, &err);
            _ = v2.duckdb_v2_value_create_bigint(factory, n, &out, &err);
        }
        return out;
    }
}.eval);

/// CAUTION, found live, not fixed (nothing to fix on this side): calling
/// `duckdb_v2_value_get_type` on a value fetched from a VARIANT cell via
/// `duckdb_v2_vector_get_value` segfaults the host process on this pinned alpha
/// (`v2.0.0-alpha48730`), reproducibly, with no error returned first. Isolated by
/// elimination, not assumed: the identical handle (same fetch, same lifetime, same
/// framework code path `VariantDefault` above already uses successfully) works fine with
/// `duckdb_v2_value_is_null`/`duckdb_v2_value_get_bigint` — only `value_get_type` crashes.
/// A one-line change (returning before the `get_type` call, left as `const probe = true`
/// below rather than deleted, to keep the isolation itself reproducible) runs clean and
/// returns a plain value. Not this project's bug: nothing here does anything but call the
/// C API function as documented. Relevant to a live discussion,
/// https://github.com/duckdb/duckdb/discussions/27525, about whether VARIANT-cell values
/// report their real inner type or stay opaque — on this build, asking crashes outright
/// rather than returning either answer.
const VariantTypeId = comptime_scalar_v2.Function("zig_v2_variant_type_id_ct", struct {
    fn eval(context: v2.duckdb_v2_context_handle, v: v2.duckdb_v2_value_handle) v2.duckdb_v2_value_handle {
        var err: v2.duckdb_v2_error_info_handle = undefined;
        var factory: v2.duckdb_v2_factory_handle = undefined;
        _ = v2.duckdb_v2_context_get_factory(context, &factory, &err);
        var out: v2.duckdb_v2_value_handle = undefined;
        const probe = false; // true: skip the crashing call, confirms everything else here is fine
        if (probe) {
            _ = v2.duckdb_v2_value_create_bigint(factory, 555, &out, &err);
            return out;
        }
        var lt: v2.duckdb_v2_logical_type_handle = undefined;
        if (v2.duckdb_v2_value_get_type(v, &lt, &err) != .ERROR_NONE) {
            _ = v2.duckdb_v2_value_create_bigint(factory, -1, &out, &err);
            return out;
        }
        defer _ = v2.duckdb_v2_logical_type_destroy(&lt);
        var id: v2.DUCKDB_V2_LOGICAL_TYPE_ID = undefined;
        if (v2.duckdb_v2_logical_type_get_id(lt, &id, &err) != .ERROR_NONE) {
            _ = v2.duckdb_v2_value_create_bigint(factory, -2, &out, &err);
            return out;
        }
        _ = v2.duckdb_v2_value_create_bigint(factory, @backingInt(id), &out, &err);
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
/// just a new duckdbV2TypeId case each (see duckdb_v2_dynamic.zig's doc comments
/// on Date/Time/Timestamp/Interval for why).
const TimestampAddCt = comptime_scalar_v2.Function("zig_v2_timestamp_add_ct", struct {
    fn eval(ts: v2_values.Timestamp, iv: v2_values.Interval) v2_values.Timestamp {
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
    fn eval(b: v2_values.Blob, n: i64) v2_values.Blob {
        const len = @min(@as(usize, @intCast(@max(n, 0))), b.bytes.len);
        return .{ .bytes = b.bytes[0..len] };
    }
}.eval);

/// Proves an error-union return on the numeric path: integer division that fails the query on a
/// zero divisor (invalid input) or on `minInt / -1` (out of range).
const CheckedDivCt = comptime_scalar_v2.Function("zig_v2_checked_div_ct", struct {
    fn eval(a: i64, b: i64) !i64 {
        if (b == 0) return error.DivisionByZero;
        return std.math.divTrunc(i64, a, b) catch error.Overflow;
    }
}.eval);

/// Proves an error-union return on the VARCHAR path: the first word, or an error for a text
/// without one.
const FirstWordCt = comptime_scalar_v2.Function("zig_v2_first_word_ct", struct {
    fn eval(s: []const u8) ![]const u8 {
        const word = std.mem.sliceTo(std.mem.trimStart(u8, s, " "), ' ');
        if (word.len == 0) return error.EmptyInput;
        return word;
    }
}.eval);

/// Proves DECIMAL as a parameter and return type: applies a tax rate
/// (as a plain double) to a DECIMAL(10,2) price, returning DECIMAL(10,2).
const Price = v2_values.Decimal(10, 2);
const ApplyTaxCt = comptime_scalar_v2.Function("zig_v2_apply_tax_ct", struct {
    fn eval(price: Price, rate: f64) Price {
        const scaled: f64 = @as(f64, @floatFromInt(price.raw)) * (1.0 + rate);
        return .{ .raw = @intFromFloat(@round(scaled)) };
    }
}.eval);

/// Proves DECIMAL at the i128 storage tier (width 38).
const BigDecimal = v2_values.Decimal(38, 10);
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
/// (zipped into a bounded per-row stack buffer, since a MAP's `entries`
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

inline fn simdIsValid(bits: [*]const u64, i: u64) bool {
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
    pub fn updateBatch(self: *@This(), views: *const [2]v2.duckdb_v2_vector_view, row_count: u64) void {
        // SAFETY: the signature registered this function's args as (DOUBLE, DOUBLE).
        const x: [*]const f64 = @ptrCast(@alignCast(views[0].data));
        const w: [*]const f64 = @ptrCast(@alignCast(views[1].data));
        const x_valid = views[0].validity;
        const w_valid = views[1].validity;

        var wsum_acc: V = @splat(0);
        var w_acc: V = @splat(0);
        var i: u64 = 0;
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

/// Prototype for the "portable alternative" to `vpconflictd` discussed in
/// `docs/v2-migration-plan.md`'s "Gram-matrix aggregate" section: for a
/// `GROUP BY` chunk (state pointers differing row-to-row), bucket the
/// chunk's rows by state-pointer equality first (a local partition, not a
/// full sort key beyond that), then run the SAME dense `@Vector` fold
/// `WeightedAvgSimdCt.updateBatch` uses on each resulting contiguous,
/// NULL-free run — recovering explicit SIMD for the grouped case without
/// any ISA-specific scatter/conflict-detection instruction. Hand-written
/// (not through `comptime_aggregate_v2.Function`) because the framework's
/// `updateBatch` fast path is deliberately scoped to the single-state
/// ungrouped case only (see that file's module doc comment) — this needs
/// its own `update` callback to do the partition step itself. Reuses
/// `WeightedAvgSimdCt`'s own `lanes`/`V`/`simdIsValid`.
const WeightedAvgPartState = struct { weighted_sum: f64, weight_sum: f64 };

/// Fixed scratch capacity for one chunk's worth of row indices / gathered
/// values — generous relative to DuckDB's own vector size, with a scalar
/// fallback below for the (should-never-happen) case a chunk exceeds it.
const max_chunk_rows: usize = 4096;
threadlocal var part_row_idx_scratch: [max_chunk_rows]u32 = undefined;
threadlocal var part_gather_x_scratch: [max_chunk_rows]f64 = undefined;
threadlocal var part_gather_w_scratch: [max_chunk_rows]f64 = undefined;

inline fn rowValid2(va: ?[*]const u64, vb: ?[*]const u64, row: u64) bool {
    if (va) |b| if (!simdIsValid(b, row)) return false;
    if (vb) |b| if (!simdIsValid(b, row)) return false;
    return true;
}

/// Dense SIMD fold over an already-gathered, NULL-free, single-group run —
/// identical in shape to `WeightedAvgSimdCt.updateBatch`'s masked fold,
/// minus the masking: gathering already did the NULL-skip and the
/// single-group selection, so this is a plain reduction.
fn weightedAvgPartDenseFold(xs: []const f64, ws: []const f64) struct { wsum: f64, wnum: f64 } {
    var wsum_acc: V = @splat(0);
    var w_acc: V = @splat(0);
    var i: usize = 0;
    while (i + lanes <= xs.len) : (i += lanes) {
        const xv: V = xs[i..][0..lanes].*;
        const wv: V = ws[i..][0..lanes].*;
        wsum_acc += xv * wv;
        w_acc += wv;
    }
    var wsum: f64 = @reduce(.Add, wsum_acc);
    var wnum: f64 = @reduce(.Add, w_acc);
    while (i < xs.len) : (i += 1) {
        wsum += xs[i] * ws[i];
        wnum += ws[i];
    }
    return .{ .wsum = wsum, .wnum = wnum };
}

fn weightedAvgPartSize(info: v2.duckdb_v2_aggregate_function_size_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    _ = v2.duckdb_v2_aggregate_function_size_set_state_size(info, @sizeOf(WeightedAvgPartState), err);
}

fn weightedAvgPartInit(info: v2.duckdb_v2_aggregate_function_init_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_init_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var states: [*]?*anyopaque = undefined;
    if (v2.duckdb_v2_aggregate_function_init_get_states(info, &states, err) != .ERROR_NONE) return;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const state: *WeightedAvgPartState = @ptrCast(@alignCast(states[i].?));
        state.* = .{ .weighted_sum = 0, .weight_sum = 0 };
    }
}

fn weightedAvgPartUpdate(info: v2.duckdb_v2_aggregate_function_update_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_update_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    if (row_count == 0) return;

    var x_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_update_get_arg(info, 0, &x_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(x_vec, err) != .ERROR_NONE) return;
    var x_view: v2.duckdb_v2_vector_view = undefined;
    if (v2.duckdb_v2_vector_get_view(x_vec, &x_view, err) != .ERROR_NONE) return;

    var w_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_update_get_arg(info, 1, &w_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_flatten(w_vec, err) != .ERROR_NONE) return;
    var w_view: v2.duckdb_v2_vector_view = undefined;
    if (v2.duckdb_v2_vector_get_view(w_vec, &w_view, err) != .ERROR_NONE) return;

    var states: [*]?*anyopaque = undefined;
    if (v2.duckdb_v2_aggregate_function_update_get_states(info, &states, err) != .ERROR_NONE) return;

    // SAFETY: this function's signature is registered as (DOUBLE, DOUBLE).
    const x: [*]const f64 = @ptrCast(@alignCast(x_view.data));
    const w: [*]const f64 = @ptrCast(@alignCast(w_view.data));

    if (row_count > max_chunk_rows) {
        var row: u64 = 0;
        while (row < row_count) : (row += 1) {
            if (!rowValid2(x_view.validity, w_view.validity, row)) continue;
            const state: *WeightedAvgPartState = @ptrCast(@alignCast(states[row].?));
            state.weighted_sum += x[row] * w[row];
            state.weight_sum += w[row];
        }
        return;
    }

    const n: usize = @intCast(row_count);
    for (0..n) |i| part_row_idx_scratch[i] = @intCast(i);
    const idx = part_row_idx_scratch[0..n];

    // The partition step itself: an in-place sort by state-pointer value,
    // NOT a full ordering on anything meaningful beyond grouping identical
    // pointers together — any stable-or-not sort that achieves that would
    // do equally well.
    const SortCtx = struct { states: [*]?*anyopaque };
    std.sort.pdq(u32, idx, SortCtx{ .states = states }, struct {
        fn lessThan(ctx: SortCtx, a: u32, b: u32) bool {
            return @intFromPtr(ctx.states[a]) < @intFromPtr(ctx.states[b]);
        }
    }.lessThan);

    var run_start: usize = 0;
    while (run_start < n) {
        const run_state_ptr = states[idx[run_start]];
        var run_end = run_start + 1;
        while (run_end < n and states[idx[run_end]] == run_state_ptr) : (run_end += 1) {}

        var gathered: usize = 0;
        for (idx[run_start..run_end]) |row_u32| {
            const row: u64 = @intCast(row_u32);
            if (!rowValid2(x_view.validity, w_view.validity, row)) continue;
            part_gather_x_scratch[gathered] = x[row];
            part_gather_w_scratch[gathered] = w[row];
            gathered += 1;
        }

        if (gathered > 0) {
            const state: *WeightedAvgPartState = @ptrCast(@alignCast(run_state_ptr.?));
            const folded = weightedAvgPartDenseFold(part_gather_x_scratch[0..gathered], part_gather_w_scratch[0..gathered]);
            state.weighted_sum += folded.wsum;
            state.weight_sum += folded.wnum;
        }
        run_start = run_end;
    }
}

fn weightedAvgPartCombine(info: v2.duckdb_v2_aggregate_function_combine_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_combine_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var sources: [*]?*anyopaque = undefined;
    if (v2.duckdb_v2_aggregate_function_combine_get_sources(info, &sources, err) != .ERROR_NONE) return;
    var targets: [*]?*anyopaque = undefined;
    if (v2.duckdb_v2_aggregate_function_combine_get_targets(info, &targets, err) != .ERROR_NONE) return;

    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const source: *WeightedAvgPartState = @ptrCast(@alignCast(sources[i].?));
        const target: *WeightedAvgPartState = @ptrCast(@alignCast(targets[i].?));
        target.weighted_sum += source.weighted_sum;
        target.weight_sum += source.weight_sum;
    }
}

fn weightedAvgPartFinalize(info: v2.duckdb_v2_aggregate_function_finalize_info_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var count: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_finalize_get_state_count(info, &count, err) != .ERROR_NONE) return;
    var states: [*]?*anyopaque = undefined;
    if (v2.duckdb_v2_aggregate_function_finalize_get_states(info, &states, err) != .ERROR_NONE) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_finalize_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    var offset: u64 = 0;
    if (v2.duckdb_v2_aggregate_function_finalize_get_result_offset(info, &offset, err) != .ERROR_NONE) return;

    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
    const out: [*]f64 = @ptrCast(@alignCast(out_data));

    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const state: *WeightedAvgPartState = @ptrCast(@alignCast(states[i].?));
        if (state.weight_sum == 0) {
            if (v2.duckdb_v2_vector_set_null(result_vec, offset + i, err) != .ERROR_NONE) return;
        } else {
            out[offset + i] = state.weighted_sum / state.weight_sum;
        }
    }
}

fn registerWeightedAvgPart(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_aggregate_function_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_aggregate_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_weighted_avg_part_ct");
    if (v2.duckdb_v2_aggregate_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var double_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_DOUBLE, &double_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&double_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_get_signature(function, &sig, err) != .ERROR_NONE) return;

    const x_name = helpers.str("x");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &x_name, double_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return;
    const w_name = helpers.str("weight");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &w_name, double_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, double_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_aggregate_function_set_size_callback(function, weightedAvgPartSize, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_aggregate_function_set_init_callback(function, weightedAvgPartInit, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_aggregate_function_set_update_callback(function, weightedAvgPartUpdate, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_aggregate_function_set_combine_callback(function, weightedAvgPartCombine, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_aggregate_function_set_finalize_callback(function, weightedAvgPartFinalize, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_aggregate_function(input.extension, function, err);
}

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
const TotalLenCt = comptime_aggregate_v2.FunctionDocumented("zig_v2_total_len_ct", struct {
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
}, &.{"s"}, .{
    .description = "The total length in bytes of the strings s, a comptime aggregate with documentation.",
    .examples = &.{.{ .sql = "SELECT zig_v2_total_len_ct(s) FROM (VALUES ('ab'), ('cde')) t(s);" }},
    .categories = &.{"aggregate"},
});

/// Proves VARCHAR as an aggregate `finalize` return type through the
/// generic framework path: last string seen in the group, both under and
/// over the 12-byte inline threshold (exercises both `v2_helpers.makeBytesValue`
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

/// Per-group 3×3 sample-covariance matrix —
/// `SELECT zig_v2_gram3_ct(x1,x2,x3) FROM t GROUP BY g`. Each row
/// contributes an outer product `row ⊗ row` into its own group's K×K
/// accumulator (K=3, fixed at comptime), the matmul-shaped aggregate
/// discussed as the natural GROUP BY-pushdown analogue of `matmul.zig`'s
/// kernel — see `docs/v2-migration-plan.md`'s "Gram-matrix aggregate for
/// grouped matmul/weighted-avg" section for why this does NOT reuse
/// `WeightedAvgSimdCt`'s single-accumulator `updateBatch` SIMD fold: DuckDB
/// hands `update` one state pointer per row, and a `GROUP BY` query's
/// pointers differ row-to-row with no contiguous same-group run to
/// vectorize over without an explicit partition pass (that section also
/// covers why `vpconflictd` and extra Zig-side threading were both ruled
/// out as ways to recover SIMD here). Covariance is formatted as a flat
/// VARCHAR matrix rather than a native LIST(LIST(DOUBLE)) return, since
/// `comptime_aggregate_v2.zig`'s `finalize` only supports the scalar/
/// VARCHAR return types `duckdbV2TypeId` maps — a native matrix return
/// would need that framework extended, out of scope for this demo.
const Gram3Ct = comptime_aggregate_v2.FunctionNamed("zig_v2_gram3_ct", struct {
    n: i64,
    sum: [3]f64,
    gram: [3][3]f64, // only the upper triangle (b >= a) is kept up to date
    buf: [200]u8,

    pub fn init() @This() {
        return .{
            .n = 0,
            .sum = .{ 0, 0, 0 },
            .gram = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } },
            .buf = undefined,
        };
    }
    pub fn update(self: *@This(), x1: f64, x2: f64, x3: f64) void {
        const row = [3]f64{ x1, x2, x3 };
        self.n += 1;
        inline for (0..3) |a| {
            self.sum[a] += row[a];
            inline for (a..3) |b| self.gram[a][b] += row[a] * row[b];
        }
    }
    pub fn combine(self: *@This(), other: @This()) void {
        if (other.n == 0) return;
        self.n += other.n;
        inline for (0..3) |a| {
            self.sum[a] += other.sum[a];
            inline for (a..3) |b| self.gram[a][b] += other.gram[a][b];
        }
    }
    // `self: *@This()`, not by value: `buf` is an inline array, same
    // dangling-slice hazard `Stats1BrcCt.finalize` documents above.
    pub fn finalize(self: *@This()) ?[]const u8 {
        if (self.n < 2) return null; // sample covariance needs n-1 >= 1
        const n: f64 = @floatFromInt(self.n);
        var cov: [3][3]f64 = undefined;
        inline for (0..3) |a| {
            inline for (a..3) |b| {
                const c = (self.gram[a][b] - self.sum[a] * self.sum[b] / n) / (n - 1);
                cov[a][b] = c;
                cov[b][a] = c;
            }
        }
        const text = std.fmt.bufPrint(
            &self.buf,
            "[[{d:.4},{d:.4},{d:.4}],[{d:.4},{d:.4},{d:.4}],[{d:.4},{d:.4},{d:.4}]]",
            .{ cov[0][0], cov[0][1], cov[0][2], cov[1][0], cov[1][1], cov[1][2], cov[2][0], cov[2][1], cov[2][2] },
        ) catch return null;
        return self.buf[0..text.len];
    }
}, &.{ "x1", "x2", "x3" });

fn registerComptimeExamples(input: *const v2.duckdb_v2_extension_input) void {
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
    VariantTypeId.register(input) catch {};
    NarrowSum.register(input) catch {};
    TimestampAddCt.register(input) catch {};
    BlobPrefixCt.register(input) catch {};
    CheckedDivCt.register(input) catch {};
    FirstWordCt.register(input) catch {};
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
    Gram3Ct.register(input) catch {};
}

fn registerDouble(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_double");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return;

    const param_name = helpers.str("x");
    if (v2.duckdb_v2_function_signature_add_parameter(
        sig,
        &param_name,
        bigint_type,
        null,
        .FUNCTION_PARAMETER_KIND_STANDARD,
        err,
    ) != .ERROR_NONE) return;

    if (v2.duckdb_v2_function_signature_set_return_type(sig, bigint_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, exampleDoubleExec, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err);
}

fn registerRange3(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_range3");
    if (v2.duckdb_v2_table_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_table_function_set_bind_callback(function, exampleTableBind, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, exampleTableInitGlobal, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, exampleTableExec, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_table_function(input.extension, function, err);
}

fn registerAggSum(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_aggregate_function_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_aggregate_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_agg_sum");
    if (v2.duckdb_v2_aggregate_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_aggregate_function_get_signature(function, &sig, err) != .ERROR_NONE) return;

    const param_name = helpers.str("x");
    if (v2.duckdb_v2_function_signature_add_parameter(
        sig,
        &param_name,
        bigint_type,
        null,
        .FUNCTION_PARAMETER_KIND_STANDARD,
        err,
    ) != .ERROR_NONE) return;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, bigint_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_aggregate_function_set_size_callback(function, exampleAggSize, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_aggregate_function_set_init_callback(function, exampleAggInit, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_aggregate_function_set_update_callback(function, exampleAggUpdate, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_aggregate_function_set_combine_callback(function, exampleAggCombine, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_aggregate_function_set_finalize_callback(function, exampleAggFinalize, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_aggregate_function(input.extension, function, err);
}

/// Live round-trip test for `comptime_appender_v2.Appender`: builds three
/// rows with it, `finish`es into a `ColumnDataCollection`, scans the
/// collection back out, and formats what it reads as the result string —
/// proof (run against a real v2.0 alpha, not just `v2-check`'s
/// type-checking) that append → finish → scan round-trips BIGINT/VARCHAR/
/// DOUBLE correctly. `zig_v2_appender_test()` takes no arguments; its
/// result should read exactly
/// "1:alice:1.50|2:bob:2.75|3:carol:-4.00" if the round trip is intact.
fn registerAppenderTest(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_appender_test");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, appenderTestExec, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err);
}

const AppenderTestRow = struct { id: i64, name: []const u8, score: f64 };

fn appenderTestExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    var buf: [256]u8 = undefined;
    const text = appenderTestRoundTrip(context, &buf, err) catch "appender round-trip FAILED";

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        var value: v2.duckdb_v2_value_handle = undefined;
        if (helpers.createVarcharValue(context, text, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

const Appender = comptime_appender_v2.Appender(AppenderTestRow);

fn appenderTestRoundTrip(context: v2.duckdb_v2_context_handle, buf: []u8, err: *v2.duckdb_v2_error_info_handle) ![]const u8 {
    var e: v2.duckdb_v2_error_info_handle = undefined;

    var appender = Appender.create(context, &e) catch return error.CreateFailed;
    defer appender.destroy();

    appender.append(.{ .id = 1, .name = "alice", .score = 1.5 }, &e) catch return error.AppendFailed;
    appender.append(.{ .id = 2, .name = "bob", .score = 2.75 }, &e) catch return error.AppendFailed;
    appender.append(.{ .id = 3, .name = "carol", .score = -4.0 }, &e) catch return error.AppendFailed;

    var collection = appender.finish(&e) catch return error.FinishFailed;
    defer _ = v2.duckdb_v2_column_data_collection_destroy(&collection);

    var types: [3]v2.duckdb_v2_logical_type_handle = undefined;
    inline for (.{ i64, []const u8, f64 }, 0..) |T, i| {
        if (helpers.createTypeFromId(context, comptime_appender_v2.duckdbV2TypeId(T), &types[i], &e) != .ERROR_NONE) {
            return error.TypeFailed;
        }
    }
    defer {
        for (&types) |*ty| _ = v2.duckdb_v2_logical_type_destroy(ty);
    }

    var scan_chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (helpers.createDataChunk(context, &types, &scan_chunk, &e) != .ERROR_NONE) return error.ChunkFailed;
    defer _ = v2.duckdb_v2_data_chunk_destroy(&scan_chunk);

    var shared_state: v2.duckdb_v2_column_data_collection_shared_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared_state, &e) != .ERROR_NONE) return error.ScanStateFailed;
    defer _ = v2.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared_state);

    var worker_state: v2.duckdb_v2_column_data_collection_worker_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker_state, &e) != .ERROR_NONE) return error.ScanStateFailed;
    defer _ = v2.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker_state);

    var pos: usize = 0;
    var wrote_any = false;

    while (true) {
        var did_produce = false;
        if (v2.duckdb_v2_column_data_collection_scan(collection, shared_state, worker_state, scan_chunk, &did_produce, &e) != .ERROR_NONE) {
            return error.ScanFailed;
        }
        if (!did_produce) break;

        var chunk_size: u64 = 0;
        if (v2.duckdb_v2_data_chunk_get_size(scan_chunk, &chunk_size, &e) != .ERROR_NONE) return error.ScanFailed;

        var id_vec: v2.duckdb_v2_vector_handle = undefined;
        var name_vec: v2.duckdb_v2_vector_handle = undefined;
        var score_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(scan_chunk, 0, &id_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_data_chunk_get_vector(scan_chunk, 1, &name_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_data_chunk_get_vector(scan_chunk, 2, &score_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_flatten(id_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_flatten(name_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_flatten(score_vec, &e) != .ERROR_NONE) return error.ScanFailed;

        var id_view: v2.duckdb_v2_vector_view = undefined;
        var name_view: v2.duckdb_v2_vector_view = undefined;
        var score_view: v2.duckdb_v2_vector_view = undefined;
        if (v2.duckdb_v2_vector_get_view(id_vec, &id_view, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_get_view(name_vec, &name_view, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_get_view(score_vec, &score_view, &e) != .ERROR_NONE) return error.ScanFailed;

        // SAFETY: `scan_chunk`'s columns were declared BIGINT/VARCHAR/DOUBLE above.
        const ids: [*]const i64 = @ptrCast(@alignCast(id_view.data));
        const names: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(name_view.data));
        const scores: [*]const f64 = @ptrCast(@alignCast(score_view.data));

        var row: u64 = 0;
        while (row < chunk_size) : (row += 1) {
            if (wrote_any) {
                if (pos >= buf.len) return error.FormatFailed;
                buf[pos] = '|';
                pos += 1;
            }
            const segment = std.fmt.bufPrint(buf[pos..], "{d}:{s}:{d:.2}", .{ ids[row], helpers.bytesSlice(&names[row]), scores[row] }) catch return error.FormatFailed;
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
    defer _ = v2.duckdb_v2_column_data_collection_destroy(&stress_collection);
    var stress_count: u64 = 0;
    if (v2.duckdb_v2_column_data_collection_row_count(stress_collection, &stress_count, &e) != .ERROR_NONE) return error.ScanFailed;

    const suffix = std.fmt.bufPrint(buf[pos..], "|stress:{d}", .{stress_count}) catch return error.FormatFailed;
    pos += suffix.len;

    _ = err;
    return buf[0..pos];
}

/// `zig_v2_nethogs_trace(cmd VARCHAR, max_cycles BIGINT) -> TABLE(ts
/// BIGINT, program VARCHAR, pid BIGINT, uid BIGINT, sent_kbps DOUBLE,
/// recv_kbps DOUBLE)` — the "appender reads from a subprocess" POC:
/// `cmd` is a subprocess command line (space-separated, no quoting
/// support — e.g. `'zig-out/bin/fake_nethogs 5'`, or real
/// `'/usr/sbin/nethogs -t -c 5'` once `sudo setcap
/// "cap_net_admin,cap_net_raw+pe" $(which nethogs)` has been run —
/// nethogs itself needs that capability grant to sniff packets at all,
/// confirmed live, which this code neither has nor requests for itself).
/// **`cmd`'s first token must be an absolute or relative path containing
/// a `/`, never a bare command name**: confirmed live that
/// `std.process.spawn` fails with `error.FileNotFound` for a slash-free
/// `argv[0]` even when it's genuinely on `$PATH` (e.g. `'nethogs -t -c
/// 5'` fails; `'/usr/sbin/nethogs -t -c 5'` works) — a real Zig 0.17.0
/// gap versus its own documented PATH-search behavior, not a bug in this
/// function. A failed spawn now raises a real SQL error naming the
/// failure, rather than silently returning 0 rows (an earlier, fixed bug
/// in this function). `src/lib/nethogs_trace.zig` spawns `cmd`, parses
/// nethogs' own tracemode line format into a columnar `TraceBatch` (the
/// "Arrow-shaped" structure-of-arrays intermediate), and THIS function's
/// `bind` pushes that batch through `comptime_appender_v2.Appender` (the
/// "comptime-generated function for its schema": the DuckDB column types
/// for `NethogsTraceRow` are derived automatically from that plain Zig
/// struct, not hand-declared per column) to build a
/// `ColumnDataCollection`; `exec` then scans it back out as this table
/// function's actual output rows — the same build-then-scan pattern
/// `appenderTestRoundTrip` above already proved live, just driving a
/// table function's output chunk instead of formatting a VARCHAR summary.
///
/// Hand-written rather than through `comptime_table_v2.Function`: that
/// framework's `State.init` has no access to the bind-time `ContextHandle`
/// `Appender.create` needs (by design — see its own module doc comment),
/// so a function that routes through a real `Appender`/
/// `ColumnDataCollection` (rather than yielding rows one at a time via
/// `next`) needs its own bind/exec callbacks.
///
/// Checkpoint this was built to confirm (see `docs/v2-migration-plan.md`):
/// `SELECT program, sum(sent_kbps + recv_kbps) AS total FROM
/// zig_v2_nethogs_trace(...) GROUP BY program` already has the exact shape
/// `tp_treemap`/`tp_snakemap` expect once aggregated into LISTs —
/// `tp_treemap(list(total), list(program))` — confirmed by actually
/// calling it, not just by inspecting the two schemas.
const NethogsTraceRow = struct {
    ts: i64,
    program: []const u8,
    pid: i64,
    uid: i64,
    sent_kbps: f64,
    recv_kbps: f64,
};
const NethogsAppender = comptime_appender_v2.Appender(NethogsTraceRow);

const NethogsBindData = struct {
    collection: v2.duckdb_v2_column_data_collection_handle,
    shared_state: v2.duckdb_v2_column_data_collection_shared_scan_state_handle,
    worker_state: v2.duckdb_v2_column_data_collection_worker_scan_state_handle,
};

fn destroyNethogsBindData(data: ?*anyopaque) callconv(.c) void {
    const bd: *NethogsBindData = @ptrCast(@alignCast(data.?));
    _ = v2.duckdb_v2_column_data_collection_worker_scan_state_destroy(&bd.worker_state);
    _ = v2.duckdb_v2_column_data_collection_shared_scan_state_destroy(&bd.shared_state);
    _ = v2.duckdb_v2_column_data_collection_destroy(&bd.collection);
    std.heap.c_allocator.destroy(bd);
}

const nethogs_trace_columns = .{
    .{ "ts", .LOGICAL_TYPE_ID_BIGINT },
    .{ "program", .LOGICAL_TYPE_ID_VARCHAR },
    .{ "pid", .LOGICAL_TYPE_ID_BIGINT },
    .{ "uid", .LOGICAL_TYPE_ID_BIGINT },
    .{ "sent_kbps", .LOGICAL_TYPE_ID_DOUBLE },
    .{ "recv_kbps", .LOGICAL_TYPE_ID_DOUBLE },
};

fn nethogsTraceBind(info: v2.duckdb_v2_function_bind_info_handle, result: v2.duckdb_v2_table_function_bind_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    inline for (nethogs_trace_columns) |col| {
        var col_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(context, col[1], &col_type, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_logical_type_destroy(&col_type);
        const col_name = helpers.str(col[0]);
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &col_name, col_type, err) != .ERROR_NONE) return;
    }

    var cmd_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, 0, &cmd_value, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_value_destroy(&cmd_value);
    var cmd_str: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_value_get_varchar(cmd_value, &cmd_str, err) != .ERROR_NONE) return;
    // SAFETY: `cmd_str` borrows from `cmd_value`; used synchronously below,
    // before `cmd_value`'s `defer valueDestroy` runs — never retained past
    // this call, so no copy is needed (unlike comptime_table_v2's State,
    // which must outlive `bind`).
    const cmd: []const u8 = @as([*]const u8, @ptrCast(cmd_str.ptr))[0..cmd_str.len];

    var cycles_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, 1, &cycles_value, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_value_destroy(&cycles_value);
    var max_cycles: i64 = 0;
    if (v2.duckdb_v2_value_get_bigint(cycles_value, &max_cycles, err) != .ERROR_NONE) return;

    var batch = nethogs_trace.readTraceBatch(std.heap.c_allocator, cmd, max_cycles) catch |e| {
        // Report the real failure instead of silently returning 0 rows —
        // confirmed live this matters: a bare command name (`"nethogs"`,
        // no `/`) fails to spawn via `std.process.spawn`'s PATH search
        // (`error.FileNotFound`) even though the same name resolves fine
        // via a shell's own PATH lookup (`which nethogs`); an absolute
        // path (`/usr/sbin/nethogs`) spawns correctly. Silently swallowing
        // that into an empty result (the original version of this code)
        // made a real, fixable usage error look like "no traffic captured".
        var buf: [160]u8 = undefined;
        const msg_text = std.fmt.bufPrint(&buf, "zig_v2_nethogs_trace: failed to spawn/read '{s}': {s} (try an absolute path, e.g. /usr/sbin/nethogs)", .{ cmd, @errorName(e) }) catch "zig_v2_nethogs_trace: failed to spawn/read subprocess";
        _ = v2.duckdb_v2_error_info_set_code(err.*, .ERROR_API);
        _ = helpers.setErrorText(err.*, msg_text);
        return;
    };
    defer batch.deinit(std.heap.c_allocator);

    var appender = NethogsAppender.create(context, err) catch return;
    defer appender.destroy();

    var i: usize = 0;
    while (i < batch.len()) : (i += 1) {
        appender.append(.{
            .ts = batch.ts.items[i],
            .program = batch.program.items[i],
            .pid = batch.pid.items[i],
            .uid = batch.uid.items[i],
            .sent_kbps = batch.sent_kbps.items[i],
            .recv_kbps = batch.recv_kbps.items[i],
        }, err) catch return;
    }

    const collection = appender.finish(err) catch return;

    var shared_state: v2.duckdb_v2_column_data_collection_shared_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared_state, err) != .ERROR_NONE) return;
    var worker_state: v2.duckdb_v2_column_data_collection_worker_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker_state, err) != .ERROR_NONE) return;

    const bind_data = std.heap.c_allocator.create(NethogsBindData) catch return;
    bind_data.* = .{ .collection = collection, .shared_state = shared_state, .worker_state = worker_state };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = bind_data, .destroy = destroyNethogsBindData, .equals = null };
    _ = v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err);
    _ = v2.duckdb_v2_table_function_bind_set_cardinality(result, @intCast(batch.len()), true, err);
}

fn nethogsTraceExec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    _ = context;
    var bind_data_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_data_ptr, err) != .ERROR_NONE) return;
    const bd: *NethogsBindData = @ptrCast(@alignCast(bind_data_ptr.?));

    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;

    var did_produce = false;
    if (v2.duckdb_v2_column_data_collection_scan(bd.collection, bd.shared_state, bd.worker_state, chunk, &did_produce, err) != .ERROR_NONE) return;
    if (!did_produce) {
        var col0: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, 0, &col0, err) != .ERROR_NONE) return;
        _ = v2.duckdb_v2_vector_set_size(col0, 0, err);
    }
}

fn registerNethogsTrace(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_nethogs_trace");
    if (v2.duckdb_v2_table_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) return;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);
    const cmd_name = helpers.str("cmd");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &cmd_name, varchar_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return;

    var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);
    const cycles_name = helpers.str("max_cycles");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &cycles_name, bigint_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_table_function_set_bind_callback(function, nethogsTraceBind, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, nethogsTraceExec, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_table_function(input.extension, function, err);
}

/// Live round-trip test for `comptime_appender_v2.Appender`'s LIST and
/// STRUCT support: builds two rows (`tags LIST(BIGINT)`, `point
/// STRUCT(x DOUBLE, y DOUBLE)`), `finish`es, scans back, and formats what
/// it reads. `zig_v2_appender_nested_test()` takes no arguments; its
/// result should read exactly "[1,2,3]:(1.5,2.5)|[]:(-1.0,0.0)" if the
/// round trip is intact.
fn registerAppenderNestedTest(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_appender_nested_test");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, appenderNestedTestExec, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err);
}

const NestedTestRow = struct { tags: []const i64, point: struct { x: f64, y: f64 } };
const NestedAppender = comptime_appender_v2.Appender(NestedTestRow);

fn appenderNestedTestExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    var buf: [256]u8 = undefined;
    const text = nestedTestRoundTrip(context, &buf, err) catch "appender nested round-trip FAILED";

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        var value: v2.duckdb_v2_value_handle = undefined;
        if (helpers.createVarcharValue(context, text, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

fn nestedTestRoundTrip(context: v2.duckdb_v2_context_handle, buf: []u8, err: *v2.duckdb_v2_error_info_handle) ![]const u8 {
    var e: v2.duckdb_v2_error_info_handle = undefined;

    var appender = NestedAppender.create(context, &e) catch return error.CreateFailed;
    defer appender.destroy();

    appender.append(.{ .tags = &[_]i64{ 1, 2, 3 }, .point = .{ .x = 1.5, .y = 2.5 } }, &e) catch return error.AppendFailed;
    appender.append(.{ .tags = &[_]i64{}, .point = .{ .x = -1.0, .y = 0.0 } }, &e) catch return error.AppendFailed;

    var collection = appender.finish(&e) catch return error.FinishFailed;
    defer _ = v2.duckdb_v2_column_data_collection_destroy(&collection);

    // Rebuild the LIST(BIGINT)/STRUCT(x DOUBLE, y DOUBLE) types by hand for
    // the scan output chunk — `Appender` doesn't expose the ones it built
    // internally (they're destroyed once `create` returns).
    var list_child_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_BIGINT, &list_child_type, &e) != .ERROR_NONE) return error.TypeFailed;
    defer _ = v2.duckdb_v2_logical_type_destroy(&list_child_type);
    var list_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createListType(context, list_child_type, &list_type, &e) != .ERROR_NONE) return error.TypeFailed;
    defer _ = v2.duckdb_v2_logical_type_destroy(&list_type);

    var x_type: v2.duckdb_v2_logical_type_handle = undefined;
    var y_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_DOUBLE, &x_type, &e) != .ERROR_NONE) return error.TypeFailed;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_DOUBLE, &y_type, &e) != .ERROR_NONE) return error.TypeFailed;
    var struct_names = [_]v2.duckdb_v2_identifier_t{ helpers.str("x"), helpers.str("y") };
    var struct_field_types = [_]v2.duckdb_v2_logical_type_handle{ x_type, y_type };
    var struct_field_type_values: [2]v2.duckdb_v2_value_handle = undefined;
    var struct_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createStructType(context, &struct_names, &struct_field_types, &struct_field_type_values, &struct_type, &e) != .ERROR_NONE) return error.TypeFailed;
    defer _ = v2.duckdb_v2_logical_type_destroy(&struct_type);
    defer {
        for (&struct_field_types) |*ty| _ = v2.duckdb_v2_logical_type_destroy(ty);
    }

    var types = [_]v2.duckdb_v2_logical_type_handle{ list_type, struct_type };
    var scan_chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (helpers.createDataChunk(context, &types, &scan_chunk, &e) != .ERROR_NONE) return error.ChunkFailed;
    defer _ = v2.duckdb_v2_data_chunk_destroy(&scan_chunk);

    var shared_state: v2.duckdb_v2_column_data_collection_shared_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared_state, &e) != .ERROR_NONE) return error.ScanStateFailed;
    defer _ = v2.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared_state);
    var worker_state: v2.duckdb_v2_column_data_collection_worker_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker_state, &e) != .ERROR_NONE) return error.ScanStateFailed;
    defer _ = v2.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker_state);

    var pos: usize = 0;
    var wrote_any = false;

    while (true) {
        var did_produce = false;
        if (v2.duckdb_v2_column_data_collection_scan(collection, shared_state, worker_state, scan_chunk, &did_produce, &e) != .ERROR_NONE) {
            return error.ScanFailed;
        }
        if (!did_produce) break;

        var chunk_size: u64 = 0;
        if (v2.duckdb_v2_data_chunk_get_size(scan_chunk, &chunk_size, &e) != .ERROR_NONE) return error.ScanFailed;

        var tags_vec: v2.duckdb_v2_vector_handle = undefined;
        var point_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(scan_chunk, 0, &tags_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_data_chunk_get_vector(scan_chunk, 1, &point_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_flatten(tags_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_flatten(point_vec, &e) != .ERROR_NONE) return error.ScanFailed;

        var tags_view: v2.duckdb_v2_vector_view = undefined;
        if (v2.duckdb_v2_vector_get_view(tags_vec, &tags_view, &e) != .ERROR_NONE) return error.ScanFailed;
        // SAFETY: `tags_vec` is LIST(BIGINT); a LIST vector's own data is `[*]ListEntry`.
        const list_entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(tags_view.data));

        var tags_child: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_vector_get_child(tags_vec, 0, &tags_child, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_flatten(tags_child, &e) != .ERROR_NONE) return error.ScanFailed;
        var tags_child_view: v2.duckdb_v2_vector_view = undefined;
        if (v2.duckdb_v2_vector_get_view(tags_child, &tags_child_view, &e) != .ERROR_NONE) return error.ScanFailed;
        // SAFETY: the LIST's child vector is BIGINT.
        const tag_elems: [*]const i64 = @ptrCast(@alignCast(tags_child_view.data));

        var x_vec: v2.duckdb_v2_vector_handle = undefined;
        var y_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_vector_get_child(point_vec, 0, &x_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_get_child(point_vec, 1, &y_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_flatten(x_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_flatten(y_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        var x_view: v2.duckdb_v2_vector_view = undefined;
        var y_view: v2.duckdb_v2_vector_view = undefined;
        if (v2.duckdb_v2_vector_get_view(x_vec, &x_view, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_vector_get_view(y_vec, &y_view, &e) != .ERROR_NONE) return error.ScanFailed;
        // SAFETY: STRUCT fields x/y are both DOUBLE.
        const xs: [*]const f64 = @ptrCast(@alignCast(x_view.data));
        const ys: [*]const f64 = @ptrCast(@alignCast(y_view.data));

        var row: u64 = 0;
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
            var k: u64 = 0;
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
/// vector layout, which `duckdb_v2_dynamic.zig`'s own `duckdb_v2_vector_get_child` doc comment
/// leaves ambiguous for ARRAY specifically (groups it with LIST's
/// `ListEntry` addressing, which doesn't obviously fit a fixed-size type).
/// `zig_v2_appender_array_enum_test()` takes no arguments; its result
/// should read exactly "[1.5,2.5,3.5]:active|[4.0,5.0,6.0]:done" if the
/// round trip is intact.
fn registerAppenderArrayEnumTest(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_appender_array_enum_test");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, appenderArrayEnumTestExec, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err);
}

const Status = enum { pending, active, done };
const ArrayEnumRow = struct { coords: [3]f64, status: Status };
const ArrayEnumAppender = comptime_appender_v2.Appender(ArrayEnumRow);

fn appenderArrayEnumTestExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    var buf: [256]u8 = undefined;
    const text = arrayEnumRoundTrip(context, &buf, err) catch "appender array/enum round-trip FAILED";

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        var value: v2.duckdb_v2_value_handle = undefined;
        if (helpers.createVarcharValue(context, text, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

fn arrayEnumRoundTrip(context: v2.duckdb_v2_context_handle, buf: []u8, err: *v2.duckdb_v2_error_info_handle) ![]const u8 {
    var e: v2.duckdb_v2_error_info_handle = undefined;

    var appender = ArrayEnumAppender.create(context, &e) catch return error.CreateFailed;
    defer appender.destroy();

    appender.append(.{ .coords = .{ 1.5, 2.5, 3.5 }, .status = .active }, &e) catch return error.AppendFailed;
    appender.append(.{ .coords = .{ 4.0, 5.0, 6.0 }, .status = .done }, &e) catch return error.AppendFailed;

    var collection = appender.finish(&e) catch return error.FinishFailed;
    defer _ = v2.duckdb_v2_column_data_collection_destroy(&collection);

    var coords_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromText(context, "DOUBLE[3]", &coords_type, &e) != .ERROR_NONE) return error.TypeFailed;
    defer _ = v2.duckdb_v2_logical_type_destroy(&coords_type);
    var status_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromText(context, "ENUM('pending','active','done')", &status_type, &e) != .ERROR_NONE) return error.TypeFailed;
    defer _ = v2.duckdb_v2_logical_type_destroy(&status_type);
    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, &e) != .ERROR_NONE) return error.TypeFailed;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var types = [_]v2.duckdb_v2_logical_type_handle{ coords_type, status_type };
    var scan_chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (helpers.createDataChunk(context, &types, &scan_chunk, &e) != .ERROR_NONE) return error.ChunkFailed;
    defer _ = v2.duckdb_v2_data_chunk_destroy(&scan_chunk);

    var shared_state: v2.duckdb_v2_column_data_collection_shared_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared_state, &e) != .ERROR_NONE) return error.ScanStateFailed;
    defer _ = v2.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared_state);
    var worker_state: v2.duckdb_v2_column_data_collection_worker_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker_state, &e) != .ERROR_NONE) return error.ScanStateFailed;
    defer _ = v2.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker_state);

    var pos: usize = 0;
    var wrote_any = false;

    while (true) {
        var did_produce = false;
        if (v2.duckdb_v2_column_data_collection_scan(collection, shared_state, worker_state, scan_chunk, &did_produce, &e) != .ERROR_NONE) {
            return error.ScanFailed;
        }
        if (!did_produce) break;

        var chunk_size: u64 = 0;
        if (v2.duckdb_v2_data_chunk_get_size(scan_chunk, &chunk_size, &e) != .ERROR_NONE) return error.ScanFailed;

        var coords_vec: v2.duckdb_v2_vector_handle = undefined;
        var status_vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(scan_chunk, 0, &coords_vec, &e) != .ERROR_NONE) return error.ScanFailed;
        if (v2.duckdb_v2_data_chunk_get_vector(scan_chunk, 1, &status_vec, &e) != .ERROR_NONE) return error.ScanFailed;

        var row: u64 = 0;
        while (row < chunk_size) : (row += 1) {
            if (wrote_any) {
                if (pos >= buf.len) return error.FormatFailed;
                buf[pos] = '|';
                pos += 1;
            }

            var coords_value: v2.duckdb_v2_value_handle = undefined;
            if (v2.duckdb_v2_vector_get_value(coords_vec, row, &coords_value, &e) != .ERROR_NONE) return error.ScanFailed;
            defer _ = v2.duckdb_v2_value_destroy(&coords_value);
            var n: u64 = 0;
            if (v2.duckdb_v2_value_get_child_count(coords_value, &n, &e) != .ERROR_NONE) return error.ScanFailed;

            if (pos >= buf.len) return error.FormatFailed;
            buf[pos] = '[';
            pos += 1;
            var k: u64 = 0;
            while (k < n) : (k += 1) {
                if (k > 0) {
                    if (pos >= buf.len) return error.FormatFailed;
                    buf[pos] = ',';
                    pos += 1;
                }
                var elem_value: v2.duckdb_v2_value_handle = undefined;
                if (v2.duckdb_v2_value_get_child(coords_value, k, &elem_value, &e) != .ERROR_NONE) return error.ScanFailed;
                defer _ = v2.duckdb_v2_value_destroy(&elem_value);
                var elem: f64 = 0;
                if (v2.duckdb_v2_value_get_double(elem_value, &elem, &e) != .ERROR_NONE) return error.ScanFailed;
                const seg = std.fmt.bufPrint(buf[pos..], "{d:.1}", .{elem}) catch return error.FormatFailed;
                pos += seg.len;
            }
            if (pos >= buf.len) return error.FormatFailed;
            buf[pos] = ']';
            pos += 1;

            var status_value: v2.duckdb_v2_value_handle = undefined;
            if (v2.duckdb_v2_vector_get_value(status_vec, row, &status_value, &e) != .ERROR_NONE) return error.ScanFailed;
            defer _ = v2.duckdb_v2_value_destroy(&status_value);
            var status_text_value: v2.duckdb_v2_value_handle = undefined;
            if (v2.duckdb_v2_value_cast(helpers.factory(context, &e) orelse return error.FailedToGetFactory, status_value, varchar_type, &status_text_value, &e) != .ERROR_NONE) return error.ScanFailed;
            defer _ = v2.duckdb_v2_value_destroy(&status_text_value);
            var status_text: v2.duckdb_v2_str = undefined;
            if (v2.duckdb_v2_value_get_varchar(status_text_value, &status_text, &e) != .ERROR_NONE) return error.ScanFailed;
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
    pub fn pushdown(self: *@This(), info: v2.duckdb_v2_table_function_filter_pushdown_info_handle, err: *v2.duckdb_v2_error_info_handle) void {
        var count: u64 = 0;
        if (v2.duckdb_v2_table_function_filter_pushdown_get_filter_count(info, &count, err) != .ERROR_NONE) return;

        var i: u64 = 0;
        while (i < count) : (i += 1) {
            var expr: v2.duckdb_v2_expression_handle = undefined;
            if (v2.duckdb_v2_table_function_filter_pushdown_get_filter(info, i, &expr, err) != .ERROR_NONE) continue;

            var expr_type: v2.DUCKDB_V2_EXPRESSION_TYPE = undefined;
            if (v2.duckdb_v2_expression_get_type(expr, &expr_type, err) != .ERROR_NONE) continue;
            if (expr_type != .EXPRESSION_TYPE_COMPARE_EQUAL) continue;

            var lhs: v2.duckdb_v2_expression_handle = undefined;
            var rhs: v2.duckdb_v2_expression_handle = undefined;
            if (v2.duckdb_v2_expression_get_child(expr, 0, &lhs, err) != .ERROR_NONE) continue;
            if (v2.duckdb_v2_expression_get_child(expr, 1, &rhs, err) != .ERROR_NONE) continue;

            var lhs_type: v2.DUCKDB_V2_EXPRESSION_TYPE = undefined;
            var rhs_type: v2.DUCKDB_V2_EXPRESSION_TYPE = undefined;
            if (v2.duckdb_v2_expression_get_type(lhs, &lhs_type, err) != .ERROR_NONE) continue;
            if (v2.duckdb_v2_expression_get_type(rhs, &rhs_type, err) != .ERROR_NONE) continue;
            if (lhs_type != .EXPRESSION_TYPE_BOUND_COLUMN_REF) continue;
            if (rhs_type != .EXPRESSION_TYPE_VALUE_CONSTANT) continue;

            var col_ref_idx: u64 = 0;
            if (v2.duckdb_v2_expression_column_ref_get_index(lhs, &col_ref_idx, err) != .ERROR_NONE) continue;
            var declared_col: u64 = 0;
            if (v2.duckdb_v2_table_function_filter_pushdown_get_column_index(info, col_ref_idx, &declared_col, err) != .ERROR_NONE) continue;
            if (declared_col != 0) continue; // only "value" (column 0) is recognized

            var constant: v2.duckdb_v2_value_handle = undefined;
            if (v2.duckdb_v2_expression_constant_get_value(rhs, &constant, err) != .ERROR_NONE) continue;
            defer _ = v2.duckdb_v2_value_destroy(&constant);
            var value: i64 = 0;
            if (v2.duckdb_v2_value_get_bigint(constant, &value, err) != .ERROR_NONE) continue;

            self.predicate = value;
            if (v2.duckdb_v2_table_function_filter_pushdown_accept(info, i, err) != .ERROR_NONE) continue;
            pushdown_hit_count += 1;
        }
    }
};

const RangeFilterTable = comptime_table_v2.Function("zig_v2_range_pushdown_ct", RangeFilterState);

fn registerFilterPushdownTest(input: *const v2.duckdb_v2_extension_input) void {
    RangeFilterTable.register(input) catch {};

    var err: v2.duckdb_v2_error_info_handle = undefined;

    var get_fn: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, &err) orelse return, &get_fn, &err) == .ERROR_NONE) {
        defer _ = v2.duckdb_v2_scalar_function_destroy(&get_fn);
        const get_name = helpers.str("zig_v2_pushdown_hit_count");
        _ = v2.duckdb_v2_scalar_function_set_name(get_fn, &get_name, &err);
        var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) == .ERROR_NONE) {
            defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);
            var sig: v2.duckdb_v2_function_signature_handle = undefined;
            if (v2.duckdb_v2_scalar_function_get_signature(get_fn, &sig, &err) == .ERROR_NONE) {
                _ = v2.duckdb_v2_function_signature_set_return_type(sig, bigint_type, &err);
                _ = v2.duckdb_v2_scalar_function_set_exec_callback(get_fn, pushdownHitCountExec, &err);
                _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, get_fn, &err);
            }
        }
    }

    var reset_fn: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, &err) orelse return, &reset_fn, &err) == .ERROR_NONE) {
        defer _ = v2.duckdb_v2_scalar_function_destroy(&reset_fn);
        const reset_name = helpers.str("zig_v2_pushdown_hit_count_reset");
        _ = v2.duckdb_v2_scalar_function_set_name(reset_fn, &reset_name, &err);
        var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) == .ERROR_NONE) {
            defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);
            var sig: v2.duckdb_v2_function_signature_handle = undefined;
            if (v2.duckdb_v2_scalar_function_get_signature(reset_fn, &sig, &err) == .ERROR_NONE) {
                _ = v2.duckdb_v2_function_signature_set_return_type(sig, bigint_type, &err);
                _ = v2.duckdb_v2_scalar_function_set_exec_callback(reset_fn, pushdownHitCountResetExec, &err);
                _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, reset_fn, &err);
            }
        }
    }
}

fn pushdownHitCountExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    _ = context;
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;
    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
    const ptr: [*]i64 = @ptrCast(@alignCast(out_data));
    var row: u64 = 0;
    while (row < row_count) : (row += 1) ptr[row] = pushdown_hit_count;
}

fn pushdownHitCountResetExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    _ = context;
    pushdown_hit_count = 0;
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;
    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
    const ptr: [*]i64 = @ptrCast(@alignCast(out_data));
    var row: u64 = 0;
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

fn registerProjectionPushdownTest(input: *const v2.duckdb_v2_extension_input) void {
    ProjectionTestTable.register(input) catch {};

    var err: v2.duckdb_v2_error_info_handle = undefined;

    var mask_fn: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, &err) orelse return, &mask_fn, &err) == .ERROR_NONE) {
        defer _ = v2.duckdb_v2_scalar_function_destroy(&mask_fn);
        const mask_name = helpers.str("zig_v2_project_last_mask");
        _ = v2.duckdb_v2_scalar_function_set_name(mask_fn, &mask_name, &err);
        var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, &err) == .ERROR_NONE) {
            defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);
            var sig: v2.duckdb_v2_function_signature_handle = undefined;
            if (v2.duckdb_v2_scalar_function_get_signature(mask_fn, &sig, &err) == .ERROR_NONE) {
                _ = v2.duckdb_v2_function_signature_set_return_type(sig, bigint_type, &err);
                _ = v2.duckdb_v2_scalar_function_set_exec_callback(mask_fn, projectionLastMaskExec, &err);
                _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, mask_fn, &err);
            }
        }
    }
}

fn projectionLastMaskExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    _ = context;
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;
    var out_data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
    const ptr: [*]i64 = @ptrCast(@alignCast(out_data));
    var row: u64 = 0;
    while (row < row_count) : (row += 1) ptr[row] = projection_last_mask;
}

/// Live test for `duckdb_v2_dynamic.zig`'s replacement-scan wrappers: recognizes
/// an unresolved table reference of the form `zig_v2_range_<N>` (e.g.
/// `FROM zig_v2_range_7`) and claims it by redirecting to
/// `zig_v2_range_ct(N)` — proves both the name-recognition path and
/// argument-threading (`replacementScanAddArgument`), not just that the
/// callback fires. Anything else is declined (no claim, no mutation) and
/// falls through to DuckDB's normal "no such table" error, same as if
/// this scan weren't registered at all.
fn registerReplacementScanTest(input: *const v2.duckdb_v2_extension_input) void {
    var err: v2.duckdb_v2_error_info_handle = undefined;

    var scan: v2.duckdb_v2_replacement_scan_handle = undefined;
    if (v2.duckdb_v2_replacement_scan_create(helpers.factory(input.context, &err) orelse return, &scan, &err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_replacement_scan_destroy(&scan);

    if (v2.duckdb_v2_replacement_scan_set_callback(scan, replacementScanCallback, &err) != .ERROR_NONE) return;
    _ = v2.duckdb_v2_extension_register_replacement_scan(input.extension, scan, &err);
}

const range_prefix = "zig_v2_range_";

fn replacementScanCallback(info: v2.duckdb_v2_replacement_scan_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var qname: v2.duckdb_v2_qname_handle = undefined;
    if (v2.duckdb_v2_replacement_scan_get_name(info, &qname, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_qname_destroy(&qname);

    var part_count: u64 = 0;
    if (v2.duckdb_v2_qname_get_part_count(qname, &part_count, err) != .ERROR_NONE) return;

    var object_name: v2.duckdb_v2_identifier_t = undefined;
    if (v2.duckdb_v2_qname_get_part(qname, part_count - 1, &object_name, err) != .ERROR_NONE) return;
    // SAFETY: `object_name` borrows from `qname`, valid until it's destroyed above.
    const name_slice: []const u8 = @as([*]const u8, @ptrCast(object_name.ptr))[0..object_name.len];

    if (!std.mem.startsWith(u8, name_slice, range_prefix)) return; // decline — not our pattern
    const n = std.fmt.parseInt(i64, name_slice[range_prefix.len..], 10) catch return; // decline — not `..._<N>`

    var target: v2.duckdb_v2_qname_handle = undefined;
    const target_name = helpers.str("zig_v2_range_ct");
    if (v2.duckdb_v2_qname_create(&.{target_name}, 1, &target, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_qname_destroy(&target);
    if (v2.duckdb_v2_replacement_scan_set_function_name(info, target, err) != .ERROR_NONE) return;

    var n_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_value_create_bigint(helpers.factory(context, err) orelse return, n, &n_value, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_value_destroy(&n_value);
    _ = v2.duckdb_v2_replacement_scan_add_argument(info, n_value, err);
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

/// Benchmarks `matmulNaive` against `matmulSimd`, `matmulSimdParallel`, `matmulSimdBlocked`,
/// `matmulSimdParallelBlocked`, `matmulSimdBlockedMc` and `matmulSimdParallelBlockedMc` on an
/// m×k × k×n multiplication, run `iterations` times each, timed via `std.Io.Clock`
/// (`std.time.Timer` no longer exists in Zig 0.17 — timing moved under the unified `Io` interface,
/// same `std.Io.Threaded` construction the braille v2-poc demo already uses to get an `Io`
/// instance outside of `std.process.Init`). The same `Threaded` instance built for timing also
/// backs every parallel kernel's `std.Io.Group` dispatch — one pool doing all of them. Test data
/// is a fixed deterministic pattern, not random — this is a throughput comparison, not a
/// correctness fuzz test (that's `matmul.zig`'s own unit tests).
const MatmulBenchState = struct {
    kernel_names: [7][]const u8,
    elapsed_ms: [7]f64,
    gflops: [7]f64,
    idx: usize,

    pub const Row = struct { kernel: []const u8, elapsed_ms: f64, gflops: f64 };

    pub fn init(m: i64, k: i64, n: i64, iterations: i64) @This() {
        const failed: @This() = .{ .kernel_names = undefined, .elapsed_ms = undefined, .gflops = undefined, .idx = 7 };

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
        const max_tasks = std.Thread.getCpuCount() catch 1;

        const flops: f64 = 2.0 * @as(f64, @floatFromInt(mu)) * @as(f64, @floatFromInt(nu)) * @as(f64, @floatFromInt(ku)) * @as(f64, @floatFromInt(iters));

        const naive_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulNaive(a, b, c, mu, ku, nu);
        const naive_ns: f64 = @floatFromInt(naive_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        const simd_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulSimd(matmul.default_rm, a, b, c, mu, ku, nu);
        const simd_ns: f64 = @floatFromInt(simd_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        const parallel_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulSimdParallel(matmul.default_rm, io, max_tasks, a, b, c, mu, ku, nu);
        const parallel_ns: f64 = @floatFromInt(parallel_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        const blocked_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulSimdBlocked(matmul.default_rm, a, b, c, mu, ku, nu);
        const blocked_ns: f64 = @floatFromInt(blocked_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        const parallel_blocked_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulSimdParallelBlocked(matmul.default_rm, io, max_tasks, a, b, c, mu, ku, nu);
        const parallel_blocked_ns: f64 = @floatFromInt(parallel_blocked_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        const blocked_mc_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulSimdBlockedMc(matmul.default_rm, a, b, c, mu, ku, nu);
        const blocked_mc_ns: f64 = @floatFromInt(blocked_mc_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        const parallel_blocked_mc_start: std.Io.Clock.Timestamp = .now(io, .awake);
        for (0..iters) |_| matmul.matmulSimdParallelBlockedMc(matmul.default_rm, io, max_tasks, a, b, c, mu, ku, nu);
        const parallel_blocked_mc_ns: f64 = @floatFromInt(parallel_blocked_mc_start.durationTo(.now(io, .awake)).raw.nanoseconds);

        return .{
            .kernel_names = .{ "naive", "simd", "simd_parallel", "simd_blocked", "simd_parallel_blocked", "simd_blocked_mc", "simd_parallel_blocked_mc" },
            .elapsed_ms = .{ naive_ns / 1e6, simd_ns / 1e6, parallel_ns / 1e6, blocked_ns / 1e6, parallel_blocked_ns / 1e6, blocked_mc_ns / 1e6, parallel_blocked_mc_ns / 1e6 },
            .gflops = .{ flops / naive_ns, flops / simd_ns, flops / parallel_ns, flops / blocked_ns, flops / parallel_blocked_ns, flops / blocked_mc_ns, flops / parallel_blocked_mc_ns },
            .idx = 0,
        };
    }

    pub fn next(self: *@This()) ?Row {
        if (self.idx >= 7) return null;
        defer self.idx += 1;
        return .{ .kernel = self.kernel_names[self.idx], .elapsed_ms = self.elapsed_ms[self.idx], .gflops = self.gflops[self.idx] };
    }
};
const MatmulBenchCt = comptime_table_v2.FunctionNamed("zig_v2_matmul_bench_ct", MatmulBenchState, &.{ "m", "k", "n", "iterations" });

// Worked examples from duckdb_v2_examples.zig, re-exposed here so this file
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

/// Live round-trip test for `comptime_appender_v2.Appender` over every leaf type (i8, i16, i32, i64, f32, f64,
/// bool, VARCHAR), a LIST(VARCHAR), a one-level STRUCT and a fixed-size ARRAY of INTEGER, with explicit
/// `flush` calls in the middle of the stream: after the first row (a chunk of one row is appended, then
/// written to again, three rows deep, which needs it sized back up), twice after the fifth (the second with
/// nothing buffered). `zig_v2_appender_types_test()`
/// returns what it scans back, each column cast to VARCHAR and joined with `|`, the rows with `;`.
fn registerAppenderTypesTest(input: *const v2.duckdb_v2_extension_input, err: *v2.duckdb_v2_error_info_handle) void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return, &function, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_appender_types_test");
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return;

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_function_signature_set_return_type(sig, varchar_type, err) != .ERROR_NONE) return;

    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, appenderTypesTestExec, err) != .ERROR_NONE) return;

    _ = v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err);
}

const TypesRow = struct {
    a: i8,
    b: i16,
    c: i32,
    d: i64,
    e: f32,
    f: f64,
    g: bool,
    h: []const u8,
    l: []const []const u8,
    s: struct { x: i32, flag: bool },
    n: [2]i32,
};
const TypesAppender = comptime_appender_v2.Appender(TypesRow);
const types_columns = [_][:0]const u8{ "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "FLOAT", "DOUBLE", "BOOLEAN", "VARCHAR", "VARCHAR[]", "STRUCT(x INTEGER, flag BOOLEAN)", "INTEGER[2]" };

fn appenderTypesTestExec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var row_count: u64 = 0;
    if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

    var result_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

    var buf: [1024]u8 = undefined;
    const text = appenderTypesRoundTrip(context, &buf) catch "appender types round-trip FAILED";

    var row: u64 = 0;
    while (row < row_count) : (row += 1) {
        var value: v2.duckdb_v2_value_handle = undefined;
        if (helpers.createVarcharValue(context, text, &value, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_value_destroy(&value);
        if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
    }
}

fn appenderTypesRoundTrip(context: v2.duckdb_v2_context_handle, buf: []u8) ![]const u8 {
    var e: v2.duckdb_v2_error_info_handle = undefined;

    var appender = TypesAppender.create(context, &e) catch return error.CreateFailed;
    defer appender.destroy();

    const names = [_][]const u8{ "s0", "s1", "s2", "s3", "s4" };
    var i: i64 = 1;
    while (i <= 6) : (i += 1) {
        var text_buf: [48]u8 = undefined;
        const h = std.fmt.bufPrint(&text_buf, "row {d}, a longer text than twelve", .{i}) catch return error.FormatFailed;
        appender.append(.{
            .a = @intCast(i - 3),
            .b = @intCast(-i * 1000),
            .c = @intCast(i * 100000),
            .d = i * 10_000_000_000,
            .e = @as(f32, @floatFromInt(i)) + 0.5,
            .f = @as(f64, @floatFromInt(i)) / 8.0,
            .g = @mod(i, 2) == 0,
            .h = h,
            .l = names[0..@intCast(i - 1)],
            .s = .{ .x = @intCast(-i), .flag = @mod(i, 3) == 0 },
            .n = .{ @intCast(i), @intCast(-i) },
        }, &e) catch return error.AppendFailed;
        if (i == 1 or i == 5) appender.flush(&e) catch return error.FlushFailed;
        if (i == 5) appender.flush(&e) catch return error.FlushFailed;
    }

    var collection = appender.finish(&e) catch return error.FinishFailed;
    defer _ = v2.duckdb_v2_column_data_collection_destroy(&collection);

    var types: [types_columns.len]v2.duckdb_v2_logical_type_handle = undefined;
    var made: usize = 0;
    defer for (types[0..made]) |*ty| {
        _ = v2.duckdb_v2_logical_type_destroy(ty);
    };
    for (types_columns, 0..) |sql_type, k| {
        if (helpers.createTypeFromText(context, sql_type, &types[k], &e) != .ERROR_NONE) return error.TypeFailed;
        made = k + 1;
    }
    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, &e) != .ERROR_NONE) return error.TypeFailed;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var scan_chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (helpers.createDataChunk(context, &types, &scan_chunk, &e) != .ERROR_NONE) return error.ChunkFailed;
    defer _ = v2.duckdb_v2_data_chunk_destroy(&scan_chunk);
    var shared_state: v2.duckdb_v2_column_data_collection_shared_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared_state, &e) != .ERROR_NONE) return error.ScanStateFailed;
    defer _ = v2.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared_state);
    var worker_state: v2.duckdb_v2_column_data_collection_worker_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker_state, &e) != .ERROR_NONE) return error.ScanStateFailed;
    defer _ = v2.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker_state);

    var pos: usize = 0;
    var wrote_any = false;
    while (true) {
        var did_produce = false;
        if (v2.duckdb_v2_column_data_collection_scan(collection, shared_state, worker_state, scan_chunk, &did_produce, &e) != .ERROR_NONE) return error.ScanFailed;
        if (!did_produce) break;
        var chunk_size: u64 = 0;
        if (v2.duckdb_v2_data_chunk_get_size(scan_chunk, &chunk_size, &e) != .ERROR_NONE) return error.ScanFailed;

        var row: u64 = 0;
        while (row < chunk_size) : (row += 1) {
            if (wrote_any) pos = try appendText(buf, pos, ";");
            wrote_any = true;
            for (0..types_columns.len) |col| {
                if (col > 0) pos = try appendText(buf, pos, "|");
                var vec: v2.duckdb_v2_vector_handle = undefined;
                if (v2.duckdb_v2_data_chunk_get_vector(scan_chunk, col, &vec, &e) != .ERROR_NONE) return error.ScanFailed;
                var value: v2.duckdb_v2_value_handle = undefined;
                if (v2.duckdb_v2_vector_get_value(vec, row, &value, &e) != .ERROR_NONE) return error.ScanFailed;
                defer _ = v2.duckdb_v2_value_destroy(&value);
                var as_text: v2.duckdb_v2_value_handle = undefined;
                if (v2.duckdb_v2_value_cast(helpers.factory(context, &e) orelse return error.FailedToGetFactory, value, varchar_type, &as_text, &e) != .ERROR_NONE) return error.ScanFailed;
                defer _ = v2.duckdb_v2_value_destroy(&as_text);
                var text: v2.duckdb_v2_str = undefined;
                if (v2.duckdb_v2_value_get_varchar(as_text, &text, &e) != .ERROR_NONE) return error.ScanFailed;
                pos = try appendText(buf, pos, @as([*]const u8, @ptrCast(text.ptr))[0..text.len]);
            }
        }
    }
    return buf[0..pos];
}

fn appendText(buf: []u8, pos: usize, text: []const u8) !usize {
    if (pos + text.len > buf.len) return error.FormatFailed;
    @memcpy(buf[pos..][0..text.len], text);
    return pos + text.len;
}
