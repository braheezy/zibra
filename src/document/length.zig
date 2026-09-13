//! Shared parsing and resolution for the supported CSS length subset.

const std = @import("std");

pub const Unit = enum {
    px,
    mm,
    em,
    rem,
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
    /// Root element's computed font size; the initial size when resolving
    /// `font-size` on the root itself (including in a separate iframe).
    root_font_size: f64 = 16.0,
    percentage_base: ?f64 = null,
    /// Image positions use area minus image size, which may be negative.
    /// Other length consumers retain their nonnegative basis contract.
    signed_percentage_basis: bool = false,
};

/// Parse a finite, non-negative CSS length in the supported `px`, `mm`, `em`,
/// `rem`, or percentage units. CSS permits a unitless zero anywhere a length is
/// expected; it canonicalizes to `0px`. Other unitless numbers and `auto`
/// remain invalid lengths.
pub fn parse(input: []const u8) ?Length {
    const value = std.mem.trim(u8, input, " \t\r\n\x0c");
    if (value.len == 0) return null;

    // Keep parsing and used-value resolution aligned with declaration
    // validation: `width: 0` is a real zero length, not an auto width.
    if (std.fmt.parseFloat(f64, value)) |unitless| {
        if (std.math.isFinite(unitless) and unitless == 0) {
            return .{ .value = 0, .unit = .px };
        }
    } else |_| {}

    const suffix: struct { unit: Unit, number_end: usize } = if (value[value.len - 1] == '%')
        .{ .unit = .percent, .number_end = value.len - 1 }
    else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px"))
        .{ .unit = .px, .number_end = value.len - 2 }
    else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "mm"))
        .{ .unit = .mm, .number_end = value.len - 2 }
    else if (value.len >= 3 and std.ascii.eqlIgnoreCase(value[value.len - 3 ..], "rem"))
        .{ .unit = .rem, .number_end = value.len - 3 }
    else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "em"))
        .{ .unit = .em, .number_end = value.len - 2 }
    else
        return null;

    // A dimension is one token: whitespace between number and unit is not
    // permitted (notably after var(--number)px substitution).
    const number = value[0..suffix.number_end];
    for (number) |byte| if (std.ascii.isWhitespace(byte)) return null;
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
        // CSS defines one inch as 96 CSS pixels, and an inch as 25.4 mm.
        .mm => length.value / 25.4 * 96.0,
        .em => length.value * context.font_size,
        .rem => if (std.math.isFinite(context.root_font_size) and context.root_font_size >= 0)
            length.value * context.root_font_size
        else
            null,
        .percent => blk: {
            const base = context.percentage_base orelse return null;
            if (!std.math.isFinite(base) or (base < 0 and !context.signed_percentage_basis)) return null;
            break :blk length.value * base / 100.0;
        },
    };
}

/// Parse and resolve a supported CSS length directly to CSS pixels.
pub fn resolve(input: []const u8, context: ResolutionContext) ?f64 {
    if (parse(input)) |length| return resolveLength(length, context);
    return if (resolveMath(input, context)) |value| @max(value, 0) else null;
}

pub const isMath = @import("css_math.zig").isMath;

/// Resolve typed CSS math without range clamping, for signed offsets/margins.
/// Length consumers reject non-finite results and require a length result.
pub fn resolveMath(input: []const u8, context: ResolutionContext) ?f64 {
    if (!isMath(input)) return null;
    if (context.percentage_base) |base| {
        if (!std.math.isFinite(base) or (base < 0 and !context.signed_percentage_basis)) return null;
    }
    const result = @import("css_math.zig").evaluate(input, .{
        .font_size = context.font_size,
        .root_font_size = context.root_font_size,
        .percentage = if (context.percentage_base) |base| .{ .dimension = .length, .value = base } else null,
    }) orelse return null;
    return if (result.dimension == .length and std.math.isFinite(result.value)) result.value else null;
}

test "CSS math preserves root and percentage context and validates dimensions" {
    try std.testing.expectEqual(@as(?f64, 360), resolve("calc(100% - 2rem)", .{ .percentage_base = 400, .root_font_size = 20 }));
    try std.testing.expectEqual(@as(?f64, 30), resolve("clamp(1rem, calc(4rem / 2), 30px)", .{ .root_font_size = 20 }));
    try std.testing.expectEqual(@as(?f64, -20), resolveMath("calc(1rem - 40px)", .{ .root_font_size = 20 }));
    try std.testing.expect(resolve("calc(1px + 2)", .{}) == null);
    try std.testing.expect(resolve("calc(1rem / 0)", .{}) == null);
    try std.testing.expect(resolve("calc(1rem +2px)", .{}) == null);
    try std.testing.expect(resolve("calc(100% - 2rem)", .{}) == null);
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
    try std.testing.expectEqual(@as(?f64, 0), parsePixel("0"));
    try std.testing.expectEqual(@as(?f64, 0), parsePixel("-0"));
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
    try std.testing.expectEqual(@as(?f64, 0), resolve("0", .{}));
    try std.testing.expect(parsePixel("2em") == null);
    try std.testing.expect(parse("1") == null);
    try std.testing.expect(parse("2EX") == null);
}

test "millimeter lengths use the CSS 96dpi absolute-unit conversion" {
    const millimeters = parse("25.4MM").?;
    try std.testing.expectEqual(Unit.mm, millimeters.unit);
    try std.testing.expectApproxEqAbs(
        @as(f64, 96.0),
        resolveLength(millimeters, .{}).?,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 96.0 / 25.4),
        resolve("1mm", .{}).?,
        0.000001,
    );
    try std.testing.expect(parsePixel("1mm") == null);
}

test "CSS math distinguishes whitespace tokens from boundary comments" {
    try std.testing.expect(resolveMath("calc(10px /**/+/**/ 2px)", .{}) == 12);
    try std.testing.expect(resolveMath("calc(10px/**/+/**/2px)", .{}) == null);
    try std.testing.expect(resolveMath("calc(10px +/**/2px)", .{}) == null);
    try std.testing.expect(resolveMath("calc(10px/**/+ 2px)", .{}) == null);
}
