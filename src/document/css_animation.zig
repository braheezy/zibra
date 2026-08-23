//! Parsing for the deliberately small CSS `animation` shorthand subset.
//!
//! Zibra currently supports one named animation, a duration, the timing
//! functions shared with transitions, integer/infinite iteration counts, and
//! normal/alternate direction. This is enough for the chapter demos while
//! keeping playback policy out of the general CSS parser.

const std = @import("std");
const easing = @import("easing.zig");

pub const Direction = enum {
    normal,
    alternate,
};

pub const Spec = struct {
    name: []const u8,
    frames: u32,
    easing_function: easing.Function = .ease,
    iterations: ?u32 = 1,
    direction: Direction = .normal,
};

const frames_per_second: f64 = 60.0;

fn nextToken(value: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < value.len and std.ascii.isWhitespace(value[cursor.*])) cursor.* += 1;
    if (cursor.* == value.len) return null;

    const start = cursor.*;
    var parentheses: usize = 0;
    while (cursor.* < value.len) : (cursor.* += 1) {
        switch (value[cursor.*]) {
            '(' => parentheses += 1,
            ')' => parentheses -|= 1,
            else => {},
        }
        if (parentheses == 0 and std.ascii.isWhitespace(value[cursor.*])) break;
        if (parentheses == 0 and value[cursor.*] == ',') return null;
    }
    return value[start..cursor.*];
}

fn parseDurationFrames(token: []const u8) ?u32 {
    const seconds = if (std.mem.endsWith(u8, token, "ms")) blk: {
        const number = std.fmt.parseFloat(f64, token[0 .. token.len - 2]) catch return null;
        break :blk number / 1000.0;
    } else if (std.mem.endsWith(u8, token, "s")) blk: {
        break :blk std.fmt.parseFloat(f64, token[0 .. token.len - 1]) catch return null;
    } else return null;

    const frame_count = seconds * frames_per_second;
    if (!std.math.isFinite(frame_count) or frame_count < 0 or
        frame_count > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
    return @intFromFloat(frame_count);
}

fn hasTopLevelComma(value: []const u8) bool {
    var parentheses: usize = 0;
    for (value) |char| {
        switch (char) {
            '(' => parentheses += 1,
            ')' => parentheses -|= 1,
            ',' => if (parentheses == 0) return true,
            else => {},
        }
    }
    return false;
}

/// Parse one animation definition. Comma-separated animation lists, delays,
/// fill modes, reverse direction, and fractional iteration counts are outside
/// the current subset and invalidate the declaration.
pub fn parse(value: []const u8) ?Spec {
    if (hasTopLevelComma(value)) return null;
    var result = Spec{ .name = undefined, .frames = 0 };
    var saw_name = false;
    var saw_duration = false;
    var saw_timing = false;
    var saw_iterations = false;
    var saw_direction = false;
    var cursor: usize = 0;

    while (nextToken(value, &cursor)) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;

        if (parseDurationFrames(token)) |frames| {
            if (saw_duration) return null;
            result.frames = frames;
            saw_duration = true;
            continue;
        }
        if (easing.parse(token)) |timing| {
            if (saw_timing) return null;
            result.easing_function = timing;
            saw_timing = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "infinite")) {
            if (saw_iterations) return null;
            result.iterations = null;
            saw_iterations = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "alternate")) {
            if (saw_direction) return null;
            result.direction = .alternate;
            saw_direction = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "normal")) {
            if (saw_direction) return null;
            result.direction = .normal;
            saw_direction = true;
            continue;
        }
        if (std.fmt.parseInt(u32, token, 10)) |count| {
            if (count == 0 or saw_iterations) return null;
            result.iterations = count;
            saw_iterations = true;
            continue;
        } else |_| {}

        if (saw_name or std.ascii.eqlIgnoreCase(token, "none")) return null;
        result.name = token;
        saw_name = true;
    }

    if (!saw_name or !saw_duration or result.frames == 0) return null;
    return result;
}

test "animation shorthand parses the chapter demo" {
    const spec = parse("2s infinite alternate fade").?;
    try std.testing.expectEqualStrings("fade", spec.name);
    try std.testing.expectEqual(@as(u32, 120), spec.frames);
    try std.testing.expect(spec.iterations == null);
    try std.testing.expectEqual(Direction.alternate, spec.direction);
    try std.testing.expectApproxEqAbs(0.802403, spec.easing_function.apply(0.5), 0.000001);
}

test "animation shorthand supports finite linear animation and rejects unsupported lists" {
    const spec = parse("narrow 500ms linear 3").?;
    try std.testing.expectEqualStrings("narrow", spec.name);
    try std.testing.expectEqual(@as(u32, 30), spec.frames);
    try std.testing.expectEqual(@as(?u32, 3), spec.iterations);
    try std.testing.expectApproxEqAbs(0.5, spec.easing_function.apply(0.5), 0.000001);

    try std.testing.expect(parse("1s fade, 1s pulse") == null);
    try std.testing.expect(parse("1s fade , 1s pulse") == null);
    try std.testing.expect(parse("1s backwards fade") == null);
    try std.testing.expect(parse("0s fade") == null);
}
