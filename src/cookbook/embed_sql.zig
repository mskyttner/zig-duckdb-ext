///! Cookbook: running SQL with the v2 C API, from a program that embeds DuckDB (`zig build cookbook-embed`).
///!
///! **Not from an extension.** Every query function of the v2 API (`parse_sql`, `statement_execute`,
///! `prepared_statement_create`, ...) takes a *connection*, and an extension is never handed one: its entry point
///! gets an extension handle and a *context*, "a connection seen from inside DuckDB", which is for reading settings
///! and building values and types, and no call turns a context into a connection. A program that hosts DuckDB
///! creates the connection itself, and that is what this file shows:
///!
///!   environment -> instance -> attach a database -> connection
///!   parse_sql        text -> an iterator over statements (parsing only: no binding, no catalog)
///!   statement_execute / prepared_statement_execute -> a **lazy** result: nothing runs until it is stepped
///!   result_fetch_chunk / result_drain / result_get_schema -> rows, side effects, columns
///!
///! **Tokenizing and parsing** are also here, because both take a connection (`tokenize_sql`, `parse_sql`): the lexical
///! classes of a text (`tokenizing`), and the kind, text and parameters of each statement without binding it
///! (`parsing`). The calls that work on text alone (identifiers, qualified names, UTF-8) run in an extension: see
///! `names.zig`.
///!
///! A query can also come back as **Arrow** (`statement_execute_arrow`: an `ArrowSchema` and `ArrowArray`s of the C Data
///! Interface instead of chunks), which is what a host handing rows to PyArrow or Arrow C++ wants. `arrowResults` below
///! reads one; the extension side of the interface (an exporter and an importer made from a context) is
///! `arrow_c_data.zig`.
///!
///! The program checks what it prints and exits non-zero on any difference. Only what is built into the library is
///! there: functions such as `sum` live in the `core_functions` extension, which is not linked (`-Dstatic-extensions`
///! links extensions into the other embedding programs).
///!
///! One trap: the error slot passed to a call must start as NULL (`Call.slot`). A call that fails fills in the error
///! info it finds in the slot, and only allocates one if the slot is empty (`WithErrorHandler` in DuckDB's source), so an
///! uninitialised slot is written through at the first failure and the process crashes instead of reporting an error.
///! A successful call never touches the slot. The slots DuckDB hands to an extension (a callback's `err`, the
///! entry point's `input.err`) are live ones and safe to pass on.
///!
///! The program links the static libraries (the static bindings: plain `extern` functions), like `v2-static-embed-poc`.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

// --- errors ---------------------------------------------------------------------------------------------------------

var error_text_buf: [1024]u8 = undefined;
/// The text and code of the last failed call: DuckDB's reason, copied before the error info is destroyed.
var error_text: []const u8 = "";
var error_code: v2.DUCKDB_V2_ERROR = .ERROR_NONE;

/// One call's error slot. Pass `c.err()` as the last argument and hand the return code to `ok`: on failure the slot
/// holds an error info that this program owns, so `ok` reads it and destroys it.
const Call = struct {
    /// Null until a call fails. The slot is declared as a non-null handle in the bindings, hence the cast.
    slot: ?v2.duckdb_v2_error_info_handle = null,

    fn err(self: *Call) *v2.duckdb_v2_error_info_handle {
        // SAFETY: `?*T` and `*T` have the same layout, with null as the extra value.
        return @ptrCast(&self.slot);
    }

    fn ok(self: *Call, code: v2.DUCKDB_V2_ERROR) error{DuckDb}!void {
        if (code == .ERROR_NONE) return;
        var info = self.slot.?;
        var reason: v2.duckdb_v2_str = undefined;
        _ = v2.duckdb_v2_error_info_get_text(info, &reason);
        _ = v2.duckdb_v2_error_info_get_code(info, &error_code);
        const n = @min(reason.len, error_text_buf.len);
        if (reason.ptr) |p| @memcpy(error_text_buf[0..n], p[0..n]);
        error_text = error_text_buf[0..n];
        _ = v2.duckdb_v2_error_info_destroy(&info);
        self.slot = null;
        return error.DuckDb;
    }
};

fn view(s: v2.duckdb_v2_str) []const u8 {
    const p = s.ptr orelse return "";
    return p[0..s.len];
}

fn typeName(id: v2.DUCKDB_V2_LOGICAL_TYPE_ID) []const u8 {
    const tag = std.enums.tagName(v2.DUCKDB_V2_LOGICAL_TYPE_ID, id) orelse return "UNKNOWN";
    return tag["LOGICAL_TYPE_ID_".len..];
}

// --- the database --------------------------------------------------------------------------------------------------

const Session = struct {
    env: v2.duckdb_v2_environment_handle,
    instance: v2.duckdb_v2_instance_handle,
    conn: v2.duckdb_v2_connection_handle,
    varchar: v2.duckdb_v2_logical_type_handle,

    /// An in-memory database. The environment is the root every instance hangs from; it detects the same file
    /// being opened twice. The instance starts empty and unstarted: attach a database, then connect.
    fn open() !Session {
        var s: Session = undefined;
        var c: Call = .{};
        try c.ok(v2.duckdb_v2_environment_create(&s.env, c.err()));
        errdefer _ = v2.duckdb_v2_environment_destroy(&s.env);
        try c.ok(v2.duckdb_v2_instance_create(s.env, &s.instance, c.err()));
        errdefer _ = v2.duckdb_v2_instance_destroy(&s.instance);
        const memory = helpers.str(":memory:");
        try c.ok(v2.duckdb_v2_instance_attach(s.instance, &memory, null, null, true, c.err()));
        try c.ok(v2.duckdb_v2_connection_create(s.instance, &s.conn, c.err()));
        errdefer _ = v2.duckdb_v2_connection_destroy(&s.conn);
        try c.ok(v2.duckdb_v2_connection_create_type_from_id(s.conn, .LOGICAL_TYPE_ID_VARCHAR, null, null, 0, &s.varchar, c.err()));
        return s;
    }

    fn close(self: *Session) void {
        _ = v2.duckdb_v2_logical_type_destroy(&self.varchar);
        _ = v2.duckdb_v2_connection_destroy(&self.conn);
        _ = v2.duckdb_v2_instance_destroy(&self.instance);
        _ = v2.duckdb_v2_environment_destroy(&self.env);
    }

    /// A second connection to the same instance: its own session, the same catalog.
    fn connect(self: *Session) !v2.duckdb_v2_connection_handle {
        var conn: v2.duckdb_v2_connection_handle = undefined;
        var c: Call = .{};
        try c.ok(v2.duckdb_v2_connection_create(self.instance, &conn, c.err()));
        return conn;
    }
};

// --- results -------------------------------------------------------------------------------------------------------

/// A result read to the end.
const Table = struct {
    result_type: v2.DUCKDB_V2_RESULT_TYPE,
    columns: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    /// One entry per row, the values as text ("NULL" for a NULL).
    rows: []const []const []const u8 = &.{},
    chunks: usize = 0,
    changed_rows: u64 = 0,

    /// "a|b" per row, rows joined by ";".
    fn flat(self: Table, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.rows, 0..) |row, i| {
            if (i > 0) try out.append(arena, ';');
            for (row, 0..) |cell, j| {
                if (j > 0) try out.append(arena, '|');
                try out.appendSlice(arena, cell);
            }
        }
        return out.items;
    }
};

/// Reads a result: the schema first (known before anything runs), then, for a result with rows, chunk after chunk,
/// and for any other result the side effects are applied by draining.
fn collect(arena: std.mem.Allocator, s: *Session, result: *v2.duckdb_v2_result_handle) !Table {
    defer _ = v2.duckdb_v2_result_destroy(result);
    var c: Call = .{};
    var table: Table = .{ .result_type = undefined };
    try c.ok(v2.duckdb_v2_result_get_result_type(result.*, &table.result_type, c.err()));

    var schema: v2.duckdb_v2_schema_handle = undefined;
    try c.ok(v2.duckdb_v2_result_get_schema(result.*, &schema, c.err()));
    defer _ = v2.duckdb_v2_schema_destroy(&schema);
    var column_count: u64 = 0;
    try c.ok(v2.duckdb_v2_schema_get_count(schema, &column_count, c.err()));
    const names = try arena.alloc([]const u8, column_count);
    const types = try arena.alloc([]const u8, column_count);
    for (0..column_count) |i| {
        var name: v2.duckdb_v2_identifier_t = undefined;
        var ty: v2.duckdb_v2_logical_type_handle = undefined; // borrowed from the schema: not destroyed
        try c.ok(v2.duckdb_v2_schema_get_field(schema, i, &name, &ty, c.err()));
        var id: v2.DUCKDB_V2_LOGICAL_TYPE_ID = undefined;
        try c.ok(v2.duckdb_v2_logical_type_get_id(ty, &id, c.err()));
        names[i] = try arena.dupe(u8, view(name));
        types[i] = typeName(id);
    }
    table.columns = names;
    table.types = types;

    if (table.result_type != .RESULT_TYPE_QUERY_RESULT) {
        // A statement without rows runs when it is drained, and not before: destroying an undrained result
        // abandons the execution, side effects included.
        try c.ok(v2.duckdb_v2_result_drain(result.*, &table.changed_rows, c.err()));
        return table;
    }

    var rows: std.ArrayList([]const []const u8) = .empty;
    while (true) {
        // End of stream is a null chunk. The out parameter is declared non-optional, so it is read as one.
        var chunk: ?v2.duckdb_v2_data_chunk_handle = null;
        // SAFETY: `?*T` and `*T` have the same layout, with null as the extra value.
        try c.ok(v2.duckdb_v2_result_fetch_chunk(result.*, @ptrCast(&chunk), c.err()));
        var owned = chunk orelse break;
        defer _ = v2.duckdb_v2_data_chunk_destroy(&owned);
        table.chunks += 1;

        var size: u64 = 0;
        try c.ok(v2.duckdb_v2_data_chunk_get_size(owned, &size, c.err()));
        for (0..size) |row| {
            const cells = try arena.alloc([]const u8, column_count);
            for (0..column_count) |col| cells[col] = try cellText(arena, s, owned, col, row);
            try rows.append(arena, cells);
        }
    }
    table.rows = rows.items;
    return table;
}

/// One cell as text: any type, through DuckDB's cast to VARCHAR.
fn cellText(arena: std.mem.Allocator, s: *Session, chunk: v2.duckdb_v2_data_chunk_handle, col: u64, row: u64) ![]const u8 {
    var c: Call = .{};
    var vec: v2.duckdb_v2_vector_handle = undefined;
    try c.ok(v2.duckdb_v2_data_chunk_get_vector(chunk, col, &vec, c.err()));
    var value: v2.duckdb_v2_value_handle = undefined;
    try c.ok(v2.duckdb_v2_vector_get_value(vec, row, &value, c.err()));
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var is_null = false;
    try c.ok(v2.duckdb_v2_value_is_null(value, &is_null, c.err()));
    if (is_null) return "NULL";
    var as_text: v2.duckdb_v2_value_handle = undefined;
    try c.ok(v2.duckdb_v2_value_cast_with_connection(s.conn, value, s.varchar, &as_text, c.err()));
    defer _ = v2.duckdb_v2_value_destroy(&as_text);
    var out: v2.duckdb_v2_str = undefined;
    try c.ok(v2.duckdb_v2_value_get_varchar(as_text, &out, c.err()));
    return arena.dupe(u8, view(out));
}

/// Parses `sql` into its statements and runs each, in order, to the end. One live result per connection, so the
/// next statement starts only when the previous result is destroyed.
fn runAll(arena: std.mem.Allocator, s: *Session, sql: []const u8) ![]Table {
    var c: Call = .{};
    const sql_z = try arena.dupeSentinel(u8, sql, 0);
    var iterator: v2.duckdb_v2_statement_iterator_handle = undefined;
    try c.ok(v2.duckdb_v2_parse_sql(s.conn, sql_z.ptr, &iterator, c.err()));
    defer _ = v2.duckdb_v2_statement_iterator_destroy(&iterator);

    var tables: std.ArrayList(Table) = .empty;
    while (true) {
        var statement: ?v2.duckdb_v2_sql_statement_handle = null;
        // SAFETY: as for the chunk: null ends the iteration.
        try c.ok(v2.duckdb_v2_statement_iterator_next(iterator, @ptrCast(&statement), c.err()));
        var owned = statement orelse break;
        defer _ = v2.duckdb_v2_sql_statement_destroy(&owned);

        var result: v2.duckdb_v2_result_handle = undefined;
        try c.ok(v2.duckdb_v2_statement_execute(s.conn, owned, null, null, 0, &result, c.err()));
        try tables.append(arena, try collect(arena, s, &result));
    }
    return tables.items;
}

/// One statement that returns rows, as "a|b;c|d".
fn query(arena: std.mem.Allocator, s: *Session, sql: []const u8) ![]const u8 {
    const tables = try runAll(arena, s, sql);
    return tables[tables.len - 1].flat(arena);
}

// --- checks --------------------------------------------------------------------------------------------------------

var checks: usize = 0;

fn expectEqual(what: []const u8, expected: []const u8, actual: []const u8) !void {
    checks += 1;
    if (std.mem.eql(u8, expected, actual)) return;
    std.debug.print("FAILED {s}\n  expected: {s}\n  actual:   {s}\n", .{ what, expected, actual });
    return error.Mismatch;
}

fn expectInt(what: []const u8, expected: u64, actual: u64) !void {
    checks += 1;
    if (expected == actual) return;
    std.debug.print("FAILED {s}: expected {d}, got {d}\n", .{ what, expected, actual });
    return error.Mismatch;
}

/// A call that must fail, with `fragment` in DuckDB's reason and the given code.
fn expectFailure(what: []const u8, result: anytype, code: v2.DUCKDB_V2_ERROR, fragment: []const u8) !void {
    checks += 1;
    if (result) |_| {
        std.debug.print("FAILED {s}: expected an error\n", .{what});
        return error.Mismatch;
    } else |_| {}
    if (error_code == code and std.mem.indexOf(u8, error_text, fragment) != null) return;
    std.debug.print("FAILED {s}\n  expected: {t} containing '{s}'\n  actual:   {t}: {s}\n", .{ what, code, fragment, error_code, error_text });
    return error.Mismatch;
}

// --- the recipe ----------------------------------------------------------------------------------------------------

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var session = Session.open() catch |e| {
        std.debug.print("cannot open a database: {s}\n", .{error_text});
        return e;
    };
    defer session.close();
    run(arena, &session) catch |e| {
        if (e == error.DuckDb) std.debug.print("DuckDB error {t}: {s}\n", .{ error_code, error_text });
        return e;
    };
    std.debug.print("all {d} embedded SQL checks passed\n", .{checks});
}

fn run(arena: std.mem.Allocator, s: *Session) !void {
    var c: Call = .{};

    // The library's own version.
    var version: v2.duckdb_v2_str = undefined;
    try c.ok(v2.duckdb_v2_library_version(&version, c.err()));
    try expectInt("library_version is not empty", 1, @intFromBool(version.len > 0));

    // The schema is known before anything runs; the values come with the chunks.
    const answer = (try runAll(arena, s, "SELECT 42 AS answer, 'duck' AS name, NULL::DOUBLE AS nothing"))[0];
    try expectEqual("columns", "answer,name,nothing", try std.mem.join(arena, ",", answer.columns));
    try expectEqual("column types", "INTEGER,VARCHAR,DOUBLE", try std.mem.join(arena, ",", answer.types));
    try expectEqual("values", "42|duck|NULL", try answer.flat(arena));

    // Several statements in one string: each has its own kind of result. DDL has nothing to return, DML a count of
    // changed rows, a query its rows.
    const script = try runAll(arena, s, "CREATE TABLE t (i INTEGER, s VARCHAR); INSERT INTO t SELECT i, 'row' || i FROM range(5000) r(i); SELECT count(*), max(i) FROM t");
    try expectInt("three statements", 3, script.len);
    try expectInt("CREATE has no rows", @backingInt(v2.DUCKDB_V2_RESULT_TYPE.RESULT_TYPE_NOTHING), @intCast(@backingInt(script[0].result_type)));
    try expectInt("INSERT reports changed rows", @backingInt(v2.DUCKDB_V2_RESULT_TYPE.RESULT_TYPE_CHANGED_ROWS), @intCast(@backingInt(script[1].result_type)));
    try expectInt("INSERT changed rows", 5000, script[1].changed_rows);
    try expectEqual("SELECT", "5000|4999", try script[2].flat(arena));

    // Rows arrive in chunks of at most 2048: 5000 rows are three chunks.
    const stream = (try runAll(arena, s, "SELECT i FROM t ORDER BY i"))[0];
    try expectInt("rows", 5000, stream.rows.len);
    try expectInt("chunks", 3, stream.chunks);
    try expectEqual("first and last row", "0,4999", try std.fmt.allocPrint(arena, "{s},{s}", .{ stream.rows[0][0], stream.rows[4999][0] }));

    try parameters(arena, s);
    try errors(arena, s);
    try lazyExecution(arena, s);
    try arrowResults(s);
    try tokenizing(arena, s);
    try parsing(arena, s);
}

/// The tokens of `sql` as "CLASS:lexeme" words, separated by a space. Whitespace is not a token.
fn tokens(arena: std.mem.Allocator, s: *Session, sql: ?[]const u8, unterminated: ?*bool) ![]const u8 {
    var c: Call = .{};
    const text = if (sql) |t| helpers.str(t) else v2.duckdb_v2_str{ .ptr = null, .len = 0 };
    var iterator: v2.duckdb_v2_token_iterator_handle = undefined;
    try c.ok(v2.duckdb_v2_tokenize_sql(s.conn, &text, &iterator, c.err()));
    defer _ = v2.duckdb_v2_token_iterator_destroy(&iterator);
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        var class: v2.DUCKDB_V2_TOKEN_TYPE = undefined;
        var start: u64 = 0;
        var length: u64 = 0;
        try c.ok(v2.duckdb_v2_token_iterator_next(iterator, &class, &start, &length, c.err()));
        // After the last token: END_OF_INPUT, at the end of the input, with no length. It repeats if asked again.
        if (class == .TOKEN_TYPE_END_OF_INPUT) {
            try expectInt("END_OF_INPUT starts at the end", (sql orelse @as([]const u8, "")).len, start);
            try expectInt("END_OF_INPUT has no length", 0, length);
            break;
        }
        const name = @tagName(class)["TOKEN_TYPE_".len..];
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.print(arena, "{s}:{s}", .{ name, (sql.?)[start..][0..length] });
    }
    if (unterminated) |flag| try c.ok(v2.duckdb_v2_token_iterator_ends_unterminated(iterator, flag, c.err()));
    return out.items;
}

/// Tokenizing: the lexical classes of a statement's text, with offsets into it, by the grammar of the connection.
/// No parsing and no catalog, so nothing needs to exist, and malformed input is not an error: the iterator says
/// whether the input ended inside an open string, quoted identifier or comment.
fn tokenizing(arena: std.mem.Allocator, s: *Session) !void {
    try expectEqual("a query", "KEYWORD:SELECT NUMBER_LITERAL:1 OPERATOR:+ NUMBER_LITERAL:2.5e3 KEYWORD:AS IDENTIFIER:x OPERATOR:, STRING_LITERAL:'it''s' KEYWORD:FROM IDENTIFIER:\"My Col\" TERMINATOR:;", try tokens(arena, s, "SELECT 1 + 2.5e3 AS x, 'it''s' FROM \"My Col\";", null));
    try expectEqual("comments are tokens", "KEYWORD:SELECT COMMENT:/* a ; b */ NUMBER_LITERAL:1 COMMENT:-- tail", try tokens(arena, s, "SELECT /* a ; b */ 1 -- tail", null));
    try expectEqual("a dollar-quoted string is one token", "KEYWORD:SELECT STRING_LITERAL:$$x;y$$ TERMINATOR:;", try tokens(arena, s, "SELECT $$x;y$$;", null));
    try expectEqual("nothing", "", try tokens(arena, s, null, null));
    try expectEqual("only whitespace", "", try tokens(arena, s, "  \n\t ", null));

    var open = false;
    try expectEqual("a string left open", "KEYWORD:SELECT STRING_LITERAL:'abc", try tokens(arena, s, "SELECT 'abc", &open));
    try expectInt("the input ended inside a token", 1, @intFromBool(open));
    inline for (.{ "SELECT \"abc", "SELECT 1 /* x", "SELECT 1 -- no newline", "SELECT $$abc" }) |sql| {
        open = false;
        _ = try tokens(arena, s, sql, &open);
        try expectInt("unterminated: " ++ sql, 1, @intFromBool(open));
    }
    inline for (.{ "SELECT 1", "SELECT 1 -- with newline\n", "SELECT 'a'", "", "  " }) |sql| {
        open = true;
        _ = try tokens(arena, s, sql, &open);
        try expectInt("terminated: " ++ sql, 0, @intFromBool(open));
    }
}

/// Parsing: text to statements, and what can be known without a catalog: the kind, the text of each statement and
/// its parameters. Nothing is bound, so a statement may name a table that does not exist.
fn parsing(arena: std.mem.Allocator, s: *Session) !void {
    var c: Call = .{};
    const sql = try arena.dupeSentinel(u8, "SELECT $1; /* c */ INSERT INTO no_such_table VALUES (1);\nCREATE TABLE x (i INTEGER); DROP TABLE y", 0);
    var iterator: v2.duckdb_v2_statement_iterator_handle = undefined;
    try c.ok(v2.duckdb_v2_parse_sql(s.conn, sql.ptr, &iterator, c.err()));
    defer _ = v2.duckdb_v2_statement_iterator_destroy(&iterator);

    var seen: std.ArrayList(u8) = .empty;
    while (true) {
        var statement: ?v2.duckdb_v2_sql_statement_handle = null;
        try c.ok(v2.duckdb_v2_statement_iterator_next(iterator, @ptrCast(&statement), c.err()));
        var owned = statement orelse break;
        defer _ = v2.duckdb_v2_sql_statement_destroy(&owned);
        var kind: v2.DUCKDB_V2_STATEMENT_TYPE = undefined;
        try c.ok(v2.duckdb_v2_sql_statement_get_type(owned, &kind, c.err()));
        var text: v2.duckdb_v2_str = undefined;
        try c.ok(v2.duckdb_v2_sql_statement_get_text(owned, &text, c.err()));
        var n_params: u64 = 0;
        try c.ok(v2.duckdb_v2_sql_statement_get_parameter_count(owned, &n_params, c.err()));
        try seen.print(arena, "{s}|{s}|{d};", .{ @tagName(kind)["STATEMENT_TYPE_".len..], view(text), n_params });
    }
    // Four statements, each with its kind, its own text (up to the next statement: the comment and the newline that
    // follow a `;` belong to the statement before it) and its parameter count. Nothing was bound: `no_such_table`
    // is not looked up.
    try expectEqual("statements", "SELECT|SELECT $1; /* c */ |1;INSERT|INSERT INTO no_such_table VALUES (1);\n|0;CREATE|CREATE TABLE x (i INTEGER); |0;DROP|DROP TABLE y|0;", seen.items);
}

/// A query's rows as Arrow: the schema first (a struct whose children are the columns), then arrays of at most the
/// batch size, until one comes back released. The caller releases every schema and array it is given.
fn arrowResults(s: *Session) !void {
    var c: Call = .{};
    const sql = "SELECT i AS id, 'row' || i AS name, CASE WHEN i % 5 = 0 THEN NULL ELSE i * 0.5 END::DOUBLE AS half FROM range(2500) r(i)";
    var iterator: v2.duckdb_v2_statement_iterator_handle = undefined;
    try c.ok(v2.duckdb_v2_parse_sql(s.conn, sql, &iterator, c.err()));
    defer _ = v2.duckdb_v2_statement_iterator_destroy(&iterator);
    var statement: ?v2.duckdb_v2_sql_statement_handle = null;
    try c.ok(v2.duckdb_v2_statement_iterator_next(iterator, @ptrCast(&statement), c.err()));
    var stmt = statement.?;
    defer _ = v2.duckdb_v2_sql_statement_destroy(&stmt);

    var result: v2.duckdb_v2_arrow_result_handle = undefined;
    try c.ok(v2.duckdb_v2_statement_execute_arrow(s.conn, stmt, null, null, 0, 1000, &result, c.err()));
    defer _ = v2.duckdb_v2_arrow_result_destroy(&result);

    var schema: v2.ArrowSchema = undefined;
    try c.ok(v2.duckdb_v2_arrow_result_get_schema(result, &schema, c.err()));
    defer if (schema.release) |release| release(&schema);
    try expectInt("the schema is a struct of three columns", 3, @intCast(schema.n_children));
    try expectEqual("schema format", "+s", std.mem.span(schema.format.?));
    var formats: std.ArrayList(u8) = .empty;
    for (0..3) |i| {
        const child = schema.children.?[i].?;
        try formats.print(std.heap.c_allocator, "{s}:{s} ", .{ std.mem.span(child.name.?), std.mem.span(child.format.?) });
    }
    defer formats.deinit(std.heap.c_allocator);
    try expectEqual("column names and Arrow formats", "id:l name:u half:g ", formats.items);

    var arrays: u64 = 0;
    var rows: i64 = 0;
    var id_sum: i64 = 0;
    var nulls: i64 = 0;
    while (true) {
        var array: v2.ArrowArray = undefined;
        try c.ok(v2.duckdb_v2_arrow_result_fetch_array(result, &array, c.err()));
        // A released array (`release == null`) is the end of the result.
        const release = array.release orelse break;
        defer release(&array);
        arrays += 1;
        rows += array.length;
        const ids: [*]const i64 = @ptrCast(@alignCast(array.children.?[0].?.buffers.?[1].?));
        for (0..@intCast(array.length)) |i| id_sum += ids[@as(usize, @intCast(array.offset)) + i];
        nulls += array.children.?[2].?.null_count;
    }
    try expectInt("arrays of at most 1000 rows", 3, arrays);
    try expectInt("rows", 2500, @intCast(rows));
    try expectInt("sum of ids, read from the Arrow buffers", 3123750, @intCast(id_sum));
    try expectInt("NULLs in the DOUBLE column", 500, @intCast(nulls));
}

/// Parameters: bound as constants for one execution, positional ($1) or by name ($x), in a statement run directly
/// or prepared once and run many times.
fn parameters(arena: std.mem.Allocator, s: *Session) !void {
    var c: Call = .{};
    const sql = try arena.dupeSentinel(u8, "SELECT $1::INTEGER + $2::INTEGER AS total", 0);
    var iterator: v2.duckdb_v2_statement_iterator_handle = undefined;
    try c.ok(v2.duckdb_v2_parse_sql(s.conn, sql.ptr, &iterator, c.err()));
    defer _ = v2.duckdb_v2_statement_iterator_destroy(&iterator);
    var statement: ?v2.duckdb_v2_sql_statement_handle = null;
    try c.ok(v2.duckdb_v2_statement_iterator_next(iterator, @ptrCast(&statement), c.err()));
    var stmt = statement.?;
    defer _ = v2.duckdb_v2_sql_statement_destroy(&stmt);

    var count: u64 = 0;
    try c.ok(v2.duckdb_v2_sql_statement_get_parameter_count(stmt, &count, c.err()));
    try expectInt("parameter count", 2, count);

    // Prepared once (binding and planning happen here), executed with different values.
    var prepared: v2.duckdb_v2_prepared_statement_handle = undefined;
    try c.ok(v2.duckdb_v2_prepared_statement_create(s.conn, stmt, false, &prepared, c.err()));
    defer _ = v2.duckdb_v2_prepared_statement_destroy(&prepared);
    var reuses = false;
    try c.ok(v2.duckdb_v2_prepared_statement_reuses_plan(prepared, &reuses, c.err()));
    try expectInt("both parameter types are cast to INTEGER, so the plan is reused", 1, @intFromBool(reuses));

    inline for (.{ .{ 1, 2, "3" }, .{ 40, 2, "42" }, .{ -5, 5, "0" } }) |args| {
        var values: [2]v2.duckdb_v2_value_handle = undefined;
        try c.ok(v2.duckdb_v2_value_create_int_with_connection(s.conn, args[0], &values[0], c.err()));
        defer _ = v2.duckdb_v2_value_destroy(&values[0]);
        try c.ok(v2.duckdb_v2_value_create_int_with_connection(s.conn, args[1], &values[1], c.err()));
        defer _ = v2.duckdb_v2_value_destroy(&values[1]);
        var result: v2.duckdb_v2_result_handle = undefined;
        try c.ok(v2.duckdb_v2_prepared_statement_execute(prepared, null, &values, values.len, &result, c.err()));
        try expectEqual("positional parameters", args[2], try (try collect(arena, s, &result)).flat(arena));
    }

    // The parameters are named for binding: "1" and "2" for $1 and $2, the identifier for $name.
    var name: v2.duckdb_v2_identifier_t = undefined;
    try c.ok(v2.duckdb_v2_sql_statement_get_parameter_name(stmt, 1, &name, c.err()));
    try expectEqual("a positional parameter's name", "2", view(name));

    var values: [2]v2.duckdb_v2_value_handle = undefined;
    try c.ok(v2.duckdb_v2_value_create_int_with_connection(s.conn, 7, &values[0], c.err()));
    defer _ = v2.duckdb_v2_value_destroy(&values[0]);
    try c.ok(v2.duckdb_v2_value_create_int_with_connection(s.conn, 8, &values[1], c.err()));
    defer _ = v2.duckdb_v2_value_destroy(&values[1]);
    // By name, in the opposite order: the names decide, not the positions.
    const swapped = [_]v2.duckdb_v2_identifier_t{ helpers.str("2"), helpers.str("1") };
    var by_name: v2.duckdb_v2_result_handle = undefined;
    try c.ok(v2.duckdb_v2_prepared_statement_execute(prepared, &swapped, &values, values.len, &by_name, c.err()));
    try expectEqual("values bound by name", "15", try (try collect(arena, s, &by_name)).flat(arena));

    // Names that do not belong to the statement are refused, and the prepared statement stays usable.
    const wrong = [_]v2.duckdb_v2_identifier_t{ helpers.str("x"), helpers.str("y") };
    var result: v2.duckdb_v2_result_handle = undefined;
    try expectFailure("unknown parameter names", blk: {
        var c2: Call = .{};
        break :blk c2.ok(v2.duckdb_v2_prepared_statement_execute(prepared, &wrong, &values, values.len, &result, c2.err()));
    }, .ERROR_INPUT_INVALID, "");

    // A statement with named parameters, run directly. `statement_bind` reports its signature without running it:
    // the output columns and the parameters' types.
    const named_sql = try arena.dupeSentinel(u8, "SELECT $x::INTEGER * $y::INTEGER AS product", 0);
    var named_iterator: v2.duckdb_v2_statement_iterator_handle = undefined;
    try c.ok(v2.duckdb_v2_parse_sql(s.conn, named_sql.ptr, &named_iterator, c.err()));
    defer _ = v2.duckdb_v2_statement_iterator_destroy(&named_iterator);
    var named_opt: ?v2.duckdb_v2_sql_statement_handle = null;
    try c.ok(v2.duckdb_v2_statement_iterator_next(named_iterator, @ptrCast(&named_opt), c.err()));
    var named = named_opt.?;
    defer _ = v2.duckdb_v2_sql_statement_destroy(&named);
    var kind: v2.DUCKDB_V2_STATEMENT_TYPE = undefined;
    try c.ok(v2.duckdb_v2_sql_statement_get_type(named, &kind, c.err()));
    try expectEqual("statement type", "STATEMENT_TYPE_SELECT", @tagName(kind));

    var outputs: v2.duckdb_v2_schema_handle = undefined;
    var inputs: v2.duckdb_v2_schema_handle = undefined;
    try c.ok(v2.duckdb_v2_statement_bind(s.conn, named, &outputs, &inputs, c.err()));
    defer _ = v2.duckdb_v2_schema_destroy(&outputs);
    defer _ = v2.duckdb_v2_schema_destroy(&inputs);
    var n_out: u64 = 0;
    var n_in: u64 = 0;
    try c.ok(v2.duckdb_v2_schema_get_count(outputs, &n_out, c.err()));
    try c.ok(v2.duckdb_v2_schema_get_count(inputs, &n_in, c.err()));
    try expectInt("output columns", 1, n_out);
    try expectInt("parameters", 2, n_in);

    var x: v2.duckdb_v2_value_handle = undefined;
    var y: v2.duckdb_v2_value_handle = undefined;
    try c.ok(v2.duckdb_v2_value_create_int_with_connection(s.conn, 6, &x, c.err()));
    defer _ = v2.duckdb_v2_value_destroy(&x);
    try c.ok(v2.duckdb_v2_value_create_int_with_connection(s.conn, 7, &y, c.err()));
    defer _ = v2.duckdb_v2_value_destroy(&y);
    const named_values = [_]v2.duckdb_v2_value_handle{ x, y };
    const named_keys = [_]v2.duckdb_v2_identifier_t{ helpers.str("x"), helpers.str("y") };
    var product: v2.duckdb_v2_result_handle = undefined;
    try c.ok(v2.duckdb_v2_statement_execute(s.conn, named, &named_keys, &named_values, named_values.len, &product, c.err()));
    try expectEqual("named parameters", "42", try (try collect(arena, s, &product)).flat(arena));
}

/// Two kinds of failure: at prepare time (the binder), and while the result is read.
fn errors(arena: std.mem.Allocator, s: *Session) !void {
    // A table that does not exist is found while the statement is prepared, before anything runs.
    try expectFailure("binder error", runAll(arena, s, "SELECT nope FROM t"), .ERROR_QUERY_BINDER, "nope");
    // A cast that fails does so on the way through the rows.
    try expectFailure("runtime error", runAll(arena, s, "SELECT CAST(s AS INTEGER) FROM t"), .ERROR_TYPE_CONVERSION, "Could not convert");
    // A syntax error is found by the parser, which touches nothing else.
    try expectFailure("parse error", runAll(arena, s, "SELEKT 1"), .ERROR_QUERY_PARSER, "SELEKT");
    // And the connection is fine afterwards.
    try expectEqual("still usable", "1", try query(arena, s, "SELECT 1"));
}

/// Results are lazy: nothing runs until it is read, and a connection holds one live result at a time.
fn lazyExecution(arena: std.mem.Allocator, s: *Session) !void {
    var c: Call = .{};
    const sql = try arena.dupeSentinel(u8, "INSERT INTO t VALUES (-1, 'lazy')", 0);
    var iterator: v2.duckdb_v2_statement_iterator_handle = undefined;
    try c.ok(v2.duckdb_v2_parse_sql(s.conn, sql.ptr, &iterator, c.err()));
    defer _ = v2.duckdb_v2_statement_iterator_destroy(&iterator);
    var statement: ?v2.duckdb_v2_sql_statement_handle = null;
    try c.ok(v2.duckdb_v2_statement_iterator_next(iterator, @ptrCast(&statement), c.err()));
    var stmt = statement.?;
    defer _ = v2.duckdb_v2_sql_statement_destroy(&stmt);

    // Executed, then destroyed without being drained: the INSERT never happened.
    var abandoned: v2.duckdb_v2_result_handle = undefined;
    try c.ok(v2.duckdb_v2_statement_execute(s.conn, stmt, null, null, 0, &abandoned, c.err()));
    _ = v2.duckdb_v2_result_destroy(&abandoned);
    try expectEqual("an abandoned INSERT did nothing", "5000", try query(arena, s, "SELECT count(*) FROM t"));

    // While a result is live, the connection takes no new statement; another connection does.
    var live: v2.duckdb_v2_result_handle = undefined;
    try c.ok(v2.duckdb_v2_statement_execute(s.conn, stmt, null, null, 0, &live, c.err()));
    var second: v2.duckdb_v2_result_handle = undefined;
    try expectFailure("one live result per connection", blk: {
        var c2: Call = .{};
        break :blk c2.ok(v2.duckdb_v2_statement_execute(s.conn, stmt, null, null, 0, &second, c2.err()));
    }, .ERROR_RESOURCE_IN_USE, "");

    // Drained, it takes effect (the first execution is still the live one).
    var changed: u64 = 0;
    try c.ok(v2.duckdb_v2_result_drain(live, &changed, c.err()));
    _ = v2.duckdb_v2_result_destroy(&live);
    try expectInt("the drained INSERT changed a row", 1, changed);

    // A second connection sees the committed row: same instance, same catalog, its own session.
    var other = try s.connect();
    defer _ = v2.duckdb_v2_connection_destroy(&other);
    var other_session = s.*;
    other_session.conn = other;
    try expectEqual("another connection sees it", "5001", try query(arena, &other_session, "SELECT count(*) FROM t"));
}
