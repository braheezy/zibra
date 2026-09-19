//! Pointer-free intrinsic sizing, box conversion and used-size constraints.
//! Callers own style dependencies and supply page-layout units except for the
//! explicit CSS length context; this module retains no DOM or layout borrows.
const std = @import("std");
const grammar = @import("../../document/css_sizing.zig");
const length = @import("../../document/length.zig");

pub const Intrinsic = struct { min: f64 = 0, max: f64 = 0 };

pub const Constraints = struct {
    min: f64 = 0,
    max: f64 = std.math.inf(f64),

    /// The minimum wins contradictory limits, and content sizes stay nonnegative.
    pub fn clamp(self: Constraints, value: f64) f64 {
        return @max(@max(self.min, 0), @min(value, self.max));
    }
};

/// Convert an authored sizing-box dimension to content-box page units.
pub fn toContent(size: f64, insets: f64, border_box: bool) f64 {
    return @max(size - if (border_box) insets else @as(f64, 0), 0);
}

pub fn toBorder(content: f64, insets: f64) f64 {
    return @max(content, 0) + @max(insets, 0);
}

pub fn fitContent(intrinsic: Intrinsic, available: f64) f64 {
    return @max(intrinsic.min, @min(@max(available, 0), intrinsic.max));
}

pub const ResolveContext = struct {
    font_size: f64 = 16,
    percentage_base: ?f64 = null,
    scale: f64 = 1,
    insets: f64 = 0,
    border_box: bool = false,
    intrinsic: Intrinsic = .{},
    available: ?f64 = null,
};

/// Resolve a width/minimum/maximum into content-box page units. Auto, none and
/// unresolved percentages return null. Intrinsic keywords name content sizes,
/// so box-sizing subtraction applies only to authored lengths/percentages.
pub fn resolve(raw: []const u8, context: ResolveContext) ?f64 {
    const value = grammar.parse(raw) orelse return null;
    return switch (value) {
        .auto, .none => null,
        .min_content => @max(context.intrinsic.min, 0),
        .max_content => @max(context.intrinsic.max, context.intrinsic.min),
        .fit_content => fitContent(context.intrinsic, context.available orelse context.intrinsic.max),
        .length => |text| toContent((length.resolve(text, .{
            .font_size = context.font_size,
            .percentage_base = context.percentage_base,
        }) orelse return null) * context.scale, context.insets, context.border_box),
    };
}

pub const Suggestions = struct {
    content: f64,
    specified: ?f64 = null,
    transferred: ?f64 = null,
    maximum: ?f64 = null,
    replaced: bool = false,
    scrollable: bool = false,
};

/// Flex content-based automatic minimum, in one consistent sizing box. The
/// caller transfers cross-axis ratio limits before passing the suggestions.
pub fn automaticMinimum(suggestions: Suggestions) f64 {
    if (suggestions.scrollable) return 0;
    var result = suggestions.content;
    if (suggestions.transferred) |transferred| {
        result = if (suggestions.replaced) @min(result, transferred) else @max(result, transferred);
    }
    if (suggestions.specified) |specified| result = @min(result, specified);
    if (suggestions.maximum) |maximum| result = @min(result, maximum);
    return @max(result, 0);
}

test "shared sizing constraints preserve box floors and minimum precedence" {
    try std.testing.expectEqual(@as(f64, 0), toContent(10, 24, true));
    try std.testing.expectEqual(@as(f64, 24), toBorder(toContent(10, 24, true), 24));
    try std.testing.expectEqual(@as(f64, 80), (Constraints{ .min = 80, .max = 40 }).clamp(60));
    try std.testing.expectEqual(@as(f64, 50), fitContent(.{ .min = 50, .max = 100 }, 20));
    try std.testing.expectEqual(@as(f64, 80), fitContent(.{ .min = 50, .max = 100 }, 80));
    try std.testing.expectEqual(@as(f64, 100), fitContent(.{ .min = 50, .max = 100 }, 300));
}

test "shared sizing resolves intrinsic content independently from border box" {
    const context = ResolveContext{ .intrinsic = .{ .min = 40, .max = 140 }, .available = 80, .insets = 20, .border_box = true, .percentage_base = 100, .scale = 2 };
    try std.testing.expectEqual(@as(?f64, 80), resolve("fit-content", context));
    try std.testing.expectEqual(@as(?f64, 40), resolve("min-content", context));
    try std.testing.expectEqual(@as(?f64, 140), resolve("max-content", context));
    try std.testing.expectEqual(@as(?f64, 80), resolve("50%", context));
    try std.testing.expectEqual(@as(?f64, null), resolve("50%", .{}));
    try std.testing.expectEqual(@as(?f64, 0), resolve("50%", .{ .percentage_base = 0 }));
}

test "shared automatic minima distinguish replaced ratio transfer and overflow" {
    try std.testing.expectEqual(@as(f64, 80), automaticMinimum(.{ .content = 120, .transferred = 80, .replaced = true }));
    try std.testing.expectEqual(@as(f64, 120), automaticMinimum(.{ .content = 120, .transferred = 80 }));
    try std.testing.expectEqual(@as(f64, 60), automaticMinimum(.{ .content = 120, .specified = 100, .maximum = 60 }));
    try std.testing.expectEqual(@as(f64, 0), automaticMinimum(.{ .content = 120, .scrollable = true }));
}
