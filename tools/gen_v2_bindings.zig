//! Generates Zig bindings for the DuckDB v2 C API from its YAML spec, in three files:
//!
//!   gen_v2_bindings <spec-dir> <out-dir> [--unstable] [--source <text>]
//!
//!   duckdb_v2_types.zig    constants, enums, handles, structs, aliases and callback types
//!   duckdb_v2_static.zig   the types, plus every function as a plain `extern fn`, resolved at link
//!                          time against libduckdb (the "direct-link" mode of static extensions)
//!   duckdb_v2_dynamic.zig  the types, plus the `get_api` function-pointer table (`Api`), `init` to
//!                          fill it, and a wrapper per function that calls through it
//!
//! `zig build gen-v2-bindings -Dv2-api-spec=<duckdb>/api_spec/v2` runs it and rewrites the three
//! files in src/lib/, which are committed so that a normal build needs neither this tool nor
//! zig-yaml.
//!
//! Declaration names are the C names in both backends, so code written against one can be built
//! against the other by swapping the module behind an import name. Both re-export the types of the
//! one shared types module, so a program that imports both still sees a single `duckdb_v2_str`.
const std = @import("std");
const log = std.log.scoped(.gen_v2_bindings);
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Yaml = @import("yaml").Yaml;
const Value = Yaml.Value;

const List = std.ArrayListUnmanaged;

const Kind = enum { primitive, handle, @"enum", @"struct", callback, alias };

const Entry = struct { name: []const u8, v: Value };

const Gen = struct {
    arena: Allocator,
    prefix: []const u8 = "",
    upper: []const u8 = "",
    include_unstable: bool = false,
    /// Where the spec comes from, recorded in the header of the generated file.
    source: []const u8 = "unspecified",

    kinds: std.StringHashMapUnmanaged(Kind) = .empty,
    /// Zig spelling of each primitive of metadata.yaml.
    prims: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// C names of primitives that are opaque handles (the extension handle).
    primitive_handles: List([]const u8) = .empty,

    enums: List(Entry) = .empty,
    handles: List(Entry) = .empty,
    structs: List(Entry) = .empty,
    callbacks: List(Entry) = .empty,
    aliases: List(Entry) = .empty,
    constants: List(Entry) = .empty,
    functions: List(Entry) = .empty,

    skipped_unstable: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.next();
    const usage = "usage: gen_v2_bindings <spec-dir> <out-dir> [--unstable] [--source <text>]";
    const spec_dir = args.next() orelse fatal(usage, .{});
    const out_dir = args.next() orelse fatal(usage, .{});

    var g: Gen = .{ .arena = arena };
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--unstable")) {
            g.include_unstable = true;
        } else if (std.mem.eql(u8, a, "--source")) {
            g.source = args.next() orelse fatal(usage, .{});
        } else {
            fatal("unknown argument {s}", .{a});
        }
    }

    var dir = try Io.Dir.cwd().openDir(io, spec_dir, .{ .iterate = true });
    defer dir.close(io);

    const meta = try loadYaml(io, arena, dir, "metadata.yaml");
    try loadMetadata(&g, meta);

    // Modules are the YAML files one directory down, except for the generator options.
    var paths: List([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or e.depth() != 2) continue;
        if (!std.mem.endsWith(u8, e.path, ".yaml") or std.mem.startsWith(u8, e.path, "options/")) continue;
        try paths.append(arena, try arena.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (paths.items) |p| try loadModule(&g, try loadYaml(io, arena, dir, p));

    var types_out: Io.Writer.Allocating = .init(arena);
    try emitTypes(&g, &types_out.writer, meta);
    try writeFormatted(io, arena, out_dir, "duckdb_v2_types.zig", types_out.written());

    var static_out: Io.Writer.Allocating = .init(arena);
    try emitStatic(&g, &static_out.writer, meta);
    try writeFormatted(io, arena, out_dir, "duckdb_v2_static.zig", static_out.written());

    var dynamic_out: Io.Writer.Allocating = .init(arena);
    try emitDynamic(&g, &dynamic_out.writer, meta);
    try writeFormatted(io, arena, out_dir, "duckdb_v2_dynamic.zig", dynamic_out.written());

    log.info(
        "{d} modules, {d} functions ({d} unstable skipped), {d} callbacks, {d} structs, {d} enums, {d} handles\n",
        .{ paths.items.len, g.functions.items.len, g.skipped_unstable, g.callbacks.items.len, g.structs.items.len, g.enums.items.len, g.handles.items.len },
    );
}

/// Runs the generated code through the formatter, so that `zig fmt` leaves the committed file alone.
fn writeFormatted(io: Io, arena: Allocator, out_dir: []const u8, name: []const u8, source: []const u8) !void {
    const raw = try arena.dupeSentinel(u8, source, 0);
    const tree = try std.zig.Ast.parse(arena, raw, .{});
    if (tree.errors.len != 0) fatal("{s}: the generated code does not parse (first error: {t})", .{ name, tree.errors[0].tag });
    const formatted = try tree.renderAlloc(arena);

    var dir = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = name, .data = formatted });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

fn loadYaml(io: Io, arena: Allocator, dir: Io.Dir, path: []const u8) !Value {
    const source = try dir.readFileAlloc(io, path, arena, .unlimited);
    const yaml = try arena.create(Yaml);
    yaml.* = .{ .source = source };
    yaml.load(arena) catch |err| {
        log.err("cannot parse {s}: {t}", .{ path, err });
        if (err == error.ParseFailure) {
            yaml.parse_errors.renderToStderr(io, .{}, .auto) catch |render_err| log.err("cannot render the parse errors: {t}", .{render_err});
        }
        std.process.exit(1);
    };
    return yaml.docs.items[0];
}

// --- small accessors over the generic YAML value -------------------------------------------------

fn get(v: Value, key: []const u8) ?Value {
    if (v != .map) return null;
    return v.map.get(key);
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .scalar) x.scalar else null;
}

fn flag(v: Value, key: []const u8) bool {
    return std.mem.eql(u8, str(get(v, key)) orelse return false, "true");
}

fn count(v: Value, key: []const u8) usize {
    const s = str(get(v, key)) orelse return 0;
    return std.fmt.parseInt(usize, s, 10) catch fatal("bad number '{s}' for {s}", .{ s, key });
}

// --- loading -------------------------------------------------------------------------------------

fn loadMetadata(g: *Gen, meta: Value) !void {
    g.prefix = str(get(meta, "prefix")) orelse fatal("metadata.yaml has no prefix", .{});
    g.upper = try std.ascii.allocUpperString(g.arena, g.prefix);

    for (get(meta, "primitives").?.list) |p| {
        const name = str(get(p, "name")).?;
        const c_type = str(get(p, "c_type")).?;
        try g.kinds.put(g.arena, name, .primitive);

        if (primitiveZig(c_type)) |z| {
            try g.prims.put(g.arena, name, z);
        } else if (str(get(p, "underlying"))) |u| {
            if (!std.mem.endsWith(u8, u, "*")) fatal("primitive {s}: unsupported underlying '{s}'", .{ name, u });
            try g.prims.put(g.arena, name, c_type);
            try g.primitive_handles.append(g.arena, c_type);
        } else if (std.mem.startsWith(u8, c_type, "struct ")) {
            try g.prims.put(g.arena, name, c_type["struct ".len..]);
        } else {
            fatal("primitive {s}: no mapping for C type '{s}'", .{ name, c_type });
        }
    }
}

fn primitiveZig(c_type: []const u8) ?[]const u8 {
    const table = [_][2][]const u8{
        .{ "void", "void" },    .{ "char", "u8" },      .{ "bool", "bool" },
        .{ "int8_t", "i8" },    .{ "int16_t", "i16" },  .{ "int32_t", "i32" },
        .{ "int64_t", "i64" },  .{ "uint8_t", "u8" },   .{ "uint16_t", "u16" },
        .{ "uint32_t", "u32" }, .{ "uint64_t", "u64" }, .{ "float", "f32" },
        .{ "double", "f64" },   .{ "idx_t", "u64" },    .{ "size_t", "usize" },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], c_type)) return row[1];
    return null;
}

fn loadModule(g: *Gen, doc: Value) !void {
    try addSection(g, doc, "enums", .@"enum", &g.enums);
    try addSection(g, doc, "handles", .handle, &g.handles);
    try addSection(g, doc, "structs", .@"struct", &g.structs);
    try addSection(g, doc, "callbacks", .callback, &g.callbacks);
    try addSection(g, doc, "aliases", .alias, &g.aliases);
    try addSection(g, doc, "constants", null, &g.constants);
    try addSection(g, doc, "functions", null, &g.functions);
}

fn addSection(g: *Gen, doc: Value, key: []const u8, kind: ?Kind, list: *List(Entry)) !void {
    const sec = get(doc, key) orelse return;
    for (sec.map.keys(), sec.map.values()) |name, v| {
        if (!g.include_unstable and isUnstable(v)) {
            g.skipped_unstable += 1;
            continue;
        }
        if (kind) |k| try g.kinds.put(g.arena, name, k);
        try list.append(g.arena, .{ .name = name, .v = v });
    }
}

/// The state of a function is the one of the last entry of its lifecycle history.
fn lifecycle(v: Value) ?struct { state: []const u8, version: []const u8 } {
    const lc = get(v, "lifecycle") orelse return null;
    if (lc != .list or lc.list.len == 0) return null;
    const last = lc.list[lc.list.len - 1];
    if (last != .list or last.list.len < 2) return null;
    return .{ .state = last.list[0].scalar, .version = last.list[1].scalar };
}

fn isUnstable(v: Value) bool {
    const lc = lifecycle(v) orelse return false;
    return std.mem.eql(u8, lc.state, "unstable");
}

// --- emitting ------------------------------------------------------------------------------------

fn fileHeader(g: *Gen, w: *Io.Writer, meta: Value, title: []const u8, blurb: []const u8) !void {
    try w.print(
        \\//! {s} for the DuckDB v2 C API.
        \\//!
        \\//! Generated by tools/gen_v2_bindings.zig from the DuckDB v2 C API spec ({s}; schema {s}, API
        \\//! versions {s}); do not edit. Regenerate with `zig build gen-v2-bindings -Dv2-api-spec=<dir>`.
        \\//! Declaration names are the C names. {s}
        \\//! Pointer nullability is inferred from the parameter descriptions (see tools/gen_v2_bindings.zig).
        \\
        \\
    , .{ title, g.source, str(get(meta, "schema_version")) orelse "?", try versionList(g, meta), blurb });
}

fn emitTypes(g: *Gen, w: *Io.Writer, meta: Value) !void {
    try fileHeader(g, w, meta, "Types", "Shared by the static and the dynamic backend, which re-export them.");

    try w.writeAll(arrow_preamble);

    for (g.primitive_handles.items) |name| {
        try w.print("/// Opaque handle of the extension being loaded.\npub const {s} = *opaque {{}};\n\n", .{name});
    }

    try w.writeAll("// --- Constants ---------------------------------------------------------------------------------\n\n");
    for (g.constants.items) |c| {
        try writeDoc(w, "", str(get(c.v, "description")));
        try w.print("pub const {s}{s} = {s};\n\n", .{ g.upper, c.name, str(get(c.v, "value")).? });
    }

    try w.writeAll("// --- Enums -------------------------------------------------------------------------------------\n\n");
    for (g.enums.items) |e| try emitEnum(g, w, e);

    try w.writeAll("// --- Handles -----------------------------------------------------------------------------------\n\n");
    for (g.handles.items) |h| {
        try writeDoc(w, "", str(get(h.v, "description")));
        try w.print("pub const {s}{s}_handle = *opaque {{}};\n\n", .{ g.prefix, h.name });
    }

    try w.writeAll("// --- Structs -----------------------------------------------------------------------------------\n\n");
    for (g.structs.items) |s| {
        try writeDoc(w, "", str(get(s.v, "description")));
        try w.print("pub const {s}{s} = extern struct {{\n", .{ g.prefix, s.name });
        try writeFields(g, w, get(s.v, "fields").?.list, 1);
        try w.writeAll("};\n\n");
    }

    try w.writeAll("// --- Aliases -----------------------------------------------------------------------------------\n\n");
    for (g.aliases.items) |a| {
        try writeDoc(w, "", str(get(a.v, "description")));
        try w.print("pub const {s}{s}_t = ", .{ g.prefix, a.name });
        try writeType(g, w, str(get(a.v, "underlying")).?, 0, false, false, false);
        try w.writeAll(";\n\n");
    }

    try w.writeAll("// --- Callbacks ---------------------------------------------------------------------------------\n\n");
    for (g.callbacks.items) |cb| {
        if (get(cb.v, "description")) |d| try writeDoc(w, "", str(d)) else try w.print("/// Callback `{s}`; see the functions that take it.\n", .{cb.name});
        try w.print("pub const {s}{s}_fn = *const fn (", .{ g.prefix, cb.name });
        try writeParams(g, w, get(cb.v, "parameters").?);
        try w.writeAll(") callconv(.c) ");
        try writeReturn(g, w, cb.v);
        try w.writeAll(";\n\n");
    }
}

/// What the backends re-export: every declaration of the types file.
fn emitReexports(g: *Gen, w: *Io.Writer) !void {
    try w.writeAll("// --- Types, re-exported from the shared types module -------------------------------------------\n\n");
    for ([_][]const u8{ "ArrowSchema", "ArrowArray", "ArrowArrayStream" }) |name| try reexport(w, name);
    for (g.primitive_handles.items) |name| try reexport(w, name);
    for (g.constants.items) |c| try reexport2(w, g.upper, c.name, "");
    for (g.enums.items) |e| try reexport2(w, g.upper, e.name, "");
    for (g.handles.items) |h| try reexport2(w, g.prefix, h.name, "_handle");
    for (g.structs.items) |st| try reexport2(w, g.prefix, st.name, "");
    for (g.aliases.items) |a| try reexport2(w, g.prefix, a.name, "_t");
    for (g.callbacks.items) |cb| try reexport2(w, g.prefix, cb.name, "_fn");
    try w.writeAll("\n");
}

fn reexport(w: *Io.Writer, name: []const u8) !void {
    try w.print("/// See `duckdb_v2_types.zig`.\npub const {s} = duckdb_v2_types.{s};\n", .{ name, name });
}

fn reexport2(w: *Io.Writer, prefix: []const u8, name: []const u8, suffix: []const u8) !void {
    try w.print("/// See `duckdb_v2_types.zig`.\npub const {s}{s}{s} = duckdb_v2_types.{s}{s}{s};\n", .{ prefix, name, suffix, prefix, name, suffix });
}

fn emitStatic(g: *Gen, w: *Io.Writer, meta: Value) !void {
    try fileHeader(g, w, meta, "Static (direct-link) bindings", "Functions are plain externs, resolved at link time.");
    try w.writeAll("const duckdb_v2_types = @import(\"duckdb_v2_types\");\n\n");
    try emitReexports(g, w);

    try w.writeAll("// --- Functions ---------------------------------------------------------------------------------\n\n");
    for (g.functions.items) |f| {
        try writeFunctionDoc(w, f.v);
        try w.print("pub extern fn {s}{s}(", .{ g.prefix, f.name });
        try writeParams(g, w, get(f.v, "parameters").?);
        try w.writeAll(") ");
        try writeReturn(g, w, f.v);
        try w.writeAll(";\n\n");
    }
}

// --- the dynamic backend ---------------------------------------------------------------------------

/// The order of the members of `duckdb_ext_api_v2` is the ABI: DuckDB fills the table in that order.
/// The spec does not state it; the header generator derives it, and what it does today is: functions
/// that are unstable come last (they sit under `#if DUCKDB_V2_API_ALLOW_UNSTABLE`), and otherwise they
/// are ordered by the date of their first lifecycle entry, then by name. A new function therefore
/// appends. The parity test compares the result with the pinned header, member by member.
fn abiOrder(g: *Gen) ![]const Entry {
    const items = try g.arena.dupe(Entry, g.functions.items);
    std.mem.sort(Entry, items, {}, abiLessThan);
    return items;
}

fn introduced(v: Value) []const u8 {
    const lc = get(v, "lifecycle") orelse return "";
    if (lc != .list or lc.list.len == 0 or lc.list[0] != .list or lc.list[0].list.len < 3) return "";
    return lc.list[0].list[2].scalar;
}

fn abiLessThan(_: void, a: Entry, b: Entry) bool {
    const unstable_a = isUnstable(a.v);
    const unstable_b = isUnstable(b.v);
    if (unstable_a != unstable_b) return !unstable_a;
    switch (std.mem.order(u8, introduced(a.v), introduced(b.v))) {
        .lt => return true,
        .gt => return false,
        .eq => return std.mem.lessThan(u8, a.name, b.name),
    }
}

fn emitDynamic(g: *Gen, w: *Io.Writer, meta: Value) !void {
    try fileHeader(g, w, meta, "Dynamic (get_api) bindings", "Functions call through the table DuckDB hands out at load time.");
    try w.writeAll("const std = @import(\"std\");\nconst duckdb_v2_types = @import(\"duckdb_v2_types\");\n\n");
    try emitReexports(g, w);

    const ordered = try abiOrder(g);

    try w.writeAll("// --- The function table ----------------------------------------------------------------------\n\n");
    try w.print(
        \\/// The API version this file was generated for, to pass to `init`.
        \\pub const api_version: [*:0]const u8 = "{s}";
        \\
        \\/// The function-pointer table DuckDB hands out through `get_api`. The order of the members is the ABI.
        \\/// A member is null when the table DuckDB serves does not have the function.
        \\pub const Api = extern struct {{
        \\
    , .{latestVersion(meta)});
    for (ordered) |f| {
        try w.print("    {s}{s}: ?*const fn (", .{ g.prefix, f.name });
        try writeParams(g, w, get(f.v, "parameters").?);
        try w.writeAll(") callconv(.c) ");
        try writeReturn(g, w, f.v);
        try w.writeAll(",\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// The table in use, filled by `init`. A copy: DuckDB may free the one `get_api` returns once the
        \\/// entrypoint returns.
        \\pub var api: Api = std.mem.zeroes(Api);
        \\
        \\/// Fetches the function table. Call it first in the extension entrypoint: nothing else may be called
        \\/// before it succeeds. On failure return from the entrypoint without touching the error slot, since
        \\/// DuckDB has already recorded why `get_api` refused.
        \\pub fn init(input: *const duckdb_v2_extension_input, minimum_api_version: [*:0]const u8) bool {
        \\    const get_api = input.get_api orelse return false;
        \\    const table = get_api(input.extension, minimum_api_version) orelse return false;
        \\    // SAFETY: for the version asked for, `get_api` returns a pointer to the table that `Api` lays out;
        \\    // its member order is the ABI both sides were generated from.
        \\    const typed: *const Api = @ptrCast(@alignCast(table));
        \\    api = typed.*;
        \\    return true;
        \\}
        \\
        \\
    );

    try w.writeAll("// --- Functions -------------------------------------------------------------------------------\n\n");
    for (g.functions.items) |f| {
        try writeFunctionDoc(w, f.v);
        try w.print("pub inline fn {s}{s}(", .{ g.prefix, f.name });
        try writeParams(g, w, get(f.v, "parameters").?);
        try w.writeAll(") ");
        try writeReturn(g, w, f.v);
        try w.print(" {{\n    return api.{s}{s}.?(", .{ g.prefix, f.name });
        for (get(f.v, "parameters").?.map.keys(), 0..) |name, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{f}", .{std.zig.fmtId(name)});
        }
        try w.writeAll(");\n}\n\n");
    }
}

fn latestVersion(meta: Value) []const u8 {
    const versions = get(meta, "versions") orelse return "";
    return versions.list[versions.list.len - 1].scalar;
}

fn versionList(g: *Gen, meta: Value) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(g.arena);
    const versions = get(meta, "versions") orelse return "?";
    for (versions.list, 0..) |v, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.writeAll(v.scalar);
    }
    return buf.written();
}

fn emitEnum(g: *Gen, w: *Io.Writer, e: Entry) !void {
    try writeDoc(w, "", str(get(e.v, "description")));
    try w.print("pub const {s}{s} = enum(c_int) {{\n", .{ g.upper, e.name });

    const values = get(e.v, "values").?;
    var seen: std.AutoHashMapUnmanaged(i64, []const u8) = .empty;
    var aliases: List(struct { name: []const u8, target: []const u8 }) = .empty;
    var next: i64 = 0;

    for (values.map.keys(), values.map.values()) |name, v| {
        var literal: []const u8 = undefined;
        var n: i64 = undefined;
        if (str(get(v, "value"))) |s| {
            n = std.fmt.parseInt(i64, s, 0) catch fatal("enum {s}.{s}: bad value '{s}'", .{ e.name, name, s });
            literal = s;
        } else {
            n = next;
            literal = try std.fmt.allocPrint(g.arena, "{d}", .{n});
        }
        next = n + 1;

        if (seen.get(n)) |first| {
            // Zig enums cannot repeat a value, so a second name becomes a declaration.
            try aliases.append(g.arena, .{ .name = name, .target = first });
            continue;
        }
        try seen.put(g.arena, n, name);
        try writeDoc(w, "    ", str(get(v, "description")));
        try w.print("    {f} = {s},\n", .{ std.zig.fmtId(name), literal });
    }
    try w.writeAll("    _,\n");
    for (aliases.items) |a| {
        try w.print("\n    pub const {f}: @This() = .{f};\n", .{ std.zig.fmtId(a.name), std.zig.fmtId(a.target) });
    }
    try w.writeAll("};\n\n");
}

fn writeFields(g: *Gen, w: *Io.Writer, fields: []const Value, depth: usize) !void {
    for (fields) |f| {
        const name = str(get(f, "name")).?;
        try indent(w, depth);
        if (get(f, "union")) |members| {
            try w.print("{f}: extern union {{\n", .{std.zig.fmtId(name)});
            for (members.list) |m| {
                try indent(w, depth + 1);
                try w.print("{f}: extern struct {{\n", .{std.zig.fmtId(str(get(m, "name")).?)});
                try writeFields(g, w, get(m, "fields").?.list, depth + 2);
                try indent(w, depth + 1);
                try w.writeAll("},\n");
            }
            try indent(w, depth);
            try w.writeAll("},\n");
        } else if (get(f, "fields")) |nested| {
            try w.print("{f}: extern struct {{\n", .{std.zig.fmtId(name)});
            try writeFields(g, w, nested.list, depth + 1);
            try indent(w, depth);
            try w.writeAll("},\n");
        } else {
            try w.print("{f}: ", .{std.zig.fmtId(name)});
            if (get(f, "array_size")) |n| try w.print("[{s}]", .{n.scalar});
            const ptr = count(f, "pointer");
            const ty = str(get(f, "type")).?;
            // A pointer stored in a struct may be NULL (`{NULL, 0}` is the empty string view). One
            // to a scalar is an array (the validity mask and selection vector of a vector view are
            // views, not out-parameters); `char *` is dealt with by `writeType`.
            const kind = g.kinds.get(ty) orelse fatal("unknown type '{s}'", .{ty});
            const scalar = (kind == .primitive and !std.mem.eql(u8, ty, "void")) or kind == .alias;
            try writeType(g, w, ty, ptr, flag(f, "const"), ptr > 0, scalar);
            try w.writeAll(",\n");
        }
    }
}

fn indent(w: *Io.Writer, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("    ");
}

fn writeParams(g: *Gen, w: *Io.Writer, params: Value) !void {
    for (params.map.keys(), params.map.values(), 0..) |name, p, i| {
        if (i > 0) try w.writeAll(", ");
        const ind = count(p, "indirection");
        const ty = str(get(p, "type")).?;
        const by_value_handle = ind == 0 and (g.kinds.get(ty) orelse .primitive) == .handle;
        const optional = (ind > 0 or by_value_handle) and try isNullable(g.arena, str(get(p, "description")) orelse "");
        try w.print("{f}: ", .{std.zig.fmtId(name)});
        try writeType(g, w, ty, ind, flag(p, "const"), optional, false);
    }
}

/// The spec has no machine-readable nullability: it is only said in the prose of a parameter, as a
/// leading "Optional." or as "Pass NULL when ...". This is the weakest part of the generated types;
/// a `nullable: true` key in the spec would replace it.
fn isNullable(arena: Allocator, description: []const u8) !bool {
    const flat = try arena.dupe(u8, description);
    for (flat) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    if (std.mem.startsWith(u8, flat, "Optional")) return true;
    const phrases = [_][]const u8{ "Pass NULL", "pass NULL", "may be NULL", "May be NULL", "can be NULL", "Can be NULL" };
    for (phrases) |ph| if (std.mem.indexOf(u8, flat, ph) != null) return true;
    return false;
}

fn writeReturn(g: *Gen, w: *Io.Writer, v: Value) !void {
    const ty = str(get(v, "return_type")).?;
    if (count(v, "return_pointer") > 0) {
        try writeType(g, w, ty, 1, flag(v, "return_const"), true, false);
    } else {
        try writeType(g, w, ty, 0, false, false, false);
    }
}

/// Writes the Zig spelling of a spec type under `indirection` levels of pointer.
/// `const` applies to the innermost pointee; `optional` to the outermost pointer (or to the handle
/// itself, passed by value); `many` makes the innermost pointer a many-item pointer.
fn writeType(g: *Gen, w: *Io.Writer, ty: []const u8, indirection: usize, is_const: bool, optional: bool, many: bool) !void {
    const kind = g.kinds.get(ty) orelse fatal("unknown type '{s}'", .{ty});
    const is_char = std.mem.eql(u8, ty, "char");
    const is_void = std.mem.eql(u8, ty, "void");

    for (0..indirection) |level| {
        if (level == 0 and optional) try w.writeAll("?");
        const innermost = level == indirection - 1;
        // `char *` is a string or a buffer, never a single character.
        try w.writeAll(if (innermost and (is_char or many)) "[*]" else "*");
        if (innermost and is_const) try w.writeAll("const ");
    }

    // A handle is a pointer, so one passed by value can be NULL too.
    if (indirection == 0 and optional and kind == .handle) try w.writeAll("?");
    if (is_void) return w.writeAll(if (indirection > 0) "anyopaque" else "void");
    switch (kind) {
        .primitive => try w.writeAll(g.prims.get(ty).?),
        .handle => try w.print("{s}{s}_handle", .{ g.prefix, ty }),
        .@"enum" => try w.print("{s}{s}", .{ g.upper, ty }),
        .@"struct" => try w.print("{s}{s}", .{ g.prefix, ty }),
        .callback => try w.print("?{s}{s}_fn", .{ g.prefix, ty }),
        .alias => try w.print("{s}{s}_t", .{ g.prefix, ty }),
    }
}

// --- documentation -------------------------------------------------------------------------------

fn writeFunctionDoc(w: *Io.Writer, v: Value) !void {
    try writeDoc(w, "", str(get(v, "description")));
    if (lifecycle(v)) |lc| try w.print("///\n/// Lifecycle: {s} since {s}.\n", .{ lc.state, lc.version });
    const params = get(v, "parameters") orelse return;
    if (params.map.count() == 0) return;
    try w.writeAll("///\n");
    for (params.map.keys(), params.map.values()) |name, p| {
        try w.print("/// - `{s}`", .{name});
        if (str(get(p, "kind"))) |k| try w.print(" ({s})", .{k});
        try w.writeAll(": ");
        try writeInline(w, str(get(p, "description")) orelse "");
        try w.writeAll("\n");
    }
}

/// A description as `///` lines. `[[name]]` cross references become code spans.
fn writeDoc(w: *Io.Writer, pad: []const u8, text: ?[]const u8) !void {
    const t = std.mem.trim(u8, text orelse return, " \n\r");
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        try w.print("{s}///", .{pad});
        if (line.len > 0) {
            try w.writeAll(" ");
            try writeRefs(w, line);
        }
        try w.writeAll("\n");
    }
}

/// Collapses a multi-line description onto one line.
fn writeInline(w: *Io.Writer, text: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, text, " \n\r");
    var first = true;
    while (it.next()) |word| {
        if (!first) try w.writeAll(" ");
        first = false;
        try writeRefs(w, word);
    }
}

fn writeRefs(w: *Io.Writer, line: []const u8) !void {
    var rest = line;
    while (std.mem.indexOf(u8, rest, "[[")) |open| {
        try w.writeAll(rest[0..open]);
        const after = rest[open + 2 ..];
        const close = std.mem.indexOf(u8, after, "]]") orelse {
            try w.writeAll(rest[open..]);
            return;
        };
        // The spec often writes `[[name]]` inside backticks already.
        const quoted = open > 0 and rest[open - 1] == '`';
        if (quoted) try w.writeAll(after[0..close]) else try w.print("`{s}`", .{after[0..close]});
        rest = after[close + 2 ..];
    }
    try w.writeAll(rest);
}

/// The Arrow C data interface, which the spec references by its upstream struct names.
const arrow_preamble =
    \\/// The Arrow C data interface struct `ArrowSchema`.
    \\pub const ArrowSchema = extern struct {
    \\    format: ?[*:0]const u8,
    \\    name: ?[*:0]const u8,
    \\    metadata: ?[*:0]const u8,
    \\    flags: i64,
    \\    n_children: i64,
    \\    children: ?[*]?*ArrowSchema,
    \\    dictionary: ?*ArrowSchema,
    \\    release: ?*const fn (?*ArrowSchema) callconv(.c) void,
    \\    private_data: ?*anyopaque,
    \\};
    \\
    \\/// The Arrow C data interface struct `ArrowArray`.
    \\pub const ArrowArray = extern struct {
    \\    length: i64,
    \\    null_count: i64,
    \\    offset: i64,
    \\    n_buffers: i64,
    \\    n_children: i64,
    \\    buffers: ?[*]?*const anyopaque,
    \\    children: ?[*]?*ArrowArray,
    \\    dictionary: ?*ArrowArray,
    \\    release: ?*const fn (?*ArrowArray) callconv(.c) void,
    \\    private_data: ?*anyopaque,
    \\};
    \\
    \\/// The Arrow C data interface struct `ArrowArrayStream`.
    \\pub const ArrowArrayStream = extern struct {
    \\    get_schema: ?*const fn (?*ArrowArrayStream, ?*ArrowSchema) callconv(.c) c_int,
    \\    get_next: ?*const fn (?*ArrowArrayStream, ?*ArrowArray) callconv(.c) c_int,
    \\    get_last_error: ?*const fn (?*ArrowArrayStream) callconv(.c) ?[*:0]const u8,
    \\    release: ?*const fn (?*ArrowArrayStream) callconv(.c) void,
    \\    private_data: ?*anyopaque,
    \\};
    \\
    \\
;
