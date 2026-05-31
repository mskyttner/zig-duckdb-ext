const std = @import("std");
pub const ansiColor = @This();

pub const AnsiColor = struct {
    color: u8 = 0,
    pub fn init(c: u8) AnsiColor {
        return AnsiColor{
            .color = c,
        };
    }

    pub fn toString(c: AnsiColor) []const u8 {
        if (std.meta.eql(c, Default)) {
            return "\x1b[0m";
        }

        if (std.meta.eql(c, Black)) {
            return "{d}";
        }

        if (std.meta.eql(c, Silver)) {
            return "\x1b[{d}m";
        }

        if (std.meta.eql(c, White)) {
            return "\x1b[{d}m";
        }

        return "\x1b[38;5;{d}m";
    }
};

pub const Default: AnsiColor = .{ .color = 15 };
pub const AliceBlue: AnsiColor = .{ .color = 255 };
pub const AntiqueWhite: AnsiColor = .{ .color = 255 };
pub const Aqua: AnsiColor = .{ .color = 14 };
pub const Aquamarine: AnsiColor = .{ .color = 122 };
pub const Azure: AnsiColor = .{ .color = 15 };
pub const Beige: AnsiColor = .{ .color = 230 };
pub const Bisque: AnsiColor = .{ .color = 224 };
pub const Black: AnsiColor = .{ .color = 188 };
pub const BlanchedAlmond: AnsiColor = .{ .color = 230 };
pub const Blue: AnsiColor = .{ .color = 12 };
pub const BlueViolet: AnsiColor = .{ .color = 92 };
pub const Brown: AnsiColor = .{ .color = 88 };
pub const BurlyWood: AnsiColor = .{ .color = 180 };
pub const CadetBlue: AnsiColor = .{ .color = 73 };
pub const Chartreuse: AnsiColor = .{ .color = 118 };
pub const Chocolate: AnsiColor = .{ .color = 166 };
pub const Coral: AnsiColor = .{ .color = 209 };
pub const CornflowerBlue: AnsiColor = .{ .color = 68 };
pub const Cornsilk: AnsiColor = .{ .color = 230 };
pub const Crimson: AnsiColor = .{ .color = 161 };
pub const Cyan: AnsiColor = .{ .color = 14 };
pub const DarkBlue: AnsiColor = .{ .color = 18 };
pub const DarkCyan: AnsiColor = .{ .color = 30 };
pub const DarkGoldenrod: AnsiColor = .{ .color = 136 };
pub const DarkGray: AnsiColor = .{ .color = 248 };
pub const DarkGreen: AnsiColor = .{ .color = 22 };
pub const DarkKhaki: AnsiColor = .{ .color = 143 };
pub const DarkMagenta: AnsiColor = .{ .color = 90 };
pub const DarkOliveGreen: AnsiColor = .{ .color = 59 };
pub const DarkOrange: AnsiColor = .{ .color = 208 };
pub const DarkOrchid: AnsiColor = .{ .color = 134 };
pub const DarkRed: AnsiColor = .{ .color = 88 };
pub const DarkSalmon: AnsiColor = .{ .color = 173 };
pub const DarkSeaGreen: AnsiColor = .{ .color = 108 };
pub const DarkSlateBlue: AnsiColor = .{ .color = 60 };
pub const DarkSlateGray: AnsiColor = .{ .color = 238 };
pub const DarkTurquoise: AnsiColor = .{ .color = 44 };
pub const DarkViolet: AnsiColor = .{ .color = 92 };
pub const DeepPink: AnsiColor = .{ .color = 198 };
pub const DeepSkyBlue: AnsiColor = .{ .color = 39 };
pub const DimGray: AnsiColor = .{ .color = 242 };
pub const DodgerBlue: AnsiColor = .{ .color = 33 };
pub const Firebrick: AnsiColor = .{ .color = 124 };
pub const FloralWhite: AnsiColor = .{ .color = 15 };
pub const ForestGreen: AnsiColor = .{ .color = 28 };
pub const Fuchsia: AnsiColor = .{ .color = 13 };
pub const Gainsboro: AnsiColor = .{ .color = 253 };
pub const GhostWhite: AnsiColor = .{ .color = 15 };
pub const Gold: AnsiColor = .{ .color = 220 };
pub const Goldenrod: AnsiColor = .{ .color = 178 };
pub const Gray: AnsiColor = .{ .color = 8 };
pub const Green: AnsiColor = .{ .color = 2 };
pub const GreenYellow: AnsiColor = .{ .color = 155 };
pub const Honeydew: AnsiColor = .{ .color = 15 };
pub const HotPink: AnsiColor = .{ .color = 205 };
pub const IndianRed: AnsiColor = .{ .color = 167 };
pub const Indigo: AnsiColor = .{ .color = 54 };
pub const Ivory: AnsiColor = .{ .color = 15 };
pub const Khaki: AnsiColor = .{ .color = 222 };
pub const Lavender: AnsiColor = .{ .color = 254 };
pub const LavenderBlush: AnsiColor = .{ .color = 255 };
pub const LawnGreen: AnsiColor = .{ .color = 118 };
pub const LemonChiffon: AnsiColor = .{ .color = 230 };
pub const LightBlue: AnsiColor = .{ .color = 152 };
pub const LightCoral: AnsiColor = .{ .color = 210 };
pub const LightCyan: AnsiColor = .{ .color = 195 };
pub const LightGoldenrodYellow: AnsiColor = .{ .color = 230 };
pub const LightGray: AnsiColor = .{ .color = 252 };
pub const LightGreen: AnsiColor = .{ .color = 120 };
pub const LightPink: AnsiColor = .{ .color = 217 };
pub const LightSalmon: AnsiColor = .{ .color = 216 };
pub const LightSeaGreen: AnsiColor = .{ .color = 37 };
pub const LightSkyBlue: AnsiColor = .{ .color = 117 };
pub const LightSlateGray: AnsiColor = .{ .color = 103 };
pub const LightSteelBlue: AnsiColor = .{ .color = 152 };
pub const LightYellow: AnsiColor = .{ .color = 230 };
pub const Lime: AnsiColor = .{ .color = 10 };
pub const LimeGreen: AnsiColor = .{ .color = 77 };
pub const Linen: AnsiColor = .{ .color = 255 };
pub const Magenta: AnsiColor = .{ .color = 13 };
pub const Maroon: AnsiColor = .{ .color = 1 };
pub const MediumAquamarine: AnsiColor = .{ .color = 79 };
pub const MediumBlue: AnsiColor = .{ .color = 20 };
pub const MediumOrchid: AnsiColor = .{ .color = 134 };
pub const MediumPurple: AnsiColor = .{ .color = 98 };
pub const MediumSeaGreen: AnsiColor = .{ .color = 72 };
pub const MediumSlateBlue: AnsiColor = .{ .color = 99 };
pub const MediumSpringGreen: AnsiColor = .{ .color = 48 };
pub const MediumTurquoise: AnsiColor = .{ .color = 80 };
pub const MediumVioletRed: AnsiColor = .{ .color = 162 };
pub const MidnightBlue: AnsiColor = .{ .color = 17 };
pub const MintCream: AnsiColor = .{ .color = 15 };
pub const MistyRose: AnsiColor = .{ .color = 224 };
pub const Moccasin: AnsiColor = .{ .color = 223 };
pub const NavajoWhite: AnsiColor = .{ .color = 223 };
pub const Navy: AnsiColor = .{ .color = 4 };
pub const OldLace: AnsiColor = .{ .color = 230 };
pub const Olive: AnsiColor = .{ .color = 3 };
pub const OliveDrab: AnsiColor = .{ .color = 64 };
pub const Orange: AnsiColor = .{ .color = 214 };
pub const OrangeRed: AnsiColor = .{ .color = 202 };
pub const Orchid: AnsiColor = .{ .color = 170 };
pub const PaleGoldenrod: AnsiColor = .{ .color = 223 };
pub const PaleGreen: AnsiColor = .{ .color = 120 };
pub const PaleTurquoise: AnsiColor = .{ .color = 159 };
pub const PaleVioletRed: AnsiColor = .{ .color = 168 };
pub const PapayaWhip: AnsiColor = .{ .color = 230 };
pub const PeachPuff: AnsiColor = .{ .color = 223 };
pub const Peru: AnsiColor = .{ .color = 173 };
pub const Pink: AnsiColor = .{ .color = 218 };
pub const Plum: AnsiColor = .{ .color = 182 };
pub const PowderBlue: AnsiColor = .{ .color = 152 };
pub const Purple: AnsiColor = .{ .color = 5 };
pub const Red: AnsiColor = .{ .color = 9 };
pub const RosyBrown: AnsiColor = .{ .color = 138 };
pub const RoyalBlue: AnsiColor = .{ .color = 63 };
pub const SaddleBrown: AnsiColor = .{ .color = 94 };
pub const Salmon: AnsiColor = .{ .color = 210 };
pub const SandyBrown: AnsiColor = .{ .color = 215 };
pub const SeaGreen: AnsiColor = .{ .color = 29 };
pub const SeaShell: AnsiColor = .{ .color = 15 };
pub const Sienna: AnsiColor = .{ .color = 131 };
pub const Silver: AnsiColor = .{ .color = 7 };
pub const SkyBlue: AnsiColor = .{ .color = 117 };
pub const SlateBlue: AnsiColor = .{ .color = 62 };
pub const SlateGray: AnsiColor = .{ .color = 66 };
pub const Snow: AnsiColor = .{ .color = 15 };
pub const SpringGreen: AnsiColor = .{ .color = 48 };
pub const SteelBlue: AnsiColor = .{ .color = 67 };
pub const Tan: AnsiColor = .{ .color = 180 };
pub const Teal: AnsiColor = .{ .color = 6 };
pub const Thistle: AnsiColor = .{ .color = 182 };
pub const Tomato: AnsiColor = .{ .color = 203 };
pub const Turquoise: AnsiColor = .{ .color = 80 };
pub const Violet: AnsiColor = .{ .color = 213 };
pub const Wheat: AnsiColor = .{ .color = 223 };
pub const White: AnsiColor = .{ .color = 15 };
pub const WhiteSmoke: AnsiColor = .{ .color = 255 };
pub const Yellow: AnsiColor = .{ .color = 11 };
pub const YellowGreen: AnsiColor = .{ .color = 149 };
