const std = @import("std");
const ansiColor = @import("ansiColor.zig");
pub const Config = @This();
const AnsiColor = ansiColor.AnsiColor;

pub const config = struct {
    rows: u8 = 0,
    columns: u8 = 0,
    width: f64 = 0,
    height: f64 = 0,
    offset: usize = 0,
    precision: usize = 2,
    caption: []const u8 = "",
    legends: []const u8 = "",
    captionColor: AnsiColor = ansiColor.Red,
    axisColor: AnsiColor = ansiColor.Red,
    labelColor: AnsiColor = ansiColor.Red,
    legendColor: AnsiColor = ansiColor.Yellow,
    /// When true, suppress all ANSI escape sequences in output.
    /// Set this when the output will be captured as a string rather than
    /// rendered to a terminal.
    no_color: bool = false,
};

pub fn adjustWidth(self: *config, w: i8) void {
    if (w > 0) {
        self.width = w;
        return;
    }
    self.width = 0;
}

pub fn adjustHeight(self: *config, h: i8) void {
    if (h > 0) {
        self.height = h;
        return;
    }
    self.height = 0;
}
