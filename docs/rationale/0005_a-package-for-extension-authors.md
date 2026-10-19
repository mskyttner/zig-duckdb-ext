# 0005 — A package for extension authors

## Status

Proposed. Nothing in this document is implemented. What it says about Zig's package mechanics was read from the 0.17.0
standard library (`std.Build.isRoot`, lazy dependencies, `.paths`); the consumer sketches below were not compiled.

## Context

Everything an author needs to write a DuckDB extension in Zig exists in this repository: generated bindings for the v2 C API
(`src/lib/duckdb_v2_{types,static,dynamic}.zig`, ADR-0007 — generated from DuckDB's own `api_spec/v2`, with a dynamic
and a direct-link static backend selected per build), helpers (`v2_helpers`), comptime frameworks that turn a plain Zig function
into a registered scalar, table, aggregate, cast or appender function, a build that appends the metadata footer, cross-compiles
and packs a repository tree, a SQL test runner, the pinned DuckDB CLI, and a release workflow. None of it can be used without
copying it.

Starting an extension today means forking the repository, or copying about 200 lines of `build.zig` (the module wiring, the
footer, the platform string, the test step) as `docs/creating-an-extension.md` tells the reader to do. A copy goes stale. The
fixes found late reach only those who copy again:

- the footer must be `C_STRUCT_UNSTABLE` with the exact DuckDB version, or an extension built for one alpha loads in another
  and crashes it (found when rehearsing the release);
- the entry point's symbol is derived from the file name, so a renamed copy fails with "did not contain function …";
- `helpers.init` must be the first call of the entry point;
- the functions need `FunctionNamed` / `FunctionDocumented`, or `duckdb_functions()` shows `a0`, `a1`.

Each of these is a rule an author learns by hitting it. The repository's own `build.zig` is 1,699 lines and exports nothing
(`b.addModule` appears nowhere), and `build.zig.zon` lists `translate_c` and both header packages as ordinary, not lazy,
dependencies.

## Decision

Make the repository a Zig package with three parts: **modules** to import, **build functions** to call from a consumer's
`build.zig`, and a **template** that is also the package's own test.

### 1. Modules

Exported with `b.addModule`, under the names the code already imports, so that existing sources need no change:

| Module | What |
|---|---|
| `duckdb_v2_api` | the dynamic bindings (the extension side: functions are fetched through `get_api`) |
| `duckdb_v2_static` | the static bindings (a program that links DuckDB) |
| `v2_helpers` | `init`, `factory`, `str`, `Docs` and `setDocs`, the value and type builders |
| `comptime_scalar_v2`, `comptime_table_v2`, `comptime_aggregate_v2`, `comptime_cast_v2`, `comptime_appender_v2` | the frameworks |

The modules are created for the consumer's target, so `addModule` is not enough on its own: the consumer asks for them through
the build function (below), which creates them per target as `v2Graph` does today.

### 2. Build functions

The package's `build.zig` exports functions; a consumer's `build.zig` calls them after `@import("zig_duckdb_ext")`.

```zig
// consumer's build.zig (a sketch)
const std = @import("std");
const duckdb = @import("zig_duckdb_ext");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zig_duckdb_ext", .{});

    // The library, the footer, the install into zig-out/lib/<name>.duckdb_extension.
    const ext = duckdb.addExtension(b, dep, .{
        .name = "my_ext",
        .version = "v0.1.0",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.getInstallStep().dependOn(ext.install);

    // SQL tests with the right CLI for the pinned DuckDB version.
    const sql = duckdb.addSqlLogicTests(b, dep, .{ .extension = ext, .files = &.{b.path("test/sql/my_ext.test")} });
    b.step("test", "SQL tests").dependOn(sql);

    // Every cross target, packed as dist/<duckdb-version>/<platform>/my_ext.duckdb_extension.gz.
    const dist = duckdb.addDist(b, dep, .{ .name = "my_ext", .version = "v0.1.0", .root_source_file = b.path("src/root.zig"), .optimize = .ReleaseSafe });
    b.step("dist", "Cross-compile and pack the repository tree").dependOn(dist);
}
```

What `addExtension` does, all of it taken from the current `build.zig`:

- creates the bindings, helpers and frameworks for the target, and imports them into the root module as `duckdb_v2_api`,
  `v2_helpers` and `comptime_*_v2`;
- links libc and builds a dynamic library;
- appends the footer (`addDuckdbExtensionMetadata`): the name is the `.name`, the platform string comes from the target, the ABI
  is `C_STRUCT_UNSTABLE` and the DuckDB version is the package's own constant (`v2_duckdb_version`), so an author cannot get
  either wrong, and a pin bump reaches every consumer through the package version;
- returns a struct with the library, the output file and the install step, so tests and `dist` can use them.

`addSqlLogicTests` builds the runner for the host, finds the pinned CLI through the lazy dependency of the package
(`dep.builder.lazyDependency("duckdb_cli_v2_linux_amd64", .{})`, the logic of `duckdbV2CliLazyPath`), and runs one test file
per step with the extension loaded. `addDist` is `cross` plus `dist_main` for the cross targets of the package, with the
target list overridable.

### 3. The entry point

The entry symbol is the other thing that is easy to get wrong, so the package generates it:

```zig
// consumer's src/root.zig (a sketch)
const duckdb = @import("v2_helpers");
const add = @import("add.zig");

comptime {
    duckdb.exportEntryPoint("my_ext", register);
}

fn register(input: *const duckdb.Input) !void {
    try add.register(input); // as today: a Function / FunctionNamed / FunctionDocumented over a plain Zig function
}
```

`exportEntryPoint` exports `my_ext_init_c_api_v2` with `@export` (a comptime-computed name), calls `init` first, and turns a
returned error into what `input.err` carries. The name is checked against the build's `.name` (the build passes it in as a build
option), so the file name, the footer and the symbol cannot disagree.

### 4. What a dependency's `build` runs

`b.dependency("zig_duckdb_ext", .{})` **runs the package's `build` function**, with all its steps. That would configure the docs
generation, the PoC extensions, the embed recipes and every cross target for every consumer, and fetch every non-lazy
dependency. So:

- `build` starts with `if (!b.isRoot()) { register modules and return; }`. Only the repository itself, as the root package, defines
  its own steps. `std.Build.isRoot` is `b.pkg_hash.len == 0`.
- Dependencies that only the repository's own steps use become lazy: `translate_c` (v1 header translation), `duckdb_headers_v1`,
  `duckdb_headers_v2`, `zignal`, `zigcv`, `yaml`, the static libraries. A consumer then fetches the CLI of its host platform
  and nothing else. (Today `translate_c` and both header packages are not lazy.)
- `.paths` lists what a consumer needs and nothing more: `build.zig`, `build.zig.zon`, `build/` (the build functions, moved out
  of the 1,699-line file), `src/lib`, the runner and the two small tools. Not `third_party`, `test`, `tools` or `docs`.

### 5. The template

`examples/hello_ext/` is a small, standalone package with its own `build.zig.zon` that depends on the repository by path, with a
`build.zig` like the sketch above, one function, and one test file. It is the answer to "how do I start": copy that directory. CI
builds it and runs its tests, so it cannot rot, and it is the first consumer of the package, which is how the API gets its
first review.

## What moves

`build.zig` becomes a thin file: `pub const addExtension = @import("build/extension.zig").addExtension;` and so on, then `build`.
`build/extension.zig` takes `addDuckdbExtensionMetadata`, `duckdbPlatformString`, `V2Graph`/`v2Graph`, and the module wiring of
`addV2CrossBuild`. `build/dist.zig` takes `cross_targets` and the `dist` step. `build/sqllogictest.zig` takes the runner step and
the CLI lookup. `build/repo.zig` keeps what only this repository uses (the cookbook, the PoCs, the docs, the embed recipes, the
generator), written with the same functions, so the repository tests the package every time it builds.

## Consequences

- An author depends on the package with `zig fetch --save`, copies a 30-line `build.zig` from the template, and writes functions.
  The rules above are in the package, not in a guide.
- A change to the footer, the pin or the entry rules ships with a package version. Versions should say which DuckDB they are for
  (for example `v0.2.0` for `v2.0.0-alpha48730`), because the v2 API is unstable by version, and a consumer who updates the
  package updates the pin with it. The cost of the port from one alpha to the next stays with the package, not with each author:
  the 177 call sites of the last port were all in this repository.
- The package carries a promise: the names of the modules and the build functions. The bindings follow DuckDB's own names and
  will change with it.
- **Zig is pinned to one version** (0.17.0). A consumer on another cannot use the package; the template and the release
  workflow state it.

## Open questions

- **One package or two?** The bindings and frameworks are useful without the build functions (a host program that embeds DuckDB
  needs the static bindings and no footer). One package keeps the pin in one place; two would let a host skip the CLI. Start with
  one.
- **Windows.** `addDist` cross-compiles to `x86_64-windows-gnu`, which works for the extensions here; the static embed on Windows
  needs MinGW runtime paths (`-Dlibstdcxx-path`) and stays out of the package.
- **Generated documentation.** `docs`/`docs-v2` could be offered as `addDocs`; the landing page generator reads this repository's
  `description.yml`, so it is out of scope for the first version.
- **The release workflow** is reusable as a `workflow_call` workflow (`build`, `verify`, `deploy`) so that a consumer's
  `release.yml` is ten lines; it needs the CLI URL and the DuckDB version as inputs.
- **Does importing a dependency's `build.zig` work with the repository's layout?** It is a common pattern and the mechanics are
  as described here, but it has not been tried with this repository. The template is how to find out; do it first (phase 1).

## Plan

1. **Template first, on the existing build.** Add `examples/hello_ext` as a package that depends on the repository by path and
   uses `b.dependency(...).module(...)` for the modules. Add the `isRoot` early return, make the heavy dependencies lazy and set
   `.paths`. This settles the open question above with the least change.
2. **`addExtension` and `exportEntryPoint`.** Move the footer and platform logic into `build/extension.zig`, use it for the
   repository's own `ext-v2` and `ext-cookbook`, then for the template.
3. **`addSqlLogicTests`**, together with the runner improvements of ADR-0006, which make the failures readable for authors.
4. **`addDist` and the reusable release workflow.**
5. **Version and publish.** Tag the package with the DuckDB version it is for, put `zig fetch --save` and the template in the
   README, and delete the copy-the-build-block instructions from `docs/creating-an-extension.md`.
