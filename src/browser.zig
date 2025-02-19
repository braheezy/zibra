const std = @import("std");
const builtin = @import("builtin");

const token = @import("token.zig");
const Token = token.Token;

const grapheme = @import("grapheme");
const code_point = @import("code_point");
const FontManager = @import("font.zig").FontManager;
const Glyph = @import("font.zig").Glyph;
const FontWeight = @import("font.zig").FontWeight;
const FontSlant = @import("font.zig").FontSlant;
const Url = @import("url.zig").Url;
const Connection = @import("url.zig").Connection;
const Cache = @import("cache.zig").Cache;
const ArrayList = std.ArrayList;
const font_assets = @import("font-assets");
const Layout = @import("Layout.zig");
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

// DisplayItem is a struct that holds the position and glyph to be displayed.
pub const DisplayItem = struct {
    // X coordinate of the display item
    x: i32,
    // Y coordinate of the display item
    y: i32,
    // Pointer to the glyph to be displayed
    glyph: Glyph,
};

// pub const TokenType = enum {
//     Text,
//     Tag,
// };

// pub const Token = struct {
//     ty: TokenType,
//     content: []const u8, // For text tokens, the text; for tag tokens, the tag name

//     pub fn deinit(self: Token, allocator: std.mem.Allocator) void {
//         allocator.free(self.content);
//     }
// };

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
    // Current content to be displayed
    current_content: ?[]const Token = null,
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
        if (self.current_content) |items| {
            for (items) |item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(items);
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

                if (self.current_content) |text| {
                    if (self.display_list) |list| {
                        self.allocator.free(list);
                        self.display_list = null;
                    }
                    try self.layout(text);
                }

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

    // Send request to a URL, load response into browser
    pub fn load(
        self: *Browser,
        url: Url,
    ) !void {
        std.log.info("Loading: {s}", .{url.path});

        // Do the request, getting back the body of the response.
        const body = if (std.mem.eql(u8, url.scheme, "file:"))
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

        defer {
            if (!std.mem.eql(u8, url.scheme, "about:")) {
                self.allocator.free(body);
            }
        }

        if (url.view_source) {
            // If "view_source" is true, maybe you do NOTHING but show raw text.
            // Or you still produce tokens, up to you.
            // Minimal approach: return an empty token list or a single text token:
            var plain = std.ArrayList(Token).init(self.allocator);
            defer plain.deinit();

            const body_copy = try self.allocator.dupe(u8, body);
            defer self.allocator.free(body_copy);

            try plain.append(Token{ .text = body_copy });

            const plain_tokens_slice = try plain.toOwnedSlice();
            try self.layout(plain_tokens_slice);
        } else {
            var tokens_array = try self.lexTokens(body);
            // defer {
            //     for (tokens_array.items) |tk| {
            //         tk.deinit(self.allocator);
            //     }
            //     tokens_array.deinit();
            // }

            // Update the SDL window title based on the <title> tag.
            std.log.info("Updating current content with {d} tokens", .{tokens_array.items.len});
            self.current_content = try tokens_array.toOwnedSlice();
            try self.layout(self.current_content.?);
        }
    }

    pub fn lexTokens(self: *Browser, body: []const u8) !std.ArrayList(Token) {
        // We'll store tokens here
        var tokens = std.ArrayList(Token).init(self.allocator);

        var temp_text = std.ArrayList(u8).init(self.allocator);
        defer temp_text.deinit();

        var tag_buffer = std.ArrayList(u8).init(self.allocator);
        defer tag_buffer.deinit();

        var in_tag = false;
        var i: usize = 0;

        while (i < body.len) : (i += 1) {
            const char = body[i];

            if (char == '<') {
                // We're entering a tag
                // If we have accumulated text, flush it to a TEXT token
                if (temp_text.items.len > 0) {
                    try tokens.append(Token{
                        .text = try self.allocator.dupe(u8, temp_text.items),
                    });
                    temp_text.clearRetainingCapacity();
                }

                in_tag = true;
                tag_buffer.clearRetainingCapacity();
                continue;
            }

            if (char == '>') {
                // We're leaving a tag
                in_tag = false;

                // Now tag_buffer has something like "b", "/b", "p", "/p"
                const tag_ptr = try token.Tag.init(self.allocator, tag_buffer.items);
                try tokens.append(Token{ .tag = tag_ptr });
                continue;
            }

            if (in_tag) {
                // Accumulate chars inside the < > pair
                try tag_buffer.append(char);
                continue;
            }

            // Outside a tag
            if (char == '&') {
                // Entities
                if (lexEntity(body[i..])) |entity| {
                    try temp_text.appendSlice(entity);
                    i += std.mem.indexOf(u8, body[i..], ";").?;
                } else {
                    try temp_text.append('&');
                }
                continue;
            }

            // If it's a raw newline, keep it as is. We will handle it in layout.
            try temp_text.append(char);
        }

        // If there's leftover text at the end, produce a final TEXT token
        if (temp_text.items.len > 0) {
            try tokens.append(Token{
                .text = try self.allocator.dupe(u8, temp_text.items),
            });
        }

        return tokens;
    }

    pub fn lexEntity(text: []const u8) ?[]const u8 {
        if (std.mem.indexOf(u8, text, ";")) |entity_end_index| {
            const entity = text[0 .. entity_end_index + 1];

            return if (std.mem.eql(u8, entity, "&amp;"))
                "&"
            else if (std.mem.eql(u8, entity, "&lt;"))
                "<"
            else if (std.mem.eql(u8, entity, "&gt;"))
                ">"
            else if (std.mem.eql(u8, entity, "&quot;"))
                "\""
            else if (std.mem.eql(u8, entity, "&apos;"))
                "'"
            else
                null;
        } else {
            return null;
        }
    }

    // Draw the browser content
    pub fn draw(self: Browser) !void {
        if (self.display_list == null) {
            return;
        }
        for (self.display_list.?) |item| {
            const screen_y = item.y - self.scroll_offset;
            if (screen_y >= 0 and screen_y < self.window_height) {
                var dst_rect: c.SDL_Rect = .{
                    .x = item.x,
                    .y = screen_y,
                    .w = item.glyph.w,
                    .h = item.glyph.h,
                };

                _ = c.SDL_RenderCopy(
                    self.canvas,
                    item.glyph.texture,
                    null,
                    &dst_rect,
                );
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

    // Arrange the content for display
    pub fn layout(self: *Browser, tokens: []const Token) !void {
        // Free existing display list if it exists
        if (self.display_list) |items| {
            self.allocator.free(items);
        }

        self.display_list = try self.layout_engine.layoutTokens(tokens);
        self.content_height = self.layout_engine.content_height;
    }
};
