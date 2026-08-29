//! Per-frame document-generation ownership and browsing-context behavior.
//!
//! A Frame owns its DOM, stylesheet, layout, display-list, focus/hover, and
//! child-frame generations. The generated type accepts only the recursive Tab
//! and Browser types plus the JavaScript event-lock mode; all other dependencies
//! are direct leaf modules.

const std = @import("std");
const url_module = @import("../network/url.zig");
const parser = @import("../document/parser.zig");
const Layout = @import("render/layout.zig");
const CSSParser = @import("../document/css_parser.zig").CSSParser;
const scroll_model = @import("scroll.zig");
const js_module = @import("../script/js.zig");
const JsRenderContext = @import("js_context.zig").JsRenderContext;
const DisplayItem = @import("render/display_list.zig").DisplayItem;
const ProtectedField = @import("../core/protected_field.zig").ProtectedField;
const history = @import("history.zig");

const Url = url_module.Url;
const Node = parser.Node;
const Bounds = Layout.Bounds;
const HistoryNavigation = history.Navigation;
const PreparedHistoryNavigation = history.PreparedNavigation;

pub const ClickButton = enum {
    primary,
    middle,
};

const FrameBoundEntry = struct {
    node: *Node,
    bounds: Bounds,
};

fn isStrictDomDescendant(node: *Node, ancestor: *Node) bool {
    var current = switch (node.*) {
        .element => |element| element.parent,
        .text => |text| text.parent,
    };
    while (current) |candidate| {
        if (candidate == ancestor) return true;
        current = switch (candidate.*) {
            .element => |element| element.parent,
            .text => |text| text.parent,
        };
    }
    return false;
}

fn parentNode(node: *Node) ?*Node {
    return switch (node.*) {
        .element => |element| element.parent,
        .text => |text| text.parent,
    };
}

/// Painted text fragments hover their containing element. Display/layout hit
/// provenance can name either kind of Node, so normalize before retaining a
/// generation-bound target.
fn hoverElementForNode(node: *Node) ?*Node {
    var current: ?*Node = node;
    while (current) |candidate| {
        switch (candidate.*) {
            .element => return candidate,
            .text => |text| current = text.parent,
        }
    }
    return null;
}

fn nodeDepth(node: *Node) usize {
    var depth: usize = 0;
    var current: ?*Node = node;
    while (current) |candidate| : (current = parentNode(candidate)) depth += 1;
    return depth;
}

fn commonDomAncestor(left: *Node, right: *Node) ?*Node {
    var left_node = left;
    var right_node = right;
    var left_depth = nodeDepth(left_node);
    var right_depth = nodeDepth(right_node);
    while (left_depth > right_depth) : (left_depth -= 1) {
        left_node = parentNode(left_node) orelse return null;
    }
    while (right_depth > left_depth) : (right_depth -= 1) {
        right_node = parentNode(right_node) orelse return null;
    }
    while (left_node != right_node) {
        left_node = parentNode(left_node) orelse return null;
        right_node = parentNode(right_node) orelse return null;
    }
    return left_node;
}

/// Toggle one side of a hover-path transition and return the highest changed
/// element. Restyling that element's subtree covers descendant selectors.
fn updateHoverBranch(branch_start: *Node, stop_before: ?*Node, hovered: bool) ?*Node {
    var highest_changed: ?*Node = null;
    var current: ?*Node = branch_start;
    while (current) |candidate| : (current = parentNode(candidate)) {
        if (candidate == stop_before) break;
        switch (candidate.*) {
            .element => |*element| {
                if (element.is_hovered != hovered) {
                    element.is_hovered = hovered;
                    highest_changed = candidate;
                }
            },
            .text => {},
        }
    }
    return highest_changed;
}

fn dirtyHoverBranch(root: ?*Node) void {
    const node = root orelse return;
    parser.dirtyStyleSubtree(node);
    switch (node.*) {
        .element => |*element| parser.dirtyStyleForElement(element),
        .text => {},
    }
}

fn viewportWidthInCssPixels(device_width: i32, zoom_value: f32) f64 {
    const safe_width = @max(device_width, 1);
    const safe_zoom = if (std.math.isFinite(zoom_value) and zoom_value > 0) zoom_value else 1.0;
    return @as(f64, @floatFromInt(safe_width)) / @as(f64, safe_zoom);
}

/// Instantiate the recursive Frame owner without importing the Browser
/// coordinator back into this leaf module.
pub fn FrameType(
    comptime Tab: type,
    comptime Browser: type,
    comptime JsEventAccess: type,
) type {
    return struct {
        const Frame = @This();

        pub const FrameHoverTarget = struct {
            frame: *Frame,
            node: *Node,
        };

        fn markFrameLayoutDirty(frame: *Frame) void {
            if (frame.document.lastValue().*) |document| document.mark();
            for (frame.children.items) |child| markFrameLayoutDirty(child);
        }

        allocator: std.mem.Allocator,
        tab: *Tab,
        parent: ?*Frame,
        frame_element: ?*Node,
        input_bounds: std.AutoHashMap(*Node, Bounds),
        /// Last laid-out document-space boxes for `<img>` nodes. Unloaded images
        /// without authored dimensions retain a one-pixel position anchor so a
        /// scroll can still bring them into the lazy preload region.
        image_bounds: std.AutoHashMap(*Node, Bounds),
        link_bounds: std.ArrayList(FrameBoundEntry),
        iframe_bounds: std.ArrayList(FrameBoundEntry),
        focus_bounds: std.ArrayList(FrameBoundEntry),
        accessibility_bounds: std.ArrayList(FrameBoundEntry),
        fragment_targets: std.ArrayList(Layout.FragmentTarget),
        viewport_width: i32 = 0,
        viewport_height: i32 = 0,
        /// Authored zoom inherited from the containing iframe. Root frames stay
        /// at one; descendant document layout multiplies this with its own DOM.
        inherited_css_zoom: f32 = 1.0,
        window_id: u32 = 0,
        current_url: ?*Url = null,
        current_url_owned: bool = false,
        // True only for a browser-generated document replacing a failed TLS
        // certificate navigation. Root-frame commits use this to suppress the
        // HTTPS padlock while retaining the requested URL in chrome and history.
        certificate_error: bool = false,
        /// Policy received with this document generation. Every navigation and
        /// subresource request originating here consults it before adding Referer.
        referrer_policy: url_module.ReferrerPolicy = .default,
        current_html_source: ?[]const u8 = null,
        current_node: ?Node = null,
        /// A dirty document means computed style has not been republished for the
        /// current DOM/rule generation. Layout consumers may use `get()` only
        /// after the style phase clears this boundary; teardown deliberately uses
        /// `lastValue()` to retire the previous owning layout pointer.
        document: ProtectedField(?*Layout.DocumentLayout),
        display_list: ?[]DisplayItem = null,
        content_height: i32 = 0,
        scroll: i32 = 0,
        // Worker-owned viewport animation. Root-frame steps commit only a new
        // scalar scroll offset; child-frame steps currently require recomposition
        // because iframe placement is encoded in the composed command tree.
        scroll_animation: ?scroll_model.ScrollAnimation = null,
        focus: ?*Node = null,
        // The innermost clicked `overflow: scroll` element. This worker-owned DOM
        // borrow is retired at the same structural-mutation boundary as focus.
        scroll_focus: ?*Node = null,
        // Innermost element under the pointer in this browsing context. A nested
        // iframe hover keeps one target in every Frame along the embedding path.
        // Like focus, this raw DOM borrow is worker-owned and generation-bound.
        hovered_node: ?*Node = null,
        js_context: ?*js_module = null,
        js_render_context: JsRenderContext = .{},
        js_render_context_initialized: bool = false,
        document_generation: u64 = 0,
        rules: std.ArrayList(CSSParser.CSSRule),
        keyframes: std.ArrayList(CSSParser.KeyframesRule),
        default_rules_count: usize = 0,
        // Owned linked and inline author stylesheet buffers in DOM order. Owned
        // rules borrow their property strings from these allocations.
        css_texts: std.ArrayList([]const u8),
        // Structural DOM mutation can add scripts/stylesheets/iframes or remove
        // linked stylesheets and iframe contexts. The next worker-side render
        // rebuilds deferred resources from the final attached DOM generation;
        // iframe removal itself completes synchronously at the mutation boundary.
        resources_dirty: bool = false,
        allowed_origins: ?std.ArrayList([]const u8) = null,
        children: std.ArrayList(*Frame),

        pub fn init(
            allocator: std.mem.Allocator,
            tab: *Tab,
            parent: ?*Frame,
            frame_element: ?*Node,
        ) Frame {
            return .{
                .allocator = allocator,
                .tab = tab,
                .parent = parent,
                .frame_element = frame_element,
                .rules = std.ArrayList(CSSParser.CSSRule).empty,
                .keyframes = std.ArrayList(CSSParser.KeyframesRule).empty,
                .css_texts = std.ArrayList([]const u8).empty,
                .children = std.ArrayList(*Frame).empty,
                .input_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
                .image_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
                .link_bounds = std.ArrayList(FrameBoundEntry).empty,
                .iframe_bounds = std.ArrayList(FrameBoundEntry).empty,
                .focus_bounds = std.ArrayList(FrameBoundEntry).empty,
                .accessibility_bounds = std.ArrayList(FrameBoundEntry).empty,
                .fragment_targets = std.ArrayList(Layout.FragmentTarget).empty,
                .document = ProtectedField(?*Layout.DocumentLayout).init(null),
            };
        }

        pub fn styleNeeded(self: *const Frame) bool {
            return self.document.dirty;
        }

        /// Read the current layout generation. Calling this while style is dirty
        /// is a phase violation and is intentionally rejected by ProtectedField.
        pub fn documentLayout(self: *const Frame) ?*Layout.DocumentLayout {
            return self.document.get().*;
        }

        /// Install an already-computed layout generation and publish a clean
        /// document phase. Tests and Browser.layoutTabNodes use this ownership
        /// transfer rather than writing the pointer directly.
        pub fn setDocumentLayout(self: *Frame, document: ?*Layout.DocumentLayout) void {
            self.document.set(document);
        }

        /// Mark style stale without discarding the last layout generation. A
        /// successful style pass republishes that same owning pointer; resulting
        /// style-field notifications decide whether its geometry is also dirty.
        pub fn markDocumentStyleDirty(self: *Frame) void {
            self.document.mark();
        }

        pub fn updateHoveredNode(self: *Frame, node: ?*Node) bool {
            const target = if (node) |candidate| hoverElementForNode(candidate) else null;
            if (self.hovered_node == target) return false;

            const common = if (self.hovered_node) |previous|
                if (target) |next| commonDomAncestor(previous, next) else null
            else
                null;
            const cleared_root = if (self.hovered_node) |previous|
                updateHoverBranch(previous, common, false)
            else
                null;
            const set_root = if (target) |next|
                updateHoverBranch(next, common, true)
            else
                null;
            self.hovered_node = target;
            dirtyHoverBranch(cleared_root);
            dirtyHoverBranch(set_root);
            const changed = cleared_root != null or set_root != null;
            if (changed) self.markDocumentStyleDirty();
            return changed;
        }

        /// Destroy the last retained layout while its DOM dependencies are still
        /// alive. The field is left clean and null; callers that require a new
        /// style pass must mark it after retirement.
        pub fn destroyDocumentLayout(self: *Frame) void {
            if (self.document.lastValue().*) |document| {
                document.deinit();
                self.allocator.destroy(document);
            }
            self.document.set(null);
        }

        pub fn layoutNeeded(self: *const Frame) bool {
            if (self.current_node == null or self.document.dirty) return false;
            const document = self.document.get().* orelse return true;
            return document.layoutNeeded();
        }

        /// Finish a style pass performed by a navigation path before it enters
        /// Browser.layoutTabNodes directly.
        pub fn publishStyledDocument(self: *Frame) void {
            self.document.set(self.document.lastValue().*);
        }

        /// Width queries in a nested browsing context use that iframe's own CSS
        /// viewport, not the native tab width. The stored geometry already omits
        /// accessibility zoom but includes authored CSS zoom inherited from the
        /// iframe element, so remove only the latter.
        pub fn mediaViewportWidthCssPixels(self: *const Frame) f64 {
            if (self.parent != null and self.viewport_width > 0) {
                const css_zoom = if (std.math.isFinite(self.inherited_css_zoom) and
                    self.inherited_css_zoom > 0)
                    self.inherited_css_zoom
                else
                    1.0;
                return @as(f64, @floatFromInt(self.viewport_width)) /
                    @as(f64, css_zoom);
            }
            return viewportWidthInCssPixels(
                self.tab.tab_width,
                self.tab.accessibility.zoom,
            );
        }

        pub const ViewportChange = struct {
            width_changed: bool,
            height_changed: bool,

            pub fn any(self: ViewportChange) bool {
                return self.width_changed or self.height_changed;
            }
        };

        /// Parent layout publishes iframe geometry during composition. Dirty this
        /// frame and every nested frame before retaining the new viewport so the
        /// follow-up render cannot reuse layout built for the old containing box.
        pub fn updateViewportFromParent(
            self: *Frame,
            width: i32,
            height: i32,
        ) ViewportChange {
            const next_width = @max(width, 0);
            const next_height = @max(height, 0);
            const change = ViewportChange{
                .width_changed = self.viewport_width != next_width,
                .height_changed = self.viewport_height != next_height,
            };
            self.viewport_width = next_width;
            self.viewport_height = next_height;
            if (change.any()) markFrameLayoutDirty(self);
            return change;
        }

        pub fn deinit(self: *Frame) void {
            // A zero generation has never hosted a live JavaScript document. This
            // guard also keeps lightweight Frame-only tests from needing to
            // initialize the Tab-owned interval registry.
            if (self.document_generation != 0) {
                self.tab.clearIntervalsForDocument(self.window_id, self.document_generation);
            }
            if (self.js_context) |ctx| {
                ctx.setNodes(self.window_id, null);
            }
            self.document_generation = 0;
            self.js_render_context.setGeneration(0);
            self.js_render_context.setPointers(null, null, null, 0);
            self.tab.unregisterFrame(self);
            self.js_context = null;
            self.js_render_context_initialized = false;
            self.hovered_node = null;

            // Display-item provenance borrows this frame's layout and DOM. Retire
            // it before any descendant/layout/node generation can be destroyed.
            self.retireDisplayList();

            self.input_bounds.deinit();
            self.image_bounds.deinit();
            self.link_bounds.deinit(self.allocator);
            self.iframe_bounds.deinit(self.allocator);
            self.focus_bounds.deinit(self.allocator);
            self.accessibility_bounds.deinit(self.allocator);
            self.fragment_targets.deinit(self.allocator);
            for (self.children.items) |child| {
                child.deinit();
                self.allocator.destroy(child);
            }
            self.children.deinit(self.allocator);

            self.destroyDocumentLayout();
            self.document.deinit(self.allocator);

            if (self.current_node) |*node| {
                node.deinit(self.allocator);
                self.current_node = null;
            }

            if (self.current_html_source) |source| {
                self.allocator.free(source);
                self.current_html_source = null;
            }

            for (self.rules.items) |*rule| {
                if (rule.owned) {
                    rule.deinit(self.allocator);
                }
            }
            self.rules.deinit(self.allocator);

            for (self.keyframes.items) |*rule| rule.deinit(self.allocator);
            self.keyframes.deinit(self.allocator);

            for (self.css_texts.items) |css_text| {
                self.allocator.free(css_text);
            }
            self.css_texts.deinit(self.allocator);

            self.clearAllowedOrigins();

            if (self.current_url_owned) {
                if (self.current_url) |url_ptr| {
                    url_ptr.*.free(self.allocator);
                    self.allocator.destroy(url_ptr);
                }
            }
            self.current_url = null;
            self.current_url_owned = false;
        }

        pub fn retireDisplayList(self: *Frame) void {
            if (self.display_list) |items| {
                DisplayItem.freeList(self.allocator, items);
                self.display_list = null;
            }
        }

        /// Retire every frame-side structure that borrows DOM or layout identity
        /// before a structural DOM mutation can remove or relocate a Node.
        pub fn retireDomMutationBorrows(self: *Frame, mutation_root: *Node) void {
            if (self.focus) |focus_node| {
                if (isStrictDomDescendant(focus_node, mutation_root)) {
                    switch (focus_node.*) {
                        .element => |*element| {
                            element.is_focused = false;
                            element.is_focus_visible = false;
                            parser.dirtyStyleForElement(element);
                        },
                        .text => {},
                    }
                    self.focus = null;
                }
            }
            if (self.scroll_focus) |scroll_node| {
                if (isStrictDomDescendant(scroll_node, mutation_root)) {
                    self.scroll_focus = null;
                }
            }
            if (self.hovered_node) |hovered_node| {
                if (isStrictDomDescendant(hovered_node, mutation_root)) {
                    _ = self.updateHoveredNode(null);
                }
            }
            self.retireDisplayList();
            self.input_bounds.clearRetainingCapacity();
            self.image_bounds.clearRetainingCapacity();
            self.link_bounds.clearRetainingCapacity();
            self.iframe_bounds.clearRetainingCapacity();
            self.focus_bounds.clearRetainingCapacity();
            self.accessibility_bounds.clearRetainingCapacity();
            self.fragment_targets.clearRetainingCapacity();
        }

        pub fn annotateVisited(self: *Frame, browser: *Browser) !void {
            const root = if (self.current_node) |*node| node else return;
            if (self.current_url) |base_url| {
                try browser.annotateVisitedLinks(root, base_url);
            }
        }

        pub fn renderStyle(self: *Frame, browser: *Browser) !void {
            if (!self.document.dirty) return;
            const root = if (self.current_node) |*node| node else {
                self.publishStyledDocument();
                return;
            };
            // Browser-level focus/paint requests conservatively enter the
            // protected style phase. The DOM summary lets a clean document
            // republish immediately without walking its tree (or rescanning
            // background-image users).
            if (parser.styleTreeNeedsUpdate(root)) {
                try parser.styleWithKeyframes(
                    browser.allocator,
                    root,
                    self.rules.items,
                    self.keyframes.items,
                );
                if (self.current_url) |page_url| {
                    try browser.loadUsedBackgroundImages(self, page_url);
                }
            }
            self.publishStyledDocument();
        }

        pub fn updateHitTestBounds(self: *Frame, engine: *Layout) !void {
            self.input_bounds.clearRetainingCapacity();
            var input_it = engine.input_bounds.iterator();
            while (input_it.next()) |entry| {
                try self.input_bounds.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            self.image_bounds.clearRetainingCapacity();
            var image_it = engine.image_bounds.iterator();
            while (image_it.next()) |entry| {
                try self.image_bounds.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            self.link_bounds.clearRetainingCapacity();
            for (engine.link_bounds.items) |entry| {
                try self.link_bounds.append(self.allocator, .{
                    .node = entry.node,
                    .bounds = entry.bounds,
                });
            }

            self.iframe_bounds.clearRetainingCapacity();
            for (engine.iframe_bounds.items) |entry| {
                try self.iframe_bounds.append(self.allocator, .{
                    .node = entry.node,
                    .bounds = entry.bounds,
                });
            }

            self.focus_bounds.clearRetainingCapacity();
            for (engine.focus_bounds.items) |entry| {
                try self.focus_bounds.append(self.allocator, .{
                    .node = entry.node,
                    .bounds = entry.bounds,
                });
            }

            self.accessibility_bounds.clearRetainingCapacity();
            for (engine.accessibility_bounds.items) |entry| {
                try self.accessibility_bounds.append(self.allocator, .{
                    .node = entry.node,
                    .bounds = entry.bounds,
                });
            }

            self.fragment_targets.clearRetainingCapacity();
            try self.fragment_targets.appendSlice(self.allocator, engine.fragment_targets.items);
        }

        pub fn scrollOffsetForFragment(self: *const Frame, fragment: []const u8) ?i32 {
            if (fragment.len == 0) return 0;
            for (self.fragment_targets.items) |target| {
                const element = switch (target.node.*) {
                    .element => |*value| value,
                    .text => continue,
                };
                const attributes = element.attributes orelse continue;
                const id = attributes.get("id") orelse continue;
                if (url_module.fragmentMatchesId(fragment, id)) {
                    return self.tab.clampScrollForFrame(self, target.y);
                }
            }
            return null;
        }

        pub fn scrollToFragment(self: *Frame, fragment: []const u8) bool {
            const target_scroll = self.scrollOffsetForFragment(fragment) orelse return false;
            self.scroll_animation = null;
            self.scroll = target_scroll;
            self.tab.scroll_changed_in_tab = true;
            return true;
        }

        pub fn navigateSameDocumentHistory(
            self: *Frame,
            b: *Browser,
            resolved_url: Url,
            history_navigation: HistoryNavigation,
        ) !void {
            const fragment = resolved_url.fragment();
            const target_scroll: ?i32 = if (fragment) |value|
                self.scrollOffsetForFragment(value)
            else
                0;

            // Same-document fragment navigations do not pass through loadInTab,
            // but they still create a visited URL entry.
            _ = try b.markVisited(&resolved_url);

            const url_ptr = self.allocator.create(Url) catch |err| {
                resolved_url.free(self.allocator);
                return err;
            };
            url_ptr.* = resolved_url;
            var url_owned = true;
            defer if (url_owned) {
                url_ptr.*.free(self.allocator);
                self.allocator.destroy(url_ptr);
            };

            var prepared_history: ?PreparedHistoryNavigation = null;
            defer if (prepared_history) |*prepared| prepared.deinit(self.allocator);
            if (history_navigation == .push) {
                const current_payload = try self.tab.currentHistoryPayloadForFrame(self);
                prepared_history = try self.tab.prepareHistoryNavigation(
                    self,
                    url_ptr,
                    current_payload,
                    false,
                );
            }

            if (self.current_url_owned) {
                if (self.current_url) |old_url| {
                    old_url.*.free(self.allocator);
                    self.allocator.destroy(old_url);
                }
            }
            self.current_url = url_ptr;
            self.current_url_owned = true;
            url_owned = false;
            if (prepared_history) |*prepared| {
                self.tab.commitPreparedHistoryNavigation(prepared);
            }

            if (target_scroll) |scroll| {
                self.scroll = scroll;
                self.tab.scroll_changed_in_tab = true;
            }
            // A paint commit carries both the new URL and scroll offset to chrome
            // without rebuilding or replacing the document.
            self.tab.setNeedsPaint();
        }

        pub fn followLink(self: *Frame, b: *Browser, href: []const u8, button: ClickButton) !void {
            const current_url_ptr = self.current_url orelse return;
            var resolved_url = try current_url_ptr.*.resolveForNavigation(self.allocator, href);

            if (button == .middle) {
                b.queueNewTab(resolved_url) catch |err| {
                    resolved_url.free(self.allocator);
                    std.log.err("Failed to queue new tab for {s}: {any}", .{ href, err });
                };
                return;
            }

            if (current_url_ptr.*.sameDocument(resolved_url) and resolved_url.fragment() != null) {
                try self.navigateSameDocumentHistory(b, resolved_url, .push);
                return;
            }

            const new_url_ptr = self.allocator.create(Url) catch |alloc_err| {
                std.log.err("Failed to allocate URL: {any}", .{alloc_err});
                resolved_url.free(self.allocator);
                return;
            };
            new_url_ptr.* = resolved_url;
            var url_owned = true;
            defer if (url_owned) {
                new_url_ptr.*.free(self.allocator);
                self.allocator.destroy(new_url_ptr);
            };

            if (self.parent != null) {
                b.scheduleFrameLoad(self, new_url_ptr, null) catch |err| {
                    std.log.err("Failed to schedule iframe load for {s}: {any}", .{ href, err });
                    return;
                };
            } else {
                b.scheduleLoad(self.tab, new_url_ptr, null) catch |err| {
                    std.log.err("Failed to schedule load for {s}: {any}", .{ href, err });
                    return;
                };
            }
            url_owned = false;
        }

        pub fn dispatchEvent(self: *Frame, event_type: []const u8, node: *Node) bool {
            return self.dispatchEventWithBubbles(event_type, node, true);
        }

        pub fn dispatchEventWithBubbles(
            self: *Frame,
            event_type: []const u8,
            node: *Node,
            bubbles: bool,
        ) bool {
            return self.dispatchEventWithAccess(
                event_type,
                node,
                bubbles,
                .acquire_lock,
            );
        }

        pub fn dispatchEventWithAccess(
            self: *Frame,
            event_type: []const u8,
            node: *Node,
            bubbles: bool,
            access: JsEventAccess,
        ) bool {
            const ctx = self.js_context orelse return true;
            const result = switch (access) {
                .acquire_lock => ctx.dispatchEventWithBubbles(
                    self.window_id,
                    event_type,
                    node,
                    bubbles,
                ),
                .native_callback => ctx.dispatchEventWithBubblesFromNativeCallback(
                    self.window_id,
                    event_type,
                    node,
                    bubbles,
                ),
            };
            return result catch |err| blk: {
                std.log.warn("Failed to dispatch {s} event: {}", .{ event_type, err });
                break :blk true;
            };
        }

        /// Dispatch on the actual event target, then recover the node that owns a
        /// browser default action through its stable JavaScript handle. A listener
        /// can move or remove by-value DOM nodes while dispatch is in progress, so
        /// retaining only `default_node` across the callback would be unsafe.
        pub fn dispatchEventForDefault(
            self: *Frame,
            event_type: []const u8,
            target: *Node,
            default_node: *Node,
        ) ?*Node {
            const ctx = self.js_context orelse {
                return if (self.dispatchEvent(event_type, target)) default_node else null;
            };
            const handle = ctx.captureNodeHandle(self.window_id, default_node) catch |err| {
                std.log.warn("Failed to capture {s} default-action target: {}", .{ event_type, err });
                return null;
            };
            if (!self.dispatchEvent(event_type, target)) return null;
            return ctx.resolveAttachedNode(self.window_id, handle);
        }

        const ClickActionKind = enum {
            iframe,
            link,
            input,
            button,
            contenteditable,
        };

        const ClickAction = struct {
            node: *Node,
            kind: ClickActionKind,
        };

        fn clickTarget(node: *Node) ?*Node {
            var current: ?*Node = node;
            while (current) |candidate| {
                switch (candidate.*) {
                    .element => return candidate,
                    .text => |text| current = text.parent,
                }
            }
            return null;
        }

        fn findClickAction(target: *Node, button: ClickButton) ?ClickAction {
            var current: ?*Node = target;
            while (current) |node| {
                switch (node.*) {
                    .element => |element| {
                        if (std.ascii.eqlIgnoreCase(element.tag, "iframe")) {
                            return .{ .node = node, .kind = .iframe };
                        }
                        if (std.ascii.eqlIgnoreCase(element.tag, "a")) {
                            return .{ .node = node, .kind = .link };
                        }
                        if (button == .primary and std.ascii.eqlIgnoreCase(element.tag, "input")) {
                            return .{ .node = node, .kind = .input };
                        }
                        if (button == .primary and std.ascii.eqlIgnoreCase(element.tag, "button")) {
                            return .{ .node = node, .kind = .button };
                        }
                        if (button == .primary) {
                            const is_contenteditable = if (element.attributes) |attributes|
                                attributes.get("contenteditable") != null
                            else
                                false;
                            if (is_contenteditable) {
                                return .{ .node = node, .kind = .contenteditable };
                            }
                        }
                        current = element.parent;
                    },
                    .text => |text| current = text.parent,
                }
            }
            return null;
        }

        fn nearestScrollContainer(target: *Node) ?*Node {
            var current: ?*Node = target;
            while (current) |node| {
                switch (node.*) {
                    .element => |element| {
                        if (element.scroll_container) return node;
                        current = element.parent;
                    },
                    .text => |text| current = text.parent,
                }
            }
            return null;
        }

        /// Focus a primary-click target, then recover it through a stable script
        /// handle because the resulting focus listener may mutate the DOM before
        /// link navigation or form submission continues.
        fn focusPrimaryClickTarget(self: *Frame, b: *Browser, target: *Node) !?*Node {
            const handle = if (self.js_context) |ctx|
                try ctx.captureNodeHandle(self.window_id, target)
            else
                null;

            _ = try self.tab.focusElement(b, self, target);
            if (handle) |stable_handle| {
                const ctx = self.js_context orelse return null;
                return ctx.resolveAttachedNode(self.window_id, stable_handle);
            }
            return target;
        }

        /// Resolve a point only against an already-published generation. This is
        /// called after the render layout phase and deliberately declines to read
        /// a dirty protected document or a retained tree that still needs layout.
        fn hoverHitNodeDevice(
            self: *Frame,
            device_x: i32,
            device_y: i32,
            zoom: f32,
        ) ?*Node {
            if (!self.document.dirty) {
                if (self.document.get().*) |document| {
                    if (!document.layoutNeeded()) {
                        if (document.hitTestDevice(device_x, device_y, zoom)) |hit| {
                            return hoverElementForNode(hit.node);
                        }
                    }
                }
            }

            const items = self.display_list orelse return null;
            const hit = DisplayItem.hitTestDevice(items, device_x, device_y, zoom) orelse return null;
            const node = hit.source.originatingNode() orelse return null;
            return hoverElementForNode(node);
        }

        fn iframeBoundsForNode(self: *const Frame, node: *Node) ?Bounds {
            for (self.iframe_bounds.items) |entry| {
                if (entry.node == node) return entry.bounds;
            }
            return null;
        }

        /// Collect one hovered element per browsing context along an iframe path.
        /// Keeping the host iframe in the parent path makes parent-document
        /// `iframe:hover` and ancestor selectors behave as expected.
        pub fn collectHoverPathDevice(
            self: *Frame,
            device_x: i32,
            device_y: i32,
            zoom: f32,
            path: *std.ArrayList(FrameHoverTarget),
        ) !void {
            const target = self.hoverHitNodeDevice(device_x, device_y, zoom) orelse return;
            try path.append(self.allocator, .{ .frame = self, .node = target });

            const element = switch (target.*) {
                .element => |*value| value,
                .text => return,
            };
            if (!std.ascii.eqlIgnoreCase(element.tag, "iframe")) return;

            const child = self.findFrameByElement(target) orelse return;
            const bounds = self.iframeBoundsForNode(target) orelse return;
            const child_x = device_x -| DisplayItem.scaleLayoutPx(bounds.x, zoom);
            const child_origin_y = bounds.y -| child.scroll;
            const child_y = device_y -| DisplayItem.scaleLayoutPx(child_origin_y, zoom);
            try child.collectHoverPathDevice(child_x, child_y, zoom, path);
        }

        pub fn click(self: *Frame, b: *Browser, x: i32, y: i32, button: ClickButton) !bool {
            const zoom = self.tab.accessibility.zoom;
            return self.clickDevice(
                b,
                DisplayItem.scaleLayoutPx(x, zoom),
                DisplayItem.scaleLayoutPx(y, zoom),
                button,
                zoom,
            );
        }

        pub fn clickDevice(
            self: *Frame,
            b: *Browser,
            device_x: i32,
            device_y: i32,
            button: ClickButton,
            zoom: f32,
        ) !bool {
            const items = self.display_list orelse return false;
            const hit = DisplayItem.hitTestDevice(items, device_x, device_y, zoom) orelse return false;
            const layout_hit = if (!self.document.dirty)
                if (self.document.get().*) |document|
                    if (!document.layoutNeeded())
                        document.hitTestDevice(device_x, device_y, zoom)
                    else
                        null
                else
                    null
            else
                null;
            const hit_node = hit.source.originatingNode() orelse
                if (layout_hit) |result| result.node else return false;
            const target = clickTarget(hit_node) orelse return false;
            const action = findClickAction(target, button);

            if (action) |candidate| {
                if (candidate.kind == .iframe) {
                    const rect = switch (hit.item.*) {
                        .iframe => |iframe_item| iframe_item.rect,
                        else => return true,
                    };
                    if (self.findFrameByElement(candidate.node)) |child| {
                        if (button == .primary) self.tab.focused_frame = child;
                        const child_x = hit.device_x -| DisplayItem.scaleLayoutPx(rect.left, zoom);
                        // Composition applies one translation for
                        // `iframe_top - child_scroll`; scale that combined CSS
                        // offset once so fractional truncation matches the pixels
                        // the user clicked.
                        const child_origin_y = rect.top -| child.scroll;
                        const child_y = hit.device_y -| DisplayItem.scaleLayoutPx(child_origin_y, zoom);
                        _ = try child.clickDevice(b, child_x, child_y, button, zoom);
                    }
                    return true;
                }
            }

            if (button == .primary) {
                self.scroll_focus = nearestScrollContainer(target);
                self.tab.focused_frame = self;
            }

            if (button != .primary) {
                const candidate = action orelse return false;
                const element = &candidate.node.element;
                if (element.attributes) |attributes| {
                    if (attributes.get("href")) |href| {
                        std.log.info("Link click in window_id={d}: {s}", .{ self.window_id, href });
                        try self.followLink(b, href, button);
                    }
                }
                return true;
            }

            const candidate = action orelse {
                _ = self.dispatchEvent("click", target);
                return true;
            };
            const live_node = self.dispatchEventForDefault("click", target, candidate.node) orelse return true;
            const element = switch (live_node.*) {
                .element => |*value| value,
                .text => return true,
            };

            switch (candidate.kind) {
                .iframe => unreachable,
                .link => {
                    const focused_node = try self.focusPrimaryClickTarget(b, live_node) orelse return true;
                    const focused_element = switch (focused_node.*) {
                        .element => |*value| value,
                        .text => return true,
                    };
                    if (focused_element.attributes) |attributes| {
                        if (attributes.get("href")) |href| {
                            std.log.info("Link click in window_id={d}: {s}", .{ self.window_id, href });
                            try self.followLink(b, href, button);
                        }
                    }
                },
                .input => {
                    if (element.isCheckbox()) {
                        _ = try element.toggleChecked();
                    } else if (element.attributes) |*attributes| {
                        try attributes.put("value", "");
                    }
                    _ = try self.tab.focusElement(b, self, live_node);
                },
                .button => {
                    const focused_node = try self.focusPrimaryClickTarget(b, live_node) orelse return true;
                    _ = try self.tab.submitForm(b, self, focused_node);
                },
                .contenteditable => {
                    _ = try self.tab.focusElement(b, self, live_node);
                },
            }
            return true;
        }

        pub fn findFrameByElement(self: *Frame, node: *Node) ?*Frame {
            if (self.frame_element == node) return self;
            for (self.children.items) |child| {
                if (child.findFrameByElement(node)) |hit| return hit;
            }
            return null;
        }

        fn childFrameIndexForWindow(
            self: *Frame,
            window_id: u32,
            first_unbound: usize,
        ) ?usize {
            const registered = self.tab.frameForWindowId(window_id) orelse return null;
            if (registered.parent != self) return null;
            for (self.children.items[first_unbound..], first_unbound..) |child, index| {
                if (child == registered) return index;
            }
            return null;
        }

        fn bindAttachedIframeNodes(self: *Frame, node: *Node, bound_count: *usize) void {
            const element = switch (node.*) {
                .element => |*value| value,
                .text => return,
            };

            if (std.mem.eql(u8, element.tag, "iframe")) {
                if (element.iframe_window_id) |window_id| {
                    if (self.childFrameIndexForWindow(window_id, bound_count.*)) |index| {
                        if (index != bound_count.*) {
                            std.mem.swap(
                                *Frame,
                                &self.children.items[index],
                                &self.children.items[bound_count.*],
                            );
                        }
                        const child = self.children.items[bound_count.*];
                        child.frame_element = node;
                        bound_count.* += 1;
                    } else {
                        // Detached iframes retain their scalar marker so that the
                        // Node can move without touching a dead Frame. Validate it
                        // on every attachment and clear it when that context is no
                        // longer registered beneath this parent.
                        element.iframe_window_id = null;
                    }
                }
            }

            for (element.children.items) |*child| {
                self.bindAttachedIframeNodes(child, bound_count);
            }
        }

        fn containsFrame(ancestor: *Frame, candidate: *Frame) bool {
            var current: ?*Frame = candidate;
            while (current) |frame| : (current = frame.parent) {
                if (frame == ancestor) return true;
            }
            return false;
        }

        /// Rebind child browsing contexts after DOM child arrays move and destroy
        /// contexts whose iframe element is no longer attached. The Element's
        /// numeric window marker moves by value with the DOM node; no stale
        /// frame_element pointer is dereferenced during this pass.
        pub fn reconcileAttachedChildFrames(self: *Frame) void {
            var bound_count: usize = 0;
            if (self.current_node) |*root| {
                self.bindAttachedIframeNodes(root, &bound_count);
            }

            while (self.children.items.len > bound_count) {
                const removed = self.children.pop().?;
                if (self.tab.focused_frame) |focused| {
                    if (containsFrame(removed, focused)) self.tab.focused_frame = self;
                }
                removed.deinit();
                self.allocator.destroy(removed);
            }
        }

        pub fn clearAllowedOrigins(self: *Frame) void {
            if (self.allowed_origins) |*origins| {
                for (origins.items) |origin| {
                    self.allocator.free(origin);
                }
                origins.deinit(self.allocator);
                self.allowed_origins = null;
            }
        }

        fn allocLowercase(self: *Frame, text: []const u8) ![]const u8 {
            const copy = try self.allocator.alloc(u8, text.len);
            for (copy, 0..) |*ch, idx| {
                ch.* = std.ascii.toLower(text[idx]);
            }
            return copy;
        }

        pub fn allowedRequest(self: *Frame, target_url: Url, base_url: ?*const Url) bool {
            var page_url: ?Url = null;
            if (base_url) |base| {
                page_url = base.*;
            } else if (self.current_url) |url_ptr| {
                page_url = url_ptr.*;
            }
            if (page_url) |current| {
                if (current.sameOrigin(target_url)) {
                    return true;
                }
            }

            const origins = self.allowed_origins orelse return true;

            var origin_buffer: [256]u8 = undefined;
            const host = target_url.host orelse return true;
            const origin_str = std.fmt.bufPrint(&origin_buffer, "{s}://{s}:{d}", .{ target_url.scheme, host, target_url.port }) catch return false;

            var lower_buffer: [256]u8 = undefined;
            if (origin_str.len > lower_buffer.len) return false;
            for (origin_str, 0..) |ch, idx| {
                lower_buffer[idx] = std.ascii.toLower(ch);
            }
            const normalized = lower_buffer[0..origin_str.len];

            for (origins.items) |allowed| {
                if (allowed.len == normalized.len and std.mem.eql(u8, allowed, normalized)) {
                    return true;
                }
            }

            return false;
        }

        pub fn applyContentSecurityPolicy(self: *Frame, header: []const u8, base_url: Url) !void {
            const whitespace = " \t\r\n";
            var directives = std.mem.tokenizeScalar(u8, header, ';');
            while (directives.next()) |directive_raw| {
                const trimmed = std.mem.trim(u8, directive_raw, whitespace);
                if (trimmed.len == 0) continue;

                var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');
                const directive_name = tokens.next() orelse continue;
                if (!std.ascii.eqlIgnoreCase(directive_name, "default-src")) continue;

                var origins_list = std.ArrayList([]const u8).empty;
                var assigned = false;
                errdefer {
                    if (!assigned) {
                        for (origins_list.items) |origin| self.allocator.free(origin);
                        origins_list.deinit(self.allocator);
                    }
                }

                while (tokens.next()) |origin_token| {
                    const semicolon_trimmed = std.mem.trimEnd(u8, origin_token, ";\r\n \t");
                    const trimmed_origin = std.mem.trim(u8, semicolon_trimmed, whitespace);
                    if (trimmed_origin.len == 0) continue;

                    if (std.ascii.eqlIgnoreCase(trimmed_origin, "'self'") or
                        std.ascii.eqlIgnoreCase(trimmed_origin, "self"))
                    {
                        if (base_url.host) |host| {
                            const normalized = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}", .{
                                base_url.scheme,
                                host,
                                base_url.port,
                            });
                            defer self.allocator.free(normalized);

                            const lowered = try self.allocLowercase(normalized);
                            try origins_list.append(self.allocator, lowered);
                        }
                        continue;
                    }

                    const origin_url = url_module.Url.init(self.allocator, trimmed_origin) catch |err| {
                        std.log.warn("Failed to parse CSP origin {s}: {}", .{ trimmed_origin, err });
                        continue;
                    };
                    defer origin_url.free(self.allocator);

                    const host = origin_url.host orelse continue;

                    const normalized = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}", .{ origin_url.scheme, host, origin_url.port });
                    defer self.allocator.free(normalized);

                    const lowered = try self.allocLowercase(normalized);
                    try origins_list.append(self.allocator, lowered);
                }

                self.allowed_origins = origins_list;
                assigned = true;
                return;
            }
        }
    };
}
