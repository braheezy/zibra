//! Builds layout trees and paint commands from Zibra's styled DOM nodes.
//!
//! This module owns block and inline layout, text and replaced-element
//! measurement, hit-test bounds, incremental invalidation, and generation of
//! the display items consumed by the browser compositor.

const std = @import("std");
const font = @import("font.zig");
const forced_colors = @import("forced_colors.zig");
const browser = @import("../root.zig");
const grapheme = @import("grapheme");
const parser = @import("../../document/parser.zig");
const dom_focus = @import("../../document/focus.zig");
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
const button_padding = 4;
const min_effective_zoom: f32 = 0.01;
const max_effective_zoom: f32 = 1024.0;

const ContentBounds = struct {
    x: i32,
    width: i32,
};

const EmbeddedBlockBox = struct {
    x: i32,
    y: i32,
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

/// Parse the standardized number/percentage grammar for `zoom`. Invalid,
/// negative, and zero values use the initial factor of one; zero's behavior is
/// the CSS compatibility rule rather than a hidden subtree.
fn parseCssZoom(value: []const u8) f32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or
        std.ascii.eqlIgnoreCase(trimmed, "normal") or
        std.ascii.eqlIgnoreCase(trimmed, "reset"))
    {
        return 1.0;
    }

    const percentage = std.mem.endsWith(u8, trimmed, "%");
    const number = if (percentage)
        std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n")
    else
        trimmed;
    const parsed = std.fmt.parseFloat(f32, number) catch return 1.0;
    if (!std.math.isFinite(parsed) or parsed <= 0.0) return 1.0;
    return if (percentage) parsed / 100.0 else parsed;
}

/// Compute the authored effective zoom at `node` from live computed styles.
/// Frame code uses this before child layout so iframe documents inherit the
/// same factor as the containing replaced element.
pub fn effectiveCssZoomForNode(node: *const Node) f32 {
    var result: f32 = 1.0;
    var current: ?*const Node = node;
    while (current) |candidate| {
        current = switch (candidate.*) {
            .element => |*element| next: {
                if (element.style) |*styles| {
                    if (styleValue(styles, "zoom")) |value| {
                        result = combinedEffectiveZoom(result, parseCssZoom(value));
                    }
                }
                break :next element.parent;
            },
            .text => |*text| text.parent,
        };
    }
    return result;
}

fn combinedEffectiveZoom(parent_zoom: f32, local_zoom: f32) f32 {
    const parent = if (std.math.isFinite(parent_zoom) and parent_zoom > 0.0) parent_zoom else 1.0;
    const local = if (std.math.isFinite(local_zoom) and local_zoom > 0.0) local_zoom else 1.0;
    return std.math.clamp(parent * local, min_effective_zoom, max_effective_zoom);
}

/// Convert an authored CSS-pixel length into the page's layout coordinate
/// space. Accessibility zoom is applied later by raster, while the ratio here
/// bakes only subtree zoom into geometry. Signed values support translations.
fn scaleCssPixel(value: i32, effective_zoom: f32, page_zoom: f32) i32 {
    const page = if (std.math.isFinite(page_zoom) and page_zoom > 0.0) page_zoom else 1.0;
    const effective = if (std.math.isFinite(effective_zoom) and effective_zoom > 0.0)
        effective_zoom
    else
        page;
    const scaled = @as(f64, @floatFromInt(value)) *
        (@as(f64, effective) / @as(f64, page));
    return @intFromFloat(std.math.clamp(
        scaled,
        @as(f64, @floatFromInt(std.math.minInt(i32))),
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    ));
}

pub fn scaleCssPixelByFactor(value: i32, factor: f32) i32 {
    return scaleCssPixel(value, factor, 1.0);
}

fn scaleCssFloat(value: f64, effective_zoom: f32, page_zoom: f32) f64 {
    const page = if (std.math.isFinite(page_zoom) and page_zoom > 0.0) page_zoom else 1.0;
    const effective = if (std.math.isFinite(effective_zoom) and effective_zoom > 0.0)
        effective_zoom
    else
        page;
    return value * (@as(f64, effective) / @as(f64, page));
}

fn tableOfContentsHeaderHeight(node: Node, effective_zoom: f32, page_zoom: f32) i32 {
    return switch (node) {
        .element => |element| if (isTableOfContentsElement(&element))
            scaleCssPixel(toc_header_height, effective_zoom, page_zoom)
        else
            0,
        .text => 0,
    };
}

fn listItemContentBounds(parent_x: i32, parent_width: i32, indent: i32) ContentBounds {
    return .{
        .x = parent_x + indent,
        .width = @max(parent_width - indent, 0),
    };
}

fn contentBoundsForNode(node: Node, parent_x: i32, parent_width: i32, indent: i32) ContentBounds {
    switch (node) {
        .element => |element| {
            if (isListItemElement(&element)) return listItemContentBounds(parent_x, parent_width, indent);
        },
        .text => {},
    }
    return .{ .x = parent_x, .width = parent_width };
}

/// Parse the subset of CSS lengths supported by block dimensions. `auto`,
/// unsupported units, negative lengths, and invalid values use auto layout.
fn parseCssPixelLength(value: []const u8) ?i32 {
    const pixels = parser.parsePixelLength(value) orelse return null;
    return parser.pixelLengthToLayoutPixels(pixels);
}

fn animatedPixelDimension(element: *const parser.Element, property: []const u8) ?i32 {
    const animations = element.animations orelse return null;
    const animation = animations.get(property) orelse return null;
    return switch (animation) {
        .pixel => |pixel| pixel.layoutPixels(),
        .numeric, .color, .transform => null,
    };
}

fn resolvedPixelDimension(
    element: *const parser.Element,
    style_map: *const parser.StyleMap,
    property: []const u8,
) ?i32 {
    return animatedPixelDimension(element, property) orelse
        if (styleValue(style_map, property)) |value| parseCssPixelLength(value) else null;
}

/// Parse the single-radius subset supported by paint and hit testing. Invalid,
/// negative, and non-pixel radii fall back to a square box.
fn parseCssPixelRadius(value: []const u8) f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 2 or !std.ascii.eqlIgnoreCase(trimmed[trimmed.len - 2 ..], "px")) return 0;

    const number = std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t\r\n");
    if (number.len == 0) return 0;
    const radius = std.fmt.parseFloat(f64, number) catch return 0;
    return if (std.math.isFinite(radius) and radius > 0) radius else 0;
}

fn appendBackgroundBox(
    commands: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    radius: f64,
    color: browser.Color,
    source: ?browser.DisplayItemSource,
) !void {
    if (color.a == 0) return;
    if (radius > 0) {
        try commands.append(allocator, .{ .rounded_rect = .{
            .x1 = x,
            .y1 = y,
            .x2 = x + width,
            .y2 = y + height,
            .radius = radius,
            .color = color,
            .source = source,
        } });
    } else {
        try commands.append(allocator, .{ .rect = .{
            .x1 = x,
            .y1 = y,
            .x2 = x + width,
            .y2 = y + height,
            .color = color,
            .source = source,
        } });
    }
}

/// Wrap one control's complete painted payload in its rounded hit shape.
/// Non-painting group metadata constrains glyph and descendant-command hits
/// that would otherwise restore the square containing rectangle after the
/// rounded background itself missed.
fn appendRoundedControlGroup(
    destination: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    items: *std.ArrayList(DisplayItem),
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    radius: f64,
    source: ?browser.DisplayItemSource,
) !void {
    const children = try items.toOwnedSlice(allocator);
    var children_owned = true;
    errdefer if (children_owned) DisplayItem.freeList(allocator, children);

    try destination.append(allocator, .{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .hit_clip = .{
            .x1 = x,
            .y1 = y,
            .x2 = x + width,
            .y2 = y + height,
            .radius = radius,
        },
        .children = children,
        .needs_compositing = false,
        .source = source,
    } });
    children_owned = false;
}

test "control backgrounds preserve CSS border radius in hit geometry" {
    try std.testing.expectEqual(@as(f64, 12.5), parseCssPixelRadius(" 12.5px "));
    try std.testing.expectEqual(@as(f64, 0), parseCssPixelRadius("-4px"));
    try std.testing.expectEqual(@as(f64, 0), parseCssPixelRadius("50%"));

    var commands = std.ArrayList(DisplayItem).empty;
    defer commands.deinit(std.testing.allocator);
    var origin: u8 = 0;
    try appendBackgroundBox(
        &commands,
        std.testing.allocator,
        0,
        0,
        100,
        40,
        20,
        .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .{ .layout = @ptrCast(&origin), .node = null },
    );

    try std.testing.expect(commands.items[0] == .rounded_rect);
    try std.testing.expect(DisplayItem.hitTestDevice(commands.items, 50, 20, 1.0) != null);
    try std.testing.expect(DisplayItem.hitTestDevice(commands.items, 1, 1, 1.0) == null);

    // A control's text/checkmark commands carry the same source and may cover
    // the square corner. The group clip must still keep that corner inert.
    var control_content = std.ArrayList(DisplayItem).empty;
    defer {
        DisplayItem.freeItems(std.testing.allocator, control_content.items);
        control_content.deinit(std.testing.allocator);
    }
    try appendBackgroundBox(
        &control_content,
        std.testing.allocator,
        0,
        0,
        100,
        40,
        0,
        .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .{ .layout = @ptrCast(&origin), .node = null },
    );
    var grouped = std.ArrayList(DisplayItem).empty;
    defer {
        DisplayItem.freeItems(std.testing.allocator, grouped.items);
        grouped.deinit(std.testing.allocator);
    }
    try appendRoundedControlGroup(
        &grouped,
        std.testing.allocator,
        &control_content,
        0,
        0,
        100,
        40,
        20,
        .{ .layout = @ptrCast(&origin), .node = null },
    );
    try std.testing.expect(grouped.items[0] == .blend);
    try std.testing.expect(grouped.items[0].blend.hit_clip != null);
    try std.testing.expect(grouped.items[0].blend.blend_mode == null);
    try std.testing.expect(!grouped.items[0].blend.needs_compositing);
    try std.testing.expect(DisplayItem.hitTestDevice(grouped.items, 50, 20, 1.0) != null);
    try std.testing.expect(DisplayItem.hitTestDevice(grouped.items, 1, 1, 1.0) == null);

    const cloned = try cloneDisplayListOwned(std.testing.allocator, grouped.items);
    defer DisplayItem.freeList(std.testing.allocator, cloned);
    try std.testing.expect(cloned[0].blend.hit_clip != null);
    try std.testing.expect(DisplayItem.hitTestDevice(cloned, 1, 1, 1.0) == null);
}

fn drawCursor(
    commands: *std.ArrayList(DisplayItem),
    allocator: std.mem.Allocator,
    x: i32,
    y: i32,
    height: i32,
    color: browser.Color,
    source: ?browser.DisplayItemSource,
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
            .source = source,
        },
    });
}

fn isNodeWithin(candidate: *Node, root: *Node) bool {
    var current: ?*Node = candidate;
    while (current) |node| {
        if (node == root) return true;
        current = switch (node.*) {
            .text => |text| text.parent,
            .element => |element| element.parent,
        };
    }
    return false;
}

fn LayoutNodeResolver(comptime LayoutObject: type) type {
    return struct {
        fn resolve(raw_layout: *const anyopaque, fragment: ?*Node) ?*Node {
            const layout_object: *const LayoutObject = @ptrCast(@alignCast(raw_layout));
            const root: ?*Node = layout_object.node_ptr;
            if (fragment) |candidate| {
                const source_root = root orelse return null;
                return if (isNodeWithin(candidate, source_root)) candidate else null;
            }
            return root;
        }
    };
}

fn resolveBlockLayoutNode(raw_layout: *const anyopaque, fragment: ?*Node) ?*Node {
    const block: *const BlockLayout = @ptrCast(@alignCast(raw_layout));
    if (fragment) |candidate| {
        if (block.node_ptr) |root| {
            return if (isNodeWithin(candidate, root)) candidate else null;
        }
        if (block.inline_nodes) |roots| {
            for (roots) |root| {
                if (isNodeWithin(candidate, root)) return candidate;
            }
        }
        return null;
    }
    return block.node_ptr;
}

fn displaySource(layout_object: anytype, node: ?*Node) browser.DisplayItemSource {
    const LayoutObject = @TypeOf(layout_object.*);
    const Resolver = LayoutNodeResolver(LayoutObject);
    return .{
        .layout = @ptrCast(layout_object),
        .node = node,
        .layout_node_resolver = if (LayoutObject == BlockLayout)
            &resolveBlockLayoutNode
        else
            &Resolver.resolve,
    };
}

fn opaqueElementForNode(node_ptr: ?*Node) ?*anyopaque {
    const node = node_ptr orelse return null;
    return switch (node.*) {
        .element => |*element| @ptrCast(element),
        else => null,
    };
}

/// Parse a translate transform value like "translate(10px, 20px)" into x and y offsets
/// Returns null if parsing fails
fn parseTranslate(value: []const u8) ?struct { x: i32, y: i32 } {
    const pixels = (parser.parseTranslate(value) orelse return null).layoutPixels();
    return .{ .x = pixels.x, .y = pixels.y };
}

/// Parse the supported CSS filter syntax. Zibra intentionally implements one
/// filter function for now, so unsupported chains are ignored as a whole.
pub fn parseBlurFilter(value: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "none")) return null;

    const prefix = "blur(";
    if (!std.mem.startsWith(u8, trimmed, prefix) or !std.mem.endsWith(u8, trimmed, ")")) return null;
    const argument = std.mem.trim(u8, trimmed[prefix.len .. trimmed.len - 1], " \t\r\n");
    if (argument.len == 0) return null;

    const number = if (std.mem.endsWith(u8, argument, "px"))
        std.mem.trim(u8, argument[0 .. argument.len - 2], " \t\r\n")
    else if (std.mem.eql(u8, argument, "0"))
        argument
    else
        return null;
    const radius = std.fmt.parseFloat(f64, number) catch return null;
    if (!std.math.isFinite(radius) or radius < 0) return null;
    return radius;
}

test "blur filter parser accepts pixel lengths and rejects unsupported filters" {
    try std.testing.expectEqual(@as(?f64, 4.5), parseBlurFilter(" blur( 4.5px ) "));
    try std.testing.expectEqual(@as(?f64, 0.0), parseBlurFilter("blur(0)"));
    try std.testing.expect(parseBlurFilter("none") == null);
    try std.testing.expect(parseBlurFilter("blur(-1px)") == null);
    try std.testing.expect(parseBlurFilter("grayscale(1)") == null);
    try std.testing.expect(parseBlurFilter("blur(2em)") == null);
    try std.testing.expect(parseBlurFilter("blur(2px) opacity(.5)") == null);
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

    /// Inline embed records are destroyed as soon as their completed line is
    /// painted. Keep their dependency graph entirely self-contained: a
    /// persistent BlockLayout is responsible for subscribing to DOM styles.
    fn setupDependencies(self: *EmbedLayout) void {
        if (self.deps_initialized) return;
        self.deps_initialized = true;

        self.zoom.freezeDependencies();

        self.font_stub.addDependency(&self.zoom);
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
        _ = parent_block;
        _ = style_map;
        layout.embed.setupDependencies();
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
    css_zoom: f32 = 1.0,

    fn init(
        allocator: std.mem.Allocator,
        layout_width: i32,
        layout_height: i32,
        parent_block: ?*BlockLayout,
        style_map: ?*const parser.StyleMap,
        zoom_value: f32,
        page_zoom: f32,
    ) IframeLayout {
        var layout = IframeLayout{
            .embed = EmbedLayout.init(allocator),
            .bgcolor = .{ .r = 0xf2, .g = 0xf2, .b = 0xf2, .a = 0xff },
            .border_color = .{ .r = 0x33, .g = 0x33, .b = 0x33, .a = 0xff },
            .border_thickness = @max(scaleCssPixel(1, zoom_value, page_zoom), 1),
            .css_zoom = zoom_value / page_zoom,
        };
        _ = parent_block;
        _ = style_map;
        layout.embed.setupDependencies();
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
        source: ?browser.DisplayItemSource,
    ) !void {
        const width_value = self.embed.width.get().*;
        const height_value = self.embed.height.get().*;
        const bg = engine.remapColor(self.bgcolor, .background);
        if (bg.a > 0) {
            try commands.append(engine.allocator, DisplayItem{
                .rect = .{
                    .x1 = x,
                    .y1 = y,
                    .x2 = x + width_value,
                    .y2 = y + height_value,
                    .color = bg,
                    .source = source,
                },
            });
        }

        const border = engine.remapColor(self.border_color, .border);
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
                    .source = source,
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
    button: ButtonLayout,
    image: ImageLayout,
    iframe: IframeLayout,

    fn deinit(self: *LineItemPayload) void {
        switch (self.*) {
            .glyph => {},
            .input => |*input_payload| input_payload.deinit(),
            .button => |*button_payload| button_payload.deinit(),
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

const visited_link_color = browser.Color{ .r = 128, .g = 0, .b = 128, .a = 255 };

/// Return the default visited-link override for text produced anywhere below
/// an annotated anchor. The walk is synchronous and borrows the current DOM
/// generation only for the duration of paint.
pub fn nodeIsInVisitedLink(node_ptr: ?*const Node) bool {
    var current = node_ptr;
    while (current) |node| {
        switch (node.*) {
            .element => |*element| {
                if (std.mem.eql(u8, element.tag, "a") and element.is_visited) {
                    return true;
                }
                current = element.parent;
            },
            .text => |*text| current = text.parent,
        }
    }
    return false;
}

pub fn textColorForNode(node_ptr: ?*const Node, normal_color: browser.Color) browser.Color {
    return if (nodeIsInVisitedLink(node_ptr)) visited_link_color else normal_color;
}

fn textColorRoleForNode(node_ptr: ?*const Node) forced_colors.Role {
    var current = node_ptr;
    while (current) |node| {
        switch (node.*) {
            .element => |*element| {
                if (std.mem.eql(u8, element.tag, "a")) {
                    return if (element.is_visited) .visited_link else .link;
                }
                current = element.parent;
            },
            .text => |*text_node| current = text_node.parent,
        }
    }
    return .text;
}

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

/// A layout-tree hit carries coordinates local to the object that supplied
/// the DOM node. Worker-owned callers can reuse it for clicking or other point
/// queries without reconstructing an absolute rectangle per object.
pub const LayoutHitResult = struct {
    node: *Node,
    local_x: i32,
    local_y: i32,
};

const HitPoint = struct {
    x: i32,
    y: i32,
};

fn subtractHitOffset(point: HitPoint, x: i32, y: i32) HitPoint {
    return .{
        .x = @intCast(std.math.clamp(
            @as(i64, point.x) - @as(i64, x),
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        )),
        .y = @intCast(std.math.clamp(
            @as(i64, point.y) - @as(i64, y),
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        )),
    };
}

fn addHitOffset(point: HitPoint, x: i32, y: i32) HitPoint {
    return .{
        .x = @intCast(std.math.clamp(
            @as(i64, point.x) + @as(i64, x),
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        )),
        .y = @intCast(std.math.clamp(
            @as(i64, point.y) + @as(i64, y),
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        )),
    };
}

fn relativeHitOffset(child: i32, parent: i32) i32 {
    return @intCast(std.math.clamp(
        @as(i64, child) - @as(i64, parent),
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

fn pointInLocalBox(point: HitPoint, width: i32, height: i32) bool {
    return width > 0 and height > 0 and
        point.x >= 0 and point.x < width and
        point.y >= 0 and point.y < height;
}

fn pointInLocalRoundedBox(point: HitPoint, width: i32, height: i32, radius_value: f64) bool {
    if (!pointInLocalBox(point, width, height)) return false;
    const radius = @min(
        @max(radius_value, 0.0),
        @min(
            @as(f64, @floatFromInt(width)) / 2.0,
            @as(f64, @floatFromInt(height)) / 2.0,
        ),
    );
    if (radius <= 0.0) return true;

    const px: f64 = @floatFromInt(point.x);
    const py: f64 = @floatFromInt(point.y);
    const right: f64 = @floatFromInt(width);
    const bottom: f64 = @floatFromInt(height);
    if (px >= radius and px < right - radius) return true;
    if (py >= radius and py < bottom - radius) return true;

    const center_x = if (px < radius) radius else right - radius;
    const center_y = if (py < radius) radius else bottom - radius;
    const dx = px - center_x;
    const dy = py - center_y;
    return dx * dx + dy * dy <= radius * radius;
}

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

fn setTestStyleValue(
    allocator: std.mem.Allocator,
    node: *Node,
    property: []const u8,
    value: []const u8,
) !void {
    std.debug.assert(node.* == .element);
    if (node.element.style == null) node.element.style = parser.StyleMap.init(allocator);
    var field = ProtectedField([]const u8).init(allocator, value);
    field.set(value);
    node.element.style.?.put(property, field) catch |err| {
        field.deinit();
        return err;
    };
}

fn setTestDisplay(allocator: std.mem.Allocator, node: *Node, value: []const u8) !void {
    return setTestStyleValue(allocator, node, "display", value);
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

    const bounds = listItemContentBounds(13, 100, list_item_indent);
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

test "CSS zoom parses numbers and percentages and composes nested lengths" {
    try std.testing.expectEqual(@as(f32, 1.5), parseCssZoom("1.5"));
    try std.testing.expectEqual(@as(f32, 1.75), parseCssZoom(" 175% "));
    try std.testing.expectEqual(@as(f32, 1.0), parseCssZoom("0"));
    try std.testing.expectEqual(@as(f32, 1.0), parseCssZoom("0%"));
    try std.testing.expectEqual(@as(f32, 1.0), parseCssZoom("-2"));
    try std.testing.expectEqual(@as(f32, 1.0), parseCssZoom("bogus"));

    const accessibility_zoom: f32 = 1.25;
    const outer = combinedEffectiveZoom(accessibility_zoom, parseCssZoom("200%"));
    const inner = combinedEffectiveZoom(outer, parseCssZoom("1.5"));
    try std.testing.expectEqual(@as(f32, 2.5), outer);
    try std.testing.expectEqual(@as(f32, 3.75), inner);
    try std.testing.expectEqual(@as(i32, 60), scaleCssPixel(20, inner, accessibility_zoom));
    try std.testing.expectEqual(@as(i32, -30), scaleCssPixel(-10, inner, accessibility_zoom));
}

test "effective CSS zoom follows ancestors and invalidates block layout" {
    const allocator = std.testing.allocator;
    var outer = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer outer.deinit(allocator);
    try setTestStyleValue(allocator, &outer, "zoom", "2");

    var middle = Node{ .element = try parser.Element.init(allocator, "section", &outer) };
    defer middle.deinit(allocator);
    try setTestStyleValue(allocator, &middle, "zoom", "150%");

    var leaf = Node{ .element = try parser.Element.init(allocator, "span", &middle) };
    defer leaf.deinit(allocator);
    try std.testing.expectEqual(@as(f32, 3.0), effectiveCssZoomForNode(&leaf));

    const document = try DocumentLayout.init(allocator, &outer);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const block = try BlockLayout.init(allocator, middle, &middle, document, null, null);
    try document.children.append(allocator, block);
    block.zoom.set(1.0);
    middle.element.style.?.getPtr("zoom").?.set("175%");
    try std.testing.expect(block.zoom.dirty);
}

test "temporary rich-button dependencies target the persistent containing block" {
    const allocator = std.testing.allocator;

    var document_node = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer document_node.deinit(allocator);
    const document = try DocumentLayout.init(allocator, &document_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    const parent = try BlockLayout.init(
        allocator,
        document_node,
        &document_node,
        document,
        null,
        null,
    );
    try document.children.append(allocator, parent);
    parent.zoom.set(1.0);
    parent.height.set(0);

    var button = Node{ .element = try parser.Element.init(allocator, "button", null) };
    defer button.deinit(allocator);
    try setTestStyleValue(allocator, &button, "zoom", "2");

    var child = Node{ .element = try parser.Element.init(allocator, "div", &button) };
    var child_owned = true;
    errdefer if (child_owned) child.deinit(allocator);
    try setTestStyleValue(allocator, &child, "display", "block");
    try setTestStyleValue(allocator, &child, "zoom", "150%");
    try button.element.children.append(allocator, child);
    child_owned = false;
    parser.fixParentPointers(&button, null);

    const temporary = try BlockLayout.initRichButton(
        allocator,
        &button,
        document,
        parent,
        200,
        2.0,
    );
    var temporary_owned = true;
    errdefer if (temporary_owned) {
        temporary.deinit();
        allocator.destroy(temporary);
    };
    try temporary.appendBlockChildren(button.element.children.items);

    try std.testing.expect(!temporary.persistent_dependencies);
    try std.testing.expect(!temporary.children.items[0].block.persistent_dependencies);
    try std.testing.expectEqual(
        @as(usize, 1),
        button.element.style.?.getPtr("zoom").?.invalidations.count(),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        button.element.children.items[0].element.style.?.getPtr("display").?.invalidations.count(),
    );
    try std.testing.expectEqual(@as(usize, 0), parent.zoom.invalidations.count());

    temporary.deinit();
    allocator.destroy(temporary);
    temporary_owned = false;

    // These writes must not call through a retired temporary BlockLayout.
    button.element.style.?.getPtr("zoom").?.set("175%");
    button.element.children.items[0].element.style.?.getPtr("display").?.set("inline");
    button.element.children.items[0].element.style.?.getPtr("zoom").?.set("125%");
    parent.zoom.set(1.25);
    try std.testing.expect(parent.height.dirty);
}

test "animated width changes the word wrapping threshold" {
    var animation = parser.PixelAnimation.initWithEasing(100, 200, 2, .linear);
    try std.testing.expect(wordNeedsNewLine(70, 50, animation.layoutPixels()));
    _ = animation.advance();
    _ = animation.advance();
    try std.testing.expect(!wordNeedsNewLine(70, 50, animation.layoutPixels()));
}

test "active layout suppresses reentrant owner-wide invalidation" {
    const allocator = std.testing.allocator;
    var block: BlockLayout = undefined;
    block.in_layout = true;
    block.x = ProtectedField(i32).init(allocator, 10);
    defer block.x.deinit();
    block.width = ProtectedField(i32).init(allocator, 100);
    defer block.width.deinit();
    block.x.set(10);
    block.width.set(100);
    block.width.setOwner(&block, BlockLayout.markOpaque);

    // A child metric may dirty the parent's aggregate while that parent is
    // already recomputing. Only that aggregate stays dirty; the owner callback
    // must not redirty x/width before the next sibling reads them.
    block.width.mark();
    try std.testing.expect(block.width.dirty);
    try std.testing.expect(!block.x.dirty);
}

test "table of contents navigation reserves a header row" {
    const allocator = std.testing.allocator;
    var toc = Node{ .element = try parser.Element.init(allocator, "nav id=toc", null) };
    defer toc.deinit(allocator);
    try std.testing.expect(isTableOfContentsElement(&toc.element));
    try std.testing.expectEqual(toc_header_height, tableOfContentsHeaderHeight(toc, 1.0, 1.0));

    var ordinary_nav = Node{ .element = try parser.Element.init(allocator, "nav id=links", null) };
    defer ordinary_nav.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 0), tableOfContentsHeaderHeight(ordinary_nav, 2.0, 1.0));
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
// Total device-pixel scale for the inline subtree currently being measured:
// accessibility zoom multiplied by every applicable authored `zoom` value.
effective_zoom: f32 = 1.0,
// Zoom inherited across a nested browsing-context boundary. Root documents
// use one; iframe documents receive the containing iframe's effective factor.
frame_css_zoom: f32 = 1.0,
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
    effective_zoom: f32,
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
        .effective_zoom = self.effective_zoom,
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
    self.effective_zoom = snapshot.effective_zoom;
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

fn effectiveZoom(self: *const Layout) f32 {
    return if (std.math.isFinite(self.effective_zoom) and self.effective_zoom > 0.0)
        self.effective_zoom
    else
        self.zoom();
}

fn scaleActiveCssPixel(self: *const Layout, css_px: i32) i32 {
    return scaleCssPixel(css_px, self.effectiveZoom(), self.zoom());
}

fn scaleActiveCssFloat(self: *const Layout, css_px: f64) f64 {
    return scaleCssFloat(css_px, self.effectiveZoom(), self.zoom());
}

fn scaledFontSize(self: *const Layout, css_size: i32) i32 {
    const scaled = scaleCssPixel(css_size, self.effectiveZoom(), 1.0);
    return if (scaled < 1) 1 else scaled;
}

fn scaledFontSizeForZoom(_: *const Layout, css_size: i32, effective_zoom: f32) i32 {
    const scaled = scaleCssPixel(css_size, effective_zoom, 1.0);
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

fn remapColor(
    self: *const Layout,
    color: browser.Color,
    role: forced_colors.Role,
) browser.Color {
    if (color.a == 0) return color;
    if (self.accessibility.forced_colors) return forced_colors.map(color, role, true);
    if (!self.color_scheme_dark) return color;

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

fn remapTextColor(
    self: *const Layout,
    node_ptr: ?*const Node,
    normal_color: browser.Color,
) browser.Color {
    return self.remapColor(
        textColorForNode(node_ptr, normal_color),
        textColorRoleForNode(node_ptr),
    );
}

test "forced-color text roles distinguish ordinary and visited link descendants" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<a id=fresh>fresh</a><a id=seen>seen</a>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &nodes);

    var fresh_text: ?*Node = null;
    var seen_text: ?*Node = null;
    for (nodes.items) |node| switch (node.*) {
        .element => |*element| {
            if (!std.ascii.eqlIgnoreCase(element.tag, "a")) continue;
            const id = if (element.attributes) |attributes|
                attributes.get("id") orelse continue
            else
                continue;
            if (element.children.items.len == 0) continue;
            if (std.mem.eql(u8, id, "fresh")) {
                fresh_text = &element.children.items[0];
            } else if (std.mem.eql(u8, id, "seen")) {
                element.is_visited = true;
                seen_text = &element.children.items[0];
            }
        },
        .text => {},
    };

    var engine: Layout = undefined;
    engine.accessibility = .{ .forced_colors = true };
    engine.color_scheme_dark = false;
    const author_color = browser.Color{ .r = 119, .g = 120, .b = 121, .a = 255 };

    try std.testing.expectEqual(
        forced_colors.text,
        engine.remapTextColor(null, author_color),
    );
    try std.testing.expectEqual(
        forced_colors.link,
        engine.remapTextColor(fresh_text.?, author_color),
    );
    try std.testing.expectEqual(
        forced_colors.accent,
        engine.remapTextColor(seen_text.?, author_color),
    );
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
                        if (isNonRenderedElement(&e)) return;
                    },
                    else => {},
                }
            }
            try self.handleTextToken(t.text, line_buffer, node_ptr);
        },
        .element => |e| {
            if (isNonRenderedElement(&e)) return;
            // Empty inline anchors have no glyph from which to derive a
            // position, so retain their insertion point explicitly.
            if (self.collect_hit_test_bounds and e.children.items.len == 0) {
                if (node_ptr) |ptr| try self.recordFragmentTargets(ptr, self.cursor_y);
            }
            // Apply CSS styles before processing this element
            try self.applyNodeStyles(e, line_buffer, true);

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
            } else if (std.mem.eql(u8, e.tag, "input")) {
                try self.handleInputElement(node, node_ptr, line_buffer);
            } else if (std.mem.eql(u8, e.tag, "button")) {
                try self.handleButtonElement(node, node_ptr, line_buffer);
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

fn isNonRenderedElement(element: *const parser.Element) bool {
    return isNonRenderTag(element.tag) or element.isHiddenInput();
}

fn handleInputElement(self: *Layout, node: Node, node_ptr: ?*Node, line_buffer: *std.ArrayList(LineItem)) !void {
    const element = switch (node) {
        .element => |e| e,
        else => return,
    };
    if (element.isHiddenInput()) return;
    self.resetSoftHyphenWord();

    var input_layout = InputLayout.init(self.allocator);
    try input_layout.measure(self, element);

    try input_layout.embed.appendInline(self, line_buffer, node_ptr, .{
        .input = input_layout,
    });
}

fn handleButtonElement(
    self: *Layout,
    node: Node,
    node_ptr: ?*Node,
    line_buffer: *std.ArrayList(LineItem),
) anyerror!void {
    const element = switch (node) {
        .element => |e| e,
        else => return,
    };
    const button_node = node_ptr orelse return;
    const parent_block = self.inline_block orelse return;
    self.resetSoftHyphenWord();

    var button_layout = ButtonLayout.init(self.allocator);
    errdefer button_layout.deinit();
    try button_layout.measure(self, button_node, element, parent_block);
    try button_layout.embed.appendInline(self, line_buffer, button_node, .{
        .button = button_layout,
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
        self.scaleActiveCssPixel(self.toLayoutPx(@intCast(data.image.width)))
    else
        0;
    const intrinsic_height: i32 = if (image_data) |data|
        self.scaleActiveCssPixel(self.toLayoutPx(@intCast(data.image.height)))
    else
        0;

    var layout_width: i32 = 0;
    var layout_height: i32 = 0;

    if (width_attr != null and height_attr != null) {
        layout_width = self.scaleActiveCssPixel(width_attr.?);
        layout_height = self.scaleActiveCssPixel(height_attr.?);
    } else if (width_attr != null) {
        layout_width = self.scaleActiveCssPixel(width_attr.?);
        if (intrinsic_width > 0 and intrinsic_height > 0) {
            layout_height = @divTrunc(layout_width * intrinsic_height, intrinsic_width);
        } else {
            layout_height = layout_width;
        }
    } else if (height_attr != null) {
        layout_height = self.scaleActiveCssPixel(height_attr.?);
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
    var image_layout = ImageLayout.init(self.allocator, layout_width, layout_height, image_data, self.inline_block, style_map, self.effectiveZoom());
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

    var layout_width: i32 = self.scaleActiveCssPixel(300);
    var layout_height: i32 = self.scaleActiveCssPixel(150);
    if (width_attr != null) {
        layout_width = self.scaleActiveCssPixel(width_attr.?);
    }
    if (height_attr != null) {
        layout_height = self.scaleActiveCssPixel(height_attr.?);
    }

    if (layout_width <= 0 or layout_height <= 0) return;

    const style_map = if (node == .element) blk: {
        if (node.element.style) |*map| break :blk map;
        break :blk null;
    } else null;
    var iframe_layout = IframeLayout.init(
        self.allocator,
        layout_width,
        layout_height,
        self.inline_block,
        style_map,
        self.effectiveZoom(),
        self.zoom(),
    );
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
    effective_zoom: f32,
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

fn registerStyleDependencies(
    style_map: *const parser.StyleMap,
    target: *ProtectedField(i32),
) void {
    var iterator = @constCast(style_map).iterator();
    while (iterator.next()) |entry| target.addDependency(entry.value_ptr);
}

fn liveBlockElement(block: *const BlockLayout) ?*const parser.Element {
    const node = block.node_ptr orelse return null;
    return switch (node.*) {
        .element => |*element| element,
        .text => null,
    };
}

fn scaleBlockCssPixel(block: *const BlockLayout, value: i32) i32 {
    return scaleCssPixel(value, block.zoom.get().*, block.document.page_zoom);
}

fn scaleBlockCssFloat(block: *const BlockLayout, value: f64) f64 {
    return scaleCssFloat(value, block.zoom.get().*, block.document.page_zoom);
}

/// Resolve the visual translation from the live DOM element. Composited
/// transform animations can advance without rebuilding the layout tree, so a
/// point query must not rely on the node snapshot captured by BlockLayout.
fn blockHitTranslation(block: *const BlockLayout) HitPoint {
    const element = liveBlockElement(block) orelse return .{ .x = 0, .y = 0 };
    if (element.animations) |animations| {
        if (animations.get("transform")) |animation| {
            switch (animation) {
                .transform => |value| {
                    const pixels = value.getValue().layoutPixels();
                    return .{
                        .x = scaleBlockCssPixel(block, pixels.x),
                        .y = scaleBlockCssPixel(block, pixels.y),
                    };
                },
                .numeric, .pixel, .color => {},
            }
        }
    }
    const styles = if (element.style) |*value| value else return .{ .x = 0, .y = 0 };
    const value = styleValue(styles, "transform") orelse return .{ .x = 0, .y = 0 };
    return if (parseTranslate(value)) |translation|
        .{
            .x = scaleBlockCssPixel(block, translation.x),
            .y = scaleBlockCssPixel(block, translation.y),
        }
    else
        .{ .x = 0, .y = 0 };
}

fn blockHitOpacity(block: *const BlockLayout) f64 {
    const element = liveBlockElement(block) orelse return 1.0;
    if (element.animations) |animations| {
        if (animations.get("opacity")) |animation| {
            switch (animation) {
                .numeric => |value| return std.math.clamp(value.getValue(), 0.0, 1.0),
                .pixel, .color, .transform => {},
            }
        }
    }
    const styles = if (element.style) |*value| value else return 1.0;
    const value = styleValue(styles, "opacity") orelse return 1.0;
    return std.math.clamp(std.fmt.parseFloat(f64, value) catch 1.0, 0.0, 1.0);
}

const BlockHitClip = struct {
    enabled: bool,
    radius: f64,
};

fn blockHitClip(block: *const BlockLayout) BlockHitClip {
    const element = liveBlockElement(block) orelse return .{ .enabled = false, .radius = 0.0 };
    const styles = if (element.style) |*value| value else return .{ .enabled = false, .radius = 0.0 };
    const radius = if (styleValue(styles, "border-radius")) |value|
        scaleBlockCssFloat(block, parseCssPixelRadius(value))
    else
        0.0;
    const overflow = std.mem.trim(
        u8,
        styleValue(styles, "overflow") orelse "visible",
        " \t\r\n",
    );
    const clips_overflow = std.ascii.eqlIgnoreCase(overflow, "clip") or
        (std.ascii.eqlIgnoreCase(overflow, "scroll") and element.scroll_container);
    return .{ .enabled = radius > 0.0 or clips_overflow, .radius = radius };
}

fn blockHitScrollY(block: *const BlockLayout) i32 {
    const element = liveBlockElement(block) orelse return 0;
    return if (element.scroll_container) @max(element.scroll_y, 0) else 0;
}

/// The exercise's simplified stacking model honors signed integer z-index
/// only for positioned elements. Invalid values and static elements stay in
/// the default zero layer.
fn blockPaintZIndex(block: *const BlockLayout) i32 {
    const element = liveBlockElement(block) orelse return 0;
    const styles = if (element.style) |*value| value else return 0;
    const position = std.mem.trim(
        u8,
        styleValue(styles, "position") orelse "static",
        " \t\r\n",
    );
    if (std.ascii.eqlIgnoreCase(position, "static")) return 0;
    const z_index = std.mem.trim(
        u8,
        styleValue(styles, "z-index") orelse "0",
        " \t\r\n",
    );
    return std.fmt.parseInt(i32, z_index, 10) catch 0;
}

fn applyNodeStyles(
    self: *Layout,
    element: parser.Element,
    _: *std.ArrayList(LineItem),
    apply_zoom: bool,
) !void {
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
        .effective_zoom = self.effective_zoom,
    };
    try self.style_stack.append(self.allocator, snapshot);

    if (element.style) |*style_map| {
        const notify_target = if (self.inline_block) |blk|
            if (blk.persistent_dependencies)
                &blk.height
            else
                blk.temporary_dependency_target
        else
            null;
        if (self.inline_block) |blk| {
            if (!blk.persistent_dependencies) {
                if (notify_target) |target| registerStyleDependencies(style_map, target);
            }
        }
        // `zoom` is not inherited as a computed property, but its used value
        // multiplies every descendant length. DOM-backed BlockLayouts already
        // folded their own zoom into block.zoom; inline descendants do it here.
        if (apply_zoom) {
            const zoom_value = if (notify_target) |target|
                styleValueRead(style_map, "zoom", target)
            else
                styleValue(style_map, "zoom");
            if (zoom_value) |zoom_str| {
                self.effective_zoom = combinedEffectiveZoom(
                    self.effectiveZoom(),
                    parseCssZoom(zoom_str),
                );
            }
        }

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
                self.transform_offset_x += self.scaleActiveCssPixel(translate.x);
                self.transform_offset_y += self.scaleActiveCssPixel(translate.y);
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
        self.effective_zoom = snapshot.effective_zoom;
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
                .color = self.remapTextColor(node_ptr, self.text_color),
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
            .button => false,
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
    for (line_buffer.items) |*item| {
        var final_y: i32 = undefined;

        const is_superscript = switch (item.payload) {
            .glyph => |glyph_payload| glyph_payload.glyph.is_superscript,
            .input => false,
            .button => false,
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
                    try includeBounds(&focus_map, focus_node, .{
                        .x = bounds_x,
                        .y = bounds_y,
                        .width = item.width,
                        .height = item.height,
                    });
                }
                if (findAccessibleNode(ptr)) |accessible_node| {
                    try includeBounds(&accessibility_map, accessible_node, .{
                        .x = bounds_x,
                        .y = bounds_y,
                        .width = item.width,
                        .height = item.height,
                    });
                }
            }
        }

        const source = if (self.inline_block) |block|
            displaySource(block, item.node_ptr)
        else
            null;

        switch (item.payload) {
            .glyph => |glyph_payload| {
                try self.current_display_target.append(self.allocator, DisplayItem{
                    .glyph = .{
                        .x = item.x,
                        .y = final_y,
                        .glyph = glyph_payload.glyph,
                        .color = glyph_payload.color,
                        .source = source,
                    },
                });
            },
            .input => |input_payload| {
                try input_payload.paintAt(self.current_display_target, self, item.x, final_y, source);
            },
            .button => |*button_payload| {
                try button_payload.paintAt(
                    self.current_display_target,
                    self,
                    item.x,
                    final_y,
                    source,
                );
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
                        .source = source,
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
                            .css_zoom = iframe_payload.css_zoom,
                            .source = source,
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
                    try iframe_payload.paintAt(self.current_display_target, self, item.x, final_y, source);
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
                .color = self.remapTextColor(node_ptr, self.text_color),
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

fn findFocusableNode(node_ptr: *Node) ?*Node {
    var current: ?*Node = node_ptr;
    while (current) |ptr| {
        switch (ptr.*) {
            .element => |*el| {
                if (dom_focus.isProgrammaticallyFocusable(el)) return ptr;
                current = el.parent;
            },
            .text => |*txt| {
                current = txt.parent;
            },
        }
    }
    return null;
}

fn includeBounds(
    map: *std.AutoHashMap(*Node, Bounds),
    node: *Node,
    bounds: Bounds,
) !void {
    const right = bounds.x + bounds.width;
    const bottom = bounds.y + bounds.height;
    if (map.getPtr(node)) |existing| {
        const existing_right = existing.x + existing.width;
        const existing_bottom = existing.y + existing.height;
        if (bounds.x < existing.x) existing.x = bounds.x;
        if (bounds.y < existing.y) existing.y = bounds.y;
        existing.width = @max(right, existing_right) - existing.x;
        existing.height = @max(bottom, existing_bottom) - existing.y;
        return;
    }
    try map.put(node, bounds);
}

test "nested inline focus fragments resolve to one target per visual line" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<a href='/next'>a <b>bold</b> link</a>",
    );
    defer html_parser.deinit(allocator);
    html_parser.use_implicit_tags = false;
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &nodes);

    var anchor: ?*Node = null;
    var text_nodes = std.ArrayList(*Node).empty;
    defer text_nodes.deinit(allocator);
    for (nodes.items) |node| switch (node.*) {
        .element => |element| {
            if (std.ascii.eqlIgnoreCase(element.tag, "a")) anchor = node;
        },
        .text => try text_nodes.append(allocator, node),
    };

    try std.testing.expect(anchor != null);
    try std.testing.expectEqual(@as(usize, 3), text_nodes.items.len);
    for (text_nodes.items) |text_node| {
        try std.testing.expect(findFocusableNode(text_node) == anchor.?);
    }

    var first_line = std.AutoHashMap(*Node, Bounds).init(allocator);
    defer first_line.deinit();
    try includeBounds(&first_line, findFocusableNode(text_nodes.items[0]).?, .{
        .x = 10,
        .y = 20,
        .width = 20,
        .height = 10,
    });
    try includeBounds(&first_line, findFocusableNode(text_nodes.items[1]).?, .{
        .x = 30,
        .y = 18,
        .width = 15,
        .height = 14,
    });
    try includeBounds(&first_line, findFocusableNode(text_nodes.items[2]).?, .{
        .x = 45,
        .y = 20,
        .width = 25,
        .height = 10,
    });
    try std.testing.expectEqual(@as(usize, 1), first_line.count());
    const first_bounds = first_line.get(anchor.?).?;
    try std.testing.expectEqual(@as(i32, 10), first_bounds.x);
    try std.testing.expectEqual(@as(i32, 18), first_bounds.y);
    try std.testing.expectEqual(@as(i32, 60), first_bounds.width);
    try std.testing.expectEqual(@as(i32, 14), first_bounds.height);

    // flushLine uses a fresh map for each line, so wrapping deliberately keeps
    // another fragment instead of making one tall bounding rectangle.
    var second_line = std.AutoHashMap(*Node, Bounds).init(allocator);
    defer second_line.deinit();
    try includeBounds(&second_line, anchor.?, .{
        .x = 10,
        .y = 40,
        .width = 18,
        .height = 10,
    });
    const second_bounds = second_line.get(anchor.?).?;
    try std.testing.expectEqual(@as(i32, 40), second_bounds.y);
    try std.testing.expectEqual(@as(i32, 18), second_bounds.width);
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

        var entity_buffer: [4]u8 = undefined;
        if (lexEntityAt(content, position, &entity_buffer)) |entity| {
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

    const gap = @max(self.scaleActiveCssPixel(paragraphGap(self.size)), 1);
    if (self.cursor_y == initial_y) {
        // Preserve an empty source line even though flushLine has no glyph
        // metrics from which to derive its normal advance.
        self.cursor_y += @max(self.scaleActiveCssPixel(self.size), 1);
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
            var entity_buffer: [4]u8 = undefined;
            if (lexEntityAt(content, i, &entity_buffer)) |entity| {
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

// Text stays source-backed in the DOM; decode references only while laying it
// out. Attribute values use the same lexer but copy decoded bytes in parser.zig.
fn lexEntityAt(
    text: []const u8,
    pos: usize,
    buffer: *[4]u8,
) ?struct { replacement: []const u8, len: usize } {
    const reference = parser.characterReferenceAt(text, pos) orelse return null;
    const encoded_len = std.unicode.utf8Encode(reference.codepoint, buffer) catch return null;
    return .{ .replacement = buffer[0..encoded_len], .len = reference.len };
}

/// Decode text exactly as the layout text walkers do. DOM text intentionally
/// remains source-backed and escaped; this owned helper also provides focused
/// coverage for generated browser-page labels.
pub fn decodeTextForDisplay(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var pos: usize = 0;
    while (pos < text.len) {
        var buffer: [4]u8 = undefined;
        if (lexEntityAt(text, pos, &buffer)) |entity| {
            try output.appendSlice(allocator, entity.replacement);
            pos += entity.len;
        } else {
            try output.append(allocator, text[pos]);
            pos += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

test "lexEntityAt recognizes the entities rendered as text" {
    const input = "&lt;div&gt; &amp; &quot;quote&quot; &apos;apostrophe&apos;";

    var buffer: [4]u8 = undefined;
    const less_than = lexEntityAt(input, 0, &buffer).?;
    try std.testing.expectEqualStrings("<", less_than.replacement);
    try std.testing.expectEqual(@as(usize, 4), less_than.len);

    const greater_than_start = std.mem.indexOf(u8, input, "&gt;").?;
    const greater_than = lexEntityAt(input, greater_than_start, &buffer).?;
    try std.testing.expectEqualStrings(">", greater_than.replacement);
    try std.testing.expectEqual(@as(usize, 4), greater_than.len);

    const soft_hyphen = lexEntityAt("&shy;", 0, &buffer).?;
    try std.testing.expectEqualStrings("\u{00AD}", soft_hyphen.replacement);
    try std.testing.expectEqual(@as(usize, 5), soft_hyphen.len);

    const numeric = lexEntityAt("&#x1F642;", 0, &buffer).?;
    try std.testing.expectEqualStrings("🙂", numeric.replacement);

    try std.testing.expect(lexEntityAt("&unknown;", 0, &buffer) == null);
    try std.testing.expect(lexEntityAt("&lt", 0, &buffer) == null);
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

// Replaced input-control layout. Buttons use ButtonLayout below so their
// descendant boxes participate in size and paint.
const InputLayout = struct {
    embed: EmbedLayout,
    font_size: i32 = 16,
    font_weight: FontWeight = .Normal,
    font_slant: FontSlant = .Roman,
    font_family: FontFamily = .proportional,
    color: browser.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    bgcolor: browser.Color = .{ .r = 173, .g = 216, .b = 230, .a = 255 }, // lightblue
    border_radius: f64 = 0,
    text: []const u8 = "",
    is_focused: bool = false,
    is_checkbox: bool = false,
    is_checked: bool = false,
    is_password: bool = false,

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
        self.is_checkbox = element.isCheckbox();
        self.is_checked = element.isChecked();
        self.is_password = element.isPasswordInput();
        if (self.is_checkbox) {
            self.bgcolor = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        if (animatedBackgroundColor(element)) |color| {
            self.bgcolor = color;
        } else if (element.style) |*style_map| {
            if (styleValue(style_map, "background-color")) |bg| {
                if (!std.ascii.eqlIgnoreCase(bg, "transparent")) {
                    if (parseColor(bg)) |col| {
                        self.bgcolor = col;
                    }
                }
            }
            if (styleValue(style_map, "border-radius")) |radius| {
                self.border_radius = engine.scaleActiveCssFloat(parseCssPixelRadius(radius));
            }
        }

        if (self.is_checkbox) {
            self.text = "";
        } else if (std.mem.eql(u8, element.tag, "input")) {
            if (element.attributes) |attrs| {
                self.text = attrs.get("value") orelse "";
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
        const natural_height = ascent_value + descent_value;
        var width_value = if (self.is_checkbox) natural_height else engine.scaleActiveCssPixel(INPUT_WIDTH_PX);
        var height_value = natural_height;
        if (!self.is_checkbox) {
            if (element.style) |*style_map| {
                if (resolvedPixelDimension(&element, style_map, "width")) |pixels|
                    width_value = @max(engine.scaleActiveCssPixel(pixels), 1);
                if (resolvedPixelDimension(&element, style_map, "height")) |pixels|
                    height_value = @max(engine.scaleActiveCssPixel(pixels), natural_height);
            }
        }
        self.embed.setupDependencies();
        self.embed.setMetrics(width_value, height_value, ascent_value, descent_value, engine.effectiveZoom(), self.font_size);
        self.is_focused = element.is_focused;
    }

    fn paintAt(
        self: *const InputLayout,
        commands: *std.ArrayList(DisplayItem),
        engine: *Layout,
        x: i32,
        y: i32,
        source: ?browser.DisplayItemSource,
    ) !void {
        const width_value = self.embed.width.get().*;
        const height_value = self.embed.height.get().*;
        const ascent_value = self.embed.ascent.get().*;
        var rounded_items = std.ArrayList(DisplayItem).empty;
        defer {
            DisplayItem.freeItems(engine.allocator, rounded_items.items);
            rounded_items.deinit(engine.allocator);
        }
        const target = if (self.border_radius > 0) &rounded_items else commands;
        const remapped_bg = engine.remapColor(self.bgcolor, .control_background);
        try appendBackgroundBox(
            target,
            engine.allocator,
            x,
            y,
            width_value,
            height_value,
            self.border_radius,
            remapped_bg,
            source,
        );

        if (engine.accessibility.forced_colors and !self.is_checkbox) {
            try target.append(engine.allocator, .{ .outline = .{
                .rect = .{
                    .left = x,
                    .top = y,
                    .right = x + width_value,
                    .bottom = y + height_value,
                },
                .color = forced_colors.text,
                .thickness = @max(scaleCssPixel(1, self.embed.zoom.get().*, engine.zoom()), 1),
                .source = source,
            } });
        }

        if (self.is_checkbox) {
            const ink = engine.remapColor(
                .{ .r = 48, .g = 48, .b = 48, .a = 255 },
                .control_text,
            );
            try target.append(engine.allocator, DisplayItem{
                .outline = .{
                    .rect = .{
                        .left = x,
                        .top = y,
                        .right = x + width_value,
                        .bottom = y + height_value,
                    },
                    .color = ink,
                    .thickness = @max(scaleCssPixel(1, self.embed.zoom.get().*, engine.zoom()), 1),
                    .source = source,
                },
            });
            if (self.is_checked) {
                const padding = @max(@divTrunc(height_value, 5), 2);
                const joint_x = x + @divTrunc(width_value, 2) - 1;
                const joint_y = y + height_value - padding;
                const thickness = @max(@divTrunc(height_value, 7), 1);
                try target.append(engine.allocator, DisplayItem{
                    .line = .{
                        .x1 = x + padding,
                        .y1 = y + @divTrunc(height_value, 2),
                        .x2 = joint_x,
                        .y2 = joint_y,
                        .color = ink,
                        .thickness = thickness,
                        .source = source,
                    },
                });
                try target.append(engine.allocator, DisplayItem{
                    .line = .{
                        .x1 = joint_x,
                        .y1 = joint_y,
                        .x2 = x + width_value - padding,
                        .y2 = y + padding,
                        .color = ink,
                        .thickness = thickness,
                        .source = source,
                    },
                });
            }
            if (self.border_radius > 0) {
                try appendRoundedControlGroup(
                    commands,
                    engine.allocator,
                    &rounded_items,
                    x,
                    y,
                    width_value,
                    height_value,
                    self.border_radius,
                    source,
                );
            }
            return;
        }

        var text_x = x + scaleCssPixel(2, self.embed.zoom.get().*, engine.zoom());
        const baseline_y = y + ascent_value;
        if (self.text.len > 0) {
            var g_iter = grapheme.iterator(self.text);

            while (g_iter.next()) |gc| {
                const gme = gc.bytes(self.text);
                const glyph_text = inputDisplayGrapheme(self.is_password, gme);
                const glyph = try engine.font_manager.getStyledGlyph(
                    glyph_text,
                    self.font_weight,
                    self.font_slant,
                    self.font_size,
                    self.font_family,
                );

                try target.append(engine.allocator, DisplayItem{
                    .glyph = .{
                        .x = text_x,
                        .y = baseline_y - engine.toLayoutPx(glyph.ascent),
                        .glyph = glyph,
                        .color = engine.remapColor(self.color, .control_text),
                        .source = source,
                    },
                });
                text_x += engine.toLayoutPx(glyph.w);
            }
        }

        if (self.is_focused) {
            try drawCursor(
                target,
                engine.allocator,
                text_x,
                y,
                height_value,
                engine.remapColor(
                    .{ .r = 255, .g = 0, .b = 0, .a = 255 },
                    .accent,
                ),
                source,
            );
        }

        if (self.border_radius > 0) {
            try appendRoundedControlGroup(
                commands,
                engine.allocator,
                &rounded_items,
                x,
                y,
                width_value,
                height_value,
                self.border_radius,
                source,
            );
        }
    }
};

fn inputDisplayGrapheme(is_password: bool, source: []const u8) []const u8 {
    if (is_password) return "*";
    if (std.mem.eql(u8, source, "\n") or std.mem.eql(u8, source, "\r")) return " ";
    return source;
}

test "hidden inputs emit no inline box and password graphemes paint as stars" {
    const allocator = std.testing.allocator;
    var hidden_node = Node{ .element = try parser.Element.init(
        allocator,
        "input type=hidden value=secret",
        null,
    ) };
    defer hidden_node.deinit(allocator);

    // The hidden check precedes every access to layout/font state, proving it
    // contributes no atomic input item, width, or line metrics.
    var unused_engine: Layout = undefined;
    var line_items = std.ArrayList(LineItem).empty;
    defer line_items.deinit(allocator);
    try unused_engine.handleInputElement(hidden_node, &hidden_node, &line_items);
    try std.testing.expectEqual(@as(usize, 0), line_items.items.len);

    const password = "aé🙂";
    var iterator = grapheme.iterator(password);
    var masked_count: usize = 0;
    while (iterator.next()) |cluster| {
        try std.testing.expectEqualStrings(
            "*",
            inputDisplayGrapheme(true, cluster.bytes(password)),
        );
        masked_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), masked_count);
    try std.testing.expectEqualStrings("x", inputDisplayGrapheme(false, "x"));
}

/// An inline button whose contents are laid out as a real block subtree. The
/// subtree lives only while the surrounding line is being built; its painted
/// commands are rebased onto the persistent outer BlockLayout before the
/// temporary layout objects are retired.
const ButtonLayout = struct {
    embed: EmbedLayout,
    root: ?*BlockLayout = null,
    commands: std.ArrayList(DisplayItem),
    bgcolor: browser.Color = .{ .r = 255, .g = 165, .b = 0, .a = 255 },
    border_radius: f64 = 0,
    content_offset_x: i32 = button_padding,
    content_offset_y: i32 = button_padding,
    input_bounds: std.AutoHashMap(*Node, Bounds),
    link_bounds: std.ArrayList(LinkBoundEntry),
    iframe_bounds: std.ArrayList(IframeBoundEntry),
    focus_bounds: std.ArrayList(FocusBoundEntry),
    accessibility_bounds: std.ArrayList(AccessibilityBoundEntry),
    fragment_targets: std.ArrayList(FragmentTarget),

    fn init(allocator: std.mem.Allocator) ButtonLayout {
        return .{
            .embed = EmbedLayout.init(allocator),
            .commands = std.ArrayList(DisplayItem).empty,
            .input_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
            .link_bounds = std.ArrayList(LinkBoundEntry).empty,
            .iframe_bounds = std.ArrayList(IframeBoundEntry).empty,
            .focus_bounds = std.ArrayList(FocusBoundEntry).empty,
            .accessibility_bounds = std.ArrayList(AccessibilityBoundEntry).empty,
            .fragment_targets = std.ArrayList(FragmentTarget).empty,
        };
    }

    fn deinit(self: *ButtonLayout) void {
        const allocator = self.embed.allocator;
        DisplayItem.freeItems(allocator, self.commands.items);
        self.commands.deinit(allocator);
        if (self.root) |root| {
            root.deinit();
            allocator.destroy(root);
            self.root = null;
        }
        self.input_bounds.deinit();
        self.link_bounds.deinit(allocator);
        self.iframe_bounds.deinit(allocator);
        self.focus_bounds.deinit(allocator);
        self.accessibility_bounds.deinit(allocator);
        self.fragment_targets.deinit(allocator);
        self.embed.deinit();
    }

    fn swapCollectors(self: *ButtonLayout, engine: *Layout) void {
        std.mem.swap(@TypeOf(self.input_bounds), &self.input_bounds, &engine.input_bounds);
        std.mem.swap(@TypeOf(self.link_bounds), &self.link_bounds, &engine.link_bounds);
        std.mem.swap(@TypeOf(self.iframe_bounds), &self.iframe_bounds, &engine.iframe_bounds);
        std.mem.swap(@TypeOf(self.focus_bounds), &self.focus_bounds, &engine.focus_bounds);
        std.mem.swap(
            @TypeOf(self.accessibility_bounds),
            &self.accessibility_bounds,
            &engine.accessibility_bounds,
        );
        std.mem.swap(
            @TypeOf(self.fragment_targets),
            &self.fragment_targets,
            &engine.fragment_targets,
        );
    }

    fn measure(
        self: *ButtonLayout,
        engine: *Layout,
        button_node: *Node,
        element: parser.Element,
        parent_block: *BlockLayout,
    ) !void {
        if (animatedBackgroundColor(element)) |color| {
            self.bgcolor = color;
        } else if (element.style) |*style_map| {
            if (styleValue(style_map, "background-color")) |background| {
                if (!std.ascii.eqlIgnoreCase(background, "transparent")) {
                    if (parseColor(background)) |color| self.bgcolor = color;
                }
            }
            if (styleValue(style_map, "border-radius")) |radius| {
                self.border_radius = engine.scaleActiveCssFloat(parseCssPixelRadius(radius));
            }
        }

        // Preserve the former 200px control width while allowing chrome and
        // authored pages to size a control explicitly. Oversized descendants
        // still expand the final outer box below instead of spilling out.
        const padding = @max(engine.scaleActiveCssPixel(button_padding), 1);
        var requested_width = engine.scaleActiveCssPixel(INPUT_WIDTH_PX);
        var requested_height: ?i32 = null;
        if (element.style) |*style_map| {
            if (resolvedPixelDimension(&element, style_map, "width")) |pixels|
                requested_width = @max(engine.scaleActiveCssPixel(pixels), 1);
            if (resolvedPixelDimension(&element, style_map, "height")) |pixels|
                requested_height = @max(engine.scaleActiveCssPixel(pixels), 1);
        }
        const content_width = @max(requested_width - 2 * padding, 1);
        const root = try BlockLayout.initRichButton(
            self.embed.allocator,
            button_node,
            parent_block.document,
            parent_block,
            content_width,
            engine.effectiveZoom(),
        );
        self.root = root;

        // Nested layout coordinates and interactive bounds are local to the
        // button until its final baseline position is known.
        self.swapCollectors(engine);
        defer self.swapCollectors(engine);
        try root.layout(engine);

        for (root.display_list.items) |item| {
            try appendClonedDisplayItem(self.embed.allocator, &self.commands, item);
        }
        try root.refreshPaintOrder();
        for (root.paint_order.items) |document_index| {
            switch (root.children.items[document_index]) {
                .block => |block| try paintBlockTreeRecursive(&self.commands, engine, block),
                .line => |line| try line.paintToList(&self.commands, engine),
            }
        }

        rebaseDisplaySources(self.commands.items, parent_block);

        const reference = try engine.font_manager.getStyledGlyph(
            "X",
            .Normal,
            .Roman,
            engine.scaledFontSize(engine.size),
            engine.activeFontFamily(),
        );
        const minimum_content_height = @max(
            engine.toLayoutPx(reference.ascent + reference.descent),
            1,
        );
        var content_bounds = browser.Rect{
            .left = 0,
            .top = 0,
            .right = content_width,
            .bottom = @max(
                root.height.get().*,
                @max(
                    minimum_content_height,
                    if (requested_height) |height| @max(height - 2 * padding, 1) else 1,
                ),
            ),
        };
        if (displayListLayoutBounds(engine, self.commands.items, 0, 0)) |paint_bounds| {
            content_bounds = unionRects(content_bounds, paint_bounds);
        }

        const box_metrics = buttonBoxMetrics(content_bounds, padding);
        self.content_offset_x = box_metrics.content_offset_x;
        self.content_offset_y = box_metrics.content_offset_y;
        self.embed.setupDependencies();
        self.embed.setMetrics(
            box_metrics.width,
            box_metrics.height,
            box_metrics.height,
            0,
            engine.effectiveZoom(),
            engine.size,
        );
    }

    fn paintAt(
        self: *ButtonLayout,
        destination: *std.ArrayList(DisplayItem),
        engine: *Layout,
        x: i32,
        y: i32,
        source: ?browser.DisplayItemSource,
    ) !void {
        const translate_x = x + self.content_offset_x;
        const translate_y = y + self.content_offset_y;
        try self.mergeBounds(engine, translate_x, translate_y);

        var rounded_items = std.ArrayList(DisplayItem).empty;
        defer {
            DisplayItem.freeItems(engine.allocator, rounded_items.items);
            rounded_items.deinit(engine.allocator);
        }
        const target = if (self.border_radius > 0) &rounded_items else destination;

        try appendBackgroundBox(
            target,
            engine.allocator,
            x,
            y,
            self.embed.width.get().*,
            self.embed.height.get().*,
            self.border_radius,
            engine.remapColor(self.bgcolor, .control_background),
            source,
        );

        if (engine.accessibility.forced_colors) {
            try target.append(engine.allocator, .{ .outline = .{
                .rect = .{
                    .left = x,
                    .top = y,
                    .right = x + self.embed.width.get().*,
                    .bottom = y + self.embed.height.get().*,
                },
                .color = forced_colors.text,
                .thickness = @max(scaleCssPixel(1, self.embed.zoom.get().*, engine.zoom()), 1),
                .source = source,
            } });
        }

        if (self.commands.items.len > 0) {
            const children = try self.commands.toOwnedSlice(engine.allocator);
            var children_owned = true;
            errdefer if (children_owned) DisplayItem.freeList(engine.allocator, children);
            try target.append(engine.allocator, .{ .transform = .{
                .translate_x = translate_x,
                .translate_y = translate_y,
                .children = children,
                .source = source,
            } });
            children_owned = false;
        }

        if (self.border_radius > 0) {
            try appendRoundedControlGroup(
                destination,
                engine.allocator,
                &rounded_items,
                x,
                y,
                self.embed.width.get().*,
                self.embed.height.get().*,
                self.border_radius,
                source,
            );
        }
    }

    fn mergeBounds(self: *ButtonLayout, engine: *Layout, dx: i32, dy: i32) !void {
        var input_iterator = self.input_bounds.iterator();
        while (input_iterator.next()) |entry| {
            try engine.input_bounds.put(entry.key_ptr.*, offsetBounds(entry.value_ptr.*, dx, dy));
        }
        for (self.link_bounds.items) |entry| try engine.link_bounds.append(engine.allocator, .{
            .node = entry.node,
            .bounds = offsetBounds(entry.bounds, dx, dy),
        });
        for (self.iframe_bounds.items) |entry| try engine.iframe_bounds.append(engine.allocator, .{
            .node = entry.node,
            .bounds = offsetBounds(entry.bounds, dx, dy),
        });
        for (self.focus_bounds.items) |entry| try engine.focus_bounds.append(engine.allocator, .{
            .node = entry.node,
            .bounds = offsetBounds(entry.bounds, dx, dy),
        });
        for (self.accessibility_bounds.items) |entry| try engine.accessibility_bounds.append(engine.allocator, .{
            .node = entry.node,
            .bounds = offsetBounds(entry.bounds, dx, dy),
        });
        for (self.fragment_targets.items) |entry| try engine.fragment_targets.append(engine.allocator, .{
            .node = entry.node,
            .y = entry.y + dy,
        });
    }
};

fn offsetBounds(bounds: Bounds, dx: i32, dy: i32) Bounds {
    return .{
        .x = bounds.x + dx,
        .y = bounds.y + dy,
        .width = bounds.width,
        .height = bounds.height,
    };
}

fn unionRects(a: browser.Rect, b: browser.Rect) browser.Rect {
    return .{
        .left = @min(a.left, b.left),
        .top = @min(a.top, b.top),
        .right = @max(a.right, b.right),
        .bottom = @max(a.bottom, b.bottom),
    };
}

const ButtonBoxMetrics = struct {
    width: i32,
    height: i32,
    content_offset_x: i32,
    content_offset_y: i32,
};

fn buttonBoxMetrics(content_bounds: browser.Rect, padding: i32) ButtonBoxMetrics {
    return .{
        .width = content_bounds.width() + 2 * padding,
        .height = content_bounds.height() + 2 * padding,
        .content_offset_x = padding - content_bounds.left,
        .content_offset_y = padding - content_bounds.top,
    };
}

test "rich button box encloses tall oversized and negative-offset content" {
    const metrics = buttonBoxMetrics(.{
        .left = -12,
        .top = -3,
        .right = 240,
        .bottom = 117,
    }, button_padding);
    try std.testing.expectEqual(@as(i32, 260), metrics.width);
    try std.testing.expectEqual(@as(i32, 128), metrics.height);
    try std.testing.expectEqual(@as(i32, 16), metrics.content_offset_x);
    try std.testing.expectEqual(@as(i32, 7), metrics.content_offset_y);
}

fn displayListLayoutBounds(
    engine: *Layout,
    items: []const DisplayItem,
    translate_x: i32,
    translate_y: i32,
) ?browser.Rect {
    var result: ?browser.Rect = null;
    for (items) |item| {
        const bounds: ?browser.Rect = switch (item) {
            .glyph => |glyph| .{
                .left = translate_x + glyph.x,
                .top = translate_y + glyph.y,
                .right = translate_x + glyph.x + engine.toLayoutPx(glyph.glyph.w),
                .bottom = translate_y + glyph.y + engine.toLayoutPx(glyph.glyph.h),
            },
            .rect => |rect| .{
                .left = translate_x + @min(rect.x1, rect.x2),
                .top = translate_y + @min(rect.y1, rect.y2),
                .right = translate_x + @max(rect.x1, rect.x2),
                .bottom = translate_y + @max(rect.y1, rect.y2),
            },
            .image => |image| .{
                .left = translate_x + @min(image.x1, image.x2),
                .top = translate_y + @min(image.y1, image.y2),
                .right = translate_x + @max(image.x1, image.x2),
                .bottom = translate_y + @max(image.y1, image.y2),
            },
            .iframe => |iframe| .{
                .left = translate_x + iframe.rect.left,
                .top = translate_y + iframe.rect.top,
                .right = translate_x + iframe.rect.right,
                .bottom = translate_y + iframe.rect.bottom,
            },
            .rounded_rect => |rect| .{
                .left = translate_x + @min(rect.x1, rect.x2),
                .top = translate_y + @min(rect.y1, rect.y2),
                .right = translate_x + @max(rect.x1, rect.x2),
                .bottom = translate_y + @max(rect.y1, rect.y2),
            },
            .line => |line| .{
                .left = translate_x + @min(line.x1, line.x2) - line.thickness,
                .top = translate_y + @min(line.y1, line.y2) - line.thickness,
                .right = translate_x + @max(line.x1, line.x2) + line.thickness,
                .bottom = translate_y + @max(line.y1, line.y2) + line.thickness,
            },
            .outline => |outline| .{
                .left = translate_x + outline.rect.left - outline.thickness,
                .top = translate_y + outline.rect.top - outline.thickness,
                .right = translate_x + outline.rect.right + outline.thickness,
                .bottom = translate_y + outline.rect.bottom + outline.thickness,
            },
            .blend => |blend| displayListLayoutBounds(
                engine,
                blend.children,
                translate_x,
                translate_y,
            ),
            .transform => |transform| displayListLayoutBounds(
                engine,
                transform.children,
                translate_x + transform.translate_x,
                translate_y + transform.translate_y,
            ),
            .draw_composited_layer => null,
        };
        if (bounds) |rect| result = if (result) |existing| unionRects(existing, rect) else rect;
    }
    return result;
}

fn rebaseDisplaySources(items: []DisplayItem, parent_block: *BlockLayout) void {
    for (items) |*item| {
        switch (item.*) {
            .blend => |*blend| {
                if (blend.source) |source| blend.source = displaySource(parent_block, source.node);
                rebaseDisplaySources(blend.children, parent_block);
            },
            .transform => |*transform| {
                if (transform.source) |source| transform.source = displaySource(parent_block, source.node);
                rebaseDisplaySources(transform.children, parent_block);
            },
            inline else => |*payload| {
                if (payload.source) |source| payload.source = displaySource(parent_block, source.node);
            },
        }
    }
}

/// Persistent BlockLayout paint caches own every nested display-list
/// container they contain. Frame snapshots therefore deep-clone cached items
/// before effects wrap or retain them; retiring a frame must never invalidate
/// the cache used by a later paint-only pass.
const DisplayListCloneError = error{OutOfMemory};

fn cloneDisplayListOwned(
    allocator: std.mem.Allocator,
    items: []const DisplayItem,
) DisplayListCloneError![]DisplayItem {
    const copy = try allocator.alloc(DisplayItem, items.len);
    var initialized: usize = 0;
    errdefer {
        DisplayItem.freeItems(allocator, copy[0..initialized]);
        allocator.free(copy);
    }
    for (items, 0..) |item, index| {
        copy[index] = try cloneDisplayItemOwned(allocator, item);
        initialized += 1;
    }
    return copy;
}

fn cloneDisplayItemOwned(
    allocator: std.mem.Allocator,
    item: DisplayItem,
) DisplayListCloneError!DisplayItem {
    return switch (item) {
        .blend => |blend| blk: {
            const children = try cloneDisplayListOwned(allocator, blend.children);
            var children_owned = true;
            errdefer if (children_owned) DisplayItem.freeList(allocator, children);

            const blend_mode = if (blend.blend_mode) |mode|
                try allocator.dupe(u8, mode)
            else
                null;
            children_owned = false;
            break :blk .{ .blend = .{
                .opacity = blend.opacity,
                .blend_mode = blend_mode,
                .blur_radius = blend.blur_radius,
                .hit_clip = blend.hit_clip,
                .children = children,
                .node = blend.node,
                .parent = null,
                .needs_compositing = blend.needs_compositing,
                .compositor_id = blend.compositor_id,
                .source = blend.source,
            } };
        },
        .transform => |transform| .{ .transform = .{
            .translate_x = transform.translate_x,
            .translate_y = transform.translate_y,
            .children = try cloneDisplayListOwned(allocator, transform.children),
            .node = transform.node,
            .composited = transform.composited,
            .animation_active = transform.animation_active,
            .compositor_id = transform.compositor_id,
            .source = transform.source,
        } },
        else => item,
    };
}

fn appendClonedDisplayItem(
    allocator: std.mem.Allocator,
    destination: *std.ArrayList(DisplayItem),
    item: DisplayItem,
) !void {
    var owned = [1]DisplayItem{try cloneDisplayItemOwned(allocator, item)};
    var transferred = false;
    errdefer if (!transferred) DisplayItem.freeItems(allocator, owned[0..]);
    try destination.append(allocator, owned[0]);
    transferred = true;
}

test "display-list cache clones recursively own nested containers" {
    const allocator = std.testing.allocator;

    const transform_children = try allocator.alloc(DisplayItem, 1);
    transform_children[0] = .{ .rect = .{
        .x1 = 1,
        .y1 = 2,
        .x2 = 30,
        .y2 = 40,
        .color = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
    } };
    const blend_children = try allocator.alloc(DisplayItem, 1);
    blend_children[0] = .{ .transform = .{
        .translate_x = 5,
        .translate_y = 7,
        .children = transform_children,
    } };
    const blend_mode = try allocator.dupe(u8, "multiply");
    var cached = [1]DisplayItem{.{ .blend = .{
        .opacity = 0.5,
        .blend_mode = blend_mode,
        .blur_radius = 3.0,
        .children = blend_children,
    } }};

    const snapshot = try cloneDisplayListOwned(allocator, cached[0..]);
    defer DisplayItem.freeList(allocator, snapshot);
    DisplayItem.freeItems(allocator, cached[0..]);

    try std.testing.expectEqualStrings("multiply", snapshot[0].blend.blend_mode.?);
    try std.testing.expectEqual(@as(f64, 3.0), snapshot[0].blend.blur_radius);
    try std.testing.expectEqual(@as(i32, 5), snapshot[0].blend.children[0].transform.translate_x);
    try std.testing.expectEqual(@as(i32, 30), snapshot[0].blend.children[0].transform.children[0].rect.x2);
}

test "rich-button descendant paint retains its own activation origin" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<button><a href='/child'>child</a><input></button>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &nodes);
    var button: ?*Node = null;
    var anchor: ?*Node = null;
    var input: ?*Node = null;
    for (nodes.items) |node| switch (node.*) {
        .element => |element| {
            if (std.ascii.eqlIgnoreCase(element.tag, "button")) button = node;
            if (std.ascii.eqlIgnoreCase(element.tag, "a")) anchor = node;
            if (std.ascii.eqlIgnoreCase(element.tag, "input")) input = node;
        },
        .text => {},
    };

    var temporary_origin: BlockLayout = undefined;
    temporary_origin.node_ptr = button.?;
    temporary_origin.inline_nodes = null;
    var persistent_origin: BlockLayout = undefined;
    persistent_origin.node_ptr = button.?;
    persistent_origin.inline_nodes = null;

    var children = [2]DisplayItem{
        .{ .rect = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = 20,
            .y2 = 20,
            .color = .{ .r = 0, .g = 0, .b = 255, .a = 255 },
            .source = displaySource(&temporary_origin, anchor.?),
        } },
        .{ .rect = .{
            .x1 = 20,
            .y1 = 0,
            .x2 = 40,
            .y2 = 20,
            .color = .{ .r = 173, .g = 216, .b = 230, .a = 255 },
            .source = displaySource(&temporary_origin, input.?),
        } },
    };
    var items = [2]DisplayItem{
        .{ .rect = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = 70,
            .y2 = 50,
            .color = .{ .r = 255, .g = 165, .b = 0, .a = 255 },
            .source = displaySource(&temporary_origin, button.?),
        } },
        .{ .transform = .{
            .translate_x = 10,
            .translate_y = 15,
            .children = children[0..],
            .source = displaySource(&temporary_origin, button.?),
        } },
    };
    rebaseDisplaySources(items[0..], &persistent_origin);

    const link_hit = DisplayItem.hitTest(items[0..], 12, 17, 1.0).?;
    try std.testing.expect(link_hit.source.originatingNode() == anchor.?);
    const input_hit = DisplayItem.hitTest(items[0..], 32, 17, 1.0).?;
    try std.testing.expect(input_hit.source.originatingNode() == input.?);
    const background_hit = DisplayItem.hitTest(items[0..], 60, 20, 1.0).?;
    try std.testing.expect(background_hit.source.originatingNode() == button.?);
}

// Text layout for individual words
const TextLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    node_ptr: ?*Node,
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

    fn addStyleDependencies(text: *TextLayout, style_map: ?*parser.StyleMap) void {
        const map = style_map orelse return;
        for ([_][]const u8{ "font-weight", "font-style", "font-size", "font-family" }) |property| {
            if (map.getPtr(property)) |field| {
                text.width.addDependency(field);
                text.height.addDependency(field);
                text.ascent.addDependency(field);
                text.descent.addDependency(field);
            }
        }
    }

    fn init(
        allocator: std.mem.Allocator,
        node: Node,
        node_ptr: ?*Node,
        word: []const u8,
        parent: *LineLayout,
        previous: ?*TextLayout,
    ) !*TextLayout {
        const text = try allocator.create(TextLayout);
        text.* = TextLayout{
            .allocator = allocator,
            .node = node,
            .node_ptr = node_ptr,
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

        if (parent.parent.persistent_dependencies) switch (text.node) {
            .text => |*t| addStyleDependencies(text, if (t.style) |*style_map| style_map else null),
            .element => |*e| addStyleDependencies(text, if (e.style) |*style_map| style_map else null),
        };
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
        self.zoom.set(self.parent.zoom.read(&self.zoom).*);
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
                .color = engine.remapTextColor(&self.node, self.color),
                .source = displaySource(self, self.node_ptr),
            },
        });
    }

    fn hitTest(
        self: *const TextLayout,
        parent_point: HitPoint,
        parent_origin: HitPoint,
    ) ?LayoutHitResult {
        const local = subtractHitOffset(
            parent_point,
            relativeHitOffset(self.x.get().*, parent_origin.x),
            relativeHitOffset(self.y.get().*, parent_origin.y),
        );
        if (!pointInLocalBox(local, self.width.get().*, self.height.get().*)) return null;
        return .{
            .node = self.node_ptr orelse return null,
            .local_x = local.x,
            .local_y = local.y,
        };
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
    in_layout: bool = false,

    fn markOpaque(ptr: *anyopaque) void {
        const self: *LineLayout = @ptrCast(@alignCast(ptr));
        if (self.in_layout) return;
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
        self.in_layout = true;
        defer self.in_layout = false;

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
        self.zoom.set(self.parent.zoom.read(&self.zoom).*);

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

    fn hitTest(
        self: *const LineLayout,
        parent_point: HitPoint,
        parent_origin: HitPoint,
    ) ?LayoutHitResult {
        const local = subtractHitOffset(
            parent_point,
            relativeHitOffset(self.x.get().*, parent_origin.x),
            relativeHitOffset(self.y.get().*, parent_origin.y),
        );
        var index = self.children.items.len;
        const origin = HitPoint{ .x = self.x.get().*, .y = self.y.get().* };
        while (index > 0) {
            index -= 1;
            if (self.children.items[index].hitTest(local, origin)) |hit| return hit;
        }
        return null;
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
    page_zoom: f32 = 1.0,

    zoom: ProtectedField(f32),
    x: ProtectedField(i32),
    y: ProtectedField(i32),
    width: ProtectedField(i32),
    height: ProtectedField(i32),
    children: std.ArrayList(*BlockLayout),

    has_dirty_descendants: bool = false,
    in_layout: bool = false,

    fn markOpaque(ptr: *anyopaque) void {
        const self: *DocumentLayout = @ptrCast(@alignCast(ptr));
        if (self.in_layout) return;
        self.mark();
    }

    fn init(allocator: std.mem.Allocator, node: *Node) !*DocumentLayout {
        const document = try allocator.create(DocumentLayout);
        document.* = DocumentLayout{
            .allocator = allocator,
            .node = node.*,
            .node_ptr = node,
            .page_zoom = 1.0,
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
        self.in_layout = true;
        defer self.in_layout = false;

        // Compute dimensions
        const zoom_value = combinedEffectiveZoom(engine.zoom(), engine.frame_css_zoom);
        self.page_zoom = engine.zoom();
        const x_value = scaleCssPixel(h_offset, zoom_value, engine.zoom());
        const y_value = scaleCssPixel(v_offset, zoom_value, engine.zoom());
        const width_value = engine.layoutWindowWidth() - engine.layoutScrollbarWidth() - (2 * x_value);
        engine.effective_zoom = zoom_value;

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

    /// Walk the layout tree back-to-front while carrying a point expressed in
    /// the current object's local coordinate space. Each child subtracts only
    /// its offset from its parent; transforms and element scrolling are
    /// inverted at the object that owns them.
    pub fn hitTest(self: *const DocumentLayout, x: i32, y: i32) ?LayoutHitResult {
        const local = subtractHitOffset(
            .{ .x = x, .y = y },
            self.x.get().*,
            self.y.get().*,
        );
        const origin = HitPoint{ .x = self.x.get().*, .y = self.y.get().* };
        var index = self.children.items.len;
        while (index > 0) {
            index -= 1;
            if (self.children.items[index].hitTest(local, origin)) |hit| return hit;
        }
        if (!pointInLocalBox(local, self.width.get().*, self.height.get().*)) return null;
        return .{ .node = self.node_ptr, .local_x = local.x, .local_y = local.y };
    }

    pub fn hitTestDevice(
        self: *const DocumentLayout,
        device_x: i32,
        device_y: i32,
        zoom_value: f32,
    ) ?LayoutHitResult {
        return self.hitTest(
            DisplayItem.deviceToLayoutPx(device_x, zoom_value),
            DisplayItem.deviceToLayoutPx(device_y, zoom_value),
        );
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

    fn hitTest(
        self: LayoutChild,
        parent_point: HitPoint,
        parent_origin: HitPoint,
    ) ?LayoutHitResult {
        return switch (self) {
            .block => |block| block.hitTest(parent_point, parent_origin),
            .line => |line| line.hitTest(parent_point, parent_origin),
        };
    }
};

const LayoutChildPaintKey = struct {
    z_index: i32,
    document_index: usize,
};

fn layoutChildPaintKey(child: LayoutChild, document_index: usize) LayoutChildPaintKey {
    return .{
        .z_index = switch (child) {
            .block => |block| blockPaintZIndex(block),
            .line => 0,
        },
        .document_index = document_index,
    };
}

fn paintKeyBefore(left: LayoutChildPaintKey, right: LayoutChildPaintKey) bool {
    if (left.z_index != right.z_index) return left.z_index < right.z_index;
    return left.document_index < right.document_index;
}

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
    // Rich buttons create a temporary, locally positioned block subtree whose
    // commands are later translated into the surrounding inline line box.
    embedded_box: ?EmbeddedBlockBox = null,
    rich_button_root: bool = false,
    effective_zoom_override: ?f32 = null,
    /// False for rich-button layout trees, which are destroyed after their
    /// paint commands are rebased into the persistent surrounding block.
    /// ProtectedField has no unsubscribe operation, so those temporary trees
    /// must never register callbacks with longer-lived DOM/layout fields.
    persistent_dependencies: bool = true,
    /// Rich-button descendants route every DOM-style invalidation to this
    /// persistent containing-block field instead of their temporary fields.
    temporary_dependency_target: ?*ProtectedField(i32) = null,

    // ProtectedField-wrapped layout properties
    zoom: ProtectedField(f32),
    x: ProtectedField(i32),
    y: ProtectedField(i32),
    width: ProtectedField(i32),
    height: ProtectedField(i32),
    children_epoch: u64 = 0,
    children_version: ProtectedField(u64),

    children: std.ArrayList(LayoutChild),
    /// DOM-index permutation captured at the last paint. Retaining it keeps
    /// structural hit queries aligned with that exact display generation.
    paint_order: std.ArrayList(usize),
    display_list: std.ArrayList(DisplayItem),
    cursor_x: i32 = 0,
    has_dirty_descendants: bool = false,
    in_layout: bool = false,

    fn markOpaque(ptr: *anyopaque) void {
        const self: *BlockLayout = @ptrCast(@alignCast(ptr));
        if (self.in_layout) return;
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
        return initWithDependencyTracking(
            allocator,
            node,
            node_ptr,
            document,
            parent_block,
            previous,
            if (parent_block) |parent| parent.persistent_dependencies else true,
        );
    }

    fn initWithDependencyTracking(
        allocator: std.mem.Allocator,
        node: Node,
        node_ptr: ?*Node,
        document: *DocumentLayout,
        parent_block: ?*BlockLayout,
        previous: ?*BlockLayout,
        persistent_dependencies: bool,
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
            .paint_order = std.ArrayList(usize).empty,
            .display_list = std.ArrayList(DisplayItem).empty,
            .embedded_box = null,
            .rich_button_root = false,
            .effective_zoom_override = null,
            .persistent_dependencies = persistent_dependencies,
            .temporary_dependency_target = if (!persistent_dependencies and parent_block != null)
                parent_block.?.temporary_dependency_target
            else
                null,
            .children_epoch = 0,
            .children_version = ProtectedField(u64).init(allocator, 0),
        };
        block.zoom.setOwner(block, markOpaque);
        block.x.setOwner(block, markOpaque);
        block.y.setOwner(block, markOpaque);
        block.width.setOwner(block, markOpaque);
        block.height.setOwner(block, markOpaque);
        block.children_version.setOwner(block, markOpaque);

        if (!persistent_dependencies) {
            if (block.temporary_dependency_target) |target| {
                if (node_ptr) |ptr| switch (ptr.*) {
                    .element => |*element| {
                        if (element.style) |*style_map| registerStyleDependencies(style_map, target);
                    },
                    .text => {},
                };
            }
        }

        if (persistent_dependencies) {
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
        }

        // Real DOM-backed blocks react to changes in their specified
        // dimensions. Anonymous blocks intentionally keep their auto size.
        if (persistent_dependencies) {
            if (node_ptr) |ptr| {
                switch (ptr.*) {
                    .element => |*element| {
                        if (element.style) |*style_map| {
                            if (style_map.getPtr("zoom")) |field| block.zoom.addDependency(field);
                            if (style_map.getPtr("width")) |field| block.width.addDependency(field);
                            if (style_map.getPtr("height")) |field| block.height.addDependency(field);
                            if (style_map.getPtr("overflow")) |field| block.height.addDependency(field);
                        }
                    },
                    .text => {},
                }
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

    fn initRichButton(
        allocator: std.mem.Allocator,
        node_ptr: *Node,
        document: *DocumentLayout,
        parent_block: *BlockLayout,
        content_width: i32,
        effective_zoom: f32,
    ) !*BlockLayout {
        const block = try BlockLayout.initWithDependencyTracking(
            allocator,
            node_ptr.*,
            node_ptr,
            document,
            parent_block,
            null,
            false,
        );
        block.embedded_box = .{ .x = 0, .y = 0, .width = content_width };
        block.rich_button_root = true;
        block.effective_zoom_override = effective_zoom;
        block.temporary_dependency_target = &parent_block.height;
        switch (node_ptr.*) {
            .element => |*element| {
                if (element.style) |*style_map| {
                    registerStyleDependencies(style_map, &parent_block.height);
                }
            },
            .text => {},
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
            .element => |*element| if (element.style) |*style_map| blk: {
                const dependency_target = if (self.persistent_dependencies)
                    target
                else
                    self.temporary_dependency_target;
                const computed = (if (dependency_target) |notify|
                    styleValueRead(style_map, property, notify)
                else
                    styleValue(style_map, property)) orelse break :blk null;
                break :blk animatedPixelDimension(element, property) orelse
                    parseCssPixelLength(computed);
            } else null,
            .text => null,
        };
    }

    fn updateScrollGeometry(
        self: *BlockLayout,
        specified_height: ?i32,
        natural_height: i32,
    ) void {
        const node_ptr = self.node_ptr orelse return;
        switch (node_ptr.*) {
            .element => |*element| {
                const overflow = if (element.style) |*style_map|
                    styleValue(style_map, "overflow") orelse "visible"
                else
                    "visible";
                const normalized = std.mem.trim(u8, overflow, " \t\r\n");
                const enabled = specified_height != null and
                    std.ascii.eqlIgnoreCase(normalized, "scroll");
                element.setScrollGeometry(
                    enabled,
                    specified_height orelse 0,
                    natural_height,
                );
            },
            .text => {},
        }
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
        self.paint_order.deinit(self.allocator);
        if (self.inline_nodes) |nodes| self.allocator.free(nodes);
        DisplayItem.freeItems(self.allocator, self.display_list.items);
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
                // Replaced controls are atomic in their surrounding line. A
                // rich button's temporary root is the contained exception.
                if (std.ascii.eqlIgnoreCase(e.tag, "input") or
                    (std.ascii.eqlIgnoreCase(e.tag, "button") and !self.rich_button_root) or
                    std.ascii.eqlIgnoreCase(e.tag, "img") or std.ascii.eqlIgnoreCase(e.tag, "iframe"))
                {
                    return false;
                }

                // A block-displayed child creates a block formatting context.
                // Otherwise, mixed content stays inline unless the element is
                // empty, matching the book's simplified layout algorithm.
                for (e.children.items) |child| {
                    if (isContainerNode(
                        child,
                        if (self.persistent_dependencies) &self.children_version else null,
                    )) return true;
                }
                return e.children.items.len == 0;
            },
        }
    }

    fn appendChild(self: *BlockLayout, child: LayoutChild) !void {
        try self.children.append(self.allocator, child);
    }

    fn refreshPaintOrder(self: *BlockLayout) !void {
        try self.paint_order.ensureTotalCapacity(self.allocator, self.children.items.len);
        self.paint_order.clearRetainingCapacity();
        for (0..self.children.items.len) |document_index| {
            self.paint_order.appendAssumeCapacity(document_index);
        }
        std.mem.sort(usize, self.paint_order.items, self.children.items, struct {
            fn lessThan(children: []const LayoutChild, left: usize, right: usize) bool {
                return paintKeyBefore(
                    layoutChildPaintKey(children[left], left),
                    layoutChildPaintKey(children[right], right),
                );
            }
        }.lessThan);
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
    fn word(
        self: *BlockLayout,
        node: Node,
        node_ptr: ?*Node,
        word_text: []const u8,
        font_mgr: *font.FontManager,
        width: i32,
    ) !void {
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
        if (wordNeedsNewLine(self.cursor_x, width, self.width)) {
            try self.newLine();
        }

        const previous_word: ?*TextLayout = if (line.children.items.len > 0)
            line.children.items[line.children.items.len - 1]
        else
            null;

        const text = try TextLayout.init(self.allocator, node, node_ptr, word_text, line, previous_word);
        try line.children.append(self.allocator, text);
        self.cursor_x += width;

        _ = font_mgr; // Will use this later for measuring
    }

    fn layout(self: *BlockLayout, engine: *Layout) !void {
        // Skip layout if nothing is dirty
        if (!self.layoutNeeded()) return;
        self.in_layout = true;
        defer self.in_layout = false;

        if (self.node_ptr) |ptr| {
            self.node = ptr.*;
        }

        // This subtree is rebuilt and destroyed inside one surrounding line
        // layout. Its live DOM styles must invalidate the persistent outer
        // block, never a ProtectedField owned by this temporary tree.
        if (!self.persistent_dependencies) {
            if (self.temporary_dependency_target) |target| switch (self.node) {
                .element => |*element| {
                    if (element.style) |*style_map| registerStyleDependencies(style_map, target);
                },
                .text => {},
            };
        }

        // Compute position and dimensions
        // Use .read() to register invalidation dependencies on parent/document/previous fields
        const parent_zoom = if (self.parent_block) |pb|
            if (self.persistent_dependencies) pb.zoom.read(&self.zoom).* else pb.zoom.get().*
        else if (self.persistent_dependencies)
            self.document.zoom.read(&self.zoom).*
        else
            self.document.zoom.get().*;
        const local_zoom = if (self.inline_nodes == null and self.node_ptr != null) local: {
            const element = switch (self.node_ptr.?.*) {
                .element => |*value| value,
                .text => break :local 1.0,
            };
            const styles = if (element.style) |*value| value else break :local 1.0;
            break :local parseCssZoom(styleValue(styles, "zoom") orelse "1");
        } else 1.0;
        const zoom_value = self.effective_zoom_override orelse
            combinedEffectiveZoom(parent_zoom, local_zoom);
        self.zoom.set(zoom_value);

        const parent_x = if (self.parent_block) |pb|
            if (self.persistent_dependencies) pb.x.read(&self.x).* else pb.x.get().*
        else if (self.persistent_dependencies)
            self.document.x.read(&self.x).*
        else
            self.document.x.get().*;
        const parent_width = if (self.parent_block) |pb|
            if (self.persistent_dependencies) pb.width.read(&self.width).* else pb.width.get().*
        else if (self.persistent_dependencies)
            self.document.width.read(&self.width).*
        else
            self.document.width.get().*;
        const prev_y = if (self.previous) |prev|
            if (self.persistent_dependencies)
                prev.y.read(&self.y).* + prev.height.read(&self.y).*
            else
                prev.y.get().* + prev.height.get().*
        else if (self.parent_block) |pb|
            (if (self.persistent_dependencies) pb.y.read(&self.y).* else pb.y.get().*) +
                tableOfContentsHeaderHeight(
                    pb.node,
                    pb.zoom.get().*,
                    engine.zoom(),
                )
        else if (self.persistent_dependencies)
            self.document.y.read(&self.y).*
        else
            self.document.y.get().*;

        // Set x, y, width early so children can read them
        const content_bounds = if (self.embedded_box) |embedded|
            ContentBounds{ .x = embedded.x, .width = embedded.width }
        else
            contentBoundsForNode(
                self.node,
                parent_x,
                parent_width,
                scaleCssPixel(list_item_indent, zoom_value, engine.zoom()),
            );
        const specified_width = if (self.embedded_box == null)
            if (self.specifiedPixelDimension("width", &self.width)) |width|
                scaleCssPixel(width, zoom_value, engine.zoom())
            else
                null
        else
            null;
        const specified_height = if (self.embedded_box == null)
            if (self.specifiedPixelDimension("height", &self.height)) |height|
                scaleCssPixel(height, zoom_value, engine.zoom())
            else
                null
        else
            null;
        self.x.set(content_bounds.x);
        self.y.set(if (self.embedded_box) |embedded| embedded.y else prev_y);
        self.width.set(specified_width orelse content_bounds.width);
        if (engine.collect_hit_test_bounds) {
            if (self.node_ptr) |ptr| try engine.recordFragmentTargets(ptr, prev_y);
        }

        var is_block = self.isBlockContainer();
        if (self.node == .element) {
            const tag = self.node.element.tag;
            if (std.ascii.eqlIgnoreCase(tag, "input") or
                (std.ascii.eqlIgnoreCase(tag, "button") and !self.rich_button_root) or
                std.ascii.eqlIgnoreCase(tag, "img") or std.ascii.eqlIgnoreCase(tag, "iframe"))
            {
                is_block = false;
            }
        }

        // Reset any cached inline commands
        DisplayItem.freeItems(self.allocator, self.display_list.items);
        self.display_list.clearRetainingCapacity();

        var natural_height: i32 = 0;
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
            const auto_height = computed_height + tableOfContentsHeaderHeight(
                self.node,
                zoom_value,
                engine.zoom(),
            );
            natural_height = auto_height;
            self.height.set(specified_height orelse auto_height);
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

            natural_height = self.height.get().*;
            if (specified_height) |height| self.height.set(height);

            // Height is set by layoutInlineBlock - need to ensure it uses .set()
        }

        try recordElementFocusBounds(engine, self);

        self.updateScrollGeometry(specified_height, natural_height);

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
                index + 1 < nodes.len and isContainerNode(
                nodes[index + 1],
                if (self.persistent_dependencies) &self.children_version else null,
            )) {
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

            if (isContainerNode(
                nodes[index],
                if (self.persistent_dependencies) &self.children_version else null,
            )) {
                const child_node = &nodes[index];
                const child = try BlockLayout.init(self.allocator, child_node.*, child_node, self.document, self, previous);
                try self.children.append(self.allocator, .{ .block = child });
                previous = child;
                index += 1;
                continue;
            }

            const start = index;
            while (index < nodes.len and !isContainerNode(
                nodes[index],
                if (self.persistent_dependencies) &self.children_version else null,
            )) : (index += 1) {}
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

    fn hitTest(
        self: *const BlockLayout,
        parent_point: HitPoint,
        parent_origin: HitPoint,
    ) ?LayoutHitResult {
        if (blockHitOpacity(self) <= 0.0) return null;

        var local = subtractHitOffset(
            parent_point,
            relativeHitOffset(self.x.get().*, parent_origin.x),
            relativeHitOffset(self.y.get().*, parent_origin.y),
        );
        const translation = blockHitTranslation(self);
        local = subtractHitOffset(local, translation.x, translation.y);

        const width = self.width.get().*;
        const height = self.height.get().*;
        const clip = blockHitClip(self);
        if (clip.enabled and !pointInLocalRoundedBox(local, width, height, clip.radius)) return null;

        // Scroll moves the contents but not the element's own box. Convert the
        // local point back into the unscrolled content space before descending.
        const content_point = addHitOffset(local, 0, blockHitScrollY(self));
        const origin = HitPoint{ .x = self.x.get().*, .y = self.y.get().* };
        if (self.paint_order.items.len == self.children.items.len) {
            var order_index = self.paint_order.items.len;
            while (order_index > 0) {
                order_index -= 1;
                const document_index = self.paint_order.items[order_index];
                if (self.children.items[document_index].hitTest(content_point, origin)) |hit| return hit;
            }
        } else {
            // Before the first paint there is no committed stack snapshot.
            // DOM reverse order is the zero-layer fallback.
            var document_index = self.children.items.len;
            while (document_index > 0) {
                document_index -= 1;
                if (self.children.items[document_index].hitTest(content_point, origin)) |hit| return hit;
            }
        }

        // Inline-mode blocks still use the legacy inline formatter and do not
        // retain LineLayout/TextLayout children. Their local leaf query uses
        // the cached paint commands, preserving fragment gaps, controls, and
        // rich-button descendants until that TODO is removed.
        if (self.display_list.items.len > 0) {
            const absolute_content_point = addHitOffset(content_point, self.x.get().*, self.y.get().*);
            if (DisplayItem.hitTest(
                self.display_list.items,
                absolute_content_point.x,
                absolute_content_point.y,
                1.0,
            )) |paint_hit| {
                if (paint_hit.source.originatingNode()) |node| {
                    return .{ .node = node, .local_x = local.x, .local_y = local.y };
                }
            }
        }

        if (!pointInLocalRoundedBox(local, width, height, clip.radius)) return null;
        return .{
            .node = self.node_ptr orelse return null,
            .local_x = local.x,
            .local_y = local.y,
        };
    }

    fn shouldPaint(self: *const BlockLayout) bool {
        // Anonymous blocks may use an input or button as their representative
        // node, but their display list contains the replaced control itself.
        // Only suppress a DOM-backed control block's redundant background.
        if (self.inline_nodes != null) return true;
        switch (self.node) {
            .text => return true,
            .element => |e| {
                // Controls paint their own background in their inline layout.
                return !std.mem.eql(u8, e.tag, "input") and !std.mem.eql(u8, e.tag, "button");
            },
        }
    }
};

fn wordNeedsNewLine(cursor_x: i32, word_width: i32, line_width: i32) bool {
    return cursor_x > 0 and cursor_x +| word_width > line_width;
}

fn setTestLayoutBox(layout_object: anytype, x: i32, y: i32, width: i32, height: i32) void {
    layout_object.zoom.set(1.0);
    layout_object.x.set(x);
    layout_object.y.set(y);
    layout_object.width.set(width);
    layout_object.height.set(height);
}

test "layout hit testing localizes nested transforms and reverses sibling order" {
    const allocator = std.testing.allocator;

    var root_node = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer root_node.deinit(allocator);
    var transformed_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer transformed_node.deinit(allocator);
    try setTestStyleValue(allocator, &transformed_node, "transform", "translate(100px, 30px)");
    var nested_node = Node{ .element = try parser.Element.init(allocator, "button", null) };
    defer nested_node.deinit(allocator);
    var later_node = Node{ .element = try parser.Element.init(allocator, "a", null) };
    defer later_node.deinit(allocator);

    const document = try DocumentLayout.init(allocator, &root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    setTestLayoutBox(document, 10, 20, 500, 500);

    const root = try BlockLayout.init(allocator, root_node, &root_node, document, null, null);
    try document.children.append(allocator, root);
    setTestLayoutBox(root, 10, 20, 400, 400);

    const transformed = try BlockLayout.init(
        allocator,
        transformed_node,
        &transformed_node,
        document,
        root,
        null,
    );
    try root.children.append(allocator, .{ .block = transformed });
    setTestLayoutBox(transformed, 30, 50, 80, 60);

    const nested = try BlockLayout.init(
        allocator,
        nested_node,
        &nested_node,
        document,
        transformed,
        null,
    );
    try transformed.children.append(allocator, .{ .block = nested });
    setTestLayoutBox(nested, 40, 60, 20, 20);

    const later = try BlockLayout.init(
        allocator,
        later_node,
        &later_node,
        document,
        root,
        transformed,
    );
    try root.children.append(allocator, .{ .block = later });
    setTestLayoutBox(later, 250, 250, 20, 20);

    const nested_hit = document.hitTest(145, 95).?;
    try std.testing.expect(nested_hit.node == &nested_node);
    try std.testing.expectEqual(@as(i32, 5), nested_hit.local_x);
    try std.testing.expectEqual(@as(i32, 5), nested_hit.local_y);

    const old_location = document.hitTest(45, 65).?;
    try std.testing.expect(old_location.node == &root_node);

    // Point queries read the live computed transform rather than the stale
    // BlockLayout node snapshot, matching compositor-only movement.
    transformed_node.element.style.?.getPtr("transform").?.set("translate(120px, 40px)");
    const moved_hit = document.hitTest(165, 105).?;
    try std.testing.expect(moved_hit.node == &nested_node);
    try std.testing.expectEqual(@as(i32, 5), moved_hit.local_x);
    try std.testing.expectEqual(@as(i32, 5), moved_hit.local_y);

    // Later paint-order siblings win once their local box overlaps the
    // transformed descendant's visual position.
    setTestLayoutBox(later, 160, 100, 20, 20);
    const overlap_hit = document.hitTest(165, 105).?;
    try std.testing.expect(overlap_hit.node == &later_node);
}

test "layout hit testing localizes nested overflow scrolling" {
    const allocator = std.testing.allocator;

    var root_node = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer root_node.deinit(allocator);
    var scroll_node = Node{ .element = try parser.Element.init(allocator, "section", null) };
    defer scroll_node.deinit(allocator);
    try setTestStyleValue(allocator, &scroll_node, "overflow", "scroll");
    scroll_node.element.setScrollGeometry(true, 50, 120);
    try std.testing.expect(scroll_node.element.scrollBy(40));
    var child_node = Node{ .element = try parser.Element.init(allocator, "button", null) };
    defer child_node.deinit(allocator);

    const document = try DocumentLayout.init(allocator, &root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    setTestLayoutBox(document, 10, 20, 500, 500);

    const root = try BlockLayout.init(allocator, root_node, &root_node, document, null, null);
    try document.children.append(allocator, root);
    setTestLayoutBox(root, 10, 20, 400, 400);

    const scroll = try BlockLayout.init(
        allocator,
        scroll_node,
        &scroll_node,
        document,
        root,
        null,
    );
    try root.children.append(allocator, .{ .block = scroll });
    setTestLayoutBox(scroll, 30, 50, 100, 50);

    const child = try BlockLayout.init(
        allocator,
        child_node,
        &child_node,
        document,
        scroll,
        null,
    );
    try scroll.children.append(allocator, .{ .block = child });
    setTestLayoutBox(child, 30, 110, 30, 20);

    const scrolled_hit = document.hitTest(35, 75).?;
    try std.testing.expect(scrolled_hit.node == &child_node);
    try std.testing.expectEqual(@as(i32, 5), scrolled_hit.local_x);
    try std.testing.expectEqual(@as(i32, 5), scrolled_hit.local_y);

    // The child's old unscrolled location lies outside the scrollport and
    // therefore falls through to the enclosing document block.
    const clipped_hit = document.hitTest(35, 115).?;
    try std.testing.expect(clipped_hit.node == &root_node);
}

test "layout hit testing localizes line and text children" {
    const allocator = std.testing.allocator;

    var root_node = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer root_node.deinit(allocator);
    var span_node = Node{ .element = try parser.Element.init(allocator, "span", null) };
    defer span_node.deinit(allocator);

    const document = try DocumentLayout.init(allocator, &root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    setTestLayoutBox(document, 10, 20, 500, 500);

    const root = try BlockLayout.init(allocator, root_node, &root_node, document, null, null);
    try document.children.append(allocator, root);
    setTestLayoutBox(root, 10, 20, 400, 400);

    const line = try LineLayout.init(allocator, root_node, root, null);
    try root.children.append(allocator, .{ .line = line });
    setTestLayoutBox(line, 20, 30, 200, 20);

    const text = try TextLayout.init(allocator, span_node, &span_node, "word", line, null);
    try line.children.append(allocator, text);
    setTestLayoutBox(text, 40, 32, 25, 15);

    const hit = document.hitTest(45, 35).?;
    try std.testing.expect(hit.node == &span_node);
    try std.testing.expectEqual(@as(i32, 5), hit.local_x);
    try std.testing.expectEqual(@as(i32, 3), hit.local_y);
}

test "z-index paint order is positioned stable and recursive" {
    const allocator = std.testing.allocator;

    var root_node = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer root_node.deinit(allocator);
    var high_first_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer high_first_node.deinit(allocator);
    try setTestStyleValue(allocator, &high_first_node, "position", "relative");
    try setTestStyleValue(allocator, &high_first_node, "z-index", "5");
    var static_high_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer static_high_node.deinit(allocator);
    try setTestStyleValue(allocator, &static_high_node, "z-index", "999");
    var negative_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer negative_node.deinit(allocator);
    try setTestStyleValue(allocator, &negative_node, "position", "relative");
    try setTestStyleValue(allocator, &negative_node, "z-index", "-2");
    var high_later_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer high_later_node.deinit(allocator);
    try setTestStyleValue(allocator, &high_later_node, "position", "absolute");
    try setTestStyleValue(allocator, &high_later_node, "z-index", "5");
    var nested_high_node = Node{ .element = try parser.Element.init(allocator, "button", null) };
    defer nested_high_node.deinit(allocator);
    try setTestStyleValue(allocator, &nested_high_node, "position", "relative");
    try setTestStyleValue(allocator, &nested_high_node, "z-index", "8");
    var nested_later_node = Node{ .element = try parser.Element.init(allocator, "button", null) };
    defer nested_later_node.deinit(allocator);
    try setTestStyleValue(allocator, &nested_later_node, "position", "relative");
    try setTestStyleValue(allocator, &nested_later_node, "z-index", "1");

    const document = try DocumentLayout.init(allocator, &root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    setTestLayoutBox(document, 10, 20, 500, 500);
    const root = try BlockLayout.init(allocator, root_node, &root_node, document, null, null);
    try document.children.append(allocator, root);
    setTestLayoutBox(root, 10, 20, 400, 400);

    const high_first = try BlockLayout.init(
        allocator,
        high_first_node,
        &high_first_node,
        document,
        root,
        null,
    );
    try root.children.append(allocator, .{ .block = high_first });
    const static_high = try BlockLayout.init(
        allocator,
        static_high_node,
        &static_high_node,
        document,
        root,
        high_first,
    );
    try root.children.append(allocator, .{ .block = static_high });
    const negative = try BlockLayout.init(
        allocator,
        negative_node,
        &negative_node,
        document,
        root,
        static_high,
    );
    try root.children.append(allocator, .{ .block = negative });
    const high_later = try BlockLayout.init(
        allocator,
        high_later_node,
        &high_later_node,
        document,
        root,
        negative,
    );
    try root.children.append(allocator, .{ .block = high_later });

    try root.refreshPaintOrder();
    const expected_forward = [_]*Node{
        &negative_node,
        &static_high_node,
        &high_first_node,
        &high_later_node,
    };
    for (root.paint_order.items, expected_forward) |document_index, expected_node| {
        try std.testing.expect(root.children.items[document_index].block.node_ptr.? == expected_node);
    }

    setTestLayoutBox(high_first, 30, 50, 100, 100);
    setTestLayoutBox(static_high, 30, 50, 100, 100);
    setTestLayoutBox(negative, 30, 50, 100, 100);
    setTestLayoutBox(high_later, 30, 50, 100, 100);
    try std.testing.expect(document.hitTest(35, 55).?.node == &high_later_node);

    const nested_high = try BlockLayout.init(
        allocator,
        nested_high_node,
        &nested_high_node,
        document,
        high_first,
        null,
    );
    try high_first.children.append(allocator, .{ .block = nested_high });
    const nested_later = try BlockLayout.init(
        allocator,
        nested_later_node,
        &nested_later_node,
        document,
        high_first,
        nested_high,
    );
    try high_first.children.append(allocator, .{ .block = nested_later });

    try high_first.refreshPaintOrder();
    try std.testing.expect(
        high_first.children.items[high_first.paint_order.items[0]].block.node_ptr.? == &nested_later_node,
    );
    try std.testing.expect(
        high_first.children.items[high_first.paint_order.items[1]].block.node_ptr.? == &nested_high_node,
    );

    setTestLayoutBox(static_high, 250, 250, 20, 20);
    setTestLayoutBox(negative, 250, 250, 20, 20);
    setTestLayoutBox(high_later, 250, 250, 20, 20);
    setTestLayoutBox(nested_high, 40, 60, 30, 30);
    setTestLayoutBox(nested_later, 40, 60, 30, 30);
    try std.testing.expect(document.hitTest(45, 65).?.node == &nested_high_node);
}

test "block display provenance rejects fragments outside its DOM origin" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><div><a>inside</a></div><p>outside</p></body></html>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &nodes);

    var anchor: ?*Node = null;
    var inside_text: ?*Node = null;
    var paragraph: ?*Node = null;
    for (nodes.items) |node| {
        switch (node.*) {
            .element => |element| {
                if (std.ascii.eqlIgnoreCase(element.tag, "a")) anchor = node;
                if (std.ascii.eqlIgnoreCase(element.tag, "p")) paragraph = node;
            },
            .text => |text| {
                if (text.parent == anchor) inside_text = node;
            },
        }
    }

    var block: BlockLayout = undefined;
    block.node_ptr = anchor.?;
    block.inline_nodes = null;

    try std.testing.expect(displaySource(&block, inside_text.?).originatingNode() == inside_text.?);
    try std.testing.expect(displaySource(&block, null).originatingNode() == anchor.?);
    try std.testing.expect(displaySource(&block, paragraph.?).originatingNode() == null);
}

test "anonymous inline run paints when its representative node is a button" {
    const allocator = std.testing.allocator;
    var button = Node{ .element = try parser.Element.init(allocator, "button", null) };
    defer button.deinit(allocator);
    var roots = [1]*Node{&button};

    var anonymous: BlockLayout = undefined;
    anonymous.node = button;
    anonymous.inline_nodes = roots[0..];
    try std.testing.expect(anonymous.shouldPaint());

    anonymous.inline_nodes = null;
    try std.testing.expect(!anonymous.shouldPaint());
}

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

    const cursor_color = self.remapColor(
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .accent,
    );
    const source = displaySource(block, block.node_ptr);
    if (findLastTextLayout(block)) |text| {
        const cursor_x = text.x.get().* + text.width.get().*;
        const cursor_y = text.y.get().*;
        const cursor_height = text.height.get().*;
        try drawCursor(commands, self.allocator, cursor_x, cursor_y, cursor_height, cursor_color, source);
        return;
    }

    const glyph = try self.font_manager.getStyledGlyph(
        "X",
        .Normal,
        .Roman,
        self.scaledFontSizeForZoom(self.default_font_size, block.zoom.get().*),
        .proportional,
    );
    const cursor_height = self.toLayoutPx(glyph.ascent + glyph.descent);
    try drawCursor(commands, self.allocator, block.x.get().*, block.y.get().*, cursor_height, cursor_color, source);
}

fn appendListMarker(self: *Layout, commands: *std.ArrayList(DisplayItem), block: *const BlockLayout) !void {
    const element = switch (block.node) {
        .element => |*value| value,
        .text => return,
    };
    if (!isListItemElement(element) or block.height.get().* <= 0) return;

    const indent = scaleBlockCssPixel(block, list_item_indent);
    const marker_size = @max(scaleBlockCssPixel(block, list_marker_size), 1);
    const marker_top = scaleBlockCssPixel(block, list_marker_top_offset);
    const marker_x = block.x.get().* - indent + @divTrunc(indent - marker_size, 2);
    const marker_y = block.y.get().* + @min(marker_top, @max(block.height.get().* - marker_size, 0));
    const color = if (element.style) |*style_map|
        if (styleValue(style_map, "color")) |value| parseColor(value) orelse browser.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } else browser.Color{ .r = 0, .g = 0, .b = 0, .a = 255 }
    else
        browser.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

    try commands.append(self.allocator, .{ .rect = .{
        .x1 = marker_x,
        .y1 = marker_y,
        .x2 = marker_x + marker_size,
        .y2 = marker_y + marker_size,
        .color = self.remapColor(color, .text),
        .source = displaySource(block, block.node_ptr),
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
    const header_height = tableOfContentsHeaderHeight(
        block.node,
        block.zoom.get().*,
        block.document.page_zoom,
    );
    const background = self.remapColor(
        .{ .r = 211, .g = 211, .b = 211, .a = 255 },
        .background,
    );
    try commands.append(self.allocator, .{ .rect = .{
        .x1 = x,
        .y1 = y,
        .x2 = x + width,
        .y2 = y + header_height,
        .color = background,
        .source = displaySource(block, block.node_ptr),
    } });

    const glyph = try self.font_manager.getStyledGlyph(
        "Table of Contents",
        .Normal,
        .Roman,
        self.scaledFontSizeForZoom(self.default_font_size, block.zoom.get().*),
        .proportional,
    );
    try commands.append(self.allocator, .{ .glyph = .{
        .x = x + scaleBlockCssPixel(block, 4),
        .y = y + scaleBlockCssPixel(block, 3),
        .glyph = glyph,
        .color = self.remapColor(
            .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .text,
        ),
        .source = displaySource(block, block.node_ptr),
    } });
}

fn elementUsesBlockFocusBox(element: *const parser.Element) bool {
    const style_map = if (element.style) |*styles| styles else return false;
    const display = styleValue(style_map, "display") orelse return false;
    return isBlockDisplay(display);
}

fn hasFocusBoundsForNode(entries: []const FocusBoundEntry, node: *Node) bool {
    for (entries) |entry| {
        if (entry.node == node) return true;
    }
    return false;
}

/// Replace every inline fragment for `node` with one block-level box while
/// preserving entries for independently focusable descendants. Capacity is
/// reserved before compaction so an allocation failure leaves the old
/// generation intact.
fn replaceFocusBoundsForNode(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(FocusBoundEntry),
    node: *Node,
    bounds: Bounds,
) !void {
    try entries.ensureUnusedCapacity(allocator, 1);

    var write_index: usize = 0;
    for (entries.items) |entry| {
        if (entry.node == node) continue;
        entries.items[write_index] = entry;
        write_index += 1;
    }
    entries.items.len = write_index;
    entries.appendAssumeCapacity(.{ .node = node, .bounds = bounds });
}

fn recordElementFocusBounds(self: *Layout, block: *const BlockLayout) !void {
    const node_ptr = block.node_ptr orelse return;
    const element = switch (node_ptr.*) {
        .element => |*value| value,
        .text => return,
    };
    if (!dom_focus.isProgrammaticallyFocusable(element)) return;

    const use_block_box = elementUsesBlockFocusBox(element);
    if (!use_block_box and hasFocusBoundsForNode(self.focus_bounds.items, node_ptr)) return;

    // Non-empty inline elements already received fragment bounds while each
    // visual line was flushed. Keep those separate instead of surrounding all
    // wrapped lines with one large rectangle. The fallback below preserves the
    // prior empty-contenteditable focus target without affecting ordinary
    // empty inline elements.
    if (!use_block_box) {
        const attributes = element.attributes orelse return;
        if (attributes.get("contenteditable") == null) return;
    }

    var height = block.height.get().*;
    if (height <= 0) {
        const glyph = try self.font_manager.getStyledGlyph(
            "X",
            .Normal,
            .Roman,
            self.scaledFontSizeForZoom(self.default_font_size, block.zoom.get().*),
            .proportional,
        );
        height = self.toLayoutPx(glyph.ascent + glyph.descent);
    }

    const bounds = Bounds{
        .x = block.x.get().*,
        .y = block.y.get().*,
        .width = block.width.get().*,
        .height = height,
    };

    if (use_block_box) {
        try replaceFocusBoundsForNode(self.allocator, &self.focus_bounds, node_ptr, bounds);
    } else {
        try self.focus_bounds.append(self.allocator, .{ .node = node_ptr, .bounds = bounds });
    }
}

test "block focus boxes replace line fragments without hiding descendants" {
    const allocator = std.testing.allocator;
    var block_node = Node{ .element = try parser.Element.init(allocator, "div tabindex=2", null) };
    defer block_node.deinit(allocator);
    try setTestDisplay(allocator, &block_node, "block");
    try std.testing.expect(dom_focus.isProgrammaticallyFocusable(&block_node.element));
    try std.testing.expect(elementUsesBlockFocusBox(&block_node.element));

    var inline_node = Node{ .element = try parser.Element.init(allocator, "a href=/next", null) };
    defer inline_node.deinit(allocator);
    try setTestDisplay(allocator, &inline_node, "inline");
    try std.testing.expect(!elementUsesBlockFocusBox(&inline_node.element));

    var entries = std.ArrayList(FocusBoundEntry).empty;
    defer entries.deinit(allocator);
    try entries.append(allocator, .{
        .node = &block_node,
        .bounds = .{ .x = 12, .y = 20, .width = 40, .height = 12 },
    });
    try entries.append(allocator, .{
        .node = &inline_node,
        .bounds = .{ .x = 30, .y = 34, .width = 24, .height = 12 },
    });
    try entries.append(allocator, .{
        .node = &block_node,
        .bounds = .{ .x = 12, .y = 48, .width = 36, .height = 12 },
    });

    const block_bounds = Bounds{ .x = 8, .y = 16, .width = 200, .height = 72 };
    try replaceFocusBoundsForNode(allocator, &entries, &block_node, block_bounds);

    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expect(entries.items[0].node == &inline_node);
    try std.testing.expectEqual(@as(i32, 30), entries.items[0].bounds.x);
    try std.testing.expect(entries.items[1].node == &block_node);
    try std.testing.expectEqual(block_bounds.x, entries.items[1].bounds.x);
    try std.testing.expectEqual(block_bounds.y, entries.items[1].bounds.y);
    try std.testing.expectEqual(block_bounds.width, entries.items[1].bounds.width);
    try std.testing.expectEqual(block_bounds.height, entries.items[1].bounds.height);
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
    self.effective_zoom = block.zoom.get().*;
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
                        const family_value = if (block.persistent_dependencies)
                            styleValueRead(style_map, "font-family", &block.height)
                        else
                            styleValue(style_map, "font-family");
                        if (family_value) |value| {
                            self.font_family = font.familyFromCss(value);
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
            try self.applyNodeStyles(e, &line_buffer, false);

            // Handle br tag for line breaks
            if (std.mem.eql(u8, e.tag, "br")) {
                try self.breakExplicitLine(&line_buffer);
            }

            if (std.ascii.eqlIgnoreCase(e.tag, "input")) {
                try self.handleInputElement(block.node, block.node_ptr, &line_buffer);
            } else if (std.ascii.eqlIgnoreCase(e.tag, "button") and !block.rich_button_root) {
                try self.handleButtonElement(block.node, block.node_ptr, &line_buffer);
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
}

fn parseColor(color_str: []const u8) ?browser.Color {
    const color = parser.parseCssColor(color_str) orelse return null;
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn animatedBackgroundColor(element: parser.Element) ?browser.Color {
    const animations = element.animations orelse return null;
    const animation = animations.get("background-color") orelse return null;
    const color = switch (animation) {
        .color => |value| value.getValue(),
        .numeric, .pixel, .transform => return null,
    };
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

test "layout reads the current background color animation value" {
    const allocator = std.testing.allocator;
    var element = try parser.Element.init(allocator, "div", null);
    defer element.deinit(allocator);
    element.animations = std.StringHashMap(parser.Animation).init(allocator);

    var color = parser.ColorAnimation.init(
        .{ .r = 255, .g = 0, .b = 0, .a = 0 },
        .{ .r = 0, .g = 0, .b = 255, .a = 255 },
        4,
    );
    _ = color.advance();
    _ = color.advance();
    try element.animations.?.put("background-color", .{ .color = color });

    try std.testing.expectEqual(
        browser.Color{ .r = 128, .g = 0, .b = 128, .a = 128 },
        animatedBackgroundColor(element).?,
    );
}

fn addBackgroundIfNeeded(self: *Layout, block: *const BlockLayout) !void {
    // Skip painting if shouldPaint returns false
    if (!block.shouldPaint()) return;
    // Anonymous inline-run blocks copy their first node only as a layout
    // representative; that node's background belongs to its own inline
    // payload, not to the full-width anonymous wrapper.
    if (block.inline_nodes != null) return;

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

            if (animatedBackgroundColor(e)) |animated| {
                color = animated;
            } else if (bgcolor_str) |bg| {
                // Don't draw if explicitly transparent
                if (std.ascii.eqlIgnoreCase(bg, "transparent")) {
                    return;
                }
                color = parseColor(bg);
            } else if (std.mem.eql(u8, e.tag, "pre")) {
                // Default gray background for pre tags if no style specified
                color = browser.Color{ .r = 230, .g = 230, .b = 230, .a = 255 };
            }

            // Draw the background rectangle if we have a color
            if (color) |col| {
                if (col.a == 0) return;
                const remapped = self.remapColor(col, .background);
                // Parse border-radius if present
                const radius = if (border_radius_str) |br_str|
                    scaleBlockCssFloat(block, parseCssPixelRadius(br_str))
                else
                    0;

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
                        .source = displaySource(block, block.node_ptr),
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
                        .source = displaySource(block, block.node_ptr),
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

    if (self.accessibility.forced_colors or self.document_color_scheme_dark) {
        const width = self.layoutWindowWidth();
        const bg_color = if (self.accessibility.forced_colors)
            forced_colors.canvas
        else if (self.accessibility.dark_palette) |palette|
            palette.background
        else
            browser.Color{ .r = 18, .g = 18, .b = 18, .a = 255 };
        const bg = DisplayItem{ .rect = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = width,
            .y2 = @max(content_height, self.toLayoutPx(self.window_height)),
            .color = bg_color,
            .source = displaySource(document, document.node_ptr),
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
    const content_start = commands.items.len;
    try appendTableOfContentsHeader(self, &commands, block);

    // Add the block's display items (from children like text, etc.)
    for (block.display_list.items) |item| {
        try appendClonedDisplayItem(self.allocator, &commands, item);
    }
    try appendListMarker(self, &commands, block);

    // Recursively paint children in stable ascending stack order. Layout and
    // DOM storage remain untouched; reverse hit testing uses the same keys.
    try block.refreshPaintOrder();
    for (block.paint_order.items) |document_index| {
        switch (block.children.items[document_index]) {
            .block => |b| try paintBlockTreeRecursive(&commands, self, b),
            .line => |l| try l.paintToList(&commands, self),
        }
    }

    try appendContentEditableCursor(self, &commands, block);
    try applyElementScroll(block, &commands, content_start);

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
                if (blend.blur_radius > 0.0) {
                    try writer.print("filter blur({d}px)\n", .{blend.blur_radius});
                } else if (blend.hit_clip) |clip| {
                    try writer.print("hit-clip rounded x1={d} y1={d} x2={d} y2={d} radius={d}\n", .{ clip.x1, clip.y1, clip.x2, clip.y2, clip.radius });
                } else {
                    try writer.print("blend opacity={d} mode={s}\n", .{ blend.opacity, blend.blend_mode orelse "normal" });
                }
                try writeDisplayItemsDebug(writer, blend.children, indent + 2);
            },
            .transform => |transform| {
                if (transform.animation_active) {
                    try writer.print("transform x={d} y={d} animation-active=true\n", .{ transform.translate_x, transform.translate_y });
                } else {
                    try writer.print("transform x={d} y={d}\n", .{ transform.translate_x, transform.translate_y });
                }
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
    const content_start = block_commands.items.len;
    try appendTableOfContentsHeader(self, &block_commands, block);

    // Add display items (from text, etc.)
    for (block.display_list.items) |item| {
        try appendClonedDisplayItem(self.allocator, &block_commands, item);
    }
    try appendListMarker(self, &block_commands, block);

    // Recursively paint children - collect their commands in stable stack
    // order without mutating their geometry/DOM order.
    try block.refreshPaintOrder();
    for (block.paint_order.items) |document_index| {
        switch (block.children.items[document_index]) {
            .block => |b| try paintBlockTreeRecursive(&block_commands, self, b),
            .line => |l| try l.paintToList(&block_commands, self),
        }
    }

    try appendContentEditableCursor(self, &block_commands, block);
    try applyElementScroll(block, &block_commands, content_start);

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

/// Keep the element's own background stationary while moving all of its
/// painted content. The enclosing overflow clip is installed below by
/// applyPaintEffects, so translated descendants cannot escape the box.
fn applyElementScroll(
    block: *BlockLayout,
    commands: *std.ArrayList(DisplayItem),
    content_start: usize,
) !void {
    const node_ptr = block.node_ptr orelse return;
    const element = switch (node_ptr.*) {
        .element => |*value| value,
        .text => return,
    };
    if (!element.scroll_container or element.scroll_y <= 0) return;
    if (content_start >= commands.items.len) return;

    const children = try block.allocator.alloc(DisplayItem, commands.items.len - content_start);
    @memcpy(children, commands.items[content_start..]);

    // The list already had room for every moved child, so replacing the
    // suffix by one transform cannot allocate after ownership is transferred.
    commands.shrinkRetainingCapacity(content_start);
    commands.appendAssumeCapacity(.{ .transform = .{
        .translate_x = 0,
        .translate_y = -element.scroll_y,
        .children = children,
        .node = opaqueElementForNode(block.node_ptr),
        .source = displaySource(block, block.node_ptr),
    } });
}

// Apply visual effects like opacity, blend modes, and clipping to a list of display commands
fn applyPaintEffects(self: *Layout, block: *BlockLayout, commands: []DisplayItem) ![]DisplayItem {
    // Check for filter, opacity, blend mode, overflow clipping, and transform.
    var opacity: f64 = 1.0;
    var blend_mode: ?[]const u8 = null;
    var blur_radius: f64 = 0.0;
    var should_clip = false;
    var border_radius: f64 = 0.0;
    var transform_x: i32 = 0;
    var transform_y: i32 = 0;
    var has_transform = false;
    var has_animated_transform = false;
    var has_animated_opacity = false;

    if (block.node == .element) {
        const elem = block.node.element;
        if (elem.style) |*style_map| {
            // Check for active opacity animation first
            if (elem.animations) |animations| {
                if (animations.get("opacity")) |anim| {
                    switch (anim) {
                        .numeric => |numeric| {
                            opacity = numeric.getValue();
                            opacity = @max(0.0, @min(1.0, opacity)); // Clamp to valid range
                            has_animated_opacity = true;
                        },
                        .pixel, .color, .transform => {},
                    }
                }
            }
            // Fall back to style value if no animation
            if (!has_animated_opacity) {
                if (styleValue(style_map, "opacity")) |op_str| {
                    opacity = std.fmt.parseFloat(f64, op_str) catch 1.0;
                    opacity = @max(0.0, @min(1.0, opacity)); // Clamp to valid range
                }
            }
            if (styleValue(style_map, "mix-blend-mode")) |blend_str| {
                if (blend_str.len > 0 and !std.mem.eql(u8, blend_str, "normal")) {
                    blend_mode = blend_str;
                }
            }
            if (styleValue(style_map, "filter")) |filter_str| {
                blur_radius = scaleBlockCssFloat(block, parseBlurFilter(filter_str) orelse 0.0);
            }
            if (styleValue(style_map, "border-radius")) |radius_str| {
                border_radius = scaleBlockCssFloat(block, parseCssPixelRadius(radius_str));
            }
            const overflow = std.mem.trim(
                u8,
                styleValue(style_map, "overflow") orelse "visible",
                " \t\r\n",
            );
            const scroll_container = if (block.node_ptr) |node_ptr| switch (node_ptr.*) {
                .element => |element| element.scroll_container,
                .text => false,
            } else false;
            if (std.ascii.eqlIgnoreCase(overflow, "clip") or
                (std.ascii.eqlIgnoreCase(overflow, "scroll") and scroll_container))
            {
                should_clip = true;
            }
            // An active translate animation overrides the computed endpoint.
            // Keep even a zero-valued animated transform wrapped so subsequent
            // frames can update only this compositor node.
            var animated_transform: ?parser.Translation = null;
            if (elem.animations) |animations| {
                if (animations.get("transform")) |animation| {
                    const css_track_will_continue = if (elem.css_animation) |state|
                        !state.finished and state.contains("transform")
                    else
                        false;
                    has_animated_transform = !animation.isComplete() or css_track_will_continue;
                    animated_transform = switch (animation) {
                        .transform => |value| value.getValue(),
                        .numeric, .pixel, .color => null,
                    };
                }
            }
            if (animated_transform) |translation| {
                const pixels = translation.layoutPixels();
                transform_x = scaleBlockCssPixel(block, pixels.x);
                transform_y = scaleBlockCssPixel(block, pixels.y);
                has_transform = true;
            } else if (styleValue(style_map, "transform")) |transform_str| {
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, transform_str, " \t\r\n"), "none")) {
                    if (parseTranslate(transform_str)) |translate| {
                        transform_x = scaleBlockCssPixel(block, translate.x);
                        transform_y = scaleBlockCssPixel(block, translate.y);
                        has_transform = true;
                    }
                }
            }
        }
    }

    // Start with the original commands
    var current_commands = commands;
    var owned_commands: ?[]DisplayItem = null;
    defer if (owned_commands) |owned| self.allocator.free(owned);

    // CSS filters consume the fully painted element subtree as one image.
    // Keep this wrapper inside clipping and opacity: filter first, then clip,
    // then group opacity/blending; translation remains outermost below.
    if (blur_radius > 0.0) {
        const blur_children = try self.allocator.alloc(DisplayItem, current_commands.len);
        @memcpy(blur_children, current_commands);

        const filtered_commands = try self.allocator.alloc(DisplayItem, 1);
        filtered_commands[0] = .{
            .blend = .{
                .opacity = 1.0,
                .blend_mode = null,
                .blur_radius = blur_radius,
                .children = blur_children,
                // The outer group owns compositor animation identity. Sharing it
                // here would apply one opacity update to both wrappers.
                .node = null,
                .needs_compositing = true,
                .source = displaySource(block, block.node_ptr),
            },
        };
        current_commands = filtered_commands;
        owned_commands = filtered_commands;
    }

    // Clipping is applied to the filtered result, so blur pixels cannot escape
    // an overflow clip even though content outside the edge contributes.
    if (should_clip) {
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
        clip_mask_commands[0] = if (border_radius > 0.0)
            DisplayItem{ .rounded_rect = .{
                .x1 = block_x,
                .y1 = block_y,
                .x2 = block_x + block_width,
                .y2 = block_y + block_height,
                .radius = border_radius,
                .color = browser.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
                .source = displaySource(block, block.node_ptr),
            } }
        else
            DisplayItem{ .rect = .{
                .x1 = block_x,
                .y1 = block_y,
                .x2 = block_x + block_width,
                .y2 = block_y + block_height,
                .color = browser.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
                .source = displaySource(block, block.node_ptr),
            } };

        const clip_blend = DisplayItem{
            .blend = .{
                .opacity = 1.0, // No opacity for clipping blend
                .blend_mode = clip_blend_mode,
                .children = clip_mask_commands,
                .needs_compositing = true, // Has blend mode, needs compositing
                .source = displaySource(block, block.node_ptr),
            },
        };

        // Append the clipping blend to the commands
        const new_commands = try self.allocator.alloc(DisplayItem, current_commands.len + 1);
        @memcpy(new_commands[0..current_commands.len], current_commands);
        new_commands[current_commands.len] = clip_blend;
        if (owned_commands) |old_container| self.allocator.free(old_container);
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
    if (has_animated_opacity or opacity < 1.0 or final_blend_mode != null or blur_radius > 0.0 or border_radius > 0.0 or should_clip) {
        const wrapped_commands = try self.allocator.alloc(DisplayItem, current_commands.len);
        @memcpy(wrapped_commands, current_commands);

        // Get pointer to the element for identifying this blend across frames
        const node_ptr = opaqueElementForNode(block.node_ptr);

        // Determine if this blend needs compositing (does actual work)
        // Blur uses an inner blend so clipping can follow it; this outer group
        // keeps the ordered filter/clip sequence in one composited surface.
        const needs_compositing = has_animated_opacity or opacity < 1.0 or final_blend_mode != null or blur_radius > 0.0 or should_clip;

        const blend_item = DisplayItem{
            .blend = .{
                .opacity = opacity,
                .blend_mode = final_blend_mode,
                .hit_clip = if (border_radius > 0.0 or should_clip) .{
                    .x1 = block.x.get().*,
                    .y1 = block.y.get().*,
                    .x2 = block.x.get().* + block.width.get().*,
                    .y2 = block.y.get().* + block.height.get().*,
                    .radius = border_radius,
                } else null,
                .children = wrapped_commands,
                .node = node_ptr,
                .needs_compositing = needs_compositing,
                .compositor_id = if (node_ptr) |ptr| @intFromPtr(ptr) else null,
                .source = displaySource(block, block.node_ptr),
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
                    .composited = true,
                    .animation_active = has_animated_transform,
                    .compositor_id = if (node_ptr) |ptr| @intFromPtr(ptr) else null,
                    .source = displaySource(block, block.node_ptr),
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

            const node_ptr = opaqueElementForNode(block.node_ptr);

            const transform_item = DisplayItem{
                .transform = .{
                    .translate_x = transform_x,
                    .translate_y = transform_y,
                    .children = wrapped_for_transform,
                    .node = node_ptr,
                    .composited = true,
                    .animation_active = has_animated_transform,
                    .compositor_id = if (node_ptr) |ptr| @intFromPtr(ptr) else null,
                    .source = displaySource(block, block.node_ptr),
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
    if (block.inline_nodes != null) return;

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

            if (animatedBackgroundColor(e)) |animated| {
                color = animated;
            } else if (bgcolor_str) |bg| {
                // Don't draw if explicitly transparent
                if (std.ascii.eqlIgnoreCase(bg, "transparent")) {
                    return;
                }
                color = parseColor(bg);
            } else if (std.mem.eql(u8, e.tag, "pre")) {
                // Default gray background for pre tags if no style specified
                color = browser.Color{ .r = 230, .g = 230, .b = 230, .a = 255 };
            }

            // Draw the background rectangle if we have a color
            if (color) |col| {
                if (col.a == 0) return;
                const remapped = self.remapColor(col, .background);
                // Parse border-radius if present
                const radius = if (border_radius_str) |br_str|
                    scaleBlockCssFloat(block, parseCssPixelRadius(br_str))
                else
                    0;

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
                        .source = displaySource(block, block.node_ptr),
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
                        .source = displaySource(block, block.node_ptr),
                    } };
                    try commands.append(self.allocator, rect);
                }
            }
        },
        else => {},
    }
}
