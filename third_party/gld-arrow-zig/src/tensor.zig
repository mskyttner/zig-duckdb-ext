const std = @import("std");
const fb = @import("flatbuf.zig");
const le = @import("le.zig");
const model = @import("model.zig");
const schema_fb = @import("schema_fb.zig");

const Error = model.Error;

pub fn readTensor(c: *model.Columnar, r: fb.Reader, header: usize, body: []const u8, sparse: bool) Error!void {
    if (sparse) try readSparse(c, r, header, body) else try readDense(c, r, header, body);
}

pub fn encodeTensorStream(gpa: std.mem.Allocator, c: *const model.Columnar) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (c.tensors.items, 0..) |_, i| {
        const msg = try encodeOne(gpa, c, i);
        defer gpa.free(msg);
        try out.appendSlice(gpa, msg);
    }
    return out.toOwnedSlice(gpa);
}

fn readDense(c: *model.Columnar, r: fb.Reader, header: usize, body: []const u8) Error!void {
    var t = model.Tensor{
        .field = try tensorType(c, r, header),
        .shape_at = 0,
        .n_shape = 0,
        .stride_at = 0,
        .n_stride = 0,
        .data_buf = 0,
        .sparse = 0,
    };
    try readShape(c, r, header, &t);
    if (try r.field(header, 3)) |sp| {
        t.stride_at = c.strides.items.len;
        const n = try r.vecLen(sp);
        const data = try r.vecData(sp);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            c.strides.append(c.gpa, try r.i64At(data + i * 8)) catch return error.OutOfMemory;
        }
        t.n_stride = n;
    } else try rowMajor(c, &t);
    const dp = (try r.field(header, 4)) orelse return error.Schema;
    t.data_buf = try copyStructBuf(c, r, dp, body);
    c.tensors.append(c.gpa, t) catch return error.OutOfMemory;
}

fn readSparse(c: *model.Columnar, r: fb.Reader, header: usize, body: []const u8) Error!void {
    var t = model.Tensor{
        .field = try tensorType(c, r, header),
        .shape_at = 0,
        .n_shape = 0,
        .stride_at = 0,
        .n_stride = 0,
        .data_buf = 0,
    };
    try readShape(c, r, header, &t);
    if (try r.field(header, 3)) |nz| t.nz = try r.i64At(nz);
    const kt = (try r.field(header, 4)) orelse return error.Schema;
    const kp = (try r.field(header, 5)) orelse return error.Schema;
    const kind = try r.u8At(kt);
    const idx = try r.follow(kp);
    t.sparse = kind;
    if (kind == 1) try readCoo(c, r, idx, body, &t) else if (kind == 2) try readCsx(c, r, idx, body, &t) else if (kind == 3) try readCsf(c, r, idx, body, &t) else return error.BadType;
    const dp = (try r.field(header, 6)) orelse return error.Schema;
    t.data_buf = try copyStructBuf(c, r, dp, body);
    c.tensors.append(c.gpa, t) catch return error.OutOfMemory;
}

fn tensorType(c: *model.Columnar, r: fb.Reader, header: usize) Error!usize {
    const tp = (try r.field(header, 0)) orelse return error.BadType;
    const tt = (try r.field(header, 1)) orelse return error.BadType;
    var f = model.Field{};
    f.kind = try schema_fb.kindFromCode(try r.u8At(tp));
    f.nullable = false;
    try schema_fb.readType(r, try r.follow(tt), &f, c);
    return c.addField(f);
}

fn readShape(c: *model.Columnar, r: fb.Reader, header: usize, t: *model.Tensor) Error!void {
    const sp = (try r.field(header, 2)) orelse return error.Schema;
    const n = try r.vecLen(sp);
    const data = try r.vecData(sp);
    t.shape_at = c.shapes.items.len;
    t.n_shape = n;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rel = try r.u32At(data + i * 4);
        const dim = data + i * 4 + rel;
        const sz = (try r.field(dim, 0)) orelse return error.Schema;
        c.shapes.append(c.gpa, try r.i64At(sz)) catch return error.OutOfMemory;
        if (try r.field(dim, 1)) |nm| {
            const text = try r.string(nm);
            c.shape_names.append(c.gpa, @intCast(try c.intern(text))) catch return error.OutOfMemory;
        } else c.shape_names.append(c.gpa, -1) catch return error.OutOfMemory;
    }
}

fn rowMajor(c: *model.Columnar, t: *model.Tensor) Error!void {
    var width: i64 = @intCast(model.byteWidth(c.fields.items[t.field]));
    if (width <= 0) width = 1;
    t.stride_at = c.strides.items.len;
    t.n_stride = t.n_shape;
    var prod = width;
    var i: isize = @as(isize, @intCast(t.n_shape)) - 1;
    while (i >= 0) : (i -= 1) {
        c.strides.append(c.gpa, prod) catch return error.OutOfMemory;
        prod *= c.shapes.items[t.shape_at + @as(usize, @intCast(i))];
    }
    var tmp: std.ArrayList(i64) = .empty;
    defer tmp.deinit(c.gpa);
    var k: usize = 0;
    while (k < t.n_stride) : (k += 1) {
        try tmp.append(c.gpa, c.strides.items[t.stride_at + t.n_stride - 1 - k]);
    }
    for (tmp.items, 0..) |v, n| c.strides.items[t.stride_at + n] = v;
}

fn copyStructBuf(c: *model.Columnar, r: fb.Reader, pos: usize, body: []const u8) Error!usize {
    const off = try r.i64At(pos);
    const ln = try r.i64At(pos + 8);
    if (ln == 0) return c.addEmptyBuf();
    if (off < 0 or ln < 0) return error.Range;
    const uoff: usize = @intCast(off);
    const uln: usize = @intCast(ln);
    if (uoff + uln > body.len) return error.Range;
    return c.addBuf(body[uoff..][0..uln]);
}

fn readIntType(r: fb.Reader, table: usize, width: *i32, signed: *bool) Error!void {
    if (try r.field(table, 0)) |w| width.* = try r.i32At(w);
    if (try r.field(table, 1)) |s| {
        signed.* = (try r.u8At(s)) != 0;
    } else signed.* = false;
}

fn readCoo(c: *model.Columnar, r: fb.Reader, table: usize, body: []const u8, t: *model.Tensor) Error!void {
    const tp = (try r.field(table, 0)) orelse return error.Schema;
    try readIntType(r, try r.follow(tp), &t.index_width, &t.index_signed);
    const bp = (try r.field(table, 2)) orelse return error.Schema;
    t.index_at = c.abufs.items.len;
    const id = try copyStructBuf(c, r, bp, body);
    c.abufs.append(c.gpa, id) catch return error.OutOfMemory;
    t.n_index = 1;
    if (try r.field(table, 3)) |flag| t.coo_canonical = (try r.u8At(flag)) != 0;
}

fn readCsx(c: *model.Columnar, r: fb.Reader, table: usize, body: []const u8, t: *model.Tensor) Error!void {
    if (try r.field(table, 0)) |ax| t.csx_axis = try r.u16At(ax);
    const ip = (try r.field(table, 1)) orelse return error.Schema;
    try readIntType(r, try r.follow(ip), &t.index_width, &t.index_signed);
    const ib = (try r.field(table, 2)) orelse return error.Schema;
    const xb = (try r.field(table, 4)) orelse return error.Schema;
    t.index_at = c.abufs.items.len;
    const a = try copyStructBuf(c, r, ib, body);
    const b = try copyStructBuf(c, r, xb, body);
    c.abufs.append(c.gpa, a) catch return error.OutOfMemory;
    c.abufs.append(c.gpa, b) catch return error.OutOfMemory;
    t.n_index = 2;
}

fn readCsf(c: *model.Columnar, r: fb.Reader, table: usize, body: []const u8, t: *model.Tensor) Error!void {
    const ip = (try r.field(table, 0)) orelse return error.Schema;
    try readIntType(r, try r.follow(ip), &t.index_width, &t.index_signed);
    t.index_at = c.abufs.items.len;
    var n: usize = 0;
    if (try r.field(table, 1)) |pb| n += try readBufVec(c, r, pb, body);
    if (try r.field(table, 3)) |ib| n += try readBufVec(c, r, ib, body);
    t.n_index = n;
    if (try r.field(table, 4)) |ao| {
        const nv = try r.vecLen(ao);
        const data = try r.vecData(ao);
        const start = c.strides.items.len;
        var i: usize = 0;
        while (i < nv) : (i += 1) {
            c.strides.append(c.gpa, try r.i32At(data + i * 4)) catch return error.OutOfMemory;
        }
        if (t.n_stride == 0) {
            t.stride_at = start;
            t.n_stride = nv;
        }
    }
}

fn readBufVec(c: *model.Columnar, r: fb.Reader, pos: usize, body: []const u8) Error!usize {
    const n = try r.vecLen(pos);
    const data = try r.vecData(pos);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const id = try copyStructBuf(c, r, data + i * 16, body);
        c.abufs.append(c.gpa, id) catch return error.OutOfMemory;
    }
    return n;
}

const OffLen = struct { off: i64, len: i64 };

fn appendBody(gpa: std.mem.Allocator, body: *std.ArrayList(u8), c: *const model.Columnar, buf: usize) Error!OffLen {
    while (body.items.len % 8 != 0) try body.append(gpa, 0);
    const off: i64 = @intCast(body.items.len);
    const src = c.buf(buf);
    try body.appendSlice(gpa, src);
    return .{ .off = off, .len = @intCast(src.len) };
}

fn encodeOne(gpa: std.mem.Allocator, c: *const model.Columnar, index: usize) Error![]u8 {
    const t = c.tensors.items[index];
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const data_loc = try appendBody(gpa, &body, c, t.data_buf);
    var index_locs: std.ArrayList(OffLen) = .empty;
    defer index_locs.deinit(gpa);
    var i: usize = 0;
    while (i < t.n_index) : (i += 1) {
        const loc = try appendBody(gpa, &body, c, c.abufs.items[t.index_at + i]);
        try index_locs.append(gpa, loc);
    }
    while (body.items.len % 8 != 0) try body.append(gpa, 0);
    var b = try fb.Builder.init(gpa);
    defer b.deinit();
    const f = c.fields.items[t.field];
    const ty = try schema_fb.typeTable(&b, c, f);
    const shape = try shapeVec(&b, c, t);
    var strides: ?usize = null;
    if (t.n_stride > 0 and t.sparse == 0) {
        var vals: std.ArrayList(u64) = .empty;
        defer vals.deinit(gpa);
        var k: usize = 0;
        while (k < t.n_stride) : (k += 1) try vals.append(gpa, @bitCast(c.strides.items[t.stride_at + k]));
        strides = try b.writeU64Vec(vals.items);
    }
    if (t.sparse == 0) {
        b.startTable(5);
        try b.addU8(0, @intFromEnum(f.kind), 0);
        try b.addOffset(1, ty);
        try b.addOffset(2, shape);
        if (strides) |s| try b.addOffset(3, s);
        try b.addI64Pair(4, data_loc.off, data_loc.len);
        return try wrap(&b, gpa, 4, try b.endTable(), body.items);
    }
    const index_tok = try sparseIndex(&b, gpa, c, t, index_locs.items);
    b.startTable(7);
    try b.addU8(0, @intFromEnum(f.kind), 0);
    try b.addOffset(1, ty);
    try b.addOffset(2, shape);
    try b.addI64(3, t.nz, -1);
    try b.addU8(4, t.sparse, 0);
    try b.addOffset(5, index_tok);
    try b.addI64Pair(6, data_loc.off, data_loc.len);
    return try wrap(&b, gpa, 5, try b.endTable(), body.items);
}

fn shapeVec(b: *fb.Builder, c: *const model.Columnar, t: model.Tensor) Error!usize {
    var offs: std.ArrayList(usize) = .empty;
    defer offs.deinit(b.gpa);
    var i: usize = 0;
    while (i < t.n_shape) : (i += 1) {
        var name: ?usize = null;
        if (t.shape_at + i < c.shape_names.items.len) {
            const ni = c.shape_names.items[t.shape_at + i];
            if (ni >= 0) name = try b.writeString(c.str(@intCast(ni)));
        }
        b.startTable(2);
        try b.addI64(0, c.shapes.items[t.shape_at + i], -1);
        if (name) |n| try b.addOffset(1, n);
        try offs.append(b.gpa, try b.endTable());
    }
    return try b.writeOffsetVec(offs.items);
}

fn wrap(b: *fb.Builder, gpa: std.mem.Allocator, kind: u8, header: usize, body: []const u8) Error![]u8 {
    b.startTable(5);
    try b.addU16(0, 4, 0);
    try b.addU8(1, kind, 0);
    try b.addOffset(2, header);
    try b.addI64(3, @intCast(body.len), 0);
    var meta = try b.finish(gpa, try b.endTable());
    defer gpa.free(meta);
    if (meta.len % 8 != 0) {
        const padded = gpa.alloc(u8, meta.len + (8 - meta.len % 8)) catch return error.OutOfMemory;
        @memcpy(padded[0..meta.len], meta);
        @memset(padded[meta.len..], 0);
        gpa.free(meta);
        meta = padded;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try le.appendU32(&out, gpa, 0xFFFFFFFF);
    try le.appendU32(&out, gpa, @intCast(meta.len));
    try out.appendSlice(gpa, meta);
    try out.appendSlice(gpa, body);
    return out.toOwnedSlice(gpa);
}

fn sparseIndex(b: *fb.Builder, gpa: std.mem.Allocator, c: *const model.Columnar, t: model.Tensor, locs: []const OffLen) Error!usize {
    b.startTable(2);
    try b.addI32(0, t.index_width, 0);
    try b.addBool(1, t.index_signed, false);
    const itype = try b.endTable();
    if (t.sparse == 1) {
        b.startTable(4);
        try b.addOffset(0, itype);
        try b.addI64Pair(2, locs[0].off, locs[0].len);
        try b.addBool(3, t.coo_canonical, false);
        return try b.endTable();
    }
    if (t.sparse == 2) {
        b.startTable(5);
        try b.addU16(0, t.csx_axis, 0);
        try b.addOffset(1, itype);
        try b.addI64Pair(2, locs[0].off, locs[0].len);
        try b.addOffset(3, itype);
        try b.addI64Pair(4, locs[1].off, locs[1].len);
        return try b.endTable();
    }
    var raw_p: std.ArrayList(u8) = .empty;
    defer raw_p.deinit(gpa);
    const half = t.n_index / 2;
    var i: usize = 0;
    while (i < half) : (i += 1) {
        try le.appendI64(&raw_p, gpa, locs[i].off);
        try le.appendI64(&raw_p, gpa, locs[i].len);
    }
    const pvec = try b.writeStructVec(raw_p.items, 16);
    var raw_i: std.ArrayList(u8) = .empty;
    defer raw_i.deinit(gpa);
    while (i < t.n_index) : (i += 1) {
        try le.appendI64(&raw_i, gpa, locs[i].off);
        try le.appendI64(&raw_i, gpa, locs[i].len);
    }
    const ivec = try b.writeStructVec(raw_i.items, 16);
    var order: ?usize = null;
    if (t.n_stride > 0) {
        var vals: std.ArrayList(i32) = .empty;
        defer vals.deinit(gpa);
        var k: usize = 0;
        while (k < t.n_stride) : (k += 1) try vals.append(gpa, @intCast(c.strides.items[t.stride_at + k]));
        order = try b.writeI32Vec(vals.items);
    }
    b.startTable(5);
    try b.addOffset(0, itype);
    try b.addOffset(1, pvec);
    try b.addOffset(2, itype);
    try b.addOffset(3, ivec);
    if (order) |o| try b.addOffset(4, o);
    return try b.endTable();
}

test "dense tensor roundtrip" {
    const gpa = std.testing.allocator;
    var c = model.Columnar.init(gpa);
    defer c.deinit();
    var f = model.Field{};
    f.kind = .int;
    f.bit_width = 32;
    f.is_signed = true;
    f.nullable = false;
    const fid = try c.addField(f);
    var data: [24]u8 = undefined;
    var n: i32 = 0;
    while (n < 6) : (n += 1) std.mem.writeInt(i32, data[@intCast(n * 4)..][0..4], n, .little);
    const buf = try c.addBuf(&data);
    try c.shapes.appendSlice(gpa, &.{ 2, 3 });
    try c.shape_names.appendSlice(gpa, &.{ -1, -1 });
    try c.strides.appendSlice(gpa, &.{ 12, 4 });
    try c.tensors.append(gpa, .{
        .field = fid,
        .shape_at = 0,
        .n_shape = 2,
        .stride_at = 0,
        .n_stride = 2,
        .data_buf = buf,
    });
    const raw = try encodeTensorStream(gpa, &c);
    defer gpa.free(raw);
    var back = try @import("ipc.zig").decodeStream(gpa, raw);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 1), back.tensors.items.len);
    const t = back.tensors.items[0];
    try std.testing.expectEqual(@as(i64, 2), back.shapes.items[t.shape_at]);
    try std.testing.expectEqual(@as(i64, 3), back.shapes.items[t.shape_at + 1]);
    try std.testing.expectEqual(@as(i64, 12), back.strides.items[t.stride_at]);
    try std.testing.expectEqual(@as(i64, 4), back.strides.items[t.stride_at + 1]);
    const got = back.buf(t.data_buf);
    try std.testing.expectEqual(@as(i64, 0), try model.readInt(got, 0, 4, true));
    try std.testing.expectEqual(@as(i64, 5), try model.readInt(got, 20, 4, true));
}
