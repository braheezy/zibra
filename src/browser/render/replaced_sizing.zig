//! Shared used-size resolution for image and iframe replaced elements.
//!
//! This module deliberately owns no layout or resource state. It reads the
//! current computed dimension/aspect-ratio values and returns unscaled CSS
//! pixel dimensions, allowing both layout and iframe navigation setup to use
//! the same rules.

const std = @import("std");
const parser = @import("../../document/parser.zig");

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const SpecifiedSize = struct {
    width: ?i32 = null,
    height: ?i32 = null,
};

/// The supported `aspect-ratio` grammar is `auto || <ratio>`, where a ratio is
/// one positive finite number or two such numbers separated by `/`.
pub const AspectRatio = struct {
    ratio: ?f64 = null,
    use_intrinsic: bool = true,

    pub const auto = AspectRatio{};
};

pub const Kind = enum {
    image,
    iframe,
};

fn isCssWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}

fn parsePositiveNumber(input: []const u8) ?f64 {
    const text = std.mem.trim(u8, input, " \t\r\n\x0c");
    if (text.len == 0) return null;
    const value = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(value) and value > 0) value else null;
}

fn parseRatio(input: []const u8) ?f64 {
    const slash = std.mem.indexOfScalar(u8, input, '/');
    if (slash) |index| {
        if (std.mem.indexOfScalar(u8, input[index + 1 ..], '/') != null) return null;
        const numerator = parsePositiveNumber(input[0..index]) orelse return null;
        const denominator = parsePositiveNumber(input[index + 1 ..]) orelse return null;
        const ratio = numerator / denominator;
        return if (std.math.isFinite(ratio) and ratio > 0) ratio else null;
    }
    return parsePositiveNumber(input);
}

fn startsWithAuto(input: []const u8) bool {
    return input.len > 4 and
        std.ascii.eqlIgnoreCase(input[0..4], "auto") and
        isCssWhitespace(input[4]);
}

fn endsWithAuto(input: []const u8) bool {
    return input.len > 4 and
        std.ascii.eqlIgnoreCase(input[input.len - 4 ..], "auto") and
        isCssWhitespace(input[input.len - 5]);
}

pub fn parseAspectRatio(input: []const u8) ?AspectRatio {
    const text = std.mem.trim(u8, input, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(text, "auto")) return .auto;

    var ratio_text = text;
    var use_intrinsic = false;
    if (startsWithAuto(text)) {
        use_intrinsic = true;
        ratio_text = std.mem.trim(u8, text[4..], " \t\r\n\x0c");
    } else if (endsWithAuto(text)) {
        use_intrinsic = true;
        ratio_text = std.mem.trim(u8, text[0 .. text.len - 4], " \t\r\n\x0c");
    }

    return .{
        .ratio = parseRatio(ratio_text) orelse return null,
        .use_intrinsic = use_intrinsic,
    };
}

fn styleValue(element: *const parser.Element, property: []const u8) ?[]const u8 {
    const style_map = if (element.style) |*styles| styles else return null;
    const field = @constCast(style_map).getPtr(property) orelse return null;
    return field.get().*;
}

fn animatedPixelDimension(element: *const parser.Element, property: []const u8) ?i32 {
    const animations = element.animations orelse return null;
    const animation = animations.get(property) orelse return null;
    return switch (animation) {
        .pixel => |pixel| pixel.layoutPixels(),
        .numeric, .color, .transform => null,
    };
}

fn cssPixelDimension(element: *const parser.Element, property: []const u8) ?i32 {
    if (animatedPixelDimension(element, property)) |pixels| return pixels;
    const value = styleValue(element, property) orelse return null;
    const pixels = parser.parsePixelLength(value) orelse return null;
    return parser.pixelLengthToLayoutPixels(pixels);
}

fn parseLengthAttribute(input: []const u8) ?i32 {
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len == 0) return null;
    const number = if (text.len >= 2 and std.ascii.eqlIgnoreCase(text[text.len - 2 ..], "px"))
        std.mem.trim(u8, text[0 .. text.len - 2], " \t\r\n")
    else
        text;
    return std.fmt.parseInt(i32, number, 10) catch null;
}

pub fn specifiedSize(element: *const parser.Element) SpecifiedSize {
    var result = SpecifiedSize{};
    if (element.attributes) |attributes| {
        if (attributes.get("width")) |value| result.width = parseLengthAttribute(value);
        if (attributes.get("height")) |value| result.height = parseLengthAttribute(value);
    }
    // A supported CSS dimension overrides the matching HTML presentational
    // hint. `auto` and unsupported CSS values retain the existing attribute
    // fallback used by this browser.
    if (cssPixelDimension(element, "width")) |width| result.width = width;
    if (cssPixelDimension(element, "height")) |height| result.height = height;
    return result;
}

pub fn aspectRatio(element: *const parser.Element) AspectRatio {
    const value = styleValue(element, "aspect-ratio") orelse return .auto;
    return parseAspectRatio(value) orelse .auto;
}

fn sizeRatio(size: ?Size) ?f64 {
    const dimensions = size orelse return null;
    if (dimensions.width <= 0 or dimensions.height <= 0) return null;
    return @as(f64, @floatFromInt(dimensions.width)) /
        @as(f64, @floatFromInt(dimensions.height));
}

fn effectiveRatio(value: AspectRatio, intrinsic: ?Size) ?f64 {
    if (value.use_intrinsic) {
        if (sizeRatio(intrinsic)) |ratio| return ratio;
    }
    return value.ratio;
}

fn scaledDimension(fixed: i32, factor: f64) i32 {
    if (fixed <= 0 or !std.math.isFinite(factor) or factor <= 0) return 0;
    const result = @as(f64, @floatFromInt(fixed)) * factor;
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    return @intFromFloat(std.math.clamp(result, 0.0, maximum));
}

/// Resolve a replaced element in unscaled CSS pixels. A CSS ratio supplies
/// the missing axis only; two authored axes remain authoritative. Images use
/// their natural ratio for `auto`; before pixels arrive, an unspecified image
/// axis stays zero unless a CSS ratio can derive it. Iframes retain their
/// 300x150 default on an axis for which no ratio was supplied.
pub fn resolve(
    kind: Kind,
    specified: SpecifiedSize,
    intrinsic: ?Size,
    value: AspectRatio,
) Size {
    if (specified.width != null and specified.height != null) {
        return .{ .width = specified.width.?, .height = specified.height.? };
    }

    const ratio = effectiveRatio(value, intrinsic);
    if (specified.width) |width| {
        return .{
            .width = width,
            .height = if (ratio) |resolved|
                scaledDimension(width, 1.0 / resolved)
            else switch (kind) {
                .image => 0,
                .iframe => 150,
            },
        };
    }
    if (specified.height) |height| {
        return .{
            .width = if (ratio) |resolved|
                scaledDimension(height, resolved)
            else switch (kind) {
                .image => 0,
                .iframe => 300,
            },
            .height = height,
        };
    }

    return switch (kind) {
        .image => intrinsic orelse .{ .width = 0, .height = 0 },
        .iframe => .{ .width = 300, .height = 150 },
    };
}

pub fn imageSize(element: *const parser.Element, intrinsic: ?Size) Size {
    return resolve(.image, specifiedSize(element), intrinsic, aspectRatio(element));
}

pub fn iframeSize(element: *const parser.Element) Size {
    return resolve(.iframe, specifiedSize(element), null, aspectRatio(element));
}

test "aspect-ratio parses auto, ratios, and the replaced fallback syntax" {
    try std.testing.expectEqual(AspectRatio.auto, parseAspectRatio(" auto ").?);

    const fraction = parseAspectRatio("16 / 9").?;
    try std.testing.expect(!fraction.use_intrinsic);
    try std.testing.expectApproxEqAbs(@as(f64, 16.0 / 9.0), fraction.ratio.?, 0.000001);

    const single = parseAspectRatio("1.5").?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), single.ratio.?, 0.000001);

    const fallback = parseAspectRatio("AUTO 4 / 3").?;
    try std.testing.expect(fallback.use_intrinsic);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0 / 3.0), fallback.ratio.?, 0.000001);
    try std.testing.expect(parseAspectRatio("4 / 3 auto").?.use_intrinsic);

    try std.testing.expect(parseAspectRatio("0 / 1") == null);
    try std.testing.expect(parseAspectRatio("1 / -2") == null);
    try std.testing.expect(parseAspectRatio("1 / 2 / 3") == null);
    try std.testing.expect(parseAspectRatio("auto auto") == null);
    try std.testing.expect(parseAspectRatio("wide") == null);
}

test "replaced sizing uses the ratio only for a missing axis" {
    const ratio = parseAspectRatio("16 / 9").?;
    try std.testing.expectEqual(
        Size{ .width = 320, .height = 180 },
        resolve(.iframe, .{ .width = 320 }, null, ratio),
    );
    try std.testing.expectEqual(
        Size{ .width = 320, .height = 180 },
        resolve(.iframe, .{ .height = 180 }, null, ratio),
    );
    try std.testing.expectEqual(
        Size{ .width = 300, .height = 90 },
        resolve(.iframe, .{ .width = 300, .height = 90 }, null, ratio),
    );
    try std.testing.expectEqual(
        Size{ .width = 640, .height = 150 },
        resolve(.iframe, .{ .width = 640 }, null, .auto),
    );
}

test "image sizing switches auto ratio from fallback to intrinsic after load" {
    const fallback = parseAspectRatio("auto 16 / 9").?;
    try std.testing.expectEqual(
        Size{ .width = 160, .height = 90 },
        resolve(.image, .{ .width = 160 }, null, fallback),
    );
    try std.testing.expectEqual(
        Size{ .width = 160, .height = 64 },
        resolve(.image, .{ .width = 160 }, .{ .width = 30, .height = 12 }, fallback),
    );
    try std.testing.expectEqual(
        Size{ .width = 160, .height = 90 },
        resolve(
            .image,
            .{ .width = 160 },
            .{ .width = 30, .height = 12 },
            parseAspectRatio("16 / 9").?,
        ),
    );
    try std.testing.expectEqual(
        Size{ .width = 160, .height = 90 },
        resolve(.image, .{ .height = 90 }, null, parseAspectRatio("16 / 9").?),
    );
}

test "unloaded images retain only explicitly specified axes" {
    try std.testing.expectEqual(
        Size{ .width = 80, .height = 0 },
        resolve(.image, .{ .width = 80 }, null, .auto),
    );
    try std.testing.expectEqual(
        Size{ .width = 0, .height = 45 },
        resolve(.image, .{ .height = 45 }, null, .auto),
    );
    try std.testing.expectEqual(
        Size{ .width = 80, .height = 45 },
        resolve(.image, .{ .width = 80, .height = 45 }, null, .auto),
    );
    try std.testing.expectEqual(
        Size{ .width = 0, .height = 0 },
        resolve(.image, .{}, null, .auto),
    );
}
