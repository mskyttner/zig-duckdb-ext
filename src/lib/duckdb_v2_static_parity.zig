//! Checks the generated static bindings (duckdb_v2_static.zig) against the pinned C header
//! (duckdb_v2.h), as translate-c sees it: every declaration of the generated module must exist in
//! the header with the same ABI shape, and every `duckdb_v2_*` function of the header must exist
//! in the generated module. This is what catches the header and the committed file drifting apart
//! when the pinned DuckDB commit changes.
//!
//! The comparison is by ABI shape, so it cannot see pointer nullability or the difference between
//! a pointer to one value and to an array; those come from the spec's prose (see the generator).
const std = @import("std");
const log = std.log.scoped(.v2_static_parity);
const gen = @import("duckdb_v2_static");
const c = @import("duckdb_v2_full_c");
const util = @import("duckdb_v2_parity_util.zig");

const fn_prefix = "duckdb_v2_";
const enum_prefix = "DUCKDB_V2_";

var failures: usize = 0;

fn fail(comptime fmt: []const u8, args: anytype) void {
    failures += 1;
    if (failures <= 40) log.err(fmt, args);
}

fn checkFunction(comptime name: []const u8) void {
    if (!@hasDecl(c, name)) return fail("function {s}: not in the C header", .{name});
    const FA = @TypeOf(@field(gen, name));
    const FB = @TypeOf(@field(c, name));
    if (@typeInfo(FB) != .@"fn") return fail("function {s}: not a function in the C header", .{name});
    if (!util.sameFn(FA, FB)) fail("function {s}: signature differs\n    gen: {s}\n    c:   {s}", .{ name, @typeName(FA), @typeName(FB) });
}

fn checkEnum(comptime name: []const u8, comptime E: type) void {
    inline for (comptime std.meta.fieldNames(E)) |field| {
        checkEnumValue(name, field, @backingInt(@field(E, field)));
    }
    // Names that repeat the value of an earlier one are declarations of the enum.
    inline for (comptime std.meta.declarations(E)) |decl| {
        if (@TypeOf(@field(E, decl)) == E) checkEnumValue(name, decl, @backingInt(@field(E, decl)));
    }
}

fn checkEnumValue(comptime name: []const u8, comptime field: []const u8, value: c_int) void {
    const cname = enum_prefix ++ field;
    if (!@hasDecl(c, cname)) return fail("enum {s}.{s}: no {s} in the C header", .{ name, field, cname });
    const cv: i64 = @field(c, cname);
    if (cv != value) fail("enum {s}.{s}: {d} here, {d} in the C header", .{ name, field, value, cv });
}

fn checkStruct(comptime name: []const u8, comptime S: type) void {
    if (!@hasDecl(c, name)) return fail("struct {s}: not in the C header", .{name});
    const C = @field(c, name);
    if (@typeInfo(C) != .@"struct") return fail("struct {s}: not a struct in the C header", .{name});
    if (@sizeOf(S) != @sizeOf(C)) fail("struct {s}: size {d} here, {d} in the C header", .{ name, @sizeOf(S), @sizeOf(C) });

    const fa = comptime std.meta.fieldNames(S);
    const fb = comptime std.meta.fieldNames(C);
    if (fa.len != fb.len) return fail("struct {s}: {d} fields here, {d} in the C header", .{ name, fa.len, fb.len });
    inline for (fa, fb) |na, nb| {
        if (!std.mem.eql(u8, na, nb)) return fail("struct {s}: field {s} here, {s} in the C header", .{ name, na, nb });
        if (@offsetOf(S, na) != @offsetOf(C, na)) fail("struct {s}.{s}: offset {d} here, {d} in the C header", .{ name, na, @offsetOf(S, na), @offsetOf(C, na) });
        if (!util.sameShape(@FieldType(S, na), @FieldType(C, na), 3)) fail("struct {s}.{s}: type differs", .{ name, na });
    }
}

fn checkType(comptime name: []const u8, comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"enum" => checkEnum(name, T),
        .@"struct" => checkStruct(name, T),
        else => {
            // handles, callbacks, aliases
            if (!@hasDecl(c, name)) return fail("type {s}: not in the C header", .{name});
            const C = @field(c, name);
            if (@TypeOf(C) != type) return fail("type {s}: not a type in the C header", .{name});
            const ok = if (@typeInfo(T) == .pointer and @typeInfo(@typeInfo(T).pointer.child) == .@"fn")
                util.sameFnPointer(T, C)
            else
                util.sameShape(T, C, 3);
            if (!ok) fail("type {s}: differs from the C header", .{name});
        },
    }
}

fn checkConstant(comptime name: []const u8, comptime value: anytype) void {
    if (!@hasDecl(c, name)) return fail("constant {s}: not in the C header", .{name});
    if (@field(c, name) != value) fail("constant {s}: differs from the C header", .{name});
}

test "generated bindings match the C header" {
    @setEvalBranchQuota(10_000_000);

    var n_fn: usize = 0;
    var n_type: usize = 0;
    var n_const: usize = 0;

    const gen_decls = comptime std.meta.declarations(gen);
    inline for (gen_decls) |name| {
        // Only look at the type of a declaration: touching a function value would make the test
        // binary reference the extern symbol.
        const DT = @TypeOf(@field(gen, name));
        if (DT == type) {
            checkType(name, @field(gen, name));
            n_type += 1;
        } else switch (@typeInfo(DT)) {
            .@"fn" => {
                checkFunction(name);
                n_fn += 1;
            },
            .int, .comptime_int => {
                checkConstant(name, @field(gen, name));
                n_const += 1;
            },
            else => fail("{s}: unexpected declaration", .{name}),
        }
    }

    // The other direction: nothing the header declares is missing from the generated bindings.
    var n_missing: usize = 0;
    const c_decls = comptime std.meta.declarations(c);
    inline for (c_decls) |name| {
        if (comptime std.mem.startsWith(u8, name, fn_prefix) and @typeInfo(@TypeOf(@field(c, name))) == .@"fn") {
            if (!@hasDecl(gen, name)) {
                fail("function {s}: in the C header, not generated", .{name});
                n_missing += 1;
            }
        }
    }

    log.info("checked {d} functions, {d} types, {d} constants; {d} header functions not generated; {d} problems", .{ n_fn, n_type, n_const, n_missing, failures });
    try std.testing.expectEqual(@as(usize, 0), failures);
}
