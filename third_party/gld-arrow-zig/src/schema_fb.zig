const std = @import("std");
const fb = @import("flatbuf.zig");
const model = @import("model.zig");

pub const Error = model.Error;

fn fail(err: fb.Error) Error {
    return err;
}

fn fld(r: fb.Reader, table: usize, id: usize) Error!?usize {
    return r.field(table, id) catch |e| fail(e);
}

fn fol(r: fb.Reader, pos: usize) Error!usize {
    return r.follow(pos) catch |e| fail(e);
}

pub fn kindFromCode(code: u8) Error!model.Kind {
    return std.enums.fromInt(model.Kind, code) orelse return error.BadType;
}

pub fn encodeSchema(gpa: std.mem.Allocator, c: *const model.Columnar) Error![]u8 {
    var b = fb.Builder.init(gpa) catch return error.OutOfMemory;
    defer b.deinit();
    const tok = try schemaToken(&b, c);
    return b.finish(gpa, tok) catch |e| fail(e);
}

pub fn schemaToken(b: *fb.Builder, c: *const model.Columnar) Error!usize {
    var offs: std.ArrayList(usize) = .empty;
    defer offs.deinit(b.gpa);
    for (c.top.items) |id| {
        const tok = try writeField(b, c, id);
        offs.append(b.gpa, tok) catch return error.OutOfMemory;
    }
    const fields = b.writeOffsetVec(offs.items) catch |e| return fail(e);
    const meta = try metaVec(b, c, c.schema_meta_at, c.n_schema_meta);
    var bits = c.features;
    if (c.codec != null) bits |= 2;
    for (c.batches.items) |batch| {
        if (batch.codec != null) bits |= 2;
    }
    const feats = try featuresToken(b, bits);
    b.startTable(4);
    if (c.endian != 0) b.addU16(0, c.endian, 0) catch |e| return fail(e);
    b.addOffset(1, fields) catch |e| return fail(e);
    if (meta) |m| b.addOffset(2, m) catch |e| return fail(e);
    if (feats) |m| b.addOffset(3, m) catch |e| return fail(e);
    return b.endTable() catch |e| fail(e);
}

fn featuresToken(b: *fb.Builder, bits: u64) Error!?usize {
    var vals: [2]u64 = undefined;
    var n: usize = 0;
    if ((bits & 1) != 0) {
        vals[n] = 1;
        n += 1;
    }
    if ((bits & 2) != 0) {
        vals[n] = 2;
        n += 1;
    }
    if (n == 0) return null;
    return b.writeU64Vec(vals[0..n]) catch |e| fail(e);
}

fn metaVec(b: *fb.Builder, c: *const model.Columnar, at: usize, n: usize) Error!?usize {
    if (n == 0) return null;
    var offs: std.ArrayList(usize) = .empty;
    defer offs.deinit(b.gpa);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const k = b.writeString(c.str(c.meta_k.items[at + i])) catch |e| return fail(e);
        const v = b.writeString(c.str(c.meta_v.items[at + i])) catch |e| return fail(e);
        b.startTable(2);
        b.addOffset(0, k) catch |e| return fail(e);
        b.addOffset(1, v) catch |e| return fail(e);
        const tok = b.endTable() catch |e| return fail(e);
        offs.append(b.gpa, tok) catch return error.OutOfMemory;
    }
    return b.writeOffsetVec(offs.items) catch |e| fail(e);
}

fn writeField(b: *fb.Builder, c: *const model.Columnar, id: usize) Error!usize {
    const f = c.fields.items[id];
    var name: ?usize = null;
    if (f.name >= 0) name = b.writeString(c.str(@intCast(f.name))) catch |e| return fail(e);
    const ty = try typeTable(b, c, f);
    const dict = try dictTable(b, f);
    var children: ?usize = null;
    if (f.n_child > 0) {
        var offs: std.ArrayList(usize) = .empty;
        defer offs.deinit(b.gpa);
        var i: usize = 0;
        while (i < f.n_child) : (i += 1) {
            const tok = try writeField(b, c, c.kids.items[f.child_at + i]);
            offs.append(b.gpa, tok) catch return error.OutOfMemory;
        }
        children = b.writeOffsetVec(offs.items) catch |e| return fail(e);
    }
    const meta = try metaVec(b, c, f.meta_at, f.n_meta);
    b.startTable(7);
    if (name) |n| b.addOffset(0, n) catch |e| return fail(e);
    b.addBool(1, f.nullable, false) catch |e| return fail(e);
    b.addU8(2, @intFromEnum(f.kind), 0) catch |e| return fail(e);
    b.addOffset(3, ty) catch |e| return fail(e);
    if (dict) |d| b.addOffset(4, d) catch |e| return fail(e);
    if (children) |ch| b.addOffset(5, ch) catch |e| return fail(e);
    if (meta) |m| b.addOffset(6, m) catch |e| return fail(e);
    return b.endTable() catch |e| fail(e);
}

fn dictTable(b: *fb.Builder, f: model.Field) Error!?usize {
    if (f.dict_id < 0) return null;
    b.startTable(2);
    b.addI32(0, f.dict_index_width, 0) catch |e| return fail(e);
    b.addBool(1, f.dict_index_signed, false) catch |e| return fail(e);
    const index = b.endTable() catch |e| return fail(e);
    b.startTable(4);
    b.addI64(0, f.dict_id, -1) catch |e| return fail(e);
    b.addOffset(1, index) catch |e| return fail(e);
    b.addBool(2, f.dict_ordered, false) catch |e| return fail(e);
    return b.endTable() catch |e| fail(e);
}

pub fn typeTable(b: *fb.Builder, c: *const model.Columnar, f: model.Field) Error!usize {
    switch (f.kind) {
        .int => {
            b.startTable(2);
            b.addI32(0, f.bit_width, 0) catch |e| return fail(e);
            b.addBool(1, f.is_signed, false) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .float => {
            b.startTable(1);
            b.addU16(0, f.unit, 0) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .decimal => {
            b.startTable(3);
            b.addI32(0, f.precision, 0) catch |e| return fail(e);
            b.addI32(1, f.scale, 0) catch |e| return fail(e);
            b.addI32(2, f.bit_width, 128) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .date => {
            b.startTable(1);
            b.addU16(0, f.unit, 1) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .time => {
            b.startTable(2);
            b.addU16(0, f.unit, 1) catch |e| return fail(e);
            b.addI32(1, f.bit_width, 32) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .timestamp => {
            var tz: ?usize = null;
            if (f.timezone >= 0) tz = b.writeString(c.str(@intCast(f.timezone))) catch |e| return fail(e);
            b.startTable(2);
            b.addU16(0, f.unit, 0) catch |e| return fail(e);
            if (tz) |t| b.addOffset(1, t) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .interval => {
            b.startTable(1);
            b.addU16(0, f.unit, 0) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .duration => {
            b.startTable(1);
            b.addU16(0, f.unit, 1) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .fixed_binary, .fixed_list => {
            b.startTable(1);
            b.addI32(0, f.fixed_size, 0) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .map => {
            b.startTable(1);
            b.addBool(0, f.keys_sorted, false) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        .@"union" => {
            var ids: ?usize = null;
            if (f.n_type_ids > 0) {
                ids = b.writeI32Vec(c.type_ids.items[f.type_ids_at..][0..f.n_type_ids]) catch |e| return fail(e);
            }
            b.startTable(2);
            b.addU16(0, f.union_mode, 0) catch |e| return fail(e);
            if (ids) |t| b.addOffset(1, t) catch |e| return fail(e);
            return b.endTable() catch |e| fail(e);
        },
        else => {
            b.startTable(0);
            return b.endTable() catch |e| fail(e);
        },
    }
}

pub fn decodeSchema(r: fb.Reader, table: usize, c: *model.Columnar) Error!void {
    if (try fld(r, table, 0)) |p| {
        c.endian = r.u16At(p) catch return error.EndOfBuffer;
    } else c.endian = 0;
    const fp = (try fld(r, table, 1)) orelse return error.Schema;
    const n = r.vecLen(fp) catch return error.Syntax;
    const data = r.vecData(fp) catch return error.Syntax;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rel = r.u32At(data + i * 4) catch return error.Syntax;
        const fid = try readField(r, data + i * 4 + rel, c, 0);
        try c.addTop(fid);
    }
    if (try fld(r, table, 2)) |mp| {
        c.schema_meta_at = c.meta_k.items.len;
        c.n_schema_meta = try readMeta(r, mp, c);
    }
    if (try fld(r, table, 3)) |feat| c.features = try readFeatures(r, feat);
}

fn readFeatures(r: fb.Reader, pos: usize) Error!u64 {
    const n = r.vecLen(pos) catch return error.Syntax;
    const data = r.vecData(pos) catch return error.Syntax;
    var bits: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = r.i64At(data + i * 8) catch return error.Syntax;
        if (v == 1 or v == 2) bits |= @intCast(v);
    }
    return bits;
}

fn readMeta(r: fb.Reader, pos: usize, c: *model.Columnar) Error!usize {
    const n = r.vecLen(pos) catch return error.Syntax;
    const data = r.vecData(pos) catch return error.Syntax;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rel = r.u32At(data + i * 4) catch return error.Syntax;
        const kv = data + i * 4 + rel;
        var key: []const u8 = "";
        var val: []const u8 = "";
        if (try fld(r, kv, 0)) |kp| key = r.string(kp) catch return error.Syntax;
        if (try fld(r, kv, 1)) |vp| val = r.string(vp) catch return error.Syntax;
        try c.addMeta(key, val);
    }
    return n;
}

fn readField(r: fb.Reader, table: usize, c: *model.Columnar, depth: usize) Error!usize {
    if (depth > model.max_depth) return error.Depth;
    var f = model.Field{};
    if (try fld(r, table, 0)) |np| {
        const text = r.string(np) catch return error.Syntax;
        f.name = @intCast(try c.intern(text));
    }
    if (try fld(r, table, 1)) |nul| {
        const b = r.u8At(nul) catch return error.EndOfBuffer;
        f.nullable = b != 0;
    } else f.nullable = false;
    const tp = (try fld(r, table, 2)) orelse return error.BadType;
    const code = r.u8At(tp) catch return error.EndOfBuffer;
    f.kind = try kindFromCode(code);
    const typ = (try fld(r, table, 3)) orelse return error.BadType;
    try readType(r, try fol(r, typ), &f, c);
    if (try fld(r, table, 4)) |dp| try readDict(r, try fol(r, dp), &f);
    const id = try c.addField(f);
    var direct: std.ArrayList(usize) = .empty;
    defer direct.deinit(c.gpa);
    if (try fld(r, table, 5)) |cp| {
        const n = r.vecLen(cp) catch return error.Syntax;
        const data = r.vecData(cp) catch return error.Syntax;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rel = r.u32At(data + i * 4) catch return error.Syntax;
            const child = try readField(r, data + i * 4 + rel, c, depth + 1);
            direct.append(c.gpa, child) catch return error.OutOfMemory;
        }
    }
    const start = c.kids.items.len;
    c.kids.appendSlice(c.gpa, direct.items) catch return error.OutOfMemory;
    const meta_at = c.meta_k.items.len;
    var nmeta: usize = 0;
    if (try fld(r, table, 6)) |mp| nmeta = try readMeta(r, mp, c);
    var stored = c.fields.items[id];
    stored.child_at = start;
    stored.n_child = direct.items.len;
    stored.meta_at = meta_at;
    stored.n_meta = nmeta;
    c.fields.items[id] = stored;
    return id;
}

fn readDict(r: fb.Reader, table: usize, f: *model.Field) Error!void {
    if (try fld(r, table, 0)) |ip| {
        f.dict_id = r.i64At(ip) catch return error.EndOfBuffer;
    } else f.dict_id = 0;
    if (try fld(r, table, 1)) |tp| {
        const it = try fol(r, tp);
        if (try fld(r, it, 0)) |w| f.dict_index_width = r.i32At(w) catch return error.EndOfBuffer;
        if (try fld(r, it, 1)) |s| {
            const b = r.u8At(s) catch return error.EndOfBuffer;
            f.dict_index_signed = b != 0;
        } else f.dict_index_signed = false;
    }
    if (try fld(r, table, 2)) |op| {
        const b = r.u8At(op) catch return error.EndOfBuffer;
        f.dict_ordered = b != 0;
    }
}

pub fn readType(r: fb.Reader, table: usize, f: *model.Field, c: *model.Columnar) Error!void {
    switch (f.kind) {
        .int => {
            const w = (try fld(r, table, 0)) orelse return error.BadType;
            f.bit_width = r.i32At(w) catch return error.EndOfBuffer;
            if (try fld(r, table, 1)) |s| {
                const b = r.u8At(s) catch return error.EndOfBuffer;
                f.is_signed = b != 0;
            } else f.is_signed = false;
        },
        .float => {
            if (try fld(r, table, 0)) |p| f.unit = r.u16At(p) catch return error.EndOfBuffer;
        },
        .decimal => {
            if (try fld(r, table, 0)) |p| f.precision = r.i32At(p) catch return error.EndOfBuffer;
            if (try fld(r, table, 1)) |s| f.scale = r.i32At(s) catch return error.EndOfBuffer;
            if (try fld(r, table, 2)) |w| {
                f.bit_width = r.i32At(w) catch return error.EndOfBuffer;
            } else f.bit_width = 128;
        },
        .date => {
            if (try fld(r, table, 0)) |u| {
                f.unit = r.u16At(u) catch return error.EndOfBuffer;
            } else f.unit = 1;
        },
        .time => {
            if (try fld(r, table, 0)) |u| {
                f.unit = r.u16At(u) catch return error.EndOfBuffer;
            } else f.unit = 1;
            if (try fld(r, table, 1)) |w| {
                f.bit_width = r.i32At(w) catch return error.EndOfBuffer;
            } else f.bit_width = 32;
        },
        .timestamp => {
            if (try fld(r, table, 0)) |u| f.unit = r.u16At(u) catch return error.EndOfBuffer;
            if (try fld(r, table, 1)) |z| {
                const text = r.string(z) catch return error.Syntax;
                f.timezone = @intCast(try c.intern(text));
            }
        },
        .interval => {
            if (try fld(r, table, 0)) |u| f.unit = r.u16At(u) catch return error.EndOfBuffer;
        },
        .duration => {
            if (try fld(r, table, 0)) |u| {
                f.unit = r.u16At(u) catch return error.EndOfBuffer;
            } else f.unit = 1;
        },
        .fixed_binary, .fixed_list => {
            if (try fld(r, table, 0)) |w| f.fixed_size = r.i32At(w) catch return error.EndOfBuffer;
        },
        .map => {
            if (try fld(r, table, 0)) |s| {
                const b = r.u8At(s) catch return error.EndOfBuffer;
                f.keys_sorted = b != 0;
            }
        },
        .@"union" => {
            if (try fld(r, table, 0)) |m| f.union_mode = r.u16At(m) catch return error.EndOfBuffer;
            if (try fld(r, table, 1)) |ids| {
                const n = r.vecLen(ids) catch return error.Syntax;
                const data = r.vecData(ids) catch return error.Syntax;
                f.type_ids_at = c.type_ids.items.len;
                f.n_type_ids = n;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const v = r.i32At(data + i * 4) catch return error.Syntax;
                    c.type_ids.append(c.gpa, v) catch return error.OutOfMemory;
                }
            }
        },
        else => {},
    }
}

test "schema int32 roundtrip" {
    const gpa = std.testing.allocator;
    var c = model.Columnar.init(gpa);
    defer c.deinit();
    var f = model.Field{};
    f.name = @intCast(try c.intern("a"));
    f.kind = .int;
    f.bit_width = 32;
    f.is_signed = true;
    f.nullable = true;
    const id = try c.addField(f);
    try c.addTop(id);
    const raw = try encodeSchema(gpa, &c);
    defer gpa.free(raw);
    var back = model.Columnar.init(gpa);
    defer back.deinit();
    const r = fb.Reader{ .data = raw };
    try decodeSchema(r, try r.root(), &back);
    try std.testing.expectEqual(@as(usize, 1), back.top.items.len);
    const got = back.fields.items[back.top.items[0]];
    try std.testing.expectEqualStrings("a", back.str(@intCast(got.name)));
    try std.testing.expectEqual(model.Kind.int, got.kind);
    try std.testing.expectEqual(@as(i32, 32), got.bit_width);
    try std.testing.expect(got.is_signed);
    try std.testing.expect(got.nullable);
}
