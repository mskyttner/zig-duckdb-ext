const std = @import("std");
pub const asciigraph = @This();
const Self = @This();

pub const options = @import("options.zig");
pub const colors = @import("ansiColor.zig");
pub const util = @import("utils.zig");

const math = @import("std").math;
pub const ColorStruct = colors.AnsiColor;

allocator: std.mem.Allocator,
config: options.config,
out: *std.Io.Writer,

const cell = struct {
    text: []const u8,
    color: ColorStruct,
    pub fn init(t: []u8, c: ColorStruct) cell {
        return cell{
            .text = t,
            .color = c,
        };
    }
};

pub fn prepareCellMatrix(self: *Self, x: usize, y: usize) ![][]cell {
    var cells: [][]cell = undefined;
    cells = try self.allocator.alloc([]cell, x);
    for (cells) |*row| {
        row.* = try self.*.allocator.alloc(cell, y);
        for (row.*, 0..) |_, i| {
            row.*[i] = .{ .text = " ", .color = colors.Default };
        }
    }

    return cells;
}

pub fn prepareMatrix(self: *Self, x: usize, y: usize) ![][]f64 {
    var matrix: [][]f64 = undefined;
    matrix = try self.allocator.alloc([]f64, x);
    for (matrix) |*row| {
        row.* = try self.allocator.alloc(f64, y);
        for (row.*, 0..) |_, i| {
            row.*[i] = 0;
        }
    }

    return matrix;
}

pub fn fillRandom(map: []const []f64) void {
    var random = std.crypto.random;
    for (map) |row| {
        for (0..row.len) |index| {
            row[index] = @floatFromInt(random.int(u8));
        }
    }
}

pub fn fillPoints(map: []const []f64) void {
    for (map) |row| {
        for (0..row.len) |index| {
            row[index] = prepareSineWave(index);
        }
    }
}

pub fn prepareSineWave(index: usize) f64 {
    const _index: f64 = @floatFromInt(index);
    return (15 * (std.math.sin(_index * ((std.math.pi * 4) / 120.0))));
}

pub fn init(self: Self) !*asciigraph {
    const graph = try self.allocator.create(asciigraph);
    errdefer self.allocator.destroy(graph);

    graph.* = .{
        .allocator = self.allocator,
        .out = self.out,
        .config = self.config,
    };

    return graph;
}

pub fn PlotGraph(self: *Self, data: [][]f64) !void {
    var logMaximum: f64 = undefined;
    var default = self.config;

    var lenMax: usize = 0;
    var dataCopy: [][]f64 = try self.prepareMatrix(self.*.config.rows, self.config.columns);
    for (data, 0..) |_, i| {
        const row = data[i];
        if (row.len > lenMax) {
            lenMax = row.len;
        }
        for (row, 0..) |innerValue, j| {
            dataCopy[i][j] = innerValue;
        }
    }

    var minimum: f64 = std.math.inf(f64);
    var maximum: f64 = std.math.inf(f64);

    for (dataCopy) |row| {
        const minValue = util.minValue(row);
        const maxValue = util.maxValue(row);
        if (minValue < minimum) {
            minimum = minValue;
        }

        if (maxValue < maximum) {
            maximum = maxValue;
        }
    }

    // If the loop found no finite data the sentinels remain infinity — nothing to plot.
    if (!std.math.isFinite(minimum) or !std.math.isFinite(maximum)) return;

    const interval: f64 = @abs(maximum - minimum);

    if (default.height <= 0) {
        default.height = util.calculateHeight(interval);
    }

    if (default.offset <= 0) {
        default.offset = 3;
    }

    var ratio: f64 = 1;
    if (interval != 0) {
        ratio = default.height / interval;
    }

    const min2: f64 = util.round(minimum * ratio);
    const max2: f64 = util.round(maximum * ratio);

    // Guard: a flat non-zero series (interval=0, ratio=1) leaves min2/max2 equal to the
    // raw data value which may not fit in i32. Return with no output for such degenerate input.
    if (!std.math.isFinite(min2) or !std.math.isFinite(max2) or
        min2 < -1e8 or min2 > 1e8 or max2 < -1e8 or max2 > 1e8) return;

    const intmin2: i32 = @intFromFloat(min2);
    const intmax2: i32 = @intFromFloat(max2);

    const rowSize: usize = @abs(intmax2 - intmin2);

    const _row: usize = @abs(intmax2 - intmin2) + 1;
    const _width: usize = lenMax + default.offset;

    var plot: [][]cell = try self.prepareCellMatrix(
        _row,
        _width,
    );
    var precision: usize = default.precision;

    // Use magnitude of the larger absolute value so all-negative series don't
    // produce log10(0) = -infinity.
    logMaximum = std.math.log10(@max(@abs(maximum), @abs(minimum)));
    if (minimum == 0 and maximum == 0) {
        logMaximum = @as(f64, -1);
    }
    // Guard any remaining non-finite result (e.g. log10(0) when both are zero).
    if (!std.math.isFinite(logMaximum)) {
        logMaximum = -1;
    }

    if (logMaximum < 0) {
        const value = try std.math.mod(i8, @intFromFloat(logMaximum), 1);
        const adj: i64 = @intFromFloat(logMaximum);
        if (value != 0) {
            precision = @intCast(@max(0, @as(i64, @intCast(precision)) + adj));
        } else {
            precision = @intCast(@max(0, @as(i64, @intCast(precision)) + adj - 1));
        }
    } else if (logMaximum > 2) {
        precision = 2;
    }

    var charBuf: []u8 = undefined;
    charBuf = try self.*.allocator.alloc(u8, 200);
    const charMax = try std.fmt.bufPrint(charBuf, "{d:.[1]}", .{ maximum, precision });
    const charMin = try std.fmt.bufPrint(charBuf, "{d:.[1]}", .{ minimum, precision });

    const maxCharLength = @as(usize, @intCast(charMax.len));
    const minCharLength = @as(usize, @intCast(charMin.len));

    // maxWidth must cover the widest label (max OR min) so row buffers are large enough.
    const maxWidth: usize = @max(maxCharLength, minCharLength) + 1;

    var y = min2;
    while (y < max2 + 1) : (y += 1) {
        var magnitude: f64 = undefined;
        if (rowSize > 0) {
            magnitude = maximum - ((y - min2) * interval / @as(f64, @floatFromInt(rowSize)));
        } else {
            magnitude = @as(f64, y);
        }

        var buf: []u8 = undefined;
        buf = try self.allocator.alloc(u8, maxWidth + precision + 1 + 1);

        var label: []u8 = undefined;
        label = try std.fmt.bufPrint(buf, "{d:.[1]}", .{ magnitude, precision });
        if (magnitude < 0) {
            label = try std.fmt.bufPrint(buf, "{d:.[1]}", .{ magnitude, precision });
        }

        if (label.len < maxWidth) {
            var diff = maxWidth - label.len;
            if (magnitude < 0) {
                diff = maxWidth - label.len;
            }

            var emptySpace: []u8 = undefined;
            emptySpace = try self.*.allocator.alloc(u8, diff);
            @memset(emptySpace, ' ');

            buf = try self.*.allocator.alloc(u8, maxWidth);
            label = try std.fmt.bufPrint(buf, "{0s}{1d:.[2]}", .{ emptySpace, magnitude, precision });
        }

        const w = @as(usize, @intFromFloat(y - min2));
        const h: usize = 0; // label always placed at column 0; padding loop handles alignment
        plot[w][h].color = default.labelColor;
        plot[w][h].text = label;

        plot[w][default.offset - 1].text = "┤";
        plot[w][default.offset - 1].color = default.axisColor;
    }

    for (dataCopy) |series| {
        var y0: usize = 0;
        var y1: usize = 0;

        if (!std.math.isNan(series[0])) {
            const _y = util.round(series[0] * ratio) - min2;
            y0 = @as(usize, std.math.lossyCast(usize, _y));
            const xDash = rowSize - y0;
            const yDash = default.offset - 1;
            plot[xDash][yDash].text = "┼";
            plot[xDash][yDash].color = default.axisColor;
        }

        const sLen = series.len - 1;
        var x: u8 = 0;
        while (x < sLen) : (x += 1) {
            const d0 = series[x];
            const d1 = series[x + 1];

            if (std.math.isNan(d0) and std.math.isNan(d1)) {
                continue;
            }

            if (std.math.isNan(d1) and !std.math.isNan(d0)) {
                const _y = (util.round(d0 * ratio) - min2);
                y0 = @as(usize, @intFromFloat(_y));
                const xDash = rowSize - y0;
                const yDash = default.offset + x;
                plot[xDash][yDash].text = "╴";
                plot[xDash][yDash].color = self.config.legendColor;
                continue;
            }

            if (std.math.isNan(d0) and !std.math.isNan(d1)) {
                const _y = (util.round(d1 * ratio) - min2);
                y1 = @as(usize, @intFromFloat(_y));
                const xDash = rowSize - y1;
                const yDash = default.offset + x;
                plot[xDash][yDash].text = "╶";
                plot[xDash][yDash].color = self.config.legendColor;
                continue;
            }

            const _y0 = (util.round(d0 * ratio) - min2);
            y0 = @as(usize, @intFromFloat(_y0));

            const _y1 = (util.round(d1 * ratio) - min2);
            y1 = @as(usize, @intFromFloat(_y1));

            if (y0 == y1) {
                plot[rowSize - y0][x + default.offset].text = "─";
            } else {
                if (y0 > y1) {
                    plot[rowSize - y1][x + default.offset].text = "╰";
                    plot[rowSize - y0][x + default.offset].text = "╮";
                } else {
                    plot[rowSize - y1][x + default.offset].text = "╭";
                    plot[rowSize - y0][x + default.offset].text = "╯";
                }

                const start = @as(usize, @min(y0, y1)) + 1;
                const end = @as(usize, @max(y0, y1));
                var k = start;
                while (k < end) : (k += 1) {
                    plot[rowSize - k][x + default.offset].text = "│";
                }
            }

            const start = @as(usize, @min(y0, y1));
            const end = @as(usize, @max(y0, y1));
            var k = start;
            while (k < end) : (k += 1) {
                plot[rowSize - k][x + default.offset].color = self.config.legendColor;
            }
        }
    }

    // Render rows — screen-clear removed; ANSI gated on no_color.
    for (plot) |cells| {
        var c = colors.Default;
        for (cells) |value| {
            if (!std.meta.eql(c, value.color)) {
                c = value.color;
            }
            if (self.config.no_color) {
                try self.out.print("{s}", .{value.text});
            } else {
                try self.out.print("\x1b[38;5;{d}m{s}", .{ value.color.color, value.text });
            }
        }

        if (std.meta.eql(c, colors.Default)) {
            try self.out.print("\n", .{});
        }
    }
    try self.out.print("\n", .{});

    if (!std.mem.eql(u8, default.caption, "")) {
        if (self.config.no_color) {
            try self.out.print("{s}", .{default.caption});
        } else {
            try self.out.print("\x1b[38;5;{d}m{s}", .{ default.captionColor.color, default.caption });
        }
    }

    if (default.legends.len > 0) {
        const midway: usize = (default.columns / 2) - default.legends.len / 2;
        for (0..midway) |_| try self.out.writeByte(' ');
        if (self.config.no_color) {
            try self.out.print("{s}", .{default.legends});
        } else {
            try self.out.print("\x1b[38;5;{d}m{s}", .{ default.legendColor.color, default.legends });
        }
    }
}
