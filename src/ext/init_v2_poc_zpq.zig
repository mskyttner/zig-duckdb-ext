///! Speculative, fully isolated v2-poc demo: `zig_v2_read_parquet(path, column) -> (value BIGINT)`,
///! built directly on zpq's `core.parquet`/`core.filter` surface (footer parsing, per-column-chunk
///! decode) rather than its `core.scan` aggregate-pipeline worker pool or its `io.*` surface
///! (S3/TLS/epoll) — see docs/rationale for the investigation that scoped this to exactly that
///! subset, and build.zig.zon's `.zpq` entry for the live confirmation that `io.*`/BoringSSL never
///! actually compile from this file alone.
///!
///! Builds as its own separate `.duckdb_extension` (`zig build v2-poc-zpq`), entirely independent
///! of `init_v2_poc.zig`/`zig_ext_v2_poc` — same full-isolation reasoning as
///! `init_v2_poc_braille.zig`/`init_v2_poc_stipple.zig`: this is the only place in the project
///! pulling in `zpq`, so nothing else is ever affected if it has trouble building or fetching.
///!
///! Deliberately narrow: one INT64 column, REQUIRED or singly-OPTIONAL (max_def <= 1), never
///! repeated; whole file read into memory; no row_gate. OPTIONAL support isn't a nice-to-have —
///! DuckDB's own `COPY ... TO PARQUET` emits columns as
///! OPTIONAL by default (confirmed live: a REQUIRED-only first cut rejected every file DuckDB
///! itself writes). Extending beyond max_def <= 1 (nested/repeated) is follow-up work.
///!
///! Tuned to parity with DuckDB's own single-threaded native `read_parquet` on a 10M-row column
///! (confirmed live, both at 0.06s): decode straight into the output vector's own buffer instead
///! of through a stack copy, reset the per-scan arena after each row group instead of letting
///! zpq's scratch allocations accumulate across all of them, and vectorize the validity-bit
///! writer (`writeValidityBits` below: one `@reduce(.Or, ...)` per 64-row word instead of 64
///! scalar read-modify-writes) — see git history for the step-by-step benchmark progression.
///!
///! Filter pushdown (`pushdown` below, up to `max_pushdown_filters` recognized comparisons of
///! `value <op> constant`): two independent layers, both built on zpq's `core.filter` surface, not
///! `core.scan`'s aggregate engine —
///!   - Whole-row-group skip: `filter_prune.pruneRowGroup` judges a row group from its column
///!     chunk statistics alone (min/max/null_count), before any decode. `unknown`/`keep` still
///!     decode normally; `skip` means the row group's bytes are never even sliced out of
///!     `file_bytes`, let alone decoded; `always_match` (a full-match proof) skips the per-row
///!     recheck below for that row group's rows, since they're already known to all pass.
///!   - Per-row filter + compaction: no page-level statistics are wired (that would need the
///!     footer's ColumnIndex/OffsetIndex, out of scope here), so a `keep`/`unknown` row group
///!     still decodes in full; a `SelectionVector` then marks which decoded rows actually pass
///!     (a NULL row never passes any comparison — standard SQL filter semantics), and its
///!     iterator walks the marked rows in order while `filterCompact` compacts them down in
///!     place inside the output vector's own buffer (same no-extra-copy approach `exec`'s
///!     unfiltered path already uses for decode).
///! Only `pruneRowGroup`'s metadata-only judgment is ever allowed to be an under-approximation
///! (an OOM mid-`ast.join` falls back to a single leaf instead of the full AND, which only prunes
///! less — always safe). The per-row step has no such fallback: an OOM building the
///! `SelectionVector` fails the query with a real error instead of silently returning unfiltered
///! rows, since skipping the filter there would be a correctness bug, not just a slower query.
///!
///! Parallel row-group scanning (see PLAN-zpq-parallel.md for the scoping, and why zpq's own
///! `core.scan` engine isn't reused for this): `GlobalState` holds only an atomic "next row group
///! to claim" counter over the shared, read-only `BindData` — `ColumnChunkReader(i64)` already
///! carries no state across row groups, so there's nothing else to share. Each thread's own
///! `LocalState` holds its own arena/reader/`row_group_always_match`, claimed via
///! `claimNextRowGroup`'s `fetchAdd`, so no two threads ever decode the same row group and no
///! locking is needed in `exec` itself. `partition_data` reports the claimed row-group index as
///! the batch index — row groups already have a stable file order, so the index doubles as the
///! batch index for free, keeping output in file order under `preserve_insertion_order`.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const zpq = @import("zpq");

const schema = zpq.core.schema;
const metadata = zpq.core.parquet.metadata;
const column = zpq.core.parquet.column;
const ast = zpq.core.filter.ast;
const prune = zpq.core.filter.prune;
const selection = zpq.core.filter.selection;

const Err = *v2.duckdb_v2_error_info_handle;

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = helpers.setErrorText(err.*, msg);
}

const max_file_bytes = 1 << 30; // 1 GiB — PoC guardrail, not a real limit.
const max_rows_per_batch = 2048;

/// A recognized `value <op> constant` pushdown predicate, independent of DuckDB's own
/// `v2.duckdb_v2_expression_handle` (which doesn't outlive the `pushdown` callback) and of zpq's
/// `ast.Leaf(i64)` (which needs `col_idx` — not known as a fixed constant here the way a literal
/// struct field would be, since it's `bind_data.col_idx`, resolved per file at bind time).
const FilterSpec = struct { op: ast.Operator, value: i64 };
const max_pushdown_filters = 4;

const BindData = struct {
    file_bytes: []u8,
    meta: schema.FileMetaData,
    col_idx: usize,
    max_def: i32,
    filters: [max_pushdown_filters]FilterSpec = undefined,
    filter_count: usize = 0,
};

fn destroyBindData(ptr: *anyopaque) callconv(.c) void {
    const data: *BindData = @ptrCast(@alignCast(ptr));
    data.meta.deinit(std.heap.c_allocator);
    std.heap.c_allocator.free(data.file_bytes);
    std.heap.c_allocator.destroy(data);
}

/// Shared by every thread of one scan. The only thing that needs sharing: which row group
/// hasn't been claimed yet — see this file's own module doc comment on why nothing else does.
const GlobalState = struct {
    next_rg: std.atomic.Value(usize),
};

fn destroyGlobalState(ptr: *anyopaque) callconv(.c) void {
    const state: *GlobalState = @ptrCast(@alignCast(ptr));
    std.heap.c_allocator.destroy(state);
}

/// One thread's own scan state — nothing here is ever touched by another thread.
const LocalState = struct {
    arena: std.heap.ArenaAllocator,
    reader: ?column.ColumnChunkReader(i64),
    done: bool,
    /// Whether `pruneRowGroup` already proved every row of the row group currently open in
    /// `reader` passes the pushed-down filter — set by `claimNextRowGroup`, read by `exec` to
    /// skip the redundant per-row recheck for that row group. Meaningless (never read) when
    /// `BindData.filter_count == 0`.
    row_group_always_match: bool = true,
    /// The row-group index backing `reader` right now — doubles as the batch index
    /// `partition_data` reports, since row groups already have a stable file order.
    rg_idx: usize = 0,
};

fn destroyLocalState(ptr: *anyopaque) callconv(.c) void {
    const state: *LocalState = @ptrCast(@alignCast(ptr));
    state.arena.deinit();
    std.heap.c_allocator.destroy(state);
}

fn copyArgString(info: v2.duckdb_v2_function_bind_info_handle, index: u64, err: Err) ![]u8 {
    var value: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_function_bind_get_arg_value(info, index, &value, err) != .ERROR_NONE) {
        return error.FailedToGetArgValue;
    }
    defer _ = v2.duckdb_v2_value_destroy(&value);
    var out: v2.duckdb_v2_str = undefined;
    if (v2.duckdb_v2_value_get_varchar(value, &out, err) != .ERROR_NONE) {
        return error.FailedToGetVarchar;
    }
    const ptr = out.ptr orelse return std.heap.c_allocator.dupe(u8, "");
    return std.heap.c_allocator.dupe(u8, ptr[0..out.len]);
}

const ResolvedColumn = struct { col_idx: usize, max_def: i32 };

/// Resolves `column_name` to a leaf index and validates it's a shape this
/// PoC supports: physical type INT64, not repeated (max_rep == 0), and at
/// most singly-nullable (max_def <= 1 — REQUIRED or top-level OPTIONAL).
fn resolveSupportedColumn(meta: *const schema.FileMetaData, column_name: []const u8) !ResolvedColumn {
    const col_idx = try metadata.resolveColumn(meta, column_name);
    var scratch = schema.LeafIterator.init(meta.schema.items);
    const leaf = meta.leafAt(col_idx, &scratch) orelse return error.UnknownColumn;
    if (leaf.max_def > 1 or leaf.max_rep != 0) return error.UnsupportedColumnShape;
    if (leaf.element.type != .INT64) return error.UnsupportedColumnType;
    return .{ .col_idx = col_idx, .max_def = leaf.max_def };
}

fn bind(
    info: v2.duckdb_v2_function_bind_info_handle,
    result: v2.duckdb_v2_table_function_bind_info_handle,
    context: v2.duckdb_v2_context_handle,
    err: Err,
) callconv(.c) void {
    var bigint_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(context, .LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_logical_type_destroy(&bigint_type);
    const value_col_name = helpers.str("value");
    if (v2.duckdb_v2_table_function_bind_add_result_column(result, &value_col_name, bigint_type, err) != .ERROR_NONE) return;

    const path = copyArgString(info, 0, err) catch return;
    defer std.heap.c_allocator.free(path);
    const column_name = copyArgString(info, 1, err) catch return;
    defer std.heap.c_allocator.free(column_name);

    // Zig 0.17's I/O overhaul requires an explicit `Io` implementation for
    // any filesystem call. `global_single_threaded` is std.Io's own
    // documented choice for exactly this case (a one-off blocking call,
    // no concurrency/cancelation needed) — see its doc comment in
    // std/Io/Threaded.zig.
    const io = std.Io.Threaded.global_single_threaded.io();
    const file_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.c_allocator, .limited(max_file_bytes)) catch |e| {
        return fail(err, .ERROR_IO_GENERAL, "zig_v2_read_parquet: could not read '{s}': {s}", .{ path, @errorName(e) });
    };

    var meta = metadata.open(std.heap.c_allocator, file_bytes) catch |e| {
        std.heap.c_allocator.free(file_bytes);
        return fail(err, .ERROR_INPUT_INVALID, "zig_v2_read_parquet: bad parquet footer in '{s}': {s}", .{ path, @errorName(e) });
    };
    const resolved = resolveSupportedColumn(&meta, column_name) catch |e| {
        meta.deinit(std.heap.c_allocator);
        std.heap.c_allocator.free(file_bytes);
        return fail(err, .ERROR_INPUT_INVALID, "zig_v2_read_parquet: column '{s}' unusable: {s}", .{ column_name, @errorName(e) });
    };

    const data = std.heap.c_allocator.create(BindData) catch {
        meta.deinit(std.heap.c_allocator);
        std.heap.c_allocator.free(file_bytes);
        return fail(err, .ERROR_RESOURCE_OUT_OF_MEMORY, "zig_v2_read_parquet: out of memory", .{});
    };
    data.* = .{ .file_bytes = file_bytes, .meta = meta, .col_idx = resolved.col_idx, .max_def = resolved.max_def };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = data, .destroy = destroyBindData, .equals = null };
    _ = v2.duckdb_v2_function_bind_set_bind_data(info, &boxed, err);
}

fn initGlobal(info: v2.duckdb_v2_table_function_init_global_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_init_global_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    const bind_data: *const BindData = @ptrCast(@alignCast(bind_ptr orelse return));

    // An upper bound: the engine may use fewer threads. More threads than row groups is wasted
    // dispatch — each thread's share of the work would be too small to be worth it (the same
    // lesson this project's matmul row-split benchmarking already learned).
    const row_groups = bind_data.meta.row_groups.items.len;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const max_threads = @max(@as(usize, 1), @min(cpu_count, row_groups));
    if (v2.duckdb_v2_table_function_init_global_set_max_threads(info, max_threads, err) != .ERROR_NONE) return;

    const state = std.heap.c_allocator.create(GlobalState) catch return;
    state.* = .{ .next_rg = .init(0) };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
    _ = v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err);
}

fn initLocal(info: v2.duckdb_v2_table_function_init_local_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    const state = std.heap.c_allocator.create(LocalState) catch return;
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .reader = null,
        .done = false,
    };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyLocalState, .equals = null };
    if (v2.duckdb_v2_table_function_init_local_set_local_state(info, &boxed, err) != .ERROR_NONE) destroyLocalState(state);
}

/// Claims the next unclaimed row group (via `global.next_rg.fetchAdd` — every row group index
/// is claimed by exactly one thread across the whole scan, whether it ends up pruned, invalid,
/// or actually read) and opens its column chunk reader into `local.reader`, or sets
/// `local.done` once row groups are exhausted. A claimed-but-skipped/invalid row group is never
/// retried by this or any other thread — the global counter only ever moves forward.
///
/// Resets the arena first: the previous row group's `ColumnChunkReader` (its scratch
/// allocations, dictionary pages, etc.) is always gone by the time this runs — callers null
/// `local.reader` before calling — so nothing here still needs that memory. Without this,
/// scratch from every row group this thread has read accumulates for the whole scan instead of
/// just the one currently being decoded.
fn claimNextRowGroup(local: *LocalState, global: *GlobalState, bind_data: *const BindData) void {
    _ = local.arena.reset(.free_all);
    while (true) {
        const idx = global.next_rg.fetchAdd(1, .monotonic);
        if (idx >= bind_data.meta.row_groups.items.len) break;
        const rg = &bind_data.meta.row_groups.items[idx];
        local.rg_idx = idx;

        local.row_group_always_match = true;
        if (bind_data.filter_count > 0) {
            var leaves: [max_pushdown_filters]ast.Filter = undefined;
            for (bind_data.filters[0..bind_data.filter_count], 0..) |spec, i| {
                leaves[i] = .{ .int64 = .{ .col_idx = bind_data.col_idx, .op = spec.op, .value = spec.value } };
            }
            // `ast.join` only allocates (the flattened `children` slice) when
            // combining 2+ operands; the single-filter case returns that
            // leaf unchanged, no allocation at all. An OOM here falls back
            // to pruning with just the first filter instead of the full
            // AND — a weaker, still-correct judgment (it can only prune
            // LESS aggressively), unlike the per-row step below, which has
            // no safe way to under-apply the filter.
            const combined: ast.Filter = if (bind_data.filter_count == 1)
                leaves[0]
            else
                ast.join(local.arena.allocator(), true, leaves[0..bind_data.filter_count]) catch leaves[0];
            const decision = prune.pruneRowGroup(rg, combined, &bind_data.meta);
            if (decision == .skip) continue; // whole row group pruned — never even sliced out of file_bytes
            local.row_group_always_match = (decision == .always_match);
        }

        const chunk = &rg.columns.items[bind_data.col_idx];
        const col_meta = chunk.meta_data orelse continue;
        const start = col_meta.dictionary_page_offset orelse col_meta.data_page_offset;
        if (start < 0 or col_meta.total_compressed_size < 0) continue;
        const start_u: u64 = @intCast(start);
        const length: u64 = @intCast(col_meta.total_compressed_size);
        if (length > bind_data.file_bytes.len or start_u > bind_data.file_bytes.len - length) continue;
        const chunk_bytes = bind_data.file_bytes[start_u .. start_u + length];
        local.reader = column.ColumnChunkReader(i64).init(
            chunk_bytes,
            col_meta.codec,
            .{ .max_def = bind_data.max_def, .max_rep = 0 },
            local.arena.allocator(),
        );
        return;
    }
    local.done = true;
}

/// Writes one validity bit per row of `def_levels` into `bits` (DuckDB's
/// own flat validity mask: 1 = valid, 0 = NULL). `def_levels[i]` is
/// always 0 or 1 here — this PoC only supports max_def <= 1 — so "is it
/// defined" collapses to a lane select against a per-bit constant instead
/// of a per-row branch, and a 64-row group reduces to one word with one
/// `@reduce(.Or, ...)` instead of 64 sequential scalar read-modify-writes.
/// Full 64-row words first, then a scalar tail for whatever doesn't
/// divide evenly.
fn writeValidityBits(bits: [*]u64, def_levels: []const u32) void {
    const V = @Vector(64, u64);
    const bit_consts: V = comptime blk: {
        var arr: [64]u64 = undefined;
        for (0..64) |b| arr[b] = @as(u64, 1) << b;
        break :blk arr;
    };
    const zero: V = @splat(0);

    var i: usize = 0;
    while (i + 64 <= def_levels.len) : (i += 64) {
        const defs: @Vector(64, u32) = def_levels[i..][0..64].*;
        const is_defined = defs == @as(@Vector(64, u32), @splat(1));
        bits[i / 64] = @reduce(.Or, @select(u64, is_defined, bit_consts, zero));
    }
    while (i < def_levels.len) : (i += 1) {
        const word = i / 64;
        const bit: u6 = @intCast(i % 64);
        if (def_levels[i] == 1) {
            bits[word] |= (@as(u64, 1) << bit);
        } else {
            bits[word] &= ~(@as(u64, 1) << bit);
        }
    }
}

fn evalFilters(specs: []const FilterSpec, value: i64) bool {
    for (specs) |s| {
        const pass = switch (s.op) {
            .Eq => value == s.value,
            .NotEq => value != s.value,
            .Lt => value < s.value,
            .LtEq => value <= s.value,
            .Gt => value > s.value,
            .GtEq => value >= s.value,
        };
        if (!pass) return false;
    }
    return true;
}

/// Filters and compacts `dest` in place against `specs`, using a `SelectionVector` to mark which
/// rows pass (a NULL row never passes — standard SQL filter semantics: a NULL comparison is
/// UNKNOWN, which WHERE treats as false) and its iterator to walk the marked rows in order while
/// compacting — the write index never passes the read index, so this is safe in place. Every kept
/// row is therefore non-NULL, so the caller never needs to touch the validity mask for the result
/// of this call. Returns the compacted row count, or `null` if it already reported a real query
/// failure through `err` — see this file's module doc comment on why there's no safe fallback
/// here, unlike `pruneRowGroup`'s.
fn filterCompact(specs: []const FilterSpec, max_def: i32, dest: []i64, def_levels: []const u32, err: Err) ?usize {
    var sel = selection.SelectionVector.init(std.heap.c_allocator, dest.len) catch {
        fail(err, .ERROR_RESOURCE_OUT_OF_MEMORY, "zig_v2_read_parquet: out of memory building selection vector", .{});
        return null;
    };
    defer sel.deinit();

    for (0..dest.len) |i| {
        const is_valid = max_def == 0 or def_levels[i] == 1;
        if (!is_valid or !evalFilters(specs, dest[i])) sel.set(i, false);
    }

    var w: usize = 0;
    var it = sel.iterator();
    while (it.next()) |r| {
        if (r != w) dest[w] = dest[r];
        w += 1;
    }
    return w;
}

fn exec(info: v2.duckdb_v2_table_function_exec_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var chunk: v2.duckdb_v2_data_chunk_handle = undefined;
    if (v2.duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, err) != .ERROR_NONE) return;
    var value_vec: v2.duckdb_v2_vector_handle = undefined;
    if (v2.duckdb_v2_data_chunk_get_vector(chunk, 0, &value_vec, err) != .ERROR_NONE) return;

    var bind_data_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_bind_data(info, &bind_data_ptr, err) != .ERROR_NONE) return;
    // `bind` can fail (file I/O, bad footer, unsupported column) and
    // return without ever calling `function_bind_set_bind_data`. Not yet
    // reverified against this release whether DuckDB still calls `exec`
    // in that case now that `bind` reports a real error via
    // `error_info_set_code`/`setErrorText` (it did on the earlier alpha,
    // before this project could set a real error at all) — this guard
    // costs nothing either way, so it stays rather than assume the fix
    // in f1bc510 (a different bug: an uninitialized error slot during
    // registration) also covers this path.
    const bind_data: *BindData = @ptrCast(@alignCast(bind_data_ptr orelse {
        _ = v2.duckdb_v2_vector_set_size(value_vec, 0, err);
        return;
    }));

    var global_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &global_ptr, err) != .ERROR_NONE) return;
    const global: *GlobalState = @ptrCast(@alignCast(global_ptr.?));
    var local_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_local_state(info, &local_ptr, err) != .ERROR_NONE) return;
    const local: *LocalState = @ptrCast(@alignCast(local_ptr.?));

    if (local.reader == null and !local.done) claimNextRowGroup(local, global, bind_data);

    while (local.reader != null) {
        // Decode straight into the output vector's own buffer — no stack
        // scratch + memcpy. Safe to size up to capacity before knowing the
        // real count: `max_rows_per_batch` matches DuckDB's standard
        // vector size, so the buffer backing `value_vec` is already
        // allocated for this many rows regardless of what size is set.
        if (v2.duckdb_v2_vector_set_size(value_vec, max_rows_per_batch, err) != .ERROR_NONE) return;
        var out_data: ?*anyopaque = null;
        if (v2.duckdb_v2_vector_get_data_mutable(value_vec, &out_data, err) != .ERROR_NONE) return;
        // SAFETY: `value_vec` was declared BIGINT in `bind` above.
        const out: [*]i64 = @ptrCast(@alignCast(out_data));
        const dest = out[0..max_rows_per_batch];

        var def_levels: [max_rows_per_batch]u32 = undefined;
        const n = if (bind_data.max_def == 0)
            local.reader.?.decode(dest)
        else
            local.reader.?.decodeWithLevels(dest, &def_levels);
        var row_count = n catch {
            local.reader = null;
            local.done = true;
            break;
        };
        if (row_count == 0) {
            local.reader = null;
            claimNextRowGroup(local, global, bind_data);
            continue;
        }

        if (bind_data.filter_count > 0 and !local.row_group_always_match) {
            row_count = filterCompact(bind_data.filters[0..bind_data.filter_count], bind_data.max_def, dest[0..row_count], def_levels[0..row_count], err) orelse return;
            // Zero matches in THIS BATCH is not the same thing as the
            // reader being exhausted — `local.reader` is still mid-row-
            // group and may well have a match a few batches further in
            // (confirmed live: a batch straddling a selective filter's
            // match can easily decode 2048 non-matching rows before
            // reaching the one that passes). `continue` re-enters the
            // `while (local.reader != null)` loop and decodes the next
            // batch off the SAME still-live reader; only `decode`/
            // `decodeWithLevels` itself returning 0 (checked above, before
            // filtering) means the row group is actually done.
            if (row_count == 0) continue;
            // Every row `filterCompact` kept is non-NULL (see its doc
            // comment), so there's no validity mask to write here.
            if (v2.duckdb_v2_vector_set_size(value_vec, row_count, err) != .ERROR_NONE) return;
            return;
        }

        if (v2.duckdb_v2_vector_set_size(value_vec, row_count, err) != .ERROR_NONE) return;

        if (bind_data.max_def != 0) {
            var validity_ptr: *u64 = undefined;
            if (v2.duckdb_v2_vector_flat_get_validity_mutable(value_vec, &validity_ptr, err) != .ERROR_NONE) return;
            // SAFETY: the mask is a flat array of words covering every row
            // of this vector; `validity_ptr` points at word 0.
            const bits: [*]u64 = @ptrCast(validity_ptr);
            writeValidityBits(bits, def_levels[0..row_count]);
        }
        return;
    }

    if (v2.duckdb_v2_vector_set_size(value_vec, 0, err) != .ERROR_NONE) return;
}

/// After each `exec`, on the same thread: reports the claimed row group's own index as the
/// batch index, but only when `requires_batch_index` says the engine actually needs one (an
/// unordered sink, say) — skips the lookup entirely otherwise.
fn partitionData(info: v2.duckdb_v2_table_function_partition_data_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var needed = false;
    if (v2.duckdb_v2_table_function_partition_data_requires_batch_index(info, &needed, err) != .ERROR_NONE) return;
    if (!needed) return;

    var local_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_partition_data_get_local_state(info, &local_ptr, err) != .ERROR_NONE) return;
    const local: *const LocalState = @ptrCast(@alignCast(local_ptr.?));
    _ = v2.duckdb_v2_table_function_partition_data_set_batch_index(info, local.rg_idx, err);
}

// --- filter pushdown -------------------------------------------------------------------------

fn opOf(t: v2.DUCKDB_V2_EXPRESSION_TYPE) ?ast.Operator {
    return switch (t) {
        .EXPRESSION_TYPE_COMPARE_EQUAL => .Eq,
        .EXPRESSION_TYPE_COMPARE_NOTEQUAL => .NotEq,
        .EXPRESSION_TYPE_COMPARE_LESSTHAN => .Lt,
        .EXPRESSION_TYPE_COMPARE_LESSTHANOREQUALTO => .LtEq,
        .EXPRESSION_TYPE_COMPARE_GREATERTHAN => .Gt,
        .EXPRESSION_TYPE_COMPARE_GREATERTHANOREQUALTO => .GtEq,
        else => null,
    };
}

fn typeOf(e: v2.duckdb_v2_expression_handle, err: Err) ?v2.DUCKDB_V2_EXPRESSION_TYPE {
    var t: v2.DUCKDB_V2_EXPRESSION_TYPE = undefined;
    if (v2.duckdb_v2_expression_get_type(e, &t, err) != .ERROR_NONE) return null;
    return t;
}

/// Recognizes `value <op> BIGINT constant`, the column always on the left (the optimizer rewrites
/// `90 < value` to `value > 90` before this callback ever sees it, per the equivalent cookbook
/// recipe, `table_pushdown.zig`, which this follows closely). Null means "not mine, apply it
/// yourself" — a declined predicate never breaks correctness, only an optimization opportunity.
/// `err` here is a scratch slot (see `pushdown` below): a failed introspection call is also just
/// "not mine," never a query failure.
fn recognize(info: v2.duckdb_v2_table_function_filter_pushdown_info_handle, filter: v2.duckdb_v2_expression_handle, scratch: Err) ?FilterSpec {
    const op = opOf(typeOf(filter, scratch) orelse return null) orelse return null;
    var count: u64 = 0;
    if (v2.duckdb_v2_expression_get_child_count(filter, &count, scratch) != .ERROR_NONE or count != 2) return null;
    var left: v2.duckdb_v2_expression_handle = undefined;
    var right: v2.duckdb_v2_expression_handle = undefined;
    if (v2.duckdb_v2_expression_get_child(filter, 0, &left, scratch) != .ERROR_NONE) return null;
    if (v2.duckdb_v2_expression_get_child(filter, 1, &right, scratch) != .ERROR_NONE) return null;
    if ((typeOf(left, scratch) orelse return null) != .EXPRESSION_TYPE_BOUND_COLUMN_REF) return null;
    if ((typeOf(right, scratch) orelse return null) != .EXPRESSION_TYPE_VALUE_CONSTANT) return null;

    // The index in the expression is among the columns the query reads; this function declares
    // exactly one ("value", index 0), so anything else means the predicate isn't on our column —
    // can't happen in practice (there's nothing else to push a filter onto), but checked anyway
    // rather than assumed.
    var referenced: u64 = 0;
    if (v2.duckdb_v2_expression_column_ref_get_index(left, &referenced, scratch) != .ERROR_NONE) return null;
    var declared: u64 = 0;
    if (v2.duckdb_v2_table_function_filter_pushdown_get_column_index(info, referenced, &declared, scratch) != .ERROR_NONE) return null;
    if (declared != 0) return null;

    var constant: v2.duckdb_v2_value_handle = undefined;
    if (v2.duckdb_v2_expression_constant_get_value(right, &constant, scratch) != .ERROR_NONE) return null;
    defer _ = v2.duckdb_v2_value_destroy(&constant);
    var is_null = false;
    if (v2.duckdb_v2_value_is_null(constant, &is_null, scratch) != .ERROR_NONE or is_null) return null;
    var c: i64 = 0;
    if (v2.duckdb_v2_value_get_bigint(constant, &c, scratch) != .ERROR_NONE) return null;
    return .{ .op = op, .value = c };
}

fn pushdown(info: v2.duckdb_v2_table_function_filter_pushdown_info_handle, context: v2.duckdb_v2_context_handle, err: Err) callconv(.c) void {
    _ = context;
    var bind_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_filter_pushdown_get_bind_data(info, &bind_ptr, err) != .ERROR_NONE) return;
    const bind_data: *BindData = @ptrCast(@alignCast(bind_ptr orelse return));

    var count: u64 = 0;
    if (v2.duckdb_v2_table_function_filter_pushdown_get_filter_count(info, &count, err) != .ERROR_NONE) return;
    for (0..count) |i| {
        if (bind_data.filter_count >= max_pushdown_filters) break;
        var filter: v2.duckdb_v2_expression_handle = undefined;
        if (v2.duckdb_v2_table_function_filter_pushdown_get_filter(info, i, &filter, err) != .ERROR_NONE) return;

        // A failed introspection on one predicate means "not recognized," not "fail the query" —
        // same reasoning as `table_pushdown.zig`'s cookbook recipe: a scratch error slot of its
        // own, discarded, rather than the real `err` the caller cares about.
        var scratch_slot: ?v2.duckdb_v2_error_info_handle = null;
        const scratch: Err = @ptrCast(&scratch_slot);
        defer if (scratch_slot) |*e| {
            _ = v2.duckdb_v2_error_info_destroy(e);
        };
        const spec = recognize(info, filter, scratch) orelse continue;
        bind_data.filters[bind_data.filter_count] = spec;
        bind_data.filter_count += 1;
        // From here on the scan applies it itself: the engine stops.
        if (v2.duckdb_v2_table_function_filter_pushdown_accept(info, i, err) != .ERROR_NONE) return;
    }
}

fn registerReadParquet(input: *const v2.duckdb_v2_extension_input, err: Err) !void {
    var function: v2.duckdb_v2_table_function_handle = undefined;
    if (v2.duckdb_v2_table_function_create(helpers.factory(input.context, err) orelse return error.FailedToGetFactory, &function, err) != .ERROR_NONE) {
        return error.FailedToCreateFunction;
    }
    defer _ = v2.duckdb_v2_table_function_destroy(&function);

    const fn_name = helpers.str("zig_v2_read_parquet");
    if (v2.duckdb_v2_table_function_set_name(function, &fn_name, err) != .ERROR_NONE) {
        return error.FailedToSetName;
    }

    var varchar_type: v2.duckdb_v2_logical_type_handle = undefined;
    if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_VARCHAR, &varchar_type, err) != .ERROR_NONE) {
        return error.FailedToCreateType;
    }
    defer _ = v2.duckdb_v2_logical_type_destroy(&varchar_type);

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_table_function_get_signature(function, &sig, err) != .ERROR_NONE) {
        return error.FailedToGetSignature;
    }
    const path_name = helpers.str("path");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &path_name, varchar_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }
    const column_name = helpers.str("column");
    if (v2.duckdb_v2_function_signature_add_parameter(sig, &column_name, varchar_type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) {
        return error.FailedToAddParameter;
    }

    if (v2.duckdb_v2_table_function_set_bind_callback(function, &bind, err) != .ERROR_NONE) {
        return error.FailedToSetBindCallback;
    }
    if (v2.duckdb_v2_table_function_set_init_global_callback(function, &initGlobal, err) != .ERROR_NONE) {
        return error.FailedToSetInitGlobalCallback;
    }
    if (v2.duckdb_v2_table_function_set_init_local_callback(function, &initLocal, err) != .ERROR_NONE) {
        return error.FailedToSetInitLocalCallback;
    }
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) {
        return error.FailedToSetExecCallback;
    }
    if (v2.duckdb_v2_table_function_set_partition_data_callback(function, &partitionData, err) != .ERROR_NONE) {
        return error.FailedToSetPartitionDataCallback;
    }
    if (v2.duckdb_v2_table_function_set_filter_pushdown_callback(function, &pushdown, err) != .ERROR_NONE) {
        return error.FailedToSetFilterPushdownCallback;
    }

    if (v2.duckdb_v2_extension_register_table_function(input.extension, function, err) != .ERROR_NONE) {
        return error.FailedToRegisterFunction;
    }
}

/// Registers the demo. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    try registerReadParquet(input, err);
}

export fn zig_ext_v2_poc_zpq_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;
    register(input) catch {};
}
