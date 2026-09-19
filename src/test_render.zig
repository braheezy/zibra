//! Focused unit-test root for layout, paint, compositing, and hit testing.

comptime {
    _ = @import("browser/render/sticky_position.zig");
    _ = @import("tests/svg_inline.zig");
    _ = @import("browser/render/svg.zig");
    // Filtered pure-layout runs still link libregexp's C object. Keep its
    // host exports reachable even when no JavaScript test is selected.
    _ = @import("kiesel").builtins.reg_exp;
    _ = @import("tests/responsive_layout.zig");
    _ = @import("tests/intrinsic_sizing.zig");
    _ = @import("tests/sizing_allocation.zig");
    _ = @import("tests/shared_sizing_alignment.zig");
    _ = @import("tests/grid_placement.zig");
    _ = @import("tests/atomic_formatting.zig");
    _ = @import("tests/overflow_axes.zig");
    _ = @import("tests/formatting_baselines.zig");
    _ = @import("tests/nested_intrinsic_sizing.zig");
    _ = @import("tests/replaced_image_layout.zig");
    _ = @import("tests/element_geometry.zig");
    _ = @import("tests/css_inspection_render.zig");
    _ = @import("browser/render/display_list.zig");
    _ = @import("browser/software_renderer.zig");
    _ = @import("browser/render/focus_ring.zig");
    _ = @import("browser/render/effects.zig");
    _ = @import("browser/render/compositor_cache.zig");
    _ = @import("browser/render/raster_snapshot.zig");
    _ = @import("browser/render/layout.zig");
    _ = @import("browser/render/table_format.zig");
    _ = @import("browser/render/replaced_sizing.zig");
    _ = @import("tests/display_list_hits.zig");
}
