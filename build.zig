const std = @import("std");
const Translator = @import("translate_c").Translator;

const extension_name = "zig_ext";
const target_duckdb_version = "v1.2.0";
const extension_version = "v0.1.0";
const abi_type = "C_STRUCT";

/// Map a resolved target to the platform string DuckDB's extension
/// metadata expects (`linux_amd64`, `osx_arm64`, ...). Used both for the
/// default/host build and for each target in the `cross` step, since the
/// metadata-appender tool always runs on the build host (it has to produce
/// its output immediately) and so can't self-detect this for a
/// cross-compiled library the way it used to.
fn duckdbPlatformString(resolved_target: std.Build.ResolvedTarget) []const u8 {
    const os = resolved_target.result.os.tag;
    const arch = resolved_target.result.cpu.arch;
    if (os == .macos) {
        if (arch == .aarch64) return "osx_arm64";
        if (arch == .x86_64) return "osx_amd64";
    }
    if (os == .linux) {
        if (arch == .aarch64) return "linux_arm64";
        if (arch == .x86_64) return "linux_amd64";
    }
    if (os == .windows) {
        if (arch == .x86_64) return "windows_amd64";
        if (arch == .aarch64) return "windows_arm64";
    }
    return "unknown";
}

/// Resolve a build-host-matched, content-hash-pinned DuckDB v2.0 alpha CLI
/// binary via the lazy dependencies in `build.zig.zon`, or `null` if the
/// host platform isn't one DuckDB publishes a CLI for at that staged URL
/// (confirmed live, 2026-10-12: only linux_amd64/linux_arm64 exist there —
/// macOS and Windows both 404). Callers fall back to a bare `"duckdb"`
/// lookup on `PATH` when this returns `null`, so a host this can't resolve
/// for isn't a hard build failure, just a missed convenience — same
/// posture a developer manually installing the alpha CLI today already has
/// to live with for those platforms.
fn duckdbV2CliLazyPath(b: *std.Build) ?std.Build.LazyPath {
    const host_platform = duckdbPlatformString(b.graph.host);
    const dep_name = if (std.mem.eql(u8, host_platform, "linux_amd64"))
        "duckdb_cli_v2_linux_amd64"
    else if (std.mem.eql(u8, host_platform, "linux_arm64"))
        "duckdb_cli_v2_linux_arm64"
    else
        return null;
    const dep = b.lazyDependency(dep_name, .{}) orelse return null;
    return dep.path("duckdb");
}

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
    platform: []const u8,
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
    append_cmd.addArg(platform);
    return append_cmd.addOutputFileArg(b.fmt("{s}.duckdb_extension", .{name}));
}

/// Cross-compile targets for the `cross` step, beyond whatever
/// `-Dtarget=`/the host default already covers via the regular `ext`
/// step. Scoped per `docs/v2-migration-plan.md`'s "Version × platform
/// build matrix" notes: get these building before trying anything
/// bigger (a DuckDB-version matrix, ARM Windows, etc).
const cross_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

/// Cross-compile the real v1 extension for one target, fully
/// self-contained (its own header translation, its own library, its own
/// metadata step) rather than threading a target parameter through the
/// host-build code above — the host build's `duckdb_c`/`lib` are also used
/// for the docs/v2-check/etc steps, which only make sense for the host
/// target, so keeping this separate avoids forcing all of that to become
/// target-parameterized too for a single cross-build use.
fn addCrossBuild(
    b: *std.Build,
    translate_c_dep: *std.Build.Dependency,
    duckdb_headers_v1_dep: *std.Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    query: std.Target.Query,
) std.Build.LazyPath {
    const resolved_target = b.resolveTargetQuery(query);
    const platform = duckdbPlatformString(resolved_target);

    const duckdb_c: Translator = .init(translate_c_dep, .{
        .name = b.fmt("duckdb_c_{s}", .{platform}),
        .c_source_file = duckdb_headers_v1_dep.path("duckdb_extension.h"),
        .target = resolved_target,
        .optimize = optimize,
        .extra_args = &.{"-DDUCKDB_API_EXCLUDE_FUNCTIONS=1"},
    });
    duckdb_c.addIncludePath(duckdb_headers_v1_dep.path("."));

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = b.fmt("{s}_{s}", .{ extension_name, platform }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("duckdb_c", duckdb_c.mod);
    lib.root_module.link_libc = true;

    // Note: `name` here (unlike the other 3 args) is used only to name
    // build artifacts — the metadata-appender tool's own executable and
    // the output file — never written into the extension's metadata
    // itself (confirmed: append_metadata_main.zig reads but never uses
    // its `ext_name` argument), so varying it per platform here is purely
    // to keep each cross target's build artifacts distinct and legible,
    // not a change to what DuckDB sees when it loads the extension.
    const unique_name = b.fmt("{s}_{s}", .{ extension_name, platform });
    return addDuckdbExtensionMetadata(b, lib, unique_name, target_duckdb_version, extension_version, abi_type, platform);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const duckdb_cli_v2 = duckdbV2CliLazyPath(b);

    // ── Translate the vendored DuckDB C API headers ───────────────────────
    // `@cImport` was removed in Zig 0.17.0 in favor of this explicit
    // build-time step (see src/lib/duckdb.zig's own doc comment for why
    // Zig can't evaluate the C side's preprocessor macros directly
    // either way — that part is unchanged). `duckdb_extension.h` already
    // `#include`s `duckdb.h` itself, so translating just the one file
    // pulls in everything `src/lib/duckdb.zig` needs.
    const translate_c_dep = b.dependency("translate_c", .{});
    // Version-pinned, content-hashed header sources (see build.zig.zon's
    // own comments on each): v1.5.6's real tagged release for v1, the
    // exact alpha commit the staged v2 CLI itself reports for v2 — not
    // the plain, no-provenance committed files this project used to vendor.
    const duckdb_headers_v1_dep = b.dependency("duckdb_headers_v1", .{});
    const duckdb_headers_v2_dep = b.dependency("duckdb_headers_v2", .{});
    const duckdb_c: Translator = .init(translate_c_dep, .{
        .name = "duckdb_c",
        .c_source_file = duckdb_headers_v1_dep.path("duckdb_extension.h"),
        .target = target,
        .optimize = optimize,
        // Extensions call through the function-pointer vtable, not linked
        // symbols — this stops the header from declaring direct function
        // prototypes that would otherwise require linking against duckdb
        // itself. Same define the old @cImport block used.
        .extra_args = &.{"-DDUCKDB_API_EXCLUDE_FUNCTIONS=1"},
    });
    duckdb_c.addIncludePath(duckdb_headers_v1_dep.path("."));

    // ── v2 API translation (in-progress rewrite, not yet wired into the
    // extension build — see src/lib/duckdb_v2.zig) ───────────────────────
    const duckdb_c_v2: Translator = .init(translate_c_dep, .{
        .name = "duckdb_c_v2",
        .c_source_file = duckdb_headers_v2_dep.path("duckdb_extension_v2.h"),
        .target = target,
        .optimize = optimize,
    });
    duckdb_c_v2.addIncludePath(duckdb_headers_v2_dep.path("."));

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

    const comptime_appender_v2_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_appender_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    comptime_appender_v2_mod.addImport("duckdb_v2", duckdb_v2_mod);
    const comptime_appender_v2_check = b.addTest(.{ .root_module = comptime_appender_v2_mod });
    const run_comptime_appender_v2_check = b.addRunArtifact(comptime_appender_v2_check);

    const comptime_cast_v2_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_cast_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    comptime_cast_v2_mod.addImport("duckdb_v2", duckdb_v2_mod);
    const comptime_cast_v2_check = b.addTest(.{ .root_module = comptime_cast_v2_mod });
    const run_comptime_cast_v2_check = b.addRunArtifact(comptime_cast_v2_check);

    const v2_check_step = b.step("v2-check", "Type-check the in-progress duckdb v2 API bindings");
    v2_check_step.dependOn(&run_v2_check.step);
    v2_check_step.dependOn(&run_duckdb_v2_examples_check.step);
    v2_check_step.dependOn(&run_comptime_scalar_v2_check.step);
    v2_check_step.dependOn(&run_comptime_table_v2_check.step);
    v2_check_step.dependOn(&run_comptime_aggregate_v2_check.step);
    v2_check_step.dependOn(&run_comptime_appender_v2_check.step);
    v2_check_step.dependOn(&run_comptime_cast_v2_check.step);

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
    v2_poc_lib.root_module.addImport("comptime_appender_v2", comptime_appender_v2_mod);
    v2_poc_lib.root_module.addImport("comptime_cast_v2", comptime_cast_v2_mod);
    v2_poc_lib.root_module.link_libc = true;

    const v2_poc_output = addDuckdbExtensionMetadata(b, v2_poc_lib, "zig_ext_v2_poc", "v2.0.0", "v0.0.0-poc", "C_STRUCT", duckdbPlatformString(target));

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

    const ext_v2_output = addDuckdbExtensionMetadata(b, ext_v2_lib, "zig_ext_v2", "v2.0.0", "v0.1.0", "C_STRUCT", duckdbPlatformString(target));
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
        // Uses the pinned v2 alpha CLI resolved above when the host
        // platform has one published (see `duckdbV2CliLazyPath`); falls
        // back to a bare `duckdb` lookup on `PATH` otherwise (macOS/
        // Windows hosts today, or a fetch failure) — same as before this
        // was added.
        const run_duckdb_v2 = if (duckdb_cli_v2) |cli| blk: {
            const r = std.Build.Step.Run.create(b, "run duckdb (v2, pinned)");
            r.addFileArg(cli);
            break :blk r;
        } else b.addSystemCommand(&.{"duckdb"});
        run_duckdb_v2.addArgs(&.{ "-unsigned", "-no-init", "-cmd" });
        // '/home/markus/repos/zig-duckdb-ext/zig-out/lib/zig_ext_v2.duckdb_extension'
        // from duckdb_functions() where extension_name like '%v2%';
        run_duckdb_v2.addFileArg2(ext_v2_output, .{ .prefix = "LOAD '", .suffix = "'; select tp_bar(0.1); from duckdb_functions() select function_name, function_type, parameter_types, examples, comment where extension_name like '%v2%'; " });
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
    const ext_output = addDuckdbExtensionMetadata(b, lib, extension_name, target_duckdb_version, extension_version, abi_type, duckdbPlatformString(target));

    // Install the .duckdb_extension file into zig-out/lib/
    const install_ext = b.addInstallFile(ext_output, "lib/" ++ extension_name ++ ".duckdb_extension");
    b.getInstallStep().dependOn(&install_ext.step);

    // ── "ext" step: just build the .duckdb_extension ─────────────────────
    const ext_step = b.step("ext", "Build the .duckdb_extension file with metadata");
    ext_step.dependOn(&install_ext.step);

    // ── "cross" step: build the real v1 extension for every target in
    // `cross_targets`, each installed under zig-out/lib/<platform>/ ──────
    const cross_step = b.step("cross", "Cross-compile the real v1 extension for every target in cross_targets");
    for (cross_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const platform = duckdbPlatformString(resolved);
        const output = addCrossBuild(b, translate_c_dep, duckdb_headers_v1_dep, optimize, query);
        const install_cross = b.addInstallFile(output, b.fmt("lib/{s}/" ++ extension_name ++ ".duckdb_extension", .{platform}));
        cross_step.dependOn(&install_cross.step);
    }

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

    // ── SQL logic tests against the real v1 AND v2 extensions ─────────────
    // DuckDB's own native .test format (require/statement/query blocks),
    // run via a small native Zig runner (src/sqllogictest_main.zig) that
    // drives the `duckdb` CLI directly — instead of the manual
    // `duckdb -c "..." | diff` comparisons this whole branch did by hand
    // at first, and instead of the `uv run --with duckdb-sqllogictest-python
    // ...` dependency this step used before that.
    //
    // The Python-based approach had a real, permanent limitation this one
    // doesn't: there is no v2-capable `duckdb` PyPI package to pass to
    // `--with duckdb==X` (v2.0 is a staged alpha, not released), and the
    // v1-era Python package that does exist looks for the old
    // `<name>_init_c_api` symbol, not `_init_c_api_v2` — confirmed by
    // testing directly. Driving the CLI directly doesn't care what Python
    // package versions exist, so `sqllogictest-v2` below works today,
    // closing a gap `docs/v2-migration-plan.md` had recorded as blocked.
    const sqllogictest_tool = b.addExecutable(.{
        .name = "sqllogictest_main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqllogictest_main.zig"),
            .target = b.graph.host,
        }),
    });
    {
        const run = b.addRunArtifact(sqllogictest_tool);
        run.addArg("duckdb");
        run.addFileArg(ext_output);
        run.addFileArg(b.path("test/sql/zig_ext.test"));
        run.step.dependOn(&install_ext.step);

        const sqllogictest_step = b.step("sqllogictest", "Run SQL logic tests against the real v1 extension");
        sqllogictest_step.dependOn(&run.step);
    }
    {
        const run = b.addRunArtifact(sqllogictest_tool);
        // Pinned v2 alpha CLI when available for this host (see
        // `duckdbV2CliLazyPath`), falling back to a bare `duckdb` on
        // `PATH` otherwise — same as before this was added.
        if (duckdb_cli_v2) |cli| run.addFileArg(cli) else run.addArg("duckdb");
        run.addFileArg(ext_v2_output);
        run.addFileArg(b.path("test/sql/zig_ext_v2.test"));
        run.step.dependOn(&install_ext_v2.step);

        const sqllogictest_v2_step = b.step("sqllogictest-v2", "Run SQL logic tests against the real v2 extension");
        sqllogictest_v2_step.dependOn(&run.step);
    }
}
