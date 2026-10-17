///! Defines the one libstdc++ symbol that DuckDB's MinGW `libduckdb_httplib.a` references and a
///! libstdc++ built against the other `mbstate_t` does not provide.
///!
///! The archives were compiled with `std::fpos<_Mbstatet>` (a UCRT-flavoured MinGW-w64), so the vtable
///! of `data_sink_streambuf` points at `std::basic_streambuf<char>::seekpos(std::fpos<_Mbstatet>,
///! std::_Ios_Openmode)`, which libstdc++ defines out of line. A msvcrt-flavoured libstdc++ (Ubuntu's
///! MinGW packages) has `fpos<int>` instead, and the link fails with "undefined symbol". The default
///! `seekpos` does nothing but return `pos_type(off_type(-1))`, and httplib never seeks its sink, so
///! that is what this does, with the x64 calling convention GCC's MinGW uses for a member function
///! that returns a 16-byte class: the hidden return pointer in the first register (RCX), then `this`,
///! the argument by reference and the mode (checked on the assembly GCC 13 emits for the same shape).
///!
///! Weak, so a libstdc++ that does define the symbol wins.
const std = @import("std");

/// `std::fpos<_Mbstatet>`: the offset, then the 8-byte `_Mbstatet`.
const Pos = extern struct {
    off: i64,
    wchar: i32,
    byte: u16,
    state: u16,
};

fn seekpos(ret: *Pos, this: ?*anyopaque, pos: *const Pos, mode: c_int) callconv(.c) *Pos {
    _ = .{ this, pos, mode };
    ret.* = .{ .off = -1, .wchar = 0, .byte = 0, .state = 0 };
    return ret;
}

comptime {
    @export(&seekpos, .{
        .name = "_ZNSt15basic_streambufIcSt11char_traitsIcEE7seekposESt4fposI9_MbstatetESt13_Ios_Openmode",
        .linkage = .weak,
    });
}

test "the shim returns pos_type(off_type(-1))" {
    var out: Pos = .{ .off = 7, .wchar = 1, .byte = 2, .state = 3 };
    const in: Pos = .{ .off = 5, .wchar = 0, .byte = 0, .state = 0 };
    try std.testing.expectEqual(&out, seekpos(&out, null, &in, 0));
    try std.testing.expectEqual(@as(i64, -1), out.off);
    try std.testing.expectEqual(@as(i32, 0), out.wchar);
}
