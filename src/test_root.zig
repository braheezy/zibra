//! Unified root for Zibra's existing unit tests.
//!
//! Keeping this root directly under `src` lets subsystem tests import sibling
//! directories without escaping their Zig module path.

comptime {
    _ = @import("browser/render/display_list.zig");
    _ = @import("browser/render/focus_ring.zig");
    _ = @import("browser/render/effects.zig");
    _ = @import("browser/render/compositor_cache.zig");
    _ = @import("browser/render/raster_snapshot.zig");
    _ = @import("browser/render/layout.zig");
    _ = @import("browser/render/replaced_sizing.zig");
    _ = @import("document/canvas.zig");
    _ = @import("document/background_image.zig");
    _ = @import("document/object_fit.zig");
    _ = @import("document/focus.zig");
    _ = @import("script/js.zig");
    _ = @import("tests/browser_input.zig");
    _ = @import("tests/browser_history.zig");
    _ = @import("tests/browser_fragments.zig");
    _ = @import("tests/browser_visited.zig");
    _ = @import("tests/browser_bookmarks.zig");
    _ = @import("tests/display_list_hits.zig");
    _ = @import("tests/browser_windows.zig");
    _ = @import("tests/browser_resize.zig");
    _ = @import("tests/browser_scroll.zig");
    _ = @import("tests/browser_touch.zig");
    _ = @import("tests/browser_timers.zig");
    _ = @import("tests/browser_frame_timing.zig");
    _ = @import("tests/browser_raster_worker.zig");
    _ = @import("tests/browser_canvas.zig");
    _ = @import("tests/browser_background_images.zig");
    _ = @import("tests/browser_lazy_images.zig");
    _ = @import("tests/browser_aspect_ratio.zig");
    _ = @import("tests/browser_dynamic_resources.zig");
    _ = @import("tests/browser_networking.zig");
    _ = @import("tests/browser_security.zig");
    _ = @import("tests/browser_cookies.zig");
    _ = @import("tests/browser_cors.zig");
    _ = @import("tests/browser_post_message.zig");
    _ = @import("tests/browser_referrer.zig");
    _ = @import("tests/parser.zig");
    _ = @import("network/url.zig");
    _ = @import("runtime/task.zig");
    _ = @import("runtime/thread_batch.zig");
}
