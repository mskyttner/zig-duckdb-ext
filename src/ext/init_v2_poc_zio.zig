///! Speculative, fully isolated v2-poc demo: tries `zio` (github.com/lalinsky/zio) as a second
///! `std.Io` backend for `matmul.matmulSimdParallel`, alongside `std.Io.Threaded`. Builds as its
///! own separate `.duckdb_extension` (`zig build v2-poc-zio`), entirely independent of
///! `init_v2_poc.zig`/`zig_ext_v2_poc` — same isolation reasoning as `init_v2_poc_braille.zig`'s
///! own doc comment gives for `zignal`: this is the only place in the whole project pulling in
///! `zio`, and it's `lazy = true` in build.zig.zon, so nothing else is affected if it fails to
///! fetch or build.
///!
///! zig_v2_matmul_bench_io_ct(m, k, n, iterations) -> (backend, elapsed_ms, gflops)
///!
///! Runs the *exact same* `matmul.matmulSimdParallel` call — not a reimplementation — against two
///! different `std.Io` values: `std.Io.Threaded` (plain OS thread pool; what
///! `zig_v2_matmul_bench_ct` in the main v2-poc extension already uses) and `zio.Runtime`
///! (work-stealing coroutine scheduler, default settings). `matmulSimdParallel` takes `io:
///! std.Io` and only ever calls `std.Io.Group.concurrent`/`.await` on it — this function is the
///! live check of zio's own claim ("code written against std.Io runs on zio unmodified"): nothing
///! in matmul.zig changes between the two rows below, only the `Io` value handed to it.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const comptime_table_v2 = @import("comptime_table_v2");
const matmul = @import("matmul");
const zio = @import("zio");

const MatmulBenchIoState = struct {
    backend_names: [2][]const u8,
    elapsed_ms: [2]f64,
    gflops: [2]f64,
    idx: usize,

    pub const Row = struct { backend: []const u8, elapsed_ms: f64, gflops: f64 };

    pub fn init(m: i64, k: i64, n: i64, iterations: i64) @This() {
        const failed: @This() = .{ .backend_names = undefined, .elapsed_ms = undefined, .gflops = undefined, .idx = 2 };

        const mu: usize = @intCast(@max(m, 1));
        const ku: usize = @intCast(@max(k, 1));
        const nu: usize = @intCast(@max(n, 1));
        const iters: usize = @intCast(@max(iterations, 1));
        const max_tasks = std.Thread.getCpuCount() catch 1;

        const a = std.heap.c_allocator.alloc(f64, mu * ku) catch return failed;
        defer std.heap.c_allocator.free(a);
        const b = std.heap.c_allocator.alloc(f64, ku * nu) catch return failed;
        defer std.heap.c_allocator.free(b);
        const c = std.heap.c_allocator.alloc(f64, mu * nu) catch return failed;
        defer std.heap.c_allocator.free(c);
        for (a, 0..) |*v, i| v.* = @floatFromInt(i % 13);
        for (b, 0..) |*v, i| v.* = @floatFromInt((i % 7) + 1);

        const flops: f64 = 2.0 * @as(f64, @floatFromInt(mu)) * @as(f64, @floatFromInt(nu)) * @as(f64, @floatFromInt(ku)) * @as(f64, @floatFromInt(iters));

        // --- std.Io.Threaded: a plain OS thread pool, no event loop. ---
        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        const threaded_io = threaded.io();

        const threaded_start: std.Io.Clock.Timestamp = .now(threaded_io, .awake);
        for (0..iters) |_| matmul.matmulSimdParallel(matmul.default_rm, threaded_io, max_tasks, a, b, c, mu, ku, nu);
        const threaded_ns: f64 = @floatFromInt(threaded_start.durationTo(.now(threaded_io, .awake)).raw.nanoseconds);

        // --- zio: a work-stealing coroutine scheduler; `.auto` executors matches CPU count,
        // same as `max_tasks` above. `Runtime.init` heap-allocates the runtime itself. ---
        const rt = zio.Runtime.init(std.heap.c_allocator, .{ .executors = .auto }) catch return failed;
        defer rt.deinit();
        const zio_io = rt.io();

        const zio_start: std.Io.Clock.Timestamp = .now(zio_io, .awake);
        for (0..iters) |_| matmul.matmulSimdParallel(matmul.default_rm, zio_io, max_tasks, a, b, c, mu, ku, nu);
        const zio_ns: f64 = @floatFromInt(zio_start.durationTo(.now(zio_io, .awake)).raw.nanoseconds);

        return .{
            .backend_names = .{ "threaded", "zio" },
            .elapsed_ms = .{ threaded_ns / 1e6, zio_ns / 1e6 },
            .gflops = .{ flops / threaded_ns, flops / zio_ns },
            .idx = 0,
        };
    }

    pub fn next(self: *@This()) ?Row {
        if (self.idx >= 2) return null;
        defer self.idx += 1;
        return .{ .backend = self.backend_names[self.idx], .elapsed_ms = self.elapsed_ms[self.idx], .gflops = self.gflops[self.idx] };
    }
};
const MatmulBenchIoCt = comptime_table_v2.FunctionNamed("zig_v2_matmul_bench_io_ct", MatmulBenchIoState, &.{ "m", "k", "n", "iterations" });

export fn zig_ext_v2_poc_zio_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;
    MatmulBenchIoCt.register(input) catch {};
}
