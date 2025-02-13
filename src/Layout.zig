const std = @import("std");
const font = @import("font.zig");
const browser = @import("browser.zig");
const code_point = @import("code_point");
const grapheme = @import("grapheme");

const DisplayItem = browser.DisplayItem;
const Token = browser.Token;
const FontWeight = font.FontWeight;
const FontSlant = font.FontSlant;
const scrollbar_width = browser.scrollbar_width;
const h_offset = browser.h_offset;
const v_offset = browser.v_offset;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const Layout = @This();

// Layout state
allocator: std.mem.Allocator,
// Font manager for handling fonts and glyphs
font_manager: font.FontManager,
window_width: i32,
window_height: i32,
rtl_text: bool = false,

// Layout cursor state
cursor_x: i32,
cursor_y: i32,
is_bold: bool = false,
is_italic: bool = false,
content_height: i32 = 0,
display_list: std.ArrayList(DisplayItem),

pub fn init(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    window_width: i32,
    window_height: i32,
    rtl_text: bool,
) !*Layout {
    const font_manager = try font.FontManager.init(allocator, renderer);
    const layout = try allocator.create(Layout);

    layout.* = Layout{
        .allocator = allocator,
        .font_manager = font_manager,
        .window_width = window_width,
        .window_height = window_height,
        .rtl_text = rtl_text,
        .cursor_x = if (rtl_text) window_width - scrollbar_width - h_offset else h_offset,
        .cursor_y = v_offset,
        .is_bold = false,
        .is_italic = false,
        .content_height = 0,
        .display_list = std.ArrayList(DisplayItem).init(allocator),
    };
    return layout;
}

pub fn deinit(self: *Layout) void {
    // clean up hash map for fonts
    self.font_manager.deinit();

    self.allocator.destroy(self);
}

pub fn layoutTokens(self: *Layout, tokens: []const Token) ![]DisplayItem {
    self.cursor_x = if (self.rtl_text)
        self.window_width - scrollbar_width - h_offset
    else
        h_offset;

    self.cursor_y = v_offset;

    const line_height = self.font_manager.current_font.?.line_height;

    for (tokens) |tok| {
        switch (tok.ty) {
            .Text => {
                try self.handleTextToken(tok.content, line_height);
            },

            .Tag => {
                try self.handleTagToken(tok.content, line_height);
            },
        }
    }

    self.content_height = self.cursor_y;
    return try self.display_list.toOwnedSlice();
}

fn handleTextToken(
    self: *Layout,
    content: []const u8,
    line_height: i32,
) !void {
    // TEXT TOKEN: inline by default, no forced break at the end

    // Make a local copy
    var text_copy = try self.allocator.dupe(u8, content);
    defer self.allocator.free(text_copy);

    // Convert literal \n in HTML to space so it doesn't cause a line break
    for (text_copy, 0..) |byte, idx| {
        if (byte == '\n') text_copy[idx] = ' ';
    }

    // Split on spaces/tabs, measure, and place graphemes inline
    var word_tokenizer = std.mem.tokenizeSequence(u8, text_copy, " \t\r");
    var local_x = self.cursor_x;

    while (word_tokenizer.next()) |word| {
        if (word.len == 0) continue;

        const measured_w = try self.measureWordWidthWithStyle(word, self.is_bold, self.is_italic);

        // line wrapping if word doesn't fit horizontally
        if (self.rtl_text) {
            if (local_x - measured_w < h_offset) {
                local_x = self.window_width - scrollbar_width - h_offset;
                self.cursor_y += line_height;
            }
        } else {
            if (local_x + measured_w > (self.window_width - scrollbar_width)) {
                local_x = h_offset;
                self.cursor_y += line_height;
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
            const weight: FontWeight = if (self.is_bold) .Bold else .Normal;
            const slantness: FontSlant = if (self.is_italic) .Italic else .Roman;
            const glyph = try self.font_manager.getStyledGlyph(gme, weight, slantness);

            // Line wrapping check before placing the glyph
            if (self.rtl_text) {
                if (glyph_x - glyph.w < h_offset) {
                    glyph_x = self.window_width - scrollbar_width - h_offset;
                    self.cursor_y += line_height;
                }
            } else {
                if (glyph_x + glyph.w > (self.window_width - scrollbar_width)) {
                    glyph_x = h_offset;
                    self.cursor_y += line_height;
                }
            }

            try self.display_list.append(.{
                .x = if (self.rtl_text) glyph_x - glyph.w else glyph_x,
                .y = self.cursor_y,
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
    self.cursor_x = local_x;
}

fn handleTagToken(self: *Layout, content: []const u8, line_height: i32) !void {
    const lower_copy = try self.allocator.dupe(u8, content);
    defer self.allocator.free(lower_copy);
    _ = std.ascii.lowerString(lower_copy, content);

    const t = std.mem.trim(u8, lower_copy, " \t\r\n");

    // Bold/italic toggles
    if (std.mem.eql(u8, t, "b")) {
        self.is_bold = true;
    } else if (std.mem.eql(u8, t, "/b")) {
        self.is_bold = false;
    } else if (std.mem.eql(u8, t, "i")) {
        self.is_italic = true;
    } else if (std.mem.eql(u8, t, "/i")) {
        self.is_italic = false;
    }
    // Paragraph => line break plus extra gap
    else if (std.mem.eql(u8, t, "p") or std.mem.eql(u8, t, "/p")) {
        self.cursor_y += line_height * 2;
        self.cursor_x = if (self.rtl_text)
            self.window_width - scrollbar_width - h_offset
        else
            h_offset;
    }
    // <br> => single line break
    else if (std.mem.eql(u8, t, "br")) {
        self.cursor_y += line_height;
        self.cursor_x = if (self.rtl_text)
            self.window_width - scrollbar_width - h_offset
        else
            h_offset;
    } else {
        // skip others
    }
}

/// Measures a word by summing the widths of its graphemes under the current style.
fn measureWordWidthWithStyle(self: *Layout, word: []const u8, bold: bool, italic: bool) !i32 {
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

fn firstCodePoint(word: []const u8) u21 {
    var it = code_point.Iterator{ .bytes = word };
    if (it.next()) |cp| return cp.code;
    return 0; // fallback if empty
}

// helper function to convert a slice to a sentinel array, because C expects that for strings
fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}
