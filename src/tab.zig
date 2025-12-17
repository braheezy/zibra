const std = @import("std");
const browser_mod = @import("browser.zig");
const url_module = @import("url.zig");
const parser = @import("parser.zig");
const Layout = @import("Layout.zig");
const CSSParser = @import("cssParser.zig");
const task = @import("task.zig");
const MeasureTime = @import("measure_time.zig").MeasureTime;

const Url = url_module.Url;
const Browser = browser_mod.Browser;
const JsRenderContext = browser_mod.JsRenderContext;
const DisplayItem = browser_mod.DisplayItem;
const TaskRunner = task.TaskRunner;
const Node = parser.Node;

// Tab represents a single web page
pub const Tab = @This();
// Memory allocator
allocator: std.mem.Allocator,
browser: *Browser,
// List of items to be displayed
display_list: ?[]DisplayItem = null,
// Current HTML node tree
current_node: ?Node = null,
// Current HTML source (must be kept alive while current_node exists)
current_html_source: ?[]const u8 = null,
// Layout tree for the document
document_layout: ?*Layout.DocumentLayout = null,
// Total height of the content
content_height: i32 = 0,
// Current scroll offset
scroll: i32 = 0,
// Current URL being displayed
current_url: ?*Url = null,
// Available height for tab content (window height minus chrome height)
tab_height: i32 = 0,
// History of visited URLs (owns Url pointers)
history: std.ArrayList(*Url),
// Currently focused input element (if any)
focus: ?*Node = null,
// Cached nodes for re-rendering without reloading
nodes: ?Node = null,
// CSS rules for styling
rules: std.ArrayList(CSSParser.CSSRule),
// Number of default browser rules (these are borrowed, not owned)
default_rules_count: usize = 0,
// CSS text buffers from external stylesheets (need to be freed)
css_texts: std.ArrayList([]const u8),
// Dynamically allocated text strings (e.g., from JavaScript results) that need to be freed
dynamic_texts: std.ArrayList([]const u8),
// Context passed to the JS engine for DOM mutation callbacks
js_render_context: JsRenderContext = .{},
js_render_context_initialized: bool = false,
js_generation: u64 = 0,
// Parsed Content-Security-Policy allowed origins (lowercase origin strings)
allowed_origins: ?std.ArrayList([]const u8) = null,
// Pending asynchronous work for this tab
task_runner: TaskRunner,
async_thread_refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
needs_render: bool = true,
scroll_changed_in_tab: bool = false,

pub fn init(allocator: std.mem.Allocator, tab_height: i32, measure: *MeasureTime) !Tab {
    var tab = Tab{
        .allocator = allocator,
        .browser = undefined,
        .tab_height = tab_height,
        .history = std.ArrayList(*Url).empty,
        .focus = null,
        .nodes = null,
        .rules = std.ArrayList(CSSParser.CSSRule).empty,
        .default_rules_count = 0,
        .css_texts = std.ArrayList([]const u8).empty,
        .dynamic_texts = std.ArrayList([]const u8).empty,
        .js_render_context = .{},
        .js_render_context_initialized = false,
        .task_runner = TaskRunner.init(allocator, measure),
    };
    try tab.task_runner.start();
    return tab;
}

pub fn deinit(self: *Tab) void {
    self.invalidateJsContext();
    self.waitForAsyncThreads();
    self.task_runner.shutdown();

    // Clean up any display list
    if (self.display_list) |list| {
        self.allocator.free(list);
    }

    // Clean up document layout tree
    if (self.document_layout) |doc| {
        doc.deinit();
        self.allocator.destroy(doc);
    }

    // Clean up the current HTML node tree
    if (self.current_node) |node_val| {
        var node = node_val;
        node.deinit(self.allocator);
    }

    // Clean up cached nodes if different from current_node
    if (self.nodes) |node_val| {
        // Only deinit if it's not the same as current_node
        if (self.current_node == null or !std.meta.eql(node_val, self.current_node.?)) {
            var node = node_val;
            Node.deinit(&node, self.allocator);
        }
    }

    // Clean up the current HTML source
    if (self.current_html_source) |source| {
        self.allocator.free(source);
    }

    // Clean up CSS rules
    // First N rules (default_rules_count) are borrowed from Browser - don't free their properties
    // Remaining rules are from external stylesheets - need to free their property hashmaps
    if (self.rules.items.len > self.default_rules_count) {
        for (self.rules.items[self.default_rules_count..]) |*rule| {
            rule.properties.deinit();
        }
    }
    self.rules.deinit(self.allocator);

    // Clean up CSS text buffers from external stylesheets
    for (self.css_texts.items) |css_text| {
        self.allocator.free(css_text);
    }
    self.css_texts.deinit(self.allocator);

    // Clean up dynamically allocated text strings
    for (self.dynamic_texts.items) |text| {
        self.allocator.free(text);
    }
    self.dynamic_texts.deinit(self.allocator);

    if (self.allowed_origins) |origins| {
        for (origins.items) |origin| {
            self.allocator.free(origin);
        }
        var list = origins;
        list.deinit(self.allocator);
        self.allowed_origins = null;
    }

    // Clean up history
    for (self.history.items) |url_ptr| {
        url_ptr.*.free(self.allocator);
        self.allocator.destroy(url_ptr);
    }
    self.history.deinit(self.allocator);

    self.task_runner.deinit();
}

pub fn clearAllowedOrigins(self: *Tab) void {
    if (self.allowed_origins) |origins| {
        for (origins.items) |origin| {
            self.allocator.free(origin);
        }
        var list = origins;
        list.deinit(self.allocator);
        self.allowed_origins = null;
    }
}

fn allocLowercase(self: *Tab, text: []const u8) ![]const u8 {
    const copy = try self.allocator.alloc(u8, text.len);
    for (copy, 0..) |*ch, idx| {
        ch.* = std.ascii.toLower(text[idx]);
    }
    return copy;
}

pub fn allowedRequest(self: *Tab, target_url: Url, base_url: ?*const Url) bool {
    const page_url = base_url orelse self.current_url;
    if (page_url) |current| {
        if (current.*.sameOrigin(target_url)) {
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

pub fn applyContentSecurityPolicy(self: *Tab, header: []const u8, base_url: Url) !void {
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

pub fn invalidateJsContext(self: *Tab) void {
    self.js_generation +%= 1;
    self.js_render_context.setGeneration(self.js_generation);
    self.js_render_context.setPointers(null, null);
    self.js_render_context_initialized = false;
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
            self.current_url = null;
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
    self.needs_render = true;
    self.browser.setNeedsAnimationFrame(self);
    self.browser.scheduleAnimationFrame();
}

fn clampScroll(self: *Tab, scroll: i32) i32 {
    const height_delta = self.content_height - self.tab_height;
    const maxscroll = if (height_delta > 0) height_delta else 0;
    if (scroll < 0) return 0;
    if (scroll > maxscroll) return maxscroll;
    return scroll;
}

// Re-render the page without reloading (style, layout, paint)
pub fn render(self: *Tab, b: *Browser) !void {
    if (!self.needs_render) return;
    self.needs_render = false;
    errdefer self.needs_render = true;
    const trace_render = b.measure.begin("render");
    defer if (trace_render) b.measure.end("render");

    if (self.current_node == null) {
        return;
    }

    // Re-apply styles with current rules
    try parser.style(b.allocator, &self.current_node.?, self.rules.items);

    // Re-layout and paint
    try b.layoutTabNodes(self);
    const clamped_scroll = self.clampScroll(self.scroll);
    if (clamped_scroll != self.scroll) {
        self.scroll_changed_in_tab = true;
        self.scroll = clamped_scroll;
    }
    b.setNeedsRasterAndDraw();
}

pub fn runAnimationFrame(self: *Tab, scroll: i32) void {
    if (self.js_render_context_initialized) {
        self.browser.js_engine.runAnimationFrameHandlers();
    }

    if (!self.scroll_changed_in_tab) {
        self.scroll = scroll;
    }

    self.render(self.browser) catch |err| {
        std.log.warn("Animation frame render failed: {}", .{err});
    };

    var commit_scroll: ?i32 = null;
    if (self.scroll_changed_in_tab) {
        commit_scroll = self.scroll;
    }

    const commit_data = browser_mod.CommitData{
        .url = self.current_url orelse null,
        .display_list = self.display_list,
        .scroll = commit_scroll,
        .height = self.content_height,
    };
    self.display_list = null;
    self.browser.commit(self, commit_data);
    self.scroll_changed_in_tab = false;
}

// Handle click on tab content
pub fn click(self: *Tab, b: *Browser, x: i32, y: i32) !void {
    std.log.info("Tab.click at ({}, {})", .{ x, y });
    try self.render(b);

    // Clear previous focus
    if (self.focus) |focus_node| {
        switch (focus_node.*) {
            .element => |*e| e.is_focused = false,
            else => {},
        }
        self.focus = null;
        self.setNeedsRender();
    }

    // Hit test using the input bounds map from the layout engine
    std.log.info("Checking {} input bounds", .{b.layout_engine.input_bounds.count()});
    var it = b.layout_engine.input_bounds.iterator();
    var handled = false;
    while (it.next()) |entry| {
        const node_ptr = entry.key_ptr.*;
        const bounds = entry.value_ptr.*;

        // Check if click is within this element's bounds
        if (x >= bounds.x and x < bounds.x + bounds.width and
            y >= bounds.y and y < bounds.y + bounds.height)
        {
            // Found the clicked element
            switch (node_ptr.*) {
                .element => |*e| {
                    std.log.info("Clicked element: {s}", .{e.tag});
                    if (std.mem.eql(u8, e.tag, "input")) {
                        std.log.info("Input clicked", .{});
                        const prevent_default = b.js_engine.dispatchEvent("click", node_ptr) catch |err| blk: {
                            std.log.warn("Failed to dispatch click event: {}", .{err});
                            break :blk false;
                        };
                        if (prevent_default) {
                            std.log.info("Default click prevented for input", .{});
                            return;
                        }
                        // Clear the input value when focusing
                        if (e.attributes) |*attrs| {
                            try attrs.put("value", "");
                        }
                        e.is_focused = true;
                        self.focus = node_ptr;
                        self.setNeedsRender();
                        handled = true;
                        break;
                    } else if (std.mem.eql(u8, e.tag, "button")) {
                        std.log.info("Button clicked - calling submitForm", .{});
                        const prevent_default = b.js_engine.dispatchEvent("click", node_ptr) catch |err| blk: {
                            std.log.warn("Failed to dispatch click event: {}", .{err});
                            break :blk false;
                        };
                        if (prevent_default) {
                            std.log.info("Default click prevented for button", .{});
                            return;
                        }
                        // Button clicked - submit the form
                        handled = true;
                        try self.submitForm(b, node_ptr);
                        return;
                    }
                },
                else => {},
            }
        }
    }

    if (!handled) {
        std.log.info("No element clicked, re-rendering", .{});
    }
}

// Submit a form when a button is clicked
fn submitForm(self: *Tab, b: *Browser, button_node: *Node) !void {
    // IMPORTANT: We cannot traverse parent pointers here because loadInTab
    // will free the tree, invalidating all pointers. Instead, we search
    // the entire tree from the root to find which form contains this button.

    std.log.info("submitForm called", .{});

    if (self.current_node == null) {
        std.log.warn("No current_node", .{});
        return;
    }

    // Get all nodes in the tree
    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(self.allocator);
    try parser.treeToList(self.allocator, &self.current_node.?, &node_list);

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
                            const prevent_default = b.js_engine.dispatchEvent("submit", node_ptr) catch |err| blk: {
                                std.log.warn("Failed to dispatch submit event: {}", .{err});
                                break :blk false;
                            };
                            if (prevent_default) {
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

                                    try self.submitFormData(b, node_ptr, action_copy);
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
fn submitFormData(self: *Tab, b: *Browser, form_node: *Node, action: []const u8) !void {
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
    if (self.current_url) |url_ptr| {
        if (std.mem.eql(u8, url_ptr.*.scheme, "file")) {
            std.log.info("Skipping form submission for file:// URL", .{});
            return;
        }
    }

    // Resolve the action URL against the current page URL
    var form_url = self.current_url.?.*.resolve(self.allocator, action) catch |err| {
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

    b.scheduleLoad(self, form_url_ptr, body_slice) catch |err| {
        std.log.err("Failed to submit form: {any}", .{err});
        return;
    };
    url_owned = false;
    body_owned = false;
}

// Cycle focus to the next input element (for Tab key)
pub fn cycleFocus(self: *Tab, b: *Browser) !void {
    _ = b;
    // Find all input elements
    const root_node = self.current_node orelse return;

    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(self.allocator);

    var root_mut = root_node;
    try parser.treeToList(self.allocator, &root_mut, &node_list);

    // Collect all input elements
    var input_elements = std.ArrayList(*Node).empty;
    defer input_elements.deinit(self.allocator);

    for (node_list.items) |node_ptr| {
        switch (node_ptr.*) {
            .element => |e| {
                if (std.mem.eql(u8, e.tag, "input")) {
                    try input_elements.append(self.allocator, node_ptr);
                }
            },
            else => {},
        }
    }

    if (input_elements.items.len == 0) return;

    // Clear current focus
    if (self.focus) |focus_node| {
        switch (focus_node.*) {
            .element => |*e| e.is_focused = false,
            else => {},
        }
    }

    // Find next input to focus
    var next_index: usize = 0;
    if (self.focus) |current_focus| {
        for (input_elements.items, 0..) |elem, i| {
            if (elem == current_focus) {
                next_index = (i + 1) % input_elements.items.len;
                break;
            }
        }
    }

    // Focus the next input element
    const to_focus = input_elements.items[next_index];
    switch (to_focus.*) {
        .element => |*e| e.is_focused = true,
        else => {},
    }
    self.focus = to_focus;

    self.setNeedsRender();
}

// Clear focus (for Escape key)
pub fn clearFocus(self: *Tab, b: *Browser) !void {
    _ = b;
    if (self.focus) |focus_node| {
        switch (focus_node.*) {
            .element => |*e| e.is_focused = false,
            else => {},
        }
        self.focus = null;
        self.setNeedsRender();
    }
}

// Handle keypress in focused input
pub fn keypress(self: *Tab, b: *Browser, char: u8) !void {
    if (self.focus) |focus_node| {
        const prevent_default = b.js_engine.dispatchEvent("keydown", focus_node) catch |err| blk: {
            std.log.warn("Failed to dispatch keydown event: {}", .{err});
            break :blk false;
        };
        if (prevent_default) {
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
                }
            },
            else => {},
        }
    }
}

// Handle backspace in focused input
pub fn backspace(self: *Tab, b: *Browser) !void {
    _ = b;
    if (self.focus) |focus_node| {
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
