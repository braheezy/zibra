const std = @import("std");
const zigimg = @import("zigimg");

const expected_width = 800;
const expected_height = 600;
// Chrome contains the clone-specific absolute file URL. The page viewport
// begins below it, and is the stable rendering output this test owns.
const ignored_top_rows = 70;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: {s} <expected.png> <actual.png>\n", .{args[0]});
        return error.BadArguments;
    }

    var expected_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var expected = try zigimg.Image.fromFilePath(
        allocator,
        init.io,
        args[1],
        &expected_buffer,
    );
    defer expected.deinit(allocator);

    var actual_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var actual = try zigimg.Image.fromFilePath(
        allocator,
        init.io,
        args[2],
        &actual_buffer,
    );
    defer actual.deinit(allocator);

    if (expected.width != expected_width or expected.height != expected_height) {
        std.debug.print(
            "golden has unexpected dimensions: {}x{} (expected {}x{})\n",
            .{ expected.width, expected.height, expected_width, expected_height },
        );
        return error.InvalidGoldenDimensions;
    }
    if (actual.width != expected.width or actual.height != expected.height) {
        std.debug.print(
            "screenshot dimensions differ: expected {}x{}, got {}x{}\n",
            .{ expected.width, expected.height, actual.width, actual.height },
        );
        return error.ScreenshotDimensionsMismatch;
    }
    if (expected.pixelFormat() != .rgba32 or actual.pixelFormat() != .rgba32) {
        std.debug.print(
            "screenshots must decode as RGBA32; expected={s}, actual={s}\n",
            .{ @tagName(expected.pixelFormat()), @tagName(actual.pixelFormat()) },
        );
        return error.UnsupportedPixelFormat;
    }

    const expected_pixels = expected.pixels.rgba32;
    const actual_pixels = actual.pixels.rgba32;
    const first_page_pixel = ignored_top_rows * expected.width;
    var different_pixels: usize = 0;
    var maximum_channel_delta: u8 = 0;
    var first_difference: ?usize = null;

    for (
        expected_pixels[first_page_pixel..],
        actual_pixels[first_page_pixel..],
        first_page_pixel..,
    ) |expected_pixel, actual_pixel, index| {
        if (expected_pixel.r == actual_pixel.r and
            expected_pixel.g == actual_pixel.g and
            expected_pixel.b == actual_pixel.b and
            expected_pixel.a == actual_pixel.a)
        {
            continue;
        }

        different_pixels += 1;
        if (first_difference == null) first_difference = index;
        maximum_channel_delta = @max(maximum_channel_delta, channelDelta(expected_pixel.r, actual_pixel.r));
        maximum_channel_delta = @max(maximum_channel_delta, channelDelta(expected_pixel.g, actual_pixel.g));
        maximum_channel_delta = @max(maximum_channel_delta, channelDelta(expected_pixel.b, actual_pixel.b));
        maximum_channel_delta = @max(maximum_channel_delta, channelDelta(expected_pixel.a, actual_pixel.a));
    }

    if (different_pixels != 0) {
        const first = first_difference.?;
        std.debug.print(
            "screenshot differs below chrome: {} pixels changed, max channel delta {}, first at ({}, {})\n",
            .{
                different_pixels,
                maximum_channel_delta,
                first % expected.width,
                first / expected.width,
            },
        );
        std.debug.print("expected: {s}\nactual:   {s}\n", .{ args[1], args[2] });
        return error.ScreenshotMismatch;
    }
}

fn channelDelta(expected: u8, actual: u8) u8 {
    return if (expected >= actual) expected - actual else actual - expected;
}
