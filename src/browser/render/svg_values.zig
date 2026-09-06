//! SVG values, inherited paint state, and viewport mapping. All text values
//! synchronously borrow the supplied DOM; this module owns no tree or pixels.

const std = @import("std");
const z2d = @import("z2d");
const dom = @import("../../document/dom.zig");
const colors = @import("../../document/color.zig");
const Numbers = @import("svg_path.zig").Numbers;
const Matrix = z2d.Transformation;
const Color = colors.Color;
const black = Color{ .r = 0, .g = 0, .b = 0 };
const namespace = "http://www.w3.org/2000/svg";
pub const max_pixels = 4 * 1024 * 1024;

pub fn attr(element: *const dom.Element, name: []const u8) ?[]const u8 {
    if (element.svg_animation) |state| if (state.values.get(name)) |value| return value;
    const attributes = element.attributes orelse return null;
    if (attributes.get(name)) |value| return value;
    // The HTML tokenizer folds foreign-content attribute names to lowercase.
    var iterator = attributes.iterator();
    while (iterator.next()) |entry| if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    return null;
}

pub fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// Live DOM styles have already cascaded presentation hints and author rules.
// Detached image trees use presentation attributes and inline declarations.
pub fn property(element: *const dom.Element, name: []const u8) ?[]const u8 {
    if (element.svg_animation) |state| if (state.values.get(name)) |value| return value;
    if (element.style) |styles| if (styles.get(name)) |field| {
        const value = field.get().*;
        if (!equal(value, "auto") and !equal(value, "inherit")) return value;
    };
    var result = attr(element, name);
    if (attr(element, "style")) |style| {
        var declarations = std.mem.splitScalar(u8, style, ';');
        while (declarations.next()) |declaration| {
            const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
            if (!equal(std.mem.trim(u8, declaration[0..colon], " \t\r\n"), name)) continue;
            result = std.mem.trim(u8, declaration[colon + 1 ..], " \t\r\n");
        }
    }
    return if (result) |value| std.mem.trim(u8, value, " \t\r\n") else null;
}

pub fn tag(element: *const dom.Element) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, element.tag, ':');
    const prefix = if (colon) |i| element.tag[0..i] else "";
    var cursor: ?*const dom.Element = element;
    while (cursor) |current| {
        if (current.attributes) |attributes| {
            var iterator = attributes.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                const matches = if (prefix.len == 0) equal(key, "xmlns") else std.mem.startsWith(u8, key, "xmlns:") and equal(key[6..], prefix);
                if (matches) return if (equal(entry.value_ptr.*, namespace))
                    element.tag[if (colon) |i| i + 1 else 0..]
                else
                    null;
            }
        }
        const parent = current.parent orelse break;
        cursor = if (parent.* == .element) &parent.element else null;
    }
    // Accept the common unprefixed, namespace-less standalone icon format.
    return if (colon == null) element.tag else null;
}

pub fn length(source: []const u8, basis: f64) !f64 {
    var numbers = Numbers{ .source = std.mem.trim(u8, source, " \t\r\n") };
    const value = try numbers.number();
    const unit = numbers.source[numbers.pos..];
    const scale: f64 = if (unit.len == 0 or equal(unit, "px")) 1 else if (equal(unit, "%")) basis / 100 else if (equal(unit, "in")) 96 else if (equal(unit, "cm")) 96.0 / 2.54 else if (equal(unit, "mm")) 96.0 / 25.4 else if (equal(unit, "pt")) 96.0 / 72.0 else if (equal(unit, "pc")) 16 else return error.UnsupportedSvgLength;
    return value * scale;
}

pub fn coordinate(element: *const dom.Element, name: []const u8, basis: f64, fallback: f64) !f64 {
    return if (property(element, name)) |value| try length(value, basis) else fallback;
}

pub fn opacity(source: []const u8) !f64 {
    return std.math.clamp(try length(source, 1), 0, 1);
}

pub const Viewport = struct {
    width: f64,
    height: f64,
    user_width: f64,
    user_height: f64,
    matrix: Matrix,

    pub fn parse(root: *const dom.Element) !Viewport {
        return parseSize(root, null);
    }

    pub fn parseSize(root: *const dom.Element, size: ?[2]f64) !Viewport {
        var box: ?[4]f64 = null;
        if (attr(root, "viewBox")) |source| {
            var numbers = Numbers{ .source = source };
            box = .{ try numbers.number(), try numbers.number(), try numbers.number(), try numbers.number() };
            if (!numbers.done() or box.?[2] <= 0 or box.?[3] <= 0) return error.InvalidSvgViewBox;
        }
        const width: ?f64 = if (size) |s| s[0] else if (property(root, "width")) |value| try length(value, 300) else null;
        const height: ?f64 = if (size) |s| s[1] else if (property(root, "height")) |value| try length(value, 150) else null;
        const ratio: ?f64 = if (box) |b| b[2] / b[3] else null;
        const w = width orelse if (height != null and ratio != null) height.? * ratio.? else if (ratio) |r| @min(300, 150 * r) else 300;
        const h = height orelse if (ratio) |r| w / r else 150;
        if (w <= 0 or h <= 0 or w > 4096 or h > 4096 or @ceil(w) * @ceil(h) > max_pixels) return error.InvalidSvgSize;
        var result = Viewport{ .width = w, .height = h, .user_width = w, .user_height = h, .matrix = .identity };
        if (box) |b| {
            result.user_width = b[2];
            result.user_height = b[3];
            var sx = w / b[2];
            var sy = h / b[3];
            var tx: f64 = 0;
            var ty: f64 = 0;
            var tokens = std.mem.tokenizeAny(u8, attr(root, "preserveAspectRatio") orelse "xMidYMid meet", " \t\r\n");
            var alignment = tokens.next() orelse "xMidYMid";
            if (equal(alignment, "defer")) alignment = tokens.next() orelse return error.InvalidSvgViewBox;
            if (!equal(alignment, "none")) {
                if (alignment.len != 8) return error.InvalidSvgViewBox;
                const mode = tokens.next() orelse "meet";
                if (!equal(mode, "meet") and !equal(mode, "slice")) return error.InvalidSvgViewBox;
                sx = if (equal(mode, "slice")) @max(sx, sy) else @min(sx, sy);
                sy = sx;
                const ax: f64 = if (equal(alignment[0..4], "xMin")) 0 else if (equal(alignment[0..4], "xMid")) 0.5 else if (equal(alignment[0..4], "xMax")) 1 else return error.InvalidSvgViewBox;
                const ay: f64 = if (equal(alignment[4..], "YMin")) 0 else if (equal(alignment[4..], "YMid")) 0.5 else if (equal(alignment[4..], "YMax")) 1 else return error.InvalidSvgViewBox;
                tx = (w - b[2] * sx) * ax;
                ty = (h - b[3] * sy) * ay;
            }
            result.matrix = Matrix.identity.translate(tx, ty).scale(sx, sy).translate(-b[0], -b[1]);
        }
        return result;
    }
};

pub fn transform(source: []const u8) !Matrix {
    if (equal(std.mem.trim(u8, source, " \t\r\n"), "none")) return .identity;
    var result = Matrix.identity;
    var pos: usize = 0;
    while (pos < source.len) {
        while (pos < source.len and (std.ascii.isWhitespace(source[pos]) or source[pos] == ',')) : (pos += 1) {}
        if (pos == source.len) break;
        const start = pos;
        while (pos < source.len and std.ascii.isAlphabetic(source[pos])) : (pos += 1) {}
        const name = source[start..pos];
        while (pos < source.len and std.ascii.isWhitespace(source[pos])) : (pos += 1) {}
        if (pos == source.len or source[pos] != '(') return error.InvalidSvgTransform;
        const end = std.mem.indexOfScalarPos(u8, source, pos + 1, ')') orelse return error.InvalidSvgTransform;
        var numbers = Numbers{ .source = source[pos + 1 .. end] };
        var values: [6]f64 = undefined;
        var count: usize = 0;
        while (!numbers.done()) {
            if (count == values.len) return error.InvalidSvgTransform;
            values[count] = try numbers.number();
            const rest = numbers.source[numbers.pos..];
            if (std.mem.startsWith(u8, rest, "px")) numbers.pos += 2;
            if (std.mem.startsWith(u8, rest, "deg")) numbers.pos += 3;
            count += 1;
        }
        const m = Matrix.identity;
        const next = if (equal(name, "matrix") and count == 6)
            Matrix{ .ax = values[0], .cx = values[1], .by = values[2], .dy = values[3], .tx = values[4], .ty = values[5] }
        else if (equal(name, "translate") and (count == 1 or count == 2))
            m.translate(values[0], if (count == 2) values[1] else 0)
        else if (equal(name, "scale") and (count == 1 or count == 2))
            m.scale(values[0], if (count == 2) values[1] else values[0])
        else if (equal(name, "rotate") and (count == 1 or count == 3)) blk: {
            const x = if (count == 3) values[1] else 0;
            const y = if (count == 3) values[2] else 0;
            break :blk m.translate(x, y).rotate(values[0] * std.math.pi / 180).translate(-x, -y);
        } else if (equal(name, "skewX") and count == 1) blk: {
            var skew = m;
            skew.by = @tan(values[0] * std.math.pi / 180);
            break :blk skew;
        } else if (equal(name, "skewY") and count == 1) blk: {
            var skew = m;
            skew.cx = @tan(values[0] * std.math.pi / 180);
            break :blk skew;
        } else return error.InvalidSvgTransform;
        result = result.mul(next);
        pos = end + 1;
    }
    return result;
}

pub const Paint = union(enum) {
    none,
    current_color,
    color: Color,
    server: []const u8,

    pub fn parse(source: []const u8) ?Paint {
        if (equal(source, "none")) return .none;
        if (equal(source, "currentColor")) return .current_color;
        if (colors.parse(source)) |color| return .{ .color = color };
        if (std.mem.startsWith(u8, source, "url(")) return .{ .server = source };
        return null;
    }

    pub fn pixel(self: Paint, current_color: Color, alpha: f64) ?z2d.pixel.RGBA {
        const color = switch (self) {
            .none => return null,
            .server => return null,
            .current_color => current_color,
            .color => |c| c,
        };
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = @intFromFloat(@round(@as(f64, @floatFromInt(color.a)) * alpha)) };
    }
};

pub const Style = struct {
    color: Color = black,
    fill: Paint = .{ .color = black },
    stroke: Paint = .none,
    fill_opacity: f64 = 1,
    stroke_opacity: f64 = 1,
    stroke_width: f64 = 1,
    fill_rule: z2d.options.FillRule = .non_zero,
    cap: z2d.options.CapMode = .butt,
    join: z2d.options.JoinMode = .miter,
    miter_limit: f64 = 4,
    visible: bool = true,

    /// Inherit current sampled paint instead of stale inherited computed values.
    /// The same rule supplies the use instance's parent paint to its target.
    pub fn deriveCascaded(self: Style, element: *const dom.Element, viewport: Viewport) !Style {
        var result = try self.derive(element, viewport);
        if (element.style != null) {
            inline for (.{ "fill", "stroke", "fill_opacity", "stroke_opacity", "stroke_width", "fill_rule", "cap", "join", "miter_limit", "color", "visible" }, 0..) |field, i| {
                const property_name = @import("../../document/svg.zig").instance_properties[i];
                const animated = if (element.svg_animation) |state| state.values.contains(property_name) else false;
                if (!animated and element.svg_specified_properties & (@as(u16, 1) << i) == 0) @field(result, field) = @field(self, field);
            }
        }
        return result;
    }

    pub fn derive(self: Style, element: *const dom.Element, viewport: Viewport) !Style {
        var result = self;
        if (property(element, "color")) |value| result.color = colors.parse(value) orelse self.color;
        if (property(element, "fill")) |value| result.fill = Paint.parse(value) orelse self.fill;
        if (property(element, "stroke")) |value| result.stroke = Paint.parse(value) orelse self.stroke;
        if (property(element, "fill-opacity")) |value| if (!equal(value, "inherit")) {
            result.fill_opacity = try opacity(value);
        };
        if (property(element, "stroke-opacity")) |value| if (!equal(value, "inherit")) {
            result.stroke_opacity = try opacity(value);
        };
        if (property(element, "stroke-width")) |value| if (!equal(value, "inherit")) {
            result.stroke_width = try length(value, @sqrt((viewport.user_width * viewport.user_width + viewport.user_height * viewport.user_height) / 2));
        };
        if (property(element, "fill-rule")) |value| {
            if (equal(value, "evenodd")) result.fill_rule = .even_odd;
            if (equal(value, "nonzero")) result.fill_rule = .non_zero;
        }
        if (property(element, "stroke-linecap")) |value| result.cap = std.meta.stringToEnum(z2d.options.CapMode, value) orelse self.cap;
        if (property(element, "stroke-linejoin")) |value| result.join = std.meta.stringToEnum(z2d.options.JoinMode, value) orelse self.join;
        if (property(element, "stroke-miterlimit")) |value| result.miter_limit = @max(1, try length(value, 1));
        if (property(element, "visibility")) |value| {
            if (equal(value, "visible")) result.visible = true;
            if (equal(value, "hidden") or equal(value, "collapse")) result.visible = false;
        }
        return result;
    }
};
