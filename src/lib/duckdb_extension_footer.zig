///! Parses the trailing 512-byte footer `append_metadata_main.zig` writes onto every
///! `.duckdb_extension` file this project builds — 8 x 32-byte zero-padded fields (written
///! field8-down-to-field1), followed by a 256-byte signature slot. Factored out of
///! `sign_extension_main.zig` once `extension_doctor_main.zig` became a second real consumer
///! of the exact same parsing (see docs/rationale/0005_a-package-for-extension-authors.md §7)
///! — this project waits for a genuine second use before extracting a shared abstraction, and
///! this is one, not a preemptive one. No DuckDB import, no project-specific coupling beyond
///! the footer's own fixed byte layout — this is DuckDB's format, not this project's own
///! invention, so it stays independently useful if this file is ever extracted further.
const std = @import("std");

pub const signature_size: u64 = 256;
pub const footer_size: u64 = 512;
const field_size: usize = 32;
const num_fields: usize = 8;

/// `FIELD1`'s own fixed content — `append_metadata_main.zig`'s magic value, written into
/// every footer this project (or a compatible tool) produces. Not DuckDB's own invention;
/// this project's own convention for recognizing its footer before trusting the rest of it.
pub const expected_magic = "4";

/// The footer's own fields, borrowed from whatever buffer `parse` was given — valid exactly
/// as long as that buffer is. Field names match `append_metadata_main.zig`'s own parameter
/// names, not the on-disk `FIELD1`..`FIELD8` numbering (`magic` is `FIELD1`, `platform` is
/// `FIELD2`, and so on down to `abi_type` as `FIELD5`; `FIELD6`-`FIELD8` are unused today and
/// not exposed here).
pub const FooterFields = struct {
    magic: []const u8,
    platform: []const u8,
    duckdb_version: []const u8,
    extension_version: []const u8,
    abi_type: []const u8,
};

pub const ParsedFooter = struct {
    fields: FooterFields,
    signature: []const u8,

    /// `append_metadata_main.zig` always writes a signature slot, signed or not — an
    /// unsigned extension's slot is all zero bytes (never written over), which is the one
    /// reliable way to tell "no signature yet" from "a real one", since a real RSA-2048
    /// signature over a non-empty hash is vanishingly unlikely to be all zero.
    pub fn isSigned(self: ParsedFooter) bool {
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

/// Parses the trailing 512-byte footer out of `contents` — the whole file's own bytes, not
/// just the footer, since callers signing/verifying it need the rest of `contents` too (the
/// composite hash covers everything except the trailing signature). Fails with
/// `error.NotADuckdbExtensionFooter` on anything whose `FIELD1` isn't this project's own magic
/// value — never silently treats an arbitrary file's trailing bytes as a real footer.
pub fn parse(contents: []const u8) !ParsedFooter {
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

/// Builds a minimal, valid footer (no wasm preamble — `parse` only ever looks at the trailing
/// 512 bytes, so the bytes before it are irrelevant to a test) for a given set of field
/// values, matching `append_metadata_main.zig`'s own write order. Exported for both this
/// module's own tests and its consumers' (`sign_extension_main.zig`,
/// `extension_doctor_main.zig`).
pub fn buildTestFooter(platform: []const u8, duckdb_version: []const u8, extension_version: []const u8, abi_type: []const u8, signature: [signature_size]u8) [footer_size]u8 {
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

test "parse extracts fields in the right order and detects signed/unsigned" {
    const unsigned_footer = buildTestFooter("linux_amd64", "v2.0.0", "v0.1.0", "C_STRUCT_UNSTABLE", @splat(0));
    const unsigned = try parse(&unsigned_footer);
    try std.testing.expectEqualStrings("linux_amd64", unsigned.fields.platform);
    try std.testing.expectEqualStrings("v2.0.0", unsigned.fields.duckdb_version);
    try std.testing.expectEqualStrings("v0.1.0", unsigned.fields.extension_version);
    try std.testing.expectEqualStrings("C_STRUCT_UNSTABLE", unsigned.fields.abi_type);
    try std.testing.expect(!unsigned.isSigned());

    var fake_sig: [signature_size]u8 = @splat(0xAB);
    const signed_footer = buildTestFooter("wasm_eh", "v2.0.0", "v0.0.0-poc", "C_STRUCT_UNSTABLE", fake_sig);
    const signed = try parse(&signed_footer);
    try std.testing.expect(signed.isSigned());
    try std.testing.expectEqualSlices(u8, &fake_sig, signed.signature);
}

test "parse rejects a file whose magic field doesn't match" {
    var not_a_footer: [footer_size]u8 = @splat(0);
    try std.testing.expectError(error.NotADuckdbExtensionFooter, parse(&not_a_footer));
}

test "parse rejects a file smaller than the footer" {
    try std.testing.expectError(error.FileTooSmallForFooter, parse("too small"));
}
