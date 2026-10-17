///! Standalone synthetic stand-in for `nethogs -t` (tracemode), emitting
///! the exact same line format on stdout with made-up per-process traffic.
///!
///! Exists because real nethogs needs `cap_net_admin`/`cap_net_raw` to
///! sniff packets at all (confirmed live: it refuses outright without
///! them) — a privileged, one-time `setcap` grant this project does not
///! make for itself. This tool lets `src/lib/nethogs_trace.zig`'s
///! subprocess-reading/parsing code be built, tested, and demoed with zero
///! privilege requirements; swapping it for real `nethogs -t -c <n>`
///! (nethogs' own `-c` flag bounds its update count, so it exits on its
///! own, same as this tool does) is a one-line command-string change with
///! no parser changes, once/if `sudo setcap "cap_net_admin,cap_net_raw+pe"
///! $(which nethogs)` has been run.
///!
///! Format confirmed against nethogs' own upstream source
///! (github.com/raboof/nethogs, `src/cui.cpp`, `show_trace()`/
///! `Line::log()`):
///!   "\nRefreshing:\n"
///!   "<program>/<pid>/<uid>\t<sent_kbps>\t<recv_kbps>\n"  -- one per process
///!
///! Usage: fake_nethogs [cycles]   (default 5 refresh cycles)
const std = @import("std");

const Program = struct {
    name: []const u8,
    pid: u32,
    uid: u32,
    base_sent: f64,
    base_recv: f64,
};

const programs = [_]Program{
    .{ .name = "/usr/bin/firefox", .pid = 1234, .uid = 1000, .base_sent = 120.0, .base_recv = 480.0 },
    .{ .name = "/usr/bin/curl", .pid = 5678, .uid = 1000, .base_sent = 8.0, .base_recv = 2.0 },
    .{ .name = "/usr/sbin/sshd", .pid = 910, .uid = 0, .base_sent = 1.5, .base_recv = 0.8 },
    .{ .name = "/usr/bin/zoom", .pid = 2222, .uid = 1000, .base_sent = 320.0, .base_recv = 310.0 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next(); // skip program name
    const cycles: u32 = if (args.next()) |s| std.fmt.parseInt(u32, s, 10) catch 5 else 5;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;

    var prng = std.Random.DefaultPrng.init(42); // fixed seed: deterministic demo output
    const rand = prng.random();

    var cycle: u32 = 0;
    while (cycle < cycles) : (cycle += 1) {
        try w.writeAll("\nRefreshing:\n");
        for (programs) |p| {
            const jitter_sent = p.base_sent * (0.5 + rand.float(f64));
            const jitter_recv = p.base_recv * (0.5 + rand.float(f64));
            try w.print("{s}/{d}/{d}\t{d:.3}\t{d:.3}\n", .{ p.name, p.pid, p.uid, jitter_sent, jitter_recv });
        }
        try w.flush();
    }
}
