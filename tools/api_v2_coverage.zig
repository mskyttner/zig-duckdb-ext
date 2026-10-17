//! Reports which functions of the DuckDB v2 C API the hand-written code references, per spec module.
//!
//!   api_v2_coverage <functions.tsv> <out.md> [--check] [--poc <path-substring>]... <dir>...
//!
//! <functions.tsv> is docs/generated/api_v2_functions.tsv (written by tools/gen_v2_bindings.zig: module,
//! name and lifecycle state of every function). Every .zig file under the <dir>s is scanned for those
//! names, except the generated bindings. A file whose path contains one of the --poc substrings counts
//! as proof-of-concept code, any other as extension code; the report keeps the two apart, since a
//! function only the PoC calls has a live test but no example a newcomer is pointed to.
//!
//! "Referenced" is a textual reference in code that is built and (for the PoC and the real extension)
//! exercised by the SQL tests; it does not say how much of the function's behavior a test pins.
//!
//! With --check the report is not written: the tool fails if <out.md> is not what it would write,
//! so a stale report fails CI.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Function = struct {
    module: []const u8,
    name: []const u8,
    unstable: bool,
    in_extension: bool = false,
    in_poc: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.next();
    const usage = "usage: api_v2_coverage <functions.tsv> <out.md> [--check] [--poc <path-substring>]... <dir>...";
    const index_path = args.next() orelse fatal(usage, .{});
    const out_path = args.next() orelse fatal(usage, .{});

    var check = false;
    var poc_markers: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, a, "--poc")) {
            try poc_markers.append(arena, args.next() orelse fatal(usage, .{}));
        } else {
            try dirs.append(arena, a);
        }
    }
    if (dirs.items.len == 0) fatal(usage, .{});

    const cwd = Io.Dir.cwd();
    const index = try cwd.readFileAlloc(io, index_path, arena, .unlimited);

    var functions: std.ArrayList(Function) = .empty;
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const module = cols.next() orelse continue;
        const name = cols.next() orelse continue;
        const state = cols.next() orelse "stable";
        try by_name.put(arena, name, functions.items.len);
        try functions.append(arena, .{ .module = module, .name = name, .unstable = std.mem.eql(u8, state, "unstable") });
    }

    var scanned: usize = 0;
    for (dirs.items) |d| {
        var dir = try cwd.openDir(io, d, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".zig") or isGenerated(std.fs.path.basename(e.path))) continue;
            const full = try std.fs.path.join(arena, &.{ d, e.path });
            const is_poc = for (poc_markers.items) |m| {
                if (std.mem.indexOf(u8, full, m) != null) break true;
            } else false;
            const source = try dir.readFileAlloc(io, e.path, arena, .unlimited);
            scanned += 1;
            scan(source, &by_name, functions.items, is_poc);
        }
    }

    var out: Io.Writer.Allocating = .init(arena);
    try report(arena, &out.writer, functions.items, scanned);

    if (check) {
        const current = cwd.readFileAlloc(io, out_path, arena, .unlimited) catch "";
        if (!std.mem.eql(u8, current, out.written())) {
            fatal("{s} is stale: run `task coverage:api-v2` and commit the result", .{out_path});
        }
        return;
    }
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out.written() });
}

/// The generated bindings and their parity tests mention every function by construction.
fn isGenerated(base: []const u8) bool {
    const generated = [_][]const u8{ "duckdb_v2_types.zig", "duckdb_v2_static.zig", "duckdb_v2_dynamic.zig", "duckdb_v2_static_parity.zig", "duckdb_v2_dynamic_parity.zig", "duckdb_v2_parity_util.zig" };
    for (generated) |g| if (std.mem.eql(u8, base, g)) return true;
    return false;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Marks every function whose C name appears in `source` as a whole identifier.
fn scan(source: []const u8, by_name: *const std.StringHashMapUnmanaged(usize), functions: []Function, is_poc: bool) void {
    const prefix = "duckdb_v2_";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, prefix)) |start| {
        var end = start + prefix.len;
        while (end < source.len and isIdent(source[end])) end += 1;
        from = end;
        if (start > 0 and isIdent(source[start - 1])) continue;
        const idx = by_name.get(source[start..end]) orelse continue;
        if (is_poc) functions[idx].in_poc = true else functions[idx].in_extension = true;
    }
}

fn report(arena: Allocator, w: *Io.Writer, functions: []const Function, scanned: usize) !void {
    try w.writeAll(
        \\# DuckDB v2 C API coverage
        \\
        \\Generated by `task coverage:api-v2` (tools/api_v2_coverage.zig) from `docs/generated/api_v2_functions.tsv`; do not edit.
        \\
        \\A function counts as **referenced** when the name appears in hand-written code that is built and exercised by the
        \\SQL tests: **ext** is the real extension and the frameworks (`src/functions`, `src/lib`), **poc** is the
        \\proof-of-concept extension and the worked examples. It says that something calls the function, not how much of its
        \\behavior a test pins. Functions marked *unstable* are only in the API table when DuckDB is built with
        \\`DUCKDB_V2_API_ALLOW_UNSTABLE`.
        \\
        \\
    );

    // Modules in the order of the index, which is alphabetical.
    var modules: std.ArrayList([]const u8) = .empty;
    for (functions) |f| {
        if (modules.items.len == 0 or !std.mem.eql(u8, modules.items[modules.items.len - 1], f.module)) try modules.append(arena, f.module);
    }

    var total: usize = 0;
    var total_ext: usize = 0;
    var total_any: usize = 0;
    var total_unstable: usize = 0;
    for (functions) |f| {
        total += 1;
        if (f.in_extension) total_ext += 1;
        if (f.in_extension or f.in_poc) total_any += 1;
        if (f.unstable) total_unstable += 1;
    }
    try w.print("{d} functions ({d} unstable) in {d} spec modules, from {d} scanned source files. Referenced by the extension: **{d}**; by the extension or the PoC: **{d}**.\n\n", .{ total, total_unstable, modules.items.len, scanned, total_ext, total_any });

    try w.writeAll("| module | functions | unstable | ext | ext or poc | not referenced |\n|---|---:|---:|---:|---:|---:|\n");
    for (modules.items) |m| {
        var n: usize = 0;
        var unstable: usize = 0;
        var ext: usize = 0;
        var any: usize = 0;
        for (functions) |f| {
            if (!std.mem.eql(u8, f.module, m)) continue;
            n += 1;
            if (f.unstable) unstable += 1;
            if (f.in_extension) ext += 1;
            if (f.in_extension or f.in_poc) any += 1;
        }
        try w.print("| {s} | {d} | {d} | {d} | {d} | {d} |\n", .{ m, n, unstable, ext, any, n - any });
    }

    try w.writeAll("\n## Not referenced\n\nBy module; the `duckdb_v2_` prefix is left out and *(u)* marks an unstable function.\n\n");
    for (modules.items) |m| {
        var wrote_heading = false;
        for (functions) |f| {
            if (!std.mem.eql(u8, f.module, m) or f.in_extension or f.in_poc) continue;
            if (!wrote_heading) {
                try w.print("**{s}**: ", .{m});
                wrote_heading = true;
            } else {
                try w.writeAll(", ");
            }
            try w.print("`{s}`{s}", .{ f.name["duckdb_v2_".len..], if (f.unstable) " *(u)*" else "" });
        }
        if (wrote_heading) try w.writeAll("\n\n");
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
