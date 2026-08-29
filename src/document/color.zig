//! CSS color values shared by style mutation and layout paint.

const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

const NamedColor = struct {
    name: []const u8,
    value: Color,
};

const named_colors = [_]NamedColor{
    .{ .name = "transparent", .value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    .{ .name = "red", .value = .{ .r = 255, .g = 0, .b = 0 } },
    .{ .name = "maroon", .value = .{ .r = 128, .g = 0, .b = 0 } },
    .{ .name = "navy", .value = .{ .r = 0, .g = 0, .b = 128 } },
    .{ .name = "green", .value = .{ .r = 0, .g = 128, .b = 0 } },
    .{ .name = "blue", .value = .{ .r = 0, .g = 0, .b = 255 } },
    .{ .name = "yellow", .value = .{ .r = 255, .g = 255, .b = 0 } },
    .{ .name = "gray", .value = .{ .r = 128, .g = 128, .b = 128 } },
    .{ .name = "grey", .value = .{ .r = 128, .g = 128, .b = 128 } },
    .{ .name = "lightgray", .value = .{ .r = 211, .g = 211, .b = 211 } },
    .{ .name = "lightgrey", .value = .{ .r = 211, .g = 211, .b = 211 } },
    .{ .name = "white", .value = .{ .r = 255, .g = 255, .b = 255 } },
    .{ .name = "black", .value = .{ .r = 0, .g = 0, .b = 0 } },
    .{ .name = "orange", .value = .{ .r = 255, .g = 165, .b = 0 } },
    .{ .name = "purple", .value = .{ .r = 128, .g = 0, .b = 128 } },
    .{ .name = "pink", .value = .{ .r = 255, .g = 192, .b = 203 } },
    .{ .name = "lightblue", .value = .{ .r = 173, .g = 216, .b = 230 } },
    .{ .name = "lightgreen", .value = .{ .r = 144, .g = 238, .b = 144 } },
    .{ .name = "cyan", .value = .{ .r = 0, .g = 255, .b = 255 } },
    .{ .name = "magenta", .value = .{ .r = 255, .g = 0, .b = 255 } },
    .{ .name = "orangered", .value = .{ .r = 255, .g = 69, .b = 0 } },
};

fn expandHexNibble(input: []const u8) ?u8 {
    const nibble = std.fmt.parseInt(u8, input, 16) catch return null;
    return nibble * 17;
}

fn parseRgbComponent(input: []const u8) ?u8 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return null;
    if (value[value.len - 1] == '%') {
        const percentage = std.fmt.parseFloat(f64, value[0 .. value.len - 1]) catch return null;
        if (!std.math.isFinite(percentage)) return null;
        return @intFromFloat(@round(std.math.clamp(percentage, 0.0, 100.0) * 255.0 / 100.0));
    }
    const component = std.fmt.parseInt(i32, value, 10) catch return null;
    return @intCast(std.math.clamp(component, 0, 255));
}

fn parseAlphaComponent(input: []const u8) ?u8 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return null;
    if (value[value.len - 1] == '%') {
        const percentage = std.fmt.parseFloat(f64, value[0 .. value.len - 1]) catch return null;
        if (!std.math.isFinite(percentage)) return null;
        return @intFromFloat(@round(std.math.clamp(percentage, 0.0, 100.0) * 255.0 / 100.0));
    }
    const alpha = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(alpha)) return null;
    return @intFromFloat(@round(std.math.clamp(alpha, 0.0, 1.0) * 255.0));
}

fn parseRgbFunction(value: []const u8) ?Color {
    const is_rgba = value.len >= 5 and std.ascii.eqlIgnoreCase(value[0..5], "rgba(");
    const prefix_len: usize = if (is_rgba)
        5
    else if (value.len >= 4 and std.ascii.eqlIgnoreCase(value[0..4], "rgb("))
        4
    else
        return null;
    if (value[value.len - 1] != ')') return null;

    var components: [4][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, value[prefix_len .. value.len - 1], ',');
    while (iterator.next()) |component| {
        if (count == components.len) return null;
        components[count] = component;
        count += 1;
    }
    if (count != if (is_rgba) @as(usize, 4) else @as(usize, 3)) return null;
    return .{
        .r = parseRgbComponent(components[0]) orelse return null,
        .g = parseRgbComponent(components[1]) orelse return null,
        .b = parseRgbComponent(components[2]) orelse return null,
        .a = if (is_rgba) parseAlphaComponent(components[3]) orelse return null else 255,
    };
}

/// Parse named colors, short/long hexadecimal colors, and comma-separated
/// `rgb()`/`rgba()` functions.
pub fn parse(input: []const u8) ?Color {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if ((value.len == 4 or value.len == 5) and value[0] == '#') {
        return .{
            .r = expandHexNibble(value[1..2]) orelse return null,
            .g = expandHexNibble(value[2..3]) orelse return null,
            .b = expandHexNibble(value[3..4]) orelse return null,
            .a = if (value.len == 5) expandHexNibble(value[4..5]) orelse return null else 255,
        };
    }
    if (value.len == 9 and value[0] == '#') {
        return .{
            .r = std.fmt.parseInt(u8, value[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, value[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, value[5..7], 16) catch return null,
            .a = std.fmt.parseInt(u8, value[7..9], 16) catch return null,
        };
    }
    if (value.len == 7 and value[0] == '#') {
        return .{
            .r = std.fmt.parseInt(u8, value[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, value[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, value[5..7], 16) catch return null,
        };
    }

    for (named_colors) |named| {
        if (std.ascii.eqlIgnoreCase(value, named.name)) return named.value;
    }
    return parseRgbFunction(value);
}

test "CSS colors parse named and alpha-bearing values" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, parse(" RED ").?);
    try std.testing.expectEqual(Color{ .r = 128, .g = 0, .b = 0 }, parse("maroon").?);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 128 }, parse("NAVY").?);
    try std.testing.expectEqual(Color{ .r = 0x12, .g = 0x34, .b = 0x56 }, parse("#123456").?);
    try std.testing.expectEqual(Color{ .r = 0xff, .g = 0xcc, .b = 0x00 }, parse("#FC0").?);
    try std.testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 }, parse("#1234").?);
    try std.testing.expectEqual(
        Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 },
        parse("#12345678").?,
    );
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, parse("transparent").?);
    try std.testing.expectEqual(Color{ .r = 204, .g = 0, .b = 0 }, parse("rgb(204, 0, 0)").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 128, .b = 0 }, parse("rgb(100%, 50%, 0%)").?);
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0, .a = 128 }, parse("rgba(255, 0, 0, .5)").?);
    try std.testing.expect(parse("not-a-color") == null);
}
