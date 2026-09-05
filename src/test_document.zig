//! Focused unit-test root for DOM, HTML, CSS, and document data types.

comptime {
    _ = @import("tests/css_computed_values.zig");
    _ = @import("document/canvas.zig");
    _ = @import("document/background_image.zig");
    _ = @import("document/html_parser_session.zig");
    _ = @import("document/html_source.zig");
    _ = @import("document/html_tokenizer.zig");
    _ = @import("document/html_live_parser.zig");
    _ = @import("browser/document_loader.zig");
    _ = @import("document/node_pins.zig");
    _ = @import("document/object_fit.zig");
    _ = @import("document/focus.zig");
    _ = @import("tests/parser.zig");
}
