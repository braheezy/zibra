const std = @import("std");
const font = @import("font.zig");
const browser = @import("browser.zig");
const code_point = @import("code_point");
const grapheme = @import("grapheme");
const parser = @import("parser.zig");
const DisplayItem = browser.DisplayItem;
const Node = parser.Node;
const FontWeight = font.FontWeight;
const FontSlant = font.FontSlant;
const FontCategory = font.FontCategory;
const scrollbar_width = browser.scrollbar_width;
const h_offset = browser.h_offset;
const v_offset = browser.v_offset;

// Define the list of HTML block elements
const BLOCK_ELEMENTS = [_][]const u8{ "html", "body", "article", "section", "nav", "aside", "h1", "h2", "h3", "h4", "h5", "h6", "hgroup", "header", "footer", "address", "p", "hr", "pre", "blockquote", "ol", "ul", "menu", "li", "dl", "dt", "dd", "figure", "figcaption", "main", "div", "table", "form", "fieldset", "legend", "details", "summary" };

fn isBlockElement(tag: []const u8) bool {
    for (BLOCK_ELEMENTS) |candidate| {
        if (std.mem.eql(u8, tag, candidate)) return true;
    }
    return false;
}

const sdl = @import("sdl.zig");
const c = sdl.c;

const LineItem = struct {
    x: i32,
    glyph: font.Glyph,
    /// The glyph's ascent (from font metrics)
    ascent: i32,
    /// The glyph's descent as a positive value (–TTF_FontDescent)
    descent: i32,
    /// Color to use when rendering this glyph
    color: browser.Color,
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
line_left: i32,
line_right: i32,
is_bold: bool = false,
is_italic: bool = false,
is_title: bool = false,
is_superscript: bool = false,
is_small_caps: bool = false,
text_color: browser.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, // black
style_stack: std.ArrayList(StyleSnapshot) = undefined,
// Final content height after layout
content_height: i32 = 0,
display_list: std.ArrayList(DisplayItem),
current_display_target: *std.ArrayList(DisplayItem),

// Add cache as field
word_cache: std.AutoHashMap(u64, WordCache),

is_preformatted: bool = false,
prev_font_category: ?FontCategory = null,
current_font_category: FontCategory = .latin,

const InlineSnapshot = struct {
    cursor_x: i32,
    cursor_y: i32,
    line_left: i32,
    line_right: i32,
    size: i32,
    is_bold: bool,
    is_italic: bool,
    is_title: bool,
    is_superscript: bool,
    is_small_caps: bool,
    is_preformatted: bool,
    prev_font_category: ?FontCategory,
    current_font_category: FontCategory,
    text_color: browser.Color,
};

fn snapshotInlineState(self: *const Layout) InlineSnapshot {
    return InlineSnapshot{
        .cursor_x = self.cursor_x,
        .cursor_y = self.cursor_y,
        .line_left = self.line_left,
        .line_right = self.line_right,
        .size = self.size,
        .is_bold = self.is_bold,
        .is_italic = self.is_italic,
        .is_title = self.is_title,
        .is_superscript = self.is_superscript,
        .is_small_caps = self.is_small_caps,
        .is_preformatted = self.is_preformatted,
        .prev_font_category = self.prev_font_category,
        .current_font_category = self.current_font_category,
        .text_color = self.text_color,
    };
}

fn restoreInlineState(self: *Layout, snapshot: InlineSnapshot) void {
    self.cursor_x = snapshot.cursor_x;
    self.cursor_y = snapshot.cursor_y;
    self.line_left = snapshot.line_left;
    self.line_right = snapshot.line_right;
    self.size = snapshot.size;
    self.is_bold = snapshot.is_bold;
    self.is_italic = snapshot.is_italic;
    self.is_title = snapshot.is_title;
    self.is_superscript = snapshot.is_superscript;
    self.is_small_caps = snapshot.is_small_caps;
    self.is_preformatted = snapshot.is_preformatted;
    self.prev_font_category = snapshot.prev_font_category;
    self.current_font_category = snapshot.current_font_category;
    self.text_color = snapshot.text_color;
}

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
        .line_left = h_offset,
        .line_right = window_width - scrollbar_width - h_offset,
        .is_bold = false,
        .is_italic = false,
        .content_height = 0,
        .display_list = std.ArrayList(DisplayItem).empty,
        .current_display_target = undefined,
        .word_cache = std.AutoHashMap(u64, WordCache).init(allocator),
    };

    layout.current_display_target = &layout.display_list;

    try layout.font_manager.loadSystemFont(layout.size);

    layout.style_stack = std.ArrayList(StyleSnapshot).empty;
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

    self.display_list.deinit(self.allocator);
    self.style_stack.deinit(self.allocator);

    self.allocator.destroy(self);
}

fn recurseNode(self: *Layout, node: Node, line_buffer: *std.ArrayList(LineItem)) !void {
    switch (node) {
        .text => |t| {
            try self.handleTextToken(t.text, line_buffer);
        },
        .element => |e| {
            // Apply CSS styles before processing this element
            try self.applyNodeStyles(e, line_buffer);

            // Handle br tag for line breaks
            if (std.mem.eql(u8, e.tag, "br")) {
                try self.flushLine(line_buffer);
            }

            for (e.children.items) |child| {
                try self.recurseNode(child, line_buffer);
            }

            // Restore styles after closing this element
            try self.restoreNodeStyles(line_buffer);
        },
    }
}

const StyleSnapshot = struct {
    is_bold: bool,
    is_italic: bool,
    size: i32,
    text_color: browser.Color,
};

fn applyNodeStyles(self: *Layout, element: parser.Element, _: *std.ArrayList(LineItem)) !void {
    // Save current style state
    const snapshot = StyleSnapshot{
        .is_bold = self.is_bold,
        .is_italic = self.is_italic,
        .size = self.size,
        .text_color = self.text_color,
    };
    try self.style_stack.append(self.allocator, snapshot);

    if (element.style) |style_map| {
        // Apply font-weight
        if (style_map.get("font-weight")) |weight_str| {
            self.is_bold = std.mem.eql(u8, weight_str, "bold");
        }

        // Apply font-style
        if (style_map.get("font-style")) |style_str| {
            self.is_italic = std.mem.eql(u8, style_str, "italic");
        }

        // Apply font-size
        if (style_map.get("font-size")) |size_str| {
            if (std.mem.endsWith(u8, size_str, "px")) {
                const size_num_str = size_str[0 .. size_str.len - 2];
                if (std.fmt.parseFloat(f64, size_num_str)) |size_float| {
                    // Convert CSS pixels to our size (multiply by 0.75 for points)
                    self.size = @intFromFloat(size_float * 0.75);
                } else |_| {}
            }
        }

        // Apply color
        if (style_map.get("color")) |color_str| {
            if (parseColor(color_str)) |color| {
                self.text_color = color;
            }
        }
    }
}

fn restoreNodeStyles(self: *Layout, _: *std.ArrayList(LineItem)) !void {
    // Restore the previous style state
    if (self.style_stack.items.len > 0) {
        const snapshot = self.style_stack.pop() orelse return;
        self.is_bold = snapshot.is_bold;
        self.is_italic = snapshot.is_italic;
        self.size = snapshot.size;
        self.text_color = snapshot.text_color;
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
        const available_width: i32 = self.line_right - self.line_left;
        const new_x_offset: i32 = self.line_left + @divTrunc(available_width - line_width, 2);
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

        try self.current_display_target.append(self.allocator, DisplayItem{
            .glyph = .{
                .x = item.x,
                .y = final_y,
                .glyph = item.glyph,
                .color = item.color, // Use the color captured when item was added to line buffer
            },
        });
    }

    // Advance cursor_y and reset cursor_x
    self.cursor_y = baseline + max_descent + extra_leading;
    self.cursor_x = if (self.rtl_text) self.line_right else self.line_left;

    line_buffer.clearRetainingCapacity();
}

// Add a common function for handling individual graphemes
fn processGrapheme(
    self: *Layout,
    gme: []const u8,
    line_buffer: *std.ArrayList(LineItem),
    options: struct {
        force_newline: bool = false,
        is_superscript: bool = false,
        is_small_caps: bool = false,
    },
) !void {
    // Extract first code point to determine character category
    var cp_iter = code_point.Iterator{ .bytes = gme };
    const first_cp = cp_iter.next() orelse return error.InvalidUtf8;

    // Determine font category based on code point
    const category = getCategory(first_cp.code);

    // Determine if we should use monospace font
    // Only use monospace for ASCII and Latin characters in preformatted mode
    // For emoji and CJK, use their specialized fonts even in preformatted mode
    const use_monospace = self.is_preformatted and
        (category == null or category.? == .latin or category.? == .monospace);

    // Update current font category if needed
    if (category != null and category.? != self.current_font_category) {
        self.prev_font_category = self.current_font_category;
        self.current_font_category = category.?;
    }

    // Use the current style settings
    const weight: font.FontWeight = if (self.is_bold) .Bold else .Normal;
    const slant: font.FontSlant = if (self.is_italic) .Italic else .Roman;

    // Handle small caps rendering
    var glyph: font.Glyph = undefined;
    if (options.is_small_caps) {
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
                use_monospace,
            );
        } else {
            // Regular rendering for non-lowercase characters
            glyph = try self.font_manager.getStyledGlyph(
                gme,
                weight,
                slant,
                self.size,
                use_monospace,
            );
        }
    } else {
        // Normal rendering
        glyph = try self.font_manager.getStyledGlyph(
            gme,
            weight,
            slant,
            if (options.is_superscript) @divTrunc(self.size, 2) else self.size,
            use_monospace,
        );
    }

    glyph.is_superscript = options.is_superscript;

    // Check for soft hyphen character (U+00AD)
    const is_soft_hyphen = (gme.len == 2 and gme[0] == 0xC2 and gme[1] == 0xAD) or
        std.mem.eql(u8, gme, "\u{00AD}");
    glyph.is_soft_hyphen = is_soft_hyphen;

    // Skip rendering soft hyphens
    if (glyph.is_soft_hyphen) {
        return;
    }

    // Handle newlines explicitly
    if (std.mem.eql(u8, gme, "\n") or options.force_newline) {
        try self.flushLine(line_buffer);
        self.cursor_x = if (self.rtl_text) self.line_right else self.line_left;
        return;
    }

    // Check if we need to wrap (only at window edge)
    if (self.cursor_x + glyph.w > self.line_right) {
        try self.flushLine(line_buffer);
        self.cursor_x = if (self.rtl_text) self.line_right else self.line_left;
    }

    // Add glyph to line buffer with current text color
    try line_buffer.append(self.allocator, LineItem{
        .x = self.cursor_x,
        .glyph = glyph,
        .ascent = glyph.ascent,
        .descent = glyph.descent,
        .color = self.text_color, // Capture color at time of adding to buffer
    });
    self.cursor_x += glyph.w;
}

// Update handlePreformattedText to use the common processGrapheme function
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

    const grapheme_data = try grapheme.init(self.allocator);
    defer grapheme_data.deinit(self.allocator);
    var g_iter = grapheme_data.iterator(content);
    while (g_iter.next()) |gc| {
        const gme = gc.bytes(content);
        try self.processGrapheme(gme, line_buffer, .{
            .is_superscript = self.is_superscript,
            .is_small_caps = self.is_small_caps,
        });
    }
}

// Update handleTextToken to use the common processGrapheme function
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

                // Process the entity using our common function
                try self.processGrapheme(entity.replacement, line_buffer, .{
                    .is_superscript = self.is_superscript,
                    .is_small_caps = self.is_small_caps,
                });

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

        // Process the grapheme using our common function
        try self.processGrapheme(gme, line_buffer, .{
            .is_superscript = self.is_superscript,
            .is_small_caps = self.is_small_caps,
        });

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

// Update layoutSourceCode to format HTML source with tags in normal font and content in bold
pub fn layoutSourceCode(self: *Layout, source: []const u8) ![]DisplayItem {
    std.debug.print("layoutSourceCode: {d} bytes\n", .{source.len});
    self.current_display_target = &self.display_list;
    self.cursor_x = if (self.rtl_text) self.line_right else self.line_left;
    self.cursor_y = v_offset;
    self.line_left = h_offset;
    self.line_right = self.window_width - scrollbar_width - h_offset;

    // Save current state
    const original_preformatted = self.is_preformatted;
    const original_font_category = self.current_font_category;
    const original_is_bold = self.is_bold;

    // Start with preformatted mode on for whitespace preservation
    // but use normal font for initial state
    self.is_preformatted = true; // Keep preformatted for all content to preserve whitespace
    self.current_font_category = .latin; // Start with normal font
    self.is_bold = false; // Start with normal weight

    var line_buffer = std.ArrayList(LineItem).empty;
    defer line_buffer.deinit(self.allocator);

    // Process the source character by character to apply different styles to tags and content
    var i: usize = 0;
    var in_tag = false;
    var in_comment = false;
    var in_string = false;
    var string_delimiter: u8 = 0;

    // Process the source character by character
    while (i < source.len) {
        // Check for tag start
        if (i + 1 < source.len and source[i] == '<') {
            // We're entering a tag
            in_tag = true;
            self.is_bold = false;
            self.is_preformatted = false; // Turn off preformatted for tags
            self.current_font_category = .latin; // Use regular document font for tags

            // Process the '<' character
            const grapheme_data = try grapheme.init(self.allocator);
            defer grapheme_data.deinit(self.allocator);
            var g_iter = grapheme_data.iterator(source[i .. i + 1]);
            if (g_iter.next()) |gc| {
                const gme = gc.bytes(source[i..]);
                try self.processGrapheme(gme, &line_buffer, .{
                    .is_superscript = self.is_superscript,
                    .is_small_caps = self.is_small_caps,
                });
            }
            i += 1;

            // Check for comment
            if (i + 2 < source.len and source[i] == '!' and source[i + 1] == '-' and source[i + 2] == '-') {
                in_comment = true;
            }

            continue;
        }

        // Check for tag end
        if (in_tag and source[i] == '>') {
            // We're exiting a tag
            in_tag = false;
            in_comment = false;
            in_string = false;

            // Process the '>' character
            const grapheme_data = try grapheme.init(self.allocator);
            defer grapheme_data.deinit(self.allocator);
            var g_iter = grapheme_data.iterator(source[i .. i + 1]);
            if (g_iter.next()) |gc| {
                const gme = gc.bytes(source[i..]);
                try self.processGrapheme(gme, &line_buffer, .{
                    .is_superscript = self.is_superscript,
                    .is_small_caps = self.is_small_caps,
                });
            }
            i += 1;

            // After exiting a tag, text content should be bold and preformatted
            self.is_bold = true;
            self.is_preformatted = true; // Turn on preformatted for text content
            self.current_font_category = .monospace; // Use monospace for text content

            continue;
        }

        // Handle string boundaries within tags
        if (in_tag and !in_comment) {
            if (!in_string and (source[i] == '"' or source[i] == '\'')) {
                in_string = true;
                string_delimiter = source[i];
            } else if (in_string and source[i] == string_delimiter) {
                in_string = false;
            }
        }

        // Handle comment end
        if (in_comment and i + 2 < source.len and
            source[i] == '-' and source[i + 1] == '-' and source[i + 2] == '>')
        {
            // Let the tag end logic handle this in the next iteration
        }

        // Process current character
        const grapheme_data = try grapheme.init(self.allocator);
        defer grapheme_data.deinit(self.allocator);
        var g_iter = grapheme_data.iterator(source[i..]);
        if (g_iter.next()) |gc| {
            const gme = gc.bytes(source[i..]);
            try self.processGrapheme(gme, &line_buffer, .{
                .is_superscript = self.is_superscript,
                .is_small_caps = self.is_small_caps,
            });
            i += gme.len;
        } else {
            i += 1; // Fallback in case of invalid UTF-8
        }
    }

    // Flush any remaining items on the last line
    try self.flushLine(&line_buffer);

    // Restore original state
    self.is_preformatted = original_preformatted;
    self.current_font_category = original_font_category;
    self.is_bold = original_is_bold;

    self.content_height = self.cursor_y;
    return try self.display_list.toOwnedSlice(self.allocator);
}

// Text layout for individual words
pub const TextLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    word: []const u8,
    parent: *LineLayout,
    previous: ?*TextLayout,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    font_size: i32 = 16,
    font_weight: FontWeight = .Normal,
    font_slant: FontSlant = .Roman,
    color: browser.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    // Store font metrics for baseline calculation
    ascent: i32 = 0,
    descent: i32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        node: Node,
        word: []const u8,
        parent: *LineLayout,
        previous: ?*TextLayout,
    ) !*TextLayout {
        const text = try allocator.create(TextLayout);
        text.* = TextLayout{
            .allocator = allocator,
            .node = node,
            .word = word,
            .parent = parent,
            .previous = previous,
        };
        return text;
    }

    pub fn deinit(self: *TextLayout) void {
        _ = self;
        // Word is not owned by TextLayout, so we don't free it
        // The node is part of the HTML tree and managed elsewhere
    }

    pub fn layout(self: *TextLayout, engine: *Layout) !void {
        // Get font properties from node style
        // In a real browser, we'd read from self.node.style
        // For now, use the engine's current style state
        self.font_weight = if (engine.is_bold) .Bold else .Normal;
        self.font_slant = if (engine.is_italic) .Italic else .Roman;
        self.font_size = engine.size;
        self.color = engine.text_color;

        // Measure the word to get its width
        const glyph = try engine.font_manager.getStyledGlyph(
            self.word,
            self.font_weight,
            self.font_slant,
            self.font_size,
            false,
        );

        self.width = glyph.w;

        // Store font metrics for baseline calculation
        self.ascent = glyph.ascent;
        self.descent = glyph.descent;

        // Height is the line spacing (ascent + descent)
        self.height = self.ascent + self.descent;

        // Compute x position (horizontal stacking with space between words)
        if (self.previous) |prev| {
            // Measure a space character
            const space_glyph = try engine.font_manager.getStyledGlyph(
                " ",
                prev.font_weight,
                prev.font_slant,
                prev.font_size,
                false,
            );
            const space = space_glyph.w;
            self.x = prev.x + space + prev.width;
        } else {
            self.x = self.parent.x;
        }

        // y position is computed by LineLayout after baseline is determined
    }

    pub fn paint(self: *TextLayout, engine: *Layout) !void {
        // Paint the word using the stored font properties
        const glyph = try engine.font_manager.getStyledGlyph(
            self.word,
            self.font_weight,
            self.font_slant,
            self.font_size,
            false,
        );

        try engine.display_list.append(engine.allocator, DisplayItem{
            .glyph = .{
                .x = self.x,
                .y = self.y,
                .glyph = glyph,
                .color = self.color,
            },
        });
    }
};

// Line layout for each line of text
pub const LineLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    parent: *BlockLayout,
    previous: ?*LineLayout,
    children: std.ArrayList(*TextLayout),
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        node: Node,
        parent: *BlockLayout,
        previous: ?*LineLayout,
    ) !*LineLayout {
        const line = try allocator.create(LineLayout);
        line.* = LineLayout{
            .allocator = allocator,
            .node = node,
            .parent = parent,
            .previous = previous,
            .children = std.ArrayList(*TextLayout).empty,
        };
        return line;
    }

    pub fn deinit(self: *LineLayout) void {
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
    }

    pub fn layout(self: *LineLayout, engine: *Layout) !void {
        // Position the line relative to parent block
        self.width = self.parent.width;
        self.x = self.parent.x;

        // Position is below previous line, or at parent's y
        if (self.previous) |prev| {
            self.y = prev.y + prev.height;
        } else {
            self.y = self.parent.y;
        }

        // Layout each word in the line (computes x, width, height, font metrics)
        for (self.children.items) |word| {
            try word.layout(engine);
        }

        // Compute the line's baseline from maximum ascent
        var max_ascent: i32 = 0;
        for (self.children.items) |word| {
            if (word.ascent > max_ascent) {
                max_ascent = word.ascent;
            }
        }

        // Baseline with 1.25 leading factor
        const baseline = self.y + @as(i32, @intFromFloat(1.25 * @as(f32, @floatFromInt(max_ascent))));

        // Position each word vertically relative to baseline
        for (self.children.items) |word| {
            word.y = baseline - word.ascent;
        }

        // Compute maximum descent
        var max_descent: i32 = 0;
        for (self.children.items) |word| {
            if (word.descent > max_descent) {
                max_descent = word.descent;
            }
        }

        // Compute line height with 1.25 leading factor
        self.height = @intFromFloat(1.25 * @as(f32, @floatFromInt(max_ascent + max_descent)));
    }

    pub fn paint(self: *LineLayout, engine: *Layout) !void {
        // Paint each word in the line
        for (self.children.items) |text| {
            try text.paint(engine);
        }
    }
};

pub const DocumentLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    children: std.ArrayList(*BlockLayout),
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn init(allocator: std.mem.Allocator, node: Node) !*DocumentLayout {
        const document = try allocator.create(DocumentLayout);
        document.* = DocumentLayout{
            .allocator = allocator,
            .node = node,
            .children = std.ArrayList(*BlockLayout).empty,
        };
        return document;
    }

    pub fn deinit(self: *DocumentLayout) void {
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
    }

    pub fn layout(self: *DocumentLayout, engine: *Layout) !void {
        self.x = h_offset;
        self.y = v_offset;
        self.width = engine.window_width - scrollbar_width - (2 * h_offset);

        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.clearRetainingCapacity();
        const child = try BlockLayout.init(self.allocator, self.node, self, null, null);
        try self.children.append(self.allocator, child);

        try child.layout(engine);
        self.height = child.height;
    }
};

// Union type to handle both block and line children
pub const LayoutChild = union(enum) {
    block: *BlockLayout,
    line: *LineLayout,

    pub fn deinit(self: LayoutChild, allocator: std.mem.Allocator) void {
        switch (self) {
            .block => |b| {
                b.deinit();
                allocator.destroy(b);
            },
            .line => |l| {
                l.deinit();
                allocator.destroy(l);
            },
        }
    }
};

pub const BlockLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    document: *DocumentLayout,
    parent_block: ?*BlockLayout,
    previous: ?*BlockLayout,
    children: std.ArrayList(LayoutChild),
    display_list: std.ArrayList(DisplayItem),
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    cursor_x: i32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        node: Node,
        document: *DocumentLayout,
        parent_block: ?*BlockLayout,
        previous: ?*BlockLayout,
    ) !*BlockLayout {
        const block = try allocator.create(BlockLayout);
        block.* = BlockLayout{
            .allocator = allocator,
            .node = node,
            .document = document,
            .parent_block = parent_block,
            .previous = previous,
            .children = std.ArrayList(LayoutChild).empty,
            .display_list = std.ArrayList(DisplayItem).empty,
        };
        return block;
    }

    pub fn deinit(self: *BlockLayout) void {
        for (self.children.items) |child| {
            child.deinit(self.allocator);
        }
        self.children.deinit(self.allocator);
        self.display_list.deinit(self.allocator);
    }

    fn isBlockContainer(self: *const BlockLayout) bool {
        switch (self.node) {
            .text => return false,
            .element => |e| {
                // Follow the chapter-5 heuristic: if any child is a known block
                // element we treat this layout box as block-level. Otherwise,
                // mixed inline content stays inline unless the element is empty,
                // in which case it acts like an empty block box (matching the
                // Python reference implementation).
                for (e.children.items) |child| {
                    switch (child) {
                        .element => |child_e| {
                            if (isBlockElement(child_e.tag)) return true;
                        },
                        else => {},
                    }
                }
                return e.children.items.len == 0;
            },
        }
    }

    // Create a new line for inline content
    fn newLine(self: *BlockLayout) !void {
        self.cursor_x = 0;
        const last_line: ?*LineLayout = if (self.children.items.len > 0) blk: {
            const last_child = self.children.items[self.children.items.len - 1];
            break :blk if (last_child == .line) last_child.line else null;
        } else null;

        const new_line = try LineLayout.init(self.allocator, self.node, self, last_line);
        try self.children.append(self.allocator, .{ .line = new_line });
    }

    // Add a word to the current line
    fn word(self: *BlockLayout, node: Node, word_text: []const u8, font_mgr: *font.FontManager, width: i32) !void {
        // Get the current line (should be the last child)
        if (self.children.items.len == 0) {
            try self.newLine();
        }

        const last_child = &self.children.items[self.children.items.len - 1];
        if (last_child.* != .line) {
            // If last child isn't a line, create a new line
            try self.newLine();
        }

        const line = self.children.items[self.children.items.len - 1].line;

        // Check if we need to wrap to a new line
        if (self.cursor_x + width > self.width and self.cursor_x > 0) {
            try self.newLine();
        }

        const previous_word: ?*TextLayout = if (line.children.items.len > 0)
            line.children.items[line.children.items.len - 1]
        else
            null;

        const text = try TextLayout.init(self.allocator, node, word_text, line, previous_word);
        try line.children.append(self.allocator, text);
        self.cursor_x += width;

        _ = font_mgr; // Will use this later for measuring
    }

    pub fn layout(self: *BlockLayout, engine: *Layout) !void {
        const parent_x = if (self.parent_block) |pb| pb.x else self.document.x;
        const parent_y = if (self.parent_block) |pb| pb.y else self.document.y;
        const parent_width = if (self.parent_block) |pb| pb.width else self.document.width;

        self.x = parent_x;
        self.width = parent_width;
        self.y = if (self.previous) |prev| prev.y + prev.height else parent_y;

        const is_block = self.isBlockContainer();
        if (is_block) {
            // Clear existing children
            for (self.children.items) |child| {
                child.deinit(self.allocator);
            }
            self.children.clearRetainingCapacity();

            // Create block children
            switch (self.node) {
                .element => |e| {
                    var previous: ?*BlockLayout = null;
                    for (e.children.items) |child_node| {
                        const child = try BlockLayout.init(self.allocator, child_node, self.document, self, previous);
                        try self.children.append(self.allocator, .{ .block = child });
                        previous = child;
                    }
                },
                else => {},
            }

            // Layout all children and compute height
            self.height = 0;
            for (self.children.items) |child| {
                switch (child) {
                    .block => |b| {
                        try b.layout(engine);
                        self.height += b.height;
                    },
                    .line => |l| {
                        try l.layout(engine);
                        self.height += l.height;
                    },
                }
            }
        } else {
            // Inline layout mode - use the old approach for now
            // TODO: Refactor to populate LineLayout and TextLayout objects
            self.display_list.clearRetainingCapacity();
            try engine.layoutInlineBlock(self);
            // Height is set by layoutInlineBlock
        }
    }
};

fn layoutInlineBlock(self: *Layout, block: *BlockLayout) !void {
    const snapshot = snapshotInlineState(self);
    const previous_target = self.current_display_target;
    defer {
        restoreInlineState(self, snapshot);
        self.current_display_target = previous_target;
    }

    self.line_left = block.x;
    self.line_right = block.x + block.width;
    self.cursor_x = if (self.rtl_text) self.line_right else self.line_left;
    self.cursor_y = block.y;
    self.size = 16;
    self.is_bold = false;
    self.is_italic = false;
    self.is_title = false;
    self.is_superscript = false;
    self.is_small_caps = false;
    self.text_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }; // Reset to black
    self.is_preformatted = false;
    self.prev_font_category = null;
    self.current_font_category = .latin;

    self.current_display_target = &block.display_list;

    var line_buffer = std.ArrayList(LineItem).empty;
    defer line_buffer.deinit(self.allocator);

    switch (block.node) {
        .text => |t| {
            try self.handleTextToken(t.text, &line_buffer);
        },
        .element => |e| {
            // Apply CSS styles for this block element
            try self.applyNodeStyles(e, &line_buffer);

            // Handle br tag for line breaks
            if (std.mem.eql(u8, e.tag, "br")) {
                try self.flushLine(&line_buffer);
            }

            for (e.children.items) |child| {
                try self.recurseNode(child, &line_buffer);
            }

            try self.restoreNodeStyles(&line_buffer);
        },
    }

    try self.flushLine(&line_buffer);
    block.height = self.cursor_y - block.y;
    if (block.height < 0) block.height = 0;
}

fn parseColor(color_str: []const u8) ?browser.Color {
    // Handle named colors
    if (std.mem.eql(u8, color_str, "red")) {
        return browser.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "green")) {
        return browser.Color{ .r = 0, .g = 128, .b = 0, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "blue")) {
        return browser.Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "yellow")) {
        return browser.Color{ .r = 255, .g = 255, .b = 0, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "gray") or std.mem.eql(u8, color_str, "grey")) {
        return browser.Color{ .r = 128, .g = 128, .b = 128, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "lightgray") or std.mem.eql(u8, color_str, "lightgrey")) {
        return browser.Color{ .r = 211, .g = 211, .b = 211, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "white")) {
        return browser.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "black")) {
        return browser.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "orange")) {
        return browser.Color{ .r = 255, .g = 165, .b = 0, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "purple")) {
        return browser.Color{ .r = 128, .g = 0, .b = 128, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "pink")) {
        return browser.Color{ .r = 255, .g = 192, .b = 203, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "lightblue")) {
        return browser.Color{ .r = 173, .g = 216, .b = 230, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "lightgreen")) {
        return browser.Color{ .r = 144, .g = 238, .b = 144, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "cyan")) {
        return browser.Color{ .r = 0, .g = 255, .b = 255, .a = 255 };
    } else if (std.mem.eql(u8, color_str, "magenta")) {
        return browser.Color{ .r = 255, .g = 0, .b = 255, .a = 255 };
    }
    // TODO: Handle hex colors like #ff0000
    return null;
}

fn addBackgroundIfNeeded(self: *Layout, block: *const BlockLayout) !void {
    switch (block.node) {
        .element => |e| {
            if (block.height <= 0) return;

            // Check for background-color in the style attribute
            const bgcolor_str = if (e.style) |style|
                style.get("background-color")
            else
                null;

            // Determine the background color
            var color: ?browser.Color = null;

            if (bgcolor_str) |bg| {
                // Don't draw if explicitly transparent
                if (std.mem.eql(u8, bg, "transparent")) {
                    return;
                }
                color = parseColor(bg);
            } else if (std.mem.eql(u8, e.tag, "pre")) {
                // Default gray background for pre tags if no style specified
                color = browser.Color{ .r = 230, .g = 230, .b = 230, .a = 255 };
            }

            // Draw the background rectangle if we have a color
            if (color) |col| {
                const rect = DisplayItem{ .rect = .{
                    .x1 = block.x,
                    .y1 = block.y,
                    .x2 = block.x + block.width,
                    .y2 = block.y + block.height,
                    .color = col,
                } };
                try self.display_list.append(self.allocator, rect);
            }
        },
        else => {},
    }
}

fn paintBlock(self: *Layout, block: *BlockLayout) !void {
    try addBackgroundIfNeeded(self, block);

    for (block.display_list.items) |item| {
        try self.display_list.append(self.allocator, item);
    }

    for (block.children.items) |child| {
        switch (child) {
            .block => |b| try paintBlock(self, b),
            .line => |l| try l.paint(self),
        }
    }
}

pub fn buildDocument(self: *Layout, root: Node) !*DocumentLayout {
    const document = try DocumentLayout.init(self.allocator, root);
    try document.layout(self);
    return document;
}

pub fn paintDocument(self: *Layout, document: *DocumentLayout) ![]DisplayItem {
    self.display_list.clearRetainingCapacity();
    self.current_display_target = &self.display_list;

    for (document.children.items) |child| {
        try paintBlock(self, child);
    }

    self.content_height = document.height + v_offset;
    return try self.display_list.toOwnedSlice(self.allocator);
}

// Layout object that can be clicked
pub const LayoutObject = union(enum) {
    text: *TextLayout,
    line: *LineLayout,
    block: *BlockLayout,

    pub fn getNode(self: LayoutObject) Node {
        return switch (self) {
            .text => |t| t.node,
            .line => |l| l.node,
            .block => |b| b.node,
        };
    }

    pub fn getBounds(self: LayoutObject) struct { x: i32, y: i32, width: i32, height: i32 } {
        return switch (self) {
            .text => |t| .{ .x = t.x, .y = t.y, .width = t.width, .height = t.height },
            .line => |l| .{ .x = l.x, .y = l.y, .width = l.width, .height = l.height },
            .block => |b| .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height },
        };
    }
};

// Flatten the layout tree into a list
pub fn layoutTreeToList(document: *DocumentLayout, list: *std.ArrayList(LayoutObject)) !void {
    for (document.children.items) |child| {
        try blockToList(child, list);
    }
}

fn blockToList(block: *BlockLayout, list: *std.ArrayList(LayoutObject)) !void {
    try list.append(block.allocator, .{ .block = block });

    for (block.children.items) |child| {
        switch (child) {
            .block => |b| try blockToList(b, list),
            .line => |l| {
                try list.append(block.allocator, .{ .line = l });
                for (l.children.items) |text| {
                    try list.append(block.allocator, .{ .text = text });
                }
            },
        }
    }
}
