//! Pure scroll-range and scrollbar-thumb geometry.
//!
//! Document and scroll values use CSS pixels. Viewport and thumb values use
//! native window pixels, with zoom providing the conversion between them.

const std = @import("std");

pub const Metrics = struct {
    visible: bool,
    viewport_height_css: i32,
    max_scroll_css: i32,
    scroll_css: i32,
    track_height_px: i32,
    thumb_height_px: i32,
    thumb_offset_px: i32,
};

/// Convert a native viewport height to the CSS height visible at `zoom`.
pub fn viewportHeightCss(viewport_height_px: i32, zoom: f32) i32 {
    const safe_height = @max(viewport_height_px, 0);
    const effective_zoom: f64 = if (zoom > 0 and std.math.isFinite(zoom)) zoom else 1.0;
    const css_height = @as(f64, @floatFromInt(safe_height)) / effective_zoom;
    const max_i32_float: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!(css_height < max_i32_float)) return std.math.maxInt(i32);
    return @intFromFloat(css_height);
}

/// Derive the shared scroll range and scrollbar geometry for a frame.
pub fn calculate(
    content_height_css: i32,
    viewport_height_px: i32,
    scroll_css: i32,
    zoom: f32,
) Metrics {
    const content_height = @max(content_height_css, 0);
    const track_height = @max(viewport_height_px, 0);
    const viewport_height = viewportHeightCss(track_height, zoom);
    const max_scroll_i64 = @max(
        @as(i64, content_height) - @as(i64, viewport_height),
        0,
    );
    const max_scroll: i32 = @intCast(@min(max_scroll_i64, std.math.maxInt(i32)));
    const clamped_scroll: i32 = @intCast(std.math.clamp(
        @as(i64, scroll_css),
        0,
        @as(i64, max_scroll),
    ));
    const visible = max_scroll > 0 and track_height > 0;

    if (!visible) {
        return .{
            .visible = false,
            .viewport_height_css = viewport_height,
            .max_scroll_css = max_scroll,
            .scroll_css = clamped_scroll,
            .track_height_px = track_height,
            .thumb_height_px = track_height,
            .thumb_offset_px = 0,
        };
    }

    const proportional_thumb = @divTrunc(
        @as(i64, track_height) * @as(i64, viewport_height),
        @as(i64, content_height),
    );
    const thumb_height: i32 = @intCast(std.math.clamp(
        proportional_thumb,
        1,
        @as(i64, track_height),
    ));
    const thumb_travel = track_height - thumb_height;
    const thumb_offset: i32 = @intCast(@divTrunc(
        @as(i64, clamped_scroll) * @as(i64, thumb_travel),
        @as(i64, max_scroll),
    ));

    return .{
        .visible = true,
        .viewport_height_css = viewport_height,
        .max_scroll_css = max_scroll,
        .scroll_css = clamped_scroll,
        .track_height_px = track_height,
        .thumb_height_px = thumb_height,
        .thumb_offset_px = thumb_offset,
    };
}

/// Clamp a requested CSS scroll offset with the same range used for drawing.
pub fn clampOffset(
    content_height_css: i32,
    viewport_height_px: i32,
    scroll_css: i32,
    zoom: f32,
) i32 {
    return calculate(content_height_css, viewport_height_px, scroll_css, zoom).scroll_css;
}
