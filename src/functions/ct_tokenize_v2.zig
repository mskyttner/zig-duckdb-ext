///! Comptime table function: ct_tokenize(input VARCHAR, delim VARCHAR) -> (token_pos BIGINT, token VARCHAR)
///!
///! v2 port of ct_tokenize.zig. Unlike the v1 comptime table framework
///! (which, like this file's own prior version, only wires up hand-written
///! bind/init_global/exec callbacks), `comptime_table_v2.Function` fully
///! generates them from this `State`'s `Row`/`init`/`next` shape — the
///! generalization `comptime_table_v2.zig`'s module doc comment describes,
///! proved here against the same custom, stateful tokenizing logic
///! `tokenize_v2.zig` hand-writes, not just a toy example.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const comptime_table_v2 = @import("comptime_table_v2");

const State = struct {
    input: []const u8,
    delim: []const u8,
    pos: usize,
    ordinal: i64,
    done: bool,

    pub const Row = struct { token_pos: i64, token: []const u8 };

    pub fn init(input: []const u8, delim: []const u8) @This() {
        return .{ .input = input, .delim = delim, .pos = 0, .ordinal = 0, .done = false };
    }

    pub fn next(self: *@This()) ?Row {
        if (self.done) return null;

        const remaining = self.input[self.pos..];
        if (self.delim.len == 0) {
            self.done = true;
            const row: Row = .{ .token_pos = self.ordinal, .token = remaining };
            self.ordinal += 1;
            return row;
        }
        if (std.mem.indexOf(u8, remaining, self.delim)) |delim_pos| {
            const row: Row = .{ .token_pos = self.ordinal, .token = remaining[0..delim_pos] };
            self.ordinal += 1;
            self.pos += delim_pos + self.delim.len;
            return row;
        }
        self.done = true;
        const row: Row = .{ .token_pos = self.ordinal, .token = remaining };
        self.ordinal += 1;
        return row;
    }

    pub fn deinit(self: *@This()) void {
        std.heap.c_allocator.free(self.input);
        std.heap.c_allocator.free(self.delim);
    }
};

const CtTokenize = comptime_table_v2.Function("ct_tokenize", State);

pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    return CtTokenize.register(input);
}
