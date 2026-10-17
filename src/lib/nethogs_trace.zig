///! Subprocess ingestion for nethogs' tracemode (`-t`) output — the
///! "nethogs-style accumulate traffic by process" POC's data-acquisition
///! layer. Spawns an arbitrary command (nethogs itself, or any stand-in
///! that emits the same line format) via `std.process.spawn`, reads its
///! stdout, and parses it into a columnar `TraceBatch` (structure-of-
///! arrays, the "Arrow-shaped intermediate" this POC builds before handing
///! rows to `comptime_appender_v2.Appender`).
///!
///! The exact format parsed here was confirmed against nethogs' own
///! upstream source (github.com/raboof/nethogs, `src/cui.cpp`,
///! `show_trace()` / `Line::log()`), not guessed or reverse-engineered
///! from running it:
///!   "\nRefreshing:\n"                                   -- batch delimiter
///!   "<program>/<pid>/<uid>\t<sent_kbps>\t<recv_kbps>\n"  -- one line/process
///! `nethogs -t` itself needs `cap_net_admin`/`cap_net_raw` (confirmed
///! live: it refuses outright without them) — a one-time `setcap` grant,
///! not something this code can or should acquire for itself. `tools/
///! fake_nethogs.zig` emits the identical line format with synthetic data,
///! so this parser works unmodified against either.
const std = @import("std");

pub const TraceBatch = struct {
    ts: std.ArrayList(i64) = .empty,
    program: std.ArrayList([]const u8) = .empty, // each entry allocator-owned
    pid: std.ArrayList(i64) = .empty,
    uid: std.ArrayList(i64) = .empty,
    sent_kbps: std.ArrayList(f64) = .empty,
    recv_kbps: std.ArrayList(f64) = .empty,

    pub fn len(self: *const TraceBatch) usize {
        return self.ts.items.len;
    }

    pub fn deinit(self: *TraceBatch, allocator: std.mem.Allocator) void {
        for (self.program.items) |p| allocator.free(p);
        self.ts.deinit(allocator);
        self.program.deinit(allocator);
        self.pid.deinit(allocator);
        self.uid.deinit(allocator);
        self.sent_kbps.deinit(allocator);
        self.recv_kbps.deinit(allocator);
    }
};

/// Spawn `cmd` (whitespace-separated; no quoting support — fine for this
/// POC's fixed argv) and parse up to `max_cycles` nethogs-tracemode refresh
/// batches from its stdout. `ts` is a synthetic per-batch counter (0, 1,
/// 2, ...), not a wall-clock timestamp — this POC cares about ordering
/// batches, not real time.
pub fn readTraceBatch(allocator: std.mem.Allocator, cmd: []const u8, max_cycles: i64) !TraceBatch {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var tok_it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (tok_it.next()) |tok| try argv.append(allocator, tok);
    if (argv.items.len == 0) return .{};

    var io_impl: std.Io.Threaded = .init(allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = child.stdout.?.reader(io, &read_buf);

    return parseTraceLines(allocator, &file_reader.interface, max_cycles);
}

/// The actual line-parsing loop, factored out from `readTraceBatch` so it
/// can be unit-tested against an in-memory `std.Io.Reader.fixed` buffer
/// instead of a real subprocess — no filesystem or process dependency in
/// the test below.
fn parseTraceLines(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_cycles: i64) !TraceBatch {
    var batch: TraceBatch = .{};
    errdefer batch.deinit(allocator);

    var cycle: i64 = 0;
    var ts: i64 = -1; // bumped to 0 on the first "Refreshing:" line

    while (true) {
        // `takeDelimiter` (not `takeDelimiterExclusive`): confirmed live via
        // a standalone repro that `takeDelimiterExclusive` has a real quirk
        // against `std.Io.Reader.fixed` — it returns the first line
        // correctly, then an endless stream of empty slices instead of
        // ever erroring or advancing, a genuine infinite-loop hazard.
        // `takeDelimiter` was verified to read every line correctly and
        // signal end-of-stream via a clean `null`.
        const line = (reader.takeDelimiter('\n') catch null) orelse break;
        if (line.len == 0) continue; // the blank line nethogs prints before "Refreshing:"
        if (std.mem.eql(u8, line, "Refreshing:")) {
            cycle += 1;
            // Checked AFTER incrementing, BEFORE consuming this cycle's own
            // data rows: checking before incrementing (the original,
            // buggy version of this loop) discarded the Nth cycle's rows
            // entirely, since the loop condition failed right as that
            // cycle began — confirmed live (`max_cycles=3` against real
            // fake_nethogs output only returned 2 cycles' worth of rows).
            if (cycle > max_cycles) break;
            ts += 1;
            continue;
        }
        if (ts < 0) continue; // a stray line before the first batch delimiter

        // "<program>/<pid>/<uid>\t<sent_kbps>\t<recv_kbps>"
        var fields = std.mem.tokenizeScalar(u8, line, '\t');
        const name_field = fields.next() orelse continue;
        const sent_str = fields.next() orelse continue;
        const recv_str = fields.next() orelse continue;

        const uid_slash = std.mem.lastIndexOfScalar(u8, name_field, '/') orelse continue;
        const uid_str = name_field[uid_slash + 1 ..];
        const rest = name_field[0..uid_slash];
        const pid_slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse continue;
        const pid_str = rest[pid_slash + 1 ..];
        const program = rest[0..pid_slash];

        const pid = std.fmt.parseInt(i64, pid_str, 10) catch continue;
        const uid = std.fmt.parseInt(i64, uid_str, 10) catch continue;
        const sent = std.fmt.parseFloat(f64, sent_str) catch continue;
        const recv = std.fmt.parseFloat(f64, recv_str) catch continue;

        const owned_program = try allocator.dupe(u8, program);
        errdefer allocator.free(owned_program);

        try batch.ts.append(allocator, ts);
        try batch.program.append(allocator, owned_program);
        try batch.pid.append(allocator, pid);
        try batch.uid.append(allocator, uid);
        try batch.sent_kbps.append(allocator, sent);
        try batch.recv_kbps.append(allocator, recv);
    }

    return batch;
}

test "parseTraceLines parses nethogs tracemode's real line format" {
    const allocator = std.testing.allocator;
    // Exercises the parser directly against an in-memory buffer — no
    // subprocess or filesystem dependency — using the exact line shape
    // confirmed against nethogs' own upstream source (see module doc
    // comment).
    const fixture =
        "\nRefreshing:\n" ++
        "/usr/bin/firefox/1234/1000\t12.5\t3.25\n" ++
        "/usr/bin/curl/5678/1000\t0.1\t0.2\n" ++
        "\nRefreshing:\n" ++
        "/usr/bin/firefox/1234/1000\t1.0\t1.0\n";
    var reader = std.Io.Reader.fixed(fixture);

    var batch = try parseTraceLines(allocator, &reader, 10);
    defer batch.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), batch.len());
    try std.testing.expectEqualStrings("/usr/bin/firefox", batch.program.items[0]);
    try std.testing.expectEqual(@as(i64, 1234), batch.pid.items[0]);
    try std.testing.expectEqual(@as(i64, 1000), batch.uid.items[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), batch.sent_kbps.items[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.25), batch.recv_kbps.items[0], 1e-9);
    try std.testing.expectEqual(@as(i64, 0), batch.ts.items[0]);
    try std.testing.expectEqualStrings("/usr/bin/curl", batch.program.items[1]);
    try std.testing.expectEqual(@as(i64, 1), batch.ts.items[2]);
}

test "parseTraceLines(max_cycles) includes the Nth cycle's own rows, not just N-1" {
    const allocator = std.testing.allocator;
    // Regression test for a real off-by-one bug: the cycle-count check
    // originally ran BEFORE consuming that cycle's data rows, so
    // requesting exactly as many cycles as the input has discarded the
    // last cycle entirely (caught live via `fake_nethogs 3` + max_cycles=3
    // returning only 2 cycles' worth of rows).
    const fixture =
        "\nRefreshing:\n" ++
        "/usr/bin/firefox/1234/1000\t1.0\t1.0\n" ++
        "\nRefreshing:\n" ++
        "/usr/bin/curl/5678/1000\t2.0\t2.0\n";
    var reader = std.Io.Reader.fixed(fixture);

    var batch = try parseTraceLines(allocator, &reader, 2);
    defer batch.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), batch.len());
    try std.testing.expectEqualStrings("/usr/bin/curl", batch.program.items[1]);
}
