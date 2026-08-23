//! Supported CSS transform values and interpolation primitives.

const std = @import("std");

pub const Translation = struct {
    x: f64,
    y: f64,

    pub fn eql(self: Translation, other: Translation) bool {
        return self.x == other.x and self.y == other.y;
    }

    pub fn layoutPixels(self: Translation) struct { x: i32, y: i32 } {
        return .{ .x = roundedLayoutPixel(self.x), .y = roundedLayoutPixel(self.y) };
    }
};

fn roundedLayoutPixel(value: f64) i32 {
    const minimum: f64 = @floatFromInt(std.math.minInt(i32));
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    return @intFromFloat(@round(std.math.clamp(value, minimum, maximum)));
}

/// Parse the currently supported transform grammar: `none` or one
/// `translate(x[, y])` using unitless numbers or pixel lengths.
pub fn parse(input: []const u8) ?Translation {
    const value = std.mem.trim(u8, input, " \t\n\r");
    if (std.ascii.eqlIgnoreCase(value, "none")) return .{ .x = 0, .y = 0 };

    const prefix = "translate(";
    if (value.len <= prefix.len or value[value.len - 1] != ')' or
        !std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix))
    {
        return null;
    }

    const arguments = value[prefix.len .. value.len - 1];
    var parts = std.mem.splitScalar(u8, arguments, ',');
    const x = parseLength(parts.next() orelse return null) orelse return null;
    const y = if (parts.next()) |part|
        parseLength(part) orelse return null
    else
        0.0;
    if (parts.next() != null) return null;
    return .{ .x = x, .y = y };
}

fn parseLength(input: []const u8) ?f64 {
    const value = std.mem.trim(u8, input, " \t\n\r");
    const number = if (std.mem.endsWith(u8, value, "px"))
        std.mem.trim(u8, value[0 .. value.len - 2], " \t\n\r")
    else
        value;
    const parsed = std.fmt.parseFloat(f64, number) catch return null;
    if (!std.math.isFinite(parsed)) return null;
    const minimum: f64 = @floatFromInt(std.math.minInt(i32));
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    if (parsed < minimum or parsed > maximum) return null;
    return parsed;
}

test "translate parser accepts pixels, fractions, and none" {
    try std.testing.expectEqual(Translation{ .x = 10, .y = -20 }, parse("translate(10px, -20px)").?);
    try std.testing.expectEqual(Translation{ .x = 4.5, .y = 0 }, parse(" TRANSLATE(4.5px) ").?);
    try std.testing.expectEqual(Translation{ .x = 0, .y = 0 }, parse("none").?);
    try std.testing.expect(parse("scale(2)") == null);
    try std.testing.expect(parse("translate(1px, 2px, 3px)") == null);
}
