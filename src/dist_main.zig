///! Standalone tool that arranges `zig build cross`'s output into the
///! layout DuckDB's `INSTALL ... FROM '<url>'` custom-extension-repository
///! mechanism expects: `<dist_dir>/<dist_version>/<platform>/<ext_name>.duckdb_extension.gz`.
///!
///! Usage: dist_main <lib_dir> <dist_dir> <ext_name> <dist_version>
///!
///! `lib_dir` is expected to contain one subdirectory per platform (as
///! `zig build cross` produces under zig-out/lib/<platform>/), each
///! optionally holding `<ext_name>.duckdb_extension`. Platforms missing
///! that file are silently skipped — not every target need be built
///! every time. `dist_version` is the DuckDB CLIENT version directory
///! name (e.g. "v1.5.6"), a separate concern from the extension's own
///! ABI-compat minimum (`target_duckdb_version` in build.zig) — see
///! docs/rationale/0004_extension-distribution-and-signing.md.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next(); // skip program name

    const lib_dir_path = args.next() orelse return error.MissingArgument;
    const dist_dir_path = args.next() orelse return error.MissingArgument;
    const ext_name = args.next() orelse return error.MissingArgument;
    const dist_version = args.next() orelse return error.MissingArgument;

    const cwd = Dir.cwd();
    var lib_dir = try cwd.openDir(io, lib_dir_path, .{ .iterate = true });
    defer lib_dir.close(io);

    const ext_file_name = try std.fmt.allocPrint(gpa, "{s}.duckdb_extension", .{ext_name});
    defer gpa.free(ext_file_name);

    var found: usize = 0;
    var it = lib_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const platform = entry.name;

        var platform_dir = lib_dir.openDir(io, platform, .{}) catch continue;
        defer platform_dir.close(io);

        var input_file = platform_dir.openFile(io, ext_file_name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer input_file.close(io);

        const out_dir_rel = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ dist_dir_path, dist_version, platform });
        defer gpa.free(out_dir_rel);
        try cwd.createDirPath(io, out_dir_rel);

        const out_file_path = try std.fmt.allocPrint(gpa, "{s}/{s}.gz", .{ out_dir_rel, ext_file_name });
        defer gpa.free(out_file_path);

        var out_file = try cwd.createFile(io, out_file_path, .{});
        defer out_file.close(io);

        var read_buf: [4096]u8 = undefined;
        var file_reader: File.Reader = .init(input_file, io, &read_buf);

        var write_buf: [4096]u8 = undefined;
        var file_writer = out_file.writer(io, &write_buf);

        var compress_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(&file_writer.interface, &compress_buf, .gzip, .level_9);
        _ = try file_reader.interface.streamRemaining(&compress.writer);
        try compress.finish();
        try file_writer.interface.flush();

        std.debug.print("packaged {s}\n", .{out_file_path});
        found += 1;
    }

    if (found == 0) {
        std.debug.print("no cross-built extension artifacts found under {s}/*/{s}\n", .{ lib_dir_path, ext_file_name });
        return 1;
    }

    std.debug.print("published {d} platform artifact(s)\n", .{found});
    return 0;
}
