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
///!
///! `matmulSimdBlocked`/`matmulSimdParallelBlocked` add a fourth axis: cache reuse beyond the
///! register tile. `simdTileRange`'s single pass down all of `k` re-streams the whole of `B` from
///! RAM once per row tile once `k * n * 8` bytes stops fitting in cache — exactly the regime this
///! PoC's own benchmarking session found (GFLOPS falling off from n=512 to n=2000, serial and
///! parallel alike). The blocked kernels restructure the loop order into `default_bn`-wide ×
///! `default_bk`-deep panels of `B`, so a panel stays resident across every row tile that needs
///! it. Still not the real thing: a production BLAS also blocks (and packs into contiguous
///! buffers) the `M` dimension so `A`'s panel survives across `N` panels too — this PoC blocked
///! `B` only at first, documented here rather than silently assumed to be "the same as OpenBLAS
///! now."
///!
///! `matmulSimdBlockedMc`/`matmulSimdParallelBlockedMc` add that third tier: `A` also gets
///! panel-blocked (see `simdTileRangeBlockedMc`'s own doc comment for why, and the real trade-off
///! it makes — `B` pays for it with an extra full sweep per `A`-panel). Not literal packing
///! (copying into a freshly laid-out contiguous buffer, what a real BLAS does): both `a` and `b`
///! are already row-major and already contiguous along the exact ranges `microTile` reads them
///! in, so there's little the kind of packing a column-major/arbitrary-stride BLAS needs would
///! add here — only the loop-order/panel-size change actually matters for this file's layout.
///!
///! STOPPED HERE, two negative results in a row, both confirmed by repeated trials (noise alone
///! doesn't explain either):
///!   1. `matmulSimdBlockedMc`/`matmulSimdParallelBlockedMc` themselves, with the full
///!      `default_mc_bytes` per thread: a wash for the serial kernel at every size tried (one
///!      thread never saturates memory bandwidth enough for `A`'s extra re-reads to matter), and
///!      noisy-to-negative for the parallel one.
///!   2. Dividing that budget by thread count (the fix the noisy parallel result above suggested
///!      — every thread targeting the *same* L3 budget at once oversubscribes a cache that's
///!      shared, not per-core): made the parallel kernel consistently *worse* instead, because
///!      the smaller per-thread budget lands `panel_tiles` just under a thread's own already-small
///!      tile range, so threads that get one extra tile from `m_tiles % tasks` now pay for an
///!      entire extra N/K-panel sweep (all its loop overhead) to cover that single leftover row
///!      tile. That's a quantization artifact of this specific division, not evidence against the
///!      shared-L3 idea it was meant to test — the two effects are tangled together and untangling
///!      them (e.g. skip the leftover panel below some minimum size) wasn't pursued.
///! `matmulSimdParallelBlocked` (two-tier: `B` panel-blocked, no `A` panel-blocking) remains the
///! best-measured kernel in this file for every size this PoC's benchmarking tried except the
///! largest, where OpenBLAS still wins — see the benchmarking session's own numbers for specifics.
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

/// `K` block size (the reduction dimension) for `matmulSimdBlocked`/`matmulSimdParallelBlocked`.
/// A `BK × BN` panel of `B` (`default_bk * default_bn * 8` bytes = 512 KiB) is read in full once
/// per row tile that uses it, so keeping that panel resident in L2 across every row tile — rather
/// than letting each row tile re-stream the whole of `B` from RAM, which is what `simdTileRange`
/// does once `k * n * 8` bytes stops fitting in cache — is the actual point of blocking (the
/// GotoBLAS/OpenBLAS "panel" idea, simplified to two loop levels instead of the full
/// NC/KC/MC-with-packing hierarchy a real BLAS uses). Like `default_rm`, a fixed, documented
/// guess, not derived from the build target's actual cache size — std has no portable query for
/// that — tunable if it's wrong for a given machine.
pub const default_bk: usize = 256;
/// `N` block size (the output-column dimension); see `default_bk`'s doc comment.
pub const default_bn: usize = 256;

/// One `RM`-row, one-`vec_width`-column tile of the register-blocked microkernel, restricted to
/// the `[k_lo, k_hi)` × `[n_lo, n_hi)` panel of `a`/`b` — `simdTileRange`'s kernel, with the full
/// `k`/`n` ranges each replaced by a caller-chosen sub-range. `accumulate` says whether `c`
/// already holds a partial sum from an earlier `k`-panel for this same `n`-panel (add to it)
/// or is this row/column's first contribution (overwrite it) — the caller must visit every
/// `k`-panel of a given `n`-panel, for a given row tile, in order, accumulate=false only on the
/// first.
fn microTile(comptime RM: usize, a: []const f64, b: []const f64, c: []f64, k_full: usize, n_full: usize, k_lo: usize, k_hi: usize, n_lo: usize, n_hi: usize, accumulate: bool, row0: usize) void {
    const n_vecs = (n_hi - n_lo) / vec_width;
    var jv: usize = 0;
    while (jv < n_vecs) : (jv += 1) {
        const j0 = n_lo + jv * vec_width;
        var acc: [RM]Vec = undefined;
        if (accumulate) {
            inline for (0..RM) |r| acc[r] = c[(row0 + r) * n_full + j0 ..][0..vec_width].*;
        } else {
            inline for (0..RM) |r| acc[r] = @splat(0);
        }

        var l = k_lo;
        while (l < k_hi) : (l += 1) {
            const bvec: Vec = b[l * n_full + j0 ..][0..vec_width].*;
            inline for (0..RM) |r| {
                const aval: Vec = @splat(a[(row0 + r) * k_full + l]);
                acc[r] = @mulAdd(Vec, aval, bvec, acc[r]);
            }
        }

        inline for (0..RM) |r| {
            c[(row0 + r) * n_full + j0 ..][0..vec_width].* = acc[r];
        }
    }

    // Column remainder ((n_hi - n_lo) % vec_width) within this panel, scalar.
    var j = n_lo + n_vecs * vec_width;
    while (j < n_hi) : (j += 1) {
        inline for (0..RM) |r| {
            var sum: f64 = if (accumulate) c[(row0 + r) * n_full + j] else 0;
            var l = k_lo;
            while (l < k_hi) : (l += 1) sum += a[(row0 + r) * k_full + l] * b[l * n_full + j];
            c[(row0 + r) * n_full + j] = sum;
        }
    }
}

/// `simdTileRange`, restructured in `default_bn`-wide column panels and `default_bk`-deep
/// reduction panels — the GotoBLAS loop order (N panel outside, K panel inside it, then every row
/// tile, then the microkernel) instead of `simdTileRange`'s single pass straight down all of `k`.
/// Parallelism (in `matmulSimdParallelBlocked`) still splits `[tile_lo, tile_hi)` the same way
/// `simdTileRange` does — blocking only changes what one thread does with its own row-tile range,
/// not how the range is split, so dispatch cost is identical to the unblocked kernel.
fn simdTileRangeBlocked(comptime RM: usize, a: []const f64, b: []const f64, c: []f64, k: usize, n: usize, tile_lo: usize, tile_hi: usize) void {
    var n_lo: usize = 0;
    while (n_lo < n) : (n_lo += default_bn) {
        const n_hi = @min(n_lo + default_bn, n);

        var k_lo: usize = 0;
        var first_k = true;
        while (k_lo < k) : (k_lo += default_bk) {
            const k_hi = @min(k_lo + default_bk, k);

            var it = tile_lo;
            while (it < tile_hi) : (it += 1) microTile(RM, a, b, c, k, n, k_lo, k_hi, n_lo, n_hi, !first_k, it * RM);

            first_k = false;
        }
    }
}

/// `matmulSimd`, with `B`'s panels blocked for cache reuse — see `simdTileRangeBlocked`'s doc
/// comment. Same row-remainder handling as `matmulSimd`; the remainder (`m % RM` rows) is small
/// enough that blocking it isn't worth the bookkeeping.
pub fn matmulSimdBlocked(comptime RM: usize, a: []const f64, b: []const f64, c: []f64, m: usize, k: usize, n: usize) void {
    const m_tiles = m / RM;
    simdTileRangeBlocked(RM, a, b, c, k, n, 0, m_tiles);
    scalarRowRemainder(a, b, c, m_tiles * RM, m, k, n);
}

/// `matmulSimdParallel`, with the per-thread row-tile range processed by the blocked kernel
/// (`simdTileRangeBlocked`) instead of the unblocked one — combines both: multiple threads, each
/// one reusing cached `B` panels across its own row tiles. See both functions' own doc comments.
pub fn matmulSimdParallelBlocked(comptime RM: usize, io: std.Io, max_tasks: usize, a: []const f64, b: []const f64, c: []f64, m: usize, k: usize, n: usize) void {
    const m_tiles = m / RM;
    const tasks = @max(@as(usize, 1), @min(max_tasks, m_tiles));

    if (tasks <= 1) {
        simdTileRangeBlocked(RM, a, b, c, k, n, 0, m_tiles);
    } else {
        const Task = struct {
            fn run(aa: []const f64, bb: []const f64, cc: []f64, kk: usize, nn: usize, lo: usize, hi: usize) void {
                simdTileRangeBlocked(RM, aa, bb, cc, kk, nn, lo, hi);
            }
        };
        var group: std.Io.Group = .init;
        const base = m_tiles / tasks;
        const extra = m_tiles % tasks;
        var lo: usize = 0;
        for (0..tasks) |t| {
            const hi = lo + base + @as(usize, if (t < extra) 1 else 0);
            group.concurrent(io, Task.run, .{ a, b, c, k, n, lo, hi }) catch Task.run(a, b, c, k, n, lo, hi);
            lo = hi;
        }
        group.await(io) catch {};
    }

    scalarRowRemainder(a, b, c, m_tiles * RM, m, k, n);
}

/// Target footprint for `A`'s own resident slice in `simdTileRangeBlockedMc` — the third tier
/// `simdTileRangeBlocked` doesn't have. Picked for L3 rather than L2: unlike `default_bk`/
/// `default_bn`'s panel of `B`, which needs to survive only across one thread's own row tiles,
/// this slice of `A` needs to survive across `simdTileRangeBlocked`'s *entire* N/K sweep for a
/// given M-panel — a much longer stretch — so it's sized for the bigger, slower cache tier.
/// Same "fixed documented guess" caveat as `default_rm`/`default_bk`/`default_bn`. This is the
/// *total* L3 budget for the matrix, not a per-thread one — `matmulSimdParallelBlockedMc` divides
/// it by its own thread count before passing it to `simdTileRangeBlockedMc`, since L3 is shared:
/// every thread targeting this many bytes resident *at once* would collectively oversubscribe a
/// real L3 by a factor of the thread count.
pub const default_mc_bytes: usize = 8 * 1024 * 1024;

/// `simdTileRangeBlocked`, with `[tile_lo, tile_hi)` itself split into row-panels first — the
/// third blocking tier `matmulSimdBlocked` doesn't have. Why it's needed: `simdTileRangeBlocked`
/// reuses `B`'s panel across the *whole* given tile range, which is exactly its win, but as a
/// consequence it re-sweeps that whole tile range's slice of `A` once per `N`-panel (`default_bn`
/// doesn't appear anywhere in this file as a guard against that — it was never meant to be one).
/// For a large `m`/`k`, that slice of `A` no longer fits any cache tier either, so those repeated
/// sweeps start hitting RAM again, the same problem blocking `B` already fixed, just moved to the
/// other operand. Splitting `[tile_lo, tile_hi)` into panels small enough that one panel's full-
/// width (`panel_rows * k * 8` bytes, `mc_bytes`) slice of `A` fits a cache tier trades this: that
/// slice of `A` now gets re-read from the *same* panel's own N/K sweep but should hit L3 (or L2,
/// for a small enough `k`) instead of RAM — at the cost of `B` now being fully re-swept once per
/// row-panel instead of once per thread's whole tile range, since each call to
/// `simdTileRangeBlocked` below starts its own `B`-panel sweep from scratch. `mc_bytes` is the
/// caller's own budget to spend, already divided by thread count if there are several threads —
/// this function doesn't know or care how many other callers are sharing the same L3 concurrently.
/// A net win only if what `A`'s repeated re-reads save (RAM → L3) outweighs what `B` loses (an
/// extra full sweep per panel instead of one); see `zig_v2_matmul_bench_ct`'s own numbers for
/// whether it does on a given machine, matrix size and thread count.
fn simdTileRangeBlockedMc(comptime RM: usize, a: []const f64, b: []const f64, c: []f64, k: usize, n: usize, tile_lo: usize, tile_hi: usize, mc_bytes: usize) void {
    const bytes_per_row = @max(k, 1) * @sizeOf(f64);
    const panel_tiles = @max(@as(usize, 1), (mc_bytes / bytes_per_row) / RM);

    var it = tile_lo;
    while (it < tile_hi) : (it += panel_tiles) {
        const hi = @min(it + panel_tiles, tile_hi);
        simdTileRangeBlocked(RM, a, b, c, k, n, it, hi);
    }
}

/// `matmulSimdBlocked`, with `A` also panel-blocked — see `simdTileRangeBlockedMc`'s doc comment.
/// The sole caller/thread, so it spends the whole of `default_mc_bytes` itself.
pub fn matmulSimdBlockedMc(comptime RM: usize, a: []const f64, b: []const f64, c: []f64, m: usize, k: usize, n: usize) void {
    const m_tiles = m / RM;
    simdTileRangeBlockedMc(RM, a, b, c, k, n, 0, m_tiles, default_mc_bytes);
    scalarRowRemainder(a, b, c, m_tiles * RM, m, k, n);
}

/// `matmulSimdParallelBlocked`, with each thread's own row-tile range additionally panel-blocked
/// by `simdTileRangeBlockedMc` instead of swept in one pass by `simdTileRangeBlocked` — see that
/// function's doc comment. Thread dispatch is unchanged: the M-panel split happens *within* one
/// thread's already-assigned range, not as a new axis of concurrency. `default_mc_bytes` is
/// divided by `tasks` before being handed to any thread — all `tasks` threads share one L3, so
/// each one claiming the whole budget for itself would oversubscribe it by that same factor.
pub fn matmulSimdParallelBlockedMc(comptime RM: usize, io: std.Io, max_tasks: usize, a: []const f64, b: []const f64, c: []f64, m: usize, k: usize, n: usize) void {
    const m_tiles = m / RM;
    const tasks = @max(@as(usize, 1), @min(max_tasks, m_tiles));
    const mc_bytes_per_task = @max(@as(usize, 1), default_mc_bytes / tasks);

    if (tasks <= 1) {
        simdTileRangeBlockedMc(RM, a, b, c, k, n, 0, m_tiles, mc_bytes_per_task);
    } else {
        const Task = struct {
            fn run(aa: []const f64, bb: []const f64, cc: []f64, kk: usize, nn: usize, lo: usize, hi: usize, mc: usize) void {
                simdTileRangeBlockedMc(RM, aa, bb, cc, kk, nn, lo, hi, mc);
            }
        };
        var group: std.Io.Group = .init;
        const base = m_tiles / tasks;
        const extra = m_tiles % tasks;
        var lo: usize = 0;
        for (0..tasks) |t| {
            const hi = lo + base + @as(usize, if (t < extra) 1 else 0);
            group.concurrent(io, Task.run, .{ a, b, c, k, n, lo, hi, mc_bytes_per_task }) catch Task.run(a, b, c, k, n, lo, hi, mc_bytes_per_task);
            lo = hi;
        }
        group.await(io) catch {};
    }

    scalarRowRemainder(a, b, c, m_tiles * RM, m, k, n);
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

test "matmulSimdBlocked agrees with matmulNaive across multiple N and K panels, non-aligned" {
    // default_bn/default_bk are 256; cross several panel boundaries in both k and n, with a
    // partial last panel in each, plus a non-tile-aligned m.
    const m = 37;
    const k = 530;
    const n = 517;
    const a = std.testing.allocator.alloc(f64, m * k) catch unreachable;
    defer std.testing.allocator.free(a);
    const b = std.testing.allocator.alloc(f64, k * n) catch unreachable;
    defer std.testing.allocator.free(b);
    for (a, 0..) |*v, i| v.* = @floatFromInt(i % 11);
    for (b, 0..) |*v, i| v.* = @floatFromInt((i % 6) + 1);

    const c_naive = std.testing.allocator.alloc(f64, m * n) catch unreachable;
    defer std.testing.allocator.free(c_naive);
    const c_blocked = std.testing.allocator.alloc(f64, m * n) catch unreachable;
    defer std.testing.allocator.free(c_blocked);
    matmulNaive(a, b, c_naive, m, k, n);
    matmulSimdBlocked(default_rm, a, b, c_blocked, m, k, n);

    for (c_naive, c_blocked) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
    }
}

test "matmulSimdParallelBlocked agrees with matmulNaive, split across more tasks than there are tiles" {
    const m = 37;
    const k = 530;
    const n = 517;
    const a = std.testing.allocator.alloc(f64, m * k) catch unreachable;
    defer std.testing.allocator.free(a);
    const b = std.testing.allocator.alloc(f64, k * n) catch unreachable;
    defer std.testing.allocator.free(b);
    for (a, 0..) |*v, i| v.* = @floatFromInt(i % 11);
    for (b, 0..) |*v, i| v.* = @floatFromInt((i % 6) + 1);

    const c_naive = std.testing.allocator.alloc(f64, m * n) catch unreachable;
    defer std.testing.allocator.free(c_naive);
    const c_parallel = std.testing.allocator.alloc(f64, m * n) catch unreachable;
    defer std.testing.allocator.free(c_parallel);
    matmulNaive(a, b, c_naive, m, k, n);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    matmulSimdParallelBlocked(default_rm, threaded.io(), 64, a, b, c_parallel, m, k, n);

    for (c_naive, c_parallel) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
    }
}

test "matmulSimdBlockedMc agrees with matmulNaive, split across multiple M-panels" {
    // A large k forces `simdTileRangeBlockedMc`'s panel_tiles well below m_tiles (9 tiles here),
    // so this exercises several M-panel boundaries, not just the single-panel fallback.
    const m = 37;
    const k = 100_000;
    const n = 23;
    const a = std.testing.allocator.alloc(f64, m * k) catch unreachable;
    defer std.testing.allocator.free(a);
    const b = std.testing.allocator.alloc(f64, k * n) catch unreachable;
    defer std.testing.allocator.free(b);
    for (a, 0..) |*v, i| v.* = @floatFromInt(i % 11);
    for (b, 0..) |*v, i| v.* = @floatFromInt((i % 6) + 1);

    const c_naive = std.testing.allocator.alloc(f64, m * n) catch unreachable;
    defer std.testing.allocator.free(c_naive);
    const c_blocked = std.testing.allocator.alloc(f64, m * n) catch unreachable;
    defer std.testing.allocator.free(c_blocked);
    matmulNaive(a, b, c_naive, m, k, n);
    matmulSimdBlockedMc(default_rm, a, b, c_blocked, m, k, n);

    for (c_naive, c_blocked) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
    }
}

test "matmulSimdParallelBlockedMc agrees with matmulNaive, split across multiple M-panels and tasks" {
    const m = 37;
    const k = 100_000;
    const n = 23;
    const a = std.testing.allocator.alloc(f64, m * k) catch unreachable;
    defer std.testing.allocator.free(a);
    const b = std.testing.allocator.alloc(f64, k * n) catch unreachable;
    defer std.testing.allocator.free(b);
    for (a, 0..) |*v, i| v.* = @floatFromInt(i % 11);
    for (b, 0..) |*v, i| v.* = @floatFromInt((i % 6) + 1);

    const c_naive = std.testing.allocator.alloc(f64, m * n) catch unreachable;
    defer std.testing.allocator.free(c_naive);
    const c_parallel = std.testing.allocator.alloc(f64, m * n) catch unreachable;
    defer std.testing.allocator.free(c_parallel);
    matmulNaive(a, b, c_naive, m, k, n);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    matmulSimdParallelBlockedMc(default_rm, threaded.io(), 64, a, b, c_parallel, m, k, n);

    for (c_naive, c_parallel) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
    }
}
