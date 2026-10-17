const std = @import("std");
const model = @import("model.zig");
const tables = @import("zstd_tables.zig");
const xxh = @import("xxh.zig");

const max_out: usize = 67_108_864;
const block_limit: usize = 131072;

const Error = model.Error;

const FseTab = struct {
    log: i32 = 0,
    size: usize = 0,
    nbits: std.ArrayList(i32) = .empty,
    nxt: std.ArrayList(i32) = .empty,
    base: std.ArrayList(i32) = .empty,
    add: std.ArrayList(i32) = .empty,
    sym: std.ArrayList(i32) = .empty,

    fn deinit(self: *FseTab, gpa: std.mem.Allocator) void {
        self.nbits.deinit(gpa);
        self.nxt.deinit(gpa);
        self.base.deinit(gpa);
        self.add.deinit(gpa);
        self.sym.deinit(gpa);
    }
};

const HuffTab = struct {
    log: i32 = 0,
    size: usize = 0,
    sym: std.ArrayList(i32) = .empty,
    nbits: std.ArrayList(i32) = .empty,

    fn deinit(self: *HuffTab, gpa: std.mem.Allocator) void {
        self.sym.deinit(gpa);
        self.nbits.deinit(gpa);
    }
};

const Rev = struct {
    base: usize,
    bitpos: isize,

    fn read(self: *Rev, data: []const u8, n: usize) i32 {
        var v: u64 = 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            v <<= 1;
            if (self.bitpos >= 0) {
                const idx = self.base + @as(usize, @intCast(@divFloor(self.bitpos, 8)));
                if (idx < data.len) {
                    const bit: u3 = @intCast(@mod(self.bitpos, 8));
                    v |= @as(u64, (data[idx] >> bit) & 1);
                }
            }
            self.bitpos -= 1;
        }
        return @intCast(v);
    }

    fn peek(self: *Rev, data: []const u8, n: usize) i32 {
        const saved = self.bitpos;
        const v = self.read(data, n);
        self.bitpos = saved;
        return v;
    }
};

const Fwd = struct {
    origin: usize,
    i: usize,
    limit: usize,
    bit: u8,

    fn read(self: *Fwd, data: []const u8, n: usize) i32 {
        var v: i32 = 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            var bitv: i32 = 0;
            if (self.i < self.limit and self.i < data.len) bitv = @intCast((data[self.i] >> @intCast(self.bit)) & 1);
            v |= bitv << @intCast(k);
            self.bit += 1;
            if (self.bit == 8) {
                self.bit = 0;
                self.i += 1;
            }
        }
        return v;
    }

    fn peek(self: *Fwd, data: []const u8, n: usize) i32 {
        const si = self.i;
        const sb = self.bit;
        const v = self.read(data, n);
        self.i = si;
        self.bit = sb;
        return v;
    }

    fn bytesUsed(self: Fwd) usize {
        if (self.bit == 0) return self.i - self.origin;
        return self.i - self.origin + 1;
    }
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    huff: HuffTab = .{},
    huff_on: bool = false,
    ll: FseTab = .{},
    oft: FseTab = .{},
    ml: FseTab = .{},
    ll_def: FseTab = .{},
    of_def: FseTab = .{},
    ml_def: FseTab = .{},
    seq_on: bool = false,
    o1: i32 = 1,
    o2: i32 = 4,
    o3: i32 = 8,
    bases_ll: []const i32 = &tables.ll_base,
    bits_ll: []const i32 = &tables.ll_bits,
    bases_ml: []const i32 = &tables.ml_base,
    bits_ml: []const i32 = &tables.ml_bits,
    bases_of: []const i32 = &tables.of_base,
    bits_of: []const i32 = &tables.of_bits,

    fn deinit(self: *Ctx) void {
        self.huff.deinit(self.gpa);
        self.ll.deinit(self.gpa);
        self.oft.deinit(self.gpa);
        self.ml.deinit(self.gpa);
        self.ll_def.deinit(self.gpa);
        self.of_def.deinit(self.gpa);
        self.ml_def.deinit(self.gpa);
    }

    fn prepare(self: *Ctx) Error!void {
        self.ll_def = try buildFse(self.gpa, &tables.ll_norm, tables.ll_norm.len - 1, 6, self.bases_ll, self.bits_ll, true);
        self.ml_def = try buildFse(self.gpa, &tables.ml_norm, tables.ml_norm.len - 1, 6, self.bases_ml, self.bits_ml, true);
        self.of_def = try buildFse(self.gpa, &tables.of_norm, tables.of_norm.len - 1, 5, self.bases_of, self.bits_of, true);
    }

    fn resetFrame(self: *Ctx) void {
        self.huff_on = false;
        self.seq_on = false;
        self.o1 = 1;
        self.o2 = 4;
        self.o3 = 8;
    }
};

pub fn compress(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    if (raw.len > max_out) return error.Compression;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &[_]u8{ 0x28, 0xB5, 0x2F, 0xFD });
    const n = raw.len;
    if (n <= 255) {
        try out.append(gpa, 0x20);
        try out.append(gpa, @intCast(n));
    } else if (n <= 65791) {
        try out.append(gpa, 0x60);
        const adj = n - 256;
        try out.append(gpa, @truncate(adj));
        try out.append(gpa, @truncate(adj >> 8));
    } else {
        try out.append(gpa, 0xA0);
        var k: usize = 0;
        while (k < 4) : (k += 1) try out.append(gpa, @truncate(n >> @intCast(8 * k)));
    }
    if (n == 0) {
        try out.appendSlice(gpa, &[_]u8{ 1, 0, 0 });
        return out.toOwnedSlice(gpa);
    }
    var uniform = n > 1;
    if (uniform) {
        for (raw[1..]) |b| {
            if (b != raw[0]) {
                uniform = false;
                break;
            }
        }
    }
    var limit = n;
    if (limit > block_limit) limit = block_limit;
    var off: usize = 0;
    while (off < n) {
        var take = n - off;
        if (take > limit) take = limit;
        const last: usize = if (off + take == n) 1 else 0;
        if (uniform) {
            const hdr = (take << 3) | 2 | last;
            try put3(&out, gpa, hdr);
            try out.append(gpa, raw[off]);
        } else {
            const hdr = (take << 3) | last;
            try put3(&out, gpa, hdr);
            try out.appendSlice(gpa, raw[off..][0..take]);
        }
        off += take;
    }
    return out.toOwnedSlice(gpa);
}

pub fn decompress(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    var ctx = Ctx{ .gpa = gpa };
    defer ctx.deinit();
    try ctx.prepare();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (pos < raw.len) {
        if (pos + 4 > raw.len) return error.Compression;
        const magic = std.mem.readInt(u32, raw[pos..][0..4], .little);
        if (magic >= 0x184D2A50 and magic <= 0x184D2A5F) {
            pos += 4;
            if (pos + 4 > raw.len) return error.Compression;
            const skip = std.mem.readInt(u32, raw[pos..][0..4], .little);
            pos += 4;
            if (pos + skip > raw.len) return error.Compression;
            pos += skip;
        } else if (magic == 0xFD2FB528) {
            pos += 4;
            pos = try decodeFrame(&ctx, raw, pos, &out);
            if (out.items.len > max_out) return error.Compression;
        } else return error.Compression;
    }
    return out.toOwnedSlice(gpa);
}

fn put3(out: *std.ArrayList(u8), gpa: std.mem.Allocator, hdr: usize) !void {
    try out.append(gpa, @truncate(hdr));
    try out.append(gpa, @truncate(hdr >> 8));
    try out.append(gpa, @truncate(hdr >> 16));
}

fn u32at(raw: []const u8, i: usize) i32 {
    return @bitCast(std.mem.readInt(u32, raw[i..][0..4], .little));
}

fn decodeFrame(ctx: *Ctx, raw: []const u8, pos0: usize, out: *std.ArrayList(u8)) Error!usize {
    ctx.resetFrame();
    var pos = pos0;
    if (pos >= raw.len) return error.Compression;
    const desc: i32 = raw[pos];
    pos += 1;
    if ((desc & 0x08) != 0) return error.Compression;
    const fcs_flag: i32 = (desc >> 6) & 3;
    const single: i32 = (desc >> 5) & 1;
    const checksum: i32 = (desc >> 2) & 1;
    const did_flag: i32 = desc & 3;
    var window: i32 = 0;
    if (single == 0) {
        if (pos >= raw.len) return error.Compression;
        const wd: i32 = raw[pos];
        pos += 1;
        const exp: i32 = wd >> 3;
        const mant: i32 = wd & 7;
        const wlog = 10 + exp;
        if (wlog > 31 or wlog < 0) return error.Compression;
        const base: i64 = @as(i64, 1) << @intCast(wlog);
        const wide = base + @divTrunc(base, 8) * mant;
        if (wide <= 0 or wide > max_out) return error.Compression;
        window = @intCast(wide);
    }
    const did_size: usize = switch (did_flag) {
        1 => 1,
        2 => 2,
        3 => 4,
        else => 0,
    };
    var fcs_size: usize = 0;
    if (single != 0) {
        fcs_size = switch (fcs_flag) {
            0 => 1,
            1 => 2,
            2 => 4,
            else => 8,
        };
    } else {
        fcs_size = switch (fcs_flag) {
            1 => 2,
            2 => 4,
            3 => 8,
            else => 0,
        };
    }
    if (pos + did_size + fcs_size > raw.len) return error.Compression;
    var did: i32 = 0;
    var k: usize = 0;
    while (k < did_size) : (k += 1) {
        did |= @as(i32, raw[pos]) << @intCast(8 * k);
        pos += 1;
    }
    if (did != 0) return error.Compression;
    var content: i64 = -1;
    if (fcs_size != 0) {
        var declared: u64 = 0;
        var kk: isize = @as(isize, @intCast(fcs_size)) - 1;
        const p0 = pos;
        while (kk >= 0) : (kk -= 1) {
            declared = (declared << 8) | raw[p0 + @as(usize, @intCast(kk))];
        }
        pos += fcs_size;
        if (fcs_size == 2) declared += 256;
        if (declared > max_out) return error.Compression;
        content = @intCast(declared);
    }
    if (single != 0) {
        if (content < 0) return error.Compression;
        window = @intCast(content);
    }
    var block_max: i32 = window;
    if (block_max > block_limit) block_max = block_limit;
    const frame_at = out.items.len;
    while (true) {
        if (pos + 3 > raw.len) return error.Compression;
        const hdr: i32 = @as(i32, raw[pos]) | (@as(i32, raw[pos + 1]) << 8) | (@as(i32, raw[pos + 2]) << 16);
        pos += 3;
        const last = hdr & 1;
        const btype = (hdr >> 1) & 3;
        const bsize = hdr >> 3;
        if (btype == 3) return error.Compression;
        if (btype == 1) {
            if (pos >= raw.len) return error.Compression;
            if (bsize > block_max or out.items.len + @as(usize, @intCast(bsize)) > max_out) return error.Compression;
            const value = raw[pos];
            pos += 1;
            if (bsize > 0) try out.appendNTimes(ctx.gpa, value, @intCast(bsize));
        } else if (btype == 0) {
            if (bsize > block_max or pos + @as(usize, @intCast(bsize)) > raw.len or out.items.len + @as(usize, @intCast(bsize)) > max_out) return error.Compression;
            if (bsize > 0) try out.appendSlice(ctx.gpa, raw[pos..][0..@intCast(bsize)]);
            pos += @intCast(bsize);
        } else {
            if (bsize > block_max or pos + @as(usize, @intCast(bsize)) > raw.len) return error.Compression;
            const before = out.items.len;
            try block(ctx, raw, pos, @intCast(bsize), out, window, block_max);
            pos += @intCast(bsize);
            if (out.items.len - before > @as(usize, @intCast(block_max))) return error.Compression;
        }
        if (last != 0) break;
    }
    if (content >= 0 and out.items.len - frame_at != @as(usize, @intCast(content))) return error.Compression;
    if (checksum != 0) {
        if (pos + 4 > raw.len) return error.Compression;
        const want = std.mem.readInt(u32, raw[pos..][0..4], .little);
        pos += 4;
        const have: u32 = @truncate(xxh.xxh64(out.items[frame_at..]));
        if (have != want) return error.Compression;
    }
    return pos;
}

fn block(ctx: *Ctx, data: []const u8, pos: usize, bsize: usize, out: *std.ArrayList(u8), window: i32, block_max: i32) Error!void {
    const end = pos + bsize;
    var cursor = pos;
    var lits: std.ArrayList(u8) = .empty;
    defer lits.deinit(ctx.gpa);
    try literals(ctx, data, &cursor, end, &lits, block_max);
    try sequences(ctx, data, &cursor, end, lits.items, out, window, block_max);
}

fn literals(ctx: *Ctx, data: []const u8, pos: *usize, end: usize, lits: *std.ArrayList(u8), block_max: i32) Error!void {
    if (pos.* >= end) return error.Compression;
    const b0: i32 = data[pos.*];
    const ltype = b0 & 3;
    const fmt = (b0 >> 2) & 3;
    if (ltype == 0 or ltype == 1) {
        var lh: usize = 1;
        var regen: i32 = b0 >> 3;
        if (fmt == 1) {
            if (pos.* + 2 > end) return error.Compression;
            lh = 2;
            regen = (b0 >> 4) + (@as(i32, data[pos.* + 1]) << 4);
        } else if (fmt == 3) {
            if (pos.* + 3 > end) return error.Compression;
            lh = 3;
            regen = (b0 >> 4) + (@as(i32, data[pos.* + 1]) << 4) + (@as(i32, data[pos.* + 2]) << 12);
        }
        if (regen > block_max or pos.* + lh > end) return error.Compression;
        if (ltype == 0) {
            if (pos.* + lh + @as(usize, @intCast(regen)) > end) return error.Compression;
            if (regen > 0) try lits.appendSlice(ctx.gpa, data[pos.* + lh ..][0..@intCast(regen)]);
            pos.* += lh + @as(usize, @intCast(regen));
            return;
        }
        if (regen == 0) {
            pos.* += lh;
            return;
        }
        if (pos.* + lh >= end) return error.Compression;
        const value = data[pos.* + lh];
        try lits.appendNTimes(ctx.gpa, value, @intCast(regen));
        pos.* += lh + 1;
        return;
    }
    if (end - pos.* < 5) return error.Compression;
    const word = u32at(data, pos.*);
    var lh: usize = 3;
    var regen: i32 = (word >> 4) & 0x3FF;
    var csize: i32 = (word >> 14) & 0x3FF;
    var single: i32 = 0;
    if (fmt == 0) {
        single = 1;
    } else if (fmt == 2) {
        lh = 4;
        regen = (word >> 4) & 0x3FFF;
        csize = word >> 18;
    } else if (fmt == 3) {
        lh = 5;
        regen = (word >> 4) & 0x3FFFF;
        csize = (word >> 22) + (@as(i32, data[pos.* + 4]) << 10);
    }
    if (csize <= 0 or regen > block_max or pos.* + lh + @as(usize, @intCast(csize)) > end) return error.Compression;
    if (single == 0 and regen < 6) return error.Compression;
    const body = pos.* + lh;
    if (ltype == 2) {
        var hp = body;
        try readHuff(ctx, data, &hp, pos.* + lh + @as(usize, @intCast(csize)));
        ctx.huff_on = true;
    } else if (ltype == 3) {
        if (!ctx.huff_on) return error.Compression;
    } else return error.Compression;
    const total = pos.* + lh + @as(usize, @intCast(csize)) - body;
    if (single != 0) {
        const part = try hufDecode(ctx.gpa, data, body, total, &ctx.huff, @intCast(regen));
        defer ctx.gpa.free(part);
        try lits.appendSlice(ctx.gpa, part);
        pos.* += lh + @as(usize, @intCast(csize));
        return;
    }
    if (total < 10) return error.Compression;
    const s1: usize = @as(usize, data[body]) | (@as(usize, data[body + 1]) << 8);
    const s2: usize = @as(usize, data[body + 2]) | (@as(usize, data[body + 3]) << 8);
    const s3: usize = @as(usize, data[body + 4]) | (@as(usize, data[body + 5]) << 8);
    if (6 + s1 + s2 + s3 >= total) return error.Compression;
    const s4 = total - 6 - s1 - s2 - s3;
    if (s1 < 1 or s2 < 1 or s3 < 1 or s4 < 1) return error.Compression;
    const chunk: i32 = @divTrunc(regen + 3, 4);
    const counts = [_]i32{ chunk, chunk, chunk, regen - 3 * chunk };
    const sizes = [_]usize{ s1, s2, s3, s4 };
    var off = body + 6;
    var stream: usize = 0;
    while (stream < 4) : (stream += 1) {
        const part = try hufDecode(ctx.gpa, data, off, sizes[stream], &ctx.huff, counts[stream]);
        defer ctx.gpa.free(part);
        try lits.appendSlice(ctx.gpa, part);
        off += sizes[stream];
    }
    pos.* += lh + @as(usize, @intCast(csize));
}

fn sequences(ctx: *Ctx, data: []const u8, pos: *usize, end: usize, lits: []const u8, out: *std.ArrayList(u8), window: i32, block_max: i32) Error!void {
    if (pos.* >= end) return error.Compression;
    const b0: i32 = data[pos.*];
    pos.* += 1;
    var nb: i32 = b0;
    if (b0 >= 128 and b0 < 255) {
        if (pos.* >= end) return error.Compression;
        nb = ((b0 - 128) << 8) + data[pos.*];
        pos.* += 1;
    } else if (b0 == 255) {
        if (pos.* + 2 > end) return error.Compression;
        nb = @as(i32, data[pos.*]) + (@as(i32, data[pos.* + 1]) << 8) + 0x7F00;
        pos.* += 2;
    }
    if (nb == 0) {
        if (pos.* != end) return error.Compression;
        try out.appendSlice(ctx.gpa, lits);
        return;
    }
    if (pos.* >= end) return error.Compression;
    const modes: i32 = data[pos.*];
    pos.* += 1;
    if ((modes & 3) != 0) return error.Compression;
    try installTable(ctx, data, pos, end, 0, (modes >> 6) & 3);
    try installTable(ctx, data, pos, end, 1, (modes >> 4) & 3);
    try installTable(ctx, data, pos, end, 2, (modes >> 2) & 3);
    if (pos.* >= end) return error.Compression;
    var br = try rev(data, pos.*, end - pos.*);
    var st_ll = br.read(data, @intCast(ctx.ll.log));
    var st_of = br.read(data, @intCast(ctx.oft.log));
    var st_ml = br.read(data, @intCast(ctx.ml.log));
    if (st_ll < 0 or st_of < 0 or st_ml < 0) return error.Compression;
    if (@as(usize, @intCast(st_ll)) >= ctx.ll.size or @as(usize, @intCast(st_of)) >= ctx.oft.size or @as(usize, @intCast(st_ml)) >= ctx.ml.size) return error.Compression;
    var lit_i: usize = 0;
    var nseq: i32 = 0;
    while (nseq < nb) : (nseq += 1) {
        const is_last = nseq + 1 == nb;
        const ll_base_v = ctx.ll.base.items[@intCast(st_ll)];
        const ml_base_v = ctx.ml.base.items[@intCast(st_ml)];
        const of_base_v = ctx.oft.base.items[@intCast(st_of)];
        const ll_add = ctx.ll.add.items[@intCast(st_ll)];
        const ml_add = ctx.ml.add.items[@intCast(st_ml)];
        const of_add = ctx.oft.add.items[@intCast(st_of)];
        const ll_nb = ctx.ll.nbits.items[@intCast(st_ll)];
        const ml_nb = ctx.ml.nbits.items[@intCast(st_ml)];
        const of_nb = ctx.oft.nbits.items[@intCast(st_of)];
        const ll_next = ctx.ll.nxt.items[@intCast(st_ll)];
        const ml_next = ctx.ml.nxt.items[@intCast(st_ml)];
        const of_next = ctx.oft.nxt.items[@intCast(st_of)];
        var offset: i32 = ctx.o1;
        if (of_add > 1) {
            offset = of_base_v + br.read(data, @intCast(of_add));
            ctx.o3 = ctx.o2;
            ctx.o2 = ctx.o1;
            ctx.o1 = offset;
        } else if (of_add == 0 and ll_base_v == 0) {
            offset = ctx.o2;
            ctx.o2 = ctx.o1;
            ctx.o1 = offset;
        } else if (of_add != 0) {
            const ll0: i32 = if (ll_base_v == 0) 1 else 0;
            const code = of_base_v + ll0 + br.read(data, 1);
            var temp = ctx.o1;
            if (code == 3) temp = ctx.o1 - 1 else if (code == 2) temp = ctx.o3 else if (code == 1) temp = ctx.o2;
            if (temp <= 0) return error.Compression;
            if (code != 1) ctx.o3 = ctx.o2;
            ctx.o2 = ctx.o1;
            ctx.o1 = temp;
            offset = temp;
        }
        var match_len: i32 = ml_base_v;
        if (ml_add != 0) match_len += br.read(data, @intCast(ml_add));
        var lit_len: i32 = ll_base_v;
        if (ll_add != 0) lit_len += br.read(data, @intCast(ll_add));
        if (offset <= 0 or lit_len < 0 or match_len < 0) return error.Compression;
        if (lit_len > block_max or match_len > block_max) return error.Compression;
        if (lit_i + @as(usize, @intCast(lit_len)) > lits.len) return error.Compression;
        if (lit_len > 0) {
            try out.appendSlice(ctx.gpa, lits[lit_i..][0..@intCast(lit_len)]);
            lit_i += @intCast(lit_len);
        }
        if (offset > out.items.len or offset > window) return error.Compression;
        const mpos = out.items.len - @as(usize, @intCast(offset));
        var t: i32 = 0;
        while (t < match_len) : (t += 1) {
            const b = out.items[mpos + @as(usize, @intCast(t))];
            try out.append(ctx.gpa, b);
        }
        if (!is_last) {
            st_ll = ll_next + br.read(data, @intCast(ll_nb));
            st_ml = ml_next + br.read(data, @intCast(ml_nb));
            st_of = of_next + br.read(data, @intCast(of_nb));
            if (st_ll < 0 or st_ml < 0 or st_of < 0) return error.Compression;
            if (@as(usize, @intCast(st_ll)) >= ctx.ll.size or @as(usize, @intCast(st_ml)) >= ctx.ml.size or @as(usize, @intCast(st_of)) >= ctx.oft.size) return error.Compression;
        }
    }
    if (br.bitpos != -1) return error.Compression;
    if (lit_i < lits.len) try out.appendSlice(ctx.gpa, lits[lit_i..]);
    ctx.seq_on = true;
}

fn installTable(ctx: *Ctx, data: []const u8, pos: *usize, end: usize, which: usize, mode: i32) Error!void {
    if (mode == 3) {
        if (!ctx.seq_on) return error.Compression;
        return;
    }
    if (mode == 0) {
        if (which == 0) {
            ctx.ll.deinit(ctx.gpa);
            ctx.ll = try copyFse(ctx.gpa, &ctx.ll_def);
        } else if (which == 1) {
            ctx.oft.deinit(ctx.gpa);
            ctx.oft = try copyFse(ctx.gpa, &ctx.of_def);
        } else {
            ctx.ml.deinit(ctx.gpa);
            ctx.ml = try copyFse(ctx.gpa, &ctx.ml_def);
        }
        return;
    }
    var max_sym: i32 = 35;
    var max_log: i32 = 9;
    if (which == 1) {
        max_sym = 31;
        max_log = 8;
    } else if (which == 2) max_sym = 52;
    if (mode == 1) {
        if (pos.* >= end) return error.Compression;
        const symbol: i32 = data[pos.*];
        pos.* += 1;
        if (which == 0) {
            ctx.ll.deinit(ctx.gpa);
            ctx.ll = try makeRle(ctx.gpa, symbol, ctx.bases_ll, ctx.bits_ll);
        } else if (which == 1) {
            ctx.oft.deinit(ctx.gpa);
            ctx.oft = try makeRle(ctx.gpa, symbol, ctx.bases_of, ctx.bits_of);
        } else {
            ctx.ml.deinit(ctx.gpa);
            ctx.ml = try makeRle(ctx.gpa, symbol, ctx.bases_ml, ctx.bits_ml);
        }
        return;
    }
    if (mode != 2) return error.Compression;
    var norm: std.ArrayList(i32) = .empty;
    defer norm.deinit(ctx.gpa);
    var table_log: i32 = 0;
    var npos: usize = pos.*;
    try readNcount(ctx.gpa, data, pos.*, end, max_sym, max_log, &norm, &table_log, &npos);
    pos.* = npos;
    const bases = if (which == 0) ctx.bases_ll else if (which == 1) ctx.bases_of else ctx.bases_ml;
    const adds = if (which == 0) ctx.bits_ll else if (which == 1) ctx.bits_of else ctx.bits_ml;
    const built = try buildFse(ctx.gpa, norm.items, @intCast(max_sym), table_log, bases, adds, true);
    if (which == 0) {
        ctx.ll.deinit(ctx.gpa);
        ctx.ll = built;
    } else if (which == 1) {
        ctx.oft.deinit(ctx.gpa);
        ctx.oft = built;
    } else {
        ctx.ml.deinit(ctx.gpa);
        ctx.ml = built;
    }
}

fn readHuff(ctx: *Ctx, data: []const u8, pos: *usize, end: usize) Error!void {
    if (pos.* >= end) return error.Compression;
    const header: i32 = data[pos.*];
    if (header >= 128) {
        const osize = header - 127;
        const nbytes: usize = @intCast(@divTrunc(osize + 1, 2));
        if (pos.* + 1 + nbytes > end) return error.Compression;
        var weights: std.ArrayList(i32) = .empty;
        defer weights.deinit(ctx.gpa);
        var n: i32 = 0;
        while (n < osize) : (n += 2) {
            const b: i32 = data[pos.* + 1 + @as(usize, @intCast(@divTrunc(n, 2)))];
            try weights.append(ctx.gpa, b >> 4);
            if (n + 1 < osize) try weights.append(ctx.gpa, b & 15);
        }
        ctx.huff.deinit(ctx.gpa);
        ctx.huff = try buildHuff(ctx.gpa, weights.items);
        pos.* += 1 + nbytes;
        return;
    }
    if (header == 0 or pos.* + 1 + @as(usize, @intCast(header)) > end) return error.Compression;
    var weights = try fseWeights(ctx.gpa, data, pos.* + 1, @intCast(header), 255);
    defer weights.deinit(ctx.gpa);
    ctx.huff.deinit(ctx.gpa);
    ctx.huff = try buildHuff(ctx.gpa, weights.items);
    pos.* += 1 + @as(usize, @intCast(header));
}

fn fseWeights(gpa: std.mem.Allocator, data: []const u8, start: usize, size: usize, max_out_n: i32) Error!std.ArrayList(i32) {
    var norm: std.ArrayList(i32) = .empty;
    defer norm.deinit(gpa);
    var table_log: i32 = 0;
    var npos: usize = start;
    try readNcount(gpa, data, start, start + size, 255, 6, &norm, &table_log, &npos);
    const empty: []const i32 = &.{};
    var tab = try buildFse(gpa, norm.items, 255, table_log, empty, empty, false);
    defer tab.deinit(gpa);
    if (npos >= start + size) return error.Compression;
    var br = try rev(data, npos, start + size - npos);
    var s1 = br.read(data, @intCast(table_log));
    var s2 = br.read(data, @intCast(table_log));
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(gpa);
    var guard: i32 = 0;
    while (guard <= max_out_n) : (guard += 1) {
        if (out.items.len > @as(usize, @intCast(max_out_n)) - 2) return error.Compression;
        if (s1 < 0 or @as(usize, @intCast(s1)) >= tab.size) return error.Compression;
        const sym = tab.sym.items[@intCast(s1)];
        const low = br.read(data, @intCast(tab.nbits.items[@intCast(s1)]));
        s1 = tab.nxt.items[@intCast(s1)] + low;
        try out.append(gpa, sym);
        if (br.bitpos < -1) {
            if (s2 < 0 or @as(usize, @intCast(s2)) >= tab.size) return error.Compression;
            try out.append(gpa, tab.sym.items[@intCast(s2)]);
            break;
        }
        if (out.items.len > @as(usize, @intCast(max_out_n)) - 2) return error.Compression;
        if (s2 < 0 or @as(usize, @intCast(s2)) >= tab.size) return error.Compression;
        const sym2 = tab.sym.items[@intCast(s2)];
        const low2 = br.read(data, @intCast(tab.nbits.items[@intCast(s2)]));
        s2 = tab.nxt.items[@intCast(s2)] + low2;
        try out.append(gpa, sym2);
        if (br.bitpos < -1) {
            if (s1 < 0 or @as(usize, @intCast(s1)) >= tab.size) return error.Compression;
            try out.append(gpa, tab.sym.items[@intCast(s1)]);
            break;
        }
    }
    if (out.items.len > @as(usize, @intCast(max_out_n)) or guard > max_out_n) return error.Compression;
    return out;
}

fn hufDecode(gpa: std.mem.Allocator, data: []const u8, start: usize, size: usize, tab: *const HuffTab, count: i32) Error![]u8 {
    if (size < 1) return error.Compression;
    var br = try rev(data, start, size);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (count == 0) {
        if (br.bitpos != -1) return error.Compression;
        return out.toOwnedSlice(gpa);
    }
    var k: i32 = 0;
    while (k < count) : (k += 1) {
        const val = br.peek(data, @intCast(tab.log));
        if (val < 0 or @as(usize, @intCast(val)) >= tab.size) return error.Compression;
        const nb = tab.nbits.items[@intCast(val)];
        if (nb <= 0 or nb > tab.log) return error.Compression;
        _ = br.read(data, @intCast(nb));
        try out.append(gpa, @intCast(tab.sym.items[@intCast(val)]));
    }
    if (br.bitpos != -1) return error.Compression;
    return out.toOwnedSlice(gpa);
}

fn buildHuff(gpa: std.mem.Allocator, weights: []const i32) Error!HuffTab {
    var rank = @as([16]i32, @splat(0));
    var total: i32 = 0;
    for (weights) |w| {
        if (w < 0 or w > 12) return error.Compression;
        rank[@intCast(w)] += 1;
        if (w > 0) total += @as(i32, 1) << @intCast(w - 1);
    }
    if (total <= 0) return error.Compression;
    const table_log = bitLength(total);
    if (table_log > 11 or table_log <= 0) return error.Compression;
    const full = @as(i32, 1) << @intCast(table_log);
    const rest = full - total;
    if (rest <= 0 or (rest & (rest - 1)) != 0) return error.Compression;
    const last = bitLength(rest);
    var ws: std.ArrayList(i32) = .empty;
    defer ws.deinit(gpa);
    try ws.appendSlice(gpa, weights);
    try ws.append(gpa, last);
    rank[@intCast(last)] += 1;
    if (rank[1] < 2 or (rank[1] & 1) != 0) return error.Compression;
    const nb = ws.items.len;
    var rank_start = @as([16]i32, @splat(0));
    var acc: i32 = 0;
    var w: i32 = 0;
    while (w <= table_log) : (w += 1) {
        rank_start[@intCast(w)] = acc;
        acc += rank[@intCast(w)];
    }
    var ordered: std.ArrayList(i32) = .empty;
    defer ordered.deinit(gpa);
    try ordered.appendNTimes(gpa, 0, nb);
    var rs = rank_start;
    for (ws.items, 0..) |ww, i| {
        const at = rs[@intCast(ww)];
        ordered.items[@intCast(at)] = @intCast(i);
        rs[@intCast(ww)] = at + 1;
    }
    const table_size: usize = @intCast(full);
    var tab = HuffTab{};
    errdefer tab.deinit(gpa);
    tab.log = table_log;
    tab.size = table_size;
    try tab.sym.appendNTimes(gpa, 0, table_size);
    try tab.nbits.appendNTimes(gpa, 0, table_size);
    var idx: i32 = rank[0];
    var slot: usize = 0;
    w = 1;
    while (w <= table_log) : (w += 1) {
        const count = rank[@intCast(w)];
        const length: usize = @intCast(@as(i32, 1) << @intCast(w - 1));
        const bits = table_log + 1 - w;
        var s: i32 = 0;
        while (s < count) : (s += 1) {
            const symbol = ordered.items[@intCast(idx + s)];
            var u: usize = 0;
            while (u < length) : (u += 1) {
                if (slot >= table_size) return error.Compression;
                tab.sym.items[slot] = symbol;
                tab.nbits.items[slot] = bits;
                slot += 1;
            }
        }
        idx += count;
    }
    if (slot != table_size) return error.Compression;
    return tab;
}

fn readNcount(
    gpa: std.mem.Allocator,
    data: []const u8,
    start: usize,
    limit: usize,
    max_symbol: i32,
    max_log: i32,
    norm: *std.ArrayList(i32),
    table_log: *i32,
    npos: *usize,
) Error!void {
    if (start >= limit) return error.Compression;
    var br = Fwd{ .origin = start, .i = start, .limit = limit, .bit = 0 };
    const acc = br.read(data, 4) + 5;
    if (acc > max_log or acc > 15 or acc < 5) return error.Compression;
    table_log.* = acc;
    var remaining = (@as(i32, 1) << @intCast(table_log.*)) + 1;
    var threshold = @as(i32, 1) << @intCast(table_log.*);
    var nb_bits = table_log.* + 1;
    norm.clearRetainingCapacity();
    try norm.appendNTimes(gpa, 0, @intCast(max_symbol + 1));
    var charnum: i32 = 0;
    var prev0: i32 = 0;
    var guard: i32 = 0;
    while (guard < max_symbol + 8) : (guard += 1) {
        if (prev0 != 0) {
            while (true) {
                const rep = br.read(data, 2);
                charnum += rep;
                if (rep != 3) break;
            }
            if (charnum > max_symbol + 1) return error.Compression;
            if (charnum >= max_symbol + 1) break;
        }
        const maxv = (2 * threshold - 1) - remaining;
        if (maxv < 0 or nb_bits <= 1) return error.Compression;
        const low = br.peek(data, @intCast(nb_bits - 1));
        var val: i32 = low;
        if (low < maxv) {
            _ = br.read(data, @intCast(nb_bits - 1));
        } else {
            val = br.read(data, @intCast(nb_bits));
            if (val >= threshold) val -= maxv;
        }
        val -= 1;
        if (charnum > max_symbol) return error.Compression;
        norm.items[@intCast(charnum)] = val;
        charnum += 1;
        if (val >= 0) remaining -= val else {
            if (val != -1) return error.Compression;
            remaining -= 1;
        }
        prev0 = if (val == 0) 1 else 0;
        if (remaining < threshold) {
            if (remaining <= 1) break;
            nb_bits = bitLength(remaining);
            threshold = @as(i32, 1) << @intCast(nb_bits - 1);
        }
        if (charnum >= max_symbol + 1) break;
    }
    if (remaining != 1 or charnum > max_symbol + 1) return error.Compression;
    var nonzero: i32 = 0;
    for (norm.items) |v| {
        if (v != 0) nonzero += 1;
    }
    if (nonzero < 2) return error.Compression;
    const used = br.bytesUsed();
    if (start + used > limit) return error.Compression;
    npos.* = start + used;
}

fn buildFse(
    gpa: std.mem.Allocator,
    norm: []const i32,
    max_symbol: usize,
    table_log: i32,
    bases: []const i32,
    adds: []const i32,
    use_base: bool,
) Error!FseTab {
    if (table_log < 5 or table_log > 12 or max_symbol >= norm.len) return error.Compression;
    const table_size: usize = @as(usize, 1) << @intCast(table_log);
    var symbol_at: std.ArrayList(i32) = .empty;
    defer symbol_at.deinit(gpa);
    try symbol_at.appendNTimes(gpa, 0, table_size);
    var symbol_next: std.ArrayList(i32) = .empty;
    defer symbol_next.deinit(gpa);
    try symbol_next.appendNTimes(gpa, 0, max_symbol + 1);
    var high: isize = @intCast(table_size - 1);
    var s: usize = 0;
    while (s <= max_symbol) : (s += 1) {
        if (norm[s] == -1) {
            if (high < 0) return error.Compression;
            symbol_at.items[@intCast(high)] = @intCast(s);
            high -= 1;
            symbol_next.items[s] = 1;
        } else if (norm[s] < 0) return error.Compression else symbol_next.items[s] = norm[s];
    }
    const step = (table_size >> 1) + (table_size >> 3) + 3;
    const mask = table_size - 1;
    var position: usize = 0;
    s = 0;
    while (s <= max_symbol) : (s += 1) {
        const count = norm[s];
        if (count > 0) {
            var j: i32 = 0;
            while (j < count) : (j += 1) {
                symbol_at.items[position] = @intCast(s);
                position = (position + step) & mask;
                var spins: usize = 0;
                while (@as(isize, @intCast(position)) > high) {
                    position = (position + step) & mask;
                    spins += 1;
                    if (spins > table_size) return error.Compression;
                }
            }
        }
    }
    if (position != 0) return error.Compression;
    var tab = FseTab{};
    errdefer tab.deinit(gpa);
    tab.log = table_log;
    tab.size = table_size;
    try tab.nbits.resize(gpa, table_size);
    try tab.nxt.resize(gpa, table_size);
    try tab.base.resize(gpa, table_size);
    try tab.add.resize(gpa, table_size);
    try tab.sym.resize(gpa, table_size);
    @memset(tab.nbits.items, 0);
    @memset(tab.nxt.items, 0);
    @memset(tab.base.items, 0);
    @memset(tab.add.items, 0);
    @memset(tab.sym.items, 0);
    var u: usize = 0;
    while (u < table_size) : (u += 1) {
        const symbol: usize = @intCast(symbol_at.items[u]);
        const ns = symbol_next.items[symbol];
        symbol_next.items[symbol] = ns + 1;
        if (ns <= 0) return error.Compression;
        const nb: i32 = table_log - (bitLength(ns) - 1);
        tab.nbits.items[u] = nb;
        const shifted = @as(i32, ns) << @intCast(nb);
        tab.nxt.items[u] = shifted - @as(i32, @intCast(table_size));
        tab.sym.items[u] = @intCast(symbol);
        if (use_base) {
            if (symbol >= bases.len or symbol >= adds.len) return error.Compression;
            tab.base.items[u] = bases[symbol];
            tab.add.items[u] = adds[symbol];
        }
    }
    return tab;
}

fn makeRle(gpa: std.mem.Allocator, symbol: i32, bases: []const i32, adds: []const i32) Error!FseTab {
    if (symbol < 0 or @as(usize, @intCast(symbol)) >= bases.len or @as(usize, @intCast(symbol)) >= adds.len) return error.Compression;
    var tab = FseTab{};
    errdefer tab.deinit(gpa);
    tab.log = 0;
    tab.size = 1;
    try tab.nbits.append(gpa, 0);
    try tab.nxt.append(gpa, 0);
    try tab.base.append(gpa, bases[@intCast(symbol)]);
    try tab.add.append(gpa, adds[@intCast(symbol)]);
    try tab.sym.append(gpa, symbol);
    return tab;
}

fn copyFse(gpa: std.mem.Allocator, src: *const FseTab) Error!FseTab {
    var dst = FseTab{};
    errdefer dst.deinit(gpa);
    dst.log = src.log;
    dst.size = src.size;
    try dst.nbits.appendSlice(gpa, src.nbits.items);
    try dst.nxt.appendSlice(gpa, src.nxt.items);
    try dst.base.appendSlice(gpa, src.base.items);
    try dst.add.appendSlice(gpa, src.add.items);
    try dst.sym.appendSlice(gpa, src.sym.items);
    return dst;
}

fn rev(data: []const u8, start: usize, size: usize) Error!Rev {
    if (size < 1 or start + size > data.len) return error.Compression;
    const last: i32 = data[start + size - 1];
    if (last == 0) return error.Compression;
    const hibit = bitLength(last) - 1;
    const bitpos: isize = @as(isize, @intCast((size - 1) * 8)) + hibit - 1;
    return .{ .base = start, .bitpos = bitpos };
}

fn bitLength(v: i32) i32 {
    if (v <= 0) return 0;
    return @intCast(32 - @clz(@as(u32, @intCast(v))));
}

test "zstd roundtrip" {
    const gpa = std.testing.allocator;
    const text = "hello hello hello hello hello";
    const comp = try compress(gpa, text);
    defer gpa.free(comp);
    const back = try decompress(gpa, comp);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(text, back);
    const zeros = try gpa.alloc(u8, 4000);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    const zc = try compress(gpa, zeros);
    defer gpa.free(zc);
    try std.testing.expect(zc.len < zeros.len);
    const zb = try decompress(gpa, zc);
    defer gpa.free(zb);
    try std.testing.expectEqualSlices(u8, zeros, zb);
}
