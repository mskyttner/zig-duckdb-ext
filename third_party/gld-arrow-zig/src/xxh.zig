const std = @import("std");

fn rotl32(x: u32, r: u32) u32 {
    return std.math.rotl(u32, x, r);
}

fn rotl64(x: u64, r: u32) u64 {
    return std.math.rotl(u64, x, r);
}

fn load32(raw: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, raw[i..][0..4], .little);
}

fn load64(raw: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, raw[i..][0..8], .little);
}

fn round32(acc: u32, lane: u32, p1: u32, p2: u32) u32 {
    return rotl32(acc +% lane *% p2, 13) *% p1;
}

fn round64(acc: u64, lane: u64, p1: u64, p2: u64) u64 {
    return rotl64(acc +% lane *% p2, 31) *% p1;
}

pub fn xxh32(raw: []const u8) u32 {
    const p1: u32 = 0x9E3779B1;
    const p2: u32 = 0x85EBCA77;
    const p3: u32 = 0xC2B2AE3D;
    const p4: u32 = 0x27D4EB2F;
    const p5: u32 = 0x165667B1;
    var i: usize = 0;
    var h: u32 = p5;
    if (raw.len >= 16) {
        var v1 = p1 +% p2;
        var v2 = p2;
        var v3: u32 = 0;
        var v4 = 0 -% p1;
        while (i + 16 <= raw.len) : (i += 16) {
            v1 = round32(v1, load32(raw, i), p1, p2);
            v2 = round32(v2, load32(raw, i + 4), p1, p2);
            v3 = round32(v3, load32(raw, i + 8), p1, p2);
            v4 = round32(v4, load32(raw, i + 12), p1, p2);
        }
        h = rotl32(v1, 1) +% rotl32(v2, 7) +% rotl32(v3, 12) +% rotl32(v4, 18);
    }
    h +%= @intCast(raw.len);
    while (i + 4 <= raw.len) : (i += 4) {
        h +%= load32(raw, i) *% p3;
        h = rotl32(h, 17) *% p4;
    }
    while (i < raw.len) : (i += 1) {
        h +%= @as(u32, raw[i]) *% p5;
        h = rotl32(h, 11) *% p1;
    }
    h ^= h >> 15;
    h *%= p2;
    h ^= h >> 13;
    h *%= p3;
    h ^= h >> 16;
    return h;
}

fn merge64(acc: u64, val: u64, p1: u64, p2: u64, p4: u64) u64 {
    return (acc ^ round64(0, val, p1, p2)) *% p1 +% p4;
}

pub fn xxh64(raw: []const u8) u64 {
    const p1: u64 = 0x9E3779B185EBCA87;
    const p2: u64 = 0xC2B2AE3D27D4EB4F;
    const p3: u64 = 0x165667B19E3779F9;
    const p4: u64 = 0x85EBCA77C2B2AE63;
    const p5: u64 = 0x27D4EB2F165667C5;
    var i: usize = 0;
    var h: u64 = p5;
    if (raw.len >= 32) {
        var v1 = p1 +% p2;
        var v2 = p2;
        var v3: u64 = 0;
        var v4 = 0 -% p1;
        while (i + 32 <= raw.len) : (i += 32) {
            v1 = round64(v1, load64(raw, i), p1, p2);
            v2 = round64(v2, load64(raw, i + 8), p1, p2);
            v3 = round64(v3, load64(raw, i + 16), p1, p2);
            v4 = round64(v4, load64(raw, i + 24), p1, p2);
        }
        h = rotl64(v1, 1) +% rotl64(v2, 7) +% rotl64(v3, 12) +% rotl64(v4, 18);
        h = merge64(h, v1, p1, p2, p4);
        h = merge64(h, v2, p1, p2, p4);
        h = merge64(h, v3, p1, p2, p4);
        h = merge64(h, v4, p1, p2, p4);
    }
    h +%= @intCast(raw.len);
    while (i + 8 <= raw.len) : (i += 8) {
        const k1 = round64(0, load64(raw, i), p1, p2);
        h ^= k1;
        h = rotl64(h, 27) *% p1 +% p4;
    }
    if (i + 4 <= raw.len) {
        h ^= @as(u64, load32(raw, i)) *% p1;
        h = rotl64(h, 23) *% p2 +% p3;
        i += 4;
    }
    while (i < raw.len) : (i += 1) {
        h ^= @as(u64, raw[i]) *% p5;
        h = rotl64(h, 11) *% p1;
    }
    h ^= h >> 33;
    h *%= p2;
    h ^= h >> 29;
    h *%= p3;
    h ^= h >> 32;
    return h;
}

test "xxh32 empty" {
    try std.testing.expectEqual(@as(u32, 0x02CC5D05), xxh32(""));
}
