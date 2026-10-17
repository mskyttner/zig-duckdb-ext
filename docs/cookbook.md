# Capability matrix: where each part of the DuckDB C API is shown

One row per capability, with where this repository demonstrates it for the **v1** C API (the one the stable /
LTS DuckDB releases ship) and for the **v2** C API (DuckDB 2.0). A dash means "not shown here", **not** "absent from
that API". Paths are relative to `src/`. `ct_*` and the `comptime_*` files are the comptime frameworks, which turn a
plain Zig function into a registered DuckDB function; the other files call the C API directly.

For what the v2 API offers beyond this table, see the generated [v2 coverage report](api-v2-coverage.md): it lists, per
spec module, every function that no code here references yet. `task coverage:api-v2` rewrites it and `check:all` fails
if it is stale, so the gaps below are measured, not remembered.

## Functions

| Capability | v1 (stable) | v2 | Notes |
|---|---|---|---|
| Scalar function, raw vectors | `functions/hello.zig`, `functions/add_numbers.zig` | `functions/hello_v2.zig`, `functions/add_numbers_v2.zig` | The smallest complete examples. v2 `hello` is written against the generated bindings. |
| Scalar function, comptime | `functions/ct_add_numbers.zig`, `lib/comptime_scalar.zig` | `functions/ct_add_numbers_v2.zig`, `lib/comptime_scalar_v2.zig` | One line of per-row Zig. |
| NULL handling | validity masks in `add_numbers.zig` | same, `v2_helpers.isValid`; special handling in `zig_v2_variant_default_ct` (PoC) | |
| Errors from a function | `add_numbers.zig`, `ct_add_numbers.zig` (overflow) | `add_numbers_v2.zig`; `E!T` returns: `ct_add_numbers_v2.zig`, `zig_v2_checked_div_ct`, `zig_v2_first_word_ct` (PoC) | |
| Named parameters, defaults | `functions/tp_bar.zig` (a SQL macro wraps it) | `functions/tp_bar_v2.zig` (native) | v1 cannot express them on a function. |
| VARCHAR, BLOB | `hello.zig` | `hello_v2.zig`, `zig_v2_blob_prefix_ct`, `zig_v2_first_word_ct` | |
| LIST, ARRAY arguments | `functions/tp_line.zig`, `tp_treemap.zig`, `tp_snakemap.zig` | the same `_v2` files, `zig_v2_list_*_ct`, `zig_v2_array_scale3_ct` | |
| STRUCT, MAP, UNION | — | `zig_v2_point_*_ct`, `zig_v2_person_*_ct`, `zig_v2_map_*_ct`, `zig_v2_union_*_ct` (PoC) | |
| DECIMAL, ENUM, dates and intervals | — | `zig_v2_apply_tax_ct`, `zig_v2_next_mood_ct`, `zig_v2_timestamp_add_ct` (PoC) | |
| VARIANT | — | `zig_v2_variant_default_ct` (PoC) | |
| Table function | `functions/tokenize.zig`, `functions/ct_tokenize.zig` | `functions/tokenize_v2.zig`, `functions/ct_tokenize_v2.zig`, `zig_v2_range3` (PoC) | bind, init, exec; several output columns. |
| Table function, pushdown and progress | — | `zig_v2_range_pushdown_ct`, `zig_v2_project_ct`, `zig_v2_range_progress_ct` (PoC) | The progress callback is wired; its reported value is not asserted by a test. |
| Aggregate function | — | `zig_v2_agg_sum`, `zig_v2_agg_sum_ct`, `zig_v2_weighted_avg_*`, `zig_v2_string_agg_ct`, `zig_v2_arg_max_ct` (PoC), `lib/comptime_aggregate_v2.zig` | State, update, combine, finalize; a SIMD batch path. |
| Cast function | — | `lib/comptime_cast_v2.zig`; casts registered in `ext/init_v2_poc.zig` | Including `TRY_CAST`. |
| Reading DuckDB's configuration | — | `cookbook/config_options.zig`: `zig_cookbook_option`, `zig_cookbook_options` (with aliases) | Options through the context (scalar `exec`) and a bind-time snapshot (table function). Read-only: see below. |
| Scalar callbacks: resolve types, bind, init, user data, properties | — | `cookbook/scalar_callbacks.zig`: `zig_cookbook_negate` (result type follows the argument), `_round_to` (a constant argument read at bind), `_times2/3/10` (user data), `_row_number` (per-thread init data, `VOLATILE`) | The four callbacks in the order they run, and what each hands to the next. |
| Appender, building a result set | — | `lib/comptime_appender_v2.zig`, `zig_v2_appender_*_test`, `zig_v2_nethogs_trace` (PoC) | |
| Replacement scan | — | `zig_v2_range_<N>`, the braille demo (PoC) | `SELECT * FROM zig_v2_range_5`. |

## Building, shipping, embedding

| Capability | v1 | v2 | Notes |
|---|---|---|---|
| Loadable `.duckdb_extension` | `zig build ext` | `zig build ext-v2` | Metadata footer, `description.yml`. |
| Cross-compiling | `zig build cross`, `task verify:cross-arm64` | same targets | One host builds every platform. |
| SQL tests | `task sqllogictest` | `task sqllogictest:v2`, `sqllogictest:v2:poc` | |
| Static linking into a host program | — | `v2-static-embed-poc`, `-extensions` (Linux), the same with `-Dtarget=x86_64-windows-gnu`; `task verify:static-windows` | The v2 bindings come in a dynamic (`get_api` table) and a static (direct `extern`) backend. |

## What is not shown yet

Taken from the generated coverage report. In the order I would write the recipes:

1. ~~Extension settings~~ — done as *reading* configuration (`cookbook/config_options.zig`). The `configuration` module is
   read-only, and **the v2 C API has no call to register an option of your own** (extension options exist only for C++
   extensions), so a setting for an extension written against the C API is not possible yet.
2. ~~Bind-time and resolve-types callbacks, `user_data`, properties for scalar functions~~ — done
   (`cookbook/scalar_callbacks.zig`). Still open: the same for **aggregate functions** (`function/aggregate`: bind
   callback, properties) and **table-function local state and partition data** (`function/table`).
3. **A `COPY` format** (`function/copy`, 78 functions).
4. **Running SQL from an extension**: connection, prepared statements, result chunks (`connection`,
   `prepared_statement`, `query_result`).
5. **Custom types** (`logical_type/custom_type`), **filesystem** access, **Arrow** import and export, **logging**,
   **tokenizing and parsing SQL**.

Before writing any of these, check in the report that the function is in the pinned alpha's table (an *unstable*
function is only present in a build with `DUCKDB_V2_API_ALLOW_UNSTABLE`), then write its SQL test, then the example.
