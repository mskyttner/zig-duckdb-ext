///! Cookbook: the parts of DuckDB's SQL front end that an extension can use: identifiers, qualified names, UTF-8.
///!
///!   zig_cookbook_quote_ident(name VARCHAR) -> VARCHAR        identifier_render_quoted
///!   zig_cookbook_qname_render(text VARCHAR) -> VARCHAR       qname_parse + qname_render: the canonical spelling
///!   zig_cookbook_qname_equals(a VARCHAR, b VARCHAR) -> BOOLEAN   qname_parse x2 + qname_equals
///!   zig_cookbook_qname_hash(text VARCHAR) -> UBIGINT         qname_parse + qname_hash
///!   zig_cookbook_qname_parts(text VARCHAR) -> (position, part, quoted)   qname_get_part_count / qname_get_part
///!   zig_cookbook_is_utf8(bytes BLOB) -> BOOLEAN              validate_utf8
///!
///! **What is not here:** the tokenizer (`tokenize_sql`) and the parser (`parse_sql`, `sql_statement_*`,
///! `statement_bind`) take a *connection*, which an extension is never given (see `embed_sql.zig`, where both are
///! shown). The calls on this page work on text alone, so they run anywhere, in an extension too.
///!
///! The rules the engine applies, and the functions return:
///!   - an identifier is quoted only when it has to be: `"select"` (a keyword), `"a b"`, `"a""b"` (quotes doubled),
///!     but `abc` stays bare;
///!   - an empty identifier is rendered as `""`, which is not a legal part of a qualified name (it does not parse back);
///!   - a qualified name has one to three parts; dots separate them, a double-quoted part may contain dots, more
///!     than three parts is an error, and so is an unterminated quote or text without a part;
///!   - names are equal when every part matches **case-insensitively**, and equal names hash equal (the hash is for
///!     in-process tables only: not stable across processes or versions).
///!
///! The two-call pattern of the render calls: with `out_text = NULL` they report the length needed, then the caller
///! provides a buffer of that length plus one for the terminator. A buffer that is too small is an error that also
///! reports the length (`ERROR_INPUT_OBJECT_SIZE`). Nothing is allocated on the caller's behalf.
///!
///! A NULL argument gives a NULL result (the default null handling), so every callback sees values only.
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

// --- the calls, in Zig terms --------------------------------------------------------------------------------------

/// The engine's SQL spelling of one identifier. The result is allocated with `alloc`.
fn quoteIdentifier(alloc: std.mem.Allocator, name: []const u8, err: Err) ?[]const u8 {
    const id = helpers.str(name);
    var needed: u64 = 0;
    // First call: no buffer, just the length. `out_text` is declared non-optional, so a null is passed as one.
    var no_buffer: ?[*]u8 = null;
    if (v2.duckdb_v2_identifier_render_quoted(&id, @as(*const [*]u8, @ptrCast(&no_buffer)).*, 0, &needed, err) != .ERROR_NONE) return null;
    // Second: a buffer for the text and its terminator.
    const buffer = alloc.alloc(u8, needed + 1) catch {
        oom(err);
        return null;
    };
    var written: u64 = 0;
    if (v2.duckdb_v2_identifier_render_quoted(&id, buffer.ptr, buffer.len, &written, err) != .ERROR_NONE) return null;
    return buffer[0..written];
}

/// A parsed qualified name. Destroy it.
const QName = struct {
    handle: v2.duckdb_v2_qname_handle,

    fn parse(text: []const u8, err: Err) ?QName {
        const s = helpers.str(text);
        var handle: v2.duckdb_v2_qname_handle = undefined;
        // The parser's own error: "unterminated quote", "too many parts", ...
        if (v2.duckdb_v2_qname_parse(&s, &handle, err) != .ERROR_NONE) return null;
        return .{ .handle = handle };
    }

    fn deinit(self: *QName) void {
        _ = v2.duckdb_v2_qname_destroy(&self.handle);
    }

    fn render(self: QName, alloc: std.mem.Allocator, err: Err) ?[]const u8 {
        var needed: u64 = 0;
        var no_buffer: ?[*]u8 = null;
        if (v2.duckdb_v2_qname_render(self.handle, @as(*const [*]u8, @ptrCast(&no_buffer)).*, 0, &needed, err) != .ERROR_NONE) return null;
        const buffer = alloc.alloc(u8, needed + 1) catch {
            oom(err);
            return null;
        };
        var written: u64 = 0;
        if (v2.duckdb_v2_qname_render(self.handle, buffer.ptr, buffer.len, &written, err) != .ERROR_NONE) return null;
        return buffer[0..written];
    }
};

// --- scalar functions ----------------------------------------------------------------------------------------------

const Value = union(enum) { text: []const u8, boolean: bool, hash: u64 };
const OutType = enum { varchar, boolean, ubigint };

/// A scalar function of `n` string arguments: `compute` maps one row to a value (or fails the query through `err`).
fn Scalar(comptime n: usize, comptime out: OutType, comptime compute: fn (std.mem.Allocator, [n][]const u8, Err) ?Value) type {
    return struct {
        fn exec(info: v2.duckdb_v2_scalar_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
            _ = context;
            var row_count: u64 = 0;
            if (v2.duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, err) != .ERROR_NONE) return;
            var views: [n]v2.duckdb_v2_vector_view = undefined;
            for (&views, 0..) |*view, i| {
                var vec: v2.duckdb_v2_vector_handle = undefined;
                if (v2.duckdb_v2_scalar_function_exec_get_arg(info, i, &vec, err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_flatten(vec, err) != .ERROR_NONE) return;
                if (v2.duckdb_v2_vector_get_view(vec, view, err) != .ERROR_NONE) return;
            }
            var result: v2.duckdb_v2_vector_handle = undefined;
            if (v2.duckdb_v2_scalar_function_exec_get_result(info, &result, err) != .ERROR_NONE) return;
            if (v2.duckdb_v2_vector_set_size(result, row_count, err) != .ERROR_NONE) return;
            var out_ptr: ?*anyopaque = null;
            if (v2.duckdb_v2_vector_get_data_mutable(result, &out_ptr, err) != .ERROR_NONE) return;
            var arena_handle: v2.duckdb_v2_arena_handle = undefined;
            if (out == .varchar and v2.duckdb_v2_vector_get_arena(result, &arena_handle, err) != .ERROR_NONE) return;

            // Scratch memory for one call's text, freed in one go.
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();

            for (0..row_count) |row| {
                var valid = true;
                for (views) |view| valid = valid and helpers.isValid(view.validity, row);
                if (!valid) {
                    if (v2.duckdb_v2_vector_set_null(result, row, err) != .ERROR_NONE) return;
                    continue;
                }
                var args: [n][]const u8 = undefined;
                for (&args, views) |*a, view| {
                    const data: [*]const v2.duckdb_v2_bytes = @ptrCast(@alignCast(view.data orelse return));
                    a.* = helpers.bytesSlice(&data[row]);
                }
                _ = scratch.reset(.retain_capacity);
                const value = compute(scratch.allocator(), args, err) orelse return;
                switch (out) {
                    .varchar => @as([*]v2.duckdb_v2_bytes, @ptrCast(@alignCast(out_ptr.?)))[row] = helpers.makeBytesValue(arena_handle, value.text, err) catch return,
                    .boolean => @as([*]u8, @ptrCast(out_ptr.?))[row] = @intFromBool(value.boolean),
                    .ubigint => @as([*]u64, @ptrCast(@alignCast(out_ptr.?)))[row] = value.hash,
                }
            }
        }
    };
}

fn quoteCompute(alloc: std.mem.Allocator, args: [1][]const u8, err: Err) ?Value {
    return .{ .text = quoteIdentifier(alloc, args[0], err) orelse return null };
}

fn renderCompute(alloc: std.mem.Allocator, args: [1][]const u8, err: Err) ?Value {
    var name = QName.parse(args[0], err) orelse return null;
    defer name.deinit();
    return .{ .text = name.render(alloc, err) orelse return null };
}

fn equalsCompute(alloc: std.mem.Allocator, args: [2][]const u8, err: Err) ?Value {
    _ = alloc;
    var left = QName.parse(args[0], err) orelse return null;
    defer left.deinit();
    var right = QName.parse(args[1], err) orelse return null;
    defer right.deinit();
    var equal = false;
    if (v2.duckdb_v2_qname_equals(left.handle, right.handle, &equal, err) != .ERROR_NONE) return null;
    return .{ .boolean = equal };
}

fn hashCompute(alloc: std.mem.Allocator, args: [1][]const u8, err: Err) ?Value {
    _ = alloc;
    var name = QName.parse(args[0], err) orelse return null;
    defer name.deinit();
    var hash: u64 = 0;
    if (v2.duckdb_v2_qname_hash(name.handle, &hash, err) != .ERROR_NONE) return null;
    return .{ .hash = hash };
}

fn utf8Compute(alloc: std.mem.Allocator, args: [1][]const u8, err: Err) ?Value {
    _ = alloc;
    _ = err;
    const bytes = helpers.str(args[0]);
    // Not an error for the caller: the failure is the answer. Ask without an error slot, so nothing is allocated.
    return .{ .boolean = v2.duckdb_v2_validate_utf8(&bytes, null) == .ERROR_NONE };
}

fn registerScalar(
    input: *const v2.duckdb_v2_extension_input,
    err: Err,
    name: []const u8,
    arg_ids: []const v2.DUCKDB_V2_LOGICAL_TYPE_ID,
    return_id: v2.DUCKDB_V2_LOGICAL_TYPE_ID,
    exec: anytype,
) !void {
    var function: v2.duckdb_v2_scalar_function_handle = undefined;
    if (v2.duckdb_v2_scalar_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_scalar_function_destroy(&function);
    const fn_name = helpers.str(name);
    if (v2.duckdb_v2_scalar_function_set_name(function, &fn_name, err) != .ERROR_NONE) return error.FailedToSetName;
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_scalar_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const param_names = [_][]const u8{ "a", "b" };
    for (arg_ids, 0..) |id, i| {
        var ty: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(input.context, id, &ty, err) != .ERROR_NONE) return error.FailedToCreateType;
        defer _ = v2.duckdb_v2_logical_type_destroy(&ty);
        const p = helpers.str(param_names[i]);
        if (v2.duckdb_v2_function_signature_add_parameter(sig, &p, ty, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    }
    var ret: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, return_id, &ret, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&ret);
    if (v2.duckdb_v2_function_signature_set_return_type(sig, ret, err) != .ERROR_NONE) return error.FailedToSetReturnType;
    if (v2.duckdb_v2_scalar_function_set_exec_callback(function, exec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_extension_register_scalar_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

// --- zig_cookbook_qname_parts(text) --------------------------------------------------------------------------------

const Parts = struct {
    arena: std.heap.ArenaAllocator,
    parts: []const []const u8,
    quoted: []const []const u8,
};

fn destroyParts(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `partsBind` stored a `*Parts`.
    const data: *Parts = @ptrCast(@alignCast(ptr));
    data.arena.deinit();
    gpa.destroy(data);
}

const Cursor = struct { next: usize = 0 };

fn destroyCursor(ptr: *anyopaque) callconv(.c) void {
    // SAFETY: `partsInitGlobal` stored a `*Cursor`.
    gpa.destroy(@as(*Cursor, @ptrCast(@alignCast(ptr))));
}

fn partsBind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    const data = gpa.create(Parts) catch return oom(err);
    data.* = .{ .arena = .init(gpa), .parts = &.{}, .quoted = &.{} };
    var keep = false;
    defer if (!keep) destroyParts(data);
    const arena = data.arena.allocator();

    var value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, 0, &value, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var text: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_value_get_varchar(value, &text, err) != .ERROR_NONE) return;

    var name = QName.parse((text.ptr orelse return)[0..text.len], err) orelse return;
    defer name.deinit();
    var count: u64 = 0;
    if (v2.duckdb_v2_qname_get_part_count(name.handle, &count, err) != .ERROR_NONE) return;
    const parts = arena.alloc([]const u8, count) catch return oom(err);
    const quoted = arena.alloc([]const u8, count) catch return oom(err);
    for (0..count) |i| {
        var part: v2.duckdb_v2_identifier_t = undefined; // borrowed from the name: copied before it is destroyed
        if (v2.duckdb_v2_qname_get_part(name.handle, i, &part, err) != .ERROR_NONE) return;
        parts[i] = arena.dupe(u8, (part.ptr orelse return)[0..part.len]) catch return oom(err);
        quoted[i] = quoteIdentifier(arena, parts[i], err) orelse return;
    }
    data.parts = parts;
    data.quoted = quoted;

    const columns = [_]struct { []const u8, v2.DUCKDB_V2_LOGICAL_TYPE_ID }{
        .{ "position", .LOGICAL_TYPE_ID_BIGINT },
        .{ "part", .LOGICAL_TYPE_ID_VARCHAR },
        .{ "quoted", .LOGICAL_TYPE_ID_VARCHAR },
    };
    for (columns) |c| {
        var t: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(context, c[1], &t, err) != .ERROR_NONE) return;
        defer _ = v2.duckdb_v2_logical_type_destroy(&t);
        const column_name = helpers.str(c[0]);
        if (v2.duckdb_v2_table_function_bind_add_result_column(result, &column_name, t, err) != .ERROR_NONE) return;
    }
    if (v2.duckdb_v2_table_function_bind_set_cardinality(result, count, true, err) != .ERROR_NONE) return;
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyParts, .equals = null };
    if (v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err) != .ERROR_NONE) return;
    keep = true;
}

fn partsInitGlobal(info: v2.duckdb_v2_table_function_init_global_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    if (v2.duckdb_v2_table_function_init_global_set_max_threads(info, 1, err) != .ERROR_NONE) return;
    const cursor = gpa.create(Cursor) catch return oom(err);
    cursor.* = .{};
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = cursor, .destroy = destroyCursor, .equals = null };
    if (v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err) != .ERROR_NONE) destroyCursor(cursor);
}

fn partsExec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    var cursor_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &cursor_ptr, err) != .ERROR_NONE) return;
    // SAFETY: the types stored by `partsBind` and `partsInitGlobal`.
    const bound: *const Parts = @ptrCast(@alignCast(bind_ptr.?));
    const cursor: *Cursor = @ptrCast(@alignCast(cursor_ptr.?));
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;

    const first = cursor.next;
    const n = bound.parts.len - first;
    cursor.next = bound.parts.len;
    var vecs: [3]v2.duckdb_v2_vector_handle = undefined;
    var data: [3]?*anyopaque = undefined;
    for (0..3) |c| {
        if (v2.duckdb_v2_data_chunk_get_vector(chunk, c, &vecs[c], err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_set_size(vecs[c], n, err) != .ERROR_NONE) return;
        if (v2.duckdb_v2_vector_get_data_mutable(vecs[c], &data[c], err) != .ERROR_NONE) return;
    }
    if (n == 0) return;
    var part_arena: v2.duckdb_v2_arena_handle = undefined;
    var quoted_arena: v2.duckdb_v2_arena_handle = undefined;
    if (v2.duckdb_v2_vector_get_arena(vecs[1], &part_arena, err) != .ERROR_NONE) return;
    if (v2.duckdb_v2_vector_get_arena(vecs[2], &quoted_arena, err) != .ERROR_NONE) return;
    const positions: [*]i64 = @ptrCast(@alignCast(data[0].?));
    const part_out: [*]v2.duckdb_v2_bytes = @ptrCast(@alignCast(data[1].?));
    const quoted_out: [*]v2.duckdb_v2_bytes = @ptrCast(@alignCast(data[2].?));
    for (0..n) |i| {
        positions[i] = @intCast(first + i);
        part_out[i] = helpers.makeBytesValue(part_arena, bound.parts[first + i], err) catch return;
        quoted_out[i] = helpers.makeBytesValue(quoted_arena, bound.quoted[first + i], err) catch return;
    }
}

fn registerParts(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) return error.FailedToCreateFunction;
    defer _ = v2.duckdb_v2_table_function_destroy(&function);
    const name = helpers.str("zig_cookbook_qname_parts");
    if (v2.duckdb_v2_table_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;
    var varchar: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar, err) != .ERROR_NONE) return error.FailedToCreateType;
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar);
    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    const p = helpers.str("text");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &p, varchar, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    if (v2.duckdb_v2_table_function_set_bind_callback(function, &partsBind, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &partsInitGlobal, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &partsExec, err) != .ERROR_NONE) return error.FailedToSetCallback;
    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterFunction;
}

/// Registers the functions. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    const varchar = v2.DUCKDB_V2_LOGICAL_TYPE_ID.LOGICAL_TYPE_ID_VARCHAR;
    try registerScalar(input, err, "zig_cookbook_quote_ident", &.{varchar}, varchar, &Scalar(1, .varchar, quoteCompute).exec);
    try registerScalar(input, err, "zig_cookbook_qname_render", &.{varchar}, varchar, &Scalar(1, .varchar, renderCompute).exec);
    try registerScalar(input, err, "zig_cookbook_qname_equals", &.{ varchar, varchar }, .LOGICAL_TYPE_ID_BOOLEAN, &Scalar(2, .boolean, equalsCompute).exec);
    try registerScalar(input, err, "zig_cookbook_qname_hash", &.{varchar}, .LOGICAL_TYPE_ID_UBIGINT, &Scalar(1, .ubigint, hashCompute).exec);
    try registerScalar(input, err, "zig_cookbook_is_utf8", &.{.LOGICAL_TYPE_ID_BLOB}, .LOGICAL_TYPE_ID_BOOLEAN, &Scalar(1, .boolean, utf8Compute).exec);
    try registerParts(input, err);
}
