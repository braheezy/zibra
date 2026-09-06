//! Focused unit-test root for the Kiesel host and DOM-facing JavaScript APIs.

comptime {
    _ = @import("tests/js_gc_threads.zig");
    _ = @import("tests/css_style.zig");
    _ = @import("kiesel").builtins.reg_exp;
    _ = @import("script/js.zig");
}
