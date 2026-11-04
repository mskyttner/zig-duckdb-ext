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
///! `.duckdb_extension`, rather than only `contents.len > 256`.
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

const signature_size: u64 = 256;
const footer_size: u64 = 512;
const field_size: usize = 32;
const num_fields: usize = 8;
const chunk_size: u64 = 1024 * 1024;

/// `FIELD1`'s own fixed content — `append_metadata_main.zig`'s magic value, written into
/// every footer this project (or a compatible tool) produces. Not DuckDB's own invention;
/// this project's own convention for recognizing its footer before trusting the rest of it.
const expected_magic = "4";

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

/// The footer's own fields, borrowed from whatever buffer `parseFooter` was given — valid
/// exactly as long as that buffer is. Field names match `append_metadata_main.zig`'s own
/// parameter names, not the on-disk `FIELD1`..`FIELD8` numbering (`magic` is `FIELD1`,
/// `platform` is `FIELD2`, and so on down to `abi_type` as `FIELD5`; `FIELD6`-`FIELD8` are
/// unused today and not exposed here).
const FooterFields = struct {
    magic: []const u8,
    platform: []const u8,
    duckdb_version: []const u8,
    extension_version: []const u8,
    abi_type: []const u8,
};

const ParsedFooter = struct {
    fields: FooterFields,
    signature: []const u8,

    /// `append_metadata_main.zig` always writes a signature slot, signed or not — an
    /// unsigned extension's slot is all zero bytes (never written over), which is the one
    /// reliable way to tell "no signature yet" from "a real one", since a real RSA-2048
    /// signature over a non-empty hash is vanishingly unlikely to be all zero.
    fn isSigned(self: ParsedFooter) bool {
        return !std.mem.allEqual(u8, self.signature, 0);
    }
};

/// Trims trailing zero padding from a fixed-width footer field — `append_metadata_main.zig`'s
/// `writePaddedField` zero-pads every field to `field_size`, never truncates a name shorter
/// than that with anything but zeros (no embedded NUL is possible in any value this project's
/// own build ever passes: extension names, versions and the fixed ABI-type strings).
fn trimPadded(field: []const u8) []const u8 {
    var end = field.len;
    while (end > 0 and field[end - 1] == 0) end -= 1;
    return field[0..end];
}

/// Parses the trailing 512-byte footer `append_metadata_main.zig` writes (8 x 32-byte padded
/// fields, written field8-down-to-field1, followed by a 256-byte signature slot) out of
/// `contents` — the whole file's own bytes, not just the footer, since the composite hash
/// `sign`/`verify` need covers everything *except* the trailing signature, which is most of
/// `contents`. Fails with `error.NotADuckdbExtensionFooter` on anything whose `FIELD1` isn't
/// this project's own magic value — never silently treats an arbitrary file's trailing bytes
/// as a real footer.
fn parseFooter(contents: []const u8) !ParsedFooter {
    if (contents.len < footer_size) return error.FileTooSmallForFooter;
    const footer = contents[contents.len - footer_size ..];
    const fields_region = footer[0 .. footer_size - signature_size];
    const signature = footer[footer_size - signature_size ..];

    // `fields_region` holds, in on-disk order, field8/field7/field6/field5(abi_type)/
    // field4(extension_version)/field3(duckdb_version)/field2(platform)/field1(magic) — see
    // `append_metadata_main.zig`'s own write order, reversed here by index.
    const fieldAt = struct {
        fn at(region: []const u8, index: usize) []const u8 {
            return trimPadded(region[index * field_size ..][0..field_size]);
        }
    }.at;

    const magic = fieldAt(fields_region, num_fields - 1); // FIELD1
    if (!std.mem.eql(u8, magic, expected_magic)) return error.NotADuckdbExtensionFooter;

    return .{
        .fields = .{
            .magic = magic,
            .platform = fieldAt(fields_region, num_fields - 2), // FIELD2
            .duckdb_version = fieldAt(fields_region, num_fields - 3), // FIELD3
            .extension_version = fieldAt(fields_region, num_fields - 4), // FIELD4
            .abi_type = fieldAt(fields_region, num_fields - 5), // FIELD5
        },
        .signature = signature,
    };
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

    const footer = parseFooter(contents) catch |err| {
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
            footer.fields.platform,
            footer.fields.duckdb_version,
            footer.fields.extension_version,
            footer.fields.abi_type,
            footer.isSigned(),
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

    _ = parseFooter(contents) catch |err| {
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

    const footer = parseFooter(contents) catch |err| {
        std.debug.print("sign_extension: '{s}' is not a recognized .duckdb_extension footer: {s}\n", .{ input_path, @errorName(err) });
        return 1;
    };
    if (!footer.isSigned()) {
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
    try cwd.writeFile(io, .{ .sub_path = sig_tmp_path, .data = footer.signature });

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

/// Builds a minimal, valid footer (no wasm preamble — `parseFooter` only ever looks at the
/// trailing 512 bytes, so the bytes before it are irrelevant to this test) for a given set of
/// field values, matching `append_metadata_main.zig`'s own write order.
fn buildTestFooter(platform: []const u8, duckdb_version: []const u8, extension_version: []const u8, abi_type: []const u8, signature: [signature_size]u8) [footer_size]u8 {
    var footer: [footer_size]u8 = @splat(0);
    const writeField = struct {
        fn at(buf: []u8, index: usize, value: []const u8) void {
            @memcpy(buf[index * field_size ..][0..value.len], value);
        }
    }.at;
    writeField(&footer, 3, abi_type); // FIELD5
    writeField(&footer, 4, extension_version); // FIELD4
    writeField(&footer, 5, duckdb_version); // FIELD3
    writeField(&footer, 6, platform); // FIELD2
    writeField(&footer, 7, expected_magic); // FIELD1
    @memcpy(footer[footer_size - signature_size ..], &signature);
    return footer;
}

test "parseFooter extracts fields in the right order and detects signed/unsigned" {
    const unsigned_footer = buildTestFooter("linux_amd64", "v2.0.0", "v0.1.0", "C_STRUCT_UNSTABLE", @splat(0));
    const unsigned = try parseFooter(&unsigned_footer);
    try std.testing.expectEqualStrings("linux_amd64", unsigned.fields.platform);
    try std.testing.expectEqualStrings("v2.0.0", unsigned.fields.duckdb_version);
    try std.testing.expectEqualStrings("v0.1.0", unsigned.fields.extension_version);
    try std.testing.expectEqualStrings("C_STRUCT_UNSTABLE", unsigned.fields.abi_type);
    try std.testing.expect(!unsigned.isSigned());

    var fake_sig: [signature_size]u8 = @splat(0xAB);
    const signed_footer = buildTestFooter("wasm_eh", "v2.0.0", "v0.0.0-poc", "C_STRUCT_UNSTABLE", fake_sig);
    const signed = try parseFooter(&signed_footer);
    try std.testing.expect(signed.isSigned());
    try std.testing.expectEqualSlices(u8, &fake_sig, signed.signature);
}

test "parseFooter rejects a file whose magic field doesn't match" {
    var not_a_footer: [footer_size]u8 = @splat(0);
    try std.testing.expectError(error.NotADuckdbExtensionFooter, parseFooter(&not_a_footer));
}

test "parseFooter rejects a file smaller than the footer" {
    try std.testing.expectError(error.FileTooSmallForFooter, parseFooter("too small"));
}
