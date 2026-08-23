//! Display commands shared by layout, hit testing, compositing, and raster.
//!
//! This module owns command-tree structure and cleanup but deliberately knows
//! nothing about `Browser`, SDL, or native-window state. Browser-side raster
//! operations consume these values from `root.zig`.

const std = @import("std");
const z2d = @import("z2d");

const Glyph = @import("font.zig").Glyph;
const Node = @import("../../document/parser.zig").Node;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn toZ2dRgba(self: Color) z2d.pixel.RGBA {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn containsPoint(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }

    pub fn width(self: Rect) i32 {
        if (self.right <= self.left) return 0;
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        if (self.bottom <= self.top) return 0;
        return self.bottom - self.top;
    }

    pub fn outset(self: Rect, amount: i32) Rect {
        return .{
            .left = self.left - amount,
            .top = self.top - amount,
            .right = self.right + amount,
            .bottom = self.bottom + amount,
        };
    }

    pub fn inset(self: Rect, amount: i32) Rect {
        return .{
            .left = self.left + amount,
            .top = self.top + amount,
            .right = self.right - amount,
            .bottom = self.bottom - amount,
        };
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.left < other.right and other.left < self.right and
            self.top < other.bottom and other.top < self.bottom;
    }

    pub fn unionWith(self: Rect, other: Rect) Rect {
        return .{
            .left = @min(self.left, other.left),
            .top = @min(self.top, other.top),
            .right = @max(self.right, other.right),
            .bottom = @max(self.bottom, other.bottom),
        };
    }

    pub fn intersection(self: Rect, other: Rect) ?Rect {
        const result = Rect{
            .left = @max(self.left, other.left),
            .top = @max(self.top, other.top),
            .right = @min(self.right, other.right),
            .bottom = @min(self.bottom, other.bottom),
        };
        return if (result.width() > 0 and result.height() > 0) result else null;
    }

    pub fn translated(self: Rect, x: i32, y: i32) Rect {
        return .{
            .left = self.left + x,
            .top = self.top + y,
            .right = self.right + x,
            .bottom = self.bottom + y,
        };
    }
};

/// A composited layer owns the display items and optional cached surface used
/// for one effect group. Raster execution remains a Browser responsibility.
pub const CompositedLayer = struct {
    display_items: []DisplayItem,
    surface: ?z2d.Surface = null,
    bounds: Rect,
    needs_raster: bool = true,
    opacity: f64 = 1.0,
    blend_mode: ?[]const u8 = null,
    node: ?*anyopaque = null,

    pub fn init(
        display_items: []DisplayItem,
        bounds: Rect,
        opacity: f64,
        blend_mode: ?[]const u8,
        node: ?*anyopaque,
    ) CompositedLayer {
        return .{
            .display_items = display_items,
            .bounds = bounds.outset(1),
            .opacity = opacity,
            .blend_mode = blend_mode,
            .node = node,
        };
    }

    pub fn deinit(self: *CompositedLayer, allocator: std.mem.Allocator) void {
        if (self.surface) |*surface| {
            surface.deinit(allocator);
            self.surface = null;
        }
        if (self.display_items.len > 0) {
            DisplayItem.freeList(allocator, self.display_items);
            self.display_items = &.{};
        }
    }

    /// Returns whether nested pixels, rather than only layer alpha, changed.
    pub fn applyCompositedOpacity(
        self: *CompositedLayer,
        node: *anyopaque,
        opacity: f64,
    ) bool {
        if (self.node == node) {
            self.opacity = opacity;
            return false;
        }
        if (DisplayItem.applyCompositedOpacity(self.display_items, node, opacity)) {
            self.needs_raster = true;
            return true;
        }
        return false;
    }

    pub fn canMerge(
        self: *const CompositedLayer,
        other_opacity: f64,
        other_blend_mode: ?[]const u8,
    ) bool {
        if (self.opacity != other_opacity) return false;
        if (self.blend_mode) |mode| {
            if (std.mem.eql(u8, mode, "dst_in")) return false;
        }
        if (self.blend_mode == null and other_blend_mode == null) return true;
        if (self.blend_mode == null or other_blend_mode == null) return false;
        return std.mem.eql(u8, self.blend_mode.?, other_blend_mode.?);
    }

    pub fn add(
        self: *CompositedLayer,
        allocator: std.mem.Allocator,
        items: []DisplayItem,
        item_bounds: Rect,
    ) !void {
        const inner_bounds = self.bounds.inset(1);
        const new_bounds = Rect{
            .left = @min(inner_bounds.left, item_bounds.left),
            .top = @min(inner_bounds.top, item_bounds.top),
            .right = @max(inner_bounds.right, item_bounds.right),
            .bottom = @max(inner_bounds.bottom, item_bounds.bottom),
        };

        const old_items = self.display_items;
        const new_items = try allocator.alloc(DisplayItem, old_items.len + items.len);
        @memcpy(new_items[0..old_items.len], old_items);
        @memcpy(new_items[old_items.len..], items);

        self.display_items = new_items;
        self.bounds = new_bounds.outset(1);
        if (old_items.len > 0) allocator.free(old_items);
        if (items.len > 0) allocator.free(items);
        self.needs_raster = true;
    }
};

pub const ImageDisplayItem = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    source_width: i32,
    source_height: i32,
    pixels: []const u8,
    opacity: f64 = 1.0,
    source: ?DisplayItemSource = null,
};

/// Synchronous-only provenance for an uncomposed frame display item.
pub const DisplayItemSource = struct {
    layout: *const anyopaque,
    node: ?*Node,
    layout_node_resolver: ?*const fn (*const anyopaque, ?*Node) ?*Node = null,

    pub fn originatingNode(self: DisplayItemSource) ?*Node {
        return if (self.layout_node_resolver) |resolve|
            resolve(self.layout, self.node)
        else
            self.node;
    }
};

pub const RoundedHitClip = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    radius: f64,
};

pub const DisplayItem = union(enum) {
    glyph: struct {
        x: i32,
        y: i32,
        glyph: Glyph,
        color: Color,
        source: ?DisplayItemSource = null,
    },
    rect: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        color: Color,
        source: ?DisplayItemSource = null,
    },
    image: ImageDisplayItem,
    iframe: struct {
        rect: Rect,
        node: *Node,
        source: ?DisplayItemSource = null,
    },
    rounded_rect: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        radius: f64,
        color: Color,
        source: ?DisplayItemSource = null,
    },
    line: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        color: Color,
        thickness: i32,
        source: ?DisplayItemSource = null,
    },
    outline: struct {
        rect: Rect,
        color: Color,
        thickness: i32,
        source: ?DisplayItemSource = null,
    },
    blend: struct {
        opacity: f64,
        blend_mode: ?[]const u8,
        blur_radius: f64 = 0.0,
        hit_clip: ?RoundedHitClip = null,
        children: []DisplayItem,
        node: ?*anyopaque = null,
        parent: ?*const DisplayItem = null,
        needs_compositing: bool = false,
        compositor_id: ?usize = null,
        source: ?DisplayItemSource = null,
    },
    draw_composited_layer: struct {
        layer: *CompositedLayer,
        source: ?DisplayItemSource = null,
    },
    transform: struct {
        translate_x: i32,
        translate_y: i32,
        children: []DisplayItem,
        node: ?*anyopaque = null,
        composited: bool = false,
        /// Active transforms can move after overlap testing. They therefore
        /// establish a conservative paint-order barrier in the raster cache.
        animation_active: bool = false,
        compositor_id: ?usize = null,
        source: ?DisplayItemSource = null,
    },

    pub const HitResult = struct {
        item: *const DisplayItem,
        source: DisplayItemSource,
        x: i32,
        y: i32,
        device_x: i32,
        device_y: i32,
    };

    pub fn source(self: *const DisplayItem) ?DisplayItemSource {
        return switch (self.*) {
            inline else => |payload| payload.source,
        };
    }

    pub fn clearSources(items: []DisplayItem) void {
        for (items) |*item| {
            switch (item.*) {
                .blend => |*blend_item| {
                    blend_item.source = null;
                    clearSources(blend_item.children);
                },
                .transform => |*transform_item| {
                    transform_item.source = null;
                    clearSources(transform_item.children);
                },
                inline else => |*payload| payload.source = null,
            }
        }
    }

    pub fn applyCompositedOpacity(
        items: []DisplayItem,
        node: *anyopaque,
        opacity: f64,
    ) bool {
        var updated = false;
        for (items) |*item| {
            switch (item.*) {
                .blend => |*blend_item| {
                    if (blend_item.node == node) {
                        blend_item.opacity = opacity;
                        updated = true;
                    }
                    if (applyCompositedOpacity(blend_item.children, node, opacity)) updated = true;
                },
                .transform => |*transform_item| {
                    if (applyCompositedOpacity(transform_item.children, node, opacity)) updated = true;
                },
                else => {},
            }
        }
        return updated;
    }

    pub fn applyCompositedTransform(
        items: []DisplayItem,
        node: *anyopaque,
        translate_x: i32,
        translate_y: i32,
    ) bool {
        var updated = false;
        for (items) |*item| {
            switch (item.*) {
                .blend => |*blend_item| {
                    if (applyCompositedTransform(
                        blend_item.children,
                        node,
                        translate_x,
                        translate_y,
                    )) updated = true;
                },
                .transform => |*transform_item| {
                    if (transform_item.composited and transform_item.node == node) {
                        transform_item.translate_x = translate_x;
                        transform_item.translate_y = translate_y;
                        updated = true;
                    }
                    if (applyCompositedTransform(
                        transform_item.children,
                        node,
                        translate_x,
                        translate_y,
                    )) updated = true;
                },
                else => {},
            }
        }
        return updated;
    }

    pub fn scaleLayoutPx(value: i32, zoom_value: f32) i32 {
        const zoom = if (zoom_value > 0) zoom_value else 1.0;
        if (zoom == 1.0) return value;
        return @intFromFloat(@as(f32, @floatFromInt(value)) * zoom);
    }

    fn deviceToLayoutPx(value: i32, zoom_value: f32) i32 {
        const zoom = if (zoom_value > 0) zoom_value else 1.0;
        if (zoom == 1.0) return value;
        return @intFromFloat(@as(f32, @floatFromInt(value)) / zoom);
    }

    pub fn hitTest(
        items: []const DisplayItem,
        x: i32,
        y: i32,
        zoom_value: f32,
    ) ?HitResult {
        return hitTestDevice(
            items,
            scaleLayoutPx(x, zoom_value),
            scaleLayoutPx(y, zoom_value),
            zoom_value,
        );
    }

    pub fn hitTestDevice(
        items: []const DisplayItem,
        x: i32,
        y: i32,
        zoom_value: f32,
    ) ?HitResult {
        const zoom = if (zoom_value > 0) zoom_value else 1.0;
        return hitTestDeviceList(items, x, y, zoom);
    }

    fn hitTestDeviceList(
        items: []const DisplayItem,
        x: i32,
        y: i32,
        zoom: f32,
    ) ?HitResult {
        var index = items.len;
        while (index > 0) {
            index -= 1;
            const item = &items[index];
            switch (item.*) {
                .blend => |blend_item| {
                    if (blend_item.opacity <= 0) continue;
                    if (blend_item.hit_clip) |clip| {
                        if (!pointInRoundedRect(x, y, clip, zoom)) continue;
                    }
                    const is_dst_in = if (blend_item.blend_mode) |mode|
                        std.mem.eql(u8, mode, "dst_in")
                    else
                        false;
                    if (is_dst_in) {
                        if (blend_item.children.len == 1) {
                            if (!containsPaintedPoint(&blend_item.children[0], x, y, zoom)) return null;
                            continue;
                        }
                        if (blend_item.children.len < 2) continue;
                        const mask = &blend_item.children[blend_item.children.len - 1];
                        if (!containsPaintedPoint(mask, x, y, zoom)) continue;
                        if (hitTestDeviceList(
                            blend_item.children[0 .. blend_item.children.len - 1],
                            x,
                            y,
                            zoom,
                        )) |hit| return hit;
                        continue;
                    }
                    if (hitTestDeviceList(blend_item.children, x, y, zoom)) |hit| return hit;
                },
                .transform => |transform_item| {
                    const local_x = x - scaleLayoutPx(transform_item.translate_x, zoom);
                    const local_y = y - scaleLayoutPx(transform_item.translate_y, zoom);
                    if (hitTestDeviceList(transform_item.children, local_x, local_y, zoom)) |hit| return hit;
                },
                else => {
                    const item_source = item.source() orelse continue;
                    if (containsPrimitivePoint(item, x, y, zoom)) {
                        return .{
                            .item = item,
                            .source = item_source,
                            .x = deviceToLayoutPx(x, zoom),
                            .y = deviceToLayoutPx(y, zoom),
                            .device_x = x,
                            .device_y = y,
                        };
                    }
                },
            }
        }
        return null;
    }

    fn containsPaintedPoint(
        item: *const DisplayItem,
        x: i32,
        y: i32,
        zoom: f32,
    ) bool {
        return switch (item.*) {
            .blend => |blend_item| blk: {
                if (blend_item.opacity <= 0) break :blk false;
                if (blend_item.hit_clip) |clip| {
                    if (!pointInRoundedRect(x, y, clip, zoom)) break :blk false;
                }
                const is_dst_in = if (blend_item.blend_mode) |mode|
                    std.mem.eql(u8, mode, "dst_in")
                else
                    false;
                if (is_dst_in) {
                    if (blend_item.children.len == 1) {
                        break :blk containsPaintedPoint(&blend_item.children[0], x, y, zoom);
                    }
                    if (blend_item.children.len < 2) break :blk false;
                    const mask = &blend_item.children[blend_item.children.len - 1];
                    if (!containsPaintedPoint(mask, x, y, zoom)) break :blk false;
                    break :blk listContainsPaintedPoint(
                        blend_item.children[0 .. blend_item.children.len - 1],
                        x,
                        y,
                        zoom,
                    );
                }
                break :blk listContainsPaintedPoint(blend_item.children, x, y, zoom);
            },
            .transform => |transform_item| blk: {
                const local_x = x - scaleLayoutPx(transform_item.translate_x, zoom);
                const local_y = y - scaleLayoutPx(transform_item.translate_y, zoom);
                break :blk listContainsPaintedPoint(transform_item.children, local_x, local_y, zoom);
            },
            else => containsPrimitivePoint(item, x, y, zoom),
        };
    }

    fn listContainsPaintedPoint(
        items: []const DisplayItem,
        x: i32,
        y: i32,
        zoom: f32,
    ) bool {
        var index = items.len;
        while (index > 0) {
            index -= 1;
            const item = &items[index];
            if (item.* == .blend) {
                const blend_item = item.blend;
                const is_dst_in = if (blend_item.blend_mode) |mode|
                    std.mem.eql(u8, mode, "dst_in")
                else
                    false;
                if (is_dst_in and blend_item.children.len == 1) {
                    if (!containsPaintedPoint(&blend_item.children[0], x, y, zoom)) return false;
                    continue;
                }
            }
            if (containsPaintedPoint(item, x, y, zoom)) return true;
        }
        return false;
    }

    fn containsPrimitivePoint(
        item: *const DisplayItem,
        x: i32,
        y: i32,
        zoom: f32,
    ) bool {
        return switch (item.*) {
            .glyph => |glyph_item| glyph_item.color.a > 0 and pointInRect(
                x,
                y,
                scaleLayoutPx(glyph_item.x, zoom),
                scaleLayoutPx(glyph_item.y, zoom),
                scaleLayoutPx(glyph_item.x, zoom) + glyph_item.glyph.w,
                scaleLayoutPx(glyph_item.y, zoom) + glyph_item.glyph.h,
            ),
            .rect => |rect_item| rect_item.color.a > 0 and pointInScaledRect(
                x,
                y,
                rect_item.x1,
                rect_item.y1,
                rect_item.x2,
                rect_item.y2,
                zoom,
            ),
            .image => |image_item| image_item.opacity > 0 and pointInScaledRect(
                x,
                y,
                image_item.x1,
                image_item.y1,
                image_item.x2,
                image_item.y2,
                zoom,
            ),
            .iframe => |iframe_item| pointInScaledRect(
                x,
                y,
                iframe_item.rect.left,
                iframe_item.rect.top,
                iframe_item.rect.right,
                iframe_item.rect.bottom,
                zoom,
            ),
            .rounded_rect => |rounded_item| rounded_item.color.a > 0 and
                pointInRoundedRect(x, y, rounded_item, zoom),
            .line => |line_item| line_item.color.a > 0 and
                pointOnLine(x, y, line_item, zoom),
            .outline => |outline_item| outline_item.color.a > 0 and
                pointOnOutline(x, y, outline_item, zoom),
            .draw_composited_layer => |layer_item| pointInRect(
                x,
                y,
                layer_item.layer.bounds.left,
                layer_item.layer.bounds.top,
                layer_item.layer.bounds.right,
                layer_item.layer.bounds.bottom,
            ),
            .blend, .transform => false,
        };
    }

    fn pointInScaledRect(
        x: i32,
        y: i32,
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        zoom: f32,
    ) bool {
        return pointInRect(
            x,
            y,
            scaleLayoutPx(x1, zoom),
            scaleLayoutPx(y1, zoom),
            scaleLayoutPx(x2, zoom),
            scaleLayoutPx(y2, zoom),
        );
    }

    fn pointInRect(x: i32, y: i32, x1: i32, y1: i32, x2: i32, y2: i32) bool {
        const left = @min(x1, x2);
        const right = @max(x1, x2);
        const top = @min(y1, y2);
        const bottom = @max(y1, y2);
        return x >= left and x < right and y >= top and y < bottom;
    }

    fn pointInRoundedRect(x: i32, y: i32, item: anytype, zoom: f32) bool {
        const left = scaleLayoutPx(@min(item.x1, item.x2), zoom);
        const right = scaleLayoutPx(@max(item.x1, item.x2), zoom);
        const top = scaleLayoutPx(@min(item.y1, item.y2), zoom);
        const bottom = scaleLayoutPx(@max(item.y1, item.y2), zoom);
        if (!pointInRect(x, y, left, top, right, bottom)) return false;
        const width: f64 = @floatFromInt(right - left);
        const height: f64 = @floatFromInt(bottom - top);
        const radius = @min(item.radius * @as(f64, zoom), @min(width / 2.0, height / 2.0));
        if (radius <= 0.5) return true;
        const x_float: f64 = @floatFromInt(x);
        const y_float: f64 = @floatFromInt(y);
        const left_float: f64 = @floatFromInt(left);
        const right_float: f64 = @floatFromInt(right);
        const top_float: f64 = @floatFromInt(top);
        const bottom_float: f64 = @floatFromInt(bottom);
        const center_x = if (x_float < left_float + radius)
            left_float + radius
        else if (x_float >= right_float - radius)
            right_float - radius
        else
            x_float;
        const center_y = if (y_float < top_float + radius)
            top_float + radius
        else if (y_float >= bottom_float - radius)
            bottom_float - radius
        else
            y_float;
        const dx = x_float - center_x;
        const dy = y_float - center_y;
        return dx * dx + dy * dy <= radius * radius;
    }

    fn pointOnLine(x: i32, y: i32, item: anytype, zoom: f32) bool {
        const x1: f64 = @floatFromInt(scaleLayoutPx(item.x1, zoom));
        const y1: f64 = @floatFromInt(scaleLayoutPx(item.y1, zoom));
        const x2: f64 = @floatFromInt(scaleLayoutPx(item.x2, zoom));
        const y2: f64 = @floatFromInt(scaleLayoutPx(item.y2, zoom));
        const dx = x2 - x1;
        const dy = y2 - y1;
        const length_squared = dx * dx + dy * dy;
        const x_float: f64 = @floatFromInt(x);
        const y_float: f64 = @floatFromInt(y);
        const t = if (length_squared == 0)
            0.0
        else
            std.math.clamp(
                ((x_float - x1) * dx + (y_float - y1) * dy) / length_squared,
                0.0,
                1.0,
            );
        const nearest_x = x1 + t * dx;
        const nearest_y = y1 + t * dy;
        const half_width = @as(
            f64,
            @floatFromInt(@max(1, scaleLayoutPx(item.thickness, zoom))),
        ) / 2.0;
        const distance_x = x_float - nearest_x;
        const distance_y = y_float - nearest_y;
        return distance_x * distance_x + distance_y * distance_y <= half_width * half_width;
    }

    fn pointOnOutline(x: i32, y: i32, item: anytype, zoom: f32) bool {
        const left = scaleLayoutPx(@min(item.rect.left, item.rect.right), zoom);
        const right = scaleLayoutPx(@max(item.rect.left, item.rect.right), zoom);
        const top = scaleLayoutPx(@min(item.rect.top, item.rect.bottom), zoom);
        const bottom = scaleLayoutPx(@max(item.rect.top, item.rect.bottom), zoom);
        const thickness = @max(1, scaleLayoutPx(item.thickness, zoom));
        if (!pointInRect(
            x,
            y,
            left - thickness,
            top - thickness,
            right + thickness,
            bottom + thickness,
        )) return false;
        const inner_left = left + thickness;
        const inner_right = right - thickness;
        const inner_top = top + thickness;
        const inner_bottom = bottom - thickness;
        return inner_left >= inner_right or inner_top >= inner_bottom or
            !pointInRect(x, y, inner_left, inner_top, inner_right, inner_bottom);
    }

    pub fn setParentPointers(items: []DisplayItem, parent: ?*const DisplayItem) void {
        for (items) |*item| {
            switch (item.*) {
                .blend => |*blend_item| {
                    blend_item.parent = parent;
                    setParentPointers(blend_item.children, item);
                },
                else => {},
            }
        }
    }

    pub fn freeList(allocator: std.mem.Allocator, items: []DisplayItem) void {
        freeItems(allocator, items);
        allocator.free(items);
    }

    pub fn freeItems(allocator: std.mem.Allocator, items: []DisplayItem) void {
        for (items) |item| freeItem(allocator, item);
    }

    fn freeItem(allocator: std.mem.Allocator, item: DisplayItem) void {
        switch (item) {
            .blend => |blend_item| {
                if (blend_item.blend_mode) |mode| allocator.free(mode);
                freeList(allocator, blend_item.children);
            },
            .transform => |transform_item| freeList(allocator, transform_item.children),
            else => {},
        }
    }
};
