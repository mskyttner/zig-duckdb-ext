///! Entry point of the dynamic-bindings PoC extension: the generated `get_api` backend
///! (`duckdb_v2_dynamic.zig`) loaded by the real DuckDB. It registers `gen_hello()`, the same
///! source `v2-static-embed-poc-gen` links statically. See `zig build v2-gen-poc`.
const v2 = @import("duckdb_v2_dynamic");
const gen_hello = @import("gen_hello");

/// DuckDB calls this symbol (`<extension name>_init_c_api_v2`) when the extension is loaded.
export fn zig_ext_v2_gen_poc_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    // Nothing else in the API may be called before this succeeds, and on failure the error slot
    // is left alone: DuckDB has already recorded why `get_api` refused.
    if (!v2.init(input, v2.api_version)) return;
    gen_hello.register(input.extension, input.context, input.err);
}
