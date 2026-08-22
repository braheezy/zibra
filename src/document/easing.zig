//! CSS transition timing functions.
//!
//! Cubic Bezier curves map normalized animation time through the CSS timing
//! function's x coordinate, then return the corresponding y coordinate.

const std = @import("std");

pub const CubicBezier = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,

    fn coordinate(first: f64, second: f64, parameter: f64) f64 {
        const inverse = 1.0 - parameter;
        return 3.0 * inverse * inverse * parameter * first +
            3.0 * inverse * parameter * parameter * second +
            parameter * parameter * parameter;
    }

    /// Return the y value whose Bezier x value matches `progress`.
    /// CSS constrains x control points to [0, 1], so bisection is monotonic
    /// and avoids the convergence edge cases of Newton iteration.
    pub fn apply(self: CubicBezier, progress: f64) f64 {
        if (progress <= 0.0) return 0.0;
        if (progress >= 1.0) return 1.0;

        var lower: f64 = 0.0;
        var upper: f64 = 1.0;
        var parameter: f64 = progress;
        for (0..30) |_| {
            parameter = (lower + upper) / 2.0;
            const x = coordinate(self.x1, self.x2, parameter);
            if (x < progress) {
                lower = parameter;
            } else {
                upper = parameter;
            }
        }
        return coordinate(self.y1, self.y2, parameter);
    }
};

pub const Function = union(enum) {
    linear,
    cubic_bezier: CubicBezier,

    pub const ease = Function{ .cubic_bezier = .{
        .x1 = 0.25,
        .y1 = 0.1,
        .x2 = 0.25,
        .y2 = 1.0,
    } };
    pub const ease_in = Function{ .cubic_bezier = .{
        .x1 = 0.42,
        .y1 = 0.0,
        .x2 = 1.0,
        .y2 = 1.0,
    } };
    pub const ease_out = Function{ .cubic_bezier = .{
        .x1 = 0.0,
        .y1 = 0.0,
        .x2 = 0.58,
        .y2 = 1.0,
    } };
    pub const ease_in_out = Function{ .cubic_bezier = .{
        .x1 = 0.42,
        .y1 = 0.0,
        .x2 = 0.58,
        .y2 = 1.0,
    } };

    pub fn apply(self: Function, progress: f64) f64 {
        return switch (self) {
            .linear => progress,
            .cubic_bezier => |curve| curve.apply(progress),
        };
    }
};

/// Parse the supported CSS timing-function keywords and explicit
/// `cubic-bezier(x1, y1, x2, y2)` values. Per CSS, x1 and x2 must be within
/// [0, 1]; y values may overshoot that interval.
pub fn parse(input: []const u8) ?Function {
    const value = std.mem.trim(u8, input, " \t\n\r");
    if (std.ascii.eqlIgnoreCase(value, "linear")) return .linear;
    if (std.ascii.eqlIgnoreCase(value, "ease")) return Function.ease;
    if (std.ascii.eqlIgnoreCase(value, "ease-in")) return Function.ease_in;
    if (std.ascii.eqlIgnoreCase(value, "ease-out")) return Function.ease_out;
    if (std.ascii.eqlIgnoreCase(value, "ease-in-out")) return Function.ease_in_out;

    const prefix = "cubic-bezier(";
    if (value.len <= prefix.len or value[value.len - 1] != ')' or
        !std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix))
    {
        return null;
    }

    const arguments = value[prefix.len .. value.len - 1];
    var parts = std.mem.splitScalar(u8, arguments, ',');
    var values: [4]f64 = undefined;
    for (&values) |*number| {
        const part = parts.next() orelse return null;
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        number.* = std.fmt.parseFloat(f64, trimmed) catch return null;
        if (!std.math.isFinite(number.*)) return null;
    }
    if (parts.next() != null or values[0] < 0.0 or values[0] > 1.0 or
        values[2] < 0.0 or values[2] > 1.0)
    {
        return null;
    }

    return .{ .cubic_bezier = .{
        .x1 = values[0],
        .y1 = values[1],
        .x2 = values[2],
        .y2 = values[3],
    } };
}

test "CSS timing functions map normalized progress" {
    try std.testing.expectApproxEqAbs(0.5, @as(Function, .linear).apply(0.5), 0.000001);
    try std.testing.expectApproxEqAbs(0.802403, Function.ease.apply(0.5), 0.000001);
    try std.testing.expectApproxEqAbs(0.315357, Function.ease_in.apply(0.5), 0.000001);
    try std.testing.expectApproxEqAbs(0.684643, Function.ease_out.apply(0.5), 0.000001);
    try std.testing.expectApproxEqAbs(0.5, Function.ease_in_out.apply(0.5), 0.000001);
    try std.testing.expectEqual(@as(f64, 0.0), Function.ease.apply(0.0));
    try std.testing.expectEqual(@as(f64, 1.0), Function.ease.apply(1.0));
}

test "explicit cubic-bezier parsing validates control points" {
    const explicit = parse("cubic-bezier(0.25, 0.1, 0.25, 1)").?;
    try std.testing.expectApproxEqAbs(Function.ease.apply(0.5), explicit.apply(0.5), 0.000001);
    try std.testing.expect(parse("CUBIC-BEZIER(0, 0, 1, 1)") != null);
    try std.testing.expect(parse("cubic-bezier(-0.1, 0, 1, 1)") == null);
    try std.testing.expect(parse("cubic-bezier(0, 0, 1.1, 1)") == null);
    try std.testing.expect(parse("cubic-bezier(0, 0, 1)") == null);
    try std.testing.expect(parse("steps(2)") == null);
}
