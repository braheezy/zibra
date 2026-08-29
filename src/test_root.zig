//! Unified root for Zibra's existing unit tests.
//!
//! Keeping this root directly under `src` lets subsystem tests import sibling
//! directories without escaping their Zig module path.

comptime {
    _ = @import("test_document.zig");
    _ = @import("test_render.zig");
    _ = @import("test_network.zig");
    _ = @import("test_script.zig");
    _ = @import("test_browser.zig");
}
