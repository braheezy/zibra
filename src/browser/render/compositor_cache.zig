//! Raster-worker-owned page planes for draw-only property updates.
//!
//! Each plane owns immutable raster pixels. Animation and scrolling mutate
//! only scalar placement/alpha state, then composite those cached pixels into
//! the next root surface without replaying paint commands.

const std = @import("std");
const z2d = @import("z2d");
const compositor = z2d.compositor;
const display = @import("display_list.zig");

const Rect = display.Rect;

/// A merged RGBA plane may use at most four MiB of pixel storage. Individual
/// paint chunks can exceed this when unavoidable; the limit only prevents a
/// merge from manufacturing a large, mostly transparent bounding surface.
pub const maximum_merged_surface_area_pixels: u64 = 1024 * 1024;

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
    surface: z2d.Surface,
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
        self.surface.deinit(allocator);
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
        if (!self.valid) return;
        for (self.planes.items) |*plane| {
            const x = plane.bounds.left + display.DisplayItem.scaleLayoutPx(plane.translate_x, zoom);
            const y = chrome_bottom + plane.bounds.top - scroll_device +
                display.DisplayItem.scaleLayoutPx(plane.translate_y, zoom);
            compositeWithOpacity(destination, &plane.surface, x, y, plane.opacity);
        }
    }
};

fn compositeWithOpacity(
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
