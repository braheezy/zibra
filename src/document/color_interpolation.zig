//! Pointer-free CSS color interpolation shared by color-mix and animation.
//! Coordinates remain unquantized and outside the display gamut until paint.
const std = @import("std");
const spaces = @import("color_space.zig");
const tokens = @import("css_tokenizer.zig");
pub const Coordinates = spaces.Coordinates;
pub const max_colors = 32;
pub const Hue = enum { shorter, longer, increasing, decreasing };
pub const Method = struct {
    space: spaces.Space = .oklab,
    hue: Hue = .shorter,

    /// Parse a borrowed `in <space> [<method> hue]` prelude.
    pub fn parse(input: []const u8) ?Method {
        var lexer = tokens.Iterator{ .input = input };
        var names: [4][]const u8 = undefined;
        var count: usize = 0;
        while (lexer.next()) |token| {
            if (token.isTrivia()) continue;
            if (token.kind != .ident or count == names.len) return null;
            names[count] = token.encodedValue(input);
            count += 1;
        }
        if ((count != 2 and count != 4) or !tokens.identifierEquals(names[0], "in")) return null;
        const space = spaces.Space.parse(names[1]) orelse return null;
        var hue = Hue.shorter;
        if (count == 4) {
            if (space.hueIndex() == null or !tokens.identifierEquals(names[3], "hue")) return null;
            hue = inline for (std.meta.tags(Hue)) |candidate| {
                if (tokens.identifierEquals(names[2], @tagName(candidate))) break candidate;
            } else return null;
        }
        return .{ .space = space, .hue = hue };
    }
};

const Analog = enum { red, green, blue, lightness, colorfulness, hue, a, b, white, black };
fn analogs(space: spaces.Space) [3]Analog {
    return switch (space) {
        .hsl => .{ .hue, .colorfulness, .lightness },
        .hwb => .{ .hue, .white, .black },
        .lab, .oklab => .{ .lightness, .a, .b },
        .lch, .oklch => .{ .lightness, .colorfulness, .hue },
        else => .{ .red, .green, .blue },
    };
}

fn powerless(color: Coordinates) bool {
    return switch (color.space) {
        .hsl => (color.components[1] orelse 0) <= 0.001,
        .hwb => (color.components[1] orelse 0) + (color.components[2] orelse 0) >= 99.999,
        .lch => (color.components[1] orelse 0) <= 0.0015,
        .oklch => (color.components[1] orelse 0) <= 0.000004,
        else => false,
    };
}

/// Convert for interpolation, carrying analogous missing components and sets.
/// Authored powerless hues are preserved when no space conversion is needed.
pub fn convert(source: Coordinates, destination: spaces.Space) Coordinates {
    if (source.space == destination) return source;
    const before = analogs(source.space);
    const after = analogs(destination);
    var carried = [_]bool{false} ** 3;
    var analogous = [_]bool{false} ** 3;
    var unmatched_all_missing = true;
    var unmatched_count: usize = 0;
    for (before, 0..) |category, i| {
        var matched = false;
        for (after, 0..) |target, j| if (category == target) {
            matched = true;
            analogous[j] = true;
            carried[j] = source.components[i] == null;
        };
        if (!matched) {
            unmatched_count += 1;
            unmatched_all_missing = unmatched_all_missing and source.components[i] == null;
        }
    }
    var numerical = source;
    if (source.space.hueIndex()) |h| if (powerless(source)) {
        numerical.components[h] = null;
    };
    const rgb = spaces.toSrgb(numerical.space, numerical.values());
    const converted = spaces.fromSrgb(destination, rgb);
    var result = Coordinates{ .space = destination, .components = .{ converted[0], converted[1], converted[2], source.components[3] } };
    if (destination.hueIndex()) |h| if (powerless(result)) {
        result.components[h] = null;
    };
    for (0..3) |i| {
        if (carried[i] or (!analogous[i] and unmatched_count > 0 and unmatched_all_missing)) result.components[i] = null;
    }
    return result;
}

fn nextHue(previous: f64, next: f64, method: Hue) f64 {
    const start = @mod(previous, 360);
    var delta = @mod(next, 360) - start;
    switch (method) {
        .shorter => if (delta > 180) {
            delta -= 360;
        } else if (delta < -180) {
            delta += 360;
        },
        .longer => if (delta > 0 and delta < 180) {
            delta -= 360;
        } else if (delta > -180 and delta <= 0) {
            delta += 360;
        },
        .increasing => if (delta < 0) {
            delta += 360;
        },
        .decreasing => if (delta > 0) {
            delta -= 360;
        },
    }
    return previous + delta;
}

/// Mix a bounded list whose weights sum to one or are all zero. The caller normalizes CSS
/// percentages and applies any under-100% alpha multiplier after interpolation.
/// Color-mix weights are nonnegative; sample() also supports extrapolation.
pub fn mix(colors: []const Coordinates, weights: []const f64, method: Method) Coordinates {
    std.debug.assert(colors.len > 0 and colors.len <= max_colors and weights.len == colors.len);
    var result = convert(colors[0], method.space);
    var total = weights[0];
    for (colors[1..], weights[1..]) |color, weight| {
        total += weight;
        result = sample(result, color, if (total > 0) weight / total else 0.5, method);
    }
    return result;
}

/// Sample two unquantized endpoints at an eased progress value.
pub fn sample(start: Coordinates, end: Coordinates, progress: f64, method: Method) Coordinates {
    const colors = [_]Coordinates{ start, end };
    const weights = [_]f64{ 1 - progress, progress };
    var prepared: [2]Coordinates = undefined;
    for (colors, 0..) |color, i| prepared[i] = convert(color, method.space);
    var missing = [_]bool{false} ** 4;
    for (0..4) |channel| {
        var weighted: f64 = 0;
        var total: f64 = 0;
        var unweighted: f64 = 0;
        var present: usize = 0;
        for (prepared[0..colors.len], weights) |color, weight| if (color.components[channel]) |value| {
            weighted += value * weight;
            total += weight;
            unweighted += value;
            present += 1;
        };
        missing[channel] = present == 0;
        const replacement = if (present == 0) (if (channel == 3) @as(f64, 1) else 0) else if (total == 0) unweighted / @as(f64, @floatFromInt(present)) else weighted / total;
        for (prepared[0..colors.len]) |*color| if (color.components[channel] == null) {
            color.components[channel] = replacement;
        };
    }
    const hue = method.space.hueIndex();
    if (hue) |h| {
        for (1..colors.len) |i| prepared[i].components[h] = nextHue(prepared[i - 1].components[h].?, prepared[i].components[h].?, method.hue);
    }
    var alpha: f64 = 0;
    for (prepared[0..colors.len], weights) |color, weight| alpha += color.components[3].? * weight;
    var result = Coordinates{ .space = method.space, .components = .{ null, null, null, if (missing[3]) null else alpha } };
    for (0..3) |channel| {
        if (missing[channel]) continue;
        var value: f64 = 0;
        for (prepared[0..colors.len], weights) |color, weight| value += color.components[channel].? * weight * (if (hue == channel) @as(f64, 1) else color.components[3].?);
        result.components[channel] = if (hue == channel) @mod(value, 360) else if (alpha == 0) 0 else value / alpha;
    }
    return result;
}

test "CSS color interpolation preserves precision alpha missing components and hue paths" {
    const red = Coordinates{ .space = .srgb, .components = .{ 1, 0, 0, 0 } };
    const blue = Coordinates{ .space = .srgb, .components = .{ 0, 0, 1, 1 } };
    try std.testing.expectEqual([4]?f64{ 0, 0, 1, 0.5 }, sample(red, blue, 0.5, .{ .space = .srgb }).components);
    const missing = Coordinates{ .space = .srgb, .components = .{ null, 0.2, null, null } };
    try std.testing.expectEqual([4]?f64{ 0, 0.1, 1, 1 }, sample(missing, blue, 0.5, .{ .space = .srgb }).components);
    const a = Coordinates{ .space = .oklch, .components = .{ 0.6, 0.2, 350, 1 } };
    const b = Coordinates{ .space = .oklch, .components = .{ 0.6, 0.2, 10, 1 } };
    for ([_]Hue{ .shorter, .longer, .increasing, .decreasing }, [_]f64{ 0, 180, 0, 180 }) |hue, expected| {
        try std.testing.expectApproxEqAbs(expected, sample(a, b, 0.5, .{ .space = .oklch, .hue = hue }).components[2].?, 0.000001);
    }
    const achromatic = Coordinates{ .space = .lab, .components = .{ 50, null, null, 1 } };
    const polar = convert(achromatic, .oklch);
    try std.testing.expect(polar.components[0] != null and polar.components[1] == null and polar.components[2] == null);
}

test "CSS color interpolation converts every supported space without clipping" {
    const rgb = spaces.Vector{ 0.2, 0.4, 0.6 };
    for (std.meta.tags(spaces.Space)) |space| {
        const roundtrip = spaces.toSrgb(space, spaces.fromSrgb(space, rgb));
        for (roundtrip, rgb) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
    }
    const extended = Coordinates{ .space = .display_p3, .components = .{ 1, 0, 0, 0.123456 } };
    const converted = convert(extended, .srgb);
    try std.testing.expect(converted.components[0].? > 1 and converted.components[1].? < 0);
    try std.testing.expectEqual(extended.components[3], converted.components[3]);
    for ([_]spaces.Space{ .hsl, .hwb }) |space| {
        const polar = convert(extended, space);
        const rgb_after = spaces.toSrgb(space, polar.values());
        for (rgb_after, converted.values()) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
    }
    try std.testing.expect(Method.parse("in srgb longer hue") == null);
    try std.testing.expectEqual(Method{ .space = .oklch, .hue = .longer }, Method.parse("in oklch longer hue").?);
}
