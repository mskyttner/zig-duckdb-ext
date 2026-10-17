# Creating an extension: the steps

How to go from nothing to a loadable DuckDB extension in Zig that has a scalar function with real parameter names, how
to check what DuckDB's catalog knows about it, and where the limits are today. Every file named here exists in this
repository; copy from it rather than from the snippets.

Two C APIs are used here (see the README): **v1**, which the stable and LTS DuckDB releases ship, and **v2**, the API of
DuckDB 2.0, pinned to the staged alpha `v2.0.0-alpha48730` (`f8f3f4dcd9`; this repository was on
`v2.0.0-alpha46057`, `b15358c371`, before). New work should go on v2. The steps below are
for v2 and say so where v1 differs.

## 1. A project that builds an extension

An extension is a shared library with a footer of metadata appended (name, version, platform, API version). The build
does both: `addDuckdbExtensionMetadata` in `build.zig` appends the footer. The smallest example to copy is the cookbook
extension (`ext-cookbook`, `build.zig` around `ext_cookbook_lib`):

```zig
const lib = b.addLibrary(.{
    .linkage = .dynamic,
    .name = "my_ext",
    .root_module = b.createModule(.{ .root_source_file = b.path("src/root_my_ext.zig"), .target = target, .optimize = optimize }),
});
lib.root_module.addImport("duckdb_v2_api", duckdb_v2_dynamic_mod); // the generated bindings, dynamic backend
lib.root_module.addImport("v2_helpers", v2_helpers_mod);
lib.root_module.link_libc = true;
const output = addDuckdbExtensionMetadata(b, lib, "my_ext", "v2.0.0", "v0.1.0", "C_STRUCT", duckdbPlatformString(target));
```

The module root (`src/root_cookbook.zig`) only has to reference the file with the entry point.

## 2. The entry point

DuckDB derives the symbol from the file name: `my_ext.duckdb_extension` must export `my_ext_init_c_api_v2`
(`src/ext/init_cookbook.zig`):

```zig
export fn my_ext_init_c_api_v2(input: *const v2.duckdb_v2_extension_input) callconv(.c) void {
    if (!helpers.init(input, "v2.0.0")) return; // fetches the function table; false if DuckDB refuses the version
    my_function.register(input) catch return;   // a failure leaves DuckDB's reason in input.err
}
```

`helpers.init` must be first. A `register` that returns an error has already put the reason into `input.err`, so the
load fails with that text instead of crashing (`task test:load-failure` proves it).

## 3. A function

Two ways, and the difference matters for the catalog (step 5).

**By hand** (`src/functions/hello_v2.zig`): create the function with the extension, name it, take its signature, add
each parameter **with a name**, set the return type, set the exec callback, register.

```zig
v2.duckdb_v2_scalar_function_create_with_extension(input.extension, &function, err)
v2.duckdb_v2_scalar_function_set_name(function, &name, err)
v2.duckdb_v2_scalar_function_get_signature(function, &sig, err)
v2.duckdb_v2_function_signature_add_parameter(sig, &param_name, type, null, .FUNCTION_PARAMETER_KIND_STANDARD, err)
v2.duckdb_v2_function_signature_set_return_type(sig, type, err)
v2.duckdb_v2_scalar_function_set_exec_callback(function, &exec, err)
v2.duckdb_v2_scalar_function_register(function, err)
```

The exec callback gets whole vectors: flatten the argument, read it through a view, check the validity mask for NULLs,
write the result vector (`hello_v2.zig`, and `scalar_callbacks.zig` for bind, init and user data). Errors are a code and
a text on the callback's `err`. The error slot a call is given must be one DuckDB handed you (see `embed_sql.zig` for
the trap with your own).

**By comptime** (`src/functions/ct_add_numbers_v2.zig`, 8 lines): write the per-row function in plain Zig and let the
framework generate the vectorized callback, NULL handling and registration.

```zig
fn add(a: i64, b: i64) !i64 { return std.math.add(i64, a, b); }   // an error is an error of the query
const CtAddNumbers = comptime_scalar_v2.FunctionNamed("ct_add_numbers", add, &.{ "a", "b" });
pub fn register(input: *const v2.duckdb_v2_extension_input) !void { return CtAddNumbers.register(input); }
```

Use `FunctionNamed`, not `Function`: Zig function parameters carry no names at the ABI, so `Function` invents `a0`, `a1`.
`FunctionNamed` exists in `comptime_scalar_v2`, `comptime_table_v2` and `comptime_aggregate_v2`, and a wrong number of
names is a compile error.

Table, aggregate, cast, `COPY`, custom type and the rest: one recipe each, listed in `docs/cookbook.md`.

## 4. Tests

SQL logic tests run the real extension in the pinned DuckDB CLI. Add a `.test` file (`test/sql/zig_ext_cookbook.test` is
the model: `query`, `statement ok`, `statement error` blocks), a `sqllogictest-*` step in `build.zig` next to
`sqllogictest-cookbook`, and a task. `task check:all` does not run them; CI does (`.github/workflows/ci.yml`). Test an
error with `statement error` and a fragment of the message. Compare against an oracle that is not your code (DuckDB's own
function, `EXCEPT` both ways) rather than a value you computed by hand.

## 5. Check what the catalog says

```sql
LOAD 'zig-out/lib/my_ext.duckdb_extension';
SELECT function_name, parameters, parameter_types, return_type, description, examples
FROM duckdb_functions() WHERE function_name = 'ct_add_numbers';
```

| Column | v2, by hand | v2, `FunctionNamed` | v2, `Function` | v1, plain |
|---|---|---|---|---|
| `parameters` | the names you gave | the names you gave | `[a0, a1]` | `[col0, col1]` |
| `parameter_types`, `return_type` | filled | filled | filled | filled |
| `description`, `examples` | empty unless set (step 6) | empty unless set (step 6) | empty unless set (step 6) | empty (no API) |

In v1 a function gets real names only through a **macro wrapper**: register the function as `tp_bar_impl` and then run
`CREATE OR REPLACE MACRO tp_bar(value, "on" := ..., width := 15) AS tp_bar_impl(value, "on", "off", width)`
(`src/functions/tp_bar.zig`). That gives names and defaults, but `parameter_types` is NULL for a macro. v2 extensions
cannot run SQL at load time, so the wrapper is v1 only, and unnecessary in v2.

## 6. Descriptions and examples

`description`, `examples` and `categories` in `duckdb_functions()` need the function docs calls, which exist from
`v2.0.0-alpha48730` (`f8f3f4dcd9`) on. The earlier pinned alpha (`v2.0.0-alpha46057`) has none, and v1 never had any:
there every function shows an empty description. `COMMENT ON FUNCTION` does not help either: it works on macros only
("Can not comment on System Catalog entries" for a registered function).

For a scalar, aggregate, table, pragma or macro function:

```c
duckdb_v2_scalar_function_get_docs(function, &docs, err);               // borrowed; never destroyed
duckdb_v2_function_docs_set_description(docs, &description, err);      // replaces an earlier one
duckdb_v2_function_docs_add_example(docs, &title_or_null, &example, err); // in the order added
duckdb_v2_function_docs_add_category(docs, &category, err);             // e.g. "string", "aggregate"
```

The docs describe one overload and are registered with the function.

**In this repository:** `helpers.Docs` and `helpers.setDocs` wrap the calls, and

```zig
const CtAddNumbers = comptime_scalar_v2.FunctionDocumented("ct_add_numbers", add, &.{ "a", "b" }, .{
    .description = "Adds two BIGINT values. Overflow is an error of the query.",
    .examples = &.{
        .{ .title = "Two numbers", .sql = "SELECT ct_add_numbers(40, 2);" },
        .{ .sql = "SELECT ct_add_numbers(i, 1) FROM range(3) t(i);" },
    },
    .categories = &.{"numeric"},
});
```

registers the function with them; a hand-written function calls `get_docs` and `setDocs` before it registers
(`src/functions/hello_v2.zig`). The result, tested in `test/sql/zig_ext_v2.test`:

```
function_name  | parameters | description                                                 | examples                                                                       | categories
ct_add_numbers | [a, b]     | Adds two BIGINT values. Overflow is an error of the query.  | ['SELECT ct_add_numbers(40, 2);', 'SELECT ct_add_numbers(i, 1) FROM range(3)...'] | [numeric]
```

Notes:

- The example's **title is not shown**: `examples` holds only the example text. Where a title surfaces, if anywhere, I did
  not find.
- Only the scalar framework has `FunctionDocumented` so far. Table and aggregate functions have the same `get_docs` call
  (not tried), but their frameworks do not take docs yet.
- A standalone spike in C against that alpha's headers is in `docs/spikes/function_docs_alpha48730.c`.

### Moving from the earlier alpha

`v2.0.0-alpha48730` is not a drop-in replacement: it renames and restructures much of the API. The port was:

- `*_create_with_extension` / `_with_connection` / `_with_context` become `*_create(factory, ...)`, and
  `*_register` becomes `duckdb_v2_extension_register_*(extension, function, err)`. The factory comes from
  `duckdb_v2_context_get_factory` (or `connection_get_factory`); `helpers.factory(context, err)` wraps it;
- `value_create_*_with_context` / `_with_connection` become `value_create_*(factory, ...)`, and `value_cast` and
  `data_chunk_create` / `_copy` take a factory too;
- type creation moves to the factory: `duckdb_v2_factory_create_type_from_id`, `_from_text`, `_from_name`;
- options become a `config` (`duckdb_v2_context_get_config`, `config_get_option_value`, `config_get_option_by_index`):
  the value comes back typed (cast it to VARCHAR to show it), and an option's scope is now its **default scope**
  (`GLOBAL` or `SESSION`) instead of the old target scope;
- `file_system_get_from_context` becomes `context_get_file_system`, and the file system gains `path_exists`, `path_glob`,
  `path_expand`, `path_remove`, `path_move` and `path_is_remote`;
- `instance_attach` takes `(instance, name, path, options, make_default, err)`: name and path swapped places;
- new: log sinks, macro and pragma function registration, custom options, `copy_function_set_file_extension`.

Error texts changed in places too (`qname_parse` of an empty string now says "Zero-length identifier").

## 7. Package and publish

- `zig build dist` cross-compiles the v1 extension for every target in `cross_targets` and arranges
  `dist/<duckdb-version>/<platform>/<name>.duckdb_extension.gz`; `zig build dist-v2` does the same for the v2 extensions
  (`zig_ext_v2` and the cookbook) under `dist/v2.0.0-alpha48730/…`. `.github/workflows/release.yml` builds both, installs
  the v2 ones in the alpha CLI (`tools/verify_dist_v2.sh`), and publishes the tree to GitHub Pages on a `v*` tag. Users
  then `INSTALL zig_ext_v2 FROM 'https://<owner>.github.io/<repo>/'` with `allow_unsigned_extensions`
  (`docs/rationale/0004_extension-distribution-and-signing.md` says why it is unsigned). Rehearse it locally with
  `task dist:v2` and `task verify:dist-v2`, which install from a `file://` repository.
- The repository directory must match the DuckDB version of the client that installs, not the extension's API version.
  A v1.5.6 client looks in `v1.5.6/`, the alpha in `v2.0.0-alpha48730/`.
- **A v2 extension must say which DuckDB it is for.** The v2 API is only guaranteed for one exact version. The footer of
  `zig_ext_v2` and the cookbook is `C_STRUCT_UNSTABLE` with that version (`v2_duckdb_version` in `build.zig`; it moves with
  the pin). With `C_STRUCT` and `v2.0.0`, which is what this repository used at first, an extension built for alpha48730
  *loaded in alpha46057 and crashed it* (a segmentation fault). With `C_STRUCT_UNSTABLE` that DuckDB refuses it: "The file
  was built specifically for DuckDB version 'v2.0.0-alpha48730' and can only be loaded with that version of DuckDB".
- The entry point is found by the **file name**: `zig_ext_v2.duckdb_extension` must export `zig_ext_v2_init_c_api_v2`, so a
  copy under another name (`unstable.duckdb_extension`) fails with "did not contain function …".
- `description.yml` at the repository root is **not** per-function documentation. It is the extension-level descriptor in
  the format of DuckDB's community-extensions program (name, version, license, maintainers, a `hello_world` example).
  This repository does not submit there; the file feeds the landing page (`zig build docs-index`). Its functions'
  signatures come from `duckdb_functions()`, which has the prose of step 6 for the functions that set it.

## Where to go next

`docs/cookbook.md` for the capability you need, `docs/api-v2-coverage.md` for what the API has that no code here uses,
`docs/v2-migration-plan.md` for how the v1 code was ported and why.
