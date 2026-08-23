//! Shared parsing and serialization for the supported CSS pixel-length subset.

const std = @import("std");

/// Parse a finite, non-negative `<number>px` value. `auto`, percentages, and
/// other units remain outside the browser's current dimension model.
pub fn parsePixel(input: []const u8) ?f64 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len < 2 or !std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px")) return null;
    const number = std.mem.trim(u8, value[0 .. value.len - 2], " \t\r\n");
    if (number.len == 0) return null;
    const pixels = std.fmt.parseFloat(f64, number) catch return null;
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(pixels) or pixels < 0 or pixels > maximum) return null;
    return pixels;
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
