const std = @import("std");
const json = @import("json.zig");
const model = @import("model.zig");

const Error = model.Error;

pub fn load(gpa: std.mem.Allocator, raw: []const u8) Error!model.Columnar {
    var doc = try json.parse(gpa, raw);
    defer doc.deinit();
    var c = model.Columnar.init(gpa);
    errdefer c.deinit();
    if (doc.find(doc.root, "fields") != null and doc.find(doc.root, "properties") == null) {
        try arrowSchema(&doc, doc.root, &c);
    } else {
        const root = try jsonSchema(&doc, doc.root, &c, "Root", true);
        try c.addTop(root);
    }
    return c;
}

pub fn title(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    var doc = try json.parse(gpa, raw);
    defer doc.deinit();
    if (doc.find(doc.root, "title")) |t| {
        if (doc.kind(t) == .str) return gpa.dupe(u8, doc.text(t)) catch error.OutOfMemory;
    }
    return gpa.dupe(u8, "Root") catch error.OutOfMemory;
}

fn arrowSchema(doc: *json.Doc, id: usize, c: *model.Columnar) Error!void {
    const fields = doc.find(id, "fields") orelse return error.Schema;
    if (doc.kind(fields) != .arr) return error.Schema;
    var i: usize = 0;
    while (i < doc.count(fields)) : (i += 1) try c.addTop(try arrowField(doc, doc.child(fields, i), c));
}

fn arrowField(doc: *json.Doc, id: usize, c: *model.Columnar) Error!usize {
    var f = model.Field{};
    if (doc.find(id, "name")) |nm| if (doc.kind(nm) == .str) {
        f.name = @intCast(try c.intern(doc.text(nm)));
    };
    if (doc.find(id, "nullable")) |nu| {
        if (doc.kind(nu) == .bool and !doc.boolean(nu)) f.nullable = false;
    }
    const ty = doc.find(id, "type") orelse return error.Schema;
    try arrowType(doc, ty, &f);
    const fid = try c.addField(f);
    var direct: std.ArrayList(usize) = .empty;
    defer direct.deinit(c.gpa);
    if (doc.find(id, "children")) |ch| if (doc.kind(ch) == .arr) {
        var i: usize = 0;
        while (i < doc.count(ch)) : (i += 1) try direct.append(c.gpa, try arrowField(doc, doc.child(ch, i), c));
    };
    const start = c.kids.items.len;
    c.kids.appendSlice(c.gpa, direct.items) catch return error.OutOfMemory;
    var stored = c.fields.items[fid];
    stored.child_at = start;
    stored.n_child = direct.items.len;
    c.fields.items[fid] = stored;
    return fid;
}

fn arrowType(doc: *json.Doc, id: usize, f: *model.Field) Error!void {
    if (doc.kind(id) == .str) {
        try applyName(doc.text(id), f);
        return;
    }
    const name = doc.find(id, "name") orelse return error.Schema;
    if (doc.kind(name) != .str) return error.Schema;
    try applyName(doc.text(name), f);
    if (doc.find(id, "bitWidth")) |bits| f.bit_width = try intOf(doc, bits);
    if (doc.find(id, "isSigned")) |signed| {
        if (doc.kind(signed) == .bool) f.is_signed = doc.boolean(signed);
    }
    if (doc.find(id, "precision")) |prec| {
        if (doc.kind(prec) == .num) f.precision = try intOf(doc, prec) else if (doc.kind(prec) == .str) {
            const p = doc.text(prec);
            if (std.mem.eql(u8, p, "HALF")) f.unit = 0 else if (std.mem.eql(u8, p, "SINGLE")) f.unit = 1 else f.unit = 2;
        }
    }
    if (doc.find(id, "scale")) |scale| f.scale = try intOf(doc, scale);
    if (doc.find(id, "unit")) |unit| {
        if (doc.kind(unit) == .str) f.unit = unitName(doc.text(unit));
    }
    if (f.kind == .decimal and f.bit_width == 0) f.bit_width = 128;
}

fn applyName(name: []const u8, f: *model.Field) Error!void {
    if (eql(name, "null")) f.kind = .null else if (eql(name, "bool") or eql(name, "boolean")) f.kind = .bool else if (eql(name, "int") or eql(name, "int32")) {
        f.kind = .int;
        if (f.bit_width == 0) f.bit_width = 32;
    } else if (eql(name, "int8")) {
        f.kind = .int;
        f.bit_width = 8;
    } else if (eql(name, "int16")) {
        f.kind = .int;
        f.bit_width = 16;
    } else if (eql(name, "int64")) {
        f.kind = .int;
        f.bit_width = 64;
    } else if (eql(name, "uint8") or eql(name, "uint16") or eql(name, "uint32") or eql(name, "uint64")) {
        f.kind = .int;
        f.is_signed = false;
        f.bit_width = if (eql(name, "uint8")) 8 else if (eql(name, "uint16")) 16 else if (eql(name, "uint32")) 32 else 64;
    } else if (eql(name, "utf8") or eql(name, "string")) f.kind = .utf8 else if (eql(name, "large_utf8") or eql(name, "large_string")) f.kind = .large_utf8 else if (eql(name, "binary")) f.kind = .binary else if (eql(name, "large_binary")) f.kind = .large_binary else if (eql(name, "floatingpoint") or eql(name, "float64") or eql(name, "double")) {
        f.kind = .float;
        f.unit = 2;
    } else if (eql(name, "float32") or eql(name, "float")) {
        f.kind = .float;
        f.unit = 1;
    } else if (eql(name, "float16") or eql(name, "halffloat")) {
        f.kind = .float;
        f.unit = 0;
    } else if (eql(name, "decimal")) f.kind = .decimal else if (eql(name, "date") or eql(name, "date32")) {
        f.kind = .date;
        f.unit = 0;
    } else if (eql(name, "date64")) {
        f.kind = .date;
        f.unit = 1;
    } else if (eql(name, "timestamp")) f.kind = .timestamp else if (eql(name, "time")) f.kind = .time else if (eql(name, "duration")) f.kind = .duration else if (eql(name, "interval")) f.kind = .interval else if (eql(name, "list")) f.kind = .list else if (eql(name, "large_list")) f.kind = .large_list else if (eql(name, "struct")) f.kind = .@"struct" else if (eql(name, "map")) f.kind = .map else if (eql(name, "fixedsizebinary")) f.kind = .fixed_binary else return error.Schema;
}

fn jsonSchema(doc: *json.Doc, id: usize, c: *model.Columnar, name: []const u8, nullable: bool) Error!usize {
    if (doc.find(id, "x-arrow-type")) |arrow| if (doc.kind(arrow) == .str) {
        var f = model.Field{};
        f.name = @intCast(try c.intern(name));
        f.nullable = nullable;
        try applyName(doc.text(arrow), &f);
        return c.addField(f);
    };
    if (doc.find(id, "type")) |typ| {
        if (doc.kind(typ) == .arr and doc.count(typ) == 2) {
            var inner = doc.child(typ, 0);
            if (doc.kind(inner) == .str and eql(doc.text(inner), "null")) inner = doc.child(typ, 1);
            if (doc.kind(inner) != .str) return error.Schema;
            return namedType(doc, id, doc.text(inner), c, name, true);
        }
        if (doc.kind(typ) == .str) return namedType(doc, id, doc.text(typ), c, name, nullable);
    }
    if (doc.find(id, "properties") != null) return object(doc, id, c, name, nullable);
    return error.Schema;
}

fn namedType(doc: *json.Doc, id: usize, name: []const u8, c: *model.Columnar, field_name: []const u8, nullable: bool) Error!usize {
    if (eql(name, "object")) return object(doc, id, c, field_name, nullable);
    if (eql(name, "array")) {
        const items = doc.find(id, "items") orelse return error.Schema;
        var item_name: std.ArrayList(u8) = .empty;
        defer item_name.deinit(c.gpa);
        try item_name.appendSlice(c.gpa, field_name);
        try item_name.appendSlice(c.gpa, "Item");
        const child = try jsonSchema(doc, items, c, item_name.items, true);
        var f = model.Field{};
        f.name = @intCast(try c.intern(field_name));
        f.kind = .list;
        f.nullable = nullable;
        const fid = try c.addField(f);
        const start = c.kids.items.len;
        c.kids.append(c.gpa, child) catch return error.OutOfMemory;
        var stored = c.fields.items[fid];
        stored.child_at = start;
        stored.n_child = 1;
        c.fields.items[fid] = stored;
        return fid;
    }
    var f = model.Field{};
    f.name = @intCast(try c.intern(field_name));
    f.nullable = nullable;
    if (eql(name, "integer")) {
        f.kind = .int;
        f.bit_width = 64;
        f.is_signed = true;
    } else if (eql(name, "number")) {
        f.kind = .float;
        f.unit = 2;
    } else if (eql(name, "string")) f.kind = .utf8 else if (eql(name, "boolean")) f.kind = .bool else if (eql(name, "null")) f.kind = .null else return error.Schema;
    return c.addField(f);
}

fn object(doc: *json.Doc, id: usize, c: *model.Columnar, name: []const u8, nullable: bool) Error!usize {
    var f = model.Field{};
    f.name = @intCast(try c.intern(name));
    f.kind = .@"struct";
    f.nullable = nullable;
    const fid = try c.addField(f);
    var direct: std.ArrayList(usize) = .empty;
    defer direct.deinit(c.gpa);
    if (doc.find(id, "properties")) |props| if (doc.kind(props) == .obj) {
        var i: usize = 0;
        while (i < doc.count(props)) : (i += 1) {
            const child_null = !required(doc, id, doc.key(props, i));
            try direct.append(c.gpa, try jsonSchema(doc, doc.child(props, i), c, doc.key(props, i), child_null));
        }
    };
    const start = c.kids.items.len;
    c.kids.appendSlice(c.gpa, direct.items) catch return error.OutOfMemory;
    var stored = c.fields.items[fid];
    stored.child_at = start;
    stored.n_child = direct.items.len;
    c.fields.items[fid] = stored;
    return fid;
}

fn required(doc: *json.Doc, id: usize, name: []const u8) bool {
    const req = doc.find(id, "required") orelse return false;
    if (doc.kind(req) != .arr) return false;
    var i: usize = 0;
    while (i < doc.count(req)) : (i += 1) {
        const item = doc.child(req, i);
        if (doc.kind(item) == .str and eql(doc.text(item), name)) return true;
    }
    return false;
}

fn intOf(doc: *json.Doc, id: usize) Error!i32 {
    if (doc.kind(id) != .num) return error.Schema;
    return std.fmt.parseInt(i32, doc.text(id), 10) catch error.Schema;
}

fn unitName(name: []const u8) u16 {
    if (eql(name, "SECOND") or eql(name, "DAY") or eql(name, "YEAR_MONTH")) return 0;
    if (eql(name, "MILLISECOND") or eql(name, "DAY_TIME")) return 1;
    if (eql(name, "MICROSECOND") or eql(name, "MONTH_DAY_NANO")) return 2;
    if (eql(name, "NANOSECOND")) return 3;
    return 1;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "json schema message" {
    const gpa = std.testing.allocator;
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/schema/message.json", gpa, .limited(1 << 20));
    defer gpa.free(raw);
    const name = try title(gpa, raw);
    defer gpa.free(name);
    try std.testing.expectEqualStrings("Message", name);
    var c = try load(gpa, raw);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 1), c.top.items.len);
    const root = c.fields.items[c.top.items[0]];
    try std.testing.expectEqual(model.Kind.@"struct", root.kind);
    try std.testing.expectEqual(@as(usize, 2), root.n_child);
    const id = c.fields.items[c.kids.items[root.child_at]];
    const nm = c.fields.items[c.kids.items[root.child_at + 1]];
    try std.testing.expectEqualStrings("id", c.str(@intCast(id.name)));
    try std.testing.expectEqual(model.Kind.int, id.kind);
    try std.testing.expectEqual(@as(i32, 64), id.bit_width);
    try std.testing.expect(!id.nullable);
    try std.testing.expectEqual(model.Kind.utf8, nm.kind);
    try std.testing.expect(!nm.nullable);
}
