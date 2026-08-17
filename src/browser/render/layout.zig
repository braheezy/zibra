//! Builds layout trees and paint commands from Zibra's styled DOM nodes.
//!
//! This module owns block and inline layout, text and replaced-element
//! measurement, hit-test bounds, incremental invalidation, and generation of
//! the display items consumed by the browser compositor.

const std = @import("std");
const font = @import("font.zig");
const browser = @import("../root.zig");
const grapheme = @import("grapheme");
const parser = @import("../../document/parser.zig");
const ProtectedField = @import("../../core/protected_field.zig").ProtectedField;
const DisplayItem = browser.DisplayItem;
const Node = parser.Node;
const FontWeight = font.FontWeight;
const FontSlant = font.FontSlant;
const FontCategory = font.FontCategory;
const FontFamily = font.FontFamily;
const scrollbar_width = browser.scrollbar_width;
const h_offset = browser.h_offset;
const v_offset = browser.v_offset;
const list_item_indent = 24;
const list_marker_size = 6;
const list_marker_top_offset = 7;
const toc_header_height = 24;

const ContentBounds = struct {
    x: i32,
    width: i32,
};

fn addPageBottomPadding(content_bottom_css: i32) i32 {
    const padded = @as(i64, @max(content_bottom_css, 0)) + v_offset;
    return @intCast(@min(padded, std.math.maxInt(i32)));
}

/// Return the full scrollable height, including top and bottom page padding.
pub fn documentScrollHeight(document_height_css: i32) i32 {
    return addPageBottomPadding(addPageBottomPadding(document_height_css));
}

fn isBlockDisplay(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "block");
}

/// Return whether a node participates as a block child. When supplied, the
/// parent's tree-version field is invalidated by later display-style changes.
fn isContainerNode(node: Node, dependency_target: ?*ProtectedField(u64)) bool {
    return switch (node) {
        .element => |element| blk: {
            const style_map = if (element.style) |*styles| styles else break :blk false;
            const field = @constCast(style_map).getPtr("display") orelse break :blk false;
            const value = if (dependency_target) |target| value: {
                target.addDependency(field);
                break :value field.read(target).*;
            } else field.get().*;
            break :blk isBlockDisplay(value);
        },
        .text => false,
    };
}

fn isRunInHeadingNode(node: Node) bool {
    return switch (node) {
        .element => |element| std.ascii.eqlIgnoreCase(element.tag, "h6"),
        .text => false,
    };
}

fn isListItemElement(element: *const parser.Element) bool {
    return std.ascii.eqlIgnoreCase(element.tag, "li");
}

fn isTableOfContentsElement(element: *const parser.Element) bool {
    if (!std.ascii.eqlIgnoreCase(element.tag, "nav")) return false;
    const attributes = element.attributes orelse return false;
    return std.mem.eql(u8, attributes.get("id") orelse return false, "toc");
}

fn tableOfContentsHeaderHeight(node: Node) i32 {
    return switch (node) {
        .element => |element| if (isTableOfContentsElement(&element)) toc_header_height else 0,
        .text => 0,
    };
}

fn listItemContentBounds(parent_x: i32, parent_width: i32) ContentBounds {
    return .{
        .x = parent_x + list_item_indent,
        .width = @max(parent_width - list_item_indent, 0),
    };
}

fn contentBoundsForNode(node: Node, parent_x: i32, parent_width: i32) ContentBounds {
    switch (node) {
        .element => |element| {
            if (isListItemElement(&element)) return listItemContentBounds(parent_x, parent_width);
        },
        .text => {},
    }
    return .{ .x = parent_x, .width = parent_width };
}

/// Parse the subset of CSS lengths supported by block dimensions. `auto`,
/// unsupported units, negative lengths, and invalid values use auto layout.
fn parseCssPixelLength(value: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return null;
    if (trimmed.len < 2 or !std.ascii.eqlIgnoreCase(trimmed[trimmed.len - 2 ..], "px")) return null;

    const number = std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t\r\n");
    if (number.len == 0) return null;
    const pixels = std.fmt.parseFloat(f64, number) catch return null;
    const max_i32_float: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(pixels) or pixels < 0 or pixels > max_i32_float) return null;
    return @intFromFloat(pixels);
}

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
    allocator: std.mem.Allocator,
    deps_initialized: bool = false,
    zoom: ProtectedField(f32),
    font_stub: ProtectedField(i32),
    width: ProtectedField(i32),
    height: ProtectedField(i32),
    ascent: ProtectedField(i32),
    descent: ProtectedField(i32),

    fn init(allocator: std.mem.Allocator) EmbedLayout {
        return .{
            .allocator = allocator,
            .deps_initialized = false,
            .zoom = ProtectedField(f32).init(allocator, 1.0),
            .font_stub = ProtectedField(i32).init(allocator, 0),
            .width = ProtectedField(i32).init(allocator, 0),
            .height = ProtectedField(i32).init(allocator, 0),
            .ascent = ProtectedField(i32).init(allocator, 0),
            .descent = ProtectedField(i32).init(allocator, 0),
        };
    }

    fn deinit(self: *EmbedLayout) void {
        self.zoom.deinit();
        self.font_stub.deinit();
        self.width.deinit();
        self.height.deinit();
        self.ascent.deinit();
        self.descent.deinit();
    }

    fn setupDependencies(self: *EmbedLayout, parent_block: ?*BlockLayout, style_map: ?*const parser.StyleMap) void {
        if (self.deps_initialized) return;
        self.deps_initialized = true;

        if (parent_block) |parent| {
            self.zoom.addDependency(&parent.zoom);
        }
        self.zoom.freezeDependencies();

        self.font_stub.addDependency(&self.zoom);
        if (style_map) |map| {
            const map_mut = @constCast(map);
            if (map_mut.getPtr("font-weight")) |field| self.font_stub.addDependency(field);
            if (map_mut.getPtr("font-style")) |field| self.font_stub.addDependency(field);
            if (map_mut.getPtr("font-size")) |field| self.font_stub.addDependency(field);
            if (map_mut.getPtr("font-family")) |field| self.font_stub.addDependency(field);
        }
        self.font_stub.freezeDependencies();

        self.width.addDependency(&self.zoom);
        self.width.freezeDependencies();

        self.height.addDependency(&self.zoom);
        self.height.addDependency(&self.font_stub);
        self.height.addDependency(&self.width);
        self.height.freezeDependencies();

        self.ascent.addDependency(&self.height);
        self.ascent.freezeDependencies();

        self.descent.freezeDependencies();
    }

    fn setMetrics(self: *EmbedLayout, width_value: i32, height_value: i32, ascent_value: i32, descent_value: i32, zoom_value: f32, font_value: i32) void {
        self.zoom.set(zoom_value);
        self.font_stub.set(font_value);
        self.width.set(width_value);
        self.height.set(height_value);
        self.ascent.set(ascent_value);
        self.descent.set(descent_value);
    }

    fn appendInline(
        self: *const EmbedLayout,
        engine: *Layout,
        line_buffer: *std.ArrayList(LineItem),
        node_ptr: ?*Node,
        payload: LineItemPayload,
    ) !void {
        const width_value = self.width.get().*;
        const height_value = self.height.get().*;
        if (width_value <= 0 or height_value <= 0) return;

        if (engine.cursor_x + width_value > engine.line_right) {
            try engine.flushLine(line_buffer);
            engine.cursor_x = engine.line_left;
        }

        try line_buffer.append(engine.allocator, LineItem{
            .x = engine.cursor_x,
            .hit_offset_x = engine.transform_offset_x,
            .hit_offset_y = engine.transform_offset_y,
            .ascent = self.ascent.get().*,
            .descent = self.descent.get().*,
            .width = width_value,
            .height = height_value,
            .node_ptr = node_ptr,
            .payload = payload,
        });
        engine.cursor_x += width_value;
    }
};

const ImageLayout = struct {
    embed: EmbedLayout,
    pixels: []const u8,
    source_width: i32,
    source_height: i32,
    opacity: f64 = 1.0,

    fn init(
        allocator: std.mem.Allocator,
        layout_width: i32,
        layout_height: i32,
        image_data: ?parser.ImageData,
        parent_block: ?*BlockLayout,
        style_map: ?*const parser.StyleMap,
        zoom_value: f32,
    ) ImageLayout {
        const empty_pixels = &[_]u8{};
        const src_width: i32 = if (image_data) |data| @intCast(data.image.width) else 0;
        const src_height: i32 = if (image_data) |data| @intCast(data.image.height) else 0;
        var layout = ImageLayout{
            .embed = EmbedLayout.init(allocator),
            .pixels = if (image_data) |data| data.image.rawBytes() else empty_pixels,
            .source_width = src_width,
            .source_height = src_height,
            .opacity = 1.0,
        };
        layout.embed.setupDependencies(parent_block, style_map);
        layout.embed.setMetrics(layout_width, layout_height, layout_height, 0, zoom_value, 0);
        return layout;
    }

    fn deinit(self: *ImageLayout) void {
        self.embed.deinit();
    }
};

const IframeLayout = struct {
    embed: EmbedLayout,
    bgcolor: browser.Color,
    border_color: browser.Color,
    border_thickness: i32 = 1,

    fn init(
        allocator: std.mem.Allocator,
        layout_width: i32,
        layout_height: i32,
        parent_block: ?*BlockLayout,
        style_map: ?*const parser.StyleMap,
        zoom_value: f32,
    ) IframeLayout {
        var layout = IframeLayout{
            .embed = EmbedLayout.init(allocator),
            .bgcolor = .{ .r = 0xf2, .g = 0xf2, .b = 0xf2, .a = 0xff },
            .border_color = .{ .r = 0x33, .g = 0x33, .b = 0x33, .a = 0xff },
            .border_thickness = 1,
        };
        layout.embed.setupDependencies(parent_block, style_map);
        layout.embed.setMetrics(layout_width, layout_height, layout_height, 0, zoom_value, 0);
        return layout;
    }

    fn deinit(self: *IframeLayout) void {
        self.embed.deinit();
    }

    fn paintAt(
        self: *const IframeLayout,
        commands: *std.ArrayList(DisplayItem),
        engine: *Layout,
        x: i32,
        y: i32,
    ) !void {
        const width_value = self.embed.width.get().*;
        const height_value = self.embed.height.get().*;
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

    fn deinit(self: *LineItemPayload) void {
        switch (self.*) {
            .glyph => {},
            .input => |*input_payload| input_payload.deinit(),
            .image => |*image_payload| image_payload.deinit(),
            .iframe => |*iframe_payload| iframe_payload.deinit(),
        }
    }
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

const SoftHyphenBreak = struct {
    item_index: usize,
    break_x: i32,
    hyphen_item: LineItem,
};

const GraphemeOptions = struct {
    force_newline: bool = false,
    is_superscript: bool = false,
    is_small_caps: bool = false,
};

// Add this struct to cache word measurements
const WordCache = struct {
    width: i32,
    graphemes: []const []const u8,
};

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

pub const FragmentTarget = struct {
    node: *Node,
    y: i32,
};

pub const Layout = @This();

const TextDirection = enum {
    left_to_right,
    right_to_left,
};

const LineAlignment = enum {
    start,
    center,
    end,
};

fn textDirectionFromFlag(rtl_text: bool) TextDirection {
    return if (rtl_text) .right_to_left else .left_to_right;
}

fn lineAlignmentShift(
    alignment: LineAlignment,
    line_left: i32,
    line_right: i32,
    content_left: i32,
    content_right: i32,
) i32 {
    const content_width = @max(content_right - content_left, 0);
    const target_left = switch (alignment) {
        .start => line_left,
        .center => line_left + @divTrunc((line_right - line_left) - content_width, 2),
        .end => line_right - content_width,
    };
    return target_left - content_left;
}

fn explicitTextDirection(element: *const parser.Element) ?TextDirection {
    const attributes = element.attributes orelse return null;
    const raw_direction = attributes.get("dir") orelse return null;
    const direction = std.mem.trim(u8, raw_direction, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(direction, "rtl")) return .right_to_left;
    if (std.ascii.eqlIgnoreCase(direction, "ltr")) return .left_to_right;
    return null;
}

fn elementHasClass(element: *const parser.Element, expected: []const u8) bool {
    const attributes = element.attributes orelse return false;
    const class_value = attributes.get("class") orelse return false;
    var classes = std.mem.tokenizeAny(u8, class_value, " \t\r\n\x0c");
    while (classes.next()) |class_name| {
        if (std.mem.eql(u8, class_name, expected)) return true;
    }
    return false;
}

fn isCenteredTitleElement(element: *const parser.Element) bool {
    return std.ascii.eqlIgnoreCase(element.tag, "h1") and
        elementHasClass(element, "title");
}

fn isCenteredTitleBlock(block: *const BlockLayout) bool {
    var current: ?*const BlockLayout = block;
    while (current) |candidate| : (current = candidate.parent_block) {
        switch (candidate.node) {
            .element => |*element| {
                if (isCenteredTitleElement(element)) return true;
            },
            .text => {},
        }
    }
    return false;
}

fn isSuperscriptElement(element: *const parser.Element) bool {
    return std.ascii.eqlIgnoreCase(element.tag, "sup");
}

fn isWithinSuperscriptBlock(block: *const BlockLayout) bool {
    var current: ?*const BlockLayout = block;
    while (current) |candidate| : (current = candidate.parent_block) {
        switch (candidate.node) {
            .element => |*element| {
                if (isSuperscriptElement(element)) return true;
            },
            .text => {},
        }
    }
    return false;
}

fn isSmallCapsElement(element: *const parser.Element) bool {
    return std.ascii.eqlIgnoreCase(element.tag, "abbr");
}

fn isWithinSmallCapsBlock(block: *const BlockLayout) bool {
    var current: ?*const BlockLayout = block;
    while (current) |candidate| : (current = candidate.parent_block) {
        switch (candidate.node) {
            .element => |*element| {
                if (isSmallCapsElement(element)) return true;
            },
            .text => {},
        }
    }
    return false;
}

fn isPreformattedElement(element: *const parser.Element) bool {
    return std.ascii.eqlIgnoreCase(element.tag, "pre");
}

fn isWithinPreformattedBlock(block: *const BlockLayout) bool {
    var current: ?*const BlockLayout = block;
    while (current) |candidate| : (current = candidate.parent_block) {
        switch (candidate.node) {
            .element => |*element| {
                if (isPreformattedElement(element)) return true;
            },
            .text => {},
        }
    }
    return false;
}

fn textSizeForSuperscript(size: i32, is_superscript: bool) i32 {
    if (!is_superscript) return size;
    return @max(@divTrunc(size, 2), 1);
}

fn isSmallCapsLowercaseGrapheme(grapheme_bytes: []const u8) bool {
    return grapheme_bytes.len > 0 and std.ascii.isLower(grapheme_bytes[0]);
}

fn textSizeForSmallCaps(size: i32) i32 {
    return @max(@divTrunc(size * 4, 5), 1);
}

fn shouldAutomaticallyWrap(
    is_preformatted: bool,
    cursor_x: i32,
    glyph_width: i32,
    line_right: i32,
    line_has_content: bool,
) bool {
    return !is_preformatted and
        line_has_content and
        cursor_x + glyph_width > line_right;
}

/// Resolve the nearest inherited HTML `dir` value through the acyclic layout
/// tree. `auto` and invalid values inherit because Zibra does not yet
/// implement Unicode bidi detection.
fn textDirectionForBlock(block: *const BlockLayout, fallback: TextDirection) TextDirection {
    var current: ?*const BlockLayout = block;
    while (current) |candidate| : (current = candidate.parent_block) {
        switch (candidate.node) {
            .element => |*element| {
                if (explicitTextDirection(element)) |direction| return direction;
            },
            .text => {},
        }
    }
    return fallback;
}

test "line alignment preserves source order and selects the requested edge" {
    try std.testing.expectEqual(
        @as(i32, 0),
        lineAlignmentShift(.start, 13, 777, 13, 76),
    );
    try std.testing.expectEqual(
        @as(i32, 701),
        lineAlignmentShift(.end, 13, 777, 13, 76),
    );
    try std.testing.expectEqual(
        @as(i32, 350),
        lineAlignmentShift(.center, 13, 777, 13, 76),
    );
}

test "HTML dir values override or inherit the CLI fallback" {
    const allocator = std.testing.allocator;

    var body = Node{ .element = try parser.Element.init(allocator, "body dir=rtl", null) };
    defer body.deinit(allocator);
    try std.testing.expectEqual(
        TextDirection.right_to_left,
        explicitTextDirection(&body.element).?,
    );

    var overridden = Node{ .element = try parser.Element.init(allocator, "p dir='LTR'", null) };
    defer overridden.deinit(allocator);
    try std.testing.expectEqual(
        TextDirection.left_to_right,
        explicitTextDirection(&overridden.element).?,
    );

    var automatic = Node{ .element = try parser.Element.init(allocator, "p dir=auto", null) };
    defer automatic.deinit(allocator);
    try std.testing.expectEqual(@as(?TextDirection, null), explicitTextDirection(&automatic.element));

    try std.testing.expectEqual(TextDirection.left_to_right, textDirectionFromFlag(false));
    try std.testing.expectEqual(TextDirection.right_to_left, textDirectionFromFlag(true));
}

test "centered title recognizes title as an HTML class token" {
    const allocator = std.testing.allocator;

    var title = Node{ .element = try parser.Element.init(
        allocator,
        "h1 class='chapter title featured'",
        null,
    ) };
    defer title.deinit(allocator);
    try std.testing.expect(isCenteredTitleElement(&title.element));

    var partial_match = Node{ .element = try parser.Element.init(
        allocator,
        "h1 class=subtitle",
        null,
    ) };
    defer partial_match.deinit(allocator);
    try std.testing.expect(!isCenteredTitleElement(&partial_match.element));

    var wrong_element = Node{ .element = try parser.Element.init(
        allocator,
        "h2 class=title",
        null,
    ) };
    defer wrong_element.deinit(allocator);
    try std.testing.expect(!isCenteredTitleElement(&wrong_element.element));
}

test "superscript elements use a bounded half-size font" {
    const allocator = std.testing.allocator;

    var superscript = Node{ .element = try parser.Element.init(allocator, "SUP", null) };
    defer superscript.deinit(allocator);
    try std.testing.expect(isSuperscriptElement(&superscript.element));

    var subscript = Node{ .element = try parser.Element.init(allocator, "sub", null) };
    defer subscript.deinit(allocator);
    try std.testing.expect(!isSuperscriptElement(&subscript.element));

    try std.testing.expectEqual(@as(i32, 8), textSizeForSuperscript(16, true));
    try std.testing.expectEqual(@as(i32, 1), textSizeForSuperscript(1, true));
    try std.testing.expectEqual(@as(i32, 16), textSizeForSuperscript(16, false));
}

test "abbr elements render lowercase ASCII as bounded small caps" {
    const allocator = std.testing.allocator;

    var abbreviation = Node{ .element = try parser.Element.init(allocator, "ABBR", null) };
    defer abbreviation.deinit(allocator);
    try std.testing.expect(isSmallCapsElement(&abbreviation.element));

    var span = Node{ .element = try parser.Element.init(allocator, "span", null) };
    defer span.deinit(allocator);
    try std.testing.expect(!isSmallCapsElement(&span.element));

    try std.testing.expect(isSmallCapsLowercaseGrapheme("a"));
    try std.testing.expect(isSmallCapsLowercaseGrapheme("a\u{0301}"));
    try std.testing.expect(!isSmallCapsLowercaseGrapheme("A"));
    try std.testing.expect(!isSmallCapsLowercaseGrapheme("7"));
    try std.testing.expect(!isSmallCapsLowercaseGrapheme("😀"));

    try std.testing.expectEqual(@as(i32, 12), textSizeForSmallCaps(16));
    try std.testing.expectEqual(@as(i32, 1), textSizeForSmallCaps(1));
}

test "pre elements preserve text without automatic wrapping" {
    const allocator = std.testing.allocator;

    var pre = Node{ .element = try parser.Element.init(allocator, "PRE", null) };
    defer pre.deinit(allocator);
    try std.testing.expect(isPreformattedElement(&pre.element));

    var code = Node{ .element = try parser.Element.init(allocator, "code", null) };
    defer code.deinit(allocator);
    try std.testing.expect(!isPreformattedElement(&code.element));

    try std.testing.expect(!shouldAutomaticallyWrap(true, 95, 10, 100, true));
    try std.testing.expect(shouldAutomaticallyWrap(false, 95, 10, 100, true));
    try std.testing.expect(!shouldAutomaticallyWrap(false, 95, 10, 100, false));
}

fn setTestDisplay(allocator: std.mem.Allocator, node: *Node, value: []const u8) !void {
    std.debug.assert(node.* == .element);
    var styles = parser.StyleMap.init(allocator);
    errdefer styles.deinit();
    var field = ProtectedField([]const u8).init(allocator, "inline");
    field.set(value);
    styles.put("display", field) catch |err| {
        field.deinit();
        return err;
    };
    node.element.style = styles;
}

test "computed display classifies block children" {
    const allocator = std.testing.allocator;
    var legacy_div = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer legacy_div.deinit(allocator);
    try std.testing.expect(!isContainerNode(legacy_div, null));

    var promoted_span = Node{ .element = try parser.Element.init(allocator, "span", null) };
    defer promoted_span.deinit(allocator);
    try setTestDisplay(allocator, &promoted_span, " BLOCK ");
    try std.testing.expect(isContainerNode(promoted_span, null));

    var tree_version = ProtectedField(u64).init(allocator, 0);
    defer tree_version.deinit();
    tree_version.set(0);
    tree_version.freezeDependencies();
    try std.testing.expect(isContainerNode(promoted_span, &tree_version));
    const display_field = promoted_span.element.style.?.getPtr("display").?;
    display_field.mark();
    display_field.set("inline");
    try std.testing.expect(tree_version.dirty);

    try std.testing.expect(isBlockDisplay("block"));
    try std.testing.expect(!isBlockDisplay("inline"));
    try std.testing.expect(!isBlockDisplay("unsupported"));
}

test "list items reserve room for square markers" {
    const allocator = std.testing.allocator;
    var item = Node{ .element = try parser.Element.init(allocator, "LI", null) };
    defer item.deinit(allocator);
    try std.testing.expect(isListItemElement(&item.element));

    const bounds = listItemContentBounds(13, 100);
    try std.testing.expectEqual(@as(i32, 37), bounds.x);
    try std.testing.expectEqual(@as(i32, 76), bounds.width);
}

test "block dimensions accept non-negative pixel lengths" {
    try std.testing.expectEqual(@as(?i32, 240), parseCssPixelLength("240px"));
    try std.testing.expectEqual(@as(?i32, 12), parseCssPixelLength(" 12.75PX "));
    try std.testing.expectEqual(@as(?i32, 0), parseCssPixelLength("0px"));

    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("auto"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("AUTO"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("100%"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("-1px"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("NaNpx"));
    try std.testing.expectEqual(@as(?i32, null), parseCssPixelLength("999999999999px"));
}

test "table of contents navigation reserves a header row" {
    const allocator = std.testing.allocator;
    var toc = Node{ .element = try parser.Element.init(allocator, "nav id=toc", null) };
    defer toc.deinit(allocator);
    try std.testing.expect(isTableOfContentsElement(&toc.element));
    try std.testing.expectEqual(toc_header_height, tableOfContentsHeaderHeight(toc));

    var ordinary_nav = Node{ .element = try parser.Element.init(allocator, "nav id=links", null) };
    defer ordinary_nav.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 0), tableOfContentsHeaderHeight(ordinary_nav));
}

test "anonymous blocks group only consecutive inline siblings" {
    const allocator = std.testing.allocator;
    var inline_node = Node{ .element = try parser.Element.init(allocator, "i", null) };
    defer inline_node.deinit(allocator);
    var paragraph = Node{ .element = try parser.Element.init(allocator, "p", null) };
    defer paragraph.deinit(allocator);
    try setTestDisplay(allocator, &paragraph, "block");
    const text = Node{ .text = .{ .text = "text" } };

    try std.testing.expect(!isContainerNode(inline_node, null));
    try std.testing.expect(isContainerNode(paragraph, null));
    try std.testing.expect(!isContainerNode(text, null));
}

test "h6 headings run into a following block" {
    const allocator = std.testing.allocator;
    var heading = Node{ .element = try parser.Element.init(allocator, "h6", null) };
    defer heading.deinit(allocator);
    var paragraph = Node{ .element = try parser.Element.init(allocator, "p", null) };
    defer paragraph.deinit(allocator);
    try setTestDisplay(allocator, &paragraph, "block");

    try std.testing.expect(isRunInHeadingNode(heading));
    try std.testing.expect(isContainerNode(paragraph, null));
}

// Layout state
allocator: std.mem.Allocator,
// Font manager for handling fonts and glyphs
font_manager: font.FontManager,
window_width: i32,
window_height: i32,
default_direction: TextDirection = .left_to_right,
line_direction: TextDirection = .left_to_right,
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
font_family: FontFamily = .proportional,
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

// Discretionary break opportunities for the current visible word and line.
// Each candidate owns no resources: its hyphen glyph borrows FontManager data.
soft_hyphen_breaks: std.ArrayList(SoftHyphenBreak),
soft_hyphen_word_has_content: bool = false,

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
// Document-space top positions for elements carrying an HTML id.
fragment_targets: std.ArrayList(FragmentTarget),
// Inspection commands serialize geometry only; they do not need interactive
// hit-test state or DOM-parent walks.
collect_hit_test_bounds: bool = true,

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
    font_family: FontFamily,
    is_title: bool,
    is_superscript: bool,
    is_small_caps: bool,
    is_preformatted: bool,
    prev_font_category: ?FontCategory,
    current_font_category: FontCategory,
    text_color: browser.Color,
    line_direction: TextDirection,
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
        .font_family = self.font_family,
        .is_title = self.is_title,
        .is_superscript = self.is_superscript,
        .is_small_caps = self.is_small_caps,
        .is_preformatted = self.is_preformatted,
        .prev_font_category = self.prev_font_category,
        .current_font_category = self.current_font_category,
        .text_color = self.text_color,
        .line_direction = self.line_direction,
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
    self.font_family = snapshot.font_family;
    self.is_title = snapshot.is_title;
    self.is_superscript = snapshot.is_superscript;
    self.is_small_caps = snapshot.is_small_caps;
    self.is_preformatted = snapshot.is_preformatted;
    self.prev_font_category = snapshot.prev_font_category;
    self.current_font_category = snapshot.current_font_category;
    self.text_color = snapshot.text_color;
    self.line_direction = snapshot.line_direction;
}

fn zoom(self: *const Layout) f32 {
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

fn activeFontFamily(self: *const Layout) FontFamily {
    // Preformatted layout already promises a monospace face independently of
    // the user-agent stylesheet. Nested CSS family rules still work normally
    // outside that whitespace-preservation mode.
    return if (self.is_preformatted) .monospace else self.font_family;
}

fn layoutWindowWidth(self: *const Layout) i32 {
    return self.toLayoutPx(self.window_width);
}

fn layoutScrollbarWidth(self: *const Layout) i32 {
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
    io: std.Io,
    environ: *const std.process.Environ.Map,
    window_width: i32,
    window_height: i32,
    rtl_text: bool,
) !*Layout {
    var font_manager = try font.FontManager.init(allocator, io, environ);
    const layout = allocator.create(Layout) catch |err| {
        font_manager.deinit();
        return err;
    };

    const default_direction = textDirectionFromFlag(rtl_text);

    layout.* = Layout{
        .allocator = allocator,
        .font_manager = font_manager,
        .window_width = window_width,
        .window_height = window_height,
        .default_direction = default_direction,
        .line_direction = default_direction,
        .cursor_x = h_offset,
        .cursor_y = v_offset,
        .line_left = h_offset,
        .line_right = window_width - scrollbar_width - h_offset,
        .is_bold = false,
        .is_italic = false,
        .content_height = 0,
        .display_list = std.ArrayList(DisplayItem).empty,
        .current_display_target = undefined,
        .word_cache = std.AutoHashMap(u64, WordCache).init(allocator),
        .soft_hyphen_breaks = std.ArrayList(SoftHyphenBreak).empty,
        .input_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
        .link_bounds = std.ArrayList(LinkBoundEntry).empty,
        .iframe_bounds = std.ArrayList(IframeBoundEntry).empty,
        .focus_bounds = std.ArrayList(FocusBoundEntry).empty,
        .accessibility_bounds = std.ArrayList(AccessibilityBoundEntry).empty,
        .fragment_targets = std.ArrayList(FragmentTarget).empty,
        .style_stack = std.ArrayList(StyleSnapshot).empty,
    };
    errdefer layout.deinit();

    layout.current_display_target = &layout.display_list;

    try layout.font_manager.loadSystemFont(layout.scaledFontSize(layout.size));
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
    self.soft_hyphen_breaks.deinit(self.allocator);

    self.input_bounds.deinit();
    self.link_bounds.deinit(self.allocator);
    self.iframe_bounds.deinit(self.allocator);
    self.focus_bounds.deinit(self.allocator);
    self.accessibility_bounds.deinit(self.allocator);
    self.fragment_targets.deinit(self.allocator);

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
            // Empty inline anchors have no glyph from which to derive a
            // position, so retain their insertion point explicitly.
            if (self.collect_hit_test_bounds and e.children.items.len == 0) {
                if (node_ptr) |ptr| try self.recordFragmentTargets(ptr, self.cursor_y);
            }
            // Apply CSS styles before processing this element
            try self.applyNodeStyles(e, line_buffer);

            // DOM recursion replaces the old opening/closing-tag token stream.
            // Scope semantic text state to this subtree so nested styles retain
            // it and following siblings return to their previous state.
            const previous_superscript = self.is_superscript;
            if (isSuperscriptElement(&e)) self.is_superscript = true;
            defer self.is_superscript = previous_superscript;

            const previous_small_caps = self.is_small_caps;
            if (isSmallCapsElement(&e)) self.is_small_caps = true;
            defer self.is_small_caps = previous_small_caps;

            const previous_preformatted = self.is_preformatted;
            if (isPreformattedElement(&e)) self.is_preformatted = true;
            defer self.is_preformatted = previous_preformatted;

            // Handle br tag for line breaks
            if (std.mem.eql(u8, e.tag, "br")) {
                try self.breakExplicitLine(line_buffer);
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
    self.resetSoftHyphenWord();

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
    self.resetSoftHyphenWord();

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

    const style_map = if (node == .element) blk: {
        if (node.element.style) |*map| break :blk map;
        break :blk null;
    } else null;
    var image_layout = ImageLayout.init(self.allocator, layout_width, layout_height, image_data, self.inline_block, style_map, self.zoom());
    try image_layout.embed.appendInline(self, line_buffer, node_ptr, .{
        .image = image_layout,
    });
}

fn handleIframeElement(self: *Layout, node: Node, node_ptr: ?*Node, line_buffer: *std.ArrayList(LineItem)) !void {
    const element = switch (node) {
        .element => |e| e,
        else => return,
    };
    self.resetSoftHyphenWord();

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

    const style_map = if (node == .element) blk: {
        if (node.element.style) |*map| break :blk map;
        break :blk null;
    } else null;
    var iframe_layout = IframeLayout.init(self.allocator, layout_width, layout_height, self.inline_block, style_map, self.zoom());
    try iframe_layout.embed.appendInline(self, line_buffer, node_ptr, .{
        .iframe = iframe_layout,
    });
}

const StyleSnapshot = struct {
    is_bold: bool,
    is_italic: bool,
    font_family: FontFamily,
    size: i32,
    text_color: browser.Color,
    transform_offset_x: i32,
    transform_offset_y: i32,
    color_scheme_dark: bool,
};

fn styleValue(style_map: *const parser.StyleMap, property: []const u8) ?[]const u8 {
    if (@constCast(style_map).getPtr(property)) |field| {
        return field.get().*;
    }
    return null;
}

fn styleValueRead(style_map: *const parser.StyleMap, property: []const u8, notify: anytype) ?[]const u8 {
    if (@constCast(style_map).getPtr(property)) |field| {
        return field.read(notify).*;
    }
    return null;
}

fn applyNodeStyles(self: *Layout, element: parser.Element, _: *std.ArrayList(LineItem)) !void {
    // Save current style state including transform offsets
    const snapshot = StyleSnapshot{
        .is_bold = self.is_bold,
        .is_italic = self.is_italic,
        .font_family = self.font_family,
        .size = self.size,
        .text_color = self.text_color,
        .transform_offset_x = self.transform_offset_x,
        .transform_offset_y = self.transform_offset_y,
        .color_scheme_dark = self.color_scheme_dark,
    };
    try self.style_stack.append(self.allocator, snapshot);

    if (element.style) |*style_map| {
        const notify_target = if (self.inline_block) |blk| &blk.height else null;
        // Apply the inherited font family before measuring any descendant
        // glyphs. Unsupported named faces resolve through the CSS fallback
        // list to Zibra's proportional system face.
        const family_value = if (notify_target) |target|
            styleValueRead(style_map, "font-family", target)
        else
            styleValue(style_map, "font-family");
        if (family_value) |family_str| {
            self.font_family = font.familyFromCss(family_str);
        }

        // Apply font-weight
        if (notify_target) |target| {
            if (styleValueRead(style_map, "font-weight", target)) |weight_str| {
                self.is_bold = std.mem.eql(u8, weight_str, "bold");
            }
        } else if (styleValue(style_map, "font-weight")) |weight_str| {
            self.is_bold = std.mem.eql(u8, weight_str, "bold");
        }

        // Apply font-style
        if (notify_target) |target| {
            if (styleValueRead(style_map, "font-style", target)) |style_str| {
                self.is_italic = std.mem.eql(u8, style_str, "italic");
            }
        } else if (styleValue(style_map, "font-style")) |style_str| {
            self.is_italic = std.mem.eql(u8, style_str, "italic");
        }

        // Apply font-size
        const size_value = if (notify_target) |target|
            styleValueRead(style_map, "font-size", target)
        else
            styleValue(style_map, "font-size");
        if (size_value) |size_str| {
            if (std.mem.endsWith(u8, size_str, "px")) {
                const size_num_str = size_str[0 .. size_str.len - 2];
                if (std.fmt.parseFloat(f64, size_num_str)) |size_float| {
                    // Convert CSS pixels to our size (multiply by 0.75 for points)
                    self.size = @intFromFloat(size_float * 0.75);
                } else |_| {}
            }
        }

        // Apply color
        if (styleValue(style_map, "color")) |color_str| {
            if (parseColor(color_str)) |color| {
                self.text_color = color;
            }
        }

        // Apply transform to cumulative offset for hit testing
        if (styleValue(style_map, "transform")) |transform_str| {
            if (parseTranslate(transform_str)) |translate| {
                self.transform_offset_x += translate.x;
                self.transform_offset_y += translate.y;
            }
        }

        if (styleValue(style_map, "color-scheme")) |scheme| {
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
        self.font_family = snapshot.font_family;
        self.size = snapshot.size;
        self.text_color = snapshot.text_color;
        self.transform_offset_x = snapshot.transform_offset_x;
        self.transform_offset_y = snapshot.transform_offset_y;
        self.color_scheme_dark = snapshot.color_scheme_dark;
    }
}

fn isSoftHyphenGrapheme(gme: []const u8) bool {
    return std.mem.eql(u8, gme, "\u{00AD}");
}

fn isWordSeparatorGrapheme(gme: []const u8) bool {
    return gme.len == 1 and std.ascii.isWhitespace(gme[0]);
}

test "soft hyphen recognition is distinct from word separation" {
    try std.testing.expect(isSoftHyphenGrapheme("\u{00AD}"));
    try std.testing.expect(!isSoftHyphenGrapheme("-"));
    try std.testing.expect(isWordSeparatorGrapheme(" "));
    try std.testing.expect(isWordSeparatorGrapheme("\t"));
    try std.testing.expect(!isWordSeparatorGrapheme("a"));
}

fn resetSoftHyphenWord(self: *Layout) void {
    self.soft_hyphen_breaks.clearRetainingCapacity();
    self.soft_hyphen_word_has_content = false;
}

fn recordSoftHyphenBreak(
    self: *Layout,
    line_buffer: *const std.ArrayList(LineItem),
    node_ptr: ?*Node,
    options: GraphemeOptions,
) !void {
    // Soft hyphens at the start of a visual line have no prefix to break, and
    // preformatted text deliberately does not wrap.
    if (self.is_preformatted or !self.soft_hyphen_word_has_content) return;

    const weight: font.FontWeight = if (self.is_bold) .Bold else .Normal;
    const slant: font.FontSlant = if (self.is_italic) .Italic else .Roman;
    const text_size = textSizeForSuperscript(self.size, options.is_superscript);
    var hyphen = try self.font_manager.getStyledGlyph(
        "-",
        weight,
        slant,
        self.scaledFontSize(text_size),
        self.activeFontFamily(),
    );
    hyphen.is_superscript = options.is_superscript;
    hyphen.is_soft_hyphen = false;

    const hyphen_width = self.toLayoutPx(hyphen.w);
    if (hyphen_width <= 0) return;

    try self.soft_hyphen_breaks.append(self.allocator, .{
        .item_index = line_buffer.items.len,
        .break_x = self.cursor_x,
        .hyphen_item = .{
            .x = self.cursor_x,
            .hit_offset_x = self.transform_offset_x,
            .hit_offset_y = self.transform_offset_y,
            .ascent = self.toLayoutPx(hyphen.ascent),
            .descent = self.toLayoutPx(hyphen.descent),
            .width = hyphen_width,
            .height = self.toLayoutPx(hyphen.h),
            .node_ptr = node_ptr,
            .payload = .{ .glyph = .{
                .glyph = hyphen,
                .color = self.remapColor(self.text_color),
            } },
        },
    });
}

/// Break at the latest recorded soft hyphen whose visible hyphen fits. The
/// suffix is transferred out of the current line before flushing its prefix,
/// then rebased onto the next line without duplicating payload ownership.
fn trySoftHyphenBreak(self: *Layout, line_buffer: *std.ArrayList(LineItem)) !bool {
    var chosen_index = self.soft_hyphen_breaks.items.len;
    while (chosen_index > 0) {
        chosen_index -= 1;
        const candidate = self.soft_hyphen_breaks.items[chosen_index];
        if (candidate.item_index == 0 or candidate.item_index > line_buffer.items.len) continue;
        if (candidate.break_x + candidate.hyphen_item.width <= self.line_right) break;
    } else return false;

    const chosen = self.soft_hyphen_breaks.items[chosen_index];

    var suffix = std.ArrayList(LineItem).empty;
    defer {
        // Until ownership is transferred back to line_buffer, suffix is
        // responsible for embedded payload cleanup.
        for (suffix.items) |*item| item.payload.deinit();
        suffix.deinit(self.allocator);
    }
    try suffix.appendSlice(self.allocator, line_buffer.items[chosen.item_index..]);
    line_buffer.shrinkRetainingCapacity(chosen.item_index);

    var carried_breaks = std.ArrayList(SoftHyphenBreak).empty;
    defer carried_breaks.deinit(self.allocator);
    for (self.soft_hyphen_breaks.items[chosen_index + 1 ..]) |candidate| {
        // Consecutive markers at the chosen boundary would become an invalid
        // break at the start of the new visual line.
        if (candidate.item_index <= chosen.item_index) continue;
        var carried = candidate;
        carried.item_index -= chosen.item_index;
        carried.break_x = self.line_left + (candidate.break_x - chosen.break_x);
        carried.hyphen_item.x = carried.break_x;
        try carried_breaks.append(self.allocator, carried);
    }

    try line_buffer.append(self.allocator, chosen.hyphen_item);
    self.cursor_x = chosen.break_x + chosen.hyphen_item.width;
    try self.flushLine(line_buffer);

    for (suffix.items) |*item| {
        item.x = self.line_left + (item.x - chosen.break_x);
    }
    try line_buffer.appendSlice(self.allocator, suffix.items);
    suffix.clearRetainingCapacity(); // Ownership transferred to line_buffer.

    try self.soft_hyphen_breaks.appendSlice(self.allocator, carried_breaks.items);
    self.soft_hyphen_word_has_content = line_buffer.items.len > 0;
    self.cursor_x = if (line_buffer.items.len > 0) blk: {
        const last = line_buffer.items[line_buffer.items.len - 1];
        break :blk last.x + last.width;
    } else self.line_left;
    return true;
}

fn flushLine(self: *Layout, line_buffer: *std.ArrayList(LineItem)) !void {
    // Nothing to flush? Return.
    if (line_buffer.items.len == 0) {
        self.resetSoftHyphenWord();
        return;
    }
    defer self.resetSoftHyphenWord();

    // Build every line in logical source order from the left, then align the
    // completed run. This preserves English LTR glyph order under `dir=rtl`
    // while making the line grow inward from the right edge.
    var content_left: i32 = line_buffer.items[0].x;
    var content_right: i32 = line_buffer.items[0].x + line_buffer.items[0].width;
    for (line_buffer.items[1..]) |item| {
        content_left = @min(content_left, item.x);
        content_right = @max(content_right, item.x + item.width);
    }
    const alignment: LineAlignment = if (self.is_title)
        .center
    else if (self.line_direction == .right_to_left)
        .end
    else
        .start;
    const shift = lineAlignmentShift(
        alignment,
        self.line_left,
        self.line_right,
        content_left,
        content_right,
    );
    if (shift != 0) {
        for (line_buffer.items) |*item| item.x += shift;
    }

    // === PASS 1: Collect line metrics ===
    var has_normal_item = false;
    var max_normal_ascent: i32 = 0;
    var max_normal_descent: i32 = 0;
    var max_superscript_ascent: i32 = 0;
    var max_superscript_descent: i32 = 0;

    for (line_buffer.items) |item| {
        const is_superscript = switch (item.payload) {
            .glyph => |glyph_payload| glyph_payload.glyph.is_superscript,
            .input => false,
            .image => false,
            .iframe => false,
        };
        if (is_superscript) {
            max_superscript_ascent = @max(max_superscript_ascent, item.ascent);
            max_superscript_descent = @max(max_superscript_descent, item.descent);
        } else {
            has_normal_item = true;
            max_normal_ascent = @max(max_normal_ascent, item.ascent);
            max_normal_descent = @max(max_normal_descent, item.descent);
        }
    }

    // Normal glyphs share a baseline. Superscripts instead share the top of
    // the tallest normal glyph, so their metrics must not move that baseline.
    // A line containing only superscripts uses its own ascent as a fallback.
    const baseline_ascent = if (has_normal_item) max_normal_ascent else max_superscript_ascent;
    const normal_height = max_normal_ascent + max_normal_descent;
    const superscript_height = max_superscript_ascent + max_superscript_descent;
    const line_height = @max(normal_height, superscript_height);
    const extra_leading: i32 = @intFromFloat(@as(f32, @floatFromInt(line_height)) * 0.25);
    const baseline = self.cursor_y + baseline_ascent;
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
            // Position superscript so its top aligns with normal text top.
            final_y = baseline - baseline_ascent;
        } else {
            // Normal baseline alignment
            final_y = baseline - item.ascent;
        }

        const bounds_x = item.x + item.hit_offset_x;
        const bounds_y = final_y + item.hit_offset_y;
        const line_bounds_y = line_top + item.hit_offset_y;

        if (item.node_ptr) |ptr| {
            if (self.collect_hit_test_bounds) {
                if (item.payload == .input) {
                    try self.input_bounds.put(ptr, .{
                        .x = bounds_x,
                        .y = bounds_y,
                        .width = item.width,
                        .height = item.height,
                    });
                }
                try self.recordLinkBounds(ptr, bounds_x, line_bounds_y, item.width, line_box_height);
                try self.recordFragmentTargets(ptr, line_bounds_y);
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

    // Clean up embedded payload state now that the line is flushed.
    for (line_buffer.items) |*item| {
        item.payload.deinit();
    }

    // Advance cursor_y and reset cursor_x
    self.cursor_y = line_top + line_height + extra_leading;
    self.cursor_x = self.line_left;

    line_buffer.clearRetainingCapacity();
}

fn breakPreformattedLine(self: *Layout, line_buffer: *std.ArrayList(LineItem)) !void {
    if (line_buffer.items.len != 0) {
        try self.flushLine(line_buffer);
        return;
    }

    // An empty visual line has no glyph metrics for flushLine() to use. Measure
    // a representative monospace glyph so consecutive newlines advance by the
    // same line box as surrounding preformatted text without painting data.
    const weight: font.FontWeight = if (self.is_bold) .Bold else .Normal;
    const slant: font.FontSlant = if (self.is_italic) .Italic else .Roman;
    const text_size = textSizeForSuperscript(self.size, self.is_superscript);
    const reference = try self.font_manager.getStyledGlyph(
        "M",
        weight,
        slant,
        self.scaledFontSize(text_size),
        .monospace,
    );
    const ascent = self.toLayoutPx(reference.ascent);
    const descent = self.toLayoutPx(reference.descent);
    const line_height = @max(ascent + descent, 1);
    const extra_leading: i32 = @intFromFloat(@as(f32, @floatFromInt(line_height)) * 0.25);

    self.cursor_y += line_height + extra_leading;
    self.cursor_x = self.line_left;
    self.resetSoftHyphenWord();
}

fn breakExplicitLine(self: *Layout, line_buffer: *std.ArrayList(LineItem)) !void {
    if (self.is_preformatted) {
        try self.breakPreformattedLine(line_buffer);
    } else {
        try self.flushLine(line_buffer);
    }
    self.cursor_x = self.line_left;
}

// Add a common function for handling individual graphemes
fn processGrapheme(
    self: *Layout,
    gme: []const u8,
    line_buffer: *std.ArrayList(LineItem),
    node_ptr: ?*Node,
    options: GraphemeOptions,
) !void {
    // Handle newlines explicitly before font shaping.
    if (std.mem.eql(u8, gme, "\n") or std.mem.eql(u8, gme, "\r") or options.force_newline) {
        try self.breakExplicitLine(line_buffer);
        return;
    }

    if (isSoftHyphenGrapheme(gme)) {
        try self.recordSoftHyphenBreak(line_buffer, node_ptr, options);
        return;
    }

    const separates_word = isWordSeparatorGrapheme(gme);
    if (separates_word) self.resetSoftHyphenWord();

    // Choose one font for the complete Unicode grapheme. Emoji sequences must
    // not be split across fallback fonts or rendered as separate code points.
    const category = font.getGraphemeCategory(gme);

    const active_family = self.activeFontFamily();

    // Update current font category if needed
    if (category != self.current_font_category) {
        self.prev_font_category = self.current_font_category;
        self.current_font_category = category;
    }

    // Use the current style settings
    const weight: font.FontWeight = if (self.is_bold) .Bold else .Normal;
    const slant: font.FontSlant = if (self.is_italic) .Italic else .Roman;

    const text_size = textSizeForSuperscript(self.size, options.is_superscript);

    // Handle small caps rendering
    var glyph: font.Glyph = undefined;
    if (options.is_small_caps) {
        const is_lowercase = isSmallCapsLowercaseGrapheme(gme);

        if (is_lowercase) {
            // Preserve combining marks in the grapheme while uppercasing its
            // ASCII base. The allocation avoids imposing a cluster-size cap.
            const upper_gme = try self.allocator.dupe(u8, gme);
            defer self.allocator.free(upper_gme);
            upper_gme[0] = std.ascii.toUpper(upper_gme[0]);
            glyph = try self.font_manager.getStyledGlyph(
                upper_gme,
                .Bold, // Force bold for small caps
                slant,
                self.scaledFontSize(textSizeForSmallCaps(text_size)),
                active_family,
            );
        } else {
            // Regular rendering for non-lowercase characters
            glyph = try self.font_manager.getStyledGlyph(
                gme,
                weight,
                slant,
                self.scaledFontSize(text_size),
                active_family,
            );
        }
    } else {
        // Normal rendering
        glyph = try self.font_manager.getStyledGlyph(
            gme,
            weight,
            slant,
            self.scaledFontSize(text_size),
            active_family,
        );
    }

    glyph.is_superscript = options.is_superscript;

    const glyph_width = self.toLayoutPx(glyph.w);
    const glyph_height = self.toLayoutPx(glyph.h);
    const glyph_ascent = self.toLayoutPx(glyph.ascent);
    const glyph_descent = self.toLayoutPx(glyph.descent);

    // Check if we need to wrap (only at window edge)
    while (shouldAutomaticallyWrap(
        self.is_preformatted,
        self.cursor_x,
        glyph_width,
        self.line_right,
        line_buffer.items.len > 0,
    )) {
        if (try self.trySoftHyphenBreak(line_buffer)) continue;
        try self.flushLine(line_buffer);
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
    if (!separates_word) self.soft_hyphen_word_has_content = true;
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

fn recordFragmentTargets(self: *Layout, node_ptr: *Node, y: i32) !void {
    var current: ?*Node = node_ptr;
    while (current) |ptr| {
        switch (ptr.*) {
            .element => |*element| {
                if (element.attributes) |attrs| {
                    if (attrs.get("id")) |id| {
                        if (id.len > 0) {
                            var found = false;
                            for (self.fragment_targets.items) |*target| {
                                if (target.node == ptr) {
                                    target.y = @min(target.y, y);
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                try self.fragment_targets.append(self.allocator, .{
                                    .node = ptr,
                                    .y = y,
                                });
                            }
                        }
                    }
                }
                current = element.parent;
            },
            .text => |*text| current = text.parent,
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

// Preserve preformatted whitespace while decoding the same text entities used
// by ordinary text nodes.
fn handlePreformattedText(
    self: *Layout,
    content: []const u8,
    line_buffer: *std.ArrayList(LineItem),
    node_ptr: ?*Node,
) !void {
    var position: usize = 0;
    while (position < content.len) {
        const line_break_len = lineBreakLengthAt(content, position);
        if (line_break_len != 0) {
            try self.breakPreformattedLine(line_buffer);
            position += line_break_len;
            continue;
        }

        if (lexEntityAt(content, position)) |entity| {
            try self.processGrapheme(entity.replacement, line_buffer, node_ptr, .{
                .is_superscript = self.is_superscript,
                .is_small_caps = self.is_small_caps,
            });
            position += entity.len;
            continue;
        }

        if (content[position] == '&') {
            // An ampersand that does not begin a recognized entity is text.
            try self.processGrapheme("&", line_buffer, node_ptr, .{
                .is_superscript = self.is_superscript,
                .is_small_caps = self.is_small_caps,
            });
            position += 1;
            continue;
        }

        // Preserve the run byte-for-byte while still keeping Unicode grapheme
        // clusters together for font fallback.
        var run_end = position;
        while (run_end < content.len and
            content[run_end] != '&' and
            lineBreakLengthAt(content, run_end) == 0)
        {
            run_end += 1;
        }
        const run = content[position..run_end];
        var g_iter = grapheme.iterator(run);
        while (g_iter.next()) |gc| {
            try self.processGrapheme(gc.bytes(run), line_buffer, node_ptr, .{
                .is_superscript = self.is_superscript,
                .is_small_caps = self.is_small_caps,
            });
        }
        position = run_end;
    }
}

fn lineBreakLengthAt(text: []const u8, position: usize) usize {
    if (position >= text.len) return 0;
    return switch (text[position]) {
        '\n' => 1,
        '\r' => if (position + 1 < text.len and text[position + 1] == '\n') 2 else 1,
        else => 0,
    };
}

fn paragraphGap(font_size: i32) i32 {
    const line_step = @max(font_size, 1);
    return @max(@divTrunc(line_step, 2), 1);
}

fn breakParagraph(self: *Layout, line_buffer: *std.ArrayList(LineItem)) !void {
    const initial_y = self.cursor_y;
    try self.flushLine(line_buffer);

    const gap = paragraphGap(self.size);
    if (self.cursor_y == initial_y) {
        // Preserve an empty source line even though flushLine has no glyph
        // metrics from which to derive its normal advance.
        self.cursor_y += @max(self.size, 1);
    }
    self.cursor_y += gap;
    self.cursor_x = self.line_left;
}

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

    // Keep source text in Unicode grapheme clusters while stopping at syntax
    // that needs special handling. This keeps emoji modifiers, flags, and ZWJ
    // sequences together for font fallback and rasterization.
    var i: usize = 0;
    while (i < content.len) {
        const line_break_len = lineBreakLengthAt(content, i);
        if (line_break_len != 0) {
            try self.breakParagraph(line_buffer);
            i += line_break_len;
            continue;
        }

        if (content[i] == '&') {
            if (lexEntityAt(content, i)) |entity| {
                try self.processGrapheme(entity.replacement, line_buffer, node_ptr, .{
                    .is_superscript = self.is_superscript,
                    .is_small_caps = self.is_small_caps,
                });

                i += entity.len;
                continue;
            }

            // An ampersand that does not begin a recognized entity is text.
            try self.processGrapheme("&", line_buffer, node_ptr, .{
                .is_superscript = self.is_superscript,
                .is_small_caps = self.is_small_caps,
            });
            i += 1;
            continue;
        }

        var run_end = i;
        while (run_end < content.len and
            content[run_end] != '&' and
            lineBreakLengthAt(content, run_end) == 0)
        {
            run_end += 1;
        }

        const run = content[i..run_end];
        var g_iter = grapheme.iterator(run);
        while (g_iter.next()) |gc| {
            try self.processGrapheme(gc.bytes(run), line_buffer, node_ptr, .{
                .is_superscript = self.is_superscript,
                .is_small_caps = self.is_small_caps,
            });
        }
        i = run_end;
    }
}

fn graphemeCount(text: []const u8) usize {
    var count: usize = 0;
    var iter = grapheme.iterator(text);
    while (iter.next()) |_| count += 1;
    return count;
}

test "emoji sequences stay in one grapheme cluster" {
    try std.testing.expectEqual(@as(usize, 1), graphemeCount("👍🏽"));
    try std.testing.expectEqual(@as(usize, 1), graphemeCount("👨‍👩‍👧‍👦"));
    try std.testing.expectEqual(@as(usize, 1), graphemeCount("🇺🇸"));
}

test "lineBreakLengthAt recognizes platform newline encodings" {
    try std.testing.expectEqual(@as(usize, 1), lineBreakLengthAt("a\nb", 1));
    try std.testing.expectEqual(@as(usize, 2), lineBreakLengthAt("a\r\nb", 1));
    try std.testing.expectEqual(@as(usize, 1), lineBreakLengthAt("a\rb", 1));
    try std.testing.expectEqual(@as(usize, 0), lineBreakLengthAt("abc", 1));
}

test "paragraph gap adds visible leading beyond a normal line step" {
    try std.testing.expectEqual(@as(i32, 8), paragraphGap(16));
    try std.testing.expect(paragraphGap(16) > 0);
    try std.testing.expectEqual(@as(i32, 1), paragraphGap(1));
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

test "lexEntityAt recognizes the entities rendered as text" {
    const input = "&lt;div&gt; &amp; &quot;quote&quot; &apos;apostrophe&apos;";

    const less_than = lexEntityAt(input, 0).?;
    try std.testing.expectEqualStrings("<", less_than.replacement);
    try std.testing.expectEqual(@as(usize, 4), less_than.len);

    const greater_than_start = std.mem.indexOf(u8, input, "&gt;").?;
    const greater_than = lexEntityAt(input, greater_than_start).?;
    try std.testing.expectEqualStrings(">", greater_than.replacement);
    try std.testing.expectEqual(@as(usize, 4), greater_than.len);

    const soft_hyphen = lexEntityAt("&shy;", 0).?;
    try std.testing.expectEqualStrings("\u{00AD}", soft_hyphen.replacement);
    try std.testing.expectEqual(@as(usize, 5), soft_hyphen.len);

    try std.testing.expect(lexEntityAt("&unknown;", 0) == null);
    try std.testing.expect(lexEntityAt("&lt", 0) == null);
}

// Update layoutSourceCode to format HTML source with tags in normal font and content in bold
pub fn layoutSourceCode(self: *Layout, source: []const u8) ![]DisplayItem {
    self.current_display_target = &self.display_list;
    self.line_left = h_offset;
    self.line_right = self.layoutWindowWidth() - self.layoutScrollbarWidth() - h_offset;
    self.cursor_x = self.line_left;
    self.cursor_y = v_offset;
    self.line_direction = self.default_direction;
    self.size = self.default_font_size;
    self.resetSoftHyphenWord();

    // Save current state
    const original_preformatted = self.is_preformatted;
    const original_font_category = self.current_font_category;
    const original_is_bold = self.is_bold;
    const original_font_family = self.font_family;

    // Start with preformatted mode on for whitespace preservation
    // but use normal font for initial state
    self.is_preformatted = true; // Keep preformatted for all content to preserve whitespace
    self.font_family = .proportional;
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
            var g_iter = grapheme.iterator(source[i .. i + 1]);
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
            var g_iter = grapheme.iterator(source[i .. i + 1]);
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
        var g_iter = grapheme.iterator(source[i..]);
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
    self.font_family = original_font_family;

    // `cursor_y` already includes the top page padding. Keep matching bottom
    // whitespace so source documents use the same scroll contract as HTML.
    self.content_height = addPageBottomPadding(self.cursor_y);
    return try self.display_list.toOwnedSlice(self.allocator);
}

const INPUT_WIDTH_PX: i32 = 200;

// Input layout for form widgets (input and button elements)
const InputLayout = struct {
    embed: EmbedLayout,
    font_size: i32 = 16,
    font_weight: FontWeight = .Normal,
    font_slant: FontSlant = .Roman,
    font_family: FontFamily = .proportional,
    color: browser.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    bgcolor: browser.Color = .{ .r = 173, .g = 216, .b = 230, .a = 255 }, // lightblue
    text: []const u8 = "",
    is_focused: bool = false,

    fn init(allocator: std.mem.Allocator) InputLayout {
        return .{
            .embed = EmbedLayout.init(allocator),
        };
    }

    fn deinit(self: *InputLayout) void {
        self.embed.deinit();
    }

    fn measure(self: *InputLayout, engine: *Layout, element: parser.Element) !void {
        self.font_weight = if (engine.is_bold) .Bold else .Normal;
        self.font_slant = if (engine.is_italic) .Italic else .Roman;
        self.font_family = engine.activeFontFamily();
        self.font_size = engine.scaledFontSize(engine.size);
        self.color = engine.text_color;

        if (element.style) |*style_map| {
            if (styleValue(style_map, "background-color")) |bg| {
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
                    else => {},
                }
            }
        }

        const glyph = try engine.font_manager.getStyledGlyph(
            "X",
            self.font_weight,
            self.font_slant,
            self.font_size,
            self.font_family,
        );

        const ascent_value = engine.toLayoutPx(glyph.ascent);
        const descent_value = engine.toLayoutPx(glyph.descent);
        const height_value = ascent_value + descent_value;
        self.embed.setupDependencies(engine.inline_block, if (element.style) |*map| map else null);
        self.embed.setMetrics(INPUT_WIDTH_PX, height_value, ascent_value, descent_value, engine.zoom(), self.font_size);
        self.is_focused = element.is_focused;
    }

    fn paintAt(self: *const InputLayout, commands: *std.ArrayList(DisplayItem), engine: *Layout, x: i32, y: i32) !void {
        const width_value = self.embed.width.get().*;
        const height_value = self.embed.height.get().*;
        const ascent_value = self.embed.ascent.get().*;
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
            var g_iter = grapheme.iterator(self.text);

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
                    self.font_family,
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
const TextLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    word: []const u8,
    parent: *LineLayout,
    previous: ?*TextLayout,

    // ProtectedField-wrapped layout properties
    zoom: ProtectedField(f32),
    x: ProtectedField(i32),
    y: ProtectedField(i32),
    width: ProtectedField(i32),
    height: ProtectedField(i32),
    ascent: ProtectedField(i32),
    descent: ProtectedField(i32),

    // Non-layout style properties (not ProtectedFields)
    font_size: i32 = 16,
    font_weight: FontWeight = .Normal,
    font_slant: FontSlant = .Roman,
    font_family: FontFamily = .proportional,
    color: browser.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },

    // Dirty tracking for descendants
    has_dirty_descendants: bool = false,

    fn markOpaque(ptr: *anyopaque) void {
        const self: *TextLayout = @ptrCast(@alignCast(ptr));
        self.mark();
    }

    fn init(
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
            .zoom = ProtectedField(f32).init(allocator, 1.0),
            .x = ProtectedField(i32).init(allocator, 0),
            .y = ProtectedField(i32).init(allocator, 0),
            .width = ProtectedField(i32).init(allocator, 0),
            .height = ProtectedField(i32).init(allocator, 0),
            .ascent = ProtectedField(i32).init(allocator, 0),
            .descent = ProtectedField(i32).init(allocator, 0),
        };
        text.zoom.setOwner(text, markOpaque);
        text.x.setOwner(text, markOpaque);
        text.y.setOwner(text, markOpaque);
        text.width.setOwner(text, markOpaque);
        text.height.setOwner(text, markOpaque);
        text.ascent.setOwner(text, markOpaque);
        text.descent.setOwner(text, markOpaque);

        // Freeze dependencies for layout fields.
        text.zoom.addDependency(&parent.zoom);
        text.zoom.freezeDependencies();

        if (previous) |prev| {
            text.x.addDependency(&prev.x);
            text.x.addDependency(&prev.width);
        } else {
            text.x.addDependency(&parent.x);
        }
        text.x.freezeDependencies();

        text.y.addDependency(&text.ascent);
        text.y.addDependency(&parent.y);
        text.y.addDependency(&parent.ascent);
        text.y.freezeDependencies();

        text.width.addDependency(&text.zoom);
        text.height.addDependency(&text.zoom);
        text.ascent.addDependency(&text.zoom);
        text.descent.addDependency(&text.zoom);

        switch (text.node) {
            .text => |*t| {
                if (t.style) |*style_map| {
                    if (style_map.getPtr("font-weight")) |field| {
                        text.width.addDependency(field);
                        text.height.addDependency(field);
                        text.ascent.addDependency(field);
                        text.descent.addDependency(field);
                    }
                    if (style_map.getPtr("font-style")) |field| {
                        text.width.addDependency(field);
                        text.height.addDependency(field);
                        text.ascent.addDependency(field);
                        text.descent.addDependency(field);
                    }
                    if (style_map.getPtr("font-size")) |field| {
                        text.width.addDependency(field);
                        text.height.addDependency(field);
                        text.ascent.addDependency(field);
                        text.descent.addDependency(field);
                    }
                    if (style_map.getPtr("font-family")) |field| {
                        text.width.addDependency(field);
                        text.height.addDependency(field);
                        text.ascent.addDependency(field);
                        text.descent.addDependency(field);
                    }
                }
            },
            .element => |*e| {
                if (e.style) |*style_map| {
                    if (style_map.getPtr("font-weight")) |field| {
                        text.width.addDependency(field);
                        text.height.addDependency(field);
                        text.ascent.addDependency(field);
                        text.descent.addDependency(field);
                    }
                    if (style_map.getPtr("font-style")) |field| {
                        text.width.addDependency(field);
                        text.height.addDependency(field);
                        text.ascent.addDependency(field);
                        text.descent.addDependency(field);
                    }
                    if (style_map.getPtr("font-size")) |field| {
                        text.width.addDependency(field);
                        text.height.addDependency(field);
                        text.ascent.addDependency(field);
                        text.descent.addDependency(field);
                    }
                    if (style_map.getPtr("font-family")) |field| {
                        text.width.addDependency(field);
                        text.height.addDependency(field);
                        text.ascent.addDependency(field);
                        text.descent.addDependency(field);
                    }
                }
            },
        }
        text.width.freezeDependencies();
        text.height.freezeDependencies();
        text.ascent.freezeDependencies();
        text.descent.freezeDependencies();
        return text;
    }

    fn deinit(self: *TextLayout) void {
        self.zoom.deinit();
        self.x.deinit();
        self.y.deinit();
        self.width.deinit();
        self.height.deinit();
        self.ascent.deinit();
        self.descent.deinit();
    }

    fn mark(self: *TextLayout) void {
        // Mark all layout properties as dirty
        self.x.markNoOwner();
        self.y.markNoOwner();
        self.width.markNoOwner();
        self.height.markNoOwner();
        self.ascent.markNoOwner();
        self.descent.markNoOwner();
        self.zoom.markNoOwner();
        // Mark immediate parent LineLayout
        if (self.parent.has_dirty_descendants) return;
        self.parent.has_dirty_descendants = true;
        // Get the BlockLayout parent and mark up the tree
        var block_parent: *BlockLayout = self.parent.parent;
        if (block_parent.has_dirty_descendants) return;
        block_parent.has_dirty_descendants = true;
        // Walk up through BlockLayout chain
        var current: ?*BlockLayout = block_parent.parent_block;
        while (current) |bp| {
            if (bp.has_dirty_descendants) break;
            bp.has_dirty_descendants = true;
            current = bp.parent_block;
        }
        // Mark document
        if (block_parent.document.has_dirty_descendants) return;
        block_parent.document.has_dirty_descendants = true;
    }

    fn layout(self: *TextLayout, engine: *Layout) !void {
        // Skip layout if nothing is dirty
        if (!self.layoutNeeded()) return;

        // Get font properties from node style
        self.font_weight = if (engine.is_bold) .Bold else .Normal;
        self.font_slant = if (engine.is_italic) .Italic else .Roman;
        self.font_family = engine.activeFontFamily();
        self.font_size = engine.scaledFontSize(engine.size);
        self.color = engine.text_color;

        // Measure the word to get its width
        const glyph = try engine.font_manager.getStyledGlyph(
            self.word,
            self.font_weight,
            self.font_slant,
            self.font_size,
            self.font_family,
        );

        const width_value = engine.toLayoutPx(glyph.w);
        const ascent_value = engine.toLayoutPx(glyph.ascent);
        const descent_value = engine.toLayoutPx(glyph.descent);
        const height_value = ascent_value + descent_value;

        // Compute x position (horizontal stacking with space between words)
        // Use .read() to register invalidation dependencies on other objects' fields
        const x_value = if (self.previous) |prev| x: {
            // Measure a space character
            const space_glyph = try engine.font_manager.getStyledGlyph(
                " ",
                prev.font_weight,
                prev.font_slant,
                prev.font_size,
                prev.font_family,
            );
            const space = engine.toLayoutPx(space_glyph.w);
            break :x prev.x.read(&self.x).* + space + prev.width.read(&self.x).*;
        } else x: {
            break :x self.parent.x.read(&self.x).*;
        };

        // Set all values using ProtectedField.set() (clears dirty flags)
        self.width.set(width_value);
        self.height.set(height_value);
        self.ascent.set(ascent_value);
        self.descent.set(descent_value);
        self.x.set(x_value);
        self.zoom.set(1.0);
        // y position is computed by LineLayout after baseline is determined

        // Clear descendant flags after layout pass
        self.has_dirty_descendants = false;
    }

    fn paint(self: *TextLayout, engine: *Layout) !void {
        var commands = std.ArrayList(DisplayItem).empty;
        defer commands.deinit(engine.allocator);
        try self.paintToList(&commands, engine);
        for (commands.items) |cmd| {
            try engine.display_list.append(engine.allocator, cmd);
        }
    }

    fn paintToList(self: *TextLayout, commands: *std.ArrayList(DisplayItem), engine: *Layout) !void {
        // Paint the word using the stored font properties
        const glyph = try engine.font_manager.getStyledGlyph(
            self.word,
            self.font_weight,
            self.font_slant,
            self.font_size,
            self.font_family,
        );

        try commands.append(self.allocator, DisplayItem{
            .glyph = .{
                .x = self.x.get().*,
                .y = self.y.get().*,
                .glyph = glyph,
                .color = engine.remapColor(self.color),
            },
        });
    }

    fn layoutNeeded(self: *const TextLayout) bool {
        if (self.zoom.dirty) return true;
        if (self.x.dirty) return true;
        if (self.y.dirty) return true;
        if (self.width.dirty) return true;
        if (self.height.dirty) return true;
        if (self.ascent.dirty) return true;
        if (self.descent.dirty) return true;
        if (self.has_dirty_descendants) return true;
        return false;
    }

    fn shouldPaint(self: *const TextLayout) bool {
        _ = self;
        return true;
    }
};

// Line layout for each line of text
const LineLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    parent: *BlockLayout,
    previous: ?*LineLayout,

    // ProtectedField-wrapped layout properties
    zoom: ProtectedField(f32),
    x: ProtectedField(i32),
    y: ProtectedField(i32),
    width: ProtectedField(i32),
    height: ProtectedField(i32),
    ascent: ProtectedField(i32),
    descent: ProtectedField(i32),

    children: std.ArrayList(*TextLayout),
    has_dirty_descendants: bool = false,
    initialized_fields: bool = false,

    fn markOpaque(ptr: *anyopaque) void {
        const self: *LineLayout = @ptrCast(@alignCast(ptr));
        self.mark();
    }

    fn init(
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
            .zoom = ProtectedField(f32).init(allocator, 1.0),
            .x = ProtectedField(i32).init(allocator, 0),
            .y = ProtectedField(i32).init(allocator, 0),
            .width = ProtectedField(i32).init(allocator, 0),
            .height = ProtectedField(i32).init(allocator, 0),
            .ascent = ProtectedField(i32).init(allocator, 0),
            .descent = ProtectedField(i32).init(allocator, 0),
            .children = std.ArrayList(*TextLayout).empty,
            .initialized_fields = false,
        };
        line.zoom.setOwner(line, markOpaque);
        line.x.setOwner(line, markOpaque);
        line.y.setOwner(line, markOpaque);
        line.width.setOwner(line, markOpaque);
        line.height.setOwner(line, markOpaque);
        line.ascent.setOwner(line, markOpaque);
        line.descent.setOwner(line, markOpaque);

        line.zoom.addDependency(&parent.zoom);
        line.zoom.freezeDependencies();
        line.x.addDependency(&parent.x);
        line.x.freezeDependencies();
        line.width.addDependency(&parent.width);
        line.width.freezeDependencies();
        if (previous) |prev| {
            line.y.addDependency(&prev.y);
            line.y.addDependency(&prev.height);
        } else {
            line.y.addDependency(&parent.y);
        }
        line.y.freezeDependencies();
        line.height.addDependency(&line.ascent);
        line.height.addDependency(&line.descent);
        line.height.freezeDependencies();
        return line;
    }

    fn deinit(self: *LineLayout) void {
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
        self.zoom.deinit();
        self.x.deinit();
        self.y.deinit();
        self.width.deinit();
        self.height.deinit();
        self.ascent.deinit();
        self.descent.deinit();
    }

    fn layout(self: *LineLayout, engine: *Layout) !void {
        // Skip layout if nothing is dirty
        if (!self.layoutNeeded()) return;

        if (!self.initialized_fields) {
            var ascent_deps = std.ArrayList(*ProtectedField(i32)).empty;
            var descent_deps = std.ArrayList(*ProtectedField(i32)).empty;
            defer ascent_deps.deinit(self.allocator);
            defer descent_deps.deinit(self.allocator);
            for (self.children.items) |child| {
                try ascent_deps.append(self.allocator, &child.ascent);
                try descent_deps.append(self.allocator, &child.descent);
            }
            for (ascent_deps.items) |dep| {
                self.ascent.addDependency(dep);
            }
            for (descent_deps.items) |dep| {
                self.descent.addDependency(dep);
            }
            self.ascent.freezeDependencies();
            self.descent.freezeDependencies();
            self.initialized_fields = true;
        }

        // Compute x position from parent block
        // Use .read() to register invalidation dependencies on parent's fields
        const x_value = self.parent.x.read(&self.x).*;
        const width_value = self.parent.width.read(&self.width).*;

        // Position is below previous line, or at parent's y
        // Use .read() to register invalidation dependencies on previous/parent fields
        const y_value = if (self.previous) |prev| prev.y.read(&self.y).* + prev.height.read(&self.y).* else self.parent.y.read(&self.y).*;

        // Set x and y BEFORE child layout so children can read them
        self.x.set(x_value);
        self.y.set(y_value);
        self.width.set(width_value);

        // Layout each word in the line (computes x, width, height, font metrics)
        for (self.children.items) |word| {
            try word.layout(engine);
        }

        // Compute the line's baseline from maximum ascent
        // Use .read() to register invalidation dependencies on children's ascent
        var max_ascent: i32 = 0;
        for (self.children.items) |word| {
            const word_ascent = word.ascent.read(&self.ascent).*;
            if (word_ascent > max_ascent) {
                max_ascent = word_ascent;
            }
        }

        // Baseline with 1.25 leading factor
        const baseline = y_value + @as(i32, @intFromFloat(1.25 * @as(f32, @floatFromInt(max_ascent))));

        // Position each word vertically relative to baseline
        for (self.children.items) |word| {
            const word_ascent = word.ascent.read(&self.ascent).*;
            const y_word = baseline - word_ascent;
            word.y.set(y_word);
        }

        // Compute maximum descent
        // Use .read() to register invalidation dependencies on children's descent
        var max_descent: i32 = 0;
        for (self.children.items) |word| {
            const word_descent = word.descent.read(&self.descent).*;
            if (word_descent > max_descent) {
                max_descent = word_descent;
            }
        }

        // Compute line height with 1.25 leading factor
        const height_value = @as(i32, @intFromFloat(1.25 * @as(f32, @floatFromInt(max_ascent + max_descent))));

        // Set remaining values (x, y already set before child layout)
        self.ascent.set(max_ascent);
        self.descent.set(max_descent);
        self.height.set(height_value);
        self.zoom.set(1.0);

        // Clear descendant flags after layout pass
        self.has_dirty_descendants = false;
    }

    fn paint(self: *LineLayout, engine: *Layout) !void {
        var commands = std.ArrayList(DisplayItem).empty;
        defer commands.deinit(engine.allocator);
        try self.paintToList(&commands, engine);
        for (commands.items) |cmd| {
            try engine.display_list.append(engine.allocator, cmd);
        }
    }

    fn paintToList(self: *LineLayout, commands: *std.ArrayList(DisplayItem), engine: *Layout) !void {
        // Paint each word in the line
        for (self.children.items) |text| {
            try text.paintToList(commands, engine);
        }
    }

    fn layoutNeeded(self: *const LineLayout) bool {
        if (self.zoom.dirty) return true;
        if (self.x.dirty) return true;
        if (self.y.dirty) return true;
        if (self.width.dirty) return true;
        if (self.height.dirty) return true;
        if (self.ascent.dirty) return true;
        if (self.descent.dirty) return true;
        if (self.has_dirty_descendants) return true;
        return false;
    }

    fn mark(self: *LineLayout) void {
        // Mark all layout properties as dirty
        self.x.markNoOwner();
        self.y.markNoOwner();
        self.width.markNoOwner();
        self.height.markNoOwner();
        self.ascent.markNoOwner();
        self.descent.markNoOwner();
        self.zoom.markNoOwner();
        // Mark immediate parent BlockLayout
        var block_parent: *BlockLayout = self.parent;
        if (block_parent.has_dirty_descendants) return;
        block_parent.has_dirty_descendants = true;
        // Walk up through BlockLayout chain
        var current: ?*BlockLayout = block_parent.parent_block;
        while (current) |bp| {
            if (bp.has_dirty_descendants) break;
            bp.has_dirty_descendants = true;
            current = bp.parent_block;
        }
        // Mark document
        if (block_parent.document.has_dirty_descendants) return;
        block_parent.document.has_dirty_descendants = true;
    }

    fn shouldPaint(self: *const LineLayout) bool {
        _ = self;
        return true;
    }
};

pub const DocumentLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    node_ptr: *Node,

    zoom: ProtectedField(f32),
    x: ProtectedField(i32),
    y: ProtectedField(i32),
    width: ProtectedField(i32),
    height: ProtectedField(i32),
    children: std.ArrayList(*BlockLayout),

    has_dirty_descendants: bool = false,

    fn markOpaque(ptr: *anyopaque) void {
        const self: *DocumentLayout = @ptrCast(@alignCast(ptr));
        self.mark();
    }

    fn init(allocator: std.mem.Allocator, node: *Node) !*DocumentLayout {
        const document = try allocator.create(DocumentLayout);
        document.* = DocumentLayout{
            .allocator = allocator,
            .node = node.*,
            .node_ptr = node,
            .zoom = ProtectedField(f32).init(allocator, 1.0),
            .children = std.ArrayList(*BlockLayout).empty,
            .x = ProtectedField(i32).init(allocator, h_offset),
            .y = ProtectedField(i32).init(allocator, v_offset),
            .width = ProtectedField(i32).init(allocator, 0),
            .height = ProtectedField(i32).init(allocator, 0),
        };
        document.zoom.setOwner(document, markOpaque);
        document.x.setOwner(document, markOpaque);
        document.y.setOwner(document, markOpaque);
        document.width.setOwner(document, markOpaque);
        document.height.setOwner(document, markOpaque);

        document.zoom.freezeDependencies();
        document.x.freezeDependencies();
        document.y.freezeDependencies();
        document.width.freezeDependencies();

        return document;
    }

    pub fn deinit(self: *DocumentLayout) void {
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
        self.zoom.deinit();
        self.x.deinit();
        self.y.deinit();
        self.width.deinit();
        self.height.deinit();
    }

    /// Serialize geometry only. This is for deterministic inspection before
    /// painting; it does not invoke the compositor, rasterizer, or window.
    pub fn writeDebug(self: *const DocumentLayout, writer: *std.Io.Writer) !void {
        try writer.print(
            "document x={d} y={d} width={d} height={d}\n",
            .{ self.x.get().*, self.y.get().*, self.width.get().*, self.height.get().* },
        );
        for (self.children.items) |child| try writeBlockDebug(writer, child, 2);
    }

    pub fn layout(self: *DocumentLayout, engine: *Layout) !void {
        if (!self.layoutNeeded()) return;

        // Compute dimensions
        const x_value = h_offset;
        const y_value = v_offset;
        const width_value = engine.layoutWindowWidth() - engine.layoutScrollbarWidth() - (2 * h_offset);
        const zoom_value = engine.zoom();

        // Set x, y, width, zoom BEFORE child layout so children can read them
        self.x.set(x_value);
        self.y.set(y_value);
        self.width.set(width_value);
        self.zoom.set(zoom_value);

        engine.input_bounds.clearRetainingCapacity();
        engine.link_bounds.clearRetainingCapacity();
        engine.iframe_bounds.clearRetainingCapacity();
        engine.focus_bounds.clearRetainingCapacity();
        engine.accessibility_bounds.clearRetainingCapacity();
        engine.fragment_targets.clearRetainingCapacity();

        self.node = self.node_ptr.*;

        var root_block = if (self.children.items.len > 0) self.children.items[0] else null;
        if (root_block == null) {
            const child = try BlockLayout.init(self.allocator, self.node, self.node_ptr, self, null, null);
            try self.children.append(self.allocator, child);
            root_block = child;
        }

        const block = root_block.?;
        if (!self.height.frozen_dependencies) {
            self.height.addDependency(&block.height);
            self.height.freezeDependencies();
        } else {
            self.height.addDependency(&block.height);
        }
        block.node = self.node;
        block.node_ptr = self.node_ptr;
        try block.layout(engine);

        // Set height after child layout completes
        // Use .read() to register invalidation dependency on child's height
        self.height.set(block.height.read(&self.height).*);

        // Clear descendant flags after layout pass
        self.has_dirty_descendants = false;
    }

    pub fn layoutNeeded(self: *const DocumentLayout) bool {
        if (self.zoom.dirty) return true;
        if (self.x.dirty) return true;
        if (self.y.dirty) return true;
        if (self.width.dirty) return true;
        if (self.height.dirty) return true;
        if (self.has_dirty_descendants) return true;
        return false;
    }

    pub fn mark(self: *DocumentLayout) void {
        // Mark all layout properties as dirty
        self.x.markNoOwner();
        self.y.markNoOwner();
        self.width.markNoOwner();
        self.height.markNoOwner();
        self.zoom.markNoOwner();
        self.has_dirty_descendants = true;
        // Also mark all children so they re-layout
        for (self.children.items) |child| {
            child.mark();
        }
    }

    fn shouldPaint(self: *const DocumentLayout) bool {
        _ = self;
        return true;
    }
};

// Union type to handle both block and line children
const LayoutChild = union(enum) {
    block: *BlockLayout,
    line: *LineLayout,

    fn deinit(self: LayoutChild, allocator: std.mem.Allocator) void {
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

const BlockLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    node_ptr: ?*Node,
    document: *DocumentLayout,
    parent_block: ?*BlockLayout,
    previous: ?*BlockLayout,
    // An anonymous block owns this pointer slice and lays out each sibling as
    // one inline run. Normal blocks retain their single DOM node instead.
    inline_nodes: ?[]*Node = null,

    // ProtectedField-wrapped layout properties
    zoom: ProtectedField(f32),
    x: ProtectedField(i32),
    y: ProtectedField(i32),
    width: ProtectedField(i32),
    height: ProtectedField(i32),
    children_epoch: u64 = 0,
    children_version: ProtectedField(u64),

    children: std.ArrayList(LayoutChild),
    display_list: std.ArrayList(DisplayItem),
    cursor_x: i32 = 0,
    has_dirty_descendants: bool = false,

    fn markOpaque(ptr: *anyopaque) void {
        const self: *BlockLayout = @ptrCast(@alignCast(ptr));
        self.mark();
    }

    fn init(
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
            .zoom = ProtectedField(f32).init(allocator, 1.0),
            .x = ProtectedField(i32).init(allocator, 0),
            .y = ProtectedField(i32).init(allocator, 0),
            .width = ProtectedField(i32).init(allocator, 0),
            .height = ProtectedField(i32).init(allocator, 0),
            .children = std.ArrayList(LayoutChild).empty,
            .display_list = std.ArrayList(DisplayItem).empty,
            .children_epoch = 0,
            .children_version = ProtectedField(u64).init(allocator, 0),
        };
        block.zoom.setOwner(block, markOpaque);
        block.x.setOwner(block, markOpaque);
        block.y.setOwner(block, markOpaque);
        block.width.setOwner(block, markOpaque);
        block.height.setOwner(block, markOpaque);
        block.children_version.setOwner(block, markOpaque);

        if (parent_block) |parent| {
            block.zoom.addDependency(&parent.zoom);
            block.x.addDependency(&parent.x);
            block.width.addDependency(&parent.width);
            if (previous) |prev| {
                block.y.addDependency(&prev.y);
                block.y.addDependency(&prev.height);
            } else {
                block.y.addDependency(&parent.y);
            }
        } else {
            block.zoom.addDependency(&document.zoom);
            block.x.addDependency(&document.x);
            block.width.addDependency(&document.width);
            if (previous) |prev| {
                block.y.addDependency(&prev.y);
                block.y.addDependency(&prev.height);
            } else {
                block.y.addDependency(&document.y);
            }
        }

        // Real DOM-backed blocks react to changes in their specified
        // dimensions. Anonymous blocks intentionally keep their auto size.
        if (node_ptr) |ptr| {
            switch (ptr.*) {
                .element => |*element| {
                    if (element.style) |*style_map| {
                        if (style_map.getPtr("width")) |field| block.width.addDependency(field);
                        if (style_map.getPtr("height")) |field| block.height.addDependency(field);
                    }
                },
                .text => {},
            }
        }
        block.zoom.freezeDependencies();
        block.x.freezeDependencies();
        block.y.freezeDependencies();
        block.width.freezeDependencies();
        block.children_version.freezeDependencies();

        if (node_ptr) |ptr| {
            switch (ptr.*) {
                .element => |*e| {
                    e.layout_ptr = block;
                    e.layout_mark = markOpaque;
                },
                else => {},
            }
        }

        return block;
    }

    fn specifiedPixelDimension(
        self: *BlockLayout,
        property: []const u8,
        target: *ProtectedField(i32),
    ) ?i32 {
        if (self.inline_nodes != null) return null;
        const node_ptr = self.node_ptr orelse return null;
        return switch (node_ptr.*) {
            .element => |*element| if (element.style) |*style_map|
                if (styleValueRead(style_map, property, target)) |value|
                    parseCssPixelLength(value)
                else
                    null
            else
                null,
            .text => null,
        };
    }

    fn initAnonymous(
        allocator: std.mem.Allocator,
        inline_nodes: []*Node,
        document: *DocumentLayout,
        parent_block: *BlockLayout,
        previous: ?*BlockLayout,
    ) !*BlockLayout {
        std.debug.assert(inline_nodes.len > 0);
        const block = try BlockLayout.init(
            allocator,
            inline_nodes[0].*,
            null,
            document,
            parent_block,
            previous,
        );
        block.inline_nodes = inline_nodes;
        return block;
    }

    fn deinit(self: *BlockLayout) void {
        if (self.node_ptr) |ptr| {
            switch (ptr.*) {
                .element => |*e| {
                    const self_ptr: *anyopaque = @ptrCast(@alignCast(self));
                    if (e.layout_ptr == self_ptr) {
                        e.layout_ptr = null;
                        e.layout_mark = null;
                    }
                },
                else => {},
            }
        }
        for (self.children.items) |child| {
            child.deinit(self.allocator);
        }
        self.children.deinit(self.allocator);
        if (self.inline_nodes) |nodes| self.allocator.free(nodes);
        self.display_list.deinit(self.allocator);
        self.zoom.deinit();
        self.x.deinit();
        self.y.deinit();
        self.width.deinit();
        self.height.deinit();
        self.children_version.deinit();
    }

    fn mark(self: *BlockLayout) void {
        // Mark all layout properties as dirty
        self.x.markNoOwner();
        self.y.markNoOwner();
        self.width.markNoOwner();
        self.height.markNoOwner();
        self.zoom.markNoOwner();
        // Mark ancestors' has_dirty_descendants by walking up the parent chain
        if (self.parent_block) |parent| {
            if (parent.has_dirty_descendants) return;
            parent.has_dirty_descendants = true;
            var current: ?*BlockLayout = parent.parent_block;
            while (current) |bp| {
                if (bp.has_dirty_descendants) break;
                bp.has_dirty_descendants = true;
                current = bp.parent_block;
            }
            if (parent.document.has_dirty_descendants) return;
            parent.document.has_dirty_descendants = true;
        } else {
            if (self.document.has_dirty_descendants) return;
            self.document.has_dirty_descendants = true;
        }
    }

    fn isBlockContainer(self: *BlockLayout) bool {
        if (self.inline_nodes != null) return false;
        switch (self.node) {
            .text => return false,
            .element => |e| {
                // Input, button, and iframe elements are always inline, even though they may have no children
                if (std.ascii.eqlIgnoreCase(e.tag, "input") or std.ascii.eqlIgnoreCase(e.tag, "button") or
                    std.ascii.eqlIgnoreCase(e.tag, "img") or std.ascii.eqlIgnoreCase(e.tag, "iframe"))
                {
                    return false;
                }

                // A block-displayed child creates a block formatting context.
                // Otherwise, mixed content stays inline unless the element is
                // empty, matching the book's simplified layout algorithm.
                for (e.children.items) |child| {
                    if (isContainerNode(child, &self.children_version)) return true;
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

    fn layout(self: *BlockLayout, engine: *Layout) !void {
        // Skip layout if nothing is dirty
        if (!self.layoutNeeded()) return;

        if (self.node_ptr) |ptr| {
            self.node = ptr.*;
        }

        // Compute position and dimensions
        // Use .read() to register invalidation dependencies on parent/document/previous fields
        const parent_x = if (self.parent_block) |pb| pb.x.read(&self.x).* else self.document.x.read(&self.x).*;
        const parent_width = if (self.parent_block) |pb| pb.width.read(&self.width).* else self.document.width.read(&self.width).*;
        const prev_y = if (self.previous) |prev|
            prev.y.read(&self.y).* + prev.height.read(&self.y).*
        else if (self.parent_block) |pb|
            pb.y.read(&self.y).* + tableOfContentsHeaderHeight(pb.node)
        else
            self.document.y.read(&self.y).*;

        // Set x, y, width early so children can read them
        const content_bounds = contentBoundsForNode(self.node, parent_x, parent_width);
        const specified_width = self.specifiedPixelDimension("width", &self.width);
        const specified_height = self.specifiedPixelDimension("height", &self.height);
        self.x.set(content_bounds.x);
        self.y.set(prev_y);
        self.width.set(specified_width orelse content_bounds.width);
        if (engine.collect_hit_test_bounds) {
            if (self.node_ptr) |ptr| try engine.recordFragmentTargets(ptr, prev_y);
        }

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
            if (children_dirty or self.children_version.dirty or self.children.items.len == 0) {
                for (self.children.items) |child| {
                    child.deinit(self.allocator);
                }
                self.children.clearRetainingCapacity();

                switch (self.node) {
                    .element => |e| try self.appendBlockChildren(e.children.items),
                    else => {},
                }
                self.children_epoch += 1;
                self.children_version.set(self.children_epoch);
            }

            {
                var height_deps = std.ArrayList(*ProtectedField(i32)).empty;
                defer height_deps.deinit(self.allocator);
                for (self.children.items) |child| {
                    switch (child) {
                        .block => |b| try height_deps.append(self.allocator, &b.height),
                        .line => |l| try height_deps.append(self.allocator, &l.height),
                    }
                }
                for (height_deps.items) |dep| {
                    self.height.addDependency(dep);
                }
                self.height.addDependency(&self.children_version);
                self.height.frozen_dependencies = true;
            }

            // Layout all children and compute height
            // Use .read() to register invalidation dependencies on children's heights
            var computed_height: i32 = 0;
            _ = self.children_version.read(&self.height);
            for (self.children.items) |child| {
                switch (child) {
                    .block => |b| {
                        try b.layout(engine);
                        computed_height += b.height.read(&self.height).*;
                    },
                    .line => |l| {
                        try l.layout(engine);
                        computed_height += l.height.read(&self.height).*;
                    },
                }
            }
            const auto_height = computed_height + tableOfContentsHeaderHeight(self.node);
            self.height.set(specified_height orelse auto_height);
            self.zoom.set(1.0);

            try recordContentEditableFocusBounds(engine, self);
        } else {
            // Inline layout mode - use the old approach for now
            // TODO: Refactor to populate LineLayout and TextLayout objects
            self.height.frozen_dependencies = false;
            try engine.layoutInlineBlock(self);

            if (self.children.items.len > 0) {
                for (self.children.items) |child| {
                    child.deinit(self.allocator);
                }
                self.children.clearRetainingCapacity();
            }
            self.children_epoch += 1;
            self.children_version.set(self.children_epoch);

            if (specified_height) |height| self.height.set(height);

            try recordContentEditableFocusBounds(engine, self);
            // Height is set by layoutInlineBlock - need to ensure it uses .set()
        }

        // Clear descendant flags after layout pass
        self.has_dirty_descendants = false;
    }

    fn appendBlockChildren(self: *BlockLayout, nodes: []Node) !void {
        var previous: ?*BlockLayout = null;
        var index: usize = 0;
        while (index < nodes.len) {
            // A run-in heading is laid out with the following paragraph rather
            // than as its own block. Once both DOM nodes are in the same
            // anonymous block, normal inline recursion preserves the h6's
            // style while continuing straight into the paragraph text.
            if (isRunInHeadingNode(nodes[index]) and
                index + 1 < nodes.len and isContainerNode(nodes[index + 1], &self.children_version))
            {
                const run_in_nodes = try self.allocator.alloc(*Node, 2);
                errdefer self.allocator.free(run_in_nodes);
                run_in_nodes[0] = &nodes[index];
                run_in_nodes[1] = &nodes[index + 1];
                const child = try BlockLayout.initAnonymous(self.allocator, run_in_nodes, self.document, self, previous);
                try self.children.append(self.allocator, .{ .block = child });
                previous = child;
                index += 2;
                continue;
            }

            if (isContainerNode(nodes[index], &self.children_version)) {
                const child_node = &nodes[index];
                const child = try BlockLayout.init(self.allocator, child_node.*, child_node, self.document, self, previous);
                try self.children.append(self.allocator, .{ .block = child });
                previous = child;
                index += 1;
                continue;
            }

            const start = index;
            while (index < nodes.len and !isContainerNode(nodes[index], &self.children_version)) : (index += 1) {}
            const inline_nodes = try self.allocator.alloc(*Node, index - start);
            errdefer self.allocator.free(inline_nodes);
            for (nodes[start..index], 0..) |*node, output_index| {
                inline_nodes[output_index] = node;
            }
            const child = try BlockLayout.initAnonymous(self.allocator, inline_nodes, self.document, self, previous);
            try self.children.append(self.allocator, .{ .block = child });
            previous = child;
        }
    }

    fn layoutNeeded(self: *const BlockLayout) bool {
        if (self.zoom.dirty) return true;
        if (self.x.dirty) return true;
        if (self.y.dirty) return true;
        if (self.width.dirty) return true;
        if (self.height.dirty) return true;
        if (self.children_version.dirty) return true;
        if (self.has_dirty_descendants) return true;
        return false;
    }

    fn shouldPaint(self: *const BlockLayout) bool {
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
        const cursor_x = text.x.get().* + text.width.get().*;
        const cursor_y = text.y.get().*;
        const cursor_height = text.height.get().*;
        try drawCursor(commands, self.allocator, cursor_x, cursor_y, cursor_height, cursor_color);
        return;
    }

    const glyph = try self.font_manager.getStyledGlyph(
        "X",
        .Normal,
        .Roman,
        self.default_font_size,
        .proportional,
    );
    const cursor_height = self.toLayoutPx(glyph.ascent + glyph.descent);
    try drawCursor(commands, self.allocator, block.x.get().*, block.y.get().*, cursor_height, cursor_color);
}

fn appendListMarker(self: *Layout, commands: *std.ArrayList(DisplayItem), block: *const BlockLayout) !void {
    const element = switch (block.node) {
        .element => |*value| value,
        .text => return,
    };
    if (!isListItemElement(element) or block.height.get().* <= 0) return;

    const marker_x = block.x.get().* - list_item_indent + (list_item_indent - list_marker_size) / 2;
    const marker_y = block.y.get().* + @min(list_marker_top_offset, @max(block.height.get().* - list_marker_size, 0));
    const color = if (element.style) |*style_map|
        if (styleValue(style_map, "color")) |value| parseColor(value) orelse browser.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } else browser.Color{ .r = 0, .g = 0, .b = 0, .a = 255 }
    else
        browser.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

    try commands.append(self.allocator, .{ .rect = .{
        .x1 = marker_x,
        .y1 = marker_y,
        .x2 = marker_x + list_marker_size,
        .y2 = marker_y + list_marker_size,
        .color = self.remapColor(color),
    } });
}

fn appendTableOfContentsHeader(self: *Layout, commands: *std.ArrayList(DisplayItem), block: *const BlockLayout) !void {
    const element = switch (block.node) {
        .element => |*value| value,
        .text => return,
    };
    if (!isTableOfContentsElement(element)) return;

    const x = block.x.get().*;
    const y = block.y.get().*;
    const width = block.width.get().*;
    const background = self.remapColor(.{ .r = 211, .g = 211, .b = 211, .a = 255 });
    try commands.append(self.allocator, .{ .rect = .{
        .x1 = x,
        .y1 = y,
        .x2 = x + width,
        .y2 = y + toc_header_height,
        .color = background,
    } });

    const glyph = try self.font_manager.getStyledGlyph(
        "Table of Contents",
        .Normal,
        .Roman,
        self.scaledFontSize(self.default_font_size),
        .proportional,
    );
    try commands.append(self.allocator, .{ .glyph = .{
        .x = x + 4,
        .y = y + 3,
        .glyph = glyph,
        .color = self.remapColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 }),
    } });
}

fn recordContentEditableFocusBounds(self: *Layout, block: *const BlockLayout) !void {
    if (block.node != .element) return;
    const element = block.node.element;
    if (element.attributes == null) return;
    if (element.attributes.?.get("contenteditable") == null) return;
    const node_ptr = block.node_ptr orelse return;

    var height = block.height.get().*;
    if (height <= 0) {
        const glyph = try self.font_manager.getStyledGlyph(
            "X",
            .Normal,
            .Roman,
            self.default_font_size,
            .proportional,
        );
        height = self.toLayoutPx(glyph.ascent + glyph.descent);
    }

    const block_bounds = Bounds{
        .x = block.x.get().*,
        .y = block.y.get().*,
        .width = block.width.get().*,
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
    self.resetSoftHyphenWord();

    self.line_left = block.x.get().*;
    const block_width = block.width.get().*;
    self.line_right = block.x.get().* + block_width;
    self.cursor_x = self.line_left;
    self.cursor_y = block.y.get().*;
    self.line_direction = textDirectionForBlock(block, self.default_direction);
    self.size = self.default_font_size;
    self.is_bold = false;
    self.is_italic = false;
    self.font_family = .proportional;
    // Centering belongs to the complete title block, not one buffered line.
    // Keeping this state stable lets explicit and automatic line breaks center
    // each completed line independently in flushLine().
    self.is_title = isCenteredTitleBlock(block);
    self.is_superscript = isWithinSuperscriptBlock(block);
    self.is_small_caps = isWithinSmallCapsBlock(block);
    self.text_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }; // Reset to black
    self.is_preformatted = isWithinPreformattedBlock(block);
    self.prev_font_category = null;
    self.current_font_category = .latin;

    // Anonymous blocks represent an inline run beneath a container but do not
    // carry that container as their own node. Seed the inherited family from
    // the parent so bare text siblings receive the same computed face as
    // nested inline elements.
    if (block.inline_nodes != null) {
        if (block.parent_block) |parent| {
            switch (parent.node) {
                .element => |element| {
                    if (element.style) |*style_map| {
                        if (styleValueRead(style_map, "font-family", &block.height)) |family_value| {
                            self.font_family = font.familyFromCss(family_value);
                        }
                    }
                },
                .text => {},
            }
        }
    }

    self.current_display_target = &block.display_list;

    var line_buffer = std.ArrayList(LineItem).empty;
    defer line_buffer.deinit(self.allocator);

    if (block.inline_nodes) |nodes| {
        for (nodes) |node| {
            try self.recurseNode(node.*, node, &line_buffer);
        }
    } else switch (block.node) {
        .text => |t| {
            try self.handleTextToken(t.text, &line_buffer, null);
        },
        .element => |e| {
            // Apply CSS styles for this block element
            try self.applyNodeStyles(e, &line_buffer);

            // Handle br tag for line breaks
            if (std.mem.eql(u8, e.tag, "br")) {
                try self.breakExplicitLine(&line_buffer);
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
    const computed_height = self.cursor_y - block.y.get().*;
    block.height.set(if (computed_height < 0) 0 else computed_height);
    block.zoom.set(1.0);
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
            if (block.height.get().* <= 0) return;

            // Check for background-color in the style attribute
            const bgcolor_str = if (e.style) |*style_map|
                styleValue(style_map, "background-color")
            else
                null;

            // Check for border-radius
            const border_radius_str = if (e.style) |*style_map|
                styleValue(style_map, "border-radius")
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

                const block_width = block.width.get().*;
                const block_x = block.x.get().*;
                const block_y = block.y.get().*;
                const block_height = block.height.get().*;
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
    const content_height = documentScrollHeight(document.height.get().*);

    if (self.document_color_scheme_dark) {
        const width = self.layoutWindowWidth();
        const bg_color = if (self.accessibility.dark_palette) |palette|
            palette.background
        else
            browser.Color{ .r = 18, .g = 18, .b = 18, .a = 255 };
        const bg = DisplayItem{ .rect = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = width,
            .y2 = content_height,
            .color = bg_color,
        } };
        try self.display_list.append(self.allocator, bg);
    }

    for (document.children.items) |child| {
        try paintBlockTree(self, child);
    }

    self.content_height = content_height;
    return try self.display_list.toOwnedSlice(self.allocator);
}

test "document scroll height includes Chapter 5 page padding" {
    try std.testing.expectEqual(@as(i32, 136), documentScrollHeight(100));
    try std.testing.expectEqual(@as(i32, 36), documentScrollHeight(0));
    try std.testing.expectEqual(@as(i32, 36), documentScrollHeight(-100));
    try std.testing.expectEqual(std.math.maxInt(i32), documentScrollHeight(std.math.maxInt(i32)));
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
    try appendTableOfContentsHeader(self, &commands, block);

    // Add the block's display items (from children like text, etc.)
    for (block.display_list.items) |item| {
        try commands.append(self.allocator, item);
    }
    try appendListMarker(self, &commands, block);

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

fn writeBlockDebug(writer: *std.Io.Writer, block: *const BlockLayout, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.print(
        "block x={d} y={d} width={d} height={d}\n",
        .{ block.x.get().*, block.y.get().*, block.width.get().*, block.height.get().* },
    );
    for (block.children.items) |child| switch (child) {
        .block => |nested| try writeBlockDebug(writer, nested, indent + 2),
        .line => |line| try writeLineDebug(writer, line, indent + 2),
    };
}

fn writeLineDebug(writer: *std.Io.Writer, line: *const LineLayout, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.print(
        "line x={d} y={d} width={d} height={d}\n",
        .{ line.x.get().*, line.y.get().*, line.width.get().*, line.height.get().* },
    );
    for (line.children.items) |text| {
        try writeIndent(writer, indent + 2);
        try writer.print(
            "text {s} x={d} y={d} width={d} height={d}\n",
            .{ text.word, text.x.get().*, text.y.get().*, text.width.get().*, text.height.get().* },
        );
    }
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    var remaining = indent;
    while (remaining > 0) : (remaining -= 1) try writer.writeByte(' ');
}

/// Serialize paint commands without compositing or rasterizing them. Pointer
/// fields and pixel buffers are intentionally omitted so output is stable.
pub fn writeDisplayListDebug(writer: *std.Io.Writer, items: []const DisplayItem) !void {
    try writeDisplayItemsDebug(writer, items, 0);
}

fn writeDisplayItemsDebug(writer: *std.Io.Writer, items: []const DisplayItem, indent: usize) !void {
    for (items) |item| {
        try writeIndent(writer, indent);
        switch (item) {
            .glyph => |glyph| try writer.print("glyph x={d} y={d} width={d} height={d} color=#{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ glyph.x, glyph.y, glyph.glyph.w, glyph.glyph.h, glyph.color.r, glyph.color.g, glyph.color.b, glyph.color.a }),
            .rect => |rect| try writer.print("rect x1={d} y1={d} x2={d} y2={d} color=#{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ rect.x1, rect.y1, rect.x2, rect.y2, rect.color.r, rect.color.g, rect.color.b, rect.color.a }),
            .image => |image| try writer.print("image x1={d} y1={d} x2={d} y2={d} source_width={d} source_height={d} opacity={d}\n", .{ image.x1, image.y1, image.x2, image.y2, image.source_width, image.source_height, image.opacity }),
            .iframe => |iframe| try writer.print("iframe left={d} top={d} right={d} bottom={d}\n", .{ iframe.rect.left, iframe.rect.top, iframe.rect.right, iframe.rect.bottom }),
            .rounded_rect => |rect| try writer.print("rounded-rect x1={d} y1={d} x2={d} y2={d} radius={d} color=#{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ rect.x1, rect.y1, rect.x2, rect.y2, rect.radius, rect.color.r, rect.color.g, rect.color.b, rect.color.a }),
            .line => |line| try writer.print("line x1={d} y1={d} x2={d} y2={d} thickness={d} color=#{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ line.x1, line.y1, line.x2, line.y2, line.thickness, line.color.r, line.color.g, line.color.b, line.color.a }),
            .outline => |outline| try writer.print("outline left={d} top={d} right={d} bottom={d} thickness={d} color=#{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ outline.rect.left, outline.rect.top, outline.rect.right, outline.rect.bottom, outline.thickness, outline.color.r, outline.color.g, outline.color.b, outline.color.a }),
            .blend => |blend| {
                try writer.print("blend opacity={d} mode={s}\n", .{ blend.opacity, blend.blend_mode orelse "normal" });
                try writeDisplayItemsDebug(writer, blend.children, indent + 2);
            },
            .transform => |transform| {
                try writer.print("transform x={d} y={d}\n", .{ transform.translate_x, transform.translate_y });
                try writeDisplayItemsDebug(writer, transform.children, indent + 2);
            },
            .draw_composited_layer => try writer.writeAll("composited-layer\n"),
        }
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
    try appendTableOfContentsHeader(self, &block_commands, block);

    // Add display items (from text, etc.)
    for (block.display_list.items) |item| {
        try block_commands.append(self.allocator, item);
    }
    try appendListMarker(self, &block_commands, block);

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
        if (elem.style) |*style_map| {
            // Check for active opacity animation first
            if (elem.animations) |animations| {
                if (animations.get("opacity")) |anim| {
                    opacity = anim.getValue();
                    opacity = @max(0.0, @min(1.0, opacity)); // Clamp to valid range
                }
            }
            // Fall back to style value if no animation
            if (opacity == 1.0) {
                if (styleValue(style_map, "opacity")) |op_str| {
                    opacity = std.fmt.parseFloat(f64, op_str) catch 1.0;
                    opacity = @max(0.0, @min(1.0, opacity)); // Clamp to valid range
                }
            }
            if (styleValue(style_map, "mix-blend-mode")) |blend_str| {
                blend_mode = blend_str;
            }
            if (std.mem.eql(u8, styleValue(style_map, "overflow") orelse "visible", "clip")) {
                should_clip = true;
                if (styleValue(style_map, "border-radius")) |radius_str| {
                    // Parse border-radius (e.g., "30px" -> 30.0)
                    if (std.mem.endsWith(u8, radius_str, "px")) {
                        const radius_value = radius_str[0 .. radius_str.len - 2];
                        border_radius = std.fmt.parseFloat(f64, radius_value) catch 0.0;
                    }
                }
            }
            // Parse transform: translate(xpx, ypx)
            if (styleValue(style_map, "transform")) |transform_str| {
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

        const block_width = block.width.get().*;
        const block_x = block.x.get().*;
        const block_y = block.y.get().*;
        const block_height = block.height.get().*;
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
            if (block.height.get().* <= 0) return;

            // Check for background-color in the style attribute
            const bgcolor_str = if (e.style) |*style_map|
                styleValue(style_map, "background-color")
            else
                null;

            // Check for border-radius
            const border_radius_str = if (e.style) |*style_map|
                styleValue(style_map, "border-radius")
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

                const block_width = block.width.get().*;
                const block_x = block.x.get().*;
                const block_y = block.y.get().*;
                const block_height = block.height.get().*;
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
