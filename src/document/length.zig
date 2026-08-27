//! Shared parsing and resolution for the supported CSS length subset.

const std = @import("std");

pub const Unit = enum {
    px,
    em,
    percent,
};

pub const Length = struct {
    value: f64,
    unit: Unit,
};

/// Context needed to turn a parsed relative length into CSS pixels.
///
/// `font_size` is the computed font size of the element using the length.
/// `percentage_base` is the containing-block dimension for the property being
/// resolved. It is intentionally optional: percentage heights in an
/// auto-sized containing block do not have a definite used value.
pub const ResolutionContext = struct {
    font_size: f64 = 16.0,
    percentage_base: ?f64 = null,
};

/// Parse a finite, non-negative CSS length in the supported `px`, `em`, or
/// percentage units. Unitless numbers and `auto` remain invalid lengths.
pub fn parse(input: []const u8) ?Length {
    const value = std.mem.trim(u8, input, " \t\r\n\x0c");
    if (value.len == 0) return null;

    const suffix: struct { unit: Unit, number_end: usize } = if (value[value.len - 1] == '%')
        .{ .unit = .percent, .number_end = value.len - 1 }
    else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px"))
        .{ .unit = .px, .number_end = value.len - 2 }
    else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "em"))
        .{ .unit = .em, .number_end = value.len - 2 }
    else
        return null;

    const number = std.mem.trim(u8, value[0..suffix.number_end], " \t\r\n\x0c");
    if (number.len == 0) return null;
    const numeric = std.fmt.parseFloat(f64, number) catch return null;
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(numeric) or numeric < 0 or numeric > maximum) return null;
    return .{ .value = numeric, .unit = suffix.unit };
}

/// Resolve a parsed CSS length to unscaled CSS pixels.
pub fn resolveLength(length: Length, context: ResolutionContext) ?f64 {
    if (!std.math.isFinite(context.font_size) or context.font_size < 0) return null;
    return switch (length.unit) {
        .px => length.value,
        .em => length.value * context.font_size,
        .percent => blk: {
            const base = context.percentage_base orelse return null;
            if (!std.math.isFinite(base) or base < 0) return null;
            break :blk length.value * base / 100.0;
        },
    };
}

/// Parse and resolve a supported CSS length directly to CSS pixels.
pub fn resolve(input: []const u8, context: ResolutionContext) ?f64 {
    return resolveLength(parse(input) orelse return null, context);
}

/// Parse a finite, non-negative `<number>px` value. Relative units are kept
/// out of this compatibility helper for callers such as pixel animations.
pub fn parsePixel(input: []const u8) ?f64 {
    const length = parse(input) orelse return null;
    if (length.unit != .px) return null;
    return length.value;
}

pub fn toLayoutPixels(value: f64) i32 {
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    return @intFromFloat(std.math.clamp(value, 0.0, maximum));
}

pub fn formatPixel(buffer: []u8, value: f64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d:.3}px", .{value});
}

test "pixel lengths parse and serialize the supported dimension grammar" {
    try std.testing.expectApproxEqAbs(@as(f64, 12.75), parsePixel(" 12.75PX ").?, 0.000001);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.750px", try formatPixel(&buffer, 12.75));
    try std.testing.expect(parsePixel("auto") == null);
    try std.testing.expect(parsePixel("50%") == null);
    try std.testing.expect(parsePixel("-1px") == null);
}

test "relative lengths resolve against explicit CSS context" {
    const em = parse("1.5em").?;
    try std.testing.expectEqual(Unit.em, em.unit);
    try std.testing.expectApproxEqAbs(
        @as(f64, 18.0),
        resolveLength(em, .{ .font_size = 12.0 }).?,
        0.000001,
    );

    const percentage = parse(" 41.17% ").?;
    try std.testing.expectEqual(Unit.percent, percentage.unit);
    try std.testing.expectApproxEqAbs(
        @as(f64, 98.808),
        resolveLength(percentage, .{ .percentage_base = 240.0 }).?,
        0.000001,
    );
    try std.testing.expect(resolve("50%", .{}) == null);
    try std.testing.expectEqual(@as(?f64, 24.0), resolve("2em", .{ .font_size = 12.0 }));
    try std.testing.expect(parsePixel("2em") == null);
    try std.testing.expect(parse("2EX") == null);
}
