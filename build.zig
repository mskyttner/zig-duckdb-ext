const std = @import("std");
const Translator = @import("translate_c").Translator;

const extension_name = "zig_ext";
const target_duckdb_version = "v1.2.0";
const extension_version = "v0.1.0";
const abi_type = "C_STRUCT";

/// Append DuckDB extension metadata to an already-configured shared
/// library, producing a `.duckdb_extension` file. Factors out the
/// metadata-tool-executable + run-command + four-args + output-arg
/// pattern that was hand-copied for the v1 extension, the real v2
/// extension, and the v2 proof-of-concept — the caller is still
/// responsible for `b.addLibrary(...)` and whatever imports/linkage that
/// particular target needs, since those differ too much per target to be
/// worth forcing into one shared signature.
fn addDuckdbExtensionMetadata(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    name: []const u8,
    duckdb_version: []const u8,
    ext_version: []const u8,
    abi: []const u8,
) std.Build.LazyPath {
    const metadata_tool = b.addExecutable(.{
        .name = b.fmt("append_metadata_{s}", .{name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/append_metadata_main.zig"),
            .target = b.graph.host,
        }),
    });
    const append_cmd = b.addRunArtifact(metadata_tool);
    append_cmd.step.dependOn(&lib.step);
    append_cmd.addArtifactArg(lib);
    append_cmd.addArg(name);
    append_cmd.addArg(duckdb_version);
    append_cmd.addArg(ext_version);
    append_cmd.addArg(abi);
    return append_cmd.addOutputFileArg(b.fmt("{s}.duckdb_extension", .{name}));
}

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

    // Worked examples kept separate from duckdb_v2.zig itself — see that
    // file's own doc comment for why.
    const duckdb_v2_examples_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_v2_examples.zig"),
        .target = target,
        .optimize = optimize,
    });
    duckdb_v2_examples_mod.addImport("duckdb_v2", duckdb_v2_mod);
    const duckdb_v2_examples_check = b.addTest(.{ .root_module = duckdb_v2_examples_mod });
    const run_duckdb_v2_examples_check = b.addRunArtifact(duckdb_v2_examples_check);

    const comptime_scalar_v2_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_scalar_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    comptime_scalar_v2_mod.addImport("duckdb_v2", duckdb_v2_mod);
    const comptime_scalar_v2_check = b.addTest(.{ .root_module = comptime_scalar_v2_mod });
    const run_comptime_scalar_v2_check = b.addRunArtifact(comptime_scalar_v2_check);

    const comptime_table_v2_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_table_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    comptime_table_v2_mod.addImport("duckdb_v2", duckdb_v2_mod);
    const comptime_table_v2_check = b.addTest(.{ .root_module = comptime_table_v2_mod });
    const run_comptime_table_v2_check = b.addRunArtifact(comptime_table_v2_check);

    const comptime_aggregate_v2_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_aggregate_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    comptime_aggregate_v2_mod.addImport("duckdb_v2", duckdb_v2_mod);
    const comptime_aggregate_v2_check = b.addTest(.{ .root_module = comptime_aggregate_v2_mod });
    const run_comptime_aggregate_v2_check = b.addRunArtifact(comptime_aggregate_v2_check);

    const v2_check_step = b.step("v2-check", "Type-check the in-progress duckdb v2 API bindings");
    v2_check_step.dependOn(&run_v2_check.step);
    v2_check_step.dependOn(&run_duckdb_v2_examples_check.step);
    v2_check_step.dependOn(&run_comptime_scalar_v2_check.step);
    v2_check_step.dependOn(&run_comptime_table_v2_check.step);
    v2_check_step.dependOn(&run_comptime_aggregate_v2_check.step);

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
    v2_poc_lib.root_module.addImport("duckdb_v2_examples", duckdb_v2_examples_mod);
    v2_poc_lib.root_module.addImport("comptime_scalar_v2", comptime_scalar_v2_mod);
    v2_poc_lib.root_module.addImport("comptime_table_v2", comptime_table_v2_mod);
    v2_poc_lib.root_module.addImport("comptime_aggregate_v2", comptime_aggregate_v2_mod);
    v2_poc_lib.root_module.link_libc = true;

    const v2_poc_output = addDuckdbExtensionMetadata(b, v2_poc_lib, "zig_ext_v2_poc", "v2.0.0", "v0.0.0-poc", "C_STRUCT");

    // ── Real, parallel v2 extension (zig_ext_v2) — migrated-off-v1
    // functions only (see src/ext/init_v2.zig); v1's real `zig_ext` target
    // below is completely untouched throughout this migration.
    const ext_v2_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig_ext_v2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root_v2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ext_v2_lib.root_module.addImport("duckdb_v2", duckdb_v2_mod);
    ext_v2_lib.root_module.addImport("comptime_scalar_v2", comptime_scalar_v2_mod);
    ext_v2_lib.root_module.addImport("comptime_table_v2", comptime_table_v2_mod);
    ext_v2_lib.root_module.link_libc = true;

    const ext_v2_output = addDuckdbExtensionMetadata(b, ext_v2_lib, "zig_ext_v2", "v2.0.0", "v0.1.0", "C_STRUCT");
    const install_ext_v2 = b.addInstallFile(ext_v2_output, "lib/zig_ext_v2.duckdb_extension");

    const ext_v2_step = b.step("ext-v2", "Build the real, parallel v2 .duckdb_extension file");
    ext_v2_step.dependOn(&install_ext_v2.step);

    // ── Interactive session with the real v2 extension pre-loaded ────────
    // Idea borrowed from habedi/template-duckdb-extension-zig (a build step
    // that drops into a REPL with the extension pre-loaded, instead of
    // retyping `duckdb -unsigned -c "LOAD '...'; ..."` by hand every time —
    // this branch did that dozens of times). Zig 0.17 split configure-time
    // from make-time (the "Configurer"/"Maker" separation), so there's no
    // `b.getInstallPath`-style string available at the point this function
    // runs — `-cmd` (run a command, then drop into the REPL rather than
    // exiting like `-c` does) plus `addFileArg2`'s prefix/suffix resolve the
    // extension's path lazily, as part of running the step, not before.
    {
        const run_duckdb_v2 = b.addSystemCommand(&.{ "duckdb", "-unsigned", "-cmd" });
        // '/home/markus/repos/zig-duckdb-ext/zig-out/lib/zig_ext_v2.duckdb_extension'
        // from duckdb_functions() where extension_name like '%v2%';
        run_duckdb_v2.addFileArg2(ext_v2_output, .{ .prefix = "LOAD '", .suffix = "'; select tp_bar(0.1); from duckdb_functions() select function_name, function_type, parameter_types, examples, comment where extension_name like '%v2%'; "});
        run_duckdb_v2.stdio = .inherit;

        const duckdb_v2_step = b.step("duckdb-extension", "Start an interactive DuckDB session with the real v2 extension loaded");
        duckdb_v2_step.dependOn(&run_duckdb_v2.step);
    }
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

    // ── Post-build step: append metadata to produce .duckdb_extension ────
    const ext_output = addDuckdbExtensionMetadata(b, lib, extension_name, target_duckdb_version, extension_version, abi_type);

    // Install the .duckdb_extension file into zig-out/lib/
    const install_ext = b.addInstallFile(ext_output, "lib/" ++ extension_name ++ ".duckdb_extension");
    b.getInstallStep().dependOn(&install_ext.step);

    // ── "ext" step: just build the .duckdb_extension ─────────────────────
    const ext_step = b.step("ext", "Build the .duckdb_extension file with metadata");
    ext_step.dependOn(&install_ext.step);

    // ── Interactive session with the real v1 extension pre-loaded ────────
    // See the v2 step above for why this uses -cmd + addFileArg2's
    // prefix/suffix rather than a WriteFiles-generated init script.
    {
        const run_duckdb = b.addSystemCommand(&.{ "duckdb", "-unsigned", "-cmd" });
        run_duckdb.addFileArg2(ext_output, .{ .prefix = "LOAD '", .suffix = "';" });
        run_duckdb.stdio = .inherit;

        const duckdb_step = b.step("duckdb-extension-v1", "Start an interactive DuckDB session with the real v1 extension loaded");
        duckdb_step.dependOn(&run_duckdb.step);
    }

    // ── API docs (Zig's built-in autodoc) ─────────────────────────────────
    // Pattern borrowed from habedi/template-duckdb-extension-zig: reuse the
    // existing compile step's emitted docs rather than shelling out to a
    // separate `zig build-lib` invocation, so the real module graph
    // (duckdb_c / duckdb_v2 imports etc.) is picked up automatically.
    {
        const install_docs = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .{ .custom = "docs" },
            .install_subdir = "",
        });
        const docs_step = b.step("docs", "Generate API documentation for the v1 extension");
        docs_step.dependOn(&install_docs.step);
    }
    {
        const install_docs_v2 = b.addInstallDirectory(.{
            .source_dir = ext_v2_lib.getEmittedDocs(),
            .install_dir = .{ .custom = "docs-v2" },
            .install_subdir = "",
        });
        const docs_v2_step = b.step("docs-v2", "Generate API documentation for the v2 extension");
        docs_v2_step.dependOn(&install_docs_v2.step);
    }

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

    // ── SQL logic tests against the real v1 extension ─────────────────────
    // Pattern borrowed from quack-zig: DuckDB's own native .test format
    // (require/statement/query blocks), run via duckdb-sqllogictest-python
    // against a matching `duckdb` Python package, instead of the manual
    // `duckdb -c "..." | diff` comparisons this whole branch did by hand.
    //
    // allow_extensions_metadata_mismatch is required: this project's
    // append_metadata_main.zig emits a plain "linux_amd64" platform tag,
    // while the pip-distributed duckdb package expects the stricter
    // "linux_amd64_gcc4" variant — an orthogonal axis from code-signing,
    // confirmed by testing (a mismatch here has nothing to do with
    // -unsigned/signature checks, which still apply separately).
    //
    // v2 has no equivalent step yet: there is no v2-capable `duckdb`
    // PyPI package to pass to `--with duckdb==X` (v2.0 is a staged alpha,
    // not released), and the v1-era Python package that does exist looks
    // for the old `<name>_init_c_api` symbol, not `_init_c_api_v2` —
    // confirmed by testing directly, not assumed. See
    // test/sql/zig_ext_v2.test (kept, unused) and
    // docs/v2-migration-plan.md for the full finding.
    {
        const sqllogictest_cmd = b.addSystemCommand(&.{
            "uv",                    "run",
            "--with",                "duckdb-sqllogictest @ https://github.com/duckdb/duckdb-sqllogictest-python/archive/be27216.zip",
            "--with",                "duckdb==" ++ target_duckdb_version[1..],
            "python3",               "-m",
            "duckdb_sqllogictest",   "--test-dir",
            "test",                  "--file-path",
            "test/sql/zig_ext.test", "--external-extension",
        });
        sqllogictest_cmd.addFileArg(ext_output);
        sqllogictest_cmd.step.dependOn(&install_ext.step);

        const sqllogictest_step = b.step("sqllogictest", "Run SQL logic tests against the real v1 extension");
        sqllogictest_step.dependOn(&sqllogictest_cmd.step);
    }
}
