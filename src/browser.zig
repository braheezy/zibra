const std = @import("std");
const builtin = @import("builtin");

const grapheme = @import("grapheme");
const FontManager = @import("font.zig").FontManager;
const Glyph = @import("font.zig").Glyph;
const Url = @import("url.zig").Url;
const Connection = @import("url.zig").Connection;
const Cache = @import("cache.zig").Cache;
const ArrayList = std.ArrayList;
const font_assets = @import("font-assets");

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
pub const window_width = 800;
const window_height = 600;
pub const h_offset = 13;
const v_offset = 18;
const scroll_increment = 100;
// *********************************************************

// DisplayItem is a struct that holds the position and glyph to be displayed.
const DisplayItem = struct {
    x: i32,
    y: i32,
    glyph: *Glyph,
};

// Browser is the main struct that holds the state of the browser.
pub const Browser = struct {
    // Memory allocator for the browser
    allocator: std.mem.Allocator,
    // SDL window handle
    window: *c.SDL_Window,
    // SDL renderer handle
    canvas: *c.SDL_Renderer,
    // Font manager for handling fonts and glyphs
    font_manager: FontManager,
    // Map of active connections. The key is the host and the value a Connection to use.
    socket_map: std.StringHashMap(Connection),
    // Cache for storing fetched resources
    cache: Cache,
    // List of items to be displayed
    display_list: ?[]DisplayItem = null,
    // Total height of the content
    content_height: i32 = 0,
    // Current scroll offset
    scroll_offset: i32 = 0,

    // Create a new Browser instance
    pub fn init(al: std.mem.Allocator) !Browser {
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
            window_width,
            window_height,
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

        return Browser{
            .allocator = al,
            .window = screen,
            .canvas = renderer,
            .font_manager = try FontManager.init(al, renderer),
            .socket_map = std.StringHashMap(Connection).init(al),
            .cache = try Cache.init(al),
        };
    }

    // Free the resources used by the browser
    pub fn free(self: Browser) void {
        // clean up hash map for fonts
        self.font_manager.deinit();

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

        // clean up sdl resources
        c.SDL_DestroyRenderer(self.canvas);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    // Run the browser event loop
    pub fn run(self: *Browser) !void {
        var quit = false;
        while (!quit) {
            // Handle events
            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event) != 0) {
                switch (event.type) {
                    // Quit when the window is closed
                    c.SDL_QUIT => quit = true,
                    // Handle key presses
                    c.SDL_KEYDOWN => {
                        const key = event.key.keysym.sym;
                        if (key == c.SDLK_DOWN) {
                            updateScroll(self, .ScrollDown);
                        }
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

    // Update the scroll offset
    pub fn updateScroll(self: *Browser, action: enum { ScrollDown }) void {
        switch (action) {
            .ScrollDown => {
                const max_scroll = if (self.content_height > window_height)
                    // Subtract window height to prevent scrolling past the end
                    self.content_height - window_height
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
        }
    }

    // Send request to a URL, load response into browser
    pub fn load(
        self: *Browser,
        url: Url,
    ) !void {
        std.log.info("Loading: {s}", .{url.path});

        // Do the request, getting back the body of the response.
        const body = if (std.mem.eql(u8, url.scheme, "file"))
            try url.fileRequest(self.allocator)
        else if (std.mem.eql(u8, url.scheme, "data"))
            url.path
        else
            try url.httpRequest(
                self.allocator,
                &self.socket_map,
                &self.cache,
                0,
            );
        defer self.allocator.free(body);

        // Clean up the response for display
        const parsed_content = try self.lex(body, url.view_source);
        defer self.allocator.free(parsed_content);

        // Arrange the response for display
        try self.layout(self.allocator, parsed_content);
    }

    // Show the body of the response, sans tags
    pub fn lex(self: *Browser, body: []const u8, view_content: bool) ![]const u8 {
        if (view_content) {
            // they don't want it lexed
            return body;
        }

        var content_builder = std.ArrayList(u8).init(self.allocator);
        defer content_builder.deinit();
        var temp_line = std.ArrayList(u8).init(self.allocator);
        defer temp_line.deinit();

        var in_tag = false;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const char = body[i];
            if (char == '<') {
                in_tag = true;
                if (temp_line.items.len > 0) {
                    try content_builder.appendSlice(std.mem.trim(
                        u8,
                        temp_line.items,
                        " \r\n\t",
                    ));
                    try content_builder.append('\n');
                    temp_line.clearAndFree();
                }
            } else if (char == '>') {
                in_tag = false;
            } else if (char == '&') {
                const entity = try lexEntity(body[i..]);
                try temp_line.appendSlice(entity);
                i += entity.len - 1;
            } else if (!in_tag) {
                if (char != '\n' and char != '\r') {
                    try temp_line.append(char);
                }
            }
        }
        // Add remaining content to the final result
        if (temp_line.items.len > 0) {
            try content_builder.appendSlice(std.mem.trim(
                u8,
                temp_line.items,
                " \r\n\t",
            ));
        }

        return try content_builder.toOwnedSlice();
    }

    pub fn lexEntity(text: []const u8) ![]const u8 {
        // Find the end of the entity
        if (std.mem.indexOf(u8, text, ";")) |entity_end_index| {
            const entity = text[0 .. entity_end_index + 1];
            if (std.mem.eql(u8, entity, "&amp;")) {
                return "&";
            } else if (std.mem.eql(u8, entity, "&lt;")) {
                return "<";
            } else if (std.mem.eql(u8, entity, "&gt;")) {
                return ">";
            } else {
                return entity;
            }
        } else {
            return error.EntityNotFound;
        }
    }

    // Draw the browser content
    pub fn draw(self: Browser) !void {
        for (self.display_list.?) |item| {
            const screen_y = item.y - self.scroll_offset;
            if (screen_y >= 0 and screen_y < window_height) {
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
    }

    // Arrange the content for display
    pub fn layout(self: *Browser, al: std.mem.Allocator, text: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text)) {
            return error.InvalidUTF8;
        }
        var display_list = std.ArrayList(DisplayItem).init(al);
        var cursor_x: i32 = h_offset;
        var cursor_y: i32 = v_offset;

        const gd = try grapheme.GraphemeData.init(al);
        defer gd.deinit();

        var iter = grapheme.Iterator.init(text, &gd);
        while (iter.next()) |gc| {
            const cluster_bytes = gc.bytes(text);

            // Check for newline character
            if (cluster_bytes[0] == '\n') {
                cursor_x = h_offset;
                cursor_y += self.font_manager.current_font.?.line_height;
                continue;
            }

            // Get or create a Glyph for this grapheme cluster
            const glyph = try self.font_manager.getGlyph(self.font_manager.current_font.?, cluster_bytes);

            // Check for line wrapping
            if (cursor_x + glyph.w > window_width - h_offset) {
                cursor_x = h_offset;
                cursor_y += self.font_manager.current_font.?.line_height;
            }

            // Add the glyph to the display list
            try display_list.append(.{
                .x = cursor_x,
                .y = cursor_y,
                .glyph = glyph,
            });

            // Advance cursor for the next glyph
            cursor_x += glyph.w;
        }

        self.content_height = cursor_y + self.font_manager.current_font.?.line_height;
        self.display_list = try display_list.toOwnedSlice();
    }
};

// helper function to convert a slice to a sentinel array, because C expects that for strings
fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}
