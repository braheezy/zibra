//! Ownership-safe materialization of retained display-command trees.
//!
//! Persistent layout caches are normally borrowed through `cached_subtree`.
//! Callers use this module only when commands must outlive that cache owner,
//! such as a temporary rich-button layout or a raster snapshot boundary.

const std = @import("std");
const display_list = @import("display_list.zig");

const DisplayItem = display_list.DisplayItem;

pub const CloneError = error{OutOfMemory};

pub fn cloneList(
    allocator: std.mem.Allocator,
    items: []const DisplayItem,
) CloneError![]DisplayItem {
    const copy = try allocator.alloc(DisplayItem, items.len);
    var initialized: usize = 0;
    errdefer {
        DisplayItem.freeItems(allocator, copy[0..initialized]);
        allocator.free(copy);
    }
    for (items, 0..) |item, index| {
        copy[index] = try cloneItem(allocator, item);
        initialized += 1;
    }
    return copy;
}

pub fn cloneItem(
    allocator: std.mem.Allocator,
    item: DisplayItem,
) CloneError!DisplayItem {
    return switch (item) {
        // A materialized command cannot retain a pointer to another layout
        // object's cache. An identity transform provides an owning container.
        .cached_subtree => |cached| .{ .transform = .{
            .translate_x = 0,
            .translate_y = 0,
            .children = try cloneList(allocator, cached.list.items),
            .source = cached.source,
        } },
        .canvas => |canvas| blk: {
            var copy = canvas;
            copy.pixels = pixels: {
                const source = canvas.source orelse break :pixels try allocator.dupe(u8, canvas.pixels);
                const node = source.originatingNode() orelse break :pixels try allocator.dupe(u8, canvas.pixels);
                if (node.* != .element or
                    !std.ascii.eqlIgnoreCase(node.element.tag, "canvas"))
                {
                    break :pixels try allocator.dupe(u8, canvas.pixels);
                }
                const backing = node.element.canvas orelse break :pixels try allocator.dupe(u8, canvas.pixels);
                break :pixels try backing.snapshot(allocator);
            };
            copy.owns_pixels = true;
            break :blk .{ .canvas = copy };
        },
        .blend => |blend| blk: {
            const children = try cloneList(allocator, blend.children);
            var children_owned = true;
            errdefer if (children_owned) DisplayItem.freeList(allocator, children);

            const blend_mode = if (blend.blend_mode) |mode|
                try allocator.dupe(u8, mode)
            else
                null;
            children_owned = false;
            break :blk .{ .blend = .{
                .opacity = blend.opacity,
                .blend_mode = blend_mode,
                .blur_radius = blend.blur_radius,
                .hit_clip = blend.hit_clip,
                .children = children,
                .node = blend.node,
                .parent = null,
                .needs_compositing = blend.needs_compositing,
                .compositor_id = blend.compositor_id,
                .source = blend.source,
            } };
        },
        .transform => |transform| .{ .transform = .{
            .translate_x = transform.translate_x,
            .translate_y = transform.translate_y,
            .scroll_attachment = transform.scroll_attachment,
            .children = try cloneList(allocator, transform.children),
            .node = transform.node,
            .composited = transform.composited,
            .animation_active = transform.animation_active,
            .compositor_id = transform.compositor_id,
            .source = transform.source,
        } },
        else => item,
    };
}

pub fn appendClone(
    allocator: std.mem.Allocator,
    destination: *std.ArrayList(DisplayItem),
    item: DisplayItem,
) !void {
    var owned = [1]DisplayItem{try cloneItem(allocator, item)};
    var transferred = false;
    errdefer if (!transferred) DisplayItem.freeItems(allocator, owned[0..]);
    try destination.append(allocator, owned[0]);
    transferred = true;
}

test "materialization recursively owns nested containers and metadata" {
    const allocator = std.testing.allocator;

    const transform_children = try allocator.alloc(DisplayItem, 1);
    transform_children[0] = .{ .rect = .{
        .x1 = 1,
        .y1 = 2,
        .x2 = 30,
        .y2 = 40,
        .color = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
    } };
    const blend_children = try allocator.alloc(DisplayItem, 1);
    blend_children[0] = .{ .transform = .{
        .translate_x = 5,
        .translate_y = 7,
        .scroll_attachment = .frame_viewport,
        .children = transform_children,
    } };
    const blend_mode = try allocator.dupe(u8, "multiply");
    var cached = [1]DisplayItem{.{ .blend = .{
        .opacity = 0.5,
        .blend_mode = blend_mode,
        .blur_radius = 3.0,
        .hit_clip = .{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 40, .radius = 8 },
        .children = blend_children,
    } }};

    const snapshot = try cloneList(allocator, cached[0..]);
    defer DisplayItem.freeList(allocator, snapshot);
    DisplayItem.freeItems(allocator, cached[0..]);

    try std.testing.expectEqualStrings("multiply", snapshot[0].blend.blend_mode.?);
    try std.testing.expectEqual(@as(f64, 3.0), snapshot[0].blend.blur_radius);
    try std.testing.expectEqual(@as(f64, 8), snapshot[0].blend.hit_clip.?.radius);
    try std.testing.expectEqual(@as(i32, 5), snapshot[0].blend.children[0].transform.translate_x);
    try std.testing.expectEqual(
        display_list.ScrollAttachment.frame_viewport,
        snapshot[0].blend.children[0].transform.scroll_attachment,
    );
    try std.testing.expectEqual(
        @as(i32, 30),
        snapshot[0].blend.children[0].transform.children[0].rect.x2,
    );
}

test "cached subtree materializes as an owning identity transform" {
    var retained = std.ArrayList(DisplayItem).empty;
    defer retained.deinit(std.testing.allocator);
    try retained.append(std.testing.allocator, .{ .rect = .{
        .x1 = 1,
        .y1 = 2,
        .x2 = 3,
        .y2 = 4,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    } });
    const item = DisplayItem{ .cached_subtree = .{
        .list = &retained,
    } };

    const copy = try cloneItem(std.testing.allocator, item);
    var owned = [1]DisplayItem{copy};
    defer DisplayItem.freeItems(std.testing.allocator, owned[0..]);
    try std.testing.expect(copy == .transform);
    try std.testing.expectEqual(@as(i32, 3), copy.transform.children[0].rect.x2);
}
