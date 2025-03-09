const std = @import("std");
const font = @import("font.zig");
const browser = @import("browser.zig");
const code_point = @import("code_point");
const grapheme = @import("grapheme");
const token = @import("token.zig");
const parser = @import("parser.zig");
const DisplayItem = browser.DisplayItem;
const Token = token.Token;
const Node = parser.Node;
const FontWeight = font.FontWeight;
const FontSlant = font.FontSlant;
const FontCategory = font.FontCategory;
const scrollbar_width = browser.scrollbar_width;
const h_offset = browser.h_offset;
const v_offset = browser.v_offset;
const newGlyphCacheKey = font.newGlyphCacheKey;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const LineItem = struct {
    x: i32,
    glyph: font.Glyph,
    /// The glyph's ascent (from font metrics)
    ascent: i32,
    /// The glyph's descent as a positive value (–TTF_FontDescent)
    descent: i32,
};

// Add this struct to cache word measurements
const WordCache = struct {
    width: i32,
    graphemes: []const []const u8,
};

const getCategory = @import("font.zig").getCategory;

pub const Layout = @This();

// Layout state
allocator: std.mem.Allocator,
// Font manager for handling fonts and glyphs
font_manager: font.FontManager,
window_width: i32,
window_height: i32,
rtl_text: bool = false,
size: i32 = 16,
cursor_x: i32,
cursor_y: i32,
is_bold: bool = false,
is_italic: bool = false,
is_title: bool = false,
is_superscript: bool = false,
is_small_caps: bool = false,
// Final content height after layout
content_height: i32 = 0,
display_list: std.ArrayList(DisplayItem),

// Add cache as field
word_cache: std.AutoHashMap(u64, WordCache),

grapheme_data: grapheme.GraphemeData,

is_preformatted: bool = false,
prev_font_category: ?FontCategory = null,
current_font_category: FontCategory = .latin,

pub fn init(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    window_width: i32,
    window_height: i32,
    rtl_text: bool,
) !*Layout {
    const font_manager = try font.FontManager.init(allocator, renderer);
    const layout = try allocator.create(Layout);
    const grapheme_data = try grapheme.GraphemeData.init(allocator);

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
        .word_cache = std.AutoHashMap(u64, WordCache).init(allocator),
        .grapheme_data = grapheme_data,
    };

    try layout.font_manager.loadSystemFont(layout.size);

    return layout;
}

pub fn deinit(self: *Layout) void {
    // clean up hash map for fonts
    self.font_manager.deinit();

    var it = self.word_cache.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.value_ptr.graphemes);
    }
    self.word_cache.deinit();

    self.grapheme_data.deinit();

    self.allocator.destroy(self);
}

pub fn layoutTokens(self: *Layout, tokens: []const Token) ![]DisplayItem {
    std.debug.print("layoutTokens: {d}\n", .{tokens.len});
    self.cursor_x = if (self.rtl_text)
        self.window_width - scrollbar_width - h_offset
    else
        h_offset;
    self.cursor_y = v_offset;

    var line_buffer = std.ArrayList(LineItem).init(self.allocator);
    defer line_buffer.deinit();

    for (tokens) |tok| {
        switch (tok) {
            .text => {
                try self.handleTextToken(tok.text, &line_buffer);
            },

            .tag => {
                try self.handleTagToken(tok.tag, &line_buffer);
            },
        }
    }

    // Flush any remaining items on the last line.
    try self.flushLine(&line_buffer);
    self.content_height = self.cursor_y;
    return try self.display_list.toOwnedSlice();
}

pub fn layoutNodes(self: *Layout, root: Node) ![]DisplayItem {
    std.debug.print("layoutNodes\n", .{});
    self.cursor_x = if (self.rtl_text)
        self.window_width - scrollbar_width - h_offset
    else
        h_offset;
    self.cursor_y = v_offset;

    var line_buffer = std.ArrayList(LineItem).init(self.allocator);
    defer line_buffer.deinit();

    // Process the node tree recursively
    try self.recurseNode(root, &line_buffer);

    // Flush any remaining items on the last line
    try self.flushLine(&line_buffer);
    self.content_height = self.cursor_y;
    return try self.display_list.toOwnedSlice();
}

fn recurseNode(self: *Layout, node: Node, line_buffer: *std.ArrayList(LineItem)) !void {
    switch (node) {
        .text => |t| {
            try self.handleTextToken(t.text, line_buffer);
        },
        .element => |e| {
            try self.openTag(e.tag, e.attributes, line_buffer);

            for (e.children.items) |child| {
                try self.recurseNode(child, line_buffer);
            }

            try self.closeTag(e.tag, line_buffer);
        },
    }
}

fn openTag(self: *Layout, tag: []const u8, attributes: ?std.StringHashMap([]const u8), line_buffer: *std.ArrayList(LineItem)) !void {
    if (std.mem.eql(u8, tag, "b")) {
        self.is_bold = true;
    } else if (std.mem.eql(u8, tag, "i")) {
        self.is_italic = true;
    } else if (std.mem.eql(u8, tag, "abbr")) {
        self.is_small_caps = true;
    } else if (std.mem.eql(u8, tag, "big")) {
        self.size += 4;
    } else if (std.mem.eql(u8, tag, "small")) {
        self.size -= 4;
    } else if (std.mem.eql(u8, tag, "p")) {
        // Flush the current line and add vertical spacing.
        try self.flushLine(line_buffer);
        self.cursor_y += self.size;
        self.cursor_x = if (self.rtl_text)
            self.window_width - scrollbar_width - h_offset
        else
            h_offset;
    } else if (std.mem.eql(u8, tag, "br")) {
        // A <br> tag always triggers a line break.
        try self.flushLine(line_buffer);
        self.cursor_x = if (self.rtl_text)
            self.window_width - scrollbar_width - h_offset
        else
            h_offset;
    } else if (std.mem.eql(u8, tag, "h1")) {
        if (attributes) |attrs| {
            if (attrs.get("class")) |id| {
                if (std.mem.eql(u8, id, "title")) {
                    self.is_title = true;
                }
            }
        }
    } else if (std.mem.eql(u8, tag, "sup")) {
        self.is_superscript = true;
    } else if (std.mem.eql(u8, tag, "pre")) {
        try self.flushLine(line_buffer);
        self.is_preformatted = true;
    }
}

fn closeTag(self: *Layout, tag: []const u8, line_buffer: *std.ArrayList(LineItem)) !void {
    if (std.mem.eql(u8, tag, "b")) {
        self.is_bold = false;
    } else if (std.mem.eql(u8, tag, "i")) {
        self.is_italic = false;
    } else if (std.mem.eql(u8, tag, "abbr")) {
        self.is_small_caps = false;
    } else if (std.mem.eql(u8, tag, "big")) {
        self.size -= 4;
    } else if (std.mem.eql(u8, tag, "small")) {
        self.size += 4;
    } else if (std.mem.eql(u8, tag, "sup")) {
        self.is_superscript = false;
    } else if (std.mem.eql(u8, tag, "pre")) {
        try self.flushLine(line_buffer);
        self.is_preformatted = false;
        // Restore previous font category
        if (self.prev_font_category) |category| {
            self.current_font_category = category;
            self.prev_font_category = null;
        }
    }
}

fn flushLine(self: *Layout, line_buffer: *std.ArrayList(LineItem)) !void {
    // Nothing to flush? Return.
    if (line_buffer.items.len == 0) return;

    // === Handle title centering if needed ===
    if (self.is_title) {
        // Determine the bounding x-coordinates from the line items.
        var min_x: i32 = line_buffer.items[0].x;
        var max_x: i32 = line_buffer.items[0].x + line_buffer.items[0].glyph.w;
        for (line_buffer.items) |item| {
            if (item.x < min_x) {
                min_x = item.x;
            }
            const item_right = item.x + item.glyph.w;
            if (item_right > max_x) {
                max_x = item_right;
            }
        }
        const line_width: i32 = max_x - min_x;
        // Compute available width:
        // Here we assume h_offset defines the left/right content margin, and scrollbar_width is reserved.
        const available_width: i32 = self.window_width - scrollbar_width - (h_offset * 2);
        // Compute new left offset so that the line is centered.
        const new_x_offset: i32 = h_offset + @divTrunc(available_width - line_width, 2);
        const shift: i32 = new_x_offset - min_x;
        // Adjust all glyph positions for centering.
        for (line_buffer.items) |*item| {
            item.x += shift;
        }
        // Reset the is_title state since the title line has been centered.
        self.is_title = false;
    }

    // === PASS 1: Collect line metrics ===
    var max_ascent: i32 = 0;
    var max_normal_ascent: i32 = 0; // Track max ascent of normal (non-superscript) text
    var max_descent: i32 = 0;

    for (line_buffer.items) |item| {
        if (item.glyph.is_superscript) {
            if (item.ascent > max_ascent) max_ascent = item.ascent;
            if (item.descent > max_descent) max_descent = item.descent;
        } else {
            if (item.ascent > max_ascent) max_ascent = item.ascent;
            if (item.ascent > max_normal_ascent) max_normal_ascent = item.ascent;
            if (item.descent > max_descent) max_descent = item.descent;
        }
    }

    const line_height = max_ascent + max_descent;
    const extra_leading: i32 = @intFromFloat(@as(f32, @floatFromInt(line_height)) * 0.25);
    const baseline = self.cursor_y + max_ascent;

    // === PASS 2: Position glyphs ===
    for (line_buffer.items) |item| {
        var final_y: i32 = undefined;

        if (item.glyph.is_superscript) {
            // Position superscript so its top aligns with normal text top
            final_y = self.cursor_y; // Start at line top
        } else {
            // Normal baseline alignment
            final_y = baseline - item.ascent;
        }

        try self.display_list.append(DisplayItem{
            .x = item.x,
            .y = final_y,
            .glyph = item.glyph,
        });
    }

    // Advance cursor_y and reset cursor_x
    self.cursor_y = baseline + max_descent + extra_leading;
    self.cursor_x = if (self.rtl_text)
        self.window_width - scrollbar_width - h_offset
    else
        h_offset;

    line_buffer.clearRetainingCapacity();
}

/// Modified text token handler now collects all glyphs into the line buffer.
/// It also checks line–wrapping on a per–word and per–glyph basis.
fn handleTextToken(
    self: *Layout,
    content: []const u8,
    line_buffer: *std.ArrayList(LineItem),
) !void {
    if (self.is_preformatted) {
        try self.handlePreformattedText(content, line_buffer);
        return;
    }

    // Replace newline characters with spaces in a stack buffer.
    var buf: [4096]u8 = undefined;
    const text = if (content.len < buf.len) blk: {
        @memcpy(buf[0..content.len], content);
        for (buf[0..content.len]) |*byte| {
            if (byte.* == '\n') byte.* = ' ';
        }
        break :blk buf[0..content.len];
    } else content;

    // Use the current style settings.
    const weight: font.FontWeight = if (self.is_bold) .Bold else .Normal;
    const slant: font.FontSlant = if (self.is_italic) .Italic else .Roman;

    // Track the last soft hyphen position in the current line
    var last_hyphen_idx: ?usize = null;

    // Process entities before grapheme iteration
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            // Check if this is an entity
            if (lexEntityAt(text, i)) |entity| {
                if (std.mem.eql(u8, entity.replacement, "\u{00AD}")) {
                    // Soft hyphen - remember position but don't render
                    last_hyphen_idx = line_buffer.items.len;
                    i += entity.len;
                    continue;
                }

                // Process the entity
                var glyph = try self.font_manager.getStyledGlyph(entity.replacement, weight, slant, if (self.is_superscript) @divTrunc(self.size, 2) else self.size, false);
                glyph.is_superscript = self.is_superscript;

                // Check if we'll exceed line width
                if (self.cursor_x + glyph.w > (self.window_width - scrollbar_width - h_offset)) {
                    // If we have a soft hyphen, add visible hyphen and break there
                    if (last_hyphen_idx != null) {
                        const hyphen_glyph = try self.font_manager.getStyledGlyph(
                            "-",
                            weight,
                            slant,
                            if (self.is_superscript) @divTrunc(self.size, 2) else self.size,
                            false,
                        );
                        try line_buffer.append(LineItem{
                            .x = self.cursor_x,
                            .glyph = hyphen_glyph,
                            .ascent = hyphen_glyph.ascent,
                            .descent = hyphen_glyph.descent,
                        });
                    }
                    try self.flushLine(line_buffer);
                    last_hyphen_idx = null;
                }

                // Add the entity glyph
                try line_buffer.append(LineItem{
                    .x = self.cursor_x,
                    .glyph = glyph,
                    .ascent = glyph.ascent,
                    .descent = glyph.descent,
                });
                self.cursor_x += glyph.w;

                // Skip past the entity
                i += entity.len;
                continue;
            }
        }

        // Find next grapheme boundary
        var g_end = i;
        while (g_end < text.len) {
            if (text[g_end] == '&') break; // Stop at potential entity

            g_end += 1;
            if (g_end < text.len) {
                if ((text[g_end] & 0xC0) != 0x80) break; // Not a continuation byte
            }
        }

        if (g_end == i) {
            // Process single character (not part of any grapheme cluster)
            g_end = i + 1;
        }

        const gme = text[i..g_end];

        // Handle small caps rendering
        var glyph: font.Glyph = undefined;
        if (self.is_small_caps) {
            // Check if the grapheme is a lowercase letter
            const is_lowercase = for (gme) |byte| {
                if (byte >= 'a' and byte <= 'z') break true;
            } else false;

            if (is_lowercase) {
                // Convert to uppercase and render at smaller size with bold
                var upper_buf: [4]u8 = undefined;
                const upper_len = std.ascii.upperString(&upper_buf, gme);
                glyph = try self.font_manager.getStyledGlyph(
                    upper_buf[0..upper_len.len],
                    .Bold, // Force bold for small caps
                    slant,
                    @divTrunc(self.size * 4, 5), // Make it ~80% of normal size
                    false,
                );
            } else {
                // Regular rendering for non-lowercase characters
                glyph = try self.font_manager.getStyledGlyph(
                    gme,
                    weight,
                    slant,
                    self.size,
                    false,
                );
            }
        } else {
            // Normal rendering (existing code)
            glyph = try self.font_manager.getStyledGlyph(
                gme,
                weight,
                slant,
                if (self.is_superscript) @divTrunc(self.size, 2) else self.size,
                false,
            );
        }
        glyph.is_superscript = self.is_superscript;

        // Check for soft hyphen character (U+00AD)
        const is_soft_hyphen = (gme.len == 2 and gme[0] == 0xC2 and gme[1] == 0xAD) or
            std.mem.eql(u8, gme, "\u{00AD}");

        glyph.is_soft_hyphen = is_soft_hyphen;

        // Skip rendering soft hyphens but remember their position
        if (glyph.is_soft_hyphen) {
            last_hyphen_idx = line_buffer.items.len;
            i = g_end;
            continue;
        }

        // If we'll exceed the line width...
        if (self.cursor_x + glyph.w > (self.window_width - scrollbar_width - h_offset)) {
            // If we have a soft hyphen, add visible hyphen and break there
            if (last_hyphen_idx) |_| {
                // Get a visible hyphen glyph
                const hyphen_glyph = try self.font_manager.getStyledGlyph(
                    "-",
                    weight,
                    slant,
                    if (self.is_superscript) @divTrunc(self.size, 2) else self.size,
                    false,
                );

                // Add the hyphen at the break point
                try line_buffer.append(LineItem{
                    .x = self.cursor_x,
                    .glyph = hyphen_glyph,
                    .ascent = hyphen_glyph.ascent,
                    .descent = hyphen_glyph.descent,
                });
            }
            try self.flushLine(line_buffer);
            last_hyphen_idx = null;
        }

        // Normal glyph handling (unchanged)
        try line_buffer.append(LineItem{
            .x = self.cursor_x,
            .glyph = glyph,
            .ascent = glyph.ascent,
            .descent = glyph.descent,
        });
        self.cursor_x += glyph.w;

        i = g_end;
    }
}

// Entity handling function that takes a position in text
fn lexEntityAt(text: []const u8, pos: usize) ?struct { replacement: []const u8, len: usize } {
    if (pos >= text.len or text[pos] != '&') return null;

    // Find the entity end (semicolon)
    var end_idx: usize = pos + 1;
    while (end_idx < text.len and end_idx < pos + 8) : (end_idx += 1) {
        if (text[end_idx] == ';') break;
    }

    // If no semicolon found or it's the last character, not an entity
    if (end_idx >= text.len or text[end_idx] != ';') return null;

    const entity = text[pos .. end_idx + 1];

    if (std.mem.eql(u8, entity, "&amp;"))
        return .{ .replacement = "&", .len = 5 };
    if (std.mem.eql(u8, entity, "&lt;"))
        return .{ .replacement = "<", .len = 4 };
    if (std.mem.eql(u8, entity, "&gt;"))
        return .{ .replacement = ">", .len = 4 };
    if (std.mem.eql(u8, entity, "&quot;"))
        return .{ .replacement = "\"", .len = 6 };
    if (std.mem.eql(u8, entity, "&apos;"))
        return .{ .replacement = "'", .len = 6 };
    if (std.mem.eql(u8, entity, "&shy;"))
        return .{ .replacement = "\u{00AD}", .len = 5 }; // Unicode soft hyphen

    return null;
}

fn handlePreformattedText(
    self: *Layout,
    content: []const u8,
    line_buffer: *std.ArrayList(LineItem),
) !void {
    // Save current font category and switch to monospace
    if (!self.is_preformatted) {
        self.prev_font_category = self.current_font_category;
        self.current_font_category = .monospace;
    }

    var g_iter = grapheme.Iterator.init(content, &self.grapheme_data);
    while (g_iter.next()) |gc| {
        const gme = gc.bytes(content);

        // Get glyph with current style settings
        const weight: font.FontWeight = if (self.is_bold) .Bold else .Normal;
        const slant: font.FontSlant = if (self.is_italic) .Italic else .Roman;

        const glyph = try self.font_manager.getStyledGlyph(
            gme,
            weight,
            slant,
            self.size,
            true,
        );

        // Handle newlines in preformatted text
        if (std.mem.eql(u8, gme, "\n")) {
            try self.flushLine(line_buffer);
            self.cursor_x = h_offset;
            continue;
        }

        // Check if we need to wrap (only at window edge)
        if (self.cursor_x + glyph.w > (self.window_width - scrollbar_width - h_offset)) {
            try self.flushLine(line_buffer);
            self.cursor_x = h_offset;
        }

        // Add glyph to line buffer
        try line_buffer.append(LineItem{
            .x = self.cursor_x,
            .glyph = glyph,
            .ascent = glyph.ascent,
            .descent = glyph.descent,
        });
        self.cursor_x += glyph.w;
    }
}

fn handleTagToken(
    self: *Layout,
    tag: *token.Tag,
    line_buffer: *std.ArrayList(LineItem),
) !void {
    if (std.mem.eql(u8, tag.name, "b")) {
        self.is_bold = !tag.is_closing;
    } else if (std.mem.eql(u8, tag.name, "i")) {
        self.is_italic = !tag.is_closing;
    } else if (std.mem.eql(u8, tag.name, "abbr")) {
        self.is_small_caps = !tag.is_closing;
    } else if (std.mem.eql(u8, tag.name, "big")) {
        if (!tag.is_closing) {
            self.size += 4;
        } else {
            self.size -= 4;
        }
    } else if (std.mem.eql(u8, tag.name, "small")) {
        if (!tag.is_closing) {
            self.size -= 4;
        } else {
            self.size += 4;
        }
    } else if (std.mem.eql(u8, tag.name, "p")) {
        // Flush the current line and add vertical spacing.
        try self.flushLine(line_buffer);
        self.cursor_y += self.size;
        self.cursor_x = if (self.rtl_text)
            self.window_width - scrollbar_width - h_offset
        else
            h_offset;
    } else if (std.mem.eql(u8, tag.name, "br")) {
        // A <br> tag always triggers a line break.
        try self.flushLine(line_buffer);
        self.cursor_x = if (self.rtl_text)
            self.window_width - scrollbar_width - h_offset
        else
            h_offset;
    } else if (std.mem.eql(u8, tag.name, "h1")) {
        if (tag.attributes) |attributes| {
            if (attributes.get("class")) |id| {
                if (std.mem.eql(u8, id, "title")) {
                    self.is_title = true;
                }
            }
        }
    } else if (std.mem.eql(u8, tag.name, "sup")) {
        self.is_superscript = !tag.is_closing;
    } else if (std.mem.eql(u8, tag.name, "pre")) {
        if (tag.is_closing) {
            try self.flushLine(line_buffer);
            self.is_preformatted = false;
            // Restore previous font category
            if (self.prev_font_category) |category| {
                self.current_font_category = category;
                self.prev_font_category = null;
            }
        } else {
            try self.flushLine(line_buffer);
            self.is_preformatted = true;
        }
    } else {
        // For other tags you can now use the attributes parsed into tag.attributes.
        // For example, if there's an inline style attribute, you might inspect it like so:
        // if (tag.attributes.get("style")) |style_val| {
        //     // Process the style value as needed.
        // }
        // Otherwise, skip tags that don't affect formatting.
    }
}
