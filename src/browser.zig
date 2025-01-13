const std = @import("std");
const builtin = @import("builtin");

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
    glyph: Glyph,
};

pub const TokenType = enum {
    Text,
    Tag,
};

pub const Token = struct {
    ty: TokenType,
    content: []const u8, // For text tokens, the text; for tag tokens, the tag name
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
    current_content: ?[]const Token = null,
    // Total height of the content
    content_height: i32 = 0,
    // Current scroll offset
    scroll_offset: i32 = 0,
    // Window dimensions
    window_width: i32 = initial_window_width,
    window_height: i32 = initial_window_height,
    // Flag to indicate if text should be right-to-left
    rtl_text: bool = false,

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

        const font_manager = try FontManager.init(al, renderer);

        return Browser{
            .allocator = al,
            .window = screen,
            .canvas = renderer,
            .font_manager = font_manager,
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
            // If “view_source” is true, maybe you do NOTHING but show raw text.
            // Or you still produce tokens, up to you.
            // Minimal approach: return an empty token list or a single text token:
            var plain = std.ArrayList(Token).init(self.allocator);
            defer plain.deinit();

            const body_copy = try self.allocator.dupe(u8, body);
            defer self.allocator.free(body_copy);

            try plain.append(Token{ .ty = .Text, .content = body_copy });

            const plain_tokens_slice = try plain.toOwnedSlice();
            try self.layout(plain_tokens_slice);
        } else {
            var tokens_array = try self.lexTokens(body);
            // defer { };

            const tok_slice = try tokens_array.toOwnedSlice();
            try self.layout(tok_slice);
        }
    }

    // Show the body of the response, sans tags
    // pub fn lex(self: *Browser, body: []const u8, view_content: bool) ![]const u8 {
    //     if (view_content) {
    //         return body;
    //     }
    //     var content_builder = std.ArrayList(u8).init(self.allocator);
    //     defer content_builder.deinit();

    //     var temp_line = std.ArrayList(u8).init(self.allocator);
    //     defer temp_line.deinit();

    //     var tag_buffer = std.ArrayList(u8).init(self.allocator);
    //     defer tag_buffer.deinit();

    //     var in_tag = false;
    //     var i: usize = 0;

    //     while (i < body.len) : (i += 1) {
    //         const char = body[i];

    //         // Entering a tag
    //         if (char == '<') {
    //             in_tag = true;

    //             // Flush any text we had *outside* of a tag
    //             if (temp_line.items.len > 0) {
    //                 try content_builder.appendSlice(temp_line.items);
    //                 temp_line.clearAndFree();
    //             }

    //             // Clear the tag_buffer to start fresh
    //             tag_buffer.clearRetainingCapacity();
    //             continue;
    //         }

    //         // Exiting a tag
    //         if (char == '>') {
    //             in_tag = false;

    //             // Now tag_buffer contains something like "p" or "/p" or "h1"
    //             const tag_text = tag_buffer.items;

    //             if (std.mem.eql(u8, tag_text, "p") or std.mem.eql(u8, tag_text, "/p")) {
    //                 // Paragraph break -> two newlines
    //                 try content_builder.appendSlice("\n\n");
    //             } else if (std.mem.eql(u8, tag_text, "br")) {
    //                 // Single line break
    //                 try content_builder.appendSlice("\n");
    //             } else if (std.mem.eql(u8, tag_text, "h1") or std.mem.eql(u8, tag_text, "/h1") or
    //                 std.mem.eql(u8, tag_text, "h2") or std.mem.eql(u8, tag_text, "/h2") or
    //                 std.mem.eql(u8, tag_text, "h3") or std.mem.eql(u8, tag_text, "/h3"))
    //             {
    //                 // For headings, add two newlines so it stands out
    //                 try content_builder.appendSlice("\n\n");
    //             }
    //             // else skip other tags

    //             continue;
    //         }

    //         // If we're inside a tag, accumulate chars into tag_buffer
    //         if (in_tag) {
    //             try tag_buffer.append(char);
    //             continue;
    //         }

    //         // Handle entities only outside tags
    //         if (char == '&') {
    //             if (lexEntity(body[i..])) |entity| {
    //                 try temp_line.appendSlice(entity);
    //                 i += std.mem.indexOf(u8, body[i..], ";").?; // Skip to the end of the entity
    //             } else {
    //                 try temp_line.append('&');
    //             }
    //             continue;
    //         }

    //         // If it's a newline, keep it (we can interpret them as spaces later)
    //         if (char == '\n') {
    //             try temp_line.append('\n');
    //         } else {
    //             try temp_line.append(char);
    //         }
    //     }

    //     // Add remaining content to the final result
    //     if (temp_line.items.len > 0) {
    //         try content_builder.appendSlice(temp_line.items);
    //     }

    //     // Trim leading whitespace and newlines
    //     const final_content = std.mem.trimLeft(u8, content_builder.items, " \t\n\r");

    //     return try self.allocator.dupe(u8, final_content);
    // }

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
                // We’re entering a tag
                // If we have accumulated text, flush it to a TEXT token
                if (temp_text.items.len > 0) {
                    try tokens.append(Token{
                        .ty = .Text,
                        .content = try self.allocator.dupe(u8, temp_text.items),
                    });
                    temp_text.clearRetainingCapacity();
                }

                in_tag = true;
                tag_buffer.clearRetainingCapacity();
                continue;
            }

            if (char == '>') {
                // We’re leaving a tag
                in_tag = false;

                // Now tag_buffer has something like "b", "/b", "p", "/p"
                // We'll produce a TAG token
                try tokens.append(Token{
                    .ty = .Tag,
                    .content = try self.allocator.dupe(u8, tag_buffer.items),
                });
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

            // If it’s a raw newline, keep it as is. We will handle it in layout.
            try temp_text.append(char);
        }

        // If there's leftover text at the end, produce a final TEXT token
        if (temp_text.items.len > 0) {
            try tokens.append(Token{
                .ty = .Text,
                .content = try self.allocator.dupe(u8, temp_text.items),
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
        var display_list = std.ArrayList(DisplayItem).init(self.allocator);
        defer display_list.deinit();

        var is_bold: bool = false;
        var is_italic: bool = false;

        var cursor_x: i32 = if (self.rtl_text)
            self.window_width - scrollbar_width - h_offset
        else
            h_offset;

        var cursor_y: i32 = v_offset;

        const line_height = self.font_manager.current_font.?.line_height;

        for (tokens) |tok| {
            switch (tok.ty) {
                /////////////////////////////////////////////////////////////////////
                // TEXT TOKEN: inline by default, no forced break at the end
                /////////////////////////////////////////////////////////////////////
                .Text => {
                    // Make a local copy
                    var text_copy = try self.allocator.dupe(u8, tok.content);
                    defer self.allocator.free(text_copy);

                    // Convert literal \n in HTML to space so it doesn't cause a line break
                    for (text_copy, 0..) |byte, idx| {
                        if (byte == '\n') text_copy[idx] = ' ';
                    }

                    // Split on spaces/tabs, measure, and place graphemes inline
                    var word_tokenizer = std.mem.tokenizeSequence(u8, text_copy, " \t\r");
                    var local_x = cursor_x;

                    while (word_tokenizer.next()) |word| {
                        if (word.len == 0) continue;

                        const measured_w = try self.measureWordWidthWithStyle(word, is_bold, is_italic);

                        // line wrapping if word doesn't fit horizontally
                        if (self.rtl_text) {
                            if (local_x - measured_w < h_offset) {
                                local_x = self.window_width - scrollbar_width - h_offset;
                                cursor_y += line_height;
                            }
                        } else {
                            if (local_x + measured_w > (self.window_width - scrollbar_width)) {
                                local_x = h_offset;
                                cursor_y += line_height;
                            }
                        }

                        // Render each grapheme
                        var gd = try grapheme.GraphemeData.init(self.allocator);
                        defer gd.deinit();
                        var g_iter = grapheme.Iterator.init(word, &gd);

                        var graphemes_array = std.ArrayList([]const u8).init(self.allocator);
                        defer graphemes_array.deinit();

                        while (g_iter.next()) |gc| {
                            try graphemes_array.append(gc.bytes(word));
                        }
                        if (self.rtl_text) {
                            std.mem.reverse([]const u8, graphemes_array.items);
                        }

                        var glyph_x = local_x;
                        for (graphemes_array.items) |gme| {
                            const weight: FontWeight = if (is_bold) .Bold else .Normal;
                            const slantness: FontSlant = if (is_italic) .Italic else .Roman;
                            const glyph = try self.font_manager.getStyledGlyph(gme, weight, slantness);

                            try display_list.append(.{
                                .x = if (self.rtl_text) glyph_x - glyph.w else glyph_x,
                                .y = cursor_y,
                                .glyph = glyph,
                            });

                            if (self.rtl_text) {
                                glyph_x -= glyph.w;
                            } else {
                                glyph_x += glyph.w;
                            }
                        }

                        local_x = glyph_x;
                    }

                    // After finishing this Text token, do NOT line-break
                    // let it remain on the same line
                    cursor_x = local_x;
                },

                /////////////////////////////////////////////////////////////////////
                // TAG TOKEN: line breaks only for <p>, <br>, toggle is_bold/is_italic for <b>, <i>
                /////////////////////////////////////////////////////////////////////
                .Tag => {
                    const lower_copy = try self.allocator.dupe(u8, tok.content);
                    defer self.allocator.free(lower_copy);
                    _ = std.ascii.lowerString(lower_copy, tok.content);

                    const t = std.mem.trim(u8, lower_copy, " \t\r\n");

                    // Bold/italic toggles
                    if (std.mem.eql(u8, t, "b")) {
                        is_bold = true;
                        std.debug.print("<b> => is_bold = true\n", .{});
                    } else if (std.mem.eql(u8, t, "/b")) {
                        is_bold = false;
                        std.debug.print("</b> => is_bold = false\n", .{});
                    } else if (std.mem.eql(u8, t, "i")) {
                        std.debug.print("<i> => is_italic = true\n", .{});
                        is_italic = true;
                    } else if (std.mem.eql(u8, t, "/i")) {
                        std.debug.print("<i> => is_italic = false\n", .{});
                        is_italic = false;
                    }
                    // Paragraph => line break plus extra gap
                    else if (std.mem.eql(u8, t, "p") or std.mem.eql(u8, t, "/p")) {
                        cursor_y += line_height * 2;
                        cursor_x = if (self.rtl_text)
                            self.window_width - scrollbar_width - h_offset
                        else
                            h_offset;
                    }
                    // <br> => single line break
                    else if (std.mem.eql(u8, t, "br")) {
                        cursor_y += line_height;
                        cursor_x = if (self.rtl_text)
                            self.window_width - scrollbar_width - h_offset
                        else
                            h_offset;
                    } else {
                        // skip others
                    }
                },
            }
        }

        self.content_height = cursor_y;
        self.display_list = try display_list.toOwnedSlice();
    }

    /// Measures how many pixels wide `word` would occupy if we render it grapheme-by-grapheme.
    fn measureWordWidth(self: *Browser, word: []const u8) !i32 {
        var total_w: i32 = 0;

        var gd = try grapheme.GraphemeData.init(self.allocator);
        defer gd.deinit();

        var g_iter = grapheme.Iterator.init(word, &gd);
        while (g_iter.next()) |gc| {
            const cluster_bytes = gc.bytes(word);
            const glyph = try self.font_manager.getGlyph(cluster_bytes);
            total_w += glyph.w;
        }
        return total_w;
    }

    /// Measures a word by summing the widths of its graphemes under the current style.
    fn measureWordWidthWithStyle(self: *Browser, word: []const u8, bold: bool, italic: bool) !i32 {
        // 1) Determine the right font or fallback
        const weight: FontWeight = if (bold) .Bold else .Normal;
        const slant: FontSlant = if (italic) .Italic else .Roman;

        var styled_font = self.font_manager.pickFontForCharacterStyle(
            firstCodePoint(word),
            weight,
            slant,
        );
        var style_set = false;
        if (styled_font == null) {
            // fallback
            styled_font = self.font_manager.pickFontForCharacter(firstCodePoint(word));
            if (styled_font == null) return error.NoFontForGlyph;

            // Synthetic styling
            var new_style: c_int = 0;
            if (bold) new_style |= c.TTF_STYLE_BOLD;
            if (italic) new_style |= c.TTF_STYLE_ITALIC;
            c.TTF_SetFontStyle(styled_font.?.font_handle, new_style);
            style_set = true;
        }

        const fh = styled_font.?.font_handle;

        // 2) Use TTF_SizeUTF8 to measure the entire word
        var w: c_int = 0;
        var h: c_int = 0;

        // Convert word to a null-terminated sentinel
        const sentinel = try sliceToSentinelArray(self.allocator, word);
        defer self.allocator.free(sentinel);

        if (c.TTF_SizeUTF8(fh, sentinel, &w, &h) != 0) {
            if (style_set) c.TTF_SetFontStyle(fh, c.TTF_STYLE_NORMAL);
            return error.RenderFailed;
        }

        // 3) Restore synthetic style if needed
        if (style_set) c.TTF_SetFontStyle(fh, c.TTF_STYLE_NORMAL);

        return w;
    }
};

// helper function to convert a slice to a sentinel array, because C expects that for strings
fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}

fn firstCodePoint(word: []const u8) u21 {
    var it = code_point.Iterator{ .bytes = word };
    if (it.next()) |cp| return cp.code;
    return 0; // fallback if empty
}
