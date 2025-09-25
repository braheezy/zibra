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
const Connection = @import("url.zig").Connection;
const Cache = @import("cache.zig").Cache;
const ArrayList = std.ArrayList;
const Layout = @import("Layout.zig");
const parser = @import("parser.zig");
const HTMLParser = parser.HTMLParser;
const Node = parser.Node;
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const dbg = std.debug.print;

fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

const stdout = std.io.getStdOut().writer();

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
    // Map of active connections. The key is the host and the value a Connection to use.
    socket_map: std.StringHashMap(Connection),
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

        return Browser{
            .allocator = al,
            .window = screen,
            .canvas = renderer,
            .socket_map = std.StringHashMap(Connection).init(al),
            .cache = try Cache.init(al),
            .layout_engine = try Layout.init(
                al,
                renderer,
                initial_window_width,
                initial_window_height,
                rtl_flag,
            ),
        };
    }

    // Free the resources used by the browser
    pub fn free(self: *Browser) void {
        // clean up hash map for sockets, including values
        var sockets_iter = self.socket_map.valueIterator();
        while (sockets_iter.next()) |socket| {
            switch (socket.*) {
                .Tcp => socket.Tcp.close(),
                .Tls => socket.Tls.stream.close(),
            }
        }

        // make mutable copies to free the resources
        var cache = self.cache;
        cache.free();
        var socket_map = self.socket_map;
        socket_map.deinit();

        // free display list slice
        if (self.display_list) |items| self.allocator.free(items);

        if (self.document_layout) |doc| {
            doc.deinit();
            self.allocator.destroy(doc);
            self.document_layout = null;
        }

        // Free the node tree if it exists
        if (self.current_node) |node| {
            node.deinit(self.allocator);
            self.current_node = null;
        }

        // clean up layout
        self.layout_engine.deinit();

        // clean up sdl resources
        c.SDL_DestroyRenderer(self.canvas);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
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

            // Clear canvas with off-white
            _ = c.SDL_SetRenderDrawColor(self.canvas, 250, 244, 237, 255);
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
                _ = c.SDL_SetRenderDrawColor(self.canvas, 250, 244, 237, 255);
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
                &self.socket_map,
                &self.cache,
                0,
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
                node.deinit(self.allocator);
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
                node.deinit(self.allocator);
                self.current_node = null;
            }

            // Parse the HTML and store the root node
            self.current_node = try html_parser.parse();

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
        var it = self.socket_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.socket_map.deinit();

        // Free cache
        self.cache.deinit();

        // Clean up any display list
        if (self.display_list) |list| {
            self.allocator.free(list);
        }

        // Clean up document layout tree
        if (self.document_layout) |doc| {
            doc.deinit();
            self.allocator.destroy(doc);
        }

        // clean up layout
        self.layout_engine.deinit();

        c.SDL_DestroyRenderer(self.canvas);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};
