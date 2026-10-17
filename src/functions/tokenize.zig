///! Table function: zig_tokenize(input VARCHAR, delim VARCHAR) -> (token_pos BIGINT, token VARCHAR)
///!
///! Splits a string by a delimiter and returns one row per token. The token_pos
///! column is a 0-based ordinal indicating the position of the token in the
///! original string.
///!
///! This exercises the full DuckDB table function lifecycle:
///!   bind  — read parameters, define output columns, allocate bind data
///!   init  — allocate per-thread execution state
///!   exec  — fill output chunks, maintaining position across calls
///!
///! Behavior:
///!   zig_tokenize('a,b,c', ',')   -> [(0,'a'), (1,'b'), (2,'c')]
///!   zig_tokenize('a,,b', ',')    -> [(0,'a'), (1,''), (2,'b')]
///!   zig_tokenize('a,b,', ',')    -> [(0,'a'), (1,'b'), (2,'')]
///!   zig_tokenize('hello', ',')   -> [(0,'hello')]
///!   zig_tokenize('', ',')        -> [(0,'')]
const std = @import("std");
const db = @import("../lib/duckdb.zig");

// ─── Bind / Init data structures ─────────────────────────────────────────────
//
// Allocated with db.malloc (DuckDB's allocator) so the destroy callbacks
// can free them with db.free.

/// Bind data — holds the input string and delimiter for the lifetime of the query.
const BindData = struct {
    /// Owned by DuckDB allocator (from duckdb_get_varchar). Freed in destroy.
    input_raw: ?[*:0]u8,
    /// Owned by DuckDB allocator (from duckdb_get_varchar). Freed in destroy.
    delim_raw: ?[*:0]u8,
    /// Byte lengths of the two strings, measured once in bind: exec runs once per chunk, and measuring a long input
    /// there makes the scan quadratic in the input.
    input_len: usize,
    delim_len: usize,
};

/// Init data — per-thread execution state tracking position in the input.
const InitData = struct {
    /// Current byte offset into the input string.
    pos: usize,
    /// 0-based index of the next token to emit.
    ordinal: i64,
    /// True when all tokens have been emitted.
    done: bool,
};

// ─── Destroy callbacks ───────────────────────────────────────────────────────

fn destroyBindData(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        // SAFETY: p was allocated as *BindData via db.malloc in splitBind.
        const data: *BindData = @ptrCast(@alignCast(p));
        // SAFETY: input_raw/delim_raw are [*:0]u8 from duckdb_get_varchar; cast to ?*anyopaque for db.free.
        if (data.input_raw) |raw| db.free(@ptrCast(raw));
        if (data.delim_raw) |raw| db.free(@ptrCast(raw));
        db.free(p);
    }
}

fn destroyInitData(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| db.free(p);
}

// ─── Table function callbacks ────────────────────────────────────────────────

/// Bind callback — called once per query to read parameters and define output schema.
pub fn tokenizeBind(info: db.BindInfo) callconv(.c) void {
    // Define output columns
    var bigint_type = db.createLogicalType(db.c.DUCKDB_TYPE_BIGINT);
    defer db.destroyLogicalType(&bigint_type);
    var varchar_type = db.createLogicalType(db.c.DUCKDB_TYPE_VARCHAR);
    defer db.destroyLogicalType(&varchar_type);

    db.bindAddResultColumn(info, "token_pos", bigint_type);
    db.bindAddResultColumn(info, "token", varchar_type);

    // Read parameters
    var param_input = db.bindGetParameter(info, 0);
    defer db.destroyValue(&param_input);
    var param_delim = db.bindGetParameter(info, 1);
    defer db.destroyValue(&param_delim);

    // Allocate bind data
    const raw_ptr = db.malloc(@sizeOf(BindData)) orelse {
        db.bindSetError(info, "zig_tokenize: failed to allocate bind data");
        return;
    };
    // SAFETY: raw_ptr is freshly allocated with sufficient size and default alignment.
    const data: *BindData = @ptrCast(@alignCast(raw_ptr));
    const input_raw = db.getVarchar(param_input);
    const delim_raw = db.getVarchar(param_delim);
    data.* = .{
        .input_raw = input_raw,
        .delim_raw = delim_raw,
        .input_len = if (input_raw) |raw| std.mem.len(raw) else 0,
        .delim_len = if (delim_raw) |raw| std.mem.len(raw) else 0,
    };

    db.bindSetBindData(info, raw_ptr, &destroyBindData);
}

/// Init callback — called once per thread to set up execution state.
pub fn tokenizeInit(info: db.InitInfo) callconv(.c) void {
    const raw_ptr = db.malloc(@sizeOf(InitData)) orelse {
        db.initSetError(info, "zig_tokenize: failed to allocate init data");
        return;
    };
    // SAFETY: raw_ptr is freshly allocated with sufficient size and default alignment.
    const data: *InitData = @ptrCast(@alignCast(raw_ptr));
    data.* = .{ .pos = 0, .ordinal = 0, .done = false };

    db.initSetInitData(info, raw_ptr, &destroyInitData);
    db.initSetMaxThreads(info, 1); // single-threaded scan — input is a single string
}

/// Execute callback — called repeatedly to fill output chunks.
/// Emits up to VECTOR_SIZE rows per call. Sets chunk size to 0 when done.
pub fn tokenizeExec(info: db.FunctionInfo, output: db.DataChunk) callconv(.c) void {
    // SAFETY: bind/init data pointers were set in tokenizeBind/tokenizeInit.
    const bind_data: *BindData = @ptrCast(@alignCast(db.functionGetBindData(info) orelse {
        db.functionSetError(info, "zig_tokenize: missing bind data");
        return;
    }));
    const init_data: *InitData = @ptrCast(@alignCast(db.functionGetInitData(info) orelse {
        db.functionSetError(info, "zig_tokenize: missing init data");
        return;
    }));

    if (init_data.done) {
        db.dataChunkSetSize(output, 0);
        return;
    }

    const input: []const u8 = if (bind_data.input_raw) |raw| raw[0..bind_data.input_len] else "";
    const delim: []const u8 = if (bind_data.delim_raw) |raw| raw[0..bind_data.delim_len] else "";

    // SAFETY: DuckDB guarantees output vectors match the schema defined in bind.
    const pos_vec = db.dataChunkGetVector(output, 0);
    const tok_vec = db.dataChunkGetVector(output, 1);
    const pos_data: [*]i64 = @ptrCast(@alignCast(db.vectorGetData(pos_vec)));

    var row: db.idx_t = 0;
    const max_rows = db.vectorSize();

    while (row < max_rows and !init_data.done) {
        const remaining = input[init_data.pos..];

        if (delim.len == 0) {
            // Empty delimiter: emit the entire remaining input as one token.
            emitToken(pos_data, tok_vec, row, init_data.ordinal, remaining);
            row += 1;
            init_data.ordinal += 1;
            init_data.done = true;
        } else if (std.mem.indexOf(u8, remaining, delim)) |delim_pos| {
            // Found delimiter — emit the token before it.
            const token = remaining[0..delim_pos];
            emitToken(pos_data, tok_vec, row, init_data.ordinal, token);
            row += 1;
            init_data.ordinal += 1;
            init_data.pos += delim_pos + delim.len;
        } else {
            // No more delimiters — emit the final token.
            emitToken(pos_data, tok_vec, row, init_data.ordinal, remaining);
            row += 1;
            init_data.ordinal += 1;
            init_data.done = true;
        }
    }

    db.dataChunkSetSize(output, row);
}

/// Write a single token row to the output vectors.
fn emitToken(
    pos_data: [*]i64,
    tok_vec: db.Vector,
    row: db.idx_t,
    ordinal: i64,
    token: []const u8,
) void {
    pos_data[row] = ordinal;
    db.vectorAssignStringElementLen(tok_vec, row, token.ptr, token.len);
}

// ─── Registration ────────────────────────────────────────────────────────────

/// Register the zig_tokenize table function with DuckDB.
pub fn register(connection: db.Connection) !void {
    const function = db.createTableFunction();
    defer db.destroyTableFunction(@constCast(&function));

    db.tableFunctionSetName(function, "zig_tokenize");

    var varchar_type = db.createLogicalType(db.c.DUCKDB_TYPE_VARCHAR);
    defer db.destroyLogicalType(&varchar_type);

    db.tableFunctionAddParameter(function, varchar_type);
    db.tableFunctionAddParameter(function, varchar_type);

    db.tableFunctionSetBind(function, &tokenizeBind);
    db.tableFunctionSetInit(function, &tokenizeInit);
    db.tableFunctionSetFunction(function, &tokenizeExec);

    if (db.registerTableFunction(connection, function) == db.DuckDBError) {
        return error.FailedToRegisterFunction;
    }
}
