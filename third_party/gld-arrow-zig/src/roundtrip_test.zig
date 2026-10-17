const std = @import("std");
const ipc = @import("ipc.zig");
const lz4 = @import("lz4.zig");
const model = @import("model.zig");
const tensor = @import("tensor.zig");
const zstd = @import("zstd.zig");

fn readAll(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(8 << 20));
}

fn utf8At(data_off: []const u8, data: []const u8, row: usize) ![]const u8 {
    const s0: usize = @intCast(try model.readInt(data_off, row * 4, 4, true));
    const s1: usize = @intCast(try model.readInt(data_off, (row + 1) * 4, 4, true));
    return data[s0..s1];
}

test "pyarrow basic stream, file, list, struct, dict, tensor" {
    const gpa = std.testing.allocator;
    const basic_raw = try readAll(gpa, "testdata/golden/pa-basic.arrows");
    defer gpa.free(basic_raw);
    var basic = try ipc.decodeStream(gpa, basic_raw);
    defer basic.deinit();
    try std.testing.expectEqual(@as(usize, 4), basic.top.items.len);
    try std.testing.expectEqual(@as(usize, 1), basic.batches.items.len);
    try std.testing.expectEqual(@as(i64, 3), basic.batches.items[0].length);
    const i_arr = basic.batchCol(0, 0);
    try std.testing.expectEqual(@as(i64, 1), try model.readInt(basic.arrayBuf(i_arr, 1), 0, 4, true));
    try std.testing.expectEqual(@as(i64, 3), try model.readInt(basic.arrayBuf(i_arr, 1), 8, 4, true));
    try std.testing.expect(!model.bitGet(basic.arrayBuf(i_arr, 0), 1));
    const s_arr = basic.batchCol(0, 1);
    try std.testing.expectEqualStrings("a", try utf8At(basic.arrayBuf(s_arr, 1), basic.arrayBuf(s_arr, 2), 0));
    try std.testing.expectEqualStrings("hi", try utf8At(basic.arrayBuf(s_arr, 1), basic.arrayBuf(s_arr, 2), 1));
    const b_arr = basic.batchCol(0, 2);
    try std.testing.expect(model.bitGet(basic.arrayBuf(b_arr, 1), 0));
    try std.testing.expect(!model.bitGet(basic.arrayBuf(b_arr, 1), 1));
    const f_arr = basic.batchCol(0, 3);
    const f0: f64 = @bitCast(try model.readInt(basic.arrayBuf(f_arr, 1), 0, 8, false));
    try std.testing.expect(f0 == 1.5);
    const fnan: f64 = @bitCast(try model.readInt(basic.arrayBuf(f_arr, 1), 8, 8, false));
    try std.testing.expect(std.math.isNan(fnan));

    const file_raw = try readAll(gpa, "testdata/golden/pa-basic.arrow");
    defer gpa.free(file_raw);
    const info = try ipc.readFooter(file_raw);
    try std.testing.expectEqual(@as(usize, 4), info.n_fields);
    try std.testing.expectEqual(@as(usize, 1), info.n_batch);
    var file_c = try ipc.decodeFile(gpa, file_raw);
    defer file_c.deinit();
    try std.testing.expectEqual(@as(i64, 3), file_c.batches.items[0].length);

    const list_raw = try readAll(gpa, "testdata/golden/pa-list.arrows");
    defer gpa.free(list_raw);
    var list_c = try ipc.decodeStream(gpa, list_raw);
    defer list_c.deinit();
    const larr = list_c.batchCol(0, 0);
    try std.testing.expectEqual(model.Kind.list, list_c.fields.items[list_c.arrays.items[larr].field].kind);
    try std.testing.expectEqual(@as(i64, 0), try model.readInt(list_c.arrayBuf(larr, 1), 0, 4, true));
    try std.testing.expectEqual(@as(i64, 2), try model.readInt(list_c.arrayBuf(larr, 1), 4, 4, true));
    try std.testing.expectEqual(@as(usize, 1), list_c.arrays.items[larr].n_child);

    const st_raw = try readAll(gpa, "testdata/golden/pa-struct.arrows");
    defer gpa.free(st_raw);
    var st = try ipc.decodeStream(gpa, st_raw);
    defer st.deinit();
    const sarr = st.batchCol(0, 0);
    try std.testing.expectEqual(@as(usize, 2), st.arrays.items[sarr].n_child);
    try std.testing.expectEqual(model.Kind.@"struct", st.fields.items[st.top.items[0]].kind);

    const d_raw = try readAll(gpa, "testdata/golden/pa-dict.arrows");
    defer gpa.free(d_raw);
    var dict = try ipc.decodeStream(gpa, d_raw);
    defer dict.deinit();
    try std.testing.expectEqual(@as(usize, 1), dict.dicts.items.len);
    const darr = dict.batchCol(0, 0);
    try std.testing.expect(dict.arrays.items[darr].dict >= 0);
    try std.testing.expectEqual(@as(i64, 4), dict.arrays.items[darr].length);
    const values = dict.arrays.items[@intCast(dict.arrays.items[darr].dict)];
    try std.testing.expectEqual(model.Kind.utf8, dict.fields.items[values.field].kind);

    const t_raw = try readAll(gpa, "testdata/golden/tensor.arrows");
    defer gpa.free(t_raw);
    var ten = try ipc.decodeStream(gpa, t_raw);
    defer ten.deinit();
    try std.testing.expectEqual(@as(usize, 1), ten.tensors.items.len);
    const t = ten.tensors.items[0];
    try std.testing.expectEqual(@as(i64, 2), ten.shapes.items[t.shape_at]);
    try std.testing.expectEqual(@as(i64, 3), ten.shapes.items[t.shape_at + 1]);
    try std.testing.expectEqual(@as(i64, 5), try model.readInt(ten.buf(t.data_buf), 20, 4, true));
}

test "dictionary list struct and both compressions" {
    const gpa = std.testing.allocator;
    var c = model.Columnar.init(gpa);
    defer c.deinit();

    var df = model.Field{};
    df.name = @intCast(try c.intern("d"));
    df.kind = .utf8;
    df.dict_id = 1;
    df.dict_index_width = 32;
    df.dict_index_signed = true;
    const dfid = try c.addField(df);
    try c.addTop(dfid);
    const dict_off = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0 };
    const dict_data = "ab";
    const dict_arr = try c.addArray(2, 0, dfid, &.{ &.{}, &dict_off, dict_data }, &.{});
    try c.addDict(.{ .id = 1, .array = dict_arr, .is_delta = false, .batch_index = 0 });
    var idx = @as([16]u8, @splat(0));
    std.mem.writeInt(i32, idx[0..4], 0, .little);
    std.mem.writeInt(i32, idx[4..8], 1, .little);
    std.mem.writeInt(i32, idx[8..12], 0, .little);
    const ibm = [_]u8{0b00000111};
    const iarr = try c.addArray(4, 1, dfid, &.{ &ibm, idx[0..12] }, &.{});
    c.arrays.items[iarr].dict = @intCast(dict_arr);

    var lf = model.Field{};
    lf.name = @intCast(try c.intern("item"));
    lf.kind = .int;
    lf.bit_width = 32;
    lf.is_signed = true;
    lf.nullable = true;
    const item = try c.addField(lf);
    var list_f = model.Field{};
    list_f.name = @intCast(try c.intern("l"));
    list_f.kind = .list;
    list_f.child_at = c.kids.items.len;
    list_f.n_child = 1;
    const list_id = try c.addField(list_f);
    try c.kids.append(gpa, item);
    var child_vals: [12]u8 = undefined;
    std.mem.writeInt(i32, child_vals[0..4], 1, .little);
    std.mem.writeInt(i32, child_vals[4..8], 2, .little);
    std.mem.writeInt(i32, child_vals[8..12], 3, .little);
    const child = try c.addArray(3, 0, item, &.{ &.{}, &child_vals }, &.{});
    const loff = [_]u8{ 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 };
    const lbm = [_]u8{0b00000101};
    const larr = try c.addArray(3, 1, list_id, &.{ &lbm, &loff }, &.{child});

    var xf = model.Field{};
    xf.name = @intCast(try c.intern("x"));
    xf.kind = .int;
    xf.bit_width = 32;
    xf.is_signed = true;
    xf.nullable = true;
    const xid = try c.addField(xf);
    var yf = model.Field{};
    yf.name = @intCast(try c.intern("y"));
    yf.kind = .utf8;
    const yid = try c.addField(yf);
    var sf = model.Field{};
    sf.name = @intCast(try c.intern("s"));
    sf.kind = .@"struct";
    sf.child_at = c.kids.items.len;
    sf.n_child = 2;
    const sid = try c.addField(sf);
    try c.kids.append(gpa, xid);
    try c.kids.append(gpa, yid);
    var xvals: [8]u8 = undefined;
    std.mem.writeInt(i32, xvals[0..4], 7, .little);
    std.mem.writeInt(i32, xvals[4..8], 0, .little);
    const xarr = try c.addArray(2, 0, xid, &.{ &.{}, &xvals }, &.{});
    const yoff = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
    const yarr = try c.addArray(2, 0, yid, &.{ &.{}, &yoff, "a" }, &.{});
    const sbm = [_]u8{0b00000001};
    const sarr = try c.addArray(2, 1, sid, &.{&sbm}, &.{ xarr, yarr });

    try c.addBatch(4, &.{ iarr, larr, sarr }, null);
    // lengths differ across columns. Use separate batches instead.
    c.batches.clearRetainingCapacity();
    c.batch_cols.clearRetainingCapacity();
    try c.addBatch(4, &.{iarr}, null);
    const plain = try ipc.encodeStream(gpa, &c);
    defer gpa.free(plain);
    var back = try ipc.decodeStream(gpa, plain);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 1), back.dicts.items.len);
    const b0 = back.batchCol(0, 0);
    try std.testing.expectEqual(@as(i32, 1), @as(i32, @intCast(try model.readInt(back.arrayBuf(b0, 1), 4, 4, true))));
    const dv_i: usize = @intCast(back.arrays.items[b0].dict);
    try std.testing.expectEqualStrings("a", try utf8At(back.arrayBuf(dv_i, 1), back.arrayBuf(dv_i, 2), 0));
    try std.testing.expectEqualStrings("b", try utf8At(back.arrayBuf(dv_i, 1), back.arrayBuf(dv_i, 2), 1));

    var lz = model.Columnar.init(gpa);
    defer lz.deinit();
    var zf = model.Field{};
    zf.name = @intCast(try lz.intern("z"));
    zf.kind = .int;
    zf.bit_width = 32;
    zf.is_signed = true;
    zf.nullable = false;
    const zid = try lz.addField(zf);
    try lz.addTop(zid);
    const zeros = try gpa.alloc(u8, 64 * 4);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    const zarr = try lz.addArray(64, 0, zid, &.{ &.{}, zeros }, &.{});
    try lz.addBatch(64, &.{zarr}, .lz4);
    const lz_bytes = try ipc.encodeStream(gpa, &lz);
    defer gpa.free(lz_bytes);
    var lz_back = try ipc.decodeStream(gpa, lz_bytes);
    defer lz_back.deinit();
    try std.testing.expectEqual(model.Codec.lz4, lz_back.batches.items[0].codec.?);
    try std.testing.expectEqual(@as(i64, 0), try model.readInt(lz_back.arrayBuf(lz_back.batchCol(0, 0), 1), 0, 4, true));
    try std.testing.expect((lz_back.features & 2) != 0);

    lz.batches.items[0].codec = .zstd;
    const zs_bytes = try ipc.encodeStream(gpa, &lz);
    defer gpa.free(zs_bytes);
    var zs_back = try ipc.decodeStream(gpa, zs_bytes);
    defer zs_back.deinit();
    try std.testing.expectEqual(model.Codec.zstd, zs_back.batches.items[0].codec.?);
    try std.testing.expectEqual(@as(i64, 0), try model.readInt(zs_back.arrayBuf(0, 1), 252, 4, true));
    try std.testing.expect(zs_bytes.len < plain.len or zs_bytes.len > 0);
}

test "compression goldens" {
    const gpa = std.testing.allocator;
    const lz = try readAll(gpa, "testdata/golden/lz4-hello.lz4");
    defer gpa.free(lz);
    const hello = try lz4.decompress(gpa, lz);
    defer gpa.free(hello);
    try std.testing.expectEqualStrings("hello hello hello hello hello", hello);

    const cases = [_]struct { path: []const u8, text: []const u8 }{
        .{ .path = "testdata/golden/zstd-empty.zst", .text = "" },
        .{ .path = "testdata/golden/zstd-a.zst", .text = "a" },
        .{ .path = "testdata/golden/zstd-hello.zst", .text = "hello" },
        .{ .path = "testdata/golden/zstd-rep.zst", .text = "hello hello hello hello hello" },
        .{ .path = "testdata/golden/zstd-checksum.zst", .text = "hello" },
    };
    for (cases) |case| {
        const raw = try readAll(gpa, case.path);
        defer gpa.free(raw);
        const got = try zstd.decompress(gpa, raw);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.text, got);
    }
    const skipped = try readAll(gpa, "testdata/golden/zstd-skip.zst");
    defer gpa.free(skipped);
    const skip_got = try zstd.decompress(gpa, skipped);
    defer gpa.free(skip_got);
    try std.testing.expectEqualStrings("hello", skip_got);
    const dictz = try readAll(gpa, "testdata/golden/zstd-dict.zst");
    defer gpa.free(dictz);
    try std.testing.expectError(error.Compression, zstd.decompress(gpa, dictz));

    const abc = try readAll(gpa, "testdata/golden/zstd-abc.zst");
    defer gpa.free(abc);
    const abc_got = try zstd.decompress(gpa, abc);
    defer gpa.free(abc_got);
    try std.testing.expectEqual(@as(usize, 300), abc_got.len);
    try std.testing.expectEqualStrings("abc", abc_got[0..3]);

    const zeros = try readAll(gpa, "testdata/golden/zstd-zeros.zst");
    defer gpa.free(zeros);
    const zeros_got = try zstd.decompress(gpa, zeros);
    defer gpa.free(zeros_got);
    try std.testing.expectEqual(@as(usize, 1000), zeros_got.len);
    try std.testing.expectEqual(@as(u8, 0), zeros_got[999]);

    const text = try readAll(gpa, "testdata/golden/zstd-text.zst");
    defer gpa.free(text);
    const text_got = try zstd.decompress(gpa, text);
    defer gpa.free(text_got);
    try std.testing.expect(std.mem.startsWith(u8, text_got, "The quick brown fox"));
    try std.testing.expectEqual(@as(usize, 45 * 40), text_got.len);

    const rnd = try readAll(gpa, "testdata/golden/zstd-random.zst");
    defer gpa.free(rnd);
    const rnd_got = try zstd.decompress(gpa, rnd);
    defer gpa.free(rnd_got);
    try std.testing.expectEqual(@as(usize, 1024), rnd_got.len);
    try std.testing.expectEqual(@as(u8, 0), rnd_got[0]);
    try std.testing.expectEqual(@as(u8, 255), rnd_got[255]);

    const mix = try readAll(gpa, "testdata/golden/zstd-mix.zst");
    defer gpa.free(mix);
    const mix_got = try zstd.decompress(gpa, mix);
    defer gpa.free(mix_got);
    try std.testing.expectEqual(@as(usize, 5000), mix_got.len);
    try std.testing.expectEqual(@as(u8, 0), mix_got[0]);
    try std.testing.expectEqual(@as(u8, 16), mix_got[16]);
}

test "more logical types from pyarrow" {
    const gpa = std.testing.allocator;
    const names = [_][]const u8{
        "testdata/golden/pa-map.arrows",
        "testdata/golden/pa-union.arrows",
        "testdata/golden/pa-ree.arrows",
        "testdata/golden/pa-view.arrows",
        "testdata/golden/pa-lview.arrows",
        "testdata/golden/pa-dec.arrows",
        "testdata/golden/pa-d32.arrows",
        "testdata/golden/pa-d256.arrows",
        "testdata/golden/pa-time.arrows",
        "testdata/golden/pa-interval.arrows",
        "testdata/golden/pa-fsb.arrows",
    };
    for (names) |path| {
        const raw = try readAll(gpa, path);
        defer gpa.free(raw);
        var c = try ipc.decodeStream(gpa, raw);
        defer c.deinit();
        try std.testing.expect(c.batches.items.len == 1);
        try std.testing.expect(c.top.items.len >= 1);
    }
    const dec_raw = try readAll(gpa, "testdata/golden/pa-dec.arrows");
    defer gpa.free(dec_raw);
    var dec = try ipc.decodeStream(gpa, dec_raw);
    defer dec.deinit();
    try std.testing.expectEqual(model.Kind.decimal, dec.fields.items[dec.top.items[0]].kind);
    try std.testing.expectEqual(@as(i32, 10), dec.fields.items[dec.top.items[0]].precision);
    try std.testing.expectEqual(@as(i32, 2), dec.fields.items[dec.top.items[0]].scale);
    const fsb_raw = try readAll(gpa, "testdata/golden/pa-fsb.arrows");
    defer gpa.free(fsb_raw);
    var fsb = try ipc.decodeStream(gpa, fsb_raw);
    defer fsb.deinit();
    const arr = fsb.batchCol(0, 0);
    try std.testing.expectEqualStrings("abc", fsb.arrayBuf(arr, 1)[0..3]);
    try std.testing.expectEqualStrings("xyz", fsb.arrayBuf(arr, 1)[6..9]);
}

test "writer list and struct" {
    const gpa = std.testing.allocator;
    var c = model.Columnar.init(gpa);
    defer c.deinit();
    var item_f = model.Field{};
    item_f.name = @intCast(try c.intern("item"));
    item_f.kind = .int;
    item_f.bit_width = 32;
    item_f.is_signed = true;
    const item = try c.addField(item_f);
    var list_f = model.Field{};
    list_f.name = @intCast(try c.intern("l"));
    list_f.kind = .list;
    list_f.child_at = c.kids.items.len;
    list_f.n_child = 1;
    const list_id = try c.addField(list_f);
    try c.kids.append(gpa, item);
    try c.addTop(list_id);
    var child_vals: [12]u8 = undefined;
    std.mem.writeInt(i32, child_vals[0..4], 1, .little);
    std.mem.writeInt(i32, child_vals[4..8], 2, .little);
    std.mem.writeInt(i32, child_vals[8..12], 3, .little);
    const child = try c.addArray(3, 0, item, &.{ &.{}, &child_vals }, &.{});
    const loff = [_]u8{ 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 };
    const lbm = [_]u8{0b00000101};
    const larr = try c.addArray(3, 1, list_id, &.{ &lbm, &loff }, &.{child});
    try c.addBatch(3, &.{larr}, null);
    const raw = try ipc.encodeStream(gpa, &c);
    defer gpa.free(raw);
    var back = try ipc.decodeStream(gpa, raw);
    defer back.deinit();
    const rows = @import("rows.zig");
    var doc = try rows.rowsFromBatch(gpa, &back, 0);
    defer doc.deinit();
    const row0 = doc.child(doc.rows.items[0], 0);
    try std.testing.expect(!doc.nodes.items[row0].is_null);
    try std.testing.expectEqual(@as(usize, 2), doc.nodes.items[row0].n_child);
    try std.testing.expectEqual(@as(i64, 1), doc.nodes.items[doc.child(row0, 0)].scalar);
    try std.testing.expect(doc.nodes.items[doc.child(doc.rows.items[1], 0)].is_null);
    const row2 = doc.child(doc.rows.items[2], 0);
    try std.testing.expectEqual(@as(i64, 3), doc.nodes.items[doc.child(row2, 0)].scalar);

    var s = model.Columnar.init(gpa);
    defer s.deinit();
    var xf = model.Field{};
    xf.name = @intCast(try s.intern("x"));
    xf.kind = .int;
    xf.bit_width = 32;
    xf.is_signed = true;
    const xid = try s.addField(xf);
    var yf = model.Field{};
    yf.name = @intCast(try s.intern("y"));
    yf.kind = .utf8;
    const yid = try s.addField(yf);
    var sf = model.Field{};
    sf.name = @intCast(try s.intern("s"));
    sf.kind = .@"struct";
    sf.child_at = s.kids.items.len;
    sf.n_child = 2;
    const sid = try s.addField(sf);
    try s.kids.append(gpa, xid);
    try s.kids.append(gpa, yid);
    try s.addTop(sid);
    var xvals: [8]u8 = undefined;
    std.mem.writeInt(i32, xvals[0..4], 7, .little);
    std.mem.writeInt(i32, xvals[4..8], 0, .little);
    const xarr = try s.addArray(2, 0, xid, &.{ &.{}, &xvals }, &.{});
    const yoff = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
    const yarr = try s.addArray(2, 0, yid, &.{ &.{}, &yoff, "a" }, &.{});
    const sbm = [_]u8{0b00000001};
    const sarr = try s.addArray(2, 1, sid, &.{&sbm}, &.{ xarr, yarr });
    try s.addBatch(2, &.{sarr}, null);
    const sraw = try ipc.encodeStream(gpa, &s);
    defer gpa.free(sraw);
    var sback = try ipc.decodeStream(gpa, sraw);
    defer sback.deinit();
    var sdoc = try rows.rowsFromBatch(gpa, &sback, 0);
    defer sdoc.deinit();
    const struct0 = sdoc.child(sdoc.rows.items[0], 0);
    try std.testing.expectEqual(@as(i64, 7), sdoc.nodes.items[sdoc.child(struct0, 0)].scalar);
    try std.testing.expectEqualStrings("a", sdoc.textOf(sdoc.child(struct0, 1)));
    try std.testing.expect(sdoc.nodes.items[sdoc.child(sdoc.rows.items[1], 0)].is_null);
}

test "sparse tensors roundtrip" {
    const gpa = std.testing.allocator;
    var c = model.Columnar.init(gpa);
    defer c.deinit();
    var f = model.Field{};
    f.kind = .int;
    f.bit_width = 32;
    f.is_signed = true;
    f.nullable = false;
    const fid = try c.addField(f);
    const data = [_]u8{ 9, 0, 0, 0 };
    const idx = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0 };
    const db = try c.addBuf(&data);
    try c.shapes.appendSlice(gpa, &.{ 2, 2 });
    try c.shape_names.appendSlice(gpa, &.{ -1, -1 });
    const ib = try c.addBuf(&idx);
    const index_at = c.abufs.items.len;
    try c.abufs.append(gpa, ib);
    try c.tensors.append(gpa, .{
        .field = fid,
        .shape_at = 0,
        .n_shape = 2,
        .stride_at = 0,
        .n_stride = 0,
        .data_buf = db,
        .sparse = 1,
        .index_at = index_at,
        .n_index = 1,
        .nz = 1,
        .coo_canonical = true,
        .index_width = 32,
        .index_signed = true,
    });
    const raw = try tensor.encodeTensorStream(gpa, &c);
    defer gpa.free(raw);
    var back = try ipc.decodeStream(gpa, raw);
    defer back.deinit();
    try std.testing.expectEqual(@as(u8, 1), back.tensors.items[0].sparse);
    try std.testing.expectEqual(@as(i64, 1), back.tensors.items[0].nz);
    try std.testing.expect(back.tensors.items[0].coo_canonical);
    try std.testing.expectEqual(@as(i64, 9), try model.readInt(back.buf(back.tensors.items[0].data_buf), 0, 4, true));

    const indptr = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
    const indices = [_]u8{ 1, 0, 0, 0 };
    const ipb = try c.addBuf(&indptr);
    const ixb = try c.addBuf(&indices);
    const at2 = c.abufs.items.len;
    try c.abufs.append(gpa, ipb);
    try c.abufs.append(gpa, ixb);
    try c.tensors.append(gpa, .{
        .field = fid,
        .shape_at = 0,
        .n_shape = 2,
        .stride_at = 0,
        .n_stride = 0,
        .data_buf = db,
        .sparse = 2,
        .index_at = at2,
        .n_index = 2,
        .nz = 1,
        .csx_axis = 0,
        .index_width = 32,
        .index_signed = true,
    });
    const raw2 = try tensor.encodeTensorStream(gpa, &c);
    defer gpa.free(raw2);
    var back2 = try ipc.decodeStream(gpa, raw2);
    defer back2.deinit();
    try std.testing.expectEqual(@as(usize, 2), back2.tensors.items.len);
    try std.testing.expectEqual(@as(u8, 2), back2.tensors.items[1].sparse);
    try std.testing.expectEqual(@as(usize, 2), back2.tensors.items[1].n_index);

    const at3 = c.abufs.items.len;
    try c.abufs.append(gpa, ipb);
    try c.abufs.append(gpa, ixb);
    try c.strides.append(gpa, 1);
    try c.strides.append(gpa, 0);
    try c.tensors.append(gpa, .{
        .field = fid,
        .shape_at = 0,
        .n_shape = 2,
        .stride_at = c.strides.items.len - 2,
        .n_stride = 2,
        .data_buf = db,
        .sparse = 3,
        .index_at = at3,
        .n_index = 2,
        .nz = 1,
        .index_width = 32,
        .index_signed = true,
    });
    const raw3 = try tensor.encodeTensorStream(gpa, &c);
    defer gpa.free(raw3);
    var back3 = try ipc.decodeStream(gpa, raw3);
    defer back3.deinit();
    const csf = back3.tensors.items[2];
    try std.testing.expectEqual(@as(u8, 3), csf.sparse);
    try std.testing.expectEqual(@as(usize, 2), csf.n_index);
    try std.testing.expectEqual(@as(i64, 1), back3.strides.items[csf.stride_at]);
}
