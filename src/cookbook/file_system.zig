///! Cookbook: files through DuckDB's file system (v2 C API, `filesystem/file_system`), not through libc.
///!
///!   zig_cookbook_fs_read(path, start := 0, length := -1) -> (size BIGINT, content BLOB)
///!   zig_cookbook_fs_write(path, content, mode := 'create', start := 0) -> (bytes BIGINT, size BIGINT, position BIGINT)
///!
///! Why not `fopen`: the file system a context hands out is the one the engine itself reads with. A path goes where
///! the engine would send it: `~` is expanded, `file:` URLs work, and a path that a registered file system claims (`s3://`
///! and `https://` with httpfs, a virtual file system of another extension) goes there. The recipe's code does not
///! change for any of them; `arrow_ipc.zig`, which uses libc, would not read those.
///!
///! The calls, in the order of a file's life:
///!   file_system_get_from_context   a borrowed handle, valid while the context is (never destroyed)
///!   file_open_options_create       options belong to a file system; flags say what the file is for (at least one)
///!   file_open_options_set_flag     READ, WRITE, CREATE, CREATE_NEW, APPEND, EXCLUSIVE_CREATE, PARALLEL_ACCESS, ...
///!   file_system_open               the path is a `duckdb_v2_str`, borrowed for the call
///!   file_size / file_tell          size in bytes; the position that read and write advance
///!   file_read, file_write          at the position; **short counts are normal** (zero read means the end), so loop
///!   file_read_at, file_write_at    at an offset, position untouched; **all of it or an error**; thread-safe with the
///!                                  PARALLEL_ACCESS flag (the writer's `at` mode sets it)
///!   file_sync, file_close          flush to storage; release the descriptor (`file_destroy` also closes)
///!
///! `fs_read` without a range reads sequentially until the end; with `start` or `length` it reads that range at an
///! offset, and a range past the end of the file is an error from DuckDB. `fs_write` has four modes, which are flag
///! combinations: `create` (WRITE + CREATE_NEW: a new file, or an existing one emptied), `append` (WRITE + APPEND +
///! CREATE), `exclusive` (WRITE + CREATE + EXCLUSIVE_CREATE: fails when the file exists) and `at` (WRITE + CREATE +
///! PARALLEL_ACCESS, written at `start`, past the end if need be). The write happens when the statement runs, not
///! when it is planned: a table function's bind may run without its scan, and the effect belongs in the scan.
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

fn spanOf(s: v2.duckdb_v2_str) []const u8 {
    const ptr = s.ptr orelse return "";
    return ptr[0..s.len];
}

/// The most `fs_read` returns: the content is one value.
const max_read: u64 = 256 * 1024 * 1024;

// --- the file ------------------------------------------------------------------------------------------------------

/// An open file. `deinit` destroys the handle, which closes it too; a writer closes it first to see the error.
const File = struct {
    handle: v2.duckdb_v2_file_handle,

    /// Opens `path` through the context's file system. A failure (no such file, no permission, the file exists under
    /// EXCLUSIVE_CREATE) is DuckDB's own error, with its text.
    fn open(context: v2.duckdb_v2_context_handle, path: []const u8, flags: []const v2.DUCKDB_V2_FILE_FLAG, err: Err) ?File {
        var fs: v2.duckdb_v2_file_system_handle = undefined; // borrowed: valid while the context is, never destroyed
        if (v2.duckdb_v2_context_get_file_system(context, &fs, err) != .ERROR_NONE) return null;

        var options: v2.duckdb_v2_file_open_options_handle = undefined;
        if (v2.duckdb_v2_file_open_options_create(fs, &options, err) != .ERROR_NONE) return null;
        defer _ = v2.duckdb_v2_file_open_options_destroy(&options);
        for (flags) |flag| {
            if (v2.duckdb_v2_file_open_options_set_flag(options, flag, err) != .ERROR_NONE) return null;
        }

        const c_path = helpers.str(path);
        var handle: v2.duckdb_v2_file_handle = undefined;
        if (v2.duckdb_v2_file_system_open(fs, &c_path, options, &handle, err) != .ERROR_NONE) return null;
        return .{ .handle = handle };
    }

    fn deinit(self: *File) void {
        _ = v2.duckdb_v2_file_destroy(&self.handle);
    }

    fn size(self: File, err: Err) ?u64 {
        var n: u64 = 0;
        if (v2.duckdb_v2_file_size(self.handle, &n, err) != .ERROR_NONE) return null;
        return n;
    }

    fn tell(self: File, err: Err) ?u64 {
        var n: u64 = 0;
        if (v2.duckdb_v2_file_tell(self.handle, &n, err) != .ERROR_NONE) return null;
        return n;
    }
};

// --- arguments -----------------------------------------------------------------------------------------------------

fn argInt(info: v2.duckdb_v2_function_bind_info_handle, index: u64, err: Err) ?i64 {
    var value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, index, &value, err) != .ERROR_NONE) return null;
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var out: i64 = 0;
    if (v2.duckdb_v2_value_get_bigint(value, &out, err) != .ERROR_NONE) return null;
    return out;
}

/// A VARCHAR argument, copied into the arena (the value is destroyed here).
fn argText(arena: std.mem.Allocator, info: v2.duckdb_v2_function_bind_info_handle, index: u64, err: Err) ?[]const u8 {
    var value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, index, &value, err) != .ERROR_NONE) return null;
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var text: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_value_get_varchar(value, &text, err) != .ERROR_NONE) return null;
    return arena.dupe(u8, spanOf(text)) catch {
        oom(err);
        return null;
    };
}

const Default = union(enum) { int: i64, text: []const u8 };
const Param = struct { name: []const u8, id: v2.DUCKDB_V2_LOGICAL_TYPE_ID, default: ?Default = null };

/// Result columns: name and type.
const ResultColumn = struct { name: []const u8, id: v2.DUCKDB_V2_LOGICAL_TYPE_ID };

// --- shared by both functions ----------------------------------------------------------------------------------------

const Bound = struct {
    arena: std.heap.ArenaAllocator,
    /// fs_read: what was read. fs_write: the content to write.
    bytes: []const u8 = "",
    path: []const u8 = "",
    mode: enum { create, append, exclusive, at } = .create,
    offset: u64 = 0,
    /// fs_read: the size of the file.
    size: u64 = 0,
};

fn destroyBound(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: both binds store a `*Bound`.
    const data: *Bound = @ptrCast(@alignCast(ptr));
    data.arena.deinit();
    gpa.destroy(data);
}

const Cursor = struct { done: bool = false };

fn destroyCursor(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `initGlobal` stored a `*Cursor`.
    gpa.destroy(@as(*Cursor, @ptrCast(@alignCast(ptr))));
}

fn initGlobal(info: v2.duckdb_v2_table_function_init_global_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    // One row, one thread: for the writer it is what makes the effect happen once.
    if (v2.duckdb_v2_table_function_init_global_set_max_threads(info, 1, err) != .ERROR_NONE) return;
    const cursor = gpa.create(Cursor) catch return oom(err);
    cursor.* = .{};
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = cursor, .destroy = destroyCursor, .equals = null };
    if (v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyCursor(cursor);
}

fn addColumns(context: v2.duckdb_v2_context_handle, result: v2.duckdb_v2_table_function_bind_info_handle, columns: []const ResultColumn, err: Err) bool {
    for (columns) |column| {
        var t: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(context, column.id, &t, err) != .ERROR_NONE) return false;
        defer _ = v2.duckdb_v2_logical_type_destroy(&t);
        const name = helpers.str(column.name);
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &name, t, err) != .ERROR_NONE) return false;
    }
    return v2.duckdb_v2_table_function_bind_set_cardinality(result, 1, true, err) == .ERROR_NONE;
}

fn store(info: v2.duckdb_v2_function_bind_info_handle, data: *Bound, err: Err) bool {
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyBound, .equals = null };
    return v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) == .ERROR_NONE;
}

/// The bind data and the cursor of the scan, and its one-row output chunk. Null after failing, or when the row has
/// been given already (the second call of the scan sees an empty chunk, which ends it).
const Scan = struct {
    bound: *const Bound,
    chunk: v2.duckdb_v2_data_chunk_handle,
};

fn startScan(info: v2.duckdb_v2_table_function_exec_info_handle, err: Err) ?Scan {
    var bind_ptr: ?*anyopaque = null;
    var cursor_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return null;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &cursor_ptr, err) != .ERROR_NONE) return null;
    // SAFETY: the types stored by the binds and `initGlobal`.
    const cursor: *Cursor = @ptrCast(@alignCast(cursor_ptr.?));
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return null;
    if (cursor.done) {
        var vec: v2.duckdb_v2_vector_handle = undefined;
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, 0, &vec, err) != .ERROR_NONE) return null;
        _ = v2.duckdb_v2_vector_set_size(vec, 0, err);
        return null;
    }
    cursor.done = true;
    return .{ .bound = @ptrCast(@alignCast(bind_ptr.?)), .chunk = chunk };
}

/// Column `c` of the one-row chunk: sized to one row, with its data.
fn outColumn(scan: Scan, c: u64, err: Err) ?struct { vec: v2.duckdb_v2_vector_handle, data: *anyopaque } {
    var vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_data_chunk_get_vector(scan.chunk, c, &vec, err) != .ERROR_NONE) return null;
    if (v2.duckdb_v2_vector_set_size(vec, 1, err) != .ERROR_NONE) return null;
    var data: ?*anyopaque = null;
    if (v2.duckdb_v2_vector_get_data_mutable(vec, &data, err) != .ERROR_NONE) return null;
    return .{ .vec = vec, .data = data.? };
}

// --- fs_read ---------------------------------------------------------------------------------------------------------

fn readBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    const data = gpa.create(Bound) catch return oom(err);
    data.* = .{ .arena = .init(gpa) };
    var keep = false;
    defer if (!keep) destroyBound(data);
    const arena = data.arena.allocator();

    data.path = argText(arena, info, 0, err) orelse return;
    const offset = argInt(info, 1, err) orelse return;
    const length = argInt(info, 2, err) orelse return;
    if (offset < 0) return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "zig_cookbook_fs_read: start must not be negative, got {d}", .{offset});
    if (length < -1) return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "zig_cookbook_fs_read: length must be -1 (to the end) or more, got {d}", .{length});

    // READ is the one flag a reader needs.
    var file = File.open(context, data.path, &.{.FILE_FLAG_READ}, err) orelse return;
    defer file.deinit();
    data.size = file.size(err) orelse return;

    // A range is read at its offset, all of it or an error. Without one, the file is read from the start until
    // `file_read` says there is no more, which is the way for a stream whose size is not known.
    const ranged = offset > 0 or length >= 0;
    const want: u64 = if (!ranged) data.size else if (length >= 0) @intCast(length) else data.size -| @as(u64, @intCast(offset));
    if (want > max_read) return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "zig_cookbook_fs_read: {d} bytes is more than the {d} it returns", .{ want, max_read });
    const buffer = arena.alloc(u8, want) catch return oom(err);

    if (ranged) {
        if (want > 0 and v2.duckdb_v2_file_read_at(file.handle, buffer.ptr, want, @intCast(offset), err) != .ERROR_NONE) return;
        data.bytes = buffer;
    } else {
        var got: u64 = 0;
        while (got < want) {
            var n: u64 = 0;
            if (v2.duckdb_v2_file_read(file.handle, buffer.ptr + got, want - got, &n, err) != .ERROR_NONE) return;
            if (n == 0) break; // the end: fewer bytes than the size said is not an error from the call
            got += n;
        }
        data.bytes = buffer[0..got];
    }

    if (!addColumns(context, result, &.{ .{ .name = "size", .id = .LOGICAL_TYPE_ID_BIGINT }, .{ .name = "content", .id = .LOGICAL_TYPE_ID_BLOB } }, err)) return;
    if (!store(info, data, err)) return;
    keep = true;
}

fn readExec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    const scan = startScan(info, err) orelse return;
    const size = outColumn(scan, 0, err) orelse return;
    const content = outColumn(scan, 1, err) orelse return;
    @as([*]i64, @ptrCast(@alignCast(size.data)))[0] = @intCast(scan.bound.size);
    var arena: v2.duckdb_v2_arena_handle = undefined;
    if (v2.duckdb_v2_vector_get_arena(content.vec, &arena, err) != .ERROR_NONE) return;
    @as([*]v2.duckdb_v2_bytes, @ptrCast(@alignCast(content.data)))[0] = helpers.makeBytesValue(arena, scan.bound.bytes, err) catch return;
}

// --- fs_write --------------------------------------------------------------------------------------------------------

fn writeBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    const data = gpa.create(Bound) catch return oom(err);
    data.* = .{ .arena = .init(gpa) };
    var keep = false;
    defer if (!keep) destroyBound(data);
    const arena = data.arena.allocator();

    data.path = argText(arena, info, 0, err) orelse return;
    data.bytes = argText(arena, info, 1, err) orelse return;
    const mode = argText(arena, info, 2, err) orelse return;
    const offset = argInt(info, 3, err) orelse return;
    data.mode = std.meta.stringToEnum(@TypeOf(data.mode), mode) orelse
        return fail(err, .ERROR_INPUT_PARAMETER_INVALID, "zig_cookbook_fs_write: unknown mode '{s}' (create, append, exclusive or at)", .{mode});
    if (offset < 0) return fail(err, .ERROR_INPUT_OUT_OF_RANGE, "zig_cookbook_fs_write: start must not be negative, got {d}", .{offset});
    data.offset = @intCast(offset);

    if (!addColumns(context, result, &.{ .{ .name = "bytes", .id = .LOGICAL_TYPE_ID_BIGINT }, .{ .name = "size", .id = .LOGICAL_TYPE_ID_BIGINT }, .{ .name = "position", .id = .LOGICAL_TYPE_ID_BIGINT } }, err)) return;
    if (!store(info, data, err)) return;
    keep = true;
}

fn writeExec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    const scan = startScan(info, err) orelse return;
    const bound = scan.bound;

    const F = v2.DUCKDB_V2_FILE_FLAG;
    var file = File.open(context, bound.path, switch (bound.mode) {
        .create => &[_]F{ .FILE_FLAG_WRITE, .FILE_FLAG_CREATE_NEW },
        .append => &[_]F{ .FILE_FLAG_WRITE, .FILE_FLAG_APPEND, .FILE_FLAG_CREATE },
        .exclusive => &[_]F{ .FILE_FLAG_WRITE, .FILE_FLAG_CREATE, .FILE_FLAG_EXCLUSIVE_CREATE },
        .at => &[_]F{ .FILE_FLAG_WRITE, .FILE_FLAG_CREATE, .FILE_FLAG_PARALLEL_ACCESS },
    }, err) orelse return;
    defer file.deinit();

    if (bound.mode == .at) {
        // All of it at the offset, or an error; the position is not moved.
        if (bound.bytes.len > 0 and v2.duckdb_v2_file_write_at(file.handle, bound.bytes.ptr, bound.bytes.len, bound.offset, err) != .ERROR_NONE) return;
    } else {
        // At the position, which moves by what was written; a short count is not an error, so go on.
        var done: u64 = 0;
        while (done < bound.bytes.len) {
            var n: u64 = 0;
            if (v2.duckdb_v2_file_write(file.handle, bound.bytes.ptr + done, bound.bytes.len - done, &n, err) != .ERROR_NONE) return;
            if (n == 0) return fail(err, .ERROR_IO_GENERAL, "zig_cookbook_fs_write: the file accepted no more bytes", .{});
            done += n;
        }
    }
    // Durable before reporting: sync flushes, close releases the descriptor and reports its own failure.
    if (v2.duckdb_v2_file_sync(file.handle, err) != .ERROR_NONE) return;
    const size = file.size(err) orelse return;
    const position = file.tell(err) orelse return;
    if (v2.duckdb_v2_file_close(file.handle, err) != .ERROR_NONE) return;

    const out = [_]i64{ @intCast(bound.bytes.len), @intCast(size), @intCast(position) };
    for (out, 0..) |value, c| {
        const col = outColumn(scan, c, err) orelse return;
        @as([*]i64, @ptrCast(@alignCast(col.data)))[0] = value;
    }
}

// --- registration ----------------------------------------------------------------------------------------------------

fn registerFunction(
    input: *const v2.duckdb_v2_extension_input,
    err: Err,
    name: []const u8,
    docs: helpers.Docs,
    params: []const Param,
    bind: anytype,
    exec: anytype,
) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);
    const fn_name = helpers.str(name);
    if (v2.duckdb_v2_table_function_set_name(function, &fn_name, err) != .ERROR_NONE) return error.FailedToSetName;

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    for (params) |param| {
        var t: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(input.context, param.id, &t, err) != .ERROR_NONE) return error.FailedToCreateType;
        defer _ = v2.duckdb_v2_logical_type_destroy(&t);
        var default: ?v2.duckdb_v2_value_handle = null;
        defer if (default) |*d| {
            _ = v2.duckdb_v2_value_destroy(d);
        };
        if (param.default) |d| {
            var value: v2.duckdb_v2_value_handle = undefined;
            const code = switch (d) {
                .int => |i| v2.duckdb_v2_value_create_bigint(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, i, &value, err),
                .text => |s| blk: {
                    const text = helpers.str(s);
                    break :blk v2.duckdb_v2_value_create_varchar(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &text, &value, err);
                },
            };
            if (code != .ERROR_NONE) return error.FailedToCreateDefault;
            default = value;
        }
        const p_name = helpers.str(param.name);
        if (v2.duckdb_v2_function_signature_add_parameter(sig, &p_name, t, default orelse null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
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
    try registerFunction(input, err, "zig_cookbook_fs_read", .{
        .description = "The content of a file (BLOB) read through DuckDB's file system, so file: URLs, ~ and remote file systems work; all of it, or length bytes from start.",
        .examples = &.{.{ .sql = "SELECT * FROM zig_cookbook_fs_write('/tmp/zig_cookbook_example.txt', 'hello world'); SELECT content::VARCHAR FROM zig_cookbook_fs_read('/tmp/zig_cookbook_example.txt', start := 6);" }},
        .categories = &.{"file"},
    }, &.{
        .{ .name = "path", .id = .LOGICAL_TYPE_ID_VARCHAR },
        .{ .name = "start", .id = .LOGICAL_TYPE_ID_BIGINT, .default = .{ .int = 0 } },
        .{ .name = "length", .id = .LOGICAL_TYPE_ID_BIGINT, .default = .{ .int = -1 } },
    }, &readBind, &readExec);
    try registerFunction(input, err, "zig_cookbook_fs_write", .{
        .description = "Writes text to a file through DuckDB's file system: create (truncate), append, exclusive (fails if it exists) or at an offset (start); returns the bytes written, the size and the position.",
        .examples = &.{.{ .sql = "SELECT * FROM zig_cookbook_fs_write('/tmp/zig_cookbook_example.txt', 'hello', mode := 'create');" }},
        .categories = &.{"file"},
    }, &.{
        .{ .name = "path", .id = .LOGICAL_TYPE_ID_VARCHAR },
        .{ .name = "content", .id = .LOGICAL_TYPE_ID_VARCHAR },
        .{ .name = "mode", .id = .LOGICAL_TYPE_ID_VARCHAR, .default = .{ .text = "create" } },
        .{ .name = "start", .id = .LOGICAL_TYPE_ID_BIGINT, .default = .{ .int = 0 } },
    }, &writeBind, &writeExec);
}
