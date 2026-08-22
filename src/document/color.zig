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

/// Parse the color forms currently supported by Zibra paint: named colors,
/// `#rrggbb`, and `#rrggbbaa`.
pub fn parse(input: []const u8) ?Color {
    const value = std.mem.trim(u8, input, " \t\r\n");
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
    return null;
}

test "CSS colors parse named and alpha-bearing values" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, parse(" RED ").?);
    try std.testing.expectEqual(Color{ .r = 0x12, .g = 0x34, .b = 0x56 }, parse("#123456").?);
    try std.testing.expectEqual(
        Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 },
        parse("#12345678").?,
    );
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, parse("transparent").?);
    try std.testing.expect(parse("not-a-color") == null);
}
