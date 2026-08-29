//! Pure z2d display-command rasterization.
//!
//! This module interprets immutable display commands into software surfaces.
//! It imports neither Browser nor SDL. The renderer borrows allocators, I/O,
//! and the retained compositor's pure bounds calculator; it owns no thread or
//! native resource.

const std = @import("std");
const z2d = @import("z2d");
const compositor = z2d.compositor;

const display_commands = @import("render/display_list.zig");
const effects = @import("render/effects.zig");
const raster_snapshot = @import("render/raster_snapshot.zig");
const DisplayCompositor = @import("display_compositor.zig").Compositor;

const blurKernelRadius = effects.blurKernelRadius;
const CompositedLayer = display_commands.CompositedLayer;
const DisplayItem = display_commands.DisplayItem;
const ImageDisplayItem = display_commands.ImageDisplayItem;
const gaussianBlurPixels = effects.gaussianBlurPixels;
const rasterBlendNeedsIsolation = raster_snapshot.blendNeedsIsolation;

fn glyphSourcePixel(
    pixel_mode: display_commands.GlyphPixelMode,
    bitmap_pixel: []const u8,
    text_color: display_commands.Color,
) ?z2d.pixel.RGBA {
    std.debug.assert(bitmap_pixel.len == 4);
    const bitmap_alpha = bitmap_pixel[3];
    const final_alpha: u8 = @intCast(
        (@as(u16, bitmap_alpha) * @as(u16, text_color.a) + 127) / 255,
    );
    if (final_alpha == 0) return null;

    const source_rgb = switch (pixel_mode) {
        .alpha_mask => .{ text_color.r, text_color.g, text_color.b },
        .color => .{ bitmap_pixel[0], bitmap_pixel[1], bitmap_pixel[2] },
    };
    return (z2d.pixel.RGBA{
        .r = source_rgb[0],
        .g = source_rgb[1],
        .b = source_rgb[2],
        .a = final_alpha,
    }).multiply();
}

test "glyph source pixels tint masks but preserve color bitmaps" {
    const bitmap = [_]u8{ 210, 120, 30, 255 };
    const text_color = display_commands.Color{ .r = 12, .g = 34, .b = 56, .a = 255 };

    try std.testing.expectEqual(
        z2d.pixel.RGBA{ .r = 12, .g = 34, .b = 56, .a = 255 },
        glyphSourcePixel(.alpha_mask, &bitmap, text_color).?,
    );
    try std.testing.expectEqual(
        z2d.pixel.RGBA{ .r = 210, .g = 120, .b = 30, .a = 255 },
        glyphSourcePixel(.color, &bitmap, text_color).?,
    );
}

test "glyph source pixels combine bitmap and CSS alpha" {
    const bitmap = [_]u8{ 255, 128, 64, 128 };
    const source = glyphSourcePixel(
        .color,
        &bitmap,
        .{ .r = 1, .g = 2, .b = 3, .a = 128 },
    ).?;
    try std.testing.expectEqual(@as(u8, 64), source.a);
    try std.testing.expect(source.r <= source.a);
    try std.testing.expect(source.g <= source.a);
    try std.testing.expect(source.b <= source.a);
}

fn imageSurfacePixels(surface: *z2d.Surface) ![]z2d.pixel.RGBA {
    return switch (surface.*) {
        .image_surface_rgba => |*image_surface| image_surface.buf,
        else => error.UnsupportedSurfaceType,
    };
}

fn compositeStraightImagePixel(
    source: []const u8,
    opacity: f64,
    destination: z2d.pixel.RGBA,
) ?z2d.pixel.RGBA {
    std.debug.assert(source.len == 4);
    const alpha_f = @as(f64, @floatFromInt(source[3])) *
        std.math.clamp(opacity, 0.0, 1.0);
    const alpha: u32 = @intCast(std.math.clamp(
        @as(i32, @intFromFloat(alpha_f + 0.5)),
        0,
        255,
    ));
    if (alpha == 0) return null;
    if (alpha == 255) return .{
        .r = source[0],
        .g = source[1],
        .b = source[2],
        .a = 255,
    };

    const inverse = 255 - alpha;
    return .{
        // Web image buffers are straight-alpha, while z2d surfaces are
        // premultiplied. Premultiply the source as part of source-over.
        .r = @intCast((@as(u32, source[0]) * alpha + @as(u32, destination.r) * inverse) / 255),
        .g = @intCast((@as(u32, source[1]) * alpha + @as(u32, destination.g) * inverse) / 255),
        .b = @intCast((@as(u32, source[2]) * alpha + @as(u32, destination.b) * inverse) / 255),
        .a = @intCast(alpha + @as(u32, destination.a) * inverse / 255),
    };
}

test "straight-alpha web images preserve premultiplied surface invariants" {
    const translucent_white = [_]u8{ 255, 255, 255, 128 };
    const transparent = z2d.pixel.RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const over_transparent = compositeStraightImagePixel(
        &translucent_white,
        1.0,
        transparent,
    ).?;
    try std.testing.expectEqual(@as(u8, 128), over_transparent.a);
    try std.testing.expectEqual(over_transparent.a, over_transparent.r);
    try std.testing.expectEqual(over_transparent.a, over_transparent.g);
    try std.testing.expectEqual(over_transparent.a, over_transparent.b);

    const opaque_blue = z2d.pixel.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const over_opaque = compositeStraightImagePixel(
        &translucent_white,
        0.5,
        opaque_blue,
    ).?;
    try std.testing.expectEqual(@as(u8, 255), over_opaque.a);
    try std.testing.expect(over_opaque.r <= over_opaque.a);
    try std.testing.expect(over_opaque.g <= over_opaque.a);
    try std.testing.expect(over_opaque.b <= over_opaque.a);
}

const RasterImageSource = struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,
};

fn rasterImageSource(image_item: anytype) RasterImageSource {
    var left: f64 = 0;
    var top: f64 = 0;
    var right: f64 = @floatFromInt(image_item.source_width);
    var bottom: f64 = @floatFromInt(image_item.source_height);
    if (comptime @hasField(@TypeOf(image_item), "source_rect")) {
        if (image_item.source_rect) |crop| {
            const source_width: f64 = @floatFromInt(image_item.source_width);
            const source_height: f64 = @floatFromInt(image_item.source_height);
            left = std.math.clamp(crop.left, 0, source_width);
            top = std.math.clamp(crop.top, 0, source_height);
            right = std.math.clamp(crop.right, left, source_width);
            bottom = std.math.clamp(crop.bottom, top, source_height);
        }
    }
    return .{ .left = left, .top = top, .width = right - left, .height = bottom - top };
}

fn mapImageSourceCoordinate(
    destination: i32,
    destination_start: i32,
    destination_size: i32,
    source_start: f64,
    source_size: f64,
) i32 {
    if (destination_size <= 0 or source_size <= 0 or
        !std.math.isFinite(source_start) or !std.math.isFinite(source_size)) return -1;
    const offset: f64 = @floatFromInt(
        @as(i64, destination) - @as(i64, destination_start),
    );
    const mapped = source_start + offset * source_size /
        @as(f64, @floatFromInt(destination_size));
    return @intFromFloat(@floor(std.math.clamp(
        mapped,
        @as(f64, @floatFromInt(std.math.minInt(i32))),
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    )));
}

fn mapImageSourceCoordinateForItem(
    image_item: anytype,
    destination: i32,
    destination_start: i32,
    destination_size: i32,
    source_start: f64,
    source_size: f64,
    horizontal: bool,
    zoom: f32,
) i32 {
    if (comptime @hasField(@TypeOf(image_item), "tiling")) {
        if (image_item.tiling) |tile| {
            const layout_size = if (horizontal) tile.width else tile.height;
            const layout_offset = if (horizontal) tile.offset_x else tile.offset_y;
            const repeats = if (horizontal) tile.repeat_x else tile.repeat_y;
            const tile_size = display_commands.DisplayItem.scaleLayoutPx(layout_size, zoom);
            if (tile_size <= 0) return -1;
            const tile_start = destination_start +
                display_commands.DisplayItem.scaleLayoutPx(layout_offset, zoom);
            const relative = destination - tile_start;
            const tile_coordinate = if (repeats)
                @mod(relative, tile_size)
            else blk: {
                if (relative < 0 or relative >= tile_size) return -1;
                break :blk relative;
            };
            return mapImageSourceCoordinate(
                tile_coordinate,
                0,
                tile_size,
                source_start,
                source_size,
            );
        }
    }
    return mapImageSourceCoordinate(
        destination,
        destination_start,
        destination_size,
        source_start,
        source_size,
    );
}

test "raster image sampling honors a clipped background source rectangle" {
    const pixels = [_]u8{0} ** (4 * 2 * 4);
    const item = ImageDisplayItem{
        .x1 = 0,
        .y1 = 0,
        .x2 = 120,
        .y2 = 120,
        .source_width = 4,
        .source_height = 2,
        .pixels = &pixels,
        .source_rect = .{ .left = 0, .top = 0, .right = 2, .bottom = 2 },
    };
    try std.testing.expectEqual(
        RasterImageSource{ .left = 0, .top = 0, .width = 2, .height = 2 },
        rasterImageSource(item),
    );
    try std.testing.expectEqual(@as(i32, 0), mapImageSourceCoordinate(0, 0, 120, 0, 2));
    try std.testing.expectEqual(@as(i32, 1), mapImageSourceCoordinate(119, 0, 120, 0, 2));
    try std.testing.expectEqual(@as(i32, 0), mapImageSourceCoordinate(0, 0, 160, 0.4, 3.2));
    try std.testing.expectEqual(@as(i32, 3), mapImageSourceCoordinate(159, 0, 160, 0.4, 3.2));
}

test "raster image sampling repeats a positioned background tile" {
    const pixels = [_]u8{0} ** (2 * 2 * 4);
    const item = ImageDisplayItem{
        .x1 = 10,
        .y1 = 20,
        .x2 = 30,
        .y2 = 40,
        .source_width = 2,
        .source_height = 2,
        .pixels = &pixels,
        .tiling = .{
            .width = 2,
            .height = 2,
            .offset_x = 1,
            .repeat_x = true,
            .repeat_y = false,
        },
    };
    try std.testing.expectEqual(
        @as(i32, 0),
        mapImageSourceCoordinateForItem(item, 13, 10, 20, 0, 2, true, 1.0),
    );
    try std.testing.expectEqual(
        @as(i32, 1),
        mapImageSourceCoordinateForItem(item, 14, 10, 20, 0, 2, true, 1.0),
    );
    try std.testing.expectEqual(
        @as(i32, -1),
        mapImageSourceCoordinateForItem(item, 23, 20, 20, 0, 2, false, 1.0),
    );
}

pub const Renderer = struct {
    /// Retained layer surfaces use the Browser allocator because their lifetime
    /// follows the Browser compositor generation.
    layer_allocator: std.mem.Allocator,
    /// Temporary blur/mask/isolation surfaces may be created on the raster
    /// worker and therefore use its SMP-safe allocator.
    scratch_allocator: std.mem.Allocator,
    io: std.Io,
    bounds: *const DisplayCompositor,
    debug_layer_borders: bool = false,

    pub fn init(
        layer_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        bounds: *const DisplayCompositor,
    ) Renderer {
        return .{
            .layer_allocator = layer_allocator,
            .scratch_allocator = scratch_allocator,
            .io = io,
            .bounds = bounds,
        };
    }

    fn scalePxWithZoom(_: *const Renderer, value: i32, zoom: f32) i32 {
        const scaled = @as(f64, @floatFromInt(value)) * @as(f64, zoom);
        return @intFromFloat(@round(scaled));
    }

    fn scalePxFWithZoom(_: *const Renderer, value: f64, zoom: f32) f64 {
        return value * @as(f64, zoom);
    }

    fn rasterCompositedLayer(self: *Renderer, layer: *CompositedLayer, zoom: f32) !void {
        if (!layer.needs_raster and layer.surface != null) return;

        const layer_width: i32 = @max(1, layer.bounds.width());
        const layer_height: i32 = @max(1, layer.bounds.height());
        if (layer.surface) |*existing| {
            if (existing.getWidth() != layer_width or existing.getHeight() != layer_height) {
                existing.deinit(self.layer_allocator);
                layer.surface = null;
            }
        }
        if (layer.surface == null) {
            layer.surface = try z2d.Surface.init(
                .image_surface_rgba,
                self.layer_allocator,
                layer_width,
                layer_height,
            );
        }

        var context = z2d.Context.init(self.io, self.layer_allocator, &layer.surface.?);
        defer context.deinit();
        context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
            .r = 0,
            .g = 0,
            .b = 0,
            .a = 0,
        } } } });
        try context.moveTo(0, 0);
        try context.lineTo(@floatFromInt(layer_width), 0);
        try context.lineTo(@floatFromInt(layer_width), @floatFromInt(layer_height));
        try context.lineTo(0, @floatFromInt(layer_height));
        try context.closePath();
        try context.fill();

        for (layer.display_items) |item| {
            try self.drawDisplayItemZ2dContextForLayer(
                &context,
                item,
                layer.bounds.left,
                layer.bounds.top,
                zoom,
            );
        }
        layer.needs_raster = false;
    }

    fn drawImageNearest(
        self: *Renderer,
        context: *z2d.Context,
        image_item: anytype,
        zoom: f32,
        dest_left: i32,
        dest_top: i32,
        dest_right: i32,
        dest_bottom: i32,
        surface_width: i32,
        surface_height: i32,
    ) !void {
        _ = self;
        const dest_width = dest_right - dest_left;
        const dest_height = dest_bottom - dest_top;
        if (dest_width <= 0 or dest_height <= 0) return;
        if (image_item.source_width <= 0 or image_item.source_height <= 0) return;
        if (!display_commands.rgbaPixelBufferComplete(
            image_item.source_width,
            image_item.source_height,
            image_item.pixels,
        )) return;

        var start_x = dest_left;
        if (start_x < 0) start_x = 0;
        var end_x = dest_right;
        if (end_x > surface_width) end_x = surface_width;

        var start_y = dest_top;
        if (start_y < 0) start_y = 0;
        var end_y = dest_bottom;
        if (end_y > surface_height) end_y = surface_height;

        if (end_x <= start_x or end_y <= start_y) return;

        const src_w = image_item.source_width;
        const src_h = image_item.source_height;
        const source = rasterImageSource(image_item);
        if (source.width <= 0 or source.height <= 0) return;
        const pixels = image_item.pixels;

        switch (context.surface.*) {
            .image_surface_rgba => |*img_surface| {
                const dest_pixels = img_surface.buf;
                const opacity = std.math.clamp(image_item.opacity, 0.0, 1.0);

                var y = start_y;
                while (y < end_y) : (y += 1) {
                    const src_y = mapImageSourceCoordinateForItem(
                        image_item,
                        y,
                        dest_top,
                        dest_height,
                        source.top,
                        source.height,
                        false,
                        zoom,
                    );
                    if (src_y < 0 or src_y >= src_h) continue;

                    const row_base = @as(usize, @intCast(y)) * @as(usize, @intCast(surface_width));

                    var x = start_x;
                    while (x < end_x) : (x += 1) {
                        const src_x = mapImageSourceCoordinateForItem(
                            image_item,
                            x,
                            dest_left,
                            dest_width,
                            source.left,
                            source.width,
                            true,
                            zoom,
                        );
                        if (src_x < 0 or src_x >= src_w) continue;

                        const src_idx = (@as(usize, @intCast(src_y)) * @as(usize, @intCast(src_w)) + @as(usize, @intCast(src_x))) * 4;
                        const dst_idx = row_base + @as(usize, @intCast(x));
                        dest_pixels[dst_idx] = compositeStraightImagePixel(
                            pixels[src_idx..][0..4],
                            opacity,
                            dest_pixels[dst_idx],
                        ) orelse continue;
                    }
                }
                return;
            },
            else => {},
        }

        var y = start_y;
        while (y < end_y) : (y += 1) {
            const src_y = mapImageSourceCoordinateForItem(
                image_item,
                y,
                dest_top,
                dest_height,
                source.top,
                source.height,
                false,
                zoom,
            );
            if (src_y < 0 or src_y >= src_h) continue;

            var x = start_x;
            while (x < end_x) : (x += 1) {
                const src_x = mapImageSourceCoordinateForItem(
                    image_item,
                    x,
                    dest_left,
                    dest_width,
                    source.left,
                    source.width,
                    true,
                    zoom,
                );
                if (src_x < 0 or src_x >= src_w) continue;

                const src_idx = (@as(usize, @intCast(src_y)) * @as(usize, @intCast(src_w)) + @as(usize, @intCast(src_x))) * 4;
                const a = pixels[src_idx + 3];
                if (a == 0) continue;

                const alpha_f = @as(f64, @floatFromInt(a)) * image_item.opacity;
                const alpha = std.math.clamp(@as(i32, @intFromFloat(alpha_f + 0.5)), 0, 255);
                if (alpha == 0) continue;

                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = pixels[src_idx + 0],
                    .g = pixels[src_idx + 1],
                    .b = pixels[src_idx + 2],
                    .a = @intCast(alpha),
                } } } });
                context.moveTo(@floatFromInt(x), @floatFromInt(y)) catch continue;
                context.lineTo(@floatFromInt(x + 1), @floatFromInt(y)) catch continue;
                context.lineTo(@floatFromInt(x + 1), @floatFromInt(y + 1)) catch continue;
                context.lineTo(@floatFromInt(x), @floatFromInt(y + 1)) catch continue;
                context.closePath() catch continue;
                context.fill() catch continue;
            }
        }
    }

    // Draw a display item using a specific z2d context
    fn compositePremultipliedSurface(
        self: *Renderer,
        context: *z2d.Context,
        surface: *z2d.Surface,
        destination_x: i32,
        destination_y: i32,
        opacity_value: f64,
        operator: compositor.Operator,
    ) !void {
        _ = self;
        const source = switch (surface.*) {
            .image_surface_rgba => |*image_surface| image_surface,
            else => return error.UnsupportedSurfaceType,
        };
        const destination = switch (context.surface.*) {
            .image_surface_rgba => |*image_surface| image_surface,
            else => return error.UnsupportedSurfaceType,
        };
        const opacity = std.math.clamp(opacity_value, 0.0, 1.0);
        if (opacity <= 0.0) return;

        const source_width: usize = @intCast(source.width);
        const source_height: usize = @intCast(source.height);
        const destination_width: usize = @intCast(destination.width);
        const destination_height: i32 = destination.height;
        for (0..source_height) |row| {
            const y = destination_y + @as(i32, @intCast(row));
            if (y < 0 or y >= destination_height) continue;
            for (0..source_width) |column| {
                const x = destination_x + @as(i32, @intCast(column));
                if (x < 0 or x >= destination.width) continue;

                var pixel = source.buf[row * source_width + column];
                if (opacity < 1.0) {
                    pixel.r = @intFromFloat(@round(@as(f64, @floatFromInt(pixel.r)) * opacity));
                    pixel.g = @intFromFloat(@round(@as(f64, @floatFromInt(pixel.g)) * opacity));
                    pixel.b = @intFromFloat(@round(@as(f64, @floatFromInt(pixel.b)) * opacity));
                    pixel.a = @intFromFloat(@round(@as(f64, @floatFromInt(pixel.a)) * opacity));
                }
                const destination_index = @as(usize, @intCast(y)) * destination_width + @as(usize, @intCast(x));
                destination.buf[destination_index] = compositor.runPixelT(
                    z2d.pixel.RGBA,
                    destination.buf[destination_index],
                    z2d.pixel.RGBA,
                    pixel,
                    operator,
                );
            }
        }
    }

    /// Render one element subtree to a transparent surface, blur its
    /// premultiplied pixels, then composite that result as a single image.
    fn drawBlurredChildren(
        self: *Renderer,
        context: *z2d.Context,
        children: []DisplayItem,
        radius: f64,
        opacity: f64,
        blend_mode: ?[]const u8,
        destination_x_offset: i32,
        destination_y_offset: i32,
        zoom: f32,
    ) anyerror!void {
        const content_bounds = self.bounds.displayItemsBounds(children, zoom) orelse return;
        const sigma = radius * @as(f64, zoom);
        const outset: i32 = @intCast(blurKernelRadius(sigma));
        if (outset == 0) {
            for (children) |child| {
                try self.drawDisplayItemZ2dContextForLayer(
                    context,
                    child,
                    -destination_x_offset,
                    -destination_y_offset,
                    zoom,
                );
            }
            return;
        }

        const blur_bounds = content_bounds.outset(outset);
        const width = blur_bounds.width();
        const height = blur_bounds.height();
        if (width <= 0 or height <= 0) return;

        const render_allocator = self.scratch_allocator;
        var surface = try z2d.Surface.init(.image_surface_rgba, render_allocator, width, height);
        defer surface.deinit(render_allocator);
        const pixels = switch (surface) {
            .image_surface_rgba => |*image_surface| image_surface.buf,
            else => return error.UnsupportedSurfaceType,
        };
        @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

        var blur_context = z2d.Context.init(self.io, render_allocator, &surface);
        defer blur_context.deinit();
        for (children) |child| {
            try self.drawDisplayItemZ2dContextForLayer(
                &blur_context,
                child,
                blur_bounds.left,
                blur_bounds.top,
                zoom,
            );
        }
        try gaussianBlurPixels(
            render_allocator,
            pixels,
            @intCast(width),
            @intCast(height),
            sigma,
        );

        const operator = if (blend_mode) |mode| self.parseBlendMode(mode) else context.getOperator();
        try self.compositePremultipliedSurface(
            context,
            &surface,
            blur_bounds.left + destination_x_offset,
            blur_bounds.top + destination_y_offset,
            opacity,
            operator,
        );
    }

    /// Apply a display-list mask to every pixel already present in one
    /// isolated layer. Doing this with the low-level compositor gives dst_in
    /// its required unbounded semantics even when the mask path covers only
    /// part of the temporary surface.
    fn applyDisplayMaskForLayer(
        self: *Renderer,
        context: *z2d.Context,
        mask: DisplayItem,
        layer_x: i32,
        layer_y: i32,
        zoom: f32,
    ) anyerror!void {
        const width = context.surface.getWidth();
        const height = context.surface.getHeight();
        if (width <= 0 or height <= 0) return;

        const render_allocator = self.scratch_allocator;
        var mask_surface = try z2d.Surface.init(.image_surface_rgba, render_allocator, width, height);
        defer mask_surface.deinit(render_allocator);
        const mask_pixels = switch (mask_surface) {
            .image_surface_rgba => |*image_surface| image_surface.buf,
            else => return error.UnsupportedSurfaceType,
        };
        @memset(mask_pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

        if (mask == .rounded_rect) {
            const rounded = mask.rounded_rect;
            const left = self.scalePxWithZoom(rounded.x1, zoom) - layer_x;
            const right = self.scalePxWithZoom(rounded.x2, zoom) - layer_x;
            const top = self.scalePxWithZoom(rounded.y1, zoom) - layer_y;
            const bottom = self.scalePxWithZoom(rounded.y2, zoom) - layer_y;
            const radius = @min(
                self.scalePxFWithZoom(rounded.radius, zoom),
                @min(
                    @as(f64, @floatFromInt(@max(0, right - left))) / 2.0,
                    @as(f64, @floatFromInt(@max(0, bottom - top))) / 2.0,
                ),
            );
            const width_usize: usize = @intCast(width);
            const sample_offsets = [_]f64{ 0.25, 0.75 };
            for (0..@as(usize, @intCast(height))) |row| {
                for (0..width_usize) |column| {
                    var covered: u8 = 0;
                    for (sample_offsets) |sample_y| {
                        for (sample_offsets) |sample_x| {
                            const x = @as(f64, @floatFromInt(column)) + sample_x;
                            const y = @as(f64, @floatFromInt(row)) + sample_y;
                            if (x < @as(f64, @floatFromInt(left)) or x >= @as(f64, @floatFromInt(right)) or
                                y < @as(f64, @floatFromInt(top)) or y >= @as(f64, @floatFromInt(bottom))) continue;
                            const nearest_x = std.math.clamp(
                                x,
                                @as(f64, @floatFromInt(left)) + radius,
                                @as(f64, @floatFromInt(right)) - radius,
                            );
                            const nearest_y = std.math.clamp(
                                y,
                                @as(f64, @floatFromInt(top)) + radius,
                                @as(f64, @floatFromInt(bottom)) - radius,
                            );
                            const dx = x - nearest_x;
                            const dy = y - nearest_y;
                            if (radius <= 0.5 or dx * dx + dy * dy <= radius * radius) covered += 1;
                        }
                    }
                    const alpha: u8 = @intCast((@as(u16, rounded.color.a) * covered + 2) / 4);
                    mask_pixels[row * width_usize + column] = .{ .r = alpha, .g = alpha, .b = alpha, .a = alpha };
                }
            }
        } else {
            var mask_context = z2d.Context.init(self.io, render_allocator, &mask_surface);
            defer mask_context.deinit();
            try self.drawDisplayItemZ2dContextForLayer(&mask_context, mask, layer_x, layer_y, zoom);
        }

        const destination_pixels = switch (context.surface.*) {
            .image_surface_rgba => |*image_surface| image_surface.buf,
            else => return error.UnsupportedSurfaceType,
        };
        for (destination_pixels, mask_pixels) |*destination, source| {
            destination.* = compositor.runPixelT(
                z2d.pixel.RGBA,
                destination.*,
                z2d.pixel.RGBA,
                source,
                .dst_in,
            );
        }
    }

    /// Raster one compositing boundary into an isolated transparent surface.
    /// This preserves the old layer semantics without sharing mutable cached
    /// `CompositedLayer` objects across threads: inner masks cannot consume
    /// pixels painted by an earlier sibling outside this effect subtree.
    fn drawIsolatedBlendForLayer(
        self: *Renderer,
        context: *z2d.Context,
        blend_item: DisplayItem,
        layer_x: i32,
        layer_y: i32,
        zoom: f32,
    ) anyerror!void {
        std.debug.assert(blend_item == .blend);
        const blend = blend_item.blend;
        const bounds = self.bounds.getDisplayItemBounds(blend_item, zoom);
        const width = bounds.width();
        const height = bounds.height();
        if (width <= 0 or height <= 0) return;

        const render_allocator = self.scratch_allocator;
        var surface = try z2d.Surface.init(.image_surface_rgba, render_allocator, width, height);
        defer surface.deinit(render_allocator);
        @memset(try imageSurfacePixels(&surface), .{ .r = 0, .g = 0, .b = 0, .a = 0 });

        var isolated_context = z2d.Context.init(self.io, render_allocator, &surface);
        defer isolated_context.deinit();
        var isolated_item = blend_item;
        isolated_item.blend.needs_compositing = false;
        isolated_item.blend.opacity = 1.0;
        const is_destination_mask = if (blend.blend_mode) |mode|
            std.mem.eql(u8, mode, "dst_in")
        else
            false;
        if (!is_destination_mask) isolated_item.blend.blend_mode = null;
        try self.drawDisplayItemZ2dContextForLayer(
            &isolated_context,
            isolated_item,
            bounds.left,
            bounds.top,
            zoom,
        );

        const operator = if (blend.blend_mode) |mode| self.parseBlendMode(mode) else .src_over;
        try self.compositePremultipliedSurface(
            context,
            &surface,
            bounds.left - layer_x,
            bounds.top - layer_y,
            blend.opacity,
            operator,
        );
    }

    pub fn drawDisplayItemZ2dContext(self: *Renderer, context: *z2d.Context, item: DisplayItem, scroll_offset: i32, zoom: f32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                const glyph_x = self.scalePxWithZoom(glyph_item.x, zoom);
                const glyph_y = self.scalePxWithZoom(glyph_item.y, zoom) - scroll_offset;
                try drawGlyphBitmap(context, glyph_item, glyph_x, glyph_y, zoom);
            },
            .rect => |rect_item| {
                const left = self.scalePxWithZoom(rect_item.x1, zoom);
                const right = self.scalePxWithZoom(rect_item.x2, zoom);
                const top = self.scalePxWithZoom(rect_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(rect_item.y2, zoom) - scroll_offset;
                const width = right - left;
                const height = bottom - top;

                // Only draw if rect has valid dimensions and is visible
                if (width > 1 and height > 1 and bottom > 0 and top < context.surface.getHeight()) {
                    // Reset path first to ensure clean state
                    context.resetPath();

                    // Set source color for filling
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rect_item.color.toZ2dRgba() } } });

                    // Create rectangle path
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();

                    // Fill and reset path after
                    try context.fill();
                    context.resetPath();
                }
            },
            .image => |image_item| {
                const left = self.scalePxWithZoom(image_item.x1, zoom);
                const right = self.scalePxWithZoom(image_item.x2, zoom);
                const top = self.scalePxWithZoom(image_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(image_item.y2, zoom) - scroll_offset;
                const surface_width = context.surface.getWidth();
                const surface_height = context.surface.getHeight();
                try self.drawImageNearest(
                    context,
                    image_item,
                    zoom,
                    left,
                    top,
                    right,
                    bottom,
                    surface_width,
                    surface_height,
                );
            },
            .canvas => |canvas_item| {
                const left = self.scalePxWithZoom(canvas_item.x1, zoom);
                const right = self.scalePxWithZoom(canvas_item.x2, zoom);
                const top = self.scalePxWithZoom(canvas_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(canvas_item.y2, zoom) - scroll_offset;
                try self.drawImageNearest(
                    context,
                    canvas_item,
                    zoom,
                    left,
                    top,
                    right,
                    bottom,
                    context.surface.getWidth(),
                    context.surface.getHeight(),
                );
            },
            .iframe => {
                // Iframe placeholders are expanded during display list composition.
            },
            .rounded_rect => |rounded_item| {
                const left = self.scalePxWithZoom(rounded_item.x1, zoom);
                const right = self.scalePxWithZoom(rounded_item.x2, zoom);
                const top = self.scalePxWithZoom(rounded_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(rounded_item.y2, zoom) - scroll_offset;
                if (bottom > 0 and top < context.surface.getHeight()) {
                    const width = right - left;
                    const height = bottom - top;
                    if (width > 1 and height > 1) {
                        context.resetPath();
                        // Set source color for filling
                        context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rounded_item.color.toZ2dRgba() } } });

                        // Clamp radius to not exceed half the width or height
                        const max_radius = @min(@as(f64, @floatFromInt(width)) / 2.0, @as(f64, @floatFromInt(height)) / 2.0);
                        const radius = @min(self.scalePxFWithZoom(rounded_item.radius, zoom), max_radius);

                        const x1 = @as(f64, @floatFromInt(left));
                        const y1 = @as(f64, @floatFromInt(top));
                        const x2 = x1 + @as(f64, @floatFromInt(width));
                        const y2 = y1 + @as(f64, @floatFromInt(height));

                        // Only draw rounded corners if radius is meaningful
                        if (radius > 0.5) {
                            try context.moveTo(x1 + radius, y1);
                            try context.lineTo(x2 - radius, y1);
                            try context.arc(x2 - radius, y1 + radius, radius, -std.math.pi / 2.0, 0);
                            try context.lineTo(x2, y2 - radius);
                            try context.arc(x2 - radius, y2 - radius, radius, 0, std.math.pi / 2.0);
                            try context.lineTo(x1 + radius, y2);
                            try context.arc(x1 + radius, y2 - radius, radius, std.math.pi / 2.0, std.math.pi);
                            try context.lineTo(x1, y1 + radius);
                            try context.arc(x1 + radius, y1 + radius, radius, -std.math.pi, -std.math.pi / 2.0);
                            try context.closePath();
                            try context.fill();
                        } else {
                            // Draw regular rectangle if radius is too small
                            try context.moveTo(x1, y1);
                            try context.lineTo(x2, y1);
                            try context.lineTo(x2, y2);
                            try context.lineTo(x1, y2);
                            try context.closePath();
                            try context.fill();
                        }
                    }
                }
            },
            .line => |line_item| {
                const x1 = self.scalePxWithZoom(line_item.x1, zoom);
                const x2 = self.scalePxWithZoom(line_item.x2, zoom);
                const y1 = self.scalePxWithZoom(line_item.y1, zoom) - scroll_offset;
                const y2 = self.scalePxWithZoom(line_item.y2, zoom) - scroll_offset;

                // Only draw if line has non-zero length
                const dx = x2 - x1;
                const dy = y2 - y1;
                if (dx != 0 or dy != 0) {
                    // Set source color and line width
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = line_item.color.toZ2dRgba() } } });
                    context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(line_item.thickness, zoom))));

                    // Draw the line
                    try context.moveTo(@floatFromInt(x1), @floatFromInt(y1));
                    try context.lineTo(@floatFromInt(x2), @floatFromInt(y2));
                    try context.stroke();
                    context.resetPath();
                }
            },
            .outline => |outline_item| {
                const r = outline_item.rect;
                const left = self.scalePxWithZoom(r.left, zoom);
                const right = self.scalePxWithZoom(r.right, zoom);
                const top = self.scalePxWithZoom(r.top, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(r.bottom, zoom) - scroll_offset;

                const width = right - left;
                const height = bottom - top;

                // Only draw if outline has valid dimensions
                if (width > 1 and height > 1) {
                    // Set source color and line width (assuming 1 pixel outline)
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = outline_item.color.toZ2dRgba() } } });
                    context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(outline_item.thickness, zoom))));

                    // Draw rectangle outline
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.stroke();
                }
            },
            .blend => |blend_item| {
                if (blend_item.blur_radius > 0.0) {
                    try self.drawBlurredChildren(
                        context,
                        blend_item.children,
                        blend_item.blur_radius,
                        blend_item.opacity,
                        blend_item.blend_mode,
                        0,
                        -scroll_offset,
                        zoom,
                    );
                    return;
                }
                if (item.fuseCompositedLayerDraw()) |layer_draw| {
                    try self.drawDisplayItemZ2dContext(context, layer_draw, scroll_offset, zoom);
                    return;
                }
                // For blend operations, only create a layer if we have opacity < 1 or a blend mode
                const should_save_layer = blend_item.opacity < 1.0 or blend_item.blend_mode != null;
                const is_dst_in = if (blend_item.blend_mode) |mode| std.mem.eql(u8, mode, "dst_in") else false;

                if (should_save_layer and is_dst_in and blend_item.children.len > 0) {
                    const original_operator = context.getOperator();
                    const content_end = blend_item.children.len - 1;
                    for (blend_item.children[0..content_end]) |child_item| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child_item;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContext(context, modified_item, scroll_offset, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContext(context, child_item, scroll_offset, zoom);
                        }
                    }
                    context.setOperator(self.parseBlendMode("dst_in"));
                    var mask_item = blend_item.children[content_end];
                    if (blend_item.opacity < 1.0) {
                        mask_item = self.applyOpacityToDisplayItem(mask_item, blend_item.opacity);
                    }
                    try self.drawDisplayItemZ2dContext(context, mask_item, scroll_offset, zoom);
                    context.setOperator(original_operator);
                } else if (should_save_layer) {
                    // Save current operator for restoration
                    const original_operator = context.getOperator();

                    // Set blend mode if specified
                    if (blend_item.blend_mode) |mode| {
                        const blend_operator = self.parseBlendMode(mode);
                        context.setOperator(blend_operator);
                    }

                    // Draw children with opacity applied to their colors (since z2d doesn't have layered alpha)
                    for (blend_item.children) |child_item| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child_item;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContext(context, modified_item, scroll_offset, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContext(context, child_item, scroll_offset, zoom);
                        }
                    }

                    // Restore original operator
                    context.setOperator(original_operator);
                } else {
                    // No layer needed, just draw children directly
                    for (blend_item.children) |child_item| {
                        try self.drawDisplayItemZ2dContext(context, child_item, scroll_offset, zoom);
                    }
                }
            },
            .draw_composited_layer => |dcl| {
                const draw_opacity = std.math.clamp(dcl.layer.opacity * dcl.opacity, 0.0, 1.0);
                if (draw_opacity <= 0.0) return;
                // Ensure the layer is rasterized
                try self.rasterCompositedLayer(dcl.layer, zoom);

                if (dcl.layer.surface) |*layer_surface| {
                    // Draw the layer surface at its position with opacity.
                    const layer_y_i64 = @as(i64, dcl.layer.bounds.top) - @as(i64, scroll_offset);
                    const layer_x_i64 = @as(i64, dcl.layer.bounds.left);
                    const layer_y: i32 = @intCast(std.math.clamp(layer_y_i64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32))));
                    const layer_x: i32 = @intCast(std.math.clamp(layer_x_i64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32))));
                    const operator = if (dcl.layer.blend_mode) |mode|
                        self.parseBlendMode(mode)
                    else
                        .src_over;
                    try self.compositePremultipliedSurface(
                        context,
                        layer_surface,
                        layer_x,
                        layer_y,
                        draw_opacity,
                        operator,
                    );
                    // Draw debug border if enabled
                    if (self.debug_layer_borders) {
                        const border_y = layer_y;
                        const border_x = dcl.layer.bounds.left;
                        const border_w = dcl.layer.bounds.width();
                        const border_h = dcl.layer.bounds.height();

                        // Use a bright color (magenta) for visibility
                        context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 0, .b = 255, .a = 255 } } } });
                        context.resetPath();

                        // Draw top border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + 2));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + 2));
                        try context.closePath();
                        try context.fill();

                        // Draw bottom border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h - 2));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h - 2));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();

                        // Draw left border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + 2), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + 2), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();

                        // Draw right border
                        try context.moveTo(@floatFromInt(border_x + border_w - 2), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x + border_w - 2), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();
                    }
                }
            },
            .transform => |t| {
                // Apply translation by adjusting scroll offset for children
                const new_scroll_offset = scroll_offset - self.scalePxWithZoom(t.translate_y, zoom);
                for (t.children) |child| {
                    // Recursively draw children with adjusted offset
                    // For x translation, we need to handle it differently since scroll is y-only
                    try self.drawDisplayItemZ2dContextWithTransform(
                        context,
                        child,
                        new_scroll_offset,
                        self.scalePxWithZoom(t.translate_x, zoom),
                        zoom,
                    );
                }
            },
        }
    }

    fn drawGlyphBitmap(
        context: *z2d.Context,
        glyph_item: anytype,
        glyph_x: i32,
        glyph_y: i32,
        target_zoom: f32,
    ) !void {
        const pixels = glyph_item.glyph.pixels orelse return;
        const img_surface = switch (context.surface.*) {
            .image_surface_rgba => |*img| img,
            else => return error.UnsupportedGlyphSurface,
        };

        const surface_width = img_surface.width;
        const surface_height = img_surface.height;
        const source_w: i32 = glyph_item.glyph.w;
        const source_h: i32 = glyph_item.glyph.h;

        if (source_w <= 0 or source_h <= 0) return;

        const source_w_usize: usize = @intCast(source_w);
        const source_h_usize: usize = @intCast(source_h);
        const pixel_count = std.math.mul(usize, source_w_usize, source_h_usize) catch
            return error.InvalidGlyphBitmap;
        const byte_count = std.math.mul(usize, pixel_count, 4) catch
            return error.InvalidGlyphBitmap;
        if (pixels.len != byte_count) return error.InvalidGlyphBitmap;

        const raster_scale = DisplayItem.rasterScale(glyph_item.page_zoom, target_zoom);
        const dest_w = DisplayItem.scaleRasterPx(source_w, glyph_item.page_zoom, target_zoom);
        const dest_h = DisplayItem.scaleRasterPx(source_h, glyph_item.page_zoom, target_zoom);
        const start_x_i64 = @max(@as(i64, 0), -@as(i64, glyph_x));
        const start_y_i64 = @max(@as(i64, 0), -@as(i64, glyph_y));
        const end_x_i64 = @min(@as(i64, dest_w), @as(i64, surface_width) - glyph_x);
        const end_y_i64 = @min(@as(i64, dest_h), @as(i64, surface_height) - glyph_y);
        if (end_x_i64 <= start_x_i64 or end_y_i64 <= start_y_i64) return;

        const start_x: i32 = @intCast(start_x_i64);
        const start_y: i32 = @intCast(start_y_i64);
        const end_x: i32 = @intCast(end_x_i64);
        const end_y: i32 = @intCast(end_y_i64);

        const buf = img_surface.buf;
        const surface_w_usize: usize = @intCast(surface_width);

        var y: i32 = start_y;
        while (y < end_y) : (y += 1) {
            const dest_y = glyph_y + y;
            const row_start = @as(usize, @intCast(dest_y)) * surface_w_usize;
            const source_y: i32 = @min(
                @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(y)) / raster_scale))),
                source_h - 1,
            );
            const src_row_start = @as(usize, @intCast(source_y)) * source_w_usize;

            var x: i32 = start_x;
            while (x < end_x) : (x += 1) {
                const dest_x = glyph_x + x;
                const dst_idx = row_start + @as(usize, @intCast(dest_x));
                const source_x: i32 = @min(
                    @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(x)) / raster_scale))),
                    source_w - 1,
                );
                const src_idx = (src_row_start + @as(usize, @intCast(source_x))) * 4;
                const source = glyphSourcePixel(
                    glyph_item.glyph.pixel_mode,
                    pixels[src_idx..][0..4],
                    glyph_item.color,
                ) orelse continue;
                buf[dst_idx] = compositor.runPixelT(
                    z2d.pixel.RGBA,
                    buf[dst_idx],
                    z2d.pixel.RGBA,
                    source,
                    .src_over,
                );
            }
        }
    }

    // Draw a display item with both scroll offset and x translation
    pub fn drawDisplayItemZ2dContextWithTransform(self: *Renderer, context: *z2d.Context, item: DisplayItem, scroll_offset: i32, x_offset: i32, zoom: f32) !void {
        switch (item) {
            .cached_subtree => |cached| {
                for (cached.list.items) |child| {
                    try self.drawDisplayItemZ2dContextWithTransform(
                        context,
                        child,
                        scroll_offset,
                        x_offset,
                        zoom,
                    );
                }
            },
            .glyph => |glyph_item| {
                const glyph_x = self.scalePxWithZoom(glyph_item.x, zoom) + x_offset;
                const glyph_y = self.scalePxWithZoom(glyph_item.y, zoom) - scroll_offset;
                try drawGlyphBitmap(context, glyph_item, glyph_x, glyph_y, zoom);
            },
            .rect => |rect_item| {
                const top = self.scalePxWithZoom(rect_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(rect_item.y2, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(rect_item.x1, zoom) + x_offset;
                const right = self.scalePxWithZoom(rect_item.x2, zoom) + x_offset;
                const width = right - left;
                const height = bottom - top;

                if (width > 1 and height > 1 and bottom > 0 and top < context.surface.getHeight()) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                        .r = rect_item.color.r,
                        .g = rect_item.color.g,
                        .b = rect_item.color.b,
                        .a = rect_item.color.a,
                    } } } });
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.fill();
                }
            },
            .image => |image_item| {
                const top = self.scalePxWithZoom(image_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(image_item.y2, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(image_item.x1, zoom) + x_offset;
                const right = self.scalePxWithZoom(image_item.x2, zoom) + x_offset;
                const surface_width = context.surface.getWidth();
                const surface_height = context.surface.getHeight();
                try self.drawImageNearest(
                    context,
                    image_item,
                    zoom,
                    left,
                    top,
                    right,
                    bottom,
                    surface_width,
                    surface_height,
                );
            },
            .canvas => |canvas_item| {
                const top = self.scalePxWithZoom(canvas_item.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(canvas_item.y2, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(canvas_item.x1, zoom) + x_offset;
                const right = self.scalePxWithZoom(canvas_item.x2, zoom) + x_offset;
                try self.drawImageNearest(
                    context,
                    canvas_item,
                    zoom,
                    left,
                    top,
                    right,
                    bottom,
                    context.surface.getWidth(),
                    context.surface.getHeight(),
                );
            },
            .iframe => {
                // Iframe placeholders are expanded during display list composition.
            },
            .rounded_rect => |rr| {
                const top = self.scalePxWithZoom(rr.y1, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(rr.y2, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(rr.x1, zoom) + x_offset;
                const right = self.scalePxWithZoom(rr.x2, zoom) + x_offset;
                const width = right - left;
                const height = bottom - top;
                if (width > 1 and height > 1 and bottom > 0 and top < context.surface.getHeight()) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rr.color.toZ2dRgba() } } });
                    const max_radius = @min(
                        @as(f64, @floatFromInt(width)) / 2.0,
                        @as(f64, @floatFromInt(height)) / 2.0,
                    );
                    const radius = @min(self.scalePxFWithZoom(rr.radius, zoom), max_radius);
                    const x1: f64 = @floatFromInt(left);
                    const y1: f64 = @floatFromInt(top);
                    const x2: f64 = @floatFromInt(right);
                    const y2: f64 = @floatFromInt(bottom);
                    if (radius > 0.5) {
                        try context.moveTo(x1 + radius, y1);
                        try context.lineTo(x2 - radius, y1);
                        try context.arc(x2 - radius, y1 + radius, radius, -std.math.pi / 2.0, 0);
                        try context.lineTo(x2, y2 - radius);
                        try context.arc(x2 - radius, y2 - radius, radius, 0, std.math.pi / 2.0);
                        try context.lineTo(x1 + radius, y2);
                        try context.arc(x1 + radius, y2 - radius, radius, std.math.pi / 2.0, std.math.pi);
                        try context.lineTo(x1, y1 + radius);
                        try context.arc(x1 + radius, y1 + radius, radius, -std.math.pi, -std.math.pi / 2.0);
                    } else {
                        try context.moveTo(x1, y1);
                        try context.lineTo(x2, y1);
                        try context.lineTo(x2, y2);
                        try context.lineTo(x1, y2);
                    }
                    try context.closePath();
                    try context.fill();
                    context.resetPath();
                }
            },
            .line => |l| {
                const y1 = self.scalePxWithZoom(l.y1, zoom) - scroll_offset;
                const y2 = self.scalePxWithZoom(l.y2, zoom) - scroll_offset;
                const x1 = self.scalePxWithZoom(l.x1, zoom) + x_offset;
                const x2 = self.scalePxWithZoom(l.x2, zoom) + x_offset;
                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = l.color.r,
                    .g = l.color.g,
                    .b = l.color.b,
                    .a = l.color.a,
                } } } });
                context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(l.thickness, zoom))));
                try context.moveTo(@floatFromInt(x1), @floatFromInt(y1));
                try context.lineTo(@floatFromInt(x2), @floatFromInt(y2));
                try context.stroke();
            },
            .outline => |o| {
                const top = self.scalePxWithZoom(o.rect.top, zoom) - scroll_offset;
                const bottom = self.scalePxWithZoom(o.rect.bottom, zoom) - scroll_offset;
                const left = self.scalePxWithZoom(o.rect.left, zoom) + x_offset;
                const right = self.scalePxWithZoom(o.rect.right, zoom) + x_offset;
                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = o.color.r,
                    .g = o.color.g,
                    .b = o.color.b,
                    .a = o.color.a,
                } } } });
                context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(o.thickness, zoom))));
                try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                try context.closePath();
                try context.stroke();
            },
            .blend => |blend_item| {
                if (blend_item.blur_radius > 0.0) {
                    try self.drawBlurredChildren(
                        context,
                        blend_item.children,
                        blend_item.blur_radius,
                        blend_item.opacity,
                        blend_item.blend_mode,
                        x_offset,
                        -scroll_offset,
                        zoom,
                    );
                    return;
                }
                if (item.fuseCompositedLayerDraw()) |layer_draw| {
                    try self.drawDisplayItemZ2dContextWithTransform(
                        context,
                        layer_draw,
                        scroll_offset,
                        x_offset,
                        zoom,
                    );
                    return;
                }
                // For blends, apply opacity and recurse into children with the transform applied
                const should_apply_opacity = blend_item.opacity < 1.0 or blend_item.blend_mode != null;
                const is_dst_in = if (blend_item.blend_mode) |mode| std.mem.eql(u8, mode, "dst_in") else false;

                if (should_apply_opacity and is_dst_in and blend_item.children.len > 0) {
                    const original_operator = context.getOperator();
                    const content_end = blend_item.children.len - 1;
                    for (blend_item.children[0..content_end]) |child| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContextWithTransform(context, modified_item, scroll_offset, x_offset, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset, x_offset, zoom);
                        }
                    }
                    context.setOperator(self.parseBlendMode("dst_in"));
                    var mask_item = blend_item.children[content_end];
                    if (blend_item.opacity < 1.0) {
                        mask_item = self.applyOpacityToDisplayItem(mask_item, blend_item.opacity);
                    }
                    try self.drawDisplayItemZ2dContextWithTransform(context, mask_item, scroll_offset, x_offset, zoom);
                    context.setOperator(original_operator);
                } else if (should_apply_opacity) {
                    const original_operator = context.getOperator();
                    if (blend_item.blend_mode) |mode| {
                        context.setOperator(self.parseBlendMode(mode));
                    }

                    for (blend_item.children) |child| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContextWithTransform(context, modified_item, scroll_offset, x_offset, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset, x_offset, zoom);
                        }
                    }

                    context.setOperator(original_operator);
                } else {
                    for (blend_item.children) |child| {
                        try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset, x_offset, zoom);
                    }
                }
            },
            .draw_composited_layer => |dcl| {
                const draw_opacity = std.math.clamp(dcl.layer.opacity * dcl.opacity, 0.0, 1.0);
                if (draw_opacity <= 0.0) return;
                // For composited layers, draw at transformed position
                try self.rasterCompositedLayer(dcl.layer, zoom);
                if (dcl.layer.surface) |*layer_surface| {
                    const layer_y = dcl.layer.bounds.top - scroll_offset;
                    const layer_x = dcl.layer.bounds.left + x_offset;
                    const operator = if (dcl.layer.blend_mode) |mode|
                        self.parseBlendMode(mode)
                    else
                        .src_over;
                    try self.compositePremultipliedSurface(
                        context,
                        layer_surface,
                        layer_x,
                        layer_y,
                        draw_opacity,
                        operator,
                    );
                }
            },
            .transform => |t| {
                // Nested transform: combine offsets
                for (t.children) |child| {
                    try self.drawDisplayItemZ2dContextWithTransform(
                        context,
                        child,
                        scroll_offset - self.scalePxWithZoom(t.translate_y, zoom),
                        x_offset + self.scalePxWithZoom(t.translate_x, zoom),
                        zoom,
                    );
                }
            },
        }
    }

    /// Draw a display item for a composited layer, mapping from absolute to local coordinates
    /// This function offsets all coordinates by the layer's origin to draw in layer-local space
    pub fn drawDisplayItemZ2dContextForLayer(self: *Renderer, context: *z2d.Context, item: DisplayItem, layer_x: i32, layer_y: i32, zoom: f32) !void {
        switch (item) {
            .cached_subtree => |cached| {
                for (cached.list.items) |child| {
                    try self.drawDisplayItemZ2dContextForLayer(
                        context,
                        child,
                        layer_x,
                        layer_y,
                        zoom,
                    );
                }
            },
            .glyph => |glyph_item| {
                const glyph_x = self.scalePxWithZoom(glyph_item.x, zoom) - layer_x;
                const glyph_y = self.scalePxWithZoom(glyph_item.y, zoom) - layer_y;
                try drawGlyphBitmap(context, glyph_item, glyph_x, glyph_y, zoom);
            },
            .rect => |rect_item| {
                // Map absolute coordinates to layer-local space
                const left = self.scalePxWithZoom(rect_item.x1, zoom) - layer_x;
                const right = self.scalePxWithZoom(rect_item.x2, zoom) - layer_x;
                const top = self.scalePxWithZoom(rect_item.y1, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(rect_item.y2, zoom) - layer_y;
                const width = right - left;
                const height = bottom - top;

                if (width > 1 and height > 1) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rect_item.color.toZ2dRgba() } } });
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.fill();
                    context.resetPath();
                }
            },
            .image => |image_item| {
                const left = self.scalePxWithZoom(image_item.x1, zoom) - layer_x;
                const right = self.scalePxWithZoom(image_item.x2, zoom) - layer_x;
                const top = self.scalePxWithZoom(image_item.y1, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(image_item.y2, zoom) - layer_y;
                const surface_width = context.surface.getWidth();
                const surface_height = context.surface.getHeight();
                try self.drawImageNearest(
                    context,
                    image_item,
                    zoom,
                    left,
                    top,
                    right,
                    bottom,
                    surface_width,
                    surface_height,
                );
            },
            .canvas => |canvas_item| {
                const left = self.scalePxWithZoom(canvas_item.x1, zoom) - layer_x;
                const right = self.scalePxWithZoom(canvas_item.x2, zoom) - layer_x;
                const top = self.scalePxWithZoom(canvas_item.y1, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(canvas_item.y2, zoom) - layer_y;
                try self.drawImageNearest(
                    context,
                    canvas_item,
                    zoom,
                    left,
                    top,
                    right,
                    bottom,
                    context.surface.getWidth(),
                    context.surface.getHeight(),
                );
            },
            .iframe => {
                // Iframe placeholders are expanded during display list composition.
            },
            .rounded_rect => |rr| {
                const left = self.scalePxWithZoom(rr.x1, zoom) - layer_x;
                const right = self.scalePxWithZoom(rr.x2, zoom) - layer_x;
                const top = self.scalePxWithZoom(rr.y1, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(rr.y2, zoom) - layer_y;
                const width = right - left;
                const height = bottom - top;

                if (width > 1 and height > 1) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rr.color.toZ2dRgba() } } });
                    const max_radius = @min(
                        @as(f64, @floatFromInt(width)) / 2.0,
                        @as(f64, @floatFromInt(height)) / 2.0,
                    );
                    const radius = @min(self.scalePxFWithZoom(rr.radius, zoom), max_radius);
                    const x1: f64 = @floatFromInt(left);
                    const y1: f64 = @floatFromInt(top);
                    const x2: f64 = @floatFromInt(right);
                    const y2: f64 = @floatFromInt(bottom);
                    if (radius > 0.5) {
                        try context.moveTo(x1 + radius, y1);
                        try context.lineTo(x2 - radius, y1);
                        try context.arc(x2 - radius, y1 + radius, radius, -std.math.pi / 2.0, 0);
                        try context.lineTo(x2, y2 - radius);
                        try context.arc(x2 - radius, y2 - radius, radius, 0, std.math.pi / 2.0);
                        try context.lineTo(x1 + radius, y2);
                        try context.arc(x1 + radius, y2 - radius, radius, std.math.pi / 2.0, std.math.pi);
                        try context.lineTo(x1, y1 + radius);
                        try context.arc(x1 + radius, y1 + radius, radius, -std.math.pi, -std.math.pi / 2.0);
                    } else {
                        try context.moveTo(x1, y1);
                        try context.lineTo(x2, y1);
                        try context.lineTo(x2, y2);
                        try context.lineTo(x1, y2);
                    }
                    try context.closePath();
                    try context.fill();
                    context.resetPath();
                }
            },
            .line => |line_item| {
                const x1 = self.scalePxWithZoom(line_item.x1, zoom) - layer_x;
                const x2 = self.scalePxWithZoom(line_item.x2, zoom) - layer_x;
                const y1 = self.scalePxWithZoom(line_item.y1, zoom) - layer_y;
                const y2 = self.scalePxWithZoom(line_item.y2, zoom) - layer_y;

                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = line_item.color.toZ2dRgba() } } });
                context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(line_item.thickness, zoom))));
                try context.moveTo(@floatFromInt(x1), @floatFromInt(y1));
                try context.lineTo(@floatFromInt(x2), @floatFromInt(y2));
                try context.stroke();
                context.resetPath();
            },
            .outline => |outline_item| {
                const left = self.scalePxWithZoom(outline_item.rect.left, zoom) - layer_x;
                const right = self.scalePxWithZoom(outline_item.rect.right, zoom) - layer_x;
                const top = self.scalePxWithZoom(outline_item.rect.top, zoom) - layer_y;
                const bottom = self.scalePxWithZoom(outline_item.rect.bottom, zoom) - layer_y;

                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = outline_item.color.toZ2dRgba() } } });
                context.setLineWidth(@floatFromInt(@max(1, self.scalePxWithZoom(outline_item.thickness, zoom))));
                try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                try context.closePath();
                try context.stroke();
                context.resetPath();
            },
            .blend => |blend_item| {
                if (rasterBlendNeedsIsolation(
                    blend_item.needs_compositing,
                    blend_item.blend_mode,
                    blend_item.children.len,
                )) {
                    try self.drawIsolatedBlendForLayer(
                        context,
                        item,
                        layer_x,
                        layer_y,
                        zoom,
                    );
                    return;
                }
                if (blend_item.blur_radius > 0.0) {
                    try self.drawBlurredChildren(
                        context,
                        blend_item.children,
                        blend_item.blur_radius,
                        blend_item.opacity,
                        blend_item.blend_mode,
                        -layer_x,
                        -layer_y,
                        zoom,
                    );
                    return;
                }
                // Check if this is a dst_in clipping blend
                const is_dst_in_clip = if (blend_item.blend_mode) |mode|
                    std.mem.eql(u8, mode, "dst_in")
                else
                    false;

                if (is_dst_in_clip and blend_item.children.len > 0) {
                    const content_end = blend_item.children.len - 1;
                    for (blend_item.children[0..content_end]) |child| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContextForLayer(context, modified_item, layer_x, layer_y, zoom);
                        } else {
                            try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x, layer_y, zoom);
                        }
                    }
                    var mask_item = blend_item.children[content_end];
                    if (blend_item.opacity < 1.0) {
                        mask_item = self.applyOpacityToDisplayItem(mask_item, blend_item.opacity);
                    }
                    try self.applyDisplayMaskForLayer(context, mask_item, layer_x, layer_y, zoom);
                } else {
                    // Apply opacity and recursively draw children in layer space
                    const should_apply_opacity = blend_item.opacity < 1.0 or blend_item.blend_mode != null;

                    if (should_apply_opacity) {
                        const original_operator = context.getOperator();
                        if (blend_item.blend_mode) |mode| {
                            context.setOperator(self.parseBlendMode(mode));
                        }

                        for (blend_item.children, 0..) |child, i| {
                            _ = i;
                            if (blend_item.opacity < 1.0) {
                                var modified_item = child;
                                modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                                try self.drawDisplayItemZ2dContextForLayer(context, modified_item, layer_x, layer_y, zoom);
                            } else {
                                try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x, layer_y, zoom);
                            }
                        }

                        context.setOperator(original_operator);
                    } else {
                        for (blend_item.children) |child| {
                            try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x, layer_y, zoom);
                        }
                    }
                }
            },
            .draw_composited_layer => {
                // Nested composited layers shouldn't appear in flattened content
                // They would have been handled by the compositing pass
            },
            .transform => |t| {
                // Apply transform offsets to the layer coordinates
                for (t.children) |child| {
                    try self.drawDisplayItemZ2dContextForLayer(
                        context,
                        child,
                        layer_x - self.scalePxWithZoom(t.translate_x, zoom),
                        layer_y - self.scalePxWithZoom(t.translate_y, zoom),
                        zoom,
                    );
                }
            },
        }
    }

    // Parse CSS blend mode string to z2d compositing operator
    fn parseBlendMode(self: *Renderer, blend_mode_str: []const u8) compositor.Operator {
        _ = self;
        if (std.mem.eql(u8, blend_mode_str, "multiply")) {
            return .multiply;
        } else if (std.mem.eql(u8, blend_mode_str, "screen")) {
            return .screen;
        } else if (std.mem.eql(u8, blend_mode_str, "overlay")) {
            return .overlay;
        } else if (std.mem.eql(u8, blend_mode_str, "darken")) {
            return .darken;
        } else if (std.mem.eql(u8, blend_mode_str, "lighten")) {
            return .lighten;
        } else if (std.mem.eql(u8, blend_mode_str, "color-dodge")) {
            return .color_dodge;
        } else if (std.mem.eql(u8, blend_mode_str, "color-burn")) {
            return .color_burn;
        } else if (std.mem.eql(u8, blend_mode_str, "hard-light")) {
            return .hard_light;
        } else if (std.mem.eql(u8, blend_mode_str, "soft-light")) {
            return .soft_light;
        } else if (std.mem.eql(u8, blend_mode_str, "difference")) {
            return .difference;
        } else if (std.mem.eql(u8, blend_mode_str, "exclusion")) {
            return .exclusion;
        } else if (std.mem.eql(u8, blend_mode_str, "dst_in")) {
            return .dst_in;
        } else {
            // Default to src_over for unknown blend modes
            return .src_over;
        }
    }

    // Apply opacity to a display item's colors
    fn applyOpacityToDisplayItem(self: *Renderer, item: DisplayItem, opacity: f64) DisplayItem {
        _ = self;
        return item.withOpacity(opacity);
    }
};
