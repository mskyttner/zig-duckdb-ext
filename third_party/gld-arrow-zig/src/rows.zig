const std = @import("std");
const model = @import("model.zig");

const Error = model.Error;

pub const Node = struct {
    kind: model.Kind,
    is_null: bool = false,
    scalar: i64 = 0,
    text_at: usize = 0,
    text_len: usize = 0,
    child_at: usize = 0,
    n_child: usize = 0,
};

pub const Rows = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(usize) = .empty,
    text: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(usize) = .empty,

    pub fn deinit(self: *Rows) void {
        self.nodes.deinit(self.gpa);
        self.edges.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.rows.deinit(self.gpa);
    }

    pub fn child(self: *const Rows, node: usize, i: usize) usize {
        return self.edges.items[self.nodes.items[node].child_at + i];
    }

    pub fn textOf(self: *const Rows, node: usize) []const u8 {
        const n = self.nodes.items[node];
        return self.text.items[n.text_at..][0..n.text_len];
    }
};

pub fn rowsFromBatch(gpa: std.mem.Allocator, c: *const model.Columnar, batch: usize) Error!Rows {
    var doc = Rows{ .gpa = gpa };
    errdefer doc.deinit();
    const b = c.batches.items[batch];
    var row: i64 = 0;
    while (row < b.length) : (row += 1) {
        var ids: std.ArrayList(usize) = .empty;
        defer ids.deinit(gpa);
        var col: usize = 0;
        while (col < b.n_col) : (col += 1) {
            const aid = c.batch_cols.items[b.col_at + col];
            try ids.append(gpa, try value(c, &doc, aid, row, 0));
        }
        var top = Node{ .kind = .@"struct" };
        top.child_at = doc.edges.items.len;
        doc.edges.appendSlice(gpa, ids.items) catch return error.OutOfMemory;
        top.n_child = ids.items.len;
        const id = doc.nodes.items.len;
        doc.nodes.append(gpa, top) catch return error.OutOfMemory;
        doc.rows.append(gpa, id) catch return error.OutOfMemory;
    }
    return doc;
}

fn value(c: *const model.Columnar, doc: *Rows, aid: usize, row: i64, depth: usize) Error!usize {
    if (depth > model.max_depth) return error.Depth;
    const a = c.arrays.items[aid];
    const f = c.fields.items[a.field];
    var n = Node{ .kind = f.kind };
    if (isNull(c, a, row)) {
        n.is_null = true;
        return push(doc, n);
    }
    if (f.dict_id >= 0 and a.dict >= 0) {
        const idx = try fixed(c, a, 1, row, @intCast(@divTrunc(f.dict_index_width, 8)), f.dict_index_signed);
        return value(c, doc, @intCast(a.dict), idx, depth + 1);
    }
    switch (f.kind) {
        .bool => {
            const bits = c.arrayBuf(aid, 1);
            n.scalar = if (model.bitGet(bits, @intCast(row))) 1 else 0;
        },
        .int, .date, .time, .timestamp, .duration, .float => {
            const width = model.byteWidth(f);
            const signed = f.kind != .float and (f.kind != .int or f.is_signed);
            n.scalar = try fixed(c, a, 1, row, width, signed);
        },
        .utf8, .large_utf8, .binary, .large_binary => {
            const wide: usize = if (f.kind == .large_utf8 or f.kind == .large_binary) 8 else 4;
            const off = c.arrayBuf(aid, 1);
            const data = c.arrayBuf(aid, 2);
            const s0: usize = @intCast(try model.readInt(off, @as(usize, @intCast(row)) * wide, wide, true));
            const s1: usize = @intCast(try model.readInt(off, @as(usize, @intCast(row + 1)) * wide, wide, true));
            n.text_at = doc.text.items.len;
            n.text_len = s1 - s0;
            doc.text.appendSlice(doc.gpa, data[s0..s1]) catch return error.OutOfMemory;
        },
        .list, .large_list, .map => {
            const wide: usize = if (f.kind == .large_list) 8 else 4;
            const off = c.arrayBuf(aid, 1);
            const s0 = try model.readInt(off, @as(usize, @intCast(row)) * wide, wide, true);
            const s1 = try model.readInt(off, @as(usize, @intCast(row + 1)) * wide, wide, true);
            const child_a = c.achilds.items[a.child_at];
            var ids: std.ArrayList(usize) = .empty;
            defer ids.deinit(doc.gpa);
            var i = s0;
            while (i < s1) : (i += 1) try ids.append(doc.gpa, try value(c, doc, child_a, i, depth + 1));
            n.child_at = doc.edges.items.len;
            doc.edges.appendSlice(doc.gpa, ids.items) catch return error.OutOfMemory;
            n.n_child = ids.items.len;
        },
        .@"struct" => {
            var ids: std.ArrayList(usize) = .empty;
            defer ids.deinit(doc.gpa);
            var ch: usize = 0;
            while (ch < a.n_child) : (ch += 1) {
                try ids.append(doc.gpa, try value(c, doc, c.achilds.items[a.child_at + ch], row, depth + 1));
            }
            n.child_at = doc.edges.items.len;
            doc.edges.appendSlice(doc.gpa, ids.items) catch return error.OutOfMemory;
            n.n_child = ids.items.len;
        },
        .null => n.is_null = true,
        else => return error.BadType,
    }
    return push(doc, n);
}

fn push(doc: *Rows, n: Node) Error!usize {
    const id = doc.nodes.items.len;
    doc.nodes.append(doc.gpa, n) catch return error.OutOfMemory;
    return id;
}

fn isNull(c: *const model.Columnar, a: model.Array, row: i64) bool {
    if (a.null_count == 0 or a.n_buf == 0) return false;
    const bm = c.buf(c.abufs.items[a.buf_at]);
    if (bm.len == 0) return false;
    return !model.bitGet(bm, @as(usize, @intCast(row)));
}

fn fixed(c: *const model.Columnar, a: model.Array, slot: usize, row: i64, width: usize, signed: bool) Error!i64 {
    const raw = c.buf(c.abufs.items[a.buf_at + slot]);
    return model.readInt(raw, @as(usize, @intCast(row)) * width, width, signed);
}
