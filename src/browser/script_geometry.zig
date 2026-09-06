//! Generation-checked, synchronous layout readback from the Tab worker.
//! This adapter never evaluates script or commits/presents a frame. The
//! existing frame layout path also refreshes retained paint/interaction data;
//! those coupled layout products must remain coherent after a script read.
const std = @import("std");
const JsRenderContext = @import("js_context.zig").JsRenderContext;
const Tab = @import("tab.zig").Tab;
const geometry = @import("render/element_geometry.zig");

pub fn Callbacks(comptime Browser: type) type {
    return struct {
        /// Under JsLock on the serialized worker. Re-resolve the numeric Node
        /// identity after flushing; copy only numbers into caller-owned output.
        pub fn measure(context: ?*anyopaque, handle: u32, unscaled: bool, allocator: std.mem.Allocator, out: *std.ArrayList(geometry.Rect)) anyerror!void {
            const ctx: *JsRenderContext = @ptrCast(@alignCast(context orelse return));
            const browser: *Browser = @ptrCast(@alignCast(ctx.browser_ptr orelse return));
            const tab: *Tab = @ptrCast(@alignCast(ctx.tab_ptr orelse return));
            const frame = tab.frameForWindowId(ctx.window_id) orelse return;
            if (frame.document_generation == 0 or !ctx.matchesGeneration(frame.document_generation)) return;
            const js = ctx.js_context orelse return;
            _ = tab.applyRequestedViewport();
            try flushAncestors(browser, frame, tab.media_environment_dirty);
            const target = js.resolveAttachedNodeFromNativeCallback(ctx.window_id, handle) orelse return;
            const document = frame.documentLayout() orelse return;
            try geometry.collect(document, target, frame.inherited_css_zoom, frame.scroll, unscaled, allocator, out);
        }

        fn flushAncestors(browser: *Browser, frame: anytype, rebuild_media: bool) anyerror!void {
            if (frame.parent) |parent| try flushAncestors(browser, parent, rebuild_media);
            try browser.refreshFrameStylesheets(frame);
            if (rebuild_media) try browser.rebuildFrameStyleRules(frame);
            try frame.renderStyle(browser);
            if (frame.current_node != null and frame.layoutNeeded()) {
                try browser.layoutTabNodes(frame, false);
                // The subsequent normal render still needs to compose/commit
                // the refreshed frame products. Do not consume that work here.
                frame.tab.needs_paint = true;
            }
        }
    };
}
