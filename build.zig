const std = @import("std");

const extension_name = "zig_ext";
const target_duckdb_version = "v1.2.0";
const extension_version = "v0.1.0";
const abi_type = "C_STRUCT";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // Add the vendored DuckDB C API headers
    lib.root_module.addIncludePath(b.path("duckdb_capi"));
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
    lib_unit_tests.root_module.addIncludePath(b.path("duckdb_capi"));
    lib_unit_tests.root_module.link_libc = true;

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
