///! A separate v2-ABI wasm32-emscripten SIDE_MODULE carrying only `zig_v2_read_matrix_opfs`,
///! built and stamped for the `wasm_threads` platform — but its own root module does NOT set
///! `.single_threaded = false`, unlike `init_v2_poc_matmul_wasm_threads.zig`'s. This tests the
///! "loading step split from computing step" idea from docs/rationale/0008's OPFS entry: can
///! `zarrow`'s record-batch decoder (whose zstd-decompression path needs `single_threaded =
///! true` somewhere in its compile unit — see that file's own entry on why) live in the SAME
///! `wasm_threads` *engine connection* as the real threaded matmul kernel, just as a SEPARATE
///! wasm module loaded alongside it, rather than linked into the same binary?
///!
///! The footer's `platform` field (what the engine's loader actually checks — confirmed live,
///! not assumed, earlier in this investigation) is stamped by this build step's own argument,
///! independent of whatever `single_threaded` setting this module's compile used — the atomics/
///! exception-handling/simd128 *target CPU features* match the connecting `wasm_threads`
///! engine either way. So in principle this module can present itself as `wasm_threads`-
///! compatible while never itself spawning a thread, and never tripping the `WasmAllocator`
///! wall. If that holds, the two-stage pipeline is: `LOAD` this extension and the matmul one
///! into one connection, materialize `zig_v2_read_matrix_opfs(...)` into a real table once per
///! matrix, then feed `zig_v2_matmul_parallel_ct` a `LIST(value ORDER BY row_index)`
///! aggregate over that table instead of a giant SQL literal — DuckDB's own native LIST
///! aggregation over already-decoded column values, not the SQL parser's LIST-literal path
///! this whole investigation found costing ~1.1s at 131,072 elements.
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");
const read_matrix_opfs_v2 = @import("read_matrix_opfs_v2");

export fn zig_ext_v2_poc_read_matrix_opfs_wasm_threads_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return;
    read_matrix_opfs_v2.register(input) catch {};
}
