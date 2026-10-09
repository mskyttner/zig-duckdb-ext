const std = @import("std");
const Translator = @import("translate_c").Translator;

const extension_name = "zig_ext";
const target_duckdb_version = "v1.2.0";
const extension_version = "v0.1.0";
const abi_type = "C_STRUCT";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Translate the vendored DuckDB C API headers ───────────────────────
    // `@cImport` was removed in Zig 0.17.0 in favor of this explicit
    // build-time step (see src/lib/duckdb.zig's own doc comment for why
    // Zig can't evaluate the C side's preprocessor macros directly
    // either way — that part is unchanged). `duckdb_extension.h` already
    // `#include`s `duckdb.h` itself, so translating just the one file
    // pulls in everything `src/lib/duckdb.zig` needs.
    const translate_c_dep = b.dependency("translate_c", .{});
    const duckdb_c: Translator = .init(translate_c_dep, .{
        .name = "duckdb_c",
        .c_source_file = b.path("duckdb_capi/duckdb_extension.h"),
        .target = target,
        .optimize = optimize,
        // Extensions call through the function-pointer vtable, not linked
        // symbols — this stops the header from declaring direct function
        // prototypes that would otherwise require linking against duckdb
        // itself. Same define the old @cImport block used.
        .extra_args = &.{"-DDUCKDB_API_EXCLUDE_FUNCTIONS=1"},
    });
    duckdb_c.addIncludePath(b.path("duckdb_capi"));

    // ── v2 API translation (in-progress rewrite, not yet wired into the
    // extension build — see src/lib/duckdb_v2.zig) ───────────────────────
    const duckdb_c_v2: Translator = .init(translate_c_dep, .{
        .name = "duckdb_c_v2",
        .c_source_file = b.path("duckdb_capi/duckdb_extension_v2.h"),
        .target = target,
        .optimize = optimize,
    });
    duckdb_c_v2.addIncludePath(b.path("duckdb_capi"));

    const duckdb_v2_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    duckdb_v2_mod.addImport("duckdb_c_v2", duckdb_c_v2.mod);

    const v2_check = b.addTest(.{ .root_module = duckdb_v2_mod });
    const run_v2_check = b.addRunArtifact(v2_check);
    const v2_check_step = b.step("v2-check", "Type-check the in-progress duckdb v2 API bindings");
    v2_check_step.dependOn(&run_v2_check.step);

    // ── v2 proof-of-concept extension (real runtime test, not the real
    // extension) — registers one scalar function against a live DuckDB
    // v2.0 alpha, proving duckdb_v2.zig's bindings beyond type-checking.
    const v2_poc_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig_ext_v2_poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ext/init_v2_poc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    v2_poc_lib.root_module.addImport("duckdb_v2", duckdb_v2_mod);
    v2_poc_lib.root_module.link_libc = true;

    const metadata_tool_v2_poc = b.addExecutable(.{
        .name = "append_metadata_v2_poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/append_metadata_main.zig"),
            .target = b.graph.host,
        }),
    });
    const v2_poc_append = b.addRunArtifact(metadata_tool_v2_poc);
    v2_poc_append.step.dependOn(&v2_poc_lib.step);
    v2_poc_append.addArtifactArg(v2_poc_lib);
    v2_poc_append.addArg("zig_ext_v2_poc");
    v2_poc_append.addArg("v2.0.0");
    v2_poc_append.addArg("v0.0.0-poc");
    v2_poc_append.addArg("C_STRUCT");
    const v2_poc_output = v2_poc_append.addOutputFileArg("zig_ext_v2_poc.duckdb_extension");
    const install_v2_poc = b.addInstallFile(v2_poc_output, "lib/zig_ext_v2_poc.duckdb_extension");

    const v2_poc_step = b.step("v2-poc", "Build the v2 proof-of-concept .duckdb_extension file");
    v2_poc_step.dependOn(&install_v2_poc.step);

    // ── Shared library (the DuckDB extension) ────────────────────────────
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = extension_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("duckdb_c", duckdb_c.mod);
    lib.root_module.link_libc = true;

    b.installArtifact(lib);

    // ── Metadata appender tool ──────────────────────────────────────────
    const metadata_tool = b.addExecutable(.{
        .name = "append_metadata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/append_metadata_main.zig"),
            .target = b.graph.host,
        }),
    });

    // ── Post-build step: append metadata to produce .duckdb_extension ────
    const append_cmd = b.addRunArtifact(metadata_tool);
    append_cmd.step.dependOn(&lib.step);

    // Pass the library output path and extension metadata as arguments
    append_cmd.addArtifactArg(lib);
    append_cmd.addArg(extension_name);
    append_cmd.addArg(target_duckdb_version);
    append_cmd.addArg(extension_version);
    append_cmd.addArg(abi_type);
    // The tool writes the output to a known location
    const ext_output = append_cmd.addOutputFileArg(extension_name ++ ".duckdb_extension");

    // Install the .duckdb_extension file into zig-out/lib/
    const install_ext = b.addInstallFile(ext_output, "lib/" ++ extension_name ++ ".duckdb_extension");
    b.getInstallStep().dependOn(&install_ext.step);

    // ── "ext" step: just build the .duckdb_extension ─────────────────────
    const ext_step = b.step("ext", "Build the .duckdb_extension file with metadata");
    ext_step.dependOn(&append_cmd.step);

    // ── Unit tests ───────────────────────────────────────────────────────
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_unit_tests.root_module.addImport("duckdb_c", duckdb_c.mod);
    lib_unit_tests.root_module.link_libc = true;

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
