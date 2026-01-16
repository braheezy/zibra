const std = @import("std");
const font = @import("font.zig");
const browser = @import("browser.zig");
const code_point = @import("code_point");
const grapheme = @import("grapheme");
const parser = @import("parser.zig");
// const ProtectedField = @import("protected_field.zig").ProtectedField;
const DisplayItem = browser.DisplayItem;
const Node = parser.Node;
const FontWeight = font.FontWeight;
const FontSlant = font.FontSlant;
const FontCategory = font.FontCategory;
const scrollbar_width = browser.scrollbar_width;
const h_offset = browser.h_offset;
const v_offset = browser.v_offset;
const GraphemeData = @TypeOf(grapheme.init(std.heap.page_allocator) catch unreachable);

const sdl2 = @import("sdl");

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


// Assume 60 fps for frame calculations
const FRAMES_PER_SECOND: u32 = 60;

fn drawCursor(
    commands: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    x: i32,
    y: i32,
    height: i32,
    color: browser.Color,
) !void {
    const cursor_height = if (height > 0) height else 1;
    try commands.append(allocator, DisplayItem{
        .line = .{
            .x1 = x,
            .y1 = y,
            .x2 = x,
            .y2 = y + cursor_height,
            .color = color,
            .thickness = 1,
        },
    });
}

/// Parse a transition value like "opacity 2s" into property name and frame count
/// Returns null if parsing fails
fn parseTransitionValue(value: []const u8) ?struct { property: []const u8, frames: u32 } {
    // Split on whitespace
    var parts = std.mem.tokenizeAny(u8, value, " \t");
    const property = parts.next() orelse return null;
    const duration_str = parts.next() orelse return null;

    // Parse duration (e.g., "2s" or "500ms")
    var frames: u32 = 0;
    if (std.mem.endsWith(u8, duration_str, "ms")) {
        // Milliseconds
        const ms_str = duration_str[0 .. duration_str.len - 2];
        const ms = std.fmt.parseFloat(f64, ms_str) catch return null;
        frames = @intFromFloat(ms / 1000.0 * @as(f64, FRAMES_PER_SECOND));
    } else if (std.mem.endsWith(u8, duration_str, "s")) {
        // Seconds
        const s_str = duration_str[0 .. duration_str.len - 1];
        const s = std.fmt.parseFloat(f64, s_str) catch return null;
        frames = @intFromFloat(s * @as(f64, FRAMES_PER_SECOND));
    } else {
        return null;
    }

    return .{ .property = property, .frames = @max(1, frames) };
}

/// Parse a translate transform value like "translate(10px, 20px)" into x and y offsets
/// Returns null if parsing fails
fn parseTranslate(value: []const u8) ?struct { x: i32, y: i32 } {
    // Look for "translate(" prefix
    const prefix = "translate(";
    if (!std.mem.startsWith(u8, value, prefix)) return null;

    // Find the closing paren
    const start = prefix.len;
    const end = std.mem.indexOf(u8, value[start..], ")") orelse return null;
    const args = value[start .. start + end];

    // Split on comma
    var parts = std.mem.tokenizeAny(u8, args, ", \t");
    const x_str = parts.next() orelse return null;
    const y_str = parts.next() orelse "0px"; // Default y to 0 if not specified

    // Parse x value (e.g., "10px")
    var x: i32 = 0;
    if (std.mem.endsWith(u8, x_str, "px")) {
        const num_str = x_str[0 .. x_str.len - 2];
        x = std.fmt.parseInt(i32, num_str, 10) catch return null;
    } else {
        // Try parsing as plain number
        x = std.fmt.parseInt(i32, x_str, 10) catch return null;
    }

    // Parse y value (e.g., "20px")
    var y: i32 = 0;
    if (std.mem.endsWith(u8, y_str, "px")) {
        const num_str = y_str[0 .. y_str.len - 2];
        y = std.fmt.parseInt(i32, num_str, 10) catch return null;
    } else {
        // Try parsing as plain number
        y = std.fmt.parseInt(i32, y_str, 10) catch return null;
    }

    return .{ .x = x, .y = y };
}

const EmbedLayout = struct {
    width: i32 = 0,
    height: i32 = 0,
    ascent: i32 = 0,
    descent: i32 = 0,

    pub fn appendInline(
        self: *const EmbedLayout,
        engine: *Layout,
        line_buffer: *std.ArrayList(LineItem),
        node_ptr: ?*Node,
        payload: LineItemPayload,
    ) !void {
        if (self.width <= 0 or self.height <= 0) return;

        if (engine.cursor_x + self.width > engine.line_right) {
            try engine.flushLine(line_buffer);
            engine.cursor_x = if (engine.rtl_text) engine.line_right else engine.line_left;
        }

        try line_buffer.append(engine.allocator, LineItem{
            .x = engine.cursor_x,
            .hit_offset_x = engine.transform_offset_x,
            .hit_offset_y = engine.transform_offset_y,
            .ascent = self.ascent,
            .descent = self.descent,
            .width = self.width,
            .height = self.height,
            .node_ptr = node_ptr,
            .payload = payload,
        });
        engine.cursor_x += self.width;
    }
};

pub const ImageLayout = struct {
    embed: EmbedLayout = .{},
    pixels: []const u8,
    source_width: i32,
    source_height: i32,
    opacity: f64 = 1.0,

    pub fn init(
        layout_width: i32,
        layout_height: i32,
        image_data: ?parser.ImageData,
    ) ImageLayout {
        const empty_pixels = &[_]u8{};
        const src_width: i32 = if (image_data) |data| @intCast(data.image.width) else 0;
        const src_height: i32 = if (image_data) |data| @intCast(data.image.height) else 0;
        return .{
            .embed = .{
                .width = layout_width,
                .height = layout_height,
                .ascent = layout_height,
                .descent = 0,
            },
            .pixels = if (image_data) |data| data.image.rawBytes() else empty_pixels,
            .source_width = src_width,
            .source_height = src_height,
            .opacity = 1.0,
        };
    }
};

pub const IframeLayout = struct {
    embed: EmbedLayout = .{},
    bgcolor: browser.Color,
    border_color: browser.Color,
    border_thickness: i32 = 1,

    pub fn init(layout_width: i32, layout_height: i32) IframeLayout {
        return .{
            .embed = .{
                .width = layout_width,
                .height = layout_height,
                .ascent = layout_height,
                .descent = 0,
            },
            .bgcolor = .{ .r = 0xf2, .g = 0xf2, .b = 0xf2, .a = 0xff },
            .border_color = .{ .r = 0x33, .g = 0x33, .b = 0x33, .a = 0xff },
            .border_thickness = 1,
        };
    }

    pub fn paintAt(
        self: *const IframeLayout,
        commands: *std.ArrayList(DisplayItem),
        engine: *Layout,
        x: i32,
        y: i32,
    ) !void {
        const width_value = self.embed.width;
        const height_value = self.embed.height;
        const bg = engine.remapColor(self.bgcolor);
        if (bg.a > 0) {
            try commands.append(engine.allocator, DisplayItem{
                .rect = .{
                    .x1 = x,
                    .y1 = y,
                    .x2 = x + width_value,
                    .y2 = y + height_value,
                    .color = bg,
                },
            });
        }

        const border = engine.remapColor(self.border_color);
        if (border.a > 0) {
            try commands.append(engine.allocator, DisplayItem{
                .outline = .{
                    .rect = .{
                        .left = x,
                        .top = y,
                        .right = x + width_value,
                        .bottom = y + height_value,
                    },
                    .color = border,
                    .thickness = self.border_thickness,
                },
            });
        }
    }
};

const LineItemPayload = union(enum) {
    glyph: struct {
        glyph: font.Glyph,
        color: browser.Color,
    },
    input: InputLayout,
    image: ImageLayout,
    iframe: IframeLayout,
};

const LineItem = struct {
    x: i32,
    hit_offset_x: i32,
    hit_offset_y: i32,
    /// The glyph's ascent or image height (from font metrics)
    ascent: i32,
    /// The glyph's descent as a positive value (–TTF_FontDescent)
    descent: i32,
    width: i32,
    height: i32,
    /// Pointer to the DOM node that produced this item (if available)
    node_ptr: ?*Node,
    payload: LineItemPayload,
};

// Add this struct to cache word measurements
const WordCache = struct {
    width: i32,
    graphemes: []const []const u8,
};

const getCategory = @import("font.zig").getCategory;

// Bounding box for hit testing
pub const Bounds = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const LinkBoundEntry = struct {
    node: *Node,
    bounds: Bounds,
};

const IframeBoundEntry = struct {
    node: *Node,
    bounds: Bounds,
};

const FocusBoundEntry = struct {
    node: *Node,
    bounds: Bounds,
};

const AccessibilityBoundEntry = struct {
    node: *Node,
    bounds: Bounds,
};

pub const Layout = @This();

// Layout state
allocator: std.mem.Allocator,
// Font manager for handling fonts and glyphs
    font_manager: font.FontManager,
    grapheme_data: GraphemeData,
    window_width: i32,
    window_height: i32,
    rtl_text: bool = false,
    accessibility: browser.AccessibilitySettings = .{},
    color_scheme_dark: bool = false,
    document_color_scheme_dark: bool = false,
    default_font_size: i32 = 16,
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
    inline_block: ?*BlockLayout = null,

// Add cache as field
word_cache: std.AutoHashMap(u64, WordCache),

// Map of input element nodes to their bounding boxes for hit testing
input_bounds: std.AutoHashMap(*Node, Bounds),
// Collected bounds for anchor elements
link_bounds: std.ArrayList(LinkBoundEntry),
// Collected bounds for iframe elements
iframe_bounds: std.ArrayList(IframeBoundEntry),
// Per-line bounds for focusable elements
focus_bounds: std.ArrayList(FocusBoundEntry),
// Per-line bounds for accessible elements
accessibility_bounds: std.ArrayList(AccessibilityBoundEntry),

// Cumulative transform offset for hit testing (tracks nested transforms)
transform_offset_x: i32 = 0,
transform_offset_y: i32 = 0,

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

pub fn zoom(self: *const Layout) f32 {
    return if (self.accessibility.zoom > 0) self.accessibility.zoom else 1.0;
}

fn toLayoutPx(self: *const Layout, device_px: i32) i32 {
    const z = self.zoom();
    if (z == 1.0) return device_px;
    return @intFromFloat(@as(f32, @floatFromInt(device_px)) / z);
}

fn toDevicePx(self: *const Layout, layout_px: i32) i32 {
    const z = self.zoom();
    if (z == 1.0) return layout_px;
    return @intFromFloat(@as(f32, @floatFromInt(layout_px)) * z);
}

fn scaledFontSize(self: *const Layout, css_size: i32) i32 {
    const scaled = self.toDevicePx(css_size);
    return if (scaled < 1) 1 else scaled;
}

fn layoutWindowWidth(self: *const Layout) i32 {
    return self.toLayoutPx(self.window_width);
}

pub fn layoutScrollbarWidth(self: *const Layout) i32 {
    return self.toLayoutPx(scrollbar_width);
}

const ColorSchemeSupport = struct {
    light: bool,
    dark: bool,
};

fn parseColorSchemeValue(value: []const u8) ColorSchemeSupport {
    var supports_light = false;
    var supports_dark = false;
    var tokens = std.mem.tokenizeAny(u8, value, " \t");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "light")) {
            supports_light = true;
        } else if (std.mem.eql(u8, token, "dark")) {
            supports_dark = true;
        }
    }
    return .{ .light = supports_light, .dark = supports_dark };
}

fn parseLengthAttribute(value: []const u8) ?i32 {
    if (value.len == 0) return null;
    if (std.mem.endsWith(u8, value, "px")) {
        const num_str = value[0 .. value.len - 2];
        return std.fmt.parseInt(i32, num_str, 10) catch null;
    }
    return std.fmt.parseInt(i32, value, 10) catch null;
}

pub fn resolveColorScheme(self: *const Layout, value: []const u8) bool {
    const support = parseColorSchemeValue(value);
    if (!support.light and !support.dark) return self.accessibility.prefers_dark;
    if (support.light and support.dark) return self.accessibility.prefers_dark;
    if (support.dark) return true;
    return false;
}

fn remapColor(self: *const Layout, color: browser.Color) browser.Color {
    if (!self.color_scheme_dark or color.a == 0) return color;

    if (self.accessibility.dark_palette) |palette| {
        if (color.r == 0 and color.g == 0 and color.b == 0) {
            return palette.text;
        }
        if (color.r == 255 and color.g == 255 and color.b == 255) {
            return palette.background;
        }
        if ((color.r == 173 and color.g == 216 and color.b == 230) or
            (color.r == 255 and color.g == 165 and color.b == 0))
        {
            return palette.control_background;
        }
    }

    const clamp_channel = struct {
        fn clamp(value: u8) u8 {
            const v: i32 = value;
            return @intCast(std.math.clamp(v, 24, 231));
        }
    }.clamp;

    return .{
        .r = clamp_channel(255 - color.r),
        .g = clamp_channel(255 - color.g),
        .b = clamp_channel(255 - color.b),
        .a = color.a,
    };
}

pub fn init(
    allocator: std.mem.Allocator,
    renderer: sdl2.Renderer,
    window_width: i32,
    window_height: i32,
    rtl_text: bool,
) !*Layout {
    const font_manager = try font.FontManager.init(allocator, renderer);
    const layout = try allocator.create(Layout);

    const layout_width = window_width;
    const scrollbar_width_css = scrollbar_width;

    layout.* = Layout{
        .allocator = allocator,
        .font_manager = font_manager,
        .grapheme_data = undefined,
        .window_width = window_width,
        .window_height = window_height,
        .rtl_text = rtl_text,
        .cursor_x = if (rtl_text) layout_width - scrollbar_width_css - h_offset else h_offset,
        .cursor_y = v_offset,
        .line_left = h_offset,
        .line_right = layout_width - scrollbar_width_css - h_offset,
        .is_bold = false,
        .is_italic = false,
        .content_height = 0,
        .display_list = std.ArrayList(DisplayItem).empty,
        .current_display_target = undefined,
        .word_cache = std.AutoHashMap(u64, WordCache).init(allocator),
        .input_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
        .link_bounds = std.ArrayList(LinkBoundEntry).empty,
        .iframe_bounds = std.ArrayList(IframeBoundEntry).empty,
        .focus_bounds = std.ArrayList(FocusBoundEntry).empty,
        .accessibility_bounds = std.ArrayList(AccessibilityBoundEntry).empty,
    };

    layout.current_display_target = &layout.display_list;

    try layout.font_manager.loadSystemFont(layout.scaledFontSize(layout.size));
    layout.grapheme_data = try grapheme.init(allocator);

    layout.style_stack = std.ArrayList(StyleSnapshot).empty;
    return layout;
}

pub fn deinit(self: *Layout) void {
    // clean up hash map for fonts
    self.grapheme_data.deinit(self.allocator);
    self.font_manager.deinit();

    var it = self.word_cache.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.value_ptr.graphemes);
    }
    self.word_cache.deinit();

    self.input_bounds.deinit();
    self.link_bounds.deinit(self.allocator);
    self.iframe_bounds.deinit(self.allocator);
    self.focus_bounds.deinit(self.allocator);
    self.accessibility_bounds.deinit(self.allocator);

    self.display_list.deinit(self.allocator);
    self.style_stack.deinit(self.allocator);

    self.allocator.destroy(self);
}

fn recurseNode(self: *Layout, node: Node, node_ptr: ?*Node, line_buffer: *std.ArrayList(LineItem)) !void {
    switch (node) {
        .text => |t| {
            if (t.parent) |parent| {
                switch (parent.*) {
                    .element => |e| {
                        if (isNonRenderTag(e.tag)) return;
                    },
                    else => {},
                }
            }
            try self.handleTextToken(t.text, line_buffer, node_ptr);
        },
        .element => |e| {
            if (isNonRenderTag(e.tag)) return;
            // Apply CSS styles before processing this element
            try self.applyNodeStyles(e, line_buffer);

            // Handle br tag for line breaks
            if (std.mem.eql(u8, e.tag, "br")) {
                try self.flushLine(line_buffer);
            } else if (std.mem.eql(u8, e.tag, "input") or std.mem.eql(u8, e.tag, "button")) {
                // Handle input and button elements - render as inline widgets
                try self.handleInputElement(node, node_ptr, line_buffer);
            } else if (std.mem.eql(u8, e.tag, "img")) {
                try self.handleImageElement(node, node_ptr, line_buffer);
            } else if (std.ascii.eqlIgnoreCase(e.tag, "iframe")) {
                try self.handleIframeElement(node, node_ptr, line_buffer);
            } else {
                for (e.children.items) |*child| {
                    try self.recurseNode(child.*, child, line_buffer);
                }
            }

            // Restore styles after closing this element
            try self.restoreNodeStyles(line_buffer);
        },
    }
}

fn isNonRenderTag(tag: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag, "script") or
        std.ascii.eqlIgnoreCase(tag, "style") or
        std.ascii.eqlIgnoreCase(tag, "head") or
        std.ascii.eqlIgnoreCase(tag, "meta") or
        std.ascii.eqlIgnoreCase(tag, "link") or
        std.ascii.eqlIgnoreCase(tag, "title");
}

fn handleInputElement(self: *Layout, node: Node, node_ptr: ?*Node, line_buffer: *std.ArrayList(LineItem)) !void {
    const element = switch (node) {
        .element => |e| e,
        else => return,
    };

    var input_layout = InputLayout.init(self.allocator);
    try input_layout.measure(self, element);

    try input_layout.embed.appendInline(self, line_buffer, node_ptr, .{
        .input = input_layout,
    });
}

fn handleImageElement(self: *Layout, node: Node, node_ptr: ?*Node, line_buffer: *std.ArrayList(LineItem)) !void {
    const element = switch (node) {
        .element => |e| e,
        else => return,
    };

    var width_attr: ?i32 = null;
    var height_attr: ?i32 = null;
    if (element.attributes) |attrs| {
        if (attrs.get("width")) |width_str| {
            width_attr = parseLengthAttribute(width_str);
        }
        if (attrs.get("height")) |height_str| {
            height_attr = parseLengthAttribute(height_str);
        }
    }

    const image_data = element.image_data;
    const intrinsic_width: i32 = if (image_data) |data|
        self.toLayoutPx(@intCast(data.image.width))
    else
        0;
    const intrinsic_height: i32 = if (image_data) |data|
        self.toLayoutPx(@intCast(data.image.height))
    else
        0;

    var layout_width: i32 = 0;
    var layout_height: i32 = 0;

    if (width_attr != null and height_attr != null) {
        layout_width = width_attr.?;
        layout_height = height_attr.?;
    } else if (width_attr != null) {
        layout_width = width_attr.?;
        if (intrinsic_width > 0 and intrinsic_height > 0) {
            layout_height = @divTrunc(layout_width * intrinsic_height, intrinsic_width);
        } else {
            layout_height = layout_width;
        }
    } else if (height_attr != null) {
        layout_height = height_attr.?;
        if (intrinsic_width > 0 and intrinsic_height > 0) {
            layout_width = @divTrunc(layout_height * intrinsic_width, intrinsic_height);
        } else {
            layout_width = layout_height;
        }
    } else {
        layout_width = intrinsic_width;
        layout_height = intrinsic_height;
    }

    if (layout_width <= 0 or layout_height <= 0) return;

    var image_layout = ImageLayout.init(layout_width, layout_height, image_data);
    try image_layout.embed.appendInline(self, line_buffer, node_ptr, .{
        .image = image_layout,
    });
}

fn handleIframeElement(self: *Layout, node: Node, node_ptr: ?*Node, line_buffer: *std.ArrayList(LineItem)) !void {
    const element = switch (node) {
        .element => |e| e,
        else => return,
    };

    var width_attr: ?i32 = null;
    var height_attr: ?i32 = null;
    if (element.attributes) |attrs| {
        if (attrs.get("width")) |width_str| {
            width_attr = parseLengthAttribute(width_str);
        }
        if (attrs.get("height")) |height_str| {
            height_attr = parseLengthAttribute(height_str);
        }
    }

    var layout_width: i32 = 300;
    var layout_height: i32 = 150;
    if (width_attr != null) {
        layout_width = width_attr.?;
    }
    if (height_attr != null) {
        layout_height = height_attr.?;
    }

    if (layout_width <= 0 or layout_height <= 0) return;

    var iframe_layout = IframeLayout.init(layout_width, layout_height);
    try iframe_layout.embed.appendInline(self, line_buffer, node_ptr, .{
        .iframe = iframe_layout,
    });
}

const StyleSnapshot = struct {
    is_bold: bool,
    is_italic: bool,
    size: i32,
    text_color: browser.Color,
    transform_offset_x: i32,
    transform_offset_y: i32,
    color_scheme_dark: bool,
};

fn applyNodeStyles(self: *Layout, element: parser.Element, _: *std.ArrayList(LineItem)) !void {
    // Save current style state including transform offsets
    const snapshot = StyleSnapshot{
        .is_bold = self.is_bold,
        .is_italic = self.is_italic,
        .size = self.size,
        .text_color = self.text_color,
        .transform_offset_x = self.transform_offset_x,
        .transform_offset_y = self.transform_offset_y,
        .color_scheme_dark = self.color_scheme_dark,
    };
    try self.style_stack.append(self.allocator, snapshot);

    if (element.style) |style_field| {
        const style_map = style_field.get();
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

        // Apply transform to cumulative offset for hit testing
        if (style_map.get("transform")) |transform_str| {
            if (parseTranslate(transform_str)) |translate| {
                self.transform_offset_x += translate.x;
                self.transform_offset_y += translate.y;
            }
        }

        if (style_map.get("color-scheme")) |scheme| {
            self.color_scheme_dark = self.resolveColorScheme(scheme);
            if (std.mem.eql(u8, element.tag, "html") or std.mem.eql(u8, element.tag, "body")) {
                self.document_color_scheme_dark = self.color_scheme_dark;
            }
        }
    }
}

fn restoreNodeStyles(self: *Layout, _: *std.ArrayList(LineItem)) !void {
    // Restore the previous style state including transform offsets
    if (self.style_stack.items.len > 0) {
        const snapshot = self.style_stack.pop() orelse return;
        self.is_bold = snapshot.is_bold;
        self.is_italic = snapshot.is_italic;
        self.size = snapshot.size;
        self.text_color = snapshot.text_color;
        self.transform_offset_x = snapshot.transform_offset_x;
        self.transform_offset_y = snapshot.transform_offset_y;
        self.color_scheme_dark = snapshot.color_scheme_dark;
    }
}

fn flushLine(self: *Layout, line_buffer: *std.ArrayList(LineItem)) !void {
    // Nothing to flush? Return.
    if (line_buffer.items.len == 0) return;

    // === Handle title centering if needed ===
    if (self.is_title) {
        // Determine the bounding x-coordinates from the line items.
        var min_x: i32 = line_buffer.items[0].x;
        var max_x: i32 = line_buffer.items[0].x + line_buffer.items[0].width;
        for (line_buffer.items) |item| {
            if (item.x < min_x) {
                min_x = item.x;
            }
            const item_right = item.x + item.width;
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
        const is_superscript = switch (item.payload) {
            .glyph => |glyph_payload| glyph_payload.glyph.is_superscript,
            .input => false,
            .image => false,
            .iframe => false,
        };
        if (is_superscript) {
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
    const line_top = self.cursor_y;
    const line_box_height = line_height + extra_leading;

    var focus_map = std.AutoHashMap(*Node, Bounds).init(self.allocator);
    defer focus_map.deinit();
    var accessibility_map = std.AutoHashMap(*Node, Bounds).init(self.allocator);
    defer accessibility_map.deinit();

    // === PASS 2: Position glyphs ===
    for (line_buffer.items) |item| {
        var final_y: i32 = undefined;

        const is_superscript = switch (item.payload) {
            .glyph => |glyph_payload| glyph_payload.glyph.is_superscript,
            .input => false,
            .image => false,
            .iframe => false,
        };
        if (is_superscript) {
            // Position superscript so its top aligns with normal text top
            final_y = self.cursor_y; // Start at line top
        } else {
            // Normal baseline alignment
            final_y = baseline - item.ascent;
        }

        const bounds_x = item.x + item.hit_offset_x;
        const bounds_y = final_y + item.hit_offset_y;
        const line_bounds_y = line_top + item.hit_offset_y;

        if (item.node_ptr) |ptr| {
            if (item.payload == .input) {
                try self.input_bounds.put(ptr, .{
                    .x = bounds_x,
                    .y = bounds_y,
                    .width = item.width,
                    .height = item.height,
                });
            }
            try self.recordLinkBounds(ptr, bounds_x, line_bounds_y, item.width, line_box_height);
            if (findFocusableNode(ptr)) |focus_node| {
                const right = bounds_x + item.width;
                const bottom = bounds_y + item.height;
                if (focus_map.getPtr(focus_node)) |existing| {
                    const existing_right = existing.x + existing.width;
                    const existing_bottom = existing.y + existing.height;
                    if (bounds_x < existing.x) existing.x = bounds_x;
                    if (bounds_y < existing.y) existing.y = bounds_y;
                    const new_right = if (right > existing_right) right else existing_right;
                    const new_bottom = if (bottom > existing_bottom) bottom else existing_bottom;
                    existing.width = new_right - existing.x;
                    existing.height = new_bottom - existing.y;
                } else {
                    try focus_map.put(focus_node, .{
                        .x = bounds_x,
                        .y = bounds_y,
                        .width = item.width,
                        .height = item.height,
                    });
                }
            }
            if (findAccessibleNode(ptr)) |accessible_node| {
                const right = bounds_x + item.width;
                const bottom = bounds_y + item.height;
                if (accessibility_map.getPtr(accessible_node)) |existing| {
                    const existing_right = existing.x + existing.width;
                    const existing_bottom = existing.y + existing.height;
                    if (bounds_x < existing.x) existing.x = bounds_x;
                    if (bounds_y < existing.y) existing.y = bounds_y;
                    const new_right = if (right > existing_right) right else existing_right;
                    const new_bottom = if (bottom > existing_bottom) bottom else existing_bottom;
                    existing.width = new_right - existing.x;
                    existing.height = new_bottom - existing.y;
                } else {
                    try accessibility_map.put(accessible_node, .{
                        .x = bounds_x,
                        .y = bounds_y,
                        .width = item.width,
                        .height = item.height,
                    });
                }
            }
        }

        switch (item.payload) {
            .glyph => |glyph_payload| {
                try self.current_display_target.append(self.allocator, DisplayItem{
                    .glyph = .{
                        .x = item.x,
                        .y = final_y,
                        .glyph = glyph_payload.glyph,
                        .color = glyph_payload.color, // Use the color captured when item was added to line buffer
                    },
                });
            },
            .input => |input_payload| {
                try input_payload.paintAt(self.current_display_target, self, item.x, final_y);
            },
            .image => |image_payload| {
                try self.current_display_target.append(self.allocator, DisplayItem{
                    .image = .{
                        .x1 = item.x,
                        .y1 = final_y,
                        .x2 = item.x + item.width,
                        .y2 = final_y + item.height,
                        .source_width = image_payload.source_width,
                        .source_height = image_payload.source_height,
                        .pixels = image_payload.pixels,
                        .opacity = image_payload.opacity,
                    },
                });
            },
            .iframe => |iframe_payload| {
                if (item.node_ptr) |ptr| {
                    try self.current_display_target.append(self.allocator, DisplayItem{
                        .iframe = .{
                            .rect = .{
                                .left = bounds_x,
                                .top = bounds_y,
                                .right = bounds_x + item.width,
                                .bottom = bounds_y + item.height,
                            },
                            .node = ptr,
                        },
                    });
                    try self.iframe_bounds.append(self.allocator, .{
                        .node = ptr,
                        .bounds = .{
                            .x = bounds_x,
                            .y = bounds_y,
                            .width = item.width,
                            .height = item.height,
                        },
                    });
                } else {
                    try iframe_payload.paintAt(self.current_display_target, self, item.x, final_y);
                }
            },
        }
    }

    var focus_it = focus_map.iterator();
    while (focus_it.next()) |entry| {
        try self.focus_bounds.append(self.allocator, .{
            .node = entry.key_ptr.*,
            .bounds = entry.value_ptr.*,
        });
    }

    var accessibility_it = accessibility_map.iterator();
    while (accessibility_it.next()) |entry| {
        try self.accessibility_bounds.append(self.allocator, .{
            .node = entry.key_ptr.*,
            .bounds = entry.value_ptr.*,
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
    node_ptr: ?*Node,
    options: struct {
        force_newline: bool = false,
        is_superscript: bool = false,
        is_small_caps: bool = false,
    },
) !void {
    // Extract first code point to determine character category
    var cp_iter = code_point.Iterator{ .bytes = gme };
    const first_cp = cp_iter.next() orelse return;

    // Handle newlines explicitly before font shaping.
    if (std.mem.eql(u8, gme, "\n") or std.mem.eql(u8, gme, "\r") or options.force_newline) {
        try self.flushLine(line_buffer);
        self.cursor_x = if (self.rtl_text) self.line_right else self.line_left;
        return;
    }

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
            glyph = self.font_manager.getStyledGlyph(
                upper_buf[0..upper_len.len],
                .Bold, // Force bold for small caps
                slant,
                self.scaledFontSize(@divTrunc(self.size * 4, 5)), // Make it ~80% of normal size
                use_monospace,
            ) catch return;
        } else {
            // Regular rendering for non-lowercase characters
            glyph = self.font_manager.getStyledGlyph(
                gme,
                weight,
                slant,
                self.scaledFontSize(self.size),
                use_monospace,
            ) catch return;
        }
    } else {
        // Normal rendering
        glyph = self.font_manager.getStyledGlyph(
            gme,
            weight,
            slant,
            self.scaledFontSize(if (options.is_superscript) @divTrunc(self.size, 2) else self.size),
            use_monospace,
        ) catch return;
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

    const glyph_width = self.toLayoutPx(glyph.w);
    const glyph_height = self.toLayoutPx(glyph.h);
    const glyph_ascent = self.toLayoutPx(glyph.ascent);
    const glyph_descent = self.toLayoutPx(glyph.descent);

    // Check if we need to wrap (only at window edge)
    if (self.cursor_x + glyph_width > self.line_right) {
        try self.flushLine(line_buffer);
        self.cursor_x = if (self.rtl_text) self.line_right else self.line_left;
    }

    // Add glyph to line buffer with current text color
    try line_buffer.append(self.allocator, LineItem{
        .x = self.cursor_x,
        .hit_offset_x = self.transform_offset_x,
        .hit_offset_y = self.transform_offset_y,
        .ascent = glyph_ascent,
        .descent = glyph_descent,
        .width = glyph_width,
        .height = glyph_height,
        .node_ptr = node_ptr,
        .payload = .{
            .glyph = .{
                .glyph = glyph,
                .color = self.remapColor(self.text_color),
            },
        },
    });
    self.cursor_x += glyph_width;
}

fn recordLinkBounds(self: *Layout, node_ptr: *Node, x: i32, y: i32, width: i32, height: i32) !void {
    if (width <= 0 or height <= 0) return;

    var current: ?*Node = node_ptr;
    while (current) |ptr| {
        switch (ptr.*) {
            .element => |*el| {
                if (std.mem.eql(u8, el.tag, "a")) {
                    const right = x + width;
                    const bottom = y + height;

                    var maybe_entry: ?*LinkBoundEntry = null;
                    for (self.link_bounds.items) |*entry| {
                        if (entry.node == ptr) {
                            maybe_entry = entry;
                            break;
                        }
                    }

                    if (maybe_entry) |entry| {
                        const existing_right = entry.bounds.x + entry.bounds.width;
                        const existing_bottom = entry.bounds.y + entry.bounds.height;

                        if (x < entry.bounds.x) entry.bounds.x = x;
                        if (y < entry.bounds.y) entry.bounds.y = y;

                        const new_right = if (right > existing_right) right else existing_right;
                        const new_bottom = if (bottom > existing_bottom) bottom else existing_bottom;

                        entry.bounds.width = new_right - entry.bounds.x;
                        entry.bounds.height = new_bottom - entry.bounds.y;
                    } else {
                        try self.link_bounds.append(self.allocator, .{
                            .node = ptr,
                            .bounds = .{
                                .x = x,
                                .y = y,
                                .width = width,
                                .height = height,
                            },
                        });
                    }
                    return;
                }
                current = el.parent;
            },
            .text => |*txt| {
                current = txt.parent;
            },
        }
    }
}

fn isTabIndexFocusable(element: *const parser.Element) bool {
    if (element.attributes) |attrs| {
        if (attrs.get("tabindex")) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) return true;
            const idx = std.fmt.parseInt(i32, trimmed, 10) catch return true;
            return idx >= 0;
        }
    }
    return false;
}

fn isElementFocusable(element: *const parser.Element) bool {
    if (std.mem.eql(u8, element.tag, "input") or std.mem.eql(u8, element.tag, "button")) {
        return true;
    }
    if (element.attributes) |attrs| {
        if (attrs.get("contenteditable") != null) {
            return true;
        }
    }
    if (std.mem.eql(u8, element.tag, "a")) {
        if (element.attributes) |attrs| {
            return attrs.get("href") != null or isTabIndexFocusable(element);
        }
    }
    return isTabIndexFocusable(element);
}

fn findFocusableNode(node_ptr: *Node) ?*Node {
    var current: ?*Node = node_ptr;
    while (current) |ptr| {
        switch (ptr.*) {
            .element => |*el| {
                if (isElementFocusable(el)) return ptr;
                current = el.parent;
            },
            .text => |*txt| {
                current = txt.parent;
            },
        }
    }
    return null;
}

fn isPresentationalTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "script") or
        std.mem.eql(u8, tag, "style") or
        std.mem.eql(u8, tag, "head") or
        std.mem.eql(u8, tag, "meta") or
        std.mem.eql(u8, tag, "link") or
        std.mem.eql(u8, tag, "title") or
        std.mem.eql(u8, tag, "br");
}

fn isElementAccessible(element: *const parser.Element) bool {
    if (isPresentationalTag(element.tag)) return false;
    if (element.attributes) |attrs| {
        if (attrs.get("aria-hidden")) |value| {
            if (std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "true")) return false;
        }
    }
    return true;
}

fn findAccessibleNode(node_ptr: *Node) ?*Node {
    var current: ?*Node = node_ptr;
    while (current) |ptr| {
        switch (ptr.*) {
            .element => |*el| {
                if (isElementAccessible(el)) return ptr;
                current = el.parent;
            },
            .text => |*txt| {
                current = txt.parent;
            },
        }
    }
    return null;
}

// Update handlePreformattedText to use the common processGrapheme function
fn handlePreformattedText(
    self: *Layout,
    content: []const u8,
    line_buffer: *std.ArrayList(LineItem),
    node_ptr: ?*Node,
) !void {
    // Save current font category and switch to monospace
    if (!self.is_preformatted) {
        self.prev_font_category = self.current_font_category;
        self.current_font_category = .monospace;
    }

    var g_iter = self.grapheme_data.iterator(content);
    while (g_iter.next()) |gc| {
        const gme = gc.bytes(content);
        try self.processGrapheme(gme, line_buffer, node_ptr, .{
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
    node_ptr: ?*Node,
) !void {
    if (self.is_preformatted) {
        try self.handlePreformattedText(content, line_buffer, node_ptr);
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
                try self.processGrapheme(entity.replacement, line_buffer, node_ptr, .{
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
        try self.processGrapheme(gme, line_buffer, node_ptr, .{
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
    self.line_right = self.layoutWindowWidth() - self.layoutScrollbarWidth() - h_offset;
    self.size = self.default_font_size;

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
            var g_iter = self.grapheme_data.iterator(source[i .. i + 1]);
            if (g_iter.next()) |gc| {
                const gme = gc.bytes(source[i..]);
                try self.processGrapheme(gme, &line_buffer, null, .{
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
            var g_iter = self.grapheme_data.iterator(source[i .. i + 1]);
            if (g_iter.next()) |gc| {
                const gme = gc.bytes(source[i..]);
                try self.processGrapheme(gme, &line_buffer, null, .{
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
        var g_iter = self.grapheme_data.iterator(source[i..]);
        if (g_iter.next()) |gc| {
            const gme = gc.bytes(source[i..]);
            try self.processGrapheme(gme, &line_buffer, null, .{
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

const INPUT_WIDTH_PX: i32 = 200;

// Input layout for form widgets (input and button elements)
pub const InputLayout = struct {
    embed: EmbedLayout,
    font_size: i32 = 16,
    font_weight: FontWeight = .Normal,
    font_slant: FontSlant = .Roman,
    color: browser.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    bgcolor: browser.Color = .{ .r = 173, .g = 216, .b = 230, .a = 255 }, // lightblue
    text: []const u8 = "",
    is_focused: bool = false,

    pub fn init(allocator: std.mem.Allocator) InputLayout {
        _ = allocator;
        return .{
            .embed = .{},
        };
    }

    pub fn measure(self: *InputLayout, engine: *Layout, element: parser.Element) !void {
        self.font_weight = if (engine.is_bold) .Bold else .Normal;
        self.font_slant = if (engine.is_italic) .Italic else .Roman;
        self.font_size = engine.scaledFontSize(engine.size);
        self.color = engine.text_color;

        if (element.style) |*style_field| {
            const style_map = style_field.get();
            if (style_map.get("background-color")) |bg| {
                if (parseColor(bg)) |col| {
                    self.bgcolor = col;
                }
            }
        }

        if (std.mem.eql(u8, element.tag, "input")) {
            if (element.attributes) |attrs| {
                self.text = attrs.get("value") orelse "";
            }
        } else if (std.mem.eql(u8, element.tag, "button")) {
            if (element.children.items.len == 1) {
                switch (element.children.items[0]) {
                    .text => |t| {
                        self.text = t.text;
                    },
                    else => {
                        std.debug.print("Ignoring HTML contents inside button\n", .{});
                    },
                }
            }
        }

        const glyph = try engine.font_manager.getStyledGlyph(
            "X",
            self.font_weight,
            self.font_slant,
            self.font_size,
            false,
        );

        self.embed.width = INPUT_WIDTH_PX;
        const ascent_value = engine.toLayoutPx(glyph.ascent);
        const descent_value = engine.toLayoutPx(glyph.descent);
        self.embed.ascent = ascent_value;
        self.embed.descent = descent_value;
        self.embed.height = ascent_value + descent_value;
        self.is_focused = element.is_focused;
    }

    pub fn paintAt(self: *const InputLayout, commands: *std.ArrayList(DisplayItem), engine: *Layout, x: i32, y: i32) !void {
        const width_value = self.embed.width;
        const height_value = self.embed.height;
        const ascent_value = self.embed.ascent;
        const remapped_bg = engine.remapColor(self.bgcolor);
        if (remapped_bg.a > 0) {
            try commands.append(engine.allocator, DisplayItem{
                .rect = .{
                    .x1 = x,
                    .y1 = y,
                    .x2 = x + width_value,
                    .y2 = y + height_value,
                    .color = remapped_bg,
                },
            });
        }

        var text_x = x + 2;
        const baseline_y = y + ascent_value;
        if (self.text.len > 0) {
            var g_iter = engine.grapheme_data.iterator(self.text);

            while (g_iter.next()) |gc| {
                const gme = gc.bytes(self.text);
                const glyph_text = if (std.mem.eql(u8, gme, "\n") or std.mem.eql(u8, gme, "\r"))
                    " "
                else
                    gme;
                const glyph = try engine.font_manager.getStyledGlyph(
                    glyph_text,
                    self.font_weight,
                    self.font_slant,
                    self.font_size,
                    false,
                );

                try commands.append(engine.allocator, DisplayItem{
                    .glyph = .{
                        .x = text_x,
                        .y = baseline_y - engine.toLayoutPx(glyph.ascent),
                        .glyph = glyph,
                        .color = engine.remapColor(self.color),
                    },
                });
                text_x += engine.toLayoutPx(glyph.w);
            }
        }

        if (self.is_focused) {
            try drawCursor(
                commands,
                engine.allocator,
                text_x,
                y,
                height_value,
                engine.remapColor(.{ .r = 255, .g = 0, .b = 0, .a = 255 }),
            );
        }
    }
};

// Text layout for individual words
pub const TextLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    word: []const u8,
    parent: *LineLayout,
    previous: ?*TextLayout,

    // Plain fields
    zoom: f32 = 1.0,
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

    // Dirty tracking
    dirty: bool = true,
    has_dirty_descendants: bool = false,

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
        // Word and node not owned by this layout
    }

    pub fn mark(self: *TextLayout) void {
        self.dirty = true;
        self.parent.mark();
    }

    pub fn layout(self: *TextLayout, engine: *Layout) !void {
        // TODO: Skip layout if nothing is dirty
        // if (!self.layout_needed()) return;

        // self.zoom.copy(&self.parent.zoom);
        // Get font properties from node style
        // In a real browser, we'd read from self.node.style
        // For now, use the engine's current style state
        self.font_weight = if (engine.is_bold) .Bold else .Normal;
        self.font_slant = if (engine.is_italic) .Italic else .Roman;
        self.font_size = engine.scaledFontSize(engine.size);
        self.color = engine.text_color;

        // Measure the word to get its width
        const glyph = try engine.font_manager.getStyledGlyph(
            self.word,
            self.font_weight,
            self.font_slant,
            self.font_size,
            false,
        );

        const width_value = engine.toLayoutPx(glyph.w);
        if (self.width != width_value) {
            self.width = width_value;
            self.dirty = true;
        }

        // Store font metrics for baseline calculation
        const ascent_value = engine.toLayoutPx(glyph.ascent);
        const descent_value = engine.toLayoutPx(glyph.descent);
        if (self.ascent != ascent_value) {
            self.ascent = ascent_value;
            self.dirty = true;
        }
        if (self.descent != descent_value) {
            self.descent = descent_value;
            self.dirty = true;
        }

        // Height is the line spacing (ascent + descent)
        const height_value = ascent_value + descent_value;
        if (self.height != height_value) {
            self.height = height_value;
            self.dirty = true;
        }

        // Compute x position (horizontal stacking with space between words)
        const x_value = if (self.previous) |prev| x: {
            // Measure a space character
            const space_glyph = try engine.font_manager.getStyledGlyph(
                " ",
                prev.font_weight,
                prev.font_slant,
                prev.font_size,
                false,
            );
            const space = engine.toLayoutPx(space_glyph.w);
            break :x prev.x + space + prev.width;
        } else x: {
            break :x self.parent.x;
        };
        // Just compute, don't set dirty during layout
        self.x = x_value;
        // y position is computed by LineLayout after baseline is determined

        // Clear flags after layout pass
        self.dirty = false;
        self.has_dirty_descendants = false;
    }

    pub fn paint(self: *TextLayout, engine: *Layout) !void {
        var commands = std.ArrayList(DisplayItem).empty;
        defer commands.deinit(engine.allocator);
        try self.paintToList(&commands, engine);
        for (commands.items) |cmd| {
            try engine.display_list.append(engine.allocator, cmd);
        }
    }

    pub fn paintToList(self: *TextLayout, commands: *std.ArrayList(DisplayItem), engine: *Layout) !void {
        // Paint the word using the stored font properties
        const glyph = try engine.font_manager.getStyledGlyph(
            self.word,
            self.font_weight,
            self.font_slant,
            self.font_size,
            false,
        );

        try commands.append(self.allocator, DisplayItem{
            .glyph = .{
                .x = self.x,
                .y = self.y,
                .glyph = glyph,
                .color = engine.remapColor(self.color),
            },
        });
    }

    pub fn layout_needed(self: *const TextLayout) bool {
        return self.dirty or self.has_dirty_descendants;
    }

    pub fn shouldPaint(self: *const TextLayout) bool {
        _ = self;
        return true;
    }
};

// Line layout for each line of text
pub const LineLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    parent: *BlockLayout,
    previous: ?*LineLayout,

    zoom: f32 = 1.0,
    children: std.ArrayList(*TextLayout),
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    ascent: i32 = 0,
    descent: i32 = 0,

    dirty: bool = true,
    has_dirty_descendants: bool = false,

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
        // TODO: Skip layout if nothing is dirty
        // if (!self.layout_needed()) return;

        // Position the line relative to parent block
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
        self.ascent = max_ascent;

        // Baseline with 1.25 leading factor
        const baseline = self.y + @as(i32, @intFromFloat(1.25 * @as(f32, @floatFromInt(max_ascent))));

        // Position each word vertically relative to baseline (just compute, don't set dirty)
        for (self.children.items) |word| {
            const word_ascent = word.ascent;
            const y_value = baseline - word_ascent;
            word.y = y_value;
        }

        // Compute maximum descent
        var max_descent: i32 = 0;
        for (self.children.items) |word| {
            if (word.descent > max_descent) {
                max_descent = word.descent;
            }
        }

        // Compute line height with 1.25 leading factor
        self.descent = max_descent;
        self.height = @intFromFloat(1.25 * @as(f32, @floatFromInt(max_ascent + max_descent)));

        // Clear flags after layout pass
        self.dirty = false;
        self.has_dirty_descendants = false;
    }

    pub fn paint(self: *LineLayout, engine: *Layout) !void {
        var commands = std.ArrayList(DisplayItem).empty;
        defer commands.deinit(engine.allocator);
        try self.paintToList(&commands, engine);
        for (commands.items) |cmd| {
            try engine.display_list.append(engine.allocator, cmd);
        }
    }

    pub fn paintToList(self: *LineLayout, commands: *std.ArrayList(DisplayItem), engine: *Layout) !void {
        // Paint each word in the line
        for (self.children.items) |text| {
            try text.paintToList(commands, engine);
        }
    }

    pub fn layout_needed(self: *const LineLayout) bool {
        return self.dirty or self.has_dirty_descendants;
    }

    pub fn mark(self: *LineLayout) void {
        self.dirty = true;
        self.parent.mark();
    }

    pub fn shouldPaint(self: *const LineLayout) bool {
        _ = self;
        return true;
    }
};

pub const DocumentLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    node_ptr: *Node,

    zoom: f32 = 1.0,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    children: std.ArrayList(*BlockLayout),

    dirty: bool = true,
    has_dirty_descendants: bool = false,

    pub fn init(allocator: std.mem.Allocator, node: *Node) !*DocumentLayout {
        const document = try allocator.create(DocumentLayout);
        document.* = DocumentLayout{
            .allocator = allocator,
            .node = node.*,
            .node_ptr = node,
            .zoom = 1.0,
            .children = std.ArrayList(*BlockLayout).empty,
            .x = h_offset,
            .y = v_offset,
            .width = 0,
            .height = 0,
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
        // TODO: Skip layout if nothing is dirty
        // if (!self.layout_needed()) return;

        // Update dimensions (just compute, don't set dirty)
        self.x = h_offset;
        self.y = v_offset;

        const width_value = engine.layoutWindowWidth() - engine.layoutScrollbarWidth() - (2 * h_offset);
        self.width = width_value;

        const zoom_value = engine.zoom();
        self.zoom = zoom_value;

        engine.input_bounds.clearRetainingCapacity();
        engine.link_bounds.clearRetainingCapacity();
        engine.iframe_bounds.clearRetainingCapacity();
        engine.focus_bounds.clearRetainingCapacity();
        engine.accessibility_bounds.clearRetainingCapacity();

        self.node = self.node_ptr.*;

        var root_block = if (self.children.items.len > 0) self.children.items[0] else null;
        if (root_block == null) {
            const child = try BlockLayout.init(self.allocator, self.node, self.node_ptr, self, null, null);
            try self.children.append(self.allocator, child);
            root_block = child;
        }

        const block = root_block.?;
        block.node = self.node;
        block.node_ptr = self.node_ptr;
        try block.layout(engine);

        // Update height from child block (don't set dirty, just compute)
        self.height = block.height;

        // Clear flags after layout pass
        self.dirty = false;
        self.has_dirty_descendants = false;
    }

    pub fn layout_needed(self: *const DocumentLayout) bool {
        return self.dirty or self.has_dirty_descendants;
    }

    pub fn mark(self: *DocumentLayout) void {
        self.dirty = true;
    }

    pub fn shouldPaint(self: *const DocumentLayout) bool {
        _ = self;
        return true;
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
    node_ptr: ?*Node,
    document: *DocumentLayout,
    parent_block: ?*BlockLayout,
    previous: ?*BlockLayout,
    zoom: f32 = 1.0,
    children: std.ArrayList(LayoutChild),
    display_list: std.ArrayList(DisplayItem),
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    cursor_x: i32 = 0,
    dirty: bool = true,
    has_dirty_descendants: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        node: Node,
        node_ptr: ?*Node,
        document: *DocumentLayout,
        parent_block: ?*BlockLayout,
        previous: ?*BlockLayout,
    ) !*BlockLayout {
        const block = try allocator.create(BlockLayout);
        block.* = BlockLayout{
            .allocator = allocator,
            .node = node,
            .node_ptr = node_ptr,
            .document = document,
            .parent_block = parent_block,
            .previous = previous,
            .zoom = 1.0,
            .children = std.ArrayList(LayoutChild).empty,
            .display_list = std.ArrayList(DisplayItem).empty,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
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

    pub fn mark(self: *BlockLayout) void {
        self.dirty = true;
        if (self.parent_block) |parent| {
            parent.mark();
        } else {
            self.document.mark();
        }
    }

    fn isBlockContainer(self: *const BlockLayout) bool {
        switch (self.node) {
            .text => return false,
            .element => |e| {
                // Input, button, and iframe elements are always inline, even though they may have no children
                if (std.ascii.eqlIgnoreCase(e.tag, "input") or std.ascii.eqlIgnoreCase(e.tag, "button") or
                    std.ascii.eqlIgnoreCase(e.tag, "img") or std.ascii.eqlIgnoreCase(e.tag, "iframe"))
                {
                    return false;
                }

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

    fn appendChild(self: *BlockLayout, child: LayoutChild) !void {
        try self.children.append(self.allocator, child);
    }

    // Create a new line for inline content
    fn newLine(self: *BlockLayout) !void {
        self.cursor_x = 0;
        const last_line: ?*LineLayout = if (self.children.items.len > 0) blk: {
            const last_child = self.children.items[self.children.items.len - 1];
            break :blk if (last_child == .line) last_child.line else null;
        } else null;

        const new_line = try LineLayout.init(self.allocator, self.node, self, last_line);
        try self.appendChild(.{ .line = new_line });
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
        // TODO: Skip layout if nothing is dirty
        // if (!self.layout_needed()) return;

        if (self.node_ptr) |ptr| {
            self.node = ptr.*;
        }

        // Update position and dimensions (just compute, don't set dirty)
        const parent_x = if (self.parent_block) |pb| pb.x else self.document.x;
        self.x = parent_x;

        const parent_y = if (self.parent_block) |pb| pb.y else self.document.y;
        const prev_y = if (self.previous) |prev| prev.y + prev.height else parent_y;
        self.y = prev_y;

        const parent_width = if (self.parent_block) |pb| pb.width else self.document.width;
        self.width = parent_width;

        var is_block = self.isBlockContainer();
        if (self.node == .element) {
            const tag = self.node.element.tag;
            if (std.ascii.eqlIgnoreCase(tag, "input") or std.ascii.eqlIgnoreCase(tag, "button") or
                std.ascii.eqlIgnoreCase(tag, "img") or std.ascii.eqlIgnoreCase(tag, "iframe"))
            {
                is_block = false;
            }
        }

        // Reset any cached inline commands
        self.display_list.clearRetainingCapacity();

        if (is_block) {
            // Check if children are dirty and rebuild them if needed
            var children_dirty = false;
            if (self.node_ptr) |node| {
                switch (node.*) {
                    .element => |*el| {
                        if (el.children_dirty) {
                            children_dirty = true;
                            el.children_dirty = false;
                        }
                    },
                    else => {},
                }
            }

            // Rebuild if children are dirty OR if we have no children yet (first layout)
            if (children_dirty or self.children.items.len == 0) {
                for (self.children.items) |child| {
                    child.deinit(self.allocator);
                }
                self.children.clearRetainingCapacity();

                switch (self.node) {
                    .element => |e| {
                        var previous: ?*BlockLayout = null;
                        for (e.children.items) |*child_node| {
                            const child = try BlockLayout.init(self.allocator, child_node.*, child_node, self.document, self, previous);
                            try self.children.append(self.allocator, .{ .block = child });
                            previous = child;
                        }
                    },
                    else => {},
                }
            }

            // Layout all children and compute height
            var computed_height: i32 = 0;
            for (self.children.items) |child| {
                switch (child) {
                    .block => |b| {
                        try b.layout(engine);
                        computed_height += b.height;
                    },
                    .line => |l| {
                        try l.layout(engine);
                        computed_height += l.height;
                    },
                }
            }
            // Just compute, don't set dirty
            self.height = computed_height;

            try recordContentEditableFocusBounds(engine, self);
        } else {
            // Inline layout mode - use the old approach for now
            // TODO: Refactor to populate LineLayout and TextLayout objects
            try engine.layoutInlineBlock(self);

            if (self.children.items.len > 0) {
                for (self.children.items) |child| {
                    child.deinit(self.allocator);
                }
                self.children.clearRetainingCapacity();
            }

            try recordContentEditableFocusBounds(engine, self);
            // Height is set by layoutInlineBlock
        }

        // Clear flags after layout pass
        self.dirty = false;
        self.has_dirty_descendants = false;
    }

    pub fn layout_needed(self: *const BlockLayout) bool {
        return self.dirty or self.has_dirty_descendants;
    }

    pub fn shouldPaint(self: *const BlockLayout) bool {
        switch (self.node) {
            .text => return true,
            .element => |e| {
                // Don't paint background for input/button in BlockLayout
                // They paint themselves in InputLayout
                return !std.mem.eql(u8, e.tag, "input") and !std.mem.eql(u8, e.tag, "button");
            },
        }
    }
};

fn findLastTextLayout(block: *BlockLayout) ?*TextLayout {
    var last: ?*TextLayout = null;
    for (block.children.items) |child| {
        switch (child) {
            .block => |b| {
                if (findLastTextLayout(b)) |found| {
                    last = found;
                }
            },
            .line => |line| {
                for (line.children.items) |text| {
                    last = text;
                }
            },
        }
    }
    return last;
}

fn appendContentEditableCursor(self: *Layout, commands: *std.ArrayList(DisplayItem), block: *BlockLayout) !void {
    if (block.node != .element) return;

    const element = block.node.element;
    if (!element.is_focused) return;
    if (element.attributes == null) return;
    if (element.attributes.?.get("contenteditable") == null) return;

    const cursor_color = self.remapColor(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    if (findLastTextLayout(block)) |text| {
        const cursor_x = text.x + text.width;
        const cursor_y = text.y;
        const cursor_height = text.height;
        try drawCursor(commands, self.allocator, cursor_x, cursor_y, cursor_height, cursor_color);
        return;
    }

    const glyph = try self.font_manager.getStyledGlyph(
        "X",
        .Normal,
        .Roman,
        self.default_font_size,
        false,
    );
    const cursor_height = self.toLayoutPx(glyph.ascent + glyph.descent);
    try drawCursor(commands, self.allocator, block.x, block.y, cursor_height, cursor_color);
}

fn recordContentEditableFocusBounds(self: *Layout, block: *const BlockLayout) !void {
    if (block.node != .element) return;
    const element = block.node.element;
    if (element.attributes == null) return;
    if (element.attributes.?.get("contenteditable") == null) return;
    const node_ptr = block.node_ptr orelse return;

    var height = block.height;
    if (height <= 0) {
        const glyph = try self.font_manager.getStyledGlyph(
            "X",
            .Normal,
            .Roman,
            self.default_font_size,
            false,
        );
        height = self.toLayoutPx(glyph.ascent + glyph.descent);
    }

    const block_bounds = Bounds{
        .x = block.x,
        .y = block.y,
        .width = block.width,
        .height = height,
    };

    for (self.focus_bounds.items) |*entry| {
        if (entry.node == node_ptr) {
            const entry_right = entry.bounds.x + entry.bounds.width;
            const entry_bottom = entry.bounds.y + entry.bounds.height;
            const block_right = block_bounds.x + block_bounds.width;
            const block_bottom = block_bounds.y + block_bounds.height;
            if (block_bounds.x < entry.bounds.x) entry.bounds.x = block_bounds.x;
            if (block_bounds.y < entry.bounds.y) entry.bounds.y = block_bounds.y;
            const new_right = if (block_right > entry_right) block_right else entry_right;
            const new_bottom = if (block_bottom > entry_bottom) block_bottom else entry_bottom;
            entry.bounds.width = new_right - entry.bounds.x;
            entry.bounds.height = new_bottom - entry.bounds.y;
            return;
        }
    }

    try self.focus_bounds.append(self.allocator, .{
        .node = node_ptr,
        .bounds = block_bounds,
    });
}

fn layoutInlineBlock(self: *Layout, block: *BlockLayout) !void {
    const snapshot = snapshotInlineState(self);
    const previous_target = self.current_display_target;
    const previous_inline_block = self.inline_block;
    defer {
        restoreInlineState(self, snapshot);
        self.current_display_target = previous_target;
        self.inline_block = previous_inline_block;
    }
    self.inline_block = block;

    self.line_left = block.x;
    const block_width = block.width;
    self.line_right = block.x + block_width;
    self.cursor_x = if (self.rtl_text) self.line_right else self.line_left;
    self.cursor_y = block.y;
    self.size = self.default_font_size;
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
            try self.handleTextToken(t.text, &line_buffer, null);
        },
        .element => |e| {
            // Apply CSS styles for this block element
            try self.applyNodeStyles(e, &line_buffer);

            // Handle br tag for line breaks
            if (std.mem.eql(u8, e.tag, "br")) {
                try self.flushLine(&line_buffer);
            }

            if (std.ascii.eqlIgnoreCase(e.tag, "input") or std.ascii.eqlIgnoreCase(e.tag, "button")) {
                try self.handleInputElement(block.node, block.node_ptr, &line_buffer);
            } else if (std.ascii.eqlIgnoreCase(e.tag, "img")) {
                try self.handleImageElement(block.node, block.node_ptr, &line_buffer);
            } else if (std.ascii.eqlIgnoreCase(e.tag, "iframe")) {
                try self.handleIframeElement(block.node, block.node_ptr, &line_buffer);
            } else {
                for (e.children.items) |*child| {
                    try self.recurseNode(child.*, child, &line_buffer);
                }
            }

            try self.restoreNodeStyles(&line_buffer);
        },
    }

    try self.flushLine(&line_buffer);
    const computed_height = self.cursor_y - block.y;
    block.height = if (computed_height < 0) 0 else computed_height;
}

fn parseColor(color_str: []const u8) ?browser.Color {
    // Handle hex colors like #rrggbbaa (with alpha)
    if (color_str.len == 9 and color_str[0] == '#') {
        const r = std.fmt.parseInt(u8, color_str[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, color_str[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, color_str[5..7], 16) catch return null;
        const a = std.fmt.parseInt(u8, color_str[7..9], 16) catch return null;
        return browser.Color{ .r = r, .g = g, .b = b, .a = a };
    }
    // Handle hex colors like #rrggbb (opaque)
    else if (color_str.len == 7 and color_str[0] == '#') {
        const r = std.fmt.parseInt(u8, color_str[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, color_str[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, color_str[5..7], 16) catch return null;
        return browser.Color{ .r = r, .g = g, .b = b, .a = 255 };
    }

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
    } else if (std.mem.eql(u8, color_str, "orangered")) {
        return browser.Color{ .r = 255, .g = 69, .b = 0, .a = 255 };
    }
    return null;
}

fn addBackgroundIfNeeded(self: *Layout, block: *const BlockLayout) !void {
    // Skip painting if shouldPaint returns false
    if (!block.shouldPaint()) return;

    switch (block.node) {
        .element => |e| {
            if (block.height <= 0) return;

            // Check for background-color in the style attribute
            const bgcolor_str = if (e.style) |*style_field|
                style_field.get().get("background-color")
            else
                null;

            // Check for border-radius
            const border_radius_str = if (e.style) |*style_field|
                style_field.get().get("border-radius")
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
                const remapped = self.remapColor(col);
                // Parse border-radius if present
                var radius: f64 = 0.0;
                if (border_radius_str) |br_str| {
                    if (std.mem.endsWith(u8, br_str, "px")) {
                        const radius_str = br_str[0 .. br_str.len - 2];
                        radius = std.fmt.parseFloat(f64, radius_str) catch 0.0;
                    }
                }

                const block_width = block.width;
                const block_x = block.x;
                const block_y = block.y;
                const block_height = block.height;
                if (radius > 0.0) {
                    // Use rounded rectangle
                    const rounded_rect = DisplayItem{ .rounded_rect = .{
                        .x1 = block_x,
                        .y1 = block_y,
                        .x2 = block_x + block_width,
                        .y2 = block_y + block_height,
                        .radius = radius,
                        .color = remapped,
                    } };
                    try self.display_list.append(self.allocator, rounded_rect);
                } else {
                    // Use regular rectangle
                    const rect = DisplayItem{ .rect = .{
                        .x1 = block_x,
                        .y1 = block_y,
                        .x2 = block_x + block_width,
                        .y2 = block_y + block_height,
                        .color = remapped,
                    } };
                    try self.display_list.append(self.allocator, rect);
                }
            }
        },
        else => {},
    }
}

pub fn buildDocument(self: *Layout, root: *Node) !*DocumentLayout {
    self.color_scheme_dark = self.resolveColorScheme("light dark");
    self.document_color_scheme_dark = self.color_scheme_dark;
    const document = try DocumentLayout.init(self.allocator, root);
    try document.layout(self);
    return document;
}

pub fn paintDocument(self: *Layout, document: *DocumentLayout) ![]DisplayItem {
    self.display_list.clearRetainingCapacity();

    if (self.document_color_scheme_dark) {
        const height = document.height + v_offset;
        const width = self.layoutWindowWidth();
        const bg_color = if (self.accessibility.dark_palette) |palette|
            palette.background
        else
            browser.Color{ .r = 18, .g = 18, .b = 18, .a = 255 };
        const bg = DisplayItem{ .rect = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = width,
            .y2 = height,
            .color = bg_color,
        } };
        try self.display_list.append(self.allocator, bg);
    }

    for (document.children.items) |child| {
        try paintBlockTree(self, child);
    }

    self.content_height = document.height + v_offset;
    return try self.display_list.toOwnedSlice(self.allocator);
}

// Paint a block and its subtree, applying stacking context effects
fn paintBlockTree(self: *Layout, block: *BlockLayout) !void {
    // Only paint if the block should be painted
    if (!block.shouldPaint()) return;

    // Collect all display commands for this block and its subtree
    var commands = std.ArrayList(DisplayItem).empty;
    defer commands.deinit(self.allocator);

    // Add the block's own background/borders
    try addBackgroundIfNeeded(self, block);

    // Add the block's display items (from children like text, etc.)
    for (block.display_list.items) |item| {
        try commands.append(self.allocator, item);
    }

    // Recursively paint children
    for (block.children.items) |child| {
        switch (child) {
            .block => |b| try paintBlockTreeRecursive(&commands, self, b),
            .line => |l| try l.paintToList(&commands, self),
        }
    }

    try appendContentEditableCursor(self, &commands, block);

    // Apply visual effects (opacity, etc.) to wrap the entire subtree
    const final_commands = try applyPaintEffects(self, block, commands.items);

    // Add the final commands to the display list
    for (final_commands) |cmd| {
        try self.display_list.append(self.allocator, cmd);
    }
    if (final_commands.len > 0) {
        self.allocator.free(final_commands);
    }
}

// Recursively paint a block's subtree into a command list, applying effects for each block
fn paintBlockTreeRecursive(commands: *std.ArrayList(DisplayItem), self: *Layout, block: *BlockLayout) !void {
    if (!block.shouldPaint()) return;

    // Collect this block's own commands
    var block_commands = std.ArrayList(DisplayItem).empty;
    defer block_commands.deinit(self.allocator);

    // Add background/borders for this block
    try addBackgroundIfNeededToList(self, &block_commands, block);

    // Add display items (from text, etc.)
    for (block.display_list.items) |item| {
        try block_commands.append(self.allocator, item);
    }

    // Recursively paint children - collect their commands
    for (block.children.items) |child| {
        switch (child) {
            .block => |b| try paintBlockTreeRecursive(&block_commands, self, b),
            .line => |l| try l.paintToList(&block_commands, self),
        }
    }

    try appendContentEditableCursor(self, &block_commands, block);

    // Apply visual effects (opacity, transform, etc.) for this block
    const final_commands = try applyPaintEffects(self, block, block_commands.items);

    // Add the wrapped commands to the parent's list
    for (final_commands) |cmd| {
        try commands.append(self.allocator, cmd);
    }
    if (final_commands.len > 0) {
        self.allocator.free(final_commands);
    }
}

// Apply visual effects like opacity, blend modes, and clipping to a list of display commands
fn applyPaintEffects(self: *Layout, block: *BlockLayout, commands: []DisplayItem) ![]DisplayItem {
    // Check for opacity, blend mode, and overflow clipping
    var opacity: f64 = 1.0;
    var blend_mode: ?[]const u8 = null;
    var should_clip = false;
    var border_radius: f64 = 0.0;
    var transform_x: i32 = 0;
    var transform_y: i32 = 0;
    var has_transform = false;

    if (block.node == .element) {
        const elem = block.node.element;
        if (elem.style) |*style_field| {
            const style = style_field.get();
            // Check for active opacity animation first
            if (elem.animations) |animations| {
                if (animations.get("opacity")) |anim| {
                    opacity = anim.getValue();
                    opacity = @max(0.0, @min(1.0, opacity)); // Clamp to valid range
                }
            }
            // Fall back to style value if no animation
            if (opacity == 1.0) {
                if (style.get("opacity")) |op_str| {
                    opacity = std.fmt.parseFloat(f64, op_str) catch 1.0;
                    opacity = @max(0.0, @min(1.0, opacity)); // Clamp to valid range
                }
            }
            if (style.get("mix-blend-mode")) |blend_str| {
                blend_mode = blend_str;
            }
            if (std.mem.eql(u8, style.get("overflow") orelse "visible", "clip")) {
                should_clip = true;
                if (style.get("border-radius")) |radius_str| {
                    // Parse border-radius (e.g., "30px" -> 30.0)
                    if (std.mem.endsWith(u8, radius_str, "px")) {
                        const radius_value = radius_str[0 .. radius_str.len - 2];
                        border_radius = std.fmt.parseFloat(f64, radius_value) catch 0.0;
                    }
                }
            }
            // Parse transform: translate(xpx, ypx)
            if (style.get("transform")) |transform_str| {
                if (parseTranslate(transform_str)) |translate| {
                    transform_x = translate.x;
                    transform_y = translate.y;
                    has_transform = true;
                }
            }
        }
    }

    // Start with the original commands
    var current_commands = commands;
    var owned_commands: ?[]DisplayItem = null;
    defer if (owned_commands) |owned| self.allocator.free(owned);

    // Apply clipping first if needed
    if (should_clip and border_radius > 0) {
        // Create a clipping mask using dst_in blend mode.
        // The mask is a white rounded rectangle that will clip the content.
        // Create the clipping blend that applies dst_in to mask the content
        const clip_blend_mode = try self.allocator.alloc(u8, 6);
        @memcpy(clip_blend_mode, "dst_in");

        const block_width = block.width;
        const block_x = block.x;
        const block_y = block.y;
        const block_height = block.height;
        const clip_mask_commands = try self.allocator.alloc(DisplayItem, 1);
        clip_mask_commands[0] = DisplayItem{
            .rounded_rect = .{
                .x1 = block_x,
                .y1 = block_y,
                .x2 = block_x + block_width,
                .y2 = block_y + block_height,
                .radius = border_radius,
                .color = browser.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
            },
        };

        const clip_blend = DisplayItem{
            .blend = .{
                .opacity = 1.0, // No opacity for clipping blend
                .blend_mode = clip_blend_mode,
                .children = clip_mask_commands,
                .needs_compositing = true, // Has blend mode, needs compositing
            },
        };

        // Append the clipping blend to the commands
        const new_commands = try self.allocator.alloc(DisplayItem, current_commands.len + 1);
        @memcpy(new_commands[0..current_commands.len], current_commands);
        new_commands[current_commands.len] = clip_blend;
        current_commands = new_commands;
        owned_commands = new_commands;
    }

    // Create a single merged blend operation for opacity and blend mode
    var final_blend_mode: ?[]const u8 = null;
    if (blend_mode) |mode| {
        // Copy the blend mode string since it needs to be owned by the DisplayItem
        final_blend_mode = try self.allocator.alloc(u8, mode.len);
        @memcpy(@constCast(final_blend_mode.?), mode);
    }

    // Only create a blend operation if we have effects to apply
    if (opacity < 1.0 or final_blend_mode != null) {
        const wrapped_commands = try self.allocator.alloc(DisplayItem, current_commands.len);
        @memcpy(wrapped_commands, current_commands);

        // Get pointer to the element for identifying this blend across frames
        const node_ptr: ?*anyopaque = if (block.node == .element)
            @ptrCast(&block.node.element)
        else
            null;

        // Determine if this blend needs compositing (does actual work)
        const needs_compositing = opacity < 1.0 or final_blend_mode != null;

        const blend_item = DisplayItem{
            .blend = .{
                .opacity = opacity,
                .blend_mode = final_blend_mode,
                .children = wrapped_commands,
                .node = node_ptr,
                .needs_compositing = needs_compositing,
            },
        };

        const result = try self.allocator.alloc(DisplayItem, 1);
        result[0] = blend_item;

        // Wrap in transform if needed
        if (has_transform) {
            const transform_item = DisplayItem{
                .transform = .{
                    .translate_x = transform_x,
                    .translate_y = transform_y,
                    .children = result,
                    .node = node_ptr,
                },
            };
            const transform_result = try self.allocator.alloc(DisplayItem, 1);
            transform_result[0] = transform_item;
            return transform_result;
        }
        return result;
    } else {
        // No blend effects, but may still have transform
        if (has_transform) {
            const wrapped_for_transform = try self.allocator.alloc(DisplayItem, current_commands.len);
            @memcpy(wrapped_for_transform, current_commands);

            const node_ptr: ?*anyopaque = if (block.node == .element)
                @ptrCast(&block.node.element)
            else
                null;

            const transform_item = DisplayItem{
                .transform = .{
                    .translate_x = transform_x,
                    .translate_y = transform_y,
                    .children = wrapped_for_transform,
                    .node = node_ptr,
                },
            };
            const result = try self.allocator.alloc(DisplayItem, 1);
            result[0] = transform_item;
            return result;
        }

        // No effects, return commands as-is
        const result = try self.allocator.alloc(DisplayItem, current_commands.len);
        @memcpy(result, current_commands);
        return result;
    }
}

// Add background/borders to a specific command list instead of the global display list
fn addBackgroundIfNeededToList(self: *Layout, commands: *std.ArrayList(DisplayItem), block: *const BlockLayout) !void {
    // Skip painting if shouldPaint returns false
    if (!block.shouldPaint()) return;

    switch (block.node) {
        .element => |e| {
            if (block.height <= 0) return;

            // Check for background-color in the style attribute
            const bgcolor_str = if (e.style) |*style_field|
                style_field.get().get("background-color")
            else
                null;

            // Check for border-radius
            const border_radius_str = if (e.style) |*style_field|
                style_field.get().get("border-radius")
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
                const remapped = self.remapColor(col);
                // Parse border-radius if present
                var radius: f64 = 0.0;
                if (border_radius_str) |br_str| {
                    if (std.mem.endsWith(u8, br_str, "px")) {
                        const radius_str = br_str[0 .. br_str.len - 2];
                        radius = std.fmt.parseFloat(f64, radius_str) catch 0.0;
                    }
                }

                const block_width = block.width;
                const block_x = block.x;
                const block_y = block.y;
                const block_height = block.height;
                if (radius > 0.0) {
                    // Use rounded rectangle
                    const rounded_rect = DisplayItem{ .rounded_rect = .{
                        .x1 = block_x,
                        .y1 = block_y,
                        .x2 = block_x + block_width,
                        .y2 = block_y + block_height,
                        .radius = radius,
                        .color = remapped,
                    } };
                    try commands.append(self.allocator, rounded_rect);
                } else {
                    // Use regular rectangle
                    const rect = DisplayItem{ .rect = .{
                        .x1 = block_x,
                        .y1 = block_y,
                        .x2 = block_x + block_width,
                        .y2 = block_y + block_height,
                        .color = remapped,
                    } };
                    try commands.append(self.allocator, rect);
                }
            }
        },
        else => {},
    }
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

    const children = block.children.get();
    for (children.items) |child| {
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
