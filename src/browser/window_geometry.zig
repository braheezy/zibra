//! Pure native-window and content-surface geometry derivation.

const std = @import("std");
const scroll = @import("scroll.zig");

pub const ResizeGeometry = struct {
    window_width: i32,
    window_height: i32,
    tab_viewport_height: i32,
    tab_surface_height: ?i32,
};

pub fn resize(
    window_width: i32,
    window_height: i32,
    chrome_height: i32,
    content_height: i32,
    zoom: f32,
    has_tab_surface: bool,
) ?ResizeGeometry {
    if (window_width <= 0 or window_height <= 0) return null;

    const viewport_delta = @as(i64, window_height) - @as(i64, chrome_height);
    const viewport_height: i32 = @intCast(std.math.clamp(
        viewport_delta,
        0,
        std.math.maxInt(i32),
    ));
    const scaled_content_height = scroll.scaleCssPx(content_height, zoom);

    return .{
        .window_width = window_width,
        .window_height = window_height,
        .tab_viewport_height = viewport_height,
        .tab_surface_height = if (has_tab_surface)
            scroll.interestSurfaceHeight(
                scaled_content_height,
                viewport_height,
                window_height,
            )
        else
            null,
    };
}
