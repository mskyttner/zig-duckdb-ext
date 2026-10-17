# Creating an extension: the steps

How to go from nothing to a loadable DuckDB extension in Zig that has a scalar function with real parameter names, how
to check what DuckDB's catalog knows about it, and where the limits are today. Every file named here exists in this
repository; copy from it rather than from the snippets.

Two C APIs are used here (see the README): **v1**, which the stable and LTS DuckDB releases ship, and **v2**, the API of
DuckDB 2.0, pinned to the staged alpha `v2.0.0-alpha46057` (`b15358c371`). New work should go on v2. The steps below are
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
| `description`, `examples` | empty | empty | empty | empty |

In v1 a function gets real names only through a **macro wrapper**: register the function as `tp_bar_impl` and then run
`CREATE OR REPLACE MACRO tp_bar(value, "on" := ..., width := 15) AS tp_bar_impl(value, "on", "off", width)`
(`src/functions/tp_bar.zig`). That gives names and defaults, but `parameter_types` is NULL for a macro. v2 extensions
cannot run SQL at load time, so the wrapper is v1 only, and unnecessary in v2.

## 6. Descriptions and examples: not with the pinned API, yes with a newer alpha

`description` and `examples` in `duckdb_functions()` are **empty for every function in this repository**, because the
pinned alpha (`v2.0.0-alpha46057`) has no call to set them, and v1 never had one. `COMMENT ON FUNCTION` does not help
either: it works on macros only ("Can not comment on System Catalog entries" for a registered function).

The staged alpha **`v2.0.0-alpha48730` (`f8f3f4dcd9`)**, from the "cyanoptera" staging channel
(`https://artifacts.duckdb.org/staged/v2.0-cyanoptera/`), has the API. For a
scalar, aggregate, table, pragma or macro function:

```c
duckdb_v2_scalar_function_get_docs(function, &docs, err);               // borrowed; never destroyed
duckdb_v2_function_docs_set_description(docs, &description, err);      // replaces an earlier one
duckdb_v2_function_docs_add_example(docs, &title_or_null, &example, err); // in the order added
duckdb_v2_function_docs_add_category(docs, &category, err);             // e.g. "string", "aggregate"
```

The docs describe one overload and are registered with the function.

**Verified with a spike** (`docs/spikes/function_docs_alpha48730.c`, in C against that alpha's headers, loaded in its
CLI): a scalar function `spike_add(left_operand BIGINT, right_operand BIGINT)` that calls the four functions above gives

```
function_name | parameters                    | parameter_types   | return_type | description             | examples                                                                  | categories
spike_add     | [left_operand, right_operand] | [BIGINT, BIGINT] | BIGINT      | Adds two BIGINT values. | ['SELECT spike_add(40, 2);', 'SELECT spike_add(i, 1) FROM range(3) t(i);'] | [numeric]
```

and the function computes (`SELECT spike_add(40, 2)` is 42). Notes from it:

- `description`, `examples` and `categories` are all filled, and the examples keep the order they were added in.
- The example's **title is not shown**: `examples` holds only the example text. Where a title surfaces, if anywhere, I did
  not find.
- The footer for this alpha was `C_STRUCT` with `v2.0.0`, built by this repository's own `append_metadata` tool, and it
  loads without changes.
- The entry point is the header's `DUCKDB_EXTENSION_ENTRYPOINT` macro, which gives the extension handle, the context and
  the error slot as arguments instead of the `duckdb_v2_extension_input` struct that the pinned alpha's entry point takes.
- Only a scalar function was tried. The same call exists for aggregate, table, pragma and macro functions; I did not test
  those.

That alpha is **not a drop-in replacement for the pinned one**. Moving the pin means regenerating the bindings
(`zig build gen-v2-bindings`) and porting every call site, because it renames and restructures much of the API:

- `*_create_with_extension` / `_with_connection` become `*_create`, and `*_register` becomes
  `duckdb_v2_extension_register_*` (or `duckdb_v2_connection_register_*`);
- `value_create_*_with_context` / `_with_connection` become `value_create_*`;
- type creation moves to a `factory` (`duckdb_v2_context_get_factory`, `duckdb_v2_factory_create_type_from_id`, ...);
- options become `config` (`duckdb_v2_context_get_config`, `config_get_option_*`);
- `file_system_get_from_*` becomes `context_get_file_system`, and gains `path_exists`, `path_glob`, `path_expand`,
  `path_remove`, `path_move` and `path_is_remote`, which the pinned alpha lacks;
- new: log sinks, macro and pragma function registration, custom options, `copy_function_set_file_extension`.

When the pin moves, the place for docs is the registration helper: `FunctionNamed` would take a description and examples
next to the names, and the by-hand recipes would call `get_docs` right after `create`.

## 7. Package and publish

- `zig build dist` cross-compiles for every target in `cross_targets` and arranges
  `dist/<duckdb-version>/<platform>/<name>.duckdb_extension.gz`; `.github/workflows/release.yml` publishes that tree to
  GitHub Pages on a `v*` tag. Users then `INSTALL my_ext FROM 'https://<owner>.github.io/<repo>/'` with
  `allow_unsigned_extensions` (`docs/rationale/0004_extension-distribution-and-signing.md` says why it is unsigned).
- The repository directory must match the DuckDB version of the client that installs, not the extension's API version.
- `description.yml` at the repository root is **not** per-function documentation. It is the extension-level descriptor in
  the format of DuckDB's community-extensions program (name, version, license, maintainers, a `hello_world` example).
  This repository does not submit there; the file feeds the landing page (`zig build docs-index`). Its functions'
  signatures come from `duckdb_functions()` and, until step 6 is done, have no prose.

## Where to go next

`docs/cookbook.md` for the capability you need, `docs/api-v2-coverage.md` for what the API has that no code here uses,
`docs/v2-migration-plan.md` for how the v1 code was ported and why.
