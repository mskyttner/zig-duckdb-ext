///! Cookbook: registering a macro from an extension (v2 C API, `function/macro`), with its documentation.
///!
///!   zig_cookbook_clamp(x, lo := 0, hi := 1)      a scalar macro: least(greatest(x, lo), hi)
///!   zig_cookbook_squares(n := 5)                 a table macro: the first n integers and their squares
///!
///! A macro is SQL text with parameters, not code: DuckDB parses its body at registration and expands it where it is
///! called, so it works on any type its body works on and needs no vectors, no callbacks and no state. Reach for one when
///! the function is an expression over existing functions; reach for a scalar or table function (the other recipes) when
///! it needs Zig.
///!
///! The calls, in order:
///!   macro_function_create(factory, SCALAR | TABLE)   scalar: the body is one expression; table: one SELECT
///!   macro_function_set_name / _set_body              the body is borrowed and copied; it refers to the parameters by name
///!   macro_function_get_signature                     parameters: `function_signature_add_parameter`
///!   macro_function_get_docs                          description, examples, categories (see `v2_helpers.Docs`)
///!   extension_register_macro_function                parses the body; fails on a syntax error or an existing name
///!   macro_function_destroy                           the handle is still ours afterwards; registered macros live on
///!
///! What differs from the other functions:
///!   - **Parameters are named and optional by position or name.** Only `FUNCTION_PARAMETER_KIND_STANDARD` is accepted, a
///!     parameter with a default value can be left out, and a parameter of type ANY is untyped. There is no return type to
///!     set: the body decides it.
///!   - **One overload only.** A second macro of the same name is an error, as is one that clashes with a function.
///!   - **Names are resolved when the macro is called**, as with SQL `CREATE MACRO`: a typo in a column name in the body is
///!     found by the first query that uses it, not at registration.
///!   - In the catalog it is a `macro` (`duckdb_functions().function_type`), with `macro_definition` holding the body.
///!
///! This replaces what v1 extensions did: register a function under a hidden name and run `CREATE OR REPLACE MACRO` over it
///! to get named parameters and defaults (`functions/tp_bar.zig`). v2 can do both without the macro, and can register a
///! macro without running SQL, which an extension cannot do at load time.
const std = @import("std");
const v2 = @import("duckdb_v2_api");
const helpers = @import("v2_helpers");

const Err = *v2.duckdb_v2_error_info_handle;

const Param = struct {
    name: []const u8,
    /// A BIGINT default, or none (the parameter is required).
    default: ?i64 = null,
};

const Macro = struct {
    name: []const u8,
    kind: v2.DUCKDB_V2_MACRO_FUNCTION_TYPE,
    params: []const Param,
    body: []const u8,
    docs: helpers.Docs,
};

const macros = [_]Macro{
    .{
        .name = "zig_cookbook_clamp",
        .kind = .MACRO_FUNCTION_TYPE_SCALAR,
        .params = &.{ .{ .name = "x" }, .{ .name = "lo", .default = 0 }, .{ .name = "hi", .default = 1 } },
        .body = "least(greatest(x, lo), hi)",
        .docs = .{
            .description = "x limited to the range from lo to hi (0 and 1 unless given), of any type that least and greatest take.",
            .examples = &.{
                .{ .sql = "SELECT zig_cookbook_clamp(1.7);" },
                .{ .title = "Named bounds", .sql = "SELECT zig_cookbook_clamp(15, lo := 10, hi := 12);" },
            },
            .categories = &.{"numeric"},
        },
    },
    .{
        .name = "zig_cookbook_squares",
        .kind = .MACRO_FUNCTION_TYPE_TABLE,
        .params = &.{.{ .name = "n", .default = 5 }},
        .body = "SELECT i, i * i AS square FROM range(n) t(i)",
        .docs = .{
            .description = "The first n integers (5 unless given) from 0, with their squares.",
            .examples = &.{
                .{ .sql = "SELECT * FROM zig_cookbook_squares();" },
                .{ .sql = "SELECT sum(square) FROM zig_cookbook_squares(n := 100);" },
            },
            .categories = &.{"numeric"},
        },
    },
};

fn registerMacro(input: *const v2.duckdb_v2_extension_input, err: Err, m: Macro) !void {
    const factory = helpers.factory(input.context, err) orelse return error.FailedToGetFactory;

    var function: v2.duckdb_v2_macro_function_handle = undefined;
    if (v2.duckdb_v2_macro_function_create(factory, m.kind, &function, err) != .ERROR_NONE) return error.FailedToCreateMacro;
    defer _ = v2.duckdb_v2_macro_function_destroy(&function);

    const name = helpers.str(m.name);
    if (v2.duckdb_v2_macro_function_set_name(function, &name, err) != .ERROR_NONE) return error.FailedToSetName;
    const body = helpers.str(m.body);
    if (v2.duckdb_v2_macro_function_set_body(function, &body, err) != .ERROR_NONE) return error.FailedToSetBody;

    var sig: v2.duckdb_v2_function_signature_handle = undefined;
    if (v2.duckdb_v2_macro_function_get_signature(function, &sig, err) != .ERROR_NONE) return error.FailedToGetSignature;
    for (m.params) |param| {
        // ANY: untyped, the body decides what the parameter must be. A default has a type of its own.
        var any_type: v2.duckdb_v2_logical_type_handle = undefined;
        if (helpers.createTypeFromId(input.context, .LOGICAL_TYPE_ID_ANY, &any_type, err) != .ERROR_NONE) return error.FailedToCreateType;
        defer _ = v2.duckdb_v2_logical_type_destroy(&any_type);
        var default: ?v2.duckdb_v2_value_handle = null;
        defer if (default) |*d| {
            _ = v2.duckdb_v2_value_destroy(d);
        };
        if (param.default) |d| {
            var value: v2.duckdb_v2_value_handle = undefined;
            if (v2.duckdb_v2_value_create_bigint(factory, d, &value, err) != .ERROR_NONE) return error.FailedToCreateDefault;
            default = value;
        }
        const param_name = helpers.str(param.name);
        if (v2.duckdb_v2_function_signature_add_parameter(sig, &param_name, any_type, default orelse null, .FUNCTION_PARAMETER_KIND_STANDARD, err) != .ERROR_NONE) return error.FailedToAddParameter;
    }

    var docs: v2.duckdb_v2_function_docs_handle = undefined;
    if (v2.duckdb_v2_macro_function_get_docs(function, &docs, err) != .ERROR_NONE) return error.FailedToGetDocs;
    helpers.setDocs(docs, m.docs, err) catch return error.FailedToSetDocs;

    if (v2.duckdb_v2_extension_register_macro_function(input.extension, function, err) != .ERROR_NONE) return error.FailedToRegisterMacro;
}

/// Registers the macros. A failure leaves DuckDB's error info in the entrypoint's error slot.
pub fn register(input: *const v2.duckdb_v2_extension_input) !void {
    const err = input.err orelse return error.MissingErrorSlot;
    for (macros) |m| try registerMacro(input, err, m);
}
