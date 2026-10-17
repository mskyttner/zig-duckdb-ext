///! Cookbook: a COPY format that writes and reads Arrow IPC streams, with a library doing the format work
///! (`third_party/gld-arrow-zig`, a pure-Zig Apache Arrow implementation; see its PATCHES.md).
///!
///!   COPY t TO 'file.arrows' (FORMAT zig_cookbook_arrow_ipc, CODEC 'zstd');
///!   COPY t FROM 'file.arrows' (FORMAT zig_cookbook_arrow_ipc);
///!   SELECT * FROM zig_cookbook_read_arrow('file.arrows');
///!
///! The recipe is the *seam* between two memory layouts: DuckDB's vectors on one side, Arrow's columnar buffers on the
///! other. Both are validity bits plus a flat array (booleans as bits, strings as offsets plus bytes), so the seam is
///! a copy per column; the library takes care of the rest: flatbuffer messages, alignment, dictionaries on read, LZ4
///! and Zstd compression. The callbacks are those of `copy_format.zig`; read that one first for what each is for.
///!
///! Columns: BOOLEAN, the eight integer types of 8 to 64 bits, FLOAT, DOUBLE, DATE (day), TIMESTAMP (microseconds) and
///! VARCHAR. Any other type fails the statement at planning, naming the column. A file with other Arrow types, or
///! dictionary-encoded columns, is rejected the same way when it is read. `COPY ... FROM` takes the table's columns
///! as they are: the file's must match them by position and type, because the values are copied, not cast.
///!
///! Two simplifications, both because the library encodes and decodes a whole stream at a time: `COPY ... TO` keeps
///! every batch in memory until the last is flushed and writes the file in `finalize`, and `COPY ... FROM` reads the
///! file whole. A format for data larger than memory would write each batch's record-batch message as it is flushed.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const arrow = @import("arrow");

comptime {
    // Arrow buffers are little-endian and are copied as they are.
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

const Err = *v2.duckdb_v2_error_info_handle;

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(file: *anyopaque) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, file: *anyopaque) usize;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, file: *anyopaque) usize;

const gpa = std.heap.c_allocator;
const format_name = "zig_cookbook_arrow_ipc";

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [400]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    const text = helpers.str(msg);
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = v2.duckdb_v2_error_info_set_text(err.*, &text);
}

fn oom(err: Err) void {
    fail(err, .ERROR_RESOURCE_OUT_OF_MEMORY, format_name ++ ": out of memory", .{});
}

fn spanOf(s: v2.duckdb_v2_str) []const u8 {
    const ptr = s.ptr orelse return "";
    return ptr[0..s.len];
}

// --- the types that cross the seam -------------------------------------------------------------------------------

/// The DuckDB column types the recipe moves, by what they are in a vector.
const Kind = enum {
    boolean,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    date,
    timestamp,
    varchar,

    fn fromId(id: v2.DUCKDB_V2_LOGICAL_TYPE_ID) ?Kind {
        return switch (id) {
            .LOGICAL_TYPE_ID_BOOLEAN => .boolean,
            .LOGICAL_TYPE_ID_TINYINT => .i8,
            .LOGICAL_TYPE_ID_SMALLINT => .i16,
            .LOGICAL_TYPE_ID_INTEGER => .i32,
            .LOGICAL_TYPE_ID_BIGINT => .i64,
            .LOGICAL_TYPE_ID_UTINYINT => .u8,
            .LOGICAL_TYPE_ID_USMALLINT => .u16,
            .LOGICAL_TYPE_ID_UINTEGER => .u32,
            .LOGICAL_TYPE_ID_UBIGINT => .u64,
            .LOGICAL_TYPE_ID_FLOAT => .f32,
            .LOGICAL_TYPE_ID_DOUBLE => .f64,
            .LOGICAL_TYPE_ID_DATE => .date,
            .LOGICAL_TYPE_ID_TIMESTAMP => .timestamp,
            .LOGICAL_TYPE_ID_VARCHAR => .varchar,
            else => null,
        };
    }

    fn typeId(self: Kind) v2.DUCKDB_V2_LOGICAL_TYPE_ID {
        return switch (self) {
            .boolean => .LOGICAL_TYPE_ID_BOOLEAN,
            .i8 => .LOGICAL_TYPE_ID_TINYINT,
            .i16 => .LOGICAL_TYPE_ID_SMALLINT,
            .i32 => .LOGICAL_TYPE_ID_INTEGER,
            .i64 => .LOGICAL_TYPE_ID_BIGINT,
            .u8 => .LOGICAL_TYPE_ID_UTINYINT,
            .u16 => .LOGICAL_TYPE_ID_USMALLINT,
            .u32 => .LOGICAL_TYPE_ID_UINTEGER,
            .u64 => .LOGICAL_TYPE_ID_UBIGINT,
            .f32 => .LOGICAL_TYPE_ID_FLOAT,
            .f64 => .LOGICAL_TYPE_ID_DOUBLE,
            .date => .LOGICAL_TYPE_ID_DATE,
            .timestamp => .LOGICAL_TYPE_ID_TIMESTAMP,
            .varchar => .LOGICAL_TYPE_ID_VARCHAR,
        };
    }

    /// The kind a column in a file maps to, if any.
    fn fromField(f: arrow.Field) ?Kind {
        for (std.enums.values(Kind)) |k| {
            if (k.matches(f)) return k;
        }
        return null;
    }

    fn sqlName(self: Kind) []const u8 {
        return switch (self) {
            .boolean => "BOOLEAN",
            .i8 => "TINYINT",
            .i16 => "SMALLINT",
            .i32 => "INTEGER",
            .i64 => "BIGINT",
            .u8 => "UTINYINT",
            .u16 => "USMALLINT",
            .u32 => "UINTEGER",
            .u64 => "UBIGINT",
            .f32 => "FLOAT",
            .f64 => "DOUBLE",
            .date => "DATE",
            .timestamp => "TIMESTAMP",
            .varchar => "VARCHAR",
        };
    }

    /// Bytes per value in a DuckDB vector and in the Arrow values buffer: the same for every fixed-width kind.
    /// (A BOOLEAN is a byte in a vector and a bit in Arrow, a VARCHAR is neither.)
    fn width(self: Kind) usize {
        return switch (self) {
            .boolean, .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32, .date => 4,
            .i64, .u64, .f64, .timestamp => 8,
            .varchar => 0,
        };
    }

    /// The Arrow type, as the library describes one. Units are Arrow's: float 1 is single and 2 is double precision,
    /// date 0 is days, timestamp 2 is microseconds.
    fn arrowField(self: Kind) arrow.Field {
        var f: arrow.Field = .{};
        switch (self) {
            .boolean => f.kind = .bool,
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => {
                f.kind = .int;
                f.bit_width = @intCast(self.width() * 8);
                f.is_signed = switch (self) {
                    .i8, .i16, .i32, .i64 => true,
                    else => false,
                };
            },
            .f32 => {
                f.kind = .float;
                f.unit = 1;
            },
            .f64 => {
                f.kind = .float;
                f.unit = 2;
            },
            .date => {
                f.kind = .date;
                f.unit = 0;
            },
            .timestamp => {
                f.kind = .timestamp;
                f.unit = 2;
            },
            .varchar => f.kind = .utf8,
        }
        return f;
    }

    /// Whether a column read from a file is this kind. The attributes that matter depend on the Arrow type.
    fn matches(self: Kind, f: arrow.Field) bool {
        const want = self.arrowField();
        if (f.kind != want.kind or f.dict_id >= 0) return false;
        return switch (want.kind) {
            .int => f.bit_width == want.bit_width and f.is_signed == want.is_signed,
            .float, .date => f.unit == want.unit,
            .timestamp => f.unit == want.unit and f.timezone < 0, // a time zone would be a TIMESTAMPTZ
            else => true,
        };
    }
};

/// The kind of every column, or null after failing the statement because one has a type the recipe does not move.
fn kindsOf(arena: std.mem.Allocator, types: []const v2.duckdb_v2_logical_type_handle, names: ?[]const []const u8, err: Err) ?[]Kind {
    const kinds = arena.alloc(Kind, types.len) catch {
        oom(err);
        return null;
    };
    for (types, 0..) |ty, i| {
        var id: v2.DUCKDB_V2_LOGICAL_TYPE_ID = undefined;
        if (v2.duckdb_v2_logical_type_get_id(ty, &id, err) != .ERROR_NONE) return null;
        kinds[i] = Kind.fromId(id) orelse {
            if (names) |n| {
                fail(err, .ERROR_TYPE_INVALID, format_name ++ ": column {s} has a type that is not supported (BOOLEAN, integers, FLOAT, DOUBLE, DATE, TIMESTAMP and VARCHAR are)", .{n[i]});
            } else {
                fail(err, .ERROR_TYPE_INVALID, format_name ++ ": column {d} has a type that is not supported (BOOLEAN, integers, FLOAT, DOUBLE, DATE, TIMESTAMP and VARCHAR are)", .{i + 1});
            }
            return null;
        };
    }
    return kinds;
}

// --- options ------------------------------------------------------------------------------------------------------

const Options = struct {
    codec: ?arrow.Codec = null,
};

/// The statement's options, `FORMAT` excluded (DuckDB consumed it). Only the writer has one: `CODEC 'none'|'lz4'|'zstd'`.
fn readOptions(comptime side: enum { to, from }, info: anytype, err: Err) ?Options {
    const count_fn = if (side == .to) v2.duckdb_v2_copy_to_bind_get_option_count else v2.duckdb_v2_copy_from_bind_get_option_count;
    const name_fn = if (side == .to) v2.duckdb_v2_copy_to_bind_get_option_name else v2.duckdb_v2_copy_from_bind_get_option_name;
    const value_fn = if (side == .to) v2.duckdb_v2_copy_to_bind_get_option_value else v2.duckdb_v2_copy_from_bind_get_option_value;

    var options: Options = .{};
    var count: u64 = 0;
    if (count_fn(info, &count, err) != .ERROR_NONE) return null;
    for (0..count) |i| {
        var name: v2.duckdb_v2_identifier_t = undefined;
        if (name_fn(info, i, &name, err) != .ERROR_NONE) return null;
        const key = spanOf(name);
        if (side == .to and std.ascii.eqlIgnoreCase(key, "codec")) {
            var value: v2.duckdb_v2_value_handle = undefined;
            if (value_fn(info, i, &value, err) != .ERROR_NONE) return null;
            defer _ = v2.duckdb_v2_value_destroy(&value);
            var text: v2.duckdb_v2_str = undefined;
            if (v2.duckdb_v2_value_get_varchar(value, &text, err) != .ERROR_NONE) return null;
            const s = spanOf(text);
            if (std.ascii.eqlIgnoreCase(s, "none")) {
                options.codec = null;
            } else if (std.ascii.eqlIgnoreCase(s, "lz4")) {
                options.codec = .lz4;
            } else if (std.ascii.eqlIgnoreCase(s, "zstd")) {
                options.codec = .zstd;
            } else {
                fail(err, .ERROR_INPUT_PARAMETER_INVALID, format_name ++ ": CODEC must be 'none', 'lz4' or 'zstd', not '{s}'", .{s});
                return null;
            }
        } else {
            const known = if (side == .to) " (CODEC exists)" else " (there are none)";
            fail(err, .ERROR_INPUT_PARAMETER_INVALID, format_name ++ ": unknown option {s}" ++ known, .{key});
            return null;
        }
    }
    return options;
}

// --- COPY ... TO --------------------------------------------------------------------------------------------------

const ToBind = struct {
    arena: std.heap.ArenaAllocator,
    options: Options,
    names: []const []const u8,
    kinds: []const Kind,
    /// Owned handles, destroyed with the bind data; the slice grows as the handles are fetched, so that a failure half
    /// way destroys exactly those.
    types: []v2.duckdb_v2_logical_type_handle,
};

fn destroyToBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `toBind` stored a `*ToBind`.
    const data: *ToBind = @ptrCast(@alignCast(ptr));
    for (data.types) |*t| _ = v2.duckdb_v2_logical_type_destroy(t);
    data.arena.deinit();
    gpa.destroy(data);
}

fn toBind(info: v2.duckdb_v2_copy_to_bind_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    const data = gpa.create(ToBind) catch return oom(err);
    data.* = .{ .arena = .init(gpa), .options = .{}, .names = &.{}, .kinds = &.{}, .types = &.{} };
    var keep = false;
    defer if (!keep) destroyToBind(data);
    const arena = data.arena.allocator();

    data.options = readOptions(.to, info, err) orelse return;

    var count: u64 = 0;
    if (v2.duckdb_v2_copy_to_bind_get_column_count(info, &count, err) != .ERROR_NONE) return;
    const names = arena.alloc([]const u8, count) catch return oom(err);
    const types = arena.alloc(v2.duckdb_v2_logical_type_handle, count) catch return oom(err);
    data.types = types[0..0];
    for (0..count) |i| {
        var name: v2.duckdb_v2_identifier_t = undefined;
        if (v2.duckdb_v2_copy_to_bind_get_column_name(info, i, &name, err) != .ERROR_NONE) return;
        names[i] = arena.dupe(u8, spanOf(name)) catch return oom(err);
        if (v2.duckdb_v2_copy_to_bind_get_column_type(info, i, &types[i], err) != .ERROR_NONE) return;
        data.types = types[0 .. i + 1];
    }
    data.names = names;
    // Planning is when an unsupported column is reported, before any file is created.
    data.kinds = kindsOf(arena, types, names, err) orelse return;

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyToBind, .equals = null };
    if (v2.duckdb_v2_copy_to_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

/// Rows per batch when the statement does not say (`BATCH_SIZE`). Each becomes one Arrow record batch.
const rows_per_batch = 8192;

fn toBatchSize(info: v2.duckdb_v2_copy_to_batch_size_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    _ = v2.duckdb_v2_copy_to_batch_size_set_target(info, rows_per_batch, err);
}

/// Per output file. Only the flush and finalize callbacks touch it, and never at the same time.
const ToFile = struct {
    file: *anyopaque,
    closed: bool = false,
    /// The stream being assembled: the schema now, a record batch per flush, encoded in finalize.
    columnar: arrow.Columnar,
    /// The field of each column in `columnar`.
    field_ids: []usize,
    codec: ?arrow.Codec,
};

fn destroyToFile(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `toInit` stored a `*ToFile`.
    const data: *ToFile = @ptrCast(@alignCast(ptr));
    if (!data.closed) _ = fclose(data.file); // finalize closes it; this is for a statement that failed first
    data.columnar.deinit();
    gpa.free(data.field_ids);
    gpa.destroy(data);
}

fn toInit(info: v2.duckdb_v2_copy_to_init_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_to_init_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `toBind` stored a `*ToBind`.
    const bound: *const ToBind = @ptrCast(@alignCast(bind_ptr.?));

    var path: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_copy_to_init_get_file_path(info, &path, err) != .ERROR_NONE) return;
    const c_path = gpa.dupeSentinel(u8, spanOf(path), 0) catch return oom(err);
    defer gpa.free(c_path);
    const file = fopen(c_path, "wb") orelse return fail(err, .ERROR_IO_GENERAL, format_name ++ ": cannot open {s} for writing", .{c_path});

    const data = gpa.create(ToFile) catch {
        _ = fclose(file);
        return oom(err);
    };
    data.* = .{ .file = file, .columnar = .init(gpa), .field_ids = &.{}, .codec = bound.options.codec };
    var keep = false;
    defer if (!keep) destroyToFile(data);

    // The schema: one Arrow field per column, in the library's model.
    data.field_ids = gpa.alloc(usize, bound.kinds.len) catch return oom(err);
    for (bound.kinds, bound.names, 0..) |kind, name, i| {
        var field = kind.arrowField();
        field.name = @intCast(data.columnar.intern(name) catch return oom(err));
        data.field_ids[i] = data.columnar.addField(field) catch return oom(err);
        data.columnar.addTop(data.field_ids[i]) catch return oom(err);
    }

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyToFile, .equals = null };
    if (v2.duckdb_v2_copy_to_init_set_init_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

/// One column of a batch, as Arrow wants it.
const Column = struct {
    /// Validity bitmap: bit `i` set when row `i` is not NULL.
    valid: std.ArrayList(u8) = .empty,
    nulls: i64 = 0,
    /// The values: raw little-endian for the fixed-width kinds, a bitmap for BOOLEAN, the offsets for VARCHAR.
    values: std.ArrayList(u8) = .empty,
    /// VARCHAR only: the text of all rows, back to back.
    chars: std.ArrayList(u8) = .empty,
};

/// A batch, prepared: what the batch callback hands to the flush callback.
const Part = struct {
    rows: usize = 0,
    columns: []Column,
};

fn destroyPart(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `toBatch` stored a `*Part`.
    const part: *Part = @ptrCast(@alignCast(ptr));
    for (part.columns) |*c| {
        c.valid.deinit(gpa);
        c.values.deinit(gpa);
        c.chars.deinit(gpa);
    }
    gpa.free(part.columns);
    gpa.destroy(part);
}

/// Sets bit `i` of a bitmap that grows a byte at a time; the bits are appended in order.
fn pushBit(bits: *std.ArrayList(u8), i: usize, on: bool) !void {
    if (i % 8 == 0) try bits.append(gpa, 0);
    if (on) bits.items[i / 8] |= @as(u8, 1) << @intCast(i % 8);
}

/// Appends the rows of one chunk to the batch's columns.
fn appendChunk(part: *Part, kinds: []const Kind, chunk: v2.duckdb_v2_data_chunk_handle, rows: usize, err: Err) bool {
    for (kinds, part.columns, 0..) |kind, *col, c| {
        var vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vec, err) != .ERROR_NONE) return false;
        // A vector can be constant or dictionary-shaped; flattening makes it a plain array.
        if (v2.duckdb_v2_vector_flatten(vec, err) != .ERROR_NONE) return false;
        var view: v2.duckdb_v2_vector_view = undefined;
        if (v2.duckdb_v2_vector_get_view(vec, &view, err) != .ERROR_NONE) return false;
        const data = view.data orelse return false;

        const first = part.rows;
        for (0..rows) |row| {
            const valid = helpers.isValid(view.validity, row);
            pushBit(&col.valid, first + row, valid) catch return oomFalse(err);
            if (!valid) col.nulls += 1;
        }

        switch (kind) {
            .boolean => {
                const bools: [*]const u8 = @ptrCast(data);
                for (0..rows) |row| {
                    const on = helpers.isValid(view.validity, row) and bools[row] != 0;
                    pushBit(&col.values, first + row, on) catch return oomFalse(err);
                }
            },
            .varchar => {
                const texts: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(data));
                for (0..rows) |row| {
                    if (helpers.isValid(view.validity, row)) col.chars.appendSlice(gpa, helpers.bytesSlice(&texts[row])) catch return oomFalse(err);
                    if (col.chars.items.len > std.math.maxInt(i32)) {
                        fail(err, .ERROR_INPUT_OBJECT_SIZE, format_name ++ ": a batch holds more than 2 GiB of text in one column; lower BATCH_SIZE", .{});
                        return false;
                    }
                    var offset: [4]u8 = undefined;
                    std.mem.writeInt(i32, &offset, @intCast(col.chars.items.len), .little);
                    col.values.appendSlice(gpa, &offset) catch return oomFalse(err);
                }
            },
            else => {
                // The same bytes in a vector and in Arrow: copy them whole, then blank what is NULL
                // (a vector leaves those bytes undefined, and a stream should not depend on them).
                const w = kind.width();
                const bytes: [*]const u8 = @ptrCast(data);
                const at = col.values.items.len;
                col.values.appendSlice(gpa, bytes[0 .. rows * w]) catch return oomFalse(err);
                for (0..rows) |row| {
                    if (!helpers.isValid(view.validity, row)) @memset(col.values.items[at + row * w ..][0..w], 0);
                }
            },
        }
    }
    part.rows += rows;
    return true;
}

fn oomFalse(err: Err) bool {
    oom(err);
    return false;
}

fn toBatch(info: v2.duckdb_v2_copy_to_batch_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_to_batch_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `toBind` stored a `*ToBind`; read only here, since batches are prepared concurrently.
    const bound: *const ToBind = @ptrCast(@alignCast(bind_ptr.?));

    // The rows of the batch are ours now, to be destroyed when done.
    var collection: v2.duckdb_v2_column_data_collection_handle = undefined;
    if (v2.duckdb_v2_copy_to_batch_take_input(info, &collection, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_column_data_collection_destroy(&collection);

    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (helpers.createDataChunk(context, bound.types, &chunk, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_data_chunk_destroy(&chunk);
    var shared: v2.duckdb_v2_column_data_collection_shared_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared);
    var worker: v2.duckdb_v2_column_data_collection_worker_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker);

    const part = gpa.create(Part) catch return oom(err);
    part.* = .{ .columns = gpa.alloc(Column, bound.kinds.len) catch {
        gpa.destroy(part);
        return oom(err);
    } };
    @memset(part.columns, .{});
    var keep = false;
    defer if (!keep) destroyPart(part);
    // The offsets of a VARCHAR column start with 0, even for no rows.
    for (bound.kinds, part.columns) |kind, *col| {
        if (kind == .varchar) col.values.appendNTimes(gpa, 0, 4) catch return oom(err);
    }

    while (true) {
        var produced = false;
        if (v2.duckdb_v2_column_data_collection_scan(collection, shared, worker, chunk, &produced, err) != .ERROR_NONE) return;
        if (!produced) break;
        var rows: u64 = 0;
        if (v2.duckdb_v2_data_chunk_get_size(chunk, &rows, err) != .ERROR_NONE) return;
        if (!appendChunk(part, bound.kinds, chunk, rows, err)) return;
    }

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = part, .destroy = destroyPart, .equals = null };
    if (v2.duckdb_v2_copy_to_batch_set_batch_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

fn toFlush(info: v2.duckdb_v2_copy_to_flush_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var init_ptr: ?*anyopaque = null;
    var batch_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_to_flush_get_init_data(info, &init_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_copy_to_flush_get_batch_data(info, &batch_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `toInit` stored a `*ToFile` and `toBatch` a `*Part`.
    const file: *ToFile = @ptrCast(@alignCast(init_ptr.?));
    const part: *const Part = @ptrCast(@alignCast(batch_ptr.?));
    if (part.rows == 0) return;

    // The library copies the buffers it is given, so the part is still DuckDB's to destroy.
    var arrays: std.ArrayList(usize) = .empty;
    defer arrays.deinit(gpa);
    const kinds_len = part.columns.len;
    for (part.columns, 0..) |col, i| {
        const is_text = file.columnar.fields.items[file.field_ids[i]].kind == .utf8;
        // No validity buffer when nothing is NULL, as Arrow writers usually do.
        const valid: []const u8 = if (col.nulls == 0) &.{} else col.valid.items;
        const array = (if (is_text)
            file.columnar.addArray(@intCast(part.rows), col.nulls, file.field_ids[i], &.{ valid, col.values.items, col.chars.items }, &.{})
        else
            file.columnar.addArray(@intCast(part.rows), col.nulls, file.field_ids[i], &.{ valid, col.values.items }, &.{})) catch return oom(err);
        arrays.append(gpa, array) catch return oom(err);
    }
    std.debug.assert(arrays.items.len == kinds_len);
    file.columnar.addBatch(@intCast(part.rows), arrays.items, file.codec) catch return oom(err);
}

fn toFinalize(info: v2.duckdb_v2_copy_to_finalize_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var init_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_to_finalize_get_init_data(info, &init_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `toInit` stored a `*ToFile`.
    const file: *ToFile = @ptrCast(@alignCast(init_ptr.?));

    const stream = arrow.encodeStream(gpa, &file.columnar) catch |e| return fail(err, .ERROR_IO_GENERAL, format_name ++ ": encoding failed ({s})", .{@errorName(e)});
    defer gpa.free(stream);
    const written = fwrite(stream.ptr, 1, stream.len, file.file);
    file.closed = true;
    const closed = fclose(file.file);
    if (written != stream.len or closed != 0) fail(err, .ERROR_IO_GENERAL, format_name ++ ": writing the file failed", .{});
}

// --- COPY ... FROM ------------------------------------------------------------------------------------------------

const FromBind = struct {
    arena: std.heap.ArenaAllocator,
    /// The file, which `columnar` borrows from (the library decodes in place).
    bytes: []u8,
    columnar: arrow.Columnar,
    kinds: []const Kind,
    types: []v2.duckdb_v2_logical_type_handle,
    rows: u64,
};

fn destroyFromBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `fromBind` stored a `*FromBind`.
    const data: *FromBind = @ptrCast(@alignCast(ptr));
    for (data.types) |*t| _ = v2.duckdb_v2_logical_type_destroy(t);
    data.columnar.deinit();
    gpa.free(data.bytes);
    data.arena.deinit();
    gpa.destroy(data);
}

fn readFile(path: [:0]const u8, err: Err) ?[]u8 {
    const file = fopen(path, "rb") orelse {
        fail(err, .ERROR_IO_FILE_NOT_FOUND, format_name ++ ": cannot open {s}", .{path});
        return null;
    };
    defer _ = fclose(file);
    var bytes: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        bytes.appendSlice(gpa, buf[0..n]) catch {
            bytes.deinit(gpa);
            oom(err);
            return null;
        };
    }
    return bytes.toOwnedSlice(gpa) catch {
        oom(err);
        return null;
    };
}

fn fieldName(c: *const arrow.Columnar, f: arrow.Field) []const u8 {
    return if (f.name >= 0) c.str(@intCast(f.name)) else "?";
}

/// An Arrow type for a message: its kind, with the width or unit that tells apart what DuckDB has one type for.
fn describe(buf: []u8, f: arrow.Field) []const u8 {
    const text = switch (f.kind) {
        .int => std.fmt.bufPrint(buf, "{s}int{d}", .{ if (f.is_signed) "" else "u", f.bit_width }),
        .float => std.fmt.bufPrint(buf, "float{d}", .{@as(u8, switch (f.unit) {
            0 => 16,
            1 => 32,
            else => 64,
        })}),
        .date => std.fmt.bufPrint(buf, "date{s}", .{if (f.unit == 0) "32" else "64"}),
        .timestamp => std.fmt.bufPrint(buf, "timestamp[{s}{s}]", .{ switch (f.unit) {
            0 => "s",
            1 => "ms",
            2 => "us",
            else => "ns",
        }, if (f.timezone >= 0) ", with a time zone" else "" }),
        else => std.fmt.bufPrint(buf, "{s}", .{@tagName(f.kind)}),
    };
    return text catch @tagName(f.kind);
}

/// Fails the statement unless the file's columns are the table's, by position and type.
fn checkSchema(c: *const arrow.Columnar, kinds: []const Kind, err: Err) bool {
    if (c.top.items.len != kinds.len) {
        fail(err, .ERROR_INPUT_INVALID, format_name ++ ": the file has {d} columns, the table {d}", .{ c.top.items.len, kinds.len });
        return false;
    }
    for (kinds, c.top.items, 0..) |kind, field_id, i| {
        const f = c.fields.items[field_id];
        if (!kind.matches(f)) {
            var buf: [32]u8 = undefined;
            const dictionary: []const u8 = if (f.dict_id >= 0) " (dictionary-encoded)" else "";
            fail(err, .ERROR_TYPE_MISMATCH, format_name ++ ": column {d} ({s}) is {s}{s} in the file; the table expects {s}", .{ i + 1, fieldName(c, f), describe(&buf, f), dictionary, kind.sqlName() });
            return false;
        }
    }
    return true;
}

/// Reads and decodes the file into `data`, which owns the bytes and the decoded tables from then on.
fn loadFile(data: *FromBind, path: [:0]const u8, err: Err) bool {
    data.bytes = readFile(path, err) orelse return false;
    const decoded = (if (std.mem.startsWith(u8, data.bytes, "ARROW1")) arrow.decodeFile(gpa, data.bytes) else arrow.decodeStream(gpa, data.bytes));
    data.columnar = decoded catch |e| {
        fail(err, .ERROR_INPUT_INVALID, format_name ++ ": {s} is not a readable Arrow IPC stream or file ({s})", .{ path, @errorName(e) });
        return false;
    };
    for (data.columnar.batches.items) |b| data.rows += @intCast(b.length);
    return true;
}

fn fromBind(info: v2.duckdb_v2_copy_from_bind_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    const data = gpa.create(FromBind) catch return oom(err);
    data.* = .{ .arena = .init(gpa), .bytes = &.{}, .columnar = .init(gpa), .kinds = &.{}, .types = &.{}, .rows = 0 };
    var keep = false;
    defer if (!keep) destroyFromBind(data);
    const arena = data.arena.allocator();

    _ = readOptions(.from, info, err) orelse return;
    var path: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_copy_from_bind_get_file_path(info, &path, err) != .ERROR_NONE) return;
    const c_path = arena.dupeSentinel(u8, spanOf(path), 0) catch return oom(err);

    // The columns are the table's: the file has to supply them as they are.
    var count: u64 = 0;
    if (v2.duckdb_v2_copy_from_bind_get_column_count(info, &count, err) != .ERROR_NONE) return;
    const types = arena.alloc(v2.duckdb_v2_logical_type_handle, count) catch return oom(err);
    data.types = types[0..0];
    for (0..count) |i| {
        if (v2.duckdb_v2_copy_from_bind_get_column_type(info, i, &types[i], err) != .ERROR_NONE) return;
        data.types = types[0 .. i + 1];
    }
    data.kinds = kindsOf(arena, types, null, err) orelse return;

    // Reading the file now means a bad file is reported while the statement is planned, and the exact row count is
    // known for the optimizer.
    if (!loadFile(data, c_path, err)) return;
    if (!checkSchema(&data.columnar, data.kinds, err)) return;
    if (v2.duckdb_v2_copy_from_bind_set_cardinality(info, data.rows, true, err) != .ERROR_NONE) return;

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyFromBind, .equals = null };
    if (v2.duckdb_v2_copy_from_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

/// Where the read is. One thread reads, and the progress callback reads `done` from another.
const FromState = struct {
    batch: usize = 0,
    row: usize = 0,
    total: u64 = 0,
    done: std.atomic.Value(u64) = .init(0),
};

fn destroyFromState(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `fromInitGlobal` stored a `*FromState`.
    gpa.destroy(@as(*FromState, @ptrCast(@alignCast(ptr))));
}

fn fromInitGlobal(info: v2.duckdb_v2_copy_from_init_global_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_from_init_global_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `fromBind` stored a `*FromBind`.
    const bound: *const FromBind = @ptrCast(@alignCast(bind_ptr.?));
    // The cursor is shared state with no per-thread part in a COPY FROM, so one thread reads.
    if (v2.duckdb_v2_copy_from_init_global_set_max_threads(info, 1, err) != .ERROR_NONE) return;
    const state = gpa.create(FromState) catch return oom(err);
    state.* = .{ .total = bound.rows };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyFromState, .equals = null };
    if (v2.duckdb_v2_copy_from_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyFromState(state);
}

fn bitAt(bits: []const u8, i: usize) bool {
    return (bits[i / 8] >> @intCast(i % 8)) & 1 != 0;
}

/// Whether row `i` of an array is valid. An empty validity buffer means that all are.
fn validAt(valid: []const u8, i: usize) bool {
    return valid.len == 0 or bitAt(valid, i);
}

/// Copies `n` rows of an Arrow array, from row `from`, into a DuckDB vector of the same kind.
fn fillVector(kind: Kind, c: *const arrow.Columnar, array: usize, from: usize, n: usize, vec: v2.duckdb_v2_vector_handle, err: Err) bool {
    const truncated = format_name ++ ": the file is truncated";
    if (v2.duckdb_v2_vector_set_size(vec, n, err) != .ERROR_NONE) return false;
    var out_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(vec, &out_ptr, err) != .ERROR_NONE) return false;
    const valid = c.arrayBuf(array, 0);
    const values = c.arrayBuf(array, 1);

    switch (kind) {
        .boolean => {
            if (values.len < (from + n + 7) / 8) return failFalse(err, truncated);
            const out: [*]u8 = @ptrCast(out_ptr.?);
            for (0..n) |i| out[i] = @intFromBool(bitAt(values, from + i));
        },
        .varchar => {
            if (values.len < (from + n + 1) * 4) return failFalse(err, truncated);
            const chars = c.arrayBuf(array, 2);
            const arena_handle = blk: {
                var a: v2.duckdb_v2_arena_handle = undefined;
                if (v2.duckdb_v2_vector_get_arena(vec, &a, err) != .ERROR_NONE) return false;
                break :blk a;
            };
            const out: [*]v2.duckdb_v2_bytes = @ptrCast(@alignCast(out_ptr.?));
            for (0..n) |i| {
                if (!validAt(valid, from + i)) continue; // set below, with the other NULLs
                const begin = std.mem.readInt(i32, values[(from + i) * 4 ..][0..4], .little);
                const end = std.mem.readInt(i32, values[(from + i + 1) * 4 ..][0..4], .little);
                if (begin < 0 or end < begin or end > chars.len) return failFalse(err, truncated);
                const text = chars[@intCast(begin)..@intCast(end)];
                // DuckDB's VARCHAR holds valid UTF-8 and nothing checks it later.
                if (!std.unicode.utf8ValidateSlice(text)) return failFalse(err, format_name ++ ": a string in the file is not valid UTF-8");
                out[i] = helpers.makeBytesValue(arena_handle, text, err) catch return false;
            }
        },
        else => {
            const w = kind.width();
            if (values.len < (from + n) * w) return failFalse(err, truncated);
            const out: [*]u8 = @ptrCast(out_ptr.?);
            @memcpy(out[0 .. n * w], values[from * w ..][0 .. n * w]);
        },
    }
    for (0..n) |i| {
        if (!validAt(valid, from + i) and v2.duckdb_v2_vector_set_null(vec, i, err) != .ERROR_NONE) return false;
    }
    return true;
}

fn failFalse(err: Err, comptime msg: []const u8) bool {
    fail(err, .ERROR_INPUT_INVALID, msg, .{});
    return false;
}

fn fromExec(info: v2.duckdb_v2_copy_from_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    var state_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_from_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_copy_from_exec_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
    // SAFETY: the types stored by `fromBind` and `fromInitGlobal`.
    const bound: *const FromBind = @ptrCast(@alignCast(bind_ptr.?));
    const state: *FromState = @ptrCast(@alignCast(state_ptr.?));

    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_copy_from_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
    fillChunk(bound, state, chunk, err);
}

/// Fills the chunk with the next rows of the file, up to a vector's worth, and moves the cursor past them.
fn fillChunk(bound: *const FromBind, state: *FromState, chunk: v2.duckdb_v2_data_chunk_handle, err: Err) void {
    // The next record batch that still has rows. Past the last, the chunk stays empty, which ends the read.
    const batches = bound.columnar.batches.items;
    while (state.batch < batches.len and state.row >= @as(usize, @intCast(batches[state.batch].length))) {
        state.batch += 1;
        state.row = 0;
    }
    var n: usize = 0;
    if (state.batch < batches.len) n = @min(vector_size, @as(usize, @intCast(batches[state.batch].length)) - state.row);

    for (bound.kinds, 0..) |kind, c| {
        var vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vec, err) != .ERROR_NONE) return;
        if (n == 0) {
            if (v2.duckdb_v2_vector_set_size(vec, 0, err) != .ERROR_NONE) return;
            continue;
        }
        const array = bound.columnar.batchCol(state.batch, c);
        if (!fillVector(kind, &bound.columnar, array, state.row, n, vec, err)) return;
    }
    state.row += n;
    _ = state.done.fetchAdd(n, .monotonic);
}

/// Rows in a DuckDB vector (the default `STANDARD_VECTOR_SIZE`): the most a chunk holds.
const vector_size = 2048;

/// Runs on another thread while `fromExec` does: only the atomic count is read.
fn fromProgress(info: v2.duckdb_v2_copy_from_progress_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var state_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_from_progress_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `fromInitGlobal` stored a `*FromState`.
    const state: *FromState = @ptrCast(@alignCast(state_ptr.?));
    const total: f64 = @floatFromInt(@max(state.total, 1));
    const done: f64 = @floatFromInt(state.done.load(.monotonic));
    _ = v2.duckdb_v2_copy_from_progress_set_progress(info, done / total, err);
}

// --- zig_cookbook_read_arrow(path) --------------------------------------------------------------------------------

// The same decode and the same chunk filling, as a table function: the table's columns are not known, so the file
// says what they are. `bind` names and types the result columns from the file's schema.

fn readBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    const data = gpa.create(FromBind) catch return oom(err);
    data.* = .{ .arena = .init(gpa), .bytes = &.{}, .columnar = .init(gpa), .kinds = &.{}, .types = &.{}, .rows = 0 };
    var keep = false;
    defer if (!keep) destroyFromBind(data);
    const arena = data.arena.allocator();

    var value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, 0, &value, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var text: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_value_get_varchar(value, &text, err) != .ERROR_NONE) return;
    const path = arena.dupeSentinel(u8, spanOf(text), 0) catch return oom(err);
    if (!loadFile(data, path, err)) return;

    const c = &data.columnar;
    const kinds = arena.alloc(Kind, c.top.items.len) catch return oom(err);
    data.kinds = kinds;
    for (c.top.items, 0..) |field_id, i| {
        const f = c.fields.items[field_id];
        kinds[i] = Kind.fromField(f) orelse {
            var buf: [32]u8 = undefined;
            const dictionary: []const u8 = if (f.dict_id >= 0) " (dictionary-encoded)" else "";
            return fail(err, .ERROR_TYPE_INVALID, format_name ++ ": column {d} ({s}) is {s}{s} in the file, which is not supported", .{ i + 1, fieldName(c, f), describe(&buf, f), dictionary });
        };
        var ty: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(context, kinds[i].typeId(), &ty, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_logical_type_destroy(&ty);
        const name = helpers.str(fieldName(c, f));
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &name, ty, err) != .ERROR_NONE) return;
    }
    if (v2.duckdb_v2_table_function_bind_set_cardinality(result, data.rows, true, err) != .ERROR_NONE) return;

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyFromBind, .equals = null };
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

fn readInitGlobal(info: v2.duckdb_v2_table_function_init_global_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    // One cursor, no local state: one thread reads.
    if (v2.duckdb_v2_table_function_init_global_set_max_threads(info, 1, err) != .ERROR_NONE) return;
    const state = gpa.create(FromState) catch return oom(err);
    state.* = .{};
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyFromState, .equals = null };
    if (v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyFromState(state);
}

fn readExec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    var state_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
    // SAFETY: the types stored by `readBind` and `readInitGlobal`.
    const bound: *const FromBind = @ptrCast(@alignCast(bind_ptr.?));
    const state: *FromState = @ptrCast(@alignCast(state_ptr.?));
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
    fillChunk(bound, state, chunk, err);
}

fn registerRead(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);
    const name = helpers.str("zig_cookbook_read_arrow");
    if (v2.duckdb_v2_table_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;

    var varchar: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const path_name = helpers.str("path");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &path_name, varchar, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;

    if (v2.duckdb_v2_table_function_set_bind_callback(function, &readBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &readInitGlobal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &readExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_register(function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

fn registerCopy(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_copy_function_handle = undefined;
    if (v2.duckdb_v2_copy_function_create_with_extension(input.extension, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_copy_function_destroy(&function);
    const name = helpers.str(format_name);
    if (v2.duckdb_v2_copy_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;

    if (v2.duckdb_v2_copy_to_set_bind_callback(function, &toBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_copy_to_set_batch_size_callback(function, &toBatchSize, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_copy_to_set_init_callback(function, &toInit, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_copy_to_set_batch_callback(function, &toBatch, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_copy_to_set_flush_callback(function, &toFlush, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_copy_to_set_finalize_callback(function, &toFinalize, err) != .ERROR_NONE) return error.FailedToSetCallback;

    if (v2.duckdb_v2_copy_from_set_bind_callback(function, &fromBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_copy_from_set_init_global_callback(function, &fromInitGlobal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_copy_from_set_exec_callback(function, &fromExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_copy_from_set_progress_callback(function, &fromProgress, err) != .ERROR_NONE) return error.FailedToSetCallback;

    if (v2.duckdb_v2_copy_function_register(function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the format. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerCopy(input, err);
    try registerRead(input, err);
}
