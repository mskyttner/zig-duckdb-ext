const std = @import("std");
const le = @import("le.zig");
const model = @import("model.zig");

pub const Error = model.Error;

pub const Builder = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    cursor: usize,
    nfields: usize,
    high: usize,
    align_need: usize,
    field_at: [32]isize,

    pub fn init(gpa: std.mem.Allocator) Error!Builder {
        const data = gpa.alloc(u8, 4096) catch return error.OutOfMemory;
        @memset(data, 0);
        return .{
            .gpa = gpa,
            .data = data,
            .cursor = data.len,
            .nfields = 0,
            .high = data.len,
            .align_need = 4,
            .field_at = @as([32]isize, @splat(-1)),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.gpa.free(self.data);
    }

    fn tok(self: *const Builder, abs_pos: usize) usize {
        return self.data.len - abs_pos;
    }

    fn absOf(self: *const Builder, token: usize) usize {
        return self.data.len - token;
    }

    fn grow(self: *Builder, need: usize) Error!void {
        if (self.cursor >= need) return;
        var bigger_n = self.data.len * 2;
        if (bigger_n < self.data.len + need + 64) bigger_n = self.data.len + need + 64;
        while (bigger_n - (self.data.len - self.cursor) < need + 64) bigger_n *= 2;
        const bigger = self.gpa.alloc(u8, bigger_n) catch return error.OutOfMemory;
        @memset(bigger, 0);
        const used = self.data.len - self.cursor;
        const shift = bigger_n - self.data.len;
        @memcpy(bigger[self.cursor + shift ..][0..used], self.data[self.cursor..][0..used]);
        self.gpa.free(self.data);
        self.data = bigger;
        self.cursor += shift;
        self.high += shift;
        for (&self.field_at) |*at| {
            if (at.* >= 0) at.* += @intCast(shift);
        }
    }

    fn place(self: *Builder, size: usize, align_to: usize) Error!void {
        try self.grow(size + align_to);
        const start = self.cursor - size;
        const mis = start % align_to;
        if (mis != 0) self.cursor -= mis;
        self.cursor -= size;
    }

    pub fn startTable(self: *Builder, nfields: usize) void {
        self.nfields = nfields;
        var i: usize = 0;
        while (i < nfields) : (i += 1) self.field_at[i] = -1;
        self.high = self.cursor;
        self.align_need = 4;
    }

    fn note(self: *Builder, id: usize, align_to: usize) void {
        self.field_at[id] = @intCast(self.cursor);
        if (align_to > self.align_need) self.align_need = align_to;
    }

    pub fn addBool(self: *Builder, id: usize, v: bool, default: bool) Error!void {
        if (v == default) return;
        try self.place(1, 1);
        self.data[self.cursor] = if (v) 1 else 0;
        self.note(id, 1);
    }

    pub fn addU8(self: *Builder, id: usize, v: u8, default: u8) Error!void {
        if (v == default) return;
        try self.place(1, 1);
        self.data[self.cursor] = v;
        self.note(id, 1);
    }

    pub fn addU16(self: *Builder, id: usize, v: u16, default: u16) Error!void {
        if (v == default) return;
        try self.place(2, 2);
        le.writeU16At(self.data, self.cursor, v);
        self.note(id, 2);
    }

    pub fn addI32(self: *Builder, id: usize, v: i32, default: i32) Error!void {
        if (v == default) return;
        try self.place(4, 4);
        le.writeU32At(self.data, self.cursor, @bitCast(v));
        self.note(id, 4);
    }

    pub fn addI64(self: *Builder, id: usize, v: i64, default: i64) Error!void {
        if (v == default) return;
        try self.place(8, 8);
        le.writeU64At(self.data, self.cursor, @bitCast(v));
        self.note(id, 8);
    }

    pub fn addI64Pair(self: *Builder, id: usize, first: i64, second: i64) Error!void {
        try self.place(16, 8);
        le.writeU64At(self.data, self.cursor, @bitCast(first));
        le.writeU64At(self.data, self.cursor + 8, @bitCast(second));
        self.note(id, 8);
    }

    pub fn addOffset(self: *Builder, id: usize, token: usize) Error!void {
        try self.place(4, 4);
        const target = self.absOf(token);
        le.writeU32At(self.data, self.cursor, @intCast(target - self.cursor));
        self.note(id, 4);
    }

    pub fn endTable(self: *Builder) Error!usize {
        try self.place(4, self.align_need);
        const table_tok = self.tok(self.cursor);
        le.writeU32At(self.data, self.cursor, 0);
        const vtsize: usize = 4 + 2 * self.nfields;
        try self.place(vtsize, 2);
        const table = self.absOf(table_tok);
        const obj: u16 = @intCast(self.high - table);
        le.writeU16At(self.data, self.cursor, @intCast(vtsize));
        le.writeU16At(self.data, self.cursor + 2, obj);
        var i: usize = 0;
        while (i < self.nfields) : (i += 1) {
            var rel: u16 = 0;
            if (self.field_at[i] >= 0) {
                const fpos: usize = @intCast(self.field_at[i]);
                rel = @intCast(fpos - table);
            }
            le.writeU16At(self.data, self.cursor + 4 + i * 2, rel);
        }
        le.writeU32At(self.data, table, @intCast(table - self.cursor));
        return table_tok;
    }

    pub fn writeBytes(self: *Builder, raw: []const u8, null_term: bool) Error!usize {
        const extra: usize = if (null_term) 1 else 0;
        const total = raw.len + extra;
        try self.grow(total + 8);
        const mis = (self.cursor - total) % 4;
        if (mis != 0) self.cursor -= mis;
        const start = self.cursor - total;
        if (raw.len > 0) @memcpy(self.data[start..][0..raw.len], raw);
        if (null_term) self.data[start + raw.len] = 0;
        self.cursor = start;
        try self.place(4, 4);
        le.writeU32At(self.data, self.cursor, @intCast(raw.len));
        return self.tok(self.cursor);
    }

    pub fn writeString(self: *Builder, text: []const u8) Error!usize {
        return self.writeBytes(text, true);
    }

    pub fn writeI32Vec(self: *Builder, vals: []const i32) Error!usize {
        var i: isize = @as(isize, @intCast(vals.len)) - 1;
        while (i >= 0) : (i -= 1) {
            try self.place(4, 4);
            le.writeU32At(self.data, self.cursor, @bitCast(vals[@intCast(i)]));
        }
        try self.place(4, 4);
        le.writeU32At(self.data, self.cursor, @intCast(vals.len));
        return self.tok(self.cursor);
    }

    pub fn writeU64Vec(self: *Builder, vals: []const u64) Error!usize {
        var i: isize = @as(isize, @intCast(vals.len)) - 1;
        while (i >= 0) : (i -= 1) {
            try self.place(8, 8);
            le.writeU64At(self.data, self.cursor, vals[@intCast(i)]);
        }
        try self.place(4, 4);
        le.writeU32At(self.data, self.cursor, @intCast(vals.len));
        return self.tok(self.cursor);
    }

    pub fn writeI64Vec(self: *Builder, vals: []const i64) Error!usize {
        var tmp: std.ArrayList(u64) = .empty;
        defer tmp.deinit(self.gpa);
        for (vals) |v| try tmp.append(self.gpa, @bitCast(v));
        return self.writeU64Vec(tmp.items);
    }

    pub fn writeOffsetVec(self: *Builder, targets: []const usize) Error!usize {
        var i: isize = @as(isize, @intCast(targets.len)) - 1;
        while (i >= 0) : (i -= 1) {
            try self.place(4, 4);
            const target = self.absOf(targets[@intCast(i)]);
            le.writeU32At(self.data, self.cursor, @intCast(target - self.cursor));
        }
        try self.place(4, 4);
        le.writeU32At(self.data, self.cursor, @intCast(targets.len));
        return self.tok(self.cursor);
    }

    pub fn writeI64Pairs(self: *Builder, first: []const i64, second: []const i64) Error!usize {
        const n = first.len;
        const nbytes = n * 16;
        try self.grow(nbytes + 16);
        const mis = if (nbytes == 0) 0 else (self.cursor - nbytes) % 8;
        if (mis != 0) self.cursor -= mis;
        var i: isize = @as(isize, @intCast(n)) - 1;
        while (i >= 0) : (i -= 1) {
            self.cursor -= 16;
            le.writeU64At(self.data, self.cursor, @bitCast(first[@intCast(i)]));
            le.writeU64At(self.data, self.cursor + 8, @bitCast(second[@intCast(i)]));
        }
        try self.place(4, 4);
        le.writeU32At(self.data, self.cursor, @intCast(n));
        return self.tok(self.cursor);
    }

    pub fn writeStructVec(self: *Builder, raw: []const u8, elem: usize) Error!usize {
        const n: usize = if (elem == 0) 0 else raw.len / elem;
        const align_to: usize = if (elem >= 8) 8 else 4;
        try self.grow(raw.len + align_to + 8);
        const mis = if (raw.len == 0) 0 else (self.cursor - raw.len) % align_to;
        if (mis != 0) self.cursor -= mis;
        self.cursor -= raw.len;
        if (raw.len > 0) @memcpy(self.data[self.cursor..][0..raw.len], raw);
        try self.place(4, 4);
        le.writeU32At(self.data, self.cursor, @intCast(n));
        return self.tok(self.cursor);
    }

    pub fn finish(self: *Builder, gpa: std.mem.Allocator, token: usize) Error![]u8 {
        try self.place(4, 8);
        const root = self.absOf(token);
        le.writeU32At(self.data, self.cursor, @intCast(root - self.cursor));
        const n = self.data.len - self.cursor;
        const out = gpa.alloc(u8, n) catch return error.OutOfMemory;
        @memcpy(out, self.data[self.cursor..][0..n]);
        return out;
    }
};

pub const Reader = struct {
    data: []const u8,

    pub fn root(self: Reader) Error!usize {
        const rel = le.readU32(self.data, 0) catch return error.EndOfBuffer;
        if (rel > self.data.len) return error.Syntax;
        return rel;
    }

    pub fn field(self: Reader, table: usize, id: usize) Error!?usize {
        const soff = le.readI32(self.data, table) catch return error.Syntax;
        const vt_i = @as(isize, @intCast(table)) - @as(isize, soff);
        if (vt_i < 0) return error.Syntax;
        const vt: usize = @intCast(vt_i);
        if (vt + 2 > self.data.len) return error.Syntax;
        const vtsize = le.readU16(self.data, vt) catch return error.Syntax;
        if (vtsize < 4 or vt + vtsize > self.data.len) return error.Syntax;
        if (4 + id * 2 + 2 > vtsize) return null;
        const rel = le.readU16(self.data, vt + 4 + id * 2) catch return error.Syntax;
        if (rel == 0) return null;
        const pos = table + @as(usize, rel);
        if (pos >= self.data.len) return error.Syntax;
        return pos;
    }

    pub fn follow(self: Reader, pos: usize) Error!usize {
        const rel = le.readU32(self.data, pos) catch return error.Syntax;
        const at = std.math.add(usize, pos, rel) catch return error.Syntax;
        if (at > self.data.len) return error.Syntax;
        return at;
    }

    pub fn vecLen(self: Reader, pos: usize) Error!usize {
        const at = try self.follow(pos);
        return le.readU32(self.data, at) catch return error.Syntax;
    }

    pub fn vecData(self: Reader, pos: usize) Error!usize {
        return (try self.follow(pos)) + 4;
    }

    pub fn string(self: Reader, pos: usize) Error![]const u8 {
        const at = try self.follow(pos);
        const n = le.readU32(self.data, at) catch return error.Syntax;
        const end = std.math.add(usize, at + 4, n) catch return error.Syntax;
        if (end > self.data.len) return error.Syntax;
        return self.data[at + 4 ..][0..n];
    }

    pub fn u8At(self: Reader, pos: usize) Error!u8 {
        return le.readU8(self.data, pos) catch return error.EndOfBuffer;
    }

    pub fn u16At(self: Reader, pos: usize) Error!u16 {
        return le.readU16(self.data, pos) catch return error.EndOfBuffer;
    }

    pub fn i32At(self: Reader, pos: usize) Error!i32 {
        return le.readI32(self.data, pos) catch return error.EndOfBuffer;
    }

    pub fn u32At(self: Reader, pos: usize) Error!u32 {
        return le.readU32(self.data, pos) catch return error.EndOfBuffer;
    }

    pub fn i64At(self: Reader, pos: usize) Error!i64 {
        return le.readI64(self.data, pos) catch return error.EndOfBuffer;
    }
};

test "flatbuffer string roundtrip" {
    const gpa = std.testing.allocator;
    var b = try Builder.init(gpa);
    defer b.deinit();
    const s = try b.writeString("hi");
    b.startTable(1);
    try b.addOffset(0, s);
    const table = try b.endTable();
    const raw = try b.finish(gpa, table);
    defer gpa.free(raw);
    const r = Reader{ .data = raw };
    const root_at = try r.root();
    const fp = (try r.field(root_at, 0)).?;
    try std.testing.expectEqualStrings("hi", try r.string(fp));
}
