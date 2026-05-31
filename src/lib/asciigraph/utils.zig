pub const Util = @This();
const std = @import("std");

pub fn calculateHeight(interval: f64) f64 {
    if (interval >= 1) {
        return interval;
    }

    const log10 = std.math.log10(interval);
    const scaleFactor = std.math.pow(f64, 10, std.math.floor(log10));
    const scaledDelta = interval / scaleFactor;

    if (scaleFactor < 2) {
        return std.math.ceil(scaledDelta);
    }

    return std.math.floor(scaledDelta);
}

pub fn interpolateArray(allocator: std.mem.Allocator, data: []f64, fitCount: f64) anyerror![]f64 {
    var arr: std.ArrayList(f64) = .{};

    const sizeInFloat: f64 = @floatFromInt(data.len);
    const springFactor = (sizeInFloat - 1) / (fitCount - 1);

    try arr.append(allocator, data[0]);

    var index: f64 = 0;
    while (index < fitCount - 1) : (index += 1) {
        const spring: f64 = index * springFactor;
        const before: usize = @intFromFloat(@floor(spring));
        const after: usize = @intFromFloat(@floor(spring));
        const atPoint: f64 = spring - @as(f64, @floatFromInt(before));
        const atValue: f64 = linearInterpolate(data[before], data[after], atPoint);
        try arr.append(allocator, atValue);
    }

    try arr.append(allocator, data[data.len - 1]);
    return arr.toOwnedSlice(allocator);
}

pub fn linearInterpolate(before: f64, after: f64, atPoint: f64) f64 {
    return before + (after - before) * atPoint;
}

pub fn round(input: f64) f64 {
    if (std.math.isNan(input)) return input;
    var _input = input;

    var sign: f64 = 1.0;
    if (input < 0) {
        sign = -1;
        _input *= -1;
    }

    const decimal = std.math.modf(_input);
    var rounded: f64 = 0.0;
    if (decimal.fpart >= 0.5) {
        rounded = std.math.ceil(_input);
    } else {
        rounded = std.math.floor(_input);
    }

    return rounded * sign;
}

pub fn minValue(values: []f64) f64 {
    var min: f64 = 0.0;

    for (values) |value| {
        if (min > value) {
            min = value;
        }
    }

    return min;
}

pub fn maxValue(values: []f64) f64 {
    var max: f64 = 0.0;

    for (values) |value| {
        if (max < value) {
            max = value;
        }
    }

    return max;
}
