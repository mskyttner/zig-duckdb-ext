const std = @import("std");
const Translator = @import("translate_c").Translator;

// Defaults for the v1 extension's own identity — overridable via
// `-Dname=`/`-Dapi-version=`/`-Dextension-version=`/`-Dplatform=` (see
// `build()`), the same four build-time settings
// habedi/template-duckdb-extension-zig exposes, under the names this
// project already used internally before they became configurable. Not
// applied to the separate, experimental v2/v2-poc builds (their own
// identity stays hardcoded — this project's v1→v2 migration exploration,
// not the general-purpose template surface these options are for).
const default_extension_name = "zig_ext";
const default_target_duckdb_version = "v1.2.0";
const default_extension_version = "v0.1.0";
const abi_type = "C_STRUCT";

/// The DuckDB version the v2 extensions are built for. The v2 API is only guaranteed for this exact version, so the
/// footer says `C_STRUCT_UNSTABLE` with it: DuckDB then refuses to load the file in any other version, with a message.
/// (With `C_STRUCT` and "v2.0.0" a build for one alpha loaded in another one and crashed it.) Move it with the pin in
/// build.zig.zon.
const v2_duckdb_version = "v2.0.0";
const v2_abi_type = "C_STRUCT_UNSTABLE";

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
        const is_musl = resolved_target.result.abi.isMusl();
        if (arch == .aarch64) return if (is_musl) "linux_arm64_musl" else "linux_arm64";
        if (arch == .x86_64) return if (is_musl) "linux_amd64_musl" else "linux_amd64";
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

/// Escape a string for embedding as a single-quoted SQL string literal
/// (doubles any embedded single quotes). Used for `-D`-supplied values
/// substituted into a `-c` command string handed to the DuckDB CLI.
fn sqlQuoteLiteral(b: *std.Build, s: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, b.allocator, s, "'", "''") catch @panic("OOM");
}

/// Resolves a GCC-toolchain file (e.g. `libstdc++.a`) via `g++
/// -print-file-name=<name>` — the same query GCC's own driver uses
/// internally — instead of hardcoding a `/usr/lib/gcc/<triple>/<version>/`
/// path that varies by distro/GCC version. Falls back to `name` itself
/// (unresolved) if `g++` isn't on `PATH` or the query fails; the
/// subsequent `addObjectFile` then fails with Zig's own "file not
/// found" error, pointing at `-Dlibstdcxx-path=`/`-Dlibgcc-eh-path=` as
/// the fix rather than silently resolving to the wrong file.
fn gccFileName(b: *std.Build, compiler: []const u8, name: []const u8) []const u8 {
    const stdout = switch (b.runFallible(&.{ compiler, b.fmt("-print-file-name={s}", .{name}) }, .{ .stderr_behavior = .ignore })) {
        .success => |out| out,
        .spawn_failed, .bad_exit_code, .crashed => return name,
    };
    return std.mem.trim(u8, stdout, " \t\r\n");
}

/// Whether a libstdc++ archive defines the emulated-TLS objects `std::call_once` uses
/// (`__emutls_v._ZSt11__once_call`). DuckDB's MinGW static libraries reference them, so they only
/// link against a libstdc++ built that way (MinGW's posix thread model); one that uses native TLS
/// (e.g. MSYS2's GCC 16) fails to link with `undefined symbol: __emutls_v._ZSt11__once_call`, see
/// duckdb/duckdb-go-bindings#105. Defining the symbols ourselves would not help: its `__once_proxy`
/// would read different variables than the archive's code writes.
fn libstdcxxHasEmulatedOnceCall(b: *std.Build, libstdcxx_path: []const u8) bool {
    return switch (b.runFallible(&.{ "grep", "-q", "-a", "--", "__emutls_v._ZSt11__once_call", libstdcxx_path }, .{ .stderr_behavior = .ignore })) {
        .success => true,
        .spawn_failed => true, // cannot tell; let the linker say
        .bad_exit_code, .crashed => false,
    };
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
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
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
    build_options_mod: *std.Build.Module,
    extension_name: []const u8,
    target_duckdb_version: []const u8,
    extension_version: []const u8,
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
    lib.root_module.addImport("build_options", build_options_mod);
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

/// One of `duckdb-wasm`'s three wasm extension platforms — `mvp` (plain WebAssembly 1.0),
/// `coi` (exceptions + threads, needs a cross-origin-isolated page), and `eh` (exceptions,
/// no threads) sits between them but isn't wired up here, nothing in this project's own
/// code needing it over plain `mvp`. Each maps to the platform string DuckDB's own
/// `extension_build_tools.cmake` writes into the footer (`DUCKDB_EXPLICIT_PLATFORM`), the
/// Zig wasm CPU feature set needed to link against that platform's `wasm-opt`/`emcc`
/// without a feature mismatch, and the extra `emcc` link flags that platform's own CMake
/// passes (`coi`: `-pthread -sSHARED_MEMORY=1`, from that same cmake file's `LINK_FLAGS`).
const WasmVariant = enum {
    mvp,
    coi,

    fn platform(self: WasmVariant) []const u8 {
        return switch (self) {
            .mvp => "wasm_mvp",
            .coi => "wasm_threads",
        };
    }

    /// `mvp`: zero extra features — an older emsdk's bundled `wasm-opt` doesn't recognize
    /// post-MVP feature names like `bulk-memory-opt` (confirmed directly: emsdk 3.1.71,
    /// official duckdb-wasm's own pin, failed with "Unknown option '--enable-bulk-memory-opt'"
    /// when linking a lib built with Zig's default `generic` CPU model instead).
    /// `coi`: Zig's `generic` model (`bulk_memory`, `multivalue`, `mutable_globals`,
    /// `nontrapping_fptoint`, `reference_types`, `sign_ext`) plus `atomics` and `simd128` —
    /// exactly `WITH_WASM_THREADS`/`WITH_WASM_SIMD`/`WITH_WASM_BULK_MEMORY`,
    /// `extension_build_tools.cmake`'s own flags for this platform, no more. Confirmed
    /// directly that more is actively wrong here, not just unneeded: Zig's `bleeding_edge`
    /// model (which this used at first) adds `exception_handling`/`relaxed_simd`/`fp16`/
    /// `gc`/`tail_call`/`multimemory` — features even emsdk 6.0.12's `wasm-opt` doesn't
    /// recognize, let alone duckdb-wasm's own coi-specific, older `3.1.57` pin. A module
    /// built without `atomics` cannot link against a `-sSHARED_MEMORY=1` main module at
    /// all — the two sides' wasm "target features" custom sections have to agree.
    fn resolveTarget(self: WasmVariant, b: *std.Build) std.Build.ResolvedTarget {
        var query: std.Target.Query = .{ .cpu_arch = .wasm32, .os_tag = .emscripten };
        switch (self) {
            .mvp => query.cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
            .coi => {
                query.cpu_model = .{ .explicit = &std.Target.wasm.cpu.generic };
                query.cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .simd128 });
            },
        }
        return b.resolveTargetQuery(query);
    }

    fn emccLinkArgs(self: WasmVariant) []const []const u8 {
        return switch (self) {
            .mvp => &.{},
            .coi => &.{ "-pthread", "-sSHARED_MEMORY=1" },
        };
    }
};

/// Build the real v1 extension as a `wasm32-emscripten` Emscripten
/// `SIDE_MODULE`, loadable by `duckdb-wasm`/`haybarn-wasm` via Emscripten's
/// own `dlopen()`. Mirrors DuckDB's own loadable-extension-for-wasm recipe
/// (`extension/extension_build_tools.cmake` in DuckDB's real source, read
/// directly — see docs/v2-migration-plan.md's WASM section for the full
/// trace): build a *static* Zig library for this target, link it with one
/// real `emcc -sSIDE_MODULE=2` call, then stamp the result with this
/// project's own `append_metadata` tool — the same footer format and tool
/// every native build already uses; no wasm-specific variant needed.
///
/// Verified end to end (2026-10-20): `mvp` loaded via `custom_extension_repository`
/// and `LOAD` into a live `haybarn-wasm`/`duckdb-wasm` engine, in Node and in a real
/// headless browser, `zig_hello`/`zig_add_numbers` both called and returned correct
/// results through a real `dlopen()`. `registerFileBuffer` + direct-path `LOAD` hangs in
/// at least one non-browser binding (a gap in that binding, not in this artifact — see
/// the migration doc) and is not what this step aims at.
///
/// Needs a real `emcc` from an activated `emsdk` on `PATH`, or `-Demcc-path=`
/// pointing at one directly — no Emscripten toolchain is vendored here, the
/// same way DuckDB's own wasm build shells out to a real `emcc` rather than
/// bundling one. A *static* Zig output needs no libc for this target/ABI
/// (confirmed directly); a *dynamic* one does, and Zig ships none for it
/// (`unable to provide libc for target "wasm32-emscripten-musl"`) — which
/// is why this does not reuse `addCrossBuild`'s `.linkage = .dynamic`, and
/// does not set `.link_libc = true` the way every other target here does.
fn addWasmEmscriptenBuild(
    b: *std.Build,
    translate_c_dep: *std.Build.Dependency,
    duckdb_headers_v1_dep: *std.Build.Dependency,
    build_options_mod: *std.Build.Module,
    extension_name: []const u8,
    duckdb_version: []const u8,
    extension_version: []const u8,
    emcc_path: []const u8,
    variant: WasmVariant,
) std.Build.LazyPath {
    const wasm_target = variant.resolveTarget(b);

    // Always `.ReleaseFast`, ignoring whatever `-Doptimize=` the rest of the build was given:
    // confirmed directly that a Debug build is actively broken against at least one real
    // engine, not just slower. Zig's `Allocator.alloc`/`.free` capture `@returnAddress()` at
    // every call site (part of the interface's own leak-attribution convention, not
    // Debug-only), which lowers to Emscripten's `__builtin_return_address` — official
    // duckdb-wasm's own pinned Emscripten (3.1.71) aborts on this without
    // `-sUSE_OFFSET_CONVERTER` (`tp_bar`, which allocates per row, hit this at runtime: "Cannot
    // use convertFrameToPC ... without -sUSE_OFFSET_CONVERTER"); `haybarn-wasm`'s pin (6.0.12)
    // tolerates it. Adding `-sUSE_OFFSET_CONVERTER` to the `emcc` link line was tried and made
    // things worse (`_setThrew is not defined` — a different ABI mismatch). `.ReleaseFast`
    // avoids the capture being reachable at all, matches what a shipped extension should be
    // built as anyway, and is verified working against both engines.
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const duckdb_c: Translator = .init(translate_c_dep, .{
        .name = b.fmt("duckdb_c_{s}", .{variant.platform()}),
        .c_source_file = duckdb_headers_v1_dep.path("duckdb_extension.h"),
        .target = wasm_target,
        .optimize = optimize,
        .extra_args = &.{"-DDUCKDB_API_EXCLUDE_FUNCTIONS=1"},
    });
    duckdb_c.addIncludePath(duckdb_headers_v1_dep.path("."));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = b.fmt("{s}_{s}", .{ extension_name, variant.platform() }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("duckdb_c", duckdb_c.mod);
    lib.root_module.addImport("build_options", build_options_mod);

    // The one real link step: `emcc` takes the static archive and produces the loadable
    // side module, exporting only the real C API entry point DuckDB looks up by name
    // (`<filebase>_init_c_api`) — matching `extension_load.cpp`'s C-ABI load path exactly.
    const emcc_cmd = b.addSystemCommand(&.{emcc_path});
    // `emcc_path` is a bare string, not a tracked `LazyPath`: the build graph has no way to
    // notice the binary it points at changed (e.g. switching -Demcc-path= to a different
    // emsdk install at the same path, as emsdk reuses its "upstream" directory in place),
    // so the Zig cache would otherwise keep serving a stale .wasm linked by a different
    // Emscripten version — confirmed directly: it did, silently, until this was added.
    emcc_cmd.has_side_effects = true;
    emcc_cmd.addArtifactArg(lib);
    emcc_cmd.addArgs(&.{ "-O3", "-g2", "-sSIDE_MODULE=2" });
    emcc_cmd.addArgs(variant.emccLinkArgs());
    emcc_cmd.addArg(b.fmt("-sEXPORTED_FUNCTIONS=_{s}_init_c_api", .{extension_name}));
    emcc_cmd.addArg("-o");
    const wasm_module = emcc_cmd.addOutputFileArg(b.fmt("{s}.wasm", .{extension_name}));

    const metadata_tool = b.addExecutable(.{
        .name = b.fmt("append_metadata_{s}_{s}", .{ extension_name, variant.platform() }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/append_metadata_main.zig"),
            .target = b.graph.host,
        }),
    });
    const append_cmd = b.addRunArtifact(metadata_tool);
    append_cmd.addFileArg(wasm_module);
    append_cmd.addArg(extension_name);
    append_cmd.addArg(duckdb_version);
    append_cmd.addArg(extension_version);
    append_cmd.addArg(abi_type);
    append_cmd.addArg(variant.platform());
    return append_cmd.addOutputFileArg(b.fmt("{s}.duckdb_extension.wasm", .{extension_name}));
}

/// The v2 extensions that are published.
const V2Extension = enum { zig_ext_v2, zig_ext_cookbook };

/// Cross-compile one of the v2 extensions for one target. The v2 bindings are plain Zig (no C header is translated),
/// so, unlike `addCrossBuild`, nothing but the modules has to be made again for the target.
fn addV2CrossBuild(
    b: *std.Build,
    extension: V2Extension,
    duckdb_version: []const u8,
    extension_version: []const u8,
    optimize: std.builtin.OptimizeMode,
    query: std.Target.Query,
) std.Build.LazyPath {
    const resolved_target = b.resolveTargetQuery(query);
    const platform = duckdbPlatformString(resolved_target);

    const types_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_v2_types.zig"),
        .target = resolved_target,
        .optimize = optimize,
    });
    const dynamic_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_v2_dynamic.zig"),
        .target = resolved_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "duckdb_v2_types", .module = types_mod }},
    });
    const graph = v2Graph(b, resolved_target, optimize, dynamic_mod);

    const name = @tagName(extension);
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = b.fmt("{s}_{s}", .{ name, platform }),
        .root_module = b.createModule(.{
            .root_source_file = b.path(switch (extension) {
                .zig_ext_v2 => "src/root_v2.zig",
                .zig_ext_cookbook => "src/root_cookbook.zig",
            }),
            .target = resolved_target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("duckdb_v2_api", dynamic_mod);
    lib.root_module.addImport("v2_helpers", graph.helpers);
    switch (extension) {
        .zig_ext_v2 => {
            lib.root_module.addImport("comptime_scalar_v2", graph.scalar);
            lib.root_module.addImport("comptime_table_v2", graph.table);
        },
        .zig_ext_cookbook => lib.root_module.addImport("arrow", b.createModule(.{
            .root_source_file = b.path("third_party/gld-arrow-zig/src/arrow.zig"),
            .target = resolved_target,
            .optimize = optimize,
        })),
    }
    lib.root_module.link_libc = true;
    // The file name is only for the build artifacts; the metadata footer does not carry it.
    return addDuckdbExtensionMetadata(b, lib, b.fmt("{s}_{s}", .{ name, platform }), duckdb_version, extension_version, v2_abi_type, platform);
}

/// The modules written against `duckdb_v2_api`, instantiated against one backend: `api` is the
/// dynamic or the static generated bindings. Function modules import these by name.
const V2Graph = struct {
    helpers: *std.Build.Module,
    values: *std.Build.Module,
    examples: *std.Build.Module,
    scalar: *std.Build.Module,
    table: *std.Build.Module,
    aggregate: *std.Build.Module,
    appender: *std.Build.Module,
    cast: *std.Build.Module,
};

fn v2Graph(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, api: *std.Build.Module) V2Graph {
    const helpers = b.createModule(.{
        .root_source_file = b.path("src/lib/v2_helpers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "duckdb_v2_api", .module = api }},
    });
    const values = b.createModule(.{
        .root_source_file = b.path("src/lib/v2_values.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "duckdb_v2_api", .module = api }},
    });
    const examples = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_v2_examples.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "duckdb_v2_api", .module = api },
            .{ .name = "v2_helpers", .module = helpers },
        },
    });
    // The frameworks need libc for `std.heap.c_allocator` (table, aggregate).
    const scalar = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_scalar_v2.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "duckdb_v2_api", .module = api },
            .{ .name = "v2_values", .module = values },
            .{ .name = "v2_helpers", .module = helpers },
        },
    });
    const table = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_table_v2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "duckdb_v2_api", .module = api },
            .{ .name = "v2_helpers", .module = helpers },
        },
    });
    const aggregate = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_aggregate_v2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "duckdb_v2_api", .module = api },
            .{ .name = "v2_helpers", .module = helpers },
        },
    });
    const appender = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_appender_v2.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "duckdb_v2_api", .module = api },
            .{ .name = "v2_helpers", .module = helpers },
        },
    });
    const cast = b.createModule(.{
        .root_source_file = b.path("src/lib/comptime_cast_v2.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "duckdb_v2_api", .module = api },
            .{ .name = "v2_values", .module = values },
            .{ .name = "v2_helpers", .module = helpers },
        },
    });
    return .{ .helpers = helpers, .values = values, .examples = examples, .scalar = scalar, .table = table, .aggregate = aggregate, .appender = appender, .cast = cast };
}

/// Runs a Windows `exe` under Wine, headless, in the Wine prefix `prefix` (created by the first run). Wine's complaints about fonts are noise: nothing here draws.
fn addWineRun(b: *std.Build, wine: []const u8, prefix: []const u8, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{wine});
    run.addArtifactArg(exe);
    run.setEnvironmentVariable("WINEPREFIX", prefix);
    run.setEnvironmentVariable("WINEDEBUG", "-all");
    run.setEnvironmentVariable("WINEARCH", "win64");
    run.removeEnvironmentVariable("DISPLAY");
    run.expectExitCode(0);
    run.addCheck(.{ .expect_stderr_match = "all static-extension queries returned the expected result" });
    run.has_side_effects = true; // always run: the point is the check, not a cached result
    return run;
}

/// What `addStaticEmbedExe` needs from `build`: the real extension linked into a process that has
/// DuckDB's static libraries, with the extensions it is asked for registered next to it.
const StaticEmbed = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    static_libs_dep: *std.Build.Dependency,
    duckdb_full_c_mod: *std.Build.Module,
    duckdb_static_mod: *std.Build.Module,
    duckdb_v2_types_mod: *std.Build.Module,
    duckdb_v2_static_mod: *std.Build.Module,
    libstdcxx_path: []const u8,
    libgcc_eh_path: []const u8,
    /// Windows only: MinGW's `libgcc.a` (`__emutls_get_address`, ...); the Zig-bundled libc++ and
    /// compiler runtime do not provide what a GCC-built, libstdc++-using DuckDB needs.
    libgcc_path: ?[]const u8,
};

/// The registration of each linked extension archive (or capability), generated: one `extern fn` per describe function,
/// as the module `static_extensions` with `registerAll()`.
fn addExtensionLoader(b: *std.Build, exe: *std.Build.Step.Compile, duckdb_static_mod: *std.Build.Module, extensions: []const []const u8) void {
    // The registration of each extension, generated: one `extern fn` per describe function.
    var loader: std.Io.Writer.Allocating = .init(b.allocator);
    loader.writer.writeAll("const duckdb_static = @import(\"duckdb_static\");\nconst D = duckdb_static.ExtensionDescriptor;\n") catch @panic("OOM");
    for (extensions) |ext| loader.writer.print("extern fn duckdb_extension_{s}_describe(*D) callconv(.c) i32;\n", .{ext}) catch @panic("OOM");
    loader.writer.writeAll("\n/// Registers every extension linked into the program, in the order given to the build; a failing\n/// registration does not stop the rest. Returns 0 if all succeeded.\npub fn registerAll() i32 {\n    var result: i32 = 0;\n    _ = &result;\n") catch @panic("OOM");
    for (extensions) |ext| loader.writer.print("    if (duckdb_static.registerStaticExtension(@ptrCast(&duckdb_extension_{s}_describe)) != 0) result = 1;\n", .{ext}) catch @panic("OOM");
    loader.writer.writeAll("    return result;\n}\n") catch @panic("OOM");
    const generated = b.addWriteFiles();
    const loader_path = generated.add("static_extensions.zig", loader.written());
    const loader_mod = b.createModule(.{ .root_source_file = loader_path });
    loader_mod.addImport("duckdb_static", duckdb_static_mod);
    exe.root_module.addImport("static_extensions", loader_mod);
}

/// The embedding recipe (src/cookbook/embed_sql.zig): a program that hosts DuckDB through the v2 API and runs SQL.
fn addEmbedSqlExe(b: *std.Build, ctx: StaticEmbed) *std.Build.Step.Compile {
    return addEmbedExe(b, ctx, "zig_cookbook_embed_sql", "src/cookbook/embed_sql.zig", &.{});
}

/// A recipe that hosts DuckDB: `source` against the static bindings, linked with the static libraries and `extensions`
/// (capabilities such as "loadable_extensions", which `LOAD 'file.duckdb_extension'` needs).
fn addEmbedExe(b: *std.Build, ctx: StaticEmbed, name: []const u8, source: []const u8, extensions: []const []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const graph = v2Graph(b, ctx.target, ctx.optimize, ctx.duckdb_v2_static_mod);
    exe.root_module.addImport("duckdb_v2_api", ctx.duckdb_v2_static_mod);
    exe.root_module.addImport("v2_helpers", graph.helpers);
    linkDuckdbStatic(b, exe, ctx, extensions);
    if (extensions.len > 0) addExtensionLoader(b, exe, ctx.duckdb_static_mod, extensions);
    return exe;
}

/// A program with the real zig_ext_v2 (built against the static bindings) and `extensions` (names of
/// DuckDB's static extension archives, e.g. "json", plus the capabilities "httplib" and
/// "loadable_extensions") registered with DuckDB before the database opens.
/// Links `exe` against DuckDB's static libraries: libc, the C++ runtime the archives were built against, the
/// extension archives (registered by the caller) and `libduckdb_static.a` last.
fn linkDuckdbStatic(b: *std.Build, exe: *std.Build.Step.Compile, ctx: StaticEmbed, extensions: []const []const u8) void {
    const static_libs_dep = ctx.static_libs_dep;
    const libstdcxx_path = ctx.libstdcxx_path;
    const libgcc_eh_path = ctx.libgcc_eh_path;
    const is_windows = ctx.target.result.os.tag == .windows;

    exe.root_module.link_libc = true;
    // NOT `link_libcpp = true` or `linkSystemLibrary("stdc++", .{})`:
    // confirmed live this static libduckdb was built against GNU
    // libstdc++ (its unresolved symbols are all classic libstdc++-ABI
    // names: `std::__cxx11::basic_string`, `__once_proxy`, etc.), but
    // `linkSystemLibrary("stdc++", ...)` doesn't link the system's
    // actual libstdc++ — `std.Build.Module.linkSystemLibrary`'s own
    // source (confirmed by reading it) special-cases any libc++-like
    // name (`isLibCxxLibName`) and silently redirects it to
    // `link_libcpp = true`, i.e. Zig's own bundled LLVM libc++ —
    // identical, ABI-incompatible result either way. The only way to
    // get the REAL system libstdc++ is to link its file directly,
    // bypassing that name-based redirect.
    //
    // The exact path (`/usr/lib/gcc/<triple>/<version>/`) differs by
    // distro and GCC version, so it's resolved via `g++
    // -print-file-name=...` (the same query GCC's own driver uses
    // internally) rather than hardcoded — `-Dlibstdcxx-path=`/
    // `-Dlibgcc-eh-path=` override it explicitly for a host without
    // `g++` on `PATH`, or a nonstandard toolchain layout.
    exe.root_module.addObjectFile(.{ .cwd_relative = libstdcxx_path });
    // libstdc++ itself needs GCC's own unwinder (`_Unwind_*`, C++
    // exception-handling primitives) — a separate archive, not part
    // of libstdc++.a and not supplied by Zig's own LLVM-based
    // unwinder either (confirmed live: without this, the `_Unwind_*`
    // symbols libstdc++.a's eh_throw.o/eh_personality.o reference are
    // undefined).
    exe.root_module.addObjectFile(.{ .cwd_relative = libgcc_eh_path });
    if (ctx.libgcc_path) |libgcc_path| exe.root_module.addObjectFile(.{ .cwd_relative = libgcc_path });
    if (is_windows) {
        // What DuckDB's MinGW build needs from Windows (sockets, the restart manager).
        exe.root_module.linkSystemLibrary("ws2_32", .{});
        exe.root_module.linkSystemLibrary("wsock32", .{});
        exe.root_module.linkSystemLibrary("rstrtmgr", .{});
    }
    // `addLibraryPath` + `linkSystemLibrary` (not `addObjectFile`): a
    // plain static archive added via `addObjectFile` ended up ordered
    // BEFORE the object files that reference its symbols on the
    // actual link command line (confirmed live via the failing
    // command's own argv) — classic single-pass-linker archive
    // ordering problem (a library must come AFTER what needs its
    // symbols). `linkSystemLibrary` puts it where system libraries
    // normally go, resolving this.
    // The extension archives come first, `libduckdb_static.a` last: an archive can only satisfy
    // the undefined symbols of what precedes it, and the extensions use DuckDB's own symbols.
    // Capabilities (`httplib`, `loadable_extensions`) are archives of their own, not extensions.
    exe.root_module.addLibraryPath(static_libs_dep.path("."));
    for (extensions) |ext| {
        if (std.mem.eql(u8, ext, "httplib") or std.mem.eql(u8, ext, "loadable_extensions")) {
            exe.root_module.linkSystemLibrary(b.fmt("duckdb_{s}", .{ext}), .{});
        } else {
            exe.root_module.linkSystemLibrary(b.fmt("{s}_extension", .{ext}), .{});
        }
    }
    exe.root_module.linkSystemLibrary("duckdb_static", .{});
}

fn addStaticEmbedExe(b: *std.Build, ctx: StaticEmbed, exe_name: []const u8, extensions: []const []const u8) *std.Build.Step.Compile {
    const target = ctx.target;
    const optimize = ctx.optimize;
    const duckdb_full_c_mod = ctx.duckdb_full_c_mod;
    const duckdb_static_mod = ctx.duckdb_static_mod;
    const duckdb_v2_types_mod = ctx.duckdb_v2_types_mod;
    const duckdb_v2_static_mod = ctx.duckdb_v2_static_mod;
    const is_windows = target.result.os.tag == .windows;

    const exe = b.addExecutable(.{
        .name = exe_name,
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/static_embed_poc_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The real extension against the static backend: `get_api` is always null under static
    // loading, and the direct-link bindings do not need it.
    const static_graph = v2Graph(b, target, optimize, duckdb_v2_static_mod);
    exe.root_module.addImport("duckdb_v2_types", duckdb_v2_types_mod);
    exe.root_module.addImport("duckdb_static", duckdb_static_mod);
    exe.root_module.addImport("duckdb_full_c", duckdb_full_c_mod);
    exe.root_module.addImport("root_v2", b.createModule(.{
        .root_source_file = b.path("src/root_v2.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "duckdb_v2_api", .module = duckdb_v2_static_mod },
            .{ .name = "v2_helpers", .module = static_graph.helpers },
            .{ .name = "comptime_scalar_v2", .module = static_graph.scalar },
            .{ .name = "comptime_table_v2", .module = static_graph.table },
        },
    }));
    linkDuckdbStatic(b, exe, ctx, extensions);

    addExtensionLoader(b, exe, duckdb_static_mod, extensions);
    const names = b.addOptions();
    names.addOption([]const []const u8, "extensions", extensions);
    exe.root_module.addOptions("static_embed_options", names);
    if (is_windows) {
        // The one libstdc++ symbol httplib needs that a msvcrt-flavoured MinGW libstdc++ lacks.
        exe.root_module.addImport("mingw_shim", b.createModule(.{
            .root_source_file = b.path("src/lib/mingw_libstdcxx_shim.zig"),
            .target = target,
            .optimize = optimize,
        }));
    }
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const duckdb_cli_v2 = duckdbV2CliLazyPath(b);

    // ── The v1 extension's own identity — configurable, mirroring
    // habedi/template-duckdb-extension-zig's `-Dextension-name=`/
    // `-Dapi-version=`/`-Dextension-version=`/`-Dplatform=` (there under
    // slightly different flag names; kept short here since this project
    // has no Makefile layer renaming them for CLI ergonomics the way that
    // template's `make build EXTENSION_NAME=...` does — a Taskfile.yml
    // recipe can do the same forwarding if needed). Optimization mode
    // (their `RELEASE_MODE`) needs no separate option at all — it's
    // already Zig's own standard `-Doptimize=`, set above.
    const extension_name = b.option(
        []const u8,
        "name",
        "Extension name (default: " ++ default_extension_name ++ ")",
    ) orelse default_extension_name;
    const target_duckdb_version = b.option(
        []const u8,
        "api-version",
        "DuckDB extension API version to target (default: " ++ default_target_duckdb_version ++ ")",
    ) orelse default_target_duckdb_version;
    const extension_version = b.option(
        []const u8,
        "extension-version",
        "Version recorded in the extension metadata (default: " ++ default_extension_version ++ ")",
    ) orelse default_extension_version;
    const platform_override = b.option(
        []const u8,
        "platform",
        "Override the auto-detected platform string written into the host build's metadata (e.g. linux_amd64) — does not affect `cross`, which already computes the correct one per target",
    );
    // The DuckDB CLIENT version directory `dist` publishes under — a
    // separate concern from `target_duckdb_version` (the extension's own
    // ABI-compat minimum). See docs/rationale/0004_extension-distribution-and-signing.md.
    const dist_version = b.option(
        []const u8,
        "dist-version",
        "DuckDB client version directory for `dist` packaging (default: v1.5.6)",
    ) orelse "v1.5.6";
    // The same for the v2 extensions: the exact alpha, because the v2 API is only guaranteed for one DuckDB version.
    const dist_version_v2 = b.option(
        []const u8,
        "dist-version-v2",
        "DuckDB version the v2 extensions are built for: the directory `dist-v2` packages under and the version in their footer (default: v2.0.0)",
    ) orelse v2_duckdb_version;
    const extension_version_v2 = b.option([]const u8, "extension-version-v2", "Extension version recorded in the v2 extensions (default: v0.1.0)") orelse "v0.1.0";

    // `wasm-ext` step — see `addWasmEmscriptenBuild`'s doc comment for the full recipe.
    const emcc_path = b.option(
        []const u8,
        "emcc-path",
        "Path to a real `emcc` from an activated emsdk, for the `wasm-ext` step (default: `emcc` on PATH, i.e. after sourcing emsdk_env.sh)",
    ) orelse "emcc";

    // `v2-static-embed-poc` link paths — see that step's own comment.
    const libstdcxx_path_override = b.option([]const u8, "libstdcxx-path", "Path to the system libstdc++.a for `v2-static-embed-poc` (default: `g++ -print-file-name=libstdc++.a`)");
    const wine_path = b.option([]const u8, "wine", "Wine executable: the v2-static-embed-poc steps run a Windows build under it (e.g. a prebuilt Wine unpacked anywhere; no install needed)");
    // Next to the unpacked Wine unless given, so the run never touches ~/.wine.
    const wine_prefix = b.option([]const u8, "wine-prefix", "Wine prefix directory for -Dwine (default: ../prefix beside the Wine executable's directory)") orelse
        if (wine_path) |w| b.fmt("{s}/prefix", .{std.fs.path.dirname(std.fs.path.dirname(w) orelse ".") orelse "."}) else "";
    const libgcc_path_override = b.option([]const u8, "libgcc-path", "Path to MinGW's libgcc.a for `v2-static-embed-poc` with `-Dtarget=x86_64-windows-gnu` (default: `x86_64-w64-mingw32-g++-posix -print-file-name=libgcc.a`)");
    const libgcc_eh_path_override = b.option([]const u8, "libgcc-eh-path", "Path to the system libgcc_eh.a for `v2-static-embed-poc` (default: `g++ -print-file-name=libgcc_eh.a`)");

    // `demo-stipple` step parameters — see its definition below.
    const stipple_demo_url = b.option(
        []const u8,
        "stipple-url",
        "Image URL for `demo-stipple` (default: the example leaves image)",
    ) orelse "https://dahtah.github.io/imager/images/stippling_leaves.png";
    const stipple_demo_width = b.option(u32, "stipple-width", "Canvas width (chars) for `demo-stipple` (default: 80)") orelse 80;
    const stipple_demo_height = b.option(u32, "stipple-height", "Canvas height (chars) for `demo-stipple` (default: 40)") orelse 40;
    const stipple_demo_points = b.option(u32, "stipple-points", "Number of stipple points for `demo-stipple` (default: 2000)") orelse 2000;
    const stipple_demo_iterations = b.option(u32, "stipple-iterations", "Lloyd relaxation iterations for `demo-stipple` (default: 20)") orelse 20;

    // `-Dname=`/`-Dapi-version=` must also reach `src/ext/init.zig`'s
    // actual exported entry point, not just the metadata footer —
    // DuckDB's loader looks for the symbol `<filename>_init_c_api` by
    // name (confirmed live: renaming only the output file, without this,
    // produces a `.duckdb_extension` DuckDB reports as "did not contain
    // function '<name>_init_c_api'", unloadable under its new name). A
    // plain `export fn <literal>` can't take a build-time string, so
    // `init.zig` instead `@export`s under a name built from this
    // generated module at comptime. The runtime API-version string
    // `initApi` negotiates with DuckDB also comes from here now, instead
    // of its own separate hardcoded `"v1.2.0"` — one source of truth
    // instead of two, now that this is actually configurable.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "extension_name", extension_name);
    build_options.addOption([]const u8, "api_version", target_duckdb_version);
    const build_options_mod = build_options.createModule();

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

    // ── Static-extension registration header (speculative prototype —
    // see docs/v2-migration-plan.md's "Static linking" section) ──────────
    // Vendored directly in src/lib/ rather than pinned via build.zig.zon;
    // see that file's own header comment for why.
    const duckdb_c_static: Translator = .init(translate_c_dep, .{
        .name = "duckdb_c_static",
        .c_source_file = b.path("src/lib/duckdb_static_extension.h"),
        .target = target,
        .optimize = optimize,
    });
    const duckdb_static_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_static.zig"),
        .target = target,
        .optimize = optimize,
    });
    duckdb_static_mod.addImport("duckdb_c_static", duckdb_c_static.mod);
    const duckdb_static_check = b.addTest(.{ .root_module = duckdb_static_mod });
    const run_duckdb_static_check = b.addRunArtifact(duckdb_static_check);

    // ── Generated v2 bindings: shared types, static (direct-link) and
    // dynamic (get_api) backends ───────────────────────────────────────────
    // `src/lib/duckdb_v2_{types,static,dynamic}.zig` are generated from
    // DuckDB's own YAML API spec by tools/gen_v2_bindings.zig
    // (`zig build gen-v2-bindings`, below) and committed, so that a normal
    // build needs neither the tool nor zig-yaml.
    //
    // - static: every function is a plain `extern fn duckdb_v2_*` resolved
    //   at link time — the mode `v2-static-embed-poc-direct` proved with
    //   hand-picked declarations.
    // - dynamic: the `get_api` function-pointer table (`Api`), `init` to
    //   fill it, and a wrapper per function that calls through it.
    //
    // Both use the C names and re-export the one `duckdb_v2_types` module,
    // so code written against `duckdb_v2_api` (an import name a consumer
    // binds to one of the two) builds against either.
    //
    // Parity tests compare the files with the pinned headers, so they
    // cannot silently drift from the commit `duckdb_headers_v2` pins.
    const duckdb_v2_types_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_v2_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const duckdb_v2_static_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_v2_static.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "duckdb_v2_types", .module = duckdb_v2_types_mod }},
    });
    const duckdb_v2_dynamic_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/duckdb_v2_dynamic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "duckdb_v2_types", .module = duckdb_v2_types_mod }},
    });
    // The generated files include the unstable functions, so the headers
    // are translated with them too.
    const duckdb_v2_header_c: Translator = .init(translate_c_dep, .{
        .name = "duckdb_v2_header_c",
        .c_source_file = duckdb_headers_v2_dep.path("duckdb_v2.h"),
        .target = target,
        .optimize = optimize,
        .extra_args = &.{"-DDUCKDB_V2_API_ALLOW_UNSTABLE=1"},
    });
    const duckdb_v2_extension_header_c: Translator = .init(translate_c_dep, .{
        .name = "duckdb_v2_extension_header_c",
        .c_source_file = duckdb_headers_v2_dep.path("duckdb_extension_v2.h"),
        .target = target,
        .optimize = optimize,
        .extra_args = &.{"-DDUCKDB_V2_API_ALLOW_UNSTABLE=1"},
    });
    duckdb_v2_extension_header_c.addIncludePath(duckdb_headers_v2_dep.path("."));

    const v2_static_parity = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/duckdb_v2_static_parity.zig"),
            .target = target,
            .optimize = optimize,
            // Debug info would name every extern function, and the linker would then
            // ask for all of them although the test only inspects their types.
            .strip = true,
            .imports = &.{
                .{ .name = "duckdb_v2_static", .module = duckdb_v2_static_mod },
                .{ .name = "duckdb_v2_full_c", .module = duckdb_v2_header_c.mod },
            },
        }),
    });
    const run_v2_static_parity = b.addRunArtifact(v2_static_parity);

    const v2_dynamic_parity = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/duckdb_v2_dynamic_parity.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .imports = &.{
                .{ .name = "duckdb_v2_static", .module = duckdb_v2_static_mod },
                .{ .name = "duckdb_v2_dynamic", .module = duckdb_v2_dynamic_mod },
                .{ .name = "duckdb_v2_extension_c", .module = duckdb_v2_extension_header_c.mod },
            },
        }),
    });
    const run_v2_dynamic_parity = b.addRunArtifact(v2_dynamic_parity);

    // Regenerates the three files above. Not part of any default step: it
    // needs a checkout of the DuckDB commit that `duckdb_headers_v2` pins,
    // and zig-yaml (a lazy path dependency, fetched only here).
    // Which functions of the v2 C API the hand-written code references (see tools/api_v2_coverage.zig):
    // `coverage-api-v2` rewrites docs/api-v2-coverage.md, `coverage-api-v2-check` fails if it is stale.
    {
        const coverage_exe = b.addExecutable(.{
            .name = "api_v2_coverage",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/api_v2_coverage.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        const coverage_args = [_][]const u8{ "--poc", "poc", "--poc", "examples", "src/functions", "src/cookbook", "src/lib", "src/ext" };
        const coverage_run = b.addRunArtifact(coverage_exe);
        coverage_run.addFileArg(b.path("docs/generated/api_v2_functions.tsv"));
        coverage_run.addArg("docs/api-v2-coverage.md");
        coverage_run.addArgs(&coverage_args);
        coverage_run.has_side_effects = true;
        b.step("coverage-api-v2", "Rewrite docs/api-v2-coverage.md: which v2 C API functions the hand-written code references").dependOn(&coverage_run.step);

        const coverage_check = b.addRunArtifact(coverage_exe);
        coverage_check.addFileArg(b.path("docs/generated/api_v2_functions.tsv"));
        coverage_check.addArg("docs/api-v2-coverage.md");
        coverage_check.addArg("--check");
        coverage_check.addArgs(&coverage_args);
        coverage_check.has_side_effects = true;
        b.step("coverage-api-v2-check", "Fail if docs/api-v2-coverage.md is stale").dependOn(&coverage_check.step);
    }

    const v2_api_spec = b.option([]const u8, "v2-api-spec", "Directory with DuckDB's v2 API spec (<duckdb checkout>/api_spec/v2), for `gen-v2-bindings`");
    const v2_api_spec_ref = b.option([]const u8, "v2-api-spec-ref", "Where the spec comes from, recorded in the generated files") orelse
        "duckdb d54cbbe3df, v2.0.0";
    const gen_v2_bindings_step = b.step("gen-v2-bindings", "Regenerate src/lib/duckdb_v2_{types,static,dynamic}.zig from the DuckDB v2 API spec (needs -Dv2-api-spec=)");
    if (v2_api_spec) |spec_dir| {
        if (b.lazyDependency("yaml", .{ .target = b.graph.host, .optimize = .ReleaseSafe })) |yaml_dep| {
            const gen_exe = b.addExecutable(.{
                .name = "gen_v2_bindings",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/gen_v2_bindings.zig"),
                    .target = b.graph.host,
                    .optimize = .ReleaseSafe,
                }),
            });
            gen_exe.root_module.addImport("yaml", yaml_dep.module("yaml"));

            const run_gen = b.addRunArtifact(gen_exe);
            run_gen.addDirectoryArg(.{ .cwd_relative = spec_dir });
            const generated = run_gen.addOutputDirectoryArg("duckdb_v2_bindings");
            run_gen.addArg("--unstable");
            run_gen.addArgs(&.{ "--source", v2_api_spec_ref });

            const update_generated = b.addUpdateSourceFiles();
            inline for (.{ "types", "static", "dynamic" }) |backend| {
                const file = "duckdb_v2_" ++ backend ++ ".zig";
                update_generated.addCopyFileToSource(generated.path(b, file), "src/lib/" ++ file);
            }
            update_generated.addCopyFileToSource(generated.path(b, "duckdb_v2_index.tsv"), "docs/generated/api_v2_functions.tsv");
            gen_v2_bindings_step.dependOn(&update_generated.step);
        }
    } else {
        gen_v2_bindings_step.dependOn(&b.addFail("gen-v2-bindings needs -Dv2-api-spec=<duckdb checkout>/api_spec/v2").step);
    }

    // The modules written against `duckdb_v2_api`, bound to the dynamic backend. The unit tests and
    // the loadable extensions use these; `v2Graph` builds the same set for another backend.
    const v2_graph = v2Graph(b, target, optimize, duckdb_v2_dynamic_mod);
    const v2_helpers_mod = v2_graph.helpers;
    const v2_values_mod = v2_graph.values;
    const duckdb_v2_examples_mod = v2_graph.examples;
    const comptime_scalar_v2_mod = v2_graph.scalar;
    const comptime_table_v2_mod = v2_graph.table;
    const comptime_aggregate_v2_mod = v2_graph.aggregate;
    const comptime_appender_v2_mod = v2_graph.appender;
    const comptime_cast_v2_mod = v2_graph.cast;
    const run_v2_helpers_check = b.addRunArtifact(b.addTest(.{ .root_module = v2_helpers_mod }));
    const run_v2_values_check = b.addRunArtifact(b.addTest(.{ .root_module = v2_values_mod }));
    const run_duckdb_v2_examples_check = b.addRunArtifact(b.addTest(.{ .root_module = duckdb_v2_examples_mod }));
    const run_comptime_scalar_v2_check = b.addRunArtifact(b.addTest(.{ .root_module = comptime_scalar_v2_mod }));
    const run_comptime_table_v2_check = b.addRunArtifact(b.addTest(.{ .root_module = comptime_table_v2_mod }));
    const run_comptime_aggregate_v2_check = b.addRunArtifact(b.addTest(.{ .root_module = comptime_aggregate_v2_mod }));
    const run_comptime_appender_v2_check = b.addRunArtifact(b.addTest(.{ .root_module = comptime_appender_v2_mod }));
    const run_comptime_cast_v2_check = b.addRunArtifact(b.addTest(.{ .root_module = comptime_cast_v2_mod }));
    duckdb_static_mod.addImport("duckdb_v2_types", duckdb_v2_types_mod);

    // One hello-world scalar function written against `duckdb_v2_api`,
    // instantiated once per backend: the same source, two bindings.
    const gen_hello_static_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/gen_hello.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "duckdb_v2_api", .module = duckdb_v2_static_mod }},
    });
    const gen_hello_dynamic_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/gen_hello.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "duckdb_v2_api", .module = duckdb_v2_dynamic_mod }},
    });

    // No DuckDB dependency at all — a pure, independently testable kernel
    // module (see its own doc comment), used by the v2-poc matmul demo.
    const matmul_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/matmul.zig"),
        .target = target,
        .optimize = optimize,
    });
    const matmul_check = b.addTest(.{ .root_module = matmul_mod });
    const run_matmul_check = b.addRunArtifact(matmul_check);

    // No DuckDB dependency either — a pure, independently testable
    // subprocess-reading/parsing module, used by the v2-poc nethogs-trace
    // demo.
    const nethogs_trace_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/nethogs_trace.zig"),
        .target = target,
        .optimize = optimize,
    });
    const nethogs_trace_check = b.addTest(.{ .root_module = nethogs_trace_mod });
    const run_nethogs_trace_check = b.addRunArtifact(nethogs_trace_check);

    const v2_check_step = b.step("v2-check", "Type-check the in-progress duckdb v2 API bindings");
    v2_check_step.dependOn(&run_v2_values_check.step);
    v2_check_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib/mingw_libstdcxx_shim.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    v2_check_step.dependOn(&run_v2_static_parity.step);
    v2_check_step.dependOn(&run_v2_dynamic_parity.step);
    v2_check_step.dependOn(&run_v2_helpers_check.step);
    v2_check_step.dependOn(&run_duckdb_v2_examples_check.step);
    v2_check_step.dependOn(&run_comptime_scalar_v2_check.step);
    v2_check_step.dependOn(&run_comptime_table_v2_check.step);
    v2_check_step.dependOn(&run_comptime_aggregate_v2_check.step);
    v2_check_step.dependOn(&run_comptime_appender_v2_check.step);
    v2_check_step.dependOn(&run_comptime_cast_v2_check.step);
    v2_check_step.dependOn(&run_duckdb_static_check.step);
    v2_check_step.dependOn(&run_matmul_check.step);
    v2_check_step.dependOn(&run_nethogs_trace_check.step);

    // ── v2 proof-of-concept extension (real runtime test, not the real
    // extension) — registers one scalar function against a live DuckDB
    // v2.0 alpha, proving duckdb_v2_dynamic.zig's bindings beyond type-checking.
    const v2_poc_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig_ext_v2_poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ext/init_v2_poc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    v2_poc_lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod);
    v2_poc_lib.root_module.addImport("v2_values", v2_values_mod);
    v2_poc_lib.root_module.addImport("v2_helpers", v2_helpers_mod);
    v2_poc_lib.root_module.addImport("duckdb_v2_examples", duckdb_v2_examples_mod);
    v2_poc_lib.root_module.addImport("comptime_scalar_v2", comptime_scalar_v2_mod);
    v2_poc_lib.root_module.addImport("comptime_table_v2", comptime_table_v2_mod);
    v2_poc_lib.root_module.addImport("comptime_aggregate_v2", comptime_aggregate_v2_mod);
    v2_poc_lib.root_module.addImport("comptime_appender_v2", comptime_appender_v2_mod);
    v2_poc_lib.root_module.addImport("comptime_cast_v2", comptime_cast_v2_mod);
    v2_poc_lib.root_module.addImport("matmul", matmul_mod);
    v2_poc_lib.root_module.addImport("nethogs_trace", nethogs_trace_mod);
    v2_poc_lib.root_module.link_libc = true;

    // Synthetic nethogs -t stand-in (see src/fake_nethogs_main.zig's doc
    // comment) — installed alongside the v2-poc extension so the demo
    // table function has something to spawn with no root/setcap needed.
    const fake_nethogs_exe = b.addExecutable(.{
        .name = "fake_nethogs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fake_nethogs_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_fake_nethogs = b.addInstallArtifact(fake_nethogs_exe, .{});

    const v2_poc_output = addDuckdbExtensionMetadata(b, v2_poc_lib, "zig_ext_v2_poc", v2_duckdb_version, "v0.0.0-poc", v2_abi_type, duckdbPlatformString(target));

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
    ext_v2_lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod);
    ext_v2_lib.root_module.addImport("v2_helpers", v2_helpers_mod);
    ext_v2_lib.root_module.addImport("comptime_scalar_v2", comptime_scalar_v2_mod);
    ext_v2_lib.root_module.addImport("comptime_table_v2", comptime_table_v2_mod);
    ext_v2_lib.root_module.link_libc = true;

    const ext_v2_output = addDuckdbExtensionMetadata(b, ext_v2_lib, "zig_ext_v2", v2_duckdb_version, "v0.1.0", v2_abi_type, duckdbPlatformString(target));
    const install_ext_v2 = b.addInstallFile(ext_v2_output, "lib/zig_ext_v2.duckdb_extension");

    const ext_v2_step = b.step("ext-v2", "Build the real, parallel v2 .duckdb_extension file");
    ext_v2_step.dependOn(&install_ext_v2.step);

    // An extension whose registration fails: loading it must fail with the reason, not crash (an error slot that
    // started uninitialised made DuckDB write through garbage).
    const bad_ext_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig_ext_bad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root_bad_ext.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bad_ext_lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod);
    bad_ext_lib.root_module.addImport("v2_helpers", v2_helpers_mod);
    bad_ext_lib.root_module.addImport("comptime_scalar_v2", comptime_scalar_v2_mod);
    bad_ext_lib.root_module.link_libc = true;
    const bad_ext_output = addDuckdbExtensionMetadata(b, bad_ext_lib, "zig_ext_bad", v2_duckdb_version, "v0.1.0", v2_abi_type, duckdbPlatformString(target));
    {
        const run = std.Build.Step.Run.create(b, "load an extension whose registration fails");
        if (duckdb_cli_v2) |cli| run.addFileArg(cli) else run.addArg("duckdb");
        run.addArgs(&.{ "-unsigned", "-no-init", "-c" });
        run.addFileArg2(bad_ext_output, .{ .prefix = "SET allow_extensions_metadata_mismatch=true; LOAD '", .suffix = "'; SELECT 1" });
        run.expectExitCode(1);
        run.addCheck(.{ .expect_stderr_match = "Duplicate parameter name" });
        run.has_side_effects = true;
        b.step("load-failure-v2", "Load an extension whose registration fails: the load must fail with the reason").dependOn(&run.step);
    }

    // The Arrow library the Arrow recipe uses (third_party/gld-arrow-zig/PATCHES.md), and its own tests, which read
    // their golden files relative to the working directory.
    const arrow_mod = b.createModule(.{
        .root_source_file = b.path("third_party/gld-arrow-zig/src/arrow.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_arrow_vendor = b.addRunArtifact(b.addTest(.{ .root_module = arrow_mod }));
    run_arrow_vendor.setCwd(b.path("third_party/gld-arrow-zig"));
    b.step("test-arrow-vendor", "Run the tests of the vendored gld-arrow-zig library").dependOn(&run_arrow_vendor.step);

    // The cookbook: one small, tested example per capability of the v2 C API (docs/cookbook.md).
    const ext_cookbook_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig_ext_cookbook",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root_cookbook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ext_cookbook_lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod);
    ext_cookbook_lib.root_module.addImport("v2_helpers", v2_helpers_mod);
    ext_cookbook_lib.root_module.addImport("arrow", arrow_mod);
    ext_cookbook_lib.root_module.link_libc = true;
    const ext_cookbook_output = addDuckdbExtensionMetadata(b, ext_cookbook_lib, "zig_ext_cookbook", v2_duckdb_version, "v0.1.0", v2_abi_type, duckdbPlatformString(target));
    const install_ext_cookbook = b.addInstallFile(ext_cookbook_output, "lib/zig_ext_cookbook.duckdb_extension");
    const ext_cookbook_step = b.step("ext-cookbook", "Build the v2 cookbook .duckdb_extension file");
    ext_cookbook_step.dependOn(&install_ext_cookbook.step);

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
    v2_poc_step.dependOn(&install_fake_nethogs.step);

    // ── Dynamic-bindings PoC extension: the generated `get_api` backend,
    // loaded by the real pinned CLI. Registers `gen_hello()` from the same
    // source `v2-static-embed-poc-gen` links statically.
    const v2_gen_poc_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig_ext_v2_gen_poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ext/init_v2_gen_poc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    v2_gen_poc_lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod);
    v2_gen_poc_lib.root_module.addImport("gen_hello", gen_hello_dynamic_mod);
    v2_gen_poc_lib.root_module.link_libc = true;
    const v2_gen_poc_output = addDuckdbExtensionMetadata(b, v2_gen_poc_lib, "zig_ext_v2_gen_poc", v2_duckdb_version, "v0.0.0-poc", v2_abi_type, duckdbPlatformString(target));

    const v2_gen_poc_step = b.step("v2-gen-poc", "Build the generated-dynamic-bindings .duckdb_extension, load it in the pinned v2 CLI and call gen_hello()");
    {
        const run_duckdb_v2_gen_poc = if (duckdb_cli_v2) |cli| blk: {
            const r = std.Build.Step.Run.create(b, "run duckdb (v2-gen-poc, pinned)");
            r.addFileArg(cli);
            break :blk r;
        } else b.addSystemCommand(&.{"duckdb"});
        run_duckdb_v2_gen_poc.addArgs(&.{ "-unsigned", "-no-init", "-list", "-noheader", "-c" });
        run_duckdb_v2_gen_poc.addFileArg2(v2_gen_poc_output, .{ .prefix = "LOAD '", .suffix = "'; SELECT gen_hello();" });
        run_duckdb_v2_gen_poc.expectStdOutEqual("Hello, generated bindings!\n");
        v2_gen_poc_step.dependOn(&run_duckdb_v2_gen_poc.step);
    }

    // ── Interactive session with the v2-poc extension pre-loaded ─────────
    // Same idea/mechanism as the `duckdb-extension` step above, pointed at
    // `zig_ext_v2_poc` instead of the real `zig_ext_v2` — e.g. for
    // `zig_v2_nethogs_trace`, which only exists in this POC extension, not
    // the real one.
    {
        const run_duckdb_v2_poc = if (duckdb_cli_v2) |cli| blk: {
            const r = std.Build.Step.Run.create(b, "run duckdb (v2-poc, pinned)");
            r.addFileArg(cli);
            break :blk r;
        } else b.addSystemCommand(&.{"duckdb"});
        run_duckdb_v2_poc.addArgs(&.{ "-unsigned", "-no-init", "-cmd" });
        run_duckdb_v2_poc.addFileArg2(v2_poc_output, .{ .prefix = "LOAD '", .suffix = "'; select function_name, function_type, parameter_types from duckdb_functions() where extension_name like '%poc%' order by function_name; " });
        run_duckdb_v2_poc.step.dependOn(&install_fake_nethogs.step);
        run_duckdb_v2_poc.stdio = .inherit;

        const duckdb_v2_poc_step = b.step("duckdb-extension-v2-poc", "Start an interactive DuckDB session with the v2 proof-of-concept extension loaded");
        duckdb_v2_poc_step.dependOn(&run_duckdb_v2_poc.step);
    }

    // ── v2 static-extension registration: real link test (experimental,
    // isolated — see docs/v2-migration-plan.md's "Static linking"
    // section) ─────────────────────────────────────────────────────────
    // Unlike duckdb_static.zig's type-level-only prototype, this actually
    // links the real pinned `libduckdb_static.a` and drives
    // `duckdb_register_static_extension` end to end against a live
    // database — see src/static_embed_poc_main.zig's own doc comment.
    // `lazy = true` on the dependency means this step alone triggers the
    // ~127MB fetch; nothing else is affected if it's never built.
    const embed_for_windows = target.result.os.tag == .windows;
    if (b.lazyDependency(if (embed_for_windows) "duckdb_static_libs_v2_windows_mingw" else "duckdb_static_libs_v2_linux_amd64", .{})) |static_libs_dep| {
        const duckdb_full_c: Translator = .init(translate_c_dep, .{
            .name = "duckdb_full_c",
            .c_source_file = static_libs_dep.path("duckdb.h"),
            .target = target,
            .optimize = optimize,
            // The header declares the functions dllimport otherwise.
            .extra_args = if (embed_for_windows) &.{"-DDUCKDB_STATIC_BUILD"} else &.{},
        });

        // The C++ runtime the archives were built against: the system GCC's, or for Windows a MinGW
        // GCC's (Zig's bundled libc++ has a different ABI).
        const gcc = if (embed_for_windows) "x86_64-w64-mingw32-g++-posix" else "g++";
        const libstdcxx_path = libstdcxx_path_override orelse gccFileName(b, gcc, "libstdc++.a");
        const libgcc_eh_path = libgcc_eh_path_override orelse gccFileName(b, gcc, "libgcc_eh.a");
        const libgcc_path: ?[]const u8 = if (embed_for_windows) (libgcc_path_override orelse gccFileName(b, gcc, "libgcc.a")) else null;
        if (embed_for_windows and !libstdcxxHasEmulatedOnceCall(b, libstdcxx_path)) {
            std.debug.print("error: {s} does not define __emutls_v._ZSt11__once_call, which DuckDB's MinGW static libraries need " ++
                "(a libstdc++ built with emulated TLS, e.g. MinGW's posix thread model; MSYS2's GCC 16 uses native TLS). " ++
                "Point -Dlibstdcxx-path= at one that does.\n", .{libstdcxx_path});
            b.invalid_user_input = true;
        }

        const static_embed_ctx: StaticEmbed = .{
            .target = target,
            .optimize = optimize,
            .static_libs_dep = static_libs_dep,
            .duckdb_full_c_mod = duckdb_full_c.mod,
            .duckdb_static_mod = duckdb_static_mod,
            .duckdb_v2_types_mod = duckdb_v2_types_mod,
            .duckdb_v2_static_mod = duckdb_v2_static_mod,
            .libstdcxx_path = libstdcxx_path,
            .libgcc_eh_path = libgcc_eh_path,
            .libgcc_path = libgcc_path,
        };
        const static_extensions_arg = b.option([]const u8, "static-extensions", "Comma-separated static extension archives to link into v2-static-embed-poc, in registration order (e.g. json,core_functions; httplib and loadable_extensions are capabilities)") orelse "";
        var static_extensions_list: std.ArrayList([]const u8) = .empty;
        var static_extensions_it = std.mem.tokenizeScalar(u8, static_extensions_arg, ',');
        while (static_extensions_it.next()) |name| static_extensions_list.append(b.allocator, name) catch @panic("OOM");
        const static_extensions = static_extensions_list.items;
        const static_embed_poc_exe = addStaticEmbedExe(b, static_embed_ctx, "v2_static_embed_poc", static_extensions);

        // A program for another OS or CPU than the host's is built and installed, not run.
        const embed_can_run = target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch;
        const install_static_embed_poc = b.addInstallArtifact(static_embed_poc_exe, .{});
        const static_embed_poc_step = b.step("v2-static-embed-poc", "Build and run the real static-extension-registration link test (only built for a target the host cannot run)");
        if (embed_can_run) {
            const run_static_embed_poc = b.addRunArtifact(static_embed_poc_exe);
            run_static_embed_poc.step.dependOn(&install_static_embed_poc.step);
            static_embed_poc_step.dependOn(&run_static_embed_poc.step);
        } else if (wine_path) |wine| {
            static_embed_poc_step.dependOn(&addWineRun(b, wine, wine_prefix, static_embed_poc_exe).step);
        } else {
            static_embed_poc_step.dependOn(&install_static_embed_poc.step);
        }

        // The embedding recipe: SQL through the v2 host API (docs/cookbook.md).
        const embed_sql_exe = addEmbedSqlExe(b, static_embed_ctx);
        const run_embed_sql = b.addRunArtifact(embed_sql_exe);
        run_embed_sql.addCheck(.{ .expect_stderr_match = "embedded SQL checks passed" });
        b.step("cookbook-embed", "Build and run the embedding recipe: SQL through the v2 host API (needs the static libraries)").dependOn(&run_embed_sql.step);

        // Instances, the catalog, and an audit of the documentation of the functions of the two v2 extensions, which
        // the program loads from their files (hence the `loadable_extensions` capability and the extensions as arguments).
        const embed_instance_exe = addEmbedExe(b, static_embed_ctx, "zig_cookbook_embed_instance", "src/cookbook/embed_instance.zig", &.{ "core_functions", "loadable_extensions" });
        const run_embed_instance = b.addRunArtifact(embed_instance_exe);
        run_embed_instance.addFileArg(ext_v2_output);
        run_embed_instance.addFileArg(ext_cookbook_output);
        run_embed_instance.addCheck(.{ .expect_stderr_match = "instance and catalog checks passed" });
        b.step("cookbook-embed-instance", "Build and run the instance, catalog and documentation-audit recipe (needs the static libraries)").dependOn(&run_embed_instance.step);

        // The same program with several extension archives linked: the capabilities first, then the
        // extensions, `libduckdb_static.a` last.
        const static_embed_poc_ext_exe = addStaticEmbedExe(b, static_embed_ctx, "v2_static_embed_poc_extensions", &.{ "httplib", "loadable_extensions", "core_functions", "json", "icu", "parquet" });
        const install_static_embed_poc_ext = b.addInstallArtifact(static_embed_poc_ext_exe, .{});
        const static_embed_poc_ext_step = b.step("v2-static-embed-poc-extensions", "Build and run the static-embedding link test with several extension archives linked (only built for a target the host cannot run)");
        if (embed_can_run) {
            const run_static_embed_poc_ext = b.addRunArtifact(static_embed_poc_ext_exe);
            run_static_embed_poc_ext.step.dependOn(&install_static_embed_poc_ext.step);
            static_embed_poc_ext_step.dependOn(&run_static_embed_poc_ext.step);
        } else if (wine_path) |wine| {
            static_embed_poc_ext_step.dependOn(&addWineRun(b, wine, wine_prefix, static_embed_poc_ext_exe).step);
        } else {
            static_embed_poc_ext_step.dependOn(&install_static_embed_poc_ext.step);
        }

        // The direct and generated-bindings link tests are for the Linux archives.
        if (!embed_for_windows) {
            // ── v2 static-extension registration, take 2: the real *direct*,
            // non-vtable binding mode the first POC above identified as
            // missing — see src/static_embed_poc_direct_main.zig's own doc
            // comment for the full chain confirming this is real, not
            // speculative (`DUCKDB_BUILD_STATIC_EXTENSION`'s actual effect on
            // `duckdb_extension_v2.h`, `nm`-confirmed real exported symbols).
            // Translated from `duckdb_v2.h` (the full host-embedding header,
            // with real top-level `extern` prototypes for every function) —
            // NOT `duckdb_extension_v2.h` (which only ever declares them as
            // vtable struct fields), and NOT the
            // (`duckdb_v2_dynamic.zig`), which intentionally only implements the
            // dynamic/vtable path.
            const duckdb_v2_full_c: Translator = .init(translate_c_dep, .{
                .name = "duckdb_v2_full_c",
                .c_source_file = static_libs_dep.path("duckdb_v2.h"),
                .target = target,
                .optimize = optimize,
            });

            const static_embed_poc_direct_exe = b.addExecutable(.{
                .name = "v2_static_embed_poc_direct",
                .use_llvm = true,
                .use_lld = true,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/static_embed_poc_direct_main.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            static_embed_poc_direct_exe.root_module.addImport("duckdb_v2_full_c", duckdb_v2_full_c.mod);
            static_embed_poc_direct_exe.root_module.addImport("duckdb_static", duckdb_static_mod);
            static_embed_poc_direct_exe.root_module.addImport("duckdb_full_c", duckdb_full_c.mod);
            static_embed_poc_direct_exe.root_module.link_libc = true;
            static_embed_poc_direct_exe.root_module.addObjectFile(.{ .cwd_relative = libstdcxx_path });
            static_embed_poc_direct_exe.root_module.addObjectFile(.{ .cwd_relative = libgcc_eh_path });
            static_embed_poc_direct_exe.root_module.addLibraryPath(static_libs_dep.path("."));
            static_embed_poc_direct_exe.root_module.linkSystemLibrary("duckdb_static", .{});

            const install_static_embed_poc_direct = b.addInstallArtifact(static_embed_poc_direct_exe, .{});
            const run_static_embed_poc_direct = b.addRunArtifact(static_embed_poc_direct_exe);
            run_static_embed_poc_direct.step.dependOn(&install_static_embed_poc_direct.step);

            const static_embed_poc_direct_step = b.step("v2-static-embed-poc-direct", "Build and run the direct (non-vtable) static-extension binding link test");
            static_embed_poc_direct_step.dependOn(&run_static_embed_poc_direct.step);

            // The same slice again, with every `duckdb_v2_*` declaration taken
            // from the generated `duckdb_v2_static.zig` instead of a translate-c
            // of `duckdb_v2.h`.
            const static_embed_poc_gen_exe = b.addExecutable(.{
                .name = "v2_static_embed_poc_gen",
                .use_llvm = true,
                .use_lld = true,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/static_embed_poc_gen_main.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            static_embed_poc_gen_exe.root_module.addImport("duckdb_v2_static", duckdb_v2_static_mod);
            static_embed_poc_gen_exe.root_module.addImport("gen_hello", gen_hello_static_mod);
            static_embed_poc_gen_exe.root_module.addImport("duckdb_static", duckdb_static_mod);
            static_embed_poc_gen_exe.root_module.addImport("duckdb_full_c", duckdb_full_c.mod);
            static_embed_poc_gen_exe.root_module.link_libc = true;
            static_embed_poc_gen_exe.root_module.addObjectFile(.{ .cwd_relative = libstdcxx_path });
            static_embed_poc_gen_exe.root_module.addObjectFile(.{ .cwd_relative = libgcc_eh_path });
            static_embed_poc_gen_exe.root_module.addLibraryPath(static_libs_dep.path("."));
            static_embed_poc_gen_exe.root_module.linkSystemLibrary("duckdb_static", .{});

            const run_static_embed_poc_gen = b.addRunArtifact(static_embed_poc_gen_exe);
            const static_embed_poc_gen_step = b.step("v2-static-embed-poc-gen", "Build and run the link test that uses the generated static bindings");
            static_embed_poc_gen_step.dependOn(&run_static_embed_poc_gen.step);
        }
    }

    // ── v2 proof-of-concept: image-to-braille-art demo (zignal dependency,
    // isolated) ────────────────────────────────────────────────────────────
    // A completely separate extension/step from `v2-poc` above, on purpose:
    // this is the only place in the project pulling in `zignal` (an image
    // decode/resize library), and it's `lazy = true` in build.zig.zon —
    // `b.lazyDependency` returns null on any invocation that doesn't ask
    // for this specific step, so nothing else (the real extensions, the
    // main v2-poc, `zig build test`, CI) is affected if this fails to
    // fetch or build. See src/ext/init_v2_poc_braille.zig's own doc
    // comment for what it registers.
    if (b.lazyDependency("zignal", .{ .target = target, .optimize = optimize })) |zignal_dep| {
        const braille_image_mod = b.createModule(.{
            .root_source_file = b.path("src/lib/braille_image.zig"),
            .target = target,
            .optimize = optimize,
        });
        braille_image_mod.addImport("zignal", zignal_dep.module("zignal"));

        const v2_poc_braille_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "zig_ext_v2_poc_braille",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ext/init_v2_poc_braille.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        v2_poc_braille_lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod);
        v2_poc_braille_lib.root_module.addImport("v2_helpers", v2_helpers_mod);
        v2_poc_braille_lib.root_module.addImport("comptime_scalar_v2", comptime_scalar_v2_mod);
        v2_poc_braille_lib.root_module.addImport("comptime_table_v2", comptime_table_v2_mod);
        v2_poc_braille_lib.root_module.addImport("braille_image", braille_image_mod);
        v2_poc_braille_lib.root_module.link_libc = true;

        const v2_poc_braille_output = addDuckdbExtensionMetadata(b, v2_poc_braille_lib, "zig_ext_v2_poc_braille", v2_duckdb_version, "v0.0.0-poc", v2_abi_type, duckdbPlatformString(target));
        const install_v2_poc_braille = b.addInstallFile(v2_poc_braille_output, "lib/zig_ext_v2_poc_braille.duckdb_extension");

        const v2_poc_braille_step = b.step("v2-poc-braille", "Build the image-to-braille-art v2 proof-of-concept .duckdb_extension file");
        v2_poc_braille_step.dependOn(&install_v2_poc_braille.step);
    }

    // ── v2 proof-of-concept: weighted-Voronoi-stippling demo (zignal +
    // zigcv dependencies, isolated) ───────────────────────────────────────
    // Same full-isolation reasoning as the braille demo above, for both
    // dependencies at once: the only place in the project pulling in
    // `zigcv`, and a second (independent) place pulling in `zignal`. See
    // src/ext/init_v2_poc_stipple.zig's own doc comment for what it
    // registers and src/lib/stipple.zig's for the algorithm itself.
    if (b.lazyDependency("zignal", .{ .target = target, .optimize = optimize })) |zignal_dep_2| {
        if (b.lazyDependency("zigcv", .{ .target = target, .optimize = optimize })) |zigcv_dep| {
            const stipple_mod = b.createModule(.{
                .root_source_file = b.path("src/lib/stipple.zig"),
                .target = target,
                .optimize = optimize,
            });
            const stipple_check = b.addTest(.{ .root_module = stipple_mod });
            const run_stipple_check = b.addRunArtifact(stipple_check);
            v2_check_step.dependOn(&run_stipple_check.step);

            const stipple_image_mod = b.createModule(.{
                .root_source_file = b.path("src/lib/stipple_image.zig"),
                .target = target,
                .optimize = optimize,
            });
            stipple_image_mod.addImport("zignal", zignal_dep_2.module("zignal"));
            stipple_image_mod.addImport("zigcv", zigcv_dep.module("zigcv"));
            stipple_image_mod.addImport("stipple", stipple_mod);

            const v2_poc_stipple_lib = b.addLibrary(.{
                .linkage = .dynamic,
                .name = "zig_ext_v2_poc_stipple",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/ext/init_v2_poc_stipple.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            v2_poc_stipple_lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod);
            v2_poc_stipple_lib.root_module.addImport("v2_helpers", v2_helpers_mod);
            v2_poc_stipple_lib.root_module.addImport("comptime_scalar_v2", comptime_scalar_v2_mod);
            v2_poc_stipple_lib.root_module.addImport("stipple_image", stipple_image_mod);
            v2_poc_stipple_lib.root_module.link_libc = true;

            const v2_poc_stipple_output = addDuckdbExtensionMetadata(b, v2_poc_stipple_lib, "zig_ext_v2_poc_stipple", v2_duckdb_version, "v0.0.0-poc", v2_abi_type, duckdbPlatformString(target));
            const install_v2_poc_stipple = b.addInstallFile(v2_poc_stipple_output, "lib/zig_ext_v2_poc_stipple.duckdb_extension");

            const v2_poc_stipple_step = b.step("v2-poc-stipple", "Build the weighted-Voronoi-stippling v2 proof-of-concept .duckdb_extension file");
            v2_poc_stipple_step.dependOn(&install_v2_poc_stipple.step);

            // ── Demo: run stipple_from_url_ct against the example image,
            // printing the rendered result to stdout. Same pinned-CLI
            // mechanism as `duckdb-extension-v2-poc` above.
            {
                const run_stipple_demo = if (duckdb_cli_v2) |cli| blk: {
                    const r = std.Build.Step.Run.create(b, "run duckdb (v2-poc-stipple demo)");
                    r.addFileArg(cli);
                    break :blk r;
                } else b.addSystemCommand(&.{"duckdb"});
                run_stipple_demo.addArgs(&.{ "-unsigned", "-no-init", "-list", "-c" });
                run_stipple_demo.addFileArg2(v2_poc_stipple_output, .{
                    .prefix = "LOAD '",
                    .suffix = b.fmt("'; SELECT stipple_from_url_ct('{s}', {d}, {d}, {d}, {d});", .{
                        sqlQuoteLiteral(b, stipple_demo_url),
                        stipple_demo_width,
                        stipple_demo_height,
                        stipple_demo_points,
                        stipple_demo_iterations,
                    }),
                });
                run_stipple_demo.stdio = .inherit;

                const stipple_demo_step = b.step("demo-stipple", "Run stipple_from_url_ct against an image (default: the example leaves image), printing the rendered result to stdout. Override with -Dstipple-url=, -Dstipple-width=, -Dstipple-height=, -Dstipple-points=, -Dstipple-iterations=");
                stipple_demo_step.dependOn(&run_stipple_demo.step);
            }
        }
    }

    // ── v2 proof-of-concept: zio as a second `std.Io` backend (zio dependency, isolated) ───────
    // Same full-isolation reasoning as braille/stipple above: the only place in the project
    // pulling in `zio`, `lazy = true` in build.zig.zon, nothing else affected if it fails to
    // fetch or build. See src/ext/init_v2_poc_zio.zig's own doc comment for what it benchmarks.
    if (b.lazyDependency("zio", .{ .target = target, .optimize = optimize })) |zio_dep| {
        const v2_poc_zio_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "zig_ext_v2_poc_zio",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ext/init_v2_poc_zio.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        v2_poc_zio_lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod);
        v2_poc_zio_lib.root_module.addImport("v2_helpers", v2_helpers_mod);
        v2_poc_zio_lib.root_module.addImport("comptime_table_v2", comptime_table_v2_mod);
        v2_poc_zio_lib.root_module.addImport("matmul", matmul_mod);
        v2_poc_zio_lib.root_module.addImport("zio", zio_dep.module("zio"));
        v2_poc_zio_lib.root_module.link_libc = true;

        const v2_poc_zio_output = addDuckdbExtensionMetadata(b, v2_poc_zio_lib, "zig_ext_v2_poc_zio", v2_duckdb_version, "v0.0.0-poc", v2_abi_type, duckdbPlatformString(target));
        const install_v2_poc_zio = b.addInstallFile(v2_poc_zio_output, "lib/zig_ext_v2_poc_zio.duckdb_extension");

        const v2_poc_zio_step = b.step("v2-poc-zio", "Build the zio-vs-std.Io.Threaded matmul benchmark v2 proof-of-concept .duckdb_extension file");
        v2_poc_zio_step.dependOn(&install_v2_poc_zio.step);
    }

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
    lib.root_module.addImport("build_options", build_options_mod);
    lib.root_module.link_libc = true;

    b.installArtifact(lib);

    // ── Post-build step: append metadata to produce .duckdb_extension ────
    const host_platform = platform_override orelse duckdbPlatformString(target);
    const ext_output = addDuckdbExtensionMetadata(b, lib, extension_name, target_duckdb_version, extension_version, abi_type, host_platform);

    // Install the .duckdb_extension file into zig-out/lib/
    const install_ext = b.addInstallFile(ext_output, b.fmt("lib/{s}.duckdb_extension", .{extension_name}));
    b.getInstallStep().dependOn(&install_ext.step);

    // ── "ext" step: just build the .duckdb_extension ─────────────────────
    const ext_step = b.step("ext", "Build the .duckdb_extension file with metadata");
    ext_step.dependOn(&install_ext.step);

    // ── "cross" step: build the real v1 extension for every target in
    // `cross_targets`, each installed under zig-out/lib/<platform>/ ──────
    // `-Dplatform=` deliberately doesn't reach here: each target already
    // computes its own correct platform string, and a single override
    // can't mean anything sensible across 5 different platforms at once.
    const cross_step = b.step("cross", "Cross-compile the real v1 extension for every target in cross_targets");
    for (cross_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const platform = duckdbPlatformString(resolved);
        const output = addCrossBuild(b, translate_c_dep, duckdb_headers_v1_dep, build_options_mod, extension_name, target_duckdb_version, extension_version, optimize, query);
        const install_cross = b.addInstallFile(output, b.fmt("lib/{s}/{s}.duckdb_extension", .{ platform, extension_name }));
        cross_step.dependOn(&install_cross.step);
    }

    // ── "wasm-ext" step: build the wasm32-emscripten SIDE_MODULE (mvp) ────
    const wasm_ext_output = addWasmEmscriptenBuild(b, translate_c_dep, duckdb_headers_v1_dep, build_options_mod, extension_name, dist_version, extension_version, emcc_path, .mvp);
    const install_wasm_ext = b.addInstallFile(wasm_ext_output, b.fmt("lib/wasm_mvp/{s}.duckdb_extension.wasm", .{extension_name}));
    const wasm_ext_step = b.step("wasm-ext", "Build the wasm32-emscripten SIDE_MODULE, mvp platform (needs a real emcc on PATH or -Demcc-path=; see docs/v2-migration-plan.md's WASM section)");
    wasm_ext_step.dependOn(&install_wasm_ext.step);

    // ── "wasm-ext-coi" step: the threaded/exceptions variant (needs a matching
    // threaded emcc build; the same -Demcc-path= as wasm-ext, just a different
    // emsdk activation) ─────────────────────────────────────────────────────
    const wasm_ext_coi_output = addWasmEmscriptenBuild(b, translate_c_dep, duckdb_headers_v1_dep, build_options_mod, extension_name, dist_version, extension_version, emcc_path, .coi);
    const install_wasm_ext_coi = b.addInstallFile(wasm_ext_coi_output, b.fmt("lib/wasm_threads/{s}.duckdb_extension.wasm", .{extension_name}));
    const wasm_ext_coi_step = b.step("wasm-ext-coi", "Build the wasm32-emscripten SIDE_MODULE, coi (threads+exceptions) platform (needs a real emcc on PATH or -Demcc-path=; see docs/v2-migration-plan.md's WASM section)");
    wasm_ext_coi_step.dependOn(&install_wasm_ext_coi.step);

    // ── "dist" step: arrange and gzip `cross`'s output into the DuckDB
    // custom-extension-repository layout `INSTALL ... FROM '<url>'`
    // expects — replaces the GitHub Actions workflow's old hand-rolled
    // bash (find/gzip) with a build-graph step that's testable locally. ──
    const dist_tool = b.addExecutable(.{
        .name = "dist_main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dist_main.zig"),
            .target = b.graph.host,
        }),
    });
    const dist_run = b.addRunArtifact(dist_tool);
    dist_run.step.dependOn(cross_step);
    dist_run.addArg("zig-out/lib");
    dist_run.addArg("dist");
    dist_run.addArg(extension_name);
    dist_run.addArg(dist_version);
    const dist_step = b.step("dist", "Cross-compile, then arrange and gzip into dist/<dist-version>/<platform>/<name>.duckdb_extension.gz");
    dist_step.dependOn(cross_step);
    dist_step.dependOn(&dist_run.step);

    // ── the v2 extensions (zig_ext_v2 and the cookbook), the same way, under the exact alpha's directory ──
    const cross_v2_step = b.step("cross-v2", "Cross-compile the v2 extensions for every target in cross_targets, into zig-out/lib-v2/<platform>/");
    const dist_v2_step = b.step("dist-v2", "Cross-compile the v2 extensions, then arrange and gzip into dist/<dist-version-v2>/<platform>/<name>.duckdb_extension.gz");
    for (cross_targets) |query| {
        const platform = duckdbPlatformString(b.resolveTargetQuery(query));
        for ([_]V2Extension{ .zig_ext_v2, .zig_ext_cookbook }) |extension| {
            const output = addV2CrossBuild(b, extension, dist_version_v2, extension_version_v2, optimize, query);
            const install = b.addInstallFile(output, b.fmt("lib-v2/{s}/{s}.duckdb_extension", .{ platform, @tagName(extension) }));
            cross_v2_step.dependOn(&install.step);
        }
    }
    // Installs both from dist/ (a file:// repository) into the pinned alpha CLI, after `dist-v2` has made the tree.
    const verify_dist_v2_step = b.step("verify-dist-v2", "Install the v2 extensions from dist/ into the pinned DuckDB alpha and use them (run dist-v2 first)");
    {
        const verify = b.addSystemCommand(&.{"tools/verify_dist_v2.sh"});
        if (duckdb_cli_v2) |cli| verify.addFileArg(cli) else verify.addArg("duckdb");
        verify.addArg("dist");
        verify_dist_v2_step.dependOn(&verify.step);
    }
    for ([_]V2Extension{ .zig_ext_v2, .zig_ext_cookbook }) |extension| {
        const run = b.addRunArtifact(dist_tool);
        run.step.dependOn(cross_v2_step);
        run.addArg("zig-out/lib-v2");
        run.addArg("dist");
        run.addArg(@tagName(extension));
        run.addArg(dist_version_v2);
        dist_v2_step.dependOn(&run.step);
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
        // `zig build dist` produces the whole publishable tree (extensions
        // + docs) in one command, same "testable locally" reasoning as
        // dist_main.zig itself.
        dist_step.dependOn(docs_step);
    }
    {
        const install_docs_v2 = b.addInstallDirectory(.{
            .source_dir = ext_v2_lib.getEmittedDocs(),
            .install_dir = .{ .custom = "docs-v2" },
            .install_subdir = "",
        });
        const docs_v2_step = b.step("docs-v2", "Generate API documentation for the v2 extension");
        docs_v2_step.dependOn(&install_docs_v2.step);
        dist_step.dependOn(docs_v2_step);
    }
    {
        // The GitHub Pages landing page: generated from
        // docs/pages/index.html.tmpl + description.yml (see
        // src/gen_docs_index_main.zig and src/lib/description_yaml.zig's
        // own doc comments) rather than a static file — its own step,
        // same sibling pattern as `docs`/`docs-v2`, so it's independently
        // buildable/testable rather than only ever appearing as a side
        // effect of `zig build dist`.
        const description_yaml_mod = b.createModule(.{
            .root_source_file = b.path("src/lib/description_yaml.zig"),
            .target = target,
            .optimize = optimize,
        });
        const description_yaml_check = b.addTest(.{ .root_module = description_yaml_mod });
        const run_description_yaml_check = b.addRunArtifact(description_yaml_check);
        v2_check_step.dependOn(&run_description_yaml_check.step);

        const gen_docs_index_exe = b.addExecutable(.{
            .name = "gen_docs_index",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gen_docs_index_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        gen_docs_index_exe.root_module.addImport("description_yaml", description_yaml_mod);

        const run_gen_docs_index = b.addRunArtifact(gen_docs_index_exe);
        run_gen_docs_index.addFileArg(b.path("description.yml"));
        run_gen_docs_index.addFileArg(b.path("docs/pages/index.html.tmpl"));
        const generated_index = run_gen_docs_index.addOutputFileArg("index.html");

        const install_docs_index = b.addInstallFile(generated_index, "index.html");
        const docs_index_step = b.step("docs-index", "Generate and install the GitHub Pages landing page");
        docs_index_step.dependOn(&install_docs_index.step);
        dist_step.dependOn(docs_index_step);
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
    lib_unit_tests.root_module.addImport("build_options", build_options_mod);
    lib_unit_tests.root_module.link_libc = true;

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Pure, dependency-free hash-computation logic (no DuckDB import at
    // all) — worth its own test step despite no other `*_main.zig` tool
    // having one: a wrong composite hash here means a silently-wrong
    // extension signature, not a build failure.
    const sign_extension_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sign_extension_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_sign_extension_tests = b.addRunArtifact(sign_extension_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_sign_extension_tests.step);
    test_step.dependOn(&run_v2_static_parity.step);
    test_step.dependOn(&run_v2_dynamic_parity.step);
    test_step.dependOn(&run_v2_helpers_check.step);

    // Installs the signing tool itself — see src/sign_extension_main.zig's
    // own doc comment for usage.
    const sign_extension_exe = b.addExecutable(.{
        .name = "sign_extension",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sign_extension_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_sign_extension = b.addInstallArtifact(sign_extension_exe, .{});
    const sign_extension_step = b.step("sign-extension-tool", "Build the extension-signing tool (zig-out/bin/sign_extension)");
    sign_extension_step.dependOn(&install_sign_extension.step);

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
    {
        const run = b.addRunArtifact(sqllogictest_tool);
        if (duckdb_cli_v2) |cli| run.addFileArg(cli) else run.addArg("duckdb");
        run.addFileArg(ext_cookbook_output);
        run.addFileArg(b.path("test/sql/zig_ext_cookbook.test"));
        run.step.dependOn(&install_ext_cookbook.step);

        const sqllogictest_cookbook_step = b.step("sqllogictest-cookbook", "Run SQL logic tests against the v2 cookbook extension");
        sqllogictest_cookbook_step.dependOn(&run.step);
    }
    {
        // The proof-of-concept extension carries the comptime scalar/table frameworks' broadest
        // coverage (STRUCT, LIST, MAP, UNION, DECIMAL, ENUM, VARIANT, pushdown, ...), which the
        // real extension does not use.
        const run = b.addRunArtifact(sqllogictest_tool);
        if (duckdb_cli_v2) |cli| run.addFileArg(cli) else run.addArg("duckdb");
        run.addFileArg(v2_poc_output);
        run.addFileArg(b.path("test/sql/zig_ext_v2_poc.test"));
        // zig_v2_nethogs_trace spawns the synthetic nethogs the v2-poc step installs.
        run.step.dependOn(&install_fake_nethogs.step);

        const sqllogictest_v2_poc_step = b.step("sqllogictest-v2-poc", "Run SQL logic tests against the v2 proof-of-concept extension (comptime scalar/table frameworks)");
        sqllogictest_v2_poc_step.dependOn(&run.step);
    }
}
