//! CSS transition/keyframe interpolation state owned by DOM Elements.
//!
//! Interpolators are pure value objects. They borrow no DOM, style map, or
//! layout state; the Tab animation driver decides how published values dirty
//! compositor, paint, or layout phases.

const std = @import("std");
const css_color = @import("color.zig");
const easing = @import("easing.zig");
const css_transform = @import("transform.zig");
const css_length = @import("length.zig");
const css_animation = @import("css_animation.zig");

pub const CssColor = css_color.Color;
pub const parseCssColor = css_color.parse;
pub const EasingFunction = easing.Function;
pub const parseEasingFunction = easing.parse;
pub const Translation = css_transform.Translation;
pub const parseTranslate = css_transform.parse;
pub const CssLength = css_length.Length;
pub const CssLengthResolutionContext = css_length.ResolutionContext;
pub const parseCssLength = css_length.parse;
pub const resolveCssLength = css_length.resolve;
pub const parsePixelLength = css_length.parsePixel;
pub const pixelLengthToLayoutPixels = css_length.toLayoutPixels;

/// Animation state for a numeric CSS property transition
pub const NumericAnimation = struct {
    start_value: f64,
    end_value: f64,
    current_frame: u32,
    total_frames: u32,
    easing_function: EasingFunction,
    progress_override: ?f64 = null,

    pub fn init(start: f64, end: f64, frames: u32) NumericAnimation {
        return initWithEasing(start, end, frames, .linear);
    }

    pub fn initWithEasing(
        start: f64,
        end: f64,
        frames: u32,
        easing_function: EasingFunction,
    ) NumericAnimation {
        return .{
            .start_value = start,
            .end_value = end,
            .current_frame = 0,
            .total_frames = frames,
            .easing_function = easing_function,
        };
    }

    /// Get the current interpolated value
    pub fn getValue(self: NumericAnimation) f64 {
        if (self.total_frames == 0 and self.progress_override == null) return self.end_value;
        const progress = self.progress_override orelse (@as(f64, @floatFromInt(self.current_frame)) /
            @as(f64, @floatFromInt(self.total_frames)));
        const t = self.easing_function.apply(progress);
        return self.start_value + (self.end_value - self.start_value) * t;
    }

    /// Advance the animation by one frame, returns true if animation is complete
    pub fn advance(self: *NumericAnimation) bool {
        if (self.current_frame < self.total_frames) {
            self.current_frame += 1;
        }
        return self.current_frame >= self.total_frames;
    }

    /// Check if animation is complete
    pub fn isComplete(self: NumericAnimation) bool {
        return self.current_frame >= self.total_frames;
    }
};

/// Numeric interpolation whose CSS representation is a non-negative pixel
/// length. Width and height use this variant so values can retain the `px`
/// suffix expected by layout.
pub const PixelAnimation = struct {
    numeric: NumericAnimation,

    pub fn initWithEasing(
        start: f64,
        end: f64,
        frames: u32,
        easing_function: EasingFunction,
    ) PixelAnimation {
        return .{ .numeric = NumericAnimation.initWithEasing(
            start,
            end,
            frames,
            easing_function,
        ) };
    }

    pub fn parse(value: []const u8) ?f64 {
        return css_length.parsePixel(value);
    }

    pub fn getValue(self: PixelAnimation) f64 {
        return self.numeric.getValue();
    }

    pub fn layoutPixels(self: PixelAnimation) i32 {
        return css_length.toLayoutPixels(self.getValue());
    }

    pub fn formatValue(self: PixelAnimation, buffer: []u8) ![]const u8 {
        return css_length.formatPixel(buffer, self.getValue());
    }

    pub fn advance(self: *PixelAnimation) bool {
        return self.numeric.advance();
    }

    pub fn isComplete(self: PixelAnimation) bool {
        return self.numeric.isComplete();
    }
};

/// Native sRGB transition values use premultiplied-alpha interpolation, then
/// return straight RGBA8 for painting. Invisible endpoint RGB cannot tint a fade.
pub const ColorAnimation = struct {
    start_value: CssColor,
    end_value: CssColor,
    current_frame: u32,
    total_frames: u32,
    easing_function: EasingFunction,
    progress_override: ?f64 = null,

    pub fn init(start: CssColor, end: CssColor, frames: u32) ColorAnimation {
        return initWithEasing(start, end, frames, .linear);
    }

    pub fn initWithEasing(
        start: CssColor,
        end: CssColor,
        frames: u32,
        easing_function: EasingFunction,
    ) ColorAnimation {
        return .{
            .start_value = start,
            .end_value = end,
            .current_frame = 0,
            .total_frames = frames,
            .easing_function = easing_function,
        };
    }

    fn interpolateChannel(start: u8, end: u8, progress: f64) u8 {
        const start_float: f64 = @floatFromInt(start);
        const end_float: f64 = @floatFromInt(end);
        const interpolated = start_float + (end_float - start_float) * progress;
        return @intFromFloat(@round(std.math.clamp(interpolated, 0.0, 255.0)));
    }

    fn interpolateColor(start: u8, end: u8, start_alpha: u8, end_alpha: u8, progress: f64) u8 {
        const a: f64 = @floatFromInt(start_alpha);
        const b: f64 = @floatFromInt(end_alpha);
        const alpha = a + (b - a) * progress;
        if (alpha <= 0) return 0;
        const channel = (@as(f64, @floatFromInt(start)) * a * (1 - progress) + @as(f64, @floatFromInt(end)) * b * progress) / alpha;
        return @intFromFloat(@round(std.math.clamp(channel, 0, 255)));
    }

    pub fn getValue(self: ColorAnimation) CssColor {
        if (self.progress_override == null and (self.total_frames == 0 or self.current_frame >= self.total_frames)) return self.end_value;
        const progress = self.progress_override orelse (@as(f64, @floatFromInt(self.current_frame)) /
            @as(f64, @floatFromInt(self.total_frames)));
        const eased_progress = self.easing_function.apply(progress);
        if (eased_progress == 0) return self.start_value;
        if (eased_progress == 1) return self.end_value;
        return .{
            .r = interpolateColor(self.start_value.r, self.end_value.r, self.start_value.a, self.end_value.a, eased_progress),
            .g = interpolateColor(self.start_value.g, self.end_value.g, self.start_value.a, self.end_value.a, eased_progress),
            .b = interpolateColor(self.start_value.b, self.end_value.b, self.start_value.a, self.end_value.a, eased_progress),
            .a = interpolateChannel(self.start_value.a, self.end_value.a, eased_progress),
        };
    }

    pub fn advance(self: *ColorAnimation) bool {
        if (self.current_frame < self.total_frames) self.current_frame += 1;
        return self.current_frame >= self.total_frames;
    }

    pub fn isComplete(self: ColorAnimation) bool {
        return self.current_frame >= self.total_frames;
    }
};

/// Animation state for the supported translate transform. Both axes share
/// one eased frame position and remain floating point until paint/compositing.
pub const TransformAnimation = struct {
    start_value: Translation,
    end_value: Translation,
    current_frame: u32,
    total_frames: u32,
    easing_function: EasingFunction,
    progress_override: ?f64 = null,

    pub fn initWithEasing(
        start: Translation,
        end: Translation,
        frames: u32,
        easing_function: EasingFunction,
    ) TransformAnimation {
        return .{
            .start_value = start,
            .end_value = end,
            .current_frame = 0,
            .total_frames = frames,
            .easing_function = easing_function,
        };
    }

    pub fn getValue(self: TransformAnimation) Translation {
        if (self.progress_override == null and (self.total_frames == 0 or self.current_frame >= self.total_frames)) return self.end_value;
        const progress = self.progress_override orelse (@as(f64, @floatFromInt(self.current_frame)) /
            @as(f64, @floatFromInt(self.total_frames)));
        const eased = self.easing_function.apply(progress);
        return .{
            .x = self.start_value.x + (self.end_value.x - self.start_value.x) * eased,
            .y = self.start_value.y + (self.end_value.y - self.start_value.y) * eased,
        };
    }

    pub fn advance(self: *TransformAnimation) bool {
        if (self.current_frame < self.total_frames) self.current_frame += 1;
        return self.current_frame >= self.total_frames;
    }

    pub fn isComplete(self: TransformAnimation) bool {
        return self.current_frame >= self.total_frames;
    }
};

/// Property-specific transition state retained by one DOM element.
pub const Animation = union(enum) {
    numeric: NumericAnimation,
    pixel: PixelAnimation,
    color: ColorAnimation,
    transform: TransformAnimation,

    pub fn sample(self: *Animation, progress: f64) void {
        switch (self.*) {
            .numeric => |*track| track.progress_override = progress,
            .pixel => |*track| track.numeric.progress_override = progress,
            .color => |*track| track.progress_override = progress,
            .transform => |*track| track.progress_override = progress,
        }
    }

    /// Caller owns this instantaneous computed CSS value; no track is retained.
    pub fn serialize(self: Animation, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .numeric => |track| std.fmt.allocPrint(allocator, "{d}", .{track.getValue()}),
            .pixel => |track| std.fmt.allocPrint(allocator, "{d}px", .{@max(track.getValue(), 0)}),
            .color => |track| blk: {
                const value = track.getValue();
                break :blk (css_color.Absolute{ .color = value, .alpha = @round(@as(f64, @floatFromInt(value.a)) / 255 * 1000) / 1000 }).serialize(allocator);
            },
            .transform => |track| std.fmt.allocPrint(allocator, "translate({d}px, {d}px)", .{ track.getValue().x, track.getValue().y }),
        };
    }

    pub fn advance(self: *Animation) bool {
        return switch (self.*) {
            .numeric => |*animation| animation.advance(),
            .pixel => |*animation| animation.advance(),
            .color => |*animation| animation.advance(),
            .transform => |*animation| animation.advance(),
        };
    }

    pub fn isComplete(self: Animation) bool {
        return switch (self) {
            .numeric => |animation| animation.isComplete(),
            .pixel => |animation| animation.isComplete(),
            .color => |animation| animation.isComplete(),
            .transform => |animation| animation.isComplete(),
        };
    }

    pub fn reset(self: *Animation) void {
        switch (self.*) {
            .numeric => |*animation| {
                animation.current_frame = 0;
                animation.progress_override = null;
            },
            .pixel => |*animation| {
                animation.numeric.current_frame = 0;
                animation.numeric.progress_override = null;
            },
            .color => |*animation| {
                animation.current_frame = 0;
                animation.progress_override = null;
            },
            .transform => |*animation| {
                animation.current_frame = 0;
                animation.progress_override = null;
            },
        }
    }

    pub fn reverse(self: *Animation) void {
        switch (self.*) {
            .numeric => |*animation| {
                std.mem.swap(f64, &animation.start_value, &animation.end_value);
                animation.easing_function = animation.easing_function.reversed();
            },
            .pixel => |*animation| {
                std.mem.swap(
                    f64,
                    &animation.numeric.start_value,
                    &animation.numeric.end_value,
                );
                animation.numeric.easing_function = animation.numeric.easing_function.reversed();
            },
            .color => |*animation| {
                std.mem.swap(CssColor, &animation.start_value, &animation.end_value);
                animation.easing_function = animation.easing_function.reversed();
            },
            .transform => |*animation| {
                std.mem.swap(
                    Translation,
                    &animation.start_value,
                    &animation.end_value,
                );
                animation.easing_function = animation.easing_function.reversed();
            },
        }
    }
};

pub const CssAnimationState = struct {
    signature: u64,
    name_hash: u64,
    property_mask: u8,
    timing: css_animation.Timing,
    templates: [css_animation_properties.len]?Animation,
    elapsed_frames: f64 = 0,
    progress: ?f64 = null,
    finished: bool = false,

    pub fn contains(self: CssAnimationState, property: []const u8) bool {
        return (self.property_mask & cssAnimationPropertyBit(property)) != 0;
    }

    pub fn isRunning(self: CssAnimationState) bool {
        return !self.finished and !self.timing.paused;
    }

    /// Publish effective tracks, retaining scalar templates through inactive
    /// phases. The map must reserve capacity for all five properties first.
    pub fn publish(self: *CssAnimationState, animations: *std.StringHashMap(Animation)) void {
        const sampled = self.timing.sample(self.elapsed_frames);
        self.progress = sampled.progress;
        self.finished = sampled.finished;
        for (css_animation_properties, self.templates) |property, template| {
            if (template) |original| {
                if (self.progress) |progress| {
                    var track = original;
                    track.sample(progress);
                    animations.putAssumeCapacity(property, track);
                } else _ = animations.remove(property);
            }
        }
    }
};

pub fn cssAnimationPropertyBit(property: []const u8) u8 {
    if (std.mem.eql(u8, property, "opacity")) return 1 << 0;
    if (std.mem.eql(u8, property, "background-color")) return 1 << 1;
    if (std.mem.eql(u8, property, "transform")) return 1 << 2;
    if (std.mem.eql(u8, property, "width")) return 1 << 3;
    if (std.mem.eql(u8, property, "height")) return 1 << 4;
    return 0;
}

pub const css_animation_properties = [_][]const u8{
    "opacity",
    "background-color",
    "transform",
    "width",
    "height",
};

test "color animation interpolates every channel" {
    var animation = ColorAnimation.init(
        .{ .r = 0, .g = 100, .b = 200, .a = 0 },
        .{ .r = 255, .g = 0, .b = 100, .a = 255 },
        4,
    );
    try std.testing.expectEqual(CssColor{ .r = 0, .g = 100, .b = 200, .a = 0 }, animation.getValue());
    _ = animation.advance();
    _ = animation.advance();
    try std.testing.expectEqual(CssColor{ .r = 255, .g = 0, .b = 100, .a = 128 }, animation.getValue());
    _ = animation.advance();
    try std.testing.expect(animation.advance());
    try std.testing.expectEqual(CssColor{ .r = 255, .g = 0, .b = 100, .a = 255 }, animation.getValue());
}

test "numeric and color animations apply easing before interpolation" {
    var numeric = NumericAnimation.initWithEasing(0.0, 100.0, 2, EasingFunction.ease);
    _ = numeric.advance();
    try std.testing.expectApproxEqAbs(80.2403, numeric.getValue(), 0.0001);

    var color = ColorAnimation.initWithEasing(
        .{ .r = 0, .g = 255, .b = 0, .a = 0 },
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        2,
        EasingFunction.ease,
    );
    _ = color.advance();
    try std.testing.expectEqual(
        CssColor{ .r = 255, .g = 0, .b = 0, .a = 205 },
        color.getValue(),
    );
}

test "pixel animation retains units and produces layout values" {
    var animation = PixelAnimation.initWithEasing(100, 200, 2, .linear);
    _ = animation.advance();
    try std.testing.expectApproxEqAbs(@as(f64, 150), animation.getValue(), 0.000001);
    try std.testing.expectEqual(@as(i32, 150), animation.layoutPixels());
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("150.000px", try animation.formatValue(&buffer));
}

test "transform animation eases both translation axes" {
    var animation = TransformAnimation.initWithEasing(
        .{ .x = 0, .y = 100 },
        .{ .x = 100, .y = 0 },
        2,
        EasingFunction.ease,
    );
    _ = animation.advance();
    const midpoint = animation.getValue();
    try std.testing.expectApproxEqAbs(80.2403, midpoint.x, 0.0001);
    try std.testing.expectApproxEqAbs(19.7597, midpoint.y, 0.0001);
    try std.testing.expectEqual(@as(i32, 80), midpoint.layoutPixels().x);
    try std.testing.expectEqual(@as(i32, 20), midpoint.layoutPixels().y);
}

// These tags can look like <tag /> and don't need a closing tag.
