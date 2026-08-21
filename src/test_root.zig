//! Unified root for Zibra's existing unit tests.
//!
//! Keeping this root directly under `src` lets subsystem tests import sibling
//! directories without escaping their Zig module path.

comptime {
    _ = @import("browser/render/layout.zig");
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
    _ = @import("tests/browser_dynamic_resources.zig");
    _ = @import("tests/parser.zig");
    _ = @import("network/url.zig");
    _ = @import("runtime/task.zig");
}
