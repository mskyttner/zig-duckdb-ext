///! A minimal, native sqllogictest runner for this project's own `.test`
///! files — replaces the `uv run --with duckdb-sqllogictest-python ...`
///! dependency with a small Zig program that drives the `duckdb` CLI
///! directly, so running these tests needs nothing beyond the CLI this
///! project already requires for everything else (`zig build
///! duckdb-extension`, manual testing, ...).
///!
///! Supports exactly the directive subset this project's `.test` files
///! use: `require <name>`, `statement ok`, `statement error` (+ `----` +
///! expected error text, matched as a SUBSTRING of the actual error per
///! DuckDB's own doc on this — https://duckdb.org/docs/current/dev/sqllogictest/result_verification —
///! not a full match), and `query <types>` (+ `----` + expected result,
///! one VALUE per line, row-major across all columns — the true
///! sqllogictest convention, not "one row per line": a 3-row, 2-column
///! result is 6 expected lines). `NULL` is written as the literal text
///! `NULL` (DuckDB's own convention).
///!
///! Queries run through the CLI's `-jsonlines` output mode (one JSON
///! object per output row, e.g. `{"a":1,"b":"x"}`), not `-csv` — this
///! sidesteps three real problems a CSV-based runner otherwise has to work
///! around by hand (each confirmed live while this runner used `-csv`,
///! see docs/v2-migration-plan.md's "Ported test:e2e/smoke.sql" entry for
///! the history): DuckDB's CSV writer quotes some non-ASCII content with
///! no comma or newline present (so a CSV-based expected value sometimes
///! needs literal quote characters nobody asked for, and sometimes
///! doesn't, for reasons not obvious from the SQL alone); an empty-string
///! result is indistinguishable from "no row" once blank lines are
///! trimmed; and a value containing an embedded newline (e.g. an ASCII-art
///! chart) can't be represented as a single expected line at all. JSON
///! string escaping has none of these problems: quoting is structural, not
///! content-dependent; `""` is unambiguous; and a newline inside a string
///! is the two characters `\`+`n`, never a real line break, so a whole
///! multi-line chart's `md5(...)`-hashed value from the CSV era can go
///! back to being the literal expected text (still just the two
///! characters `\n` where the real output has a line break — see
///! `extractJsonRowValues`'s doc comment on what is and isn't unescaped).
///!
///! `(empty)` IS now supported, and required, not optional — a `.test`
///! file's expected-output block still ends at the first blank line (see
///! `parseBlocks`), independent of the `-jsonlines` switch, so a literal
///! blank line still can't represent an expected empty string; write
///! `(empty)` instead, DuckDB's own convention, reproduced verbatim by
///! `extractJsonRowValues`.
///!
///! NOT supported (no current `.test` file needs them — add if one ever
///! does): nested JSON values (a result column that's a LIST/STRUCT/MAP
///! would need actual JSON parsing, not `extractJsonRowValues`'s flat
///! scalar-only scan); `<REGEX>:`/`<!REGEX>:`/`<FILE>:` result forms;
///! hash-based results (`N values
///! hashing to ...` — also unnecessary now, see the `md5(...)` note
///! above, which gets the same effect as an ordinary SQL expression
///! instead of dedicated format support); shared query labels; `nosort`/
///! `rowsort`/`valuesort`; `skipif`/`onlyif`/`halt`/`hash-threshold`. The
///! format's full grammar traces back to SQLite's own sqllogictest
///! (https://sqlite.org/sqllogictest/doc/trunk/about.wiki); DuckDB
///! extends it with `require`/named extension loading. See
///! https://github.com/Mytherin/vscode-sqllogictest for a fuller
///! reference on the format if this runner ever needs to grow past what's
///! used here.
///!
///! Usage: sqllogictest_main <duckdb_cli_path> <extension_path> <test_file_path>
///!
///! How it works: the whole `.test` file is compiled into one SQL script
///! (each block's SQL, followed by a `SELECT '@@SQLLOGICTEST_MARK_<i>@@';`
///! sentinel), run as a single non-interactive `duckdb` invocation with
///! stdout and stderr merged (`2>&1`, via a `sh -c` wrapper — simplest way
///! to get OS-level stream merging without hand-rolling non-blocking,
///! interleaved pipe reads). Merging the streams is what lets one error
///! message and the marker queries around it stay in true temporal order:
///! DuckDB executes statements one at a time in this mode, so by the time
///! a block's marker line appears in the merged output, that block's own
///! stdout AND stderr are both already fully written before it, with
///! nothing from any other block possibly intermixed. The combined output
///! is then split on the marker lines in one pass, in order, assigning
///! each chunk back to the block that produced it. Confirmed live: an
///! error message is plain text regardless of `-jsonlines`/`-csv` (only
///! successful query RESULTS are mode-dependent), so `statement error`'s
///! substring match needs no special handling; a marker's own `SELECT
///! '@@...@@'` still contains that exact literal substring once wrapped
///! in a JSON object (`{"'@@...@@'":"@@...@@"}`), so marker detection
///! still works unchanged as a substring search, not an exact-line match.
const std = @import("std");

const Block = union(enum) {
    require: []const u8,
    statement_ok: []const u8,
    statement_error: struct { sql: []const u8, expected: []const u8 },
    query: struct { sql: []const u8, expected: []const []const u8 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // program name
    const duckdb_cli = arg_it.next() orelse return usageError();
    const extension_path = arg_it.next() orelse return usageError();
    const test_file_path = arg_it.next() orelse return usageError();

    const source = try std.Io.Dir.cwd().readFileAlloc(io, test_file_path, arena, .unlimited);
    const blocks = try parseBlocks(arena, source);

    // Build one combined script: each block's SQL, then its own marker.
    var script: std.ArrayList(u8) = .empty;
    for (blocks, 0..) |block, i| {
        switch (block) {
            .require => {
                try script.print(arena, "LOAD '{s}';\n", .{extension_path});
            },
            .statement_ok => |sql| {
                try script.print(arena, "{s};\n", .{sql});
            },
            .statement_error => |s| {
                try script.print(arena, "{s};\n", .{s.sql});
            },
            .query => |q| {
                try script.print(arena, "{s};\n", .{q.sql});
            },
        }
        try script.print(arena, "SELECT '@@SQLLOGICTEST_MARK_{d}@@';\n", .{i});
    }

    const script_path = try std.fmt.allocPrint(arena, "{s}.sqllogictest_tmp.sql", .{test_file_path});
    {
        const script_file = try std.Io.Dir.cwd().createFile(io, script_path, .{});
        defer script_file.close(io);
        var buf: [4096]u8 = undefined;
        var writer = std.Io.File.Writer.init(script_file, io, &buf);
        try writer.interface.writeAll(script.items);
        try writer.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, script_path) catch {};

    const shell_cmd = try std.fmt.allocPrint(
        arena,
        "'{s}' -unsigned -jsonlines -init /dev/null < '{s}' 2>&1",
        .{ duckdb_cli, script_path },
    );

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", shell_cmd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    var read_buf: [4096]u8 = undefined;
    var file_reader = child.stdout.?.reader(io, &read_buf);
    const combined_output = try file_reader.interface.allocRemaining(arena, .unlimited);

    // The duckdb CLI exits non-zero whenever ANY statement in the script
    // errored, even an expected one (a `statement error` block) that the
    // rest of the script recovered from fine — so a non-zero exit here is
    // not itself a failure signal. `splitByMarkers` finding all the
    // expected marker lines is the real evidence the whole script ran to
    // completion; only a genuine crash/hang would come up short there.
    _ = try child.wait(io);

    const chunks = try splitByMarkers(arena, combined_output, blocks.len);

    var failures: usize = 0;
    for (blocks, chunks, 0..) |block, chunk, i| {
        const trimmed = std.mem.trim(u8, chunk, " \t\r\n");
        switch (block) {
            .require => {
                if (trimmed.len != 0) {
                    failures += 1;
                    std.debug.print("[{d}] require: unexpected output loading extension:\n{s}\n", .{ i, trimmed });
                }
            },
            .statement_ok => |sql| {
                if (trimmed.len != 0) {
                    failures += 1;
                    std.debug.print("[{d}] statement ok FAILED: {s}\n  got: {s}\n", .{ i, sql, trimmed });
                }
            },
            .statement_error => |s| {
                if (std.mem.indexOf(u8, trimmed, s.expected) == null) {
                    failures += 1;
                    std.debug.print("[{d}] statement error MISMATCH: {s}\n  expected (substring): {s}\n  got: {s}\n", .{ i, s.sql, s.expected, trimmed });
                }
            },
            .query => |q| {
                // One JSONL line per output ROW; each row's values are
                // flattened in column order onto the same got_lines list
                // `matchesExpected` compares against — the true
                // sqllogictest convention (one value per expected line,
                // not one row per line; see this file's module doc
                // comment).
                var got_lines: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, trimmed, '\n');
                while (it.next()) |line| {
                    const row = std.mem.trim(u8, line, " \t\r");
                    if (row.len == 0) continue;
                    try extractJsonRowValues(arena, row, &got_lines);
                }
                if (!matchesExpected(got_lines.items, q.expected)) {
                    failures += 1;
                    const expected_joined = try std.mem.join(arena, " | ", q.expected);
                    const got_joined = try std.mem.join(arena, " | ", got_lines.items);
                    std.debug.print("[{d}] query MISMATCH: {s}\n  expected: {s}\n  got: {s}\n", .{ i, q.sql, expected_joined, got_joined });
                }
            },
        }
    }

    if (failures != 0) {
        std.debug.print("sqllogictest: {d}/{d} blocks FAILED ({s})\n", .{ failures, blocks.len, test_file_path });
        return error.SqlLogicTestFailed;
    }
    std.debug.print("sqllogictest: all {d} blocks passed ({s})\n", .{ blocks.len, test_file_path });
}

fn usageError() !void {
    std.debug.print("usage: sqllogictest_main <duckdb_cli_path> <extension_path> <test_file_path>\n", .{});
    return error.InvalidArgs;
}

/// Parses one `-jsonlines` output row — a flat JSON object with scalar
/// (string/number/bool/null) field values, e.g. `{"a":1,"b":"x\ny"}` — and
/// appends each field's VALUE (not its key; a key is just the column's
/// derived SQL expression text, not meaningful here) to `out`, in the
/// row's own column order.
///
/// A string value's content between the quotes is kept EXACTLY as JSON
/// wrote it — backslash escape sequences (`\n`, `\"`, `\\`, ...) are left
/// alone, not decoded into real bytes. This is deliberate, not a
/// shortcut: decoding `\n` into a real line break would reintroduce the
/// exact "a value can't fit on one expected line" problem switching to
/// `-jsonlines` was meant to solve. A `.test` file's expected text for
/// such a value is therefore also the literal two characters `\`+`n`
/// (visibly, not an actual line break) wherever the real output has an
/// embedded newline — see a `.test` file using this for a worked example.
/// A bare `null` token becomes the literal text `NULL`, DuckDB's own
/// sqllogictest convention; every other token (a number, `true`, `false`)
/// is kept as its raw JSON text, which already matches what a `.test`
/// file's expected line looks like.
///
/// Assumes every value is a scalar — a LIST/STRUCT/MAP column would
/// contain `[`/`{` characters this scan doesn't recognize as nesting and
/// would mis-parse. No current `.test` file returns a nested type; add
/// real recursion here first if one ever does.
fn extractJsonRowValues(arena: std.mem.Allocator, row: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    if (i >= row.len or row[i] != '{') return error.MalformedJsonLine;
    i += 1;
    while (true) {
        while (i < row.len and row[i] != '"') : (i += 1) {}
        if (i >= row.len) return error.MalformedJsonLine;
        i += 1; // opening quote of the key
        while (i < row.len and row[i] != '"') : (i += 1) {
            if (row[i] == '\\') i += 1; // skip the escaped character too
        }
        if (i >= row.len) return error.MalformedJsonLine;
        i += 1; // closing quote of the key

        while (i < row.len and row[i] != ':') : (i += 1) {}
        if (i >= row.len) return error.MalformedJsonLine;
        i += 1; // the ':'
        while (i < row.len and row[i] == ' ') : (i += 1) {}

        if (i < row.len and row[i] == '"') {
            const value_start = i + 1;
            i += 1;
            while (i < row.len and row[i] != '"') : (i += 1) {
                if (row[i] == '\\') i += 1;
            }
            if (i >= row.len) return error.MalformedJsonLine;
            // A blank line in a `.test` file's expected-output block would
            // be read as the END of that block (see `parseBlocks`), not as
            // an expected empty string — so an empty string still can't be
            // written as a literal blank line, independent of whatever the
            // output transport does. DuckDB's own sqllogictest convention
            // for this is the literal token `(empty)`; adopted verbatim
            // here rather than inventing a different one.
            const value = row[value_start..i];
            try out.append(arena, if (value.len == 0) "(empty)" else value);
            i += 1; // closing quote
        } else {
            const value_start = i;
            while (i < row.len and row[i] != ',' and row[i] != '}') : (i += 1) {}
            const token = row[value_start..i];
            try out.append(arena, if (std.mem.eql(u8, token, "null")) "NULL" else token);
        }

        while (i < row.len and row[i] == ' ') : (i += 1) {}
        if (i < row.len and row[i] == ',') {
            i += 1;
            continue;
        }
        break; // '}' or end of input
    }
}

fn matchesExpected(got: []const []const u8, expected: []const []const u8) bool {
    if (got.len != expected.len) return false;
    for (got, expected) |g, e| {
        if (!std.mem.eql(u8, g, e)) return false;
    }
    return true;
}

/// Split `output` on the `blocks_len` marker lines (in order), returning
/// one chunk per block: the text produced between the previous marker
/// (or the start of output, for block 0) and this block's own marker.
fn splitByMarkers(arena: std.mem.Allocator, output: []const u8, blocks_len: usize) ![][]const u8 {
    var chunks: std.ArrayList([]const u8) = .empty;
    var chunk_start: usize = 0;
    var expected_marker: usize = 0;

    var it = std.mem.splitScalar(u8, output, '\n');
    var pos: usize = 0;
    while (it.next()) |line| {
        const line_start = pos;
        pos += line.len + 1; // +1 for the '\n' this split consumed
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const marker = try std.fmt.allocPrint(arena, "@@SQLLOGICTEST_MARK_{d}@@", .{expected_marker});
        // A substring search, not an exact-line match: under `-jsonlines`
        // the marker query's own output is `{"'@@...@@'":"@@...@@"}`, not
        // the bare marker text (confirmed live — see this file's module
        // doc comment). Each marker's text is unique (it embeds its own
        // index), so a substring match can't collide with a different
        // marker.
        if (std.mem.indexOf(u8, trimmed, marker) != null) {
            try chunks.append(arena, output[chunk_start..line_start]);
            chunk_start = pos;
            expected_marker += 1;
            if (expected_marker == blocks_len) break;
        }
    }

    if (chunks.items.len != blocks_len) {
        std.debug.print(
            "sqllogictest: expected {d} marker lines, found {d} — the duckdb CLI likely crashed or hung mid-script\n--- combined output ---\n{s}\n",
            .{ blocks_len, chunks.items.len, output },
        );
        return error.MarkerDesync;
    }
    return chunks.items;
}

fn parseBlocks(arena: std.mem.Allocator, source: []const u8) ![]Block {
    var blocks: std.ArrayList(Block) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    {
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |line| try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));
    }

    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (line.len == 0 or line[0] == '#') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "require ")) {
            try blocks.append(arena, .{ .require = std.mem.trim(u8, line["require ".len..], " \t") });
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, line, "statement ok")) {
            i += 1;
            const sql = try collectUntilBlank(arena, lines.items, &i);
            try blocks.append(arena, .{ .statement_ok = sql });
            continue;
        }
        if (std.mem.eql(u8, line, "statement error")) {
            i += 1;
            const sql = try collectUntilSeparator(arena, lines.items, &i);
            const expected = try collectUntilBlank(arena, lines.items, &i);
            try blocks.append(arena, .{ .statement_error = .{ .sql = sql, .expected = expected } });
            continue;
        }
        if (std.mem.startsWith(u8, line, "query ")) {
            i += 1;
            const sql = try collectUntilSeparator(arena, lines.items, &i);
            var expected: std.ArrayList([]const u8) = .empty;
            while (i < lines.items.len and lines.items[i].len != 0) : (i += 1) {
                try expected.append(arena, lines.items[i]);
            }
            try blocks.append(arena, .{ .query = .{ .sql = sql, .expected = expected.items } });
            continue;
        }
        std.debug.print("sqllogictest: unrecognized directive on line {d}: {s}\n", .{ i + 1, line });
        return error.UnsupportedDirective;
    }
    return blocks.items;
}

/// Collect lines starting at `i.*` up to (not including) the next blank
/// line or EOF, joined with `\n`; advances `i.*` past the blank line.
fn collectUntilBlank(arena: std.mem.Allocator, lines: []const []const u8, i: *usize) ![]const u8 {
    var collected: std.ArrayList(u8) = .empty;
    var first = true;
    while (i.* < lines.len and lines[i.*].len != 0) : (i.* += 1) {
        if (!first) try collected.append(arena, '\n');
        try collected.appendSlice(arena, lines[i.*]);
        first = false;
    }
    if (i.* < lines.len) i.* += 1; // skip the blank separator
    return collected.items;
}

/// Like `collectUntilBlank`, but stops at a line that is exactly `----`
/// instead of a blank line, and advances `i.*` past that separator.
fn collectUntilSeparator(arena: std.mem.Allocator, lines: []const []const u8, i: *usize) ![]const u8 {
    var collected: std.ArrayList(u8) = .empty;
    var first = true;
    while (i.* < lines.len and !std.mem.eql(u8, lines[i.*], "----")) : (i.* += 1) {
        if (!first) try collected.append(arena, '\n');
        try collected.appendSlice(arena, lines[i.*]);
        first = false;
    }
    if (i.* < lines.len) i.* += 1; // skip "----"
    return collected.items;
}
