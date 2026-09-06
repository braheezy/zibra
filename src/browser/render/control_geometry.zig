//! Pure used-value calculations for replaced form controls.
//!
//! Control objects, font lookup, DOM state, display-command ownership, and
//! invalidation dependencies stay in `layout.zig`. These helpers only convert
//! already-resolved inputs into leaf geometry or display text.

const std = @import("std");
const display_list = @import("display_list.zig");
const BoxEdges = @import("box_model.zig").BoxEdges;

/// Resolved layout-coordinate sizes. Min wins over max, including when the
/// authored border box is smaller than its padding and borders.
pub const Axis = struct {
    preferred: ?i32 = null,
    min: ?i32 = null,
    max: ?i32 = null,

    fn content(self: Axis, natural: i32, edges: i32, border_box: bool) i32 {
        const subtract = if (border_box) edges else 0;
        var value = if (self.preferred) |v| @max(v -| subtract, 0) else natural;
        if (self.max) |v| value = @min(value, @max(v -| subtract, 0));
        if (self.min) |v| value = @max(value, @max(v -| subtract, 0));
        return @max(value, 0);
    }
};

/// Pointer-free used box shared by native-control paint and CSSOM snapshots.
pub const TextBox = struct {
    content_width: i32 = 0,
    content_height: i32 = 0,
    padding: BoxEdges = .{},
    border: BoxEdges = .{},

    pub fn width(self: TextBox) i32 {
        return self.content_width +| self.padding.horizontal() +| self.border.horizontal();
    }
    pub fn height(self: TextBox) i32 {
        return self.content_height +| self.padding.vertical() +| self.border.vertical();
    }
};

pub fn textBox(natural_width: i32, natural_height: i32, horizontal: Axis, vertical: Axis, padding: BoxEdges, border: BoxEdges, border_box: bool) TextBox {
    return .{
        .content_width = horizontal.content(natural_width, padding.horizontal() + border.horizontal(), border_box),
        .content_height = vertical.content(natural_height, padding.vertical() + border.vertical(), border_box),
        .padding = padding,
        .border = border,
    };
}

/// Single-line editors clip to the content box horizontally and padding box
/// vertically. Multiline editors expose the padding box in both axes.
pub fn clientInsets(border: BoxEdges, padding: BoxEdges, single_line: bool) BoxEdges {
    var result = border;
    if (single_line) {
        result.left += padding.left;
        result.right += padding.right;
    }
    return result;
}

test "geometry text control used boxes honor constraints and editor clipping" {
    const padding = BoxEdges{ .top = 2, .right = 2, .bottom = 2, .left = 2 };
    const border = BoxEdges{ .top = 10, .right = 20, .bottom = 10, .left = 20 };
    const content = textBox(200, 18, .{ .preferred = 300 }, .{ .preferred = 200 }, padding, border, false);
    try std.testing.expectEqual(@as(i32, 344), content.width());
    try std.testing.expectEqual(@as(i32, 224), content.height());
    try std.testing.expectEqual(@as(i32, 22), clientInsets(border, padding, true).left);
    try std.testing.expectEqual(@as(i32, 20), clientInsets(border, padding, false).left);
    const constrained = textBox(200, 18, .{ .preferred = 300, .min = 120, .max = 100 }, .{ .preferred = 0 }, padding, border, true);
    try std.testing.expectEqual(@as(i32, 120), constrained.width());
    try std.testing.expectEqual(@as(i32, 24), constrained.height());
    try std.testing.expectEqual(@as(i32, 0), constrained.content_height);
}

pub const ChoiceBoxMetrics = struct {
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

/// Resolve the atomic box of a checkbox or radio button.
/// Choice controls deliberately use the line's natural height in both axes;
/// CSS sizing for these themed widgets remains outside the text-editor subset.
pub fn choiceBoxMetrics(
    natural_height: i32,
    is_radio: bool,
    border_radius: f64,
) ChoiceBoxMetrics {
    const natural = @max(natural_height, 1);
    const radius = if (is_radio and border_radius <= 0)
        @as(f64, @floatFromInt(natural)) / 2.0
    else
        @max(border_radius, 0);
    return .{ .width = natural, .height = natural, .border_radius = radius };
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

test "choice input metrics honor their sizing contracts" {
    const checkbox = choiceBoxMetrics(18, false, 0);
    try std.testing.expectEqual(@as(i32, 18), checkbox.width);
    try std.testing.expectEqual(@as(i32, 18), checkbox.height);
    try std.testing.expectEqual(@as(f64, 0), checkbox.border_radius);

    const radio = choiceBoxMetrics(18, true, 0);
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
