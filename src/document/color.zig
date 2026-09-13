//! CSS color values shared by style mutation and layout paint.

const std = @import("std");

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
/// Missing HSL components remain explicit in specified serialization and act
/// as zero when this absolute color is painted without interpolation.
pub const Absolute = struct {
    color: Color,
    alpha: f64,
    missing_hsl: ?[4]?f64 = null,
    srgb_components: ?[4]?f64 = null,

    pub fn serialize(self: Absolute, allocator: std.mem.Allocator) ![]u8 {
        if (self.missing_hsl orelse self.srgb_components) |components| {
            const hsl = self.missing_hsl != null;
            var text: [4][]const u8 = undefined;
            var buffers: [4][384]u8 = undefined;
            for (components, 0..) |component, i| {
                text[i] = if (component) |number| decimal(&buffers[i], number) else "none";
                if (hsl and (i == 1 or i == 2) and component != null) {
                    buffers[i][text[i].len] = '%';
                    text[i] = buffers[i][0 .. text[i].len + 1];
                }
            }
            const function = if (hsl) "hsl(" else "color(srgb ";
            if (components[3] == 1) return std.fmt.allocPrint(allocator, "{s}{s} {s} {s})", .{ function, text[0], text[1], text[2] });
            return std.fmt.allocPrint(allocator, "{s}{s} {s} {s} / {s})", .{ function, text[0], text[1], text[2], text[3] });
        }
        const c = self.color;
        if (self.alpha == 1) return std.fmt.allocPrint(allocator, "rgb({d}, {d}, {d})", .{ c.r, c.g, c.b });
        var buffer: [384]u8 = undefined;
        return std.fmt.allocPrint(allocator, "rgba({d}, {d}, {d}, {s})", .{ c.r, c.g, c.b, decimal(&buffer, self.alpha) });
    }
};

const lexer = @import("css_tokenizer.zig");

const math = @import("css_math.zig");
pub const Context = math.Context;

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

fn hslColor(h: f64, saturation: f64, lightness: f64, alpha: f64) Color {
    const s = std.math.clamp(saturation / 100, 0, 1);
    const l = std.math.clamp(lightness / 100, 0, 1);
    const amplitude = s * @min(l, 1 - l);
    var rgb: [3]u8 = undefined;
    for ([_]f64{ 0, 8, 4 }, 0..) |n, i| {
        const k = @mod(n + h / 30, 12);
        rgb[i] = byte((l - amplitude * @max(-1, @min(@min(k - 3, 9 - k), 1))) * 255);
    }
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = byte(alpha * 255) };
}

fn parseFunction(input: []const u8, context: Context) ?Absolute {
    var iterator = lexer.Iterator{ .input = input };
    var function = iterator.next() orelse return null;
    while (function.isTrivia()) function = iterator.next() orelse return null;
    if (function.kind != .function) return null;
    const name = function.encodedValue(input);
    const hsl = lexer.identifierEquals(name, "hsl") or lexer.identifierEquals(name, "hsla");
    const srgb = lexer.identifierEquals(name, "color");
    if (!hsl and !srgb and !lexer.identifierEquals(name, "rgb") and !lexer.identifierEquals(name, "rgba")) return null;
    const Component = struct { source: []const u8, kind: lexer.Kind, delim: u21 = 0 };
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
    if (srgb) {
        if (!@import("css_value_tokens.zig").isKeyword(arguments[0].source, "srgb")) return null;
        std.mem.copyForwards(Component, arguments[0 .. count - 1], arguments[1..count]);
        count -= 1;
    }
    const legacy = arguments[1].kind == .comma;
    if (srgb and legacy) return null;
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
    var values: [4]?f64 = .{ null, null, null, 1 };
    var first_dimension: ?math.Dimension = null;
    for (components[0..if (has_alpha) @as(usize, 4) else 3], 0..) |component, i| {
        if (!legacy and @import("css_value_tokens.zig").isKeyword(component.source, "none")) continue;
        const result = math.evaluate(component.source, context) orelse return null;
        if (i == 0 and hsl) {
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
        const number = result.value;
        values[i] = if (i == 3) bounded(if (result.dimension == .percentage) number / 100 else number, 0, 1) else if (hsl)
            bounded(number, 0, 100)
        else if (srgb)
            if (std.math.isNan(number)) 0 else if (result.dimension == .percentage) number / 100 else number
        else
            bounded(if (result.dimension == .percentage) number / 100 * 255 else number, 0, 255);
    }
    // Alpha defaults to one only when omitted; an explicit none is missing.
    if (has_alpha and @import("css_value_tokens.zig").isKeyword(components[3].source, "none")) values[3] = null;
    const alpha = values[3] orelse 0;
    const has_missing = values[0] == null or values[1] == null or values[2] == null or values[3] == null;
    if (hsl) return .{
        .color = hslColor(values[0] orelse 0, values[1] orelse 0, values[2] orelse 0, alpha),
        .alpha = alpha,
        .missing_hsl = if (has_missing) values else null,
    };
    var normalized = values;
    if (!srgb) for (normalized[0..3]) |*component| {
        if (component.*) |number| component.* = number / 255;
    };
    return .{
        .color = .{ .r = byte((normalized[0] orelse 0) * 255), .g = byte((normalized[1] orelse 0) * 255), .b = byte((normalized[2] orelse 0) * 255), .a = byte(alpha * 255) },
        .alpha = alpha,
        .srgb_components = if (srgb or has_missing) normalized else null,
    };
}

/// Parse absolute colors with initial relative-unit bases. Declaration callers
/// preserve calculations; computed style calls parseWithContext after cascade.
pub fn parseAbsolute(input: []const u8) ?Absolute {
    return parseWithContext(input, .{});
}

pub fn parseWithContext(input: []const u8, context: Context) ?Absolute {
    if (parseFunction(input, context)) |function| return function;
    const color = parseLiteral(input) orelse return null;
    const hundredth = @round(@as(f64, @floatFromInt(color.a)) / 255 * 100) / 100;
    const alpha = if (byte(hundredth * 255) == color.a) hundredth else @round(@as(f64, @floatFromInt(color.a)) / 255 * 1000) / 1000;
    return .{ .color = color, .alpha = alpha };
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
    const value = std.mem.trim(u8, input, " \t\r\n\x0c");
    return parseAbsolute(if (std.ascii.eqlIgnoreCase(value, "currentcolor")) foreground else value);
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
