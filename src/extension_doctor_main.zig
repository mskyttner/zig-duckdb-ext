///! Static-check tool for a built `.duckdb_extension` file — audits the artifact's own
///! structure before anyone tries to `LOAD` it, the way `R CMD check` audits an R package's
///! structure before anyone tries to use it. See
///! docs/rationale/0005_a-package-for-extension-authors.md §7 for the full scoping: this
///! exists because this project's own "rules an author learns by hitting it" (ADR-0005's
///! Context section) include two that are purely structural — wrong `abi_type`/version, and
///! a renamed file's entry-point symbol silently mismatching — both inspectable from the
///! binary alone, no DuckDB involved.
///!
///! Usage: extension_doctor <path.duckdb_extension>
///!
///! Checks the footer's own fields (via `lib/duckdb_extension_footer.zig`, shared with
///! `sign_extension_main.zig` — this tool is its second real consumer, which is when it was
///! actually worth factoring out, not before): a recognized `abi_type` (`C_STRUCT` or
///! `C_STRUCT_UNSTABLE`), a recognized platform string (the same list `build.zig`'s own
///! `duckdbPlatformString`/`WasmVariant.platform()` produce), and non-empty
///! `duckdb_version`/`extension_version` fields.
///!
///! Then checks the binary's own exported-symbol table for the entry point DuckDB will
///! actually look up at `LOAD` time. The footer does *not* record the extension's own name
///! (confirmed by reading `append_metadata_main.zig`: it takes `ext_name` as an argument and
///! explicitly discards it, `_ = ext_name;`), so the expected symbol is derived from the
///! file's own name on disk — `<name>.duckdb_extension` → expect `<name>_init_c_api`
///! (`abi_type = C_STRUCT`) or `<name>_init_c_api_v2` (`C_STRUCT_UNSTABLE`). This is exactly
///! the right check, not a workaround for the footer gap: the real failure mode ADR-0005
///! documents is specifically a *renamed copy*, so "does the symbol match this file's current
///! name" is the right question.
///!
///! Only ELF (Linux) symbol-table parsing is implemented, via `std.elf` — proven live against
///! a real built extension before this tool was written (footer bytes appended after a valid
///! ELF image don't disturb offset-based section-header parsing at all). Mach-O (macOS), PE
///! (Windows) and wasm export-table parsing are each the same shape of work
///! (`std.macho`/`std.coff`/`std.wasm` all exist in the stdlib) but unattempted — a
///! non-ELF file is reported as a WARNING ("symbol check not supported for this format yet"),
///! not a FAIL, so the doctor degrades to footer-only checking on those platforms instead of
///! refusing to run at all.
///!
///! Explicitly deferred, not in scope here: anything needing a real `LOAD` (whether
///! `duckdb_functions()` would show `a0`/`a1` for a missing `FunctionNamed` — only observable
///! at runtime, needing `sqllogictest_main`/`verify_wasm_load*`'s CLI-driving machinery, not a
///! binary inspector) and whole-`dist/`-tree consistency checks across platforms.
const std = @import("std");
const footer = @import("lib/duckdb_extension_footer.zig");

const Level = enum { pass, warn, fail };

const Finding = struct {
    level: Level,
    message: []const u8,
};

/// The platform strings this project's own build ever produces — `build.zig`'s
/// `duckdbPlatformString` (native) and `WasmVariant.platform()` (wasm) — kept as a literal
/// list here rather than shared with `build.zig`, since a build-time function and a
/// standalone runtime tool have no natural shared module today; worth revisiting if this list
/// drifts in practice.
const known_platforms = [_][]const u8{
    "linux_amd64", "linux_amd64_musl", "linux_arm64",   "linux_arm64_musl",
    "osx_amd64",   "osx_arm64",        "windows_amd64", "windows_arm64",
    "wasm_mvp",    "wasm_eh",          "wasm_threads",
};

const known_abi_types = [_][]const u8{ "C_STRUCT", "C_STRUCT_UNSTABLE" };

fn isKnown(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

/// `<name>.duckdb_extension` → `<name>` — the file's own current name, which is what DuckDB's
/// loader derives the expected symbol from, not anything recorded in the footer (it records
/// nothing of the sort — see this file's own doc comment).
fn extensionNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const suffix = ".duckdb_extension";
    if (std.mem.endsWith(u8, base, suffix)) return base[0 .. base.len - suffix.len];
    return base;
}

/// The symbol DuckDB's own loader looks up, derived from the file's current name and the
/// footer's own `abi_type` — `C_STRUCT` (v1, the stable C API) uses `<name>_init_c_api`;
/// `C_STRUCT_UNSTABLE` (v2) uses `<name>_init_c_api_v2`, the same convention
/// `addWasmEmscriptenBuild`/`addV2CrossBuild` already use on the build side.
fn expectedSymbol(gpa: std.mem.Allocator, ext_name: []const u8, abi_type: []const u8) ![]const u8 {
    if (std.mem.eql(u8, abi_type, "C_STRUCT_UNSTABLE")) {
        return std.fmt.allocPrint(gpa, "{s}_init_c_api_v2", .{ext_name});
    }
    return std.fmt.allocPrint(gpa, "{s}_init_c_api", .{ext_name});
}

const Format = enum { elf, macho, pe, wasm, unknown };

fn detectFormat(contents: []const u8) Format {
    if (contents.len < 4) return .unknown;
    if (std.mem.eql(u8, contents[0..4], "\x7fELF")) return .elf;
    if (std.mem.eql(u8, contents[0..4], "\x00asm")) return .wasm;
    if (std.mem.eql(u8, contents[0..2], "MZ")) return .pe;
    const magic32 = std.mem.readInt(u32, contents[0..4], .big);
    if (magic32 == 0xFEEDFACE or magic32 == 0xFEEDFACF or magic32 == 0xCAFEBABE or magic32 == 0xCAFEBABF) return .macho;
    return .unknown;
}

/// Reads the ELF dynamic symbol table and reports whether `expected_symbol` is among the
/// defined (non-undefined) entries — proven live against a real built extension before this
/// tool was written: the trailing DuckDB footer, appended after a valid ELF image, does not
/// disturb offset-based section-header parsing at all.
fn checkElfSymbol(allocator: std.mem.Allocator, io: std.Io, path: []const u8, expected_symbol: []const u8, findings: *std.ArrayList(Finding)) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const header = std.elf.Header.read(&file_reader.interface) catch {
        try findings.append(allocator, .{ .level = .warn, .message = "could not parse ELF header; skipping symbol check" });
        return;
    };

    var section_it = header.iterateSectionHeaders(&file_reader);
    var dynsym: ?std.elf.Elf64_Shdr = null;
    var dynstr_idx: u32 = 0;
    while (try section_it.next()) |shdr| {
        if (shdr.sh_type == std.elf.SHT_DYNSYM) {
            dynsym = shdr;
            dynstr_idx = shdr.sh_link;
        }
    }
    const sym_shdr = dynsym orelse {
        try findings.append(allocator, .{ .level = .warn, .message = "no dynamic symbol table (SHT_DYNSYM) found; skipping symbol check" });
        return;
    };

    try file_reader.seekTo(0);
    var section_it2 = header.iterateSectionHeaders(&file_reader);
    var strtab_shdr: ?std.elf.Elf64_Shdr = null;
    var idx: u32 = 0;
    while (try section_it2.next()) |shdr| {
        if (idx == dynstr_idx) strtab_shdr = shdr;
        idx += 1;
    }
    const str_shdr = strtab_shdr orelse {
        try findings.append(allocator, .{ .level = .warn, .message = "dynamic symbol table has no matching string table; skipping symbol check" });
        return;
    };

    // A second read of the same file — the first (in `main`) only needed the leading bytes
    // `detectFormat`/`footer.parse` look at; this one needs the symbol/string table's own
    // byte ranges, which `std.elf`'s API has no helper for extracting directly. Allocated
    // from the same arena `main` passed in, so no `defer ... free` needed here either.
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    const strtab = contents[str_shdr.sh_offset..][0..str_shdr.sh_size];
    const sym_bytes = contents[sym_shdr.sh_offset..][0..sym_shdr.sh_size];
    const num_syms = sym_bytes.len / @sizeOf(std.elf.Elf64_Sym);
    const syms: [*]const std.elf.Elf64_Sym = @ptrCast(@alignCast(sym_bytes.ptr));

    var found = false;
    for (0..num_syms) |i| {
        const sym = syms[i];
        if (sym.st_name == 0 or sym.st_shndx == 0) continue; // skip unnamed/undefined entries
        const name_end = std.mem.indexOfScalar(u8, strtab[sym.st_name..], 0) orelse continue;
        const name = strtab[sym.st_name..][0..name_end];
        if (std.mem.eql(u8, name, expected_symbol)) {
            found = true;
            break;
        }
    }

    if (found) {
        try findings.append(allocator, .{ .level = .pass, .message = try std.fmt.allocPrint(allocator, "entry-point symbol '{s}' found in the ELF dynamic symbol table", .{expected_symbol}) });
    } else {
        try findings.append(allocator, .{ .level = .fail, .message = try std.fmt.allocPrint(allocator, "entry-point symbol '{s}' NOT found — DuckDB's LOAD will fail with \"did not contain function...\" (renamed file, or a build/name mismatch?)", .{expected_symbol}) });
    }
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    // A short-lived CLI tool exiting right after printing its report — the arena, like
    // `sqllogictest_main.zig`'s own `main`, is torn down whole at process exit, so every
    // `allocPrint`'d finding message below needs no individual `defer ... free`.
    const arena = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.next(); // skip program name
    const path = args.next() orelse {
        std.debug.print("usage: extension_doctor <path.duckdb_extension>\n", .{});
        return 1;
    };

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);

    var findings: std.ArrayList(Finding) = .empty;

    const parsed = footer.parse(contents) catch |err| {
        std.debug.print("extension_doctor: '{s}' is not a recognized .duckdb_extension footer: {s}\n", .{ path, @errorName(err) });
        return 1;
    };

    if (isKnown(&known_abi_types, parsed.fields.abi_type)) {
        try findings.append(arena, .{ .level = .pass, .message = try std.fmt.allocPrint(arena, "abi_type '{s}' is recognized", .{parsed.fields.abi_type}) });
    } else {
        try findings.append(arena, .{ .level = .fail, .message = try std.fmt.allocPrint(arena, "abi_type '{s}' is not one of {{C_STRUCT, C_STRUCT_UNSTABLE}}", .{parsed.fields.abi_type}) });
    }

    if (isKnown(&known_platforms, parsed.fields.platform)) {
        try findings.append(arena, .{ .level = .pass, .message = try std.fmt.allocPrint(arena, "platform '{s}' is recognized", .{parsed.fields.platform}) });
    } else {
        try findings.append(arena, .{ .level = .warn, .message = try std.fmt.allocPrint(arena, "platform '{s}' is not in this tool's known list (may just be stale — check known_platforms)", .{parsed.fields.platform}) });
    }

    if (parsed.fields.duckdb_version.len == 0) {
        try findings.append(arena, .{ .level = .fail, .message = "duckdb_version field is empty" });
    } else {
        try findings.append(arena, .{ .level = .pass, .message = try std.fmt.allocPrint(arena, "duckdb_version: '{s}'", .{parsed.fields.duckdb_version}) });
    }

    if (parsed.fields.extension_version.len == 0) {
        try findings.append(arena, .{ .level = .fail, .message = "extension_version field is empty" });
    } else {
        try findings.append(arena, .{ .level = .pass, .message = try std.fmt.allocPrint(arena, "extension_version: '{s}'", .{parsed.fields.extension_version}) });
    }

    const ext_name = extensionNameFromPath(path);
    const expected_symbol = try expectedSymbol(arena, ext_name, parsed.fields.abi_type);

    switch (detectFormat(contents)) {
        .elf => try checkElfSymbol(arena, io, path, expected_symbol, &findings),
        .macho => try findings.append(arena, .{ .level = .warn, .message = "Mach-O symbol-table check not implemented yet; skipping" }),
        .pe => try findings.append(arena, .{ .level = .warn, .message = "PE export-table check not implemented yet; skipping" }),
        .wasm => try findings.append(arena, .{ .level = .warn, .message = "wasm export-table check not implemented yet; skipping" }),
        .unknown => try findings.append(arena, .{ .level = .warn, .message = "unrecognized binary format; skipping symbol check" }),
    }

    var fails: usize = 0;
    var warns: usize = 0;
    for (findings.items) |finding| {
        const tag = switch (finding.level) {
            .pass => "PASS",
            .warn => "WARN",
            .fail => "FAIL",
        };
        std.debug.print("[{s}] {s}\n", .{ tag, finding.message });
        if (finding.level == .fail) fails += 1;
        if (finding.level == .warn) warns += 1;
    }

    std.debug.print("extension_doctor: {d} fail, {d} warn, {d} pass ({s})\n", .{ fails, warns, findings.items.len - fails - warns, path });
    return if (fails > 0) 1 else 0;
}

test "extensionNameFromPath strips directory and the .duckdb_extension suffix" {
    try std.testing.expectEqualStrings("zig_ext_v2_poc", extensionNameFromPath("zig-out/lib/zig_ext_v2_poc.duckdb_extension"));
    try std.testing.expectEqualStrings("zig_ext", extensionNameFromPath("zig_ext.duckdb_extension"));
}

test "expectedSymbol picks the v1 vs v2 entry-point convention from abi_type" {
    const gpa = std.testing.allocator;
    const v1 = try expectedSymbol(gpa, "zig_ext", "C_STRUCT");
    defer gpa.free(v1);
    try std.testing.expectEqualStrings("zig_ext_init_c_api", v1);

    const v2 = try expectedSymbol(gpa, "zig_ext_v2", "C_STRUCT_UNSTABLE");
    defer gpa.free(v2);
    try std.testing.expectEqualStrings("zig_ext_v2_init_c_api_v2", v2);
}

test "detectFormat recognizes ELF, wasm and PE magic bytes" {
    try std.testing.expectEqual(Format.elf, detectFormat("\x7fELF\x02\x01\x01\x00"));
    try std.testing.expectEqual(Format.wasm, detectFormat("\x00asm\x01\x00\x00\x00"));
    try std.testing.expectEqual(Format.pe, detectFormat("MZ\x90\x00"));
    try std.testing.expectEqual(Format.unknown, detectFormat("not a binary"));
}

test "isKnown matches exactly, not a prefix or substring" {
    try std.testing.expect(isKnown(&known_abi_types, "C_STRUCT"));
    try std.testing.expect(isKnown(&known_abi_types, "C_STRUCT_UNSTABLE"));
    try std.testing.expect(!isKnown(&known_abi_types, "C_STRUCT_UNSTABL"));
    try std.testing.expect(!isKnown(&known_abi_types, "CPP"));
}
