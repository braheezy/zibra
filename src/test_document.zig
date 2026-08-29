//! Focused unit-test root for DOM, HTML, CSS, and document data types.

comptime {
    _ = @import("document/canvas.zig");
    _ = @import("document/background_image.zig");
    _ = @import("document/object_fit.zig");
    _ = @import("document/focus.zig");
    _ = @import("tests/parser.zig");
}
