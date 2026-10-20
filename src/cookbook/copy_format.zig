///! Cookbook: a custom COPY format (v2 C API, `function/copy`).
///!
///!   COPY t TO 'file' (FORMAT zig_cookbook_lines, DELIMITER ';', HEADER, NULL_TEXT '\N');
///!   COPY t FROM 'file' (FORMAT zig_cookbook_lines, DELIMITER ';', HEADER);
///!
///! One row per line, the values separated by a delimiter (default `|`), a NULL written as `\N`. A backslash escapes
///! the delimiter, a newline and itself. Every type works, because values travel as text: DuckDB's own VARCHAR cast
///! writes them and reads them back.
///!
///! A copy function has two sides, each a chain of callbacks that hand data down it.
///!
///! `COPY ... TO`
///!   bind        planning: the columns (names, types), the options and the path; leaves bind data
///!   batch_size  planning: how many rows make a batch (the statement's BATCH_SIZE wins)
///!   init        once per output file: opens it; leaves init data
///!   batch       takes a batch of rows and *prepares* it (here: encodes it as text). Runs on several threads at once,
///!               so it touches only the bind data and its own batch.
///!   flush       writes a prepared batch. Never concurrent for one file, so the file needs no lock.
///!   finalize    after the last flush: closes the file
///!
///! `COPY ... FROM`
///!   bind        planning: path, options, the columns *the table expects* (the format must produce exactly those);
///!               a row count estimate; leaves bind data
///!   init_global once per statement: opens the file, shared state, the thread limit (one: a text file is read in order)
///!   exec        repeatedly: fills the next chunk; an empty chunk ends the read
///!   progress    on demand, concurrently with exec: how far the read is, so it reads atomics
///!
///! Files are read and written with the C library here. DuckDB's own file system (`filesystem` module) is what a
///! format would use to support remote paths; that is a recipe of its own.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const Err = *v2.duckdb_v2_error_info_handle;

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(file: *anyopaque) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, file: *anyopaque) usize;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, file: *anyopaque) usize;

const gpa = std.heap.c_allocator;
const format_name = "zig_cookbook_lines";

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [300]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = helpers.setErrorText(err.*, msg);
}

fn spanOf(s: v2.duckdb_v2_str) []const u8 {
    const ptr = s.ptr orelse return "";
    return ptr[0..s.len];
}

// --- options and columns, shared by both sides -------------------------------------------------------------------

const Options = struct {
    delimiter: u8 = '|',
    header: bool = false,
    null_text: []const u8 = "\\N",
};

/// The statement's options, `FORMAT` excluded (DuckDB consumed it). `info` is a bind info of either side: the
/// functions of the two sides have the same shape.
fn readOptions(comptime side: enum { to, from }, arena: std.mem.Allocator, info: anytype, err: Err) ?Options {
    const count_fn = if (side == .to) v2.duckdb_v2_copy_to_bind_get_option_count else v2.duckdb_v2_copy_from_bind_get_option_count;
    const name_fn = if (side == .to) v2.duckdb_v2_copy_to_bind_get_option_name else v2.duckdb_v2_copy_from_bind_get_option_name;
    const value_fn = if (side == .to) v2.duckdb_v2_copy_to_bind_get_option_value else v2.duckdb_v2_copy_from_bind_get_option_value;

    var options: Options = .{};
    var count: u64 = 0;
    if (count_fn(info, &count, err) != .ERROR_NONE) return null;
    for (0..count) |i| {
        var name: v2.duckdb_v2_identifier_t = undefined;
        if (name_fn(info, i, &name, err) != .ERROR_NONE) return null;
        var value: v2.duckdb_v2_value_handle = undefined;
        if (value_fn(info, i, &value, err) != .ERROR_NONE) return null;
        defer _ = v2.duckdb_v2_value_destroy(&value);

        const key = spanOf(name);
        if (std.ascii.eqlIgnoreCase(key, "header")) {
            // A bare `HEADER` is the BOOLEAN true; `HEADER false` is a value.
            if (v2.duckdb_v2_value_get_bool(value, &options.header, err) != .ERROR_NONE) return null;
        } else if (std.ascii.eqlIgnoreCase(key, "delimiter") or std.ascii.eqlIgnoreCase(key, "null_text")) {
            var text: v2.duckdb_v2_str = undefined;
            if (v2.duckdb_v2_value_get_varchar(value, &text, err) != .ERROR_NONE) return null;
            const s = arena.dupe(u8, spanOf(text)) catch return null;
            if (std.ascii.eqlIgnoreCase(key, "delimiter")) {
                if (s.len != 1 or s[0] == '\\' or s[0] == '\n' or s[0] == '\r') {
                    fail(err, .ERROR_INPUT_PARAMETER_INVALID, format_name ++ ": DELIMITER must be one character, other than a backslash or a line break", .{});
                    return null;
                }
                options.delimiter = s[0];
            } else options.null_text = s;
        } else {
            fail(err, .ERROR_INPUT_PARAMETER_INVALID, format_name ++ ": unknown option {s} (DELIMITER, HEADER and NULL_TEXT exist)", .{key});
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
    const data = gpa.create(ToBind) catch return;
    data.* = .{ .arena = .init(gpa), .options = .{}, .names = &.{}, .types = &.{} };
    var keep = false;
    defer if (!keep) destroyToBind(data);
    const arena = data.arena.allocator();

    data.options = readOptions(.to, arena, info, err) orelse return;

    var count: u64 = 0;
    if (v2.duckdb_v2_copy_to_bind_get_column_count(info, &count, err) != .ERROR_NONE) return;
    const names = arena.alloc([]const u8, count) catch return;
    const types = arena.alloc(v2.duckdb_v2_logical_type_handle, count) catch return;
    data.types = types[0..0];
    for (0..count) |i| {
        var name: v2.duckdb_v2_identifier_t = undefined;
        if (v2.duckdb_v2_copy_to_bind_get_column_name(info, i, &name, err) != .ERROR_NONE) return;
        names[i] = arena.dupe(u8, spanOf(name)) catch return;
        if (v2.duckdb_v2_copy_to_bind_get_column_type(info, i, &types[i], err) != .ERROR_NONE) return;
        data.types = types[0 .. i + 1];
    }
    data.names = names;

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyToBind, .equals = null };
    if (v2.duckdb_v2_copy_to_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

/// Rows per batch when the statement does not say (`BATCH_SIZE`): the batches are what the batch callback gets.
const rows_per_batch = 1000;

fn toBatchSize(info: v2.duckdb_v2_copy_to_batch_size_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    _ = v2.duckdb_v2_copy_to_batch_size_set_target(info, rows_per_batch, err);
}

/// Per output file. Only the flush and finalize callbacks touch it, and never at the same time.
const ToFile = struct {
    file: *anyopaque,
    closed: bool = false,
};

fn destroyToFile(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `toInit` stored a `*ToFile`.
    const data: *ToFile = @ptrCast(@alignCast(ptr));
    if (!data.closed) _ = fclose(data.file); // finalize closes it; this is for a statement that failed first
    gpa.destroy(data);
}

fn toInit(info: v2.duckdb_v2_copy_to_init_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var path: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_copy_to_init_get_file_path(info, &path, err) != .ERROR_NONE) return;
    const c_path = gpa.dupeSentinel(u8, spanOf(path), 0) catch return;
    defer gpa.free(c_path);
    const file = fopen(c_path, "wb") orelse return fail(err, .ERROR_IO_GENERAL, format_name ++ ": cannot open {s} for writing", .{c_path});

    const data = gpa.create(ToFile) catch {
        _ = fclose(file);
        return;
    };
    data.* = .{ .file = file };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyToFile, .equals = null };
    if (v2.duckdb_v2_copy_to_init_set_init_data(info, &boxed, err) != .ERROR_NONE) return destroyToFile(data);

    // The header is the file's first line, so it belongs here, not in a batch.
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_to_init_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `toBind` stored a `*ToBind`.
    const bound: *const ToBind = @ptrCast(@alignCast(bind_ptr.?));
    if (!bound.options.header) return;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    for (bound.names, 0..) |name, i| {
        if (i > 0) line.append(gpa, bound.options.delimiter) catch return;
        appendEscaped(&line, name, bound.options.delimiter) catch return;
    }
    line.append(gpa, '\n') catch return;
    if (fwrite(line.items.ptr, 1, line.items.len, file) != line.items.len) fail(err, .ERROR_IO_GENERAL, format_name ++ ": write failed", .{});
}

/// A batch, encoded: what the batch callback hands to the flush callback.
const Encoded = struct { bytes: std.ArrayList(u8) = .empty };

fn destroyEncoded(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `toBatch` stored a `*Encoded`.
    const data: *Encoded = @ptrCast(@alignCast(ptr));
    data.bytes.deinit(gpa);
    gpa.destroy(data);
}

fn appendEscaped(out: *std.ArrayList(u8), text: []const u8, delimiter: u8) !void {
    for (text) |c| {
        switch (c) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            else => {
                if (c == delimiter) try out.append(gpa, '\\');
                try out.append(gpa, c);
            },
        }
    }
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

    var varchar: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_VARCHAR, &varchar, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar);
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (helpers.createDataChunk(context, bound.types, &chunk, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_data_chunk_destroy(&chunk);
    var shared: v2.duckdb_v2_column_data_collection_shared_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_shared_scan_state_create(collection, &shared, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_column_data_collection_shared_scan_state_destroy(&shared);
    var worker: v2.duckdb_v2_column_data_collection_worker_scan_state_handle = undefined;
    if (v2.duckdb_v2_column_data_collection_worker_scan_state_create(collection, &worker, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_column_data_collection_worker_scan_state_destroy(&worker);

    const encoded = gpa.create(Encoded) catch return;
    encoded.* = .{};
    var keep = false;
    defer if (!keep) destroyEncoded(encoded);

    const options = bound.options;

    while (true) {
        var produced = false;
        if (v2.duckdb_v2_column_data_collection_scan(collection, shared, worker, chunk, &produced, err) != .ERROR_NONE) return;
        if (!produced) break;
        var rows: u64 = 0;
        if (v2.duckdb_v2_data_chunk_get_size(chunk, &rows, err) != .ERROR_NONE) return;
        for (0..rows) |row| {
            for (0..bound.types.len) |c| {
                if (c > 0) encoded.bytes.append(gpa, options.delimiter) catch return;
                var vec: v2.duckdb_v2_vector_handle = undefined;
                if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vec, err) != .ERROR_NONE) return;
                var value: v2.duckdb_v2_value_handle = undefined;
                if (v2.duckdb_v2_vector_get_value(vec, row, &value, err) != .ERROR_NONE) return;
                defer _ = v2.duckdb_v2_value_destroy(&value);
                var is_null = false;
                if (v2.duckdb_v2_value_is_null(value, &is_null, err) != .ERROR_NONE) return;
                if (is_null) {
                    encoded.bytes.appendSlice(gpa, options.null_text) catch return;
                    continue;
                }
                // Any type to its text, by DuckDB's own cast.
                var text_value: v2.duckdb_v2_value_handle = undefined;
                if (v2.duckdb_v2_value_cast(helpers.factory(context, err) orelse return, value, varchar, &text_value, err) != .ERROR_NONE) return;
                defer _ = v2.duckdb_v2_value_destroy(&text_value);
                var text: v2.duckdb_v2_str = undefined;
                if (v2.duckdb_v2_value_get_varchar(text_value, &text, err) != .ERROR_NONE) return;
                appendEscaped(&encoded.bytes, spanOf(text), options.delimiter) catch return;
            }
            encoded.bytes.append(gpa, '\n') catch return;
        }
    }

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = encoded, .destroy = destroyEncoded, .equals = null };
    if (v2.duckdb_v2_copy_to_batch_set_batch_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

fn toFlush(info: v2.duckdb_v2_copy_to_flush_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var init_ptr: ?*anyopaque = null;
    var batch_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_to_flush_get_init_data(info, &init_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_copy_to_flush_get_batch_data(info, &batch_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `toInit` stored a `*ToFile` and `toBatch` an `*Encoded`.
    const file: *ToFile = @ptrCast(@alignCast(init_ptr.?));
    const encoded: *const Encoded = @ptrCast(@alignCast(batch_ptr.?));
    const bytes = encoded.bytes.items;
    if (fwrite(bytes.ptr, 1, bytes.len, file.file) != bytes.len) fail(err, .ERROR_IO_GENERAL, format_name ++ ": write failed", .{});
}

fn toFinalize(info: v2.duckdb_v2_copy_to_finalize_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var init_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_to_finalize_get_init_data(info, &init_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `toInit` stored a `*ToFile`.
    const file: *ToFile = @ptrCast(@alignCast(init_ptr.?));
    file.closed = true;
    if (fclose(file.file) != 0) fail(err, .ERROR_IO_GENERAL, format_name ++ ": closing the file failed", .{});
}

// --- COPY ... FROM ------------------------------------------------------------------------------------------------

const FromBind = struct {
    arena: std.heap.ArenaAllocator,
    options: Options,
    path: [:0]const u8,
    types: []v2.duckdb_v2_logical_type_handle,
};

fn destroyFromBind(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `fromBind` stored a `*FromBind`.
    const data: *FromBind = @ptrCast(@alignCast(ptr));
    for (data.types) |*t| _ = v2.duckdb_v2_logical_type_destroy(t);
    data.arena.deinit();
    gpa.destroy(data);
}

/// The whole file, read in chunks into one buffer. A cookbook simplification: a real format streams.
fn readFile(path: [:0]const u8, err: Err) ?std.ArrayList(u8) {
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
            return null;
        };
    }
    return bytes;
}

fn countLines(bytes: []const u8) u64 {
    var n: u64 = @intCast(std.mem.count(u8, bytes, "\n"));
    if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') n += 1;
    return n;
}

fn fromBind(info: v2.duckdb_v2_copy_from_bind_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    const data = gpa.create(FromBind) catch return;
    data.* = .{ .arena = .init(gpa), .options = .{}, .path = "", .types = &.{} };
    var keep = false;
    defer if (!keep) destroyFromBind(data);
    const arena = data.arena.allocator();

    data.options = readOptions(.from, arena, info, err) orelse return;
    var path: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_copy_from_bind_get_file_path(info, &path, err) != .ERROR_NONE) return;
    data.path = arena.dupeSentinel(u8, spanOf(path), 0) catch return;

    // The columns are the table's: the format has to produce them as they are.
    var count: u64 = 0;
    if (v2.duckdb_v2_copy_from_bind_get_column_count(info, &count, err) != .ERROR_NONE) return;
    const types = arena.alloc(v2.duckdb_v2_logical_type_handle, count) catch return;
    data.types = types[0..0];
    for (0..count) |i| {
        if (v2.duckdb_v2_copy_from_bind_get_column_type(info, i, &types[i], err) != .ERROR_NONE) return;
        data.types = types[0 .. i + 1];
    }

    // The estimate is a hint for the optimizer: here the exact number of lines. A missing file is reported now,
    // while the statement is planned, rather than when it runs.
    var bytes = readFile(data.path, err) orelse return;
    defer bytes.deinit(gpa);
    const lines = countLines(bytes.items);
    const rows = if (data.options.header and lines > 0) lines - 1 else lines;
    if (v2.duckdb_v2_copy_from_bind_set_cardinality(info, rows, true, err) != .ERROR_NONE) return;

    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyFromBind, .equals = null };
    if (v2.duckdb_v2_copy_from_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

/// Shared by the threads of the read (there is one) and by the progress callback, hence the atomic.
const FromState = struct {
    bytes: std.ArrayList(u8),
    pos: std.atomic.Value(usize) = .init(0),
    line_no: u64 = 0,
};

fn destroyFromState(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `fromInitGlobal` stored a `*FromState`.
    const state: *FromState = @ptrCast(@alignCast(ptr));
    state.bytes.deinit(gpa);
    gpa.destroy(state);
}

fn fromInitGlobal(info: v2.duckdb_v2_copy_from_init_global_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_from_init_global_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `fromBind` stored a `*FromBind`.
    const bound: *const FromBind = @ptrCast(@alignCast(bind_ptr.?));
    // A line-oriented file is read in order by one thread.
    if (v2.duckdb_v2_copy_from_init_global_set_max_threads(info, 1, err) != .ERROR_NONE) return;

    const state = gpa.create(FromState) catch return;
    state.* = .{ .bytes = readFile(bound.path, err) orelse {
        gpa.destroy(state);
        return;
    } };
    if (bound.options.header) {
        // Skip the header line.
        const end = std.mem.indexOfScalar(u8, state.bytes.items, '\n');
        state.pos.store(if (end) |e| e + 1 else state.bytes.items.len, .monotonic);
        state.line_no = 1;
    }
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyFromState, .equals = null };
    if (v2.duckdb_v2_copy_from_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyFromState(state);
}

/// Splits one line into its fields, undoing the escapes; `raw_null` marks the fields that were exactly the null text.
/// Returns the number of fields.
fn splitLine(line: []const u8, options: Options, fields: *std.ArrayList([]const u8), nulls: *std.ArrayList(bool), scratch: std.mem.Allocator) !usize {
    fields.clearRetainingCapacity();
    nulls.clearRetainingCapacity();
    var field_start: usize = 0;
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        const at_end = i == line.len;
        if (!at_end and line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            try cur.append(scratch, switch (line[i]) {
                'n' => '\n',
                'r' => '\r',
                else => line[i],
            });
        } else if (at_end or line[i] == options.delimiter) {
            try nulls.append(scratch, std.mem.eql(u8, line[field_start..i], options.null_text));
            try fields.append(scratch, try cur.toOwnedSlice(scratch));
            cur = .empty;
            field_start = i + 1;
        } else {
            try cur.append(scratch, line[i]);
        }
    }
    return fields.items.len;
}

fn fromExec(info: v2.duckdb_v2_copy_from_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    var bind_ptr: ?*anyopaque = null;
    var state_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_from_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_copy_from_exec_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
    // SAFETY: the types stored by `fromBind` and `fromInitGlobal`.
    const bound: *const FromBind = @ptrCast(@alignCast(bind_ptr.?));
    const state: *FromState = @ptrCast(@alignCast(state_ptr.?));

    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_copy_from_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();
    var fields: std.ArrayList([]const u8) = .empty;
    var nulls: std.ArrayList(bool) = .empty;

    const bytes = state.bytes.items;
    var pos = state.pos.load(.monotonic);
    var rows: u64 = 0;
    // Parse a chunk's worth of lines first; the vectors are sized, then filled, column by column.
    var cells: std.ArrayList([]const u8) = .empty;
    var cell_nulls: std.ArrayList(bool) = .empty;
    const columns = bound.types.len;
    while (rows < 2048 and pos < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
        var line = bytes[pos..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        pos = if (end < bytes.len) end + 1 else bytes.len;
        state.line_no += 1;
        const n = splitLine(line, bound.options, &fields, &nulls, scratch) catch return;
        if (n != columns) return fail(err, .ERROR_INPUT_INVALID, format_name ++ ": line {d}: expected {d} fields, got {d}", .{ state.line_no, columns, n });
        cells.appendSlice(scratch, fields.items) catch return;
        cell_nulls.appendSlice(scratch, nulls.items) catch return;
        rows += 1;
    }
    state.pos.store(pos, .monotonic);

    for (0..columns) |c| {
        var vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vec, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(vec, rows, err) != .ERROR_NONE) return;
        for (0..rows) |row| {
            const k = row * columns + c;
            if (cell_nulls.items[k]) {
                if (v2.duckdb_v2_vector_set_null(vec, row, err) != .ERROR_NONE) return;
                continue;
            }
            // Text to the column's type, by DuckDB's own cast; a value that does not fit fails the statement.
            var text: v2.duckdb_v2_value_handle = undefined;
            if (helpers.createVarcharValue(context, cells.items[k], &text, err) != .ERROR_NONE) return;
            defer _ = v2.duckdb_v2_value_destroy(&text);
            var value: v2.duckdb_v2_value_handle = undefined;
            if (v2.duckdb_v2_value_cast(helpers.factory(context, err) orelse return, text, bound.types[c], &value, err) != .ERROR_NONE) return;
            defer _ = v2.duckdb_v2_value_destroy(&value);
            if (v2.duckdb_v2_vector_set_value(vec, row, value, err) != .ERROR_NONE) return;
        }
    }
}

/// Runs on another thread while `fromExec` does: only the atomic position is read.
fn fromProgress(info: v2.duckdb_v2_copy_from_progress_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var state_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_copy_from_progress_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
    // SAFETY: `fromInitGlobal` stored a `*FromState`.
    const state: *FromState = @ptrCast(@alignCast(state_ptr.?));
    const total: f64 = @floatFromInt(@max(state.bytes.items.len, 1));
    const done: f64 = @floatFromInt(state.pos.load(.monotonic));
    _ = v2.duckdb_v2_copy_from_progress_set_progress(info, done / total, err);
}

fn registerCopy(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_copy_function_handle = undefined;
    if (v2.duckdb_v2_copy_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
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

    if (v2.duckdb_v2_extension_register_copy_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the format. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerCopy(input, err);
}
