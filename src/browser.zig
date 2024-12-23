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
const initial_window_width = 800;
const initial_window_height = 600;
const h_offset = 13;
const v_offset = 18;
const scroll_increment = 100;
const scrollbar_width = 10;
// *********************************************************

// DisplayItem is a struct that holds the position and glyph to be displayed.
const DisplayItem = struct {
    // X coordinate of the display item
    x: i32,
    // Y coordinate of the display item
    y: i32,
    // Pointer to the glyph to be displayed
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
    // Current content to be displayed
    current_content: ?[]const u8 = null,
    // Total height of the content
    content_height: i32 = 0,
    // Current scroll offset
    scroll_offset: i32 = 0,
    // Window dimensions
    window_width: i32 = initial_window_width,
    window_height: i32 = initial_window_height,

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

    pub fn handleResize(self: *Browser) !void {
        // Adjust renderer viewport to match new window size
        _ = c.SDL_RenderSetViewport(self.canvas, null);

        // Re-run layout with existing content
        if (self.current_content) |text| {
            if (self.display_list) |list| {
                self.allocator.free(list);
                self.display_list = null;
            }
            try self.layout(text);
        }
    }

    pub fn handleWindowEvent(self: *Browser, window_event: c.SDL_WindowEvent) !void {
        const data1 = window_event.data1;
        const data2 = window_event.data2;

        switch (window_event.event) {
            c.SDL_WINDOWEVENT_RESIZED, c.SDL_WINDOWEVENT_SIZE_CHANGED => {
                self.window_width = data1;
                self.window_height = data2;

                _ = c.SDL_RenderSetViewport(self.canvas, null);

                if (self.current_content) |text| {
                    if (self.display_list) |list| {
                        self.allocator.free(list);
                        self.display_list = null;
                    }
                    try self.layout(text);
                }

                _ = c.SDL_SetRenderDrawColor(self.canvas, 250, 244, 237, 255);
                _ = c.SDL_RenderClear(self.canvas);
                try self.draw();
                c.SDL_RenderPresent(self.canvas);
            },
            c.SDL_WINDOWEVENT_EXPOSED, c.SDL_WINDOWEVENT_MAXIMIZED, c.SDL_WINDOWEVENT_RESTORED => {
                try self.handleResize();
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
        try self.layout(parsed_content);
    }

    // Show the body of the response, sans tags
    pub fn lex(self: *Browser, body: []const u8, view_content: bool) ![]const u8 {
        if (view_content) {
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

            // Entering a tag
            if (char == '<') {
                in_tag = true;

                // Flush accumulated text before the tag
                if (temp_line.items.len > 0) {
                    try content_builder.appendSlice(temp_line.items);
                    temp_line.clearAndFree();
                }
                continue;
            }

            // Exiting a tag
            if (char == '>') {
                in_tag = false;
                continue;
            }

            // Inside a tag, skip all characters
            if (in_tag) {
                continue;
            }

            // Handle entities only outside tags
            if (char == '&') {
                if (lexEntity(body[i..])) |entity| {
                    try temp_line.appendSlice(entity);
                    i += std.mem.indexOf(u8, body[i..], ";").?; // Skip to the end of the entity
                } else {
                    try temp_line.append('&');
                }
                continue;
            }

            // Handle regular characters and whitespace
            if (char == '\n') {
                // Normalize newlines as spaces
                try temp_line.append('\n');
            } else {
                try temp_line.append(char);
            }
        }

        // Add remaining content to the final result
        if (temp_line.items.len > 0) {
            try content_builder.appendSlice(temp_line.items);
        }

        // Trim leading whitespace and newlines
        const final_content = std.mem.trimLeft(u8, content_builder.items, " \t\n\r");

        return try self.allocator.dupe(u8, final_content);
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
    pub fn layout(self: *Browser, text: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text)) {
            return error.InvalidUTF8;
        }

        var display_list = std.ArrayList(DisplayItem).init(self.allocator);
        defer display_list.deinit();

        var cursor_x: i32 = h_offset;
        var cursor_y: i32 = v_offset;

        const gd = try grapheme.GraphemeData.init(self.allocator);
        defer gd.deinit();

        var iter = grapheme.Iterator.init(text, &gd);
        var newline_count: u8 = 0;

        // Skip initial newlines
        while (iter.next()) |gc| {
            const cluster_bytes = gc.bytes(text);

            if (std.mem.eql(u8, cluster_bytes, "\n")) {
                continue;
            }

            // Stop skipping once a non-newline is encountered
            break;
        }

        // Reset iterator for normal processing
        iter = grapheme.Iterator.init(text, &gd);
        newline_count = 0;

        while (iter.next()) |gc| {
            const cluster_bytes = gc.bytes(text);

            // Handle newline characters
            if (std.mem.eql(u8, cluster_bytes, "\n")) {
                newline_count += 1;
                cursor_x = h_offset;

                if (newline_count == 1) {
                    // Single newline → Line break
                    cursor_y += self.font_manager.current_font.?.line_height;
                } else if (newline_count == 2) {
                    // Double newline → Paragraph break
                    cursor_y += self.font_manager.current_font.?.line_height * 2;
                }

                continue;
            }

            // Reset newline counter for non-newline characters
            newline_count = 0;

            // Get or create a Glyph for this grapheme cluster
            const glyph = try self.font_manager.getGlyph(cluster_bytes);

            // Adjust for line wrapping
            if (cursor_x + glyph.w > self.window_width - scrollbar_width) {
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
