const std = @import("std");
const model = @import("model.zig");

const Error = model.Error;

const PField = struct {
    num: usize,
    wire: u8,
    start: usize,
    size: usize,
    u: u64,
};

fn putVarint(b: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u64) !void {
    var x = v;
    while (true) {
        const byte: u8 = @truncate(x & 0x7f);
        x >>= 7;
        if (x != 0) {
            try b.append(gpa, byte | 0x80);
        } else {
            try b.append(gpa, byte);
            break;
        }
    }
}

fn putKey(b: *std.ArrayList(u8), gpa: std.mem.Allocator, field: usize, wire: u8) !void {
    try putVarint(b, gpa, @intCast((field << 3) | wire));
}

fn putBytes(b: *std.ArrayList(u8), gpa: std.mem.Allocator, field: usize, raw: []const u8) !void {
    try putKey(b, gpa, field, 2);
    try putVarint(b, gpa, @intCast(raw.len));
    try b.appendSlice(gpa, raw);
}

fn readVarint(raw: []const u8, i: *usize, end: usize) Error!u64 {
    var shift: u6 = 0;
    var out: u64 = 0;
    var guard: usize = 0;
    while (i.* < end and guard < 10) : (guard += 1) {
        const b = raw[i.*];
        i.* += 1;
        out |= @as(u64, b & 0x7f) << shift;
        if ((b & 0x80) == 0) return out;
        if (shift > 56) return error.Flight;
        shift += 7;
    }
    return error.Flight;
}

const ParseBuf = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(PField) = .empty,

    fn deinit(self: *ParseBuf) void {
        self.list.deinit(self.gpa);
    }
};

fn parseFields(gpa: std.mem.Allocator, raw: []const u8) Error!ParseBuf {
    var out = ParseBuf{ .gpa = gpa };
    errdefer out.deinit();
    var i: usize = 0;
    while (i < raw.len) {
        const tag = try readVarint(raw, &i, raw.len);
        const field = tag >> 3;
        const wire: u8 = @truncate(tag & 7);
        if (field == 0) return error.Flight;
        if (wire == 0) {
            const u = try readVarint(raw, &i, raw.len);
            try out.list.append(gpa, .{ .num = @intCast(field), .wire = 0, .start = i, .size = 0, .u = u });
        } else if (wire == 1) {
            if (i + 8 > raw.len) return error.Flight;
            const u = std.mem.readInt(u64, raw[i..][0..8], .little);
            try out.list.append(gpa, .{ .num = @intCast(field), .wire = 1, .start = i, .size = 8, .u = u });
            i += 8;
        } else if (wire == 2) {
            const ln = try readVarint(raw, &i, raw.len);
            if (i + ln > raw.len) return error.Flight;
            try out.list.append(gpa, .{
                .num = @intCast(field),
                .wire = 2,
                .start = i,
                .size = @intCast(ln),
                .u = ln,
            });
            i += @intCast(ln);
        } else if (wire == 5) {
            if (i + 4 > raw.len) return error.Flight;
            i += 4;
        } else return error.Flight;
    }
    return out;
}

fn findVarint(fields: []const PField, num: usize, default: u64) u64 {
    for (fields) |f| if (f.num == num and f.wire == 0) return f.u;
    return default;
}

fn findBytes(raw: []const u8, fields: []const PField, num: usize) []const u8 {
    for (fields) |f| if (f.num == num and f.wire == 2) return raw[f.start..][0..f.size];
    return &.{};
}

pub fn encodeHandshake(gpa: std.mem.Allocator, version: u64, payload: []const u8) Error![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try putKey(&b, gpa, 1, 0);
    try putVarint(&b, gpa, version);
    try putBytes(&b, gpa, 2, payload);
    return b.toOwnedSlice(gpa);
}

pub const Handshake = struct {
    version: u64,
    payload: []u8,

    pub fn deinit(self: *Handshake, gpa: std.mem.Allocator) void {
        gpa.free(self.payload);
    }
};

pub fn decodeHandshake(gpa: std.mem.Allocator, raw: []const u8) Error!Handshake {
    var fields = try parseFields(gpa, raw);
    defer fields.deinit();
    const payload = findBytes(raw, fields.list.items, 2);
    return .{
        .version = findVarint(fields.list.items, 1, 0),
        .payload = gpa.dupe(u8, payload) catch return error.OutOfMemory,
    };
}

pub const FlightData = struct {
    header: []const u8 = &.{},
    body: []const u8 = &.{},
    meta: []const u8 = &.{},
};

pub fn encodeFlightData(gpa: std.mem.Allocator, data: FlightData) Error![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    if (data.header.len > 0) try putBytes(&b, gpa, 2, data.header);
    if (data.meta.len > 0) try putBytes(&b, gpa, 3, data.meta);
    try putBytes(&b, gpa, 1000, data.body);
    return b.toOwnedSlice(gpa);
}

pub fn decodeFlightData(gpa: std.mem.Allocator, raw: []const u8) Error!struct { header: []u8, body: []u8, meta: []u8 } {
    var fields = try parseFields(gpa, raw);
    defer fields.deinit();
    return .{
        .header = gpa.dupe(u8, findBytes(raw, fields.list.items, 2)) catch return error.OutOfMemory,
        .meta = gpa.dupe(u8, findBytes(raw, fields.list.items, 3)) catch return error.OutOfMemory,
        .body = gpa.dupe(u8, findBytes(raw, fields.list.items, 1000)) catch return error.OutOfMemory,
    };
}

pub fn encodeTicket(gpa: std.mem.Allocator, ticket: []const u8) Error![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try putBytes(&b, gpa, 1, ticket);
    return b.toOwnedSlice(gpa);
}

pub fn encodePutResult(gpa: std.mem.Allocator, meta: []const u8) Error![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try putBytes(&b, gpa, 1, meta);
    return b.toOwnedSlice(gpa);
}

pub fn encodeDescriptorCmd(gpa: std.mem.Allocator, cmd: []const u8) Error![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try putKey(&b, gpa, 1, 0);
    try putVarint(&b, gpa, 2);
    try putBytes(&b, gpa, 2, cmd);
    return b.toOwnedSlice(gpa);
}

const Stored = struct {
    ticket: []u8,
    frames: std.ArrayList(FlightOwned) = .empty,
};

pub const FlightOwned = struct {
    header: []u8,
    body: []u8,
    meta: []u8,

    pub fn deinit(self: *FlightOwned, gpa: std.mem.Allocator) void {
        gpa.free(self.header);
        gpa.free(self.body);
        gpa.free(self.meta);
    }
};

pub const Exchange = struct {
    gpa: std.mem.Allocator,
    sets: std.ArrayList(Stored) = .empty,

    pub fn init(gpa: std.mem.Allocator) Exchange {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Exchange) void {
        for (self.sets.items) |*s| {
            self.gpa.free(s.ticket);
            for (s.frames.items) |*f| f.deinit(self.gpa);
            s.frames.deinit(self.gpa);
        }
        self.sets.deinit(self.gpa);
    }

    pub fn handshake(gpa: std.mem.Allocator, version: u64, payload: []const u8) Error!Handshake {
        const raw = try encodeHandshake(gpa, version, payload);
        defer gpa.free(raw);
        return decodeHandshake(gpa, raw);
    }

    pub fn doPut(self: *Exchange, cmd: []const u8, frames: []const FlightData) Error![]u8 {
        const ticket = if (cmd.len > 0) self.gpa.dupe(u8, cmd) catch return error.OutOfMemory else try std.fmt.allocPrint(self.gpa, "t{d}", .{self.sets.items.len});
        errdefer self.gpa.free(ticket);
        var stored = Stored{ .ticket = ticket };
        errdefer {
            for (stored.frames.items) |*f| f.deinit(self.gpa);
            stored.frames.deinit(self.gpa);
        }
        for (frames) |frame| {
            try stored.frames.append(self.gpa, .{
                .header = self.gpa.dupe(u8, frame.header) catch return error.OutOfMemory,
                .body = self.gpa.dupe(u8, frame.body) catch return error.OutOfMemory,
                .meta = self.gpa.dupe(u8, frame.meta) catch return error.OutOfMemory,
            });
        }
        const result = try encodePutResult(self.gpa, ticket);
        try self.sets.append(self.gpa, stored);
        return result;
    }

    pub fn doGet(self: *Exchange, ticket: []const u8) Error![]FlightOwned {
        for (self.sets.items) |s| {
            if (!std.mem.eql(u8, s.ticket, ticket)) continue;
            const out = self.gpa.alloc(FlightOwned, s.frames.items.len) catch return error.OutOfMemory;
            var filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < filled) : (i += 1) out[i].deinit(self.gpa);
                self.gpa.free(out);
            }
            for (s.frames.items, 0..) |frame, i| {
                out[i] = .{
                    .header = self.gpa.dupe(u8, frame.header) catch return error.OutOfMemory,
                    .body = self.gpa.dupe(u8, frame.body) catch return error.OutOfMemory,
                    .meta = self.gpa.dupe(u8, frame.meta) catch return error.OutOfMemory,
                };
                filled += 1;
            }
            return out;
        }
        return error.Flight;
    }
};

pub fn putResultMeta(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    var fields = try parseFields(gpa, raw);
    defer fields.deinit();
    return gpa.dupe(u8, findBytes(raw, fields.list.items, 1)) catch error.OutOfMemory;
}

test "flight handshake do_put do_get" {
    const gpa = std.testing.allocator;
    var hs = try Exchange.handshake(gpa, 9, "ping");
    defer hs.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 9), hs.version);
    try std.testing.expectEqualStrings("ping", hs.payload);

    const encoded = try encodeFlightData(gpa, .{ .header = "sch", .body = "body", .meta = "m" });
    defer gpa.free(encoded);
    const decoded = try decodeFlightData(gpa, encoded);
    defer gpa.free(decoded.header);
    defer gpa.free(decoded.body);
    defer gpa.free(decoded.meta);
    try std.testing.expectEqualStrings("sch", decoded.header);
    try std.testing.expectEqualStrings("body", decoded.body);
    try std.testing.expectEqualStrings("m", decoded.meta);

    const desc = try encodeDescriptorCmd(gpa, "orders");
    defer gpa.free(desc);
    var fields = try parseFields(gpa, desc);
    defer fields.deinit();
    try std.testing.expectEqual(@as(u64, 2), findVarint(fields.list.items, 1, 0));

    var ex = Exchange.init(gpa);
    defer ex.deinit();
    const frames = [_]FlightData{
        .{ .header = "schema-ipc", .body = "batch-1" },
        .{ .header = "batch-meta", .body = "batch-2", .meta = "app" },
    };
    const put = try ex.doPut("orders", &frames);
    defer gpa.free(put);
    const ticket = try putResultMeta(gpa, put);
    defer gpa.free(ticket);
    try std.testing.expectEqualStrings("orders", ticket);
    const got = try ex.doGet(ticket);
    defer {
        for (got) |*f| {
            var frame = f.*;
            frame.deinit(gpa);
        }
        gpa.free(got);
    }
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("batch-1", got[0].body);
    try std.testing.expectEqualStrings("batch-2", got[1].body);
    try std.testing.expectEqualStrings("app", got[1].meta);
    try std.testing.expectError(error.Flight, ex.doGet("missing"));
}
