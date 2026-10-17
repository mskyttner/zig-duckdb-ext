const std = @import("std");

pub const version = @import("version.zig").version;
pub const Columnar = @import("model.zig").Columnar;
pub const Field = @import("model.zig").Field;
pub const Array = @import("model.zig").Array;
pub const Kind = @import("model.zig").Kind;
pub const Codec = @import("model.zig").Codec;
pub const Tensor = @import("model.zig").Tensor;
pub const Dict = @import("model.zig").Dict;
pub const Error = @import("model.zig").Error;
pub const byteWidth = @import("model.zig").byteWidth;
pub const readInt = @import("model.zig").readInt;

pub const encodeStream = @import("ipc.zig").encodeStream;
pub const decodeStream = @import("ipc.zig").decodeStream;
pub const encodeFile = @import("ipc.zig").encodeFile;
pub const decodeFile = @import("ipc.zig").decodeFile;
pub const readFooter = @import("ipc.zig").readFooter;
pub const FooterInfo = @import("ipc.zig").FooterInfo;

pub const encodeTensorStream = @import("tensor.zig").encodeTensorStream;
pub const readTensor = @import("tensor.zig").readTensor;

pub const compressLz4 = @import("lz4.zig").compress;
pub const decompressLz4 = @import("lz4.zig").decompress;
pub const compressZstd = @import("zstd.zig").compress;
pub const decompressZstd = @import("zstd.zig").decompress;

pub const flight = @import("flight.zig");
pub const loadSchema = @import("schema_load.zig").load;
pub const schemaTitle = @import("schema_load.zig").title;
pub const emitSchema = @import("codegen.zig").emit;
pub const rowsFromBatch = @import("rows.zig").rowsFromBatch;
pub const Rows = @import("rows.zig").Rows;

pub fn compress(gpa: std.mem.Allocator, codec: Codec, raw: []const u8) Error![]u8 {
    return switch (codec) {
        .lz4 => compressLz4(gpa, raw),
        .zstd => compressZstd(gpa, raw),
    };
}

pub fn decompress(gpa: std.mem.Allocator, codec: Codec, raw: []const u8) Error![]u8 {
    return switch (codec) {
        .lz4 => decompressLz4(gpa, raw),
        .zstd => decompressZstd(gpa, raw),
    };
}

test {
    _ = @import("flatbuf.zig");
    _ = @import("schema_fb.zig");
    _ = @import("lz4.zig");
    _ = @import("zstd.zig");
    _ = @import("xxh.zig");
    _ = @import("ipc.zig");
    _ = @import("tensor.zig");
    _ = @import("flight.zig");
    _ = @import("schema_load.zig");
    _ = @import("codegen.zig");
    _ = @import("roundtrip_test.zig");
}

test "version is 0.2.0" {
    try std.testing.expectEqualStrings("0.2.0", version);
}
