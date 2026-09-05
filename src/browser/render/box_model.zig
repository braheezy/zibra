//! Pure CSS used-value and box-geometry helpers for layout.
//!
//! This module does not own layout objects or register invalidation edges. It
//! converts already-computed style values into scalar geometry consumed by
//! `layout.zig`.

const std = @import("std");
const parser = @import("../../document/parser.zig");
const margin_collapse = @import("margin_collapse.zig");

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
    /// Positioned against the owning frame viewport and excluded from normal
    /// flow. The renderer consumes its paint group in viewport coordinates.
    fixed,
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

pub const HorizontalAutoMargins = struct {
    left: bool = false,
    right: bool = false,
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
    if (std.ascii.eqlIgnoreCase(trimmed, "fixed")) return .fixed;
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

/// Apply CSS min/max used-value constraints. CSS resolves the maximum first
/// and the minimum second, so a minimum larger than the maximum wins.
pub fn constrainDimension(value: i32, minimum: ?i32, maximum: ?i32) i32 {
    var constrained = value;
    if (maximum) |limit| constrained = @min(constrained, limit);
    if (minimum) |limit| constrained = @max(constrained, limit);
    return @max(constrained, 0);
}

/// Collapse two adjoining vertical margins. Longer chains are represented by
/// `margin_collapse.MarginStrut` so nested empty blocks retain both extrema.
pub fn collapseAdjoiningMargins(first: i32, second: i32) i32 {
    var strut = margin_collapse.MarginStrut.init(first);
    strut.append(second);
    return strut.used();
}

/// Resolve the supported px/em/percentage subset while permitting a sign.
pub fn resolveSignedCssLength(value: []const u8, context: parser.CssLengthResolutionContext) ?i32 {
    if (@import("../../document/length.zig").resolveMath(value, context)) |pixels| {
        return @intFromFloat(std.math.clamp(pixels, std.math.minInt(i32), std.math.maxInt(i32)));
    }
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
    if (@import("../../document/length.zig").resolveMath(trimmed, context)) |pixels| return if (allow_negative) pixels else @max(pixels, 0);
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
            .top = resolveBorderEdge(
                style_map,
                "border-top-width",
                "border-top-style",
                font_size,
                effective_zoom,
                page_zoom,
            ),
            .right = resolveBorderEdge(
                style_map,
                "border-right-width",
                "border-right-style",
                font_size,
                effective_zoom,
                page_zoom,
            ),
            .bottom = resolveBorderEdge(
                style_map,
                "border-bottom-width",
                "border-bottom-style",
                font_size,
                effective_zoom,
                page_zoom,
            ),
            .left = resolveBorderEdge(
                style_map,
                "border-left-width",
                "border-left-style",
                font_size,
                effective_zoom,
                page_zoom,
            ),
        },
    };
}

/// Report horizontal `auto` margins before their used values are resolved.
/// `resolveBoxEdges` intentionally represents `auto` as zero so ordinary
/// width calculations can proceed; a block formatting context distributes
/// the remaining inline space after it knows the used border-box width.
pub fn horizontalAutoMargins(style_map: *const parser.StyleMap) HorizontalAutoMargins {
    return .{
        .left = isAutoKeyword(styleValue(style_map, "margin-left")),
        .right = isAutoKeyword(styleValue(style_map, "margin-right")),
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

fn intrinsicTextWidth(text: []const u8, font_size: f64) ?i32 {
    if (std.mem.trim(u8, text, " \t\r\n\x0c").len == 0) return null;
    const codepoints = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (codepoints == 0) return null;
    // This is a pre-layout estimate used only to resolve positioned
    // shrink-to-fit boxes. The real inline pass measures each glyph; a
    // 0.6em average keeps common proportional text close enough for the
    // containing-block and right-inset calculation.
    return @max(@as(i32, @intFromFloat(@as(f64, @floatFromInt(codepoints)) * font_size * 0.6)), 1);
}

fn intrinsicOuterWidth(
    element: *const parser.Element,
    containing_width_css: f64,
    inherited_font_size: f64,
) ?i32 {
    const styles = if (element.style) |*style_map| style_map else return null;
    const font_size = if (styleValue(styles, "font-size")) |font_value|
        parser.resolveCssLength(font_value, .{
            .font_size = inherited_font_size,
            .percentage_base = inherited_font_size,
        }) orelse inherited_font_size
    else
        inherited_font_size;
    const context = parser.CssLengthResolutionContext{
        .font_size = font_size,
        .percentage_base = containing_width_css,
    };
    const display = std.mem.trim(
        u8,
        styleValue(styles, "display") orelse "inline",
        " \t\r\n",
    );
    const float_side = parseFloatSide(styleValue(styles, "float") orelse "none");
    const is_replaced_image = std.ascii.eqlIgnoreCase(element.tag, "img") or
        (std.ascii.eqlIgnoreCase(element.tag, "object") and
            element.image_data != null and !element.image_data.?.is_broken);
    const inline_width_ignored = std.ascii.eqlIgnoreCase(display, "inline") and
        float_side == .none and !is_replaced_image;

    var content_width = if (!inline_width_ignored)
        if (styleValue(styles, "width")) |width| resolveCssLength(width, context) else null
    else
        null;
    if (content_width == null and is_replaced_image) {
        if (element.image_data) |data| content_width = @intCast(data.image.width);
    }
    if (content_width == null) {
        for (element.children.items) |*child| {
            // Out-of-flow descendants do not contribute to their parent's
            // shrink-to-fit width. Their own containing block still performs
            // an independent shrink-to-fit calculation. This distinction is
            // important for an absolutely positioned child inside a zero-
            // width anchor such as Acid3's score container.
            switch (child.*) {
                .element => |*child_element| {
                    if (child_element.style) |*child_styles| {
                        const child_position = parsePositionMode(
                            styleValue(child_styles, "position") orelse "static",
                        );
                        if (child_position == .absolute or child_position == .fixed) continue;
                    }
                },
                .text => {},
            }
            const child_width = switch (child.*) {
                .text => |text| intrinsicTextWidth(text.text, font_size),
                .element => |*child_element| intrinsicOuterWidth(
                    child_element,
                    containing_width_css,
                    font_size,
                ),
            };
            if (child_width) |width| {
                content_width = @max(content_width orelse 0, width);
            }
        }
    }
    const content = content_width orelse return null;
    const edges = resolveBoxEdges(styles, font_size, containing_width_css, 1.0, 1.0);
    return @max(
        content + edges.padding.horizontal() + edges.border.horizontal() +
            edges.margin.horizontal(),
        0,
    );
}

/// Approximate CSS shrink-to-fit width from descendants with definite widths.
/// This is intentionally a pure pre-layout measurement: callers clamp it to
/// available space and fall back to the normal auto width when no definite
/// descendant contributes an intrinsic width.
pub fn shrinkToFitSpecifiedContentWidth(
    element: *const parser.Element,
    containing_width_css: f64,
    inherited_font_size: f64,
) ?i32 {
    var width: ?i32 = null;
    for (element.children.items) |*child| {
        const child_width = switch (child.*) {
            .text => |text| intrinsicTextWidth(text.text, inherited_font_size),
            .element => |*child_element| intrinsicOuterWidth(
                child_element,
                containing_width_css,
                inherited_font_size,
            ),
        };
        if (child_width) |candidate| width = @max(width orelse 0, candidate);
    }
    return width;
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
    width_property: []const u8,
    style_property: []const u8,
    font_size: f64,
    effective_zoom: f32,
    page_zoom: f32,
) i32 {
    // CSS border widths are *used* as zero when their style is none or
    // hidden. Painting already skips those styles; resolving this here keeps
    // box geometry, descendant containing blocks, and paint quadrilaterals in
    // agreement. In particular, a `border-style: none solid` box must not
    // gain phantom top and bottom space from its specified border width.
    if (borderStyleSuppressesWidth(styleValue(style_map, style_property))) return 0;

    const value = styleValue(style_map, width_property) orelse return 0;
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

fn borderStyleSuppressesWidth(value: ?[]const u8) bool {
    const style = std.mem.trim(u8, value orelse return true, " \t\r\n\x0c");
    return std.ascii.eqlIgnoreCase(style, "none") or
        std.ascii.eqlIgnoreCase(style, "hidden");
}

fn styleValue(style_map: *const parser.StyleMap, property: []const u8) ?[]const u8 {
    const field = @constCast(style_map).getPtr(property) orelse return null;
    return field.get().*;
}

fn isAutoKeyword(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, " \t\r\n\x0c"), "auto");
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

test "none and hidden border styles have no used width" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style='border-width:7px;border-style:none solid hidden dashed'></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    const edges = resolveBoxEdges(&root.element.style.?, 16.0, 400.0, 1.0, 1.0);
    try std.testing.expectEqual(@as(i32, 0), edges.border.top);
    try std.testing.expectEqual(@as(i32, 7), edges.border.right);
    try std.testing.expectEqual(@as(i32, 0), edges.border.bottom);
    try std.testing.expectEqual(@as(i32, 7), edges.border.left);
}

test "horizontal auto margins survive edge resolution for block distribution" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style='margin: 1px auto 2px'></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    const styles = &root.element.style.?;
    const edges = resolveBoxEdges(styles, 16.0, 400.0, 1.0, 1.0);
    const auto = horizontalAutoMargins(styles);
    try std.testing.expectEqual(@as(i32, 0), edges.margin.left);
    try std.testing.expectEqual(@as(i32, 0), edges.margin.right);
    try std.testing.expect(auto.left);
    try std.testing.expect(auto.right);
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
    try std.testing.expectEqual(PositionMode.fixed, parsePositionMode("fixed"));
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

    try std.testing.expectEqual(@as(i32, 40), constrainDimension(100, 20, 40));
    try std.testing.expectEqual(@as(i32, 20), constrainDimension(10, 20, 40));
    // The minimum wins when the constraints conflict, per CSS 2.1.
    try std.testing.expectEqual(@as(i32, 50), constrainDimension(30, 50, 40));
    try std.testing.expectEqual(@as(i32, 12), collapseAdjoiningMargins(8, 12));
    try std.testing.expectEqual(@as(i32, -12), collapseAdjoiningMargins(-8, -12));
    try std.testing.expectEqual(@as(i32, 4), collapseAdjoiningMargins(-8, 12));
}

test "shrink-to-fit measurement uses definite descendant outer widths" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style='position:absolute'>" ++
            "<div style='float:right;width:48px;border:2px solid;padding:3px'></div>" ++
            "</div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    try std.testing.expectEqual(
        @as(?i32, 58),
        shrinkToFitSpecifiedContentWidth(&root.element, 400, 16),
    );
}

test "shrink-to-fit measurement includes direct text content" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style='position:absolute'><div style='position:absolute'>100/100</div></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    // Seven characters at the inherited 16px font produce a non-zero
    // preferred width, even though the containing block itself is zero wide.
    try std.testing.expectEqual(
        @as(?i32, 67),
        shrinkToFitSpecifiedContentWidth(&root.element, 0, 16),
    );
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
