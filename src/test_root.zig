//! Unified root for Zibra's existing unit tests.
//!
//! Keeping this root directly under `src` lets subsystem tests import sibling
//! directories without escaping their Zig module path.

comptime {
    _ = @import("script/js.zig");
    _ = @import("tests/parser.zig");
    _ = @import("network/url.zig");
    _ = @import("runtime/task.zig");
}
