const std = @import("std");
const arrow = @import("arrow");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var schema_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) continue;
        if ((std.mem.eql(u8, args[i], "--schema") or std.mem.eql(u8, args[i], "--out")) and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i - 1], "--schema")) schema_path = args[i] else out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            usage();
            return;
        }
    }
    if (schema_path == null or out_dir == null) {
        usage();
        return;
    }
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, schema_path.?, gpa, .limited(32 << 20));
    defer gpa.free(raw);
    const text = try generate(gpa, raw);
    defer gpa.free(text);
    try std.Io.Dir.cwd().createDirPath(io, out_dir.?);
    const struct_name = titleOf(text);
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.zig", .{ out_dir.?, struct_name }) catch return error.Syntax;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
    std.debug.print("wrote {s}\n", .{path});
}

fn usage() void {
    std.debug.print("gld-arrowgen-zig --schema FILE --out DIR\n", .{});
}

fn generate(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (looksJson(raw)) {
        const name = try arrow.schemaTitle(gpa, raw);
        defer gpa.free(name);
        var c = try arrow.loadSchema(gpa, raw);
        defer c.deinit();
        return arrow.emitSchema(gpa, name, &c);
    }
    var c = arrow.decodeStream(gpa, raw) catch try arrow.decodeFile(gpa, raw);
    defer c.deinit();
    const name = metaTitle(&c);
    return arrow.emitSchema(gpa, name, &c);
}

fn looksJson(raw: []const u8) bool {
    for (raw) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        return c == '{';
    }
    return false;
}

fn metaTitle(c: *const arrow.Columnar) []const u8 {
    var i: usize = 0;
    while (i < c.n_schema_meta) : (i += 1) {
        const k = c.meta_k.items[c.schema_meta_at + i];
        if (std.mem.eql(u8, c.str(k), "title")) return c.str(c.meta_v.items[c.schema_meta_at + i]);
    }
    return "Root";
}

fn titleOf(text: []const u8) []const u8 {
    const key = "pub const ";
    const at = std.mem.indexOf(u8, text, key) orelse return "Root";
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "Root";
    return rest[0..end];
}
