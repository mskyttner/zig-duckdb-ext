const std = @import("std");
const fb = @import("flatbuf.zig");
const le = @import("le.zig");
const lz4 = @import("lz4.zig");
const model = @import("model.zig");
const schema_fb = @import("schema_fb.zig");
const tensor = @import("tensor.zig");
const zstd = @import("zstd.zig");

const Error = model.Error;
const magic = "ARROW1";

/// Large IPC bodies are allocated on a 2MB boundary and populated as transparent
/// huge pages so the following copy faults a handful of pages instead of one
/// page per 4KiB. Smaller buffers stay on the ordinary allocator path.
fn reserveHuge(gpa: std.mem.Allocator, out: *std.ArrayList(u8), need: usize) Error!void {
    if (out.capacity >= need) return;
    if (need < 256 * 1024 or @import("builtin").os.tag != .linux) {
        out.ensureTotalCapacityPrecise(gpa, need) catch return error.OutOfMemory;
        return;
    }
    const huge = comptime std.mem.Alignment.fromByteUnits(1 << 21);
    const buf = gpa.alignedAlloc(u8, huge, need) catch return error.OutOfMemory;
    _ = std.os.linux.madvise(buf.ptr, buf.len, 14); // MADV_HUGEPAGE
    _ = std.os.linux.madvise(buf.ptr, buf.len, 23); // MADV_POPULATE_WRITE
    const len = out.items.len;
    if (len > 0) @memcpy(buf[0..len], out.items);
    gpa.free(out.allocatedSlice());
    out.items = buf[0..len];
    out.capacity = buf.len;
}

pub fn encodeStream(gpa: std.mem.Allocator, c: *const model.Columnar) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeStream(gpa, c, &out);
    return takeBytes(gpa, &out);
}

pub fn encodeFile(gpa: std.mem.Allocator, c: *const model.Columnar) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    try out.appendSlice(gpa, &[_]u8{ 0, 0 });
    var blocks_off: std.ArrayList(i64) = .empty;
    defer blocks_off.deinit(gpa);
    var blocks_meta: std.ArrayList(i32) = .empty;
    defer blocks_meta.deinit(gpa);
    var blocks_body: std.ArrayList(i64) = .empty;
    defer blocks_body.deinit(gpa);
    var blocks_kind: std.ArrayList(u8) = .empty;
    defer blocks_kind.deinit(gpa);
    try writeStreamTracked(gpa, c, &out, &blocks_off, &blocks_meta, &blocks_body, &blocks_kind);
    const footer = try footerBytes(gpa, c, blocks_off.items, blocks_meta.items, blocks_body.items, blocks_kind.items);
    defer gpa.free(footer);
    try out.appendSlice(gpa, footer);
    try le.appendU32(&out, gpa, @intCast(footer.len));
    try out.appendSlice(gpa, magic);
    return takeBytes(gpa, &out);
}

fn takeBytes(gpa: std.mem.Allocator, list: *std.ArrayList(u8)) Error![]u8 {
    if (list.capacity == list.items.len) {
        const result = list.items;
        list.* = .empty;
        return result;
    }
    return list.toOwnedSlice(gpa) catch error.OutOfMemory;
}

/// Decode an IPC stream. Uncompressed little-endian bodies alias `raw`.
/// `raw` must stay allocated until `c.deinit()`.
pub fn decodeStream(gpa: std.mem.Allocator, raw: []const u8) Error!model.Columnar {
    var c = model.Columnar.init(gpa);
    errdefer c.deinit();
    try ingest(&c, raw, 0, raw.len);
    return c;
}

/// Decode an IPC file. The same lifetime rule as `decodeStream` applies to `raw`.
pub fn decodeFile(gpa: std.mem.Allocator, raw: []const u8) Error!model.Columnar {
    if (raw.len < 10 or !magicAt(raw, 0) or !magicAt(raw, raw.len - 6)) return error.Syntax;
    const flen = le.readU32(raw, raw.len - 10) catch return error.EndOfBuffer;
    if (flen < 8 or raw.len < 10 + flen) return error.Syntax;
    const footer_at = raw.len - 10 - flen;
    if (footer_at < 8) return error.Syntax;
    var c = model.Columnar.init(gpa);
    errdefer c.deinit();
    try ingest(&c, raw, 8, footer_at);
    return c;
}

pub const FooterInfo = struct {
    version: u16,
    n_fields: usize,
    n_dict: usize,
    n_batch: usize,
    first_batch_off: i64 = 0,
    first_batch_meta: i32 = 0,
    first_batch_body: i64 = 0,
};

pub fn readFooter(raw: []const u8) Error!FooterInfo {
    if (raw.len < 10 or !magicAt(raw, 0) or !magicAt(raw, raw.len - 6)) return error.Syntax;
    const flen = le.readU32(raw, raw.len - 10) catch return error.EndOfBuffer;
    if (flen < 8 or raw.len < 10 + flen) return error.Syntax;
    const footer_at = raw.len - 10 - flen;
    const r = fb.Reader{ .data = raw[footer_at .. footer_at + flen] };
    const table = try r.root();
    var info = FooterInfo{ .version = 4, .n_fields = 0, .n_dict = 0, .n_batch = 0 };
    if (try r.field(table, 0)) |p| info.version = try r.u16At(p);
    if (try r.field(table, 1)) |sp| {
        const schema = try r.follow(sp);
        if (try r.field(schema, 1)) |fp| info.n_fields = try r.vecLen(fp);
    }
    if (try r.field(table, 2)) |dp| info.n_dict = try r.vecLen(dp);
    if (try r.field(table, 3)) |bp| {
        info.n_batch = try r.vecLen(bp);
        if (info.n_batch > 0) {
            const data = try r.vecData(bp);
            info.first_batch_off = try r.i64At(data);
            info.first_batch_meta = try r.i32At(data + 8);
            info.first_batch_body = try r.i64At(data + 16);
        }
    }
    if (info.version != 3 and info.version != 4) return error.Version;
    return info;
}

fn magicAt(raw: []const u8, i: usize) bool {
    if (i + 6 > raw.len) return false;
    return std.mem.eql(u8, raw[i..][0..6], magic);
}

fn writeStream(gpa: std.mem.Allocator, c: *const model.Columnar, out: *std.ArrayList(u8)) Error!void {
    const schema_meta = try messageBytes(gpa, c, 1, 0);
    defer gpa.free(schema_meta);
    try appendMeta(gpa, out, schema_meta);
    var di: usize = 0;
    var bi: usize = 0;
    while (bi < c.batches.items.len) : (bi += 1) {
        while (di < c.dicts.items.len and c.dicts.items[di].batch_index == bi) : (di += 1) {
            _ = try writeDictInto(gpa, c, out, c.dicts.items[di]);
        }
        _ = try writeBatchInto(gpa, c, out, bi);
    }
    while (di < c.dicts.items.len) : (di += 1) {
        _ = try writeDictInto(gpa, c, out, c.dicts.items[di]);
    }
    try le.appendU32(out, gpa, 0xFFFFFFFF);
    try le.appendU32(out, gpa, 0);
}

fn writeStreamTracked(
    gpa: std.mem.Allocator,
    c: *const model.Columnar,
    out: *std.ArrayList(u8),
    blocks_off: *std.ArrayList(i64),
    blocks_meta: *std.ArrayList(i32),
    blocks_body: *std.ArrayList(i64),
    blocks_kind: *std.ArrayList(u8),
) Error!void {
    const schema_meta = try messageBytes(gpa, c, 1, 0);
    defer gpa.free(schema_meta);
    try appendEncapsulated(gpa, out, schema_meta, &.{});
    var di: usize = 0;
    var bi: usize = 0;
    while (bi < c.batches.items.len) : (bi += 1) {
        while (di < c.dicts.items.len and c.dicts.items[di].batch_index == bi) : (di += 1) {
            try writeOne(gpa, c, out, blocks_off, blocks_meta, blocks_body, blocks_kind, true, di, 0);
        }
        try writeOne(gpa, c, out, blocks_off, blocks_meta, blocks_body, blocks_kind, false, 0, bi);
    }
    while (di < c.dicts.items.len) : (di += 1) {
        try writeOne(gpa, c, out, blocks_off, blocks_meta, blocks_body, blocks_kind, true, di, 0);
    }
    try le.appendU32(out, gpa, 0xFFFFFFFF);
    try le.appendU32(out, gpa, 0);
}

fn writeOne(
    gpa: std.mem.Allocator,
    c: *const model.Columnar,
    out: *std.ArrayList(u8),
    blocks_off: *std.ArrayList(i64),
    blocks_meta: *std.ArrayList(i32),
    blocks_body: *std.ArrayList(i64),
    blocks_kind: *std.ArrayList(u8),
    is_dict: bool,
    di: usize,
    bi: usize,
) Error!void {
    const start = out.items.len;
    const body_len: usize = if (is_dict) try writeDictInto(gpa, c, out, c.dicts.items[di]) else try writeBatchInto(gpa, c, out, bi);
    const wrote = out.items.len - start;
    try blocks_off.append(gpa, @intCast(start));
    try blocks_meta.append(gpa, @intCast(wrote - body_len));
    try blocks_body.append(gpa, @intCast(body_len));
    try blocks_kind.append(gpa, if (is_dict) 2 else 3);
}

fn messageBytes(gpa: std.mem.Allocator, c: *const model.Columnar, kind: u8, body_len: i64) Error![]u8 {
    var b = try fb.Builder.init(gpa);
    defer b.deinit();
    const header = try schema_fb.schemaToken(&b, c);
    const msg = try message(&b, kind, header, body_len);
    return try b.finish(gpa, msg);
}

fn message(b: *fb.Builder, kind: u8, header: usize, body_len: i64) Error!usize {
    b.startTable(5);
    try b.addU16(0, 4, 0);
    try b.addU8(1, kind, 0);
    try b.addOffset(2, header);
    try b.addI64(3, body_len, 0);
    return try b.endTable();
}

fn batchMessage(
    gpa: std.mem.Allocator,
    length: i64,
    nodes_l: []const i64,
    nodes_n: []const i64,
    boff: []const i64,
    blen: []const i64,
    variadic: []const i64,
    codec: ?model.Codec,
    body_len: i64,
    header_kind: u8,
    dict_id: i64,
    is_delta: bool,
) Error![]u8 {
    var b = try fb.Builder.init(gpa);
    defer b.deinit();
    const ntok = try b.writeI64Pairs(nodes_l, nodes_n);
    const btok = try b.writeI64Pairs(boff, blen);
    var ctok: ?usize = null;
    if (codec) |codec_v| {
        b.startTable(2);
        try b.addU8(0, @intFromEnum(codec_v), 0);
        ctok = try b.endTable();
    }
    var vtok: ?usize = null;
    if (variadic.len > 0) {
        var vals: std.ArrayList(u64) = .empty;
        defer vals.deinit(gpa);
        for (variadic) |v| try vals.append(gpa, @intCast(v));
        vtok = try b.writeU64Vec(vals.items);
    }
    b.startTable(5);
    try b.addI64(0, length, -1);
    try b.addOffset(1, ntok);
    try b.addOffset(2, btok);
    if (ctok) |t| try b.addOffset(3, t);
    if (vtok) |t| try b.addOffset(4, t);
    var header = try b.endTable();
    var hkind = header_kind;
    if (header_kind == 2) {
        b.startTable(3);
        try b.addI64(0, dict_id, -1);
        try b.addOffset(1, header);
        try b.addBool(2, is_delta, false);
        header = try b.endTable();
        hkind = 2;
    }
    const msg = try message(&b, hkind, header, body_len);
    return try b.finish(gpa, msg);
}

const Piece = struct {
    off: i64,
    len: i64,
    bytes: []const u8,
    owned: ?[]u8,
};

fn writeBatchInto(gpa: std.mem.Allocator, c: *const model.Columnar, out: *std.ArrayList(u8), bi: usize) Error!usize {
    const batch = c.batches.items[bi];
    var nodes_l: std.ArrayList(i64) = .empty;
    defer nodes_l.deinit(gpa);
    var nodes_n: std.ArrayList(i64) = .empty;
    defer nodes_n.deinit(gpa);
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(gpa);
    var variadic: std.ArrayList(i64) = .empty;
    defer variadic.deinit(gpa);
    var i: usize = 0;
    while (i < batch.n_col) : (i += 1) {
        const aid = c.batch_cols.items[batch.col_at + i];
        try emitArray(c, c.fields.items[c.arrays.items[aid].field], aid, false, &nodes_l, &nodes_n, &order, &variadic, 0);
    }
    const codec = if (batch.codec) |k| k else c.codec;
    return writePlanned(gpa, c, out, order.items, nodes_l.items, nodes_n.items, variadic.items, codec, batch.length, 3, -1, false);
}

fn writeDictInto(gpa: std.mem.Allocator, c: *const model.Columnar, out: *std.ArrayList(u8), d: model.Dict) Error!usize {
    var nodes_l: std.ArrayList(i64) = .empty;
    defer nodes_l.deinit(gpa);
    var nodes_n: std.ArrayList(i64) = .empty;
    defer nodes_n.deinit(gpa);
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(gpa);
    var variadic: std.ArrayList(i64) = .empty;
    defer variadic.deinit(gpa);
    const f = c.fields.items[c.arrays.items[d.array].field];
    try emitArray(c, f, d.array, true, &nodes_l, &nodes_n, &order, &variadic, 0);
    return writePlanned(gpa, c, out, order.items, nodes_l.items, nodes_n.items, variadic.items, c.codec, c.arrays.items[d.array].length, 2, d.id, d.is_delta);
}

fn writePlanned(
    gpa: std.mem.Allocator,
    c: *const model.Columnar,
    out: *std.ArrayList(u8),
    order: []const usize,
    nodes_l: []const i64,
    nodes_n: []const i64,
    variadic: []const i64,
    codec: ?model.Codec,
    length: i64,
    header_kind: u8,
    dict_id: i64,
    is_delta: bool,
) Error!usize {
    var boff: std.ArrayList(i64) = .empty;
    defer boff.deinit(gpa);
    var blen: std.ArrayList(i64) = .empty;
    defer blen.deinit(gpa);
    var pieces: std.ArrayList(Piece) = .empty;
    errdefer {
        for (pieces.items) |p| if (p.owned) |owned| gpa.free(owned);
        pieces.deinit(gpa);
    }
    var cursor: usize = 0;
    for (order) |id| {
        const src = c.buf(id);
        if (src.len == 0) {
            try boff.append(gpa, 0);
            try blen.append(gpa, 0);
            continue;
        }
        cursor = std.mem.alignForward(usize, cursor, 8);
        const owned: ?[]u8 = if (codec) |codec_v| try wrapCompress(gpa, codec_v, src) else null;
        const bytes: []const u8 = if (owned) |payload| payload else src;
        boff.append(gpa, @intCast(cursor)) catch |err| {
            if (owned) |payload| gpa.free(payload);
            return err;
        };
        blen.append(gpa, @intCast(bytes.len)) catch |err| {
            if (owned) |payload| gpa.free(payload);
            return err;
        };
        pieces.append(gpa, .{ .off = @intCast(cursor), .len = @intCast(bytes.len), .bytes = bytes, .owned = owned }) catch |err| {
            if (owned) |payload| gpa.free(payload);
            return err;
        };
        cursor += bytes.len;
    }
    const total = std.mem.alignForward(usize, cursor, 8);
    const meta = try batchMessage(gpa, length, nodes_l, nodes_n, boff.items, blen.items, variadic, codec, @intCast(total), header_kind, dict_id, is_delta);
    defer gpa.free(meta);
    try paint(gpa, out, meta, pieces.items, total);
    for (pieces.items) |p| if (p.owned) |owned| gpa.free(owned);
    pieces.deinit(gpa);
    return total;
}

fn paint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), meta: []const u8, pieces: []const Piece, total: usize) Error!void {
    var pad: usize = 0;
    if (meta.len % 8 != 0) pad = 8 - (meta.len % 8);
    // Spare 8 bytes so the end-of-stream word does not reallocate the body.
    try reserveHuge(gpa, out, out.items.len + 8 + meta.len + pad + total + 8);
    try le.appendU32(out, gpa, 0xFFFFFFFF);
    try le.appendU32(out, gpa, @intCast(meta.len + pad));
    try out.appendSlice(gpa, meta);
    try out.appendNTimes(gpa, 0, pad);
    if (total == 0) return;
    const body_at = out.items.len;
    out.resize(gpa, body_at + total) catch return error.OutOfMemory;
    var cursor = body_at;
    for (pieces) |p| {
        const at = body_at + @as(usize, @intCast(p.off));
        while (cursor < at) : (cursor += 1) out.items[cursor] = 0;
        const n: usize = @intCast(p.len);
        if (n > 0) @memcpy(out.items[at..][0..n], p.bytes);
        cursor = at + n;
    }
    while (cursor < body_at + total) : (cursor += 1) out.items[cursor] = 0;
}

fn wrapCompress(gpa: std.mem.Allocator, codec: model.Codec, raw: []const u8) Error![]u8 {
    const comp = switch (codec) {
        .lz4 => try lz4.compress(gpa, raw),
        .zstd => try zstd.compress(gpa, raw),
    };
    defer gpa.free(comp);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (comp.len >= raw.len) {
        try le.appendI64(&out, gpa, -1);
        try out.appendSlice(gpa, raw);
    } else {
        try le.appendI64(&out, gpa, @intCast(raw.len));
        try out.appendSlice(gpa, comp);
    }
    return out.toOwnedSlice(gpa);
}

fn appendMeta(gpa: std.mem.Allocator, out: *std.ArrayList(u8), meta: []const u8) Error!void {
    try appendEncapsulated(gpa, out, meta, &.{});
}

fn appendEncapsulated(gpa: std.mem.Allocator, out: *std.ArrayList(u8), meta: []const u8, body: []const u8) Error!void {
    var pad: usize = 0;
    if (meta.len % 8 != 0) pad = 8 - (meta.len % 8);
    out.ensureTotalCapacityPrecise(gpa, out.items.len + 8 + meta.len + pad + body.len) catch return error.OutOfMemory;
    try le.appendU32(out, gpa, 0xFFFFFFFF);
    try le.appendU32(out, gpa, @intCast(meta.len + pad));
    try out.appendSlice(gpa, meta);
    try out.appendNTimes(gpa, 0, pad);
    try out.appendSlice(gpa, body);
}

fn emitArray(
    c: *const model.Columnar,
    f: model.Field,
    aid: usize,
    as_values: bool,
    nodes_l: *std.ArrayList(i64),
    nodes_n: *std.ArrayList(i64),
    order: *std.ArrayList(usize),
    variadic: *std.ArrayList(i64),
    depth: usize,
) Error!void {
    if (depth > model.max_depth) return error.Depth;
    const a = c.arrays.items[aid];
    const gpa = c.gpa;
    if (f.dict_id >= 0 and !as_values) {
        try nodes_l.append(gpa, a.length);
        try nodes_n.append(gpa, a.null_count);
        var i: usize = 0;
        while (i < a.n_buf) : (i += 1) try order.append(gpa, c.abufs.items[a.buf_at + i]);
        return;
    }
    try nodes_l.append(gpa, a.length);
    try nodes_n.append(gpa, a.null_count);
    const local = model.localBufs(f);
    var i: usize = 0;
    while (i < local and i < a.n_buf) : (i += 1) try order.append(gpa, c.abufs.items[a.buf_at + i]);
    if (model.isVariadic(f.kind)) {
        const extra: i64 = @intCast(a.n_buf - local);
        try variadic.append(gpa, extra);
        while (i < a.n_buf) : (i += 1) try order.append(gpa, c.abufs.items[a.buf_at + i]);
    }
    var ch: usize = 0;
    while (ch < a.n_child and ch < f.n_child) : (ch += 1) {
        const cf = c.fields.items[c.kids.items[f.child_at + ch]];
        try emitArray(c, cf, c.achilds.items[a.child_at + ch], false, nodes_l, nodes_n, order, variadic, depth + 1);
    }
}

fn footerBytes(
    gpa: std.mem.Allocator,
    c: *const model.Columnar,
    blocks_off: []const i64,
    blocks_meta: []const i32,
    blocks_body: []const i64,
    blocks_kind: []const u8,
) Error![]u8 {
    var b = try fb.Builder.init(gpa);
    defer b.deinit();
    const schema = try schema_fb.schemaToken(&b, c);
    const dicts = try blockVec(&b, gpa, blocks_off, blocks_meta, blocks_body, blocks_kind, 2);
    const batches = try blockVec(&b, gpa, blocks_off, blocks_meta, blocks_body, blocks_kind, 3);
    b.startTable(5);
    try b.addU16(0, 4, 0);
    try b.addOffset(1, schema);
    try b.addOffset(2, dicts);
    try b.addOffset(3, batches);
    const footer = try b.endTable();
    const raw = try b.finish(gpa, footer);
    if (raw.len % 8 == 0) return raw;
    const padded = gpa.alloc(u8, raw.len + (8 - raw.len % 8)) catch return error.OutOfMemory;
    @memcpy(padded[0..raw.len], raw);
    @memset(padded[raw.len..], 0);
    gpa.free(raw);
    return padded;
}

fn blockVec(
    b: *fb.Builder,
    gpa: std.mem.Allocator,
    blocks_off: []const i64,
    blocks_meta: []const i32,
    blocks_body: []const i64,
    blocks_kind: []const u8,
    want: u8,
) Error!usize {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var i: usize = 0;
    while (i < blocks_off.len) : (i += 1) {
        if (blocks_kind[i] != want) continue;
        try le.appendI64(&raw, gpa, blocks_off[i]);
        var meta_b: [4]u8 = undefined;
        std.mem.writeInt(u32, &meta_b, @bitCast(blocks_meta[i]), .little);
        try raw.appendSlice(gpa, &meta_b);
        try raw.appendNTimes(gpa, 0, 4);
        try le.appendI64(&raw, gpa, blocks_body[i]);
    }
    return try b.writeStructVec(raw.items, 24);
}

fn ingest(c: *model.Columnar, raw: []const u8, begin: usize, end: usize) Error!void {
    var i = begin;
    while (i + 4 <= end) {
        const word = le.readU32(raw, i) catch return error.EndOfBuffer;
        if (word == 0) return;
        var mlen: u32 = undefined;
        var meta_at: usize = undefined;
        if (word == 0xFFFFFFFF) {
            if (i + 8 > end) return error.EndOfBuffer;
            mlen = le.readU32(raw, i + 4) catch return error.EndOfBuffer;
            if (mlen == 0) return;
            meta_at = i + 8;
        } else {
            mlen = word;
            meta_at = i + 4;
        }
        if (meta_at + mlen > end) return error.Range;
        const meta = raw[meta_at .. meta_at + mlen];
        const r = fb.Reader{ .data = meta };
        const table = try r.root();
        var ver: u16 = 4;
        if (try r.field(table, 0)) |p| ver = try r.u16At(p);
        if (ver != 3 and ver != 4) return error.Version;
        const ht = (try r.field(table, 1)) orelse return error.Syntax;
        const hd = (try r.field(table, 2)) orelse return error.Syntax;
        const hkind = try r.u8At(ht);
        const header = try r.follow(hd);
        var body_len: i64 = 0;
        if (try r.field(table, 3)) |p| body_len = try r.i64At(p);
        const body_at = meta_at + mlen;
        if (body_len < 0 or body_at + @as(usize, @intCast(body_len)) > end) return error.Range;
        const body = raw[body_at .. body_at + @as(usize, @intCast(body_len))];
        if (hkind == 1) {
            try schema_fb.decodeSchema(r, header, c);
        } else if (hkind == 2) {
            try readDictionary(c, r, header, body);
        } else if (hkind == 3) {
            try readBatch(c, r, header, body);
        } else if (hkind == 4 or hkind == 5) {
            try tensor.readTensor(c, r, header, body, hkind == 5);
        } else return error.BadType;
        i = body_at + @as(usize, @intCast(body_len));
    }
}

const State = struct {
    node_l: std.ArrayList(i64) = .empty,
    node_n: std.ArrayList(i64) = .empty,
    buf_off: std.ArrayList(i64) = .empty,
    buf_len: std.ArrayList(i64) = .empty,
    variadic: std.ArrayList(i64) = .empty,
    node_i: usize = 0,
    buf_i: usize = 0,
    var_i: usize = 0,
    codec: ?model.Codec = null,
    direct_ext: i32 = -1,

    fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.node_l.deinit(gpa);
        self.node_n.deinit(gpa);
        self.buf_off.deinit(gpa);
        self.buf_len.deinit(gpa);
        self.variadic.deinit(gpa);
    }
};

fn loadBatch(r: fb.Reader, table: usize, st: *State, gpa: std.mem.Allocator) Error!void {
    if (try r.field(table, 1)) |np| {
        const n = try r.vecLen(np);
        const data = try r.vecData(np);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try st.node_l.append(gpa, try r.i64At(data + i * 16));
            try st.node_n.append(gpa, try r.i64At(data + i * 16 + 8));
        }
    }
    if (try r.field(table, 2)) |bp| {
        const n = try r.vecLen(bp);
        const data = try r.vecData(bp);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try st.buf_off.append(gpa, try r.i64At(data + i * 16));
            try st.buf_len.append(gpa, try r.i64At(data + i * 16 + 8));
        }
    }
    if (try r.field(table, 3)) |cp| {
        const comp = try r.follow(cp);
        var codec_b: u8 = 0;
        if (try r.field(comp, 0)) |cpos| codec_b = try r.u8At(cpos);
        st.codec = std.enums.fromInt(model.Codec, codec_b) orelse return error.Compression;
    }
    if (try r.field(table, 4)) |vp| {
        const n = try r.vecLen(vp);
        const data = try r.vecData(vp);
        var i: usize = 0;
        while (i < n) : (i += 1) try st.variadic.append(gpa, try r.i64At(data + i * 8));
    }
}

fn readDictionary(c: *model.Columnar, r: fb.Reader, table: usize, body: []const u8) Error!void {
    var id: i64 = 0;
    if (try r.field(table, 0)) |ip| id = try r.i64At(ip);
    var delta = false;
    if (try r.field(table, 2)) |dp| delta = (try r.u8At(dp)) != 0;
    const bp = (try r.field(table, 1)) orelse return error.Schema;
    const field_id = try fieldForDict(c, id);
    const aid = try readOneArray(c, r, try r.follow(bp), body, field_id, true);
    try c.addDict(.{ .id = id, .array = aid, .is_delta = delta, .batch_index = c.batches.items.len });
}

fn fieldForDict(c: *const model.Columnar, id: i64) Error!usize {
    for (c.fields.items, 0..) |f, i| {
        if (f.dict_id == id) return i;
    }
    return error.Schema;
}

fn readBatch(c: *model.Columnar, r: fb.Reader, table: usize, body: []const u8) Error!void {
    var length: i64 = 0;
    if (try r.field(table, 0)) |lp| length = try r.i64At(lp);
    var st = State{};
    defer st.deinit(c.gpa);
    try loadBatch(r, table, &st, c.gpa);
    try reserveUncompressed(c, &st, body);
    var cols: std.ArrayList(usize) = .empty;
    defer cols.deinit(c.gpa);
    for (c.top.items) |fid| {
        const aid = try readArrayState(c, body, fid, false, &st, 0);
        try cols.append(c.gpa, aid);
    }
    const codec = st.codec;
    try c.addBatch(length, cols.items, codec);
    if (codec != null) {
        c.codec = codec;
        c.features |= 2;
    }
}

fn readOneArray(c: *model.Columnar, r: fb.Reader, batch_table: usize, body: []const u8, field_id: usize, as_values: bool) Error!usize {
    var st = State{};
    defer st.deinit(c.gpa);
    try loadBatch(r, batch_table, &st, c.gpa);
    try reserveUncompressed(c, &st, body);
    return readArrayState(c, body, field_id, as_values, &st, 0);
}

fn reserveUncompressed(c: *model.Columnar, st: *State, body: []const u8) Error!void {
    if (st.codec != null or c.endian != 0 or body.len == 0) return;
    // The body stays in the caller's stream. Buffer views point into that slice.
    st.direct_ext = try c.addBorrow(body);
}

fn readArrayState(
    c: *model.Columnar,
    body: []const u8,
    field_id: usize,
    as_values: bool,
    st: *State,
    depth: usize,
) Error!usize {
    if (depth > model.max_depth) return error.Depth;
    if (st.node_i >= st.node_l.items.len) return error.Schema;
    const f = c.fields.items[field_id];
    const length = st.node_l.items[st.node_i];
    const null_count = st.node_n.items[st.node_i];
    st.node_i += 1;
    var a = model.Array{
        .field = field_id,
        .length = length,
        .null_count = null_count,
        .buf_at = c.abufs.items.len,
        .n_buf = 0,
        .child_at = 0,
        .n_child = 0,
    };
    if (f.dict_id >= 0 and !as_values) {
        try takeN(c, body, st, 2, 0);
        a.n_buf = 2;
        a.dict = latestDict(c, f.dict_id);
        c.arrays.append(c.gpa, a) catch return error.OutOfMemory;
        return c.arrays.items.len - 1;
    }
    const local = model.localBufs(f);
    var swap_w: usize = 0;
    if (c.endian != 0) swap_w = model.byteWidth(f);
    try takeN(c, body, st, local, swap_w);
    var extra: usize = 0;
    if (model.isVariadic(f.kind)) {
        if (st.var_i >= st.variadic.items.len) return error.Schema;
        const n = st.variadic.items[st.var_i];
        st.var_i += 1;
        if (n < 0) return error.Schema;
        extra = @intCast(n);
        try takeN(c, body, st, extra, 0);
    }
    a.n_buf = local + extra;
    var direct: std.ArrayList(usize) = .empty;
    defer direct.deinit(c.gpa);
    var ch: usize = 0;
    while (ch < f.n_child) : (ch += 1) {
        const child = try readArrayState(c, body, c.kids.items[f.child_at + ch], false, st, depth + 1);
        try direct.append(c.gpa, child);
    }
    a.child_at = c.achilds.items.len;
    c.achilds.appendSlice(c.gpa, direct.items) catch return error.OutOfMemory;
    a.n_child = direct.items.len;
    c.arrays.append(c.gpa, a) catch return error.OutOfMemory;
    return c.arrays.items.len - 1;
}

fn latestDict(c: *const model.Columnar, id: i64) i64 {
    var i: isize = @as(isize, @intCast(c.dicts.items.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const d = c.dicts.items[@intCast(i)];
        if (d.id == id and !d.is_delta) return @intCast(d.array);
    }
    i = @as(isize, @intCast(c.dicts.items.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const d = c.dicts.items[@intCast(i)];
        if (d.id == id) return @intCast(d.array);
    }
    return -1;
}

fn takeN(c: *model.Columnar, body: []const u8, st: *State, n: usize, swap_w: usize) Error!void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (st.buf_i >= st.buf_off.items.len) return error.Schema;
        const off = st.buf_off.items[st.buf_i];
        const ln = st.buf_len.items[st.buf_i];
        st.buf_i += 1;
        if (st.direct_ext >= 0) {
            if (ln == 0) {
                const id = try c.addEmptyBuf();
                c.abufs.append(c.gpa, id) catch return error.OutOfMemory;
            } else {
                if (off < 0 or ln < 0) return error.Range;
                const abs_off: usize = @intCast(off);
                const abs_len: usize = @intCast(ln);
                if (abs_off + abs_len > body.len) return error.Range;
                const id = try c.addBorrowedBuf(st.direct_ext, abs_off, abs_len);
                c.abufs.append(c.gpa, id) catch return error.OutOfMemory;
            }
            continue;
        }
        if (ln == 0) {
            const id = try c.addEmptyBuf();
            c.abufs.append(c.gpa, id) catch return error.OutOfMemory;
            continue;
        }
        if (off < 0 or ln < 0) return error.Range;
        const abs_off: usize = @intCast(off);
        const abs_len: usize = @intCast(ln);
        if (abs_off + abs_len > body.len) return error.Range;
        var slice: []const u8 = body[abs_off..][0..abs_len];
        var heap: ?[]u8 = null;
        defer if (heap) |p| c.gpa.free(p);
        if (st.codec) |codec| {
            heap = try decompressBuf(c.gpa, codec, slice);
            slice = heap.?;
        }
        if (swap_w > 1 and i == 1 and slice.len > 0) {
            if (heap == null) {
                heap = c.gpa.dupe(u8, slice) catch return error.OutOfMemory;
                slice = heap.?;
            }
            model.swapFixed(heap.?, swap_w);
            slice = heap.?;
        }
        const id = try c.addBuf(slice);
        c.abufs.append(c.gpa, id) catch return error.OutOfMemory;
    }
}

fn decompressBuf(gpa: std.mem.Allocator, codec: model.Codec, chunk: []const u8) Error![]u8 {
    if (chunk.len < 8) return error.Compression;
    const un = le.readI64(chunk, 0) catch return error.Compression;
    const rest = chunk[8..];
    if (un < 0) return gpa.dupe(u8, rest) catch error.OutOfMemory;
    const got = switch (codec) {
        .lz4 => try lz4.decompress(gpa, rest),
        .zstd => try zstd.decompress(gpa, rest),
    };
    if (got.len != @as(usize, @intCast(un))) {
        gpa.free(got);
        return error.Compression;
    }
    return got;
}

test "ipc nulls roundtrip and footer" {
    const gpa = std.testing.allocator;
    var c = model.Columnar.init(gpa);
    defer c.deinit();
    var f = model.Field{};
    f.name = @intCast(try c.intern("a"));
    f.kind = .int;
    f.bit_width = 32;
    f.is_signed = true;
    const fid = try c.addField(f);
    try c.addTop(fid);
    const bm = [_]u8{0b00000101};
    var vals: [12]u8 = undefined;
    std.mem.writeInt(i32, vals[0..4], 1, .little);
    std.mem.writeInt(i32, vals[4..8], 0, .little);
    std.mem.writeInt(i32, vals[8..12], 3, .little);
    const arr = try c.addArray(3, 1, fid, &.{ &bm, &vals }, &.{});
    try c.addBatch(3, &.{arr}, null);
    const stream = try encodeStream(gpa, &c);
    defer gpa.free(stream);
    const again = try encodeStream(gpa, &c);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, stream, again);
    var back = try decodeStream(gpa, stream);
    defer back.deinit();
    try std.testing.expectEqual(@as(i64, 3), back.arrays.items[0].length);
    try std.testing.expectEqual(@as(i64, 1), back.arrays.items[0].null_count);
    const got = back.arrayBuf(0, 1);
    try std.testing.expectEqual(@as(i64, 1), try model.readInt(got, 0, 4, true));
    try std.testing.expectEqual(@as(i64, 3), try model.readInt(got, 8, 4, true));
    const file = try encodeFile(gpa, &c);
    defer gpa.free(file);
    try std.testing.expect(std.mem.startsWith(u8, file, "ARROW1"));
    try std.testing.expect(std.mem.endsWith(u8, file, "ARROW1"));
    const info = try readFooter(file);
    try std.testing.expectEqual(@as(u16, 4), info.version);
    try std.testing.expectEqual(@as(usize, 1), info.n_fields);
    try std.testing.expectEqual(@as(usize, 1), info.n_batch);
    try std.testing.expect(info.first_batch_off >= 8);
    var from_file = try decodeFile(gpa, file);
    defer from_file.deinit();
    try std.testing.expectEqualStrings("a", from_file.str(@intCast(from_file.fields.items[from_file.top.items[0]].name)));
    try std.testing.expectEqual(@as(i64, 3), try model.readInt(from_file.arrayBuf(0, 1), 8, 4, true));
}
