//! Parses inline transition declarations and installs typed DOM animations.
//!
//! Animation storage remains owned by document Elements. These helpers only
//! parse transition metadata and mutate the caller-provided Element.

const std = @import("std");
const parser = @import("../document/parser.zig");

const NumericAnimation = parser.NumericAnimation;
const PixelAnimation = parser.PixelAnimation;
const ColorAnimation = parser.ColorAnimation;
const TransformAnimation = parser.TransformAnimation;
const Animation = parser.Animation;
const EasingFunction = parser.EasingFunction;

// Assume 60 fps for frame calculations
const FRAMES_PER_SECOND: u32 = 60;

/// Parse a simple inline style string like "opacity: 0.5; transition: opacity 2s"
pub fn parseInlineStyle(allocator: std.mem.Allocator, style_str: []const u8) !std.StringHashMap([]const u8) {
    var result = std.StringHashMap([]const u8).init(allocator);
    errdefer result.deinit();

    var parts = std.mem.tokenizeAny(u8, style_str, ";");
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
            const property = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
            const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");
            try result.put(property, value);
        }
    }
    return result;
}

pub const TransitionValue = struct {
    property: []const u8,
    frames: u32,
    easing_function: EasingFunction,
};

fn takeTransitionToken(remaining: *[]const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, remaining.*, " \t\n\r");
    if (trimmed.len == 0) return null;
    const end = std.mem.indexOfAny(u8, trimmed, " \t\n\r") orelse trimmed.len;
    remaining.* = trimmed[end..];
    return trimmed[0..end];
}

/// Parse `property duration [timing-function]`. CSS transitions default to
/// `ease`, while an explicit supported keyword or cubic-bezier overrides it.
pub fn parseTransitionValue(value: []const u8) ?TransitionValue {
    var remaining = value;
    const property = takeTransitionToken(&remaining) orelse return null;
    const duration_str = takeTransitionToken(&remaining) orelse return null;

    var duration_seconds: f64 = 0;
    if (std.mem.endsWith(u8, duration_str, "ms")) {
        const ms_str = duration_str[0 .. duration_str.len - 2];
        const ms = std.fmt.parseFloat(f64, ms_str) catch return null;
        duration_seconds = ms / 1000.0;
    } else if (std.mem.endsWith(u8, duration_str, "s")) {
        const s_str = duration_str[0 .. duration_str.len - 1];
        duration_seconds = std.fmt.parseFloat(f64, s_str) catch return null;
    } else {
        return null;
    }

    const frame_count = duration_seconds * @as(f64, FRAMES_PER_SECOND);
    const max_frames: f64 = @floatFromInt(std.math.maxInt(u32));
    if (!std.math.isFinite(frame_count) or frame_count < 0 or frame_count > max_frames) return null;
    const frames: u32 = @intFromFloat(frame_count);

    const timing_value = std.mem.trim(u8, remaining, " \t\n\r");
    const easing_function = if (timing_value.len == 0)
        EasingFunction.ease
    else
        parser.parseEasingFunction(timing_value) orelse return null;

    return .{
        .property = property,
        .frames = @max(1, frames),
        .easing_function = easing_function,
    };
}

pub const TransitionListIterator = struct {
    remaining: []const u8,

    pub fn init(value: []const u8) TransitionListIterator {
        return .{ .remaining = value };
    }

    /// Split only top-level commas so cubic-bezier arguments remain one
    /// timing function.
    pub fn next(self: *TransitionListIterator) ?[]const u8 {
        self.remaining = std.mem.trim(u8, self.remaining, " \t\n\r,");
        if (self.remaining.len == 0) return null;
        var depth: usize = 0;
        for (self.remaining, 0..) |char, index| {
            switch (char) {
                '(' => depth += 1,
                ')' => depth -|= 1,
                ',' => if (depth == 0) {
                    const result = self.remaining[0..index];
                    self.remaining = self.remaining[index + 1 ..];
                    return std.mem.trim(u8, result, " \t\n\r");
                },
                else => {},
            }
        }
        const result = self.remaining;
        self.remaining = &.{};
        return std.mem.trim(u8, result, " \t\n\r");
    }
};

/// Start an opacity animation on an element
pub fn startOpacityAnimation(
    allocator: std.mem.Allocator,
    elem: *parser.Element,
    start: f64,
    end: f64,
    frames: u32,
    easing_function: EasingFunction,
) !void {
    if (elem.animations == null) {
        elem.animations = std.StringHashMap(Animation).init(allocator);
    }
    const animation = Animation{
        .numeric = NumericAnimation.initWithEasing(start, end, frames, easing_function),
    };
    try elem.animations.?.put("opacity", animation);
}

/// Start a background-color animation on an element.
pub fn startBackgroundColorAnimation(
    allocator: std.mem.Allocator,
    elem: *parser.Element,
    start: parser.CssColor,
    end: parser.CssColor,
    frames: u32,
    easing_function: EasingFunction,
) !void {
    if (elem.animations == null) {
        elem.animations = std.StringHashMap(Animation).init(allocator);
    }
    const animation = Animation{
        .color = ColorAnimation.initWithEasing(start, end, frames, easing_function),
    };
    try elem.animations.?.put("background-color", animation);
}

pub fn startTransformAnimation(
    allocator: std.mem.Allocator,
    elem: *parser.Element,
    start: parser.Translation,
    end: parser.Translation,
    frames: u32,
    easing_function: EasingFunction,
) !void {
    if (elem.animations == null) {
        elem.animations = std.StringHashMap(Animation).init(allocator);
    }
    const animation = Animation{
        .transform = TransformAnimation.initWithEasing(
            start,
            end,
            frames,
            easing_function,
        ),
    };
    try elem.animations.?.put("transform", animation);
}

pub fn startPixelAnimation(
    allocator: std.mem.Allocator,
    elem: *parser.Element,
    property: []const u8,
    start: f64,
    end: f64,
    frames: u32,
    easing_function: EasingFunction,
) !void {
    if (elem.animations == null) {
        elem.animations = std.StringHashMap(Animation).init(allocator);
    }
    const animation = Animation{ .pixel = PixelAnimation.initWithEasing(
        start,
        end,
        frames,
        easing_function,
    ) };
    try elem.animations.?.put(property, animation);
}

test "transition values default to ease and parse supported timing functions" {
    const default_transition = parseTransitionValue("background-color 500ms").?;
    try std.testing.expectEqualStrings("background-color", default_transition.property);
    try std.testing.expectEqual(@as(u32, 30), default_transition.frames);
    try std.testing.expectApproxEqAbs(
        EasingFunction.ease.apply(0.5),
        default_transition.easing_function.apply(0.5),
        0.000001,
    );

    const linear = parseTransitionValue("opacity 2s linear").?;
    try std.testing.expectEqual(@as(u32, 120), linear.frames);
    try std.testing.expectApproxEqAbs(0.5, linear.easing_function.apply(0.5), 0.000001);

    const explicit = parseTransitionValue(
        "opacity 1s cubic-bezier(0.42, 0, 0.58, 1)",
    ).?;
    try std.testing.expectApproxEqAbs(0.5, explicit.easing_function.apply(0.5), 0.000001);
    try std.testing.expect(parseTransitionValue("opacity 1s steps(2)") == null);
    try std.testing.expect(parseTransitionValue("opacity -1s ease") == null);
}

test "transition list keeps cubic-bezier commas and simultaneous properties" {
    var iterator = TransitionListIterator.init(
        "transform 1s cubic-bezier(0.25, 0.1, 0.25, 1), opacity 1s linear",
    );
    const transform = parseTransitionValue(iterator.next().?).?;
    try std.testing.expectEqualStrings("transform", transform.property);
    try std.testing.expectApproxEqAbs(EasingFunction.ease.apply(0.5), transform.easing_function.apply(0.5), 0.000001);
    const opacity = parseTransitionValue(iterator.next().?).?;
    try std.testing.expectEqualStrings("opacity", opacity.property);
    try std.testing.expectApproxEqAbs(0.5, opacity.easing_function.apply(0.5), 0.000001);
    try std.testing.expect(iterator.next() == null);
}

pub fn currentAnimatedOpacity(elem: *const parser.Element) ?f64 {
    const animations = elem.animations orelse return null;
    const animation = animations.get("opacity") orelse return null;
    return switch (animation) {
        .numeric => |numeric| numeric.getValue(),
        .pixel, .color, .transform => null,
    };
}

pub fn currentAnimatedBackgroundColor(elem: *const parser.Element) ?parser.CssColor {
    const animations = elem.animations orelse return null;
    const animation = animations.get("background-color") orelse return null;
    return switch (animation) {
        .color => |color| color.getValue(),
        .numeric, .pixel, .transform => null,
    };
}

pub fn currentAnimatedTransform(elem: *const parser.Element) ?parser.Translation {
    const animations = elem.animations orelse return null;
    const animation = animations.get("transform") orelse return null;
    return switch (animation) {
        .transform => |transform| transform.getValue(),
        .numeric, .pixel, .color => null,
    };
}

pub fn currentAnimatedPixel(elem: *const parser.Element, property: []const u8) ?f64 {
    const animations = elem.animations orelse return null;
    const animation = animations.get(property) orelse return null;
    return switch (animation) {
        .pixel => |pixel| pixel.getValue(),
        .numeric, .color, .transform => null,
    };
}
