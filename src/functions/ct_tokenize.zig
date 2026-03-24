///! Comptime table function: ct_tokenize(input VARCHAR, delim VARCHAR) -> (token_pos BIGINT, token VARCHAR)
///!
///! Equivalent to zig_tokenize, but registration is handled by the comptime table
///! framework. The bind, init, and exec callbacks are the same functions used by
///! the hand-written version — only the registration boilerplate is replaced.
const db = @import("../lib/duckdb.zig");
const comptime_table = @import("../lib/comptime_table.zig");
const tokenize = @import("tokenize.zig");

/// Comptime-generated table function type.
const CtTokenize = comptime_table.Function(struct {
    pub const name: [:0]const u8 = "ct_tokenize";
    pub const param_types = [_]db.c.DUCKDB_TYPE{ db.c.DUCKDB_TYPE_VARCHAR, db.c.DUCKDB_TYPE_VARCHAR };
    pub const bind = &tokenize.tokenizeBind;
    pub const init = &tokenize.tokenizeInit;
    pub const exec = &tokenize.tokenizeExec;
});

/// Register the ct_tokenize table function with DuckDB.
pub fn register(connection: db.Connection) !void {
    return CtTokenize.register(connection);
}
