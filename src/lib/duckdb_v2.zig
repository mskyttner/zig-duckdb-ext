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
pub const TableFunctionInitGlobalInfoHandle = c.duckdb_v2_table_function_init_global_info_handle;
pub const TableFunctionExecInfoHandle = c.duckdb_v2_table_function_exec_info_handle;
pub const AggregateFunctionHandle = c.duckdb_v2_aggregate_function_handle;
pub const AggregateFunctionSizeInfoHandle = c.duckdb_v2_aggregate_function_size_info_handle;
pub const AggregateFunctionInitInfoHandle = c.duckdb_v2_aggregate_function_init_info_handle;
pub const AggregateFunctionUpdateInfoHandle = c.duckdb_v2_aggregate_function_update_info_handle;
pub const AggregateFunctionCombineInfoHandle = c.duckdb_v2_aggregate_function_combine_info_handle;
pub const AggregateFunctionFinalizeInfoHandle = c.duckdb_v2_aggregate_function_finalize_info_handle;

// ─── Re-export enums / structs ────────────────────────────────────────────────

pub const ErrorCode = c.DUCKDB_V2_ERROR;
pub const ParameterKind = c.DUCKDB_V2_FUNCTION_PARAMETER_KIND;
pub const LogicalTypeId = c.DUCKDB_V2_LOGICAL_TYPE_ID;
pub const ExtensionInput = c.duckdb_v2_extension_input;
pub const VectorView = c.duckdb_v2_vector_view;
pub const ScalarFunctionExecCallback = c.duckdb_v2_scalar_function_exec_callback_fn;
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

// --- Table Function bind/init/exec info ---

pub fn tableFunctionBindAddResultColumn(
    info: TableFunctionBindInfoHandle,
    name: *const IdentifierT,
    column_type: LogicalTypeHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_table_function_bind_add_result_column.?(info, name, column_type, err);
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

pub fn logicalTypeDestroy(logical_type: *LogicalTypeHandle) ErrorCode {
    return getApi().duckdb_v2_logical_type_destroy.?(logical_type);
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

pub fn valueCreateBigintWithContext(
    ctx: ContextHandle,
    in_value: i64,
    out_value: *ValueHandle,
    err: *ErrorInfoHandle,
) ErrorCode {
    return getApi().duckdb_v2_value_create_bigint_with_context.?(ctx, in_value, out_value, err);
}

pub fn valueDestroy(value: *ValueHandle) ErrorCode {
    return getApi().duckdb_v2_value_destroy.?(value);
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

// ─── Worked example ──────────────────────────────────────────────────────
//
// A v2 port of the v1 `hello.zig`-style trivial scalar function, written by
// hand (not through the comptime framework yet) to prove the exec callback
// round trip: read one BIGINT arg through a `VectorView`, double it, write
// through `vectorGetDataMutable`. NULL propagation uses `view.validity`
// (null = "no NULLs present", matching v1's `vectorGetValidity` convention)
// and `vectorSetNull` for the slow path.
//
// Not registered against a real connection anywhere yet — `v2-check` only
// type-checks this against the vtable's declared signatures.
const example = struct {
    // `err` must match the vtable's raw `[*c]ErrorInfoHandle` C-pointer type
    // exactly — assigning a fn literal to a function-pointer-typed field
    // requires an exact type match, unlike ordinary argument passing (which
    // auto-coerces `*T` to `[*c]T`, as every other wrapper above relies on).
    fn doubleExec(info: ScalarFunctionExecInfoHandle, context: ContextHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        _ = context;
        var row_count: idx_t = 0;
        if (scalarFunctionExecGetRowCount(info, &row_count, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var arg_vec: VectorHandle = undefined;
        if (scalarFunctionExecGetArg(info, 0, &arg_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;
        if (vectorFlatten(arg_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var view: VectorView = undefined;
        if (vectorGetView(arg_vec, &view, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var result_vec: VectorHandle = undefined;
        if (scalarFunctionExecGetResult(info, &result_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;
        // The result vector starts at whatever size it was last used at (often
        // 1) — must grow it to row_count before writing/nulling past index 0,
        // or duckdb_v2_vector_set_null rejects out-of-range rows.
        if (vectorSetSize(result_vec, row_count, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var out_data: ?*anyopaque = null;
        if (vectorGetDataMutable(result_vec, &out_data, err) != c.DUCKDB_V2_ERROR_NONE) return;
        // SAFETY: the signature registered this function as (BIGINT) -> BIGINT,
        // so the arg view and result buffer are both i64-typed by construction.
        const in: [*]const i64 = @ptrCast(@alignCast(view.data));
        const out: [*]i64 = @ptrCast(@alignCast(out_data));

        var row: idx_t = 0;
        while (row < row_count) : (row += 1) {
            if (view.validity != null and !isValid(view.validity.?, row)) {
                if (vectorSetNull(result_vec, row, err) != c.DUCKDB_V2_ERROR_NONE) return;
                continue;
            }
            out[row] = in[row] * 2;
        }
    }

    inline fn isValid(validity: [*]const u64, row: idx_t) bool {
        const entry_idx = row / 64;
        const bit_idx: u6 = @intCast(row % 64);
        return (validity[entry_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }
};

/// Re-export of `example.doubleExec` for `src/ext/init_v2_poc.zig`'s live
/// registration test — kept out of the main wrapper namespace above since
/// it's demo code, not a real binding.
pub const exampleDoubleExecForPoc = example.doubleExec;

// ─── Worked example: VARCHAR scalar function ─────────────────────────────
//
// A v2 port of the v1 `hello.zig` example: `zig_v2_hello(name VARCHAR) ->
// VARCHAR`, proving the first-cut VARCHAR read/write path by hand before
// generalizing it into comptime_scalar_v2. Reads via `bytesSlice` directly
// off the flattened arg vector (zero-copy, same as any numeric read);
// writes via `valueCreateVarcharWithContext` + `vectorSetValue` (boxed,
// simpler than hand-rolling the inline/arena encoding — see those
// functions' own doc comments for the tradeoff).
const varchar_example = struct {
    fn helloExec(info: ScalarFunctionExecInfoHandle, context: ContextHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        var row_count: idx_t = 0;
        if (scalarFunctionExecGetRowCount(info, &row_count, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var arg_vec: VectorHandle = undefined;
        if (scalarFunctionExecGetArg(info, 0, &arg_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;
        if (vectorFlatten(arg_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var view: VectorView = undefined;
        if (vectorGetView(arg_vec, &view, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var result_vec: VectorHandle = undefined;
        if (scalarFunctionExecGetResult(info, &result_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;
        if (vectorSetSize(result_vec, row_count, err) != c.DUCKDB_V2_ERROR_NONE) return;

        // SAFETY: the signature registered this function as (VARCHAR) -> VARCHAR.
        const in: [*]const BytesValue = @ptrCast(@alignCast(view.data));

        var row: idx_t = 0;
        while (row < row_count) : (row += 1) {
            if (view.validity != null and !example.isValid(view.validity.?, row)) {
                if (vectorSetNull(result_vec, row, err) != c.DUCKDB_V2_ERROR_NONE) return;
                continue;
            }
            const name = bytesSlice(&in[row]);
            var buf: [1024]u8 = undefined;
            const prefix = "Hello, ";
            const suffix = "!";
            const total = prefix.len + name.len + suffix.len;
            const greeting = if (total <= buf.len) blk: {
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len .. prefix.len + name.len], name);
                @memcpy(buf[prefix.len + name.len .. total], suffix);
                break :blk buf[0..total];
            } else "Hello, world!";

            var value: ValueHandle = undefined;
            if (valueCreateVarcharWithContext(context, greeting, &value, err) != c.DUCKDB_V2_ERROR_NONE) return;
            defer _ = valueDestroy(&value);
            if (vectorSetValue(result_vec, row, value, err) != c.DUCKDB_V2_ERROR_NONE) return;
        }
    }
};

pub const exampleHelloExecForPoc = varchar_example.helloExec;

// ─── Worked example: table function ──────────────────────────────────────
//
// `zig_v2_range3()`: a fixed-arity, non-parallel table function returning
// one BIGINT column `n` over 3 rows (0, 1, 2) — proves bind → init_global →
// exec against a live runtime. Global state is a single heap-allocated
// `GlobalState.emitted` flag, boxed in a `duckdb_v2_opaque` (ptr + destroy +
// equals) via `table_function_init_global_set_global_state` so DuckDB frees
// it itself when the query ends — see `Opaque`'s doc comment above.
const table_example = struct {
    const GlobalState = struct { emitted: bool };

    fn destroyGlobalState(data: ?*anyopaque) callconv(.c) void {
        const state: *GlobalState = @ptrCast(@alignCast(data.?));
        std.heap.c_allocator.destroy(state);
    }

    fn bind(info: c.duckdb_v2_function_bind_info_handle, result: TableFunctionBindInfoHandle, context: ContextHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        _ = info;
        var bigint_type: LogicalTypeHandle = undefined;
        if (contextCreateTypeFromId(context, c.DUCKDB_V2_LOGICAL_TYPE_ID_BIGINT, &bigint_type, err) != c.DUCKDB_V2_ERROR_NONE) return;
        defer _ = logicalTypeDestroy(&bigint_type);

        const col_name = str("n");
        if (tableFunctionBindAddResultColumn(result, &col_name, bigint_type, err) != c.DUCKDB_V2_ERROR_NONE) return;
        _ = tableFunctionBindSetCardinality(result, 3, true, err);
    }

    fn initGlobal(info: TableFunctionInitGlobalInfoHandle, context: ContextHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        _ = context;
        const state = std.heap.c_allocator.create(GlobalState) catch return;
        state.* = .{ .emitted = false };
        var boxed: Opaque = .{ .ptr = state, .destroy = destroyGlobalState, .equals = null };
        _ = tableFunctionInitGlobalSetGlobalState(info, &boxed, err);
    }

    fn exec(info: TableFunctionExecInfoHandle, context: ContextHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        _ = context;
        var state_ptr: ?*anyopaque = null;
        if (tableFunctionExecGetGlobalState(info, &state_ptr, err) != c.DUCKDB_V2_ERROR_NONE) return;
        // SAFETY: the pointer stored in initGlobal is always a *GlobalState.
        const state: *GlobalState = @ptrCast(@alignCast(state_ptr.?));

        var chunk: DataChunkHandle = undefined;
        if (tableFunctionExecGetOutputChunk(info, &chunk, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var col0: VectorHandle = undefined;
        if (dataChunkGetVector(chunk, 0, &col0, err) != c.DUCKDB_V2_ERROR_NONE) return;

        // A table function signals end-of-scan by returning a 0-size chunk.
        if (state.emitted) {
            _ = vectorSetSize(col0, 0, err);
            return;
        }

        if (vectorSetSize(col0, 3, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var out_data: ?*anyopaque = null;
        if (vectorGetDataMutable(col0, &out_data, err) != c.DUCKDB_V2_ERROR_NONE) return;
        const out: [*]i64 = @ptrCast(@alignCast(out_data));
        out[0] = 0;
        out[1] = 1;
        out[2] = 2;
        state.emitted = true;
    }
};

pub const exampleTableBindForPoc = table_example.bind;
pub const exampleTableInitGlobalForPoc = table_example.initGlobal;
pub const exampleTableExecForPoc = table_example.exec;

// ─── Worked example: aggregate function ──────────────────────────────────
//
// `zig_v2_agg_sum(x BIGINT) -> BIGINT`: proves the full size → init →
// update → combine → finalize lifecycle, v2's biggest structural departure
// from v1 — every stage is batched over an array of state pointers rather
// than one state at a time. No bind callback needed (return type is fixed
// via the signature, not dynamic), no destroy callback needed (the state
// owns no resources).
const aggregate_example = struct {
    const SumState = struct { sum: i64 };

    fn size(info: AggregateFunctionSizeInfoHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        _ = aggregateFunctionSizeSetStateSize(info, @sizeOf(SumState), err);
    }

    fn init(info: AggregateFunctionInitInfoHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        var count: idx_t = 0;
        if (aggregateFunctionInitGetStateCount(info, &count, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var states: [*c]?*anyopaque = null;
        if (aggregateFunctionInitGetStates(info, &states, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var i: idx_t = 0;
        while (i < count) : (i += 1) {
            const state: *SumState = @ptrCast(@alignCast(states[i].?));
            state.* = .{ .sum = 0 };
        }
    }

    fn update(info: AggregateFunctionUpdateInfoHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        var row_count: idx_t = 0;
        if (aggregateFunctionUpdateGetRowCount(info, &row_count, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var arg_vec: VectorHandle = undefined;
        if (aggregateFunctionUpdateGetArg(info, 0, &arg_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;
        if (vectorFlatten(arg_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var view: VectorView = undefined;
        if (vectorGetView(arg_vec, &view, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var states: [*c]?*anyopaque = null;
        if (aggregateFunctionUpdateGetStates(info, &states, err) != c.DUCKDB_V2_ERROR_NONE) return;

        // SAFETY: the signature registered this function as (BIGINT) -> BIGINT.
        const values: [*]const i64 = @ptrCast(@alignCast(view.data));
        var row: idx_t = 0;
        while (row < row_count) : (row += 1) {
            if (view.validity != null and !example.isValid(view.validity.?, row)) continue;
            const state: *SumState = @ptrCast(@alignCast(states[row].?));
            state.sum += values[row];
        }
    }

    fn combine(info: AggregateFunctionCombineInfoHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        var count: idx_t = 0;
        if (aggregateFunctionCombineGetStateCount(info, &count, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var sources: [*c]?*anyopaque = null;
        if (aggregateFunctionCombineGetSources(info, &sources, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var targets: [*c]?*anyopaque = null;
        if (aggregateFunctionCombineGetTargets(info, &targets, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var i: idx_t = 0;
        while (i < count) : (i += 1) {
            const source: *SumState = @ptrCast(@alignCast(sources[i].?));
            const target: *SumState = @ptrCast(@alignCast(targets[i].?));
            target.sum += source.sum;
        }
    }

    fn finalize(info: AggregateFunctionFinalizeInfoHandle, err: [*c]ErrorInfoHandle) callconv(.c) void {
        var count: idx_t = 0;
        if (aggregateFunctionFinalizeGetStateCount(info, &count, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var states: [*c]?*anyopaque = null;
        if (aggregateFunctionFinalizeGetStates(info, &states, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var result_vec: VectorHandle = undefined;
        if (aggregateFunctionFinalizeGetResult(info, &result_vec, err) != c.DUCKDB_V2_ERROR_NONE) return;
        var offset: idx_t = 0;
        if (aggregateFunctionFinalizeGetResultOffset(info, &offset, err) != c.DUCKDB_V2_ERROR_NONE) return;

        var out_data: ?*anyopaque = null;
        if (vectorGetDataMutable(result_vec, &out_data, err) != c.DUCKDB_V2_ERROR_NONE) return;
        const out: [*]i64 = @ptrCast(@alignCast(out_data));

        var i: idx_t = 0;
        while (i < count) : (i += 1) {
            const state: *SumState = @ptrCast(@alignCast(states[i].?));
            out[offset + i] = state.sum;
        }
    }
};

pub const exampleAggregateSizeForPoc = aggregate_example.size;
pub const exampleAggregateInitForPoc = aggregate_example.init;
pub const exampleAggregateUpdateForPoc = aggregate_example.update;
pub const exampleAggregateCombineForPoc = aggregate_example.combine;
pub const exampleAggregateFinalizeForPoc = aggregate_example.finalize;

// ─── Tests ────────────────────────────────────────────────────────────────
//
// Beyond these static/structural checks, the worked examples above are also
// verified against a real, live DuckDB v2.0 alpha runtime via
// `src/ext/init_v2_poc.zig` + `zig build v2-poc` — see that file.

test "ExtApiV2 vtable is default-zeroable" {
    const zeroed: ExtApiV2 = std.mem.zeroes(ExtApiV2);
    try std.testing.expect(zeroed.duckdb_v2_instance_create == null);
}

test "example.doubleExec matches the exec callback signature" {
    // Taking the function's address forces Zig to semantically analyze its
    // body (analysis is lazy per-function) — this is the only thing that
    // actually type-checks the worked example above, since nothing calls it.
    const cb: ScalarFunctionExecCallback = example.doubleExec;
    try std.testing.expect(cb != null);
}

test "varchar_example.helloExec matches the exec callback signature" {
    const cb: ScalarFunctionExecCallback = varchar_example.helloExec;
    try std.testing.expect(cb != null);
}

test "table_example callbacks match their callback signatures" {
    const bind_cb: c.duckdb_v2_table_function_bind_callback_fn = table_example.bind;
    const init_cb: c.duckdb_v2_table_function_init_global_callback_fn = table_example.initGlobal;
    const exec_cb: c.duckdb_v2_table_function_exec_callback_fn = table_example.exec;
    try std.testing.expect(bind_cb != null);
    try std.testing.expect(init_cb != null);
    try std.testing.expect(exec_cb != null);
}

test "aggregate_example callbacks match their callback signatures" {
    const size_cb: c.duckdb_v2_aggregate_function_size_callback_fn = aggregate_example.size;
    const init_cb: c.duckdb_v2_aggregate_function_init_callback_fn = aggregate_example.init;
    const update_cb: c.duckdb_v2_aggregate_function_update_callback_fn = aggregate_example.update;
    const combine_cb: c.duckdb_v2_aggregate_function_combine_callback_fn = aggregate_example.combine;
    const finalize_cb: c.duckdb_v2_aggregate_function_finalize_callback_fn = aggregate_example.finalize;
    try std.testing.expect(size_cb != null);
    try std.testing.expect(init_cb != null);
    try std.testing.expect(update_cb != null);
    try std.testing.expect(combine_cb != null);
    try std.testing.expect(finalize_cb != null);
}

test "example.isValid reads validity bits correctly" {
    var bits: [1]u64 = .{0b101};
    try std.testing.expect(example.isValid(&bits, 0));
    try std.testing.expect(!example.isValid(&bits, 1));
    try std.testing.expect(example.isValid(&bits, 2));
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
