//! Focused unit-test root for browser, tab, frame, input, and worker behavior.

comptime {
    _ = @import("browser/document_lifecycle.zig");
    _ = @import("tests/browser_lifecycle.zig");
    _ = @import("tests/browser_input.zig");
    _ = @import("tests/browser_history.zig");
    _ = @import("tests/browser_fragments.zig");
    _ = @import("tests/browser_visited.zig");
    _ = @import("tests/browser_bookmarks.zig");
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
    _ = @import("tests/browser_lengths.zig");
    _ = @import("tests/browser_dynamic_resources.zig");
    _ = @import("tests/browser_networking.zig");
    _ = @import("tests/browser_security.zig");
    _ = @import("tests/browser_cookies.zig");
    _ = @import("tests/browser_cors.zig");
    _ = @import("tests/browser_post_message.zig");
    _ = @import("tests/browser_referrer.zig");
    _ = @import("runtime/task.zig");
    _ = @import("runtime/thread_batch.zig");
}
