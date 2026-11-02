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
///! repeated; whole file read into memory; single-threaded scan; no filter pushdown, no row_gate.
///! OPTIONAL support isn't a nice-to-have — DuckDB's own `COPY ... TO PARQUET` emits columns as
///! OPTIONAL by default (confirmed live: a REQUIRED-only first cut rejected every file DuckDB
///! itself writes). Extending beyond max_def <= 1 (nested/repeated) is follow-up work.
///!
///! Tuned to parity with DuckDB's own single-threaded native `read_parquet` on a 10M-row column
///! (confirmed live, both at 0.06s): decode straight into the output vector's own buffer instead
///! of through a stack copy, reset the per-scan arena after each row group instead of letting
///! zpq's scratch allocations accumulate across all of them, and vectorize the validity-bit
///! writer (`writeValidityBits` below: one `@reduce(.Or, ...)` per 64-row word instead of 64
///! scalar read-modify-writes) — see git history for the step-by-step benchmark progression.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const zpq = @import("zpq");

const schema = zpq.core.schema;
const metadata = zpq.core.parquet.metadata;
const column = zpq.core.parquet.column;

const Err = *v2.duckdb_v2_error_info_handle;

fn fail(err: Err, code: v2.DUCKDB_V2_ERROR, comptime fmt: []const u8, args: anytype) void {
    var buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    _ = v2.duckdb_v2_error_info_set_code(err.*, code);
    _ = helpers.setErrorText(err.*, msg);
}

const max_file_bytes = 1 << 30; // 1 GiB — PoC guardrail, not a real limit.
const max_rows_per_batch = 2048;

const BindData = struct {
    file_bytes: []u8,
    meta: schema.FileMetaData,
    col_idx: usize,
    max_def: i32,
};

fn destroyBindData(ptr: *anyopaque) callconv(.c) void {
    const data: *BindData = @ptrCast(@alignCast(ptr));
    data.meta.deinit(std.heap.c_allocator);
    std.heap.c_allocator.free(data.file_bytes);
    std.heap.c_allocator.destroy(data);
}

const GlobalState = struct {
    arena: std.heap.ArenaAllocator,
    rg_idx: usize,
    reader: ?column.ColumnChunkReader(i64),
    done: bool,
};

fn destroyGlobalState(ptr: *anyopaque) callconv(.c) void {
    const state: *GlobalState = @ptrCast(@alignCast(ptr));
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
    const state = std.heap.c_allocator.create(GlobalState) catch return;
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .rg_idx = 0,
        .reader = null,
        .done = false,
    };
    var boxed: v2.duckdb_v2_opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
    _ = v2.duckdb_v2_table_function_init_global_set_global_state(info, &boxed, err);
}

/// Opens the next row group's column chunk reader into `state.reader`, or
/// sets `state.done` once row groups are exhausted or a chunk's byte range
/// doesn't fit the file (the bounds check `metadata.checkFooterFields`
/// explicitly leaves to its caller — see this PoC's scoping notes).
///
/// Resets the arena first: the previous row group's `ColumnChunkReader`
/// (its scratch allocations, dictionary pages, etc.) is always gone by the
/// time this runs — callers null `state.reader` before calling — so
/// nothing here still needs that memory. Without this, scratch from every
/// row group in the file accumulates for the whole scan instead of just
/// the one currently being decoded.
fn openNextRowGroup(state: *GlobalState, bind_data: *const BindData) void {
    _ = state.arena.reset(.free_all);
    while (state.rg_idx < bind_data.meta.row_groups.items.len) {
        const rg = &bind_data.meta.row_groups.items[state.rg_idx];
        state.rg_idx += 1;
        const chunk = &rg.columns.items[bind_data.col_idx];
        const col_meta = chunk.meta_data orelse continue;
        const start = col_meta.dictionary_page_offset orelse col_meta.data_page_offset;
        if (start < 0 or col_meta.total_compressed_size < 0) continue;
        const start_u: u64 = @intCast(start);
        const length: u64 = @intCast(col_meta.total_compressed_size);
        if (length > bind_data.file_bytes.len or start_u > bind_data.file_bytes.len - length) continue;
        const chunk_bytes = bind_data.file_bytes[start_u .. start_u + length];
        state.reader = column.ColumnChunkReader(i64).init(
            chunk_bytes,
            col_meta.codec,
            .{ .max_def = bind_data.max_def, .max_rep = 0 },
            state.arena.allocator(),
        );
        return;
    }
    state.done = true;
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

    var state_ptr: ?*anyopaque = null;
    if (v2.duckdb_v2_table_function_exec_get_global_state(info, &state_ptr, err) != .ERROR_NONE) return;
    const state: *GlobalState = @ptrCast(@alignCast(state_ptr.?));

    if (state.reader == null and !state.done) openNextRowGroup(state, bind_data);

    while (state.reader != null) {
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
            state.reader.?.decode(dest)
        else
            state.reader.?.decodeWithLevels(dest, &def_levels);
        const row_count = n catch {
            state.reader = null;
            state.done = true;
            break;
        };
        if (row_count == 0) {
            state.reader = null;
            openNextRowGroup(state, bind_data);
            continue;
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
    if (v2.duckdb_v2_table_function_set_exec_callback(function, &exec, err) != .ERROR_NONE) {
        return error.FailedToSetExecCallback;
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
