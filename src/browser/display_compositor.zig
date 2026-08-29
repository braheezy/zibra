//! Owns retained composited layers and their independently owned draw list.
//!
//! `Compositor` deep-copies owning display commands when it separates paint
//! strata. Its layer pointers remain valid only until the next `rebuild` or
//! `deinit`; callers must retire every draw-list borrower first.

const std = @import("std");

const display_commands = @import("render/display_list.zig");
const effects = @import("render/effects.zig");

const blurKernelRadius = effects.blurKernelRadius;
const CompositedLayer = display_commands.CompositedLayer;
const DisplayItem = display_commands.DisplayItem;
const Rect = display_commands.Rect;

pub const Compositor = struct {
    allocator: std.mem.Allocator,
    layers: std.ArrayList(CompositedLayer) = .empty,
    draw_list: std.ArrayList(DisplayItem) = .empty,

    pub fn init(allocator: std.mem.Allocator) Compositor {
        return .{ .allocator = allocator };
    }

    fn clearDrawList(self: *Compositor) void {
        if (self.draw_list.items.len == 0) return;
        DisplayItem.freeItems(self.allocator, self.draw_list.items);
        self.draw_list.items.len = 0;
    }

    /// Retire draw-list borrowers before destroying the layers they reference.
    pub fn clear(self: *Compositor) void {
        self.clearDrawList();
        for (self.layers.items) |*layer| layer.deinit(self.allocator);
        self.layers.items.len = 0;
    }

    fn scalePxWithZoom(_: *const Compositor, value: i32, zoom: f32) i32 {
        const scaled = @as(f64, @floatFromInt(value)) * @as(f64, zoom);
        return @intFromFloat(@round(scaled));
    }

    /// Build composited layers from the display list
    /// Returns true if layers were rebuilt, false if using cached layers
    pub fn rebuild(self: *Compositor, display_list: ?[]DisplayItem, zoom: f32) !bool {
        if (display_list == null) return false;

        // Draw commands contain raw layer pointers, so they must retire before
        // any layer allocation can be destroyed or moved.
        self.clearDrawList();
        for (self.layers.items) |*layer| {
            layer.deinit(self.allocator);
        }
        self.layers.items.len = 0;

        // Walk the display list and create layers for blend items
        for (display_list.?) |item| {
            try self.compositeItem(item, zoom);
        }

        // Log layer count for optimization verification
        std.log.debug("Compositing complete: {} layers created", .{self.layers.items.len});

        return true;
    }

    /// Recursively process a display item for compositing
    fn compositeItem(self: *Compositor, item: DisplayItem, zoom: f32) !void {
        switch (item) {
            .blend => |blend_item| {
                // Use the pre-computed needs_compositing flag
                const needs_layer = blend_item.needs_compositing;

                if (needs_layer) {
                    const is_dst_in = if (blend_item.blend_mode) |mode|
                        std.mem.eql(u8, mode, "dst_in")
                    else
                        false;

                    if (is_dst_in) {
                        const cloned = try self.cloneDisplayItem(item);
                        var cloned_owned = true;
                        errdefer if (cloned_owned) {
                            var cloned_items = [_]DisplayItem{cloned};
                            DisplayItem.freeItems(self.allocator, &cloned_items);
                        };

                        const layer_items = try self.allocator.alloc(DisplayItem, 1);
                        layer_items[0] = cloned;
                        cloned_owned = false;

                        const bounds = self.getDisplayItemBounds(item, zoom);
                        const layer_blend_mode = if (cloned == .blend) cloned.blend.blend_mode else blend_item.blend_mode;

                        var layer = CompositedLayer.init(
                            layer_items,
                            bounds,
                            blend_item.opacity,
                            layer_blend_mode,
                            blend_item.node,
                        );
                        var layer_owned = true;
                        errdefer if (layer_owned) layer.deinit(self.allocator);
                        try self.layers.append(self.allocator, layer);
                        layer_owned = false;
                        return;
                    }

                    // Flatten the subtree to collect all non-composited items
                    var flattened = std.ArrayList(DisplayItem).empty;
                    defer flattened.deinit(self.allocator);
                    errdefer DisplayItem.freeItems(self.allocator, flattened.items);
                    try self.flattenSubtree(blend_item.children, &flattened);

                    // flattenSubtree deep-copies every owning command, so the
                    // resulting slice can move directly into the layer.
                    const flattened_items = try flattened.toOwnedSlice(self.allocator);
                    var flattened_items_owned = true;
                    errdefer if (flattened_items_owned) DisplayItem.freeList(self.allocator, flattened_items);

                    // Calculate bounds from flattened children
                    var bounds = Rect{ .left = std.math.maxInt(i32), .top = std.math.maxInt(i32), .right = std.math.minInt(i32), .bottom = std.math.minInt(i32) };
                    for (flattened_items) |child| {
                        const child_bounds = self.getDisplayItemBounds(child, zoom);
                        bounds.left = @min(bounds.left, child_bounds.left);
                        bounds.top = @min(bounds.top, child_bounds.top);
                        bounds.right = @max(bounds.right, child_bounds.right);
                        bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
                    }

                    // Keep one layer per effect wrapper. Effect subtrees are
                    // ordered groups (filter, then clip, then opacity/blend),
                    // and merging neighboring groups would let a dst_in mask
                    // or blur consume pixels belonging to another element.
                    var layer = CompositedLayer.init(
                        flattened_items,
                        bounds,
                        blend_item.opacity,
                        blend_item.blend_mode,
                        blend_item.node,
                    );
                    flattened_items_owned = false;
                    var layer_owned = true;
                    errdefer if (layer_owned) layer.deinit(self.allocator);
                    try self.layers.append(self.allocator, layer);
                    layer_owned = false;
                } else {
                    // No layer needed, recurse into children
                    for (blend_item.children) |child| {
                        try self.compositeItem(child, zoom);
                    }
                }
            },
            .transform => |transform_item| {
                // Recurse into transform children - they may contain composited blends
                for (transform_item.children) |child| {
                    try self.compositeItem(child, zoom);
                }
            },
            else => {
                // Primitive items don't need compositing decisions
            },
        }
    }

    const CloneError = error{OutOfMemory};

    fn cloneDisplayItem(self: *Compositor, item: DisplayItem) CloneError!DisplayItem {
        switch (item) {
            .canvas => |canvas_item| {
                var copy = canvas_item;
                copy.pixels = try self.allocator.dupe(u8, canvas_item.pixels);
                copy.owns_pixels = true;
                return .{ .canvas = copy };
            },
            .blend => |blend_item| {
                const children = try self.cloneDisplayItemList(blend_item.children);
                errdefer DisplayItem.freeList(self.allocator, children);
                const mode_copy = if (blend_item.blend_mode) |mode| blk: {
                    const dup = try self.allocator.alloc(u8, mode.len);
                    @memcpy(dup, mode);
                    break :blk dup;
                } else null;
                return .{
                    .blend = .{
                        .opacity = blend_item.opacity,
                        .blend_mode = mode_copy,
                        .blur_radius = blend_item.blur_radius,
                        .hit_clip = blend_item.hit_clip,
                        .children = children,
                        .node = blend_item.node,
                        .parent = null,
                        .needs_compositing = blend_item.needs_compositing,
                        .compositor_id = blend_item.compositor_id,
                        .source = blend_item.source,
                    },
                };
            },
            .transform => |transform_item| {
                const children = try self.cloneDisplayItemList(transform_item.children);
                return .{
                    .transform = .{
                        .translate_x = transform_item.translate_x,
                        .translate_y = transform_item.translate_y,
                        .children = children,
                        .node = transform_item.node,
                        .composited = transform_item.composited,
                        .animation_active = transform_item.animation_active,
                        .compositor_id = transform_item.compositor_id,
                        .source = transform_item.source,
                    },
                };
            },
            else => return item,
        }
    }

    pub fn cloneDisplayItemList(self: *Compositor, items: []DisplayItem) CloneError![]DisplayItem {
        const copy = try self.allocator.alloc(DisplayItem, items.len);
        var filled: usize = 0;
        errdefer {
            if (filled > 0) {
                DisplayItem.freeItems(self.allocator, copy[0..filled]);
            }
            self.allocator.free(copy);
        }
        for (items, 0..) |item, idx| {
            copy[idx] = try self.cloneDisplayItem(item);
            filled = idx + 1;
        }
        return copy;
    }

    /// Flatten a subtree of display items by recursively expanding non-composited blends.
    /// This collects primitives into an independently owned list for efficient
    /// rasterization. Owning commands are cloned so failure cleanup never
    /// aliases the browser's committed display list.
    fn flattenSubtree(self: *Compositor, items: []DisplayItem, result: *std.ArrayList(DisplayItem)) !void {
        for (items) |item| {
            switch (item) {
                .blend => |blend_item| {
                    if (blend_item.needs_compositing) {
                        // Composited blends stay as-is (they'll create their own layer)
                        const cloned = try self.cloneDisplayItem(item);
                        var cloned_owned = true;
                        errdefer if (cloned_owned) {
                            var cloned_items = [_]DisplayItem{cloned};
                            DisplayItem.freeItems(self.allocator, &cloned_items);
                        };
                        try result.append(self.allocator, cloned);
                        cloned_owned = false;
                    } else {
                        // Non-composited blends are flattened - recurse into children
                        try self.flattenSubtree(blend_item.children, result);
                    }
                },
                .transform => |transform_item| {
                    // Transforms need to be preserved to apply translation during rendering
                    // Recursively flatten children but wrap them in the transform
                    var flattened_children = std.ArrayList(DisplayItem).empty;
                    defer flattened_children.deinit(self.allocator);
                    errdefer DisplayItem.freeItems(self.allocator, flattened_children.items);
                    try self.flattenSubtree(transform_item.children, &flattened_children);

                    if (flattened_children.items.len > 0) {
                        // Move the independently owned children into the new
                        // transform and guard that move until append succeeds.
                        const children_copy = try flattened_children.toOwnedSlice(self.allocator);
                        var children_owned = true;
                        errdefer if (children_owned) DisplayItem.freeList(self.allocator, children_copy);
                        try result.append(self.allocator, .{
                            .transform = .{
                                .translate_x = transform_item.translate_x,
                                .translate_y = transform_item.translate_y,
                                .children = children_copy,
                                .node = transform_item.node,
                                .composited = transform_item.composited,
                                .animation_active = transform_item.animation_active,
                                .compositor_id = transform_item.compositor_id,
                                .source = transform_item.source,
                            },
                        });
                        children_owned = false;
                    }
                },
                else => {
                    // Mutable-canvas snapshots own their bytes; all other
                    // primitive payloads borrow immutable resource data.
                    const primitive = try self.cloneDisplayItem(item);
                    var primitive_owned = true;
                    errdefer if (primitive_owned) {
                        var primitive_items = [_]DisplayItem{primitive};
                        DisplayItem.freeItems(self.allocator, &primitive_items);
                    };
                    try result.append(self.allocator, primitive);
                    primitive_owned = false;
                },
            }
        }
    }

    pub fn displayItemsBounds(self: *const Compositor, items: []const DisplayItem, zoom: f32) ?Rect {
        if (items.len == 0) return null;
        var bounds = self.getDisplayItemBounds(items[0], zoom);
        for (items[1..]) |child| {
            const child_bounds = self.getDisplayItemBounds(child, zoom);
            bounds.left = @min(bounds.left, child_bounds.left);
            bounds.top = @min(bounds.top, child_bounds.top);
            bounds.right = @max(bounds.right, child_bounds.right);
            bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
        }
        return bounds;
    }

    fn blurOutset(self: *const Compositor, radius: f64, zoom: f32) i32 {
        _ = self;
        return @intCast(blurKernelRadius(radius * @as(f64, zoom)));
    }

    /// Get the bounding rect of a display item in device/document coordinates.
    pub fn getDisplayItemBounds(self: *const Compositor, item: DisplayItem, zoom: f32) Rect {
        return switch (item) {
            .cached_subtree => |cached| self.displayItemsBounds(cached.list.items, zoom) orelse .{
                .left = 0,
                .top = 0,
                .right = 0,
                .bottom = 0,
            },
            .glyph => |g| Rect{
                .left = self.scalePxWithZoom(g.x, zoom),
                .top = self.scalePxWithZoom(g.y, zoom),
                .right = self.scalePxWithZoom(g.x, zoom) + DisplayItem.scaleRasterPx(
                    g.glyph.w,
                    g.page_zoom,
                    zoom,
                ),
                .bottom = self.scalePxWithZoom(g.y, zoom) + DisplayItem.scaleRasterPx(
                    g.glyph.h,
                    g.page_zoom,
                    zoom,
                ),
            },
            .rect => |r| Rect{
                .left = self.scalePxWithZoom(r.x1, zoom),
                .top = self.scalePxWithZoom(r.y1, zoom),
                .right = self.scalePxWithZoom(r.x2, zoom),
                .bottom = self.scalePxWithZoom(r.y2, zoom),
            },
            .image => |img| Rect{
                .left = self.scalePxWithZoom(img.x1, zoom),
                .top = self.scalePxWithZoom(img.y1, zoom),
                .right = self.scalePxWithZoom(img.x2, zoom),
                .bottom = self.scalePxWithZoom(img.y2, zoom),
            },
            .canvas => |canvas| Rect{
                .left = self.scalePxWithZoom(canvas.x1, zoom),
                .top = self.scalePxWithZoom(canvas.y1, zoom),
                .right = self.scalePxWithZoom(canvas.x2, zoom),
                .bottom = self.scalePxWithZoom(canvas.y2, zoom),
            },
            .iframe => |iframe_item| Rect{
                .left = self.scalePxWithZoom(iframe_item.rect.left, zoom),
                .top = self.scalePxWithZoom(iframe_item.rect.top, zoom),
                .right = self.scalePxWithZoom(iframe_item.rect.right, zoom),
                .bottom = self.scalePxWithZoom(iframe_item.rect.bottom, zoom),
            },
            .rounded_rect => |r| Rect{
                .left = self.scalePxWithZoom(r.x1, zoom),
                .top = self.scalePxWithZoom(r.y1, zoom),
                .right = self.scalePxWithZoom(r.x2, zoom),
                .bottom = self.scalePxWithZoom(r.y2, zoom),
            },
            .line => |l| Rect{
                .left = self.scalePxWithZoom(@min(l.x1, l.x2), zoom),
                .top = self.scalePxWithZoom(@min(l.y1, l.y2), zoom),
                .right = self.scalePxWithZoom(@max(l.x1, l.x2), zoom) + self.scalePxWithZoom(l.thickness, zoom),
                .bottom = self.scalePxWithZoom(@max(l.y1, l.y2), zoom) + self.scalePxWithZoom(l.thickness, zoom),
            },
            .outline => |o| Rect{
                .left = self.scalePxWithZoom(o.rect.left, zoom),
                .top = self.scalePxWithZoom(o.rect.top, zoom),
                .right = self.scalePxWithZoom(o.rect.right, zoom),
                .bottom = self.scalePxWithZoom(o.rect.bottom, zoom),
            },
            .blend => |b| blk: {
                if (b.blend_mode) |mode| {
                    if (std.mem.eql(u8, mode, "dst_in") and b.children.len > 0) {
                        const mask_child = b.children[b.children.len - 1];
                        break :blk self.getDisplayItemBounds(mask_child, zoom);
                    }
                }
                var bounds = self.displayItemsBounds(b.children, zoom) orelse Rect{
                    .left = 0,
                    .top = 0,
                    .right = 0,
                    .bottom = 0,
                };
                if (b.blur_radius > 0.0) bounds = bounds.outset(self.blurOutset(b.blur_radius, zoom));
                break :blk bounds;
            },
            .draw_composited_layer => |dcl| dcl.layer.bounds,
            .transform => |t| blk: {
                // Get children bounds and apply translation offset
                var bounds = Rect{ .left = std.math.maxInt(i32), .top = std.math.maxInt(i32), .right = std.math.minInt(i32), .bottom = std.math.minInt(i32) };
                for (t.children) |child| {
                    const child_bounds = self.getDisplayItemBounds(child, zoom);
                    bounds.left = @min(bounds.left, child_bounds.left);
                    bounds.top = @min(bounds.top, child_bounds.top);
                    bounds.right = @max(bounds.right, child_bounds.right);
                    bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
                }
                // Apply translation to get absolute bounds
                break :blk Rect{
                    .left = bounds.left + self.scalePxWithZoom(t.translate_x, zoom),
                    .top = bounds.top + self.scalePxWithZoom(t.translate_y, zoom),
                    .right = bounds.right + self.scalePxWithZoom(t.translate_x, zoom),
                    .bottom = bounds.bottom + self.scalePxWithZoom(t.translate_y, zoom),
                };
            },
        };
    }

    /// Build a draw list from composited layers
    pub fn rebuildDrawList(self: *Compositor, display_list: ?[]DisplayItem) !void {
        self.clearDrawList();

        if (display_list == null) return;

        // Walk the display list and emit draw commands
        var layer_index: usize = 0;
        for (display_list.?) |item| {
            try self.paintItem(item, &layer_index);
        }
    }

    /// Recursively emit draw commands for an item
    fn paintItem(self: *Compositor, item: DisplayItem, layer_index: *usize) !void {
        switch (item) {
            .blend => |blend_item| {
                // Use the pre-computed needs_compositing flag
                if (blend_item.needs_compositing) {
                    // Emit a DrawCompositedLayer pointing to the corresponding layer
                    if (layer_index.* < self.layers.items.len) {
                        try self.draw_list.append(self.allocator, .{
                            .draw_composited_layer = .{
                                .layer = &self.layers.items[layer_index.*],
                            },
                        });
                        layer_index.* += 1;
                    }
                } else {
                    // No layer, emit children directly
                    for (blend_item.children) |child| {
                        try self.paintItem(child, layer_index);
                    }
                }
            },
            .transform => |transform_item| {
                // Transforms preserve their structure but recurse for composited content
                // We need to collect children and emit a transform wrapping them
                // Save original draw list length
                const original_len = self.draw_list.items.len;

                // Recurse into children
                for (transform_item.children) |child| {
                    try self.paintItem(child, layer_index);
                }

                // Collect newly added items
                if (self.draw_list.items.len > original_len) {
                    const new_items = self.draw_list.items[original_len..];
                    const children_copy = try self.allocator.alloc(DisplayItem, new_items.len);
                    @memcpy(children_copy, new_items);

                    // Remove the newly added items
                    self.draw_list.items.len = original_len;
                    var children_owned = true;
                    errdefer if (children_owned) DisplayItem.freeList(self.allocator, children_copy);

                    // Emit transform wrapping those items
                    try self.draw_list.append(self.allocator, .{
                        .transform = .{
                            .translate_x = transform_item.translate_x,
                            .translate_y = transform_item.translate_y,
                            .children = children_copy,
                            .node = transform_item.node,
                            .composited = transform_item.composited,
                            .animation_active = transform_item.animation_active,
                            .compositor_id = transform_item.compositor_id,
                            .source = transform_item.source,
                        },
                    });
                    children_owned = false;
                }
            },
            else => {
                // Primitive items go directly to the draw list
                const primitive = try self.cloneDisplayItem(item);
                var primitive_owned = true;
                errdefer if (primitive_owned) {
                    var primitive_items = [_]DisplayItem{primitive};
                    DisplayItem.freeItems(self.allocator, &primitive_items);
                };
                try self.draw_list.append(self.allocator, primitive);
                primitive_owned = false;
            },
        }
    }

    /// Retire draw-list containers before layers because draw commands borrow
    /// their stable layer addresses.
    pub fn deinit(self: *Compositor) void {
        self.clear();
        self.draw_list.deinit(self.allocator);
        self.layers.deinit(self.allocator);
        self.* = undefined;
    }
};

test "compositor owns layer commands and retires draw borrowers first" {
    const allocator = std.testing.allocator;
    var compositor = Compositor.init(allocator);
    defer compositor.deinit();

    var children = [_]DisplayItem{.{ .rect = .{
        .x1 = 1,
        .y1 = 2,
        .x2 = 11,
        .y2 = 12,
        .color = .{ .r = 1, .g = 2, .b = 3 },
    } }};
    var source = [_]DisplayItem{.{ .blend = .{
        .opacity = 0.5,
        .blend_mode = null,
        .children = &children,
        .needs_compositing = true,
    } }};

    try std.testing.expect(try compositor.rebuild(&source, 2.0));
    try std.testing.expectEqual(@as(usize, 1), compositor.layers.items.len);
    try std.testing.expectEqual(
        Rect{ .left = 1, .top = 3, .right = 23, .bottom = 25 },
        compositor.layers.items[0].bounds,
    );
    try std.testing.expectEqual(@as(usize, 1), compositor.layers.items[0].display_items.len);

    try compositor.rebuildDrawList(&source);
    try std.testing.expectEqual(@as(usize, 1), compositor.draw_list.items.len);
    try std.testing.expect(
        compositor.draw_list.items[0].draw_composited_layer.layer ==
            &compositor.layers.items[0],
    );

    compositor.clear();
    try std.testing.expectEqual(@as(usize, 0), compositor.draw_list.items.len);
    try std.testing.expectEqual(@as(usize, 0), compositor.layers.items.len);
}
