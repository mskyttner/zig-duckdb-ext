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
| **Macros** | — (v1 wrapped a function in `CREATE MACRO`: `functions/tp_bar.zig`) | `cookbook/macros.zig`: `zig_cookbook_clamp(x, lo := 0, hi := 1)` (scalar macro) and `zig_cookbook_squares(n := 5)` (table macro) | A macro is SQL text with parameters, registered without running any SQL: `macro_function_create` (scalar or table), `set_name`, `set_body`, parameters through `get_signature` (type ANY is untyped, a default makes a parameter optional, named or by position), `get_docs`, `extension_register_macro_function`. One overload only; the body is parsed at registration and resolved when called. In the catalog: `function_type` `macro` / `table_macro`, `macro_definition`. |
| **Function documentation** | — (v1 has no way) | `helpers.Docs` / `helpers.setDocs`; `FunctionDocumented` in `comptime_scalar_v2`, `comptime_table_v2` and `comptime_aggregate_v2`; `get_docs` by hand for all nine functions of `zig_ext_v2`, for the cookbook's table, aggregate and macro functions | `get_docs` exists for scalar, aggregate, table, pragma and macro functions: a description, examples (the title is kept but `duckdb_functions().examples` lists only the SQL) and categories, shown by `duckdb_functions()`. The tests check that the examples run. |
| **Table function: filter, projection and partitioning pushdown** | — | `cookbook/table_pushdown.zig`: `zig_cookbook_range(n)` and `zig_cookbook_range_stats()` | Filter pushdown: the callback is offered the predicates, recognizes `value`/`bucket` compared with a BIGINT constant (a bucket bound becomes a value bound), narrows the range in the bind data and `accept`s them; everything else (BETWEEN, `square`, `OR`, `IN`, other constant types) stays with the engine. Projection: `set_projection_pushdown` and `exec_get_column_index`, so only the columns a query uses are computed. Partitioning: `set_partitioning_callback` claims `TABLE_PARTITION_INFO_SINGLE_VALUE_PARTITIONS` for `GROUP BY bucket` (a `PARTITIONED_AGGREGATE`), `set_partition_data_callback` reports each batch's bucket with its batch index. Every claim is a promise; the stats function shows from SQL what was offered, accepted and produced. |
| **SQL text**: identifiers, qualified names, UTF-8 | — | `cookbook/names.zig`: `zig_cookbook_quote_ident`, `_qname_render`, `_qname_equals`, `_qname_hash`, `_qname_parts`, `_is_utf8` | The calls that work on text alone, so they run in an extension: `identifier_render_quoted` (quotes only when needed), `qname_parse` / `_render` / `_equals` / `_hash` / `_get_part` (one to three parts, equality is case-insensitive in every part), `validate_utf8` (bytes, so a BLOB can fail where a VARCHAR cannot). The render calls are the two-call pattern: a NULL buffer reports the length, then a buffer of length + 1. **Tokenizer and parser are not callable from an extension**: `tokenize_sql` and `parse_sql` take a connection, so they are shown in `embed_sql.zig` (token classes and offsets, unterminated input; statement kind, text and parameters without binding). |
| **Logging** | — | `cookbook/logging.zig`: `zig_cookbook_log(level, log_type, message)` | One call, `context_log`, with the context of an exec. It always succeeds and writes only if the database's log configuration takes the entry (logging on, level at or above `logging_level`); the extension cannot ask whether anyone listens. Entries have scope CONNECTION with the connection's ids and are read from `duckdb_logs`. A custom `log_type` is recorded, but `enable_logging('my_type')` rejects it, so it is filtered in SQL. The function is VOLATILE, or DuckDB folds constant calls. |
| **File system** | — | `cookbook/file_system.zig`: `zig_cookbook_fs_read(path, start := 0, length := -1)` and `zig_cookbook_fs_write(path, content, mode := 'create', start := 0)` | A file opened through DuckDB's file system (a borrowed handle from the context; options with flags; `file_system_open`), not libc, so the path goes where the engine would send it: `file:` URLs, `~`, and remote or virtual file systems. `file_read` and `file_write` move the position and may be short (loop until zero); `file_read_at` and `file_write_at` take an offset and are all-or-error. The four write modes are flag combinations (`CREATE_NEW` truncates, `APPEND`, `CREATE` + `EXCLUSIVE_CREATE`, `PARALLEL_ACCESS` for offset writes). The effect of the writer happens in exec, not bind. `v2.0.0-alpha48730` has `path_exists`, `path_glob`, `path_remove` and more, which this recipe does not use yet (the earlier alpha had none). |
| Arrow **C Data Interface** | — | `cookbook/arrow_c_data.zig`: `zig_cookbook_arrow_export(n)` and `zig_cookbook_arrow_import(n, copy := false)`; `embed_sql.zig` for `arrow_result_*` | Export: DuckDB chunks go to an `arrow_exporter`, which hands back `ArrowArray`s of a fixed batch size; the recipe reads their buffers (validity bitmap, offsets, bits) in Zig and reports them. Import: Zig builds an `ArrowSchema` and an `ArrowArray` from its own buffers, an `arrow_importer` turns them into chunks (zero-copy when the array is consumed, copied otherwise), and the importer's schema names the result columns. The rules for a producer of the structs (`release` once, children with the parent) are in the file header; a test counts live arrays to see every one released once. |
| `COPY` with a **library** doing the format | — | `cookbook/arrow_ipc.zig`: `FORMAT zig_cookbook_arrow_ipc` (`CODEC 'none'\|'lz4'\|'zstd'`), `COPY ... TO` and `COPY ... FROM`, and the table function `zig_cookbook_read_arrow(path)`, with [gld-arrow-zig](../third_party/gld-arrow-zig/PATCHES.md) (pure Zig, vendored) | The same callbacks as the line above; the recipe is the **seam** between DuckDB vectors and Arrow buffers: validity bits plus a flat array (booleans as bits, strings as offsets plus bytes), one copy per column. A `COPY ... TO` batch is prepared in parallel into column buffers, flushed into one record batch each, and the stream is encoded in finalize. Columns: BOOLEAN, 8 to 64-bit integers, FLOAT, DOUBLE, DATE, TIMESTAMP, VARCHAR; anything else fails at planning, naming the column. Reading takes a stream or a file and LZ4; the file's columns must match the table's by position and type (nothing is cast). The table function shares the decode and the chunk filling, and `bind` takes the result columns' names and types from the file's schema. |
| Running SQL: parse, execute, prepared statements, results | — | `cookbook/embed_sql.zig`, `zig build cookbook-embed` (needs the static libraries): a program that **embeds** DuckDB | Environment, instance, connection; `parse_sql`; lazy results read by chunk; positional and named parameters; prepared statements; error codes; one live result per connection. **Not available to an extension**: see below. |
| **Instances, attach, the catalog** | — | `cookbook/embed_instance.zig`, `zig build cookbook-embed-instance` (needs the static libraries) | Host side, like running SQL: an extension is never given an instance, a connection or an environment. `environment_get_instance_count` (and `environment_destroy`, refused while one is alive); `instance_create_with_options` (startup options as SQL `SET` writes them; an unknown name or an option that needs a running instance fails the creation); `instance_attach` (the name derived from the path up to its first dot, `attach_options` as the `(KEY value)` of `ATTACH`, a path attached once per environment), `instance_set_default` (for connections made afterwards) and `instance_detach` (the default can go too); `connection_describe_table` (the resolved name, read-only catalog, every column's name, type, default and generated flags; a snapshot that outlives the table; views and unknown names are the engine's errors). |
| **Documentation audit** of an instance | — | the same file, `audit`: loads `zig_ext_v2` and the cookbook from their files (the `loadable_extensions` capability, registered like any static extension, and the `allow_unsigned_extensions` startup option) | Counts, per extension of the instance (`duckdb_functions().extension_name`, a path for a file), the functions that are described, have examples, have categories, and have `col0`/`a0` parameter names; prints the table for the whole instance (core_functions: 1709 functions, 1705 described), then **requires 100%** for the two extensions and **runs every example** of theirs. A new function without docs fails the build. |
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
   Filesystem access is done too (`cookbook/file_system.zig`). Logging is done too (`cookbook/logging.zig`), and so are tokenizing and parsing SQL: `tokenize_sql` and `parse_sql` need a connection, so they are in the embedding recipe (`embed_sql.zig`), and the connection-free name calls are in `cookbook/names.zig`. The matrix and this list have no open item left.

   Limits of the vendored library (gld-arrow-zig 0.2.0), found while testing the recipe against PyArrow: its Zstd **decoder**
   fails (`Compression`) on most frames PyArrow writes, for example 200 or more integers (it reads LZ4, and its own Zstd);
   its Zstd **encoder** stores blocks uncompressed, valid but no smaller; it builds and reads whole streams, with no
   incremental writer; dictionary-encoded columns are read as dictionaries, which the recipe rejects rather than expands.
   Patches for Zig 0.17 are listed in `third_party/gld-arrow-zig/PATCHES.md`.

Before writing any of these, check in the report that the function is in the pinned alpha's table (an *unstable*
function is only present in a build with `DUCKDB_V2_API_ALLOW_UNSTABLE`), then write its SQL test, then the example.
