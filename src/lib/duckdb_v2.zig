///! Zig bindings for the DuckDB v2 C Extension API (staged, unreleased —
///! see docs/rationale for the v1→v2 comparison that motivated this).
///!
///! v2 is a from-scratch, separately namespaced API (`duckdb_v2_*`), not an
///! extension of v1: every call returns a `DUCKDB_V2_ERROR` code and writes
///! its result through an out-parameter, instead of v1's mix of
///! return-value-is-the-result and return-value-is-a-status-enum styles.
///!
///! This file is a work-in-progress vertical slice (instance/connection
///! lifecycle + minimal scalar function registration) proving the binding
///! pattern against the real v2 header, not yet the full port of
///! `duckdb.zig`'s 74 wrapped functions. Not wired into the extension build
///! yet — see the `v2-check` build step, which only type-checks this file.
const std = @import("std");
pub const c = @import("duckdb_c_v2");

// ─── Re-export opaque handle types ───────────────────────────────────────────

pub const ExtensionHandle = c.duckdb_v2_extension_handle;
pub const ContextHandle = c.duckdb_v2_context_handle;
pub const ErrorInfoHandle = c.duckdb_v2_error_info_handle;
pub const InstanceHandle = c.duckdb_v2_instance_handle;
pub const ConnectionHandle = c.duckdb_v2_connection_handle;
pub const EnvironmentHandle = c.duckdb_v2_environment_handle;
pub const ScalarFunctionHandle = c.duckdb_v2_scalar_function_handle;
pub const ScalarFunctionExecInfoHandle = c.duckdb_v2_scalar_function_exec_info_handle;
pub const FunctionSignatureHandle = c.duckdb_v2_function_signature_handle;
pub const LogicalTypeHandle = c.duckdb_v2_logical_type_handle;
pub const ValueHandle = c.duckdb_v2_value_handle;
pub const VectorHandle = c.duckdb_v2_vector_handle;
pub const IdentifierT = c.duckdb_v2_identifier_t;
pub const DataChunkHandle = c.duckdb_v2_data_chunk_handle;
pub const TableFunctionHandle = c.duckdb_v2_table_function_handle;
pub const TableFunctionBindInfoHandle = c.duckdb_v2_table_function_bind_info_handle;
pub const FunctionBindInfoHandle = c.duckdb_v2_function_bind_info_handle;
pub const TableFunctionInitGlobalInfoHandle = c.duckdb_v2_table_function_init_global_info_handle;
pub const TableFunctionExecInfoHandle = c.duckdb_v2_table_function_exec_info_handle;
pub const AggregateFunctionHandle = c.duckdb_v2_aggregate_function_handle;
pub const AggregateFunctionSizeInfoHandle = c.duckdb_v2_aggregate_function_size_info_handle;
pub const AggregateFunctionInitInfoHandle = c.duckdb_v2_aggregate_function_init_info_handle;
pub const AggregateFunctionUpdateInfoHandle = c.duckdb_v2_aggregate_function_update_info_handle;
pub const AggregateFunctionCombineInfoHandle = c.duckdb_v2_aggregate_function_combine_info_handle;
pub const AggregateFunctionFinalizeInfoHandle = c.duckdb_v2_aggregate_function_finalize_info_handle;
pub const AggregateFunctionDestroyInfoHandle = c.duckdb_v2_aggregate_function_destroy_info_handle;
pub const ColumnDataCollectionHandle = c.duckdb_v2_column_data_collection_handle;
pub const ColumnDataCollectionAppendStateHandle = c.duckdb_v2_column_data_collection_append_state_handle;
pub const ExpressionHandle = c.duckdb_v2_expression_handle;
pub const TableFunctionFilterPushdownInfoHandle = c.duckdb_v2_table_function_filter_pushdown_info_handle;

// ─── Re-export enums / structs ────────────────────────────────────────────────

pub const ErrorCode = c.DUCKDB_V2_ERROR;
pub const ParameterKind = c.DUCKDB_V2_FUNCTION_PARAMETER_KIND;
pub const LogicalTypeId = c.DUCKDB_V2_LOGICAL_TYPE_ID;
pub const ExtensionInput = c.duckdb_v2_extension_input;
pub const VectorView = c.duckdb_v2_vector_view;
pub const ListEntry = c.duckdb_v2_list_entry;
pub const ScalarFunctionExecCallback = c.duckdb_v2_scalar_function_exec_callback_fn;
pub const TableFunctionFilterPushdownCallback = c.duckdb_v2_table_function_filter_pushdown_callback_fn;
pub const ExpressionType = c.DUCKDB_V2_EXPRESSION_TYPE;
pub const CastMode = c.DUCKDB_V2_CAST_MODE;
pub const idx_t = c.idx_t;

// ─── Extension API singleton ─────────────────────────────────────────────────
//
// Mirrors the v1 pattern in duckdb.zig: copy the vtable by value since
// DuckDB may free the memory `get_api` returned after the entrypoint
// returns.

const ExtApiV2 = c.duckdb_ext_api_v2;

var api_storage: ExtApiV2 = std.mem.zeroes(ExtApiV2);
var api_initialized: bool = false;

/// Initialize the v2 extension API from the entrypoint's `duckdb_v2_extension_input`.
/// Must be called before any other function in this file. Returns false if the
/// API version is incompatible (mirrors the `DUCKDB_EXTENSION_API_INIT` macro).
pub fn initApi(input: *const ExtensionInput, minimum_api_version: [*:0]const u8) bool {
    const get_api = input.get_api orelse return false;
    const raw = get_api(input.extension, minimum_api_version);
    if (raw == null) return false;
    // SAFETY: get_api returns a pointer to the duckdb_ext_api_v2 vtable when the version matches.
    const res: *const ExtApiV2 = @ptrCast(@alignCast(raw));
    api_storage = res.*;
    api_initialized = true;
    return true;
}

fn getApi() *const ExtApiV2 {
    // Invariant: initApi must be called before any API wrapper, by the extension
    // entry point, as its first step. A panic here is a programming error, not
    // a runtime user error.
    if (!api_initialized) @panic("DuckDB v2 Extension API not initialized — call initApi first");
    return &api_storage;
}

// ─── Wrapped API functions ──────────────────────────────────────────────────
//
// Vertical slice only: instance/connection lifecycle plus enough of the
// scalar-function + signature calls to register one named-parameter scalar
// function end to end. More to follow mechanically once this pattern is
// confirmed against a real v2 runtime.

// --- Instance / Connection ---

pub fn instanceCreate(env: EnvironmentHandle, out_instance: *InstanceHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_instance_create.?(env, out_instance, err);
}

pub fn instanceDestroy(instance: *InstanceHandle) ErrorCode {
    return getApi().duckdb_v2_instance_destroy.?(instance);
}

pub fn connectionCreate(instance: InstanceHandle, out_conn: *ConnectionHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_connection_create.?(instance, out_conn, err);
}

pub fn connectionDestroy(conn: *ConnectionHandle) ErrorCode {
    return getApi().duckdb_v2_connection_destroy.?(conn);
}

// --- Scalar Function ---

pub fn scalarFunctionCreateWithConnection(
    connection: ConnectionHandle,
    out_function: *ScalarFunctionHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_scalar_function_create_with_connection.?(connection, out_function, err);
}

pub fn scalarFunctionCreateWithExtension(
    extension: ExtensionHandle,
    out_function: *ScalarFunctionHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_scalar_function_create_with_extension.?(extension, out_function, err);
}

pub fn scalarFunctionDestroy(function: *ScalarFunctionHandle) ErrorCode {
    return getApi().duckdb_v2_scalar_function_destroy.?(function);
}

pub fn scalarFunctionSetName(function: ScalarFunctionHandle, name: *const IdentifierT, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_scalar_function_set_name.?(function, name, err);
}

pub fn scalarFunctionGetSignature(
    function: ScalarFunctionHandle,
    out_sig: *FunctionSignatureHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_scalar_function_get_signature.?(function, out_sig, err);
}

pub fn scalarFunctionRegister(function: ScalarFunctionHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_scalar_function_register.?(function, err);
}

// --- Table Function ---
//
// Minimal slice: create/name/register plus the bind → init_global → exec
// callback trio, enough for a fixed-arity, non-parallel table function.
// No parameter/filter-pushdown/partitioning/local-state wrappers yet.

pub fn tableFunctionCreateWithExtension(
    extension: ExtensionHandle,
    out_function: *TableFunctionHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_create_with_extension.?(extension, out_function, err);
}

pub fn tableFunctionDestroy(function: *TableFunctionHandle) ErrorCode {
    return getApi().duckdb_v2_table_function_destroy.?(function);
}

pub fn tableFunctionSetName(function: TableFunctionHandle, name: *const IdentifierT, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_table_function_set_name.?(function, name, err);
}

pub fn tableFunctionGetSignature(
    function: TableFunctionHandle,
    out_sig: *FunctionSignatureHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_get_signature.?(function, out_sig, err);
}

pub fn tableFunctionRegister(function: TableFunctionHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_table_function_register.?(function, err);
}

pub fn tableFunctionSetBindCallback(
    function: TableFunctionHandle,
    callback: c.duckdb_v2_table_function_bind_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_set_bind_callback.?(function, callback, err);
}

pub fn tableFunctionSetInitGlobalCallback(
    function: TableFunctionHandle,
    callback: c.duckdb_v2_table_function_init_global_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_set_init_global_callback.?(function, callback, err);
}

pub fn tableFunctionSetExecCallback(
    function: TableFunctionHandle,
    callback: c.duckdb_v2_table_function_exec_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_set_exec_callback.?(function, callback, err);
}

/// Called during optimization, after bind and before any init callback,
/// with the filter predicates the query applies to this function's rows
/// (AND-combined; see `tableFunctionFilterPushdownGetFilterCount`'s doc
/// comment). Accept a predicate via `tableFunctionFilterPushdownAccept` to
/// promise the scan filters it itself — DuckDB then stops applying it
/// above the scan; anything left unaccepted it keeps applying as a safety
/// net, so a callback that recognizes nothing can simply return. May be
/// called more than once per query, each time with only the
/// not-yet-accepted predicates; never called when there are none.
pub fn tableFunctionSetFilterPushdownCallback(
    function: TableFunctionHandle,
    callback: TableFunctionFilterPushdownCallback,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_set_filter_pushdown_callback.?(function, callback, err);
}

// --- Table Function Filter Pushdown ---

/// The bind data set via `functionBindSetBindData` — the same object
/// `init`/`exec` later receive, so a predicate accepted here can be
/// recorded in it for the scan to apply.
pub fn tableFunctionFilterPushdownGetBindData(
    info: TableFunctionFilterPushdownInfoHandle,
    out_data: *?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_filter_pushdown_get_bind_data.?(info, out_data, err);
}

/// Number of AND-combined predicates offered. Valid indices for
/// `tableFunctionFilterPushdownGetFilter`/`Accept` are `0..count`.
pub fn tableFunctionFilterPushdownGetFilterCount(
    info: TableFunctionFilterPushdownInfoHandle,
    out_count: *idx_t,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_filter_pushdown_get_filter_count.?(info, out_count, err);
}

/// The predicate at `index`, as a BOOLEAN-typed bound expression —
/// inspect it with the `expression*` functions. Borrowed; valid only for
/// the duration of the filter-pushdown callback.
pub fn tableFunctionFilterPushdownGetFilter(
    info: TableFunctionFilterPushdownInfoHandle,
    index: idx_t,
    out_filter: *ExpressionHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_filter_pushdown_get_filter.?(info, index, out_filter, err);
}

/// Promise the scan will apply the predicate at `index` itself — see
/// `tableFunctionSetFilterPushdownCallback`'s doc comment on what
/// accepting means.
pub fn tableFunctionFilterPushdownAccept(
    info: TableFunctionFilterPushdownInfoHandle,
    index: idx_t,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_filter_pushdown_accept.?(info, index, err);
}

/// Number of columns a `BOUND_COLUMN_REF` node inside a predicate may
/// index into (see `tableFunctionFilterPushdownGetColumnIndex`).
pub fn tableFunctionFilterPushdownGetColumnCount(
    info: TableFunctionFilterPushdownInfoHandle,
    out_count: *idx_t,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_filter_pushdown_get_column_count.?(info, out_count, err);
}

/// Resolve the index a `BOUND_COLUMN_REF` node reports
/// (`expressionColumnRefGetIndex`) to the index of the column among the
/// ones declared via `tableFunctionBindAddResultColumn`, in declaration
/// order — a column reference's own index counts the columns the query
/// reads, not necessarily every declared column.
pub fn tableFunctionFilterPushdownGetColumnIndex(
    info: TableFunctionFilterPushdownInfoHandle,
    index: idx_t,
    out_column_index: *idx_t,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_filter_pushdown_get_column_index.?(info, index, out_column_index, err);
}

// --- Expression ---
//
// Read-only introspection of a bound expression tree. Every handle here
// (including every child borrowed via `expressionGetChild`) is owned by
// the engine and valid only for the duration of the callback that handed
// it out — never stash one, only values decoded out of it. In this v2
// alpha, the only producer of `ExpressionHandle`s anywhere in the header
// is table-function filter pushdown, above.

pub fn expressionGetType(expression: ExpressionHandle, out_type: *ExpressionType, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_expression_get_type.?(expression, out_type, err);
}

/// The logical type the expression evaluates to (the target type, for a
/// cast). Caller-owned; destroy via `logicalTypeDestroy`.
pub fn expressionGetReturnType(
    expression: ExpressionHandle,
    out_type: *LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_expression_get_return_type.?(expression, out_type, err);
}

/// Works for every node type, including `EXPRESSION_TYPE_INVALID`.
/// Constants, parameters, and column references have no children.
pub fn expressionGetChildCount(expression: ExpressionHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_expression_get_child_count.?(expression, out_count, err);
}

/// Children are ordered as the node's `ExpressionType` describes. Borrowed;
/// shares its parent's lifetime.
pub fn expressionGetChild(
    expression: ExpressionHandle,
    index: idx_t,
    out_child: *ExpressionHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_expression_get_child.?(expression, index, out_child, err);
}

/// Fails unless `expression` is `EXPRESSION_TYPE_VALUE_CONSTANT`.
/// Caller-owned; destroy via `valueDestroy`.
pub fn expressionConstantGetValue(
    expression: ExpressionHandle,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_expression_constant_get_value.?(expression, out_value, err);
}

/// Fails unless `expression` is `EXPRESSION_TYPE_BOUND_COLUMN_REF`. The
/// index counts the columns of whatever operator the predicate is
/// evaluated against — resolve it through
/// `tableFunctionFilterPushdownGetColumnIndex` for a table-function filter.
pub fn expressionColumnRefGetIndex(
    expression: ExpressionHandle,
    out_index: *idx_t,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_expression_column_ref_get_index.?(expression, out_index, err);
}

/// The name of the scalar function a `BOUND_FUNCTION` node (or a
/// comparison/`BETWEEN`/cast, which are function calls underneath) calls.
/// Borrowed; shares the node's lifetime.
pub fn expressionFunctionGetName(
    expression: ExpressionHandle,
    out_name: *IdentifierT,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_expression_function_get_name.?(expression, out_name, err);
}

/// Fails unless `expression` is `EXPRESSION_TYPE_OPERATOR_CAST`.
pub fn expressionCastGetMode(expression: ExpressionHandle, out_mode: *CastMode, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_expression_cast_get_mode.?(expression, out_mode, err);
}

// --- Table Function bind/init/exec info ---

pub fn tableFunctionBindAddResultColumn(
    info: TableFunctionBindInfoHandle,
    name: *const IdentifierT,
    column_type: LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_bind_add_result_column.?(info, name, column_type, err);
}

/// Read the value of a table/scalar/aggregate function argument at bind
/// time. The generic `FunctionBindInfoHandle` (not the table-specific
/// `TableFunctionBindInfoHandle` used to declare output columns) is the
/// first parameter DuckDB hands every bind callback.
pub fn functionBindGetArgValue(
    info: FunctionBindInfoHandle,
    index: idx_t,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_function_bind_get_arg_value.?(info, index, out_value, err);
}

/// Set the bind-time data a table function's exec callback will read back
/// via `tableFunctionExecGetBindData`. Boxed through `Opaque` the same way
/// `tableFunctionInitGlobalSetGlobalState` is, for the same reason: v2
/// frees it via the box's own `destroy` callback, not a separate hook.
pub fn functionBindSetBindData(info: FunctionBindInfoHandle, data: *Opaque, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_function_bind_set_bind_data.?(info, data, err);
}

pub fn tableFunctionExecGetBindData(
    info: TableFunctionExecInfoHandle,
    out_data: *?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_exec_get_bind_data.?(info, out_data, err);
}

pub fn tableFunctionBindSetCardinality(
    info: TableFunctionBindInfoHandle,
    cardinality: idx_t,
    is_exact: bool,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_bind_set_cardinality.?(info, cardinality, is_exact, err);
}

/// Unlike `exec_get_global_state`'s raw `void*` out-param, *setting* global
/// state requires wrapping it in a `duckdb_v2_opaque` — `{ ptr, destroy,
/// equals }` — so DuckDB can free it itself when the query ends. This is
/// v2's destructor mechanism for per-query state; it's bundled into the
/// opaque box rather than a separate vtable call the way v1 handles deletion.
pub const Opaque = c.duckdb_v2_opaque;

pub fn tableFunctionInitGlobalSetGlobalState(
    info: TableFunctionInitGlobalInfoHandle,
    data: *Opaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_init_global_set_global_state.?(info, data, err);
}

pub fn tableFunctionExecGetGlobalState(
    info: TableFunctionExecInfoHandle,
    out_data: *?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_exec_get_global_state.?(info, out_data, err);
}

pub fn tableFunctionExecGetOutputChunk(
    info: TableFunctionExecInfoHandle,
    out_chunk: *DataChunkHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_exec_get_output_chunk.?(info, out_chunk, err);
}

// --- Data Chunk ---

pub fn dataChunkGetVector(
    chunk: DataChunkHandle,
    index: idx_t,
    out_vector: *VectorHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_data_chunk_get_vector.?(chunk, index, out_vector, err);
}

/// Allocate a fresh, standalone `DataChunk` typed by `types`. Unlike
/// `tableFunctionExecGetOutputChunk`'s borrowed, DuckDB-owned chunk, this one
/// is caller-owned — needed by anything that builds rows itself instead of
/// being handed a chunk to fill (e.g. a bulk-insert/appender helper). Must be
/// released with `dataChunkDestroy`.
pub fn dataChunkCreateWithConnection(
    conn: ConnectionHandle,
    types: []const LogicalTypeHandle,
    out_chunk: *DataChunkHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_data_chunk_create_with_connection.?(conn, types.ptr, types.len, out_chunk, err);
}

/// Context-based counterpart to `dataChunkCreateWithConnection` — the one
/// actually usable from inside a function callback, which is handed a
/// `ContextHandle`, never a `ConnectionHandle` (see `connectionCreateTypeFromId`).
pub fn dataChunkCreateWithContext(
    ctx: ContextHandle,
    types: []const LogicalTypeHandle,
    out_chunk: *DataChunkHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_data_chunk_create_with_context.?(ctx, types.ptr, types.len, out_chunk, err);
}

pub fn dataChunkDestroy(chunk: *DataChunkHandle) ErrorCode {
    return getApi().duckdb_v2_data_chunk_destroy.?(chunk);
}

pub fn dataChunkGetSize(chunk: DataChunkHandle, out_size: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_data_chunk_get_size.?(chunk, out_size, err);
}

// NOTE: `duckdb_v2_data_chunk_get_capacity` exists in the header but is
// gated behind `#if DUCKDB_V2_API_ALLOW_UNSTABLE` (not defined by this
// build's translate-c invocation), so it isn't in the compiled vtable —
// callers that need a chunk's capacity use the same hand-pinned
// `max_rows_per_batch = 2048` constant `comptime_table_v2.zig` already
// relies on (DuckDB's standard vector size) instead of querying it.

// --- Column Data Collection ---
//
// v2's bulk-insert primitive — there is no `duckdb_v2_appender_*` family at
// all (v1's row-based Appender, `duckdb_appender_create` +
// `duckdb_append_*`, has no v2 equivalent). Build rows into a `DataChunk`
// yourself, then hand whole chunks to a `ColumnDataCollection` via `append`.
// See `comptime_appender_v2.zig` for the batching helper built on top of
// this and `dataChunkCreateWithConnection`.

pub fn columnDataCollectionCreateWithConnection(
    conn: ConnectionHandle,
    types: []const LogicalTypeHandle,
    out_collection: *ColumnDataCollectionHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_create_with_connection.?(conn, types.ptr, types.len, out_collection, err);
}

/// Context-based counterpart to `columnDataCollectionCreateWithConnection`
/// (see `dataChunkCreateWithContext`'s doc comment on why this is the one
/// actually usable from inside a function callback).
pub fn columnDataCollectionCreateWithContext(
    ctx: ContextHandle,
    types: []const LogicalTypeHandle,
    out_collection: *ColumnDataCollectionHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_create_with_context.?(ctx, types.ptr, types.len, out_collection, err);
}

pub fn columnDataCollectionDestroy(collection: *ColumnDataCollectionHandle) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_destroy.?(collection);
}

pub fn columnDataCollectionAppendStateCreate(
    collection: ColumnDataCollectionHandle,
    out_state: *ColumnDataCollectionAppendStateHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_append_state_create.?(collection, out_state, err);
}

pub fn columnDataCollectionAppendStateDestroy(state: *ColumnDataCollectionAppendStateHandle) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_append_state_destroy.?(state);
}

/// Append `chunk`'s current rows (per its own vector sizes, not its
/// capacity) into `collection`. Assumed to copy — `chunk` is caller-owned
/// and reused across calls by `comptime_appender_v2.zig` — unconfirmed
/// against a live v2 build; verify before relying on reusing `chunk`
/// after this call.
pub fn columnDataCollectionAppend(
    collection: ColumnDataCollectionHandle,
    state: ColumnDataCollectionAppendStateHandle,
    chunk: DataChunkHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_append.?(collection, state, chunk, err);
}

pub fn columnDataCollectionRowCount(
    collection: ColumnDataCollectionHandle,
    out_row_count: *idx_t,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_row_count.?(collection, out_row_count, err);
}

pub const ColumnDataCollectionSharedScanStateHandle = c.duckdb_v2_column_data_collection_shared_scan_state_handle;
pub const ColumnDataCollectionWorkerScanStateHandle = c.duckdb_v2_column_data_collection_worker_scan_state_handle;

pub fn columnDataCollectionSharedScanStateCreate(
    collection: ColumnDataCollectionHandle,
    out_state: *ColumnDataCollectionSharedScanStateHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_shared_scan_state_create.?(collection, out_state, err);
}

pub fn columnDataCollectionSharedScanStateDestroy(state: *ColumnDataCollectionSharedScanStateHandle) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_shared_scan_state_destroy.?(state);
}

pub fn columnDataCollectionWorkerScanStateCreate(
    collection: ColumnDataCollectionHandle,
    out_state: *ColumnDataCollectionWorkerScanStateHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_worker_scan_state_create.?(collection, out_state, err);
}

pub fn columnDataCollectionWorkerScanStateDestroy(state: *ColumnDataCollectionWorkerScanStateHandle) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_worker_scan_state_destroy.?(state);
}

/// Scan the next chunk's worth of rows out of `collection` into `out_chunk`
/// (caller-owned, typed to match the collection — e.g. via
/// `dataChunkCreateWithContext`). `did_produce_chunk` is false once the scan
/// is exhausted; `out_chunk`'s contents are then undefined.
pub fn columnDataCollectionScan(
    collection: ColumnDataCollectionHandle,
    shared_state: ColumnDataCollectionSharedScanStateHandle,
    worker_state: ColumnDataCollectionWorkerScanStateHandle,
    out_chunk: DataChunkHandle,
    did_produce_chunk: *bool,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_column_data_collection_scan.?(collection, shared_state, worker_state, out_chunk, did_produce_chunk, err);
}

// --- Aggregate Function ---
//
// v2 aggregates are vectorized/batched at every stage, unlike v1's one-row,
// one-state model: update/combine/finalize each hand the callback an ARRAY
// of state pointers (one per row or per group) to process together. size,
// init, update, combine, and finalize must all be set before registration
// (per the header's own doc comments) — only bind and destroy are optional.

pub fn aggregateFunctionCreateWithExtension(
    extension: ExtensionHandle,
    out_function: *AggregateFunctionHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_create_with_extension.?(extension, out_function, err);
}

pub fn aggregateFunctionDestroy(function: *AggregateFunctionHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_destroy.?(function);
}

pub fn aggregateFunctionSetName(function: AggregateFunctionHandle, name: *const IdentifierT, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_set_name.?(function, name, err);
}

pub fn aggregateFunctionGetSignature(
    function: AggregateFunctionHandle,
    out_sig: *FunctionSignatureHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_get_signature.?(function, out_sig, err);
}

pub fn aggregateFunctionRegister(function: AggregateFunctionHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_register.?(function, err);
}

pub fn aggregateFunctionSetSizeCallback(
    function: AggregateFunctionHandle,
    callback: c.duckdb_v2_aggregate_function_size_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_set_size_callback.?(function, callback, err);
}

pub fn aggregateFunctionSetInitCallback(
    function: AggregateFunctionHandle,
    callback: c.duckdb_v2_aggregate_function_init_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_set_init_callback.?(function, callback, err);
}

pub fn aggregateFunctionSetUpdateCallback(
    function: AggregateFunctionHandle,
    callback: c.duckdb_v2_aggregate_function_update_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_set_update_callback.?(function, callback, err);
}

pub fn aggregateFunctionSetCombineCallback(
    function: AggregateFunctionHandle,
    callback: c.duckdb_v2_aggregate_function_combine_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_set_combine_callback.?(function, callback, err);
}

pub fn aggregateFunctionSetFinalizeCallback(
    function: AggregateFunctionHandle,
    callback: c.duckdb_v2_aggregate_function_finalize_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_set_finalize_callback.?(function, callback, err);
}

// --- Aggregate Function: size/init/update/combine/finalize info ---

pub fn aggregateFunctionSizeSetStateSize(info: AggregateFunctionSizeInfoHandle, size: idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_size_set_state_size.?(info, size, err);
}

pub fn aggregateFunctionInitGetStateCount(info: AggregateFunctionInitInfoHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_init_get_state_count.?(info, out_count, err);
}

pub fn aggregateFunctionInitGetStates(
    info: AggregateFunctionInitInfoHandle,
    out_states: *[*c]?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_init_get_states.?(info, out_states, err);
}

pub fn aggregateFunctionUpdateGetRowCount(info: AggregateFunctionUpdateInfoHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_update_get_row_count.?(info, out_count, err);
}

pub fn aggregateFunctionUpdateGetArg(
    info: AggregateFunctionUpdateInfoHandle,
    index: idx_t,
    out_vector: *VectorHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_update_get_arg.?(info, index, out_vector, err);
}

pub fn aggregateFunctionUpdateGetStates(
    info: AggregateFunctionUpdateInfoHandle,
    out_states: *[*c]?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_update_get_states.?(info, out_states, err);
}

pub fn aggregateFunctionCombineGetStateCount(info: AggregateFunctionCombineInfoHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_combine_get_state_count.?(info, out_count, err);
}

pub fn aggregateFunctionCombineGetSources(
    info: AggregateFunctionCombineInfoHandle,
    out_states: *[*c]?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_combine_get_sources.?(info, out_states, err);
}

pub fn aggregateFunctionCombineGetTargets(
    info: AggregateFunctionCombineInfoHandle,
    out_states: *[*c]?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_combine_get_targets.?(info, out_states, err);
}

pub fn aggregateFunctionFinalizeGetStateCount(info: AggregateFunctionFinalizeInfoHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_finalize_get_state_count.?(info, out_count, err);
}

pub fn aggregateFunctionFinalizeGetStates(
    info: AggregateFunctionFinalizeInfoHandle,
    out_states: *[*c]?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_finalize_get_states.?(info, out_states, err);
}

pub fn aggregateFunctionFinalizeGetResult(
    info: AggregateFunctionFinalizeInfoHandle,
    out_vector: *VectorHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_finalize_get_result.?(info, out_vector, err);
}

pub fn aggregateFunctionFinalizeGetResultOffset(info: AggregateFunctionFinalizeInfoHandle, out_offset: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_finalize_get_result_offset.?(info, out_offset, err);
}

/// Optional — only needed when aggregate states own resources that must be
/// released (e.g. a growable buffer backing `string_agg`-style state). Runs
/// on states discarded without being finalized (combine's merged-away
/// sources, states abandoned on error/cancellation): the complement of
/// finalize, which is otherwise the only other place a state's lifetime
/// ends. Must not fail — an error reported through its error slot is
/// ignored (per the header's own doc comment).
pub fn aggregateFunctionSetDestroyCallback(
    function: AggregateFunctionHandle,
    callback: c.duckdb_v2_aggregate_function_destroy_callback_fn,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_set_destroy_callback.?(function, callback, err);
}

pub fn aggregateFunctionDestroyGetStateCount(info: AggregateFunctionDestroyInfoHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_destroy_get_state_count.?(info, out_count, err);
}

pub fn aggregateFunctionDestroyGetStates(
    info: AggregateFunctionDestroyInfoHandle,
    out_states: *[*c]?*anyopaque,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_aggregate_function_destroy_get_states.?(info, out_states, err);
}

// --- Function Signature (shared by scalar/aggregate/table functions) ---

/// Add a parameter to a function signature. `default_value` may be a null
/// handle for a required parameter; `kind` selects positional-only,
/// standard (positional-or-named), *args, named-only, or **kwargs — see
/// `ParameterKind`. This replaces v1's SQL-macro-wrapper workaround for
/// named scalar-function parameters (no v1 equivalent existed).
pub fn functionSignatureAddParameter(
    sig: FunctionSignatureHandle,
    name: *const IdentifierT,
    param_type: LogicalTypeHandle,
    default_value: ValueHandle,
    kind: ParameterKind,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_function_signature_add_parameter.?(sig, name, param_type, default_value, kind, err);
}

pub fn functionSignatureSetReturnType(
    sig: FunctionSignatureHandle,
    return_type: LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_function_signature_set_return_type.?(sig, return_type, err);
}

// --- Logical Type ---
//
// Unlike v1's free-standing `duckdb_create_logical_type(type_id)`, v2 ties
// type creation to a connection or context — there is no handle-less
// constructor. We only need the context-based variant for use inside the
// extension entrypoint, which is handed a context directly.

pub fn contextCreateTypeFromId(
    ctx: ContextHandle,
    type_id: LogicalTypeId,
    out_type: *LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_context_create_type_from_id.?(ctx, type_id, null, null, 0, out_type, err);
}

/// Connection-based counterpart to `contextCreateTypeFromId`, for callers
/// with only a `ConnectionHandle` (e.g. a bulk-insert helper used outside
/// any function callback, which is never handed a `ContextHandle`).
pub fn connectionCreateTypeFromId(
    conn: ConnectionHandle,
    type_id: LogicalTypeId,
    out_type: *LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_connection_create_type_from_id.?(conn, type_id, null, null, 0, out_type, err);
}

/// Parse a SQL type expression ("INTEGER", "STRUCT(a INTEGER)", "VARIANT",
/// ...) into a logical type. `contextCreateTypeFromId(..., VARIANT, ...)`
/// segfaults on this v2.0 alpha build (confirmed live, in DuckDB's own
/// C++ internals, not this binding) despite VARIANT needing no
/// parameters at the SQL level (`SELECT 1::VARIANT` works fine) — this is
/// the workaround for VARIANT specifically, and presumably for any other
/// id that hits the same bug.
pub fn contextCreateTypeFromText(
    ctx: ContextHandle,
    text: []const u8,
    out_type: *LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    const text_str = str(text);
    return getApi().duckdb_v2_context_create_type_from_text.?(ctx, &text_str, out_type, err);
}

/// Wrap a logical type as a TYPE-kind Value, the only way v2 passes a type
/// as a parameter to a parameterized type constructor (LIST, ARRAY, MAP,
/// STRUCT, ...). The type is borrowed and copied in, so the input can be
/// destroyed independently once this returns.
pub fn valueCreateTypeWithContext(
    ctx: ContextHandle,
    in_type: LogicalTypeHandle,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_type_with_context.?(ctx, in_type, out_value, err);
}

/// Create LIST(child_type). v2's `context_create_type_from_id` takes LIST's
/// element type as a single positional TYPE-kind Value parameter (per its
/// own doc comment: "list(T)" resolves through the same parameter path as
/// DECIMAL/STRUCT/MAP/etc) — this hides that Value-wrapping step behind the
/// same plain (ctx, child_type) shape callers already use for primitives.
pub fn contextCreateListType(
    ctx: ContextHandle,
    child_type: LogicalTypeHandle,
    out_type: *LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    var child_type_value: ValueHandle = undefined;
    if (valueCreateTypeWithContext(ctx, child_type, &child_type_value, err) != c.DUCKDB_V2_ERROR_NONE) {
        return c.DUCKDB_V2_ERROR_API;
    }
    defer _ = valueDestroy(&child_type_value);
    return getApi().duckdb_v2_context_create_type_from_id.?(
        ctx,
        c.DUCKDB_V2_LOGICAL_TYPE_ID_LIST,
        null,
        &child_type_value,
        1,
        out_type,
        err,
    );
}

/// Create STRUCT(names[0] field_types[0], ...). Unlike LIST's single
/// positional child type, STRUCT needs one *named* TYPE-kind Value
/// parameter per field — same two-step Value-wrapping dance
/// `contextCreateListType` hides for a single child, generalized to N
/// named fields. `field_type_values` is caller-provided scratch (length
/// must equal `names.len`/`field_types.len`): the caller destroys each
/// entry once this returns, same ownership shape as any other
/// `valueCreateTypeWithContext` result.
pub fn contextCreateStructType(
    ctx: ContextHandle,
    names: []const IdentifierT,
    field_types: []const LogicalTypeHandle,
    field_type_values: []ValueHandle,
    out_type: *LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    for (field_types, 0..) |ft, i| {
        if (valueCreateTypeWithContext(ctx, ft, &field_type_values[i], err) != c.DUCKDB_V2_ERROR_NONE) {
            return c.DUCKDB_V2_ERROR_API;
        }
    }
    return getApi().duckdb_v2_context_create_type_from_id.?(
        ctx,
        c.DUCKDB_V2_LOGICAL_TYPE_ID_STRUCT,
        names.ptr,
        field_type_values.ptr,
        names.len,
        out_type,
        err,
    );
}

pub fn logicalTypeDestroy(logical_type: *LogicalTypeHandle) ErrorCode {
    return getApi().duckdb_v2_logical_type_destroy.?(logical_type);
}

/// Declare that the scalar function handles NULL arguments itself and must
/// be invoked even when one is NULL — the default otherwise short-circuits
/// to a NULL result without calling the function at all (and, confirmed
/// live, constant-folds a literal NULL argument away before the function
/// ever runs). Needed for a VARIANT parameter, whose NULL is ordinary data
/// the function may want to see, not an absent argument.
pub fn scalarFunctionSetNullHandlingSpecial(function: ScalarFunctionHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_scalar_function_set_property.?(
        function,
        c.DUCKDB_V2_FUNCTION_PROPERTY_NULL_HANDLING,
        c.DUCKDB_V2_FUNCTION_PROPERTY_NULL_HANDLING_SPECIAL,
        err,
    );
}

// --- Scalar Function exec callback ---

pub fn scalarFunctionSetExecCallback(
    function: ScalarFunctionHandle,
    callback: ScalarFunctionExecCallback,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_scalar_function_set_exec_callback.?(function, callback, err);
}

pub fn scalarFunctionExecGetArg(
    info: ScalarFunctionExecInfoHandle,
    index: idx_t,
    out_vector: *VectorHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_scalar_function_exec_get_arg.?(info, index, out_vector, err);
}

pub fn scalarFunctionExecGetResult(
    info: ScalarFunctionExecInfoHandle,
    out_vector: *VectorHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_scalar_function_exec_get_result.?(info, out_vector, err);
}

pub fn scalarFunctionExecGetRowCount(info: ScalarFunctionExecInfoHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_scalar_function_exec_get_row_count.?(info, out_count, err);
}

// --- Vector ---

/// A no-op on an already-FLAT vector; materializes CONSTANT/DICTIONARY/FSST/
/// SEQUENCE/SHREDDED vectors in place first. `vectorGetView` refuses FSST,
/// SEQUENCE, and SHREDDED vectors outright (confirmed live: `range()`
/// produces a SEQUENCE vector, and `SELECT agg(i) FROM range(...)` failed
/// with "vector is FSST / SEQUENCE / SHREDDED — call
/// duckdb_v2_vector_flatten first" until this was called beforehand) —
/// callers reading an argument vector's view should flatten first,
/// unconditionally, rather than special-case which representations are safe.
pub fn vectorFlatten(vector: VectorHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_flatten.?(vector, err);
}

/// Borrow a nested vector's child by index: for LIST/ARRAY, index 0 is the
/// flat element vector shared across every row (addressed per-row via the
/// parent LIST vector's own `ListEntry{offset, length}` records, read from
/// its `VectorView.data` same as any other vector). See
/// `duckdb_v2_vector_get_child`'s own doc comment for STRUCT/MAP/UNION.
pub fn vectorGetChild(vector: VectorHandle, index: idx_t, out_child: *VectorHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_get_child.?(vector, index, out_child, err);
}

pub fn vectorGetChildCount(vector: VectorHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_get_child_count.?(vector, out_count, err);
}

/// The "total fallback reader": reads one cell as an owned `Value`, working
/// on ANY vector representation (no `vectorFlatten` needed first) and ANY
/// type kind, including VARIANT and GEOMETRY — the ones with no committed
/// view layout, where this is the only way to read a cell at all. Slower
/// per-row than the view path (one allocation per call), so only worth it
/// for types `vectorGetView` can't handle. Caller-owned; destroy via
/// `valueDestroy`.
pub fn vectorGetValue(vector: VectorHandle, row: idx_t, out_value: *ValueHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_get_value.?(vector, row, out_value, err);
}

/// True if `value` represents SQL NULL. The VARIANT-row counterpart of
/// checking a `VectorView.validity` bit — VARIANT has no view, so
/// `vectorGetValue` + `valueIsNull` is how a NULL VARIANT cell is detected.
pub fn valueIsNull(value: ValueHandle, out_is_null: *bool, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_is_null.?(value, out_is_null, err);
}

pub fn vectorGetView(vector: VectorHandle, out_view: *VectorView, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_get_view.?(vector, out_view, err);
}

pub fn vectorGetDataMutable(vector: VectorHandle, out_data: *?*anyopaque, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_get_data_mutable.?(vector, out_data, err);
}

pub fn vectorFlatGetValidityMutable(vector: VectorHandle, out_validity: *?[*]u64, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_flat_get_validity_mutable.?(vector, out_validity, err);
}

pub fn vectorSetNull(vector: VectorHandle, row: idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_set_null.?(vector, row, err);
}

pub fn vectorSetSize(vector: VectorHandle, size: idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_set_size.?(vector, size, err);
}

// --- Str / Identifier ---

pub const Str = c.duckdb_v2_str;

/// Build a `duckdb_v2_str` (also used as `duckdb_v2_identifier_t`) borrowing
/// from a Zig slice. The slice must outlive the call this is passed to.
pub fn str(s: []const u8) Str {
    return .{ .ptr = s.ptr, .len = s.len };
}

// --- VARCHAR / Bytes (vector storage for VARCHAR, BLOB, BIT, BIGNUM) ---
//
// `duckdb_v2_str` (above) is the plain {ptr, len} shape used for API
// in/out parameters (names, error text, ...). Vector STORAGE for
// VARCHAR/BLOB/BIT/BIGNUM instead uses the 16-byte `duckdb_v2_bytes`
// union — bytes inlined directly when length <= 12, else a pointer +
// 4-byte prefix — the same small-string-optimization layout v1's
// `duckdb_string_t` used, just with the fields renamed.

pub const BytesValue = c.duckdb_v2_bytes;

/// Decode a vector-stored VARCHAR/BLOB element to a Zig slice without
/// copying. The returned slice points into DuckDB-owned memory (inline
/// storage or the vector's arena); valid only for the duration of the
/// current exec/update callback, same lifetime rule as v1's `stringSlice`.
pub fn bytesSlice(b: *const BytesValue) []const u8 {
    const len = b.value.inlined.length;
    // SAFETY: duckdb_v2_bytes is a transparent union (per its own doc
    // comment): when length <= 12 the bytes are inlined in
    // `value.inlined.inlined`; otherwise `value.pointer.ptr` is non-null.
    const ptr: [*]const u8 = if (len <= 12)
        @ptrCast(&b.value.inlined.inlined)
    else
        @ptrCast(b.value.pointer.ptr);
    return ptr[0..len];
}

/// Read a VARCHAR `Value`'s text. Borrowed from the value — valid only
/// until the value is destroyed, so copy it out (e.g. into bind data meant
/// to outlive the bind callback) before calling `valueDestroy`.
pub fn valueGetVarchar(value: ValueHandle, out: *Str, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_varchar.?(value, out, err);
}

// Numeric `Value` readers, mirroring the same type set `duckdbV2TypeId`
// maps across the comptime frameworks (i8/i16/i32/i64/f32/f64/bool) —
// needed for reading table-function constructor arguments at bind time,
// where (unlike scalar/aggregate `exec`/`update`) the argument arrives as
// a boxed `Value`, not a vector.
pub fn valueGetTinyint(value: ValueHandle, out: *i8, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_tinyint.?(value, out, err);
}
pub fn valueGetSmallint(value: ValueHandle, out: *i16, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_smallint.?(value, out, err);
}
pub fn valueGetInt(value: ValueHandle, out: *i32, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_int.?(value, out, err);
}
pub fn valueGetBigint(value: ValueHandle, out: *i64, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_bigint.?(value, out, err);
}
pub fn valueGetFloat(value: ValueHandle, out: *f32, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_float.?(value, out, err);
}
pub fn valueGetDouble(value: ValueHandle, out: *f64, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_double.?(value, out, err);
}
pub fn valueGetBool(value: ValueHandle, out: *bool, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_bool.?(value, out, err);
}

/// Child count of a nested `Value` (LIST/ARRAY element count, or STRUCT
/// field count). Caller-owned `out_child` results from `valueGetChild`
/// must be destroyed via `valueDestroy`.
pub fn valueGetChildCount(value: ValueHandle, out_count: *idx_t, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_child_count.?(value, out_count, err);
}

pub fn valueGetChild(value: ValueHandle, index: idx_t, out_child: *ValueHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_value_get_child.?(value, index, out_child, err);
}

/// Box a Zig string as a VARCHAR `Value`, for use with `vectorSetValue`.
/// The caller must `valueDestroy` the result once written.
pub fn valueCreateVarcharWithContext(
    ctx: ContextHandle,
    text: []const u8,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    const text_str = str(text);
    return getApi().duckdb_v2_value_create_varchar_with_context.?(ctx, &text_str, out_value, err);
}

/// Connection-based counterpart to `valueCreateVarcharWithContext`, for
/// callers with only a `ConnectionHandle` (see `connectionCreateTypeFromId`).
pub fn valueCreateVarcharWithConnection(
    conn: ConnectionHandle,
    text: []const u8,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    const text_str = str(text);
    return getApi().duckdb_v2_value_create_varchar_with_connection.?(conn, &text_str, out_value, err);
}

/// Box a Zig byte slice as a BLOB `Value`, for use with `vectorSetValue`.
/// The caller must `valueDestroy` the result once written. BLOB shares
/// VARCHAR's vector storage shape (`duckdb_v2_bytes`, see `BytesValue`'s
/// own doc comment) but is a distinct logical type (no UTF-8 requirement)
/// — kept as its own wrapper rather than reusing `valueCreateVarcharWithContext`
/// so the two never get silently conflated.
pub fn valueCreateBlobWithContext(
    ctx: ContextHandle,
    bytes: []const u8,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    const bytes_str = str(bytes);
    return getApi().duckdb_v2_value_create_blob_with_context.?(ctx, &bytes_str, out_value, err);
}

// --- DATE/TIME/TIMESTAMP/INTERVAL: fixed-width, no Value boxing needed ---
//
// Unlike VARCHAR/BLOB/VARIANT, these are plain fixed-width vector storage
// (the C API has no `duckdb_v2_date_t`/`duckdb_v2_time_t`/
// `duckdb_v2_timestamp_t` struct at all — DATE is a raw `int32_t` (days
// since 1970-01-01), TIME/TIMESTAMP a raw `int64_t` (micros since midnight/
// epoch), same physical layout as INTEGER/BIGINT), so the comptime scalar
// framework's existing direct-buffer read/write path handles them with no
// new exec-path code — only a distinct Zig type is needed so
// `duckdbV2TypeId` can tell them apart from plain `i32`/`i64`. A
// non-exhaustive enum wrapping the same backing int is a zero-cost way to
// get a distinct type with identical layout.
pub const Date = enum(i32) { _ };
pub const Time = enum(i64) { _ };
pub const Timestamp = enum(i64) { _ };

/// INTERVAL's vector storage is the raw `duckdb_v2_interval_t` struct
/// (months/days/micros) inline, same reasoning as DATE/TIME/TIMESTAMP
/// above — a direct type alias (not a wrapper) since the C struct is
/// already a distinct Zig type.
pub const Interval = c.duckdb_v2_interval_t;

/// BLOB marker type for `comptime_scalar_v2`: wraps a byte slice, decoded/
/// encoded exactly like VARCHAR's `BytesValue`/boxed-`Value` machinery, but
/// a distinct Zig type so it maps to SQL BLOB, not VARCHAR. NOTE: this is a
/// Zig `struct`, so framework code that distinguishes "is this a STRUCT
/// argument" from "is this some other framework-provided marker type" must
/// special-case `Blob` explicitly (see `comptime_scalar_v2.zig`'s
/// `isStructType`) — it must never be treated as a one-field SQL STRUCT.
pub const Blob = struct { bytes: []const u8 };

/// The storage int DECIMAL(width, _) uses in vector storage, per
/// `vector_get_view`'s own doc comment (a documented contract, not an
/// inference): width <= 4 -> int16, <= 9 -> int32, <= 18 -> int64,
/// <= 38 -> int128, boundaries inclusive.
pub fn DecimalStorageInt(comptime width: u8) type {
    return if (width <= 4) i16 else if (width <= 9) i32 else if (width <= 18) i64 else i128;
}

/// DECIMAL(width, scale) marker type for `comptime_scalar_v2`: a one-field
/// wrapper around the storage int the width selects (see
/// `DecimalStorageInt`), so the vector is read/written as that raw int
/// directly — DECIMAL is a typed leaf array in vector storage, same as any
/// numeric type, once the right width is picked, per the same doc comment.
/// `raw` is the value scaled by 10^scale (e.g. `10.5` as `DECIMAL(8, 3)`
/// is stored as `10500`), matching `value_create_decimal`'s own
/// convention. NOTE: this is a Zig `struct`, so framework code
/// distinguishing "is this a STRUCT argument" from "is this some other
/// framework-provided marker type" must special-case it explicitly (see
/// `comptime_scalar_v2.zig`'s `isStructType`), same reasoning as `Blob`.
pub fn Decimal(comptime width: u8, comptime scale: u8) type {
    return struct {
        pub const v2_decimal_width: u8 = width;
        pub const v2_decimal_scale: u8 = scale;
        pub const Raw = DecimalStorageInt(width);
        raw: Raw,
    };
}

pub fn valueCreateUtinyintWithContext(
    ctx: ContextHandle,
    in_value: u8,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_utinyint_with_context.?(ctx, in_value, out_value, err);
}

/// Build DECIMAL(width, scale). Width/scale cross as plain UTINYINT
/// `Value`s (not TYPE-kind values — they aren't child types), per
/// `context_create_type_from_id`'s own doc comment ("decimal(width,
/// scale)" resolves through the same parameter path as LIST/STRUCT/etc,
/// just with UTINYINT values instead of TYPE ones for this particular id).
pub fn contextCreateDecimalType(
    ctx: ContextHandle,
    width: u8,
    scale: u8,
    out_type: *LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    var width_value: ValueHandle = undefined;
    if (valueCreateUtinyintWithContext(ctx, width, &width_value, err) != c.DUCKDB_V2_ERROR_NONE) {
        return c.DUCKDB_V2_ERROR_API;
    }
    defer _ = valueDestroy(&width_value);
    var scale_value: ValueHandle = undefined;
    if (valueCreateUtinyintWithContext(ctx, scale, &scale_value, err) != c.DUCKDB_V2_ERROR_NONE) {
        return c.DUCKDB_V2_ERROR_API;
    }
    defer _ = valueDestroy(&scale_value);
    var params = [_]ValueHandle{ width_value, scale_value };
    return getApi().duckdb_v2_context_create_type_from_id.?(
        ctx,
        c.DUCKDB_V2_LOGICAL_TYPE_ID_DECIMAL,
        null,
        &params,
        2,
        out_type,
        err,
    );
}

/// Borrow a vector's own logical type — needed to cast a boxed `Value`
/// to an ENUM column's exact type when writing (there's no
/// `value_create_enum_*`, see `comptime_appender_v2.zig`'s module doc
/// comment on ENUM). Caller-owned; destroy via `logicalTypeDestroy`.
pub fn vectorGetLogicalType(vector: VectorHandle, out_type: *LogicalTypeHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_get_logical_type.?(vector, out_type, err);
}

pub fn valueCreateTinyintWithContext(
    ctx: ContextHandle,
    in_value: i8,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_tinyint_with_context.?(ctx, in_value, out_value, err);
}

pub fn valueCreateSmallintWithContext(
    ctx: ContextHandle,
    in_value: i16,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_smallint_with_context.?(ctx, in_value, out_value, err);
}

pub fn valueCreateIntWithContext(
    ctx: ContextHandle,
    in_value: i32,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_int_with_context.?(ctx, in_value, out_value, err);
}

pub fn valueCreateBigintWithContext(
    ctx: ContextHandle,
    in_value: i64,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_bigint_with_context.?(ctx, in_value, out_value, err);
}

pub fn valueCreateFloatWithContext(
    ctx: ContextHandle,
    in_value: f32,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_float_with_context.?(ctx, in_value, out_value, err);
}

pub fn valueCreateDoubleWithContext(
    ctx: ContextHandle,
    in_value: f64,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_double_with_context.?(ctx, in_value, out_value, err);
}

pub fn valueCreateBoolWithContext(
    ctx: ContextHandle,
    in_value: bool,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_bool_with_context.?(ctx, in_value, out_value, err);
}

pub fn valueDestroy(value: *ValueHandle) ErrorCode {
    return getApi().duckdb_v2_value_destroy.?(value);
}

/// Box `children` (already-boxed `Value`s, all of `child_type`) as a LIST
/// `Value`, for use with `vectorSetValue`. The caller destroys `children`
/// and the result independently once written — mirrors
/// `valueCreateVarcharWithContext`'s ownership shape, just for a LIST
/// rather than a scalar leaf.
pub fn valueCreateListWithContext(
    ctx: ContextHandle,
    child_type: LogicalTypeHandle,
    children: []const ValueHandle,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_list_with_context.?(ctx, child_type, children.ptr, children.len, out_value, err);
}

/// Box `names`/`children` (already-boxed `Value`s, one per field, same
/// order as `names`) as a STRUCT `Value`, for use with `vectorSetValue`.
/// Same ownership shape as `valueCreateListWithContext`.
pub fn valueCreateStructWithContext(
    ctx: ContextHandle,
    names: []const IdentifierT,
    children: []const ValueHandle,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_struct_with_context.?(ctx, names.ptr, children.ptr, names.len, out_value, err);
}

/// Box `children` as an ARRAY `Value` (fixed-size: the array's length IS
/// `children.len`, there is no separate size parameter). Same shape and
/// ownership as `valueCreateListWithContext` otherwise.
pub fn valueCreateArrayWithContext(
    ctx: ContextHandle,
    child_type: LogicalTypeHandle,
    children: []const ValueHandle,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_array_with_context.?(ctx, child_type, children.ptr, children.len, out_value, err);
}

/// Cast a boxed `Value` to `target_type`, e.g. a VARCHAR `Value` to an
/// ENUM type — the only way to produce an ENUM `Value`: there is no
/// `duckdb_v2_value_create_enum_*` family at all (confirmed by grepping
/// the header), so building one goes through this the same way SQL casts
/// a string literal to an enum (`'a'::my_enum`).
pub fn valueCastWithContext(
    ctx: ContextHandle,
    value: ValueHandle,
    target_type: LogicalTypeHandle,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_cast_with_context.?(ctx, value, target_type, out_value, err);
}

/// Write a boxed `Value` into a vector at `row`, copying it in and casting
/// to the vector's type. Simpler (if slower, due to the per-row Value
/// allocation) than hand-rolling the inline/arena encoding `BytesValue`
/// requires for direct writes — the right tradeoff for a first VARCHAR
/// implementation; a direct-arena-write path can replace this later if
/// profiling calls for it.
pub fn vectorSetValue(vector: VectorHandle, row: idx_t, value: ValueHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_set_value.?(vector, row, value, err);
}

pub const ArenaHandle = c.duckdb_v2_arena_handle;

/// Borrow a string-backed vector's (VARCHAR/BLOB/BIT/BIGNUM) arena, for
/// direct `BytesValue` writes. Needed in callbacks that have no `context`
/// handle to go through `valueCreateVarcharWithContext`/`vectorSetValue`
/// with — aggregate `size`/`init`/`update`/`combine`/`finalize` callbacks,
/// specifically, which the v2 API gives no context at all (unlike `bind`).
/// Borrowed — never destroy it.
pub fn vectorGetArena(vector: VectorHandle, out_arena: *ArenaHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_get_arena.?(vector, out_arena, err);
}

/// Allocate `byte_len` writable bytes from `arena`, valid as long as the
/// arena is. Never free the result; the arena owns it.
pub fn arenaAllocate(arena: ArenaHandle, byte_len: idx_t, out_ptr: *?[*]u8, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_arena_allocate.?(arena, byte_len, out_ptr, err);
}

/// Hand-construct a `BytesValue` for `text`, inlining when it fits in 12
/// bytes and otherwise copying into `arena`-owned memory. The counterpart
/// write path to `bytesSlice`'s decode, for callbacks with no `context`
/// handle (see `vectorGetArena`'s doc comment).
pub fn makeBytesValue(arena: ArenaHandle, text: []const u8, err: *ErrorInfoHandle) !BytesValue {
    var b: BytesValue = undefined;
    if (text.len <= 12) {
        b.value.inlined.length = @intCast(text.len);
        @memcpy(b.value.inlined.inlined[0..text.len], text);
    } else {
        var out_ptr: ?[*]u8 = null;
        if (arenaAllocate(arena, text.len, &out_ptr, err) != c.DUCKDB_V2_ERROR_NONE) return error.DuckDbError;
        const dst = out_ptr.?[0..text.len];
        @memcpy(dst, text);
        b.value.pointer.length = @intCast(text.len);
        const prefix_len = @min(text.len, 4);
        @memcpy(b.value.pointer.prefix[0..prefix_len], text[0..prefix_len]);
        if (prefix_len < 4) @memset(b.value.pointer.prefix[prefix_len..4], 0);
        // SAFETY: `pointer.ptr` is `[*c]u8` in the translated header; `out_ptr`
        // is arena-owned memory valid for the arena's lifetime (per
        // `arenaAllocate`'s doc comment), handed to DuckDB without a copy.
        b.value.pointer.ptr = @ptrCast(out_ptr.?);
    }
    return b;
}

// ─── Tests ────────────────────────────────────────────────────────────────
//
// Worked examples exercising these bindings (scalar/table/aggregate,
// VARCHAR, LIST) live in duckdb_v2_examples.zig, not here — this file is
// bindings only, matching v1's duckdb.zig.

test "ExtApiV2 vtable is default-zeroable" {
    const zeroed: ExtApiV2 = std.mem.zeroes(ExtApiV2);
    try std.testing.expect(zeroed.duckdb_v2_instance_create == null);
}

test "initApi fails cleanly when get_api is null" {
    var err: ErrorInfoHandle = undefined;
    _ = &err;
    const input: ExtensionInput = .{
        .get_api = null,
        .extension = undefined,
        .context = undefined,
        .err = undefined,
    };
    try std.testing.expect(!initApi(&input, "v2.0.0"));
}
