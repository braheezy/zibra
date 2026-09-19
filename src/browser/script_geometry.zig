//! Generation-checked, synchronous layout readback from the Tab worker.
//! This adapter never evaluates script or commits/presents a frame. The
//! existing frame layout path also refreshes retained paint/interaction data;
//! those coupled layout products must remain coherent after a script read.
const std = @import("std");
const JsRenderContext = @import("js_context.zig").JsRenderContext;
const Tab = @import("tab.zig").Tab;
const geometry = @import("render/element_geometry.zig");
const bindings = @import("../script/geometry_bindings.zig");
const dom = @import("../document/dom.zig");
const box_model = @import("render/box_model.zig");

pub fn Callbacks(comptime Browser: type) type {
    return struct {
        /// Under JsLock on the serialized worker. Re-resolve the numeric Node
        /// identity after flushing; copy only numbers into caller-owned output.
        pub fn measure(context: ?*anyopaque, handle: u32, query: bindings.Query, allocator: std.mem.Allocator, out: *bindings.Result) anyerror!void {
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
            if (query == .scroll_metrics or query == .scroll_set) {
                if (target.* != .element) return;
                const element = &target.element;
                const root = target == document.node_ptr;
                const scale: f64 = frame.inherited_css_zoom * (if (root) @as(f32, 1) else box_model.effectiveCssZoomForNode(target));
                const metrics = try geometry.measureMetrics(document, target, frame.inherited_css_zoom, .{ .width = @floatFromInt(document.scrollport_width), .height = @floatFromInt(document.scrollport_height) }, allocator);
                if (!root and !metrics.has_box) return;
                if (query == .scroll_set) {
                    const current_x = if (root) frame.scroll_x else element.scroll_x;
                    const current_y = if (root) frame.scroll else element.scroll_y;
                    const x = scrollCoordinate(out.scroll_x, current_x, scale, out.scroll_relative);
                    const y = scrollCoordinate(out.scroll_y, current_y, scale, out.scroll_relative);
                    const moved = if (root) changed: {
                        const next = tab.clampScrollForFrame(frame, y);
                        const next_x = tab.clampScrollXForFrame(frame, x);
                        if (next == frame.scroll and next_x == frame.scroll_x) break :changed false;
                        frame.scroll = next;
                        frame.scroll_x = next_x;
                        if (frame.parent == null) tab.scroll_changed_in_tab = true;
                        break :changed true;
                    } else element.scrollTo(x, y);
                    if (moved) {
                        dom.markPaintForElement(element);
                        _ = frame.updateSticky();
                        tab.setNeedsPaint();
                    }
                } else {
                    out.scroll = if (root)
                        .{ @as(f64, @floatFromInt(frame.scroll_x)) / scale, @as(f64, @floatFromInt(frame.scroll)) / scale, @as(f64, @floatFromInt(document.content_width)) / scale, @as(f64, @floatFromInt(document.content_height)) / scale }
                    else
                        .{ @as(f64, @floatFromInt(element.scroll_x)) / scale, @as(f64, @floatFromInt(element.scroll_y)) / scale, @max(metrics.client.width, @as(f64, @floatFromInt(element.scroll_content_width)) / scale), @max(metrics.client.height, @as(f64, @floatFromInt(element.scroll_content_height)) / scale) };
                }
                return;
            }
            if (query == .box_metrics) {
                // The document width excludes both its tutorial inset and the
                // reserved viewport gutter. Add back only the former.
                const viewport = geometry.Rect{
                    .width = @as(f64, @floatFromInt(document.width.get().* + 2 * document.x.get().*)) / frame.inherited_css_zoom,
                    .height = frame.mediaViewportHeightCssPixels(),
                };
                const metrics = try geometry.measureMetrics(document, target, frame.inherited_css_zoom, viewport, allocator);
                out.client = metrics.client;
                out.offset_x = metrics.offset_x;
                out.offset_y = metrics.offset_y;
                if (metrics.offset_parent) |parent| out.offset_parent = try js.captureNodeHandleFromNativeCallback(ctx.window_id, parent);
            } else try geometry.collectScrolled(document, target, frame.inherited_css_zoom, frame.scroll_x, frame.scroll, query == .offset_rects, allocator, &out.rects);
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
            if (frame.updateSticky()) frame.tab.needs_paint = true;
        }
    };
}

fn scrollCoordinate(requested: ?f64, current: i32, scale: f64, relative: bool) i32 {
    const value = requested orelse return current;
    const normalized = if (std.math.isFinite(value)) value else 0;
    return @intFromFloat(std.math.clamp(normalized * scale + (if (relative) @as(f64, @floatFromInt(current)) else 0), std.math.minInt(i32), std.math.maxInt(i32)));
}
