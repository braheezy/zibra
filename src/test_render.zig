//! Focused unit-test root for layout, paint, compositing, and hit testing.

comptime {
    _ = @import("browser/render/display_list.zig");
    _ = @import("browser/render/focus_ring.zig");
    _ = @import("browser/render/effects.zig");
    _ = @import("browser/render/compositor_cache.zig");
    _ = @import("browser/render/raster_snapshot.zig");
    _ = @import("browser/render/layout.zig");
    _ = @import("browser/render/table_format.zig");
    _ = @import("browser/render/replaced_sizing.zig");
    _ = @import("tests/display_list_hits.zig");
}
