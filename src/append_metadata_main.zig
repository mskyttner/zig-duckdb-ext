///! Standalone tool that appends DuckDB extension metadata to a shared library.
///!
///! Usage: append_metadata <input_lib> <ext_name> <duckdb_version> <ext_version> <abi_type> <output_file>
///!
///! This is invoked as a build step by build.zig.
const std = @import("std");

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip program name

    const input_path = args.next() orelse return error.MissingArgument;
    const ext_name = args.next() orelse return error.MissingArgument;
    _ = ext_name;
    const duckdb_version = args.next() orelse return error.MissingArgument;
    const ext_version = args.next() orelse return error.MissingArgument;
    const abi_type = args.next() orelse return error.MissingArgument;
    const output_path = args.next() orelse return error.MissingArgument;

    // Detect platform
    const platform = detectPlatform();

    // Copy input to output
    const cwd = std.fs.cwd();
    try cwd.copyFile(input_path, cwd, output_path, .{});

    // Open output for appending
    const file = try cwd.openFile(output_path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);

    // Write start signature (wasm-compat preamble)
    const sig = [_]u8{
        0x00, // custom section
        0x93, 0x04, // LEB128(531)
        0x10, // name length = 16
        'd',
        'u',
        'c',
        'k',
        'd',
        'b',
        '_',
        's',
        'i',
        'g',
        'n',
        'a',
        't',
        'u',
        'r',
        'e',
        0x80, 0x04, // LEB128(512)
    };
    try file.writeAll(&sig);

    // Write 8 x 32-byte padded fields (field8 down to field1)
    try writePaddedField(file, ""); // FIELD8 (unused)
    try writePaddedField(file, ""); // FIELD7 (unused)
    try writePaddedField(file, ""); // FIELD6 (unused)
    try writePaddedField(file, abi_type); // FIELD5 (abi_type)
    try writePaddedField(file, ext_version); // FIELD4 (extension_version)
    try writePaddedField(file, duckdb_version); // FIELD3 (duckdb_version)
    try writePaddedField(file, platform); // FIELD2 (platform)
    try writePaddedField(file, "4"); // FIELD1 (magic value)

    // Write 256 bytes for digital signature placeholder
    const zeroes = [_]u8{0} ** 256;
    try file.writeAll(&zeroes);

    // Log to stderr
    const stderr = std.fs.File.stderr();
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Created DuckDB extension: {s}\n  Platform: {s}\n  DuckDB version: {s}\n  Extension version: {s}\n  ABI type: {s}\n", .{ output_path, platform, duckdb_version, ext_version, abi_type }) catch "metadata appended\n";
    stderr.writeAll(msg) catch {};
}

fn writePaddedField(file: std.fs.File, value: []const u8) !void {
    var field: [32]u8 = [_]u8{0} ** 32;
    const len = @min(value.len, 32);
    @memcpy(field[0..len], value[0..len]);
    try file.writeAll(&field);
}

fn detectPlatform() []const u8 {
    const builtin = @import("builtin");
    const os = builtin.target.os.tag;
    const arch = builtin.target.cpu.arch;

    if (os == .macos) {
        if (arch == .aarch64) return "osx_arm64";
        if (arch == .x86_64) return "osx_amd64";
    }
    if (os == .linux) {
        if (arch == .aarch64) return "linux_arm64";
        if (arch == .x86_64) return "linux_amd64";
    }
    if (os == .windows) {
        if (arch == .x86_64) return "windows_amd64";
    }
    return "unknown";
}
