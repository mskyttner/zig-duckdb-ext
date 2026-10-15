///! Standalone tool that signs a `.duckdb_extension` file for loading via
///! a custom `CREATE EXTENSION REPOSITORY ... USING PUBLIC KEY` trust
///! anchor — see docs/rationale/0004_extension-distribution-and-signing.md
///! for the full investigation this came out of (confirmed live, 2026-10-15,
///! that `LOAD <name> FROM <repo>;` genuinely accepts a signature produced
///! this exact way, with no `-unsigned` flag needed).
///!
///! Usage: sign_extension <input.duckdb_extension> <private_key.pem> <output.duckdb_extension> [openssl_path]
///!
///! Reproduces DuckDB's own v2.0.0-alpha46057 verification algorithm
///! exactly (`src/main/extension/extension_load.cpp`'s
///! `CheckExtensionSignature`/`ComputeFinalHash`, confirmed by reading
///! that source, not guessed): split the file minus its trailing 256-byte
///! signature placeholder into 1MiB chunks, SHA256 each chunk, concatenate
///! the raw 32-byte digests, SHA256 that concatenation once more — the
///! "composite hash" — then RSA-sign it. The hashing happens entirely in
///! this file via `std.crypto.hash.sha2.Sha256`; only the actual RSA
///! private-key operation shells out to `openssl pkeyutl -sign`, the one
///! piece this project isn't reimplementing (see the ADR for why: no
///! pure-Zig RSA implementation found was usable — none had the required
///! PKCS#1v1.5 padding/DigestInfo construction, and linking a full OpenSSL
///! build from source for one operation was judged disproportionate).
///!
///! `openssl_path` must contain a `/` (an absolute or relative path, e.g.
///! `/usr/bin/openssl`), never a bare command name — confirmed earlier
///! this session that `std.process.spawn`'s PATH search
///! (`SpawnOptions.Exe.detect`) doesn't actually resolve a slash-free
///! `argv[0]`, even when it's genuinely on `$PATH` (the same gap
///! `nethogs_trace.zig` already documents). Defaults to `/usr/bin/openssl`
///! if omitted.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Sha256 = std.crypto.hash.sha2.Sha256;

const signature_size: u64 = 256;
const chunk_size: u64 = 1024 * 1024;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next(); // skip program name

    const input_path = args.next() orelse return printUsage();
    const private_key_path = args.next() orelse return printUsage();
    const output_path = args.next() orelse return printUsage();
    const openssl_path = args.next() orelse "/usr/bin/openssl";

    const cwd = Dir.cwd();

    if (!std.mem.eql(u8, input_path, output_path)) {
        try cwd.copyFile(input_path, cwd, output_path, io, .{});
    }

    const contents = try cwd.readFileAlloc(io, output_path, gpa, .unlimited);
    defer gpa.free(contents);

    if (contents.len <= signature_size) return error.FileTooSmallToSign;
    const hashed_len = contents.len - signature_size;
    const hashed_region = contents[0..hashed_len];

    const composite_hash = computeCompositeHash(gpa, hashed_region) catch |err| {
        std.debug.print("sign_extension: failed to compute composite hash: {s}\n", .{@errorName(err)});
        return 1;
    };

    const hash_tmp_path = try std.fmt.allocPrint(gpa, "{s}.hash.tmp", .{output_path});
    defer gpa.free(hash_tmp_path);
    const sig_tmp_path = try std.fmt.allocPrint(gpa, "{s}.sig.tmp", .{output_path});
    defer gpa.free(sig_tmp_path);
    defer cwd.deleteFile(io, hash_tmp_path) catch {};
    defer cwd.deleteFile(io, sig_tmp_path) catch {};

    try cwd.writeFile(io, .{ .sub_path = hash_tmp_path, .data = &composite_hash });

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const spawn_io = io_impl.io();

    if (std.mem.indexOfScalar(u8, openssl_path, '/') == null) {
        std.debug.print(
            "sign_extension: openssl_path '{s}' has no '/' — must be an absolute or relative path, not a bare command name (std.process.spawn's PATH search does not resolve bare names, confirmed live)\n",
            .{openssl_path},
        );
        return 1;
    }

    var child = try std.process.spawn(spawn_io, .{
        .argv = &.{
            openssl_path,    "pkeyutl",        "-sign",
            "-inkey",        private_key_path, "-pkeyopt",
            "digest:sha256", "-in",            hash_tmp_path,
            "-out",          sig_tmp_path,
        },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(spawn_io);
    if (!term.success()) {
        std.debug.print("sign_extension: openssl pkeyutl -sign failed\n", .{});
        return 1;
    }

    const signature = try cwd.readFileAlloc(io, sig_tmp_path, gpa, .limited(signature_size + 1));
    defer gpa.free(signature);
    if (signature.len != signature_size) {
        std.debug.print(
            "sign_extension: expected a {d}-byte RSA-2048 signature, got {d} bytes — is the key really 2048-bit RSA?\n",
            .{ signature_size, signature.len },
        );
        return 1;
    }

    const file = try cwd.openFile(io, output_path, .{ .mode = .write_only });
    defer file.close(io);
    var buf: [signature_size]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.seekTo(hashed_len);
    try writer.interface.writeAll(signature);
    try writer.flush();

    std.debug.print("sign_extension: wrote a {d}-byte signature into '{s}'\n", .{ signature.len, output_path });
    return 0;
}

/// `src/main/extension/extension_load.cpp`'s `ComputeFinalHash` +
/// `InitializeAncillaryData` + `ComputeSHA256FileSegment`, reproduced
/// exactly: per-1MiB-chunk SHA256 (a single hash over each full chunk is
/// equivalent to DuckDB's own incremental 8KiB-at-a-time feeding of the
/// same bytes — SHA256 is a standard streaming-safe construction), the
/// raw 32-byte digests concatenated, SHA256 of that concatenation.
fn computeCompositeHash(gpa: std.mem.Allocator, data: []const u8) ![Sha256.digest_length]u8 {
    const num_chunks = (data.len + chunk_size - 1) / chunk_size;
    const digests = try gpa.alloc(u8, num_chunks * Sha256.digest_length);
    defer gpa.free(digests);

    var offset: usize = 0;
    var i: usize = 0;
    while (offset < data.len) : (i += 1) {
        const end = @min(offset + chunk_size, data.len);
        Sha256.hash(data[offset..end], digests[i * Sha256.digest_length ..][0..Sha256.digest_length], .{});
        offset = end;
    }

    var result: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(digests, &result, .{});
    return result;
}

fn printUsage() u8 {
    std.debug.print(
        "Usage: sign_extension <input.duckdb_extension> <private_key.pem> <output.duckdb_extension> [openssl_path]\n",
        .{},
    );
    return 1;
}

test "computeCompositeHash matches a hand-computed single-chunk case" {
    const gpa = std.testing.allocator;
    const data = "hello world, this is a tiny test file under one chunk";

    // For data smaller than one chunk, the composite hash is just
    // SHA256(SHA256(data)) — one chunk digest, hashed again.
    var inner: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &inner, .{});
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&inner, &expected, .{});

    const actual = try computeCompositeHash(gpa, data);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "computeCompositeHash handles a multi-chunk boundary correctly" {
    const gpa = std.testing.allocator;
    const data = try gpa.alloc(u8, chunk_size + 100);
    defer gpa.free(data);
    for (data, 0..) |*b, idx| b.* = @truncate(idx);

    var chunk1: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data[0..chunk_size], &chunk1, .{});
    var chunk2: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data[chunk_size..], &chunk2, .{});

    var concat: [Sha256.digest_length * 2]u8 = undefined;
    @memcpy(concat[0..Sha256.digest_length], &chunk1);
    @memcpy(concat[Sha256.digest_length..], &chunk2);

    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&concat, &expected, .{});

    const actual = try computeCompositeHash(gpa, data);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
