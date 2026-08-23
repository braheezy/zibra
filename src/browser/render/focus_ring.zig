//! Display-command generation for focus and accessibility indicators.

const std = @import("std");
const display = @import("display_list.zig");

const Color = display.Color;
const DisplayItem = display.DisplayItem;
const Rect = display.Rect;

pub const ring_padding: i32 = 2;
pub const outer_thickness: i32 = 4;
pub const inner_thickness: i32 = 2;
pub const outer_color = Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };
pub const inner_color = Color{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff };

pub fn rectAround(x: i32, y: i32, width: i32, height: i32) Rect {
    return .{
        .left = x - ring_padding,
        .top = y - ring_padding,
        .right = x + width + ring_padding,
        .bottom = y + height + ring_padding,
    };
}

pub fn appendOutline(
    items: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    rect: Rect,
    color: Color,
    thickness: i32,
) !void {
    try items.append(allocator, outlineItem(rect, color, thickness));
}

fn outlineItem(rect: Rect, color: Color, thickness: i32) DisplayItem {
    return .{ .outline = .{
        .rect = rect,
        .color = color,
        .thickness = thickness,
    } };
}

/// Paint the broad white stroke first, then the narrower black stroke. One of
/// the two edges therefore contrasts with both light and dark surroundings.
pub fn appendHighContrast(
    items: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    rect: Rect,
) !void {
    // Reserve both slots before publishing either stroke, so allocation
    // failure cannot leave a half-painted focus indicator in the list.
    try items.ensureUnusedCapacity(allocator, 2);
    items.appendAssumeCapacity(outlineItem(rect, outer_color, outer_thickness));
    items.appendAssumeCapacity(outlineItem(rect, inner_color, inner_thickness));
}

test "focus ring paints thick white below thin black" {
    var items = std.ArrayList(DisplayItem).empty;
    defer items.deinit(std.testing.allocator);
    const rect = rectAround(10, 20, 80, 30);

    try appendHighContrast(&items, std.testing.allocator, rect);

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expect(items.items[0] == .outline);
    try std.testing.expect(items.items[1] == .outline);
    try std.testing.expectEqual(Rect{ .left = 8, .top = 18, .right = 92, .bottom = 52 }, rect);
    try std.testing.expectEqual(outer_color, items.items[0].outline.color);
    try std.testing.expectEqual(inner_color, items.items[1].outline.color);
    try std.testing.expectEqual(outer_thickness, items.items[0].outline.thickness);
    try std.testing.expectEqual(inner_thickness, items.items[1].outline.thickness);
    try std.testing.expectEqual(rect, items.items[0].outline.rect);
    try std.testing.expectEqual(rect, items.items[1].outline.rect);
}

test "accessibility outline helper emits one requested stroke" {
    var items = std.ArrayList(DisplayItem).empty;
    defer items.deinit(std.testing.allocator);
    const rect = rectAround(0, 0, 10, 10);
    const amber = Color{ .r = 0xf5, .g = 0x9e, .b = 0x0b, .a = 0xff };

    try appendOutline(&items, std.testing.allocator, rect, amber, 1);

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqual(amber, items.items[0].outline.color);
    try std.testing.expectEqual(@as(i32, 1), items.items[0].outline.thickness);
}
