///! Standalone tool that appends DuckDB extension metadata to a shared library.
///!
///! Usage: append_metadata <input_lib> <ext_name> <duckdb_version> <ext_version> <abi_type> <platform> <output_file>
///!
///! This is invoked as a build step by build.zig. `platform` is passed in
///! explicitly by the caller rather than self-detected from this tool's
///! own compile target: this tool always runs on the build host (it has
///! to — the build needs its output immediately), but the library it's
///! stamping may be cross-compiled for a different target entirely, so
///! the host's own platform would be wrong for anything but a native
///! build.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next(); // skip program name

    const input_path = args.next() orelse return error.MissingArgument;
    const ext_name = args.next() orelse return error.MissingArgument;
    _ = ext_name;
    const duckdb_version = args.next() orelse return error.MissingArgument;
    const ext_version = args.next() orelse return error.MissingArgument;
    const abi_type = args.next() orelse return error.MissingArgument;
    const platform = args.next() orelse return error.MissingArgument;
    const output_path = args.next() orelse return error.MissingArgument;

    // Copy input to output
    const cwd = Dir.cwd();
    try cwd.copyFile(input_path, cwd, output_path, io, .{});

    // Open output for writing (append by seeking to end)
    const file = try cwd.openFile(io, output_path, .{ .mode = .write_only });
    defer file.close(io);

    // Get file size to seek to end
    const stat = try file.stat(io);
    const file_size = stat.size;

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.seekTo(file_size);

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
    try writer.interface.writeAll(&sig);

    // Write 8 x 32-byte padded fields (field8 down to field1)
    try writePaddedField(&writer, ""); // FIELD8 (unused)
    try writePaddedField(&writer, ""); // FIELD7 (unused)
    try writePaddedField(&writer, ""); // FIELD6 (unused)
    try writePaddedField(&writer, abi_type); // FIELD5 (abi_type)
    try writePaddedField(&writer, ext_version); // FIELD4 (extension_version)
    try writePaddedField(&writer, duckdb_version); // FIELD3 (duckdb_version)
    try writePaddedField(&writer, platform); // FIELD2 (platform)
    try writePaddedField(&writer, "4"); // FIELD1 (magic value)

    // Write 256 bytes for digital signature placeholder
    const zeroes: [256]u8 = @splat(0);
    try writer.interface.writeAll(&zeroes);

    try writer.flush();
}

/// Write a 32-byte zero-padded field to the output.
fn writePaddedField(writer: *File.Writer, value: []const u8) !void {
    var field: [32]u8 = @splat(0);
    const len = @min(value.len, 32);
    @memcpy(field[0..len], value[0..len]);
    try writer.interface.writeAll(&field);
}
