//! Pixel-level software effects used by both retained and worker raster paths.

const std = @import("std");
const z2d = @import("z2d");

const max_blur_kernel_radius: usize = 128;

pub fn blurKernelRadius(sigma: f64) usize {
    if (!std.math.isFinite(sigma) or sigma <= 0.0) return 0;
    return @intFromFloat(@min(
        @ceil(sigma * 3.0),
        @as(f64, @floatFromInt(max_blur_kernel_radius)),
    ));
}

fn rgbaFromWeightedSums(r: f64, g: f64, b: f64, a: f64) z2d.pixel.RGBA {
    return .{
        .r = @intFromFloat(@round(std.math.clamp(r, 0.0, 255.0))),
        .g = @intFromFloat(@round(std.math.clamp(g, 0.0, 255.0))),
        .b = @intFromFloat(@round(std.math.clamp(b, 0.0, 255.0))),
        .a = @intFromFloat(@round(std.math.clamp(a, 0.0, 255.0))),
    };
}

/// Apply a separable Gaussian blur to z2d's premultiplied RGBA pixels.
/// Sampling beyond the surface uses transparent black, matching CSS filter
/// edges when callers provide the standard three-sigma outset.
pub fn gaussianBlurPixels(
    allocator: std.mem.Allocator,
    pixels: []z2d.pixel.RGBA,
    width: usize,
    height: usize,
    sigma: f64,
) !void {
    const pixel_count = try std.math.mul(usize, width, height);
    if (pixel_count != pixels.len) return error.InvalidBlurBuffer;
    const radius = blurKernelRadius(sigma);
    if (radius == 0 or pixel_count == 0) return;

    const kernel_len = radius * 2 + 1;
    const weights = try allocator.alloc(f64, kernel_len);
    defer allocator.free(weights);
    var weight_total: f64 = 0.0;
    for (weights, 0..) |*weight, index| {
        const distance: f64 = @floatFromInt(
            @as(isize, @intCast(index)) - @as(isize, @intCast(radius)),
        );
        weight.* = @exp(-(distance * distance) / (2.0 * sigma * sigma));
        weight_total += weight.*;
    }
    for (weights) |*weight| weight.* /= weight_total;

    const intermediate = try allocator.alloc(z2d.pixel.RGBA, pixel_count);
    defer allocator.free(intermediate);

    for (0..height) |y| {
        for (0..width) |x| {
            var r: f64 = 0.0;
            var g: f64 = 0.0;
            var b: f64 = 0.0;
            var a: f64 = 0.0;
            for (weights, 0..) |weight, index| {
                const sample_x = @as(isize, @intCast(x)) +
                    @as(isize, @intCast(index)) - @as(isize, @intCast(radius));
                if (sample_x < 0 or sample_x >= @as(isize, @intCast(width))) continue;
                const sample = pixels[y * width + @as(usize, @intCast(sample_x))];
                r += @as(f64, @floatFromInt(sample.r)) * weight;
                g += @as(f64, @floatFromInt(sample.g)) * weight;
                b += @as(f64, @floatFromInt(sample.b)) * weight;
                a += @as(f64, @floatFromInt(sample.a)) * weight;
            }
            intermediate[y * width + x] = rgbaFromWeightedSums(r, g, b, a);
        }
    }

    for (0..height) |y| {
        for (0..width) |x| {
            var r: f64 = 0.0;
            var g: f64 = 0.0;
            var b: f64 = 0.0;
            var a: f64 = 0.0;
            for (weights, 0..) |weight, index| {
                const sample_y = @as(isize, @intCast(y)) +
                    @as(isize, @intCast(index)) - @as(isize, @intCast(radius));
                if (sample_y < 0 or sample_y >= @as(isize, @intCast(height))) continue;
                const sample = intermediate[@as(usize, @intCast(sample_y)) * width + x];
                r += @as(f64, @floatFromInt(sample.r)) * weight;
                g += @as(f64, @floatFromInt(sample.g)) * weight;
                b += @as(f64, @floatFromInt(sample.b)) * weight;
                a += @as(f64, @floatFromInt(sample.a)) * weight;
            }
            pixels[y * width + x] = rgbaFromWeightedSums(r, g, b, a);
        }
    }
}

test "Gaussian blur spreads premultiplied color without transparent halos" {
    var pixels = [_]z2d.pixel.RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 49;
    pixels[3 * 7 + 3] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    try gaussianBlurPixels(std.testing.allocator, &pixels, 7, 7, 1.0);

    const center = pixels[3 * 7 + 3];
    const neighbor = pixels[3 * 7 + 2];
    const two_away = pixels[3 * 7 + 1];
    try std.testing.expect(center.a < 255 and center.a > neighbor.a);
    try std.testing.expect(neighbor.a > 0);
    try std.testing.expect(two_away.a > 0);
    for (pixels) |pixel| {
        try std.testing.expectEqual(pixel.a, pixel.r);
        try std.testing.expectEqual(@as(u8, 0), pixel.g);
        try std.testing.expectEqual(@as(u8, 0), pixel.b);
    }
}
