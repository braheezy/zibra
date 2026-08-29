//! Pure CSS used-value and box-geometry helpers for layout.
//!
//! This module does not own layout objects or register invalidation edges. It
//! converts already-computed style values into scalar geometry consumed by
//! `layout.zig`.

const std = @import("std");
const parser = @import("../../document/parser.zig");

const min_effective_zoom: f32 = 0.01;
const max_effective_zoom: f32 = 1024.0;

pub const ContentBounds = struct {
    x: i32,
    width: i32,
};

pub const FloatSide = enum {
    none,
    left,
    right,
};

pub const ClearSide = enum {
    none,
    left,
    right,
    both,
};

pub const PositionMode = enum {
    static,
    relative,
    absolute,
};

pub const PositionOffset = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const BoxEdges = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    pub fn horizontal(self: BoxEdges) i32 {
        return self.left + self.right;
    }

    pub fn vertical(self: BoxEdges) i32 {
        return self.top + self.bottom;
    }
};

pub const FloatBox = struct {
    side: FloatSide,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    margin: BoxEdges,

    pub fn bottom(self: FloatBox) i32 {
        return self.y +| self.height +| self.margin.bottom;
    }

    pub fn top(self: FloatBox) i32 {
        return self.y -| self.margin.top;
    }

    pub fn leftEdge(self: FloatBox) i32 {
        return self.x -| self.margin.left;
    }

    pub fn rightEdge(self: FloatBox) i32 {
        return self.x +| self.width +| self.margin.right;
    }
};

pub const BoxModelEdges = struct {
    margin: BoxEdges,
    padding: BoxEdges,
    border: BoxEdges,
};

pub const EmbeddedBlockBox = struct {
    x: i32,
    y: i32,
    width: i32,
};

pub fn parseFloatSide(value: []const u8) FloatSide {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "left")) return .left;
    if (std.ascii.eqlIgnoreCase(trimmed, "right")) return .right;
    return .none;
}

pub fn parseClearSide(value: []const u8) ClearSide {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "left")) return .left;
    if (std.ascii.eqlIgnoreCase(trimmed, "right")) return .right;
    if (std.ascii.eqlIgnoreCase(trimmed, "both")) return .both;
    return .none;
}

pub fn parsePositionMode(value: []const u8) PositionMode {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "relative")) return .relative;
    if (std.ascii.eqlIgnoreCase(trimmed, "absolute")) return .absolute;
    return .static;
}

/// Parse the standardized number/percentage grammar for `zoom`. Invalid,
/// negative, and zero values use the initial factor of one.
pub fn parseCssZoom(value: []const u8) f32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or
        std.ascii.eqlIgnoreCase(trimmed, "normal") or
        std.ascii.eqlIgnoreCase(trimmed, "reset"))
    {
        return 1.0;
    }

    const percentage = std.mem.endsWith(u8, trimmed, "%");
    const number = if (percentage)
        std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n")
    else
        trimmed;
    const parsed = std.fmt.parseFloat(f32, number) catch return 1.0;
    if (!std.math.isFinite(parsed) or parsed <= 0.0) return 1.0;
    return if (percentage) parsed / 100.0 else parsed;
}

pub fn combinedEffectiveZoom(parent_zoom: f32, local_zoom: f32) f32 {
    const parent = if (std.math.isFinite(parent_zoom) and parent_zoom > 0.0) parent_zoom else 1.0;
    const local = if (std.math.isFinite(local_zoom) and local_zoom > 0.0) local_zoom else 1.0;
    return std.math.clamp(parent * local, min_effective_zoom, max_effective_zoom);
}

/// Compute authored zoom from the current Node ancestry. The returned value
/// borrows no DOM storage.
pub fn effectiveCssZoomForNode(node: *const parser.Node) f32 {
    var result: f32 = 1.0;
    var current: ?*const parser.Node = node;
    while (current) |candidate| {
        current = switch (candidate.*) {
            .element => |*element| next: {
                if (element.style) |*styles| {
                    if (styleValue(styles, "zoom")) |value| {
                        result = combinedEffectiveZoom(result, parseCssZoom(value));
                    }
                }
                break :next element.parent;
            },
            .text => |*text| text.parent,
        };
    }
    return result;
}

/// Convert authored CSS pixels into page layout coordinates. Accessibility
/// zoom is represented by `page_zoom` and divided out here because raster
/// applies it to the complete display list later.
pub fn scaleCssPixel(value: i32, effective_zoom: f32, page_zoom: f32) i32 {
    const page = validZoomOr(page_zoom, 1.0);
    const effective = validZoomOr(effective_zoom, page);
    const scaled = @as(f64, @floatFromInt(value)) *
        (@as(f64, effective) / @as(f64, page));
    return @intFromFloat(std.math.clamp(
        scaled,
        @as(f64, @floatFromInt(std.math.minInt(i32))),
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    ));
}

pub fn scaleCssPixelByFactor(value: i32, factor: f32) i32 {
    return scaleCssPixel(value, factor, 1.0);
}

pub fn scaleCssFloat(value: f64, effective_zoom: f32, page_zoom: f32) f64 {
    const page = validZoomOr(page_zoom, 1.0);
    const effective = validZoomOr(effective_zoom, page);
    return value * (@as(f64, effective) / @as(f64, page));
}

pub fn cssPixelsFromLayout(value: i32, effective_zoom: f32, page_zoom: f32) f64 {
    const page = validZoomOr(page_zoom, 1.0);
    const effective = validZoomOr(effective_zoom, page);
    return @as(f64, @floatFromInt(value)) *
        (@as(f64, page) / @as(f64, effective));
}

fn validZoomOr(value: f32, fallback: f32) f32 {
    return if (std.math.isFinite(value) and value > 0.0) value else fallback;
}

/// Parse the non-negative pixel subset used by block dimensions.
pub fn parseCssPixelLength(value: []const u8) ?i32 {
    const pixels = parser.parsePixelLength(value) orelse return null;
    return parser.pixelLengthToLayoutPixels(pixels);
}

pub fn resolveCssLength(value: []const u8, context: parser.CssLengthResolutionContext) ?i32 {
    const pixels = parser.resolveCssLength(value, context) orelse return null;
    return parser.pixelLengthToLayoutPixels(pixels);
}

/// Resolve the supported px/em/percentage subset while permitting a sign.
pub fn resolveSignedCssLength(value: []const u8, context: parser.CssLengthResolutionContext) ?i32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n\x0c");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "auto")) return null;
    const negative = trimmed[0] == '-';
    const positive = trimmed[0] == '+';
    const magnitude = if (negative or positive) trimmed[1..] else trimmed;
    if (magnitude.len == 0) return null;
    const pixels = parser.resolveCssLength(magnitude, context) orelse return null;
    const signed = if (negative) -pixels else pixels;
    if (!std.math.isFinite(signed)) return null;
    return @intFromFloat(std.math.clamp(
        signed,
        @as(f64, @floatFromInt(std.math.minInt(i32))),
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    ));
}

/// Resolve a box-model length. Margins may be negative and treat `auto` as
/// zero in Zibra's block-only model; padding and border widths may not.
pub fn resolveBoxCssLength(
    value: []const u8,
    context: parser.CssLengthResolutionContext,
    allow_negative: bool,
) ?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return if (allow_negative) 0.0 else null;
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "0")) return 0.0;

    var sign: f64 = 1.0;
    var magnitude = trimmed;
    if (trimmed[0] == '-') {
        if (!allow_negative) return null;
        sign = -1.0;
        magnitude = trimmed[1..];
    } else if (trimmed[0] == '+') {
        magnitude = trimmed[1..];
    }
    if (magnitude.len == 0) return null;
    return sign * (parser.resolveCssLength(magnitude, context) orelse return null);
}

pub fn resolveBoxEdges(
    style_map: *const parser.StyleMap,
    font_size: f64,
    percentage_base: ?f64,
    effective_zoom: f32,
    page_zoom: f32,
) BoxModelEdges {
    const context = parser.CssLengthResolutionContext{
        .font_size = font_size,
        .percentage_base = percentage_base,
    };
    return .{
        .margin = .{
            .top = resolveEdge(style_map, "margin-top", context, effective_zoom, page_zoom, true),
            .right = resolveEdge(style_map, "margin-right", context, effective_zoom, page_zoom, true),
            .bottom = resolveEdge(style_map, "margin-bottom", context, effective_zoom, page_zoom, true),
            .left = resolveEdge(style_map, "margin-left", context, effective_zoom, page_zoom, true),
        },
        .padding = .{
            .top = resolveEdge(style_map, "padding-top", context, effective_zoom, page_zoom, false),
            .right = resolveEdge(style_map, "padding-right", context, effective_zoom, page_zoom, false),
            .bottom = resolveEdge(style_map, "padding-bottom", context, effective_zoom, page_zoom, false),
            .left = resolveEdge(style_map, "padding-left", context, effective_zoom, page_zoom, false),
        },
        .border = .{
            .top = resolveBorderEdge(style_map, "border-top-width", font_size, effective_zoom, page_zoom),
            .right = resolveBorderEdge(style_map, "border-right-width", font_size, effective_zoom, page_zoom),
            .bottom = resolveBorderEdge(style_map, "border-bottom-width", font_size, effective_zoom, page_zoom),
            .left = resolveBorderEdge(style_map, "border-left-width", font_size, effective_zoom, page_zoom),
        },
    };
}

pub fn animatedPixelDimension(element: *const parser.Element, property: []const u8) ?i32 {
    const animations = element.animations orelse return null;
    const animation = animations.get(property) orelse return null;
    return switch (animation) {
        .pixel => |pixel| pixel.layoutPixels(),
        .numeric, .color, .transform => null,
    };
}

pub fn resolvedPixelDimension(
    element: *const parser.Element,
    style_map: *const parser.StyleMap,
    property: []const u8,
    context: parser.CssLengthResolutionContext,
) ?i32 {
    return animatedPixelDimension(element, property) orelse
        if (styleValue(style_map, property)) |value| resolveCssLength(value, context) else null;
}

/// Parse the single positive pixel radius supported by paint and hit testing.
pub fn parseCssPixelRadius(value: []const u8) f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 2 or !std.ascii.eqlIgnoreCase(trimmed[trimmed.len - 2 ..], "px")) return 0;
    const number = std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t\r\n");
    if (number.len == 0) return 0;
    const radius = std.fmt.parseFloat(f64, number) catch return 0;
    return if (std.math.isFinite(radius) and radius > 0) radius else 0;
}

fn resolveEdge(
    style_map: *const parser.StyleMap,
    property: []const u8,
    context: parser.CssLengthResolutionContext,
    effective_zoom: f32,
    page_zoom: f32,
    allow_negative: bool,
) i32 {
    const value = styleValue(style_map, property) orelse return 0;
    const css_value = resolveBoxCssLength(value, context, allow_negative) orelse return 0;
    return clampedLayoutInt(scaleCssFloat(css_value, effective_zoom, page_zoom));
}

fn borderWidthCss(value: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n\x0c");
    if (std.mem.eql(u8, trimmed, "0")) return 0.0;
    if (std.ascii.eqlIgnoreCase(trimmed, "thin")) return 1.0;
    if (std.ascii.eqlIgnoreCase(trimmed, "medium")) return 3.0;
    if (std.ascii.eqlIgnoreCase(trimmed, "thick")) return 5.0;
    return resolveBoxCssLength(trimmed, .{}, false);
}

fn resolveBorderEdge(
    style_map: *const parser.StyleMap,
    property: []const u8,
    font_size: f64,
    effective_zoom: f32,
    page_zoom: f32,
) i32 {
    const value = styleValue(style_map, property) orelse return 0;
    const parsed = if (std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "0"))
        0.0
    else if (borderWidthCss(value)) |length|
        resolveBoxCssLength(value, .{ .font_size = font_size }, false) orelse length
    else
        0.0;
    return @intFromFloat(std.math.clamp(
        scaleCssFloat(parsed, effective_zoom, page_zoom),
        0.0,
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    ));
}

fn styleValue(style_map: *const parser.StyleMap, property: []const u8) ?[]const u8 {
    const field = @constCast(style_map).getPtr(property) orelse return null;
    return field.get().*;
}

fn clampedLayoutInt(value: f64) i32 {
    return @intFromFloat(std.math.clamp(
        value,
        @as(f64, @floatFromInt(std.math.minInt(i32))),
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    ));
}

test "box model edges resolve relative lengths against the containing block" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style='margin: 1em 2%; padding: 3px 4px; border: .5em solid red'></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    const edges = resolveBoxEdges(&root.element.style.?, 16.0, 400.0, 1.0, 1.0);
    try std.testing.expectEqual(@as(i32, 16), edges.margin.top);
    try std.testing.expectEqual(@as(i32, 8), edges.margin.right);
    try std.testing.expectEqual(@as(i32, 3), edges.padding.top);
    try std.testing.expectEqual(@as(i32, 4), edges.padding.right);
    try std.testing.expectEqual(@as(i32, 8), edges.border.top);
}

test "position float clear and dimension values normalize independently of layout state" {
    try std.testing.expectEqual(FloatSide.left, parseFloatSide(" LEFT "));
    try std.testing.expectEqual(FloatSide.right, parseFloatSide("right"));
    try std.testing.expectEqual(FloatSide.none, parseFloatSide("inline-start"));
    try std.testing.expectEqual(ClearSide.left, parseClearSide(" left "));
    try std.testing.expectEqual(ClearSide.right, parseClearSide("RIGHT"));
    try std.testing.expectEqual(ClearSide.both, parseClearSide(" both "));
    try std.testing.expectEqual(ClearSide.none, parseClearSide("inline-start"));
    try std.testing.expectEqual(PositionMode.relative, parsePositionMode(" RELATIVE "));
    try std.testing.expectEqual(PositionMode.absolute, parsePositionMode("absolute"));
    try std.testing.expectEqual(PositionMode.static, parsePositionMode("sticky"));

    try std.testing.expectEqual(@as(?i32, 240), parseCssPixelLength("240px"));
    try std.testing.expectEqual(@as(?i32, 12), parseCssPixelLength(" 12.75PX "));
    try std.testing.expectEqual(@as(?i32, 0), parseCssPixelLength("0px"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("auto"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("100%"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("-1px"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("NaNpx"));
    try std.testing.expectEqual(@as(?i32, 24), resolveSignedCssLength("+2em", .{ .font_size = 12 }));
    try std.testing.expectEqual(@as(?i32, -50), resolveSignedCssLength("-25%", .{ .percentage_base = 200 }));
    try std.testing.expectEqual(@as(?i32, -3), resolveSignedCssLength("-3px", .{}));
    try std.testing.expectEqual(@as(?i32, null), resolveSignedCssLength("auto", .{}));
}

test "CSS zoom composes and scales authored geometry" {
    try std.testing.expectEqual(@as(f32, 1.5), parseCssZoom("1.5"));
    try std.testing.expectEqual(@as(f32, 1.75), parseCssZoom(" 175% "));
    try std.testing.expectEqual(@as(f32, 1.0), parseCssZoom("0"));
    try std.testing.expectEqual(@as(f32, 1.0), parseCssZoom("0%"));
    try std.testing.expectEqual(@as(f32, 1.0), parseCssZoom("-2"));
    try std.testing.expectEqual(@as(f32, 1.0), parseCssZoom("bogus"));

    const accessibility_zoom: f32 = 2.0;
    const outer = combinedEffectiveZoom(accessibility_zoom, parseCssZoom("200%"));
    const inner = combinedEffectiveZoom(outer, parseCssZoom("1.5"));
    try std.testing.expectEqual(@as(f32, 4.0), outer);
    try std.testing.expectEqual(@as(f32, 6.0), inner);
    try std.testing.expectEqual(@as(i32, 60), scaleCssPixel(20, inner, accessibility_zoom));
    try std.testing.expectEqual(@as(i32, -30), scaleCssPixel(-10, inner, accessibility_zoom));
}

test "radius parsing accepts only finite positive pixels" {
    try std.testing.expectEqual(@as(f64, 12.5), parseCssPixelRadius(" 12.5px "));
    try std.testing.expectEqual(@as(f64, 0), parseCssPixelRadius("-4px"));
    try std.testing.expectEqual(@as(f64, 0), parseCssPixelRadius("50%"));
}
