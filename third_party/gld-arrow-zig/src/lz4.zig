const std = @import("std");
const xxh = @import("xxh.zig");
const model = @import("model.zig");

const magic: u32 = 0x184D2204;
const block_max_default: usize = 65536;
const hash_log = 12;
const out_limit: usize = 67_108_864;

pub fn compress(gpa: std.mem.Allocator, raw: []const u8) model.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &[_]u8{ 0x04, 0x22, 0x4D, 0x18 });
    const flg: u8 = 0x60;
    const bd: u8 = 0x40;
    const hdr = [_]u8{ flg, bd };
    const sum = xxh.xxh32(&hdr);
    try out.append(gpa, flg);
    try out.append(gpa, bd);
    try out.append(gpa, @truncate(sum >> 8));
    if (raw.len == 0) {
        try writeStored(&out, gpa, raw, 0, 0);
    } else {
        var off: usize = 0;
        while (off < raw.len) {
            var take = raw.len - off;
            if (take > block_max_default) take = block_max_default;
            try writeBlock(&out, gpa, raw, off, take);
            off += take;
        }
    }
    try out.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    return out.toOwnedSlice(gpa);
}

pub fn decompress(gpa: std.mem.Allocator, raw: []const u8) model.Error![]u8 {
    if (raw.len < 7) return error.Compression;
    const mag = std.mem.readInt(u32, raw[0..4], .little);
    if (mag != magic) return error.Compression;
    const flg = raw[4];
    const bd = raw[5];
    if ((flg >> 6) != 1 or (flg & 0x02) != 0) return error.Compression;
    if ((bd & 0x8F) != 0) return error.Compression;
    const max_code: u8 = (bd >> 4) & 7;
    const block_max = try lz4BlockMax(max_code);
    const independent: u8 = (flg >> 5) & 1;
    const block_check: u8 = (flg >> 4) & 1;
    const size_flag: u8 = (flg >> 3) & 1;
    const content_check: u8 = (flg >> 2) & 1;
    const dict_flag: u8 = flg & 1;
    var hdr: std.ArrayList(u8) = .empty;
    defer hdr.deinit(gpa);
    try hdr.append(gpa, raw[4]);
    try hdr.append(gpa, raw[5]);
    var pos: usize = 6;
    var content_size: i64 = -1;
    if (size_flag != 0) {
        if (pos + 8 > raw.len) return error.Compression;
        const declared = std.mem.readInt(u64, raw[pos..][0..8], .little);
        if (declared > out_limit) return error.Compression;
        content_size = @intCast(declared);
        try hdr.appendSlice(gpa, raw[pos..][0..8]);
        pos += 8;
    }
    if (dict_flag != 0) {
        if (pos + 4 > raw.len) return error.Compression;
        try hdr.appendSlice(gpa, raw[pos..][0..4]);
        pos += 4;
    }
    if (pos >= raw.len) return error.Compression;
    const expect: u8 = @truncate(xxh.xxh32(hdr.items) >> 8);
    if (raw[pos] != expect) return error.Compression;
    pos += 1;
    if (dict_flag != 0) return error.Compression;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        if (pos + 4 > raw.len) return error.Compression;
        const size_word = std.mem.readInt(u32, raw[pos..][0..4], .little);
        pos += 4;
        if (size_word == 0) break;
        const stored = (size_word & 0x80000000) != 0;
        const size: usize = size_word & 0x7FFFFFFF;
        if (size > block_max or pos + size > raw.len) return error.Compression;
        const block = raw[pos..][0..size];
        pos += size;
        if (block_check != 0) {
            if (pos + 4 > raw.len) return error.Compression;
            const got = std.mem.readInt(u32, raw[pos..][0..4], .little);
            pos += 4;
            if (got != xxh.xxh32(block)) return error.Compression;
        }
        const block_at = out.items.len;
        if (stored) {
            try out.appendSlice(gpa, block);
        } else try lz4Block(block, &out, gpa, block_at, independent);
        if (out.items.len > out_limit) return error.Compression;
    }
    if (content_check != 0) {
        if (pos + 4 > raw.len) return error.Compression;
        const got = std.mem.readInt(u32, raw[pos..][0..4], .little);
        pos += 4;
        if (got != xxh.xxh32(out.items)) return error.Compression;
    }
    if (content_size >= 0 and content_size != out.items.len) return error.Compression;
    if (pos != raw.len) return error.Compression;
    return out.toOwnedSlice(gpa);
}

fn writeBlock(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8, off: usize, n: usize) model.Error!void {
    const comp = try lz4CompressBlock(gpa, raw[off..][0..n]);
    defer gpa.free(comp);
    if (comp.len >= n) {
        try writeStored(out, gpa, raw, off, n);
    } else {
        try putU32(out, gpa, @intCast(comp.len));
        try out.appendSlice(gpa, comp);
    }
}

fn writeStored(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8, off: usize, n: usize) !void {
    const size: u32 = @intCast(n);
    try putU32(out, gpa, size | 0x80000000);
    if (n > 0) try out.appendSlice(gpa, raw[off..][0..n]);
}

fn lz4CompressBlock(gpa: std.mem.Allocator, raw: []const u8) model.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const n = raw.len;
    if (n < 13) {
        try emitLiterals(&out, gpa, raw, 0, n);
        return out.toOwnedSlice(gpa);
    }
    var table = @as([1 << hash_log]i32, @splat(-1));
    var anchor: usize = 0;
    var i: usize = 0;
    while (i <= n - 12) {
        const h = hash4(raw, i);
        const src_at = table[h];
        table[h] = @intCast(i);
        if (src_at < 0 or i - @as(usize, @intCast(src_at)) > 65535 or !match4(raw, @intCast(src_at), i)) {
            i += 1;
        } else {
            const from: usize = @intCast(src_at);
            var m: usize = 4;
            const max_m = n - 5 - i;
            while (m < max_m and raw[from + m] == raw[i + m]) m += 1;
            try emitSequence(&out, gpa, raw, anchor, i, i - from, m);
            i += m;
            anchor = i;
        }
    }
    try emitLiterals(&out, gpa, raw, anchor, n);
    return out.toOwnedSlice(gpa);
}

fn match4(raw: []const u8, a: usize, b: usize) bool {
    return std.mem.eql(u8, raw[a..][0..4], raw[b..][0..4]);
}

fn hash4(raw: []const u8, i: usize) usize {
    const v = std.mem.readInt(u32, raw[i..][0..4], .little);
    return @intCast((v *% 2654435761) >> (32 - hash_log));
}

fn emitLiterals(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8, anchor: usize, end: usize) !void {
    const lit = end - anchor;
    const tok = out.items.len;
    try out.append(gpa, 0);
    if (lit >= 15) {
        out.items[tok] = 15 << 4;
        try emitExtra(out, gpa, lit - 15);
    } else out.items[tok] = @intCast(lit << 4);
    if (lit > 0) try out.appendSlice(gpa, raw[anchor..end]);
}

fn emitSequence(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8, anchor: usize, at: usize, offset: usize, mlen: usize) !void {
    const lit = at - anchor;
    const tok = out.items.len;
    try out.append(gpa, 0);
    const ll: usize = if (lit > 15) 15 else lit;
    const ml = mlen - 4;
    const mm: usize = if (ml > 15) 15 else ml;
    out.items[tok] = @intCast((ll << 4) | mm);
    if (lit >= 15) try emitExtra(out, gpa, lit - 15);
    if (lit > 0) try out.appendSlice(gpa, raw[anchor..at]);
    try out.append(gpa, @truncate(offset));
    try out.append(gpa, @truncate(offset >> 8));
    if (ml >= 15) try emitExtra(out, gpa, ml - 15);
}

fn emitExtra(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: usize) !void {
    var extra = value;
    while (extra >= 255) : (extra -= 255) try out.append(gpa, 255);
    try out.append(gpa, @intCast(extra));
}

fn lz4Block(src: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator, block_at: usize, independent: u8) model.Error!void {
    var i: usize = 0;
    while (i < src.len) {
        const token = src[i];
        i += 1;
        var lit: usize = token >> 4;
        if (lit == 15) {
            while (true) {
                if (i >= src.len) return error.Compression;
                const extra: usize = src[i];
                i += 1;
                lit += extra;
                if (extra != 255) break;
            }
        }
        if (i + lit > src.len) return error.Compression;
        try out.appendSlice(gpa, src[i..][0..lit]);
        i += lit;
        if (i >= src.len) break;
        if (i + 2 > src.len) return error.Compression;
        const offset: usize = @as(usize, src[i]) | (@as(usize, src[i + 1]) << 8);
        i += 2;
        if (offset == 0 or offset > out.items.len) return error.Compression;
        if (independent != 0 and offset > out.items.len - block_at) return error.Compression;
        var mlen: usize = @as(usize, token & 15) + 4;
        if ((token & 15) == 15) {
            while (true) {
                if (i >= src.len) return error.Compression;
                const extra: usize = src[i];
                i += 1;
                mlen += extra;
                if (extra != 255) break;
            }
        }
        const mpos = out.items.len - offset;
        var k: usize = 0;
        while (k < mlen) : (k += 1) {
            const b = out.items[mpos + k];
            try out.append(gpa, b);
        }
    }
    if (out.items.len > out_limit) return error.Compression;
}

fn lz4BlockMax(code: u8) model.Error!usize {
    return switch (code) {
        4 => 65536,
        5 => 262144,
        6 => 1048576,
        7 => 4194304,
        else => error.Compression,
    };
}

fn putU32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

test "lz4 roundtrip" {
    const gpa = std.testing.allocator;
    const text = "hello hello hello hello";
    const comp = try compress(gpa, text);
    defer gpa.free(comp);
    const back = try decompress(gpa, comp);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(text, back);
    const empty_c = try compress(gpa, "");
    defer gpa.free(empty_c);
    const empty_b = try decompress(gpa, empty_c);
    defer gpa.free(empty_b);
    try std.testing.expectEqual(@as(usize, 0), empty_b.len);
}
