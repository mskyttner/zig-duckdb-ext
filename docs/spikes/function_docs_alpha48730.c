// A spike, not part of the build: do the function-docs calls of DuckDB v2.0.0-alpha48730 (f8f3f4dcd9) fill
// `description`, `examples` and `categories` in duckdb_functions()? They do (see docs/creating-an-extension.md, step 6).
//
// Written in C against that alpha's own headers, because this repository's generated bindings are for the pinned
// alpha (v2.0.0-alpha46057), which has no docs API. To repeat it:
//
//   1. Download https://artifacts.duckdb.org/staged/v2.0-cyanoptera/duckdb-cli-linux-amd64.tar.gz (a redirect to
//      duckdb-staging.duckdb.org/f8f3f4dcd9/v2.0.0-alpha48730/...) and, next to it, .../libduckdb-src.zip, which has
//      duckdb_v2.h and duckdb_extension_v2.h. Unpack each into its own directory.
//   2. zig cc -shared -fPIC -O1 -Wall -I <headers> -o spike_docs.so function_docs_alpha48730.c
//   3. Append the footer with this repository's tool (src/append_metadata_main.zig, built by `zig build ext`):
//      append_metadata_zig_ext spike_docs.so spike_docs v2.0.0 v0.0.1 C_STRUCT linux_amd64 spike_docs.duckdb_extension
//   4. duckdb -unsigned -c "LOAD 'spike_docs.duckdb_extension'; SELECT * FROM duckdb_functions() WHERE function_name = 'spike_add';"
//
#define DUCKDB_EXTENSION_NAME spike_docs
#include "duckdb_extension_v2.h"
#include <string.h>

DUCKDB_EXTENSION_EXTERN

#define STR(s) ((duckdb_v2_str) {(s), strlen(s)})

static void add_exec(duckdb_v2_scalar_function_exec_info_handle info, duckdb_v2_context_handle context,
                     duckdb_v2_error_info_handle *err) {
	(void)context;
	idx_t rows = 0;
	if (duckdb_v2_scalar_function_exec_get_row_count(info, &rows, err) != DUCKDB_V2_ERROR_NONE) return;
	duckdb_v2_vector_handle a, b, out;
	duckdb_v2_vector_view va, vb;
	if (duckdb_v2_scalar_function_exec_get_arg(info, 0, &a, err) != DUCKDB_V2_ERROR_NONE) return;
	if (duckdb_v2_scalar_function_exec_get_arg(info, 1, &b, err) != DUCKDB_V2_ERROR_NONE) return;
	if (duckdb_v2_vector_flatten(a, err) != DUCKDB_V2_ERROR_NONE) return;
	if (duckdb_v2_vector_flatten(b, err) != DUCKDB_V2_ERROR_NONE) return;
	if (duckdb_v2_vector_get_view(a, &va, err) != DUCKDB_V2_ERROR_NONE) return;
	if (duckdb_v2_vector_get_view(b, &vb, err) != DUCKDB_V2_ERROR_NONE) return;
	if (duckdb_v2_scalar_function_exec_get_result(info, &out, err) != DUCKDB_V2_ERROR_NONE) return;
	if (duckdb_v2_vector_set_size(out, rows, err) != DUCKDB_V2_ERROR_NONE) return;
	void *data = NULL;
	if (duckdb_v2_vector_get_data_mutable(out, &data, err) != DUCKDB_V2_ERROR_NONE) return;
	const int64_t *x = (const int64_t *)va.data, *y = (const int64_t *)vb.data;
	int64_t *z = (int64_t *)data;
	for (idx_t i = 0; i < rows; i++) z[i] = x[i] + y[i]; // a spike: no NULL or overflow handling
}

#define TRY(call) do { if ((call) != DUCKDB_V2_ERROR_NONE) return; } while (0)

DUCKDB_EXTENSION_ENTRYPOINT(duckdb_v2_extension_handle extension, duckdb_v2_context_handle context,
                            duckdb_v2_error_info_handle *err) {
	duckdb_v2_factory_handle factory;
	TRY(duckdb_v2_context_get_factory(context, &factory, err));
	duckdb_v2_logical_type_handle bigint;
	TRY(duckdb_v2_factory_create_type_from_id(factory, DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, NULL, NULL, 0, &bigint, err));

	duckdb_v2_scalar_function_handle fn;
	TRY(duckdb_v2_scalar_function_create(factory, &fn, err));
	duckdb_v2_str name = STR("spike_add");
	TRY(duckdb_v2_scalar_function_set_name(fn, &name, err));

	duckdb_v2_function_signature_handle sig;
	TRY(duckdb_v2_scalar_function_get_signature(fn, &sig, err));
	duckdb_v2_str pa = STR("left_operand"), pb = STR("right_operand");
	TRY(duckdb_v2_function_signature_add_parameter(sig, &pa, bigint, NULL, DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, err));
	TRY(duckdb_v2_function_signature_add_parameter(sig, &pb, bigint, NULL, DUCKDB_V2_FUNCTION_PARAMETER_KIND_STANDARD, err));
	TRY(duckdb_v2_function_signature_set_return_type(sig, bigint, err));

	// The point of the spike.
	duckdb_v2_function_docs_handle docs;
	TRY(duckdb_v2_scalar_function_get_docs(fn, &docs, err));
	duckdb_v2_str description = STR("Adds two BIGINT values.");
	TRY(duckdb_v2_function_docs_set_description(docs, &description, err));
	duckdb_v2_str title1 = STR("Two numbers"), ex1 = STR("SELECT spike_add(40, 2);");
	TRY(duckdb_v2_function_docs_add_example(docs, &title1, &ex1, err));
	duckdb_v2_str ex2 = STR("SELECT spike_add(i, 1) FROM range(3) t(i);");
	TRY(duckdb_v2_function_docs_add_example(docs, NULL, &ex2, err));
	duckdb_v2_str cat = STR("numeric");
	TRY(duckdb_v2_function_docs_add_category(docs, &cat, err));

	TRY(duckdb_v2_scalar_function_set_exec_callback(fn, add_exec, err));
	TRY(duckdb_v2_extension_register_scalar_function(extension, fn, err));
	duckdb_v2_scalar_function_destroy(&fn);
	duckdb_v2_logical_type_destroy(&bigint);
}
