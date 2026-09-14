//! Borrowed CSS color grammar and owned serialization shared by declarations,
//! computed style and native paint. Absolute results contain copied coordinates.

const std = @import("std");
const spaces = @import("color_space.zig");
pub const interpolation = @import("color_interpolation.zig");
const mixes = @import("color_mix.zig");
const value_tokens = @import("css_value_tokens.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

const NamedColor = struct {
    name: []const u8,
    value: Color,
};

// CSS Color named sRGB keywords, including spelling aliases.
// https://drafts.csswg.org/css-color-4/#named-colors
const named_colors = [_]NamedColor{
    .{ .name = "transparent", .value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    .{ .name = "aliceblue", .value = .{ .r = 240, .g = 248, .b = 255 } },
    .{ .name = "antiquewhite", .value = .{ .r = 250, .g = 235, .b = 215 } },
    .{ .name = "aqua", .value = .{ .r = 0, .g = 255, .b = 255 } },
    .{ .name = "aquamarine", .value = .{ .r = 127, .g = 255, .b = 212 } },
    .{ .name = "azure", .value = .{ .r = 240, .g = 255, .b = 255 } },
    .{ .name = "beige", .value = .{ .r = 245, .g = 245, .b = 220 } },
    .{ .name = "bisque", .value = .{ .r = 255, .g = 228, .b = 196 } },
    .{ .name = "black", .value = .{ .r = 0, .g = 0, .b = 0 } },
    .{ .name = "blanchedalmond", .value = .{ .r = 255, .g = 235, .b = 205 } },
    .{ .name = "blue", .value = .{ .r = 0, .g = 0, .b = 255 } },
    .{ .name = "blueviolet", .value = .{ .r = 138, .g = 43, .b = 226 } },
    .{ .name = "brown", .value = .{ .r = 165, .g = 42, .b = 42 } },
    .{ .name = "burlywood", .value = .{ .r = 222, .g = 184, .b = 135 } },
    .{ .name = "cadetblue", .value = .{ .r = 95, .g = 158, .b = 160 } },
    .{ .name = "chartreuse", .value = .{ .r = 127, .g = 255, .b = 0 } },
    .{ .name = "chocolate", .value = .{ .r = 210, .g = 105, .b = 30 } },
    .{ .name = "coral", .value = .{ .r = 255, .g = 127, .b = 80 } },
    .{ .name = "cornflowerblue", .value = .{ .r = 100, .g = 149, .b = 237 } },
    .{ .name = "cornsilk", .value = .{ .r = 255, .g = 248, .b = 220 } },
    .{ .name = "crimson", .value = .{ .r = 220, .g = 20, .b = 60 } },
    .{ .name = "cyan", .value = .{ .r = 0, .g = 255, .b = 255 } },
    .{ .name = "darkblue", .value = .{ .r = 0, .g = 0, .b = 139 } },
    .{ .name = "darkcyan", .value = .{ .r = 0, .g = 139, .b = 139 } },
    .{ .name = "darkgoldenrod", .value = .{ .r = 184, .g = 134, .b = 11 } },
    .{ .name = "darkgray", .value = .{ .r = 169, .g = 169, .b = 169 } },
    .{ .name = "darkgreen", .value = .{ .r = 0, .g = 100, .b = 0 } },
    .{ .name = "darkgrey", .value = .{ .r = 169, .g = 169, .b = 169 } },
    .{ .name = "darkkhaki", .value = .{ .r = 189, .g = 183, .b = 107 } },
    .{ .name = "darkmagenta", .value = .{ .r = 139, .g = 0, .b = 139 } },
    .{ .name = "darkolivegreen", .value = .{ .r = 85, .g = 107, .b = 47 } },
    .{ .name = "darkorange", .value = .{ .r = 255, .g = 140, .b = 0 } },
    .{ .name = "darkorchid", .value = .{ .r = 153, .g = 50, .b = 204 } },
    .{ .name = "darkred", .value = .{ .r = 139, .g = 0, .b = 0 } },
    .{ .name = "darksalmon", .value = .{ .r = 233, .g = 150, .b = 122 } },
    .{ .name = "darkseagreen", .value = .{ .r = 143, .g = 188, .b = 143 } },
    .{ .name = "darkslateblue", .value = .{ .r = 72, .g = 61, .b = 139 } },
    .{ .name = "darkslategray", .value = .{ .r = 47, .g = 79, .b = 79 } },
    .{ .name = "darkslategrey", .value = .{ .r = 47, .g = 79, .b = 79 } },
    .{ .name = "darkturquoise", .value = .{ .r = 0, .g = 206, .b = 209 } },
    .{ .name = "darkviolet", .value = .{ .r = 148, .g = 0, .b = 211 } },
    .{ .name = "deeppink", .value = .{ .r = 255, .g = 20, .b = 147 } },
    .{ .name = "deepskyblue", .value = .{ .r = 0, .g = 191, .b = 255 } },
    .{ .name = "dimgray", .value = .{ .r = 105, .g = 105, .b = 105 } },
    .{ .name = "dimgrey", .value = .{ .r = 105, .g = 105, .b = 105 } },
    .{ .name = "dodgerblue", .value = .{ .r = 30, .g = 144, .b = 255 } },
    .{ .name = "firebrick", .value = .{ .r = 178, .g = 34, .b = 34 } },
    .{ .name = "floralwhite", .value = .{ .r = 255, .g = 250, .b = 240 } },
    .{ .name = "forestgreen", .value = .{ .r = 34, .g = 139, .b = 34 } },
    .{ .name = "fuchsia", .value = .{ .r = 255, .g = 0, .b = 255 } },
    .{ .name = "gainsboro", .value = .{ .r = 220, .g = 220, .b = 220 } },
    .{ .name = "ghostwhite", .value = .{ .r = 248, .g = 248, .b = 255 } },
    .{ .name = "gold", .value = .{ .r = 255, .g = 215, .b = 0 } },
    .{ .name = "goldenrod", .value = .{ .r = 218, .g = 165, .b = 32 } },
    .{ .name = "gray", .value = .{ .r = 128, .g = 128, .b = 128 } },
    .{ .name = "green", .value = .{ .r = 0, .g = 128, .b = 0 } },
    .{ .name = "greenyellow", .value = .{ .r = 173, .g = 255, .b = 47 } },
    .{ .name = "grey", .value = .{ .r = 128, .g = 128, .b = 128 } },
    .{ .name = "honeydew", .value = .{ .r = 240, .g = 255, .b = 240 } },
    .{ .name = "hotpink", .value = .{ .r = 255, .g = 105, .b = 180 } },
    .{ .name = "indianred", .value = .{ .r = 205, .g = 92, .b = 92 } },
    .{ .name = "indigo", .value = .{ .r = 75, .g = 0, .b = 130 } },
    .{ .name = "ivory", .value = .{ .r = 255, .g = 255, .b = 240 } },
    .{ .name = "khaki", .value = .{ .r = 240, .g = 230, .b = 140 } },
    .{ .name = "lavender", .value = .{ .r = 230, .g = 230, .b = 250 } },
    .{ .name = "lavenderblush", .value = .{ .r = 255, .g = 240, .b = 245 } },
    .{ .name = "lawngreen", .value = .{ .r = 124, .g = 252, .b = 0 } },
    .{ .name = "lemonchiffon", .value = .{ .r = 255, .g = 250, .b = 205 } },
    .{ .name = "lightblue", .value = .{ .r = 173, .g = 216, .b = 230 } },
    .{ .name = "lightcoral", .value = .{ .r = 240, .g = 128, .b = 128 } },
    .{ .name = "lightcyan", .value = .{ .r = 224, .g = 255, .b = 255 } },
    .{ .name = "lightgoldenrodyellow", .value = .{ .r = 250, .g = 250, .b = 210 } },
    .{ .name = "lightgray", .value = .{ .r = 211, .g = 211, .b = 211 } },
    .{ .name = "lightgreen", .value = .{ .r = 144, .g = 238, .b = 144 } },
    .{ .name = "lightgrey", .value = .{ .r = 211, .g = 211, .b = 211 } },
    .{ .name = "lightpink", .value = .{ .r = 255, .g = 182, .b = 193 } },
    .{ .name = "lightsalmon", .value = .{ .r = 255, .g = 160, .b = 122 } },
    .{ .name = "lightseagreen", .value = .{ .r = 32, .g = 178, .b = 170 } },
    .{ .name = "lightskyblue", .value = .{ .r = 135, .g = 206, .b = 250 } },
    .{ .name = "lightslategray", .value = .{ .r = 119, .g = 136, .b = 153 } },
    .{ .name = "lightslategrey", .value = .{ .r = 119, .g = 136, .b = 153 } },
    .{ .name = "lightsteelblue", .value = .{ .r = 176, .g = 196, .b = 222 } },
    .{ .name = "lightyellow", .value = .{ .r = 255, .g = 255, .b = 224 } },
    .{ .name = "lime", .value = .{ .r = 0, .g = 255, .b = 0 } },
    .{ .name = "limegreen", .value = .{ .r = 50, .g = 205, .b = 50 } },
    .{ .name = "linen", .value = .{ .r = 250, .g = 240, .b = 230 } },
    .{ .name = "magenta", .value = .{ .r = 255, .g = 0, .b = 255 } },
    .{ .name = "maroon", .value = .{ .r = 128, .g = 0, .b = 0 } },
    .{ .name = "mediumaquamarine", .value = .{ .r = 102, .g = 205, .b = 170 } },
    .{ .name = "mediumblue", .value = .{ .r = 0, .g = 0, .b = 205 } },
    .{ .name = "mediumorchid", .value = .{ .r = 186, .g = 85, .b = 211 } },
    .{ .name = "mediumpurple", .value = .{ .r = 147, .g = 112, .b = 219 } },
    .{ .name = "mediumseagreen", .value = .{ .r = 60, .g = 179, .b = 113 } },
    .{ .name = "mediumslateblue", .value = .{ .r = 123, .g = 104, .b = 238 } },
    .{ .name = "mediumspringgreen", .value = .{ .r = 0, .g = 250, .b = 154 } },
    .{ .name = "mediumturquoise", .value = .{ .r = 72, .g = 209, .b = 204 } },
    .{ .name = "mediumvioletred", .value = .{ .r = 199, .g = 21, .b = 133 } },
    .{ .name = "midnightblue", .value = .{ .r = 25, .g = 25, .b = 112 } },
    .{ .name = "mintcream", .value = .{ .r = 245, .g = 255, .b = 250 } },
    .{ .name = "mistyrose", .value = .{ .r = 255, .g = 228, .b = 225 } },
    .{ .name = "moccasin", .value = .{ .r = 255, .g = 228, .b = 181 } },
    .{ .name = "navajowhite", .value = .{ .r = 255, .g = 222, .b = 173 } },
    .{ .name = "navy", .value = .{ .r = 0, .g = 0, .b = 128 } },
    .{ .name = "oldlace", .value = .{ .r = 253, .g = 245, .b = 230 } },
    .{ .name = "olive", .value = .{ .r = 128, .g = 128, .b = 0 } },
    .{ .name = "olivedrab", .value = .{ .r = 107, .g = 142, .b = 35 } },
    .{ .name = "orange", .value = .{ .r = 255, .g = 165, .b = 0 } },
    .{ .name = "orangered", .value = .{ .r = 255, .g = 69, .b = 0 } },
    .{ .name = "orchid", .value = .{ .r = 218, .g = 112, .b = 214 } },
    .{ .name = "palegoldenrod", .value = .{ .r = 238, .g = 232, .b = 170 } },
    .{ .name = "palegreen", .value = .{ .r = 152, .g = 251, .b = 152 } },
    .{ .name = "paleturquoise", .value = .{ .r = 175, .g = 238, .b = 238 } },
    .{ .name = "palevioletred", .value = .{ .r = 219, .g = 112, .b = 147 } },
    .{ .name = "papayawhip", .value = .{ .r = 255, .g = 239, .b = 213 } },
    .{ .name = "peachpuff", .value = .{ .r = 255, .g = 218, .b = 185 } },
    .{ .name = "peru", .value = .{ .r = 205, .g = 133, .b = 63 } },
    .{ .name = "pink", .value = .{ .r = 255, .g = 192, .b = 203 } },
    .{ .name = "plum", .value = .{ .r = 221, .g = 160, .b = 221 } },
    .{ .name = "powderblue", .value = .{ .r = 176, .g = 224, .b = 230 } },
    .{ .name = "purple", .value = .{ .r = 128, .g = 0, .b = 128 } },
    .{ .name = "rebeccapurple", .value = .{ .r = 102, .g = 51, .b = 153 } },
    .{ .name = "red", .value = .{ .r = 255, .g = 0, .b = 0 } },
    .{ .name = "rosybrown", .value = .{ .r = 188, .g = 143, .b = 143 } },
    .{ .name = "royalblue", .value = .{ .r = 65, .g = 105, .b = 225 } },
    .{ .name = "saddlebrown", .value = .{ .r = 139, .g = 69, .b = 19 } },
    .{ .name = "salmon", .value = .{ .r = 250, .g = 128, .b = 114 } },
    .{ .name = "sandybrown", .value = .{ .r = 244, .g = 164, .b = 96 } },
    .{ .name = "seagreen", .value = .{ .r = 46, .g = 139, .b = 87 } },
    .{ .name = "seashell", .value = .{ .r = 255, .g = 245, .b = 238 } },
    .{ .name = "sienna", .value = .{ .r = 160, .g = 82, .b = 45 } },
    .{ .name = "silver", .value = .{ .r = 192, .g = 192, .b = 192 } },
    .{ .name = "skyblue", .value = .{ .r = 135, .g = 206, .b = 235 } },
    .{ .name = "slateblue", .value = .{ .r = 106, .g = 90, .b = 205 } },
    .{ .name = "slategray", .value = .{ .r = 112, .g = 128, .b = 144 } },
    .{ .name = "slategrey", .value = .{ .r = 112, .g = 128, .b = 144 } },
    .{ .name = "snow", .value = .{ .r = 255, .g = 250, .b = 250 } },
    .{ .name = "springgreen", .value = .{ .r = 0, .g = 255, .b = 127 } },
    .{ .name = "steelblue", .value = .{ .r = 70, .g = 130, .b = 180 } },
    .{ .name = "tan", .value = .{ .r = 210, .g = 180, .b = 140 } },
    .{ .name = "teal", .value = .{ .r = 0, .g = 128, .b = 128 } },
    .{ .name = "thistle", .value = .{ .r = 216, .g = 191, .b = 216 } },
    .{ .name = "tomato", .value = .{ .r = 255, .g = 99, .b = 71 } },
    .{ .name = "turquoise", .value = .{ .r = 64, .g = 224, .b = 208 } },
    .{ .name = "violet", .value = .{ .r = 238, .g = 130, .b = 238 } },
    .{ .name = "wheat", .value = .{ .r = 245, .g = 222, .b = 179 } },
    .{ .name = "white", .value = .{ .r = 255, .g = 255, .b = 255 } },
    .{ .name = "whitesmoke", .value = .{ .r = 245, .g = 245, .b = 245 } },
    .{ .name = "yellow", .value = .{ .r = 255, .g = 255, .b = 0 } },
    .{ .name = "yellowgreen", .value = .{ .r = 154, .g = 205, .b = 50 } },
};

fn expandHexNibble(input: []const u8) ?u8 {
    const nibble = std.fmt.parseInt(u8, input, 16) catch return null;
    return nibble * 17;
}

/// Absolute colors keep alpha precision for CSSOM; painting uses RGBA8.
/// Modern coordinates retain their space and precision through serialization;
/// missing components act as zero when painted without interpolation.
pub const Absolute = struct {
    color: Color,
    alpha: f64,
    coordinates: spaces.Coordinates,
    legacy: bool,
    quantized_alpha: bool = false,

    /// Copy normalized coordinates and cache their RGBA8 paint projection.
    /// legacy identifies the originating syntax, not the destination space.
    pub fn fromCoordinates(coordinates: spaces.Coordinates, legacy: bool) Absolute {
        const alpha = bounded(coordinates.components[3] orelse 0, 0, 1);
        const rgb = spaces.toPaint(coordinates.space, coordinates.values());
        var clamped = coordinates;
        if (clamped.components[3] != null) clamped.components[3] = alpha;
        return .{
            .color = .{ .r = byte(rgb[0] * 255), .g = byte(rgb[1] * 255), .b = byte(rgb[2] * 255), .a = byte(alpha * 255) },
            .alpha = alpha,
            .coordinates = clamped,
            .legacy = legacy,
        };
    }

    /// Lift a legacy byte color, retaining its exact alpha for interpolation.
    pub fn fromColor(color: Color) Absolute {
        const alpha = @as(f64, @floatFromInt(color.a)) / 255;
        return .{
            .color = color,
            .alpha = alpha,
            .coordinates = .{ .space = .srgb, .components = .{ @as(f64, @floatFromInt(color.r)) / 255, @as(f64, @floatFromInt(color.g)) / 255, @as(f64, @floatFromInt(color.b)) / 255, alpha } },
            .legacy = true,
            .quantized_alpha = true,
        };
    }

    pub fn serialize(self: Absolute, allocator: std.mem.Allocator) ![]u8 {
        if (!self.legacy) {
            var modern = self.coordinates;
            // A resolved polar sRGB mix uses color(srgb), preserving fractional
            // channels. Missing polar components still require their own syntax.
            if ((modern.space == .hsl or modern.space == .hwb) and !hasMissing(modern.components)) {
                const rgb = spaces.toSrgb(modern.space, modern.values());
                modern = .{ .space = .srgb, .components = .{ rgb[0], rgb[1], rgb[2], modern.components[3] } };
            }
            const components = modern.components;
            const percentages = modern.space == .hsl or modern.space == .hwb;
            var text: [4][]const u8 = undefined;
            var buffers: [4][384]u8 = undefined;
            for (components, 0..) |component, i| {
                text[i] = if (component) |number| decimal(&buffers[i], number) else "none";
                if (percentages and (i == 1 or i == 2) and component != null) {
                    buffers[i][text[i].len] = '%';
                    text[i] = buffers[i][0 .. text[i].len + 1];
                }
            }
            var prefix: [64]u8 = undefined;
            const function = if (modern.space.predefined())
                std.fmt.bufPrint(&prefix, "color({s} ", .{modern.space.name()}) catch unreachable
            else
                std.fmt.bufPrint(&prefix, "{s}(", .{modern.space.name()}) catch unreachable;
            if (components[3] == 1) return std.fmt.allocPrint(allocator, "{s}{s} {s} {s})", .{ function, text[0], text[1], text[2] });
            return std.fmt.allocPrint(allocator, "{s}{s} {s} {s} / {s})", .{ function, text[0], text[1], text[2], text[3] });
        }
        const c = self.color;
        if (self.alpha == 1) return std.fmt.allocPrint(allocator, "rgb({d}, {d}, {d})", .{ c.r, c.g, c.b });
        var buffer: [384]u8 = undefined;
        const hundredth = @round(self.alpha * 100) / 100;
        const alpha = if (!self.quantized_alpha) self.alpha else if (byte(hundredth * 255) == c.a) hundredth else @round(self.alpha * 1000) / 1000;
        return std.fmt.allocPrint(allocator, "rgba({d}, {d}, {d}, {s})", .{ c.r, c.g, c.b, decimal(&buffer, alpha) });
    }
};

fn hasMissing(components: [4]?f64) bool {
    for (components) |value| if (value == null) return true;
    return false;
}

const lexer = @import("css_tokenizer.zig");

const math = @import("css_math.zig");
pub const Context = struct {
    font_size: f64 = 16,
    root_font_size: f64 = 16,
    current_color: ?Absolute = null,

    fn numeric(self: Context) math.Context {
        return .{ .font_size = self.font_size, .root_font_size = self.root_font_size };
    }
};

fn decimal(buffer: []u8, value: f64) []const u8 {
    if (std.math.isNan(value)) return "calc(NaN)";
    if (std.math.isInf(value)) return if (value < 0) "calc(-infinity)" else "calc(infinity)";
    if (value != 0 and @abs(value) < 0.00000001) return std.fmt.bufPrint(buffer, "{d}", .{value}) catch unreachable;
    const text = std.fmt.bufPrint(buffer, "{d:.8}", .{if (value == 0) @as(f64, 0) else value}) catch unreachable;
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}

/// Keep calculations in specified values until the style owner has supplied
/// the element's computed unit context. This scan never retains input.
pub fn hasCalculation(input: []const u8) bool {
    var iterator = lexer.Iterator{ .input = input };
    while (iterator.next()) |token| if (token.kind == .function and math.isMath(token.raw(input))) return true;
    return false;
}

pub fn hasRelativeUnits(input: []const u8) bool {
    var iterator = lexer.Iterator{ .input = input };
    while (iterator.next()) |token| {
        if (token.kind != .dimension) continue;
        const unit = token.encodedValue(input);
        if (lexer.identifierEquals(unit, "em") or lexer.identifierEquals(unit, "rem")) return true;
    }
    return false;
}

fn bounded(value: f64, minimum: f64, maximum: f64) f64 {
    return if (std.math.isNan(value)) minimum else std.math.clamp(value, minimum, maximum);
}

fn byte(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}

const Component = struct { source: []const u8, kind: lexer.Kind, delim: u21 = 0 };
const Function = struct {
    space: spaces.Space,
    predefined: bool,
    legacy: bool,
    components: [4]Component,
    has_alpha: bool,
};

fn readFunction(input: []const u8) ?Function {
    var iterator = lexer.Iterator{ .input = input };
    var function = iterator.next() orelse return null;
    while (function.isTrivia()) function = iterator.next() orelse return null;
    if (function.kind != .function) return null;
    const name = function.encodedValue(input);
    const hsl = lexer.identifierEquals(name, "hsl") or lexer.identifierEquals(name, "hsla");
    const predefined = lexer.identifierEquals(name, "color");
    var space: spaces.Space = if (hsl) .hsl else .srgb;
    if (!hsl and !predefined and !lexer.identifierEquals(name, "rgb") and !lexer.identifierEquals(name, "rgba")) {
        space = inline for ([_]spaces.Space{ .hwb, .lab, .lch, .oklab, .oklch }) |candidate| {
            if (lexer.identifierEquals(name, candidate.name())) break candidate;
        } else return null;
    }
    var arguments: [8]Component = undefined;
    var count: usize = 0;
    var closed = false;
    while (iterator.next()) |token| {
        if (token.isTrivia()) continue;
        if (token.kind == .close_paren) {
            closed = true;
            break;
        }
        if (count == arguments.len) return null;
        var end = token.end;
        if (token.kind == .function) {
            end = (@import("css_value_tokens.zig").closeFunction(input, token.end) orelse return null) + 1;
            iterator.cursor = end;
        }
        arguments[count] = .{ .source = input[token.start..end], .kind = token.kind, .delim = token.delim };
        count += 1;
    }
    if (!closed or count < 3) return null;
    while (iterator.next()) |token| if (!token.isTrivia()) return null;
    if (predefined) {
        if (arguments[0].kind != .ident) return null;
        space = spaces.Space.parsePredefined(arguments[0].source) orelse return null;
        std.mem.copyForwards(Component, arguments[0 .. count - 1], arguments[1..count]);
        count -= 1;
    }
    const legacy = arguments[1].kind == .comma;
    if (legacy and (predefined or (space != .srgb and space != .hsl))) return null;
    var components: [4]Component = undefined;
    var has_alpha = false;
    if (legacy) {
        if ((count != 5 and count != 7) or arguments[3].kind != .comma) return null;
        for (0..3) |i| components[i] = arguments[i * 2];
        if (count == 7) {
            if (arguments[5].kind != .comma) return null;
            components[3] = arguments[6];
            has_alpha = true;
        }
    } else {
        if (count != 3 and count != 5) return null;
        @memcpy(components[0..3], arguments[0..3]);
        if (count == 5) {
            if (arguments[3].kind != .delim or arguments[3].delim != '/') return null;
            components[3] = arguments[4];
            has_alpha = true;
        }
    }
    return .{ .space = space, .predefined = predefined, .legacy = legacy, .components = components, .has_alpha = has_alpha };
}

fn parseFunction(input: []const u8, context: Context) ?Absolute {
    const function = readFunction(input) orelse return null;
    const space = function.space;
    const predefined = function.predefined;
    const legacy = function.legacy;
    const hsl = space == .hsl;
    const components = function.components;
    const has_alpha = function.has_alpha;
    var values: [4]?f64 = .{ null, null, null, 1 };
    var first_dimension: ?math.Dimension = null;
    for (components[0..if (has_alpha) @as(usize, 4) else 3], 0..) |component, i| {
        if (!legacy and @import("css_value_tokens.zig").isKeyword(component.source, "none")) continue;
        const result = math.evaluate(component.source, context.numeric()) orelse return null;
        const hue = (i == 0 and (space == .hsl or space == .hwb)) or (i == 2 and (space == .lch or space == .oklch));
        if (hue) {
            if (result.dimension != .number and result.dimension != .angle) return null;
            values[i] = if (std.math.isFinite(result.value)) @mod(result.value, 360) else 0;
            continue;
        }
        if (result.dimension != .number and result.dimension != .percentage) return null;
        if (legacy and i < 3) {
            if (hsl and result.dimension != .percentage) return null;
            if (!hsl and first_dimension != null and result.dimension != first_dimension.?) return null;
            first_dimension = result.dimension;
        }
        var number = result.value;
        if (result.dimension == .percentage) number = number / 100 * (if (i == 3) @as(f64, 1) else switch (space) {
            .hsl, .hwb => 100,
            .lab => if (i == 0) @as(f64, 100) else 125,
            .lch => if (i == 0) @as(f64, 100) else 150,
            .oklab, .oklch => if (i == 0) @as(f64, 1) else 0.4,
            else => if (predefined) @as(f64, 1) else 255,
        });
        values[i] = if (i == 3) bounded(number, 0, 1) else switch (space) {
            .hsl, .hwb => bounded(number, 0, 100),
            .lab, .lch => if (i == 0) bounded(number, 0, 100) else if (space == .lch) @max(0, number) else if (std.math.isNan(number)) 0 else number,
            .oklab, .oklch => if (i == 0) bounded(number, 0, 1) else if (space == .oklch) @max(0, number) else if (std.math.isNan(number)) 0 else number,
            else => if (!predefined) bounded(number, 0, 255) else if (std.math.isNan(number)) 0 else number,
        };
    }
    // Alpha defaults to one only when omitted; an explicit none is missing.
    if (has_alpha and @import("css_value_tokens.zig").isKeyword(components[3].source, "none")) values[3] = null;
    const has_missing = hasMissing(values);
    if (space == .srgb and !predefined) for (values[0..3]) |*component| {
        if (component.*) |number| component.* = number / 255;
    };
    return Absolute.fromCoordinates(.{ .space = space, .components = values }, !predefined and !has_missing and (space == .srgb or space == .hsl or space == .hwb));
}

/// Parse absolute colors with initial relative-unit bases. Declaration callers
/// preserve calculations; computed style calls parseWithContext after cascade.
pub fn parseAbsolute(input: []const u8) ?Absolute {
    return parseWithContext(input, .{});
}

/// Resolve using caller-supplied computed units and optional currentcolor.
/// A context-dependent mix returns null when that foreground is unavailable.
pub fn parseWithContext(input: []const u8, context: Context) ?Absolute {
    if (input.len > 1024 * 1024) return null;
    return parseNested(input, context, 0);
}

fn parseNested(input: []const u8, context: Context, depth: usize) ?Absolute {
    if (depth == 64) return null;
    if (value_tokens.isKeyword(input, "currentcolor")) return context.current_color;
    if (mixes.parse(input)) |mix| {
        const weights = mix.weights(context.numeric()) orelse return null;
        var colors: [mixes.max_colors]spaces.Coordinates = undefined;
        for (mix.items[0..mix.count], 0..) |item, i| colors[i] = (parseNested(item.color, context, depth + 1) orelse return null).coordinates;
        var result = interpolation.mix(colors[0..mix.count], weights.values[0..mix.count], mix.method);
        if (result.components[3]) |alpha| result.components[3] = alpha * weights.alpha;
        return Absolute.fromCoordinates(result, false);
    }
    if (parseFunction(input, context)) |function| return function;
    return Absolute.fromColor(parseLiteral(input) orelse return null);
}

/// Shared declaration admission includes currentcolor at any nesting depth.
/// The placeholder proves grammar only and is never published as computed data.
pub fn isValid(input: []const u8) bool {
    return parseWithContext(input, .{ .current_color = Absolute.fromColor(.{ .r = 0, .g = 0, .b = 0 }) }) != null;
}

pub fn hasCurrentColor(input: []const u8) bool {
    var iterator = lexer.Iterator{ .input = input };
    while (iterator.next()) |token| if (token.kind == .ident and lexer.identifierEquals(token.encodedValue(input), "currentcolor")) return true;
    return false;
}

/// Recognize the first function token; this is not a grammar validity check.
pub fn isMix(input: []const u8) bool {
    var iterator = lexer.Iterator{ .input = input };
    while (iterator.next()) |token| {
        if (token.isTrivia()) continue;
        return token.kind == .function and lexer.identifierEquals(token.encodedValue(input), "color-mix");
    }
    return false;
}

/// Caller owns CSSOM specified text. Calculations and currentcolor remain
/// symbolic; legacy operands use their canonical RGB serialization.
pub fn serializeSpecified(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    if (input.len > 1024 * 1024) return null;
    return serializeValue(allocator, input, .{}, .specified, false, 0);
}

/// Caller owns retained declaration text. Nested legacy operands keep fractional
/// channels independently of the CSSOM presentation returned above.
pub fn normalizeSpecified(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    if (input.len > 1024 * 1024) return null;
    return serializeValue(allocator, input, .{}, .retained, false, 0);
}

/// Caller owns an interpolation operand without legacy channel quantization.
/// Supplying context computes font-dependent channels before inheritance;
/// omitted current_color remains symbolic for the eventual receiving element.
pub fn normalizeInterpolationOperand(allocator: std.mem.Allocator, input: []const u8, context: ?Context) !?[]u8 {
    if (input.len > 1024 * 1024) return null;
    return serializeValue(allocator, input, context orelse .{}, if (context != null) .computed else .retained, true, 0);
}

/// Caller owns computed text. Without current_color, nested currentcolor stays
/// symbolic while font-dependent channels and weights compute before inheritance.
pub fn serializeComputed(allocator: std.mem.Allocator, input: []const u8, context: Context) !?[]u8 {
    if (input.len > 1024 * 1024) return null;
    return serializeValue(allocator, input, context, .computed, false, 0);
}

const Serialization = enum { specified, retained, computed };
fn serializeValue(allocator: std.mem.Allocator, input: []const u8, context: Context, mode: Serialization, nested: bool, depth: usize) std.mem.Allocator.Error!?[]u8 {
    if (depth == 64) return null;
    if (value_tokens.isKeyword(input, "currentcolor")) {
        if (mode == .computed) if (context.current_color) |current| return try current.serialize(allocator);
        return try allocator.dupe(u8, "currentcolor");
    }
    if (mode == .computed) if (parseNested(input, context, depth)) |absolute| return try serializeOperand(allocator, absolute, nested);
    if (mixes.parse(input)) |mix| {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        try output.appendSlice(allocator, "color-mix(");
        if (mix.method.space != .oklab) {
            try output.appendSlice(allocator, "in ");
            try output.appendSlice(allocator, mix.method.space.name());
            if (mix.method.hue != .shorter) {
                try output.append(allocator, ' ');
                try output.appendSlice(allocator, @tagName(mix.method.hue));
                try output.appendSlice(allocator, " hue");
            }
            try output.appendSlice(allocator, ", ");
        }
        var values: [mixes.max_colors]?f64 = undefined;
        var total: f64 = 0;
        var omitted: usize = 0;
        var unknown = false;
        for (mix.items[0..mix.count], 0..) |item, i| {
            values[i] = null;
            if (item.percentage) |source| {
                if (mode != .computed and math.isMath(source)) {
                    unknown = true;
                } else {
                    values[i] = mixes.percentage(source, context.numeric()) orelse return null;
                    total += values[i].?;
                }
            } else omitted += 1;
        }
        var equal = !unknown;
        const share = 100 / @as(f64, @floatFromInt(mix.count));
        for (mix.items[0..mix.count], 0..) |item, i| {
            if (!unknown and item.percentage == null) values[i] = @max(0, 100 - total) / @as(f64, @floatFromInt(@max(1, omitted)));
            equal = equal and values[i] != null and @abs(values[i].? - share) < 0.0000000001;
        }
        for (mix.items[0..mix.count], 0..) |item, i| {
            if (i != 0) try output.appendSlice(allocator, ", ");
            const child = try serializeValue(allocator, item.color, context, mode, true, depth + 1) orelse return null;
            defer allocator.free(child);
            try output.appendSlice(allocator, child);
            if (!equal) {
                if (values[i]) |number| {
                    var buffer: [384]u8 = undefined;
                    try output.append(allocator, ' ');
                    try output.appendSlice(allocator, decimal(&buffer, number));
                    try output.append(allocator, '%');
                } else if (item.percentage) |source| {
                    const calculation = try math.serializeSpecified(allocator, source, context.numeric()) orelse try allocator.dupe(u8, source);
                    defer allocator.free(calculation);
                    try output.append(allocator, ' ');
                    try output.appendSlice(allocator, calculation);
                }
            }
        }
        try output.append(allocator, ')');
        return try output.toOwnedSlice(allocator);
    }
    const absolute = parseNested(input, context, depth) orelse return null;
    if (readFunction(input)) |function| {
        if (mode != .computed and hasCalculation(input) and (!absolute.legacy or hasRelativeUnits(input))) {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(allocator);
            const name = if (function.space == .srgb and !function.predefined) "rgb" else function.space.name();
            if (function.predefined) try output.appendSlice(allocator, "color(");
            try output.appendSlice(allocator, name);
            try output.append(allocator, if (function.predefined) ' ' else '(');
            for (function.components[0..if (function.has_alpha) @as(usize, 4) else 3], 0..) |component, i| {
                if (i != 0) try output.appendSlice(allocator, if (i == 3) " / " else " ");
                if (math.isMath(component.source)) {
                    const calculation = try math.serializeSpecified(allocator, component.source, context.numeric()) orelse try allocator.dupe(u8, component.source);
                    defer allocator.free(calculation);
                    try output.appendSlice(allocator, calculation);
                } else if (absolute.coordinates.components[i]) |number| {
                    var buffer: [384]u8 = undefined;
                    const value = if (function.space == .srgb and !function.predefined and i < 3) number * 255 else number;
                    try output.appendSlice(allocator, decimal(&buffer, value));
                    if ((function.space == .hsl or function.space == .hwb) and (i == 1 or i == 2)) try output.append(allocator, '%');
                } else try output.appendSlice(allocator, "none");
            }
            try output.append(allocator, ')');
            return try output.toOwnedSlice(allocator);
        }
        if (nested and mode != .specified) return try serializeOperand(allocator, absolute, true);
    } else if (input.len != 0 and input[0] != '#') {
        return try std.ascii.allocLowerString(allocator, std.mem.trim(u8, input, " \t\r\n\x0c"));
    }
    return try absolute.serialize(allocator);
}

fn serializeOperand(allocator: std.mem.Allocator, absolute: Absolute, fractional: bool) ![]u8 {
    if (!fractional or !absolute.legacy) return absolute.serialize(allocator);
    const rgb = spaces.toSrgb(absolute.coordinates.space, absolute.coordinates.values());
    var buffers: [4][384]u8 = undefined;
    const r = decimal(&buffers[0], rgb[0] * 255);
    const g = decimal(&buffers[1], rgb[1] * 255);
    const b = decimal(&buffers[2], rgb[2] * 255);
    if (absolute.alpha == 1) return std.fmt.allocPrint(allocator, "rgb({s}, {s}, {s})", .{ r, g, b });
    return std.fmt.allocPrint(allocator, "rgba({s}, {s}, {s}, {s})", .{ r, g, b, decimal(&buffers[3], absolute.alpha) });
}

/// Resolve an absolute color into the renderer's RGBA8 representation.
pub fn parse(input: []const u8) ?Color {
    return (parseAbsolute(input) orelse return null).color;
}

/// Resolve an absolute color or currentcolor without retaining either input.
/// The caller supplies the same element's resolved foreground, or the parent's
/// foreground when resolving the color property itself. CSSOM retains alpha
/// precision; paint callers consume the returned RGBA8 projection.
pub fn resolve(input: []const u8, foreground: []const u8) ?Absolute {
    return parseWithContext(input, .{ .current_color = parseAbsolute(foreground) });
}

test "color mix preserves specified calculations weights nesting and scalar precision" {
    const cases = .{
        .{ "lab(calc(50 * 3) 50% 0 / calc(-1))", "lab(calc(150) 62.5 0 / calc(-1))" },
        .{ "color-mix(in oklab, red 50%, blue)", "color-mix(red, blue)" },
        .{ "color-mix(in hsl shorter hue, 25% red, blue)", "color-mix(in hsl, red 25%, blue 75%)" },
        .{ "color-mix(in srgb, red calc(20% * 2), currentcolor)", "color-mix(in srgb, red calc(40%), currentcolor)" },
        .{ "color-mix(in srgb, color-mix(in srgb, red, blue), white)", "color-mix(in srgb, color-mix(in srgb, red, blue), white)" },
    };
    inline for (cases) |case| {
        const specified = (try serializeSpecified(std.testing.allocator, case[0])).?;
        defer std.testing.allocator.free(specified);
        try std.testing.expectEqualStrings(case[1], specified);
        try std.testing.expect(isValid(specified));
    }
    const mixed = parseAbsolute("color-mix(in srgb, rgb(10.25 20.5 30.75 / .2), rgb(100.5 110.75 120.25 / .8))").?;
    try std.testing.expectApproxEqAbs(@as(f64, 82.45 / 255.0), mixed.coordinates.components[0].?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), mixed.alpha, 0.000001);
    const zero = parseAbsolute("color-mix(in srgb, red 0%, blue 0%)").?;
    try std.testing.expectEqual([4]?f64{ 0.5, 0, 0.5, 0 }, zero.coordinates.components);
    const three_zero = parseAbsolute("color-mix(in srgb, red 0%, lime 0%, blue 0%)").?;
    try std.testing.expectEqual([4]?f64{ 0.25, 0.25, 0.5, 0 }, three_zero.coordinates.components);
    const ordered = parseAbsolute("color-mix(in hsl, hsl(0 100% 50%), hsl(120 100% 50%), hsl(240 100% 50%))").?;
    try std.testing.expectApproxEqAbs(@as(f64, 120), ordered.coordinates.components[0].?, 0.000001);
    try std.testing.expect(!isValid("color-mix(in srgb, red, bogus)"));
    try std.testing.expect(!isValid("color-mix(in srgb, red 101%, blue)"));
    try std.testing.expect(parseAbsolute("color-mix(currentcolor, blue)") == null);
    try std.testing.expect(!isValid("color-mix(" ** 64 ++ "red" ++ ", blue)" ** 64));
}

test "computed mixes preserve receiving currentcolor while resolving font-dependent operands" {
    const source = "color-mix(in srgb, currentcolor, rgb(calc(1em / 1px) 0 0))";
    const computed = (try serializeComputed(std.testing.allocator, source, .{ .font_size = 20 })).?;
    defer std.testing.allocator.free(computed);
    try std.testing.expectEqualStrings("color-mix(in srgb, currentcolor, rgb(20, 0, 0))", computed);
    const red = resolve(computed, "red").?;
    const blue = resolve(computed, "blue").?;
    try std.testing.expectEqual(Color{ .r = 138, .g = 0, .b = 0 }, red.color);
    try std.testing.expectEqual(Color{ .r = 10, .g = 0, .b = 128 }, blue.color);
    try std.testing.expectEqual(Color{ .r = 188, .g = 0, .b = 188 }, parseAbsolute("color-mix(in srgb-linear, red, blue)").?.color);
    const precise = (try serializeComputed(std.testing.allocator, "color-mix(in srgb, currentcolor, rgb(calc(1em / 1px) 0 0))", .{ .font_size = 20.25 })).?;
    defer std.testing.allocator.free(precise);
    try std.testing.expectEqualStrings("color-mix(in srgb, currentcolor, rgb(20.25, 0, 0))", precise);
}

fn serializeColorAllocationCheck(allocator: std.mem.Allocator) !void {
    const value = (try serializeSpecified(allocator, "color-mix(in srgb, lab(calc(40 + 10) 0 0), currentcolor calc(50% * sign(100em - 1px)))")).?;
    defer allocator.free(value);
}

test "color calculation and mix serialization releases partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, serializeColorAllocationCheck, .{});
}

test "modern color serialization preserves spaces missing components and extended coordinates" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "LAB(20% -50% 90% / 50%)", "lab(20 -62.5 112.5 / 0.5)" },
        .{ "oklab(20% 70% -80%)", "oklab(0.2 0.28 -0.32)" },
        .{ "lch(40% 50% 1turn / none)", "lch(40 75 0 / none)" },
        .{ "oklch(60% -10 -90deg)", "oklch(0.6 0 270)" },
        .{ "oklch(200% 80% 100grad / 140%)", "oklch(1 0.32 90)" },
        .{ "color(DISPLAY-P3 120% -0.2 none / none)", "color(display-p3 1.2 -0.2 none / none)" },
        .{ "color(srgb-linear 50% 0 0)", "color(srgb-linear 0.5 0 0)" },
        .{ "color(display-p3-linear 0.5 0 0)", "color(display-p3-linear 0.5 0 0)" },
        .{ "color(xyz 10% 20% 30%)", "color(xyz-d65 0.1 0.2 0.3)" },
        .{ "color(xyz-d50 0.1 0.2 0.3 / 0.123456)", "color(xyz-d50 0.1 0.2 0.3 / 0.123456)" },
        .{ "hwb(none 40% none / none)", "hwb(none 40% none / none)" },
        .{ "lab(calc(NaN) 0 0)", "lab(0 0 0)" },
        .{ "lch(50 calc(-infinity) calc(infinity))", "lch(50 0 0)" },
        .{ "color(a98-rgb calc(infinity) 0 0)", "color(a98-rgb calc(infinity) 0 0)" },
        .{ "color(prophoto-rgb none none none)", "color(prophoto-rgb none none none)" },
        .{ "color(rec2020 0 0 0)", "color(rec2020 0 0 0)" },
        .{ "o\\6b lch(0.5 0.1 30)", "oklch(0.5 0.1 30)" },
        .{ "color(\\64 isplay-p3 0 0 0)", "color(display-p3 0 0 0)" },
    };
    for (cases) |case| {
        const parsed = parseAbsolute(case[0]).?;
        const text = try parsed.serialize(allocator);
        defer allocator.free(text);
        try std.testing.expectEqualStrings(case[1], text);
        const roundtrip = try parseAbsolute(text).?.serialize(allocator);
        defer allocator.free(roundtrip);
        try std.testing.expectEqualStrings(text, roundtrip);
    }
}

test "modern color grammar uses typed calculations and rejects unsupported syntax" {
    const value = "oklch(calc(50% + sign(1em - 10px) * 10%) 0.2 30 / .5)";
    try std.testing.expectEqual(@as(?f64, 0.6), parseWithContext(value, .{ .font_size = 20 }).?.coordinates.components[0]);
    try std.testing.expectEqual(@as(?f64, 0.4), parseWithContext(value, .{ .font_size = 8 }).?.coordinates.components[0]);
    for ([_][]const u8{
        "lab(1, 2, 3)",              "oklch(0.5 0.2 30%)",              "lab(20% 0 10deg)",
        "color(lab 0.5 0 0)",        "color(--custom 0 0 0)",           "color(srgb 1 2)",
        "color(display-p3 1, 0, 0)", "oklab(0 0 0 1)",                  "hwb(0, 0%, 0%)",
        "oklch(from red l c h)",     "color-mix(in future, red, blue)", "lab(calc(1s) 0 0)",
        "color(xyz calc(1deg) 0 0)",
    }) |input| try std.testing.expect(parseAbsolute(input) == null);
}

test "modern color paint converts reference colors and clamps lightness endpoints" {
    for ([_][]const u8{
        "lab(46.2775% -47.5621 48.5837)",            "lch(46.2775% 67.9892 134.3912)",
        "oklab(51.975% -0.1403 0.10768)",            "oklch(51.975% 0.17686 142.495)",
        "color(display-p3 0.21604 0.49418 0.13151)", "color(srgb-linear 0 0.21586 0)",
        "hwb(120 0% 49.8039%)",
    }) |input| try std.testing.expectEqual(Color{ .r = 0, .g = 128, .b = 0 }, parse(input).?);
    try std.testing.expectEqual(Color{ .r = 128, .g = 128, .b = 128 }, parse("hwb(0 100% 100%)").?);
    try std.testing.expectEqual(Color{ .r = 77, .g = 128, .b = 77 }, parse("hwb(120 30% 50%)").?);
    try std.testing.expectEqual(Color{ .r = 153, .g = 77, .b = 128 }, parse("hwb(320deg 30% 40%)").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, parse("lch(100 110 180)").?);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, parse("oklch(0 1e300 30)").?);
}

test "CSS resolved colors preserve alpha and cover named color aliases" {
    try std.testing.expectEqual(Color{ .r = 102, .g = 51, .b = 153 }, parse("RebeccaPurple").?);
    try std.testing.expectEqual(Color{ .r = 0, .g = 128, .b = 128 }, parse("teal").?);
    try std.testing.expectEqual(Color{ .r = 240, .g = 248, .b = 255 }, parse("aliceblue").?);
    try std.testing.expectEqual(parse("cyan").?, parse("aqua").?);
    try std.testing.expectEqual(parse("darkgray").?, parse("darkgrey").?);
    try std.testing.expect(parse("dark-grey") == null);
    const color = resolve(" CURRENTcolor ", "rgb(1 2 3 / .12345)").?;
    const text = try color.serialize(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("rgba(1, 2, 3, 0.12345)", text);
    try std.testing.expectEqual(parse("green").?, resolve("green", "invalid").?.color);
    try std.testing.expect(resolve("currentcolor", "currentcolor") == null);
    const transparent = resolve("transparent", "red").?;
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, transparent.color);
}

fn parseLiteral(input: []const u8) ?Color {
    var value = std.mem.trim(u8, input, " \t\r\n");
    var hash: [9]u8 = undefined;
    if (std.mem.startsWith(u8, value, "#")) {
        // Color grammar consumes the decoded hash value, irrespective of its
        // identifier flag. Serialized ID hashes may still escape leading digits.
        const tokens = @import("css_tokenizer.zig");
        var iterator = tokens.Iterator{ .input = value };
        const token = iterator.next().?;
        if (token.kind != .hash or token.end != value.len) return null;
        var decoder = tokens.Decoder{ .input = token.encodedValue(value) };
        hash[0] = '#';
        var size: usize = 1;
        while (decoder.next()) |point| {
            if (point > 127 or !std.ascii.isHex(@intCast(point)) or size == hash.len) return null;
            hash[size] = @intCast(point);
            size += 1;
        }
        value = hash[0..size];
    }
    if ((value.len == 4 or value.len == 5) and value[0] == '#') {
        return .{
            .r = expandHexNibble(value[1..2]) orelse return null,
            .g = expandHexNibble(value[2..3]) orelse return null,
            .b = expandHexNibble(value[3..4]) orelse return null,
            .a = if (value.len == 5) expandHexNibble(value[4..5]) orelse return null else 255,
        };
    }
    if (value.len == 9 and value[0] == '#') {
        return .{
            .r = std.fmt.parseInt(u8, value[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, value[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, value[5..7], 16) catch return null,
            .a = std.fmt.parseInt(u8, value[7..9], 16) catch return null,
        };
    }
    if (value.len == 7 and value[0] == '#') {
        return .{
            .r = std.fmt.parseInt(u8, value[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, value[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, value[5..7], 16) catch return null,
        };
    }

    for (named_colors) |named| {
        if (std.ascii.eqlIgnoreCase(value, named.name)) return named.value;
    }
    return null;
}

test "CSS colors parse named and alpha-bearing values" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, parse(" RED ").?);
    try std.testing.expectEqual(Color{ .r = 128, .g = 0, .b = 0 }, parse("maroon").?);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 128 }, parse("NAVY").?);
    try std.testing.expectEqual(Color{ .r = 192, .g = 192, .b = 192 }, parse("silver").?);
    try std.testing.expectEqual(Color{ .r = 0x12, .g = 0x34, .b = 0x56 }, parse("#123456").?);
    try std.testing.expectEqual(Color{ .r = 0xff, .g = 0xcc, .b = 0x00 }, parse("#FC0").?);
    try std.testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33 }, parse("#\\31 23").?);
    try std.testing.expectEqual(Color{ .r = 0xff, .g = 0xcc, .b = 0x00 }, parse("#\\66 c0").?);
    try std.testing.expect(parse("#12/**/3") == null);
    try std.testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 }, parse("#1234").?);
    try std.testing.expectEqual(
        Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 },
        parse("#12345678").?,
    );
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, parse("transparent").?);
    try std.testing.expectEqual(Color{ .r = 204, .g = 0, .b = 0 }, parse("rgb(204, 0, 0)").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 128, .b = 0 }, parse("rgb(100%, 50%, 0%)").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0, .a = 128 }, parse("rgba(255, 0, 0, .5)").?);
    try std.testing.expectEqual(Color{ .r = 0, .g = 255, .b = 0 }, parse("lime").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 255 }, parse("fuchsia").?);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, parse("hsla(0, 0%, 0%, 1.0)").?);
    try std.testing.expectEqual(Color{ .r = 0, .g = 255, .b = 0 }, parse("hsl(120, 100%, 50%)").?);
    try std.testing.expect(parse("not-a-color") == null);
}

test "CSS RGB HSL grammar shares aliases hue units missing components and alpha serialization" {
    const cases = [_][2][]const u8{
        .{ "rgb(20, 10, 0, -10)", "rgba(20, 10, 0, 0)" },
        .{ "rgba(255 20% 102 / 12.5%)", "rgba(255, 51, 102, 0.125)" },
        .{ "rgb(none 50% none / none)", "color(srgb none 0.5 none / none)" },
        .{ "rgb(0 0 0 / 0.999)", "rgba(0, 0, 0, 0.999)" },
        .{ "rgba(1, 2, 3)", "rgb(1, 2, 3)" },
        .{ "hsl(120deg 30% 50% / 0.5)", "rgba(89, 166, 89, 0.5)" },
        .{ "hsl(-0.5turn 100 50)", "rgb(0, 255, 255)" },
        .{ "hsla(200grad, 100%, 50%)", "rgb(0, 255, 255)" },
        .{ "hsl(3.141592653589793rad 100% 50%)", "rgb(0, 255, 255)" },
        .{ "hsla(120 none 50% / none)", "hsl(120 none 50% / none)" },
        .{ "#00000080", "rgba(0, 0, 0, 0.5)" },
    };
    for (cases) |case| {
        const parsed = parseAbsolute(case[0]).?;
        const text = try parsed.serialize(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case[1], text);
        try std.testing.expectEqual(parsed.color, parse(text).?);
    }
    for ([_][]const u8{
        "rgb(10%, 20%, 3)",  "rgba(1, 2, 3 / 0.5)", "rgb(1 2, 3)",       "rgb(1, 2, 3,)",
        "hsl(120, 50, 30%)", "hsl(20% 50% 50%)",    "hsl(none, 0%, 0%)", "rgb(1px 2 3)",
        "rgb(1 2 3) red",    "rgb(1 2 3",           "rgb(1e999 0 0)",    "hsl(1 2 3 4)",
    }) |invalid| try std.testing.expect(parse(invalid) == null);
}

test "CSS color math resolves typed channels nonfinite bounds and relative font context" {
    const cases = [_][2][]const u8{
        .{ "rgb(calc(infinity), calc(-infinity), calc(0 / 0))", "rgb(255, 0, 0)" },
        .{ "rgb(calc(20 + 30) 0 calc(25% * 2) / clamp(0, .5, 1))", "rgba(50, 0, 128, 0.5)" },
        .{ "hsl(calc(.5turn + 60deg) 100% 50% / calc(NaN))", "rgba(0, 0, 255, 0)" },
        .{ "rgb(128 none 20% / none)", "color(srgb 0.50196078 none 0.2 / none)" },
        .{ "hsl(120 none 50% / none)", "hsl(120 none 50% / none)" },
    };
    for (cases) |case| {
        const result = parseAbsolute(case[0]).?;
        const serialized = try result.serialize(std.testing.allocator);
        defer std.testing.allocator.free(serialized);
        try std.testing.expectEqualStrings(case[1], serialized);
        try std.testing.expectEqual(result.color, parse(serialized).?);
    }
    const relative = "rgb(calc(50% + sign(1em - 10px) * 10%) 0 0 / .5)";
    try std.testing.expectEqual(@as(u8, 102), parseWithContext(relative, .{ .font_size = 8 }).?.color.r);
    try std.testing.expectEqual(@as(u8, 153), parseWithContext(relative, .{ .font_size = 20 }).?.color.r);
    for ([_][]const u8{ "rgb(calc(1px) 0 0)", "rgb(calc(10% + 2deg) 0 0)", "rgb(calc(1) , 20% , 0%)", "hsl(calc(1%) 0 0)" }) |input| {
        try std.testing.expect(parseAbsolute(input) == null);
    }
}
