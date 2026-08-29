//! Shared paint leaves for backgrounds and replaced controls.
//!
//! Functions append owning display-command containers where required but do
//! not own layout objects. Pixel slices and command provenance remain borrowed
//! from the current document generation until a raster snapshot copies them.

const std = @import("std");
const parser = @import("../../document/parser.zig");
const background_image = @import("../../document/background_image.zig");
const display_list = @import("display_list.zig");

const DisplayItem = display_list.DisplayItem;

pub const BackgroundImagePaint = struct {
    pixels: []const u8,
    source_width: i32,
    source_height: i32,
    size: background_image.Size,
    repeat: background_image.Repeat,
    position: []const u8,
};

pub fn backgroundImagePaint(element: *const parser.Element) ?BackgroundImagePaint {
    const installed = element.background_image orelse return null;
    const data = installed.data orelse return null;
    const styles = if (element.style) |*style_map| style_map else return null;
    const size = if (styleValue(styles, "background-size")) |value|
        background_image.parseSize(value) orelse background_image.Size.automatic()
    else
        background_image.Size.automatic();
    const repeat = if (styleValue(styles, "background-repeat")) |value|
        background_image.parseRepeat(value) orelse background_image.Repeat{ .x = true, .y = true }
    else
        background_image.Repeat{ .x = true, .y = true };
    return .{
        .pixels = data.image.rawBytes(),
        .source_width = @intCast(data.image.width),
        .source_height = @intCast(data.image.height),
        .size = size,
        .repeat = repeat,
        .position = styleValue(styles, "background-position") orelse "0 0",
    };
}

pub fn backgroundImagePaintForSource(source: ?display_list.DisplayItemSource) ?BackgroundImagePaint {
    const node = (source orelse return null).node orelse return null;
    return switch (node.*) {
        .element => |*element| backgroundImagePaint(element),
        .text => null,
    };
}

pub fn appendBackgroundBox(
    commands: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    radius: f64,
    color: display_list.Color,
    source: ?display_list.DisplayItemSource,
) !void {
    if (color.a == 0) return;
    if (radius > 0) {
        try commands.append(allocator, .{ .rounded_rect = .{
            .x1 = x,
            .y1 = y,
            .x2 = x + width,
            .y2 = y + height,
            .radius = radius,
            .color = color,
            .source = source,
        } });
    } else {
        try commands.append(allocator, .{ .rect = .{
            .x1 = x,
            .y1 = y,
            .x2 = x + width,
            .y2 = y + height,
            .color = color,
            .source = source,
        } });
    }
}

/// Paint one positioned background tile clipped to the element's box. The
/// raster command retains repetition metadata so small images do not produce
/// one display command per tile.
pub fn appendBackgroundImageBox(
    commands: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    paint: BackgroundImagePaint,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    css_scale: f64,
    source: ?display_list.DisplayItemSource,
) !void {
    const resolved = background_image.resolveSize(
        paint.size,
        width,
        height,
        paint.source_width,
        paint.source_height,
        css_scale,
    );
    if (resolved.width <= 0 or resolved.height <= 0) return;
    const position = background_image.resolvePosition(
        paint.position,
        width,
        height,
        resolved.width,
        resolved.height,
        css_scale,
    );

    try commands.append(allocator, .{ .image = .{
        .x1 = x,
        .y1 = y,
        .x2 = x + width,
        .y2 = y + height,
        .source_width = paint.source_width,
        .source_height = paint.source_height,
        .pixels = paint.pixels,
        .tiling = .{
            .width = resolved.width,
            .height = resolved.height,
            .offset_x = position.x,
            .offset_y = position.y,
            .repeat_x = paint.repeat.x,
            .repeat_y = paint.repeat.y,
        },
        .source = source,
    } });
}

/// Move a control's complete payload into one non-painting rounded hit group.
/// On success `items` is empty and the destination owns its former commands.
pub fn appendRoundedControlGroup(
    destination: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    items: *std.ArrayList(DisplayItem),
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    radius: f64,
    source: ?display_list.DisplayItemSource,
) !void {
    const children = try items.toOwnedSlice(allocator);
    var children_owned = true;
    errdefer if (children_owned) DisplayItem.freeList(allocator, children);

    try destination.append(allocator, .{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .hit_clip = .{
            .x1 = x,
            .y1 = y,
            .x2 = x + width,
            .y2 = y + height,
            .radius = radius,
        },
        .children = children,
        .needs_compositing = false,
        .source = source,
    } });
    children_owned = false;
}

fn styleValue(style_map: *const parser.StyleMap, property: []const u8) ?[]const u8 {
    const field = @constCast(style_map).getPtr(property) orelse return null;
    return field.get().*;
}

test "background image paint resolves size and fractional source crop" {
    const pixels = [_]u8{
        255, 0,   0, 255,
        0,   255, 0, 255,
    };
    var commands = std.ArrayList(DisplayItem).empty;
    defer commands.deinit(std.testing.allocator);

    try appendBackgroundImageBox(
        &commands,
        std.testing.allocator,
        .{
            .pixels = &pixels,
            .source_width = 2,
            .source_height = 1,
            .size = .cover,
            .repeat = .{ .x = false, .y = false },
            .position = "0 0",
        },
        10,
        20,
        100,
        100,
        1.0,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), commands.items.len);
    const image = commands.items[0].image;
    try std.testing.expectEqual(@as(i32, 10), image.x1);
    try std.testing.expectEqual(@as(i32, 110), image.x2);
    try std.testing.expectEqual(@as(i32, 200), image.tiling.?.width);
    try std.testing.expect(!image.tiling.?.repeat_x);
}

test "rounded control group constrains child hits without compositing" {
    var origin: u8 = 0;
    const source = display_list.DisplayItemSource{
        .layout = @ptrCast(&origin),
        .node = null,
    };
    var content = std.ArrayList(DisplayItem).empty;
    defer {
        DisplayItem.freeItems(std.testing.allocator, content.items);
        content.deinit(std.testing.allocator);
    }
    try appendBackgroundBox(
        &content,
        std.testing.allocator,
        0,
        0,
        100,
        40,
        0,
        .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        source,
    );

    var grouped = std.ArrayList(DisplayItem).empty;
    defer {
        DisplayItem.freeItems(std.testing.allocator, grouped.items);
        grouped.deinit(std.testing.allocator);
    }
    try appendRoundedControlGroup(
        &grouped,
        std.testing.allocator,
        &content,
        0,
        0,
        100,
        40,
        20,
        source,
    );

    try std.testing.expectEqual(@as(usize, 0), content.items.len);
    try std.testing.expect(grouped.items[0] == .blend);
    try std.testing.expect(grouped.items[0].blend.hit_clip != null);
    try std.testing.expect(!grouped.items[0].blend.needs_compositing);
    try std.testing.expect(DisplayItem.hitTestDevice(grouped.items, 50, 20, 1.0) != null);
    try std.testing.expect(DisplayItem.hitTestDevice(grouped.items, 1, 1, 1.0) == null);
}
