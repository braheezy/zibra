const std = @import("std");

const FontManager = @import("font.zig").FontManager;
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

pub const width = 800;
const height = 600;

pub const Browser = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    canvas: *c.SDL_Renderer,
    current_content: ?[]const u8 = null,
    font_manager: *FontManager,

    pub fn init(al: std.mem.Allocator) !*Browser {
        // Initialize SDL
        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }

        // Create a window
        const screen = c.SDL_CreateWindow(
            "zibra",
            c.SDL_WINDOWPOS_UNDEFINED,
            c.SDL_WINDOWPOS_UNDEFINED,
            width,
            height,
            c.SDL_WINDOW_METAL,
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
        font_manager.loadSystemFont("Hiragino Sans GB", 16) catch |err| {
            font_manager.deinit();
            al.destroy(font_manager);
            return err;
        };

        var browser = try al.create(Browser);
        browser.window = screen;
        browser.canvas = renderer;
        browser.allocator = al;
        browser.font_manager = font_manager;

        return browser;
    }

    pub fn free(self: *Browser) void {
        if (self.current_content) |content| {
            self.allocator.free(content);
        }
        self.font_manager.deinit();
        self.allocator.destroy(self.font_manager);

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
                    c.SDL_QUIT => {
                        quit = true;
                    },
                    else => {},
                }
            }
            // Clear canvas with off-white
            _ = c.SDL_SetRenderDrawColor(self.canvas, 250, 244, 237, 255);
            _ = c.SDL_RenderClear(self.canvas);

            // Render text
            if (self.current_content) |content| {
                const text = try sliceToSentinelArray(self.allocator, content);
                defer self.allocator.free(text);
                try self.font_manager.renderText("Hiragino Sans GB", text, 10, 10);
                // try self.renderWrappedText(text, 100, 100, 600);
            }

            // Present the updated frame
            c.SDL_RenderPresent(self.canvas);

            // we delay for 17ms to get 60fps
            c.SDL_Delay(17);
        }
    }

    pub fn load(
        self: *Browser,
        url: Url,
        socket_map: *std.StringHashMap(Connection),
        cache: *Cache,
    ) !void {
        if (std.mem.eql(u8, url.scheme, "file")) {
            dbg("File request: {s}\n", .{url.path});
            const body = try url.fileRequest(self.allocator);
            defer self.allocator.free(body);
            try self.lex(body, url.view_source);
        } else if (std.mem.eql(u8, url.scheme, "data")) {
            dbg("Data request: {s}\n", .{url.path});
            try self.lex(url.path, url.view_source);
        } else {
            const body = try url.httpRequest(
                self.allocator,
                socket_map,
                cache,
                0,
            );
            defer self.allocator.free(body);
            try self.lex(body, url.view_source);
        }
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
    pub fn lex(self: *Browser, body: []const u8, view_content: bool) !void {
        if (view_content) {
            self.current_content = body;
            return;
        }

        var content_builder = std.ArrayList(u8).init(self.allocator);
        defer content_builder.deinit();

        var in_tag = false;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const char = body[i];
            if (char == '<') {
                in_tag = true;
            } else if (char == '>') {
                in_tag = false;
            } else if (char == '&') {
                const entity = try lexEntity(body[i..]);
                try content_builder.appendSlice(entity);
                i += entity.len - 1;
            } else if (!in_tag) {
                try content_builder.append(char);
            }
        }

        const content = try content_builder.toOwnedSlice();
        // dbg("setting content: {s}\n", .{content});
        self.current_content = content;
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
};

fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}
