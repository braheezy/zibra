const std = @import("std");
const builtin = @import("builtin");

const token = @import("token.zig");
const font = @import("font.zig");
const Token = token.Token;
const grapheme = @import("grapheme");
const code_point = @import("code_point");
const FontManager = font.FontManager;
const Glyph = font.Glyph;
const FontWeight = font.FontWeight;
const FontSlant = font.FontSlant;
const Url = @import("url.zig").Url;
const Cache = @import("cache.zig").Cache;
const ArrayList = std.ArrayList;
const Layout = @import("Layout.zig");
const parser = @import("parser.zig");
const HTMLParser = parser.HTMLParser;
const Node = parser.Node;
const CSSParser = @import("cssParser.zig").CSSParser;
const sdl = @import("sdl.zig");
const c = sdl.c;
const js_module = @import("js.zig");

const dbg = std.debug.print;

fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

const stdout = std.io.getStdOut().writer();

// Default browser stylesheet - defines default styling for HTML elements
const DEFAULT_STYLE_SHEET = @embedFile("browser.css");

// *********************************************************
// * App Settings
// *********************************************************
const initial_window_width = 800;
const initial_window_height = 600;
pub const h_offset = 13;
pub const v_offset = 18;
const scroll_increment = 100;
pub const scrollbar_width = 10;
// *********************************************************

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

// Display items are the drawing commands emitted by layout.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

// Rectangle helper for layout bounds
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn containsPoint(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }
};

pub const DisplayItem = union(enum) {
    glyph: struct {
        x: i32,
        y: i32,
        glyph: Glyph,
        color: Color,
    },
    rect: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        color: Color,
    },
    line: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        color: Color,
        thickness: i32,
    },
    outline: struct {
        rect: Rect,
        color: Color,
        thickness: i32,
    },
};

// Chrome represents the browser UI (tab bar, buttons, etc.)
pub const Chrome = struct {
    font_size: i32 = 20,
    font_height: i32 = 0,
    padding: i32 = 5,
    tabbar_top: i32 = 0,
    tabbar_bottom: i32 = 0,
    urlbar_top: i32 = 0,
    urlbar_bottom: i32 = 0,
    newtab_rect: Rect = undefined,
    back_rect: Rect = undefined,
    address_rect: Rect = undefined,
    bottom: i32 = 0,
    // Address bar editing state
    focus: ?[]const u8 = null,
    address_bar: std.ArrayList(u8) = undefined,
    allocator: std.mem.Allocator = undefined,
    // Cached URL string for display (owned, must be freed)
    cached_url_str: ?[]u8 = null,
    // Cached display list (owned, must be freed)
    cached_display_list: ?[]DisplayItem = null,

    pub fn init(font_manager: *font.FontManager, window_width: i32, allocator: std.mem.Allocator) !Chrome {
        var chrome = Chrome{
            .address_bar = std.ArrayList(u8).empty,
            .allocator = allocator,
        };

        // Measure font height
        const test_glyph = try font_manager.getStyledGlyph(
            "X",
            .Normal,
            .Roman,
            chrome.font_size,
            false,
        );
        chrome.font_height = test_glyph.ascent + test_glyph.descent;

        // Calculate tabbar bounds
        chrome.tabbar_top = 0;
        chrome.tabbar_bottom = chrome.font_height + 2 * chrome.padding;

        // Calculate URL bar bounds
        chrome.urlbar_top = chrome.tabbar_bottom;
        chrome.urlbar_bottom = chrome.urlbar_top + chrome.font_height + 2 * chrome.padding;
        chrome.bottom = chrome.urlbar_bottom;

        // Calculate new tab button bounds
        const plus_glyph = try font_manager.getStyledGlyph(
            "+",
            .Normal,
            .Roman,
            chrome.font_size,
            false,
        );
        const plus_width = plus_glyph.w + 2 * chrome.padding;
        chrome.newtab_rect = Rect{
            .left = chrome.padding,
            .top = chrome.padding,
            .right = chrome.padding + plus_width,
            .bottom = chrome.padding + chrome.font_height,
        };

        // Calculate back button bounds
        const back_glyph = try font_manager.getStyledGlyph(
            "<",
            .Normal,
            .Roman,
            chrome.font_size,
            false,
        );
        const back_width = back_glyph.w + 2 * chrome.padding;
        chrome.back_rect = Rect{
            .left = chrome.padding,
            .top = chrome.urlbar_top + chrome.padding,
            .right = chrome.padding + back_width,
            .bottom = chrome.urlbar_bottom - chrome.padding,
        };

        // Calculate address bar bounds
        chrome.address_rect = Rect{
            .left = chrome.back_rect.right + chrome.padding,
            .top = chrome.urlbar_top + chrome.padding,
            .right = window_width - chrome.padding,
            .bottom = chrome.urlbar_bottom - chrome.padding,
        };

        return chrome;
    }

    pub fn deinit(self: *Chrome) void {
        self.address_bar.deinit(self.allocator);
        if (self.cached_url_str) |url_str| {
            self.allocator.free(url_str);
        }
        if (self.cached_display_list) |list| {
            self.allocator.free(list);
        }
    }

    pub fn tabRect(self: *const Chrome, i: usize) Rect {
        const tabs_start = self.newtab_rect.right + self.padding;
        const tab_width = 100; // Approximate width for "Tab X"
        const idx: i32 = @intCast(i);
        return Rect{
            .left = tabs_start + tab_width * idx,
            .top = self.tabbar_top,
            .right = tabs_start + tab_width * (idx + 1),
            .bottom = self.tabbar_bottom,
        };
    }

    pub fn paint(self: *Chrome, allocator: std.mem.Allocator, browser: *const Browser) !std.ArrayList(DisplayItem) {
        // Free the old display list if it exists
        if (self.cached_display_list) |old_list| {
            allocator.free(old_list);
            self.cached_display_list = null;
        }

        // Note: We don't free cached_url_str here anymore - it's managed in the URL drawing code
        // and only freed/reallocated when the URL actually changes

        var cmds = std.ArrayList(DisplayItem).empty;

        // Draw white background for chrome
        try cmds.append(allocator, .{ .rect = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = browser.window_width,
            .y2 = self.bottom,
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        } });

        // Draw bottom border of chrome
        try cmds.append(allocator, .{ .line = .{
            .x1 = 0,
            .y1 = self.bottom,
            .x2 = browser.window_width,
            .y2 = self.bottom,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .thickness = 1,
        } });

        // Draw new tab button outline
        try cmds.append(allocator, .{ .outline = .{
            .rect = self.newtab_rect,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .thickness = 1,
        } });

        // Draw "+" text
        const plus_glyph = try browser.layout_engine.font_manager.getStyledGlyph(
            "+",
            .Normal,
            .Roman,
            self.font_size,
            false,
        );
        try cmds.append(allocator, .{ .glyph = .{
            .x = self.newtab_rect.left + self.padding,
            .y = self.newtab_rect.top,
            .glyph = plus_glyph,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        } });

        // Draw tabs
        for (browser.tabs.items, 0..) |tab, i| {
            const bounds = self.tabRect(i);

            // Draw left border
            try cmds.append(allocator, .{ .line = .{
                .x1 = bounds.left,
                .y1 = 0,
                .x2 = bounds.left,
                .y2 = bounds.bottom,
                .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                .thickness = 1,
            } });

            // Draw right border
            try cmds.append(allocator, .{ .line = .{
                .x1 = bounds.right,
                .y1 = 0,
                .x2 = bounds.right,
                .y2 = bounds.bottom,
                .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                .thickness = 1,
            } });

            // If this is the active tab, draw the file folder effect
            if (browser.active_tab_index) |active_idx| {
                if (i == active_idx) {
                    // Draw line from left edge to tab start
                    try cmds.append(allocator, .{ .line = .{
                        .x1 = 0,
                        .y1 = bounds.bottom,
                        .x2 = bounds.left,
                        .y2 = bounds.bottom,
                        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                        .thickness = 1,
                    } });

                    // Draw line from tab end to right edge
                    try cmds.append(allocator, .{ .line = .{
                        .x1 = bounds.right,
                        .y1 = bounds.bottom,
                        .x2 = browser.window_width,
                        .y2 = bounds.bottom,
                        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                        .thickness = 1,
                    } });
                }
            }

            // Draw tab label
            var tab_label_buf: [20]u8 = undefined;
            const tab_label = try std.fmt.bufPrint(&tab_label_buf, "Tab {d}", .{i});
            const tab_glyph = try browser.layout_engine.font_manager.getStyledGlyph(
                tab_label,
                .Normal,
                .Roman,
                self.font_size,
                false,
            );
            try cmds.append(allocator, .{ .glyph = .{
                .x = bounds.left + self.padding,
                .y = bounds.top + self.padding,
                .glyph = tab_glyph,
                .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            } });

            _ = tab; // Silence unused variable warning
        }

        // Draw back button
        try cmds.append(allocator, .{ .outline = .{
            .rect = self.back_rect,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .thickness = 1,
        } });

        const back_glyph = try browser.layout_engine.font_manager.getStyledGlyph(
            "<",
            .Normal,
            .Roman,
            self.font_size,
            false,
        );
        try cmds.append(allocator, .{ .glyph = .{
            .x = self.back_rect.left + self.padding,
            .y = self.back_rect.top,
            .glyph = back_glyph,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        } });

        // Draw address bar
        try cmds.append(allocator, .{ .outline = .{
            .rect = self.address_rect,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .thickness = 1,
        } });

        // Draw address bar content (either typed text or current URL)
        if (self.focus) |focus_str| {
            if (std.mem.eql(u8, focus_str, "address bar")) {
                // Draw the typed text
                if (self.address_bar.items.len > 0) {
                    const addr_glyph = try browser.layout_engine.font_manager.getStyledGlyph(
                        self.address_bar.items,
                        .Normal,
                        .Roman,
                        self.font_size,
                        false,
                    );
                    try cmds.append(allocator, .{ .glyph = .{
                        .x = self.address_rect.left + self.padding,
                        .y = self.address_rect.top,
                        .glyph = addr_glyph,
                        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                    } });
                }

                // Draw cursor
                const cursor_x = if (self.address_bar.items.len > 0) blk: {
                    const cursor_glyph = try browser.layout_engine.font_manager.getStyledGlyph(
                        self.address_bar.items,
                        .Normal,
                        .Roman,
                        self.font_size,
                        false,
                    );
                    break :blk self.address_rect.left + self.padding + cursor_glyph.w;
                } else self.address_rect.left + self.padding;

                try cmds.append(allocator, .{
                    .line = .{
                        .x1 = cursor_x,
                        .y1 = self.address_rect.top,
                        .x2 = cursor_x,
                        .y2 = self.address_rect.bottom,
                        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 }, // Red cursor
                        .thickness = 1,
                    },
                });
            }
        } else {
            // Draw current URL if there's an active tab
            if (browser.activeTab()) |active_tab| {
                if (active_tab.current_url) |url| {
                    // Get URL string into a temporary buffer
                    var url_buf: [512]u8 = undefined;
                    const url_str_temp = url.toString(&url_buf) catch "(invalid url)";

                    // Only allocate a new string if the URL has changed or we don't have one cached
                    const needs_new_string = if (self.cached_url_str) |cached|
                        !std.mem.eql(u8, cached, url_str_temp)
                    else
                        true;

                    if (needs_new_string) {
                        // Free old cached URL if it exists
                        if (self.cached_url_str) |old_url| {
                            allocator.free(old_url);
                        }

                        // Allocate new URL string on the heap
                        const url_str = try allocator.alloc(u8, url_str_temp.len);
                        @memcpy(url_str, url_str_temp);
                        self.cached_url_str = url_str;
                    }

                    // Use the cached URL string (which is now stable)
                    const url_str = self.cached_url_str.?;

                    const url_glyph = try browser.layout_engine.font_manager.getStyledGlyph(
                        url_str,
                        .Normal,
                        .Roman,
                        self.font_size,
                        false,
                    );
                    try cmds.append(allocator, .{ .glyph = .{
                        .x = self.address_rect.left + self.padding,
                        .y = self.address_rect.top,
                        .glyph = url_glyph,
                        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                    } });
                }
            }
        }

        return cmds;
    }

    pub fn click(self: *Chrome, browser: *Browser, x: i32, y: i32) !void {
        // Clear focus by default
        self.focus = null;

        // Check if clicked on new tab button
        if (self.newtab_rect.containsPoint(x, y)) {
            const url = try Url.init(browser.allocator, "https://browser.engineering/");
            browser.newTab(url) catch |err| {
                std.log.err("Failed to create new tab: {any}", .{err});
            };
            return;
        }

        // Check if clicked on back button
        if (self.back_rect.containsPoint(x, y)) {
            if (browser.activeTab()) |tab| {
                tab.goBack(browser) catch |err| {
                    std.log.err("Failed to go back: {any}", .{err});
                };
            }
            return;
        }

        // Check if clicked on address bar
        if (self.address_rect.containsPoint(x, y)) {
            self.focus = "address bar";
            self.address_bar.clearRetainingCapacity();
            return;
        }

        // Check if clicked on a tab
        for (0..browser.tabs.items.len) |i| {
            if (self.tabRect(i).containsPoint(x, y)) {
                browser.active_tab_index = i;
                return;
            }
        }
    }

    pub fn keypress(self: *Chrome, char: u8) !void {
        if (self.focus) |focus_str| {
            if (std.mem.eql(u8, focus_str, "address bar")) {
                try self.address_bar.append(self.allocator, char);
            }
        }
    }

    pub fn backspace(self: *Chrome) void {
        if (self.focus) |focus_str| {
            if (std.mem.eql(u8, focus_str, "address bar")) {
                if (self.address_bar.items.len > 0) {
                    _ = self.address_bar.pop();
                }
            }
        }
    }

    pub fn blur(self: *Chrome) void {
        self.focus = null;
    }

    pub fn enter(self: *Chrome, browser: *Browser) !void {
        if (self.focus) |focus_str| {
            if (std.mem.eql(u8, focus_str, "address bar")) {
                if (self.address_bar.items.len > 0) {
                    // Create URL from address bar content
                    const url = Url.init(browser.allocator, self.address_bar.items) catch |err| {
                        std.log.err("Invalid URL: {any}", .{err});
                        // Clear focus even on error
                        self.focus = null;
                        return;
                    };

                    // Load it in the active tab
                    if (browser.activeTab()) |tab| {
                        browser.loadInTab(tab, url, null) catch |err| {
                            std.log.err("Failed to load URL: {any}", .{err});
                        };
                    }

                    // Clear focus
                    self.focus = null;
                }
            }
        }
    }
};

// Tab represents a single web page
pub const Tab = struct {
    // Memory allocator
    allocator: std.mem.Allocator,
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
    scroll_offset: i32 = 0,
    // Current URL being displayed
    current_url: ?Url = null,
    // Available height for tab content (window height minus chrome height)
    tab_height: i32 = 0,
    // History of visited URLs
    history: std.ArrayList(Url),
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

    pub fn init(allocator: std.mem.Allocator, tab_height: i32) Tab {
        return Tab{
            .allocator = allocator,
            .tab_height = tab_height,
            .history = std.ArrayList(Url).empty,
            .focus = null,
            .nodes = null,
            .rules = std.ArrayList(CSSParser.CSSRule).empty,
            .default_rules_count = 0,
            .css_texts = std.ArrayList([]const u8).empty,
            .dynamic_texts = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *Tab) void {
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

        // Clean up history
        self.history.deinit(self.allocator);
    }

    // Scroll the tab down
    pub fn scrollDown(self: *Tab) void {
        const max_y = @max(self.content_height - self.tab_height, 0);
        if (self.scroll_offset + scroll_increment <= max_y) {
            self.scroll_offset += scroll_increment;
        } else {
            self.scroll_offset = max_y;
        }
    }

    // Scroll the tab up
    pub fn scrollUp(self: *Tab) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= scroll_increment;
            if (self.scroll_offset < 0) {
                self.scroll_offset = 0;
            }
        }
    }

    // Go back in history
    pub fn goBack(self: *Tab, browser: *Browser) !void {
        if (self.history.items.len > 1) {
            // Remove current page (we already checked length > 1)
            _ = self.history.pop().?;
            // Get previous page and load it (which will add it back to history)
            const back_url = self.history.pop().?;
            try browser.loadInTab(self, back_url, null);
            try browser.draw();
        }
    }

    // Re-render the page without reloading (style, layout, paint)
    pub fn render(self: *Tab, browser: *Browser) !void {
        if (self.current_node == null) return;

        // Re-apply styles with current rules
        try parser.style(browser.allocator, &self.current_node.?, self.rules.items);

        // Re-layout and paint
        try browser.layoutTabNodes(self);
    }

    // Handle click on tab content
    pub fn click(self: *Tab, browser: *Browser, x: i32, y: i32) !void {
        std.log.info("Tab.click at ({}, {})", .{ x, y });

        // Clear previous focus
        if (self.focus) |focus_node| {
            switch (focus_node.*) {
                .element => |*e| e.is_focused = false,
                else => {},
            }
            self.focus = null;
        }

        // Hit test using the input bounds map from the layout engine
        std.log.info("Checking {} input bounds", .{browser.layout_engine.input_bounds.count()});
        var it = browser.layout_engine.input_bounds.iterator();
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
                            // Clear the input value when focusing
                            if (e.attributes) |*attrs| {
                                try attrs.put("value", "");
                            }
                            e.is_focused = true;
                            self.focus = node_ptr;
                            break;
                        } else if (std.mem.eql(u8, e.tag, "button")) {
                            std.log.info("Button clicked - calling submitForm", .{});
                            // Button clicked - submit the form
                            try self.submitForm(browser, node_ptr);
                            return;
                        }
                    },
                    else => {},
                }
            }
        }

        std.log.info("No element clicked, re-rendering", .{});
        // Re-render to show changes
        try self.render(browser);
    }

    // Submit a form when a button is clicked
    fn submitForm(self: *Tab, browser: *Browser, button_node: *Node) !void {
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
                                // Found the form containing this button
                                if (e.attributes) |attrs| {
                                    if (attrs.get("action")) |action| {
                                        std.log.info("Form action: {s}", .{action});
                                        // Copy the action string before we free the tree
                                        const action_copy = try self.allocator.alloc(u8, action.len);
                                        @memcpy(action_copy, action);
                                        defer self.allocator.free(action_copy);

                                        try self.submitFormData(browser, node_ptr, action_copy);
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
    fn submitFormData(self: *Tab, browser: *Browser, form_node: *Node, action: []const u8) !void {
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
        defer self.allocator.free(body_slice);

        // Log the form submission
        std.log.info("Form submission to {s}: {s}", .{ action, body_slice });

        // For file:// URLs, we can't actually submit forms, so just log it
        if (self.current_url) |url| {
            if (std.mem.eql(u8, url.scheme, "file")) {
                std.log.info("Skipping form submission for file:// URL", .{});
                return;
            }
        }

        // Resolve the action URL against the current page URL
        const form_url = self.current_url.?.resolve(self.allocator, action) catch |err| {
            std.log.warn("Failed to resolve form action URL: {}", .{err});
            return;
        };
        defer form_url.free(self.allocator);

        // Load the URL with the POST body
        try browser.loadInTab(self, form_url, body_slice);
    }

    // Cycle focus to the next input element (for Tab key)
    pub fn cycleFocus(self: *Tab, browser: *Browser) !void {
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

        // Re-render to show changes
        try self.render(browser);
    }

    // Clear focus (for Escape key)
    pub fn clearFocus(self: *Tab, browser: *Browser) !void {
        if (self.focus) |focus_node| {
            switch (focus_node.*) {
                .element => |*e| e.is_focused = false,
                else => {},
            }
            self.focus = null;
            try self.render(browser);
        }
    }

    // Handle keypress in focused input
    pub fn keypress(self: *Tab, browser: *Browser, char: u8) !void {
        if (self.focus) |focus_node| {
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
                        try self.render(browser);
                    }
                },
                else => {},
            }
        }
    }

    // Handle backspace in focused input
    pub fn backspace(self: *Tab, browser: *Browser) !void {
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
                            try self.render(browser);
                        }
                    }
                },
                else => {},
            }
        }
    }
};

// Browser manages the window and tabs
pub const Browser = struct {
    // Memory allocator for the browser
    allocator: std.mem.Allocator,
    // SDL window handle
    window: *c.SDL_Window,
    // SDL renderer handle
    canvas: *c.SDL_Renderer,
    // HTTP client for making requests (handles both HTTP and HTTPS)
    http_client: std.http.Client,
    // Cache for storing fetched resources
    cache: Cache,
    // Window dimensions
    window_width: i32 = initial_window_width,
    window_height: i32 = initial_window_height,
    layout_engine: *Layout,
    // Default browser stylesheet rules
    default_style_sheet_rules: []CSSParser.CSSRule,
    // List of tabs
    tabs: std.ArrayList(*Tab),
    // Index of the active tab
    active_tab_index: ?usize = null,
    // Browser chrome (UI)
    chrome: Chrome = undefined,
    // Focus tracking: null means nothing focused, "content" means page content
    focus: ?[]const u8 = null,
    // JavaScript engine
    js_engine: *js_module,

    // Create a new Browser instance
    pub fn init(al: std.mem.Allocator, rtl_flag: bool) !Browser {
        // Initialize SDL
        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }

        // Create a window with correct OS graphics
        const window_flags = switch (builtin.target.os.tag) {
            .macos => c.SDL_WINDOW_METAL,
            .windows => c.SDL_WINDOW_VULKAN,
            .linux => c.SDL_WINDOW_OPENGL,
            else => c.SDL_WINDOW_OPENGL,
        };
        const screen = c.SDL_CreateWindow(
            "zibra",
            c.SDL_WINDOWPOS_UNDEFINED,
            c.SDL_WINDOWPOS_UNDEFINED,
            initial_window_width,
            initial_window_height,
            window_flags,
        ) orelse
            {
                c.SDL_Log("Unable to create window: %s", c.SDL_GetError());
                return error.SDLInitializationFailed;
            };

        // Create a renderer, which will be used to draw to the window
        const renderer = c.SDL_CreateRenderer(screen, -1, c.SDL_RENDERER_ACCELERATED) orelse {
            c.SDL_Log("Unable to create renderer: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        // Parse the default browser stylesheet
        var css_parser = try CSSParser.init(al, DEFAULT_STYLE_SHEET);
        defer css_parser.deinit(al);
        const default_rules = try css_parser.parse(al);

        const layout_engine = try Layout.init(
            al,
            renderer,
            initial_window_width,
            initial_window_height,
            rtl_flag,
        );

        // Initialize JavaScript engine
        const js_engine = try js_module.init(al);
        errdefer js_engine.deinit(al);

        return Browser{
            .allocator = al,
            .window = screen,
            .canvas = renderer,
            .http_client = .{ .allocator = al },
            .cache = try Cache.init(al),
            .layout_engine = layout_engine,
            .default_style_sheet_rules = default_rules,
            .tabs = std.ArrayList(*Tab).empty,
            .chrome = try Chrome.init(&layout_engine.font_manager, initial_window_width, al),
            .js_engine = js_engine,
        };
    }

    // Get the active tab (if any)
    fn activeTab(self: *const Browser) ?*Tab {
        if (self.active_tab_index) |idx| {
            if (idx < self.tabs.items.len) {
                return self.tabs.items[idx];
            }
        }
        return null;
    }

    // Free the resources used by the browser
    // Deprecated: use deinit() instead
    pub fn free(self: *Browser) void {
        self.deinit();
    }

    // Create a new tab and load a URL into it
    pub fn newTab(self: *Browser, url: Url) !void {
        const tab_height = self.window_height - self.chrome.bottom;
        const tab = try self.allocator.create(Tab);
        tab.* = Tab.init(self.allocator, tab_height);

        try self.tabs.append(self.allocator, tab);
        self.active_tab_index = self.tabs.items.len - 1;

        try self.loadInTab(tab, url, null);
        try self.draw();
    }

    // Run the browser event loop
    pub fn run(self: *Browser) !void {
        var quit = false;

        while (!quit) {
            var event: c.SDL_Event = undefined;

            while (c.SDL_PollEvent(&event) != 0) {
                switch (event.type) {
                    // Quit when the window is closed
                    c.SDL_QUIT => quit = true,
                    c.SDL_KEYDOWN => {
                        try self.handleKeyEvent(event.key.keysym.sym);
                    },
                    c.SDL_TEXTINPUT => {
                        // Handle text input
                        const text = std.mem.sliceTo(&event.text.text, 0);
                        for (text) |char| {
                            if (char >= 0x20 and char < 0x7f) {
                                // Try chrome first
                                try self.chrome.keypress(char);
                                // If focus is on content, send to active tab
                                if (self.focus) |focus_str| {
                                    if (std.mem.eql(u8, focus_str, "content")) {
                                        if (self.activeTab()) |tab| {
                                            try tab.keypress(self, char);
                                        }
                                    }
                                }
                            }
                        }
                        try self.draw();
                    },
                    // Handle mouse wheel events
                    c.SDL_MOUSEWHEEL => {
                        if (self.activeTab()) |tab| {
                            if (event.wheel.y > 0) {
                                tab.scrollUp();
                            } else if (event.wheel.y < 0) {
                                tab.scrollDown();
                            }
                            try self.draw();
                        }
                    },
                    // Handle mouse button clicks
                    c.SDL_MOUSEBUTTONDOWN => {
                        if (event.button.button == c.SDL_BUTTON_LEFT) {
                            try self.handleClick(event.button.x, event.button.y);
                        }
                    },
                    c.SDL_WINDOWEVENT => {
                        try self.handleWindowEvent(event.window);
                    },
                    else => {},
                }
            }

            // Draw browser content (includes canvas clear)
            try self.draw();

            // Present the updated frame
            c.SDL_RenderPresent(self.canvas);

            // delay for 17ms to get 60fps
            c.SDL_Delay(17);
        }
    }

    pub fn handleWindowEvent(self: *Browser, window_event: c.SDL_WindowEvent) !void {
        const data1 = window_event.data1;
        const data2 = window_event.data2;

        switch (window_event.event) {
            c.SDL_WINDOWEVENT_RESIZED, c.SDL_WINDOWEVENT_SIZE_CHANGED => {
                // Adjust renderer viewport to match new window size
                _ = c.SDL_RenderSetViewport(self.canvas, null);

                self.window_width = data1;
                self.window_height = data2;

                // Update layout engine's window dimensions
                self.layout_engine.window_width = data1;
                self.layout_engine.window_height = data2;

                // Force a clear and redraw
                _ = c.SDL_SetRenderDrawColor(self.canvas, 255, 255, 255, 255);
                _ = c.SDL_RenderClear(self.canvas);
                try self.draw();
                c.SDL_RenderPresent(self.canvas);
            },
            else => {},
        }
    }

    fn handleKeyEvent(self: *Browser, key: c.SDL_Keycode) !void {
        // Handle Tab key to cycle through input elements
        if (key == c.SDLK_TAB) {
            if (self.focus) |focus_str| {
                if (std.mem.eql(u8, focus_str, "content")) {
                    if (self.activeTab()) |tab| {
                        try tab.cycleFocus(self);
                    }
                }
            }
            return;
        }

        // Handle Escape key to clear focus
        if (key == c.SDLK_ESCAPE) {
            if (self.focus) |focus_str| {
                if (std.mem.eql(u8, focus_str, "content")) {
                    if (self.activeTab()) |tab| {
                        try tab.clearFocus(self);
                    }
                    // Also clear browser focus
                    self.focus = null;
                }
            }
            try self.draw();
            return;
        }

        // Handle Backspace key
        if (key == c.SDLK_BACKSPACE) {
            self.chrome.backspace();
            // Also send to tab if content is focused
            if (self.focus) |focus_str| {
                if (std.mem.eql(u8, focus_str, "content")) {
                    if (self.activeTab()) |tab| {
                        try tab.backspace(self);
                    }
                }
            }
            try self.draw();
            return;
        }

        // Handle Enter/Return key
        if (key == c.SDLK_RETURN or key == c.SDLK_RETURN2) {
            try self.chrome.enter(self);
            try self.draw();
            return;
        }

        // Handle scrolling keys
        if (self.activeTab()) |tab| {
            switch (key) {
                c.SDLK_DOWN => {
                    tab.scrollDown();
                    try self.draw();
                },
                c.SDLK_UP => {
                    tab.scrollUp();
                    try self.draw();
                },
                else => {},
            }
        }
    }

    // Handle mouse clicks to navigate links
    fn handleClick(self: *Browser, screen_x: i32, screen_y: i32) !void {
        std.debug.print("Click detected at screen ({d}, {d})\n", .{ screen_x, screen_y });

        // Check if click is in chrome area
        if (screen_y < self.chrome.bottom) {
            self.focus = null;
            try self.chrome.click(self, screen_x, screen_y);
            try self.draw();
            return;
        }

        // Click is in tab content area - set focus and blur chrome
        self.focus = "content";
        self.chrome.blur();

        const tab = self.activeTab() orelse return;
        const tab_y = screen_y - self.chrome.bottom;

        // Convert screen coordinates to page coordinates
        const page_x = screen_x;
        const page_y = tab_y + tab.scroll_offset;

        std.debug.print("Page coordinates: ({d}, {d})\n", .{ page_x, page_y });

        // Only proceed if we have the HTML tree
        const root_node = tab.current_node orelse {
            std.debug.print("No current_node\n", .{});
            return;
        };

        std.debug.print("Current URL: {s}\n", .{if (tab.current_url) |url| url.path else "none"});

        // For now, use a simple approach: collect all nodes and check bounds
        // TODO: Use the layout tree when LineLayout/TextLayout are fully implemented
        var node_list = std.ArrayList(*Node).empty;
        defer node_list.deinit(self.allocator);

        var root_mut = root_node;
        try parser.treeToList(self.allocator, &root_mut, &node_list);

        std.debug.print("Found {d} nodes in tree\n", .{node_list.items.len});

        // Find clickable elements (links) and check if click is within their bounds
        // For now, we'll just search for <a> elements in the tree
        // and try to find one that might contain the click
        var link_count: usize = 0;
        var element_count: usize = 0;
        for (node_list.items) |node_ptr| {
            switch (node_ptr.*) {
                .element => |e| {
                    element_count += 1;
                    std.debug.print("Element #{d}: tag='{s}'\n", .{ element_count, e.tag });
                    if (std.mem.eql(u8, e.tag, "a")) {
                        link_count += 1;
                        if (e.attributes) |attrs| {
                            std.debug.print("Link has {d} attributes\n", .{attrs.count()});
                            if (attrs.get("href")) |href| {
                                std.debug.print("Found link #{d}: {s}\n", .{ link_count, href });
                                // Resolve the URL relative to current page
                                if (tab.current_url) |current_url| {
                                    const resolved_url = try current_url.resolve(self.allocator, href);
                                    std.debug.print("Resolved to: {s}\n", .{resolved_url.path});
                                    std.debug.print("Loading link: {s}\n", .{href});
                                    self.loadInTab(tab, resolved_url, null) catch |err| {
                                        std.log.err("Failed to load URL {s}: {any}", .{ href, err });
                                        return;
                                    };
                                    self.draw() catch |err| {
                                        std.log.err("Failed to draw after loading: {any}", .{err});
                                    };
                                    return;
                                } else {
                                    std.debug.print("No current_url to resolve against\n", .{});
                                }
                            } else {
                                std.debug.print("Link #{d} has no href\n", .{link_count});
                            }
                        } else {
                            std.debug.print("Link #{d} has no attributes\n", .{link_count});
                        }
                    }
                },
                .text => |t| {
                    std.debug.print("Text node: '{s}'\n", .{t.text[0..@min(20, t.text.len)]});
                },
            }
        }

        std.debug.print("No links found to click\n", .{});

        // Handle input element clicks
        try tab.click(self, page_x, page_y);
    }

    // Update the scroll offset
    pub fn fetchBody(self: *Browser, url: Url, payload: ?[]const u8) ![]const u8 {
        return if (std.mem.eql(u8, url.scheme, "file"))
            try url.fileRequest(self.allocator)
        else if (std.mem.eql(u8, url.scheme, "data"))
            url.path
        else if (std.mem.eql(u8, url.scheme, "about"))
            url.aboutRequest()
        else
            try url.httpRequest(
                self.allocator,
                &self.http_client,
                &self.cache,
                payload,
            );
    }

    // Send request to a URL, load response into a tab
    pub fn loadInTab(
        self: *Browser,
        tab: *Tab,
        url: Url,
        payload: ?[]const u8,
    ) !void {
        std.log.info("Loading: {s}", .{url.path});

        // Add URL to history
        try tab.history.append(self.allocator, url);

        // Store the current URL for resolving relative links
        tab.current_url = url;

        // Do the request, getting back the body of the response.
        const body = try self.fetchBody(url, payload);

        // Free previous HTML source if it exists
        if (tab.current_html_source) |old_source| {
            self.allocator.free(old_source);
            tab.current_html_source = null;
        }

        if (url.view_source) {
            // Use the new layoutSourceCode function for view-source mode
            defer if (!std.mem.eql(u8, url.scheme, "about")) self.allocator.free(body);

            if (tab.display_list) |items| {
                self.allocator.free(items);
            }

            if (tab.document_layout) |doc| {
                doc.deinit();
                self.allocator.destroy(doc);
                tab.document_layout = null;
            }

            if (tab.current_node) |node| {
                var n = node;
                n.deinit(self.allocator);
                tab.current_node = null;
            }

            tab.display_list = try self.layout_engine.layoutSourceCode(body);
            tab.content_height = self.layout_engine.content_height;
        } else {
            // Parse HTML into a node tree
            var html_parser = try HTMLParser.init(self.allocator, body);
            defer html_parser.deinit(self.allocator);

            // Clear any previous node tree
            if (tab.current_node) |node| {
                var n = node;
                n.deinit(self.allocator);
                tab.current_node = null;
            }

            // Parse the HTML and store the root node
            tab.current_node = try html_parser.parse();

            // IMPORTANT: Fix parent pointers after copying the tree
            // The parse() method returns the tree by value, which copies it,
            // but the parent pointers still point to the old locations
            parser.fixParentPointers(&tab.current_node.?, null);

            // Store the HTML source (it contains slices used by the tree)
            // Only store if it's not an about: URL (those return static strings)
            if (!std.mem.eql(u8, url.scheme, "about")) {
                tab.current_html_source = body;
            }

            // Update the JS engine with the current nodes for DOM API
            self.js_engine.setNodes(&tab.current_node.?);

            // Find all scripts and stylesheets
            var node_list = std.ArrayList(*parser.Node).empty;
            defer node_list.deinit(self.allocator);
            try parser.treeToList(self.allocator, &tab.current_node.?, &node_list);

            // Collect script URLs from <script src="..."> elements
            var script_urls = std.ArrayList([]const u8).empty;
            defer {
                for (script_urls.items) |src| {
                    self.allocator.free(src);
                }
                script_urls.deinit(self.allocator);
            }

            for (node_list.items) |node| {
                switch (node.*) {
                    .element => |e| {
                        if (std.mem.eql(u8, e.tag, "script")) {
                            if (e.attributes) |attrs| {
                                if (attrs.get("src")) |src| {
                                    // Copy the src string for later use
                                    const src_copy = try self.allocator.alloc(u8, src.len);
                                    @memcpy(src_copy, src);
                                    try script_urls.append(self.allocator, src_copy);
                                }
                            }
                        }
                    },
                    .text => {},
                }
            }

            // Load and execute each script
            for (script_urls.items) |src| {
                std.log.info("Loading script: {s}", .{src});

                // Resolve relative URL against the current page URL
                const script_url = url.resolve(self.allocator, src) catch |err| {
                    std.log.warn("Failed to resolve script URL {s}: {}", .{ src, err });
                    continue;
                };
                defer script_url.free(self.allocator);

                // Fetch the script
                const script_body = self.fetchBody(script_url, null) catch |err| {
                    std.log.warn("Failed to load script {s}: {}", .{ src, err });
                    continue;
                };

                // Only free if it's not a static string (data: and about: return static/borrowed strings)
                const should_free = !std.mem.eql(u8, script_url.scheme, "data") and
                    !std.mem.eql(u8, script_url.scheme, "about");
                defer if (should_free) self.allocator.free(script_body);

                // Execute the script
                std.log.info("========== Executing script ==========", .{});
                const result = self.js_engine.evaluate(script_body) catch |err| {
                    std.log.err("Script {s} crashed: {}", .{ src, err });
                    continue;
                };

                // Format result to a stack buffer for logging
                var result_buf: [4096]u8 = undefined;
                const result_str = js_module.formatValue(result, &result_buf) catch |err| {
                    std.log.err("Failed to format script result: {}", .{err});
                    continue;
                };

                std.log.info("Script result: {s}", .{result_str});
                std.log.info("======================================", .{});

                // Only inject non-undefined results into the DOM
                if (!std.mem.eql(u8, result_str, "undefined")) {
                    // Inject the result into the DOM as a text node in the body
                    // We need to allocate the string so it can be owned by the DOM tree
                    const result_text = try self.allocator.alloc(u8, result_str.len);
                    @memcpy(result_text, result_str);
                    // Track this allocation so it can be freed later
                    try tab.dynamic_texts.append(self.allocator, result_text);

                    // Find the body element
                    var body_node: ?*Node = null;
                    for (node_list.items) |node| {
                        switch (node.*) {
                            .element => |e| {
                                if (std.mem.eql(u8, e.tag, "body")) {
                                    body_node = node;
                                    break;
                                }
                            },
                            .text => {},
                        }
                    }

                    if (body_node) |body_elem| {
                        // Create a text node with the result
                        const text_node = Node{ .text = .{
                            .text = result_text,
                            .parent = body_elem,
                        } };

                        // Append it to the body
                        try body_elem.appendChild(self.allocator, text_node);

                        // IMPORTANT: Fix parent pointers after modifying the tree
                        // ArrayList reallocation can invalidate existing parent pointers
                        parser.fixParentPointers(&tab.current_node.?, null);

                        // IMPORTANT: Recreate node_list after modifying the tree
                        // The old node_list contains stale pointers after appendChild
                        node_list.clearRetainingCapacity();
                        try parser.treeToList(self.allocator, &tab.current_node.?, &node_list);
                    } else {
                        // If we couldn't find the body, free the allocated text
                        self.allocator.free(result_text);
                    }
                }
            }

            // Collect stylesheet URLs from <link rel="stylesheet" href="..."> elements
            var stylesheet_urls = std.ArrayList([]const u8).empty;
            defer {
                for (stylesheet_urls.items) |href| {
                    self.allocator.free(href);
                }
                stylesheet_urls.deinit(self.allocator);
            }

            for (node_list.items) |node| {
                switch (node.*) {
                    .element => |e| {
                        if (std.mem.eql(u8, e.tag, "link")) {
                            if (e.attributes) |attrs| {
                                const rel = attrs.get("rel");
                                const href = attrs.get("href");

                                if (rel != null and href != null and
                                    std.mem.eql(u8, rel.?, "stylesheet"))
                                {
                                    // Copy the href string for later use
                                    const href_copy = try self.allocator.alloc(u8, href.?.len);
                                    @memcpy(href_copy, href.?);
                                    try stylesheet_urls.append(self.allocator, href_copy);
                                }
                            }
                        }
                    },
                    .text => {},
                }
            }

            // Note: We use self.allocator directly for CSS parsing instead of an arena
            // because the CSS rules need to live as long as the Tab (for re-rendering)

            // Load and parse external stylesheets
            var all_rules = std.ArrayList(CSSParser.CSSRule).empty;

            // Track how many default rules we have so we don't double-free them
            const default_rules_count = self.default_style_sheet_rules.len;

            defer {
                // Only deinit rules that were allocated in this function (external stylesheets)
                // Skip the first default_rules_count rules as they're owned by the browser
                if (all_rules.items.len > default_rules_count) {
                    for (all_rules.items[default_rules_count..]) |*rule| {
                        var mutable_rule = rule;
                        mutable_rule.deinit(self.allocator);
                    }
                }
                all_rules.deinit(self.allocator);
            }

            // Start with default browser stylesheet rules (shallow copy, browser still owns them)
            for (self.default_style_sheet_rules) |rule| {
                try all_rules.append(self.allocator, rule);
            }

            // Download and parse each linked stylesheet
            for (stylesheet_urls.items) |href| {
                std.log.info("Loading stylesheet: {s}", .{href});

                // Resolve relative URL against the current page URL
                const stylesheet_url = url.resolve(self.allocator, href) catch |err| {
                    std.log.warn("Failed to resolve stylesheet URL {s}: {}", .{ href, err });
                    continue;
                };
                defer stylesheet_url.free(self.allocator);

                // Fetch the stylesheet
                const css_text = self.fetchBody(stylesheet_url, null) catch |err| {
                    std.log.warn("Failed to load stylesheet {s}: {}", .{ href, err });
                    continue;
                };

                // Parse the stylesheet using self.allocator
                // (CSS rules need to live as long as the Tab)
                var css_parser = try CSSParser.init(self.allocator, css_text);
                defer css_parser.deinit(self.allocator);

                const parsed_rules = css_parser.parse(self.allocator) catch |err| {
                    std.log.warn("Failed to parse stylesheet {s}: {}", .{ href, err });
                    // Free css_text before continuing
                    self.allocator.free(css_text);
                    continue;
                };

                // Store css_text so it can be freed when the Tab is destroyed
                // (CSS rules reference strings within this text)
                try tab.css_texts.append(self.allocator, css_text);

                // Add the parsed rules to our collection
                for (parsed_rules) |rule| {
                    try all_rules.append(self.allocator, rule);
                }

                // Free the parsed_rules slice (the rules themselves are now in all_rules)
                self.allocator.free(parsed_rules);
            }

            // Sort rules by cascade priority (more specific selectors override less specific)
            // Stable sort preserves file order for rules with equal priority
            std.mem.sort(CSSParser.CSSRule, all_rules.items, {}, struct {
                fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                    return a.cascadePriority() < b.cascadePriority();
                }
            }.lessThan);

            // Clean up old CSS rules and texts before replacing them
            // First, free the property hashmaps for external stylesheet rules (not default rules)
            if (tab.rules.items.len > tab.default_rules_count) {
                for (tab.rules.items[tab.default_rules_count..]) |*rule| {
                    rule.properties.deinit();
                }
            }

            // Free old CSS text buffers
            for (tab.css_texts.items) |old_css_text| {
                self.allocator.free(old_css_text);
            }
            tab.css_texts.clearRetainingCapacity();

            // Now clear the rules list
            tab.rules.clearRetainingCapacity();

            // Track how many default rules we have (these are borrowed, not owned)
            tab.default_rules_count = default_rules_count;

            // Copy all rules to tab (first N are borrowed, rest are owned)
            for (all_rules.items) |rule| {
                try tab.rules.append(self.allocator, rule);
            }

            // Apply all stylesheet rules and inline styles (sorted by cascade order)
            try parser.style(self.allocator, &tab.current_node.?, tab.rules.items);

            // Layout using the HTML node tree
            try self.layoutTabNodes(tab);
        }
    }

    // Layout a tab's HTML nodes with the tree-based layout
    pub fn layoutTabNodes(self: *Browser, tab: *Tab) !void {
        if (tab.current_node == null) {
            return error.NoNodeToLayout;
        }

        // Free existing display list if it exists
        if (tab.display_list) |items| {
            self.allocator.free(items);
        }

        // Clear previous document layout if it exists
        if (tab.document_layout != null) {
            tab.document_layout.?.deinit();
            self.allocator.destroy(tab.document_layout.?);
            tab.document_layout = null;
        }

        // Create and layout the document tree
        tab.document_layout = try self.layout_engine.buildDocument(tab.current_node.?);

        // Paint the document to produce draw commands
        tab.display_list = try self.layout_engine.paintDocument(tab.document_layout.?);

        // Update content height from the layout engine
        tab.content_height = self.layout_engine.content_height;
    }

    // Draw the browser content
    pub fn draw(self: *Browser) !void {
        // Clear the canvas
        _ = c.SDL_SetRenderDrawColor(self.canvas, 255, 255, 255, 255);
        _ = c.SDL_RenderClear(self.canvas);

        // Only draw the active tab
        const tab = self.activeTab() orelse {
            // Draw just the chrome if no tabs
            var chrome_cmds = try self.chrome.paint(self.allocator, self);
            defer chrome_cmds.deinit(self.allocator);
            for (chrome_cmds.items) |item| {
                try self.drawDisplayItem(item, 0);
            }
            return;
        };

        if (tab.display_list) |display_list| {
            for (display_list) |item| {
                // Offset by chrome height and scroll
                try self.drawDisplayItem(item, tab.scroll_offset - self.chrome.bottom);
            }
        }

        // Draw chrome on top
        var chrome_cmds = try self.chrome.paint(self.allocator, self);
        defer chrome_cmds.deinit(self.allocator);
        for (chrome_cmds.items) |item| {
            try self.drawDisplayItem(item, 0);
        }

        self.drawScrollbar(tab);
    }

    fn drawDisplayItem(self: *Browser, item: DisplayItem, scroll_offset: i32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                const screen_y = glyph_item.y - scroll_offset;
                if (screen_y >= 0 and screen_y < self.window_height) {
                    var dst_rect: c.SDL_Rect = .{
                        .x = glyph_item.x,
                        .y = screen_y,
                        .w = glyph_item.glyph.w,
                        .h = glyph_item.glyph.h,
                    };

                    // Apply text color to the glyph texture
                    _ = c.SDL_SetTextureColorMod(
                        glyph_item.glyph.texture,
                        glyph_item.color.r,
                        glyph_item.color.g,
                        glyph_item.color.b,
                    );

                    _ = c.SDL_RenderCopy(
                        self.canvas,
                        glyph_item.glyph.texture,
                        null,
                        &dst_rect,
                    );
                }
            },
            .rect => |rect_item| {
                const top = rect_item.y1 - scroll_offset;
                const bottom = rect_item.y2 - scroll_offset;
                if (bottom > 0 and top < self.window_height) {
                    const width = rect_item.x2 - rect_item.x1;
                    const height = bottom - top;
                    if (width > 0 and height > 0) {
                        _ = c.SDL_SetRenderDrawColor(
                            self.canvas,
                            rect_item.color.r,
                            rect_item.color.g,
                            rect_item.color.b,
                            rect_item.color.a,
                        );

                        var rect: c.SDL_Rect = .{
                            .x = rect_item.x1,
                            .y = top,
                            .w = width,
                            .h = height,
                        };
                        _ = c.SDL_RenderFillRect(self.canvas, &rect);
                    }
                }
            },
            .line => |line_item| {
                const y1 = line_item.y1 - scroll_offset;
                const y2 = line_item.y2 - scroll_offset;
                _ = c.SDL_SetRenderDrawColor(
                    self.canvas,
                    line_item.color.r,
                    line_item.color.g,
                    line_item.color.b,
                    line_item.color.a,
                );
                // SDL doesn't have line thickness directly, draw as rect for thickness > 1
                if (line_item.thickness == 1) {
                    _ = c.SDL_RenderDrawLine(self.canvas, line_item.x1, y1, line_item.x2, y2);
                } else {
                    // Draw thick line as rectangle
                    const is_horizontal = (line_item.y1 == line_item.y2);
                    if (is_horizontal) {
                        const width: i32 = @intCast(@abs(line_item.x2 - line_item.x1));
                        var rect: c.SDL_Rect = .{
                            .x = @min(line_item.x1, line_item.x2),
                            .y = y1 - @divTrunc(line_item.thickness, 2),
                            .w = width,
                            .h = line_item.thickness,
                        };
                        _ = c.SDL_RenderFillRect(self.canvas, &rect);
                    } else {
                        const height: i32 = @intCast(@abs(y2 - y1));
                        var rect: c.SDL_Rect = .{
                            .x = line_item.x1 - @divTrunc(line_item.thickness, 2),
                            .y = @min(y1, y2),
                            .w = line_item.thickness,
                            .h = height,
                        };
                        _ = c.SDL_RenderFillRect(self.canvas, &rect);
                    }
                }
            },
            .outline => |outline_item| {
                const r = outline_item.rect;
                const top = r.top - scroll_offset;
                const bottom = r.bottom - scroll_offset;
                _ = c.SDL_SetRenderDrawColor(
                    self.canvas,
                    outline_item.color.r,
                    outline_item.color.g,
                    outline_item.color.b,
                    outline_item.color.a,
                );
                // Draw four lines for the outline
                _ = c.SDL_RenderDrawLine(self.canvas, r.left, top, r.right, top); // top
                _ = c.SDL_RenderDrawLine(self.canvas, r.right, top, r.right, bottom); // right
                _ = c.SDL_RenderDrawLine(self.canvas, r.right, bottom, r.left, bottom); // bottom
                _ = c.SDL_RenderDrawLine(self.canvas, r.left, bottom, r.left, top); // left
            },
        }
    }

    pub fn drawScrollbar(self: *Browser, tab: *Tab) void {
        const tab_height = self.window_height - self.chrome.bottom;
        if (tab.content_height <= tab_height) {
            // No scrollbar needed if content fits in the window
            return;
        }

        // Calculate scrollbar thumb size and position (accounting for chrome height)
        const track_height = tab_height;
        const thumb_height: i32 = @intFromFloat(@as(f32, @floatFromInt(tab_height)) * (@as(f32, @floatFromInt(tab_height)) / @as(f32, @floatFromInt(tab.content_height))));
        const max_scroll = tab.content_height - tab_height;
        const thumb_y_offset: i32 = @intFromFloat(@as(f32, @floatFromInt(tab.scroll_offset)) / @as(f32, @floatFromInt(max_scroll)) * (@as(f32, @floatFromInt(tab_height)) - @as(f32, @floatFromInt(thumb_height))));

        // Draw scrollbar track (background) - start below chrome
        var track_rect: c.SDL_Rect = .{
            .x = self.window_width - scrollbar_width,
            .y = self.chrome.bottom,
            .w = scrollbar_width,
            .h = track_height,
        };
        // Light gray
        _ = c.SDL_SetRenderDrawColor(self.canvas, 200, 200, 200, 255);
        _ = c.SDL_RenderFillRect(self.canvas, &track_rect);

        // Draw scrollbar thumb (movable part) - offset by chrome height
        var thumb_rect: c.SDL_Rect = .{
            .x = self.window_width - scrollbar_width,
            .y = self.chrome.bottom + thumb_y_offset,
            .w = scrollbar_width,
            .h = thumb_height,
        };
        _ = c.SDL_SetRenderDrawColor(self.canvas, 0, 102, 204, 255); // Blue
        _ = c.SDL_RenderFillRect(self.canvas, &thumb_rect);
    }

    // Ensure we clean up the document_layout in deinit
    pub fn deinit(self: *Browser) void {
        // Close all connections
        self.http_client.deinit();

        // Free cache
        var cache = self.cache;
        cache.free();

        // Clean up chrome
        self.chrome.deinit();

        // Clean up all tabs
        for (self.tabs.items) |tab| {
            tab.deinit();
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);

        // Clean up default stylesheet rules
        for (self.default_style_sheet_rules) |*rule| {
            rule.deinit(self.allocator);
        }
        self.allocator.free(self.default_style_sheet_rules);

        // clean up layout
        self.layout_engine.deinit();

        // Clean up JavaScript engine
        self.js_engine.deinit(self.allocator);

        c.SDL_DestroyRenderer(self.canvas);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};
