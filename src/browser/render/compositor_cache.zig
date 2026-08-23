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

pub const Update = struct {
    id: usize,
    value: union(enum) {
        opacity: f64,
        transform: struct { x: i32, y: i32 },
    },
};

pub const Plane = struct {
    surface: z2d.Surface,
    bounds: Rect,
    compositor_id: ?usize = null,
    opacity: f64 = 1.0,
    translate_x: i32 = 0,
    translate_y: i32 = 0,

    pub fn deinit(self: *Plane, allocator: std.mem.Allocator) void {
        self.surface.deinit(allocator);
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
