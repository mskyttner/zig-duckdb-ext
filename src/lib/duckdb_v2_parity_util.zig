//! Shared by the parity tests of the generated v2 bindings: comparing two types, as seen from
//! the generated code and from translate-c of the C header, by ABI shape.
const std = @import("std");

/// Same size and, for pointers, the same kind of pointee. Integers, enums and structs of the same
/// size are interchangeable: the C side spells an enum `c_uint` where the generated side has an enum.
pub fn sameShape(comptime A: type, comptime B: type, comptime depth: u8) bool {
    const ia = @typeInfo(A);
    const ib = @typeInfo(B);
    if (ia == .optional) return sameShape(ia.optional.child, B, depth);
    if (ib == .optional) return sameShape(A, ib.optional.child, depth);

    if (ia == .pointer or ib == .pointer) {
        if (ia != .pointer or ib != .pointer) return false;
        const ca = ia.pointer.child;
        const cb = ib.pointer.child;
        // Opaque and function pointees cannot be compared further.
        if (@typeInfo(ca) == .@"opaque" or @typeInfo(cb) == .@"opaque") return true;
        if (@typeInfo(ca) == .@"fn" or @typeInfo(cb) == .@"fn") return true;
        if (depth == 0) return true;
        return sameShape(ca, cb, depth - 1);
    }
    if (A == void or B == void) return A == B;
    return @sizeOf(A) == @sizeOf(B);
}

pub fn sameFn(comptime FA: type, comptime FB: type) bool {
    const a = @typeInfo(FA).@"fn";
    const b = @typeInfo(FB).@"fn";
    if (a.param_types.len != b.param_types.len) return false;
    inline for (a.param_types, b.param_types) |pa, pb| {
        if (!sameShape(pa.?, pb.?, 3)) return false;
    }
    return sameShape(a.return_type.?, b.return_type.?, 3);
}

pub fn sameFnPointer(comptime A: type, comptime B: type) bool {
    const pb = if (@typeInfo(B) == .optional) @typeInfo(B).optional.child else B;
    return sameFn(@typeInfo(A).pointer.child, @typeInfo(pb).pointer.child);
}
