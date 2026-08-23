const std = @import("std");
const browser = @import("../browser/root.zig");

const DisplayItem = browser.DisplayItem;
const RasterSnapshot = browser.RasterSnapshot;

test "raster snapshot owns nested glyph and image pixels" {
    var glyph_pixels = [_]u8{ 1, 2, 3, 4 };
    var image_pixels = [_]u8{ 10, 20, 30, 40 };
    var nested = [_]DisplayItem{
        .{ .glyph = .{
            .x = 3,
            .y = 4,
            .glyph = .{
                .w = 1,
                .h = 1,
                .ascent = 1,
                .descent = 0,
                .pixels = &glyph_pixels,
            },
            .color = .{ .r = 5, .g = 6, .b = 7 },
            .source = .{ .layout = @ptrFromInt(1), .node = null },
        } },
        .{ .image = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = 1,
            .y2 = 1,
            .source_width = 1,
            .source_height = 1,
            .pixels = &image_pixels,
            .source = .{ .layout = @ptrFromInt(2), .node = null },
        } },
    };
    const items = [_]DisplayItem{.{ .transform = .{
        .translate_x = 8,
        .translate_y = 9,
        .children = &nested,
        .node = @ptrFromInt(3),
        .animation_active = true,
    } }};

    var snapshot = try RasterSnapshot.clone(std.testing.allocator, &items);
    defer snapshot.deinit();

    glyph_pixels[0] = 99;
    image_pixels[0] = 88;

    const transform = snapshot.items[0].transform;
    try std.testing.expectEqual(@as(?*anyopaque, null), transform.node);
    try std.testing.expectEqual(@as(?browser.DisplayItemSource, null), transform.source);
    try std.testing.expect(transform.animation_active);
    try std.testing.expectEqual(@as(u8, 1), transform.children[0].glyph.glyph.pixels.?[0]);
    try std.testing.expectEqual(@as(u8, 10), transform.children[1].image.pixels[0]);
    try std.testing.expectEqual(@as(?browser.DisplayItemSource, null), transform.children[0].glyph.source);
    try std.testing.expectEqual(@as(?browser.DisplayItemSource, null), transform.children[1].image.source);
}

test "raster snapshot owns blend structure and rejects layer pointers" {
    var child = [_]DisplayItem{.{ .rect = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 10,
        .y2 = 10,
        .color = .{ .r = 1, .g = 2, .b = 3 },
    } }};
    const items = [_]DisplayItem{.{ .blend = .{
        .opacity = 0.5,
        .blend_mode = "multiply",
        .children = &child,
        .node = @ptrFromInt(4),
        .needs_compositing = true,
    } }};

    var snapshot = try RasterSnapshot.clone(std.testing.allocator, &items);
    defer snapshot.deinit();
    child[0].rect.color.r = 200;

    try std.testing.expectEqualStrings("multiply", snapshot.items[0].blend.blend_mode.?);
    try std.testing.expectEqual(@as(u8, 1), snapshot.items[0].blend.children[0].rect.color.r);
    try std.testing.expectEqual(@as(?*anyopaque, null), snapshot.items[0].blend.node);

    const layer_item = [_]DisplayItem{.{ .draw_composited_layer = .{ .layer = undefined } }};
    try std.testing.expectError(
        error.CompositedLayerCannotCrossRasterBoundary,
        RasterSnapshot.clone(std.testing.allocator, &layer_item),
    );
}

test "raster isolation preserves list-level masks inside their parent group" {
    try std.testing.expect(!browser.rasterBlendNeedsIsolation(false, null, 2));
    try std.testing.expect(!browser.rasterBlendNeedsIsolation(true, "dst_in", 1));
    try std.testing.expect(browser.rasterBlendNeedsIsolation(true, "dst_in", 2));
    try std.testing.expect(browser.rasterBlendNeedsIsolation(true, null, 1));
    try std.testing.expect(browser.rasterBlendNeedsIsolation(true, "multiply", 1));
}

test "opacity-only ancestor folds into composited layer draw scalar" {
    var layer = browser.CompositedLayer{
        .display_items = &.{},
        .bounds = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 },
        .opacity = 0.8,
    };
    var blend_children = [_]DisplayItem{.{ .draw_composited_layer = .{ .layer = &layer } }};
    const blend = DisplayItem{ .blend = .{
        .opacity = 0.5,
        .blend_mode = null,
        .children = &blend_children,
    } };

    const fused = blend.fuseCompositedLayerDraw().?;

    try std.testing.expect(fused == .draw_composited_layer);
    try std.testing.expectEqual(
        @as(*browser.CompositedLayer, &layer),
        fused.draw_composited_layer.layer,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5),
        fused.draw_composited_layer.opacity,
        0.0001,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), layer.opacity, 0.0001);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.4),
        layer.opacity * fused.draw_composited_layer.opacity,
        0.0001,
    );

    var second_layer = layer;
    var multiple_children = [_]DisplayItem{
        blend_children[0],
        .{ .draw_composited_layer = .{ .layer = &second_layer } },
    };
    const overlapping_group = DisplayItem{ .blend = .{
        .opacity = 0.5,
        .blend_mode = null,
        .children = &multiple_children,
    } };
    try std.testing.expect(overlapping_group.fuseCompositedLayerDraw() == null);

    var blended_group = blend;
    blended_group.blend.blend_mode = "multiply";
    try std.testing.expect(blended_group.fuseCompositedLayerDraw() == null);
    var filtered_group = blend;
    filtered_group.blend.blur_radius = 3.0;
    try std.testing.expect(filtered_group.fuseCompositedLayerDraw() == null);
    var opaque_group = blend;
    opaque_group.blend.opacity = 1.0;
    try std.testing.expect(opaque_group.fuseCompositedLayerDraw() == null);
}
