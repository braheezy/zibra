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

const font_name = switch (builtin.target.os.tag) {
    .macos => "Hiragino Sans GB",
    .linux => "NotoSansCJK-VF",
    else => @compileError("Unsupported operating system"),
};

pub const window_width = 800;
const window_height = 600;
pub const h_offset = 13;
const v_offset = 18;
const scroll_increment = 100;

const DisplayItem = struct {
    x: i32,
    y: i32,
    glyph: *Glyph,
};

pub const Browser = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    canvas: *c.SDL_Renderer,
    font_manager: *FontManager,
    socket_map: std.StringHashMap(Connection),
    cache: Cache,
    display_list: []DisplayItem,
    content_height: i32,
    scroll_offset: i32 = 0,

    pub fn init(al: std.mem.Allocator) !*Browser {
        // Initialize SDL
        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }

        const window_flags = switch (builtin.target.os.tag) {
            .macos => c.SDL_WINDOW_METAL,
            .windows => c.SDL_WINDOW_VULKAN,
            .linux => c.SDL_WINDOW_OPENGL,
            else => c.SDL_WINDOW_OPENGL,
        };

        // Create a window
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

        const font_manager = try FontManager.init(al, renderer);
        // try browser.font_manager.loadFontFromEmbed(32);
        font_manager.loadSystemFont(font_name, 16) catch |err| {
            font_manager.deinit();
            al.destroy(font_manager);
            return err;
        };

        const socket_map = std.StringHashMap(Connection).init(al);
        const cache = try Cache.init(al);

        var browser = try al.create(Browser);
        browser.window = screen;
        browser.canvas = renderer;
        browser.allocator = al;
        browser.font_manager = font_manager;
        browser.socket_map = socket_map;
        browser.cache = cache;
        browser.scroll_offset = 0;

        return browser;
    }

    pub fn free(self: *Browser) void {
        self.font_manager.deinit();
        self.allocator.destroy(self.font_manager);

        var sockets_iter = self.socket_map.valueIterator();
        while (sockets_iter.next()) |socket| {
            switch (socket.*) {
                .Tcp => socket.Tcp.close(),
                .Tls => socket.Tls.stream.close(),
            }
        }
        self.socket_map.deinit();
        self.cache.free();

        self.allocator.free(self.display_list);

        c.SDL_DestroyRenderer(self.canvas);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *Browser) !void {
        var quit = false;
        // dbg("text: {s}\n", .{self.current_content.?});
        while (!quit) {
            var event: c.SDL_Event = undefined;
            // Handle events
            while (c.SDL_PollEvent(&event) != 0) {
                switch (event.type) {
                    // Quit when the window is closed
                    c.SDL_QUIT => quit = true,
                    c.SDL_KEYDOWN => {
                        // Handle key presses
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

            try self.draw();

            // Present the updated frame
            c.SDL_RenderPresent(self.canvas);

            // we delay for 17ms to get 60fps
            c.SDL_Delay(17);
        }
    }

    pub fn updateScroll(browser: *Browser, action: enum { ScrollDown }) void {
        switch (action) {
            .ScrollDown => {
                const max_scroll = if (browser.content_height > window_height)
                    browser.content_height - window_height
                else
                    0;

                if (browser.scroll_offset < max_scroll) {
                    browser.scroll_offset += scroll_increment;
                    if (browser.scroll_offset > max_scroll) {
                        browser.scroll_offset = max_scroll;
                    }
                }
            },
        }
    }

    pub fn load(
        self: *Browser,
        url: Url,
    ) !void {
        dbg("Loading: {s}\n", .{url.path});

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

        const parsed_content = try self.lex(body, url.view_source);
        defer self.allocator.free(parsed_content);
        try self.layout(self.allocator, parsed_content);
    }

    pub fn loadAll(
        self: *Browser,
        urls: ArrayList(Url),
    ) !void {
        var socket_map = std.StringHashMap(Connection).init(self.allocator);
        var cache = try Cache.init(self.allocator);
        defer {
            var sockets_iter = socket_map.valueIterator();
            while (sockets_iter.next()) |socket| {
                switch (socket.*) {
                    .Tcp => socket.Tcp.close(),
                    .Tls => socket.Tls.stream.close(),
                }
            }
            socket_map.deinit();
            cache.free();
        }

        for (urls.items) |url| {
            try self.load(url, &socket_map, &cache);
        }
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
            if (char == '<') {
                in_tag = true;
                if (temp_line.items.len > 0) {
                    try content_builder.appendSlice(std.mem.trim(u8, temp_line.items, " \r\n\t"));
                    try content_builder.append('\n'); // Add a newline after a block
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
            try content_builder.appendSlice(std.mem.trim(u8, temp_line.items, " \r\n\t"));
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

    pub fn draw(self: *Browser) !void {
        for (self.display_list) |item| {
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

    fn drawCircle(self: *Browser, cx: i32, cy: i32, radius: i32, color: struct { u8, u8, u8, u8 }) void {
        _ = c.SDL_SetRenderDrawColor(self.canvas, color[0], color[1], color[2], color[3]);
        var dx = -radius;
        while (dx < radius + 1) : (dx += 1) {
            const term: usize = @intCast(radius * radius - dx * dx);
            const dy: i32 = @intCast(std.math.sqrt(term));
            _ = c.SDL_RenderDrawLine(self.canvas, cx + dx, cy - dy, cx + dx, cy + dy);
        }
    }

    fn drawRectangle(self: *Browser, x: c_int, y: c_int, w: c_int, h: c_int) void {
        const rect = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_SetRenderDrawColor(self.canvas, 255, 0, 0, 255);
        _ = c.SDL_RenderFillRect(self.canvas, &rect);
    }

    pub fn layout(self: *Browser, al: std.mem.Allocator, text: []const u8) !void {
        dbg("Layout: {s}\n", .{text});
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
                cursor_y += self.font_manager.current_font.line_height;
                continue;
            }

            // Get or create a Glyph for this grapheme cluster
            const glyph = try self.font_manager.getGlyph(self.font_manager.current_font, cluster_bytes);

            // Check for line wrapping
            if (cursor_x + glyph.w > window_width - h_offset) {
                cursor_x = h_offset;
                cursor_y += self.font_manager.current_font.line_height;
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

        self.content_height = cursor_y + self.font_manager.current_font.line_height;
        self.display_list = try display_list.toOwnedSlice();
    }
};

fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}
