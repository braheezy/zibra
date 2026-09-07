//! Focused unit-test root for the Kiesel host and DOM-facing JavaScript APIs.

comptime {
    _ = @import("tests/js_gc_threads.zig");
    _ = @import("tests/css_style.zig");
    _ = @import("tests/document_accessors.zig");
    _ = @import("tests/html_fragments.zig");
    _ = @import("tests/character_data.zig");
    _ = @import("tests/referrer_dom.zig");
    _ = @import("kiesel").builtins.reg_exp;
    _ = @import("script/js.zig");
}
