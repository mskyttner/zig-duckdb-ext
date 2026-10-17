const std = @import("std");

pub const Error = error{EndOfBuffer};

pub fn readU8(data: []const u8, at: usize) Error!u8 {
    if (at >= data.len) return error.EndOfBuffer;
    return data[at];
}

pub fn readU16(data: []const u8, at: usize) Error!u16 {
    if (at + 2 > data.len) return error.EndOfBuffer;
    return std.mem.readInt(u16, data[at..][0..2], .little);
}

pub fn readU32(data: []const u8, at: usize) Error!u32 {
    if (at + 4 > data.len) return error.EndOfBuffer;
    return std.mem.readInt(u32, data[at..][0..4], .little);
}

pub fn readI32(data: []const u8, at: usize) Error!i32 {
    return @bitCast(try readU32(data, at));
}

pub fn readU64(data: []const u8, at: usize) Error!u64 {
    if (at + 8 > data.len) return error.EndOfBuffer;
    return std.mem.readInt(u64, data[at..][0..8], .little);
}

pub fn readI64(data: []const u8, at: usize) Error!i64 {
    return @bitCast(try readU64(data, at));
}

pub fn writeU16At(data: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, data[at..][0..2], v, .little);
}

pub fn writeU32At(data: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, data[at..][0..4], v, .little);
}

pub fn writeU64At(data: []u8, at: usize, v: u64) void {
    std.mem.writeInt(u64, data[at..][0..8], v, .little);
}

pub fn appendU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

pub fn appendI64(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: i64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, @bitCast(v), .little);
    try list.appendSlice(gpa, &b);
}

pub fn appendInt(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: i64, width: usize) !void {
    var b: [8]u8 = undefined;
    const u: u64 = @bitCast(v);
    var i: usize = 0;
    while (i < width) : (i += 1) b[i] = @truncate(u >> @intCast(i * 8));
    try list.appendSlice(gpa, b[0..width]);
}

pub fn readInt(data: []const u8, at: usize, width: usize, signed: bool) Error!i64 {
    if (at + width > data.len) return error.EndOfBuffer;
    var u: u64 = 0;
    var i: usize = 0;
    while (i < width) : (i += 1) u |= @as(u64, data[at + i]) << @intCast(i * 8);
    if (!signed) {
        if (width == 8) return @bitCast(u);
        return @intCast(u);
    }
    const shift: u6 = @intCast((8 - width) * 8);
    if (width == 8) return @bitCast(u);
    const signed_wide: i64 = @as(i64, @bitCast(u << shift)) >> shift;
    return signed_wide;
}
