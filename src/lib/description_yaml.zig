///! A narrow, purpose-built parser for THIS project's own `description.yml`
///! — NOT a general YAML parser. Handles exactly the shape that file
///! actually uses: three top-level maps (`extension`/`repo`/`docs`), 2-space
///! indented scalar/list keys under each, `>-` folded block scalars,
///! `|` literal block scalars, and `- item` lists. Deliberately doesn't
///! handle anything YAML permits beyond that (anchors, flow collections,
///! multi-line plain scalars, etc.) — if `description.yml` ever needs one
///! of those, this parser should fail loudly (a missing field becomes a
///! clear error, never a silently wrong value) rather than silently
///! misparse.
const std = @import("std");

pub const Description = struct {
    name: []const u8,
    description: []const u8,
    version: []const u8,
    language: []const u8,
    build: []const u8,
    license: []const u8,
    maintainers: [][]const u8,
    repo_github: []const u8,
    repo_ref: []const u8,
    hello_world: []const u8,
    extended_description: []const u8,

    pub fn deinit(self: *Description, allocator: std.mem.Allocator) void {
        allocator.free(self.maintainers);
    }
};

const Section = enum { none, extension, repo, docs };

/// Parses `contents` (the raw file text). All returned slices borrow
/// directly from `contents` (block-scalar values are reassembled into
/// freshly allocated strings via `allocator`, since they're joined from
/// multiple lines) — `contents` must outlive the returned `Description`.
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !Description {
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var language: ?[]const u8 = null;
    var build: ?[]const u8 = null;
    var license: ?[]const u8 = null;
    var maintainers: std.ArrayList([]const u8) = .empty;
    errdefer maintainers.deinit(allocator);
    var repo_github: ?[]const u8 = null;
    var repo_ref: ?[]const u8 = null;
    var hello_world: ?[]const u8 = null;
    var extended_description: ?[]const u8 = null;

    var section: Section = .none;
    var lines = std.mem.splitScalar(u8, contents, '\n');

    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trimEnd(u8, raw_line, " \r");
        if (trimmed.len == 0) continue;
        const stripped = std.mem.trimStart(u8, trimmed, " ");
        if (stripped.len == 0 or stripped[0] == '#') continue;

        const indent = trimmed.len - stripped.len;

        if (indent == 0) {
            if (std.mem.eql(u8, stripped, "extension:")) {
                section = .extension;
            } else if (std.mem.eql(u8, stripped, "repo:")) {
                section = .repo;
            } else if (std.mem.eql(u8, stripped, "docs:")) {
                section = .docs;
            } else {
                section = .none;
            }
            continue;
        }

        if (indent == 4 and std.mem.startsWith(u8, stripped, "- ")) {
            try maintainers.append(allocator, std.mem.trim(u8, stripped[2..], " "));
            continue;
        }

        // A 2-space-indented "key: value" or "key: |"/"key: >-" line.
        const colon = std.mem.indexOfScalar(u8, stripped, ':') orelse continue;
        const key = stripped[0..colon];
        const rest = std.mem.trim(u8, stripped[colon + 1 ..], " ");

        if (std.mem.eql(u8, rest, "|") or std.mem.eql(u8, rest, ">-")) {
            const folded = std.mem.eql(u8, rest, ">-");
            const block = try consumeBlockScalar(allocator, &lines, folded);
            assignBlock(section, key, block, &description, &hello_world, &extended_description);
            continue;
        }

        switch (section) {
            .extension => {
                if (std.mem.eql(u8, key, "name")) name = rest;
                if (std.mem.eql(u8, key, "version")) version = rest;
                if (std.mem.eql(u8, key, "language")) language = rest;
                if (std.mem.eql(u8, key, "build")) build = rest;
                if (std.mem.eql(u8, key, "license")) license = rest;
            },
            .repo => {
                if (std.mem.eql(u8, key, "github")) repo_github = rest;
                if (std.mem.eql(u8, key, "ref")) repo_ref = rest;
            },
            .docs, .none => {},
        }
    }

    return .{
        .name = name orelse return error.MissingField,
        .description = description orelse return error.MissingField,
        .version = version orelse return error.MissingField,
        .language = language orelse return error.MissingField,
        .build = build orelse return error.MissingField,
        .license = license orelse return error.MissingField,
        .maintainers = try maintainers.toOwnedSlice(allocator),
        .repo_github = repo_github orelse return error.MissingField,
        .repo_ref = repo_ref orelse return error.MissingField,
        .hello_world = hello_world orelse return error.MissingField,
        .extended_description = extended_description orelse return error.MissingField,
    };
}

fn assignBlock(
    section: Section,
    key: []const u8,
    value: []const u8,
    description: *?[]const u8,
    hello_world: *?[]const u8,
    extended_description: *?[]const u8,
) void {
    switch (section) {
        .extension => if (std.mem.eql(u8, key, "description")) {
            description.* = value;
        },
        .docs => {
            if (std.mem.eql(u8, key, "hello_world")) hello_world.* = value;
            if (std.mem.eql(u8, key, "extended_description")) extended_description.* = value;
        },
        .repo, .none => {},
    }
}

/// Consumes lines more indented than the enclosing key (4+ spaces, given
/// this file's 2-space-per-level convention: the key itself sits at
/// indent 2, so its block content sits one level deeper, at indent 4)
/// until indentation drops back or the input ends. `folded` (`>-`)
/// joins lines with a single space and strips the final trailing
/// newline (the `-` chomp indicator); the literal form (`|`) joins with
/// `\n`, preserving one trailing newline.
fn consumeBlockScalar(allocator: std.mem.Allocator, lines: *std.mem.SplitIterator(u8, .scalar), folded: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var first = true;
    while (true) {
        const saved_lines = lines.*;
        const raw_line = lines.next() orelse break;
        const trimmed = std.mem.trimEnd(u8, raw_line, " \r");
        if (trimmed.len == 0) {
            if (!folded) try out.append(allocator, '\n');
            continue;
        }
        const stripped = std.mem.trimStart(u8, trimmed, " ");
        const indent = trimmed.len - stripped.len;
        if (indent < 4) {
            lines.* = saved_lines; // push the line back for the outer loop
            break;
        }
        if (!first) try out.append(allocator, if (folded) ' ' else '\n');
        try out.appendSlice(allocator, stripped);
        first = false;
    }
    if (!folded) try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

test "parse reads this project's own real description.yml correctly" {
    const allocator = std.testing.allocator;
    const sample =
        \\# a comment
        \\extension:
        \\  name: zig_ext
        \\  description: >-
        \\    A DuckDB extension written in Zig, demonstrating scalar and
        \\    table functions.
        \\  version: 0.1.0
        \\  language: Zig
        \\  build: zig
        \\  license: MIT
        \\  maintainers:
        \\    - mskyttner
        \\
        \\repo:
        \\  github: mskyttner/zig-duckdb-ext
        \\  ref: main
        \\
        \\docs:
        \\  hello_world: |
        \\    LOAD zig_ext;
        \\    SELECT zig_hello('world');
        \\  extended_description: >-
        \\    Demonstrates building DuckDB functions in Zig.
        \\
    ;

    var desc = try parse(allocator, sample);
    defer desc.deinit(allocator);

    try std.testing.expectEqualStrings("zig_ext", desc.name);
    try std.testing.expectEqualStrings(
        "A DuckDB extension written in Zig, demonstrating scalar and table functions.",
        desc.description,
    );
    try std.testing.expectEqualStrings("0.1.0", desc.version);
    try std.testing.expectEqualStrings("Zig", desc.language);
    try std.testing.expectEqualStrings("zig", desc.build);
    try std.testing.expectEqualStrings("MIT", desc.license);
    try std.testing.expectEqual(@as(usize, 1), desc.maintainers.len);
    try std.testing.expectEqualStrings("mskyttner", desc.maintainers[0]);
    try std.testing.expectEqualStrings("mskyttner/zig-duckdb-ext", desc.repo_github);
    try std.testing.expectEqualStrings("main", desc.repo_ref);
    try std.testing.expectEqualStrings("LOAD zig_ext;\nSELECT zig_hello('world');\n", desc.hello_world);
    try std.testing.expectEqualStrings("Demonstrates building DuckDB functions in Zig.", desc.extended_description);

    allocator.free(desc.description);
    allocator.free(desc.hello_world);
    allocator.free(desc.extended_description);
}
