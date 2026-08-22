//! Stable synchronous host callback context for one JavaScript window.

const std = @import("std");
const js_module = @import("../script/js.zig");

pub const JsRenderContext = struct {
    browser_ptr: ?*anyopaque = null,
    tab_ptr: ?*anyopaque = null,
    js_context: ?*js_module = null,
    window_id: u32 = 0,
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn setPointers(
        self: *JsRenderContext,
        browser_ptr: ?*anyopaque,
        tab_ptr: ?*anyopaque,
        js_context: ?*js_module,
        window_id: u32,
    ) void {
        self.browser_ptr = browser_ptr;
        self.tab_ptr = tab_ptr;
        self.js_context = js_context;
        self.window_id = window_id;
    }

    pub fn setGeneration(self: *JsRenderContext, generation: u64) void {
        self.generation.store(generation, .seq_cst);
    }

    pub fn currentGeneration(self: *const JsRenderContext) u64 {
        return self.generation.load(.seq_cst);
    }

    pub fn matchesGeneration(self: *const JsRenderContext, expected: u64) bool {
        return self.currentGeneration() == expected;
    }
};
