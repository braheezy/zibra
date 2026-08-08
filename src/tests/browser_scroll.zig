//! Unit coverage for the shared page-scroll and scrollbar geometry model.

const std = @import("std");
const scroll = @import("../browser/scroll.zig");

test "short documents hide the scrollbar and clamp to the top" {
    const shorter = scroll.calculate(500, 600, 100, 1.0);
    try std.testing.expect(!shorter.visible);
    try std.testing.expectEqual(@as(i32, 600), shorter.viewport_height_css);
    try std.testing.expectEqual(@as(i32, 0), shorter.max_scroll_css);
    try std.testing.expectEqual(@as(i32, 0), shorter.scroll_css);
    try std.testing.expectEqual(@as(i32, 600), shorter.thumb_height_px);
    try std.testing.expectEqual(@as(i32, 0), shorter.thumb_offset_px);

    const exact_fit = scroll.calculate(600, 600, 0, 1.0);
    try std.testing.expect(!exact_fit.visible);
    try std.testing.expectEqual(@as(i32, 0), exact_fit.max_scroll_css);
}

test "thumb follows the top middle and bottom of a document" {
    const top = scroll.calculate(1200, 600, 0, 1.0);
    try std.testing.expect(top.visible);
    try std.testing.expectEqual(@as(i32, 600), top.max_scroll_css);
    try std.testing.expectEqual(@as(i32, 300), top.thumb_height_px);
    try std.testing.expectEqual(@as(i32, 0), top.thumb_offset_px);

    const middle = scroll.calculate(1200, 600, 300, 1.0);
    try std.testing.expectEqual(@as(i32, 300), middle.scroll_css);
    try std.testing.expectEqual(@as(i32, 150), middle.thumb_offset_px);

    const bottom = scroll.calculate(1200, 600, 999, 1.0);
    try std.testing.expectEqual(@as(i32, 600), bottom.scroll_css);
    try std.testing.expectEqual(@as(i32, 300), bottom.thumb_offset_px);
    try std.testing.expectEqual(bottom.track_height_px, bottom.thumb_offset_px + bottom.thumb_height_px);
}

test "zoom and viewport resize update both range and thumb" {
    const zoomed = scroll.calculate(1000, 600, 350, 2.0);
    try std.testing.expectEqual(@as(i32, 300), zoomed.viewport_height_css);
    try std.testing.expectEqual(@as(i32, 700), zoomed.max_scroll_css);
    try std.testing.expectEqual(@as(i32, 180), zoomed.thumb_height_px);
    try std.testing.expectEqual(@as(i32, 210), zoomed.thumb_offset_px);

    const narrow_viewport = scroll.calculate(1000, 400, 600, 1.0);
    try std.testing.expectEqual(@as(i32, 600), narrow_viewport.max_scroll_css);
    try std.testing.expectEqual(@as(i32, 160), narrow_viewport.thumb_height_px);

    const tall_viewport = scroll.calculate(1000, 800, 600, 1.0);
    try std.testing.expectEqual(@as(i32, 200), tall_viewport.scroll_css);
    try std.testing.expectEqual(@as(i32, 640), tall_viewport.thumb_height_px);
    try std.testing.expectEqual(@as(i32, 160), tall_viewport.thumb_offset_px);
}

test "geometry remains bounded for extreme and invalid inputs" {
    const huge = scroll.calculate(std.math.maxInt(i32), 600, std.math.maxInt(i32), 1.0);
    try std.testing.expect(huge.visible);
    try std.testing.expectEqual(@as(i32, 1), huge.thumb_height_px);
    try std.testing.expect(huge.thumb_offset_px >= 0);
    try std.testing.expect(huge.thumb_offset_px + huge.thumb_height_px <= huge.track_height_px);

    const invalid_zoom = scroll.calculate(1000, 600, -100, 0.0);
    try std.testing.expectEqual(@as(i32, 600), invalid_zoom.viewport_height_css);
    try std.testing.expectEqual(@as(i32, 0), invalid_zoom.scroll_css);

    const empty_track = scroll.calculate(1000, -10, 500, 1.0);
    try std.testing.expect(!empty_track.visible);
    try std.testing.expectEqual(@as(i32, 0), empty_track.track_height_px);
    try std.testing.expectEqual(@as(i32, 0), empty_track.thumb_height_px);
}
