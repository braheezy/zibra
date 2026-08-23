//! Raster-worker-owned page planes for draw-only property updates.
//!
//! Each plane owns either immutable raster pixels or a tiny worker-safe display
//! list. Animation and scrolling mutate only scalar placement/alpha state;
//! tiny lists are replayed during draw while larger lists composite cached
//! pixels into the next root surface.

const std = @import("std");
const z2d = @import("z2d");
const compositor = z2d.compositor;
const display = @import("display_list.zig");
const RasterSnapshot = @import("raster_snapshot.zig").RasterSnapshot;

const Rect = display.Rect;
const DisplayItem = display.DisplayItem;

/// A merged RGBA plane may use at most four MiB of pixel storage. Individual
/// paint chunks can exceed this when unavoidable; the limit only prevents a
/// merge from manufacturing a large, mostly transparent bounding surface.
pub const maximum_merged_surface_area_pixels: u64 = 1024 * 1024;
pub const maximum_direct_paint_commands: usize = 3;

const DirectPaintInfo = struct {
    count: usize = 0,
    grouped_opacity: bool = false,
};

fn collectDirectPaintInfo(items: []const DisplayItem, info: *DirectPaintInfo) bool {
    for (items) |item| {
        switch (item) {
            .rect, .rounded_rect, .line, .outline => {
                info.count += 1;
                if (info.count > maximum_direct_paint_commands) return false;
            },
            .transform => |transform| {
                if (!collectDirectPaintInfo(transform.children, info)) return false;
            },
            .blend => |blend| {
                if (blend.blend_mode != null or blend.blur_radius > 0.0) return false;
                if (blend.opacity < 1.0 or blend.compositor_id != null) {
                    info.grouped_opacity = true;
                }
                if (!collectDirectPaintInfo(blend.children, info)) return false;
            },
            .glyph, .image, .iframe, .draw_composited_layer => return false,
        }
    }
    return true;
}

/// Tiny command trees are cheaper to replay than to retain as RGBA textures.
/// Text, images, masks, filters, and multi-command opacity groups stay
/// rasterized because their per-frame cost or group semantics are nontrivial.
pub fn canDrawDirectly(items: []const DisplayItem) bool {
    var info = DirectPaintInfo{};
    if (!collectDirectPaintInfo(items, &info)) return false;
    if (info.count == 0 or info.count > maximum_direct_paint_commands) return false;
    return !info.grouped_opacity or info.count == 1;
}

pub fn mergeFitsSurfaceArea(first: Rect, second: Rect) bool {
    const combined = first.unionWith(second);
    const width: u64 = @intCast(@max(
        @as(i64, combined.right) - @as(i64, combined.left),
        0,
    ));
    const height: u64 = @intCast(@max(
        @as(i64, combined.bottom) - @as(i64, combined.top),
        0,
    ));
    return width * height <= maximum_merged_surface_area_pixels;
}

pub const Update = struct {
    id: usize,
    value: union(enum) {
        opacity: f64,
        transform: struct { x: i32, y: i32 },
    },
};

pub const Plane = struct {
    /// Exactly one backing is installed in every live cache plane. Surfaces
    /// retain expensive raster results; tiny direct snapshots retain owned,
    /// pointer-free commands for replay during software draw.
    surface: ?z2d.Surface = null,
    direct_commands: ?RasterSnapshot = null,
    /// Surface placement. Static planes cover the interest region, while a
    /// dynamic plane is tightly cropped around its untransformed pixels.
    bounds: Rect,
    /// Tight bounds of pixels painted into this plane, before its scalar
    /// compositor translation. Static planes use this for overlap testing.
    paint_bounds: ?Rect = null,
    compositor_id: ?usize = null,
    opacity: f64 = 1.0,
    translate_x: i32 = 0,
    translate_y: i32 = 0,
    /// An active transform may enter another plane's current bounds later.
    /// No subsequently painted static content may move ahead of this plane.
    assume_overlap_after: bool = false,

    pub fn deinit(self: *Plane, allocator: std.mem.Allocator) void {
        if (self.surface) |*surface| surface.deinit(allocator);
        self.surface = null;
        if (self.direct_commands) |*commands| commands.deinit();
        self.direct_commands = null;
    }

    fn currentPaintBounds(self: *const Plane, zoom: f32) Rect {
        const pixels = self.paint_bounds orelse self.bounds;
        if (self.compositor_id == null) return pixels;
        return pixels.translated(
            display.DisplayItem.scaleLayoutPx(self.translate_x, zoom),
            display.DisplayItem.scaleLayoutPx(self.translate_y, zoom),
        );
    }
};

pub const Cache = struct {
    planes: std.ArrayList(Plane) = .empty,
    valid: bool = false,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.planes.deinit(allocator);
    }

    pub fn clear(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.planes.items) |*plane| plane.deinit(allocator);
        self.planes.items.len = 0;
        self.valid = false;
    }

    pub fn apply(self: *Cache, updates: []const Update) void {
        for (updates) |update| {
            for (self.planes.items) |*plane| {
                if (plane.compositor_id != update.id) continue;
                switch (update.value) {
                    .opacity => |opacity| plane.opacity = std.math.clamp(opacity, 0.0, 1.0),
                    .transform => |transform| {
                        plane.translate_x = transform.x;
                        plane.translate_y = transform.y;
                    },
                }
            }
        }
    }

    /// Find a static plane that `paint_bounds` can join without changing paint
    /// order or creating an excessively sparse surface. A static stratum may
    /// move ahead of intervening planes only when it cannot overlap them.
    /// Active transforms are permanent barriers because their future
    /// positions are not represented by their current bounds.
    pub fn staticMergeTarget(
        self: *const Cache,
        paint_bounds: Rect,
        zoom: f32,
    ) ?usize {
        var index = self.planes.items.len;
        while (index > 0) {
            index -= 1;
            const plane = &self.planes.items[index];
            if (plane.compositor_id == null) {
                const existing_bounds = plane.paint_bounds orelse plane.bounds;
                if (mergeFitsSurfaceArea(existing_bounds, paint_bounds)) return index;
                // A later chunk cannot cross overlapping pixels in a plane it
                // cannot join, or their relative paint order would reverse.
                if (existing_bounds.overlaps(paint_bounds)) return null;
                continue;
            }
            if (plane.assume_overlap_after or
                plane.currentPaintBounds(zoom).overlaps(paint_bounds))
            {
                return null;
            }
        }
        return null;
    }

    pub fn draw(
        self: *const Cache,
        destination: *z2d.Surface,
        chrome_bottom: i32,
        scroll_device: i32,
        zoom: f32,
    ) void {
        // Browser orchestration interleaves direct command replay with these
        // surface planes. This helper remains the surface-only path used by
        // low-level cache tests.
        if (!self.valid) return;
        for (self.planes.items) |*plane| {
            const surface = if (plane.surface) |*value| value else continue;
            const x = plane.bounds.left + display.DisplayItem.scaleLayoutPx(plane.translate_x, zoom);
            const y = chrome_bottom + plane.bounds.top - scroll_device +
                display.DisplayItem.scaleLayoutPx(plane.translate_y, zoom);
            compositeWithOpacity(destination, surface, x, y, plane.opacity);
        }
    }
};

pub fn compositeWithOpacity(
    destination: *z2d.Surface,
    source: *const z2d.Surface,
    x: i32,
    y: i32,
    opacity_value: f64,
) void {
    const opacity = std.math.clamp(opacity_value, 0.0, 1.0);
    if (opacity <= 0.0) return;
    if (opacity >= 1.0) {
        z2d.Surface.composite(destination, source, .src_over, x, y, .{});
        return;
    }

    const alpha: u8 = @intFromFloat(@round(opacity * 255.0));
    const mask = z2d.pixel.Pixel{ .rgba = .{
        .r = alpha,
        .g = alpha,
        .b = alpha,
        .a = alpha,
    } };
    compositor.SurfaceCompositor.run(destination, x, y, 2, .{
        .{
            .operator = .src_in,
            .src = .{ .surface = source },
            .dst = .{ .pixel = mask },
        },
        .{ .operator = .src_over },
    }, .{});
}

fn directTestRect(x: i32) DisplayItem {
    return .{ .rect = .{
        .x1 = x,
        .y1 = 0,
        .x2 = x + 10,
        .y2 = 10,
        .color = .{ .r = 20, .g = 40, .b = 60 },
    } };
}

test "short simple display lists bypass raster surfaces" {
    const one = [_]DisplayItem{directTestRect(0)};
    const three = [_]DisplayItem{
        directTestRect(0),
        directTestRect(10),
        directTestRect(20),
    };
    const four = [_]DisplayItem{
        directTestRect(0),
        directTestRect(10),
        directTestRect(20),
        directTestRect(30),
    };

    try std.testing.expect(canDrawDirectly(&one));
    try std.testing.expect(canDrawDirectly(&three));
    try std.testing.expect(!canDrawDirectly(&four));
    try std.testing.expect(!canDrawDirectly(&.{}));
}

test "direct display lists reject expensive commands and unsafe opacity groups" {
    var transformed_children = [_]DisplayItem{directTestRect(0)};
    const transformed = [_]DisplayItem{.{ .transform = .{
        .translate_x = 8,
        .translate_y = 4,
        .children = &transformed_children,
        .composited = true,
        .compositor_id = 9,
    } }};
    try std.testing.expect(canDrawDirectly(&transformed));

    var one_opacity_child = [_]DisplayItem{directTestRect(0)};
    const one_opacity_group = [_]DisplayItem{.{ .blend = .{
        .opacity = 0.5,
        .blend_mode = null,
        .children = &one_opacity_child,
        .needs_compositing = true,
        .compositor_id = 9,
    } }};
    try std.testing.expect(canDrawDirectly(&one_opacity_group));

    var two_opacity_children = [_]DisplayItem{ directTestRect(0), directTestRect(5) };
    const two_opacity_group = [_]DisplayItem{.{ .blend = .{
        .opacity = 0.5,
        .blend_mode = null,
        .children = &two_opacity_children,
        .needs_compositing = true,
        .compositor_id = 9,
    } }};
    try std.testing.expect(!canDrawDirectly(&two_opacity_group));

    var blurred_children = [_]DisplayItem{directTestRect(0)};
    const blurred = [_]DisplayItem{.{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .blur_radius = 3.0,
        .children = &blurred_children,
    } }};
    try std.testing.expect(!canDrawDirectly(&blurred));

    var blended_children = [_]DisplayItem{directTestRect(0)};
    const blended = [_]DisplayItem{.{ .blend = .{
        .opacity = 1.0,
        .blend_mode = "multiply",
        .children = &blended_children,
    } }};
    try std.testing.expect(!canDrawDirectly(&blended));

    const image = [_]DisplayItem{.{ .image = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 1,
        .y2 = 1,
        .source_width = 1,
        .source_height = 1,
        .pixels = &.{ 0, 0, 0, 0 },
    } }};
    try std.testing.expect(!canDrawDirectly(&image));
}

test "surface-less plane owns and releases its direct command snapshot" {
    const items = [_]DisplayItem{directTestRect(0)};
    var plane = Plane{
        .direct_commands = try RasterSnapshot.clone(std.testing.allocator, &items),
        .bounds = .{ .left = 0, .top = 0, .right = 10, .bottom = 10 },
    };
    plane.deinit(std.testing.allocator);
    try std.testing.expect(plane.surface == null);
    try std.testing.expect(plane.direct_commands == null);
}

test "cached planes update transform and opacity without replacing pixels" {
    const allocator = std.testing.allocator;
    var source = try z2d.Surface.init(.image_surface_rgba, allocator, 1, 1);
    switch (source) {
        .image_surface_rgba => |*surface| surface.buf[0] = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        else => unreachable,
    }
    var cache = Cache{};
    defer cache.deinit(allocator);
    try cache.planes.append(allocator, .{
        .surface = source,
        .bounds = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 },
        .compositor_id = 7,
    });
    cache.valid = true;
    cache.apply(&.{
        .{ .id = 7, .value = .{ .opacity = 0.5 } },
        .{ .id = 7, .value = .{ .transform = .{ .x = 1, .y = 0 } } },
    });

    var destination = try z2d.Surface.init(.image_surface_rgba, allocator, 3, 1);
    defer destination.deinit(allocator);
    switch (destination) {
        .image_surface_rgba => |*surface| @memset(surface.buf, .{ .r = 255, .g = 255, .b = 255, .a = 255 }),
        else => unreachable,
    }
    cache.draw(&destination, 0, 0, 1.0);
    const pixels = switch (destination) {
        .image_surface_rgba => |*surface| surface.buf,
        else => unreachable,
    };
    try std.testing.expectEqual(z2d.pixel.RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 }, pixels[0]);
    try std.testing.expect(@abs(@as(i16, pixels[1].g) - 127) <= 1);
    try std.testing.expect(@abs(@as(i16, pixels[1].b) - 127) <= 1);
    try std.testing.expectEqual(@as(u8, 255), pixels[1].r);
}

test "animated transform is a permanent overlap barrier for later paint" {
    const allocator = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(allocator);

    var before = try z2d.Surface.init(.image_surface_rgba, allocator, 1, 1);
    var before_owned = true;
    errdefer if (before_owned) before.deinit(allocator);
    try cache.planes.append(allocator, .{
        .surface = before,
        .bounds = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .paint_bounds = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 },
    });
    before_owned = false;

    var moving = try z2d.Surface.init(.image_surface_rgba, allocator, 1, 1);
    var moving_owned = true;
    errdefer if (moving_owned) moving.deinit(allocator);
    try cache.planes.append(allocator, .{
        .surface = moving,
        .bounds = .{ .left = 30, .top = 0, .right = 40, .bottom = 10 },
        .paint_bounds = .{ .left = 30, .top = 0, .right = 40, .bottom = 10 },
        .compositor_id = 7,
        .assume_overlap_after = true,
    });
    moving_owned = false;

    // The later item is currently far from the moving plane. A current-bounds
    // test alone would merge it into plane 0 and place it underneath once the
    // transform reaches x=80. Assume-overlap mode keeps it after the mover.
    const later = Rect{ .left = 80, .top = 0, .right = 90, .bottom = 10 };
    try std.testing.expect(cache.staticMergeTarget(later, 1.0) == null);

    var after = try z2d.Surface.init(.image_surface_rgba, allocator, 1, 1);
    var after_owned = true;
    errdefer if (after_owned) after.deinit(allocator);
    try cache.planes.append(allocator, .{
        .surface = after,
        .bounds = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .paint_bounds = later,
    });
    after_owned = false;
    try std.testing.expectEqual(@as(?usize, 2), cache.staticMergeTarget(
        .{ .left = 92, .top = 0, .right = 98, .bottom = 10 },
        1.0,
    ));
}

test "fixed transform permits current-bounds static plane merging" {
    const allocator = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(allocator);

    var before = try z2d.Surface.init(.image_surface_rgba, allocator, 1, 1);
    var before_owned = true;
    errdefer if (before_owned) before.deinit(allocator);
    try cache.planes.append(allocator, .{
        .surface = before,
        .bounds = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .paint_bounds = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 },
    });
    before_owned = false;

    var fixed = try z2d.Surface.init(.image_surface_rgba, allocator, 1, 1);
    var fixed_owned = true;
    errdefer if (fixed_owned) fixed.deinit(allocator);
    try cache.planes.append(allocator, .{
        .surface = fixed,
        .bounds = .{ .left = 30, .top = 0, .right = 40, .bottom = 10 },
        .paint_bounds = .{ .left = 30, .top = 0, .right = 40, .bottom = 10 },
        .compositor_id = 8,
    });
    fixed_owned = false;

    try std.testing.expectEqual(@as(?usize, 0), cache.staticMergeTarget(
        .{ .left = 80, .top = 0, .right = 90, .bottom = 10 },
        1.0,
    ));
    try std.testing.expect(cache.staticMergeTarget(
        .{ .left = 35, .top = 0, .right = 45, .bottom = 10 },
        1.0,
    ) == null);
}

test "far-apart chunks do not create a sparse merged surface" {
    try std.testing.expect(mergeFitsSurfaceArea(
        .{ .left = 0, .top = 0, .right = 512, .bottom = 1024 },
        .{ .left = 512, .top = 0, .right = 1024, .bottom = 1024 },
    ));
    try std.testing.expect(!mergeFitsSurfaceArea(
        .{ .left = 0, .top = 0, .right = 512, .bottom = 1024 },
        .{ .left = 512, .top = 0, .right = 1025, .bottom = 1024 },
    ));

    const allocator = std.testing.allocator;
    var cache = Cache{};
    defer cache.deinit(allocator);

    var surface = try z2d.Surface.init(.image_surface_rgba, allocator, 1, 1);
    var surface_owned = true;
    errdefer if (surface_owned) surface.deinit(allocator);
    const top = Rect{ .left = 0, .top = 0, .right = 700, .bottom = 40 };
    try cache.planes.append(allocator, .{
        .surface = surface,
        .bounds = top,
        .paint_bounds = top,
    });
    surface_owned = false;

    const nearby = Rect{ .left = 0, .top = 50, .right = 700, .bottom = 90 };
    try std.testing.expectEqual(@as(?usize, 0), cache.staticMergeTarget(nearby, 1.0));

    const far = Rect{ .left = 0, .top = 2000, .right = 700, .bottom = 2040 };
    try std.testing.expect(!mergeFitsSurfaceArea(top, far));
    try std.testing.expect(cache.staticMergeTarget(far, 1.0) == null);
}
