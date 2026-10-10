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

// ─── Re-export enums / structs ────────────────────────────────────────────────

pub const ErrorCode = c.DUCKDB_V2_ERROR;
pub const ParameterKind = c.DUCKDB_V2_FUNCTION_PARAMETER_KIND;
pub const LogicalTypeId = c.DUCKDB_V2_LOGICAL_TYPE_ID;
pub const ExtensionInput = c.duckdb_v2_extension_input;
pub const VectorView = c.duckdb_v2_vector_view;
pub const ListEntry = c.duckdb_v2_list_entry;
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

/// Write a boxed `Value` into a vector at `row`, copying it in and casting
/// to the vector's type. Simpler (if slower, due to the per-row Value
/// allocation) than hand-rolling the inline/arena encoding `BytesValue`
/// requires for direct writes — the right tradeoff for a first VARCHAR
/// implementation; a direct-arena-write path can replace this later if
/// profiling calls for it.
pub fn vectorSetValue(vector: VectorHandle, row: idx_t, value: ValueHandle, err: *ErrorInfoHandle) ErrorCode {
    return getApi().duckdb_v2_vector_set_value.?(vector, row, value, err);
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
