///! Row-major matrix multiplication: C(m×n) = A(m×k) * B(k×n), flat
///! `[]const f64` arrays (row i, col j of A at `a[i*k+j]`, etc.) — a
///! scaled-down, single-ISA-per-build Zig take on llamafile's tinyBLAS
///! SGEMM kernels (github.com/Mozilla-Ocho/llamafile/blob/main/llamafile/tinyblas_cpu.h),
///! built as a v2-poc demo of `comptime` generics + `@Vector` SIMD
///! builtins replacing that file's C++ template class plus its
///! per-ISA `#ifdef __FMA__`/`#ifdef __ARM_FEATURE_FMA`/... ladder of
///! hand-written `add`/`mul`/`madd` intrinsic overloads.
///!
///! Deliberately NOT ported: llamafile's runtime dispatch between whole
///! functions compiled for different x86 microarchitectures (AVX-512+BF16
///! vs. plain AVX2, chosen via `cpuid` at process startup) — Zig has no
///! turnkey equivalent of GCC/Clang function multiversioning for that;
///! this file picks one `@Vector` width per build target instead, same
///! as this project's own `zig build cross` already does per platform.
///! Also not ported: the quantized-type kernels (`tinyBLAS_Q0_*`,
///! integer dot-product intrinsics with no portable `@Vector` equivalent
///! either way) and the Kahan-style hierarchical summation tinyBLAS uses
///! for numerical stability over long `k` — `matmulSimd` accumulates
///! each output element as one running sum per the usual IEEE 754
///! rounding behavior, same as `matmulNaive`, not bit-identical to a
///! from-scratch BLAS but matching to float64 precision for the sizes
///! this demo targets.
///!
///! `matmulSimdParallel` adds a third axis this PoC's SIMD kernel alone
///! doesn't have: multiple OS threads. It splits `matmulSimd`'s row
///! tiles across `std.Io.Group.concurrent` tasks instead of running them
///! on one thread — using Zig 0.17's `std.Io` concurrency interface
///! (`Threaded`'s own worker pool), not a new dependency, since each
///! tile writes disjoint output rows and needs no synchronization with
///! the others. llamafile's own threading lives one layer up, in
///! llama.cpp's scheduler, not inside tinyBLAS itself — so this has no
///! direct tinyBLAS analogue to port from; it's this PoC's own answer to
///! "can the matmul PoC use more than one thread" from its own
///! benchmarking session.
const std = @import("std");

/// Vector lane width for the SIMD kernel's inner loop — **picked at
/// comptime from the build's actual target CPU**, not a fixed guess.
/// `std.simd.suggestVectorLength(f64)` is the stdlib's own answer to
/// exactly the `#ifdef __AVX512F__`/`#ifdef __AVX2__`/`#ifdef __SSE__`
/// ladder tinyblas_cpu.h's `madd`/`add`/`mul` intrinsic overloads use
/// (lines 225–264 of that file) — one function querying
/// `cpu.has(.x86, .avx512f)`/`.avx2`/`.sse`/`cpu.has(.arm, .neon)`/
/// `cpu.has(.aarch64, .sve)`/etc. at comptime, covering far more
/// architectures (x86, ARM, AArch64 SVE, RISC-V V, WASM SIMD128,
/// PowerPC, MIPS, s390x, SPARC, Hexagon, LoongArch — see its own
/// implementation in `std/simd.zig`) than tinyblas_cpu.h's hand-written
/// x86/ARM-only ladder. `orelse 1` falls back to a 1-wide "vector" (a
/// genuine scalar loop, `@Vector(1, T)` compiles away to plain scalar
/// code) on a target with no detected SIMD support at all.
///
/// Confirmed live, not assumed: compiling this exact file for
/// `x86_64-linux-gnu` with no `-Dcpu=` override (Zig's conservative
/// baseline for that triple) resolves to 2 (128-bit SSE2); the identical
/// source recompiled with `-Dcpu=x86_64_v3` (an AVX2-capable baseline)
/// resolves to 4 (256-bit AVX2) — the same `@Vector`-based kernel code,
/// genuinely picking a different lane width per target, with zero
/// source-level branching on which ISA is active.
const vec_width = std.simd.suggestVectorLength(f64) orelse 1;
const Vec = @Vector(vec_width, f64);

/// Naive O(m·n·k) scalar triple loop — the baseline `matmulSimd` is
/// benchmarked against.
pub fn matmulNaive(a: []const f64, b: []const f64, c: []f64, m: usize, k: usize, n: usize) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var sum: f64 = 0;
            for (0..k) |l| sum += a[i * k + l] * b[l * n + j];
            c[i * n + j] = sum;
        }
    }
}

/// One register-blocked tile per iteration over `[tile_lo, tile_hi)` of the `RM`-row tile index —
/// the inner loop `matmulSimd` runs serially over the whole range, and `matmulSimdParallel` runs
/// concurrently over disjoint sub-ranges of. `RM` rows of A/C share each loaded vector of B across
/// all `RM` row-accumulators — the "unroll the outer loop so a B load is reused across multiple
/// FMAs" trick tinyblas_cpu.h's `gemm<RM, RN>` (and the blog post's `SLLMM4`/`SLLMM3X4` examples)
/// describe, simplified to one vector-width of columns per iteration instead of full 2D (RM×RN)
/// tiling. The `n % vec_width` column remainder falls back to a plain scalar loop — not the
/// reference's recursive edge-tiling (`mnpack`), a deliberate simplification for this POC.
fn simdTileRange(comptime RM: usize, a: []const f64, b: []const f64, c: []f64, k: usize, n: usize, n_vecs: usize, tile_lo: usize, tile_hi: usize) void {
    var it = tile_lo;
    while (it < tile_hi) : (it += 1) {
        const row0 = it * RM;

        var jv: usize = 0;
        while (jv < n_vecs) : (jv += 1) {
            const j0 = jv * vec_width;
            var acc: [RM]Vec = undefined;
            inline for (0..RM) |r| acc[r] = @splat(0);

            for (0..k) |l| {
                const bvec: Vec = b[l * n + j0 ..][0..vec_width].*;
                inline for (0..RM) |r| {
                    const aval: Vec = @splat(a[(row0 + r) * k + l]);
                    acc[r] = @mulAdd(Vec, aval, bvec, acc[r]);
                }
            }

            inline for (0..RM) |r| {
                c[(row0 + r) * n + j0 ..][0..vec_width].* = acc[r];
            }
        }

        // Column remainder (n % vec_width) for this row tile, scalar.
        var j = n_vecs * vec_width;
        while (j < n) : (j += 1) {
            inline for (0..RM) |r| {
                var sum: f64 = 0;
                for (0..k) |l| sum += a[(row0 + r) * k + l] * b[l * n + j];
                c[(row0 + r) * n + j] = sum;
            }
        }
    }
}

/// Row remainder (m % RM) past the last full tile, scalar — shared by `matmulSimd` and
/// `matmulSimdParallel`, which both tile only `m / RM` whole groups of rows.
fn scalarRowRemainder(a: []const f64, b: []const f64, c: []f64, m_tiles_end: usize, m: usize, k: usize, n: usize) void {
    var i = m_tiles_end;
    while (i < m) : (i += 1) {
        for (0..n) |j| {
            var sum: f64 = 0;
            for (0..k) |l| sum += a[i * k + l] * b[l * n + j];
            c[i * n + j] = sum;
        }
    }
}

/// Serial register-blocked SIMD kernel: see `simdTileRange`'s doc comment for the kernel itself.
pub fn matmulSimd(comptime RM: usize, a: []const f64, b: []const f64, c: []f64, m: usize, k: usize, n: usize) void {
    const m_tiles = m / RM;
    const n_vecs = n / vec_width;
    simdTileRange(RM, a, b, c, k, n, n_vecs, 0, m_tiles);
    scalarRowRemainder(a, b, c, m_tiles * RM, m, k, n);
}

/// `matmulSimd`, with the `RM`-row tiles split into up to `max_tasks` contiguous ranges run
/// concurrently via `io` (an `std.Io.Group`) — each tile writes disjoint rows of `c`, so no
/// synchronization is needed between tasks. Falls back to running a sub-range inline, on the
/// calling thread, if `io`'s implementation can't grant concurrency for it (`Group.concurrent`'s
/// `error.ConcurrencyUnavailable`) — e.g. a single-threaded `Io`.
///
/// Dispatch has real overhead (thread-pool task handoff, not free), so this only pays off once a
/// task's share of the work clears that cost by a comfortable margin; for small matrices, more
/// tasks can mean a slower result than `matmulSimd` alone. See `zig_v2_matmul_bench_ct`'s own
/// numbers for where the crossover actually falls on a given machine.
pub fn matmulSimdParallel(comptime RM: usize, io: std.Io, max_tasks: usize, a: []const f64, b: []const f64, c: []f64, m: usize, k: usize, n: usize) void {
    const m_tiles = m / RM;
    const n_vecs = n / vec_width;
    const tasks = @max(@as(usize, 1), @min(max_tasks, m_tiles));

    if (tasks <= 1) {
        simdTileRange(RM, a, b, c, k, n, n_vecs, 0, m_tiles);
    } else {
        const Task = struct {
            fn run(aa: []const f64, bb: []const f64, cc: []f64, kk: usize, nn: usize, nv: usize, lo: usize, hi: usize) void {
                simdTileRange(RM, aa, bb, cc, kk, nn, nv, lo, hi);
            }
        };
        var group: std.Io.Group = .init;
        const base = m_tiles / tasks;
        const extra = m_tiles % tasks;
        var lo: usize = 0;
        for (0..tasks) |t| {
            const hi = lo + base + @as(usize, if (t < extra) 1 else 0);
            group.concurrent(io, Task.run, .{ a, b, c, k, n, n_vecs, lo, hi }) catch Task.run(a, b, c, k, n, n_vecs, lo, hi);
            lo = hi;
        }
        group.await(io) catch {};
    }

    scalarRowRemainder(a, b, c, m_tiles * RM, m, k, n);
}

/// The RM this project's DuckDB-facing functions use — 4 rows of
/// accumulators, matching the register-pressure spirit of tinyblas's
/// own tile choices without tuning per target.
pub const default_rm = 4;

test "matmulSimd agrees with matmulNaive on a non-square, non-tile-aligned matrix" {
    const m = 7;
    const k = 5;
    const n = 11;
    var a: [m * k]f64 = undefined;
    var b: [k * n]f64 = undefined;
    for (&a, 0..) |*v, i| v.* = @floatFromInt(i % 7);
    for (&b, 0..) |*v, i| v.* = @floatFromInt((i % 5) + 1);

    var c_naive: [m * n]f64 = undefined;
    var c_simd: [m * n]f64 = undefined;
    matmulNaive(&a, &b, &c_naive, m, k, n);
    matmulSimd(default_rm, &a, &b, &c_simd, m, k, n);

    for (c_naive, c_simd) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-9);
    }
}

test "matmulSimd agrees with matmulNaive on a tile-aligned matrix" {
    const m = 8;
    const k = 8;
    const n = 8;
    var a: [m * k]f64 = undefined;
    var b: [k * n]f64 = undefined;
    for (&a, 0..) |*v, i| v.* = @floatFromInt(i);
    for (&b, 0..) |*v, i| v.* = @floatFromInt(i);

    var c_naive: [m * n]f64 = undefined;
    var c_simd: [m * n]f64 = undefined;
    matmulNaive(&a, &b, &c_naive, m, k, n);
    matmulSimd(default_rm, &a, &b, &c_simd, m, k, n);

    for (c_naive, c_simd) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-9);
    }
}

test "matmulSimd handles a 2x2 identity multiplication" {
    const a = [_]f64{ 1, 0, 0, 1 };
    const b = [_]f64{ 5, 6, 7, 8 };
    var c: [4]f64 = undefined;
    matmulSimd(1, &a, &b, &c, 2, 2, 2);
    try std.testing.expectEqualSlices(f64, &b, &c);
}

test "matmulSimdParallel agrees with matmulNaive, split across more tasks than there are tiles" {
    const m = 37;
    const k = 9;
    const n = 23;
    var a: [m * k]f64 = undefined;
    var b: [k * n]f64 = undefined;
    for (&a, 0..) |*v, i| v.* = @floatFromInt(i % 11);
    for (&b, 0..) |*v, i| v.* = @floatFromInt((i % 6) + 1);

    var c_naive: [m * n]f64 = undefined;
    var c_parallel: [m * n]f64 = undefined;
    matmulNaive(&a, &b, &c_naive, m, k, n);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    // More tasks than m_tiles (37 / 4 = 9): exercises the "fewer tasks than asked for" clamp too.
    matmulSimdParallel(default_rm, threaded.io(), 64, &a, &b, &c_parallel, m, k, n);

    for (c_naive, c_parallel) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-9);
    }
}
