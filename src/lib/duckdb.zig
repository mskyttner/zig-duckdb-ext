///! Zig bindings for the DuckDB C Extension API.
///!
///! This module provides type-safe wrappers around the DuckDB C API function pointers
///! that are passed to extensions via the extension access vtable. Rather than using
///! C preprocessor macros (which Zig's @cImport cannot evaluate), we translate the
///! C header's opaque handle types and the `duckdb_ext_api_v1` function pointer struct
///! into idiomatic Zig types.
const std = @import("std");
pub const c = @cImport({
    // We define DUCKDB_API_EXCLUDE_FUNCTIONS to prevent the header from declaring
    // direct function prototypes — extensions call through function pointers, not linked symbols.
    @cDefine("DUCKDB_API_EXCLUDE_FUNCTIONS", "1");
    @cInclude("duckdb.h");
    @cInclude("duckdb_extension.h");
});

// ─── Re-export opaque handle types ───────────────────────────────────────────

pub const Database = c.duckdb_database;
pub const Connection = c.duckdb_connection;
pub const Result = c.duckdb_result;
pub const PreparedStatement = c.duckdb_prepared_statement;
pub const ExtractedStatements = c.duckdb_extracted_statements;
pub const PendingResult = c.duckdb_pending_result;
pub const Appender = c.duckdb_appender;
pub const Config = c.duckdb_config;
pub const LogicalType = c.duckdb_logical_type;
pub const DataChunk = c.duckdb_data_chunk;
pub const Vector = c.duckdb_vector;
pub const Value = c.duckdb_value;
pub const FunctionInfo = c.duckdb_function_info;
pub const ScalarFunction = c.duckdb_scalar_function;
pub const ScalarFunctionSet = c.duckdb_scalar_function_set;
pub const TableFunction = c.duckdb_table_function;
pub const BindInfo = c.duckdb_bind_info;
pub const InitInfo = c.duckdb_init_info;
pub const AggregateFunction = c.duckdb_aggregate_function;
pub const AggregateFunctionSet = c.duckdb_aggregate_function_set;
pub const AggregateState = c.duckdb_aggregate_state;
pub const ReplacementScanInfo = c.duckdb_replacement_scan_info;
pub const ExtensionInfo = c.duckdb_extension_info;
pub const ExtensionAccess = c.duckdb_extension_access;
pub const TableDescription = c.duckdb_table_description;
pub const TaskState = c.duckdb_task_state;
pub const ProfilingInfo = c.duckdb_profiling_info;
pub const CastFunction = c.duckdb_cast_function;
pub const CreateTypeInfo = c.duckdb_create_type_info;

// ─── Re-export enums ─────────────────────────────────────────────────────────

pub const Type = c.duckdb_type;
pub const DUCKDB_TYPE = c.DUCKDB_TYPE;
pub const State = c.duckdb_state;
pub const PendingState = c.duckdb_pending_state;
pub const ResultType = c.duckdb_result_type;
pub const StatementType = c.duckdb_statement_type;
pub const ErrorType = c.duckdb_error_type;

// ─── Re-export value types (structs with no indirection) ─────────────────────

pub const Date = c.duckdb_date;
pub const DateStruct = c.duckdb_date_struct;
pub const Time = c.duckdb_time;
pub const TimeStruct = c.duckdb_time_struct;
pub const TimeTz = c.duckdb_time_tz;
pub const TimeTzStruct = c.duckdb_time_tz_struct;
pub const Timestamp = c.duckdb_timestamp;
pub const TimestampS = c.duckdb_timestamp_s;
pub const TimestampMs = c.duckdb_timestamp_ms;
pub const TimestampNs = c.duckdb_timestamp_ns;
pub const TimestampStruct = c.duckdb_timestamp_struct;
pub const Interval = c.duckdb_interval;
pub const Hugeint = c.duckdb_hugeint;
pub const Uhugeint = c.duckdb_uhugeint;
pub const Decimal = c.duckdb_decimal;
pub const StringT = c.duckdb_string_t;
pub const String = c.duckdb_string;
pub const Blob = c.duckdb_blob;
pub const ListEntry = c.duckdb_list_entry;
pub const QueryProgress = c.duckdb_query_progress_type;

// ─── idx_t ───────────────────────────────────────────────────────────────────

pub const idx_t = c.idx_t;

// ─── State constants ─────────────────────────────────────────────────────────

pub const DuckDBSuccess = c.DuckDBSuccess;
pub const DuckDBError = c.DuckDBError;

// ─── Callback types ──────────────────────────────────────────────────────────

pub const DeleteCallback = c.duckdb_delete_callback_t;
pub const ScalarFunctionCallback = c.duckdb_scalar_function_t;
pub const TableFunctionCallback = c.duckdb_table_function_t;
pub const TableFunctionBind = c.duckdb_table_function_bind_t;
pub const TableFunctionInit = c.duckdb_table_function_init_t;
pub const ReplacementCallback = c.duckdb_replacement_callback_t;

// ─── Extension API singleton ─────────────────────────────────────────────────
//
// In the C template, this is a global `duckdb_ext_api_v1 duckdb_ext_api = {0};`
// and every `duckdb_*` call is a macro expanding to `duckdb_ext_api.duckdb_*`.
//
// In Zig we store the vtable pointer after initialization and provide wrapper
// functions.

const ExtApiV1 = c.duckdb_ext_api_v1;

/// The full copy of the vtable — matching the C template's `duckdb_ext_api_v1 duckdb_ext_api = {0};`
/// We must copy the struct by value (not store a pointer) because DuckDB may free the
/// memory returned by `get_api` after the init function returns.
var api_storage: ExtApiV1 = std.mem.zeroes(ExtApiV1);
var api_initialized: bool = false;

/// Initialize the extension API. Must be called before any other API function.
/// Returns false if the API version is incompatible.
pub fn initApi(info: ExtensionInfo, access: *ExtensionAccess, version_string: [*:0]const u8) bool {
    const raw = access.get_api.?(info, version_string);
    if (raw == null) return false;
    // SAFETY: get_api returns a pointer to the duckdb_ext_api_v1 vtable when the version matches.
    const res: *const ExtApiV1 = @ptrCast(@alignCast(raw));
    api_storage = res.*; // Copy by value, like the C template: `duckdb_ext_api = *res;`
    api_initialized = true;
    return true;
}

fn getApi() *const ExtApiV1 {
    // Invariant: initApi must be called before any API wrapper. This is guaranteed
    // by the extension entry point (init.zig) calling initApi as its first step.
    // A panic here indicates a programming error, not a runtime user error.
    if (!api_initialized) @panic("DuckDB Extension API not initialized — call initApi first");
    return &api_storage;
}

// ─── Wrapped API functions ──────────────────────────────────────────────────
//
// We only wrap the functions we need for the initial extension. More can be
// added as needed — the pattern is mechanical.

// --- Database / Connection ---

pub fn open(path: ?[*:0]const u8, out_database: *Database) State {
    return getApi().duckdb_open.?(path, out_database);
}

pub fn openExt(path: ?[*:0]const u8, out_database: *Database, config_param: Config, out_error: *?[*:0]u8) State {
    // SAFETY: out_error is *?[*:0]u8 which has the same layout as the C API's char** parameter.
    return getApi().duckdb_open_ext.?(path, out_database, config_param, @ptrCast(out_error));
}

pub fn close(database: *Database) void {
    getApi().duckdb_close.?(database);
}

pub fn connect(database: Database, out_connection: *Connection) State {
    return getApi().duckdb_connect.?(database, out_connection);
}

pub fn disconnect(connection: *Connection) void {
    getApi().duckdb_disconnect.?(connection);
}

pub fn libraryVersion() [*:0]const u8 {
    return getApi().duckdb_library_version.?();
}

// --- Query ---

pub fn query(connection: Connection, sql: [*:0]const u8, out_result: *Result) State {
    return getApi().duckdb_query.?(connection, sql, out_result);
}

pub fn destroyResult(result: *Result) void {
    getApi().duckdb_destroy_result.?(result);
}

pub fn columnName(result: *Result, col: idx_t) ?[*:0]const u8 {
    return getApi().duckdb_column_name.?(result, col);
}

pub fn columnCount(result: *Result) idx_t {
    return getApi().duckdb_column_count.?(result);
}

pub fn resultError(result: *Result) ?[*:0]const u8 {
    return getApi().duckdb_result_error.?(result);
}

pub fn fetchChunk(result: Result) DataChunk {
    return getApi().duckdb_fetch_chunk.?(result);
}

// --- Data Chunk ---

pub fn dataChunkGetSize(chunk: DataChunk) idx_t {
    return getApi().duckdb_data_chunk_get_size.?(chunk);
}

pub fn dataChunkGetVector(chunk: DataChunk, col_idx: idx_t) Vector {
    return getApi().duckdb_data_chunk_get_vector.?(chunk, col_idx);
}

pub fn dataChunkGetColumnCount(chunk: DataChunk) idx_t {
    return getApi().duckdb_data_chunk_get_column_count.?(chunk);
}

pub fn dataChunkSetSize(chunk: DataChunk, size: idx_t) void {
    getApi().duckdb_data_chunk_set_size.?(chunk, size);
}

pub fn destroyDataChunk(chunk: *DataChunk) void {
    getApi().duckdb_destroy_data_chunk.?(chunk);
}

// --- Vector ---

pub fn vectorGetData(vector: Vector) ?*anyopaque {
    return getApi().duckdb_vector_get_data.?(vector);
}

pub fn vectorGetValidity(vector: Vector) ?[*]u64 {
    return getApi().duckdb_vector_get_validity.?(vector);
}

pub fn vectorEnsureValidityWritable(vector: Vector) void {
    getApi().duckdb_vector_ensure_validity_writable.?(vector);
}

pub fn vectorAssignStringElement(vector: Vector, index: idx_t, str: [*:0]const u8) void {
    getApi().duckdb_vector_assign_string_element.?(vector, index, str);
}

pub fn vectorAssignStringElementLen(vector: Vector, index: idx_t, str: [*]const u8, len: idx_t) void {
    getApi().duckdb_vector_assign_string_element_len.?(vector, index, str, len);
}

// --- Validity ---

pub fn validityRowIsValid(validity: ?[*]u64, row: idx_t) bool {
    return getApi().duckdb_validity_row_is_valid.?(validity, row);
}

pub fn validitySetRowInvalid(validity: [*]u64, row: idx_t) void {
    getApi().duckdb_validity_set_row_invalid.?(validity, row);
}

pub fn validitySetRowValid(validity: [*]u64, row: idx_t) void {
    getApi().duckdb_validity_set_row_valid.?(validity, row);
}

// --- Logical Type ---

pub fn createLogicalType(type_id: c.DUCKDB_TYPE) LogicalType {
    return getApi().duckdb_create_logical_type.?(type_id);
}

pub fn destroyLogicalType(logical_type: *LogicalType) void {
    getApi().duckdb_destroy_logical_type.?(logical_type);
}

pub fn getTypeId(logical_type: LogicalType) Type {
    return getApi().duckdb_get_type_id.?(logical_type);
}

pub fn createListType(child: LogicalType) LogicalType {
    return getApi().duckdb_create_list_type.?(child);
}

pub fn createStructType(member_types: [*]LogicalType, member_names: [*]const [*:0]const u8, member_count: idx_t) LogicalType {
    return getApi().duckdb_create_struct_type.?(member_types, member_names, member_count);
}

// --- Scalar Function ---

pub fn createScalarFunction() ScalarFunction {
    return getApi().duckdb_create_scalar_function.?();
}

pub fn destroyScalarFunction(function: *ScalarFunction) void {
    getApi().duckdb_destroy_scalar_function.?(function);
}

pub fn scalarFunctionSetName(function: ScalarFunction, name: [*:0]const u8) void {
    getApi().duckdb_scalar_function_set_name.?(function, name);
}

pub fn scalarFunctionAddParameter(function: ScalarFunction, logical_type: LogicalType) void {
    getApi().duckdb_scalar_function_add_parameter.?(function, logical_type);
}

pub fn scalarFunctionSetReturnType(function: ScalarFunction, logical_type: LogicalType) void {
    getApi().duckdb_scalar_function_set_return_type.?(function, logical_type);
}

pub fn scalarFunctionSetFunction(function: ScalarFunction, callback: ScalarFunctionCallback) void {
    getApi().duckdb_scalar_function_set_function.?(function, callback);
}

pub fn scalarFunctionSetExtraInfo(function: ScalarFunction, extra_info: ?*anyopaque, destroy: DeleteCallback) void {
    getApi().duckdb_scalar_function_set_extra_info.?(function, extra_info, destroy);
}

pub fn registerScalarFunction(connection: Connection, function: ScalarFunction) State {
    return getApi().duckdb_register_scalar_function.?(connection, function);
}

pub fn scalarFunctionGetExtraInfo(info: FunctionInfo) ?*anyopaque {
    return getApi().duckdb_scalar_function_get_extra_info.?(info);
}

pub fn scalarFunctionSetError(info: FunctionInfo, err: [*:0]const u8) void {
    getApi().duckdb_scalar_function_set_error.?(info, err);
}

// --- Table Function ---

pub fn createTableFunction() TableFunction {
    return getApi().duckdb_create_table_function.?();
}

pub fn destroyTableFunction(function: *TableFunction) void {
    getApi().duckdb_destroy_table_function.?(function);
}

pub fn tableFunctionSetName(function: TableFunction, name: [*:0]const u8) void {
    getApi().duckdb_table_function_set_name.?(function, name);
}

pub fn tableFunctionAddParameter(function: TableFunction, logical_type: LogicalType) void {
    getApi().duckdb_table_function_add_parameter.?(function, logical_type);
}

pub fn tableFunctionSetExtraInfo(function: TableFunction, extra_info: ?*anyopaque, destroy: DeleteCallback) void {
    getApi().duckdb_table_function_set_extra_info.?(function, extra_info, destroy);
}

pub fn tableFunctionSetBind(function: TableFunction, bind: TableFunctionBind) void {
    getApi().duckdb_table_function_set_bind.?(function, bind);
}

pub fn tableFunctionSetInit(function: TableFunction, init: TableFunctionInit) void {
    getApi().duckdb_table_function_set_init.?(function, init);
}

pub fn tableFunctionSetFunction(function: TableFunction, callback: TableFunctionCallback) void {
    getApi().duckdb_table_function_set_function.?(function, callback);
}

pub fn tableFunctionSupportsProjectionPushdown(function: TableFunction, pushdown: bool) void {
    getApi().duckdb_table_function_supports_projection_pushdown.?(function, pushdown);
}

pub fn registerTableFunction(connection: Connection, function: TableFunction) State {
    return getApi().duckdb_register_table_function.?(connection, function);
}

// --- Table Function Bind/Init helpers ---

pub fn bindGetExtraInfo(info: BindInfo) ?*anyopaque {
    return getApi().duckdb_bind_get_extra_info.?(info);
}

pub fn bindAddResultColumn(info: BindInfo, name: [*:0]const u8, logical_type: LogicalType) void {
    getApi().duckdb_bind_add_result_column.?(info, name, logical_type);
}

pub fn bindGetParameterCount(info: BindInfo) idx_t {
    return getApi().duckdb_bind_get_parameter_count.?(info);
}

pub fn bindGetParameter(info: BindInfo, index: idx_t) Value {
    return getApi().duckdb_bind_get_parameter.?(info, index);
}

pub fn bindSetBindData(info: BindInfo, data: ?*anyopaque, destroy: DeleteCallback) void {
    getApi().duckdb_bind_set_bind_data.?(info, data, destroy);
}

pub fn bindSetCardinality(info: BindInfo, cardinality: idx_t, is_exact: bool) void {
    getApi().duckdb_bind_set_cardinality.?(info, cardinality, is_exact);
}

pub fn bindSetError(info: BindInfo, err: [*:0]const u8) void {
    getApi().duckdb_bind_set_error.?(info, err);
}

pub fn initGetBindData(info: InitInfo) ?*anyopaque {
    return getApi().duckdb_init_get_bind_data.?(info);
}

pub fn initSetInitData(info: InitInfo, data: ?*anyopaque, destroy: DeleteCallback) void {
    getApi().duckdb_init_set_init_data.?(info, data, destroy);
}

pub fn initSetMaxThreads(info: InitInfo, max_threads: idx_t) void {
    getApi().duckdb_init_set_max_threads.?(info, max_threads);
}

pub fn initSetError(info: InitInfo, err: [*:0]const u8) void {
    getApi().duckdb_init_set_error.?(info, err);
}

pub fn functionGetBindData(info: FunctionInfo) ?*anyopaque {
    return getApi().duckdb_function_get_bind_data.?(info);
}

pub fn functionGetInitData(info: FunctionInfo) ?*anyopaque {
    return getApi().duckdb_function_get_init_data.?(info);
}

pub fn functionSetError(info: FunctionInfo, err: [*:0]const u8) void {
    getApi().duckdb_function_set_error.?(info, err);
}

// --- Memory ---

pub fn malloc(size: usize) ?*anyopaque {
    return getApi().duckdb_malloc.?(size);
}

pub fn free(ptr: ?*anyopaque) void {
    getApi().duckdb_free.?(ptr);
}

// --- Value ---

pub fn createVarchar(text: [*:0]const u8) Value {
    return getApi().duckdb_create_varchar.?(text);
}

pub fn createInt64(val: i64) Value {
    return getApi().duckdb_create_int64.?(val);
}

pub fn getVarchar(value: Value) ?[*:0]u8 {
    // SAFETY: duckdb_get_varchar returns a null-terminated C string; cast from [*c]u8 to ?[*:0]u8.
    return @ptrCast(getApi().duckdb_get_varchar.?(value));
}

pub fn getInt64(value: Value) i64 {
    return getApi().duckdb_get_int64.?(value);
}

pub fn destroyValue(value: *Value) void {
    getApi().duckdb_destroy_value.?(value);
}

pub fn vectorSize() idx_t {
    return getApi().duckdb_vector_size.?();
}
