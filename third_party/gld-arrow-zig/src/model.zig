const std = @import("std");
const le = @import("le.zig");

pub const max_depth: usize = 64;

pub const Error = error{
    EndOfBuffer,
    Syntax,
    BadType,
    Schema,
    Range,
    Depth,
    Version,
    Compression,
    Flight,
    OutOfMemory,
};

pub const Kind = enum(u8) {
    null = 1,
    int = 2,
    float = 3,
    binary = 4,
    utf8 = 5,
    bool = 6,
    decimal = 7,
    date = 8,
    time = 9,
    timestamp = 10,
    interval = 11,
    list = 12,
    @"struct" = 13,
    @"union" = 14,
    fixed_binary = 15,
    fixed_list = 16,
    map = 17,
    duration = 18,
    large_binary = 19,
    large_utf8 = 20,
    large_list = 21,
    run_end = 22,
    binary_view = 23,
    utf8_view = 24,
    list_view = 25,
    large_list_view = 26,
};

pub const Codec = enum(u8) {
    lz4 = 0,
    zstd = 1,
};

pub const Field = struct {
    name: i32 = -1,
    nullable: bool = true,
    kind: Kind = .null,
    bit_width: i32 = 0,
    is_signed: bool = true,
    precision: i32 = 0,
    scale: i32 = 0,
    unit: u16 = 0,
    timezone: i32 = -1,
    union_mode: u16 = 0,
    type_ids_at: usize = 0,
    n_type_ids: usize = 0,
    child_at: usize = 0,
    n_child: usize = 0,
    meta_at: usize = 0,
    n_meta: usize = 0,
    dict_id: i64 = -1,
    dict_index_width: i32 = 32,
    dict_index_signed: bool = true,
    dict_ordered: bool = false,
    keys_sorted: bool = false,
    fixed_size: i32 = 0,
};

const Buf = struct {
    off: usize,
    len: usize,
    /// Index into `Columnar.borrows`, or -1 when the bytes live in `Columnar.bytes`.
    ext: i32 = -1,
};

pub const Array = struct {
    field: usize,
    length: i64,
    null_count: i64,
    buf_at: usize,
    n_buf: usize,
    child_at: usize,
    n_child: usize,
    dict: i64 = -1,
};

pub const Batch = struct {
    length: i64,
    col_at: usize,
    n_col: usize,
    codec: ?Codec = null,
};

pub const Dict = struct {
    id: i64,
    array: usize,
    is_delta: bool,
    batch_index: usize,
};

pub const Tensor = struct {
    field: usize,
    shape_at: usize,
    n_shape: usize,
    stride_at: usize,
    n_stride: usize,
    data_buf: usize,
    sparse: u8 = 0,
    index_at: usize = 0,
    n_index: usize = 0,
    nz: i64 = 0,
    coo_canonical: bool = false,
    csx_axis: u16 = 0,
    index_width: i32 = 64,
    index_signed: bool = true,
};

pub const Columnar = struct {
    gpa: std.mem.Allocator,
    string_bytes: std.ArrayList(u8) = .empty,
    string_off: std.ArrayList(usize) = .empty,
    string_len: std.ArrayList(usize) = .empty,
    fields: std.ArrayList(Field) = .empty,
    kids: std.ArrayList(usize) = .empty,
    type_ids: std.ArrayList(i32) = .empty,
    meta_k: std.ArrayList(usize) = .empty,
    meta_v: std.ArrayList(usize) = .empty,
    top: std.ArrayList(usize) = .empty,
    endian: u16 = 0,
    features: u64 = 0,
    schema_meta_at: usize = 0,
    n_schema_meta: usize = 0,
    bufs: std.ArrayList(Buf) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    /// IPC bodies kept alive by the caller. `deinit` drops the list, not the bytes.
    borrows: std.ArrayList([]const u8) = .empty,
    abufs: std.ArrayList(usize) = .empty,
    achilds: std.ArrayList(usize) = .empty,
    arrays: std.ArrayList(Array) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    batch_cols: std.ArrayList(usize) = .empty,
    dicts: std.ArrayList(Dict) = .empty,
    shapes: std.ArrayList(i64) = .empty,
    shape_names: std.ArrayList(i32) = .empty,
    strides: std.ArrayList(i64) = .empty,
    tensors: std.ArrayList(Tensor) = .empty,
    codec: ?Codec = null,

    pub fn init(gpa: std.mem.Allocator) Columnar {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Columnar) void {
        self.string_bytes.deinit(self.gpa);
        self.string_off.deinit(self.gpa);
        self.string_len.deinit(self.gpa);
        self.fields.deinit(self.gpa);
        self.kids.deinit(self.gpa);
        self.type_ids.deinit(self.gpa);
        self.meta_k.deinit(self.gpa);
        self.meta_v.deinit(self.gpa);
        self.top.deinit(self.gpa);
        self.bufs.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
        self.borrows.deinit(self.gpa);
        self.abufs.deinit(self.gpa);
        self.achilds.deinit(self.gpa);
        self.arrays.deinit(self.gpa);
        self.batches.deinit(self.gpa);
        self.batch_cols.deinit(self.gpa);
        self.dicts.deinit(self.gpa);
        self.shapes.deinit(self.gpa);
        self.shape_names.deinit(self.gpa);
        self.strides.deinit(self.gpa);
        self.tensors.deinit(self.gpa);
    }

    pub fn intern(self: *Columnar, text: []const u8) Error!usize {
        var i: usize = 0;
        while (i < self.string_off.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.str(i), text)) return i;
        }
        const off = self.string_bytes.items.len;
        self.string_bytes.appendSlice(self.gpa, text) catch return error.OutOfMemory;
        self.string_off.append(self.gpa, off) catch return error.OutOfMemory;
        self.string_len.append(self.gpa, text.len) catch return error.OutOfMemory;
        return self.string_off.items.len - 1;
    }

    pub fn str(self: *const Columnar, id: usize) []const u8 {
        const off = self.string_off.items[id];
        const n = self.string_len.items[id];
        return self.string_bytes.items[off..][0..n];
    }

    pub fn addField(self: *Columnar, field: Field) Error!usize {
        self.fields.append(self.gpa, field) catch return error.OutOfMemory;
        return self.fields.items.len - 1;
    }

    pub fn addTop(self: *Columnar, field_id: usize) Error!void {
        self.top.append(self.gpa, field_id) catch return error.OutOfMemory;
    }

    pub fn addMeta(self: *Columnar, key: []const u8, value: []const u8) Error!void {
        const k = try self.intern(key);
        const v = try self.intern(value);
        self.meta_k.append(self.gpa, k) catch return error.OutOfMemory;
        self.meta_v.append(self.gpa, v) catch return error.OutOfMemory;
    }

    pub fn addBuf(self: *Columnar, raw: []const u8) Error!usize {
        const off = self.bytes.items.len;
        if (raw.len > 0) self.bytes.appendSlice(self.gpa, raw) catch return error.OutOfMemory;
        self.bufs.append(self.gpa, .{ .off = off, .len = raw.len }) catch return error.OutOfMemory;
        return self.bufs.items.len - 1;
    }

    pub fn addEmptyBuf(self: *Columnar) Error!usize {
        return self.addBuf(&.{});
    }

    /// Record a buffer that already lives in `bytes` at `off`.
    pub fn addBufView(self: *Columnar, off: usize, len: usize) Error!usize {
        self.bufs.append(self.gpa, .{ .off = off, .len = len }) catch return error.OutOfMemory;
        return self.bufs.items.len - 1;
    }

    /// Remember `raw` and return an id for `addBorrowedBuf`. The caller keeps `raw` alive.
    pub fn addBorrow(self: *Columnar, raw: []const u8) Error!i32 {
        self.borrows.append(self.gpa, raw) catch return error.OutOfMemory;
        return @intCast(self.borrows.items.len - 1);
    }

    pub fn addBorrowedBuf(self: *Columnar, ext: i32, off: usize, len: usize) Error!usize {
        self.bufs.append(self.gpa, .{ .off = off, .len = len, .ext = ext }) catch return error.OutOfMemory;
        return self.bufs.items.len - 1;
    }

    pub fn buf(self: *const Columnar, id: usize) []const u8 {
        if (id >= self.bufs.items.len) return &.{};
        const b = self.bufs.items[id];
        if (b.len == 0) return &.{};
        if (b.ext >= 0) {
            const src = self.borrows.items[@intCast(b.ext)];
            return src[b.off..][0..b.len];
        }
        return self.bytes.items[b.off..][0..b.len];
    }

    pub fn addArray(
        self: *Columnar,
        length: i64,
        null_count: i64,
        field: usize,
        buffers: []const []const u8,
        children: []const usize,
    ) Error!usize {
        const buf_at = self.abufs.items.len;
        for (buffers) |raw| {
            const id = try self.addBuf(raw);
            self.abufs.append(self.gpa, id) catch return error.OutOfMemory;
        }
        const child_at = self.achilds.items.len;
        self.achilds.appendSlice(self.gpa, children) catch return error.OutOfMemory;
        self.arrays.append(self.gpa, .{
            .field = field,
            .length = length,
            .null_count = null_count,
            .buf_at = buf_at,
            .n_buf = buffers.len,
            .child_at = child_at,
            .n_child = children.len,
        }) catch return error.OutOfMemory;
        return self.arrays.items.len - 1;
    }

    pub fn addBatch(self: *Columnar, length: i64, cols: []const usize, codec: ?Codec) Error!void {
        const col_at = self.batch_cols.items.len;
        self.batch_cols.appendSlice(self.gpa, cols) catch return error.OutOfMemory;
        self.batches.append(self.gpa, .{
            .length = length,
            .col_at = col_at,
            .n_col = cols.len,
            .codec = codec,
        }) catch return error.OutOfMemory;
    }

    pub fn addDict(self: *Columnar, dict: Dict) Error!void {
        self.dicts.append(self.gpa, dict) catch return error.OutOfMemory;
    }

    pub fn arrayBuf(self: *const Columnar, array_i: usize, slot: usize) []const u8 {
        const a = self.arrays.items[array_i];
        return self.buf(self.abufs.items[a.buf_at + slot]);
    }

    pub fn batchCol(self: *const Columnar, batch: usize, col: usize) usize {
        const b = self.batches.items[batch];
        return self.batch_cols.items[b.col_at + col];
    }
};

pub fn byteWidth(f: Field) usize {
    return switch (f.kind) {
        .bool, .null => 0,
        .int => @intCast(@divTrunc(f.bit_width, 8)),
        .date => if (f.unit == 0) 4 else 8,
        .time => if (f.unit <= 1) 4 else 8,
        .timestamp, .duration => 8,
        .float => switch (f.unit) {
            0 => 2,
            1 => 4,
            else => 8,
        },
        .decimal => @intCast(@divTrunc(f.bit_width, 8)),
        .fixed_binary => @intCast(f.fixed_size),
        .interval => switch (f.unit) {
            0 => 4,
            1 => 8,
            else => 16,
        },
        else => 0,
    };
}

pub fn isVariadic(kind: Kind) bool {
    return kind == .binary_view or kind == .utf8_view;
}

pub fn swapFixed(raw: []u8, width: usize) void {
    if (width <= 1) return;
    var i: usize = 0;
    while (i + width <= raw.len) : (i += width) {
        var a: usize = 0;
        var b: usize = width - 1;
        while (a < b) {
            const t = raw[i + a];
            raw[i + a] = raw[i + b];
            raw[i + b] = t;
            a += 1;
            b -= 1;
        }
    }
}

pub fn bitGet(raw: []const u8, i: usize) bool {
    if (raw.len == 0) return false;
    const b = raw[i / 8];
    return ((b >> @intCast(i % 8)) & 1) != 0;
}

pub fn bitSet(raw: []u8, i: usize) void {
    const at = i / 8;
    raw[at] |= @as(u8, 1) << @intCast(i % 8);
}

pub fn validityBitmap(gpa: std.mem.Allocator, n: usize, is_null: []const bool) Error![]u8 {
    const nbytes = (n + 7) / 8;
    const out = gpa.alloc(u8, nbytes) catch return error.OutOfMemory;
    @memset(out, 0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const missing = i < is_null.len and is_null[i];
        if (!missing) bitSet(out, i);
    }
    return out;
}

pub fn readInt(data: []const u8, at: usize, width: usize, signed: bool) Error!i64 {
    return le.readInt(data, at, width, signed) catch error.EndOfBuffer;
}

pub fn localBufs(f: Field) usize {
    return switch (f.kind) {
        .null, .run_end => 0,
        .@"struct", .fixed_list => 1,
        .@"union" => if (f.union_mode == 1) 2 else 1,
        .list, .large_list, .map => 2,
        .list_view, .large_list_view => 3,
        .binary, .utf8, .large_binary, .large_utf8 => 3,
        .binary_view, .utf8_view => 2,
        else => 2,
    };
}
