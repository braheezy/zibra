//! Pure scroll-range and scrollbar-thumb geometry.
//!
//! Document and scroll values use CSS pixels. Viewport and thumb values use
//! native window pixels, with zoom providing the conversion between them.

const std = @import("std");

/// The tab raster cache is deliberately bounded independently of document
/// height. Values in this model are native/device pixels, not CSS pixels.
pub const interest_region_window_multiplier: i32 = 4;

pub const InterestRegion = struct {
    start_px: i32,
    height_px: i32,

    pub fn endPx(self: InterestRegion) i32 {
        return @intCast(@min(
            @as(i64, self.start_px) + @as(i64, self.height_px),
            std.math.maxInt(i32),
        ));
    }

    /// Whether the complete viewport can be copied from this cached region.
    pub fn containsViewport(
        self: InterestRegion,
        scroll_px: i32,
        viewport_height_px: i32,
    ) bool {
        if (self.height_px <= 0) return false;
        const viewport_start = @max(@as(i64, scroll_px), 0);
        const viewport_end = viewport_start + @max(@as(i64, viewport_height_px), 0);
        const region_start = @as(i64, self.start_px);
        const region_end = region_start + @as(i64, self.height_px);
        return viewport_start >= region_start and viewport_end <= region_end;
    }
};

/// Scale a non-negative CSS coordinate into device pixels without allowing an
/// extreme document height or zoom to overflow the renderer's i32 geometry.
pub fn scaleCssPx(value: i32, zoom_value: f32) i32 {
    const safe_value = @max(value, 0);
    const zoom: f32 = if (zoom_value > 0 and std.math.isFinite(zoom_value)) zoom_value else 1.0;
    const scaled = @as(f32, @floatFromInt(safe_value)) * zoom;
    const max_i32_float: f32 = @floatFromInt(std.math.maxInt(i32));
    if (!(scaled < max_i32_float)) return std.math.maxInt(i32);
    return @intFromFloat(scaled);
}

/// Height of the bounded page-raster cache. Short pages use only what they
/// need; long pages cannot allocate more than four native window heights.
pub fn interestSurfaceHeight(
    content_height_px: i32,
    viewport_height_px: i32,
    window_height_px: i32,
) i32 {
    const total_height = @max(@max(content_height_px, viewport_height_px), 1);
    const base_height = @max(@max(window_height_px, viewport_height_px), 1);
    const capacity_i64 = @as(i64, base_height) * interest_region_window_multiplier;
    const capacity: i32 = @intCast(@min(capacity_i64, std.math.maxInt(i32)));
    return @min(total_height, capacity);
}

/// Choose a cache window around the current viewport. Keeping one viewport of
/// pixels behind the scroll position makes small reversals cheap while the
/// remaining cache provides forward scroll headroom.
pub fn calculateInterestRegion(
    content_height_px: i32,
    viewport_height_px: i32,
    window_height_px: i32,
    scroll_px: i32,
) InterestRegion {
    const viewport_height = @max(viewport_height_px, 0);
    const total_height = @max(@max(content_height_px, viewport_height), 1);
    const height = interestSurfaceHeight(total_height, viewport_height, window_height_px);
    const max_scroll = @max(
        @as(i64, total_height) - @as(i64, viewport_height),
        0,
    );
    const clamped_scroll = std.math.clamp(@as(i64, scroll_px), 0, max_scroll);
    const preferred_start = @max(clamped_scroll - @as(i64, viewport_height), 0);
    const max_start = @max(@as(i64, total_height) - @as(i64, height), 0);
    return .{
        .start_px = @intCast(@min(preferred_start, max_start)),
        .height_px = height,
    };
}

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
