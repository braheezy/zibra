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

// Display items are the drawing commands emitted by layout.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
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
};

// Browser is the main struct that holds the state of the browser.
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
    // List of items to be displayed
    display_list: ?[]DisplayItem = null,
    // Current HTML node tree (when using parser)
    current_node: ?Node = null,
    // Layout tree for the document
    document_layout: ?*Layout.DocumentLayout = null,
    // Total height of the content
    content_height: i32 = 0,
    // Current scroll offset
    scroll_offset: i32 = 0,
    // Window dimensions
    window_width: i32 = initial_window_width,
    window_height: i32 = initial_window_height,
    layout_engine: *Layout,
    // Default browser stylesheet rules
    default_style_sheet_rules: []CSSParser.CSSRule,

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
            window_flags | c.SDL_WINDOW_RESIZABLE,
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

        return Browser{
            .allocator = al,
            .window = screen,
            .canvas = renderer,
            .http_client = .{ .allocator = al },
            .cache = try Cache.init(al),
            .layout_engine = try Layout.init(
                al,
                renderer,
                initial_window_width,
                initial_window_height,
                rtl_flag,
            ),
            .default_style_sheet_rules = default_rules,
        };
    }

    // Free the resources used by the browser
    // Deprecated: use deinit() instead
    pub fn free(self: *Browser) void {
        self.deinit();
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
                    c.SDL_KEYDOWN => self.handleKeyEvent(event.key.keysym.sym),
                    // Handle mouse wheel events
                    c.SDL_MOUSEWHEEL => {
                        if (event.wheel.y > 0) {
                            self.updateScroll(.Up);
                        } else if (event.wheel.y < 0) {
                            self.updateScroll(.Down);
                        }
                    },
                    c.SDL_WINDOWEVENT => {
                        try self.handleWindowEvent(event.window);
                    },
                    else => {},
                }
            }

            // Clear canvas with white background
            _ = c.SDL_SetRenderDrawColor(self.canvas, 255, 255, 255, 255);
            _ = c.SDL_RenderClear(self.canvas);

            // draw browser content
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

    fn handleKeyEvent(self: *Browser, key: c.SDL_Keycode) void {
        switch (key) {
            c.SDLK_DOWN => self.updateScroll(.Down),
            c.SDLK_UP => self.updateScroll(.Up),
            else => {},
        }
    }

    // Update the scroll offset
    pub fn updateScroll(
        self: *Browser,
        action: enum {
            Down,
            Up,
        },
    ) void {
        switch (action) {
            .Down => {
                const max_scroll = if (self.content_height > self.window_height)
                    // Subtract window height to prevent scrolling past the end
                    self.content_height - self.window_height
                else
                    // No scrolling needed, content fits in window
                    0;

                // Only scroll if there is content to scroll
                if (self.scroll_offset < max_scroll) {
                    self.scroll_offset += scroll_increment;
                    // Prevent scrolling past the end
                    if (self.scroll_offset > max_scroll) {
                        self.scroll_offset = max_scroll;
                    }
                }
            },
            .Up => {
                if (self.scroll_offset > 0) {
                    self.scroll_offset -= scroll_increment;
                    // Prevent scrolling past the beginning
                    if (self.scroll_offset < 0) {
                        self.scroll_offset = 0;
                    }
                }
            },
        }
    }

    pub fn fetchBody(self: *Browser, url: Url) ![]const u8 {
        return if (std.mem.eql(u8, url.scheme, "file:"))
            try url.fileRequest(self.allocator)
        else if (std.mem.eql(u8, url.scheme, "data:"))
            url.path
        else if (std.mem.eql(u8, url.scheme, "about:"))
            url.aboutRequest()
        else
            try url.httpRequest(
                self.allocator,
                &self.http_client,
                &self.cache,
            );
    }

    // Send request to a URL, load response into browser
    pub fn load(
        self: *Browser,
        url: Url,
    ) !void {
        std.log.info("Loading: {s}", .{url.path});

        // Do the request, getting back the body of the response.
        const body = try self.fetchBody(url);

        defer if (!std.mem.eql(u8, url.scheme, "about:")) self.allocator.free(body);

        if (url.view_source) {
            // Use the new layoutSourceCode function for view-source mode
            if (self.display_list) |items| {
                self.allocator.free(items);
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

            self.display_list = try self.layout_engine.layoutSourceCode(body);
            self.content_height = self.layout_engine.content_height;
        } else {
            // Parse HTML into a node tree
            var html_parser = try HTMLParser.init(self.allocator, body);
            defer html_parser.deinit(self.allocator);

            // Clear any previous node tree
            if (self.current_node) |node| {
                var n = node;
                n.deinit(self.allocator);
                self.current_node = null;
            }

            // Parse the HTML and store the root node
            self.current_node = try html_parser.parse();

            // Find all linked stylesheets
            var node_list = std.ArrayList(*parser.Node).empty;
            defer node_list.deinit(self.allocator);
            try parser.treeToList(self.allocator, &self.current_node.?, &node_list);

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

            // Create an arena allocator for CSS parsing
            // All CSS string data will be allocated in this arena and freed at once
            var css_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer css_arena.deinit();
            const css_allocator = css_arena.allocator();

            // Load and parse external stylesheets
            var all_rules = std.ArrayList(CSSParser.CSSRule).empty;

            // Track how many default rules we have so we don't double-free them
            const default_rules_count = self.default_style_sheet_rules.len;

            defer {
                // Only deinit rules that were allocated in this function (external stylesheets)
                // Skip the first default_rules_count rules as they're owned by the browser
                // Note: Property strings are in the arena, only need to free selectors
                if (all_rules.items.len > default_rules_count) {
                    for (all_rules.items[default_rules_count..]) |*rule| {
                        var mutable_rule = rule;
                        mutable_rule.deinit(css_allocator);
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
                const css_text = self.fetchBody(stylesheet_url) catch |err| {
                    std.log.warn("Failed to load stylesheet {s}: {}", .{ href, err });
                    continue;
                };
                // Copy css_text into the arena so property strings stay alive
                const css_text_copy = try css_allocator.dupe(u8, css_text);
                self.allocator.free(css_text);

                // Parse the stylesheet using the CSS arena allocator
                var css_parser = try CSSParser.init(css_allocator, css_text_copy);
                defer css_parser.deinit(css_allocator);

                const parsed_rules = css_parser.parse(css_allocator) catch |err| {
                    std.log.warn("Failed to parse stylesheet {s}: {}", .{ href, err });
                    continue;
                };

                // Add the parsed rules to our collection
                for (parsed_rules) |rule| {
                    try all_rules.append(self.allocator, rule);
                }

                // Note: parsed_rules slice is in the arena, will be freed automatically
            }

            // Sort rules by cascade priority (more specific selectors override less specific)
            // Stable sort preserves file order for rules with equal priority
            std.mem.sort(CSSParser.CSSRule, all_rules.items, {}, struct {
                fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                    return a.cascadePriority() < b.cascadePriority();
                }
            }.lessThan);

            // Apply all stylesheet rules and inline styles (sorted by cascade order)
            try parser.style(self.allocator, &self.current_node.?, all_rules.items);

            // Layout using the HTML node tree
            try self.layoutWithNodes();
        }
    }

    // New method to layout using HTML nodes with the tree-based layout
    pub fn layoutWithNodes(self: *Browser) !void {
        if (self.current_node == null) {
            return error.NoNodeToLayout;
        }

        // Free existing display list if it exists
        if (self.display_list) |items| {
            self.allocator.free(items);
        }

        // Clear previous document layout if it exists
        if (self.document_layout != null) {
            self.document_layout.?.deinit();
            self.allocator.destroy(self.document_layout.?);
            self.document_layout = null;
        }

        // Create and layout the document tree
        self.document_layout = try self.layout_engine.buildDocument(self.current_node.?);

        // Paint the document to produce draw commands
        self.display_list = try self.layout_engine.paintDocument(self.document_layout.?);

        // Update content height from the layout engine
        self.content_height = self.layout_engine.content_height;
    }

    // Draw the browser content
    pub fn draw(self: Browser) !void {
        if (self.display_list == null) {
            return;
        }
        for (self.display_list.?) |item| {
            switch (item) {
                .glyph => |glyph_item| {
                    const screen_y = glyph_item.y - self.scroll_offset;
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
                    const top = rect_item.y1 - self.scroll_offset;
                    const bottom = rect_item.y2 - self.scroll_offset;
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
            }
        }

        self.drawScrollbar();
    }

    pub fn drawScrollbar(self: Browser) void {
        if (self.content_height <= self.window_height) {
            // No scrollbar needed if content fits in the window
            return;
        }

        // Calculate scrollbar thumb size and position
        const track_height = self.window_height;
        const thumb_height: i32 = @intFromFloat(@as(f32, @floatFromInt(self.window_height)) * (@as(f32, @floatFromInt(self.window_height)) / @as(f32, @floatFromInt(self.content_height))));
        const max_scroll = self.content_height - self.window_height;
        const thumb_y: i32 = @intFromFloat(@as(f32, @floatFromInt(self.scroll_offset)) / @as(f32, @floatFromInt(max_scroll)) * (@as(f32, @floatFromInt(self.window_height)) - @as(f32, @floatFromInt(thumb_height))));

        // Draw scrollbar track (background)
        var track_rect: c.SDL_Rect = .{
            .x = self.window_width - scrollbar_width,
            .y = 0,
            .w = scrollbar_width,
            .h = track_height,
        };
        // Light gray
        _ = c.SDL_SetRenderDrawColor(self.canvas, 200, 200, 200, 255);
        _ = c.SDL_RenderFillRect(self.canvas, &track_rect);

        // Draw scrollbar thumb (movable part)
        var thumb_rect: c.SDL_Rect = .{
            .x = self.window_width - scrollbar_width,
            .y = thumb_y,
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
            Node.deinit(&node, self.allocator);
        }

        // Clean up default stylesheet rules
        for (self.default_style_sheet_rules) |*rule| {
            var mutable_rule = rule;
            mutable_rule.deinit(self.allocator);
        }
        self.allocator.free(self.default_style_sheet_rules);

        // clean up layout
        self.layout_engine.deinit();

        c.SDL_DestroyRenderer(self.canvas);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};
