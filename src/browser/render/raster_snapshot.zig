//! Owned display-list generations that may safely cross to the raster worker.

const std = @import("std");
const display = @import("display_list.zig");

const DisplayItem = display.DisplayItem;

/// Structural containers, blend strings, glyph bitmaps, and image pixels are
/// independently owned. DOM/layout provenance and layer pointers never cross
/// the worker boundary.
pub const RasterSnapshot = struct {
    const CloneError = std.mem.Allocator.Error ||
        error{CompositedLayerCannotCrossRasterBoundary};

    allocator: std.mem.Allocator,
    items: []DisplayItem,
    pixel_buffers: std.ArrayList([]u8) = .empty,

    pub fn clone(
        allocator: std.mem.Allocator,
        items: []const DisplayItem,
    ) CloneError!RasterSnapshot {
        var snapshot = RasterSnapshot{
            .allocator = allocator,
            .items = &.{},
        };
        errdefer snapshot.deinit();
        snapshot.items = try snapshot.cloneList(items);
        return snapshot;
    }

    fn clonePixelBuffer(
        self: *RasterSnapshot,
        source: []const u8,
    ) CloneError![]u8 {
        const copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(copy);
        try self.pixel_buffers.append(self.allocator, copy);
        return copy;
    }

    fn cloneList(
        self: *RasterSnapshot,
        items: []const DisplayItem,
    ) CloneError![]DisplayItem {
        const copy = try self.allocator.alloc(DisplayItem, items.len);
        var initialized: usize = 0;
        errdefer {
            DisplayItem.freeItems(self.allocator, copy[0..initialized]);
            self.allocator.free(copy);
        }
        for (items, 0..) |item, index| {
            copy[index] = try self.cloneItem(item);
            initialized = index + 1;
        }
        return copy;
    }

    fn cloneItem(
        self: *RasterSnapshot,
        item: DisplayItem,
    ) CloneError!DisplayItem {
        return switch (item) {
            .cached_subtree => |cached| .{ .transform = .{
                .translate_x = 0,
                .translate_y = 0,
                .children = try self.cloneList(cached.list.items),
                .source = null,
            } },
            .glyph => |glyph_item| blk: {
                var copy = glyph_item;
                copy.source = null;
                if (glyph_item.glyph.pixels) |pixels| {
                    copy.glyph.pixels = try self.clonePixelBuffer(pixels);
                }
                break :blk .{ .glyph = copy };
            },
            .image => |image_item| blk: {
                var copy = image_item;
                copy.source = null;
                copy.pixels = try self.clonePixelBuffer(image_item.pixels);
                break :blk .{ .image = copy };
            },
            .canvas => |canvas_item| blk: {
                var copy = canvas_item;
                copy.source = null;
                copy.pixels = try self.allocator.dupe(u8, canvas_item.pixels);
                copy.owns_pixels = true;
                break :blk .{ .canvas = copy };
            },
            .blend => |blend_item| blk: {
                const children = try self.cloneList(blend_item.children);
                errdefer DisplayItem.freeList(self.allocator, children);
                const mode_copy = if (blend_item.blend_mode) |mode|
                    try self.allocator.dupe(u8, mode)
                else
                    null;
                break :blk .{ .blend = .{
                    .opacity = blend_item.opacity,
                    .blend_mode = mode_copy,
                    .blur_radius = blend_item.blur_radius,
                    .hit_clip = blend_item.hit_clip,
                    .children = children,
                    .node = null,
                    .parent = null,
                    .needs_compositing = blend_item.needs_compositing,
                    .compositor_id = blend_item.compositor_id,
                    .source = null,
                } };
            },
            .transform => |transform_item| .{ .transform = .{
                .translate_x = transform_item.translate_x,
                .translate_y = transform_item.translate_y,
                .children = try self.cloneList(transform_item.children),
                .node = null,
                .composited = transform_item.composited,
                .animation_active = transform_item.animation_active,
                .compositor_id = transform_item.compositor_id,
                .source = null,
            } },
            .draw_composited_layer => error.CompositedLayerCannotCrossRasterBoundary,
            .rect => |payload| clearSource(.rect, payload),
            .iframe => |payload| clearSource(.iframe, payload),
            .rounded_rect => |payload| clearSource(.rounded_rect, payload),
            .line => |payload| clearSource(.line, payload),
            .outline => |payload| clearSource(.outline, payload),
        };
    }

    fn clearSource(comptime tag: std.meta.Tag(DisplayItem), payload: anytype) DisplayItem {
        var copy = payload;
        copy.source = null;
        return @unionInit(DisplayItem, @tagName(tag), copy);
    }

    pub fn deinit(self: *RasterSnapshot) void {
        if (self.items.len > 0) DisplayItem.freeList(self.allocator, self.items);
        self.items = &.{};
        for (self.pixel_buffers.items) |pixels| self.allocator.free(pixels);
        self.pixel_buffers.deinit(self.allocator);
    }
};

/// A one-child dst_in command is a list-level mask for already-painted
/// siblings. Every other compositing boundary gets an isolated surface.
pub fn blendNeedsIsolation(
    needs_compositing: bool,
    blend_mode: ?[]const u8,
    child_count: usize,
) bool {
    if (!needs_compositing) return false;
    if (blend_mode) |mode| {
        if (std.mem.eql(u8, mode, "dst_in") and child_count == 1) return false;
    }
    return true;
}
