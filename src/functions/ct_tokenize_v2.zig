///! Comptime table function: ct_tokenize(input VARCHAR, delim VARCHAR) -> (token_pos BIGINT, token VARCHAR)
///!
///! v2 port of ct_tokenize.zig — same bind/init_global/exec callbacks as
///! zig_tokenize, registered via comptime_table_v2 instead of by hand.
const db = @import("duckdb_v2");
const comptime_table_v2 = @import("comptime_table_v2");
const tokenize = @import("tokenize_v2.zig");

const CtTokenize = comptime_table_v2.Function(struct {
    pub const name: [:0]const u8 = "ct_tokenize";
    pub const param_types = [_]db.LogicalTypeId{ db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR, db.c.DUCKDB_V2_LOGICAL_TYPE_ID_VARCHAR };
    pub const bind = tokenize.bindForCt;
    pub const initGlobal = tokenize.initGlobalForCt;
    pub const exec = tokenize.execForCt;
});

pub fn register(input: *const db.ExtensionInput) !void {
    return CtTokenize.register(input);
}
