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
| Aggregate callbacks: bind (result type), bind data, user data, properties | — | `cookbook/aggregate_callbacks.zig`: `zig_cookbook_agg_sum` / `_sumsq` (one set of callbacks, user data = the power), `zig_cookbook_agg_last` (order dependent) | `AGG_ORDER_DEPENDENT` and `AGG_DISTINCT_DEPENDENT`: what the planner does with `ORDER BY` and `DISTINCT` inside the call. |
| Parallel table function: global and local state, threads, output order | — | `cookbook/table_callbacks.zig`: `zig_cookbook_parallel_range` | `init_global` (max threads), `init_local` (a worker's state), `partition_data` (batch index), user data = block size. Without the partition data callback the rows stay in order but one worker produces them. |
| A custom `COPY` format | — | `cookbook/copy_format.zig`: `FORMAT zig_cookbook_lines` (`DELIMITER`, `HEADER`, `NULL_TEXT`), both `COPY ... TO` and `COPY ... FROM` | TO: bind, batch size, init, batch (prepares, in parallel), flush (writes, serial), finalize. FROM: bind (the table's columns), init_global, exec (an empty chunk ends the read), progress. Values travel as text through DuckDB's own cast, so every type works. |
| **File system** | — | `cookbook/file_system.zig`: `zig_cookbook_fs_read(path, start := 0, length := -1)` and `zig_cookbook_fs_write(path, content, mode := 'create', start := 0)` | A file opened through DuckDB's file system (a borrowed handle from the context; options with flags; `file_system_open`), not libc, so the path goes where the engine would send it: `file:` URLs, `~`, and remote or virtual file systems. `file_read` and `file_write` move the position and may be short (loop until zero); `file_read_at` and `file_write_at` take an offset and are all-or-error. The four write modes are flag combinations (`CREATE_NEW` truncates, `APPEND`, `CREATE` + `EXCLUSIVE_CREATE`, `PARALLEL_ACCESS` for offset writes). The effect of the writer happens in exec, not bind. There is no listing, existence or delete call in the API. |
| Arrow **C Data Interface** | — | `cookbook/arrow_c_data.zig`: `zig_cookbook_arrow_export(n)` and `zig_cookbook_arrow_import(n, copy := false)`; `embed_sql.zig` for `arrow_result_*` | Export: DuckDB chunks go to an `arrow_exporter`, which hands back `ArrowArray`s of a fixed batch size; the recipe reads their buffers (validity bitmap, offsets, bits) in Zig and reports them. Import: Zig builds an `ArrowSchema` and an `ArrowArray` from its own buffers, an `arrow_importer` turns them into chunks (zero-copy when the array is consumed, copied otherwise), and the importer's schema names the result columns. The rules for a producer of the structs (`release` once, children with the parent) are in the file header; a test counts live arrays to see every one released once. |
| `COPY` with a **library** doing the format | — | `cookbook/arrow_ipc.zig`: `FORMAT zig_cookbook_arrow_ipc` (`CODEC 'none'\|'lz4'\|'zstd'`), `COPY ... TO` and `COPY ... FROM`, and the table function `zig_cookbook_read_arrow(path)`, with [gld-arrow-zig](../third_party/gld-arrow-zig/PATCHES.md) (pure Zig, vendored) | The same callbacks as the line above; the recipe is the **seam** between DuckDB vectors and Arrow buffers: validity bits plus a flat array (booleans as bits, strings as offsets plus bytes), one copy per column. A `COPY ... TO` batch is prepared in parallel into column buffers, flushed into one record batch each, and the stream is encoded in finalize. Columns: BOOLEAN, 8 to 64-bit integers, FLOAT, DOUBLE, DATE, TIMESTAMP, VARCHAR; anything else fails at planning, naming the column. Reading takes a stream or a file and LZ4; the file's columns must match the table's by position and type (nothing is cast). The table function shares the decode and the chunk filling, and `bind` takes the result columns' names and types from the file's schema. |
| Running SQL: parse, execute, prepared statements, results | — | `cookbook/embed_sql.zig`, `zig build cookbook-embed` (needs the static libraries): a program that **embeds** DuckDB | Environment, instance, connection; `parse_sql`; lazy results read by chunk; positional and named parameters; prepared statements; error codes; one live result per connection. **Not available to an extension**: see below. |
| A custom type with casts | — | `cookbook/custom_type.zig`: `zig_cookbook_celsius` (a name bound to DOUBLE), its four casts (VARCHAR, DOUBLE, one implicit), `zig_cookbook_to_fahrenheit` / `_from_fahrenheit` | `custom_type_*` registers the name and base type; the type is created for signatures by lookup (`context_create_type_from_name`) or from the base type (`..._with_alias`); casts honour `TRY_CAST`; the implicit cost lets a value go where its base type is expected. |
| Appender, building a result set | — | `lib/comptime_appender_v2.zig`, `zig_v2_appender_*_test`, `zig_v2_nethogs_trace` (PoC) | |
| Replacement scan | — | `zig_v2_range_<N>`, the braille demo (PoC) | `SELECT * FROM zig_v2_range_5`. |

## Building, shipping, embedding

| Capability | v1 | v2 | Notes |
|---|---|---|---|
| Loadable `.duckdb_extension` | `zig build ext` | `zig build ext-v2` | Metadata footer, `description.yml`. |
| Cross-compiling | `zig build cross`, `task verify:cross-arm64` | same targets | One host builds every platform. |
| SQL tests | `task sqllogictest` | `task sqllogictest:v2`, `sqllogictest:v2:poc` | |
| Static linking into a host program | — | `v2-static-embed-poc`, `-extensions` (Linux), the same with `-Dtarget=x86_64-windows-gnu`; `task verify:static-windows` | The v2 bindings come in a dynamic (`get_api` table) and a static (direct `extern`) backend. |

## Error slots

A call that can fail takes an `err` slot. On failure it **fills in the error info it finds in the slot** (and allocates one only
if the slot is NULL), so the slot you pass must start as NULL or hold a live info: an uninitialised one is written through at the
first failure and crashes the process. The slots DuckDB gives an extension (a callback's `err`, the entry point's `input.err`) are
live, so pass those on, as the frameworks' `register` functions now do (`zig build load-failure-v2` loads an extension whose
registration fails and checks that the load fails with the reason; with an uninitialised local slot it crashed). A program that
embeds DuckDB owns its slots and starts them empty (`cookbook/embed_sql.zig`, `Call`).

## What is not shown yet

Taken from the generated coverage report. In the order I would write the recipes:

1. ~~Extension settings~~ — done as *reading* configuration (`cookbook/config_options.zig`). The `configuration` module is
   read-only, and **the v2 C API has no call to register an option of your own** (extension options exist only for C++
   extensions), so a setting for an extension written against the C API is not possible yet.
2. ~~Bind-time and resolve-types callbacks, `user_data`, properties~~ — done for scalar functions
   (`cookbook/scalar_callbacks.zig`), aggregate functions (`cookbook/aggregate_callbacks.zig`) and parallel table
   functions (`cookbook/table_callbacks.zig`). Still open in `function/table`: projection and partitioning-column
   callbacks, `table_function_partitioning`, and the unstable batch-claiming and multi-file functions.
3. ~~A `COPY` format~~ — done (`cookbook/copy_format.zig`), with the C library for files. Left in `function/copy`: the
   unstable `RETURN_STATS` statistics callback, and reading and writing through DuckDB's file system (so that remote
   paths work), which belongs to the `filesystem` recipe.
4. ~~Running SQL~~ — done for a program that **embeds** DuckDB (`cookbook/embed_sql.zig`). **An extension cannot do it with
   the v2 C API as pinned:** every query function (`parse_sql`, `statement_execute`, `prepared_statement_create`, ...)
   takes a *connection*, an extension is handed only an extension handle and a *context*, and no call turns a context
   into a connection (nor yields the instance to create one from). Settings, values, types and the file system are what
   a context is for.
5. ~~Custom types~~ — done (`cookbook/custom_type.zig`).
6. ~~Arrow files~~ — done as a `COPY` format over a library (`cookbook/arrow_ipc.zig`). Arrow through the C Data Interface is
   done too (`cookbook/arrow_c_data.zig`: an exporter and an importer made from a context, with hand-built `ArrowSchema`
   and `ArrowArray` structs and their `release` rules; `arrow_result_*` needs a connection, so it is in `embed_sql.zig`).
   Filesystem access is done too (`cookbook/file_system.zig`). Still open: **logging**, **tokenizing and parsing SQL**.

   Limits of the vendored library (gld-arrow-zig 0.2.0), found while testing the recipe against PyArrow: its Zstd **decoder**
   fails (`Compression`) on most frames PyArrow writes, for example 200 or more integers (it reads LZ4, and its own Zstd);
   its Zstd **encoder** stores blocks uncompressed, valid but no smaller; it builds and reads whole streams, with no
   incremental writer; dictionary-encoded columns are read as dictionaries, which the recipe rejects rather than expands.
   Patches for Zig 0.17 are listed in `third_party/gld-arrow-zig/PATCHES.md`.

Before writing any of these, check in the report that the function is in the pinned alpha's table (an *unstable*
function is only present in a build with `DUCKDB_V2_API_ALLOW_UNSTABLE`), then write its SQL test, then the example.
