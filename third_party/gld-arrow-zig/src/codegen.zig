const std = @import("std");
const model = @import("model.zig");

const Error = model.Error;

fn add(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) Error!void {
    out.appendSlice(gpa, text) catch return error.OutOfMemory;
}

fn line(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error!void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return error.Syntax;
    try add(out, gpa, text);
}

pub fn emit(gpa: std.mem.Allocator, title_text: []const u8, c: *const model.Columnar) Error![]u8 {
    const name = try ident(gpa, title_text);
    defer gpa.free(name);
    const ids = try emitIds(gpa, c);
    defer gpa.free(ids);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try add(&out, gpa, "const std = @import(\"std\");\nconst arrow = @import(\"arrow\");\n\npub const ");
    try add(&out, gpa, name);
    try add(&out, gpa, " = struct {\n");
    for (ids) |id| {
        const f = c.fields.items[id];
        const fname = try zigName(gpa, fieldRaw(c, f));
        defer gpa.free(fname);
        try line(&out, gpa, "    {s}: {s},\n", .{ fname, zigType(f) });
        if (f.nullable) try line(&out, gpa, "    {s}_set: bool = false,\n", .{fname});
    }
    try add(&out, gpa, "\n    pub fn deinit(self: *");
    try add(&out, gpa, name);
    try add(&out, gpa, ", gpa: std.mem.Allocator) void {\n");
    for (ids) |id| {
        const f = c.fields.items[id];
        if (isBytes(f.kind)) {
            const fname = try zigName(gpa, fieldRaw(c, f));
            defer gpa.free(fname);
            try line(&out, gpa, "        gpa.free(self.{s});\n", .{fname});
        }
    }
    try add(&out, gpa, "    }\n\n    pub fn encodedLen(self: ");
    try add(&out, gpa, name);
    try add(&out, gpa, ", gpa: std.mem.Allocator) !usize {\n        const raw = try self.encode(gpa);\n        defer gpa.free(raw);\n        return raw.len;\n    }\n\n    pub fn encode(self: ");
    try add(&out, gpa, name);
    try add(&out, gpa, ", gpa: std.mem.Allocator) ![]u8 {\n        var c = arrow.Columnar.init(gpa);\n        defer c.deinit();\n        const empty: []const u8 = &.{};\n");
    for (ids, 0..) |id, i| try appendField(&out, gpa, c, c.fields.items[id], i);
    try add(&out, gpa, "        try c.addBatch(1, &.{");
    for (ids, 0..) |_, i| {
        if (i != 0) try add(&out, gpa, ", ");
        try line(&out, gpa, "a{d}", .{i});
    }
    try add(&out, gpa, "}, null);\n        return try arrow.encodeStream(gpa, &c);\n    }\n\n    pub fn decode(gpa: std.mem.Allocator, raw: []const u8) !");
    try add(&out, gpa, name);
    try add(&out, gpa, " {\n        var c = try arrow.decodeStream(gpa, raw);\n        defer c.deinit();\n        var rows = try arrow.rowsFromBatch(gpa, &c, 0);\n        defer rows.deinit();\n        const row = rows.rows.items[0];\n        var out_value: ");
    try add(&out, gpa, name);
    try add(&out, gpa, " = .{");
    for (ids, 0..) |id, i| {
        const f = c.fields.items[id];
        const fname = try zigName(gpa, fieldRaw(c, f));
        defer gpa.free(fname);
        if (i != 0) try add(&out, gpa, ",");
        try line(&out, gpa, " .{s} = {s}", .{ fname, zeroOf(f) });
    }
    try add(&out, gpa, " };\n");
    for (ids, 0..) |id, i| {
        const f = c.fields.items[id];
        const fname = try zigName(gpa, fieldRaw(c, f));
        defer gpa.free(fname);
        try line(&out, gpa, "        const n{d} = rows.child(row, {d});\n", .{ i, i });
        const pad: []const u8 = if (f.nullable) "            " else "        ";
        if (f.nullable) {
            try line(&out, gpa, "        out_value.{s}_set = !rows.nodes.items[n{d}].is_null;\n", .{ fname, i });
            try line(&out, gpa, "        if (out_value.{s}_set) {{\n", .{fname});
        }
        if (isBytes(f.kind)) {
            try line(&out, gpa, "{s}out_value.{s} = try gpa.dupe(u8, rows.textOf(n{d}));\n", .{ pad, fname, i });
        } else if (f.kind == .bool) {
            try line(&out, gpa, "{s}out_value.{s} = rows.nodes.items[n{d}].scalar != 0;\n", .{ pad, fname, i });
        } else if (f.kind == .float and f.unit == 1) {
            try line(&out, gpa, "{s}out_value.{s} = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(rows.nodes.items[n{d}].scalar)))));\n", .{ pad, fname, i });
        } else if (f.kind == .float) {
            try line(&out, gpa, "{s}out_value.{s} = @bitCast(rows.nodes.items[n{d}].scalar);\n", .{ pad, fname, i });
        } else {
            try line(&out, gpa, "{s}out_value.{s} = @intCast(rows.nodes.items[n{d}].scalar);\n", .{ pad, fname, i });
        }
        if (f.nullable) try add(&out, gpa, "        }\n");
    }
    try add(&out, gpa, "        return out_value;\n    }\n};\n");
    return out.toOwnedSlice(gpa);
}

fn appendField(out: *std.ArrayList(u8), gpa: std.mem.Allocator, c: *const model.Columnar, f: model.Field, i: usize) Error!void {
    const fname = try zigName(gpa, fieldRaw(c, f));
    defer gpa.free(fname);
    const raw = fieldRaw(c, f);
    try line(out, gpa, "        var f{d} = arrow.Field{{}};\n", .{i});
    try line(out, gpa, "        f{d}.name = @intCast(try c.intern(\"{s}\"));\n", .{ i, raw });
    try line(out, gpa, "        f{d}.kind = .{s};\n", .{ i, kindTok(f.kind) });
    try line(out, gpa, "        f{d}.nullable = {};\n", .{ i, f.nullable });
    try line(out, gpa, "        f{d}.bit_width = {d};\n", .{ i, f.bit_width });
    try line(out, gpa, "        f{d}.is_signed = {};\n", .{ i, f.is_signed });
    try line(out, gpa, "        f{d}.unit = {d};\n", .{ i, f.unit });
    try line(out, gpa, "        const id{d} = try c.addField(f{d});\n", .{ i, i });
    try line(out, gpa, "        try c.addTop(id{d});\n", .{i});
    if (isBytes(f.kind)) {
        const wide: usize = if (f.kind == .large_utf8 or f.kind == .large_binary) 8 else 4;
        try line(out, gpa, "        var off{d}: [{d}]u8 = undefined;\n", .{ i, wide * 2 });
        if (wide == 4) {
            try line(out, gpa, "        std.mem.writeInt(i32, off{d}[0..4], 0, .little);\n", .{i});
            try line(out, gpa, "        std.mem.writeInt(i32, off{d}[4..8], @intCast(self.{s}.len), .little);\n", .{ i, fname });
        } else {
            try line(out, gpa, "        std.mem.writeInt(i64, off{d}[0..8], 0, .little);\n", .{i});
            try line(out, gpa, "        std.mem.writeInt(i64, off{d}[8..16], @intCast(self.{s}.len), .little);\n", .{ i, fname });
        }
        if (f.nullable) {
            try line(out, gpa, "        const nb{d} = [_]u8{{ if (self.{s}_set) 1 else 0 }};\n", .{ i, fname });
            try line(out, gpa, "        const nc{d}: i64 = if (self.{s}_set) 0 else 1;\n", .{ i, fname });
            try line(out, gpa, "        const bufs{d} = [_][]const u8{{ &nb{d}, &off{d}, self.{s} }};\n", .{ i, i, i, fname });
            try line(out, gpa, "        const a{d} = try c.addArray(1, nc{d}, id{d}, &bufs{d}, &[_]usize{{}});\n", .{ i, i, i, i });
        } else {
            try line(out, gpa, "        const bufs{d} = [_][]const u8{{ empty, &off{d}, self.{s} }};\n", .{ i, i, fname });
            try line(out, gpa, "        const a{d} = try c.addArray(1, 0, id{d}, &bufs{d}, &[_]usize{{}});\n", .{ i, i, i });
        }
    } else if (f.kind == .bool) {
        try line(out, gpa, "        const bit{d} = [_]u8{{ if (self.{s}) 1 else 0 }};\n", .{ i, fname });
        try line(out, gpa, "        const bufs{d} = [_][]const u8{{ empty, &bit{d} }};\n", .{ i, i });
        try line(out, gpa, "        const a{d} = try c.addArray(1, 0, id{d}, &bufs{d}, &[_]usize{{}});\n", .{ i, i, i });
    } else {
        const width = model.byteWidth(f);
        const use = if (width == 0) 8 else width;
        try line(out, gpa, "        var raw{d}: [{d}]u8 = undefined;\n", .{ i, use });
        if (f.kind == .float and f.unit == 1) {
            try line(out, gpa, "        std.mem.writeInt(u32, &raw{d}, @bitCast(self.{s}), .little);\n", .{ i, fname });
        } else if (f.kind == .float) {
            try line(out, gpa, "        std.mem.writeInt(u64, &raw{d}, @bitCast(self.{s}), .little);\n", .{ i, fname });
        } else if (std.mem.startsWith(u8, zigType(f), "u")) {
            try line(out, gpa, "        std.mem.writeInt({s}, &raw{d}, self.{s}, .little);\n", .{ zigType(f), i, fname });
        } else {
            try line(out, gpa, "        std.mem.writeInt({s}, &raw{d}, @as({s}, @intCast(self.{s})), .little);\n", .{ signedStore(use), i, signedStore(use), fname });
        }
        try line(out, gpa, "        const bufs{d} = [_][]const u8{{ empty, &raw{d} }};\n", .{ i, i });
        try line(out, gpa, "        const a{d} = try c.addArray(1, 0, id{d}, &bufs{d}, &[_]usize{{}});\n", .{ i, i, i });
    }
}

fn kindTok(k: model.Kind) []const u8 {
    return switch (k) {
        .@"struct" => "@\"struct\"",
        .@"union" => "@\"union\"",
        .null => "null",
        else => switch (k) {
            .int => "int",
            .float => "float",
            .binary => "binary",
            .utf8 => "utf8",
            .bool => "bool",
            .decimal => "decimal",
            .date => "date",
            .time => "time",
            .timestamp => "timestamp",
            .interval => "interval",
            .list => "list",
            .fixed_binary => "fixed_binary",
            .fixed_list => "fixed_list",
            .map => "map",
            .duration => "duration",
            .large_binary => "large_binary",
            .large_utf8 => "large_utf8",
            .large_list => "large_list",
            .run_end => "run_end",
            .binary_view => "binary_view",
            .utf8_view => "utf8_view",
            .list_view => "list_view",
            .large_list_view => "large_list_view",
            else => "int",
        },
    };
}

fn isBytes(k: model.Kind) bool {
    return k == .utf8 or k == .large_utf8 or k == .binary or k == .large_binary;
}

fn zigType(f: model.Field) []const u8 {
    return switch (f.kind) {
        .bool => "bool",
        .utf8, .large_utf8, .binary, .large_binary => "[]u8",
        .float => if (f.unit == 1) "f32" else "f64",
        .int => switch (f.bit_width) {
            8 => if (f.is_signed) "i8" else "u8",
            16 => if (f.is_signed) "i16" else "u16",
            32 => if (f.is_signed) "i32" else "u32",
            else => if (f.is_signed) "i64" else "u64",
        },
        else => "i64",
    };
}

fn zeroOf(f: model.Field) []const u8 {
    return switch (f.kind) {
        .bool => "false",
        .utf8, .large_utf8, .binary, .large_binary => "&[_]u8{}",
        else => "0",
    };
}

fn signedStore(width: usize) []const u8 {
    return switch (width) {
        1 => "i8",
        2 => "i16",
        4 => "i32",
        else => "i64",
    };
}

fn fieldRaw(c: *const model.Columnar, f: model.Field) []const u8 {
    if (f.name < 0) return "field";
    return c.str(@intCast(f.name));
}

fn emitIds(gpa: std.mem.Allocator, c: *const model.Columnar) Error![]usize {
    var ids: std.ArrayList(usize) = .empty;
    errdefer ids.deinit(gpa);
    if (c.top.items.len == 1 and c.fields.items[c.top.items[0]].kind == .@"struct") {
        const f = c.fields.items[c.top.items[0]];
        var i: usize = 0;
        while (i < f.n_child) : (i += 1) try ids.append(gpa, c.kids.items[f.child_at + i]);
    } else try ids.appendSlice(gpa, c.top.items);
    return ids.toOwnedSlice(gpa) catch error.OutOfMemory;
}

fn zigName(gpa: std.mem.Allocator, name: []const u8) Error![]u8 {
    return ident(gpa, name);
}

fn ident(gpa: std.mem.Allocator, name: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (name.len == 0) {
        try add(&out, gpa, "Root");
    } else {
        for (name, 0..) |ch, i| {
            const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_' or (ch >= '0' and ch <= '9' and i != 0);
            out.append(gpa, if (ok) ch else '_') catch return error.OutOfMemory;
        }
    }
    const keywords = [_][]const u8{ "struct", "type", "error", "fn", "const", "var", "pub", "if", "else", "while", "for", "return", "try", "self", "null", "true", "false" };
    for (keywords) |kw| if (std.mem.eql(u8, out.items, kw)) out.append(gpa, '_') catch return error.OutOfMemory;
    return out.toOwnedSlice(gpa) catch error.OutOfMemory;
}

test "codegen names the three methods" {
    const gpa = std.testing.allocator;
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/schema/message.json", gpa, .limited(1 << 20));
    defer gpa.free(raw);
    const schema_load = @import("schema_load.zig");
    const name = try schema_load.title(gpa, raw);
    defer gpa.free(name);
    var c = try schema_load.load(gpa, raw);
    defer c.deinit();
    const src = try emit(gpa, name, &c);
    defer gpa.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const Message") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn encodedLen") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn encode") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn decode") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "id: i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "name: []u8") != null);
}
