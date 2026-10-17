const std = @import("std");
const model = @import("model.zig");

pub const Error = model.Error;

pub const Kind = enum(u8) { null, bool, num, str, arr, obj };

pub const Node = struct {
    kind: Kind,
    a: usize = 0,
    n: usize = 0,
};

pub const Doc = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(usize) = .empty,
    pair_k: std.ArrayList(usize) = .empty,
    pair_v: std.ArrayList(usize) = .empty,
    texts: std.ArrayList([]u8) = .empty,
    root: usize = 0,

    pub fn deinit(self: *Doc) void {
        for (self.texts.items) |t| self.gpa.free(t);
        self.texts.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.edges.deinit(self.gpa);
        self.pair_k.deinit(self.gpa);
        self.pair_v.deinit(self.gpa);
    }

    fn push(self: *Doc, n: Node) Error!usize {
        self.nodes.append(self.gpa, n) catch return error.OutOfMemory;
        return self.nodes.items.len - 1;
    }

    pub fn kind(self: *const Doc, id: usize) Kind {
        return self.nodes.items[id].kind;
    }

    pub fn text(self: *const Doc, id: usize) []const u8 {
        return self.texts.items[self.nodes.items[id].a];
    }

    pub fn boolean(self: *const Doc, id: usize) bool {
        return self.nodes.items[id].a != 0;
    }

    pub fn count(self: *const Doc, id: usize) usize {
        return self.nodes.items[id].n;
    }

    pub fn child(self: *const Doc, id: usize, i: usize) usize {
        const n = self.nodes.items[id];
        if (n.kind == .obj) return self.pair_v.items[n.a + i];
        return self.edges.items[n.a + i];
    }

    pub fn key(self: *const Doc, id: usize, i: usize) []const u8 {
        return self.texts.items[self.pair_k.items[self.nodes.items[id].a + i]];
    }

    pub fn find(self: *const Doc, id: usize, name: []const u8) ?usize {
        if (self.kind(id) != .obj) return null;
        var i: usize = 0;
        while (i < self.count(id)) : (i += 1) {
            if (std.mem.eql(u8, self.key(id, i), name)) return self.child(id, i);
        }
        return null;
    }
};

pub fn parse(gpa: std.mem.Allocator, raw: []const u8) Error!Doc {
    var doc = Doc{ .gpa = gpa };
    errdefer doc.deinit();
    var i = skip(raw, 0);
    const root = try value(raw, &doc, &i);
    i = skip(raw, i);
    if (i != raw.len) return error.Syntax;
    doc.root = root;
    return doc;
}

fn skip(raw: []const u8, start: usize) usize {
    var i = start;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            ' ', '\t', '\n', '\r' => {},
            else => return i,
        }
    }
    return i;
}

fn value(raw: []const u8, doc: *Doc, i: *usize) Error!usize {
    i.* = skip(raw, i.*);
    if (i.* >= raw.len) return error.EndOfBuffer;
    switch (raw[i.*]) {
        'n' => return lit(raw, doc, i, "null", .null, 0),
        't' => return lit(raw, doc, i, "true", .bool, 1),
        'f' => return lit(raw, doc, i, "false", .bool, 0),
        '"' => {
            const text = try string(doc.gpa, raw, i);
            const id = doc.texts.items.len;
            doc.texts.append(doc.gpa, text) catch return error.OutOfMemory;
            return doc.push(.{ .kind = .str, .a = id });
        },
        '[' => return array(raw, doc, i),
        '{' => return object(raw, doc, i),
        '-', '0'...'9' => return number(raw, doc, i),
        else => return error.Syntax,
    }
}

fn lit(raw: []const u8, doc: *Doc, i: *usize, word: []const u8, kind: Kind, a: usize) Error!usize {
    if (i.* + word.len > raw.len or !std.mem.eql(u8, raw[i.*..][0..word.len], word)) return error.Syntax;
    i.* += word.len;
    return doc.push(.{ .kind = kind, .a = a });
}

fn string(gpa: std.mem.Allocator, raw: []const u8, i: *usize) Error![]u8 {
    i.* += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (i.* < raw.len) {
        const c = raw[i.*];
        i.* += 1;
        if (c == '"') return out.toOwnedSlice(gpa);
        if (c == '\\') {
            if (i.* >= raw.len) return error.Syntax;
            const e = raw[i.*];
            i.* += 1;
            switch (e) {
                '"', '\\', '/' => try out.append(gpa, e),
                'b' => try out.append(gpa, 8),
                'f' => try out.append(gpa, 12),
                'n' => try out.append(gpa, '\n'),
                'r' => try out.append(gpa, '\r'),
                't' => try out.append(gpa, '\t'),
                'u' => {
                    if (i.* + 4 > raw.len) return error.Syntax;
                    const cp = std.fmt.parseInt(u21, raw[i.*..][0..4], 16) catch return error.Syntax;
                    i.* += 4;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.Syntax;
                    try out.appendSlice(gpa, buf[0..n]);
                },
                else => return error.Syntax,
            }
        } else try out.append(gpa, c);
    }
    return error.Syntax;
}

fn array(raw: []const u8, doc: *Doc, i: *usize) Error!usize {
    i.* += 1;
    var kids: std.ArrayList(usize) = .empty;
    defer kids.deinit(doc.gpa);
    i.* = skip(raw, i.*);
    if (i.* < raw.len and raw[i.*] == ']') {
        i.* += 1;
        const start = doc.edges.items.len;
        return doc.push(.{ .kind = .arr, .a = start, .n = 0 });
    }
    while (true) {
        const child = try value(raw, doc, i);
        try kids.append(doc.gpa, child);
        i.* = skip(raw, i.*);
        if (i.* >= raw.len) return error.Syntax;
        if (raw[i.*] == ',') {
            i.* += 1;
            continue;
        }
        if (raw[i.*] == ']') {
            i.* += 1;
            break;
        }
        return error.Syntax;
    }
    const start = doc.edges.items.len;
    doc.edges.appendSlice(doc.gpa, kids.items) catch return error.OutOfMemory;
    return doc.push(.{ .kind = .arr, .a = start, .n = kids.items.len });
}

fn object(raw: []const u8, doc: *Doc, i: *usize) Error!usize {
    i.* += 1;
    var keys: std.ArrayList(usize) = .empty;
    defer keys.deinit(doc.gpa);
    var vals: std.ArrayList(usize) = .empty;
    defer vals.deinit(doc.gpa);
    i.* = skip(raw, i.*);
    if (i.* < raw.len and raw[i.*] == '}') {
        i.* += 1;
        return doc.push(.{ .kind = .obj, .a = doc.pair_k.items.len, .n = 0 });
    }
    while (true) {
        i.* = skip(raw, i.*);
        if (i.* >= raw.len or raw[i.*] != '"') return error.Syntax;
        const key = try string(doc.gpa, raw, i);
        const kid = doc.texts.items.len;
        doc.texts.append(doc.gpa, key) catch return error.OutOfMemory;
        i.* = skip(raw, i.*);
        if (i.* >= raw.len or raw[i.*] != ':') return error.Syntax;
        i.* += 1;
        const child = try value(raw, doc, i);
        try keys.append(doc.gpa, kid);
        try vals.append(doc.gpa, child);
        i.* = skip(raw, i.*);
        if (i.* >= raw.len) return error.Syntax;
        if (raw[i.*] == ',') {
            i.* += 1;
            continue;
        }
        if (raw[i.*] == '}') {
            i.* += 1;
            break;
        }
        return error.Syntax;
    }
    const start = doc.pair_k.items.len;
    doc.pair_k.appendSlice(doc.gpa, keys.items) catch return error.OutOfMemory;
    doc.pair_v.appendSlice(doc.gpa, vals.items) catch return error.OutOfMemory;
    return doc.push(.{ .kind = .obj, .a = start, .n = keys.items.len });
}

fn number(raw: []const u8, doc: *Doc, i: *usize) Error!usize {
    const start = i.*;
    if (raw[i.*] == '-') i.* += 1;
    if (i.* >= raw.len or raw[i.*] < '0' or raw[i.*] > '9') return error.Syntax;
    while (i.* < raw.len and raw[i.*] >= '0' and raw[i.*] <= '9') i.* += 1;
    if (i.* < raw.len and raw[i.*] == '.') {
        i.* += 1;
        while (i.* < raw.len and raw[i.*] >= '0' and raw[i.*] <= '9') i.* += 1;
    }
    const text = doc.gpa.dupe(u8, raw[start..i.*]) catch return error.OutOfMemory;
    const id = doc.texts.items.len;
    doc.texts.append(doc.gpa, text) catch return error.OutOfMemory;
    return doc.push(.{ .kind = .num, .a = id });
}
