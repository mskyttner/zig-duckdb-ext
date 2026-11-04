///! Standalone tool for DuckDB's `.duckdb_extension` footer: signing it for loading via a
///! custom `CREATE EXTENSION REPOSITORY ... USING PUBLIC KEY` trust anchor, verifying a
///! signature independently of DuckDB itself, and inspecting the footer's own fields —
///! see docs/rationale/0004_extension-distribution-and-signing.md for the signing
///! investigation this came out of (confirmed live, 2026-10-15, that `LOAD <name> FROM
///! <repo>;` genuinely accepts a signature produced this exact way, with no `-unsigned`
///! flag needed) and docs/rationale/0005_a-package-for-extension-authors.md §6 for why this
///! tool is scoped to need nothing but `std` and DuckDB's own fixed footer format: it works
///! on any `.duckdb_extension` file, regardless of what built it — not something tied to
///! this project's own Zig/DuckDB bindings, unlike everything else in `src/`.
///!
///! Usage:
///!   sign_extension sign    <input.duckdb_extension> <private_key.pem> <output.duckdb_extension> [openssl_path]
///!   sign_extension verify  <input.duckdb_extension> <public_key.pem> [openssl_path]
///!   sign_extension inspect <input.duckdb_extension>
///!
///! `sign` reproduces DuckDB's own verification algorithm (the same in v2.0.0-alpha46057 and
///! alpha48730) exactly (`src/main/extension/extension_load.cpp`'s
///! `CheckExtensionSignature`/`ComputeFinalHash`, confirmed by reading that source, not
///! guessed): split the file minus its trailing 256-byte signature placeholder into 1MiB
///! chunks, SHA256 each chunk, concatenate the raw 32-byte digests, SHA256 that concatenation
///! once more — the "composite hash" — then RSA-sign it. `verify` does the identical hash
///! computation and checks the existing signature against it with `openssl pkeyutl -verify`
///! instead of writing a new one — independent of ever loading the extension into DuckDB
///! itself. The hashing happens entirely in this file via `std.crypto.hash.sha2.Sha256`;
///! only the actual RSA operation shells out to `openssl pkeyutl`, the one piece this project
///! isn't reimplementing (see the ADR for why: no pure-Zig RSA implementation found was
///! usable — none had the required PKCS#1v1.5 padding/DigestInfo construction, and linking a
///! full OpenSSL build from source for one operation was judged disproportionate).
///!
///! `inspect` parses the footer's own fields (`platform`/`duckdb_version`/
///! `extension_version`/`abi_type`, the same ones `append_metadata_main.zig` writes) without
///! touching any signature — "platform and versions come from the footer of each binary, not
///! from the artifact name" is also how `tobilg/duckdb-extension-self-hosting` (a comparable
///! tool for other extension authors) reads a binary, confirmed against its own README
///! before adopting the same approach here, not assumed independently. All three
///! subcommands validate the footer's own magic field first (`sign`/`verify` would otherwise
///! stamp a signature into, or check a signature against, bytes that were never DuckDB's
///! footer at all) and fail with a clear error on a file that isn't a recognized
///! `.duckdb_extension`, rather than only `contents.len > 256`. The footer parsing itself
///! lives in `lib/duckdb_extension_footer.zig`, shared with `extension_doctor_main.zig` (see
///! docs/rationale/0005_a-package-for-extension-authors.md §7) — this tool's second real
///! consumer, which is when it was actually worth factoring out rather than before.
///!
///! `openssl_path` must contain a `/` (an absolute or relative path, e.g.
///! `/usr/bin/openssl`), never a bare command name — confirmed earlier this session that
///! `std.process.spawn`'s PATH search (`SpawnOptions.Exe.detect`) doesn't actually resolve a
///! slash-free `argv[0]`, even when it's genuinely on `$PATH` (the same gap
///! `nethogs_trace.zig` already documents). Defaults to `/usr/bin/openssl` if omitted.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Sha256 = std.crypto.hash.sha2.Sha256;
const footer = @import("lib/duckdb_extension_footer.zig");

const signature_size = footer.signature_size;
const chunk_size: u64 = 1024 * 1024;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next(); // skip program name

    const command = args.next() orelse return printUsage();
    if (std.mem.eql(u8, command, "sign")) return cmdSign(init, &args);
    if (std.mem.eql(u8, command, "verify")) return cmdVerify(init, &args);
    if (std.mem.eql(u8, command, "inspect")) return cmdInspect(init, &args);

    std.debug.print("sign_extension: unknown command '{s}'\n", .{command});
    return printUsage();
}

fn cmdInspect(init: std.process.Init, args: anytype) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    const input_path = args.next() orelse {
        std.debug.print("Usage: sign_extension inspect <input.duckdb_extension>\n", .{});
        return 1;
    };

    const contents = try Dir.cwd().readFileAlloc(io, input_path, gpa, .unlimited);
    defer gpa.free(contents);

    const parsed = footer.parse(contents) catch |err| {
        std.debug.print("sign_extension: '{s}' is not a recognized .duckdb_extension footer: {s}\n", .{ input_path, @errorName(err) });
        return 1;
    };

    std.debug.print(
        "platform:           {s}\n" ++
            "duckdb_version:     {s}\n" ++
            "extension_version:  {s}\n" ++
            "abi_type:           {s}\n" ++
            "signed:             {}\n",
        .{
            parsed.fields.platform,
            parsed.fields.duckdb_version,
            parsed.fields.extension_version,
            parsed.fields.abi_type,
            parsed.isSigned(),
        },
    );
    return 0;
}

fn cmdSign(init: std.process.Init, args: anytype) !u8 {
    const io = init.io;
    const gpa = init.gpa;

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

    _ = footer.parse(contents) catch |err| {
        std.debug.print("sign_extension: '{s}' is not a recognized .duckdb_extension footer: {s}\n", .{ input_path, @errorName(err) });
        return 1;
    };

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

    if (!isPathish(openssl_path)) {
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

fn cmdVerify(init: std.process.Init, args: anytype) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    const input_path = args.next() orelse return printUsage();
    const public_key_path = args.next() orelse return printUsage();
    const openssl_path = args.next() orelse "/usr/bin/openssl";

    const cwd = Dir.cwd();
    const contents = try cwd.readFileAlloc(io, input_path, gpa, .unlimited);
    defer gpa.free(contents);

    const parsed = footer.parse(contents) catch |err| {
        std.debug.print("sign_extension: '{s}' is not a recognized .duckdb_extension footer: {s}\n", .{ input_path, @errorName(err) });
        return 1;
    };
    if (!parsed.isSigned()) {
        std.debug.print("sign_extension: '{s}' has no signature to verify (its signature slot is all zero)\n", .{input_path});
        return 1;
    }

    const hashed_region = contents[0 .. contents.len - signature_size];
    const composite_hash = computeCompositeHash(gpa, hashed_region) catch |err| {
        std.debug.print("sign_extension: failed to compute composite hash: {s}\n", .{@errorName(err)});
        return 1;
    };

    const hash_tmp_path = try std.fmt.allocPrint(gpa, "{s}.verify-hash.tmp", .{input_path});
    defer gpa.free(hash_tmp_path);
    const sig_tmp_path = try std.fmt.allocPrint(gpa, "{s}.verify-sig.tmp", .{input_path});
    defer gpa.free(sig_tmp_path);
    defer cwd.deleteFile(io, hash_tmp_path) catch {};
    defer cwd.deleteFile(io, sig_tmp_path) catch {};

    try cwd.writeFile(io, .{ .sub_path = hash_tmp_path, .data = &composite_hash });
    try cwd.writeFile(io, .{ .sub_path = sig_tmp_path, .data = parsed.signature });

    if (!isPathish(openssl_path)) {
        std.debug.print(
            "sign_extension: openssl_path '{s}' has no '/' — must be an absolute or relative path, not a bare command name\n",
            .{openssl_path},
        );
        return 1;
    }

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const spawn_io = io_impl.io();

    var child = try std.process.spawn(spawn_io, .{
        .argv = &.{
            openssl_path, "pkeyutl",       "-verify",  "-pubin",
            "-inkey",     public_key_path, "-pkeyopt", "digest:sha256",
            "-sigfile",   sig_tmp_path,    "-in",      hash_tmp_path,
        },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(spawn_io);
    if (!term.success()) {
        std.debug.print("sign_extension: signature verification FAILED for '{s}'\n", .{input_path});
        return 1;
    }

    std.debug.print("sign_extension: signature verification OK for '{s}'\n", .{input_path});
    return 0;
}

fn isPathish(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') != null;
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
        "Usage:\n" ++
            "  sign_extension sign    <input.duckdb_extension> <private_key.pem> <output.duckdb_extension> [openssl_path]\n" ++
            "  sign_extension verify  <input.duckdb_extension> <public_key.pem> [openssl_path]\n" ++
            "  sign_extension inspect <input.duckdb_extension>\n",
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

// Footer-parsing tests (`buildTestFooter`, "parse extracts fields...", etc.) now live in
// `lib/duckdb_extension_footer.zig`, the module they test — nothing footer-specific to test
// here anymore.
