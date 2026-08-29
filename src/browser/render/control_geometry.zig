//! Pure used-value calculations for replaced form controls.
//!
//! Control objects, font lookup, DOM state, display-command ownership, and
//! invalidation dependencies stay in `layout.zig`. These helpers only convert
//! already-resolved inputs into leaf geometry or display text.

const std = @import("std");
const display_list = @import("display_list.zig");

pub const InputBoxMetrics = struct {
    width: i32,
    height: i32,
    border_radius: f64,
};

pub const ButtonBoxMetrics = struct {
    width: i32,
    height: i32,
    content_offset_x: i32,
    content_offset_y: i32,
};

/// Resolve the atomic box of a text input, checkbox, or radio button.
/// Choice controls deliberately use the line's natural height in both axes;
/// authored dimensions apply only to text/password inputs in Zibra's subset.
pub fn inputBoxMetrics(
    natural_height: i32,
    default_text_width: i32,
    is_choice: bool,
    is_radio: bool,
    authored_width: ?i32,
    authored_height: ?i32,
    border_radius: f64,
) InputBoxMetrics {
    const natural = @max(natural_height, 1);
    const width = if (is_choice)
        natural
    else if (authored_width) |value|
        @max(value, 1)
    else
        @max(default_text_width, 1);
    const height = if (is_choice)
        natural
    else if (authored_height) |value|
        @max(value, natural)
    else
        natural;
    const radius = if (is_radio and border_radius <= 0)
        @as(f64, @floatFromInt(natural)) / 2.0
    else
        @max(border_radius, 0);
    return .{ .width = width, .height = height, .border_radius = radius };
}

pub fn inputDisplayGrapheme(is_password: bool, source: []const u8) []const u8 {
    if (is_password) return "*";
    if (std.mem.eql(u8, source, "\n") or std.mem.eql(u8, source, "\r")) return " ";
    return source;
}

pub fn buttonBoxMetrics(
    content_bounds: display_list.Rect,
    padding: i32,
) ButtonBoxMetrics {
    return .{
        .width = content_bounds.width() + 2 * padding,
        .height = content_bounds.height() + 2 * padding,
        .content_offset_x = padding - content_bounds.left,
        .content_offset_y = padding - content_bounds.top,
    };
}

test "choice and text input metrics honor their sizing contracts" {
    const text = inputBoxMetrics(18, 200, false, false, 120, 10, 6);
    try std.testing.expectEqual(@as(i32, 120), text.width);
    try std.testing.expectEqual(@as(i32, 18), text.height);
    try std.testing.expectEqual(@as(f64, 6), text.border_radius);

    const checkbox = inputBoxMetrics(18, 200, true, false, 120, 40, 0);
    try std.testing.expectEqual(@as(i32, 18), checkbox.width);
    try std.testing.expectEqual(@as(i32, 18), checkbox.height);
    try std.testing.expectEqual(@as(f64, 0), checkbox.border_radius);

    const radio = inputBoxMetrics(18, 200, true, true, null, null, 0);
    try std.testing.expectEqual(@as(i32, 18), radio.width);
    try std.testing.expectEqual(@as(i32, 18), radio.height);
    try std.testing.expectEqual(@as(f64, 9), radio.border_radius);
}

test "password display masks one source grapheme at a time" {
    try std.testing.expectEqualStrings("*", inputDisplayGrapheme(true, "a"));
    try std.testing.expectEqualStrings("*", inputDisplayGrapheme(true, "🙂"));
    try std.testing.expectEqualStrings("x", inputDisplayGrapheme(false, "x"));
    try std.testing.expectEqualStrings(" ", inputDisplayGrapheme(false, "\n"));
}

test "rich button metrics enclose negative-offset content" {
    const metrics = buttonBoxMetrics(.{
        .left = -12,
        .top = -3,
        .right = 240,
        .bottom = 117,
    }, 4);
    try std.testing.expectEqual(@as(i32, 260), metrics.width);
    try std.testing.expectEqual(@as(i32, 128), metrics.height);
    try std.testing.expectEqual(@as(i32, 16), metrics.content_offset_x);
    try std.testing.expectEqual(@as(i32, 7), metrics.content_offset_y);
}
