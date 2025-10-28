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
const url_module = @import("url.zig");
const Url = url_module.Url;
const Cache = @import("cache.zig").Cache;
const ArrayList = std.ArrayList;
const Layout = @import("Layout.zig");
const parser = @import("parser.zig");
const HTMLParser = parser.HTMLParser;
const Node = parser.Node;
const CSSParser = @import("cssParser.zig").CSSParser;
const js_module = @import("js.zig");
const Tab = @import("tab.zig");
const Chrome = @import("chrome.zig");

const sdl = @import("sdl.zig");
const c = sdl.c;
const sdl2 = @import("sdl");

// Default browser stylesheet - defines default styling for HTML elements
const DEFAULT_STYLE_SHEET = @embedFile("browser.css");

// *********************************************************
// * App Settings
// *********************************************************
const initial_window_width = 800;
const initial_window_height = 600;
pub const h_offset = 13;
pub const v_offset = 18;
pub const scrollbar_width = 10;
// *********************************************************

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

pub const JsRenderContext = struct {
    browser_ptr: ?*anyopaque = null,
    tab_ptr: ?*anyopaque = null,
};

// Browser manages the window and tabs
pub const Browser = struct {
    // Memory allocator for the browser
    allocator: std.mem.Allocator,
    // SDL window handle
    window: sdl2.Window,
    // SDL renderer handle
    canvas: sdl2.Renderer,
    // HTTP client for making requests (handles both HTTP and HTTPS)
    http_client: std.http.Client,
    // Cache for storing fetched resources
    cache: Cache,
    // Shared cookie storage across tabs
    cookie_jar: std.StringHashMap(url_module.CookieEntry),
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
        try sdl2.init(.{
            .video = true,
        });

        // Create a window with correct OS graphics
        const screen = try sdl2.createWindow(
            "zibra",
            .default,
            .default,
            initial_window_width,
            initial_window_height,
            .{ .resizable = true },
        );

        // Create a renderer, which will be used to draw to the window
        const renderer = try sdl2.createRenderer(
            screen,
            null,
            .{ .accelerated = true },
        );

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
            .cookie_jar = std.StringHashMap(url_module.CookieEntry).init(al),
            .layout_engine = layout_engine,
            .default_style_sheet_rules = default_rules,
            .tabs = std.ArrayList(*Tab).empty,
            .chrome = try Chrome.init(&layout_engine.font_manager, initial_window_width, al),
            .js_engine = js_engine,
        };
    }

    // Get the active tab (if any)
    pub fn activeTab(self: *const Browser) ?*Tab {
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

        const url_ptr = try self.allocator.create(Url);
        url_ptr.* = url;
        var load_success = false;
        defer if (!load_success) {
            url_ptr.*.free(self.allocator);
            self.allocator.destroy(url_ptr);
        };

        try self.loadInTab(tab, url_ptr, null);
        load_success = true;
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

    pub fn handleWindowEvent(self: *Browser, window_event: sdl2.WindowEvent) !void {
        switch (window_event.type) {
            .resized, .size_changed => |size| {
                // Adjust renderer viewport to match new window size
                try self.canvas.setViewport(null);

                self.window_width = size.width;
                self.window_height = size.height;

                // Update layout engine's window dimensions
                self.layout_engine.window_width = size.width;
                self.layout_engine.window_height = size.height;

                // Force a clear and redraw
                try self.canvas.setColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });
                try self.canvas.clear();
                try self.draw();
                try self.canvas.present();
            },
            else => {},
        }
    }

    fn handleKeyEvent(self: *Browser, key: sdl2.Keycode) !void {
        switch (key) {
            // Handle Tab key to cycle through input elements
            .tab => {
                if (self.focus) |focus_str| {
                    if (std.mem.eql(u8, focus_str, "content")) {
                        if (self.activeTab()) |tab| {
                            try tab.cycleFocus(self);
                        }
                    }
                }
                return;
            },
            // Handle Escape key to clear focus
            .escape => {
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
            },

            // Handle Backspace key
            .backspace => {
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
            },

            // Handle Enter/Return key
            .@"return", .return_2 => {
                try self.chrome.enter(self);
                try self.draw();
                return;
            },
            else => {
                // Handle scrolling keys
                if (self.activeTab()) |tab| {
                    switch (key) {
                        .down => {
                            tab.scrollDown();
                            try self.draw();
                        },
                        .up => {
                            tab.scrollUp();
                            try self.draw();
                        },
                        else => {},
                    }
                }
            },
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
        if (tab.current_node == null) {
            std.debug.print("No current_node\n", .{});
            return;
        }

        std.debug.print("Current URL: {s}\n", .{if (tab.current_url) |url_ptr| url_ptr.*.path else "none"});

        var handled_link = false;
        for (self.layout_engine.link_bounds.items) |entry| {
            const bounds = entry.bounds;
            if (page_x >= bounds.x and page_x < bounds.x + bounds.width and
                page_y >= bounds.y and page_y < bounds.y + bounds.height)
            {
                const link_node = entry.node;
                const prevent_default = self.js_engine.dispatchEvent("click", link_node) catch |err| blk: {
                    std.log.warn("Failed to dispatch click event: {}", .{err});
                    break :blk false;
                };
                if (prevent_default) {
                    std.debug.print("Click default prevented for link\n", .{});
                    return;
                }

                switch (link_node.*) {
                    .element => |*link_element| {
                        if (link_element.attributes) |attrs| {
                            if (attrs.get("href")) |href| {
                                if (tab.current_url) |current_url_ptr| {
                                    var resolved_url = try current_url_ptr.*.resolve(self.allocator, href);
                                    std.debug.print("Loading link: {s}\n", .{href});

                                    const new_url_ptr = self.allocator.create(Url) catch |alloc_err| {
                                        std.log.err("Failed to allocate URL: {any}", .{alloc_err});
                                        resolved_url.free(self.allocator);
                                        return;
                                    };
                                    new_url_ptr.* = resolved_url;
                                    var load_success = false;
                                    defer if (!load_success) {
                                        new_url_ptr.*.free(self.allocator);
                                        self.allocator.destroy(new_url_ptr);
                                    };

                                    self.loadInTab(tab, new_url_ptr, null) catch |err| {
                                        std.log.err("Failed to load URL {s}: {any}", .{ href, err });
                                        return;
                                    };
                                    load_success = true;

                                    self.draw() catch |err| {
                                        std.log.err("Failed to draw after loading: {any}", .{err});
                                    };
                                    handled_link = true;
                                } else {
                                    std.debug.print("No current_url to resolve against\n", .{});
                                }
                            }
                        }
                    },
                    else => {},
                }

                if (handled_link) {
                    return;
                }
            }
        }

        // Handle input element clicks
        try tab.click(self, page_x, page_y);
    }

    // Update the scroll offset
    pub fn fetchBody(self: *Browser, url: Url, referrer: ?Url, payload: ?[]const u8) !url_module.HttpResponse {
        if (std.mem.eql(u8, url.scheme, "file")) {
            const content = try url.fileRequest(self.allocator);
            return .{ .body = content, .csp_header = null };
        } else if (std.mem.eql(u8, url.scheme, "data")) {
            return .{ .body = url.path, .csp_header = null };
        } else if (std.mem.eql(u8, url.scheme, "about")) {
            return .{ .body = url.aboutRequest(), .csp_header = null };
        }

        return try url.httpRequest(
            self.allocator,
            &self.http_client,
            &self.cache,
            &self.cookie_jar,
            referrer,
            payload,
        );
    }

    // Send request to a URL, load response into a tab
    pub fn loadInTab(
        self: *Browser,
        tab: *Tab,
        url: *Url,
        payload: ?[]const u8,
    ) !void {
        std.log.info("Loading: {s}", .{url.*.path});

        var referrer_value: ?Url = null;
        if (tab.current_url) |ref_ptr| {
            referrer_value = ref_ptr.*;
        }

        // Do the request, getting back the body of the response.
        const response = try self.fetchBody(url.*, referrer_value, payload);
        defer if (response.csp_header) |hdr| self.allocator.free(hdr);

        tab.clearAllowedOrigins();
        if (response.csp_header) |hdr| {
            tab.applyContentSecurityPolicy(hdr) catch |err| {
                std.log.warn("Failed to apply Content-Security-Policy: {}", .{err});
            };
        }

        const body = response.body;

        // Free previous HTML source if it exists
        if (tab.current_html_source) |old_source| {
            self.allocator.free(old_source);
            tab.current_html_source = null;
        }

        if (url.*.view_source) {
            // Use the new layoutSourceCode function for view-source mode
            defer if (!std.mem.eql(u8, url.*.scheme, "about")) self.allocator.free(body);

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

            tab.js_render_context = .{};
            tab.js_render_context_initialized = false;
            self.js_engine.setNodes(null);

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
            if (!std.mem.eql(u8, url.*.scheme, "about")) {
                tab.current_html_source = body;
            }

            // Update the JS engine with the current nodes for DOM API
            self.js_engine.setNodes(&tab.current_node.?);
            tab.js_render_context.browser_ptr = @as(?*anyopaque, @ptrCast(self));
            tab.js_render_context.tab_ptr = @as(?*anyopaque, @ptrCast(tab));
            tab.js_render_context_initialized = true;
            self.js_engine.setRenderCallback(
                jsRenderCallback,
                @ptrCast(&tab.js_render_context),
            );
            self.js_engine.setXhrCallback(
                jsXhrCallback,
                @ptrCast(&tab.js_render_context),
            );

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
                const script_url = url.*.resolve(self.allocator, src) catch |err| {
                    std.log.warn("Failed to resolve script URL {s}: {}", .{ src, err });
                    continue;
                };
                defer script_url.free(self.allocator);

                if (!tab.allowedRequest(script_url)) {
                    std.log.warn("Blocked script {s} due to CSP", .{src});
                    continue;
                }

                // Fetch the script
                const script_response = self.fetchBody(script_url, url.*, null) catch |err| {
                    std.log.warn("Failed to load script {s}: {}", .{ src, err });
                    continue;
                };
                defer if (script_response.csp_header) |hdr| self.allocator.free(hdr);

                var script_body = script_response.body;
                if (std.mem.eql(u8, script_url.scheme, "data") or std.mem.eql(u8, script_url.scheme, "about")) {
                    const copy = try self.allocator.alloc(u8, script_body.len);
                    @memcpy(copy, script_body);
                    script_body = copy;
                }
                defer self.allocator.free(script_body);

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
                const stylesheet_url = url.*.resolve(self.allocator, href) catch |err| {
                    std.log.warn("Failed to resolve stylesheet URL {s}: {}", .{ href, err });
                    continue;
                };
                defer stylesheet_url.free(self.allocator);

                if (!tab.allowedRequest(stylesheet_url)) {
                    std.log.warn("Blocked stylesheet {s} due to CSP", .{href});
                    continue;
                }

                // Fetch the stylesheet
                const css_response = self.fetchBody(stylesheet_url, url.*, null) catch |err| {
                    std.log.warn("Failed to load stylesheet {s}: {}", .{ href, err });
                    continue;
                };
                defer if (css_response.csp_header) |hdr| self.allocator.free(hdr);

                var css_text = css_response.body;
                if (std.mem.eql(u8, stylesheet_url.scheme, "data") or std.mem.eql(u8, stylesheet_url.scheme, "about")) {
                    const copy = try self.allocator.alloc(u8, css_text.len);
                    @memcpy(copy, css_text);
                    css_text = copy;
                }

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

        // Record navigation history and update current URL ownership
        try tab.history.append(self.allocator, url);
        tab.current_url = url;
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
        try self.canvas.setColorRGB(255, 255, 255);
        try self.canvas.clear();

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

        try self.drawScrollbar(tab);
    }

    fn drawDisplayItem(self: *Browser, item: DisplayItem, scroll_offset: i32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                const screen_y = glyph_item.y - scroll_offset;
                if (screen_y >= 0 and screen_y < self.window_height) {
                    const dst_rect: sdl2.Rectangle = .{
                        .x = glyph_item.x,
                        .y = screen_y,
                        .width = glyph_item.glyph.w,
                        .height = glyph_item.glyph.h,
                    };

                    // Apply text color to the glyph texture
                    try glyph_item.glyph.texture.?.setColorMod(.{
                        .r = glyph_item.color.r,
                        .g = glyph_item.color.g,
                        .b = glyph_item.color.b,
                    });

                    try self.canvas.copy(glyph_item.glyph.texture.?, dst_rect, null);
                }
            },
            .rect => |rect_item| {
                const top = rect_item.y1 - scroll_offset;
                const bottom = rect_item.y2 - scroll_offset;
                if (bottom > 0 and top < self.window_height) {
                    const width = rect_item.x2 - rect_item.x1;
                    const height = bottom - top;
                    if (width > 0 and height > 0) {
                        try self.canvas.setColor(.{
                            .r = rect_item.color.r,
                            .g = rect_item.color.g,
                            .b = rect_item.color.b,
                            .a = rect_item.color.a,
                        });

                        const rect: sdl2.Rectangle = .{
                            .x = rect_item.x1,
                            .y = top,
                            .width = width,
                            .height = height,
                        };
                        try self.canvas.fillRect(rect);
                    }
                }
            },
            .line => |line_item| {
                const y1 = line_item.y1 - scroll_offset;
                const y2 = line_item.y2 - scroll_offset;
                try self.canvas.setColor(.{
                    .r = line_item.color.r,
                    .g = line_item.color.g,
                    .b = line_item.color.b,
                    .a = line_item.color.a,
                });
                // SDL doesn't have line thickness directly, draw as rect for thickness > 1
                if (line_item.thickness == 1) {
                    try self.canvas.drawLine(line_item.x1, y1, line_item.x2, y2);
                } else {
                    // Draw thick line as rectangle
                    const is_horizontal = (line_item.y1 == line_item.y2);
                    if (is_horizontal) {
                        const width: i32 = @intCast(@abs(line_item.x2 - line_item.x1));
                        const rect: sdl2.Rectangle = .{
                            .x = @min(line_item.x1, line_item.x2),
                            .y = y1 - @divTrunc(line_item.thickness, 2),
                            .width = width,
                            .height = line_item.thickness,
                        };
                        try self.canvas.fillRect(rect);
                    } else {
                        const height: i32 = @intCast(@abs(y2 - y1));
                        const rect: sdl2.Rectangle = .{
                            .x = line_item.x1 - @divTrunc(line_item.thickness, 2),
                            .y = @min(y1, y2),
                            .width = line_item.thickness,
                            .height = height,
                        };
                        try self.canvas.fillRect(rect);
                    }
                }
            },
            .outline => |outline_item| {
                const r = outline_item.rect;
                const top = r.top - scroll_offset;
                const bottom = r.bottom - scroll_offset;
                try self.canvas.setColor(.{
                    .r = outline_item.color.r,
                    .g = outline_item.color.g,
                    .b = outline_item.color.b,
                    .a = outline_item.color.a,
                });
                // Draw four lines for the outline
                try self.canvas.drawLine(r.left, top, r.right, top); // top
                try self.canvas.drawLine(r.right, top, r.right, bottom); // right
                try self.canvas.drawLine(r.right, bottom, r.left, bottom); // bottom
                try self.canvas.drawLine(r.left, bottom, r.left, top); // left
            },
        }
    }

    pub fn drawScrollbar(self: *Browser, tab: *Tab) !void {
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
        const track_rect: sdl2.Rectangle = .{
            .x = self.window_width - scrollbar_width,
            .y = self.chrome.bottom,
            .width = scrollbar_width,
            .height = track_height,
        };
        // Light gray
        try self.canvas.setColor(.{
            .r = 200,
            .g = 200,
            .b = 200,
            .a = 255,
        });
        try self.canvas.fillRect(track_rect);

        // Draw scrollbar thumb (movable part) - offset by chrome height
        const thumb_rect: sdl2.Rectangle = .{
            .x = self.window_width - scrollbar_width,
            .y = self.chrome.bottom + thumb_y_offset,
            .width = scrollbar_width,
            .height = thumb_height,
        };
        try self.canvas.setColor(.{
            .r = 0,
            .g = 102,
            .b = 204,
            .a = 255,
        });
        try self.canvas.fillRect(thumb_rect);
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

        // Free cookie jar values and map storage
        var cookie_it = self.cookie_jar.iterator();
        while (cookie_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cookie_jar.deinit();

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

        // c.SDL_DestroyRenderer(self.canvas);
        // c.SDL_DestroyWindow(self.window);
        // c.SDL_Quit();
        sdl2.quit();
    }
};

fn jsRenderCallback(context: ?*anyopaque) anyerror!void {
    const ctx_ptr = context orelse return;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return;
    const tab_ptr = ctx.tab_ptr orelse return;

    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    try tab.render(browser);
}

fn jsXhrCallback(
    context: ?*anyopaque,
    method: []const u8,
    url_str: []const u8,
    body: ?[]const u8,
) anyerror!js_module.XhrResult {
    _ = method;

    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    const allocator = browser.allocator;

    var resolved_url: Url = undefined;
    if (tab.current_url) |current_ptr| {
        resolved_url = current_ptr.*.resolve(allocator, url_str) catch |err| blk: {
            std.log.warn("Failed to resolve XHR URL {s} relative to page: {}", .{ url_str, err });
            break :blk try Url.init(allocator, url_str);
        };
    } else {
        resolved_url = try Url.init(allocator, url_str);
    }
    defer resolved_url.free(allocator);

    if (tab.current_url) |current_ptr| {
        if (!current_ptr.*.sameOrigin(resolved_url)) {
            const current_host = current_ptr.*.host orelse "";
            const target_host = resolved_url.host orelse "";
            std.log.warn(
                "Blocked cross-origin XHR {s}://{s}:{d} -> {s}://{s}:{d}",
                .{ current_ptr.*.scheme, current_host, current_ptr.*.port, resolved_url.scheme, target_host, resolved_url.port },
            );
            return error.CrossOriginBlocked;
        }
    }

    if (!tab.allowedRequest(resolved_url)) {
        const target_host = resolved_url.host orelse "";
        std.log.warn(
            "Blocked XHR to {s}://{s}:{d} due to CSP",
            .{ resolved_url.scheme, target_host, resolved_url.port },
        );
        return error.CspViolation;
    }

    var current_url_value: ?Url = null;
    if (tab.current_url) |cur_ptr| {
        current_url_value = cur_ptr.*;
    }

    const response = try browser.fetchBody(resolved_url, current_url_value, body);
    defer if (response.csp_header) |hdr| allocator.free(hdr);

    var response_body = response.body;

    var should_free_response = true;
    var response_allocator: ?std.mem.Allocator = allocator;

    if (std.mem.eql(u8, resolved_url.scheme, "data")) {
        const copy = try allocator.alloc(u8, response_body.len);
        @memcpy(copy, response_body);
        response_body = copy;
    } else if (std.mem.eql(u8, resolved_url.scheme, "about")) {
        should_free_response = false;
        response_allocator = null;
    }

    return .{
        .data = response_body,
        .allocator = response_allocator,
        .should_free = should_free_response,
    };
}
