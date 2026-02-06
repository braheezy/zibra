const std = @import("std");
const browser_mod = @import("browser.zig");
const url_module = @import("url.zig");
const parser = @import("parser.zig");
const Layout = @import("Layout.zig");
const CSSParser = @import("cssParser.zig");
const task = @import("task.zig");
const MeasureTime = @import("measure_time.zig").MeasureTime;
const js_module = @import("js.zig");

const Url = url_module.Url;
const Browser = browser_mod.Browser;
const JsRenderContext = browser_mod.JsRenderContext;
const DisplayItem = browser_mod.DisplayItem;
const AccessibilitySettings = browser_mod.AccessibilitySettings;
const TaskRunner = task.TaskRunner;
const Node = parser.Node;
const Bounds = Layout.Bounds;
const FrameBoundEntry = struct {
    node: *Node,
    bounds: Bounds,
};

/// Represents a composited visual effect update (e.g., opacity change during animation)
pub const CompositedUpdate = struct {
    node: *anyopaque, // Pointer to the element that owns this effect
    opacity: f64, // New opacity value
};

pub const AccessibilityNode = struct {
    role: []const u8,
    name: []const u8,
    bounds: Bounds,
    children: std.ArrayList(*AccessibilityNode),
    dom_node: ?*Node,
    live: ?LiveSetting = null,
    last_announced: ?[]const u8 = null,

    pub fn deinit(self: *AccessibilityNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
    }
};

pub const LiveSetting = enum {
    polite,
    assertive,
};

pub const Frame = struct {
    allocator: std.mem.Allocator,
    tab: *Tab,
    parent: ?*Frame,
    frame_element: ?*Node,
    input_bounds: std.AutoHashMap(*Node, Bounds),
    link_bounds: std.ArrayList(FrameBoundEntry),
    iframe_bounds: std.ArrayList(FrameBoundEntry),
    focus_bounds: std.ArrayList(FrameBoundEntry),
    accessibility_bounds: std.ArrayList(FrameBoundEntry),
    viewport_width: i32 = 0,
    viewport_height: i32 = 0,
    window_id: u32 = 0,
    current_url: ?*Url = null,
    current_url_owned: bool = false,
    current_html_source: ?[]const u8 = null,
    current_node: ?Node = null,
    document_layout: ?*Layout.DocumentLayout = null,
    display_list: ?[]DisplayItem = null,
    content_height: i32 = 0,
    scroll: i32 = 0,
    focus: ?*Node = null,
    js_context: ?*js_module = null,
    js_render_context: JsRenderContext = .{},
    js_render_context_initialized: bool = false,
    rules: std.ArrayList(CSSParser.CSSRule),
    default_rules_count: usize = 0,
    css_texts: std.ArrayList([]const u8),
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
            .css_texts = std.ArrayList([]const u8).empty,
            .children = std.ArrayList(*Frame).empty,
            .input_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
            .link_bounds = std.ArrayList(FrameBoundEntry).empty,
            .iframe_bounds = std.ArrayList(FrameBoundEntry).empty,
            .focus_bounds = std.ArrayList(FrameBoundEntry).empty,
            .accessibility_bounds = std.ArrayList(FrameBoundEntry).empty,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.tab.unregisterFrame(self);
        self.input_bounds.deinit();
        self.link_bounds.deinit(self.allocator);
        self.iframe_bounds.deinit(self.allocator);
        self.focus_bounds.deinit(self.allocator);
        self.accessibility_bounds.deinit(self.allocator);
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);

        if (self.display_list) |items| {
            DisplayItem.freeList(self.allocator, items);
            self.display_list = null;
        }

        if (self.document_layout) |doc| {
            doc.deinit();
            self.allocator.destroy(doc);
            self.document_layout = null;
        }

        if (self.current_node) |node| {
            var n = node;
            n.deinit(self.allocator);
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

    pub fn render(self: *Frame, browser: *Browser, needs_style: bool, needs_layout: bool, needs_paint: bool) !void {
        if (self.current_node == null) return;
        if (needs_style) {
            try parser.style(browser.allocator, &self.current_node.?, self.rules.items);
        }
        if (needs_layout or needs_paint) {
            try browser.layoutTabNodes(self);
        }
    }

    pub fn updateHitTestBounds(self: *Frame, engine: *Layout) !void {
        self.input_bounds.clearRetainingCapacity();
        var input_it = engine.input_bounds.iterator();
        while (input_it.next()) |entry| {
            try self.input_bounds.put(entry.key_ptr.*, entry.value_ptr.*);
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
    }

    pub fn dispatchEvent(self: *Frame, event_type: []const u8, node: *Node) bool {
        const ctx = self.js_context orelse return true;
        return ctx.dispatchEvent(self.window_id, event_type, node) catch |err| blk: {
            std.log.warn("Failed to dispatch {s} event: {}", .{ event_type, err });
            break :blk true;
        };
    }

    pub fn click(self: *Frame, b: *Browser, x: i32, y: i32) !bool {
        for (self.iframe_bounds.items) |entry| {
            const bounds = entry.bounds;
            if (x >= bounds.x and x < bounds.x + bounds.width and
                y >= bounds.y and y < bounds.y + bounds.height)
            {
                if (self.findFrameByElement(entry.node)) |child| {
                    self.tab.focused_frame = child;
                    const child_x = x - bounds.x;
                    const child_y = y - bounds.y + child.scroll;
                    _ = try child.click(b, child_x, child_y);
                }
                return true;
            }
        }

        for (self.link_bounds.items) |entry| {
            const bounds = entry.bounds;
            if (x >= bounds.x and x < bounds.x + bounds.width and
                y >= bounds.y and y < bounds.y + bounds.height)
            {
                const link_node = entry.node;
                const do_default = self.dispatchEvent("click", link_node);
                if (!do_default) return true;

                switch (link_node.*) {
                    .element => |*link_element| {
                        if (link_element.attributes) |attrs| {
                            if (attrs.get("href")) |href| {
                                std.log.info("Link click in window_id={d}: {s}", .{ self.window_id, href });
                                if (self.current_url) |current_url_ptr| {
                                    var resolved_url = try current_url_ptr.*.resolve(self.allocator, href);
                                    const new_url_ptr = self.allocator.create(Url) catch |alloc_err| {
                                        std.log.err("Failed to allocate URL: {any}", .{alloc_err});
                                        resolved_url.free(self.allocator);
                                        return true;
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
                                            return true;
                                        };
                                    } else {
                                        b.scheduleLoad(self.tab, new_url_ptr, null) catch |err| {
                                            std.log.err("Failed to schedule load for {s}: {any}", .{ href, err });
                                            return true;
                                        };
                                    }
                                    url_owned = false;
                                }
                            }
                        }
                    },
                    else => {},
                }
                self.tab.focused_frame = self;
                return true;
            }
        }
        var best_focus: ?struct {
            node: *Node,
            bounds: Bounds,
            priority: u8,
        } = null;

        for (self.focus_bounds.items) |entry| {
            const bounds = entry.bounds;
            if (x < bounds.x or x >= bounds.x + bounds.width or
                y < bounds.y or y >= bounds.y + bounds.height)
            {
                continue;
            }
            var priority: u8 = 0;
            switch (entry.node.*) {
                .element => |e| {
                    if (e.attributes) |attrs| {
                        if (attrs.get("contenteditable") != null) {
                            priority = 3;
                        }
                    }
                    if (std.mem.eql(u8, e.tag, "input") or std.mem.eql(u8, e.tag, "button")) {
                        if (priority < 2) priority = 2;
                    }
                },
                else => {},
            }
            if (priority == 0) continue;

            if (best_focus == null) {
                best_focus = .{ .node = entry.node, .bounds = bounds, .priority = priority };
                continue;
            }
            const best = best_focus.?;
            if (priority > best.priority) {
                best_focus = .{ .node = entry.node, .bounds = bounds, .priority = priority };
                continue;
            }
            if (priority == best.priority) {
                const best_area = best.bounds.width * best.bounds.height;
                const area = bounds.width * bounds.height;
                if (area < best_area) {
                    best_focus = .{ .node = entry.node, .bounds = bounds, .priority = priority };
                }
            }
        }

        if (best_focus) |hit| {
            const node_ptr = hit.node;
            const do_default = self.dispatchEvent("click", node_ptr);
            if (!do_default) return true;
            switch (node_ptr.*) {
                .element => |*e| {
                    if (std.mem.eql(u8, e.tag, "input")) {
                        if (e.attributes) |*attrs| {
                            try attrs.put("value", "");
                        }
                        e.is_focused = true;
                        self.focus = node_ptr;
                        self.tab.focused_frame = self;
                        self.tab.updateAccessibilityFocus(b);
                        self.tab.setNeedsRender();
                        return true;
                    }
                    if (std.mem.eql(u8, e.tag, "button")) {
                        try self.tab.submitForm(b, self, node_ptr);
                        self.tab.focused_frame = self;
                        return true;
                    }
                    e.is_focused = true;
                    self.focus = node_ptr;
                    self.tab.focused_frame = self;
                    self.tab.updateAccessibilityFocus(b);
                    self.tab.setNeedsRender();
                    return true;
                },
                else => {},
            }
        }

        return false;
    }

    pub fn findFrameByElement(self: *Frame, node: *Node) ?*Frame {
        if (self.frame_element == node) return self;
        for (self.children.items) |child| {
            if (child.findFrameByElement(node)) |hit| return hit;
        }
        return null;
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
                const semicolon_trimmed = std.mem.trimRight(u8, origin_token, ";\r\n \t");
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

// Tab represents a single web page
pub const Tab = @This();
// Memory allocator
allocator: std.mem.Allocator,
browser: *Browser,
accessibility: AccessibilitySettings = .{},
// Available height for tab content (window height minus chrome height)
tab_height: i32 = 0,
// History of visited URLs (owns Url pointers)
history: std.ArrayList(*Url),
// Dynamically allocated text strings (e.g., from JavaScript results) that need to be freed
dynamic_texts: std.ArrayList([]const u8),
// JS contexts keyed by origin string
js_contexts: std.StringHashMap(*js_module),
// Context passed to the JS engine for DOM mutation callbacks
js_generation: u64 = 0,
// Root frame for this tab
root_frame: ?*Frame = null,
focused_frame: ?*Frame = null,
frames_by_id: std.AutoHashMap(u32, *Frame),
parent_window_ids: std.AutoHashMap(u32, u32),
next_window_id: u32 = 1,
// Pending asynchronous work for this tab
task_runner: TaskRunner,
async_thread_refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
// Separate dirty flags for render phases
needs_style: bool = true,
needs_layout: bool = true,
needs_paint: bool = true,
scroll_changed_in_tab: bool = false,
// Composited visual effect updates for the current frame
composited_updates: std.ArrayList(CompositedUpdate),
// Root of the accessibility tree
accessibility_root: ?*AccessibilityNode = null,
// Focused accessibility node
accessibility_focused: ?*AccessibilityNode = null,
// Hovered accessibility node (for screen reader hover)
accessibility_hovered: ?*AccessibilityNode = null,
// Pending polite announcements
accessibility_polite_queue: std.ArrayList(*AccessibilityNode),
// Highlighted accessibility node for voice commands
accessibility_highlight: ?*AccessibilityNode = null,
// Owned strings for accessibility names/labels
accessibility_strings: std.ArrayList([]const u8),

pub fn init(allocator: std.mem.Allocator, tab_height: i32, measure: *MeasureTime) Tab {
    return Tab{
        .allocator = allocator,
        .browser = undefined,
        .accessibility = .{ .dark_palette = .{} },
        .tab_height = tab_height,
        .history = std.ArrayList(*Url).empty,
        .dynamic_texts = std.ArrayList([]const u8).empty,
        .js_contexts = std.StringHashMap(*js_module).init(allocator),
        .task_runner = TaskRunner.init(allocator, measure),
        .composited_updates = std.ArrayList(CompositedUpdate).empty,
        .accessibility_root = null,
        .accessibility_focused = null,
        .accessibility_hovered = null,
        .accessibility_polite_queue = std.ArrayList(*AccessibilityNode).empty,
        .accessibility_highlight = null,
        .accessibility_strings = std.ArrayList([]const u8).empty,
        .frames_by_id = std.AutoHashMap(u32, *Frame).init(allocator),
        .parent_window_ids = std.AutoHashMap(u32, u32).init(allocator),
    };
}

pub fn logAccessibilitySettings(self: *const Tab, reason: []const u8) void {
    std.log.info(
        "Accessibility settings ({s}): zoom={d:.2} prefers_dark={} reduce_motion={} screen_reader={}",
        .{
            reason,
            self.accessibility.zoom,
            self.accessibility.prefers_dark,
            self.accessibility.reduce_motion,
            self.accessibility.screen_reader,
        },
    );
}

pub fn setZoom(self: *Tab, zoom: f32) void {
    const clamped = std.math.clamp(zoom, 0.5, 3.0);
    if (self.accessibility.zoom == clamped) return;
    self.accessibility.zoom = clamped;

    // Mark all frame layouts as dirty for layout recalculation
    if (self.root_frame) |frame| {
        markFrameLayoutDirty(frame);
    }

    self.setNeedsRender();
}

fn markFrameLayoutDirty(frame: *Frame) void {
    if (frame.document_layout) |doc| {
        doc.mark();
    }
    for (frame.children.items) |child| {
        markFrameLayoutDirty(child);
    }
}

pub fn adjustZoom(self: *Tab, delta: f32) void {
    self.setZoom(self.accessibility.zoom + delta);
}

/// Start the task runner thread. Must be called after the Tab is in its final memory location.
pub fn start(self: *Tab) !void {
    try self.task_runner.start();
}

pub fn deinit(self: *Tab) void {
    std.debug.print("[TAB.DEINIT] invalidateJsContext\n", .{});
    self.invalidateJsContext();
    std.debug.print("[TAB.DEINIT] waitForAsyncThreads\n", .{});
    self.waitForAsyncThreads();
    std.debug.print("[TAB.DEINIT] task_runner.shutdown\n", .{});
    self.task_runner.shutdown();
    std.debug.print("[TAB.DEINIT] task_runner.shutdown done\n", .{});

    if (self.root_frame) |frame| {
        frame.deinit();
        self.allocator.destroy(frame);
        self.root_frame = null;
    }
    self.frames_by_id.deinit();
    self.parent_window_ids.deinit();

    var js_it = self.js_contexts.iterator();
    while (js_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.deinit(self.allocator);
    }
    self.js_contexts.deinit();

    // Clean up dynamically allocated text strings
    for (self.dynamic_texts.items) |text| {
        self.allocator.free(text);
    }
    self.dynamic_texts.deinit(self.allocator);

    self.clearAccessibilityTree();
    for (self.accessibility_strings.items) |value| {
        self.allocator.free(value);
    }
    self.accessibility_strings.deinit(self.allocator);

    // Clean up history
    for (self.history.items) |url_ptr| {
        url_ptr.*.free(self.allocator);
        self.allocator.destroy(url_ptr);
    }
    self.history.deinit(self.allocator);

    self.task_runner.deinit();
    self.accessibility_polite_queue.deinit(self.allocator);
}

pub fn clearAllowedOrigins(self: *Tab) void {
    if (self.root_frame) |frame| {
        frame.clearAllowedOrigins();
    }
}

pub fn registerFrame(self: *Tab, frame: *Frame) void {
    const id = self.next_window_id;
    self.next_window_id += 1;
    frame.window_id = id;
    self.frames_by_id.put(id, frame) catch {};
}

pub fn unregisterFrame(self: *Tab, frame: *Frame) void {
    if (self.frames_by_id.fetchRemove(frame.window_id)) |_| {}
    _ = self.parent_window_ids.fetchRemove(frame.window_id);
    if (frame.js_context) |ctx| {
        ctx.setParentWindow(frame.window_id, null);
    }
}

fn originKey(self: *Tab, url: *Url) ![]const u8 {
    if (std.mem.eql(u8, url.*.scheme, "file")) {
        return try self.allocator.dupe(u8, "file://");
    }
    if (std.mem.eql(u8, url.*.scheme, "about") or std.mem.eql(u8, url.*.scheme, "data")) {
        return try std.fmt.allocPrint(self.allocator, "{s}:", .{url.*.scheme});
    }
    const host = url.*.host orelse "";
    return try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}", .{ url.*.scheme, host, url.*.port });
}

pub fn get_js(self: *Tab, url: *Url) !*js_module {
    const key = try self.originKey(url);
    if (self.js_contexts.get(key)) |ctx| {
        self.allocator.free(key);
        return ctx;
    }

    const ctx = try js_module.init(self.allocator);
    try self.js_contexts.put(key, ctx);
    return ctx;
}

pub fn frameForWindowId(self: *Tab, window_id: u32) ?*Frame {
    return self.frames_by_id.get(window_id);
}

pub fn setParentWindow(self: *Tab, child_window_id: u32, parent_window_id: ?u32) void {
    if (parent_window_id) |parent_id| {
        self.parent_window_ids.put(child_window_id, parent_id) catch {};
    } else {
        _ = self.parent_window_ids.fetchRemove(child_window_id);
    }
}

pub fn invalidateJsContext(self: *Tab) void {
    self.js_generation +%= 1;
    self.parent_window_ids.clearRetainingCapacity();
    var it = self.frames_by_id.valueIterator();
    while (it.next()) |frame_ptr| {
        frame_ptr.*.js_render_context.setGeneration(self.js_generation);
        frame_ptr.*.js_render_context.setPointers(null, null, null, 0);
        frame_ptr.*.js_render_context_initialized = false;
        if (frame_ptr.*.js_context) |ctx| {
            ctx.setNodes(frame_ptr.*.window_id, null);
        }
    }
}

pub fn retainAsyncThread(self: *Tab) void {
    _ = self.async_thread_refs.fetchAdd(1, .seq_cst);
}

pub fn releaseAsyncThread(self: *Tab) void {
    _ = self.async_thread_refs.fetchSub(1, .seq_cst);
}

fn waitForAsyncThreads(self: *Tab) void {
    while (self.async_thread_refs.load(.seq_cst) != 0) {
        std.Thread.yield() catch {};
    }
}

// Go back in history
pub fn goBack(self: *Tab, b: *Browser) !void {
    if (self.history.items.len > 1) {
        // Remove current page (we already checked length > 1)
        if (self.history.pop()) |current_ptr| {
            current_ptr.*.free(self.allocator);
            self.allocator.destroy(current_ptr);
            if (self.root_frame) |frame| {
                frame.current_url = null;
                frame.current_url_owned = false;
            }
        }
        // Get previous page and load it (which will add it back to history)
        if (self.history.pop()) |back_ptr| {
            b.scheduleLoad(self, back_ptr, null) catch |err| {
                try self.history.append(self.allocator, back_ptr);
                return err;
            };
        }
        try b.draw();
    }
}

pub fn setNeedsRender(self: *Tab) void {
    self.needs_style = true;
    self.needs_layout = true;
    self.needs_paint = true;
    self.browser.setNeedsAnimationFrame(self);
    self.browser.scheduleAnimationFrame();
}

pub fn setNeedsPaint(self: *Tab) void {
    self.needs_paint = true;
    self.browser.setNeedsAnimationFrame(self);
    self.browser.scheduleAnimationFrame();
}

fn refreshFocusState(self: *Tab) !void {
    const frame = self.focused_frame orelse self.root_frame orelse return;
    var frames = std.ArrayList(*Frame).empty;
    defer frames.deinit(self.allocator);
    try self.collectFramesPostOrder(frame, &frames);

    for (frames.items) |target| {
        if (target.focus == null or target.current_node == null) continue;
        var node_list = std.ArrayList(*Node).empty;
        defer node_list.deinit(self.allocator);

        var root_mut = target.current_node.?;
        try parser.treeToList(self.allocator, &root_mut, &node_list);

        var found = false;
        for (node_list.items) |node_ptr| {
            if (node_ptr == target.focus.?) {
                found = true;
                switch (node_ptr.*) {
                    .element => |*e| e.is_focused = true,
                    else => {},
                }
                break;
            }
        }

        if (!found) {
            if (target.focus) |focus_node| {
                switch (focus_node.*) {
                    .element => |*e| e.is_focused = false,
                    else => {},
                }
            }
            target.focus = null;
        }
    }
}

pub fn clampScrollForFrame(self: *Tab, frame: *Frame, scroll: i32) i32 {
    const zoom = if (self.accessibility.zoom > 0) self.accessibility.zoom else 1.0;
    const viewport_height = if (frame.viewport_height > 0) frame.viewport_height else self.tab_height;
    const visible_height = if (zoom == 1.0) viewport_height else @as(i32, @intFromFloat(@as(f32, @floatFromInt(viewport_height)) / zoom));
    const height_delta = frame.content_height - visible_height;
    const maxscroll = if (height_delta > 0) height_delta else 0;
    if (scroll < 0) return 0;
    if (scroll > maxscroll) return maxscroll;
    return scroll;
}

fn collectFramesPostOrder(self: *Tab, frame: *Frame, out: *std.ArrayList(*Frame)) !void {
    for (frame.children.items) |child| {
        try self.collectFramesPostOrder(child, out);
    }
    try out.append(self.allocator, frame);
}

const IframeComposeError = error{OutOfMemory};

fn composeDisplayList(self: *Tab, root: *Frame) IframeComposeError!void {
    const root_list = root.display_list orelse return;
    root.display_list = null;

    var combined = std.ArrayList(DisplayItem).empty;
    defer combined.deinit(self.allocator);

    try self.replaceIframesInList(root, root_list, &combined);
    browser_mod.DisplayItem.freeList(self.allocator, root_list);
    root.display_list = try combined.toOwnedSlice(self.allocator);
}

fn replaceIframesInList(
    self: *Tab,
    root: *Frame,
    items: []DisplayItem,
    out: *std.ArrayList(DisplayItem),
) IframeComposeError!void {
    for (items) |item| {
        switch (item) {
            .iframe => |iframe_item| {
                try self.appendIframeContent(root, .{ .iframe = iframe_item }, out);
            },
            .blend => |blend_item| {
                var children = std.ArrayList(DisplayItem).empty;
                defer children.deinit(self.allocator);
                try self.replaceIframesInList(root, blend_item.children, &children);

                const child_slice = try self.allocator.alloc(DisplayItem, children.items.len);
                @memcpy(child_slice, children.items);

                const mode_copy = if (blend_item.blend_mode) |mode|
                    try self.allocator.dupe(u8, mode)
                else
                    null;

                try out.append(self.allocator, .{
                    .blend = .{
                        .opacity = blend_item.opacity,
                        .blend_mode = mode_copy,
                        .children = child_slice,
                        .node = blend_item.node,
                        .parent = null,
                        .needs_compositing = blend_item.needs_compositing,
                    },
                });
            },
            .transform => |transform_item| {
                var children = std.ArrayList(DisplayItem).empty;
                defer children.deinit(self.allocator);
                try self.replaceIframesInList(root, transform_item.children, &children);

                const child_slice = try self.allocator.alloc(DisplayItem, children.items.len);
                @memcpy(child_slice, children.items);

                try out.append(self.allocator, .{
                    .transform = .{
                        .translate_x = transform_item.translate_x,
                        .translate_y = transform_item.translate_y,
                        .children = child_slice,
                        .node = transform_item.node,
                    },
                });
            },
            else => try out.append(self.allocator, item),
        }
    }
}

fn appendIframeContent(
    self: *Tab,
    root: *Frame,
    iframe_item: DisplayItem,
    out: *std.ArrayList(DisplayItem),
) IframeComposeError!void {
    const border_color = browser_mod.Color{ .r = 0x33, .g = 0x33, .b = 0x33, .a = 0xff };
    const bg_color = browser_mod.Color{ .r = 0xf2, .g = 0xf2, .b = 0xf2, .a = 0xff };

    const iframe_data = iframe_item.iframe;
    try out.append(self.allocator, .{
        .rect = .{
            .x1 = iframe_data.rect.left,
            .y1 = iframe_data.rect.top,
            .x2 = iframe_data.rect.right,
            .y2 = iframe_data.rect.bottom,
            .color = bg_color,
        },
    });

    const child_frame = root.findFrameByElement(iframe_data.node);
    if (child_frame == null or child_frame.?.display_list == null) {
        try out.append(self.allocator, .{
            .outline = .{
                .rect = iframe_data.rect,
                .color = border_color,
                .thickness = 1,
            },
        });
        return;
    }

    child_frame.?.viewport_width = iframe_data.rect.right - iframe_data.rect.left;
    child_frame.?.viewport_height = iframe_data.rect.bottom - iframe_data.rect.top;

    const child_list = child_frame.?.display_list.?;

    var expanded_children = std.ArrayList(DisplayItem).empty;
    defer expanded_children.deinit(self.allocator);
    try self.replaceIframesInList(root, child_list, &expanded_children);
    const expanded_slice = try expanded_children.toOwnedSlice(self.allocator);

    const transform_item = DisplayItem{
        .transform = .{
            .translate_x = iframe_data.rect.left,
            .translate_y = iframe_data.rect.top - child_frame.?.scroll,
            .children = expanded_slice,
            .node = null,
        },
    };
    const mask_item = DisplayItem{
        .rect = .{
            .x1 = iframe_data.rect.left,
            .y1 = iframe_data.rect.top,
            .x2 = iframe_data.rect.right,
            .y2 = iframe_data.rect.bottom,
            .color = browser_mod.Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
        },
    };
    const clip_children = try self.allocator.alloc(DisplayItem, 2);
    clip_children[0] = transform_item;
    clip_children[1] = mask_item;
    const clip_blend_mode = try self.allocator.alloc(u8, 6);
    @memcpy(clip_blend_mode, "dst_in");
    try out.append(self.allocator, .{
        .blend = .{
            .opacity = 1.0,
            .blend_mode = clip_blend_mode,
            .children = clip_children,
            .node = null,
            .needs_compositing = true,
        },
    });

    try out.append(self.allocator, .{
        .outline = .{
            .rect = iframe_data.rect,
            .color = border_color,
            .thickness = 1,
        },
    });
}

// Re-render the page without reloading (style, layout, paint)
pub fn render(self: *Tab, b: *Browser) !void {
    std.debug.print("[TAB] render: style={} layout={} paint={}\n", .{ self.needs_style, self.needs_layout, self.needs_paint });
    // Check if any render phase is needed
    if (!self.needs_style and !self.needs_layout and !self.needs_paint) return;
    std.debug.print("[TAB] render RUNNING\n", .{});

    const profiling = b.profiling_enabled;
    const render_start = if (profiling) std.time.nanoTimestamp() else 0;
    var style_ns: u64 = 0;
    var layout_ns: u64 = 0;

    const trace_render = b.measure.begin("render");
    defer if (trace_render) b.measure.end("render");

    const frame = self.root_frame orelse {
        self.needs_style = false;
        self.needs_layout = false;
        self.needs_paint = false;
        return;
    };
    if (frame.current_node == null) {
        self.needs_style = false;
        self.needs_layout = false;
        self.needs_paint = false;
        return;
    }

    b.layout_engine.accessibility = self.accessibility;
    try self.refreshFocusState();

    // Style phase
    if (self.needs_style) {
        self.needs_style = false;
        errdefer self.needs_style = true;
        const style_start = if (profiling) std.time.nanoTimestamp() else 0;
        var frames = std.ArrayList(*Frame).empty;
        defer frames.deinit(self.allocator);
        try self.collectFramesPostOrder(frame, &frames);
        for (frames.items) |child_frame| {
            try child_frame.render(b, true, false, false);
        }
        if (profiling) {
            style_ns = @as(u64, @intCast(std.time.nanoTimestamp() - style_start));
        }
    }

    // Layout phase (also does paint since they're combined in layoutTabNodes)
    if (self.needs_layout or self.needs_paint) {
        self.needs_layout = false;
        self.needs_paint = false;
        errdefer {
            self.needs_layout = true;
            self.needs_paint = true;
        }
        const layout_start = if (profiling) std.time.nanoTimestamp() else 0;
        var frames = std.ArrayList(*Frame).empty;
        defer frames.deinit(self.allocator);
        try self.collectFramesPostOrder(frame, &frames);
        for (frames.items) |child_frame| {
            try child_frame.render(b, false, true, true);
        }
        std.debug.print("[TAB] render: composeDisplayList\n", .{});
        try self.composeDisplayList(frame);
        std.debug.print("[TAB] render: composeDisplayList done\n", .{});
        if (profiling) {
            layout_ns = @as(u64, @intCast(std.time.nanoTimestamp() - layout_start));
        }
        frame.viewport_height = self.tab_height;
        const clamped_scroll = self.clampScrollForFrame(frame, frame.scroll);
        if (clamped_scroll != frame.scroll) {
            self.scroll_changed_in_tab = true;
            frame.scroll = clamped_scroll;
        }
    }

    std.debug.print("[TAB] render: setNeedsCompositeRasterDraw\n", .{});
    b.setNeedsCompositeRasterDraw();
    std.debug.print("[TAB] render: setNeedsCompositeRasterDraw done\n", .{});

    if (profiling) {
        const total_ns = @as(u64, @intCast(std.time.nanoTimestamp() - render_start));
        std.log.info(
            "profile: render total={}ms style={}ms layout={}ms",
            .{
                @divTrunc(total_ns, 1_000_000),
                @divTrunc(style_ns, 1_000_000),
                @divTrunc(layout_ns, 1_000_000),
            },
        );
    }
    std.debug.print("[TAB] render END\n", .{});
}

pub fn runAnimationFrame(self: *Tab, scroll: i32) void {
    const frame = self.root_frame orelse return;
    var frame_it = self.frames_by_id.valueIterator();
    while (frame_it.next()) |frame_ptr| {
        if (frame_ptr.*.js_render_context_initialized) {
            if (frame_ptr.*.js_context) |ctx| {
                ctx.runAnimationFrameHandlers(frame_ptr.*.window_id);
            }
        }
    }

    if (!self.scroll_changed_in_tab) {
        frame.scroll = scroll;
    }

    // Clear previous frame's composited updates
    self.composited_updates.items.len = 0;

    // Advance CSS transition animations
    var animations_running = false;
    if (frame.current_node) |*root| {
        animations_running = self.advanceAnimations(root);
    }

    // If animations are running, schedule the next frame
    if (animations_running) {
        self.browser.scheduleAnimationFrame();
    }

    // Only run full render if there are non-composited changes
    // Composited-only updates (like opacity) skip layout and paint
    const has_composited_updates = self.composited_updates.items.len > 0;
    const needs_full_render = self.needs_style or self.needs_layout or self.needs_paint;

    if (needs_full_render) {
        self.render(self.browser) catch |err| {
            std.log.warn("Animation frame render failed: {}", .{err});
        };
    }

    var commit_scroll: ?i32 = null;
    if (self.scroll_changed_in_tab) {
        commit_scroll = frame.scroll;
    }

    // Only commit if we have something to send
    if (needs_full_render or has_composited_updates) {
        const commit_data = browser_mod.CommitData{
            .url = frame.current_url orelse null,
            .display_list = frame.display_list,
            .scroll = commit_scroll,
            .height = frame.content_height,
            .zoom = self.accessibility.zoom,
            .prefers_dark = self.accessibility.prefers_dark,
            .composited_updates = self.composited_updates.items,
        };
        frame.display_list = null;
        self.browser.commit(self, commit_data);
    }
    self.scroll_changed_in_tab = false;
}

/// Advance all animations in the node tree, returns true if any animations are still running
fn advanceAnimations(self: *Tab, node: *parser.Node) bool {
    var any_running = false;

    switch (node.*) {
        .element => |*elem| {
            // Advance animations on this element
            if (elem.animations) |*animations| {
                var it = animations.iterator();
                while (it.next()) |entry| {
                    const anim = entry.value_ptr;
                    if (!anim.isComplete()) {
                        _ = anim.advance();
                        any_running = true;

                        // Record composited update for opacity animations
                        if (std.mem.eql(u8, entry.key_ptr.*, "opacity")) {
                            self.composited_updates.append(self.allocator, .{
                                .node = @ptrCast(elem),
                                .opacity = anim.getValue(),
                            }) catch {};
                        }
                    }
                }
            }

            // Recurse into children
            for (elem.children.items) |*child| {
                if (self.advanceAnimations(child)) {
                    any_running = true;
                }
            }
        },
        .text => {},
    }

    return any_running;
}

// Handle click on tab content
pub fn click(self: *Tab, b: *Browser, x: i32, y: i32) !void {
    const frame = self.root_frame orelse return;
    try self.render(b);

    if (self.focused_frame) |focused| {
        if (focused.focus) |focus_node| {
            switch (focus_node.*) {
                .element => |*e| e.is_focused = false,
                else => {},
            }
            focused.focus = null;
        }
    }
    self.focused_frame = frame;

    const handled = try frame.click(b, x, y);
    if (!handled and self.focused_frame != null) {
        self.setNeedsRender();
    }
}

// Submit a form when a button is clicked
fn submitForm(self: *Tab, b: *Browser, frame: *Frame, button_node: *Node) !void {
    // IMPORTANT: We cannot traverse parent pointers here because loadInTab
    // will free the tree, invalidating all pointers. Instead, we search
    // the entire tree from the root to find which form contains this button.

    std.log.info("submitForm called", .{});

    if (frame.current_node == null) {
        std.log.warn("No current_node", .{});
        return;
    }

    // Get all nodes in the tree
    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(self.allocator);
    try parser.treeToList(self.allocator, &frame.current_node.?, &node_list);

    std.log.info("Found {} nodes in tree", .{node_list.items.len});

    // Find all form elements
    for (node_list.items) |node_ptr| {
        switch (node_ptr.*) {
            .element => |e| {
                if (std.mem.eql(u8, e.tag, "form")) {
                    std.log.info("Found form element", .{});
                    // Check if this form contains the button
                    var form_nodes = std.ArrayList(*Node).empty;
                    defer form_nodes.deinit(self.allocator);
                    try parser.treeToList(self.allocator, node_ptr, &form_nodes);

                    std.log.info("Form has {} child nodes", .{form_nodes.items.len});

                    for (form_nodes.items) |form_child| {
                        if (form_child == button_node) {
                            std.log.info("Found button in form!", .{});
                            const do_default = frame.dispatchEvent("submit", node_ptr);
                            if (!do_default) {
                                std.log.info("Default submit prevented", .{});
                                return;
                            }
                            // Found the form containing this button
                            if (e.attributes) |attrs| {
                                if (attrs.get("action")) |action| {
                                    std.log.info("Form action: {s}", .{action});
                                    // Copy the action string before we free the tree
                                    const action_copy = try self.allocator.alloc(u8, action.len);
                                    @memcpy(action_copy, action);
                                    defer self.allocator.free(action_copy);

                                    try self.submitFormData(b, frame, node_ptr, action_copy);
                                    return;
                                }
                            }
                        }
                    }
                }
            },
            .text => {},
        }
    }

    std.log.warn("No form found containing button", .{});
}

// Collect form inputs and submit via POST
fn submitFormData(self: *Tab, b: *Browser, frame: *Frame, form_node: *Node, action: []const u8) !void {
    // Get all descendents of the form
    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(self.allocator);

    try parser.treeToList(self.allocator, form_node, &node_list);

    // Collect all input elements with name attributes
    var inputs = std.ArrayList(*Node).empty;
    defer inputs.deinit(self.allocator);

    for (node_list.items) |node_ptr| {
        switch (node_ptr.*) {
            .element => |e| {
                if (std.mem.eql(u8, e.tag, "input")) {
                    if (e.attributes) |attrs| {
                        if (attrs.get("name")) |_| {
                            try inputs.append(self.allocator, node_ptr);
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Build the form-encoded body
    var body = std.ArrayList(u8).empty;
    defer body.deinit(self.allocator);

    for (inputs.items, 0..) |input_node, i| {
        switch (input_node.*) {
            .element => |e| {
                if (e.attributes) |attrs| {
                    const name = attrs.get("name") orelse continue;
                    const value = attrs.get("value") orelse "";

                    // Add ampersand separator (except for first item)
                    if (i > 0) {
                        try body.append(self.allocator, '&');
                    }

                    // Percent-encode and append name=value
                    try percentEncode(self.allocator, name, &body);
                    try body.append(self.allocator, '=');
                    try percentEncode(self.allocator, value, &body);
                }
            },
            else => {},
        }
    }

    // Get the form body
    const body_slice = try body.toOwnedSlice(self.allocator);
    var body_owned = true;
    defer if (body_owned) {
        self.allocator.free(body_slice);
    };

    // Log the form submission
    std.log.info("Form submission to {s}: {s}", .{ action, body_slice });

    // For file:// URLs, we can't actually submit forms, so just log it
    if (frame.current_url) |url_ptr| {
        if (std.mem.eql(u8, url_ptr.*.scheme, "file")) {
            std.log.info("Skipping form submission for file:// URL", .{});
            return;
        }
    }

    // Resolve the action URL against the current page URL
    var form_url = frame.current_url.?.*.resolve(self.allocator, action) catch |err| {
        std.log.warn("Failed to resolve form action URL: {}", .{err});
        return;
    };

    // Load the URL with the POST body
    const form_url_ptr = b.allocator.create(Url) catch |alloc_err| {
        std.log.err("Failed to allocate form URL: {any}", .{alloc_err});
        form_url.free(self.allocator);
        return;
    };
    form_url_ptr.* = form_url;
    var url_owned = true;
    defer if (url_owned) {
        form_url_ptr.*.free(b.allocator);
        b.allocator.destroy(form_url_ptr);
    };

    if (frame.parent != null) {
        b.scheduleFrameLoad(frame, form_url_ptr, body_slice) catch |err| {
            std.log.err("Failed to submit iframe form: {any}", .{err});
            return;
        };
    } else {
        b.scheduleLoad(self, form_url_ptr, body_slice) catch |err| {
            std.log.err("Failed to submit form: {any}", .{err});
            return;
        };
    }
    url_owned = false;
    body_owned = false;
}

// Cycle focus to the next input element (for Tab key)
fn isTabIndexFocusable(element: *const parser.Element) bool {
    if (element.attributes) |attrs| {
        if (attrs.get("tabindex")) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) return true;
            const idx = std.fmt.parseInt(i32, trimmed, 10) catch return true;
            return idx >= 0;
        }
    }
    return false;
}

fn isElementFocusable(element: *const parser.Element) bool {
    if (std.mem.eql(u8, element.tag, "input") or std.mem.eql(u8, element.tag, "button")) {
        return true;
    }
    if (element.attributes) |attrs| {
        if (attrs.get("contenteditable") != null) {
            return true;
        }
    }
    if (std.mem.eql(u8, element.tag, "a")) {
        if (element.attributes) |attrs| {
            return attrs.get("href") != null or isTabIndexFocusable(element);
        }
    }
    return isTabIndexFocusable(element);
}

fn collectFocusableElements(self: *Tab, frame: *Frame, out: *std.ArrayList(*Node)) !void {
    const root_node = frame.current_node orelse return;

    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(self.allocator);

    var root_mut = root_node;
    try parser.treeToList(self.allocator, &root_mut, &node_list);

    for (node_list.items) |node_ptr| {
        switch (node_ptr.*) {
            .element => |e| {
                if (isElementFocusable(&e)) {
                    try out.append(self.allocator, node_ptr);
                }
            },
            else => {},
        }
    }
}

pub fn cycleFocus(self: *Tab, b: *Browser, reverse: bool) !void {
    const frame = self.focused_frame orelse self.root_frame orelse return;
    var focusables = std.ArrayList(*Node).empty;
    defer focusables.deinit(self.allocator);
    try self.collectFocusableElements(frame, &focusables);
    if (focusables.items.len == 0) return;

    // Clear current focus
    if (frame.focus) |focus_node| {
        switch (focus_node.*) {
            .element => |*e| e.is_focused = false,
            else => {},
        }
    }

    var found_index: ?usize = null;
    if (frame.focus) |current_focus| {
        for (focusables.items, 0..) |elem, i| {
            if (elem == current_focus) {
                found_index = i;
                break;
            }
        }
    }

    const next_index = if (found_index) |i| blk: {
        if (reverse) {
            break :blk if (i == 0) focusables.items.len - 1 else i - 1;
        }
        break :blk (i + 1) % focusables.items.len;
    } else if (reverse) focusables.items.len - 1 else 0;

    const to_focus = focusables.items[next_index];
    switch (to_focus.*) {
        .element => |*e| e.is_focused = true,
        else => {},
    }
    frame.focus = to_focus;
    self.focused_frame = frame;
    self.updateAccessibilityFocus(b);
    b.lock.lock();
    b.focus = "content";
    b.lock.unlock();

    self.setNeedsRender();
}

pub fn activateFocusedElement(self: *Tab, b: *Browser) !void {
    const frame = self.focused_frame orelse self.root_frame orelse return;
    if (frame.focus == null) return;
    const node_ptr = frame.focus.?;

    switch (node_ptr.*) {
        .element => |*e| {
            if (std.mem.eql(u8, e.tag, "input")) {
                if (e.attributes) |attrs| {
                    if (attrs.get("type")) |raw_type| {
                        if (std.mem.eql(u8, raw_type, "submit") or std.mem.eql(u8, raw_type, "button")) {
                            const do_default = frame.dispatchEvent("click", node_ptr);
                            if (!do_default) return;
                            try self.submitForm(b, frame, node_ptr);
                        }
                    }
                }
                return;
            }

            if (std.mem.eql(u8, e.tag, "button")) {
                const do_default = frame.dispatchEvent("click", node_ptr);
                if (!do_default) return;
                try self.submitForm(b, frame, node_ptr);
                return;
            }

            if (std.mem.eql(u8, e.tag, "a")) {
                const do_default = frame.dispatchEvent("click", node_ptr);
                if (!do_default) return;
                if (e.attributes) |attrs| {
                    if (attrs.get("href")) |href| {
                        if (frame.current_url) |current_url_ptr| {
                            const resolved_url = try current_url_ptr.*.resolve(self.allocator, href);
                            const url_ptr = try self.allocator.create(Url);
                            url_ptr.* = resolved_url;
                            if (frame.parent != null) {
                                b.scheduleFrameLoad(frame, url_ptr, null) catch |err| {
                                    std.log.err("Failed to schedule iframe load for {s}: {any}", .{ href, err });
                                    url_ptr.*.free(self.allocator);
                                    self.allocator.destroy(url_ptr);
                                };
                            } else {
                                b.scheduleLoad(self, url_ptr, null) catch |err| {
                                    std.log.err("Failed to schedule load for {s}: {any}", .{ href, err });
                                    url_ptr.*.free(self.allocator);
                                    self.allocator.destroy(url_ptr);
                                };
                            }
                            return;
                        }
                    }
                }
            }

            _ = frame.dispatchEvent("click", node_ptr);
        },
        else => {},
    }
}

// Clear focus (for Escape key)
pub fn clearFocus(self: *Tab, b: *Browser) !void {
    const frame = self.focused_frame orelse self.root_frame orelse return;
    if (frame.focus) |focus_node| {
        switch (focus_node.*) {
            .element => |*e| e.is_focused = false,
            else => {},
        }
        frame.focus = null;
        self.updateAccessibilityFocus(b);
        self.setNeedsRender();
    }
}

// Handle keypress in focused input
pub fn keypress(self: *Tab, b: *Browser, char: u8) !void {
    _ = b;
    const frame = self.focused_frame orelse self.root_frame orelse return;
    if (frame.focus) |focus_node| {
        const do_default = frame.dispatchEvent("keydown", focus_node);
        if (!do_default) {
            std.log.info("Default keydown prevented", .{});
            return;
        }
        switch (focus_node.*) {
            .element => |*e| {
                if (std.mem.eql(u8, e.tag, "input")) {
                    if (e.attributes) |*attrs| {
                        const old_value = attrs.get("value") orelse "";
                        // Append the character
                        var new_value = try self.allocator.alloc(u8, old_value.len + 1);
                        @memcpy(new_value[0..old_value.len], old_value);
                        new_value[old_value.len] = char;
                        try attrs.put("value", new_value);
                        // Track this allocation so we can free it later
                        if (e.owned_strings == null) {
                            e.owned_strings = std.ArrayList([]const u8).empty;
                        }
                        try e.owned_strings.?.append(self.allocator, new_value);
                    }
                    self.setNeedsRender();
                } else if (e.attributes) |*attrs| {
                    if (attrs.get("contenteditable") != null) {
                        var node_list = std.ArrayList(*Node).empty;
                        defer node_list.deinit(self.allocator);
                        try parser.treeToList(self.allocator, focus_node, &node_list);

                        var last_text_node: ?*Node = null;
                        for (node_list.items) |node_ptr| {
                            if (node_ptr.* == .text) {
                                last_text_node = node_ptr;
                            }
                        }

                        const new_text = blk: {
                            if (last_text_node) |text_node| {
                                switch (text_node.*) {
                                    .text => |t| {
                                        const old_text = t.text;
                                        const buffer = try self.allocator.alloc(u8, old_text.len + 1);
                                        @memcpy(buffer[0..old_text.len], old_text);
                                        buffer[old_text.len] = char;
                                        break :blk buffer;
                                    },
                                    else => unreachable,
                                }
                            } else {
                                const buffer = try self.allocator.alloc(u8, 1);
                                buffer[0] = char;
                                break :blk buffer;
                            }
                        };

                        if (e.owned_strings == null) {
                            e.owned_strings = std.ArrayList([]const u8).empty;
                        }
                        try e.owned_strings.?.append(self.allocator, new_text);

                        if (last_text_node) |text_node| {
                            switch (text_node.*) {
                                .text => |*t| t.text = new_text,
                                else => unreachable,
                            }
                        } else {
                            const text_node = Node{ .text = .{
                                .text = new_text,
                                .parent = focus_node,
                            } };
                            try e.children.append(self.allocator, text_node);
                            e.children_dirty = true;
                            parser.fixParentPointers(focus_node, e.parent);
                        }

                        self.setNeedsRender();
                    }
                }
            },
            else => {},
        }
    }
}

// Handle backspace in focused input
pub fn backspace(self: *Tab, b: *Browser) !void {
    _ = b;
    const frame = self.focused_frame orelse self.root_frame orelse return;
    if (frame.focus) |focus_node| {
        switch (focus_node.*) {
            .element => |*e| {
                if (std.mem.eql(u8, e.tag, "input")) {
                    if (e.attributes) |*attrs| {
                        const old_value = attrs.get("value") orelse "";
                        if (old_value.len > 0) {
                            // Remove the last character
                            const new_value = try self.allocator.alloc(u8, old_value.len - 1);
                            @memcpy(new_value, old_value[0 .. old_value.len - 1]);
                            try attrs.put("value", new_value);
                            // Track this allocation
                            if (e.owned_strings == null) {
                                e.owned_strings = std.ArrayList([]const u8).empty;
                            }
                            try e.owned_strings.?.append(self.allocator, new_value);
                        }
                        self.setNeedsRender();
                    }
                }
            },
            else => {},
        }
    }
}

pub fn buildAccessibilityTree(self: *Tab, b: *Browser) !void {
    const previous_root = self.accessibility_root;
    self.accessibility_root = null;

    self.clearAccessibilityTree();
    for (self.accessibility_strings.items) |value| {
        self.allocator.free(value);
    }
    self.accessibility_strings.clearRetainingCapacity();

    const frame = self.root_frame orelse return;
    if (frame.current_node == null) return;

    var bounds_map = std.AutoHashMap(*Node, Bounds).init(self.allocator);
    defer bounds_map.deinit();

    var frames = std.ArrayList(*Frame).empty;
    defer frames.deinit(self.allocator);
    try self.collectFramesPostOrder(frame, &frames);
    for (frames.items) |target_frame| {
        const offset = self.frameOffsetToRoot(target_frame);
        for (target_frame.accessibility_bounds.items) |entry| {
            const adjusted = Bounds{
                .x = entry.bounds.x + offset.x,
                .y = entry.bounds.y + offset.y,
                .width = entry.bounds.width,
                .height = entry.bounds.height,
            };
            if (bounds_map.getPtr(entry.node)) |existing| {
                mergeBounds(existing, adjusted);
            } else {
                try bounds_map.put(entry.node, adjusted);
            }
        }
    }

    var root_children = std.ArrayList(*AccessibilityNode).empty;
    switch (frame.current_node.?) {
        .text => {},
        .element => |*root_element| {
            for (root_element.children.items) |*child| {
                try self.appendAccessibilityNodes(&root_children, child, &bounds_map);
            }
        },
    }

    const root_bounds = Bounds{
        .x = 0,
        .y = 0,
        .width = b.layout_engine.window_width,
        .height = frame.content_height,
    };
    const root_name = try self.copyAccessibilityString("document");
    const root = try self.createAccessibilityNode("document", root_name, root_bounds, null, root_children);
    self.accessibility_root = root;
    self.accessibility_focused = self.findAccessibilityNodeForDom(self.accessibility_root, frame.focus);
    self.accessibility_hovered = null;

    if (previous_root) |old_root| {
        self.handleLiveRegionUpdates(old_root, root);
        old_root.deinit(self.allocator);
        self.allocator.destroy(old_root);
    }
    if (self.accessibility_focused != null and self.accessibility.screen_reader) {
        self.speakAccessibilityNode(self.accessibility_focused.?, "focus");
    }
}

fn createAccessibilityNode(
    self: *Tab,
    role: []const u8,
    name: []const u8,
    bounds: Bounds,
    dom_node: ?*Node,
    children: std.ArrayList(*AccessibilityNode),
) !*AccessibilityNode {
    const node = try self.allocator.create(AccessibilityNode);
    node.* = .{
        .role = role,
        .name = name,
        .bounds = bounds,
        .children = children,
        .dom_node = dom_node,
    };
    return node;
}

fn appendAccessibilityNodes(
    self: *Tab,
    out: *std.ArrayList(*AccessibilityNode),
    node_ptr: *Node,
    bounds_map: *std.AutoHashMap(*Node, Bounds),
) !void {
    switch (node_ptr.*) {
        .text => {},
        .element => |*e| {
            if (isAriaHidden(e)) return;
            if (isPresentationalTag(e.tag)) {
                for (e.children.items) |*child| {
                    try self.appendAccessibilityNodes(out, child, bounds_map);
                }
                return;
            }

            var children = std.ArrayList(*AccessibilityNode).empty;
            if (std.mem.eql(u8, e.tag, "iframe")) {
                if (self.frameForElement(node_ptr)) |child_frame| {
                    if (child_frame.current_node) |*child_root| {
                        switch (child_root.*) {
                            .text => {},
                            .element => |*child_element| {
                                for (child_element.children.items) |*child| {
                                    try self.appendAccessibilityNodes(&children, child, bounds_map);
                                }
                            },
                        }
                    }
                }
            } else {
                for (e.children.items) |*child| {
                    try self.appendAccessibilityNodes(&children, child, bounds_map);
                }
            }

            const role = accessibilityRole(e);
            const name = try self.accessibilityName(node_ptr, e);
            const bounds = bounds_map.get(node_ptr) orelse Bounds{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const node = try self.createAccessibilityNode(role, name, bounds, node_ptr, children);
            node.live = liveSettingFromAttributes(e);
            try out.append(self.allocator, node);
        },
    }
}

fn isPresentationalTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "script") or
        std.mem.eql(u8, tag, "style") or
        std.mem.eql(u8, tag, "head") or
        std.mem.eql(u8, tag, "meta") or
        std.mem.eql(u8, tag, "link") or
        std.mem.eql(u8, tag, "title") or
        std.mem.eql(u8, tag, "br");
}

fn isAriaHidden(element: *const parser.Element) bool {
    if (element.attributes) |attrs| {
        if (attrs.get("aria-hidden")) |value| {
            return std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "true");
        }
    }
    return false;
}

fn accessibilityRole(element: *const parser.Element) []const u8 {
    if (std.mem.eql(u8, element.tag, "a")) return "link";
    if (std.mem.eql(u8, element.tag, "button")) return "button";
    if (std.mem.eql(u8, element.tag, "input")) {
        if (element.attributes) |attrs| {
            if (attrs.get("type")) |raw_type| {
                if (std.mem.eql(u8, raw_type, "submit") or std.mem.eql(u8, raw_type, "button")) {
                    return "button";
                }
            }
        }
        return "textbox";
    }
    if (std.mem.startsWith(u8, element.tag, "h") and element.tag.len == 2) return "heading";
    if (std.mem.eql(u8, element.tag, "p")) return "paragraph";
    if (std.mem.eql(u8, element.tag, "img")) return "img";
    if (std.mem.eql(u8, element.tag, "ul") or std.mem.eql(u8, element.tag, "ol")) return "list";
    if (std.mem.eql(u8, element.tag, "li")) return "listitem";
    if (std.mem.eql(u8, element.tag, "form")) return "form";
    if (std.mem.eql(u8, element.tag, "iframe")) return "iframe";
    return "generic";
}

fn frameForElement(self: *Tab, node: *Node) ?*Frame {
    const root = self.root_frame orelse return null;
    return root.findFrameByElement(node);
}

fn frameOffsetToRoot(self: *Tab, frame: *Frame) struct { x: i32, y: i32 } {
    _ = self;
    var x: i32 = 0;
    var y: i32 = 0;
    var current: *Frame = frame;
    while (current.parent) |parent| {
        if (current.frame_element) |elem| {
            for (parent.iframe_bounds.items) |entry| {
                if (entry.node == elem) {
                    x += entry.bounds.x;
                    y += entry.bounds.y - current.scroll;
                    break;
                }
            }
        }
        current = parent;
    }
    return .{ .x = x, .y = y };
}

fn accessibilityName(self: *Tab, node_ptr: *Node, element: *const parser.Element) ![]const u8 {
    if (element.attributes) |attrs| {
        if (attrs.get("aria-label")) |label| {
            return self.copyAccessibilityString(label);
        }
    }

    if (std.mem.eql(u8, element.tag, "input")) {
        if (element.attributes) |attrs| {
            if (attrs.get("value")) |value| {
                if (value.len > 0) return self.copyAccessibilityString(value);
            }
            if (attrs.get("placeholder")) |placeholder| {
                if (placeholder.len > 0) return self.copyAccessibilityString(placeholder);
            }
        }
        return self.copyAccessibilityString("input");
    }

    if (std.mem.eql(u8, element.tag, "img")) {
        if (element.attributes) |attrs| {
            if (attrs.get("alt")) |alt| {
                if (alt.len > 0) return self.copyAccessibilityString(alt);
            }
        }
        return self.copyAccessibilityString("image");
    }

    if (std.mem.eql(u8, element.tag, "a")) {
        const text = try self.collectText(node_ptr);
        if (text.len > 0) return text;
        if (element.attributes) |attrs| {
            if (attrs.get("href")) |href| {
                if (href.len > 0) return self.copyAccessibilityString(href);
            }
        }
    }

    const text = try self.collectText(node_ptr);
    if (text.len > 0) return text;
    return self.copyAccessibilityString("");
}

fn liveSettingFromAttributes(element: *const parser.Element) ?LiveSetting {
    if (element.attributes) |attrs| {
        if (attrs.get("aria-live")) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "off")) return null;
            if (std.mem.eql(u8, trimmed, "assertive")) return .assertive;
            if (std.mem.eql(u8, trimmed, "polite")) return .polite;
        }
    }
    return null;
}

fn findLiveSettingInTree(node: *AccessibilityNode) ?LiveSetting {
    if (node.live) |setting| return setting;
    for (node.children.items) |child| {
        if (findLiveSettingInTree(child)) |setting| return setting;
    }
    return null;
}

fn collectText(self: *Tab, node_ptr: *Node) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(self.allocator);
    try self.collectTextImpl(node_ptr, &buffer);
    const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
    return self.copyAccessibilityString(trimmed);
}

fn collectTextImpl(self: *Tab, node_ptr: *Node, buffer: *std.ArrayList(u8)) !void {
    switch (node_ptr.*) {
        .text => |t| {
            try buffer.appendSlice(self.allocator, t.text);
        },
        .element => |*e| {
            for (e.children.items) |*child| {
                try self.collectTextImpl(child, buffer);
            }
        },
    }
}

fn copyAccessibilityString(self: *Tab, value: []const u8) ![]const u8 {
    const duped = try self.allocator.alloc(u8, value.len);
    @memcpy(duped, value);
    try self.accessibility_strings.append(self.allocator, duped);
    return duped;
}

fn mergeBounds(existing: *Bounds, incoming: Bounds) void {
    const existing_right = existing.x + existing.width;
    const existing_bottom = existing.y + existing.height;
    const incoming_right = incoming.x + incoming.width;
    const incoming_bottom = incoming.y + incoming.height;
    if (incoming.x < existing.x) existing.x = incoming.x;
    if (incoming.y < existing.y) existing.y = incoming.y;
    const new_right = if (incoming_right > existing_right) incoming_right else existing_right;
    const new_bottom = if (incoming_bottom > existing_bottom) incoming_bottom else existing_bottom;
    existing.width = new_right - existing.x;
    existing.height = new_bottom - existing.y;
}

pub fn accessibilityHitTest(self: *Tab, x: i32, y: i32) ?*AccessibilityNode {
    const root = self.accessibility_root orelse return null;
    return self.hitTestAccessibilityNode(root, x, y);
}

pub fn updateAccessibilityFocus(self: *Tab, b: *Browser) void {
    _ = b;
    const frame = self.focused_frame orelse self.root_frame orelse return;
    self.accessibility_focused = self.findAccessibilityNodeForDom(self.accessibility_root, frame.focus);
    if (self.accessibility_focused != null and self.accessibility.screen_reader) {
        self.speakAccessibilityNode(self.accessibility_focused.?, "focus");
    }
}

pub fn updateAccessibilityHover(self: *Tab, node: ?*AccessibilityNode) void {
    if (self.accessibility_hovered == node) return;
    self.accessibility_hovered = node;
    if (node != null and self.accessibility.screen_reader) {
        self.speakAccessibilityNode(node.?, "hover");
    }
}

fn speakAccessibilityNode(self: *Tab, node: *AccessibilityNode, reason: []const u8) void {
    _ = self;
    var value_buf: [128]u8 = undefined;
    var value_text: []const u8 = "";
    if (node.dom_node) |dom| {
        switch (dom.*) {
            .element => |*e| {
                if (std.mem.eql(u8, e.tag, "input")) {
                    if (e.attributes) |attrs| {
                        if (attrs.get("value")) |val| {
                            value_text = val;
                        }
                    }
                }
            },
            else => {},
        }
    }

    if (value_text.len > 0) {
        const formatted = std.fmt.bufPrint(&value_buf, "{s} {s} value {s}", .{
            node.role,
            node.name,
            value_text,
        }) catch return;
        std.log.info("screen reader {s}: {s}", .{ reason, formatted });
        return;
    }

    if (node.name.len > 0) {
        std.log.info("screen reader {s}: {s} {s}", .{ reason, node.role, node.name });
    } else {
        std.log.info("screen reader {s}: {s}", .{ reason, node.role });
    }
}

fn findLiveSetting(node: *AccessibilityNode) ?LiveSetting {
    if (node.live) |setting| return setting;
    return null;
}

fn handleLiveRegionUpdates(self: *Tab, old_root: *AccessibilityNode, new_root: *AccessibilityNode) void {
    if (!self.accessibility.screen_reader) return;
    self.syncLiveRegionAnnounce(old_root, new_root);
    self.flushPoliteAnnouncements();
}

fn syncLiveRegionAnnounce(self: *Tab, old_node: *AccessibilityNode, new_node: *AccessibilityNode) void {
    const parent_setting = findLiveSetting(new_node);
    self.checkLiveRegionChange(old_node, new_node, parent_setting);
}

fn checkLiveRegionChange(self: *Tab, old_node: *AccessibilityNode, new_node: *AccessibilityNode, live_setting: ?LiveSetting) void {
    if (live_setting) |setting| {
        const old_text = old_node.name;
        const new_text = new_node.name;
        if (!std.mem.eql(u8, old_text, new_text) and new_text.len > 0) {
            if (setting == .assertive) {
                self.accessibility_polite_queue.clearRetainingCapacity();
                self.speakAccessibilityNode(new_node, "assertive");
            } else {
                _ = self.accessibility_polite_queue.append(self.allocator, new_node) catch {};
            }
        }
    }
}

fn syncLiveRegionAnnounceFromParent(
    self: *Tab,
    old_node: *AccessibilityNode,
    new_node: *AccessibilityNode,
    inherited_live: ?LiveSetting,
) void {
    const live_setting = new_node.live orelse inherited_live;
    self.checkLiveRegionChange(old_node, new_node, live_setting);

    const child_count = @min(old_node.children.items.len, new_node.children.items.len);
    var idx: usize = 0;
    while (idx < child_count) : (idx += 1) {
        self.syncLiveRegionAnnounceFromParent(
            old_node.children.items[idx],
            new_node.children.items[idx],
            live_setting,
        );
    }
}

fn flushPoliteAnnouncements(self: *Tab) void {
    for (self.accessibility_polite_queue.items) |node| {
        self.speakAccessibilityNode(node, "polite");
    }
    self.accessibility_polite_queue.clearRetainingCapacity();
}

pub fn readAccessibilityDocument(self: *Tab) void {
    if (!self.accessibility.screen_reader) return;
    const root = self.accessibility_root orelse return;
    self.readAccessibilityNode(root);
}

fn readAccessibilityNode(self: *Tab, node: *AccessibilityNode) void {
    self.speakAccessibilityNode(node, "document");
    for (node.children.items) |child| {
        self.readAccessibilityNode(child);
    }
}

pub fn handleVoiceCommand(self: *Tab, b: *Browser, command: []const u8) void {
    if (self.accessibility_root == null) return;

    if (std.mem.eql(u8, command, "read page")) {
        self.readAccessibilityDocument();
        return;
    }
    if (std.mem.eql(u8, command, "focus next")) {
        self.cycleFocus(b, false) catch |err| {
            std.log.warn("Failed to focus next: {}", .{err});
        };
        return;
    }
    if (std.mem.eql(u8, command, "focus prev")) {
        self.cycleFocus(b, true) catch |err| {
            std.log.warn("Failed to focus previous: {}", .{err});
        };
        return;
    }
    if (std.mem.eql(u8, command, "scroll down")) {
        b.handleScroll(100);
        return;
    }
    if (std.mem.eql(u8, command, "scroll up")) {
        b.handleScroll(-100);
        return;
    }

    if (std.mem.startsWith(u8, command, "click ")) {
        const query = std.mem.trim(u8, command["click ".len..], " \t\r\n");
        if (query.len == 0) return;
        self.commandClick(query);
        return;
    }

    std.log.info("voice command: unknown '{s}'", .{command});
}

fn commandClick(self: *Tab, query: []const u8) void {
    const root = self.accessibility_root orelse return;
    const frame = self.root_frame orelse return;
    if (self.findAccessibilityByName(root, query)) |node| {
        self.accessibility_highlight = node;
        if (node.dom_node) |dom| {
            frame.focus = dom;
            if (frame.focus) |focus_node| {
                switch (focus_node.*) {
                    .element => |*e| e.is_focused = true,
                    else => {},
                }
            }
            self.updateAccessibilityFocus(self.browser);
            self.activateFocusedElement(self.browser) catch |err| {
                std.log.warn("Failed to activate element: {}", .{err});
            };
            self.setNeedsRender();
        }
    } else {
        std.log.info("voice command: no match for '{s}'", .{query});
    }
}

fn findAccessibilityByName(self: *Tab, node: *AccessibilityNode, query: []const u8) ?*AccessibilityNode {
    if (node.name.len > 0 and std.mem.containsAtLeast(u8, node.name, 1, query)) {
        return node;
    }
    for (node.children.items) |child| {
        if (self.findAccessibilityByName(child, query)) |hit| {
            return hit;
        }
    }
    return null;
}

fn hitTestAccessibilityNode(self: *Tab, node: *AccessibilityNode, x: i32, y: i32) ?*AccessibilityNode {
    if (!boundsContains(node.bounds, x, y)) return null;
    for (node.children.items) |child| {
        if (self.hitTestAccessibilityNode(child, x, y)) |hit| {
            return hit;
        }
    }
    return node;
}

fn boundsContains(bounds: Bounds, x: i32, y: i32) bool {
    return x >= bounds.x and x < bounds.x + bounds.width and y >= bounds.y and y < bounds.y + bounds.height;
}

fn findAccessibilityNodeForDom(self: *Tab, root: ?*AccessibilityNode, dom_node: ?*Node) ?*AccessibilityNode {
    const root_node = root orelse return null;
    const target = dom_node orelse return null;
    if (root_node.dom_node == target) return root_node;
    for (root_node.children.items) |child| {
        if (findAccessibilityNodeForDom(self, child, dom_node)) |hit| {
            return hit;
        }
    }
    return null;
}

pub fn dumpAccessibilityTree(self: *Tab) void {
    const root = self.accessibility_root orelse return;
    dumpAccessibilityNode(root, 0);
}

fn dumpAccessibilityNode(node: *AccessibilityNode, indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print("  ", .{});
    }
    std.debug.print(
        "{s} \"{s}\" ({d},{d},{d},{d})\n",
        .{ node.role, node.name, node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height },
    );
    for (node.children.items) |child| {
        dumpAccessibilityNode(child, indent + 1);
    }
}

fn clearAccessibilityTree(self: *Tab) void {
    if (self.accessibility_root) |root| {
        root.deinit(self.allocator);
        self.allocator.destroy(root);
    }
    self.accessibility_root = null;
    self.accessibility_focused = null;
    self.accessibility_hovered = null;
    self.accessibility_polite_queue.clearRetainingCapacity();
    self.accessibility_highlight = null;
}

// Percent-encode a string for use in form data (application/x-www-form-urlencoded)
// Encodes special characters as %XX where XX is the hex code
fn percentEncode(allocator: std.mem.Allocator, input: []const u8, output: *std.ArrayList(u8)) !void {
    for (input) |byte| {
        // Unreserved characters (don't need encoding): A-Z a-z 0-9 - _ . ~
        if ((byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_' or byte == '.' or byte == '~')
        {
            try output.append(allocator, byte);
        } else {
            // Encode as %XX
            const hex = "0123456789ABCDEF";
            try output.append(allocator, '%');
            try output.append(allocator, hex[byte >> 4]);
            try output.append(allocator, hex[byte & 0x0F]);
        }
    }
}
