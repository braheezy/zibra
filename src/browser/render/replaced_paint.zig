//! Shared paint leaves for backgrounds and replaced controls.
//!
//! Functions append owning display-command containers where required but do
//! not own layout objects. External pixels and provenance borrow the current
//! generation; generated gradients own scalar stops copied again at snapshot.

const std = @import("std");
const parser = @import("../../document/parser.zig");
const background_image = @import("../../document/background_image.zig");
const display_list = @import("display_list.zig");
const paint_effects = @import("paint_effects.zig");
const BoxEdges = @import("box_model.zig").BoxEdges;

const DisplayItem = display_list.DisplayItem;

pub const BackgroundImagePaint = struct {
    pixels: []const u8,
    source_width: i32,
    source_height: i32,
    size: background_image.Size,
    repeat: background_image.Repeat,
    position: []const u8,
    font_size: f64 = 16,
    attachment: display_list.ImageTiling.Attachment,
    gradient_source: ?[]const u8 = null,
    foreground: []const u8 = "black",
    border_radius: f64 = 0,
    origin: background_image.Origin = .padding_box,
};

pub fn backgroundImagePaint(element: *const parser.Element) ?BackgroundImagePaint {
    const styles = if (element.style) |*style_map| style_map else return null;
    const image_value = styleValue(styles, "background-image") orelse "none";
    const gradient = if (@import("../../document/css_gradient.zig").parse(image_value) != null) image_value else null;
    const data = if (gradient == null) (element.background_image orelse return null).data orelse return null else null;
    const size = if (styleValue(styles, "background-size")) |value|
        background_image.parseSize(value) orelse background_image.Size.automatic()
    else
        background_image.Size.automatic();
    const repeat = if (styleValue(styles, "background-repeat")) |value|
        background_image.parseRepeat(value) orelse background_image.Repeat{ .x = true, .y = true }
    else
        background_image.Repeat{ .x = true, .y = true };
    return .{
        .pixels = if (data) |image| image.image.rawBytes() else &.{},
        .source_width = if (data) |image| @intCast(image.image.width) else 1,
        .source_height = if (data) |image| @intCast(image.image.height) else 1,
        .gradient_source = gradient,
        .foreground = styleValue(styles, "color") orelse "black",
        .border_radius = @import("box_model.zig").parseCssPixelRadius(styleValue(styles, "border-radius") orelse "0px"),
        .origin = background_image.parseOrigin(styleValue(styles, "background-origin") orelse "padding-box") orelse .padding_box,
        .size = size,
        .repeat = repeat,
        .position = styleValue(styles, "background-position") orelse "0% 0%",
        .font_size = @import("../../document/length.zig").parsePixel(styleValue(styles, "font-size") orelse "16px") orelse 16,
        // `local` needs a scrollable element's own scroll offset, which is
        // outside this single-layer background subset. It therefore retains
        // the ordinary scroll-attached phase until element scrolling gains a
        // dedicated background coordinate space.
        .attachment = if (styleValue(styles, "background-attachment")) |value|
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n\x0c"), "fixed"))
                .fixed
            else
                .scroll
        else
            .scroll,
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

/// Paint one positioned background tile clipped to the element's border box.
/// Used borders and padding are already scaled by layout. Origin selects the
/// positioning area without shrinking the paint clip.
/// The raster command retains repetition metadata so small images do not produce
/// one display command per tile. A fixed attachment resolves its size and
/// position against the frame viewport but keeps the supplied element box as
/// its paint clip.
pub fn appendBackgroundImageBox(
    commands: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    paint: BackgroundImagePaint,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    border: BoxEdges,
    padding: BoxEdges,
    viewport_width: i32,
    viewport_height: i32,
    css_scale: f64,
    source: ?display_list.DisplayItemSource,
) !void {
    if (width <= 0 or height <= 0) return;
    const fixed = paint.attachment == .fixed;
    const insets: BoxEdges = switch (paint.origin) {
        .border_box => .{},
        .padding_box => border,
        .content_box => .{
            .left = border.left +| padding.left,
            .right = border.right +| padding.right,
            .top = border.top +| padding.top,
            .bottom = border.bottom +| padding.bottom,
        },
    };
    const positioning_width = if (fixed) viewport_width else @max(width -| insets.left -| insets.right, 0);
    const positioning_height = if (fixed) viewport_height else @max(height -| insets.top -| insets.bottom, 0);
    const resolved = if (paint.gradient_source != null) background_image.resolveGeneratedSize(paint.size, positioning_width, positioning_height, css_scale) else background_image.resolveSize(
        paint.size,
        positioning_width,
        positioning_height,
        paint.source_width,
        paint.source_height,
        css_scale,
    );
    if (resolved.width <= 0 or resolved.height <= 0) return;
    const position = background_image.resolvePosition(
        paint.position,
        positioning_width,
        positioning_height,
        resolved.width,
        resolved.height,
        css_scale,
        paint.font_size,
    );

    const gradient = if (paint.gradient_source) |input|
        try @import("../../document/gradient_line.zig").Linear.init(allocator, input, .{
            .font_size = paint.font_size,
            .current_color = @import("../../document/color.zig").parseAbsolute(paint.foreground),
        }, @as(f64, @floatFromInt(resolved.width)) / css_scale, @as(f64, @floatFromInt(resolved.height)) / css_scale)
    else
        null;
    errdefer if (gradient) |owned| owned.deinit(allocator);
    if (paint.gradient_source != null and gradient == null) return;
    try commands.append(allocator, .{ .image = .{
        .x1 = x,
        .y1 = y,
        .x2 = x + width,
        .y2 = y + height,
        .source_width = paint.source_width,
        .source_height = paint.source_height,
        .pixels = paint.pixels,
        .gradient = gradient,
        .clip_radius = paint.border_radius * css_scale,
        .tiling = .{
            .width = resolved.width,
            .height = resolved.height,
            .offset_x = position.x +| if (fixed) @as(i32, 0) else insets.left,
            .offset_y = position.y +| if (fixed) @as(i32, 0) else insets.top,
            .repeat_x = paint.repeat.x,
            .repeat_y = paint.repeat.y,
            .attachment = paint.attachment,
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

/// Consume an editor's glyph/caret commands into a real raster and hit clip.
/// The control shell stays outside this group. `items` is empty after transfer,
/// including on failure; the returned command containers belong to destination.
pub fn appendEditorClip(destination: *std.ArrayList(DisplayItem), allocator: std.mem.Allocator, items: *std.ArrayList(DisplayItem), bounds: display_list.Rect, source: ?display_list.DisplayItemSource) !void {
    const wrapped = try paint_effects.wrapOwned(allocator, try items.toOwnedSlice(allocator), .{ .clips_overflow = true }, .{ .bounds = bounds, .source = source });
    errdefer DisplayItem.freeList(allocator, wrapped);
    try destination.appendSlice(allocator, wrapped);
    allocator.free(wrapped);
}

fn styleValue(style_map: *const parser.StyleMap, property: []const u8) ?[]const u8 {
    const field = @constCast(style_map).getPtr(property) orelse return null;
    return field.get().*;
}

fn roundedGradientAllocationCheck(allocator: std.mem.Allocator) !void {
    var commands: std.ArrayList(DisplayItem) = .empty;
    defer commands.deinit(allocator);
    defer DisplayItem.freeItems(allocator, commands.items);
    try appendBackgroundImageBox(&commands, allocator, .{
        .pixels = &.{},
        .source_width = 1,
        .source_height = 1,
        .size = .cover,
        .repeat = .{ .x = true, .y = true },
        .position = "0 0",
        .attachment = .scroll,
        .gradient_source = "linear-gradient(red, blue)",
        .border_radius = 8,
    }, 0, 0, 20, 20, .{}, .{}, 400, 300, 2, null);
    try std.testing.expectEqual(@as(usize, 1), commands.items.len);
    try std.testing.expect(commands.items[0] == .image);
    try std.testing.expectEqual(@as(f64, 16), commands.items[0].image.clip_radius);
}

test "rounded gradient background publication releases every partial owner on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, roundedGradientAllocationCheck, .{});
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
            .attachment = .scroll,
        },
        10,
        20,
        100,
        100,
        .{},
        .{},
        300,
        200,
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

test "fixed background images use viewport sizing but retain element clipping" {
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
            .size = .{ .dimensions = .{ .width = .{ .percentage = 50 }, .height = .auto } },
            .repeat = .{ .x = false, .y = false },
            .position = "100% 0",
            .attachment = .fixed,
        },
        40,
        80,
        20,
        20,
        .{ .top = 3, .left = 5, .bottom = 3, .right = 5 },
        .{},
        200,
        100,
        1.0,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), commands.items.len);
    const image = commands.items[0].image;
    try std.testing.expectEqual(@as(i32, 40), image.x1);
    try std.testing.expectEqual(@as(i32, 80), image.y1);
    try std.testing.expectEqual(@as(i32, 60), image.x2);
    try std.testing.expectEqual(@as(i32, 100), image.y2);
    try std.testing.expectEqual(@as(i32, 100), image.tiling.?.width);
    try std.testing.expectEqual(@as(i32, 100), image.tiling.?.offset_x);
    try std.testing.expectEqual(display_list.ImageTiling.Attachment.fixed, image.tiling.?.attachment);
}

test "CSS background edge positions preserve font zoom negative offsets and clip geometry" {
    const pixels = [_]u8{ 0, 128, 0, 255 };
    var commands: std.ArrayList(DisplayItem) = .empty;
    defer commands.deinit(std.testing.allocator);
    try appendBackgroundImageBox(&commands, std.testing.allocator, .{
        .pixels = &pixels,
        .source_width = 1,
        .source_height = 1,
        .size = .{ .dimensions = .{ .width = .{ .pixels = 20 }, .height = .{ .pixels = 10 } } },
        .position = "bottom -5px right 1em",
        .font_size = 24,
        .repeat = .{ .x = false, .y = false },
        .attachment = .scroll,
    }, 10, 20, 200, 100, .{ .left = 3, .right = 7, .top = 5, .bottom = 9 }, .{}, 800, 600, 2, null);
    const command = commands.items[0].image;
    try std.testing.expectEqual(10, command.x1);
    try std.testing.expectEqual(210, command.x2);
    try std.testing.expectEqual(40, command.tiling.?.width);
    try std.testing.expectEqual(105, command.tiling.?.offset_x);
    try std.testing.expectEqual(81, command.tiling.?.offset_y);
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

test "background origin changes tile size and phase independently of clipping" {
    const allocator = std.testing.allocator;
    const Case = struct { origin: background_image.Origin, width: i32, height: i32, x: i32, y: i32 };
    const cases = [_]Case{
        .{ .origin = .border_box, .width = 100, .height = 60, .x = 100, .y = 60 },
        .{ .origin = .padding_box, .width = 90, .height = 50, .x = 95, .y = 54 },
        .{ .origin = .content_box, .width = 75, .height = 40, .x = 90, .y = 52 },
    };
    for (cases) |case| for ([_]bool{ false, true }) |fixed| for ([_]bool{ false, true }) |generated| {
        var commands: std.ArrayList(DisplayItem) = .empty;
        defer commands.deinit(allocator);
        defer DisplayItem.freeItems(allocator, commands.items);
        try appendBackgroundImageBox(&commands, allocator, .{
            .pixels = &.{ 0, 255, 0, 255 },
            .source_width = 1,
            .source_height = 1,
            .size = .{ .dimensions = .{ .width = .{ .percentage = 50 }, .height = .{ .percentage = 50 } } },
            .repeat = .{ .x = true, .y = false },
            .position = "100% 100%",
            .attachment = if (fixed) .fixed else .scroll,
            .origin = case.origin,
            .gradient_source = if (generated) "linear-gradient(red, blue)" else null,
        }, 30, 40, 200, 120, .{ .left = 5, .right = 15, .top = 4, .bottom = 16 }, .{ .left = 10, .right = 20, .top = 8, .bottom = 12 }, 800, 600, 2, null);
        const command = commands.items[0].image;
        try std.testing.expectEqual(30, command.x1);
        try std.testing.expectEqual(230, command.x2);
        try std.testing.expectEqual(40, command.y1);
        try std.testing.expectEqual(160, command.y2);
        try std.testing.expectEqual(if (fixed) @as(i32, 400) else case.width, command.tiling.?.width);
        try std.testing.expectEqual(if (fixed) @as(i32, 300) else case.height, command.tiling.?.height);
        try std.testing.expectEqual(if (fixed) @as(i32, 400) else case.x, command.tiling.?.offset_x);
        try std.testing.expectEqual(if (fixed) @as(i32, 300) else case.y, command.tiling.?.offset_y);
        try std.testing.expectEqual(generated, command.gradient != null);
    };
}

test "empty background content area does not publish a generated image" {
    var commands: std.ArrayList(DisplayItem) = .empty;
    defer commands.deinit(std.testing.allocator);
    defer DisplayItem.freeItems(std.testing.allocator, commands.items);
    try appendBackgroundImageBox(&commands, std.testing.allocator, .{
        .pixels = &.{},
        .source_width = 1,
        .source_height = 1,
        .size = .cover,
        .repeat = .{ .x = true, .y = true },
        .position = "center",
        .attachment = .scroll,
        .origin = .content_box,
        .gradient_source = "linear-gradient(red, blue)",
    }, 0, 0, 10, 10, .{}, .{ .left = 10, .right = 10 }, 800, 600, 1, null);
    try std.testing.expectEqual(0, commands.items.len);
}
