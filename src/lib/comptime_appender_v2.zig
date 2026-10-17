///! Comptime bulk-insert helper for the DuckDB v2 C Extension API — the v2
///! analogue of v1's row-based Appender (`duckdb_appender_create` +
///! `duckdb_append_*`, aliased as `db.Appender` in `duckdb.zig`), which v2
///! has no equivalent of at all: `duckdb_extension_v2.h` defines no
///! `duckdb_v2_appender_*` family. What v2 offers instead is bulk/columnar:
///! build a `duckdb_v2_data_chunk_handle` yourself and hand whole chunks to
///! a `duckdb_v2_column_data_collection_handle` via
///! `duckdb_v2_column_data_collection_append` (see `duckdb_v2.zig`'s
///! "Column Data Collection" section).
///!
///! This generalizes that into the same "derive the plumbing from a plain
///! Zig shape" pattern `comptime_table_v2.Function` uses for table
///! functions, just in the opposite data direction: instead of DuckDB
///! pulling rows out via `next()`, the caller pushes rows in via `append()`,
///! and the framework batches them into DataChunks for the caller.
///!
///! The caller supplies a plain Row struct — the same shape
///! `comptime_table_v2`'s `State.Row` uses — and gets back an
///! `Appender(Row)` with:
///!   - `create(ctx, err) !Self` — creates the backing
///!     `ColumnDataCollection` and a reusable `DataChunk` sized to DuckDB's
///!     standard vector capacity. Takes a `ContextHandle`, not a
///!     `ConnectionHandle`: a `ConnectionHandle` is what the header's
///!     `_with_connection` variants of every call here want, but nothing in
///!     this codebase's function callbacks is ever handed one — scalar and
///!     table function exec callbacks, and `bind`, are all handed a
///!     `ContextHandle` instead (confirmed against `duckdb_v2.h`'s
///!     callback typedefs), so this uses the `_with_context` variant of
///!     every call throughout. `duckdb_v2.zig` keeps the `_with_connection`
///!     wrappers too, for a standalone embedder that does have a real
///!     connection, but `Appender` itself only needs the context path.
///!   - `append(self, row, err) !void` — buffer one row; auto-flushes the
///!     chunk into the collection once it fills.
///!   - `flush(self, err) !void` — force any buffered rows into the
///!     collection now.
///!   - `finish(self, err) !v2.duckdb_v2_column_data_collection_handle` — flush and hand
///!     back the collection; the caller now owns it (release via
///!     `v2.duckdb_v2_column_data_collection_destroy`) and may feed it to
///!     `column_data_collection_scan`/`combine`/anything else that takes a
///!     collection.
///!   - `destroy(self)` — release the appender's own scratch chunk + append
///!     state. Does NOT destroy the collection — `finish` already
///!     transferred that out. Safe (and required) to call even after
///!     `finish`.
///!
///! Bindings: the Appender calls DuckDB through the generated bindings (`duckdb_v2_dynamic`, plus
///! the helpers in `v2_helpers.zig`), and its methods take and return the generated handles.
///!
///! VARIANT is NOT supported: this v2 alpha has no `Value` constructor for
///! it at all (matching `duckdb_v2.zig`'s own VARIANT caveats on the read
///! side), so there is nothing for a write path to call.
const std = @import("std");
const v2 = @import("duckdb_v2_dynamic");
const helpers = @import("v2_helpers");

/// Rows buffered per chunk before an auto-flush — matches DuckDB's standard
/// vector size, same hand-pinned constant `comptime_table_v2.zig` uses
/// (`duckdb_v2_data_chunk_get_capacity` would be the live-queried
/// equivalent, but it's gated behind `DUCKDB_V2_API_ALLOW_UNSTABLE` and not
/// in this build's vtable — see `duckdb_v2.zig`'s note on it).
const max_rows_per_batch = 2048;

/// Leaf (non-nested) type → logical type id. Covers every type a LIST
/// element or STRUCT field may be; `Row`'s own top-level fields may ALSO be
/// LIST/STRUCT, which this does not handle — see `createColumnType`/
/// `buildValue` for the dispatch that adds those on top of this.
pub fn duckdbV2TypeId(comptime T: type) v2.DUCKDB_V2_LOGICAL_TYPE_ID {
    return switch (T) {
        i8 => .LOGICAL_TYPE_ID_TINYINT,
        i16 => .LOGICAL_TYPE_ID_SMALLINT,
        i32 => .LOGICAL_TYPE_ID_INTEGER,
        i64 => .LOGICAL_TYPE_ID_BIGINT,
        f32 => .LOGICAL_TYPE_ID_FLOAT,
        f64 => .LOGICAL_TYPE_ID_DOUBLE,
        bool => .LOGICAL_TYPE_ID_BOOLEAN,
        []const u8 => .LOGICAL_TYPE_ID_VARCHAR,
        else => @compileError("unsupported leaf type for DuckDB v2 mapping: " ++ @typeName(T)),
    };
}

/// True for a leaf type written via the raw-pointer fast path in `append`
/// (every leaf EXCEPT VARCHAR, which goes through boxed-`Value` like
/// LIST/STRUCT do).
fn isLeafScalarType(comptime T: type) bool {
    return switch (T) {
        i8, i16, i32, i64, f32, f64, bool => true,
        else => false,
    };
}

fn isLeafType(comptime T: type) bool {
    return isLeafScalarType(T) or T == []const u8;
}

/// `[]const E` where E is a leaf type, reserving `[]const u8` for VARCHAR
/// rather than LIST(TINYINT).
fn isListType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size != .slice or !ptr.attrs.@"const") return false;
    if (ptr.child == u8) return false;
    return isLeafType(ptr.child);
}

fn ListElemType(comptime T: type) type {
    return @typeInfo(T).pointer.child;
}

/// A plain Zig struct whose fields are all leaf types — one level deep,
/// same restriction `comptime_scalar_v2.zig`'s STRUCT-argument support
/// uses. A field that is itself LIST/STRUCT is a compile error, not a
/// silently-dropped column.
fn isStructType(comptime T: type) bool {
    if (T == []const u8) return false;
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |name_, type_| {
        if (!isLeafType(type_)) {
            @compileError("Appender STRUCT field '" ++ name_ ++ "' must be a leaf type (numeric/bool/[]const u8) — nested LIST/STRUCT fields aren't supported: " ++ @typeName(type_));
        }
    }
    return true;
}

fn ArrayElemType(comptime T: type) type {
    return @typeInfo(T).array.child;
}

fn ArrayLen(comptime T: type) usize {
    return @typeInfo(T).array.len;
}

/// `[N]E` where E is a leaf type — a fixed-size ARRAY, N taken from the
/// Zig array's own length.
fn isArrayType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .array) return false;
    return isLeafType(info.array.child);
}

fn isEnumType(comptime T: type) bool {
    return @typeInfo(T) == .@"enum";
}

/// Leaf type → SQL type name, for building the `"E[N]"` text
/// `contextCreateTypeFromText` parses for an ARRAY column (see this file's
/// module doc comment for why text rather than `context_create_type_from_id`).
fn sqlTypeName(comptime T: type) []const u8 {
    return switch (T) {
        i8 => "TINYINT",
        i16 => "SMALLINT",
        i32 => "INTEGER",
        i64 => "BIGINT",
        f32 => "FLOAT",
        f64 => "DOUBLE",
        bool => "BOOLEAN",
        []const u8 => "VARCHAR",
        else => @compileError("unsupported leaf type for SQL type text: " ++ @typeName(T)),
    };
}

/// Build `"ENUM('member0','member1',...)"` from a Zig enum's own variant
/// names, for `contextCreateTypeFromText`.
fn enumSqlText(comptime T: type) []const u8 {
    const info = @typeInfo(T).@"enum";
    comptime var text: []const u8 = "ENUM(";
    inline for (info.field_names, 0..) |name_, i| {
        if (i > 0) text = text ++ ",";
        text = text ++ "'" ++ name_ ++ "'";
    }
    return text ++ ")";
}

/// Compile-time-only validation that `T` is a shape `Appender` knows how
/// to handle (leaf, LIST, one-level STRUCT, ARRAY, or ENUM) — called for
/// every `Row` field so an unsupported type fails at `Appender(Row)`
/// instantiation, not at first `append`.
fn validateFieldType(comptime T: type) void {
    if (comptime isListType(T)) return;
    if (comptime isStructType(T)) return;
    if (comptime isArrayType(T)) return;
    if (comptime isEnumType(T)) return;
    _ = duckdbV2TypeId(T);
}

/// Build the logical type for `Row` field type `T` (leaf, LIST, or
/// one-level STRUCT) under `ctx`. Caller destroys `out_type`.
fn createColumnType(ctx: v2.duckdb_v2_context_handle, comptime T: type, out_type: *v2.duckdb_v2_logical_type_handle, err: *v2.duckdb_v2_error_info_handle) v2.DUCKDB_V2_ERROR {
    if (comptime isListType(T)) {
        const E = ListElemType(T);
        var child_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(ctx, duckdbV2TypeId(E), &child_type, err) != .ERROR_NONE) {
            return .ERROR_API;
        }
        defer _ = v2.duckdb_v2_logical_type_destroy(&child_type);
        return helpers.createListType(ctx, child_type, out_type, err);
    }
    if (comptime isStructType(T)) {
        const struct_info = @typeInfo(T).@"struct";
        const num_struct_fields = struct_info.field_names.len;
        var names: [num_struct_fields]v2.duckdb_v2_identifier_t = undefined;
        var field_types: [num_struct_fields]v2.duckdb_v2_logical_type_handle = undefined;
        var field_type_values: [num_struct_fields]v2.duckdb_v2_value_handle = undefined;
        inline for (struct_info.field_names, struct_info.field_types, 0..) |name_, type_, i| {
            names[i] = helpers.str(name_);
            if (helpers.createTypeFromId(ctx, duckdbV2TypeId(type_), &field_types[i], err) != .ERROR_NONE) {
                return .ERROR_API;
            }
        }
        defer {
            for (&field_types) |*ty| _ = v2.duckdb_v2_logical_type_destroy(ty);
        }
        return helpers.createStructType(ctx, &names, &field_types, &field_type_values, out_type, err);
    }
    if (comptime isArrayType(T)) {
        const text = comptime sqlTypeName(ArrayElemType(T)) ++ std.fmt.comptimePrint("[{d}]", .{ArrayLen(T)});
        return helpers.createTypeFromText(ctx, text, out_type, err);
    }
    if (comptime isEnumType(T)) {
        return helpers.createTypeFromText(ctx, comptime enumSqlText(T), out_type, err);
    }
    return helpers.createTypeFromId(ctx, duckdbV2TypeId(T), out_type, err);
}

/// Box a single leaf value as a `Value` (VARCHAR included — unlike the
/// numeric leaf types, VARCHAR has no raw-buffer write path, same as in
/// the original VARCHAR-only version of this file).
fn buildLeafValue(ctx: v2.duckdb_v2_context_handle, comptime T: type, value: T, err: *v2.duckdb_v2_error_info_handle) !v2.duckdb_v2_value_handle {
    var v: v2.duckdb_v2_value_handle = undefined;
    const code = switch (T) {
        i8 => v2.duckdb_v2_value_create_tinyint_with_context(ctx, value, &v, err),
        i16 => v2.duckdb_v2_value_create_smallint_with_context(ctx, value, &v, err),
        i32 => v2.duckdb_v2_value_create_int_with_context(ctx, value, &v, err),
        i64 => v2.duckdb_v2_value_create_bigint_with_context(ctx, value, &v, err),
        f32 => v2.duckdb_v2_value_create_float_with_context(ctx, value, &v, err),
        f64 => v2.duckdb_v2_value_create_double_with_context(ctx, value, &v, err),
        bool => v2.duckdb_v2_value_create_bool_with_context(ctx, value, &v, err),
        []const u8 => helpers.createVarcharValue(ctx, value, &v, err),
        else => @compileError("unsupported leaf type for DuckDB v2 value boxing: " ++ @typeName(T)),
    };
    if (code != .ERROR_NONE) return error.DuckDbError;
    return v;
}

/// Box a `[]const E` slice as a LIST `Value`: box each element, then wrap.
/// Children are boxed into a short-lived `std.heap.c_allocator` allocation
/// (a Zig slice's length isn't known at comptime) and destroyed before
/// returning — `valueCreateListWithContext` copies them in.
fn buildListValue(ctx: v2.duckdb_v2_context_handle, comptime E: type, items: []const E, err: *v2.duckdb_v2_error_info_handle) !v2.duckdb_v2_value_handle {
    const allocator = std.heap.c_allocator;
    const children = try allocator.alloc(v2.duckdb_v2_value_handle, items.len);
    defer allocator.free(children);

    var created: usize = 0;
    errdefer {
        for (children[0..created]) |*c| _ = v2.duckdb_v2_value_destroy(c);
    }
    for (items, 0..) |item, i| {
        children[i] = try buildLeafValue(ctx, E, item, err);
        created = i + 1;
    }
    defer {
        for (children) |*c| _ = v2.duckdb_v2_value_destroy(c);
    }

    var child_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(ctx, duckdbV2TypeId(E), &child_type, err) != .ERROR_NONE) return error.DuckDbError;
    defer _ = v2.duckdb_v2_logical_type_destroy(&child_type);

    var out: v2.duckdb_v2_value_handle = undefined;
    if (helpers.createListValue(ctx, child_type, children, &out, err) != .ERROR_NONE) return error.DuckDbError;
    return out;
}

/// Box a `[N]E` fixed-size array as an ARRAY `Value`: box each element,
/// then wrap. Same ownership shape as `buildListValue`; the array's size
/// IS `items.len`, no separate size parameter.
fn buildArrayValue(ctx: v2.duckdb_v2_context_handle, comptime E: type, items: []const E, err: *v2.duckdb_v2_error_info_handle) !v2.duckdb_v2_value_handle {
    const allocator = std.heap.c_allocator;
    const children = try allocator.alloc(v2.duckdb_v2_value_handle, items.len);
    defer allocator.free(children);

    var created: usize = 0;
    errdefer {
        for (children[0..created]) |*c| _ = v2.duckdb_v2_value_destroy(c);
    }
    for (items, 0..) |item, i| {
        children[i] = try buildLeafValue(ctx, E, item, err);
        created = i + 1;
    }
    defer {
        for (children) |*c| _ = v2.duckdb_v2_value_destroy(c);
    }

    var child_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(ctx, duckdbV2TypeId(E), &child_type, err) != .ERROR_NONE) return error.DuckDbError;
    defer _ = v2.duckdb_v2_logical_type_destroy(&child_type);

    var out: v2.duckdb_v2_value_handle = undefined;
    if (helpers.createArrayValue(ctx, child_type, children, &out, err) != .ERROR_NONE) return error.DuckDbError;
    return out;
}

/// Box a one-level STRUCT `Row` field as a STRUCT `Value`: box each field,
/// then wrap, field names taken from `T`'s own Zig field names.
fn buildStructValue(ctx: v2.duckdb_v2_context_handle, comptime T: type, value: T, err: *v2.duckdb_v2_error_info_handle) !v2.duckdb_v2_value_handle {
    const struct_info = @typeInfo(T).@"struct";
    const num_struct_fields = struct_info.field_names.len;
    var names: [num_struct_fields]v2.duckdb_v2_identifier_t = undefined;
    var children: [num_struct_fields]v2.duckdb_v2_value_handle = undefined;

    var created: usize = 0;
    errdefer {
        for (children[0..created]) |*c| _ = v2.duckdb_v2_value_destroy(c);
    }
    inline for (struct_info.field_names, struct_info.field_types, 0..) |name_, type_, i| {
        names[i] = helpers.str(name_);
        children[i] = try buildLeafValue(ctx, type_, @field(value, name_), err);
        created = i + 1;
    }
    defer {
        for (&children) |*c| _ = v2.duckdb_v2_value_destroy(c);
    }

    var out: v2.duckdb_v2_value_handle = undefined;
    if (helpers.createStructValue(ctx, &names, &children, &out, err) != .ERROR_NONE) return error.DuckDbError;
    return out;
}

/// Box a `Row` field value of any supported shape EXCEPT enum (leaf, LIST,
/// one-level STRUCT, or ARRAY) as a `Value`, for `vectorSetValue`. ENUM is
/// NOT handled here — it needs the column's own `LogicalTypeHandle` to
/// cast against, which this function has no way to receive; see `append`'s
/// dedicated enum branch instead.
fn buildValue(ctx: v2.duckdb_v2_context_handle, comptime T: type, value: T, err: *v2.duckdb_v2_error_info_handle) !v2.duckdb_v2_value_handle {
    if (comptime isListType(T)) {
        return buildListValue(ctx, ListElemType(T), value, err);
    }
    if (comptime isStructType(T)) {
        return buildStructValue(ctx, T, value, err);
    }
    if (comptime isArrayType(T)) {
        return buildArrayValue(ctx, ArrayElemType(T), value[0..], err);
    }
    return buildLeafValue(ctx, T, value, err);
}

/// Define a v2 bulk-insert helper from a plain Zig `Row` struct. See this
/// file's module doc comment for the full shape and usage.
pub fn Appender(comptime Row: type) type {
    const row_info = @typeInfo(Row).@"struct";
    const field_names = row_info.field_names;
    const field_types = row_info.field_types;
    const num_fields = field_names.len;

    inline for (field_types) |t| validateFieldType(t);

    return struct {
        const Self = @This();

        ctx: v2.duckdb_v2_context_handle,
        collection: v2.duckdb_v2_column_data_collection_handle,
        append_state: v2.duckdb_v2_column_data_collection_append_state_handle,
        chunk: v2.duckdb_v2_data_chunk_handle,
        /// Kept alive for the Appender's whole lifetime (unlike every
        /// other field shape, which only needs its column type transiently
        /// while building the collection/chunk): an ENUM field's `append`
        /// casts against `types[i]` directly — see this file's module doc
        /// comment on ENUM. Released in `destroy`.
        types: [num_fields]v2.duckdb_v2_logical_type_handle,
        capacity: u64,
        /// Rows written into `chunk` since the last flush. Every vector in
        /// `chunk` is kept sized to `capacity` (not `buffered`) between
        /// writes — see assumption 1 in the module doc comment — and
        /// shrunk to `buffered` only transiently, inside `flush`, for the
        /// `columnDataCollectionAppend` call itself.
        buffered: u64,

        /// Create an appender for `Row`s under `ctx`.
        pub fn create(ctx: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) !Self {
            var types: [num_fields]v2.duckdb_v2_logical_type_handle = undefined;
            var types_created: usize = 0;
            errdefer {
                for (types[0..types_created]) |*ty| _ = v2.duckdb_v2_logical_type_destroy(ty);
            }
            inline for (field_types, 0..) |t, i| {
                if (createColumnType(ctx, t, &types[i], err) != .ERROR_NONE) {
                    return error.FailedToCreateColumnType;
                }
                types_created = i + 1;
            }

            var collection: v2.duckdb_v2_column_data_collection_handle = undefined;
            if (helpers.createColumnDataCollection(ctx, &types, &collection, err) != .ERROR_NONE) {
                return error.FailedToCreateCollection;
            }
            errdefer _ = v2.duckdb_v2_column_data_collection_destroy(&collection);

            var append_state: v2.duckdb_v2_column_data_collection_append_state_handle = undefined;
            if (v2.duckdb_v2_column_data_collection_append_state_create(collection, &append_state, err) != .ERROR_NONE) {
                return error.FailedToCreateAppendState;
            }
            errdefer _ = v2.duckdb_v2_column_data_collection_append_state_destroy(&append_state);

            var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
            if (helpers.createDataChunk(ctx, &types, &chunk, err) != .ERROR_NONE) {
                return error.FailedToCreateChunk;
            }
            errdefer _ = v2.duckdb_v2_data_chunk_destroy(&chunk);

            var self: Self = .{
                .ctx = ctx,
                .collection = collection,
                .append_state = append_state,
                .chunk = chunk,
                .types = types,
                .capacity = max_rows_per_batch,
                .buffered = 0,
            };
            try self.growVectorsToCapacity(err);
            return self;
        }

        /// Pre-grow every vector in `chunk` to `capacity` so a raw write at
        /// any row index up to `capacity` is in bounds — see assumption 1
        /// in the module doc comment.
        fn growVectorsToCapacity(self: *Self, err: *v2.duckdb_v2_error_info_handle) !void {
            inline for (0..num_fields) |i| {
                var vec: v2.duckdb_v2_vector_handle = undefined;
                if (v2.duckdb_v2_data_chunk_get_vector(self.chunk, i, &vec, err) != .ERROR_NONE) return error.DuckDbError;
                if (v2.duckdb_v2_vector_set_size(vec, self.capacity, err) != .ERROR_NONE) return error.DuckDbError;
            }
        }

        /// Buffer one row, auto-flushing a full chunk first.
        pub fn append(self: *Self, row: Row, err: *v2.duckdb_v2_error_info_handle) !void {
            if (self.buffered == self.capacity) try self.flush(err);

            inline for (0..num_fields) |i| {
                var vec: v2.duckdb_v2_vector_handle = undefined;
                if (v2.duckdb_v2_data_chunk_get_vector(self.chunk, i, &vec, err) != .ERROR_NONE) return error.DuckDbError;
                const T = field_types[i];
                const field_value = @field(row, field_names[i]);
                if (comptime isLeafScalarType(T)) {
                    var out_data: ?*anyopaque = null;
                    if (v2.duckdb_v2_vector_get_data_mutable(vec, &out_data, err) != .ERROR_NONE) return error.DuckDbError;
                    // SAFETY: vector `i` was created from `types[i]`, which maps to `T` via `duckdbV2TypeId`.
                    const ptr: [*]T = @ptrCast(@alignCast(out_data));
                    ptr[self.buffered] = field_value;
                } else if (comptime isEnumType(T)) {
                    // No `value_create_enum_*` exists — cast a boxed VARCHAR
                    // of the variant's name to the column's own ENUM type
                    // (`self.types[i]`), the same way `'a'::my_enum` works
                    // in SQL. See this file's module doc comment on ENUM.
                    var text_value = try buildLeafValue(self.ctx, []const u8, @tagName(field_value), err);
                    defer _ = v2.duckdb_v2_value_destroy(&text_value);
                    var value: v2.duckdb_v2_value_handle = undefined;
                    if (v2.duckdb_v2_value_cast_with_context(self.ctx, text_value, self.types[i], &value, err) != .ERROR_NONE) return error.DuckDbError;
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(vec, self.buffered, value, err) != .ERROR_NONE) return error.DuckDbError;
                } else {
                    // VARCHAR, LIST, STRUCT, and ARRAY all go through boxed
                    // Value — none has a raw-buffer write path (see this
                    // file's doc comment on LIST/STRUCT/ARRAY).
                    var value = try buildValue(self.ctx, T, field_value, err);
                    defer _ = v2.duckdb_v2_value_destroy(&value);
                    if (v2.duckdb_v2_vector_set_value(vec, self.buffered, value, err) != .ERROR_NONE) return error.DuckDbError;
                }
            }
            self.buffered += 1;
        }

        /// Force any buffered rows into the collection now.
        pub fn flush(self: *Self, err: *v2.duckdb_v2_error_info_handle) !void {
            if (self.buffered == 0) return;

            inline for (0..num_fields) |i| {
                var vec: v2.duckdb_v2_vector_handle = undefined;
                if (v2.duckdb_v2_data_chunk_get_vector(self.chunk, i, &vec, err) != .ERROR_NONE) return error.DuckDbError;
                if (v2.duckdb_v2_vector_set_size(vec, self.buffered, err) != .ERROR_NONE) return error.DuckDbError;
            }
            if (v2.duckdb_v2_column_data_collection_append(self.collection, self.append_state, self.chunk, err) != .ERROR_NONE) {
                return error.FailedToAppendChunk;
            }
            self.buffered = 0;
            // Re-grow back to capacity for the next round of `append` writes
            // (see assumption 1 in the module doc comment) — relies on
            // assumption 2 (`chunk` is safe to reuse after `append`).
            try self.growVectorsToCapacity(err);
        }

        /// Flush and hand back the collection; the caller now owns it.
        pub fn finish(self: *Self, err: *v2.duckdb_v2_error_info_handle) !v2.duckdb_v2_column_data_collection_handle {
            try self.flush(err);
            return self.collection;
        }

        /// Release the appender's own scratch chunk + append state. Does
        /// NOT destroy the collection (see `finish`). Safe to call whether
        /// or not `finish` was called first.
        pub fn destroy(self: *Self) void {
            _ = v2.duckdb_v2_data_chunk_destroy(&self.chunk);
            _ = v2.duckdb_v2_column_data_collection_append_state_destroy(&self.append_state);
            for (&self.types) |*ty| _ = v2.duckdb_v2_logical_type_destroy(ty);
        }
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────
//
// Type-level only — no live v2 instance/connection to append against yet
// (same constraint `duckdb_v2.zig`'s own tests operate under).

test "Appender generates a valid Zig type for a single-column numeric Row" {
    const Row = struct { value: i64 };
    const A = Appender(Row);
    _ = &A.create;
    _ = &A.append;
    _ = &A.flush;
    _ = &A.finish;
    _ = &A.destroy;
}

test "Appender supports mixed numeric and VARCHAR columns" {
    const Row = struct { id: i64, name: []const u8, score: f64 };
    const A = Appender(Row);
    _ = &A.create;
}

test "Appender supports a LIST(BIGINT) column" {
    const Row = struct { tags: []const i64 };
    const A = Appender(Row);
    _ = &A.create;
}

test "Appender supports a LIST(VARCHAR) column" {
    const Row = struct { names: []const []const u8 };
    const A = Appender(Row);
    _ = &A.create;
}

test "Appender supports a one-level STRUCT column" {
    const Row = struct { point: struct { x: f64, y: f64 } };
    const A = Appender(Row);
    _ = &A.create;
}

test "Appender supports a fixed-size ARRAY column" {
    const Row = struct { coords: [3]f64 };
    const A = Appender(Row);
    _ = &A.create;
}

test "Appender supports an ENUM column" {
    const Status = enum { pending, active, done };
    const Row = struct { status: Status };
    const A = Appender(Row);
    _ = &A.create;
}

test "logicalTypeId and sqlTypeName agree for every leaf type" {
    const Pair = struct { T: type, id: v2.DUCKDB_V2_LOGICAL_TYPE_ID, name: []const u8 };
    const pairs = [_]Pair{
        .{ .T = i8, .id = .LOGICAL_TYPE_ID_TINYINT, .name = "TINYINT" },
        .{ .T = i16, .id = .LOGICAL_TYPE_ID_SMALLINT, .name = "SMALLINT" },
        .{ .T = i32, .id = .LOGICAL_TYPE_ID_INTEGER, .name = "INTEGER" },
        .{ .T = i64, .id = .LOGICAL_TYPE_ID_BIGINT, .name = "BIGINT" },
        .{ .T = f32, .id = .LOGICAL_TYPE_ID_FLOAT, .name = "FLOAT" },
        .{ .T = f64, .id = .LOGICAL_TYPE_ID_DOUBLE, .name = "DOUBLE" },
        .{ .T = bool, .id = .LOGICAL_TYPE_ID_BOOLEAN, .name = "BOOLEAN" },
        .{ .T = []const u8, .id = .LOGICAL_TYPE_ID_VARCHAR, .name = "VARCHAR" },
    };
    inline for (pairs) |pair| {
        try std.testing.expectEqual(pair.id, duckdbV2TypeId(pair.T));
        try std.testing.expectEqualStrings(pair.name, sqlTypeName(pair.T));
    }
}

test "enumSqlText lists the variants in declaration order" {
    const Status = enum { pending, active, done };
    try std.testing.expectEqualStrings("ENUM('pending','active','done')", enumSqlText(Status));
}
