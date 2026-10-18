///! Cookbook: the Arrow C Data Interface, both ways, with the v2 API's `arrow_exporter_*` and `arrow_importer_*`.
///!
///! The C Data Interface is two C structs, `ArrowSchema` and `ArrowArray`, that programs in one process hand each
///! other (PyArrow, Arrow C++, DuckDB, a Zig library): pointers to buffers plus a `release` callback, no bytes on a
///! wire. (`arrow_ipc.zig` is the other Arrow recipe: IPC *files*, through a library.) DuckDB does the conversion
///! between its vectors and the structs; the extension's part is to feed it, read what comes out, or build the structs.
///!
///!   zig_cookbook_arrow_export(n BIGINT) -> (batch, col, format, length, null_count, n_buffers, checksum)
///!   zig_cookbook_arrow_import(n BIGINT, copy BOOLEAN := false) -> (id BIGINT, label VARCHAR, day DATE)
///!   zig_cookbook_arrow_live_arrays() -> BIGINT
///!
///! **Export.** `export` makes n rows of (BIGINT, VARCHAR with NULLs, BOOLEAN) as DuckDB chunks, feeds them to an
///! *exporter* and takes `ArrowArray`s out, a thousand rows each, whatever the chunk sizes were. For every column of
///! every array it reports what the struct says (`format` is Arrow's type string, `n_buffers` how many buffers the
///! layout has) and a checksum that Zig computes from the raw buffers: the sum of the valid BIGINTs, the bytes of the
///! strings (last offset minus first), the bits set in the booleans. That is the reading of the structs: a validity
///! bitmap that is absent when there are no NULLs, an `offset` into the buffers, offsets plus bytes for strings.
///!
///! **Import.** `import` builds an `ArrowSchema` and an `ArrowArray` by hand, from buffers that Zig allocated, and
///! gives them to an *importer*, which hands back chunks. With `consume` (the default here) the importer takes the
///! array over and the chunks point into Zig's buffers, which stay alive until DuckDB is done with the chunks, when
///! the array's `release` runs. With `copy := true` the chunks are copies and the array is released as soon as it was
///! read. The importer also names the result columns: its schema is DuckDB's reading of the Arrow format strings.
///!
///! `live_arrays` counts the hand-built arrays not yet freed, so a test can see that every one is released exactly once
///! (a release that never comes leaves the count up, one that comes twice is a crash).
///!
///! The rules for a producer of these structs, which `Owned` follows: `release` is called once, by whoever holds the
///! struct last; a struct that was moved has `release == null`; children are released with their parent. A consumer
///! may also release a child by itself, so the children share a reference count with the parent here.
///!
///! Neither function needs a connection: the exporter and importer are made from the *context* an extension has. The
///! `arrow_result_*` calls (a query's rows as Arrow) need a connection, so they are in the embedding recipe.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const Err = *v2.duckdb_v2_error_info_handle;
const gpa = std.heap.c_allocator;

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [300]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    const text = helpers.str(msg);
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = v2.duckdb_v2_error_info_set_text(err.*, &text);
}

fn oom(err: Err) void {
    fail(err, .ERROR_RESOURCE_OUT_OF_MEMORY, "out of memory", .{});
}

/// The rows a call can make: they sit in memory (and in the exporter's arrays) until the statement is bound.
const max_rows = 10_000_000;

fn argInt(info: v2.duckdb_v2_function_bind_info_handle, index: u64, err: Err) ?i64 {
    var value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, index, &value, err) != .ERROR_NONE) return null;
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var out: i64 = 0;
    if (v2.duckdb_v2_value_get_bigint(value, &out, err) != .ERROR_NONE) return null;
    return out;
}

fn argRows(info: v2.duckdb_v2_function_bind_info_handle, name: []const u8, err: Err) ?u64 {
    const n = argInt(info, 0, err) orelse return null;
    if (n < 0 or n > max_rows) {
        fail(err, .ERROR_INPUT_OUT_OF_RANGE, "{s}: n must be between 0 and {d}, got {d}", .{ name, max_rows, n });
        return null;
    }
    return @intCast(n);
}

fn createType(context: v2.duckdb_v2_context_handle, id: v2.DUCKDB_V2_LOGICAL_TYPE_ID, err: Err) ?v2.duckdb_v2_logical_type_handle {
    var t: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, id, &t, err) != .ERROR_NONE) return null;
    return t;
}

/// Where the scan is: one cursor and one thread, since the rows are already made.
const Cursor = struct { next: usize = 0 };

fn destroyCursor(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `initGlobal` stored a `*Cursor`.
    gpa.destroy(@as(*Cursor, @ptrCast(@alignCast(ptr))));
}

fn initGlobal(info: v2.duckdb_v2_table_function_init_global_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    if (v2.duckdb_v2_table_function_init_global_set_max_threads(info, 1, err) != .ERROR_NONE) return;
    const cursor = gpa.create(Cursor) catch return oom(err);
    cursor.* = .{};
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = cursor, .destroy = destroyCursor, .equals = null };
    if (v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyCursor(cursor);
}

// --- export: DuckDB chunks to ArrowArrays -------------------------------------------------------------------------

const export_name = "zig_cookbook_arrow_export";
const export_columns = [_][]const u8{ "batch", "col", "format", "length", "null_count", "n_buffers", "checksum" };
const export_batch_rows = 1000;
const chunk_rows = 2048;

/// One line of the report: a column of one exported array.
const Line = struct {
    batch: i64,
    col: []const u8,
    format: []const u8,
    length: i64,
    null_count: i64,
    n_buffers: i64,
    checksum: i64,
};

const ExportBind = struct {
    arena: std.heap.ArenaAllocator,
    lines: []const Line,
};

fn destroyExportBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `exportBind` stored an `*ExportBind`.
    const data: *ExportBind = @ptrCast(@alignCast(ptr));
    data.arena.deinit();
    gpa.destroy(data);
}

fn bitAt(bits: [*]const u8, i: usize) bool {
    return (bits[i / 8] >> @intCast(i % 8)) & 1 != 0;
}

/// A column of an `ArrowArray`, summed up from its buffers as the Arrow specification lays them out. The validity
/// buffer is a null pointer when no value is NULL, and the buffers are read from `offset` on.
fn checksum(format: []const u8, a: *const v2.ArrowArray) i64 {
    const buffers = a.buffers orelse return 0;
    const validity: ?[*]const u8 = @ptrCast(buffers[0]);
    const offset: usize = @intCast(a.offset);
    const length: usize = @intCast(a.length);
    const valid = struct {
        fn at(v: ?[*]const u8, i: usize) bool {
            return if (v) |bits| bitAt(bits, i) else true;
        }
    }.at;

    if (std.mem.eql(u8, format, "l")) {
        const values: [*]const i64 = @ptrCast(@alignCast(buffers[1].?));
        var sum: i64 = 0;
        for (offset..offset + length) |i| {
            if (valid(validity, i)) sum += values[i];
        }
        return sum;
    }
    if (std.mem.eql(u8, format, "u")) {
        // The bytes of a string are between its offset and the next one: the first and the last offset bound all.
        const offsets: [*]const i32 = @ptrCast(@alignCast(buffers[1].?));
        return offsets[offset + length] - offsets[offset];
    }
    if (std.mem.eql(u8, format, "b")) {
        const bits: [*]const u8 = @ptrCast(buffers[1].?);
        var set: i64 = 0;
        for (offset..offset + length) |i| {
            if (valid(validity, i) and bitAt(bits, i)) set += 1;
        }
        return set;
    }
    return 0; // a layout this report does not read (string views, for one)
}

fn spanZ(s: ?[*:0]const u8) []const u8 {
    return if (s) |p| std.mem.span(p) else "";
}

/// Reports the arrays of one struct array: the top level is a struct whose children are the columns.
fn reportArray(arena: std.mem.Allocator, lines: *std.ArrayList(Line), batch: i64, schema: *const v2.ArrowSchema, array: *const v2.ArrowArray) !void {
    const n: usize = @intCast(schema.n_children);
    for (0..n) |c| {
        const col_schema = schema.children.?[c].?;
        const col = array.children.?[c].?;
        const format = try arena.dupe(u8, spanZ(col_schema.format));
        try lines.append(arena, .{
            .batch = batch,
            .col = try arena.dupe(u8, spanZ(col_schema.name)),
            .format = format,
            .length = col.length,
            .null_count = col.null_count,
            .n_buffers = col.n_buffers,
            .checksum = checksum(format, col),
        });
    }
}

/// n rows of (id BIGINT, label VARCHAR, even BOOLEAN) from row `start`, as a chunk the caller owns.
fn makeChunk(context: v2.duckdb_v2_context_handle, types: []const v2.duckdb_v2_logical_type_handle, start: usize, rows: usize, err: Err) ?v2.duckdb_v2_data_chunk_handle {
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_data_chunk_create(helpers.factory(context, err) orelse return null, types.ptr, types.len, &chunk, err) != .ERROR_NONE) return null;
    errdefer _ = v2.duckdb_v2_data_chunk_destroy(&chunk);

    var vecs: [3]v2.duckdb_v2_vector_handle = undefined;
    var data: [3]?*anyopaque = undefined;
    for (0..3) |c| {
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vecs[c], err) != .ERROR_NONE) return null;
        if (v2.duckdb_v2_vector_set_size(vecs[c], rows, err) != .ERROR_NONE) return null;
        if (v2.duckdb_v2_vector_get_data_mutable(vecs[c], &data[c], err) != .ERROR_NONE) return null;
    }
    var arena: v2.duckdb_v2_arena_handle = undefined;
    if (v2.duckdb_v2_vector_get_arena(vecs[1], &arena, err) != .ERROR_NONE) return null;
    const ids: [*]i64 = @ptrCast(@alignCast(data[0].?));
    const labels: [*]v2.duckdb_v2_bytes = @ptrCast(@alignCast(data[1].?));
    const evens: [*]u8 = @ptrCast(data[2].?);
    for (0..rows) |i| {
        const row = start + i;
        ids[i] = @intCast(row);
        evens[i] = @intFromBool(row % 2 == 0);
        if (row % 3 == 0) {
            if (v2.duckdb_v2_vector_set_null(vecs[1], i, err) != .ERROR_NONE) return null;
        } else {
            var buf: [24]u8 = undefined;
            labels[i] = helpers.makeBytesValue(arena, std.fmt.bufPrint(&buf, "row-{d}", .{row}) catch unreachable, err) catch return null;
        }
    }
    return chunk;
}

fn exportBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    const rows = argRows(info, export_name, err) orelse return;

    const data = gpa.create(ExportBind) catch return oom(err);
    data.* = .{ .arena = .init(gpa), .lines = &.{} };
    var keep = false;
    defer if (!keep) destroyExportBind(data);
    const arena = data.arena.allocator();

    // The result's columns.
    const result_types = [_]v2.DUCKDB_V2_LOGICAL_TYPE_ID{ .LOGICAL_TYPE_ID_BIGINT, .LOGICAL_TYPE_ID_VARCHAR, .LOGICAL_TYPE_ID_VARCHAR, .LOGICAL_TYPE_ID_BIGINT, .LOGICAL_TYPE_ID_BIGINT, .LOGICAL_TYPE_ID_BIGINT, .LOGICAL_TYPE_ID_BIGINT };
    inline for (export_columns, result_types) |name, id| {
        var t = createType(context, id, err) orelse return;
        defer _ = v2.duckdb_v2_logical_type_destroy(&t);
        const column_name = helpers.str(name);
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &column_name, t, err) != .ERROR_NONE) return;
    }

    // The exporter: the columns it will be fed, with the rows an array holds at most.
    var types: [3]v2.duckdb_v2_logical_type_handle = undefined;
    var made: usize = 0;
    defer for (types[0..made]) |*t| {
        _ = v2.duckdb_v2_logical_type_destroy(t);
    };
    for ([_]v2.DUCKDB_V2_LOGICAL_TYPE_ID{ .LOGICAL_TYPE_ID_BIGINT, .LOGICAL_TYPE_ID_VARCHAR, .LOGICAL_TYPE_ID_BOOLEAN }) |id| {
        types[made] = createType(context, id, err) orelse return;
        made += 1;
    }
    const names = [_]v2.duckdb_v2_str{ helpers.str("id"), helpers.str("label"), helpers.str("even") };
    var exporter: v2.duckdb_v2_arrow_exporter_handle = undefined;
    if (v2.duckdb_v2_arrow_exporter_create(context, &types, &names, 3, export_batch_rows, &exporter, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_arrow_exporter_destroy(&exporter);

    // The schema is the same for every array. It is ours to release.
    var schema: v2.ArrowSchema = undefined;
    if (v2.duckdb_v2_arrow_exporter_get_schema(exporter, &schema, err) != .ERROR_NONE) return;
    defer if (schema.release) |release| release(&schema);

    var lines: std.ArrayList(Line) = .empty;
    var batch: i64 = 0;
    var start: usize = 0;
    while (start < rows) {
        const n = @min(chunk_rows, rows - start);
        var chunk = makeChunk(context, &types, start, n, err) orelse return;
        start += n;
        // `consume` hands the chunk over, so the exporter destroys it. The last one also ends the input: `flush`
        // finishes the rows that were waiting for a full batch.
        if (v2.duckdb_v2_arrow_exporter_append(exporter, &chunk, true, start == rows, err) != .ERROR_NONE) return;

        // Arrays that are complete. `release == null` is the "none ready" of the C Data Interface.
        while (true) {
            var array: v2.ArrowArray = undefined;
            if (v2.duckdb_v2_arrow_exporter_next_array(exporter, &array, err) != .ERROR_NONE) return;
            const release = array.release orelse break;
            defer release(&array);
            reportArray(arena, &lines, batch, &schema, &array) catch return oom(err);
            batch += 1;
        }
    }
    data.lines = lines.items;
    if (v2.duckdb_v2_table_function_bind_set_cardinality(result, lines.items.len, true, err) != .ERROR_NONE) return;

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyExportBind, .equals = null };
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

fn exportExec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    var cursor_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &cursor_ptr, err) != .ERROR_NONE) return;
    // SAFETY: the types stored by `exportBind` and `initGlobal`.
    const bound: *const ExportBind = @ptrCast(@alignCast(bind_ptr.?));
    const cursor: *Cursor = @ptrCast(@alignCast(cursor_ptr.?));
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;

    const n = @min(chunk_rows, bound.lines.len - cursor.next);
    const lines = bound.lines[cursor.next..][0..n];
    cursor.next += n;

    var vecs: [export_columns.len]v2.duckdb_v2_vector_handle = undefined;
    var data: [export_columns.len]?*anyopaque = undefined;
    for (0..export_columns.len) |c| {
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vecs[c], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(vecs[c], n, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_get_data_mutable(vecs[c], &data[c], err) != .ERROR_NONE) return;
    }
    var arena: v2.duckdb_v2_arena_handle = undefined;
    if (v2.duckdb_v2_vector_get_arena(vecs[1], &arena, err) != .ERROR_NONE) return;
    var format_arena: v2.duckdb_v2_arena_handle = undefined;
    if (v2.duckdb_v2_vector_get_arena(vecs[2], &format_arena, err) != .ERROR_NONE) return;
    const batches: [*]i64 = @ptrCast(@alignCast(data[0].?));
    const cols: [*]v2.duckdb_v2_bytes = @ptrCast(@alignCast(data[1].?));
    const formats: [*]v2.duckdb_v2_bytes = @ptrCast(@alignCast(data[2].?));
    const numbers = [_][*]i64{ @ptrCast(@alignCast(data[3].?)), @ptrCast(@alignCast(data[4].?)), @ptrCast(@alignCast(data[5].?)), @ptrCast(@alignCast(data[6].?)) };
    for (lines, 0..) |line, i| {
        batches[i] = line.batch;
        cols[i] = helpers.makeBytesValue(arena, line.col, err) catch return;
        formats[i] = helpers.makeBytesValue(format_arena, line.format, err) catch return;
        numbers[0][i] = line.length;
        numbers[1][i] = line.null_count;
        numbers[2][i] = line.n_buffers;
        numbers[3][i] = line.checksum;
    }
}

// --- import: ArrowArrays built by hand to DuckDB chunks -----------------------------------------------------------

const import_name = "zig_cookbook_arrow_import";
const import_columns = [_][:0]const u8{ "id", "label", "day" };
const import_batch_rows = 1000;

var live_arrays: std.atomic.Value(i64) = .init(0);

/// What a hand-built array stands on: the buffers, the structs that point into them, and the count of structs that
/// are still unreleased (the parent and its three children). Whoever releases the last one frees all.
const Owned = struct {
    refs: std.atomic.Value(usize) = .init(4),
    rows: usize,
    ids: []i64,
    day: []i32,
    label_valid: []u8,
    label_offsets: []i32,
    label_chars: []u8,

    top_buffers: [1]?*const anyopaque = .{null},
    top_children: [3]?*v2.ArrowArray = undefined,
    id_buffers: [2]?*const anyopaque = undefined,
    label_buffers: [3]?*const anyopaque = undefined,
    day_buffers: [2]?*const anyopaque = undefined,
    children: [3]v2.ArrowArray = undefined,

    fn unref(self: *Owned) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        gpa.free(self.ids);
        gpa.free(self.day);
        gpa.free(self.label_valid);
        gpa.free(self.label_offsets);
        gpa.free(self.label_chars);
        gpa.destroy(self);
        _ = live_arrays.fetchSub(1, .monotonic);
    }
};

/// `release` of a child: mark the struct released, drop its reference.
fn releaseChild(a: ?*v2.ArrowArray) callconv(.c) void {
    const array = a.?;
    // SAFETY: `makeArray` stored the `*Owned` as the private data of the parent and of each child.
    const owned: *Owned = @ptrCast(@alignCast(array.private_data.?));
    array.release = null;
    owned.unref();
}

/// `release` of the top-level array. It releases the children that are still there, as the specification asks: a
/// consumer that read the parent and never touched the children (DuckDB's importer) calls only this.
fn releaseParent(a: ?*v2.ArrowArray) callconv(.c) void {
    const array = a.?;
    // SAFETY: as above.
    const owned: *Owned = @ptrCast(@alignCast(array.private_data.?));
    for (&owned.children) |*child| {
        if (child.release != null) releaseChild(child);
    }
    array.release = null;
    owned.unref();
}

/// n rows: id = 10 * row, label = "item-<row>" except NULL on every fourth row, day = the row as days since 1970.
/// The caller owns the array and releases it.
fn makeArray(n: usize) !v2.ArrowArray {
    const owned = try gpa.create(Owned);
    errdefer gpa.destroy(owned);
    _ = live_arrays.fetchAdd(1, .monotonic);
    errdefer _ = live_arrays.fetchSub(1, .monotonic);
    owned.* = .{
        .rows = n,
        .ids = try gpa.alloc(i64, n),
        .day = undefined,
        .label_valid = undefined,
        .label_offsets = undefined,
        .label_chars = undefined,
    };
    errdefer gpa.free(owned.ids);
    owned.day = try gpa.alloc(i32, n);
    errdefer gpa.free(owned.day);
    owned.label_valid = try gpa.alloc(u8, (n + 7) / 8);
    errdefer gpa.free(owned.label_valid);
    owned.label_offsets = try gpa.alloc(i32, n + 1);
    errdefer gpa.free(owned.label_offsets);
    var chars: std.ArrayList(u8) = .empty;
    errdefer chars.deinit(gpa);

    @memset(owned.label_valid, 0);
    var nulls: i64 = 0;
    owned.label_offsets[0] = 0;
    for (0..n) |i| {
        owned.ids[i] = @intCast(10 * i);
        owned.day[i] = @intCast(i);
        if (i % 4 == 3) {
            nulls += 1; // a NULL has no bytes: the offset stays
        } else {
            owned.label_valid[i / 8] |= @as(u8, 1) << @intCast(i % 8);
            var buf: [24]u8 = undefined;
            try chars.appendSlice(gpa, std.fmt.bufPrint(&buf, "item-{d}", .{i}) catch unreachable);
        }
        owned.label_offsets[i + 1] = @intCast(chars.items.len);
    }
    owned.label_chars = try chars.toOwnedSlice(gpa);

    // Each column: validity (null when nothing is NULL), then the values. A string has offsets, then the bytes.
    owned.id_buffers = .{ null, owned.ids.ptr };
    owned.label_buffers = .{ owned.label_valid.ptr, owned.label_offsets.ptr, owned.label_chars.ptr };
    owned.day_buffers = .{ null, owned.day.ptr };
    const length: i64 = @intCast(n);
    const leaf = struct {
        fn init(owned_: *Owned, buffers: []?*const anyopaque, null_count: i64, len: i64) v2.ArrowArray {
            return .{ .length = len, .null_count = null_count, .offset = 0, .n_buffers = @intCast(buffers.len), .n_children = 0, .buffers = buffers.ptr, .children = null, .dictionary = null, .release = releaseChild, .private_data = owned_ };
        }
    }.init;
    owned.children[0] = leaf(owned, &owned.id_buffers, 0, length);
    owned.children[1] = leaf(owned, &owned.label_buffers, nulls, length);
    owned.children[2] = leaf(owned, &owned.day_buffers, 0, length);
    for (&owned.children, 0..) |*child, i| owned.top_children[i] = child;

    // A struct array has no values of its own: one buffer, the validity, which is absent.
    return .{ .length = length, .null_count = 0, .offset = 0, .n_buffers = 1, .n_children = 3, .buffers = &owned.top_buffers, .children = &owned.top_children, .dictionary = null, .release = releaseParent, .private_data = owned };
}

/// The schema of those arrays. Static data, so its `release` has nothing to free: it marks the struct released.
const schema_children = struct {
    var id: v2.ArrowSchema = leafSchema("l", "id");
    var label: v2.ArrowSchema = leafSchema("u", "label");
    var day: v2.ArrowSchema = leafSchema("tdD", "day");
    var list: [3]?*v2.ArrowSchema = .{ &id, &label, &day };
};

fn releaseSchema(s: ?*v2.ArrowSchema) callconv(.c) void {
    s.?.release = null;
}

fn leafSchema(format: [*:0]const u8, name: [*:0]const u8) v2.ArrowSchema {
    // flags 2 is ARROW_FLAG_NULLABLE.
    return .{ .format = format, .name = name, .metadata = null, .flags = 2, .n_children = 0, .children = null, .dictionary = null, .release = releaseSchema, .private_data = null };
}

fn topSchema() v2.ArrowSchema {
    return .{ .format = "+s", .name = "", .metadata = null, .flags = 0, .n_children = 3, .children = &schema_children.list, .dictionary = null, .release = releaseSchema, .private_data = null };
}

const ImportBind = struct {
    /// The imported chunks. The output vectors point into them, so they live as long as the bind data.
    chunks: std.ArrayList(v2.duckdb_v2_data_chunk_handle),
};

fn destroyImportBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `importBind` stored an `*ImportBind`.
    const data: *ImportBind = @ptrCast(@alignCast(ptr));
    for (data.chunks.items) |*chunk| _ = v2.duckdb_v2_data_chunk_destroy(chunk);
    data.chunks.deinit(gpa);
    gpa.destroy(data);
}

fn importBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    const rows = argRows(info, import_name, err) orelse return;
    var copy_value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, 1, &copy_value, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_value_destroy(&copy_value);
    var copy = false;
    if (v2.duckdb_v2_value_get_bool(copy_value, &copy, err) != .ERROR_NONE) return;

    const data = gpa.create(ImportBind) catch return oom(err);
    data.* = .{ .chunks = .empty };
    var keep = false;
    defer if (!keep) destroyImportBind(data);

    // The importer resolves the Arrow format strings to DuckDB types. The schema is read, not consumed.
    var schema = topSchema();
    var importer: v2.duckdb_v2_arrow_importer_handle = undefined;
    if (v2.duckdb_v2_arrow_importer_create(context, &schema, import_batch_rows, &importer, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_arrow_importer_destroy(&importer);
    defer if (schema.release) |release| release(&schema);

    // Its schema names the result columns: one field per child of the struct.
    var resolved: v2.duckdb_v2_schema_handle = undefined;
    if (v2.duckdb_v2_arrow_importer_get_schema(importer, &resolved, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_schema_destroy(&resolved);
    var count: u64 = 0;
    if (v2.duckdb_v2_schema_get_count(resolved, &count, err) != .ERROR_NONE) return;
    for (0..count) |i| {
        var name: v2.duckdb_v2_identifier_t = undefined;
        var ty: v2.duckdb_v2_logical_type_handle = undefined; // borrowed: not destroyed
        if (v2.duckdb_v2_schema_get_field(resolved, i, &name, &ty, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &name, ty, err) != .ERROR_NONE) return;
    }
    if (v2.duckdb_v2_table_function_bind_set_cardinality(result, rows, true, err) != .ERROR_NONE) return;

    if (rows > 0) {
        var array = makeArray(rows) catch return oom(err);
        // `consume` true: the importer owns the array from here (it sets `release` to null), and the chunks it
        // makes read the buffers in place. False: it reads the array and the chunks are copies.
        const consume = !copy;
        defer if (array.release) |release| release(&array);
        if (v2.duckdb_v2_arrow_importer_append(importer, &array, consume, true, err) != .ERROR_NONE) return;
        // Until a NULL chunk: the array is drained (`flush` above made the last short chunk come out too).
        while (true) {
            var chunk: ?v2.duckdb_v2_data_chunk_handle = null;
            if (v2.duckdb_v2_arrow_importer_next_chunk(importer, @ptrCast(&chunk), err) != .ERROR_NONE) return;
            const c = chunk orelse break;
            data.chunks.append(gpa, c) catch {
                var doomed = c;
                _ = v2.duckdb_v2_data_chunk_destroy(&doomed);
                return oom(err);
            };
        }
    }

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyImportBind, .equals = null };
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

fn importExec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    var cursor_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &cursor_ptr, err) != .ERROR_NONE) return;
    // SAFETY: the types stored by `importBind` and `initGlobal`.
    const bound: *const ImportBind = @ptrCast(@alignCast(bind_ptr.?));
    const cursor: *Cursor = @ptrCast(@alignCast(cursor_ptr.?));
    var out: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &out, err) != .ERROR_NONE) return;

    // One imported chunk per call; past the last, the output chunk stays empty, which ends the scan.
    if (cursor.next >= bound.chunks.items.len) {
        for (0..import_columns.len) |c| {
            var vec: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_data_chunk_get_vector(out, c, &vec, err) != .ERROR_NONE) return;
            if (v2.duckdb_v2_vector_set_size(vec, 0, err) != .ERROR_NONE) return;
        }
        return;
    }
    const chunk = bound.chunks.items[cursor.next];
    cursor.next += 1;
    var rows: u64 = 0;
    if (v2.duckdb_v2_data_chunk_get_size(chunk, &rows, err) != .ERROR_NONE) return;
    for (0..import_columns.len) |c| {
        var from: v2.duckdb_v2_vector_handle = undefined;
        var to: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &from, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_data_chunk_get_vector(out, c, &to, err) != .ERROR_NONE) return;
        // No copy: the output vector now reads what the imported one does, which is Zig's buffers when consumed.
        if (v2.duckdb_v2_vector_reference(to, from, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(to, rows, err) != .ERROR_NONE) return;
    }
}

fn liveBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    _ = info;
    var t = createType(context, .LOGICAL_TYPE_ID_BIGINT, err) orelse return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&t);
    const name = helpers.str("live_arrays");
    _ = v2.duckdb_v2_table_function_bind_add_result_column(result, &name, t, err);
}

fn liveExec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var cursor_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &cursor_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `initGlobal` stored a `*Cursor`.
    const cursor: *Cursor = @ptrCast(@alignCast(cursor_ptr.?));
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
    var vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, err) != .ERROR_NONE) return;
    const rows: u64 = if (cursor.next == 0) 1 else 0;
    cursor.next = 1;
    if (v2.duckdb_v2_vector_set_size(vec, rows, err) != .ERROR_NONE) return;
    var data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(vec, &data, err) != .ERROR_NONE) return;
    if (rows == 1) @as([*]i64, @ptrCast(@alignCast(data.?)))[0] = live_arrays.load(.monotonic);
}

fn registerLive(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);
    const name = helpers.str("zig_cookbook_arrow_live_arrays");
    if (v2.duckdb_v2_table_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;
    if (v2.duckdb_v2_table_function_set_bind_callback(function, &liveBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &initGlobal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &liveExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    // What duckdb_functions() shows besides the signature.
    var function_docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_table_function_get_docs(function, &function_docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(function_docs, .{
        .description = "How many of the hand-built Arrow arrays of zig_cookbook_arrow_import are not released yet: 0 when every one was released exactly once.",
        .examples = &.{.{ .sql = "SELECT * FROM zig_cookbook_arrow_live_arrays();" }},
        .categories = &.{"arrow"},
    }, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

fn registerFunction(
    input: *const v2.duckdb_v2_extension_input,
    err: Err,
    name: []const u8,
    docs: helpers.Docs,
    second_parameter: ?[]const u8,
    bind: anytype,
    exec: anytype,
) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);
    const fn_name = helpers.str(name);
    if (v2.duckdb_v2_table_function_set_name(function, &fn_name, err) != .ERROR_NONE) return error.FailedToSetName;

    var bigint = createType(input.context, .LOGICAL_TYPE_ID_BIGINT, err) orelse return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const n_name = helpers.str("n");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &n_name, bigint, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    if (second_parameter) |p| {
        var boolean = createType(input.context, .LOGICAL_TYPE_ID_BOOLEAN, err) orelse return error.FailedToCreateType;
        defer _ = v2.duckdb_v2_logical_type_destroy(&boolean);
        var default: v2.duckdb_v2_value_handle = undefined;
        if (v2.duckdb_v2_value_create_bool(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, false, &default, err) != .ERROR_NONE) return error.FailedToCreateDefault;
        defer _ = v2.duckdb_v2_value_destroy(&default);
        const p_name = helpers.str(p);
        if (v2.duckdb_v2_function_signature_add_parameter(sig, &p_name, boolean, default, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    }

    if (v2.duckdb_v2_table_function_set_bind_callback(function, bind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &initGlobal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, exec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    // What duckdb_functions() shows besides the signature.
    var function_docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_table_function_get_docs(function, &function_docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(function_docs, docs, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the two functions. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerFunction(input, err, export_name, .{
        .description = "n rows of (BIGINT, VARCHAR with NULLs, BOOLEAN) fed to an Arrow exporter in chunks, reported per exported ArrowArray and column: format, length, null count, buffer count and a checksum read from the raw buffers.",
        .examples = &.{.{ .sql = "SELECT * FROM zig_cookbook_arrow_export(2500);" }},
        .categories = &.{"arrow"},
    }, null, &exportBind, &exportExec);
    try registerFunction(input, err, import_name, .{
        .description = "n rows (id, label, day) from an Arrow schema and array built by hand and imported zero-copy, or copied with copy := true.",
        .examples = &.{
            .{ .sql = "SELECT * FROM zig_cookbook_arrow_import(5);" },
            .{ .title = "Copied instead of imported in place", .sql = "SELECT * FROM zig_cookbook_arrow_import(5, copy := true);" },
        },
        .categories = &.{"arrow"},
    }, "copy", &importBind, &importExec);
    try registerLive(input, err);
}
