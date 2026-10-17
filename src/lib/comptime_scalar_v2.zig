///! Comptime scalar function framework for the DuckDB v2 C Extension API.
///!
///! A v2 port of `comptime_scalar.zig`'s `Function(name, implFn)` pattern,
///! generating the same vectorized-callback-from-a-per-row-function
///! boilerplate, adapted to v2's error-returning, out-param calling
///! convention and extension-based (not connection-based) registration.
///! Supports the same numeric types as the v1 framework (i8, i16, i32, i64,
///! f32, f64, bool), plus `[]const u8` for VARCHAR parameters and/or return
///! type — see duckdb_v2_dynamic.zig's `bytesSlice` (in `v2_helpers.zig`)/`duckdb_v2_value_create_varchar_with_context`
///! doc comments for how vector-stored strings differ from numeric types.
///! Also: `v2_values.Date`/`v2_values.Time`/`v2_values.Timestamp`/`v2_values.Interval` (fixed-width,
///! same direct-buffer path as the numeric types — see their doc comments
///! in duckdb_v2_dynamic.zig for why no new exec-path code was needed) and
///! `v2_values.Blob` (VARCHAR's `BytesValue`/boxed-`Value` machinery, reused as-is,
///! just tagged as BLOB instead of VARCHAR at registration).
///!
///! CAUTION: a `[]const u8`-returning `implFn` must return a slice that
///! outlives the call — one borrowed from its own arguments (a substring,
///! or an argument unchanged), a string literal, or heap/static memory.
///! It must NOT return a slice into its own local stack buffer: the result
///! is boxed into a Value immediately after `implFn` returns, by which
///! point a local buffer's storage is already gone. (The hand-written
///! `zig_v2_hello` example in duckdb_v2_dynamic.zig sidesteps this by building and
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
///!   name). Also supported as a *return* type (one level deep, same
///!   restriction as arguments): each field is written into its own child
///!   vector via `vectorGetChild(result_vec, field_index, ...)` — numeric/
///!   bool fields through a cached flat buffer, `[]const u8` fields boxed
///!   through `valueCreateVarcharWithContext`/`vectorSetValue` on that
///!   field's own child vector — mirroring the plain (non-struct) return
///!   path's two writing conventions, just addressed at the child vector
///!   instead of `result_vec` itself. A STRUCT return is never itself NULL
///!   (no `?T` return convention for structs here) — `vectorSetNull` only
///!   fires for an invalid argument, and the v2 header confirms this
///!   already cascades NULL to every nested child automatically
///!   (`vector_set_null`'s own doc comment: "broadcasts the NULL
///!   recursively to every descendant element under that row"), so no
///!   extra per-field NULL-ing is needed there either.
///! - `v2.duckdb_v2_value_handle` as a parameter or return type maps to SQL VARIANT:
///!   `implFn` receives/returns a boxed `Value` directly rather than a
///!   decoded Zig value, since VARIANT's dynamic, runtime-chosen content
///!   type has no single Zig type to decode into. Unlike every other
///!   parameter type, a VARIANT argument does NOT participate in the
///!   automatic "any NULL argument skips the row" convention — SQL NULL is
///!   ordinary data VARIANT can hold, not an absent argument, so `implFn`
///!   always runs and decides what NULL means itself, via ``v2.duckdb_v2_value_is_null``
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
///! - `[]const T` (T a numeric/bool leaf type, excluding `[]const u8` —
///!   that's VARCHAR, unchanged) maps to SQL LIST(T); `[N]T` maps to
///!   ARRAY(T, N). Scoped to flat leaf element types only (not nested
///!   STRUCT/DECIMAL/ENUM/VARIANT/another LIST, and not `[]const u8`
///!   elements — all deferred). A LIST argument decodes
///!   zero-copy (a real slice into the flattened child vector, sliced via
///!   the parent's own `ListEntry{offset,length}` per row); an ARRAY
///!   argument likewise, strided by its fixed length. Returns box each
///!   element through the matching `value_create_*` leaf constructor and
///!   `valueCreateListWithContext`/`valueCreateArrayWithContext` — the
///!   same "simpler, if slower" tradeoff already accepted for VARCHAR/
///!   BLOB/STRUCT-VARCHAR-field returns, not a direct child-vector write
///!   (which would need cumulative per-row offset bookkeeping across the
///!   whole batch). A LIST return is capped at a fixed max length per
///!   row (a query error past it, not silent truncation); ARRAY needs no
///!   such cap, since its length is fixed and comptime-known. CAUTION:
///!   individual elements inside a non-NULL LIST/ARRAY row are NOT
///!   checked for their own NULL-ness, only the LIST/ARRAY row itself —
///!   confirmed live that a NULL element decodes as uninitialized
///!   garbage, not a crash, but also not a meaningful value; a future
///!   addition, not attempted here. Can't be combined with STRUCT/
///!   VARIANT parameters/return in the same function yet (compile error).
///! - `Map(K, V)` (a dedicated wrapper type — Zig has no built-in
///!   parallel-key/value-array shape — wrapping `entries: []const
///!   Entry{key,value}`) maps to SQL MAP(K, V), K/V scoped to the same
///!   flat leaf set LIST/ARRAY elements use. Argument decode zips each
///!   row's parallel key/value flat arrays (addressed via the parent
///!   MAP vector's own `ListEntry{offset,length}`, since MAP is
///!   physically LIST(STRUCT(key,value)) internally) into a bounded
///!   per-row stack buffer — not zero-copy like LIST, since
///!   `Entry{key,value}` is an array of structs but the source storage
///!   is two parallel flat arrays; entries past the cap are silently
///!   truncated (documented, not an error). Returns box through
///!   `valueCreateMapWithContext` (parallel key/value `Value` arrays),
///!   capped the same way LIST returns are (a query error past the cap).
///! - A plain Zig tagged union (`union(enum) { ... }`) maps to SQL
///!   UNION(name1 type1, ...) directly — Zig's native tagged union is
///!   already a 1:1 match, no wrapper type needed (unlike MAP). Member
///!   types scoped to the same flat leaf set as STRUCT fields (numeric/
///!   bool/`[]const u8`, one level deep) — reuses that machinery, since
///!   UNION's child-vector-per-member layout is directly analogous to
///!   STRUCT's child-vector-per-field layout. CAUTION: there is no
///!   `duckdb_v2_value_create_union_*` constructor at all (confirmed by
///!   grepping the header) — writes go directly into the tag child's
///!   flat buffer plus the active member's own child vector, never
///!   through a boxed whole-UNION `Value`. CAUTION, confirmed live (a
///!   real bug, since fixed): every member's child vector at a given
///!   row — not just the active one — must be given a well-defined
///!   value; leaving an *inactive* member's row untouched worked fine
///!   across a mixed-tag batch when every member was a flat numeric
///!   type, but segfaulted as soon as one member was VARCHAR (a
///!   leftover, never-initialized `duckdb_v2_string_t` apparently gets
///!   read by something downstream regardless of that row's own active
///!   tag) — fixed by explicitly `vectorSetNull`-ing every inactive
///!   member's row rather than leaving it alone. Can't be combined with
///!   STRUCT/VARIANT/LIST/ARRAY/the other of MAP or UNION in the same
///!   function yet (compile error).
///!
///! An `implFn` may return `E!T` (T a number, Date/Time/Timestamp, Interval, DECIMAL, ENUM, VARCHAR or
///! BLOB; not a nested type or VARIANT yet): an error ends the query with "<function name>:
///! <error name>", as out-of-range input for `error.Overflow` (e.g. `std.math.add`) and as invalid
///! input for any other error. NULL arguments never reach `implFn`, so they cannot cause one.
///!
///! Bindings: the framework calls DuckDB through the generated bindings
///! (`duckdb_v2_dynamic`, plus the helpers in `v2_helpers.zig`). A user function takes and returns
///! the generated handles (`v2.duckdb_v2_context_handle`, `v2.duckdb_v2_value_handle`) and the
///! value types `v2_values.Interval`, `v2_values.Date`/`Time`/`Timestamp`, `v2_values.Blob`, `v2_values.Decimal`.
///!
///! Usage:
///!   const MyFn = comptime_scalar_v2.Function("my_double", struct {
///!       fn eval(a: i64) i64 { return a * 2; }
///!   }.eval);
///!   try MyFn.register(input); // input: *const v2.duckdb_v2_extension_input
const std = @import("std");
const v2_values = @import("v2_values");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const UserContext = v2.duckdb_v2_context_handle;
const UserValue = v2.duckdb_v2_value_handle;

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
        UserValue => .LOGICAL_TYPE_ID_VARIANT,
        v2_values.Blob => .LOGICAL_TYPE_ID_BLOB,
        v2_values.Date => .LOGICAL_TYPE_ID_DATE,
        v2_values.Time => .LOGICAL_TYPE_ID_TIME,
        v2_values.Timestamp => .LOGICAL_TYPE_ID_TIMESTAMP,
        v2_values.Interval => .LOGICAL_TYPE_ID_INTERVAL,
        else => @compileError("unsupported type for DuckDB v2 mapping: " ++ @typeName(T)),
    };
}

fn isDecimalType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "v2_decimal_width");
}

fn isEnumType(comptime T: type) bool {
    // v2_values.Date/v2_values.Time/v2_values.Timestamp are themselves non-exhaustive enums
    // (a zero-cost way to get a distinct type with the same layout as
    // their backing int — see duckdb_v2_dynamic.zig's doc comment on them), not
    // SQL ENUMs, so they must be excluded here the same way Blob/Decimal
    // are excluded from isStructType. Found live: without this, building
    // a v2_values.Timestamp's logical type tried `enumSqlText(v2_values.Timestamp)` —
    // an empty dictionary, since the enum has no named fields — and
    // segfaulted DuckDB's own `context_create_type_from_text`.
    if (T == v2_values.Date or T == v2_values.Time or T == v2_values.Timestamp) return false;
    return @typeInfo(T) == .@"enum";
}

/// LIST(elem_type): a plain Zig slice, excluding `[]const u8` (reserved for
/// VARCHAR, matching the plain non-nested parameter/return path's existing
/// convention). Scoped to a flat leaf element type only (the same numeric/
/// bool set `duckdbV2TypeId` maps directly) — not STRUCT/DECIMAL/ENUM/
/// VARIANT/another LIST elements, and not `[]const u8` elements either, all
/// deferred (see this file's module doc comment).
fn isListType(comptime T: type) bool {
    if (T == []const u8) return false;
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice and info.pointer.attrs.@"const";
}

fn ListElem(comptime T: type) type {
    return @typeInfo(T).pointer.child;
}

/// ARRAY(elem_type, size): a fixed-size Zig array, same element-type scope
/// as `isListType`.
fn isArrayType(comptime T: type) bool {
    return @typeInfo(T) == .array;
}

fn ArrayElem(comptime T: type) type {
    return @typeInfo(T).array.child;
}

fn ArrayLen(comptime T: type) usize {
    return @typeInfo(T).array.len;
}

fn isSupportedListArrayElem(comptime T: type) bool {
    return switch (T) {
        i8, i16, i32, i64, f32, f64, bool => true,
        else => false,
    };
}

const isSupportedMapKV = isSupportedListArrayElem;

fn isSupportedUnionMember(comptime T: type) bool {
    return T == []const u8 or isSupportedListArrayElem(T);
}

fn isStructType(comptime T: type) bool {
    // v2_values.Blob and v2_values.Decimal(w,s) are Zig structs (wrapping a []const u8
    // and a raw storage int, respectively) but must never be treated as a
    // one-field SQL STRUCT — each has its own dedicated decode/encode path
    // instead (see the `return_is_blob`/`return_is_decimal` branches
    // below). Map(K,V) (wrapping `entries: []const Entry`) is excluded
    // the same way.
    if (T == v2_values.Blob) return false;
    if (comptime isDecimalType(T)) return false;
    if (comptime isMapType(T)) return false;
    return @typeInfo(T) == .@"struct";
}

/// MAP(key_type, value_type): `v2_values.Map(K, V)`, a dedicated wrapper type
/// (Zig has no built-in parallel-key/value-array shape) wrapping a flat
/// `entries: []const Entry` slice. K/V scoped to the same flat leaf set
/// `isSupportedListArrayElem` already uses — not `[]const u8`, not
/// nested STRUCT/DECIMAL/ENUM/VARIANT/LIST/ARRAY/another MAP — matching
/// LIST/ARRAY's own element-type restriction (reusing that same read
/// path's flat-buffer convention, not the STRUCT-field path's
/// per-field/`[]const u8` support).
pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        pub const v2_map_key = K;
        pub const v2_map_value = V;
        pub const Entry = struct { key: K, value: V };
        entries: []const Entry,
    };
}

fn isMapType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "v2_map_key") and @hasDecl(T, "v2_map_value");
}

fn MapKey(comptime T: type) type {
    return T.v2_map_key;
}

fn MapValue(comptime T: type) type {
    return T.v2_map_value;
}

/// UNION(names[0] member_types[0], ...): a plain Zig tagged union —
/// Zig's native tagged union is a genuine 1:1 match for SQL UNION, no
/// wrapper type needed (unlike MAP). Member types scoped to the same
/// flat leaf set as STRUCT fields (numeric/bool/`[]const u8`, one level
/// deep) — reuses that machinery, since UNION's child-vector-per-member
/// layout is directly analogous to STRUCT's child-vector-per-field
/// layout. CAUTION: there is no `duckdb_v2_value_create_union_*`
/// constructor at all (confirmed by grepping the header) — UNION return
/// writes go directly into each member's own child vector
/// (`vectorGetDataMutable`/boxed-per-row VARCHAR), never through a
/// boxed whole-UNION `Value`.
fn isUnionType(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type != null;
}

/// Build "ENUM('member0','member1',...)" from a Zig enum's own variant
/// names, for `contextCreateTypeFromText` — mirrors
/// `comptime_appender_v2.zig`'s `enumSqlText`.
fn enumSqlText(comptime T: type) []const u8 {
    const info = @typeInfo(T).@"enum";
    comptime var text: []const u8 = "ENUM(";
    inline for (info.field_names, 0..) |name_, i| {
        if (i > 0) text = text ++ ",";
        text = text ++ "'" ++ name_ ++ "'";
    }
    return text ++ ")";
}

/// Build the logical type for a plain (non-struct) Zig type T. VARIANT
/// goes through `contextCreateTypeFromText` instead of
/// `contextCreateTypeFromId` — see that function's doc comment for why.
fn createLogicalType(ctx: v2.duckdb_v2_context_handle, comptime T: type, out_type: *v2.duckdb_v2_logical_type_handle, err: *v2.duckdb_v2_error_info_handle) v2.DUCKDB_V2_ERROR {
    if (comptime T == UserValue) {
        return helpers.createTypeFromText(ctx, "VARIANT", out_type, err);
    }
    if (comptime isDecimalType(T)) {
        return helpers.createDecimalType(ctx, T.v2_decimal_width, T.v2_decimal_scale, out_type, err);
    }
    if (comptime isEnumType(T)) {
        return helpers.createTypeFromText(ctx, comptime enumSqlText(T), out_type, err);
    }
    if (comptime isListType(T)) {
        const Elem = ListElem(T);
        if (!comptime isSupportedListArrayElem(Elem)) {
            @compileError("unsupported LIST element type for DuckDB v2 mapping: " ++ @typeName(Elem));
        }
        var elem_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (createLogicalType(ctx, Elem, &elem_type, err) != .ERROR_NONE) {
            return .ERROR_API;
        }
        defer _ = v2.duckdb_v2_logical_type_destroy(&elem_type);
        return helpers.createListType(ctx, elem_type, out_type, err);
    }
    if (comptime isArrayType(T)) {
        const Elem = ArrayElem(T);
        if (!comptime isSupportedListArrayElem(Elem)) {
            @compileError("unsupported ARRAY element type for DuckDB v2 mapping: " ++ @typeName(Elem));
        }
        var elem_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (createLogicalType(ctx, Elem, &elem_type, err) != .ERROR_NONE) {
            return .ERROR_API;
        }
        defer _ = v2.duckdb_v2_logical_type_destroy(&elem_type);
        return helpers.createArrayType(ctx, elem_type, @intCast(ArrayLen(T)), out_type, err);
    }
    if (comptime isMapType(T)) {
        const K = MapKey(T);
        const V = MapValue(T);
        if (!comptime isSupportedMapKV(K)) {
            @compileError("unsupported MAP key type for DuckDB v2 mapping: " ++ @typeName(K));
        }
        if (!comptime isSupportedMapKV(V)) {
            @compileError("unsupported MAP value type for DuckDB v2 mapping: " ++ @typeName(V));
        }
        var key_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (createLogicalType(ctx, K, &key_type, err) != .ERROR_NONE) {
            return .ERROR_API;
        }
        defer _ = v2.duckdb_v2_logical_type_destroy(&key_type);
        var value_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (createLogicalType(ctx, V, &value_type, err) != .ERROR_NONE) {
            return .ERROR_API;
        }
        defer _ = v2.duckdb_v2_logical_type_destroy(&value_type);
        return helpers.createMapType(ctx, key_type, value_type, out_type, err);
    }
    if (comptime isUnionType(T)) {
        const info = @typeInfo(T).@"union";
        const n = info.field_types.len;
        inline for (0..n) |f| {
            if (!comptime isSupportedUnionMember(info.field_types[f])) {
                @compileError("unsupported UNION member type for DuckDB v2 mapping: " ++ @typeName(info.field_types[f]));
            }
        }
        var member_logical_types: [n]v2.duckdb_v2_logical_type_handle = undefined;
        inline for (0..n) |f| {
            if (createLogicalType(ctx, info.field_types[f], &member_logical_types[f], err) != .ERROR_NONE) {
                return .ERROR_API;
            }
        }
        defer inline for (0..n) |f| {
            _ = v2.duckdb_v2_logical_type_destroy(&member_logical_types[f]);
        };
        var names: [n]v2.duckdb_v2_identifier_t = undefined;
        inline for (0..n) |f| names[f] = helpers.str(info.field_names[f]);
        var member_type_values: [n]v2.duckdb_v2_value_handle = undefined;
        const rc = helpers.createUnionType(ctx, &names, &member_logical_types, &member_type_values, out_type, err);
        defer inline for (0..n) |f| {
            _ = v2.duckdb_v2_value_destroy(&member_type_values[f]);
        };
        return rc;
    }
    if (comptime isStructType(T)) {
        const fields = @typeInfo(T).@"struct";
        const n = fields.field_types.len;
        var field_logical_types: [n]v2.duckdb_v2_logical_type_handle = undefined;
        inline for (0..n) |f| {
            if (createLogicalType(ctx, fields.field_types[f], &field_logical_types[f], err) != .ERROR_NONE) {
                return .ERROR_API;
            }
        }
        defer inline for (0..n) |f| {
            _ = v2.duckdb_v2_logical_type_destroy(&field_logical_types[f]);
        };
        var field_names: [n]v2.duckdb_v2_identifier_t = undefined;
        inline for (0..n) |f| field_names[f] = helpers.str(fields.field_names[f]);
        var field_type_values: [n]v2.duckdb_v2_value_handle = undefined;
        const rc = helpers.createStructType(ctx, &field_names, &field_logical_types, &field_type_values, out_type, err);
        defer inline for (0..n) |f| {
            _ = v2.duckdb_v2_value_destroy(&field_type_values[f]);
        };
        return rc;
    }
    return helpers.createTypeFromId(ctx, duckdbV2TypeId(T), out_type, err);
}

/// Define a v2 DuckDB scalar function from a comptime-known Zig function,
/// with synthesized `a0`/`a1`/... SQL parameter names (Zig function
/// parameters carry no names at the ABI level — confirmed live:
/// `SELECT parameters FROM duckdb_functions() WHERE function_name =
/// 'ct_add_numbers'` showed exactly that, the anti-pattern
/// posit-dev/ggsql-duckdb#16 flags). Use `FunctionNamed` instead for real
/// parameter names; see its doc comment. A separate function rather than
/// an optional argument here, since Zig has no default-parameter-value
/// syntax to keep this call site unchanged for every existing caller.
pub fn Function(comptime name: [:0]const u8, comptime implFn: anytype) type {
    return FunctionImpl(name, implFn, null);
}

/// Like `Function`, but `param_names` supplies the SQL parameter names in
/// order instead of synthesizing `a0`/`a1`/.... Hand-registered v2
/// functions (`functionSignatureAddParameter` called directly) already
/// get real names for free; this closes the same gap for comptime-
/// registered ones. Must have exactly one name per SQL parameter (not
/// counting a leading VARIANT `context` parameter, which isn't a SQL
/// parameter at all).
pub fn FunctionNamed(comptime name: [:0]const u8, comptime implFn: anytype, comptime param_names: []const [:0]const u8) type {
    return FunctionImpl(name, implFn, param_names);
}

fn FunctionImpl(comptime name: [:0]const u8, comptime implFn: anytype, comptime param_names: ?[]const [:0]const u8) type {
    const fn_info = @typeInfo(@TypeOf(implFn)).@"fn";
    const raw_param_types = fn_info.param_types;
    // `implFn` may return `E!T`: on an error the query fails (see `reportError`). Only the paths
    // that write a leaf, VARCHAR, BLOB, DECIMAL or ENUM result support it.
    const RawReturnType = fn_info.return_type.?;
    const returns_error = @typeInfo(RawReturnType) == .error_union;
    const ReturnType = if (returns_error) @typeInfo(RawReturnType).error_union.payload else RawReturnType;

    const return_is_variant = ReturnType == UserValue;
    const raw_has_variant_arg = blk: {
        inline for (raw_param_types) |t| {
            if (t.? == UserValue) break :blk true;
        }
        break :blk false;
    };
    const needs_context = return_is_variant or raw_has_variant_arg;
    if (needs_context and (raw_param_types.len == 0 or raw_param_types[0].? != UserContext)) {
        @compileError("a VARIANT-involving Function's implFn must take `context: v2.duckdb_v2_context_handle` as its first parameter");
    }
    const param_types = if (needs_context) raw_param_types[1..] else raw_param_types;
    if (param_names) |names| {
        if (names.len != param_types.len) {
            @compileError(std.fmt.comptimePrint(
                "FunctionNamed(\"{s}\", ...): param_names has {d} entries but implFn takes {d} SQL parameters",
                .{ name, names.len, param_types.len },
            ));
        }
    }

    inline for (param_types) |t| {
        if (comptime !isStructType(t.?) and !isDecimalType(t.?) and !isEnumType(t.?) and !isListType(t.?) and !isArrayType(t.?) and !isMapType(t.?) and !isUnionType(t.?)) _ = duckdbV2TypeId(t.?);
    }
    if (comptime !isStructType(ReturnType) and !isDecimalType(ReturnType) and !isEnumType(ReturnType) and !isListType(ReturnType) and !isArrayType(ReturnType) and !isMapType(ReturnType) and !isUnionType(ReturnType)) _ = duckdbV2TypeId(ReturnType);

    const has_variant_arg = raw_has_variant_arg;
    const return_is_decimal = isDecimalType(ReturnType);
    const return_is_enum = isEnumType(ReturnType);
    const return_is_struct = isStructType(ReturnType);
    const return_is_list = isListType(ReturnType);
    const return_is_array = isArrayType(ReturnType);
    const return_is_map = isMapType(ReturnType);
    const return_is_union = isUnionType(ReturnType);
    const has_struct_arg = blk: {
        inline for (param_types) |t| {
            if (comptime isStructType(t.?)) break :blk true;
        }
        break :blk false;
    };
    const has_list_or_array_arg = blk: {
        inline for (param_types) |t| {
            if (comptime isListType(t.?) or isArrayType(t.?)) break :blk true;
        }
        break :blk false;
    };
    const has_list_or_array = has_list_or_array_arg or return_is_list or return_is_array;
    const has_map_arg = blk: {
        inline for (param_types) |t| {
            if (comptime isMapType(t.?)) break :blk true;
        }
        break :blk false;
    };
    const has_map = has_map_arg or return_is_map;
    const has_union_arg = blk: {
        inline for (param_types) |t| {
            if (comptime isUnionType(t.?)) break :blk true;
        }
        break :blk false;
    };
    const has_union = has_union_arg or return_is_union;
    if (returns_error and (has_variant_arg or return_is_variant or has_struct_arg or return_is_struct or has_list_or_array or has_map or has_union)) {
        @compileError("a Function returning an error union can't take or return VARIANT/STRUCT/LIST/ARRAY/MAP/UNION yet");
    }
    if (has_list_or_array and (has_variant_arg or return_is_variant or has_struct_arg or return_is_struct)) {
        @compileError("a Function can't mix LIST/ARRAY with STRUCT or VARIANT parameters/return in the same function yet");
    }
    if (has_map and (has_variant_arg or return_is_variant or has_struct_arg or return_is_struct or has_list_or_array or has_union)) {
        @compileError("a Function can't mix MAP with STRUCT/VARIANT/LIST/ARRAY/UNION parameters/return in the same function yet");
    }
    if (has_union and (has_variant_arg or return_is_variant or has_struct_arg or return_is_struct or has_list_or_array or has_map)) {
        @compileError("a Function can't mix UNION with STRUCT/VARIANT/LIST/ARRAY/MAP parameters/return in the same function yet");
    }

    return struct {
        /// Register this scalar function against the extension being loaded.
        /// Must be called from inside the v2 extension entrypoint, which is
        /// handed both an `extension` handle (to create the function) and a
        /// `context` handle (to create logical types — v2 has no
        /// handle-less type constructor).
        pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
            // Start from DuckDB's own slot: a failing call fills in an existing error info and writes through a
            // non-NULL slot as it finds it, so an uninitialised local would crash at the first failure, and a
            // failure reports its reason to the load this way.
            var err = (input.err orelse return error.MissingErrorSlot).*;

            var function: v2.duckdb_v2_scalar_function_handle = undefined;
            if (v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, &err) != .ERROR_NONE) {
                return error.FailedToCreateFunction;
            }
            defer _ = v2.duckdb_v2_scalar_function_destroy(&function);

            const fn_name = helpers.str(name);
            if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, &err) != .ERROR_NONE) {
                return error.FailedToSetName;
            }

            var sig: v2.duckdb_v2_function_signature_handle = undefined;
            if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, &err) != .ERROR_NONE) {
                return error.FailedToGetSignature;
            }

            inline for (param_types, 0..) |t, i| {
                const T = t.?;
                var param_type: v2.duckdb_v2_logical_type_handle = undefined;
                if (createLogicalType(input.context, T, &param_type, &err) != .ERROR_NONE) {
                    return error.FailedToCreateParamType;
                }
                defer _ = v2.duckdb_v2_logical_type_destroy(&param_type);

                // Real names from `FunctionNamed`, or synthesized
                // positional ones ("a0", "a1", ...) — see `Function`'s
                // doc comment on why Zig function parameters have no
                // names of their own to use here.
                const param_name_buf = if (param_names) |names| names[i] else std.fmt.comptimePrint("a{d}", .{i});
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

            var return_type: v2.duckdb_v2_logical_type_handle = undefined;
            if (createLogicalType(input.context, ReturnType, &return_type, &err) != .ERROR_NONE) {
                return error.FailedToCreateReturnType;
            }
            defer _ = v2.duckdb_v2_logical_type_destroy(&return_type);
            if (v2.duckdb_v2_function_signature_set_return_type(sig, return_type, &err) != .ERROR_NONE) {
                return error.FailedToSetReturnType;
            }

            if (v2.duckdb_v2_scalar_function_set_exec_callback(function, execute, &err) != .ERROR_NONE) {
                return error.FailedToSetExecCallback;
            }

            if (comptime has_variant_arg) {
                if (helpers.setNullHandlingSpecial(function, &err) != .ERROR_NONE) {
                    return error.FailedToSetNullHandling;
                }
            }

            if (v2.duckdb_v2_scalar_function_register(function, &err) != .ERROR_NONE) {
                return error.FailedToRegisterFunction;
            }
        }

        const return_is_varchar = ReturnType == []const u8;
        const return_is_blob = ReturnType == v2_values.Blob;
        const WriteType = if (return_is_decimal) ReturnType.Raw else ReturnType;

        /// Vectorized exec callback invoked by DuckDB for each batch of rows.
        fn execute(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
            var row_count: u64 = 0;
            if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;

            var result_vec: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result_vec, err) != .ERROR_NONE) return;
            if (v2.duckdb_v2_vector_set_size(result_vec, row_count, err) != .ERROR_NONE) return;

            if (comptime has_variant_arg or return_is_variant) {
                return executeDynamic(info, context, result_vec, row_count, err);
            }
            if (comptime has_struct_arg or return_is_struct) {
                return executeStruct(info, context, result_vec, row_count, err);
            }
            if (comptime has_list_or_array) {
                return executeListArray(info, context, result_vec, row_count, err);
            }
            if (comptime has_map) {
                return executeMap(info, context, result_vec, row_count, err);
            }
            if (comptime has_union) {
                return executeUnion(info, context, result_vec, row_count, err);
            }

            // Cache each argument's view (flattened first — sequence/FSST/
            // dictionary-encoded args aren't directly readable otherwise,
            // see duckdb_v2_dynamic.zig's `duckdb_v2_vector_flatten` doc comment).
            var views: [param_types.len]v2.duckdb_v2_vector_view = undefined;
            inline for (0..param_types.len) |i| {
                var arg_vec: v2.duckdb_v2_vector_handle = undefined;
                if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &arg_vec, err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_flatten(arg_vec, err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_get_view(arg_vec, &views[i], err) != .ERROR_NONE) return;
            }

            var has_nulls = false;
            inline for (0..param_types.len) |i| {
                if (views[i].validity != null) has_nulls = true;
            }

            // VARCHAR/BLOB results can't be written through a flat typed
            // buffer (variable width) — each row boxes through a Value
            // instead, via duckdb_v2_dynamic.zig's `duckdb_v2_value_create_varchar_with_context`/
            // valueCreateBlobWithContext + vectorSetValue.
            if (comptime return_is_varchar or return_is_blob) {
                var row: u64 = 0;
                while (row < row_count) : (row += 1) {
                    if (has_nulls and !rowIsValid(&views, row)) {
                        if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                        continue;
                    }
                    const produced = call(&views, row, err) orelse return;
                    const bytes = if (comptime return_is_blob) produced.bytes else produced;
                    var value: v2.duckdb_v2_value_handle = undefined;
                    const create_err = if (comptime return_is_blob)
                        helpers.createBlobValue(context, bytes, &value, err)
                    else
                        helpers.createVarcharValue(context, bytes, &value, err);
                    if (create_err != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                }
                return;
            }

            // ENUM has no `value_create_enum_*` constructor (confirmed by
            // grepping the header, same finding `comptime_appender_v2.zig`
            // made) — box the tag name as VARCHAR, then cast it to the
            // result vector's own ENUM type, the way `'a'::my_enum` works
            // in SQL.
            if (comptime return_is_enum) {
                var result_type: v2.duckdb_v2_logical_type_handle = undefined;
                if (v2.duckdb_v2_vector_get_logical_type(result_vec, &result_type, err) != .ERROR_NONE) return;
                defer _ = v2.duckdb_v2_logical_type_destroy(&result_type);

                var row: u64 = 0;
                while (row < row_count) : (row += 1) {
                    if (has_nulls and !rowIsValid(&views, row)) {
                        if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                        continue;
                    }
                    const produced = call(&views, row, err) orelse return;
                    var text_value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createVarcharValue(context, @tagName(produced), &text_value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&text_value);
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (v2.duckdb_v2_value_cast_with_context(context, text_value, result_type, &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                }
                return;
            }

            // DECIMAL is a typed leaf array in vector storage, same as any
            // numeric type, once its width's storage int is picked (see
            // `v2_values.Decimal`'s doc comment) — written through the flat
            // buffer below, same as any other non-variable-width return,
            // just unwrapping `.raw` first via `writeResult`.
            var out_data: ?*anyopaque = null;
            if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
            // SAFETY: types were validated at comptime against the registered signature.
            const result: [*]WriteType = @ptrCast(@alignCast(out_data));

            if (has_nulls) {
                var row: u64 = 0;
                while (row < row_count) : (row += 1) {
                    if (rowIsValid(&views, row)) {
                        result[row] = writeResult(&views, row, err) orelse return;
                    } else {
                        if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                    }
                }
            } else {
                var row: u64 = 0;
                while (row < row_count) : (row += 1) {
                    result[row] = writeResult(&views, row, err) orelse return;
                }
            }
        }

        inline fn writeResult(views: *const [param_types.len]v2.duckdb_v2_vector_view, row: u64, err: *v2.duckdb_v2_error_info_handle) ?WriteType {
            const v = call(views, row, err) orelse return null;
            return if (comptime return_is_decimal) v.raw else v;
        }

        inline fn rowIsValid(views: *const [param_types.len]v2.duckdb_v2_vector_view, row: u64) bool {
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

        /// `invoke`, with an error of `implFn` reported as the error of the query: null means the
        /// caller must stop (DuckDB fails the query, whatever else is written).
        inline fn call(views: *const [param_types.len]v2.duckdb_v2_vector_view, row: u64, err: *v2.duckdb_v2_error_info_handle) ?ReturnType {
            const produced = invoke(views, row);
            if (comptime !returns_error) return produced;
            return produced catch |e| {
                reportError(err, e);
                return null;
            };
        }

        /// Makes `e` the error of the query: `error.Overflow` is out-of-range
        /// input, any other error is invalid input, and the text is "<function name>: <error name>".
        fn reportError(err: *v2.duckdb_v2_error_info_handle, e: anyerror) void {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ name, @errorName(e) }) catch name;
            const text = helpers.str(msg);
            const code: v2.DUCKDB_V2_ERROR = if (e == error.Overflow) .ERROR_INPUT_OUT_OF_RANGE else .ERROR_INPUT_INVALID;
            // There is nowhere to report a failure to report: DuckDB fails the query either way.
            _ = v2.duckdb_v2_error_info_set_code(err.*, code);
            _ = v2.duckdb_v2_error_info_set_text(err.*, &text);
        }

        inline fn invoke(views: *const [param_types.len]v2.duckdb_v2_vector_view, row: u64) RawReturnType {
            var args: ArgsTuple = undefined;
            inline for (0..param_types.len) |i| {
                const T = param_types[i].?;
                if (T == []const u8) {
                    // SAFETY: views[i].data points to a flattened VARCHAR vector's
                    // duckdb_v2_bytes elements (the signature registered this param as VARCHAR).
                    const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = helpers.bytesSlice(&typed[row]);
                } else if (T == v2_values.Blob) {
                    // SAFETY: same duckdb_v2_bytes storage shape as VARCHAR,
                    // registered as BLOB instead (see duckdbV2TypeId).
                    const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = .{ .bytes = helpers.bytesSlice(&typed[row]) };
                } else if (comptime isDecimalType(T)) {
                    // SAFETY: DECIMAL is a typed leaf array over T.Raw, per
                    // v2_values.Decimal's own doc comment.
                    const typed: [*]const T.Raw = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = .{ .raw = typed[row] };
                } else if (comptime isEnumType(T)) {
                    args[i] = decodeEnumArg(T, views.*[i], row);
                } else {
                    // SAFETY: views[i].data points to a flattened, type-matched vector buffer.
                    const typed: [*]const T = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = typed[row];
                }
            }
            return @call(.auto, implFn, args);
        }

        /// Decode an ENUM argument: its vector storage is the dictionary
        /// ordinal as a uint8/uint16/uint32 (size picked by the dictionary's
        /// size, per `vector_get_view`'s own doc comment), which maps back
        /// to a Zig enum value via the enum's own `field_values` in
        /// declaration order — the same order `enumSqlText` built the SQL
        /// `ENUM(...)` dictionary in — rather than assuming
        /// `@enumFromInt(ordinal)`, so a manually-numbered Zig enum still
        /// decodes correctly.
        inline fn decodeEnumArg(comptime T: type, view: v2.duckdb_v2_vector_view, row: u64) T {
            const info = @typeInfo(T).@"enum";
            const n = info.field_values.len;
            const StorageT = if (n <= 255) u8 else if (n <= 65535) u16 else u32;
            const dict_values = comptime blk: {
                var vals: [n]std.meta.Tag(T) = undefined;
                for (info.field_values, 0..) |v, idx| vals[idx] = @intCast(v);
                break :blk vals;
            };
            // SAFETY: views[i].data points to a flattened ENUM vector's
            // dictionary-ordinal array, width chosen by dictionary size.
            const typed: [*]const StorageT = @ptrCast(@alignCast(view.data));
            return @fromBackingInt(@intCast(dict_values[typed[row]]));
        }

        /// Dedicated exec path for any VARIANT argument or return type.
        /// VARIANT has no committed view layout (no `vectorGetView` support)
        /// — each VARIANT cell is read/written one at a time as a boxed
        /// `Value` via `vectorGetValue`/`vectorSetValue` instead, so this
        /// path skips the shared view-caching machinery entirely rather
        /// than bolting VARIANT's row-by-row shape onto it.
        fn executeDynamic(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, result_vec: v2.duckdb_v2_vector_handle, row_count: u64, err: *v2.duckdb_v2_error_info_handle) void {
            var arg_vecs: [param_types.len]v2.duckdb_v2_vector_handle = undefined;
            var views: [param_types.len]v2.duckdb_v2_vector_view = undefined;
            inline for (0..param_types.len) |i| {
                if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &arg_vecs[i], err) != .ERROR_NONE) return;
                if (comptime param_types[i].? != UserValue) {
                    if (v2.duckdb_v2_vector_flatten(arg_vecs[i], err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_get_view(arg_vecs[i], &views[i], err) != .ERROR_NONE) return;
                }
            }

            var out: [*]ReturnType = undefined;
            if (comptime !return_is_variant and !return_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                var args: ArgsTuple = undefined;
                var fetched: [param_types.len]?v2.duckdb_v2_value_handle = undefined;
                inline for (0..param_types.len) |i| fetched[i] = null;
                var row_valid = true;

                inline for (0..param_types.len) |i| {
                    const T = param_types[i].?;
                    if (comptime T == UserValue) {
                        // Deliberately does NOT participate in the automatic
                        // NULL-skip every other type gets: VARIANT's NULL is
                        // ordinary data (SQL NULL is a value VARIANT can
                        // hold), not an absent argument, so implFn decides
                        // what it means — calling `valueIsNull` itself if it
                        // cares, same as `zig_v2_variant_default_ct` does.
                        var value: v2.duckdb_v2_value_handle = undefined;
                        if (v2.duckdb_v2_vector_get_value(arg_vecs[i], row, &value, err) != .ERROR_NONE) return;
                        fetched[i] = value;
                        args[i] = value;
                    } else {
                        if (views[i].validity) |validity| {
                            const entry_idx = row / 64;
                            const bit_idx: u6 = @intCast(row % 64);
                            if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) row_valid = false;
                        }
                        if (comptime T == []const u8) {
                            const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views[i].data));
                            args[i] = helpers.bytesSlice(&typed[row]);
                        } else {
                            const typed: [*]const T = @ptrCast(@alignCast(views[i].data));
                            args[i] = typed[row];
                        }
                    }
                }

                defer inline for (0..param_types.len) |i| {
                    if (comptime param_types[i].? == UserValue) {
                        if (fetched[i]) |v| {
                            var vv = v;
                            _ = v2.duckdb_v2_value_destroy(&vv);
                        }
                    }
                };

                if (!row_valid) {
                    if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                    continue;
                }

                // executeDynamic only runs when needs_context is true (see
                // the branch in `execute`), so implFn always takes context first.
                const result = @call(.auto, implFn, .{context} ++ args);
                if (comptime return_is_variant) {
                    var rv = result;
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, rv, err) != .ERROR_NONE) return;
                    _ = v2.duckdb_v2_value_destroy(&rv);
                } else if (comptime return_is_varchar) {
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createVarcharValue(context, result, &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                } else {
                    out[row] = result;
                }
            }
        }

        fn StructFieldCount(comptime T: type) usize {
            return @typeInfo(T).@"struct".field_types.len;
        }

        fn ViewsFor(comptime T: type) type {
            return if (comptime isStructType(T)) [StructFieldCount(T)]v2.duckdb_v2_vector_view else v2.duckdb_v2_vector_view;
        }

        fn MakeViewsTuple() type {
            var types: [param_types.len]type = undefined;
            for (0..param_types.len) |i| types[i] = ViewsFor(param_types[i].?);
            return @Tuple(&types);
        }
        const ViewsTuple = MakeViewsTuple();

        /// A field's write handle: a cached flat-buffer pointer for a
        /// numeric/bool field, or the field's own child `VectorHandle` for
        /// `[]const u8` (boxed through `vectorSetValue` per row instead,
        /// same as the plain return path does at the top level).
        fn StructFieldWriteHandle(comptime FT: type) type {
            return if (FT == []const u8) v2.duckdb_v2_vector_handle else [*]FT;
        }
        fn MakeReturnChildPtrsTuple() type {
            if (comptime !return_is_struct) return void;
            const fields = @typeInfo(ReturnType).@"struct";
            var types: [fields.field_types.len]type = undefined;
            for (fields.field_types, 0..) |ft, i| types[i] = StructFieldWriteHandle(ft);
            return @Tuple(&types);
        }
        const ReturnChildPtrsTuple = MakeReturnChildPtrsTuple();

        /// Writes each field of a STRUCT return value into `result_vec`'s
        /// own child vectors at `row` — the return-side mirror of
        /// `buildStructArgs`'s decode. Returns `false` (having already
        /// populated `err`) on the first failed write, same convention as
        /// every other `... != DUCKDB_V2_ERROR_NONE) return;` call site in
        /// this file, just surfaced as a boolean since this runs inside a
        /// `comptime inline for`, not the exec callback itself.
        inline fn writeStructResult(
            context: v2.duckdb_v2_context_handle,
            ptrs: *const ReturnChildPtrsTuple,
            row: u64,
            value: ReturnType,
            err: *v2.duckdb_v2_error_info_handle,
        ) bool {
            const fields = @typeInfo(ReturnType).@"struct";
            inline for (0..fields.field_types.len) |f| {
                const FT = fields.field_types[f];
                const field_value = @field(value, fields.field_names[f]);
                if (comptime FT == []const u8) {
                    var v: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createVarcharValue(context, field_value, &v, err) != .ERROR_NONE) return false;
                    defer _ = v2.duckdb_v2_value_destroy(&v);
                    if (v2.duckdb_v2_vector_set_value(ptrs.*[f], row, v, err) != .ERROR_NONE) return false;
                } else {
                    ptrs.*[f][row] = field_value;
                }
            }
            return true;
        }

        /// Dedicated exec path for a STRUCT-typed argument: each field's
        /// child vector is addressed directly via `vectorGetChild`/index
        /// (no `ListEntry`-style offset/length indirection, unlike LIST —
        /// a STRUCT field is already aligned 1:1 with the parent's rows),
        /// flattened and view-cached the same way a plain argument is.
        /// DuckDB's nested-NULL invariant (a NULL STRUCT row implies NULL
        /// field rows) means checking each field's own validity bit is
        /// sufficient — no separate STRUCT-level validity check is needed.
        fn executeStruct(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, result_vec: v2.duckdb_v2_vector_handle, row_count: u64, err: *v2.duckdb_v2_error_info_handle) void {
            var arg_vecs: [param_types.len]v2.duckdb_v2_vector_handle = undefined;
            var views: ViewsTuple = undefined;
            inline for (0..param_types.len) |i| {
                if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &arg_vecs[i], err) != .ERROR_NONE) return;
                const T = param_types[i].?;
                if (comptime isStructType(T)) {
                    const fields = @typeInfo(T).@"struct";
                    inline for (0..fields.field_types.len) |f| {
                        var child_vec: v2.duckdb_v2_vector_handle = undefined;
                        if (v2.duckdb_v2_vector_get_child(arg_vecs[i], f, &child_vec, err) != .ERROR_NONE) return;
                        if (v2.duckdb_v2_vector_flatten(child_vec, err) != .ERROR_NONE) return;
                        if (v2.duckdb_v2_vector_get_view(child_vec, &views[i][f], err) != .ERROR_NONE) return;
                    }
                } else {
                    if (v2.duckdb_v2_vector_flatten(arg_vecs[i], err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_get_view(arg_vecs[i], &views[i], err) != .ERROR_NONE) return;
                }
            }

            // Output side: a flat buffer (numeric/bool return), one boxed
            // Value per row (VARCHAR return), or one write handle per field
            // cached up front (STRUCT return) — the same three-way split
            // `writeStructResult`'s doc comment describes, just set up here.
            var out: [*]ReturnType = undefined;
            var return_child_ptrs: ReturnChildPtrsTuple = undefined;
            if (comptime return_is_struct) {
                const fields = @typeInfo(ReturnType).@"struct";
                inline for (0..fields.field_types.len) |f| {
                    const FT = fields.field_types[f];
                    var child_vec: v2.duckdb_v2_vector_handle = undefined;
                    if (v2.duckdb_v2_vector_get_child(result_vec, f, &child_vec, err) != .ERROR_NONE) return;
                    if (comptime FT == []const u8) {
                        return_child_ptrs[f] = child_vec;
                    } else {
                        var out_data: ?*anyopaque = null;
                        if (v2.duckdb_v2_vector_get_data_mutable(child_vec, &out_data, err) != .ERROR_NONE) return;
                        return_child_ptrs[f] = @ptrCast(@alignCast(out_data));
                    }
                }
            } else if (comptime !return_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                if (!structRowIsValid(&views, row)) {
                    if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                    continue;
                }
                const args = buildStructArgs(&views, row);
                const result = @call(.auto, implFn, args);
                if (comptime return_is_struct) {
                    if (!writeStructResult(context, &return_child_ptrs, row, result, err)) return;
                } else if (comptime return_is_varchar) {
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createVarcharValue(context, result, &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                } else {
                    out[row] = result;
                }
            }
        }

        inline fn structRowIsValid(views: *const ViewsTuple, row: u64) bool {
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

        inline fn buildStructArgs(views: *const ViewsTuple, row: u64) ArgsTuple {
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
                            const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views.*[i][f].data));
                            @field(val, fname) = helpers.bytesSlice(&typed[row]);
                        } else {
                            const typed: [*]const FT = @ptrCast(@alignCast(views.*[i][f].data));
                            @field(val, fname) = typed[row];
                        }
                    }
                    args[i] = val;
                } else if (comptime T == []const u8) {
                    const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = helpers.bytesSlice(&typed[row]);
                } else {
                    const typed: [*]const T = @ptrCast(@alignCast(views.*[i].data));
                    args[i] = typed[row];
                }
            }
            return args;
        }

        /// A LIST return longer than this per row is a query error, not a
        /// silent truncation. ARRAY returns need no such cap — their
        /// length is fixed and comptime-known (`ArrayLen(ReturnType)`).
        const list_return_max_elems = 4096;

        inline fn boxLeafValue(ctx: v2.duckdb_v2_context_handle, comptime T: type, v: T, out: *v2.duckdb_v2_value_handle, err: *v2.duckdb_v2_error_info_handle) bool {
            const rc = switch (T) {
                i8 => v2.duckdb_v2_value_create_tinyint_with_context(ctx, v, out, err),
                i16 => v2.duckdb_v2_value_create_smallint_with_context(ctx, v, out, err),
                i32 => v2.duckdb_v2_value_create_int_with_context(ctx, v, out, err),
                i64 => v2.duckdb_v2_value_create_bigint_with_context(ctx, v, out, err),
                f32 => v2.duckdb_v2_value_create_float_with_context(ctx, v, out, err),
                f64 => v2.duckdb_v2_value_create_double_with_context(ctx, v, out, err),
                bool => v2.duckdb_v2_value_create_bool_with_context(ctx, v, out, err),
                else => @compileError("unsupported LIST/ARRAY element type for boxing: " ++ @typeName(T)),
            };
            return rc == .ERROR_NONE;
        }

        inline fn listRowIsValid(views: *const [param_types.len]v2.duckdb_v2_vector_view, row: u64) bool {
            inline for (0..param_types.len) |i| {
                if (views.*[i].validity) |validity| {
                    const entry_idx = row / 64;
                    const bit_idx: u6 = @intCast(row % 64);
                    if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) return false;
                }
            }
            return true;
        }

        /// Dedicated exec path for a LIST/ARRAY-typed argument and/or
        /// return, scoped to flat leaf element types
        /// (`isSupportedListArrayElem`) — not combined with STRUCT/VARIANT
        /// in the same function (see the `has_list_or_array` compile-time
        /// guard above).
        ///
        /// Argument decode is zero-copy: LIST reads each row's
        /// `ListEntry{offset, length}` from the flattened parent vector's
        /// own view, then slices directly into the flattened child
        /// vector's flat element buffer. ARRAY has no per-row metadata —
        /// elements are contiguous, strided by the fixed array length.
        /// CAUTION: individual elements inside a non-NULL LIST/ARRAY row
        /// are NOT checked for their own NULL-ness — only the LIST/ARRAY
        /// row itself (via the parent vector's own validity bit); a
        /// future addition, not attempted here (mirrors the one-level-
        /// deep restriction already documented for STRUCT fields).
        ///
        /// Return is boxed through
        /// `valueCreateListWithContext`/`valueCreateArrayWithContext`
        /// (building each element as its own boxed `Value` via the
        /// matching `value_create_*` leaf constructor, the same "simpler,
        /// if slower" tradeoff already accepted for VARCHAR/BLOB/STRUCT-
        /// VARCHAR-field returns) rather than a direct child-vector
        /// write — a direct write would need computing cumulative
        /// per-row offsets into one shared child vector across the whole
        /// batch, real added complexity this first implementation
        /// doesn't take on.
        fn executeListArray(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, result_vec: v2.duckdb_v2_vector_handle, row_count: u64, err: *v2.duckdb_v2_error_info_handle) void {
            var arg_vecs: [param_types.len]v2.duckdb_v2_vector_handle = undefined;
            var parent_views: [param_types.len]v2.duckdb_v2_vector_view = undefined;
            var child_views: [param_types.len]v2.duckdb_v2_vector_view = undefined;

            inline for (0..param_types.len) |i| {
                const T = param_types[i].?;
                if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &arg_vecs[i], err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_flatten(arg_vecs[i], err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_get_view(arg_vecs[i], &parent_views[i], err) != .ERROR_NONE) return;
                if (comptime isListType(T) or isArrayType(T)) {
                    var child_vec: v2.duckdb_v2_vector_handle = undefined;
                    if (v2.duckdb_v2_vector_get_child(arg_vecs[i], 0, &child_vec, err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_flatten(child_vec, err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_get_view(child_vec, &child_views[i], err) != .ERROR_NONE) return;
                }
            }

            const ReturnElem = if (comptime return_is_list) ListElem(ReturnType) else if (comptime return_is_array) ArrayElem(ReturnType) else void;
            var return_elem_type: v2.duckdb_v2_logical_type_handle = undefined;
            if (comptime return_is_list or return_is_array) {
                if (createLogicalType(context, ReturnElem, &return_elem_type, err) != .ERROR_NONE) return;
            }
            defer if (comptime return_is_list or return_is_array) {
                _ = v2.duckdb_v2_logical_type_destroy(&return_elem_type);
            };

            var out: [*]ReturnType = undefined;
            if (comptime !return_is_list and !return_is_array and !return_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                if (!listRowIsValid(&parent_views, row)) {
                    if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                    continue;
                }

                var args: ArgsTuple = undefined;
                inline for (0..param_types.len) |i| {
                    const T = param_types[i].?;
                    if (comptime isListType(T)) {
                        const Elem = ListElem(T);
                        // SAFETY: a flattened LIST vector's view data is an
                        // array of ListEntry{offset,length} records, per row.
                        const entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(parent_views[i].data));
                        const entry = entries[row];
                        // SAFETY: the flattened child vector's view data is
                        // the flat element buffer shared across all rows.
                        const elems: [*]const Elem = @ptrCast(@alignCast(child_views[i].data));
                        args[i] = elems[entry.offset..][0..entry.length];
                    } else if (comptime isArrayType(T)) {
                        const Elem = ArrayElem(T);
                        const n = comptime ArrayLen(T);
                        // SAFETY: an ARRAY's flattened child vector has
                        // `row_count * n` elements, strided by n per row.
                        const elems: [*]const Elem = @ptrCast(@alignCast(child_views[i].data));
                        const start = row * n;
                        var arr: T = undefined;
                        inline for (0..n) |k| arr[k] = elems[start + k];
                        args[i] = arr;
                    } else if (comptime T == []const u8) {
                        const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(parent_views[i].data));
                        args[i] = helpers.bytesSlice(&typed[row]);
                    } else {
                        const typed: [*]const T = @ptrCast(@alignCast(parent_views[i].data));
                        args[i] = typed[row];
                    }
                }

                const result = @call(.auto, implFn, args);

                if (comptime return_is_list) {
                    if (result.len > list_return_max_elems) {
                        const msg = helpers.str("LIST return exceeds the supported maximum length");
                        _ = v2.duckdb_v2_error_info_set_code(err.*, .ERROR_API);
                        _ = v2.duckdb_v2_error_info_set_text(err.*, &msg);
                        return;
                    }
                    var boxed: [list_return_max_elems]v2.duckdb_v2_value_handle = undefined;
                    for (result, 0..) |item, k| {
                        if (!boxLeafValue(context, ReturnElem, item, &boxed[k], err)) return;
                    }
                    defer for (0..result.len) |k| {
                        _ = v2.duckdb_v2_value_destroy(&boxed[k]);
                    };
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createListValue(context, return_elem_type, boxed[0..result.len], &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                } else if (comptime return_is_array) {
                    const n = comptime ArrayLen(ReturnType);
                    var boxed: [n]v2.duckdb_v2_value_handle = undefined;
                    inline for (0..n) |k| {
                        if (!boxLeafValue(context, ReturnElem, result[k], &boxed[k], err)) return;
                    }
                    defer inline for (0..n) |k| {
                        _ = v2.duckdb_v2_value_destroy(&boxed[k]);
                    };
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createArrayValue(context, return_elem_type, &boxed, &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                } else if (comptime return_is_varchar) {
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createVarcharValue(context, result, &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                } else {
                    out[row] = result;
                }
            }
        }

        /// A MAP argument's per-row entry count is capped here — past it,
        /// entries are silently truncated (not an error; documented, not
        /// attempted to be made more precise, same posture as the
        /// LIST/ARRAY per-element-NULL limitation above).
        const map_arg_max_entries = 256;
        /// A MAP return longer than this per row is a query error, same
        /// convention as `list_return_max_elems`.
        const map_return_max_entries = 4096;

        /// Dedicated exec path for a MAP argument and/or return, scoped
        /// to flat leaf key/value types (`isSupportedMapKV`). Argument
        /// decode mirrors LIST's: the parent MAP vector's own view gives
        /// per-row `ListEntry{offset,length}` (MAP is physically
        /// LIST(STRUCT(key,value)) internally — confirmed by
        /// `vector_get_child_count`'s own doc comment grouping
        /// LIST/MAP/ARRAY together); `vectorGetChild(map_vec, 0, ...)`
        /// descends into the entries STRUCT vector, whose own children
        /// [0]/[1] are the flat key/value arrays. Unlike LIST, this can't
        /// be a zero-copy slice reinterpretation — `v2_values.Map(K,V).entries`
        /// is `[]const Entry{key,value}`, an array of structs, but the
        /// source storage is two parallel flat arrays — so each row's
        /// entries are zipped into a bounded stack buffer
        /// (`map_arg_max_entries`), reused per row since it's consumed
        /// synchronously within the same iteration (safe, unlike
        /// returning a slice into it — see the VARCHAR-return CAUTION
        /// above). Return is boxed via `valueCreateMapWithContext`
        /// (parallel key/value `Value` arrays) — same "simpler, if
        /// slower" tradeoff as LIST/ARRAY returns.
        fn executeMap(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, result_vec: v2.duckdb_v2_vector_handle, row_count: u64, err: *v2.duckdb_v2_error_info_handle) void {
            var arg_vecs: [param_types.len]v2.duckdb_v2_vector_handle = undefined;
            var parent_views: [param_types.len]v2.duckdb_v2_vector_view = undefined;
            var key_views: [param_types.len]v2.duckdb_v2_vector_view = undefined;
            var value_views: [param_types.len]v2.duckdb_v2_vector_view = undefined;

            inline for (0..param_types.len) |i| {
                const T = param_types[i].?;
                if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &arg_vecs[i], err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_flatten(arg_vecs[i], err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_get_view(arg_vecs[i], &parent_views[i], err) != .ERROR_NONE) return;
                if (comptime isMapType(T)) {
                    var entries_vec: v2.duckdb_v2_vector_handle = undefined;
                    if (v2.duckdb_v2_vector_get_child(arg_vecs[i], 0, &entries_vec, err) != .ERROR_NONE) return;
                    var key_vec: v2.duckdb_v2_vector_handle = undefined;
                    if (v2.duckdb_v2_vector_get_child(entries_vec, 0, &key_vec, err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_flatten(key_vec, err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_get_view(key_vec, &key_views[i], err) != .ERROR_NONE) return;
                    var value_vec: v2.duckdb_v2_vector_handle = undefined;
                    if (v2.duckdb_v2_vector_get_child(entries_vec, 1, &value_vec, err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_flatten(value_vec, err) != .ERROR_NONE) return;
                    if (v2.duckdb_v2_vector_get_view(value_vec, &value_views[i], err) != .ERROR_NONE) return;
                }
            }

            const MapK = if (comptime return_is_map) MapKey(ReturnType) else void;
            const MapV = if (comptime return_is_map) MapValue(ReturnType) else void;
            var return_key_type: v2.duckdb_v2_logical_type_handle = undefined;
            var return_value_type: v2.duckdb_v2_logical_type_handle = undefined;
            if (comptime return_is_map) {
                if (createLogicalType(context, MapK, &return_key_type, err) != .ERROR_NONE) return;
                if (createLogicalType(context, MapV, &return_value_type, err) != .ERROR_NONE) return;
            }
            defer if (comptime return_is_map) {
                _ = v2.duckdb_v2_logical_type_destroy(&return_key_type);
                _ = v2.duckdb_v2_logical_type_destroy(&return_value_type);
            };

            var out: [*]ReturnType = undefined;
            if (comptime !return_is_map and !return_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                if (!listRowIsValid(&parent_views, row)) {
                    if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                    continue;
                }

                var args: ArgsTuple = undefined;
                inline for (0..param_types.len) |i| {
                    const T = param_types[i].?;
                    if (comptime isMapType(T)) {
                        const K = MapKey(T);
                        const V = MapValue(T);
                        const Entry = T.Entry;
                        // SAFETY: a flattened MAP vector's view data is an
                        // array of ListEntry{offset,length} records, per row.
                        const list_entries: [*]const v2.duckdb_v2_list_entry = @ptrCast(@alignCast(parent_views[i].data));
                        const list_entry = list_entries[row];
                        const keys: [*]const K = @ptrCast(@alignCast(key_views[i].data));
                        const values: [*]const V = @ptrCast(@alignCast(value_views[i].data));
                        const n = @min(list_entry.length, map_arg_max_entries);
                        var buf: [map_arg_max_entries]Entry = undefined;
                        for (0..n) |k| buf[k] = .{ .key = keys[list_entry.offset + k], .value = values[list_entry.offset + k] };
                        args[i] = .{ .entries = buf[0..n] };
                    } else if (comptime T == []const u8) {
                        const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(parent_views[i].data));
                        args[i] = helpers.bytesSlice(&typed[row]);
                    } else {
                        const typed: [*]const T = @ptrCast(@alignCast(parent_views[i].data));
                        args[i] = typed[row];
                    }
                }

                const result = @call(.auto, implFn, args);

                if (comptime return_is_map) {
                    if (result.entries.len > map_return_max_entries) {
                        const msg = helpers.str("MAP return exceeds the supported maximum entry count");
                        _ = v2.duckdb_v2_error_info_set_code(err.*, .ERROR_API);
                        _ = v2.duckdb_v2_error_info_set_text(err.*, &msg);
                        return;
                    }
                    var boxed_keys: [map_return_max_entries]v2.duckdb_v2_value_handle = undefined;
                    var boxed_values: [map_return_max_entries]v2.duckdb_v2_value_handle = undefined;
                    for (result.entries, 0..) |entry, k| {
                        if (!boxLeafValue(context, MapK, entry.key, &boxed_keys[k], err)) return;
                        if (!boxLeafValue(context, MapV, entry.value, &boxed_values[k], err)) return;
                    }
                    defer for (0..result.entries.len) |k| {
                        _ = v2.duckdb_v2_value_destroy(&boxed_keys[k]);
                        _ = v2.duckdb_v2_value_destroy(&boxed_values[k]);
                    };
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createMapValue(context, return_key_type, return_value_type, boxed_keys[0..result.entries.len], boxed_values[0..result.entries.len], &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                } else if (comptime return_is_varchar) {
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createVarcharValue(context, result, &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                } else {
                    out[row] = result;
                }
            }
        }

        /// Dedicated exec path for a UNION argument and/or return, scoped
        /// to flat leaf member types including `[]const u8`
        /// (`isSupportedUnionMember`) — reuses STRUCT's per-field
        /// child-vector read/write machinery, since UNION's
        /// child-vector-per-member layout (`vectorGetChild`: [0] = tag,
        /// [1..N] = every member) is directly analogous. CAUTION: there
        /// is no `duckdb_v2_value_create_union_*` constructor at all
        /// (confirmed by grepping the header) — writes go directly into
        /// the tag child's flat buffer plus the active member's own
        /// child vector (flat write, or boxed-per-row `Value` for a
        /// `[]const u8` member), never through a boxed whole-UNION
        /// `Value`. The tag is a UTINYINT (`u8`) dictionary-style index
        /// into the member list, same convention `value_get_child`'s own
        /// doc comment describes at the `Value` level; confirmed live
        /// this also holds at the vector level.
        fn executeUnion(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, result_vec: v2.duckdb_v2_vector_handle, row_count: u64, err: *v2.duckdb_v2_error_info_handle) void {
            var arg_vecs: [param_types.len]v2.duckdb_v2_vector_handle = undefined;
            var parent_views: [param_types.len]v2.duckdb_v2_vector_view = undefined;

            inline for (0..param_types.len) |i| {
                if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &arg_vecs[i], err) != .ERROR_NONE) return;
                // Flattened/viewed uniformly, union args included — a
                // union vector's own top-level `.validity` bit is still
                // meaningful and readable this way, even though its
                // `.data` is never read directly (the tag/member
                // children, descended via `vectorGetChild` on the
                // original `arg_vecs[i]` handle below, carry the actual
                // value).
                if (v2.duckdb_v2_vector_flatten(arg_vecs[i], err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_get_view(arg_vecs[i], &parent_views[i], err) != .ERROR_NONE) return;
            }

            var out: [*]ReturnType = undefined;
            if (comptime !return_is_union and !return_is_varchar) {
                var out_data: ?*anyopaque = null;
                if (v2.duckdb_v2_vector_get_data_mutable(result_vec, &out_data, err) != .ERROR_NONE) return;
                out = @ptrCast(@alignCast(out_data));
            }

            var row: u64 = 0;
            while (row < row_count) : (row += 1) {
                var row_valid = true;
                inline for (0..param_types.len) |i| {
                    if (parent_views[i].validity) |validity| {
                        const entry_idx = row / 64;
                        const bit_idx: u6 = @intCast(row % 64);
                        if ((validity[entry_idx] & (@as(u64, 1) << bit_idx)) == 0) row_valid = false;
                    }
                }
                if (!row_valid) {
                    if (v2.duckdb_v2_vector_set_null(result_vec, row, err) != .ERROR_NONE) return;
                    continue;
                }

                var args: ArgsTuple = undefined;
                inline for (0..param_types.len) |i| {
                    const T = param_types[i].?;
                    if (comptime isUnionType(T)) {
                        args[i] = readUnionArg(T, arg_vecs[i], row, err) orelse return;
                    } else if (comptime T == []const u8) {
                        const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(parent_views[i].data));
                        args[i] = helpers.bytesSlice(&typed[row]);
                    } else {
                        const typed: [*]const T = @ptrCast(@alignCast(parent_views[i].data));
                        args[i] = typed[row];
                    }
                }

                const result = @call(.auto, implFn, args);

                if (comptime return_is_union) {
                    if (!writeUnionResult(context, result_vec, row, result, err)) return;
                } else if (comptime return_is_varchar) {
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (helpers.createVarcharValue(context, result, &value, err) != .ERROR_NONE) return;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(result_vec, row, value, err) != .ERROR_NONE) return;
                } else {
                    out[row] = result;
                }
            }
        }

        /// Decode a UNION argument at `row`: read the tag child's flat
        /// `u8` ordinal, then read the corresponding member child at the
        /// same row. Returns `null` (having already set `err`) only on a
        /// genuine API failure, not on any data condition.
        fn readUnionArg(comptime T: type, union_vec: v2.duckdb_v2_vector_handle, row: u64, err: *v2.duckdb_v2_error_info_handle) ?T {
            const info = @typeInfo(T).@"union";
            const n = info.field_types.len;

            var tag_vec: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_vector_get_child(union_vec, 0, &tag_vec, err) != .ERROR_NONE) return null;
            if (v2.duckdb_v2_vector_flatten(tag_vec, err) != .ERROR_NONE) return null;
            var tag_view: v2.duckdb_v2_vector_view = undefined;
            if (v2.duckdb_v2_vector_get_view(tag_vec, &tag_view, err) != .ERROR_NONE) return null;
            // SAFETY: the tag child is a flattened UTINYINT vector.
            const tags: [*]const u8 = @ptrCast(@alignCast(tag_view.data));
            const active = tags[row];

            inline for (0..n) |m| {
                if (active == m) {
                    var member_vec: v2.duckdb_v2_vector_handle = undefined;
                    if (v2.duckdb_v2_vector_get_child(union_vec, 1 + m, &member_vec, err) != .ERROR_NONE) return null;
                    if (v2.duckdb_v2_vector_flatten(member_vec, err) != .ERROR_NONE) return null;
                    var member_view: v2.duckdb_v2_vector_view = undefined;
                    if (v2.duckdb_v2_vector_get_view(member_vec, &member_view, err) != .ERROR_NONE) return null;
                    const FT = info.field_types[m];
                    const field_name = info.field_names[m];
                    if (comptime FT == []const u8) {
                        const typed: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(member_view.data));
                        return @unionInit(T, field_name, helpers.bytesSlice(&typed[row]));
                    } else {
                        const typed: [*]const FT = @ptrCast(@alignCast(member_view.data));
                        return @unionInit(T, field_name, typed[row]);
                    }
                }
            }
            unreachable; // `active` is a dictionary ordinal DuckDB itself produced, always < n
        }

        /// Write a UNION return value at `row`: the active tag, plus the
        /// active member's own value into its own child vector — every
        /// other member's child vector at this row is left untouched
        /// (unspecified, not required to be NULL or zeroed — UNION's
        /// tag is what determines which value is meaningful).
        fn writeUnionResult(context: v2.duckdb_v2_context_handle, result_vec: v2.duckdb_v2_vector_handle, row: u64, value: ReturnType, err: *v2.duckdb_v2_error_info_handle) bool {
            const info = @typeInfo(ReturnType).@"union";
            const n = info.field_types.len;

            var tag_vec: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_vector_get_child(result_vec, 0, &tag_vec, err) != .ERROR_NONE) return false;
            var tag_data: ?*anyopaque = null;
            if (v2.duckdb_v2_vector_get_data_mutable(tag_vec, &tag_data, err) != .ERROR_NONE) return false;
            const tags: [*]u8 = @ptrCast(@alignCast(tag_data));

            const active = @backingInt(value);
            tags[row] = @intCast(active);

            // CAUTION, confirmed live: every member's child vector, not
            // just the active one, must be given a well-defined value at
            // this row — a mixed-tag batch left the *inactive* members'
            // rows untouched (uninitialized), which worked fine across
            // rows when every member was a flat numeric type, but
            // segfaulted as soon as one member was VARCHAR (a leftover,
            // never-initialized `duckdb_v2_string_t` is apparently read
            // by something downstream regardless of the row's own tag —
            // narrowed by testing a two-numeric-member union, which
            // never crashed, against a num/VARCHAR union, which crashed
            // on every mixed-tag batch and never on a same-tag batch).
            // Fixed by explicitly NULLing every non-active member's row,
            // not just leaving it alone.
            inline for (0..n) |m| {
                var member_vec: v2.duckdb_v2_vector_handle = undefined;
                if (v2.duckdb_v2_vector_get_child(result_vec, 1 + m, &member_vec, err) != .ERROR_NONE) return false;
                if (active == m) {
                    const FT = info.field_types[m];
                    const field_name = info.field_names[m];
                    const field_value = @field(value, field_name);
                    if (comptime FT == []const u8) {
                        var v: v2.duckdb_v2_value_handle = undefined;
                        if (helpers.createVarcharValue(context, field_value, &v, err) != .ERROR_NONE) return false;
                        defer _ = v2.duckdb_v2_value_destroy(&v);
                        if (v2.duckdb_v2_vector_set_value(member_vec, row, v, err) != .ERROR_NONE) return false;
                    } else {
                        var member_data: ?*anyopaque = null;
                        if (v2.duckdb_v2_vector_get_data_mutable(member_vec, &member_data, err) != .ERROR_NONE) return false;
                        const typed: [*]FT = @ptrCast(@alignCast(member_data));
                        typed[row] = field_value;
                    }
                } else {
                    if (v2.duckdb_v2_vector_set_null(member_vec, row, err) != .ERROR_NONE) return false;
                }
            }
            return true;
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
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Double.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "FunctionNamed supports real parameter names" {
    const Add = FunctionNamed("v2_test_named_add", struct {
        fn eval(a: i64, b: i64) i64 {
            return a + b;
        }
    }.eval, &.{ "a", "b" });
    _ = &Add.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Add.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports multiple parameters of different types" {
    const Mix = Function("v2_test_mix", struct {
        fn eval(a: i64, b: f64, c: bool) f64 {
            return if (c) @as(f64, @floatFromInt(a)) + b else b;
        }
    }.eval);
    _ = &Mix.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Mix.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
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
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = FirstChar.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports a one-level STRUCT argument" {
    const Point = struct { x: i64, y: i64 };
    const Dist2 = Function("v2_test_struct_dist2", struct {
        fn eval(p: Point) i64 {
            return p.x * p.x + p.y * p.y;
        }
    }.eval);
    _ = &Dist2.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Dist2.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports a STRUCT argument with a VARCHAR field, mixed with a plain argument" {
    const Named = struct { label: []const u8, count: i64 };
    const Describe = Function("v2_test_struct_varchar_field", struct {
        fn eval(n: Named, scale: i64) i64 {
            return @as(i64, @intCast(n.label.len)) + n.count * scale;
        }
    }.eval);
    _ = &Describe.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Describe.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports a one-level STRUCT return type" {
    const Point = struct { x: i64, y: i64 };
    const Scale = Function("v2_test_struct_return", struct {
        fn eval(factor: i64) Point {
            return .{ .x = factor, .y = factor * 2 };
        }
    }.eval);
    _ = &Scale.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Scale.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports STRUCT argument and STRUCT return together, including a VARCHAR field" {
    const Person = struct { name: []const u8, age: i64 };
    const Birthday = Function("v2_test_struct_arg_and_return", struct {
        fn eval(p: Person) Person {
            return .{ .name = p.name, .age = p.age + 1 };
        }
    }.eval);
    _ = &Birthday.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Birthday.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports VARIANT as a parameter and return type" {
    // Per the CAUTION above: returns a freshly created Value, never `v`
    // itself (which would double-free, since the framework destroys both
    // the argument and the return value independently).
    const IsNull = Function("v2_test_variant_is_null", struct {
        fn eval(context: v2.duckdb_v2_context_handle, v: v2.duckdb_v2_value_handle) bool {
            _ = context;
            var err: v2.duckdb_v2_error_info_handle = undefined;
            var is_null: bool = false;
            _ = v2.duckdb_v2_value_is_null(v, &is_null, &err);
            return is_null;
        }
    }.eval);
    _ = &IsNull.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = IsNull.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function accepts an error-union return on the leaf, VARCHAR and DECIMAL paths" {
    const Checked = Function("v2_test_checked", struct {
        fn eval(a: i64) !i64 {
            return std.math.add(i64, a, 1);
        }
    }.eval);
    _ = &Checked.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Checked.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);

    const Word = Function("v2_test_checked_word", struct {
        fn eval(s: []const u8) ![]const u8 {
            if (s.len == 0) return error.EmptyInput;
            return s;
        }
    }.eval);
    _ = &Word.register;
    const Money = Function("v2_test_checked_money", struct {
        fn eval(d: v2_values.Decimal(10, 2)) !v2_values.Decimal(10, 2) {
            return d;
        }
    }.eval);
    _ = &Money.register;
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
        fn eval(d: v2_values.Date, t: v2_values.Time, ts: v2_values.Timestamp, iv: v2_values.Interval) v2_values.Timestamp {
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
        fn eval(b: v2_values.Blob) v2_values.Blob {
            return .{ .bytes = b.bytes[0..@min(1, b.bytes.len)] };
        }
    }.eval);
    _ = &FirstByte.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = FirstByte.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports DECIMAL as a parameter and return type" {
    const Price = v2_values.Decimal(10, 2);
    const DoublePrice = Function("v2_test_decimal_double", struct {
        fn eval(p: Price) Price {
            return .{ .raw = p.raw * 2 };
        }
    }.eval);
    _ = &DoublePrice.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = DoublePrice.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports DECIMAL at each storage-width tier" {
    const Narrow = v2_values.Decimal(4, 1); // i16
    const Medium = v2_values.Decimal(9, 2); // i32
    const Wide = v2_values.Decimal(18, 4); // i64
    const Huge = v2_values.Decimal(38, 10); // i128
    try std.testing.expectEqual(i16, Narrow.Raw);
    try std.testing.expectEqual(i32, Medium.Raw);
    try std.testing.expectEqual(i64, Wide.Raw);
    try std.testing.expectEqual(i128, Huge.Raw);
}

test "Function supports ENUM as a parameter and return type, including manually-numbered variants" {
    const Status = enum(u8) { pending = 5, active = 10, done = 20 };
    const NextStatus = Function("v2_test_enum_next", struct {
        fn eval(s: Status) Status {
            return switch (s) {
                .pending => .active,
                .active => .done,
                .done => .done,
            };
        }
    }.eval);
    _ = &NextStatus.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = NextStatus.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports a LIST(BIGINT) argument" {
    const Sum = Function("v2_test_list_sum", struct {
        fn eval(xs: []const i64) i64 {
            var total: i64 = 0;
            for (xs) |x| total += x;
            return total;
        }
    }.eval);
    _ = &Sum.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Sum.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports a LIST(BIGINT) return type" {
    const Pair = Function("v2_test_list_return", struct {
        fn eval(a: i64) []const i64 {
            _ = a;
            return &.{ 1, 2, 3 };
        }
    }.eval);
    _ = &Pair.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Pair.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports an ARRAY(DOUBLE, N) argument and return type" {
    const Scale2 = Function("v2_test_array_scale", struct {
        fn eval(xs: [2]f64) [2]f64 {
            return .{ xs[0] * 2, xs[1] * 2 };
        }
    }.eval);
    _ = &Scale2.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = Scale2.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports LIST mixed with a plain argument" {
    const WeightedSum = Function("v2_test_list_mixed", struct {
        fn eval(xs: []const i64, scale: i64) i64 {
            var total: i64 = 0;
            for (xs) |x| total += x;
            return total * scale;
        }
    }.eval);
    _ = &WeightedSum.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = WeightedSum.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports a MAP(BIGINT, BIGINT) argument" {
    const MapSumValues = Function("v2_test_map_sum_values", struct {
        fn eval(m: Map(i64, i64)) i64 {
            var total: i64 = 0;
            for (m.entries) |e| total += e.value;
            return total;
        }
    }.eval);
    _ = &MapSumValues.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = MapSumValues.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports a MAP(BIGINT, BIGINT) return type" {
    const MapMake = Function("v2_test_map_make", struct {
        fn eval(n: i64) Map(i64, i64) {
            _ = n;
            return .{ .entries = &.{ .{ .key = 1, .value = 10 }, .{ .key = 2, .value = 20 } } };
        }
    }.eval);
    _ = &MapMake.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = MapMake.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}

test "Function supports a UNION argument and return type, including a VARCHAR member" {
    const NumOrText = union(enum) { num: i64, text: []const u8 };
    const UnionRoundtrip = Function("v2_test_union_roundtrip", struct {
        fn eval(u: NumOrText) NumOrText {
            return u;
        }
    }.eval);
    _ = &UnionRoundtrip.register;
    const exec_cb: v2.duckdb_v2_scalar_function_exec_callback_fn = UnionRoundtrip.execute;
    try std.testing.expect(@intFromPtr(exec_cb) != 0);
}
