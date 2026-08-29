//! Builds layout trees and paint commands from Zibra's styled DOM nodes.
//!
//! This module owns block and inline layout, text and replaced-element
//! measurement, hit-test bounds, incremental invalidation, and generation of
//! the display items consumed by the browser compositor.

const std = @import("std");
const font = @import("font.zig");
const forced_colors = @import("forced_colors.zig");
const browser = @import("../root.zig");
const image_loader = @import("../image_loader.zig");
const grapheme = @import("grapheme");
const parser = @import("../../document/parser.zig");
const object_fit = @import("../../document/object_fit.zig");
const replaced_sizing = @import("replaced_sizing.zig");
const box_model = @import("box_model.zig");
const margin_collapse = @import("margin_collapse.zig");
const control_geometry = @import("control_geometry.zig");
const inline_format = @import("inline_format.zig");
const layout_hit = @import("layout_hit.zig");
const table_format = @import("table_format.zig");
const paint_effects = @import("paint_effects.zig");
const replaced_paint = @import("replaced_paint.zig");
const retained_commands = @import("retained_commands.zig");
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
const ContentBounds = box_model.ContentBounds;
const FloatSide = box_model.FloatSide;
const ClearSide = box_model.ClearSide;
const PositionMode = box_model.PositionMode;
const PositionOffset = box_model.PositionOffset;
const BoxEdges = box_model.BoxEdges;
const FloatBox = box_model.FloatBox;
const BoxModelEdges = box_model.BoxModelEdges;
const EmbeddedBlockBox = box_model.EmbeddedBlockBox;
const MarginStrut = margin_collapse.MarginStrut;

fn addPageBottomPadding(content_bottom_css: i32) i32 {
    const padded = @as(i64, @max(content_bottom_css, 0)) + v_offset;
    return @intCast(@min(padded, std.math.maxInt(i32)));
}

/// Return the full scrollable height, including top and bottom page padding.
pub fn documentScrollHeight(document_height_css: i32) i32 {
    return addPageBottomPadding(addPageBottomPadding(document_height_css));
}

fn isBlockDisplay(value: []const u8) bool {
    const display = std.mem.trim(u8, value, " \t\r\n");
    return std.ascii.eqlIgnoreCase(display, "block") or
        std.ascii.eqlIgnoreCase(display, "list-item");
}

fn isListItemDisplay(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "list-item");
}

/// Read only the bounded table roles that need retained layout boxes. The
/// display field is also a child-tree dependency: changing a box into or out
/// of a table role changes anonymous row/cell normalization.
fn nodeTableRole(node: Node, dependency_target: ?*ProtectedField(u64)) table_format.Role {
    return switch (node) {
        .element => |element| blk: {
            const style_map = if (element.style) |*styles| styles else break :blk .ordinary;
            const field = @constCast(style_map).getPtr("display") orelse break :blk .ordinary;
            const value = if (dependency_target) |target| value: {
                target.addDependency(field, style_map.allocator);
                break :value field.read(target, style_map.allocator).*;
            } else field.get().*;
            break :blk table_format.roleForDisplay(value);
        },
        .text => .ordinary,
    };
}

/// Return the last published table role for a structural-mutation eligibility
/// check. Such checks can run after style has been dirtied but before the next
/// style pass; unlike layout, they must not read a dirty computed field.
fn publishedNodeTableRole(node: Node) table_format.Role {
    return switch (node) {
        .element => |element| blk: {
            const style_map = if (element.style) |*styles| styles else break :blk .ordinary;
            const field = @constCast(style_map).getPtr("display") orelse break :blk .ordinary;
            break :blk table_format.roleForDisplay(field.lastValue().*);
        },
        .text => .ordinary,
    };
}

const parseFloatSide = box_model.parseFloatSide;
const parseClearSide = box_model.parseClearSide;
const parsePositionMode = box_model.parsePositionMode;

fn isOutOfFlowPosition(mode: PositionMode) bool {
    return mode == .absolute or mode == .fixed;
}

fn nodePositionMode(node: Node, dependency_target: ?*ProtectedField(u64)) PositionMode {
    return switch (node) {
        .element => |element| blk: {
            const style_map = if (element.style) |*styles| styles else break :blk .static;
            const field = @constCast(style_map).getPtr("position") orelse break :blk .static;
            const value = if (dependency_target) |target| value: {
                target.addDependency(field, style_map.allocator);
                break :value field.read(target, style_map.allocator).*;
            } else field.get().*;
            break :blk parsePositionMode(value);
        },
        .text => .static,
    };
}

fn nodeFloatSide(node: Node, dependency_target: ?*ProtectedField(u64)) FloatSide {
    if (isOutOfFlowPosition(nodePositionMode(node, dependency_target))) return .none;
    return switch (node) {
        .element => |element| blk: {
            const style_map = if (element.style) |*styles| styles else break :blk .none;
            const field = @constCast(style_map).getPtr("float") orelse break :blk .none;
            const value = if (dependency_target) |target| value: {
                target.addDependency(field, style_map.allocator);
                break :value field.read(target, style_map.allocator).*;
            } else field.get().*;
            break :blk parseFloatSide(value);
        },
        .text => .none,
    };
}

fn nodeClearSide(node: Node) ClearSide {
    if (isOutOfFlowPosition(nodePositionMode(node, null))) return .none;
    return switch (node) {
        .element => |element| blk: {
            const style_map = if (element.style) |*styles| styles else break :blk .none;
            const field = @constCast(style_map).getPtr("clear") orelse break :blk .none;
            break :blk parseClearSide(field.get().*);
        },
        .text => .none,
    };
}

/// Return whether a node participates as a block child. When supplied, the
/// parent's tree-version field is invalidated by later display-style changes.
fn isContainerNode(node: Node, dependency_target: ?*ProtectedField(u64)) bool {
    return switch (node) {
        .element => |element| blk: {
            if (isOutOfFlowPosition(nodePositionMode(node, dependency_target))) break :blk true;
            if (nodeFloatSide(node, dependency_target) != .none) break :blk true;
            if (table_format.establishesFormattingContext(nodeTableRole(node, dependency_target))) {
                break :blk true;
            }
            if (element.style) |*styles| {
                const style_map = @constCast(styles);
                if (style_map.getPtr("display")) |field| {
                    const value = if (dependency_target) |target| value: {
                        target.addDependency(field, style_map.allocator);
                        break :value field.read(target, style_map.allocator).*;
                    } else field.get().*;
                    if (isBlockDisplay(value)) break :blk true;
                }
            }

            // CSS block-in-inline fixup is substantially richer than this
            // layout tree, but retaining an inline wrapper as a container is
            // enough to keep its block descendants out of one flattened text
            // run. The wrapper then supplies the anonymous block boundary.
            for (element.children.items) |child| {
                if (isContainerNode(child, dependency_target)) break :blk true;
            }
            break :blk false;
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

fn usesListItemMarker(element: *const parser.Element) bool {
    if (!isListItemElement(element)) return false;
    const styles = if (element.style) |*style_map| style_map else return false;
    const field = @constCast(styles).getPtr("display") orelse return false;
    return isListItemDisplay(field.get().*);
}

fn isTableOfContentsElement(element: *const parser.Element) bool {
    if (!std.ascii.eqlIgnoreCase(element.tag, "nav")) return false;
    const attributes = element.attributes orelse return false;
    return std.mem.eql(u8, attributes.get("id") orelse return false, "toc");
}

const parseCssZoom = box_model.parseCssZoom;
pub const effectiveCssZoomForNode = box_model.effectiveCssZoomForNode;
const combinedEffectiveZoom = box_model.combinedEffectiveZoom;
const scaleCssPixel = box_model.scaleCssPixel;
pub const scaleCssPixelByFactor = box_model.scaleCssPixelByFactor;
const scaleCssFloat = box_model.scaleCssFloat;
const cssPixelsFromLayout = box_model.cssPixelsFromLayout;

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
            if (usesListItemMarker(&element)) return listItemContentBounds(parent_x, parent_width, indent);
        },
        .text => {},
    }
    return .{ .x = parent_x, .width = parent_width };
}

const resolveCssLength = box_model.resolveCssLength;
const resolveSignedCssLength = box_model.resolveSignedCssLength;
const constrainDimension = box_model.constrainDimension;
const collapseAdjoiningMargins = box_model.collapseAdjoiningMargins;
const shrinkToFitSpecifiedContentWidth = box_model.shrinkToFitSpecifiedContentWidth;
const resolveBoxEdges = box_model.resolveBoxEdges;
const horizontalAutoMargins = box_model.horizontalAutoMargins;
const animatedPixelDimension = box_model.animatedPixelDimension;
const resolvedPixelDimension = box_model.resolvedPixelDimension;
const parseCssPixelRadius = box_model.parseCssPixelRadius;
const appendBackgroundBox = replaced_paint.appendBackgroundBox;
const backgroundImagePaint = replaced_paint.backgroundImagePaint;
const backgroundImagePaintForSource = replaced_paint.backgroundImagePaintForSource;
const appendBackgroundImageBox = replaced_paint.appendBackgroundImageBox;
const appendRoundedControlGroup = replaced_paint.appendRoundedControlGroup;

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

pub const parseBlurFilter = paint_effects.parseBlurFilter;

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
            .zoom = ProtectedField(f32).init(1.0),
            .font_stub = ProtectedField(i32).init(0),
            .width = ProtectedField(i32).init(0),
            .height = ProtectedField(i32).init(0),
            .ascent = ProtectedField(i32).init(0),
            .descent = ProtectedField(i32).init(0),
        };
    }

    fn deinit(self: *EmbedLayout) void {
        self.zoom.deinit(self.allocator);
        self.font_stub.deinit(self.allocator);
        self.width.deinit(self.allocator);
        self.height.deinit(self.allocator);
        self.ascent.deinit(self.allocator);
        self.descent.deinit(self.allocator);
    }

    /// Inline embed records are destroyed as soon as their completed line is
    /// painted. Keep their dependency graph entirely self-contained: a
    /// persistent BlockLayout is responsible for subscribing to DOM styles.
    fn setupDependencies(self: *EmbedLayout) void {
        if (self.deps_initialized) return;
        self.deps_initialized = true;

        self.zoom.freezeDependencies();

        self.font_stub.addDependency(&self.zoom, self.allocator);
        self.font_stub.freezeDependencies();

        self.width.addDependency(&self.zoom, self.allocator);
        self.width.freezeDependencies();

        self.height.addDependency(&self.zoom, self.allocator);
        self.height.addDependency(&self.font_stub, self.allocator);
        self.height.addDependency(&self.width, self.allocator);
        self.height.freezeDependencies();

        self.ascent.addDependency(&self.height, self.allocator);
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
        return self.appendInlineWithPolicy(engine, line_buffer, node_ptr, payload, false);
    }

    /// Unloaded images can reserve just one authored axis. Retaining that
    /// degenerate inline item makes width affect line flow and height affect
    /// line height without inventing a natural size for the missing axis.
    fn appendImagePlaceholder(
        self: *const EmbedLayout,
        engine: *Layout,
        line_buffer: *std.ArrayList(LineItem),
        node_ptr: ?*Node,
        payload: LineItemPayload,
    ) !void {
        return self.appendInlineWithPolicy(engine, line_buffer, node_ptr, payload, true);
    }

    fn appendInlineWithPolicy(
        self: *const EmbedLayout,
        engine: *Layout,
        line_buffer: *std.ArrayList(LineItem),
        node_ptr: ?*Node,
        payload: LineItemPayload,
        allow_single_zero_axis: bool,
    ) !void {
        const width_value = self.width.get().*;
        const height_value = self.height.get().*;
        if (width_value < 0 or height_value < 0) return;
        if (allow_single_zero_axis) {
            if (width_value == 0 and height_value == 0) return;
        } else if (width_value == 0 or height_value == 0) return;

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
            .line_height = engine.lineHeightForNatural(@max(
                self.ascent.get().* + self.descent.get().*,
                height_value,
            )),
            .width = width_value,
            .height = height_value,
            .node_ptr = node_ptr,
            .payload = payload,
        });
        engine.cursor_x += width_value;
        // Replaced content separates adjacent normal-whitespace runs. A
        // following source-space therefore remains eligible to produce one
        // collapsed space instead of being merged with whitespace before the
        // control or image.
        engine.last_was_collapsible_space = false;
    }
};

const ImageLayout = struct {
    embed: EmbedLayout,
    pixels: []const u8,
    source_width: i32,
    source_height: i32,
    natural_width: i32,
    natural_height: i32,
    content_width: i32,
    content_height: i32,
    padding: BoxEdges,
    border: BoxEdges,
    css_scale: f64,
    fit: object_fit.Mode,
    opacity: f64 = 1.0,

    fn init(
        allocator: std.mem.Allocator,
        layout_width: i32,
        layout_height: i32,
        natural_width: i32,
        natural_height: i32,
        image_data: ?parser.ImageData,
        parent_block: ?*BlockLayout,
        style_map: ?*const parser.StyleMap,
        zoom_value: f32,
        edges: BoxModelEdges,
        css_scale: f64,
    ) ImageLayout {
        const empty_pixels = &[_]u8{};
        const src_width: i32 = if (image_data) |data| @intCast(data.image.width) else 0;
        const src_height: i32 = if (image_data) |data| @intCast(data.image.height) else 0;
        var layout = ImageLayout{
            .embed = EmbedLayout.init(allocator),
            .pixels = if (image_data) |data| data.image.rawBytes() else empty_pixels,
            .source_width = src_width,
            .source_height = src_height,
            .natural_width = natural_width,
            .natural_height = natural_height,
            .content_width = layout_width,
            .content_height = layout_height,
            .padding = edges.padding,
            .border = edges.border,
            .css_scale = css_scale,
            .fit = if (style_map) |styles|
                if (styleValue(styles, "object-fit")) |value|
                    object_fit.parse(value) orelse .fill
                else
                    .fill
            else
                .fill,
            .opacity = 1.0,
        };
        _ = parent_block;
        layout.embed.setupDependencies();
        const outer_width = @max(
            layout_width + edges.padding.horizontal() + edges.border.horizontal(),
            0,
        );
        const outer_height = @max(
            layout_height + edges.padding.vertical() + edges.border.vertical(),
            0,
        );
        layout.embed.setMetrics(outer_width, outer_height, outer_height, 0, zoom_value, 0);
        return layout;
    }

    fn displayItem(
        self: *const ImageLayout,
        box_x: i32,
        box_y: i32,
        source: ?browser.DisplayItemSource,
    ) browser.ImageDisplayItem {
        const content_x = box_x +| self.border.left +| self.padding.left;
        const content_y = box_y +| self.border.top +| self.padding.top;
        const geometry = object_fit.resolve(
            self.fit,
            self.content_width,
            self.content_height,
            self.natural_width,
            self.natural_height,
            self.source_width,
            self.source_height,
        ) orelse object_fit.Geometry{
            .destination = .{ .left = 0, .top = 0, .right = self.content_width, .bottom = self.content_height },
            .source = null,
        };
        const source_rect: ?browser.ImageSourceRect = if (geometry.source) |crop| .{
            .left = crop.left,
            .top = crop.top,
            .right = crop.right,
            .bottom = crop.bottom,
        } else null;
        return .{
            .x1 = content_x +| geometry.destination.left,
            .y1 = content_y +| geometry.destination.top,
            .x2 = content_x +| geometry.destination.right,
            .y2 = content_y +| geometry.destination.bottom,
            .source_width = self.source_width,
            .source_height = self.source_height,
            .pixels = self.pixels,
            .source_rect = source_rect,
            .hit_rect = .{
                .left = box_x,
                .top = box_y,
                .right = box_x +| self.embed.width.get().*,
                .bottom = box_y +| self.embed.height.get().*,
            },
            .opacity = self.opacity,
            .source = source,
        };
    }

    fn paintAt(
        self: *const ImageLayout,
        commands: *std.ArrayList(DisplayItem),
        engine: *Layout,
        x: i32,
        y: i32,
        source: ?browser.DisplayItemSource,
    ) !void {
        const width = self.embed.width.get().*;
        const height = self.embed.height.get().*;
        const element: ?*const parser.Element = if (source) |item_source|
            if (item_source.node) |node| switch (node.*) {
                .element => |*value| value,
                .text => null,
            } else null
        else
            null;

        if (element) |live_element| if (live_element.style) |*style_map| {
            const background = if (animatedBackgroundColor(live_element.*)) |animated|
                animated
            else if (styleValue(style_map, "background-color")) |value|
                parseColor(value)
            else
                null;
            if (background) |color| {
                const radius = if (styleValue(style_map, "border-radius")) |value|
                    self.css_scale * parseCssPixelRadius(value)
                else
                    0;
                try appendBackgroundBox(
                    commands,
                    engine.allocator,
                    x,
                    y,
                    width,
                    height,
                    radius,
                    engine.remapColor(color, .background),
                    source,
                );
            }
            if (!engine.accessibility.forced_colors) {
                if (backgroundImagePaint(live_element)) |paint| {
                    try appendBackgroundImageBox(
                        commands,
                        engine.allocator,
                        paint,
                        x,
                        y,
                        width,
                        height,
                        self.css_scale,
                        source,
                    );
                }
            }
            try appendBorderBoxes(
                engine,
                commands,
                x,
                y,
                width,
                height,
                self.border,
                style_map,
                live_element,
                source,
            );
        };

        try commands.append(engine.allocator, .{
            .image = self.displayItem(x, y, source),
        });
    }

    fn deinit(self: *ImageLayout) void {
        self.embed.deinit();
    }
};

test "object-fit separates fitted image paint from the replaced element hit box" {
    const allocator = std.testing.allocator;
    var image = ImageLayout.init(
        allocator,
        100,
        100,
        200,
        100,
        null,
        null,
        null,
        1.0,
        .{ .margin = .{}, .padding = .{}, .border = .{} },
        1.0,
    );
    defer image.deinit();
    image.source_width = 200;
    image.source_height = 100;

    image.fit = .contain;
    const contained = image.displayItem(10, 20, null);
    try std.testing.expectEqual(@as(i32, 10), contained.x1);
    try std.testing.expectEqual(@as(i32, 45), contained.y1);
    try std.testing.expectEqual(@as(i32, 110), contained.x2);
    try std.testing.expectEqual(@as(i32, 95), contained.y2);
    try std.testing.expect(contained.source_rect == null);
    try std.testing.expectEqual(
        browser.Rect{ .left = 10, .top = 20, .right = 110, .bottom = 120 },
        contained.hit_rect.?,
    );

    image.fit = .cover;
    const covered = image.displayItem(10, 20, null);
    try std.testing.expectEqual(@as(i32, 10), covered.x1);
    try std.testing.expectEqual(@as(i32, 20), covered.y1);
    try std.testing.expectEqual(@as(i32, 110), covered.x2);
    try std.testing.expectEqual(@as(i32, 120), covered.y2);
    try std.testing.expectEqual(
        browser.ImageSourceRect{ .left = 50, .top = 0, .right = 150, .bottom = 100 },
        covered.source_rect.?,
    );
}

test "inline replaced image boxes include padding and borders" {
    const allocator = std.testing.allocator;
    var image = ImageLayout.init(
        allocator,
        100,
        50,
        100,
        50,
        null,
        null,
        null,
        1.0,
        .{
            .margin = .{},
            .padding = .{ .top = 3, .right = 7, .bottom = 4, .left = 5 },
            .border = .{ .top = 1, .right = 6, .bottom = 2, .left = 2 },
        },
        1.0,
    );
    defer image.deinit();
    image.source_width = 100;
    image.source_height = 50;

    try std.testing.expectEqual(@as(i32, 120), image.embed.width.get().*);
    try std.testing.expectEqual(@as(i32, 60), image.embed.height.get().*);
    const item = image.displayItem(10, 20, null);
    try std.testing.expectEqual(@as(i32, 17), item.x1);
    try std.testing.expectEqual(@as(i32, 24), item.y1);
    try std.testing.expectEqual(@as(i32, 117), item.x2);
    try std.testing.expectEqual(@as(i32, 74), item.y2);
    try std.testing.expectEqual(
        browser.Rect{ .left = 10, .top = 20, .right = 130, .bottom = 80 },
        item.hit_rect.?,
    );
}

const CanvasLayout = struct {
    embed: EmbedLayout,
    /// The backing object is allocated lazily by getContext("2d"), after the
    /// initial layout may already exist. Borrow the owning element so repaint
    /// observes a backing store created without requiring a geometry rebuild.
    element: *parser.Element,
    source_width: i32,
    source_height: i32,

    fn init(
        allocator: std.mem.Allocator,
        layout_width: i32,
        layout_height: i32,
        source_width: i32,
        source_height: i32,
        element: *parser.Element,
        zoom_value: f32,
    ) CanvasLayout {
        var layout = CanvasLayout{
            .embed = EmbedLayout.init(allocator),
            .element = element,
            .source_width = source_width,
            .source_height = source_height,
        };
        layout.embed.setupDependencies();
        layout.embed.setMetrics(layout_width, layout_height, layout_height, 0, zoom_value, 0);
        return layout;
    }

    fn deinit(self: *CanvasLayout) void {
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
    canvas: CanvasLayout,
    iframe: IframeLayout,

    fn deinit(self: *LineItemPayload) void {
        switch (self.*) {
            .glyph => {},
            .input => |*input_payload| input_payload.deinit(),
            .button => |*button_payload| button_payload.deinit(),
            .image => |*image_payload| image_payload.deinit(),
            .canvas => |*canvas_payload| canvas_payload.deinit(),
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
    /// Used line-box height contributed by this inline item.
    line_height: i32,
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
    is_collapsed_space: bool = false,
    is_superscript: bool = false,
    is_small_caps: bool = false,
};

// Add this struct to cache word measurements
const WordCache = struct {
    width: i32,
    graphemes: []const []const u8,
};

pub const Bounds = layout_hit.Bounds;
pub const LayoutHitResult = layout_hit.Result;
const HitPoint = layout_hit.Point;

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

const TextDirection = inline_format.TextDirection;
const LineAlignment = inline_format.LineAlignment;
const textDirectionFromFlag = inline_format.textDirectionFromFlag;
const lineAlignmentShift = inline_format.lineAlignmentShift;

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

const textSizeForSuperscript = inline_format.textSizeForSuperscript;
const isSmallCapsLowercaseGrapheme = inline_format.isSmallCapsLowercaseGrapheme;
const textSizeForSmallCaps = inline_format.textSizeForSmallCaps;
const shouldAutomaticallyWrap = inline_format.shouldAutomaticallyWrap;

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

fn lineAlignmentForBlock(
    block: *const BlockLayout,
    direction: TextDirection,
    centered_title: bool,
) LineAlignment {
    if (centered_title) return .center;
    const element = liveBlockElement(block) orelse
        return if (direction == .right_to_left) .end else .start;
    const styles = if (element.style) |*style_map| style_map else return if (direction == .right_to_left) .end else .start;
    const value = std.mem.trim(
        u8,
        styleValue(styles, "text-align") orelse "start",
        " \t\r\n",
    );
    if (std.ascii.eqlIgnoreCase(value, "center")) return .center;
    if (std.ascii.eqlIgnoreCase(value, "right")) return .end;
    if (std.ascii.eqlIgnoreCase(value, "left")) return .start;
    if (std.ascii.eqlIgnoreCase(value, "start")) {
        return if (direction == .right_to_left) .end else .start;
    }
    if (std.ascii.eqlIgnoreCase(value, "end")) {
        return if (direction == .right_to_left) .start else .end;
    }
    return if (direction == .right_to_left) .end else .start;
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

test "superscript elements are recognized case-insensitively" {
    const allocator = std.testing.allocator;

    var superscript = Node{ .element = try parser.Element.init(allocator, "SUP", null) };
    defer superscript.deinit(allocator);
    try std.testing.expect(isSuperscriptElement(&superscript.element));

    var subscript = Node{ .element = try parser.Element.init(allocator, "sub", null) };
    defer subscript.deinit(allocator);
    try std.testing.expect(!isSuperscriptElement(&subscript.element));
}

test "abbr elements opt into small caps" {
    const allocator = std.testing.allocator;

    var abbreviation = Node{ .element = try parser.Element.init(allocator, "ABBR", null) };
    defer abbreviation.deinit(allocator);
    try std.testing.expect(isSmallCapsElement(&abbreviation.element));

    var span = Node{ .element = try parser.Element.init(allocator, "span", null) };
    defer span.deinit(allocator);
    try std.testing.expect(!isSmallCapsElement(&span.element));
}

test "pre elements opt into preformatted layout" {
    const allocator = std.testing.allocator;

    var pre = Node{ .element = try parser.Element.init(allocator, "PRE", null) };
    defer pre.deinit(allocator);
    try std.testing.expect(isPreformattedElement(&pre.element));

    var code = Node{ .element = try parser.Element.init(allocator, "code", null) };
    defer code.deinit(allocator);
    try std.testing.expect(!isPreformattedElement(&code.element));
}

fn setTestStyleValue(
    allocator: std.mem.Allocator,
    node: *Node,
    property: []const u8,
    value: []const u8,
) !void {
    std.debug.assert(node.* == .element);
    if (node.element.style == null) node.element.style = parser.StyleMap.init(allocator);
    var field = ProtectedField([]const u8).init(value);
    field.set(value);
    node.element.style.?.put(property, field) catch |err| {
        field.deinit(allocator);
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

    var tree_version = ProtectedField(u64).init(0);
    defer tree_version.deinit(allocator);
    tree_version.set(0);
    tree_version.freezeDependencies();
    try std.testing.expect(isContainerNode(promoted_span, &tree_version));
    const display_field = promoted_span.element.style.?.getPtr("display").?;
    display_field.mark();
    display_field.set("inline");
    try std.testing.expect(tree_version.dirty);

    try std.testing.expect(isBlockDisplay("block"));
    try std.testing.expect(isBlockDisplay("list-item"));
    try std.testing.expect(!isBlockDisplay("inline"));
    try std.testing.expect(!isBlockDisplay("unsupported"));
}

test "bounded tables normalize direct children into grid cells" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html style='display:block'><body style='display:block;margin:0'>" ++
            "<div id=table style='display:table'>" ++
            "<div id=a style='display:table-cell;width:11px;height:13px'></div>" ++
            "<div id=b style='display:table;width:17px;height:13px'></div>" ++
            "<div id=c style='display:table-cell;width:19px;height:5px'></div>" ++
            "<div id=d style='display:block;width:23px;height:13px'></div>" ++
            "</div>" ++
            "<div id=rows style='display:table'>" ++
            "<div id=row style='display:table-row'>" ++
            "<div id=e style='display:table-cell;width:7px;height:9px'></div>" ++
            "<div id=f style='display:table-cell;width:13px;height:5px'></div>" ++
            "</div></div></body></html>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root_node = try html_parser.parse();
    defer root_node.deinit(allocator);
    parser.fixParentPointers(&root_node, null);
    try parser.style(allocator, &root_node, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root_node, &nodes);
    var table_node: ?*Node = null;
    var a_node: ?*Node = null;
    var b_node: ?*Node = null;
    var c_node: ?*Node = null;
    var d_node: ?*Node = null;
    var rows_node: ?*Node = null;
    var row_node: ?*Node = null;
    var e_node: ?*Node = null;
    var f_node: ?*Node = null;
    for (nodes.items) |node| switch (node.*) {
        .element => |*element| {
            const id = (element.attributes orelse continue).get("id") orelse continue;
            if (std.mem.eql(u8, id, "table")) table_node = node;
            if (std.mem.eql(u8, id, "a")) a_node = node;
            if (std.mem.eql(u8, id, "b")) b_node = node;
            if (std.mem.eql(u8, id, "c")) c_node = node;
            if (std.mem.eql(u8, id, "d")) d_node = node;
            if (std.mem.eql(u8, id, "rows")) rows_node = node;
            if (std.mem.eql(u8, id, "row")) row_node = node;
            if (std.mem.eql(u8, id, "e")) e_node = node;
            if (std.mem.eql(u8, id, "f")) f_node = node;
        },
        .text => {},
    };

    const table: *BlockLayout = @ptrCast(@alignCast(table_node.?.element.layout_ptr.?));
    const a: *BlockLayout = @ptrCast(@alignCast(a_node.?.element.layout_ptr.?));
    const b: *BlockLayout = @ptrCast(@alignCast(b_node.?.element.layout_ptr.?));
    const c: *BlockLayout = @ptrCast(@alignCast(c_node.?.element.layout_ptr.?));
    const d: *BlockLayout = @ptrCast(@alignCast(d_node.?.element.layout_ptr.?));
    try std.testing.expectEqual(@as(i32, 70), table.width.get().*);
    try std.testing.expectEqual(@as(i32, 13), table.height.get().*);
    try std.testing.expectEqual(table.x.get().*, a.x.get().*);
    try std.testing.expectEqual(a.x.get().* + 11, b.x.get().*);
    try std.testing.expectEqual(b.x.get().* + 17, c.x.get().*);
    try std.testing.expectEqual(c.x.get().* + 19, d.x.get().*);
    try std.testing.expectEqual(@as(i32, 13), c.height.get().*);
    try std.testing.expect(a.previousBlock() == null);
    try std.testing.expect(b.previousBlock() == null);
    try std.testing.expect(c.previousBlock() == null);
    try std.testing.expect(d.previousBlock() == null);
    try std.testing.expect(!table_node.?.element.canReuseLayoutForInsert(1));

    const rows: *BlockLayout = @ptrCast(@alignCast(rows_node.?.element.layout_ptr.?));
    const row: *BlockLayout = @ptrCast(@alignCast(row_node.?.element.layout_ptr.?));
    const e: *BlockLayout = @ptrCast(@alignCast(e_node.?.element.layout_ptr.?));
    const f: *BlockLayout = @ptrCast(@alignCast(f_node.?.element.layout_ptr.?));
    try std.testing.expectEqual(@as(i32, 20), rows.width.get().*);
    try std.testing.expectEqual(@as(i32, 9), rows.height.get().*);
    try std.testing.expectEqual(rows.x.get().*, row.x.get().*);
    try std.testing.expectEqual(@as(i32, 20), row.width.get().*);
    try std.testing.expectEqual(row.x.get().*, e.x.get().*);
    try std.testing.expectEqual(e.x.get().* + 7, f.x.get().*);
    try std.testing.expectEqual(@as(i32, 9), f.height.get().*);
    try std.testing.expect(e.previousBlock() == null);
    try std.testing.expect(f.previousBlock() == null);
}

test "list items reserve room for square markers" {
    const allocator = std.testing.allocator;
    var item = Node{ .element = try parser.Element.init(allocator, "LI", null) };
    defer item.deinit(allocator);
    try std.testing.expect(isListItemElement(&item.element));

    try setTestDisplay(allocator, &item, "list-item");
    try std.testing.expect(usesListItemMarker(&item.element));

    const bounds = contentBoundsForNode(item, 13, 100, list_item_indent);
    try std.testing.expectEqual(@as(i32, 37), bounds.x);
    try std.testing.expectEqual(@as(i32, 76), bounds.width);

    item.element.style.?.getPtr("display").?.set("block");
    try std.testing.expect(!usesListItemMarker(&item.element));
    const unmarked_bounds = contentBoundsForNode(item, 13, 100, list_item_indent);
    try std.testing.expectEqual(@as(i32, 13), unmarked_bounds.x);
    try std.testing.expectEqual(@as(i32, 100), unmarked_bounds.width);
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
    block.x = ProtectedField(i32).init(10);
    defer block.x.deinit(allocator);
    block.width = ProtectedField(i32).init(100);
    defer block.width.deinit(allocator);
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

    var inline_form = Node{ .element = try parser.Element.init(allocator, "form", null) };
    defer inline_form.deinit(allocator);
    try setTestDisplay(allocator, &inline_form, "inline");
    var form_paragraph = Node{ .element = try parser.Element.init(allocator, "p", &inline_form) };
    var form_paragraph_owned = true;
    errdefer if (form_paragraph_owned) form_paragraph.deinit(allocator);
    try setTestDisplay(allocator, &form_paragraph, "block");
    try inline_form.element.children.append(allocator, form_paragraph);
    form_paragraph_owned = false;
    parser.fixParentPointers(&inline_form, null);
    try std.testing.expect(isContainerNode(inline_form, null));
}

test "append-only block layout retains its existing child objects after DOM relocation" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main style='display:block'>" ++
            "<section id=target style='display:block'>" ++
            "<div id=one style='display:block'></div>" ++
            "<div id=two style='display:block'></div>" ++
            "</section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root_node = try html_parser.parse();
    defer root_node.deinit(allocator);
    parser.fixParentPointers(&root_node, null);
    try parser.style(allocator, &root_node, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root_node, &nodes);
    var target: ?*Node = null;
    for (nodes.items) |node| switch (node.*) {
        .element => |*element| {
            const attributes = element.attributes orelse continue;
            if (std.mem.eql(u8, attributes.get("id") orelse "", "target")) {
                target = node;
                break;
            }
        },
        .text => {},
    };
    const target_node = target.?;
    const target_layout: *BlockLayout = @ptrCast(@alignCast(target_node.element.layout_ptr.?));
    try std.testing.expect(target_node.element.canReuseLayoutForInsert(2));
    try std.testing.expectEqual(@as(usize, 2), target_layout.children.items.len);
    const first_layout = target_layout.children.items[0].block;
    const second_layout = target_layout.children.items[1].block;
    const prior_epoch = target_layout.children_epoch;
    const old_children_ptr = target_node.element.children.items.ptr;

    var appended = Node{ .element = try parser.Element.init(
        allocator,
        "div id=three style='display:block'",
        null,
    ) };
    var appended_owned = true;
    defer if (appended_owned) appended.deinit(allocator);

    target_node.element.markChildInserted();
    parser.dirtyStyleForElement(&target_node.element);
    target_node.element.layout_mark.?(target_node.element.layout_ptr.?);

    // Allocate the replacement while the old buffer is live. This guarantees
    // a different address and exercises the synchronous raw-pointer repair,
    // rather than relying on allocator-specific ArrayList growth behavior.
    var relocated = std.ArrayList(Node).empty;
    defer relocated.deinit(allocator);
    try relocated.ensureTotalCapacityPrecise(
        allocator,
        target_node.element.children.items.len + 1,
    );
    for (target_node.element.children.items) |child| {
        relocated.appendAssumeCapacity(child);
    }
    relocated.appendAssumeCapacity(appended);
    appended_owned = false;
    target_node.element.children.deinit(allocator);
    target_node.element.children = relocated;
    relocated = std.ArrayList(Node).empty;
    parser.fixParentPointers(&root_node, null);

    try std.testing.expect(old_children_ptr != target_node.element.children.items.ptr);
    try std.testing.expect(target_node.element.rebindLayoutAfterInsert(target_node));
    try std.testing.expect(first_layout.node_ptr.? == &target_node.element.children.items[0]);
    try std.testing.expect(second_layout.node_ptr.? == &target_node.element.children.items[1]);

    // A second append before layout keeps the original represented prefix and
    // accumulates both new DOM nodes into one suffix.
    try std.testing.expect(target_node.element.canReuseLayoutForInsert(3));
    var fourth = Node{ .element = try parser.Element.init(
        allocator,
        "div id=four style='display:block'",
        null,
    ) };
    var fourth_owned = true;
    defer if (fourth_owned) fourth.deinit(allocator);
    target_node.element.markChildInserted();
    try target_node.element.children.ensureUnusedCapacity(allocator, 1);
    target_node.element.children.appendAssumeCapacity(fourth);
    fourth_owned = false;
    parser.fixParentPointers(&root_node, null);
    try std.testing.expect(target_node.element.rebindLayoutAfterInsert(target_node));

    parser.dirtyStyleSubtree(&target_node.element.children.items[2]);
    parser.dirtyStyleSubtree(&target_node.element.children.items[3]);
    try parser.style(allocator, &root_node, &.{});

    // Model resource refresh republishing an equivalent computed display
    // slice from new stylesheet backing. It dirties children_version, but the
    // matcher should validate the unchanged block shape and still reuse the
    // prefix.
    const republished_display = try allocator.dupe(u8, "block");
    if (target_node.element.children.items[0].element.owned_strings == null) {
        target_node.element.children.items[0].element.owned_strings =
            std.ArrayList([]const u8).empty;
    }
    try target_node.element.children.items[0].element.owned_strings.?.append(
        allocator,
        republished_display,
    );
    target_node.element.children.items[0].element.style.?.getPtr("display").?.set(
        republished_display,
    );
    try std.testing.expect(target_layout.children_version.dirty);
    try document.layout(engine);

    try std.testing.expectEqual(@as(usize, 4), target_layout.children.items.len);
    try std.testing.expect(target_layout.children.items[0].block == first_layout);
    try std.testing.expect(target_layout.children.items[1].block == second_layout);
    try std.testing.expect(
        target_layout.children.items[2].block.node_ptr.? ==
            &target_node.element.children.items[2],
    );
    try std.testing.expect(target_layout.children.items[2].block.previousBlock() == second_layout);
    try std.testing.expect(
        target_layout.children.items[3].block.node_ptr.? ==
            &target_node.element.children.items[3],
    );
    try std.testing.expect(
        target_layout.children.items[3].block.previousBlock() ==
            target_layout.children.items[2].block,
    );
    try std.testing.expectEqual(prior_epoch + 1, target_layout.children_epoch);
    try std.testing.expectEqual(@as(usize, 4), target_layout.laid_out_dom_children);
    try std.testing.expect(!target_node.element.children_dirty);
    try std.testing.expect(!target_node.element.children_insertions_only);
}

test "inserted block matches siblings and invalidates only the changed previous link" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main style='display:block'>" ++
            "<section id=target style='display:block'>" ++
            "<div id=one style='display:block;height:10px'></div>" ++
            "<div id=two style='display:block;height:10px'></div>" ++
            "<div id=three style='display:block;height:10px'></div>" ++
            "</section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root_node = try html_parser.parse();
    defer root_node.deinit(allocator);
    parser.fixParentPointers(&root_node, null);
    try parser.style(allocator, &root_node, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root_node, &nodes);
    var target: ?*Node = null;
    for (nodes.items) |node| switch (node.*) {
        .element => |*element| {
            const attributes = element.attributes orelse continue;
            if (std.mem.eql(u8, attributes.get("id") orelse "", "target")) {
                target = node;
                break;
            }
        },
        .text => {},
    };
    const target_node = target.?;
    const target_layout: *BlockLayout = @ptrCast(@alignCast(target_node.element.layout_ptr.?));
    const first_layout = target_layout.children.items[0].block;
    const second_layout = target_layout.children.items[1].block;
    const third_layout = target_layout.children.items[2].block;
    const second_y_before = second_layout.y.get().*;
    const third_y_before = third_layout.y.get().*;
    const prior_epoch = target_layout.children_epoch;

    try std.testing.expect(first_layout.previousBlock() == null);
    try std.testing.expect(second_layout.previousBlock() == first_layout);
    try std.testing.expect(third_layout.previousBlock() == second_layout);
    try std.testing.expect(second_layout.previous.invalidations.contains(&second_layout.y));
    try std.testing.expect(target_node.element.canReuseLayoutForInsert(1));

    var inserted = Node{ .element = try parser.Element.init(
        allocator,
        "div id=inserted style='display:block;height:7px'",
        null,
    ) };
    var inserted_owned = true;
    defer if (inserted_owned) inserted.deinit(allocator);

    target_node.element.markChildInserted();
    parser.dirtyStyleForElement(&target_node.element);
    target_node.element.layout_mark.?(target_node.element.layout_ptr.?);

    var relocated = std.ArrayList(Node).empty;
    defer relocated.deinit(allocator);
    try relocated.ensureTotalCapacityPrecise(
        allocator,
        target_node.element.children.items.len + 1,
    );
    relocated.appendAssumeCapacity(target_node.element.children.items[0]);
    relocated.appendAssumeCapacity(inserted);
    inserted_owned = false;
    for (target_node.element.children.items[1..]) |child| relocated.appendAssumeCapacity(child);
    target_node.element.children.deinit(allocator);
    target_node.element.children = relocated;
    relocated = std.ArrayList(Node).empty;
    parser.fixParentPointers(&root_node, null);
    try std.testing.expect(target_node.element.rebindLayoutAfterInsert(target_node));
    parser.dirtyStyleSubtree(&target_node.element.children.items[1]);

    try parser.style(allocator, &root_node, &.{});
    try document.layout(engine);

    try std.testing.expectEqual(@as(usize, 4), target_layout.children.items.len);
    try std.testing.expect(target_layout.children.items[0].block == first_layout);
    const inserted_layout = target_layout.children.items[1].block;
    try std.testing.expect(target_layout.children.items[2].block == second_layout);
    try std.testing.expect(target_layout.children.items[3].block == third_layout);
    try std.testing.expect(inserted_layout.previousBlock() == first_layout);
    try std.testing.expect(second_layout.previousBlock() == inserted_layout);
    try std.testing.expect(third_layout.previousBlock() == second_layout);
    try std.testing.expect(inserted_layout.height.invalidations.contains(&second_layout.y));
    try std.testing.expectEqual(second_y_before + 7, second_layout.y.get().*);
    try std.testing.expectEqual(third_y_before + 7, third_layout.y.get().*);
    try std.testing.expectEqual(prior_epoch + 1, target_layout.children_epoch);
    try std.testing.expect(!target_node.element.children_dirty);
    try std.testing.expect(!target_node.element.children_insertions_only);
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

test "floating inline nodes become block containers" {
    const allocator = std.testing.allocator;
    var floating_inline = Node{ .element = try parser.Element.init(allocator, "span", null) };
    defer floating_inline.deinit(allocator);
    try setTestStyleValue(allocator, &floating_inline, "float", "left");

    try std.testing.expect(isContainerNode(floating_inline, null));
}

test "float exclusions use margin boxes and stop at the float bottom" {
    const allocator = std.testing.allocator;
    var root_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer root_node.deinit(allocator);

    const document = try DocumentLayout.init(allocator, &root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const root = try BlockLayout.init(allocator, root_node, &root_node, document, null, null);
    try document.children.append(allocator, root);
    try root.floats.append(allocator, .{
        .side = .left,
        .x = 50,
        .y = 20,
        .width = 40,
        .height = 30,
        .margin = .{ .top = 5, .right = 6, .bottom = 7, .left = 8 },
    });

    const narrowed = root.floatBoundsAt(20, 10, 200);
    try std.testing.expectEqual(@as(i32, 96), narrowed.x);
    try std.testing.expectEqual(@as(i32, 114), narrowed.width);
    try std.testing.expectEqual(@as(i32, 57), root.clearBottom(10, .left));
    const restored = root.floatBoundsAt(57, 10, 200);
    try std.testing.expectEqual(@as(i32, 10), restored.x);
    try std.testing.expectEqual(@as(i32, 200), restored.width);
}

test "non-formatting blocks share their nearest float context" {
    const allocator = std.testing.allocator;
    var root_node = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer root_node.deinit(allocator);
    var transparent_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer transparent_node.deinit(allocator);
    try setTestStyleValue(allocator, &transparent_node, "overflow", "visible");
    var float_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer float_node.deinit(allocator);
    try setTestStyleValue(allocator, &float_node, "float", "left");
    var clipped_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer clipped_node.deinit(allocator);
    try setTestStyleValue(allocator, &clipped_node, "overflow", "hidden");

    const document = try DocumentLayout.init(allocator, &root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const root = try BlockLayout.init(allocator, root_node, &root_node, document, null, null);
    try document.children.append(allocator, root);
    const transparent = try BlockLayout.init(
        allocator,
        transparent_node,
        &transparent_node,
        document,
        root,
        null,
    );
    try root.children.append(allocator, .{ .block = transparent });
    const floating = try BlockLayout.init(
        allocator,
        float_node,
        &float_node,
        document,
        transparent,
        null,
    );
    try transparent.children.append(allocator, .{ .block = floating });
    const clipped = try BlockLayout.init(
        allocator,
        clipped_node,
        &clipped_node,
        document,
        transparent,
        null,
    );
    try transparent.children.append(allocator, .{ .block = clipped });

    try std.testing.expect(root.establishesFloatContext());
    try std.testing.expect(!transparent.establishesFloatContext());
    try std.testing.expect(transparent.floatContextForChildren() == root);
    try std.testing.expect(floating.establishesFloatContext());
    try std.testing.expect(floating.floatContextForChildren() == floating);
    try std.testing.expect(clipped.establishesFloatContext());
    try std.testing.expect(clipped.floatContextForChildren() == clipped);
}

test "nested floats place and clear in a shared context after invalidation" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html style='display:block'><body style='display:block;margin:0'>" ++
            "<main id=stage style='display:block;width:180px'>" ++
            "<div id=wrapper style='display:block'>" ++
            "<div id=a style='display:block;float:left;width:60px;height:40px'></div>" ++
            "<div id=b style='display:block;float:left;width:60px;height:40px'></div>" ++
            "</div>" ++
            "<div id=c style='display:block;float:left;width:60px;height:40px'></div>" ++
            "<div id=empty style='display:block;margin:120px 0'>" ++
            "<div style='display:block;margin:0 0 -116px'></div></div>" ++
            "<p id=clear style='display:block;clear:both;height:10px'></p>" ++
            "</main></body></html>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root_node = try html_parser.parse();
    defer root_node.deinit(allocator);
    parser.fixParentPointers(&root_node, null);
    try parser.style(allocator, &root_node, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root_node, &nodes);
    var wrapper_node: ?*Node = null;
    var first_float_node: ?*Node = null;
    var third_float_node: ?*Node = null;
    var empty_node: ?*Node = null;
    var clear_node: ?*Node = null;
    for (nodes.items) |node| switch (node.*) {
        .element => |*element| {
            const attributes = element.attributes orelse continue;
            const id = attributes.get("id") orelse continue;
            if (std.mem.eql(u8, id, "wrapper")) wrapper_node = node;
            if (std.mem.eql(u8, id, "a")) first_float_node = node;
            if (std.mem.eql(u8, id, "c")) third_float_node = node;
            if (std.mem.eql(u8, id, "empty")) empty_node = node;
            if (std.mem.eql(u8, id, "clear")) clear_node = node;
        },
        .text => {},
    };

    const wrapper: *BlockLayout = @ptrCast(@alignCast(wrapper_node.?.element.layout_ptr.?));
    const first_float: *BlockLayout = @ptrCast(@alignCast(first_float_node.?.element.layout_ptr.?));
    const third_float: *BlockLayout = @ptrCast(@alignCast(third_float_node.?.element.layout_ptr.?));
    const empty: *BlockLayout = @ptrCast(@alignCast(empty_node.?.element.layout_ptr.?));
    const clearing: *BlockLayout = @ptrCast(@alignCast(clear_node.?.element.layout_ptr.?));
    try std.testing.expectEqual(@as(i32, 0), wrapper.height.get().*);
    try std.testing.expect(empty.normal_flow_result.?.collapses_through);
    try std.testing.expectEqual(first_float.y.get().*, third_float.y.get().*);
    try std.testing.expectEqual(
        first_float.y.get().* + first_float.height.get().*,
        clearing.y.get().*,
    );

    first_float_node.?.element.style.?.getPtr("height").?.set("80px");
    try document.layout(engine);
    try std.testing.expectEqual(@as(i32, 0), wrapper.height.get().*);
    try std.testing.expect(empty.normal_flow_result.?.collapses_through);
    try std.testing.expectEqual(first_float.y.get().*, third_float.y.get().*);
    try std.testing.expectEqual(
        first_float.y.get().* + first_float.height.get().*,
        clearing.y.get().*,
    );
}

test "float paint phases keep normal backgrounds below floats" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html style='display:block'><body style='display:block;margin:0'>" ++
            "<main id=stage style='display:block;width:120px'>" ++
            "<div id=float style='display:block;float:left;width:40px;height:24px;background-color:#ff0000'></div>" ++
            "<div id=under style='display:block;height:24px;background-color:#0000ff'></div>" ++
            "</main>" ++
            "<main id=bfc-stage style='display:block;width:120px'>" ++
            "<div id=bfc-float style='display:block;float:left;width:40px;height:24px;background-color:#ff0000'></div>" ++
            "<div id=bfc style='display:block;overflow:hidden;height:24px;background-color:#00ff00'></div>" ++
            "</main></body></html>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root_node = try html_parser.parse();
    defer root_node.deinit(allocator);
    parser.fixParentPointers(&root_node, null);
    try parser.style(allocator, &root_node, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root_node, &nodes);
    var stage: ?*BlockLayout = null;
    var float: ?*BlockLayout = null;
    var under: ?*BlockLayout = null;
    var bfc_float: ?*BlockLayout = null;
    var bfc: ?*BlockLayout = null;
    for (nodes.items) |node| switch (node.*) {
        .element => |*element| {
            const attributes = element.attributes orelse continue;
            const id = attributes.get("id") orelse continue;
            const layout: *BlockLayout = @ptrCast(@alignCast(element.layout_ptr.?));
            if (std.mem.eql(u8, id, "stage")) stage = layout;
            if (std.mem.eql(u8, id, "float")) float = layout;
            if (std.mem.eql(u8, id, "under")) under = layout;
            if (std.mem.eql(u8, id, "bfc-float")) bfc_float = layout;
            if (std.mem.eql(u8, id, "bfc")) bfc = layout;
        },
        .text => {},
    };

    // A normal-flow block's border box stays at the containing-block origin
    // and width. Its inline ranges, not this box, wrap around the red float.
    try std.testing.expectEqual(float.?.x.get().*, under.?.x.get().*);
    try std.testing.expectEqual(stage.?.width.get().*, under.?.width.get().*);
    // A new overflow formatting context is the contrasting case: it avoids
    // the external float as a whole used border box.
    try std.testing.expectEqual(
        bfc_float.?.x.get().* + bfc_float.?.width.get().*,
        bfc.?.x.get().*,
    );
    try std.testing.expectEqual(
        stage.?.width.get().* - bfc_float.?.width.get().*,
        bfc.?.width.get().*,
    );

    const frame = try engine.paintDocument(document);
    defer DisplayItem.freeList(allocator, frame);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try writeDisplayListDebug(&output.writer, frame);
    const blue_background = std.mem.indexOf(u8, output.written(), "color=#0000ffff").?;
    const red_float = std.mem.indexOf(u8, output.written(), "color=#ff0000ff").?;
    try std.testing.expect(blue_background < red_float);
}

// Layout state
allocator: std.mem.Allocator,
// Font manager for handling fonts and glyphs
font_manager: font.FontManager,
window_width: i32,
window_height: i32,
default_direction: TextDirection = .left_to_right,
line_direction: TextDirection = .left_to_right,
line_alignment: LineAlignment = .start,
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
/// Computed CSS font size in CSS pixels. `size` retains the historical
/// font-raster unit used by this layout engine; relative lengths use this
/// unrounded CSS value as their `em` base.
font_size_css: f64 = 16.0,
/// Explicit CSS line-height in CSS pixels. A null value represents `normal`;
/// unitless values are resolved against the current element's font size.
line_height_css: ?f64 = null,
cursor_x: i32,
cursor_y: i32,
line_left: i32,
line_right: i32,
is_bold: bool = false,
is_italic: bool = false,
font_family: FontFamily = .proportional,
/// CSS `font-variant: small-caps`; semantic elements such as `abbr` keep
/// their separate state in `is_small_caps` so nested styles do not erase it.
css_small_caps: bool = false,
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
// Document-space boxes/anchors for HTML images. Frames retain a copy after
// layout so lazy loading can select nearby images without borrowing layouts.
image_bounds: std.AutoHashMap(*Node, Bounds),
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
last_was_collapsible_space: bool = false,
prev_font_category: ?FontCategory = null,
current_font_category: FontCategory = .latin,

const InlineSnapshot = struct {
    cursor_x: i32,
    cursor_y: i32,
    line_left: i32,
    line_right: i32,
    size: i32,
    font_size_css: f64,
    line_height_css: ?f64,
    is_bold: bool,
    is_italic: bool,
    font_family: FontFamily,
    css_small_caps: bool,
    is_title: bool,
    is_superscript: bool,
    is_small_caps: bool,
    is_preformatted: bool,
    last_was_collapsible_space: bool,
    prev_font_category: ?FontCategory,
    current_font_category: FontCategory,
    text_color: browser.Color,
    line_direction: TextDirection,
    line_alignment: LineAlignment,
    effective_zoom: f32,
};

fn snapshotInlineState(self: *const Layout) InlineSnapshot {
    return InlineSnapshot{
        .cursor_x = self.cursor_x,
        .cursor_y = self.cursor_y,
        .line_left = self.line_left,
        .line_right = self.line_right,
        .size = self.size,
        .font_size_css = self.font_size_css,
        .line_height_css = self.line_height_css,
        .is_bold = self.is_bold,
        .is_italic = self.is_italic,
        .font_family = self.font_family,
        .css_small_caps = self.css_small_caps,
        .is_title = self.is_title,
        .is_superscript = self.is_superscript,
        .is_small_caps = self.is_small_caps,
        .is_preformatted = self.is_preformatted,
        .last_was_collapsible_space = self.last_was_collapsible_space,
        .prev_font_category = self.prev_font_category,
        .current_font_category = self.current_font_category,
        .text_color = self.text_color,
        .line_direction = self.line_direction,
        .line_alignment = self.line_alignment,
        .effective_zoom = self.effective_zoom,
    };
}

fn restoreInlineState(self: *Layout, snapshot: InlineSnapshot) void {
    self.cursor_x = snapshot.cursor_x;
    self.cursor_y = snapshot.cursor_y;
    self.line_left = snapshot.line_left;
    self.line_right = snapshot.line_right;
    self.size = snapshot.size;
    self.font_size_css = snapshot.font_size_css;
    self.line_height_css = snapshot.line_height_css;
    self.is_bold = snapshot.is_bold;
    self.is_italic = snapshot.is_italic;
    self.font_family = snapshot.font_family;
    self.css_small_caps = snapshot.css_small_caps;
    self.is_title = snapshot.is_title;
    self.is_superscript = snapshot.is_superscript;
    self.is_small_caps = snapshot.is_small_caps;
    self.is_preformatted = snapshot.is_preformatted;
    self.last_was_collapsible_space = snapshot.last_was_collapsible_space;
    self.prev_font_category = snapshot.prev_font_category;
    self.current_font_category = snapshot.current_font_category;
    self.text_color = snapshot.text_color;
    self.line_direction = snapshot.line_direction;
    self.line_alignment = snapshot.line_alignment;
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

fn lineHeightForNatural(self: *const Layout, natural_height: i32) i32 {
    const natural = @max(natural_height, 1);
    if (self.line_height_css) |line_height_css| {
        const scaled = self.scaleActiveCssFloat(line_height_css);
        if (!std.math.isFinite(scaled)) return natural;
        const scaled_layout: i32 = @intFromFloat(std.math.clamp(
            scaled,
            0.0,
            @as(f64, @floatFromInt(std.math.maxInt(i32))),
        ));
        return @max(scaled_layout, natural);
    }

    const extra_leading: i32 = @intFromFloat(@as(f32, @floatFromInt(natural)) * 0.25);
    return natural + extra_leading;
}

const resolveLineHeightCss = inline_format.resolveLineHeightCss;

fn fontWeightIsBold(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "bold") or
        std.ascii.eqlIgnoreCase(trimmed, "bolder")) return true;
    const numeric = std.fmt.parseInt(u16, trimmed, 10) catch return false;
    return numeric >= 600;
}

fn containingBlockCssDimension(self: *const Layout, height: bool) ?f64 {
    const inline_block = self.inline_block orelse return null;
    // Anonymous inline-run blocks are implementation details; their
    // containing block is the real parent block, whose definite height may
    // already be published for percentage-height descendants.
    const block = if (inline_block.inline_nodes != null)
        inline_block.parent_block orelse inline_block
    else
        inline_block;
    if (height and !block.content_height_definite) return null;
    if (height and block.height.dirty) return null;
    const layout_value = if (height) block.content_height else block.content_width;
    if (layout_value < 0 or (height and layout_value <= 0)) return null;
    return cssPixelsFromLayout(layout_value, block.zoom.get().*, block.document.page_zoom);
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

fn layoutWindowHeight(self: *const Layout) i32 {
    return self.toLayoutPx(self.window_height);
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
        .image_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
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
    self.image_bounds.deinit();
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
            } else if (elementUsesImageLayout(&e)) {
                try self.handleImageElement(node, node_ptr, line_buffer);
            } else if (std.ascii.eqlIgnoreCase(e.tag, "canvas")) {
                try self.handleCanvasElement(node_ptr, line_buffer);
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

/// `<img>` always establishes an atomic replaced box, including while its
/// pixels are pending. `<object>` does so only after an image resource decoded;
/// otherwise its ordinary children remain the rendered fallback subtree.
fn elementUsesImageLayout(element: *const parser.Element) bool {
    if (std.ascii.eqlIgnoreCase(element.tag, "img")) return true;
    if (!std.ascii.eqlIgnoreCase(element.tag, "object")) return false;
    const data = element.image_data orelse return false;
    return !data.is_broken;
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

    const style_map = if (node == .element) blk: {
        if (node.element.style) |*map| break :blk map;
        break :blk null;
    } else null;
    if (style_map) |styles| registerReplacedSizeDependencies(self, styles);

    const loaded_data = element.image_data;
    const image_data: ?parser.ImageData = if (loaded_data) |data|
        if (!data.is_broken or image_loader.shouldShowBrokenImage(&element)) data else null
    else
        null;
    const intrinsic_size: ?replaced_sizing.Size = if (image_data) |data| .{
        .width = @intCast(data.image.width),
        .height = @intCast(data.image.height),
    } else null;
    const box = replaced_sizing.imageSizeWithContext(&element, intrinsic_size, .{
        .font_size = self.font_size_css,
        .percentage_width = self.containingBlockCssDimension(false),
        .percentage_height = self.containingBlockCssDimension(true),
    });
    const layout_width = self.scaleActiveCssPixel(box.width);
    const layout_height = self.scaleActiveCssPixel(box.height);
    const intrinsic_width = self.scaleActiveCssPixel(if (intrinsic_size) |size| size.width else 0);
    const intrinsic_height = self.scaleActiveCssPixel(if (intrinsic_size) |size| size.height else 0);
    const edges = if (style_map) |styles|
        resolveBoxEdges(
            styles,
            self.font_size_css,
            self.containingBlockCssDimension(false),
            self.effectiveZoom(),
            self.zoom(),
        )
    else
        BoxModelEdges{ .margin = .{}, .padding = .{}, .border = .{} };

    if (layout_width < 0 or layout_height < 0 or
        (layout_width == 0 and layout_height == 0))
    {
        // An intrinsic-only unloaded image has no dimensions, but it still
        // needs a stable position at which scrolling can discover it. The
        // one-pixel anchor is visibility metadata, not occupied layout.
        if (self.collect_hit_test_bounds) {
            if (node_ptr) |ptr| {
                try self.image_bounds.put(ptr, .{
                    .x = self.cursor_x + self.transform_offset_x,
                    .y = self.cursor_y + self.transform_offset_y,
                    .width = 1,
                    .height = 1,
                });
            }
        }
        return;
    }

    var image_layout = ImageLayout.init(
        self.allocator,
        layout_width,
        layout_height,
        intrinsic_width,
        intrinsic_height,
        image_data,
        self.inline_block,
        style_map,
        self.effectiveZoom(),
        edges,
        self.scaleActiveCssFloat(1.0),
    );
    try image_layout.embed.appendImagePlaceholder(self, line_buffer, node_ptr, .{
        .image = image_layout,
    });
}

fn handleIframeElement(self: *Layout, node: Node, node_ptr: ?*Node, line_buffer: *std.ArrayList(LineItem)) !void {
    const element = switch (node) {
        .element => |e| e,
        else => return,
    };
    self.resetSoftHyphenWord();

    const style_map = if (node == .element) blk: {
        if (node.element.style) |*map| break :blk map;
        break :blk null;
    } else null;
    if (style_map) |styles| registerReplacedSizeDependencies(self, styles);

    const box = replaced_sizing.iframeSizeWithContext(&element, .{
        .font_size = self.font_size_css,
        .percentage_width = self.containingBlockCssDimension(false),
        .percentage_height = self.containingBlockCssDimension(true),
    });
    const layout_width = self.scaleActiveCssPixel(box.width);
    const layout_height = self.scaleActiveCssPixel(box.height);

    if (layout_width <= 0 or layout_height <= 0) return;

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

fn handleCanvasElement(
    self: *Layout,
    node_ptr: ?*Node,
    line_buffer: *std.ArrayList(LineItem),
) !void {
    const canvas_node = node_ptr orelse return;
    if (canvas_node.* != .element) return;
    const element = &canvas_node.element;
    self.resetSoftHyphenWord();

    const dimensions = element.canvasDimensions();
    if (element.canvas) |canvas| try canvas.resize(dimensions.width, dimensions.height);

    const layout_width = self.scaleActiveCssPixel(dimensions.width);
    const layout_height = self.scaleActiveCssPixel(dimensions.height);
    if (layout_width <= 0 or layout_height <= 0) return;

    var canvas_layout = CanvasLayout.init(
        self.allocator,
        layout_width,
        layout_height,
        dimensions.width,
        dimensions.height,
        element,
        self.effectiveZoom(),
    );
    try canvas_layout.embed.appendInline(self, line_buffer, canvas_node, .{
        .canvas = canvas_layout,
    });
}

const StyleSnapshot = struct {
    is_bold: bool,
    is_italic: bool,
    font_family: FontFamily,
    size: i32,
    font_size_css: f64,
    line_height_css: ?f64,
    css_small_caps: bool,
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
        return field.read(notify, style_map.allocator).*;
    }
    return null;
}

fn registerStyleDependencies(
    style_map: *const parser.StyleMap,
    target: *ProtectedField(i32),
) void {
    var iterator = @constCast(style_map).iterator();
    while (iterator.next()) |entry| target.addDependency(entry.value_ptr, style_map.allocator);
}

fn registerReplacedSizeDependencies(self: *Layout, style_map: *const parser.StyleMap) void {
    const block = self.inline_block orelse return;
    const target = if (block.persistent_dependencies)
        &block.height
    else
        block.temporary_dependency_target orelse return;
    _ = styleValueRead(style_map, "width", target);
    _ = styleValueRead(style_map, "height", target);
    _ = styleValueRead(style_map, "aspect-ratio", target);
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

/// Resolve live compositor-visible values from the current DOM generation.
/// Neither hit testing nor paint wrapping may retain the returned style slice.
fn resolvedBlockEffects(block: *const BlockLayout) paint_effects.ResolvedEffects {
    return paint_effects.resolveElement(
        liveBlockElement(block),
        block.zoom.get().*,
        block.document.page_zoom,
    );
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

/// Return whether this block establishes its own normal-flow box alongside
/// external floats. Ordinary blocks keep their containing-block width and
/// only their inline line boxes flow around outside floats. Tables and
/// non-visible overflow boxes instead establish a bounded formatting context,
/// so their border boxes avoid the surrounding float area.
fn blockAvoidsExternalFloats(block: *const BlockLayout) bool {
    if (block.tableRole() == .table) return true;
    const element = liveBlockElement(block) orelse return false;
    const styles = if (element.style) |*style_map| style_map else return false;
    const overflow = std.mem.trim(
        u8,
        styleValue(styles, "overflow") orelse "visible",
        " \t\r\n",
    );
    return !std.ascii.eqlIgnoreCase(overflow, "visible");
}

/// A static, effect-free child can be split into its background/border phase
/// and its content phase when a sibling float is present. Keep every more
/// complex subtree atomic: its existing effect wrapper remains the authority
/// for clipping, blending, transforms, positioned stacking, and scrolling.
fn isFloatPaintPhaseCandidate(block: *const BlockLayout) bool {
    if (block.floatSide() != .none or block.positionMode() != .static) return false;
    if (block.tableRole() != .ordinary or blockAvoidsExternalFloats(block)) return false;
    const effects = resolvedBlockEffects(block);
    return !effects.needsBlendGroup() and effects.translation == null;
}

/// The bounded float painter only reorders a simple direct-sibling context.
/// If any sibling needs independent stacking or an effect wrapper, retain the
/// established atomic subtree ordering instead of partially splitting it.
fn usesFloatPaintPhases(block: *const BlockLayout) bool {
    var has_float = false;
    for (block.children.items) |child| switch (child) {
        .block => |nested| {
            if (nested.floatSide() != .none) {
                has_float = true;
            } else if (!isFloatPaintPhaseCandidate(nested)) {
                return false;
            }
        },
        .line => {},
    };
    return has_float;
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
        .font_size_css = self.font_size_css,
        .line_height_css = self.line_height_css,
        .css_small_caps = self.css_small_caps,
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
                self.is_bold = fontWeightIsBold(weight_str);
            }
        } else if (styleValue(style_map, "font-weight")) |weight_str| {
            self.is_bold = fontWeightIsBold(weight_str);
        }

        // Apply font-style
        if (notify_target) |target| {
            if (styleValueRead(style_map, "font-style", target)) |style_str| {
                self.is_italic = std.ascii.eqlIgnoreCase(style_str, "italic") or
                    std.ascii.eqlIgnoreCase(style_str, "oblique");
            }
        } else if (styleValue(style_map, "font-style")) |style_str| {
            self.is_italic = std.ascii.eqlIgnoreCase(style_str, "italic") or
                std.ascii.eqlIgnoreCase(style_str, "oblique");
        }

        // Apply font-size
        const size_value = if (notify_target) |target|
            styleValueRead(style_map, "font-size", target)
        else
            styleValue(style_map, "font-size");
        if (size_value) |size_str| {
            if (parser.resolveCssLength(size_str, .{
                .font_size = self.font_size_css,
                .percentage_base = self.font_size_css,
            })) |size_float| {
                self.font_size_css = size_float;
                // Convert CSS pixels to our historical font-raster unit
                // (multiply by 0.75 for points).
                self.size = @intFromFloat(size_float * 0.75);
            }
        }

        // Line-height is inherited independently from font-size. Unitless
        // values have already retained their multiplier in computed style;
        // resolve them after the element's font-size has been applied.
        const line_height_value = if (notify_target) |target|
            styleValueRead(style_map, "line-height", target)
        else
            styleValue(style_map, "line-height");
        if (line_height_value) |line_height_str| {
            self.line_height_css = resolveLineHeightCss(line_height_str, self.font_size_css);
        }

        const variant_value = if (notify_target) |target|
            styleValueRead(style_map, "font-variant", target)
        else
            styleValue(style_map, "font-variant");
        if (variant_value) |variant_str| {
            self.css_small_caps = std.ascii.eqlIgnoreCase(
                std.mem.trim(u8, variant_str, " \t\r\n"),
                "small-caps",
            );
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
        self.font_size_css = snapshot.font_size_css;
        self.line_height_css = snapshot.line_height_css;
        self.css_small_caps = snapshot.css_small_caps;
        self.text_color = snapshot.text_color;
        self.transform_offset_x = snapshot.transform_offset_x;
        self.transform_offset_y = snapshot.transform_offset_y;
        self.color_scheme_dark = snapshot.color_scheme_dark;
        self.effective_zoom = snapshot.effective_zoom;
    }
}

const isSoftHyphenGrapheme = inline_format.isSoftHyphenGrapheme;
const isNonBreakingSpaceGrapheme = inline_format.isNonBreakingSpaceGrapheme;
const isWordSeparatorGrapheme = inline_format.isWordSeparatorGrapheme;

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
            .line_height = self.lineHeightForNatural(
                self.toLayoutPx(hyphen.ascent) + self.toLayoutPx(hyphen.descent),
            ),
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
        self.updateInlineBounds();
        self.cursor_x = self.line_left;
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
    const shift = lineAlignmentShift(
        self.line_alignment,
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
    var max_item_line_height: i32 = 0;

    for (line_buffer.items) |item| {
        max_item_line_height = @max(max_item_line_height, item.line_height);
        const is_superscript = switch (item.payload) {
            .glyph => |glyph_payload| glyph_payload.glyph.is_superscript,
            .input => false,
            .button => false,
            .image => false,
            .canvas => false,
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
    const line_height = @max(
        @max(normal_height, superscript_height),
        max_item_line_height,
    );
    const baseline = self.cursor_y + baseline_ascent;
    const line_top = self.cursor_y;
    const line_box_height = line_height;

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
            .canvas => false,
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
                if (item.payload == .image) {
                    try self.image_bounds.put(ptr, .{
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
                        .page_zoom = self.zoom(),
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
                try image_payload.paintAt(
                    self.current_display_target,
                    self,
                    item.x,
                    final_y,
                    source,
                );
            },
            .canvas => |canvas_payload| {
                const pixels = if (canvas_payload.element.canvas) |canvas|
                    try canvas.snapshot(self.allocator)
                else
                    try self.allocator.alloc(u8, 0);
                var pixels_owned = true;
                errdefer if (pixels_owned) self.allocator.free(pixels);
                try self.current_display_target.append(self.allocator, DisplayItem{
                    .canvas = .{
                        .x1 = item.x,
                        .y1 = final_y,
                        .x2 = item.x + item.width,
                        .y2 = final_y + item.height,
                        .source_width = canvas_payload.source_width,
                        .source_height = canvas_payload.source_height,
                        .pixels = pixels,
                        .owns_pixels = true,
                        .source = source,
                    },
                });
                pixels_owned = false;
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
    self.cursor_y = line_top + line_box_height;
    self.updateInlineBounds();
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
    const line_height = self.lineHeightForNatural(ascent + descent);
    self.cursor_y += line_height;
    self.updateInlineBounds();
    self.cursor_x = self.line_left;
    self.resetSoftHyphenWord();
}

fn inlineContentBounds(block: *const BlockLayout, y: i32) ContentBounds {
    const block_left = block.x.get().* + block.border.left + block.padding.left;
    const block_right = block_left +| block.content_width;
    if (block.establishesFloatContext()) {
        return .{ .x = block_left, .width = @max(block_right -| block_left, 0) };
    }

    if (block.parent_block) |parent| {
        const parent_left = parent.x.get().* + parent.border.left + parent.padding.left;
        const parent_bounds = parent.floatContextForChildrenConst().floatBoundsAt(
            y,
            parent_left,
            parent.content_width,
        );
        const left = @max(block_left, parent_bounds.x);
        const right = @min(block_right, parent_bounds.x +| parent_bounds.width);
        return .{ .x = left, .width = @max(right -| left, 0) };
    }
    return .{ .x = block_left, .width = @max(block_right -| block_left, 0) };
}

fn updateInlineBounds(self: *Layout) void {
    const block = self.inline_block orelse return;
    const bounds = inlineContentBounds(block, self.cursor_y);
    self.line_left = bounds.x;
    self.line_right = bounds.x +| bounds.width;
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
    const small_caps = options.is_small_caps or self.css_small_caps;

    // Source newlines are collapsible whitespace in normal flow. Only an
    // explicit request or a preformatted run turns one into a line break.
    if (options.force_newline or
        (self.is_preformatted and
            (std.mem.eql(u8, gme, "\n") or std.mem.eql(u8, gme, "\r"))))
    {
        try self.breakExplicitLine(line_buffer);
        return;
    }

    if (isSoftHyphenGrapheme(gme)) {
        try self.recordSoftHyphenBreak(line_buffer, node_ptr, options);
        return;
    }

    const separates_word = isWordSeparatorGrapheme(gme);
    const non_breaking_space = isNonBreakingSpaceGrapheme(gme);
    const permits_automatic_wrap = !non_breaking_space;
    // Some native fonts expose NBSP with no drawable outline and a zero
    // measured width. It shares the ordinary space glyph while retaining its
    // distinct no-wrap behavior in the formatter.
    const rendered_gme = if (non_breaking_space) " " else gme;
    if (separates_word) self.resetSoftHyphenWord();

    // Choose one font for the complete Unicode grapheme. Emoji sequences must
    // not be split across fallback fonts or rendered as separate code points.
    const category = font.getGraphemeCategory(rendered_gme);

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
    if (non_breaking_space) {
        // SDL_ttf can reject an all-whitespace render at small font sizes.
        // Borrow stable metrics from a representative glyph, keep only a
        // space-like advance, and omit pixels because whitespace is invisible.
        glyph = try self.font_manager.getStyledGlyph(
            "n",
            weight,
            slant,
            self.scaledFontSize(text_size),
            active_family,
        );
        glyph.w = @max(@divTrunc(glyph.w, 2), 1);
        glyph.pixels = null;
    } else if (small_caps) {
        const is_lowercase = isSmallCapsLowercaseGrapheme(rendered_gme);

        if (is_lowercase) {
            // Preserve combining marks in the grapheme while uppercasing its
            // ASCII base. The allocation avoids imposing a cluster-size cap.
            const upper_gme = try self.allocator.dupe(u8, rendered_gme);
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
                rendered_gme,
                weight,
                slant,
                self.scaledFontSize(text_size),
                active_family,
            );
        }
    } else {
        // Normal rendering
        glyph = try self.font_manager.getStyledGlyph(
            rendered_gme,
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

    // A collapsed source-space at the right edge is trailing whitespace, not
    // the first glyph of the next line.
    if (options.is_collapsed_space and shouldAutomaticallyWrap(
        self.is_preformatted,
        self.cursor_x,
        glyph_width,
        self.line_right,
        line_buffer.items.len > 0,
    )) {
        try self.flushLine(line_buffer);
        return;
    }

    // Check if we need to wrap (only at window edge)
    while (permits_automatic_wrap and shouldAutomaticallyWrap(
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
        .line_height = self.lineHeightForNatural(glyph_ascent + glyph_descent),
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

const lineBreakLengthAt = inline_format.lineBreakLengthAt;
const isCollapsibleWhitespaceGrapheme = inline_format.isCollapsibleWhitespaceGrapheme;

fn processNormalGrapheme(
    self: *Layout,
    gme: []const u8,
    line_buffer: *std.ArrayList(LineItem),
    node_ptr: ?*Node,
) !void {
    if (isCollapsibleWhitespaceGrapheme(gme)) {
        if (self.last_was_collapsible_space) return;
        self.last_was_collapsible_space = true;
        if (line_buffer.items.len == 0 and self.cursor_x == self.line_left) return;
        try self.processGrapheme(" ", line_buffer, node_ptr, .{
            .is_collapsed_space = true,
            .is_superscript = self.is_superscript,
            .is_small_caps = self.is_small_caps,
        });
        return;
    }

    self.last_was_collapsible_space = false;
    try self.processGrapheme(gme, line_buffer, node_ptr, .{
        .is_superscript = self.is_superscript,
        .is_small_caps = self.is_small_caps,
    });
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

    // Keep source text in Unicode grapheme clusters while stopping at entity
    // syntax. HTML source formatting whitespace collapses to one ordinary
    // space; only preformatted text preserves source line breaks.
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '&') {
            var entity_buffer: [4]u8 = undefined;
            if (lexEntityAt(content, i, &entity_buffer)) |entity| {
                try self.processNormalGrapheme(entity.replacement, line_buffer, node_ptr);

                i += entity.len;
                continue;
            }

            // An ampersand that does not begin a recognized entity is text.
            try self.processNormalGrapheme("&", line_buffer, node_ptr);
            i += 1;
            continue;
        }

        var run_end = i;
        while (run_end < content.len and content[run_end] != '&') {
            run_end += 1;
        }

        const run = content[i..run_end];
        var g_iter = grapheme.iterator(run);
        while (g_iter.next()) |gc| {
            try self.processNormalGrapheme(gc.bytes(run), line_buffer, node_ptr);
        }
        i = run_end;
    }
}

const lexEntityAt = inline_format.lexEntityAt;
pub const decodeTextForDisplay = inline_format.decodeTextForDisplay;

// Update layoutSourceCode to format HTML source with tags in normal font and content in bold
pub fn layoutSourceCode(self: *Layout, source: []const u8) ![]DisplayItem {
    self.current_display_target = &self.display_list;
    self.line_left = h_offset;
    self.line_right = self.layoutWindowWidth() - self.layoutScrollbarWidth() - h_offset;
    self.cursor_x = self.line_left;
    self.cursor_y = v_offset;
    self.line_direction = self.default_direction;
    self.line_alignment = if (self.default_direction == .right_to_left) .end else .start;
    self.size = self.default_font_size;
    self.font_size_css = @floatFromInt(self.default_font_size);
    self.line_height_css = null;
    self.css_small_caps = false;
    self.resetSoftHyphenWord();

    // Save current state
    const original_preformatted = self.is_preformatted;
    const original_font_category = self.current_font_category;
    const original_is_bold = self.is_bold;
    const original_font_family = self.font_family;
    const original_line_height_css = self.line_height_css;
    const original_css_small_caps = self.css_small_caps;

    // Start with preformatted mode on for whitespace preservation
    // but use normal font for initial state
    self.is_preformatted = true; // Keep preformatted for all content to preserve whitespace
    self.font_family = .proportional;
    self.current_font_category = .latin; // Start with normal font
    self.is_bold = false; // Start with normal weight
    self.line_height_css = null;
    self.css_small_caps = false;

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
        // View-source recognizes physical source-line boundaries even while
        // tag glyphs temporarily use normal wrapping for syntax coloring.
        const source_break_len = lineBreakLengthAt(source, i);
        if (source_break_len != 0) {
            try self.breakExplicitLine(&line_buffer);
            i += source_break_len;
            continue;
        }

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
    self.line_height_css = original_line_height_css;
    self.css_small_caps = original_css_small_caps;

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
    is_radio: bool = false,
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
        self.is_radio = element.isInputType("radio");
        self.is_checked = if (self.is_radio)
            if (element.attributes) |attributes| attributes.get("checked") != null else false
        else
            element.isChecked();
        self.is_password = element.isPasswordInput();
        const is_choice = self.is_checkbox or self.is_radio;
        if (is_choice) {
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

        if (is_choice) {
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
        var authored_width: ?i32 = null;
        var authored_height: ?i32 = null;
        if (!is_choice) {
            if (element.style) |*style_map| {
                if (resolvedPixelDimension(&element, style_map, "width", .{
                    .font_size = engine.font_size_css,
                    .percentage_base = engine.containingBlockCssDimension(false),
                })) |pixels|
                    authored_width = @max(engine.scaleActiveCssPixel(pixels), 1);
                if (resolvedPixelDimension(&element, style_map, "height", .{
                    .font_size = engine.font_size_css,
                    .percentage_base = engine.containingBlockCssDimension(true),
                })) |pixels|
                    authored_height = @max(engine.scaleActiveCssPixel(pixels), natural_height);
            }
        }
        const metrics = control_geometry.inputBoxMetrics(
            natural_height,
            engine.scaleActiveCssPixel(INPUT_WIDTH_PX),
            is_choice,
            self.is_radio,
            authored_width,
            authored_height,
            self.border_radius,
        );
        self.border_radius = metrics.border_radius;
        self.embed.setupDependencies();
        self.embed.setMetrics(
            metrics.width,
            metrics.height,
            ascent_value,
            descent_value,
            engine.effectiveZoom(),
            self.font_size,
        );
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
        if (!engine.accessibility.forced_colors) {
            if (backgroundImagePaintForSource(source)) |paint| {
                try appendBackgroundImageBox(
                    target,
                    engine.allocator,
                    paint,
                    x,
                    y,
                    width_value,
                    height_value,
                    scaleCssFloat(1.0, self.embed.zoom.get().*, engine.zoom()),
                    source,
                );
            }
        }

        if (engine.accessibility.forced_colors and !self.is_checkbox and !self.is_radio) {
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

        if (self.is_radio) {
            const ink = engine.remapColor(
                .{ .r = 48, .g = 48, .b = 48, .a = 255 },
                .control_text,
            );
            const inset = @max(@divTrunc(height_value, 7), 1);
            try appendBackgroundBox(
                target,
                engine.allocator,
                x,
                y,
                width_value,
                height_value,
                self.border_radius,
                ink,
                source,
            );
            try appendBackgroundBox(
                target,
                engine.allocator,
                x + inset,
                y + inset,
                @max(width_value - 2 * inset, 1),
                @max(height_value - 2 * inset, 1),
                @max(self.border_radius - @as(f64, @floatFromInt(inset)), 0),
                remapped_bg,
                source,
            );
            if (self.is_checked) {
                const dot_inset = @max(@divTrunc(height_value, 3), inset + 1);
                try appendBackgroundBox(
                    target,
                    engine.allocator,
                    x + dot_inset,
                    y + dot_inset,
                    @max(width_value - 2 * dot_inset, 1),
                    @max(height_value - 2 * dot_inset, 1),
                    @max(self.border_radius - @as(f64, @floatFromInt(dot_inset)), 0),
                    ink,
                    source,
                );
            }
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
                        .page_zoom = engine.zoom(),
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

const inputDisplayGrapheme = control_geometry.inputDisplayGrapheme;

test "hidden inputs emit no inline box" {
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
}

test "radio inputs use compact circular control metrics" {
    const allocator = std.testing.allocator;
    var radio = try parser.Element.init(allocator, "input type=radio checked", null);
    defer radio.deinit(allocator);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();

    var input = InputLayout.init(allocator);
    defer input.deinit();
    try input.measure(engine, radio);
    try std.testing.expect(input.is_radio);
    try std.testing.expect(input.is_checked);
    try std.testing.expectEqualStrings("", input.text);
    try std.testing.expectEqual(input.embed.height.get().*, input.embed.width.get().*);
    try std.testing.expect(input.embed.width.get().* < engine.scaleActiveCssPixel(INPUT_WIDTH_PX));
    try std.testing.expect(input.border_radius > 0);
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
    image_bounds: std.AutoHashMap(*Node, Bounds),
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
            .image_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
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
        self.image_bounds.deinit();
        self.link_bounds.deinit(allocator);
        self.iframe_bounds.deinit(allocator);
        self.focus_bounds.deinit(allocator);
        self.accessibility_bounds.deinit(allocator);
        self.fragment_targets.deinit(allocator);
        self.embed.deinit();
    }

    fn swapCollectors(self: *ButtonLayout, engine: *Layout) void {
        std.mem.swap(@TypeOf(self.input_bounds), &self.input_bounds, &engine.input_bounds);
        std.mem.swap(@TypeOf(self.image_bounds), &self.image_bounds, &engine.image_bounds);
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
            if (resolvedPixelDimension(&element, style_map, "width", .{
                .font_size = engine.font_size_css,
                .percentage_base = engine.containingBlockCssDimension(false),
            })) |pixels|
                requested_width = @max(engine.scaleActiveCssPixel(pixels), 1);
            if (resolvedPixelDimension(&element, style_map, "height", .{
                .font_size = engine.font_size_css,
                .percentage_base = engine.containingBlockCssDimension(true),
            })) |pixels|
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
            content_bounds = content_bounds.unionWith(paint_bounds);
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
        if (!engine.accessibility.forced_colors) {
            if (backgroundImagePaintForSource(source)) |paint| {
                try appendBackgroundImageBox(
                    target,
                    engine.allocator,
                    paint,
                    x,
                    y,
                    self.embed.width.get().*,
                    self.embed.height.get().*,
                    scaleCssFloat(1.0, self.embed.zoom.get().*, engine.zoom()),
                    source,
                );
            }
        }

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
        var image_iterator = self.image_bounds.iterator();
        while (image_iterator.next()) |entry| {
            try engine.image_bounds.put(entry.key_ptr.*, offsetBounds(entry.value_ptr.*, dx, dy));
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

const buttonBoxMetrics = control_geometry.buttonBoxMetrics;

fn displayListLayoutBounds(
    engine: *Layout,
    items: []const DisplayItem,
    translate_x: i32,
    translate_y: i32,
) ?browser.Rect {
    var result: ?browser.Rect = null;
    for (items) |item| {
        const bounds: ?browser.Rect = switch (item) {
            .cached_subtree => |cached| displayListLayoutBounds(
                engine,
                cached.list.items,
                translate_x,
                translate_y,
            ),
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
            .canvas => |canvas| .{
                .left = translate_x + @min(canvas.x1, canvas.x2),
                .top = translate_y + @min(canvas.y1, canvas.y2),
                .right = translate_x + @max(canvas.x1, canvas.x2),
                .bottom = translate_y + @max(canvas.y1, canvas.y2),
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
        if (bounds) |rect| result = if (result) |existing| existing.unionWith(rect) else rect;
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

const appendClonedDisplayItem = retained_commands.appendClone;

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
    /// Complete paint commands for this text fragment. LineLayout references
    /// this list through a non-owning cached_subtree edge.
    paint_cache: std.ArrayList(DisplayItem) = .empty,
    paint_dirty: bool = true,
    paint_generation: u64 = 0,

    fn markOpaque(ptr: *anyopaque) void {
        const self: *TextLayout = @ptrCast(@alignCast(ptr));
        self.mark();
    }

    fn addStyleDependencies(text: *TextLayout, style_map: ?*parser.StyleMap) void {
        const map = style_map orelse return;
        for ([_][]const u8{ "font-weight", "font-style", "font-size", "font-family", "line-height" }) |property| {
            if (map.getPtr(property)) |field| {
                text.width.addDependency(field, text.allocator);
                text.height.addDependency(field, text.allocator);
                text.ascent.addDependency(field, text.allocator);
                text.descent.addDependency(field, text.allocator);
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
            .zoom = ProtectedField(f32).init(1.0),
            .x = ProtectedField(i32).init(0),
            .y = ProtectedField(i32).init(0),
            .width = ProtectedField(i32).init(0),
            .height = ProtectedField(i32).init(0),
            .ascent = ProtectedField(i32).init(0),
            .descent = ProtectedField(i32).init(0),
            .paint_cache = std.ArrayList(DisplayItem).empty,
        };
        text.zoom.setOwner(text, markOpaque);
        text.x.setOwner(text, markOpaque);
        text.y.setOwner(text, markOpaque);
        text.width.setOwner(text, markOpaque);
        text.height.setOwner(text, markOpaque);
        text.ascent.setOwner(text, markOpaque);
        text.descent.setOwner(text, markOpaque);

        // Freeze dependencies for layout fields.
        text.zoom.addDependency(&parent.zoom, allocator);
        text.zoom.freezeDependencies();

        if (previous) |prev| {
            text.x.addDependency(&prev.x, allocator);
            text.x.addDependency(&prev.width, allocator);
        } else {
            text.x.addDependency(&parent.x, allocator);
        }
        text.x.freezeDependencies();

        text.y.addDependency(&text.ascent, allocator);
        text.y.addDependency(&parent.y, allocator);
        text.y.addDependency(&parent.ascent, allocator);
        text.y.freezeDependencies();

        text.width.addDependency(&text.zoom, allocator);
        text.height.addDependency(&text.zoom, allocator);
        text.ascent.addDependency(&text.zoom, allocator);
        text.descent.addDependency(&text.zoom, allocator);

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
        DisplayItem.freeItems(self.allocator, self.paint_cache.items);
        self.paint_cache.deinit(self.allocator);
        self.zoom.deinit(self.allocator);
        self.x.deinit(self.allocator);
        self.y.deinit(self.allocator);
        self.width.deinit(self.allocator);
        self.height.deinit(self.allocator);
        self.ascent.deinit(self.allocator);
        self.descent.deinit(self.allocator);
    }

    fn mark(self: *TextLayout) void {
        self.markPaint();
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

    fn markPaint(self: *TextLayout) void {
        self.paint_dirty = true;
        self.parent.markPaint();
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
            break :x prev.x.read(&self.x, self.allocator).* + space + prev.width.read(&self.x, self.allocator).*;
        } else x: {
            break :x self.parent.x.read(&self.x, self.allocator).*;
        };

        // Set all values using ProtectedField.set() (clears dirty flags)
        self.width.set(width_value);
        self.height.set(height_value);
        self.ascent.set(ascent_value);
        self.descent.set(descent_value);
        self.x.set(x_value);
        self.zoom.set(self.parent.zoom.read(&self.zoom, self.allocator).*);
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
                .page_zoom = engine.zoom(),
                .source = displaySource(self, self.node_ptr),
            },
        });
    }

    fn hitTest(
        self: *const TextLayout,
        parent_point: HitPoint,
        parent_origin: HitPoint,
    ) ?LayoutHitResult {
        const local = layout_hit.childLocalPoint(
            parent_point,
            .{ .x = self.x.get().*, .y = self.y.get().* },
            parent_origin,
        );
        if (!layout_hit.containsBox(local, .{
            .width = self.width.get().*,
            .height = self.height.get().*,
        })) return null;
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
    paint_cache: std.ArrayList(DisplayItem) = .empty,
    paint_dirty: bool = true,
    paint_generation: u64 = 0,
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
            .zoom = ProtectedField(f32).init(1.0),
            .x = ProtectedField(i32).init(0),
            .y = ProtectedField(i32).init(0),
            .width = ProtectedField(i32).init(0),
            .height = ProtectedField(i32).init(0),
            .ascent = ProtectedField(i32).init(0),
            .descent = ProtectedField(i32).init(0),
            .children = std.ArrayList(*TextLayout).empty,
            .paint_cache = std.ArrayList(DisplayItem).empty,
            .initialized_fields = false,
        };
        line.zoom.setOwner(line, markOpaque);
        line.x.setOwner(line, markOpaque);
        line.y.setOwner(line, markOpaque);
        line.width.setOwner(line, markOpaque);
        line.height.setOwner(line, markOpaque);
        line.ascent.setOwner(line, markOpaque);
        line.descent.setOwner(line, markOpaque);

        line.zoom.addDependency(&parent.zoom, allocator);
        line.zoom.freezeDependencies();
        line.x.addDependency(&parent.x, allocator);
        line.x.freezeDependencies();
        line.width.addDependency(&parent.width, allocator);
        line.width.freezeDependencies();
        if (previous) |prev| {
            line.y.addDependency(&prev.y, allocator);
            line.y.addDependency(&prev.height, allocator);
        } else {
            line.y.addDependency(&parent.y, allocator);
        }
        line.y.freezeDependencies();
        line.height.addDependency(&line.ascent, allocator);
        line.height.addDependency(&line.descent, allocator);
        line.height.freezeDependencies();
        return line;
    }

    fn deinit(self: *LineLayout) void {
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
        DisplayItem.freeItems(self.allocator, self.paint_cache.items);
        self.paint_cache.deinit(self.allocator);
        self.zoom.deinit(self.allocator);
        self.x.deinit(self.allocator);
        self.y.deinit(self.allocator);
        self.width.deinit(self.allocator);
        self.height.deinit(self.allocator);
        self.ascent.deinit(self.allocator);
        self.descent.deinit(self.allocator);
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
                self.ascent.addDependency(dep, self.allocator);
            }
            for (descent_deps.items) |dep| {
                self.descent.addDependency(dep, self.allocator);
            }
            self.ascent.freezeDependencies();
            self.descent.freezeDependencies();
            self.initialized_fields = true;
        }

        // Compute x position from parent block
        // Use .read() to register invalidation dependencies on parent's fields
        const x_value = self.parent.x.read(&self.x, self.allocator).*;
        const width_value = self.parent.width.read(&self.width, self.allocator).*;

        // Position is below previous line, or at parent's y
        // Use .read() to register invalidation dependencies on previous/parent fields
        const y_value = if (self.previous) |prev| prev.y.read(&self.y, self.allocator).* + prev.height.read(&self.y, self.allocator).* else self.parent.y.read(&self.y, self.allocator).*;

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
            const word_ascent = word.ascent.read(&self.ascent, self.allocator).*;
            if (word_ascent > max_ascent) {
                max_ascent = word_ascent;
            }
        }

        // Baseline with 1.25 leading factor
        const baseline = y_value + @as(i32, @intFromFloat(1.25 * @as(f32, @floatFromInt(max_ascent))));

        // Position each word vertically relative to baseline
        for (self.children.items) |word| {
            const word_ascent = word.ascent.read(&self.ascent, self.allocator).*;
            const y_word = baseline - word_ascent;
            word.y.set(y_word);
        }

        // Compute maximum descent
        // Use .read() to register invalidation dependencies on children's descent
        var max_descent: i32 = 0;
        for (self.children.items) |word| {
            const word_descent = word.descent.read(&self.descent, self.allocator).*;
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
        self.zoom.set(self.parent.zoom.read(&self.zoom, self.allocator).*);

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
        const local = layout_hit.childLocalPoint(
            parent_point,
            .{ .x = self.x.get().*, .y = self.y.get().* },
            parent_origin,
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
        self.markPaint();
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

    fn markPaint(self: *LineLayout) void {
        self.paint_dirty = true;
        self.parent.markPaint(false);
    }

    fn markSubtree(self: *LineLayout) void {
        self.mark();
        for (self.children.items) |child| child.mark();
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
    /// Authoritative retained display-list root. Its children are cache edges
    /// into BlockLayouts, so a narrow repaint does not copy the rest of the
    /// page merely to publish a new frame snapshot.
    paint_cache: std.ArrayList(DisplayItem) = .empty,
    paint_dirty: bool = true,
    paint_generation: u64 = 0,

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
            .zoom = ProtectedField(f32).init(1.0),
            .children = std.ArrayList(*BlockLayout).empty,
            .paint_cache = std.ArrayList(DisplayItem).empty,
            .x = ProtectedField(i32).init(h_offset),
            .y = ProtectedField(i32).init(v_offset),
            .width = ProtectedField(i32).init(0),
            .height = ProtectedField(i32).init(0),
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
        DisplayItem.freeItems(self.allocator, self.paint_cache.items);
        self.paint_cache.deinit(self.allocator);
        self.zoom.deinit(self.allocator);
        self.x.deinit(self.allocator);
        self.y.deinit(self.allocator);
        self.width.deinit(self.allocator);
        self.height.deinit(self.allocator);
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
        self.paint_dirty = true;
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
        engine.image_bounds.clearRetainingCapacity();
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
            self.height.addDependency(&block.height, self.allocator);
            self.height.freezeDependencies();
        } else {
            self.height.addDependency(&block.height, self.allocator);
        }
        block.node = self.node;
        block.node_ptr = self.node_ptr;
        try block.layout(engine);

        // Set height after child layout completes
        // Use .read() to register invalidation dependency on child's height
        self.height.set(block.height.read(&self.height, self.allocator).*);

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
        const local = layout_hit.subtractOffset(
            .{ .x = x, .y = y },
            .{ .x = self.x.get().*, .y = self.y.get().* },
        );
        const origin = HitPoint{ .x = self.x.get().*, .y = self.y.get().* };
        var index = self.children.items.len;
        while (index > 0) {
            index -= 1;
            if (self.children.items[index].hitTest(local, origin)) |hit| return hit;
        }
        if (!layout_hit.containsBox(local, .{
            .width = self.width.get().*,
            .height = self.height.get().*,
        })) return null;
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
        self.paint_dirty = true;
        // Mark all layout properties as dirty
        self.x.markNoOwner();
        self.y.markNoOwner();
        self.width.markNoOwner();
        self.height.markNoOwner();
        self.zoom.markNoOwner();
        self.has_dirty_descendants = true;
        // Also mark all children so they re-layout
        for (self.children.items) |child| {
            child.markSubtree();
        }
    }

    pub fn markPaintSubtree(self: *DocumentLayout) void {
        self.paint_dirty = true;
        for (self.children.items) |child| child.markPaintSubtree();
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

fn layoutChildPaintKey(child: LayoutChild, document_index: usize) layout_hit.StackingKey {
    return .{
        .z_index = switch (child) {
            .block => |block| blockPaintZIndex(block),
            .line => 0,
        },
        .document_index = document_index,
    };
}

/// A synchronous table-grid placement constraint for one existing DOM-backed
/// block. It never owns or outlives the `layoutWithTableBox` call that installs
/// it; the layout object still owns its style, children, paint cache, and DOM
/// callback identity.
const TableBox = struct {
    x: i32,
    y: i32,
    width: i32,
    /// A forced border-box height for the row-stretch pass. Null permits a
    /// first natural-height measurement pass.
    height: ?i32 = null,
};

/// A parent supplies this synchronous, scalar-only cursor immediately before
/// laying out one ordinary in-flow block child. It is intentionally not a
/// ProtectedField: it is valid only during the serialized parent traversal
/// and owns neither a layout object nor a dependency edge.
const NormalFlowPlacement = struct {
    origin_y: i32,
    preceding_margin: MarginStrut = .{},

    fn eql(self: NormalFlowPlacement, other: NormalFlowPlacement) bool {
        return self.origin_y == other.origin_y and
            self.preceding_margin.eql(other.preceding_margin);
    }
};

/// The part of a direct child's vertical flow that its parent needs for the
/// next sibling. Empty blocks leave `cursor_y` unchanged and carry their
/// adjoining margins in `trailing_margin`; a visible block consumes the prior
/// strut at its border top and starts a new trailing chain at its border
/// bottom.
const NormalFlowResult = struct {
    cursor_y: i32,
    trailing_margin: MarginStrut = .{},
    collapses_through: bool = false,
};

const BlockLayout = struct {
    allocator: std.mem.Allocator,
    node: Node,
    node_ptr: ?*Node,
    document: *DocumentLayout,
    parent_block: ?*BlockLayout,
    /// The preceding in-flow block can change when a DOM child is inserted.
    /// Keeping the pointer protected lets that narrow structural mutation
    /// invalidate only this block's vertical position and its dependents.
    previous: ProtectedField(?*BlockLayout),
    // An anonymous block owns this pointer slice and lays out each sibling as
    // one inline run. Normal blocks retain their single DOM node instead.
    inline_nodes: ?[]*Node = null,
    // Rich buttons create a temporary, locally positioned block subtree whose
    // commands are later translated into the surrounding inline line box.
    embedded_box: ?EmbeddedBlockBox = null,
    rich_button_root: bool = false,
    effective_zoom_override: ?f32 = null,
    /// Present only during a table parent's synchronous child-layout pass.
    /// Unlike `embedded_box`, this preserves the child element's CSS edges,
    /// effects, and content dimensions while forcing its grid border box.
    table_box: ?TableBox = null,
    /// Ephemeral direct-parent normal-flow state. The parent updates this
    /// before calling `layout`; `normal_flow_result` is then read before it
    /// visits the next sibling. Neither field survives a layout phase as an
    /// owned cross-object reference.
    normal_flow_placement: ?NormalFlowPlacement = null,
    normal_flow_result: ?NormalFlowResult = null,
    /// Borrowed column widths used only while a real `table-row` lays out its
    /// direct cells. `layoutWithTableRowBox` clears this before its caller's
    /// temporary table plan is released.
    table_row_columns: ?[]const i32 = null,
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
    /// `x/y/width/height` describe the border box. CSS width and height are
    /// content-box values; these fields retain the used content rectangle so
    /// child flow and percentage resolution do not accidentally include
    /// padding or borders.
    margin: BoxEdges = .{},
    padding: BoxEdges = .{},
    border: BoxEdges = .{},
    content_width: i32 = 0,
    content_height: i32 = 0,
    content_height_definite: bool = false,
    /// Visual movement applied after normal-flow geometry. Keeping this
    /// separate from x/y prevents relative positioning from moving the slot
    /// used by a following sibling.
    position_offset: PositionOffset = .{},
    /// Number of direct DOM children represented by the last successfully
    /// published block-child list. An accepted insertion matches those
    /// existing objects and creates layout objects only for new DOM gaps.
    laid_out_dom_children: usize = 0,
    children_epoch: u64 = 0,
    children_version: ProtectedField(u64),
    /// Floats owned by this block formatting context. Non-context descendants
    /// contribute to their nearest owning ancestor instead of retaining a
    /// private exclusion list.
    floats: std.ArrayList(FloatBox),
    rebuilding_floats: bool = false,

    children: std.ArrayList(LayoutChild),
    /// DOM-index permutation captured at the last paint. Retaining it keeps
    /// structural hit queries aligned with that exact display generation.
    paint_order: std.ArrayList(usize),
    /// Layout-time commands for the legacy inline formatter. `paint_cache`
    /// wraps these with this block's background, descendants, scrolling, and
    /// effects, while cached_subtree edges keep both lists independently
    /// reusable.
    display_list: std.ArrayList(DisplayItem),
    paint_cache: std.ArrayList(DisplayItem) = .empty,
    paint_dirty: bool = true,
    inline_paint_dirty: bool = false,
    used_inline_layout: bool = false,
    paint_generation: u64 = 0,
    cursor_x: i32 = 0,
    has_dirty_descendants: bool = false,
    in_layout: bool = false,

    /// An ephemeral row record points only at already-owned DOM-backed
    /// BlockLayouts. Anonymous rows are represented by a null owner; no
    /// synthetic DOM node or retained anonymous layout object is created.
    const TableRowPlan = struct {
        owner: ?*BlockLayout,
        first_cell: usize,
        cell_count: usize,
    };

    const TablePlan = struct {
        allocator: std.mem.Allocator,
        rows: std.ArrayList(TableRowPlan) = .empty,
        cells: std.ArrayList(*BlockLayout) = .empty,

        fn init(allocator: std.mem.Allocator) TablePlan {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *TablePlan) void {
            self.rows.deinit(self.allocator);
            self.cells.deinit(self.allocator);
        }
    };

    fn markOpaque(ptr: *anyopaque) void {
        const self: *BlockLayout = @ptrCast(@alignCast(ptr));
        if (self.in_layout) return;
        self.mark();
    }

    fn markPaintOpaque(ptr: *anyopaque) void {
        const self: *BlockLayout = @ptrCast(@alignCast(ptr));
        self.markPaint(true);
    }

    fn canReuseInsertOpaque(ptr: *anyopaque, insert_index: usize) bool {
        const self: *BlockLayout = @ptrCast(@alignCast(ptr));
        return self.canReuseInsert(insert_index);
    }

    fn rebindAfterInsertOpaque(ptr: *anyopaque, node: *Node) bool {
        const self: *BlockLayout = @ptrCast(@alignCast(ptr));
        return self.rebindAfterInsert(node);
    }

    fn bindDomNode(self: *BlockLayout, node: *Node) void {
        self.node = node.*;
        self.node_ptr = node;
        switch (node.*) {
            .element => |*element| {
                element.layout_ptr = self;
                element.layout_mark = markOpaque;
                element.layout_paint_mark = markPaintOpaque;
                element.layout_can_reuse_insert = canReuseInsertOpaque;
                element.layout_rebind_after_insert = rebindAfterInsertOpaque;
            },
            .text => {},
        }
    }

    fn nodeLayoutOwner(node: *const Node) ?*anyopaque {
        return switch (node.*) {
            .element => |element| element.layout_ptr,
            .text => null,
        };
    }

    fn ownsNode(block: *BlockLayout, node: *const Node) bool {
        const block_ptr: *anyopaque = @ptrCast(@alignCast(block));
        return nodeLayoutOwner(node) == block_ptr;
    }

    /// This deliberately accepts only a stable block-mode shape: every
    /// already-laid-out DOM child maps one-to-one to a DOM-backed BlockLayout.
    /// Previously inserted, not-yet-laid-out nodes may appear as gaps between
    /// those owners. Anonymous inline runs retain the conservative path.
    fn canReuseInsert(self: *BlockLayout, insert_index: usize) bool {
        // A table's direct-child sequence defines its anonymous rows and cells,
        // so even an append can change the formatting topology. Rebuild this
        // bounded formatting context conservatively rather than retaining an
        // ordinary block-child mapping.
        if (publishedNodeTableRole(self.node) != .ordinary) return false;
        if (!self.persistent_dependencies or self.inline_nodes != null) return false;
        if (self.children_version.dirty or self.laid_out_dom_children == 0) return false;

        const node = self.node_ptr orelse return false;
        const element = switch (node.*) {
            .element => |*value| value,
            .text => return false,
        };
        if (insert_index > element.children.items.len) return false;
        if (element.children_dirty and !element.children_insertions_only) return false;
        if (self.laid_out_dom_children > element.children.items.len) return false;
        if (!element.children_dirty and
            self.laid_out_dom_children != element.children.items.len) return false;
        if (self.children.items.len != self.laid_out_dom_children) return false;

        // Appending after a trailing run-in heading can merge that retained
        // child with the new block. A middle insertion leaves that trailing
        // boundary untouched and can still use identity matching.
        if (insert_index == element.children.items.len and
            isRunInHeadingNode(element.children.items[element.children.items.len - 1]))
        {
            return false;
        }

        var retained_index: usize = 0;
        var expected_previous: ?*BlockLayout = null;
        for (element.children.items) |*dom_child| {
            if (retained_index < self.children.items.len) {
                const block = switch (self.children.items[retained_index]) {
                    .block => |value| value,
                    .line => return false,
                };
                if (ownsNode(block, dom_child)) {
                    const position_mode = block.positionMode();
                    const block_previous = if (isOutOfFlowPosition(position_mode)) null else expected_previous;
                    if (block.inline_nodes != null or
                        block.parent_block != self or
                        block.node_ptr != dom_child or
                        block.previous.dirty or
                        block.previous.get().* != block_previous)
                    {
                        return false;
                    }
                    if (block.floatSide() == .none and !isOutOfFlowPosition(position_mode)) {
                        expected_previous = block;
                    }
                    retained_index += 1;
                    continue;
                }
            }

            // A gap is safe only when it has no unrelated live layout owner.
            if (nodeLayoutOwner(dom_child) != null) return false;
        }
        return retained_index == self.children.items.len;
    }

    /// Child-array capacity growth can move every direct Node by value. Repair
    /// every retained child synchronously, before JavaScript or teardown can
    /// dereference one of the old addresses. Inserted gaps are intentionally
    /// left without layout objects until the next protected layout phase.
    fn rebindAfterInsert(self: *BlockLayout, node: *Node) bool {
        if (self.node_ptr != node or self.children.items.len != self.laid_out_dom_children) {
            return false;
        }
        const element = switch (node.*) {
            .element => |*value| value,
            .text => return false,
        };
        if (!element.children_dirty or !element.children_insertions_only or
            self.laid_out_dom_children > element.children.items.len) return false;

        // Validate the complete identity mapping before changing any pointers.
        var retained_index: usize = 0;
        for (element.children.items) |*dom_child| {
            if (retained_index < self.children.items.len) {
                const block = switch (self.children.items[retained_index]) {
                    .block => |value| value,
                    .line => return false,
                };
                if (ownsNode(block, dom_child)) {
                    if (block.inline_nodes != null or block.parent_block != self) return false;
                    retained_index += 1;
                    continue;
                }
            }
            if (nodeLayoutOwner(dom_child) != null) return false;
        }
        if (retained_index != self.children.items.len) return false;

        self.bindDomNode(node);
        retained_index = 0;
        for (element.children.items) |*dom_child| {
            if (retained_index >= self.children.items.len) break;
            const block = self.children.items[retained_index].block;
            if (!ownsNode(block, dom_child)) continue;
            block.bindDomNode(dom_child);
            retained_index += 1;
        }
        return true;
    }

    /// Match retained block objects to their live DOM owners after style has
    /// been republished, then build layout objects only for inserted gaps.
    /// This also computes the new in-flow predecessor for every retained
    /// block; `setPrevious` invalidates only blocks whose link changed.
    fn rebuildInsertedChildren(
        self: *BlockLayout,
        element: *parser.Element,
    ) !bool {
        if (self.children.items.len != self.laid_out_dom_children or
            self.laid_out_dom_children > element.children.items.len)
        {
            return false;
        }

        const dom_children = element.children.items;
        const retained_for_dom = try self.allocator.alloc(?*BlockLayout, dom_children.len);
        defer self.allocator.free(retained_for_dom);
        @memset(retained_for_dom, null);

        var retained_index: usize = 0;
        for (dom_children, 0..) |*dom_child, dom_index| {
            if (retained_index < self.children.items.len) {
                const block = switch (self.children.items[retained_index]) {
                    .block => |value| value,
                    .line => return false,
                };
                if (ownsNode(block, dom_child)) {
                    if (block.inline_nodes != null or
                        block.parent_block != self or
                        block.node_ptr != dom_child or
                        !isContainerNode(dom_child.*, &self.children_version))
                    {
                        return false;
                    }
                    retained_for_dom[dom_index] = block;
                    retained_index += 1;
                    continue;
                }
            }
            if (nodeLayoutOwner(dom_child) != null) return false;
        }
        if (retained_index != self.children.items.len) return false;

        // A run-in pair is represented by one anonymous block. Reusing either
        // member's old one-to-one BlockLayout would therefore be incorrect.
        for (dom_children, 0..) |dom_child, dom_index| {
            if (!isRunInHeadingNode(dom_child) or dom_index + 1 >= dom_children.len) continue;
            if (!isContainerNode(dom_children[dom_index + 1], &self.children_version)) continue;
            if (retained_for_dom[dom_index] != null or
                retained_for_dom[dom_index + 1] != null)
            {
                return false;
            }
        }

        // Refresh every shallow Node copy after style publication before
        // querying float state or installing new predecessor links.
        for (retained_for_dom, dom_children) |retained, *dom_child| {
            if (retained) |block| block.bindDomNode(dom_child);
        }

        const desired_previous = try self.allocator.alloc(?*BlockLayout, self.children.items.len);
        defer self.allocator.free(desired_previous);
        @memset(desired_previous, null);

        var replacement = std.ArrayList(LayoutChild).empty;
        defer replacement.deinit(self.allocator);
        try replacement.ensureTotalCapacity(self.allocator, dom_children.len);

        var created = std.ArrayList(*BlockLayout).empty;
        defer created.deinit(self.allocator);
        try created.ensureTotalCapacity(self.allocator, dom_children.len);
        errdefer for (created.items) |block| {
            block.deinit();
            self.allocator.destroy(block);
        };

        var previous: ?*BlockLayout = null;
        retained_index = 0;
        var dom_index: usize = 0;
        while (dom_index < dom_children.len) {
            if (retained_for_dom[dom_index]) |block| {
                const position_mode = block.positionMode();
                desired_previous[retained_index] = if (isOutOfFlowPosition(position_mode)) null else previous;
                replacement.appendAssumeCapacity(.{ .block = block });
                if (block.floatSide() == .none and !isOutOfFlowPosition(position_mode)) previous = block;
                retained_index += 1;
                dom_index += 1;
                continue;
            }

            if (isRunInHeadingNode(dom_children[dom_index]) and
                dom_index + 1 < dom_children.len and
                isContainerNode(dom_children[dom_index + 1], &self.children_version))
            {
                std.debug.assert(retained_for_dom[dom_index + 1] == null);
                const run_in_nodes = try self.allocator.alloc(*Node, 2);
                errdefer self.allocator.free(run_in_nodes);
                run_in_nodes[0] = &dom_children[dom_index];
                run_in_nodes[1] = &dom_children[dom_index + 1];
                const child = try BlockLayout.initAnonymous(
                    self.allocator,
                    run_in_nodes,
                    self.document,
                    self,
                    previous,
                );
                created.appendAssumeCapacity(child);
                replacement.appendAssumeCapacity(.{ .block = child });
                if (child.floatSide() == .none and !isOutOfFlowPosition(child.positionMode())) previous = child;
                dom_index += 2;
                continue;
            }

            if (isContainerNode(dom_children[dom_index], &self.children_version)) {
                const child_node = &dom_children[dom_index];
                const child_position = nodePositionMode(child_node.*, &self.children_version);
                const child = try BlockLayout.init(
                    self.allocator,
                    child_node.*,
                    child_node,
                    self.document,
                    self,
                    if (isOutOfFlowPosition(child_position)) null else previous,
                );
                created.appendAssumeCapacity(child);
                replacement.appendAssumeCapacity(.{ .block = child });
                if (child.floatSide() == .none and !isOutOfFlowPosition(child_position)) previous = child;
                dom_index += 1;
                continue;
            }

            const start = dom_index;
            while (dom_index < dom_children.len and
                !isContainerNode(dom_children[dom_index], &self.children_version)) : (dom_index += 1)
            {
                std.debug.assert(retained_for_dom[dom_index] == null);
            }
            const inline_nodes = try self.allocator.alloc(*Node, dom_index - start);
            errdefer self.allocator.free(inline_nodes);
            for (dom_children[start..dom_index], 0..) |*dom_child, output_index| {
                inline_nodes[output_index] = dom_child;
            }
            const child = try BlockLayout.initAnonymous(
                self.allocator,
                inline_nodes,
                self.document,
                self,
                previous,
            );
            created.appendAssumeCapacity(child);
            replacement.appendAssumeCapacity(.{ .block = child });
            if (child.floatSide() == .none and !isOutOfFlowPosition(child.positionMode())) previous = child;
        }
        std.debug.assert(retained_index == self.children.items.len);

        for (self.children.items, desired_previous) |layout_child, new_previous| {
            layout_child.block.setPrevious(new_previous);
        }

        var old_children = self.children;
        self.children = replacement;
        replacement = std.ArrayList(LayoutChild).empty;
        old_children.deinit(self.allocator);
        return true;
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
            .previous = ProtectedField(?*BlockLayout).init(previous),
            .zoom = ProtectedField(f32).init(1.0),
            .x = ProtectedField(i32).init(0),
            .y = ProtectedField(i32).init(0),
            .width = ProtectedField(i32).init(0),
            .height = ProtectedField(i32).init(0),
            .margin = .{},
            .padding = .{},
            .border = .{},
            .content_width = 0,
            .content_height = 0,
            .content_height_definite = false,
            .position_offset = .{},
            .laid_out_dom_children = 0,
            .children = std.ArrayList(LayoutChild).empty,
            .paint_order = std.ArrayList(usize).empty,
            .display_list = std.ArrayList(DisplayItem).empty,
            .paint_cache = std.ArrayList(DisplayItem).empty,
            .embedded_box = null,
            .rich_button_root = false,
            .effective_zoom_override = null,
            .table_box = null,
            .table_row_columns = null,
            .persistent_dependencies = persistent_dependencies,
            .temporary_dependency_target = if (!persistent_dependencies and parent_block != null)
                parent_block.?.temporary_dependency_target
            else
                null,
            .children_epoch = 0,
            .children_version = ProtectedField(u64).init(0),
            .floats = std.ArrayList(FloatBox).empty,
            .rebuilding_floats = false,
        };
        block.zoom.setOwner(block, markOpaque);
        block.x.setOwner(block, markOpaque);
        block.y.setOwner(block, markOpaque);
        block.width.setOwner(block, markOpaque);
        block.height.setOwner(block, markOpaque);
        block.children_version.setOwner(block, markOpaque);
        block.previous.setOwner(block, markOpaque);
        block.previous.set(previous);
        block.y.addDependency(&block.previous, allocator);

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
                block.zoom.addDependency(&parent.zoom, allocator);
                block.x.addDependency(&parent.x, allocator);
                block.width.addDependency(&parent.width, allocator);
                if (previous) |prev| {
                    block.y.addDependency(&prev.y, allocator);
                    block.y.addDependency(&prev.height, allocator);
                } else {
                    block.y.addDependency(&parent.y, allocator);
                }

                // Parent padding and border widths affect the containing
                // content origin/width even when the parent's outer width is
                // unchanged. Subscribe the child directly because those
                // used values are plain box-model fields, not ProtectedFields.
                if (parent.node_ptr) |parent_ptr| switch (parent_ptr.*) {
                    .element => |*element| if (element.style) |*style_map| {
                        for ([_][]const u8{
                            "padding-top",      "padding-right",      "padding-bottom",      "padding-left",
                            "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
                        }) |property| {
                            if (style_map.getPtr(property)) |field| {
                                block.x.addDependency(field, allocator);
                                block.y.addDependency(field, allocator);
                                block.width.addDependency(field, allocator);
                            }
                        }
                    },
                    .text => {},
                };
            } else {
                block.zoom.addDependency(&document.zoom, allocator);
                block.x.addDependency(&document.x, allocator);
                block.width.addDependency(&document.width, allocator);
                if (previous) |prev| {
                    block.y.addDependency(&prev.y, allocator);
                    block.y.addDependency(&prev.height, allocator);
                } else {
                    block.y.addDependency(&document.y, allocator);
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
                            if (style_map.getPtr("zoom")) |field| block.zoom.addDependency(field, style_map.allocator);
                            if (style_map.getPtr("width")) |field| block.width.addDependency(field, style_map.allocator);
                            if (style_map.getPtr("min-width")) |field| block.width.addDependency(field, style_map.allocator);
                            if (style_map.getPtr("max-width")) |field| block.width.addDependency(field, style_map.allocator);
                            if (style_map.getPtr("height")) |field| block.height.addDependency(field, style_map.allocator);
                            if (style_map.getPtr("min-height")) |field| block.height.addDependency(field, style_map.allocator);
                            if (style_map.getPtr("max-height")) |field| block.height.addDependency(field, style_map.allocator);
                            if (style_map.getPtr("overflow")) |field| block.height.addDependency(field, style_map.allocator);
                            if (style_map.getPtr("position")) |field| {
                                block.x.addDependency(field, style_map.allocator);
                                block.y.addDependency(field, style_map.allocator);
                            }
                            for ([_][]const u8{ "left", "right" }) |property| {
                                if (style_map.getPtr(property)) |field| {
                                    block.x.addDependency(field, style_map.allocator);
                                }
                            }
                            for ([_][]const u8{ "top", "bottom" }) |property| {
                                if (style_map.getPtr(property)) |field| {
                                    block.y.addDependency(field, style_map.allocator);
                                }
                            }
                            for ([_][]const u8{
                                "margin-top",       "margin-right",       "margin-bottom",       "margin-left",
                                "padding-top",      "padding-right",      "padding-bottom",      "padding-left",
                                "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
                                "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
                                "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
                                "float",            "clear",
                            }) |property| {
                                if (style_map.getPtr(property)) |field| block.height.addDependency(field, allocator);
                            }
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
        block.previous.freezeDependencies();

        if (node_ptr) |ptr| {
            switch (ptr.*) {
                .element => |*e| {
                    e.layout_ptr = block;
                    e.layout_mark = markOpaque;
                    e.layout_paint_mark = markPaintOpaque;
                    e.layout_can_reuse_insert = canReuseInsertOpaque;
                    e.layout_rebind_after_insert = rebindAfterInsertOpaque;
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
        context: parser.CssLengthResolutionContext,
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
                    resolveCssLength(computed, context);
            } else null,
            .text => null,
        };
    }

    fn computedFontSizeCss(self: *const BlockLayout) f64 {
        const element = switch (self.node) {
            .element => |*value| value,
            .text => return 16.0,
        };
        const styles = element.style orelse return 16.0;
        const value = styleValue(&styles, "font-size") orelse return 16.0;
        return parser.resolveCssLength(value, .{
            .font_size = 16.0,
            .percentage_base = 16.0,
        }) orelse 16.0;
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
                        e.clearLayoutOwner();
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
        DisplayItem.freeItems(self.allocator, self.paint_cache.items);
        self.paint_cache.deinit(self.allocator);
        self.floats.deinit(self.allocator);
        self.zoom.deinit(self.allocator);
        self.x.deinit(self.allocator);
        self.y.deinit(self.allocator);
        self.width.deinit(self.allocator);
        self.height.deinit(self.allocator);
        self.children_version.deinit(self.allocator);
        self.previous.deinit(self.allocator);
    }

    fn mark(self: *BlockLayout) void {
        // Geometry changes always make this block's recorded commands stale.
        // The layout pass will regenerate legacy inline commands before paint.
        self.markPaint(false);
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

    fn markPaint(self: *BlockLayout, inline_commands_dirty: bool) void {
        self.paint_dirty = true;
        if (inline_commands_dirty and self.used_inline_layout) {
            self.inline_paint_dirty = true;
        } else if (inline_commands_dirty) {
            // A block-formatting element owns its background/effects, while
            // each direct run of inline DOM children is painted by an
            // anonymous BlockLayout. DOM style invalidation resolves to the
            // nearest element-backed owner, so forward paint-only changes to
            // those anonymous runs without dirtying ordinary block siblings.
            for (self.children.items) |child| switch (child) {
                .block => |block| {
                    if (block.node_ptr != null) continue;
                    block.paint_dirty = true;
                    if (block.used_inline_layout) block.inline_paint_dirty = true;
                },
                .line => |line| {
                    line.paint_dirty = true;
                    for (line.children.items) |text| text.paint_dirty = true;
                },
            };
        }

        // Ancestor lists contain stable cache edges, but their shallow order
        // and effect wrappers can depend on descendant styles (notably
        // z-index). Mark the path, without dirtying sibling caches.
        var ancestor = self.parent_block;
        while (ancestor) |parent| {
            parent.paint_dirty = true;
            ancestor = parent.parent_block;
        }
        self.document.paint_dirty = true;
    }

    fn markPaintSubtree(self: *BlockLayout) void {
        self.markPaint(true);
        for (self.children.items) |child| switch (child) {
            .block => |block| block.markPaintSubtree(),
            .line => |line| {
                line.paint_dirty = true;
                for (line.children.items) |text| text.paint_dirty = true;
            },
        };
    }

    fn markSubtree(self: *BlockLayout) void {
        self.mark();
        for (self.children.items) |child| switch (child) {
            .block => |block| block.markSubtree(),
            .line => |line| line.markSubtree(),
        };
    }

    fn isBlockContainer(self: *BlockLayout) bool {
        if (self.inline_nodes != null) return false;
        if (table_format.establishesFormattingContext(self.tableRole())) return true;
        switch (self.node) {
            .text => return false,
            .element => |e| {
                // Floating an inline element promotes it to a block-level
                // formatting context. Replaced elements remain atomic below.
                const is_float = nodeFloatSide(self.node, null) != .none;
                // Replaced controls are atomic in their surrounding line. A
                // rich button's temporary root is the contained exception.
                if (std.ascii.eqlIgnoreCase(e.tag, "input") or
                    (std.ascii.eqlIgnoreCase(e.tag, "button") and !self.rich_button_root) or
                    elementUsesImageLayout(&e) or
                    std.ascii.eqlIgnoreCase(e.tag, "canvas") or
                    std.ascii.eqlIgnoreCase(e.tag, "iframe"))
                {
                    return false;
                }

                if (is_float) return true;

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

    fn tableRole(self: *const BlockLayout) table_format.Role {
        return nodeTableRole(self.node, null);
    }

    fn floatSide(self: *const BlockLayout) FloatSide {
        return nodeFloatSide(self.node, null);
    }

    fn clearSide(self: *const BlockLayout) ClearSide {
        return nodeClearSide(self.node);
    }

    fn previousBlock(self: *const BlockLayout) ?*BlockLayout {
        return self.previous.get().*;
    }

    /// Rewire one retained block after insertion. The protected pointer marks
    /// `y`, while the newly selected predecessor's metrics are added to the
    /// dependency graph before that pointer becomes observable. Old edges are
    /// harmlessly conservative because retained insertion destroys no block.
    fn setPrevious(self: *BlockLayout, previous: ?*BlockLayout) void {
        if (self.previous.get().* == previous) return;

        if (self.persistent_dependencies) {
            if (previous) |block| {
                self.y.addDependency(&block.y, self.allocator);
                self.y.addDependency(&block.height, self.allocator);
            } else if (self.parent_block) |parent| {
                self.y.addDependency(&parent.y, self.allocator);
            } else {
                self.y.addDependency(&self.document.y, self.allocator);
            }
        }
        self.previous.set(previous);
    }

    /// Install the scalar position of an ordinary in-flow child before its
    /// parent calls `layout`. A changed cursor is a real geometry change even
    /// when this child's style fields stayed clean, so mark the subtree then.
    fn setNormalFlowPlacement(self: *BlockLayout, placement: NormalFlowPlacement) void {
        if (self.normal_flow_placement) |current| {
            if (current.eql(placement)) return;
        }
        self.normal_flow_placement = placement;
        self.normal_flow_result = null;
        self.mark();
    }

    /// A block that has become floating, positioned, or table-placed must not
    /// reuse the ordinary-flow result from an earlier layout generation.
    fn clearNormalFlowPlacement(self: *BlockLayout) void {
        if (self.normal_flow_placement == null and self.normal_flow_result == null) return;
        self.normal_flow_placement = null;
        self.normal_flow_result = null;
        self.mark();
    }

    /// Whether this box's bottom edge may pass the pending bottom-margin
    /// strut of its last ordinary child to its own parent. This deliberately
    /// covers only ordinary auto-height block flow; formatting contexts,
    /// definite heights, direct line content, floats, and positioned children
    /// remain barriers in the caller.
    fn canCollapseBottomMargin(
        self: *const BlockLayout,
        is_block: bool,
        specified_height: ?i32,
        min_height: ?i32,
        has_flow_barrier: bool,
    ) bool {
        if (!is_block or has_flow_barrier) return false;
        if (self.parent_block == null or self.inline_nodes != null or self.embedded_box != null) {
            return false;
        }
        if (self.table_box != null or self.tableRole() != .ordinary) return false;
        if (self.floatSide() != .none or isOutOfFlowPosition(self.positionMode())) return false;
        if (blockAvoidsExternalFloats(self)) return false;
        if (specified_height) |height| {
            if (height != 0) return false;
        }
        if (min_height) |height| {
            if (height != 0) return false;
        }
        return self.padding.bottom == 0 and self.border.bottom == 0;
    }

    /// An empty ordinary block can let its top margin, descendants' adjoining
    /// margins, and bottom margin form one strut. All visual/formatting
    /// boundaries are excluded here so a returned result never skips a box
    /// that occupies space or paints a non-empty border/padding area.
    fn canCollapseThrough(
        self: *const BlockLayout,
        is_block: bool,
        specified_height: ?i32,
        min_height: ?i32,
        natural_height: i32,
        clearance_applied: bool,
    ) bool {
        if (!self.canCollapseBottomMargin(
            is_block,
            specified_height,
            min_height,
            false,
        )) return false;
        if (clearance_applied or self.clearSide() != .none) return false;
        if (self.padding.top != 0 or self.border.top != 0 or natural_height != 0) return false;
        for (self.children.items) |child| switch (child) {
            .line => return false,
            .block => |block| {
                if (block.floatSide() != .none or isOutOfFlowPosition(block.positionMode())) {
                    return false;
                }
                const result = block.normal_flow_result orelse return false;
                if (!result.collapses_through) return false;
            },
        };
        return true;
    }

    fn positionMode(self: *const BlockLayout) PositionMode {
        return nodePositionMode(self.node, null);
    }

    fn establishesFloatContext(self: *const BlockLayout) bool {
        if (self.parent_block == null or self.embedded_box != null) return true;
        if (self.floatSide() != .none or isOutOfFlowPosition(self.positionMode())) return true;
        return blockAvoidsExternalFloats(self);
    }

    fn floatContextForChildren(self: *BlockLayout) *BlockLayout {
        if (self.establishesFloatContext()) return self;
        return self.parent_block.?.floatContextForChildren();
    }

    fn floatContextForChildrenConst(self: *const BlockLayout) *const BlockLayout {
        if (self.establishesFloatContext()) return self;
        return self.parent_block.?.floatContextForChildrenConst();
    }

    fn specifiedPositionOffset(
        self: *const BlockLayout,
        property: []const u8,
        context: parser.CssLengthResolutionContext,
        engine_zoom: f32,
    ) ?i32 {
        if (self.inline_nodes != null or self.embedded_box != null) return null;
        const node_ptr = self.node_ptr orelse return null;
        const element = switch (node_ptr.*) {
            .element => |*value| value,
            .text => return null,
        };
        const styles = if (element.style) |*style_map| style_map else return null;
        const value = styleValue(styles, property) orelse return null;
        const pixels = resolveSignedCssLength(value, context) orelse return null;
        return scaleCssPixel(pixels, self.zoom.get().*, engine_zoom);
    }

    fn updatePositionOffset(
        self: *BlockLayout,
        containing_x: i32,
        containing_y: i32,
        containing_width: i32,
        containing_height: ?i32,
        containing_width_css: f64,
        containing_height_css: ?f64,
        engine_zoom: f32,
    ) void {
        self.position_offset = .{};
        const mode = self.positionMode();
        if (mode == .static) return;

        const horizontal_context = parser.CssLengthResolutionContext{
            .font_size = self.computedFontSizeCss(),
            .percentage_base = containing_width_css,
        };
        const vertical_context = parser.CssLengthResolutionContext{
            .font_size = self.computedFontSizeCss(),
            .percentage_base = containing_height_css,
        };
        const left = self.specifiedPositionOffset("left", horizontal_context, engine_zoom);
        const right = self.specifiedPositionOffset("right", horizontal_context, engine_zoom);
        const top = self.specifiedPositionOffset("top", vertical_context, engine_zoom);
        const bottom = self.specifiedPositionOffset("bottom", vertical_context, engine_zoom);

        if (mode == .relative) {
            self.position_offset.x = left orelse if (right) |value| 0 -| value else 0;
            self.position_offset.y = top orelse if (bottom) |value| 0 -| value else 0;
            return;
        }

        if (left) |value| {
            const desired_x = containing_x +| value +| self.margin.left;
            self.position_offset.x = desired_x -| self.x.get().*;
        } else if (right) |value| {
            const desired_x = containing_x +| containing_width -| value -|
                self.margin.right -| self.width.get().*;
            self.position_offset.x = desired_x -| self.x.get().*;
        }

        if (top) |value| {
            const desired_y = containing_y +| value +| self.margin.top;
            self.position_offset.y = desired_y -| self.y.get().*;
        } else if (bottom) |value| {
            if (containing_height) |height| {
                const desired_y = containing_y +| height -| value -|
                    self.margin.bottom -| self.height.get().*;
                self.position_offset.y = desired_y -| self.y.get().*;
            }
        }
    }

    fn floatBoundsAt(
        self: *const BlockLayout,
        y: i32,
        base_x: i32,
        base_width: i32,
    ) ContentBounds {
        var left = base_x;
        var right = base_x +| @max(base_width, 0);
        for (self.floats.items) |float_box| {
            if (y < float_box.top() or y >= float_box.bottom()) continue;
            switch (float_box.side) {
                .left => left = @max(left, float_box.rightEdge()),
                .right => right = @min(right, float_box.leftEdge()),
                .none => {},
            }
        }
        return .{ .x = left, .width = @max(right -| left, 0) };
    }

    fn clearBottom(self: *const BlockLayout, y: i32, clear: ClearSide) i32 {
        var bottom = y;
        for (self.floats.items) |float_box| {
            const applies = switch (clear) {
                .left => float_box.side == .left,
                .right => float_box.side == .right,
                .both => float_box.side == .left or float_box.side == .right,
                .none => false,
            };
            if (applies and float_box.bottom() > bottom) bottom = float_box.bottom();
        }
        return bottom;
    }

    fn nextFloatBottom(self: *const BlockLayout, y: i32) ?i32 {
        var next: ?i32 = null;
        for (self.floats.items) |float_box| {
            if (y < float_box.top() or y >= float_box.bottom()) continue;
            const bottom = float_box.bottom();
            if (next == null or bottom < next.?) next = bottom;
        }
        return next;
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
                return layout_hit.StackingKey.before(
                    layoutChildPaintKey(children[left], left),
                    layoutChildPaintKey(children[right], right),
                );
            }
        }.lessThan);
    }

    fn layout(self: *BlockLayout, engine: *Layout) anyerror!void {
        const inherited_float_rebuild = if (self.parent_block) |parent|
            parent.floatContextForChildren().rebuilding_floats
        else
            false;
        // Skip layout if nothing is dirty
        if (!self.layoutNeeded() and !inherited_float_rebuild) return;
        self.paint_dirty = true;
        self.document.paint_dirty = true;
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

        // Compute position and dimensions.
        //
        // Fixed boxes remain in the DOM/layout tree for inherited styles and
        // descendants, but resolve their used offsets against the owning
        // frame viewport. Their outer paint group carries the same attachment
        // through raster so page scrolling does not move them.
        const position_mode = self.positionMode();
        const fixed_to_viewport = position_mode == .fixed and self.embedded_box == null;
        const table_box = self.table_box;
        // Use .read() to register invalidation dependencies on parent/document/previous fields
        const parent_zoom = if (self.parent_block) |pb|
            if (self.persistent_dependencies) pb.zoom.read(&self.zoom, self.allocator).* else pb.zoom.get().*
        else if (self.persistent_dependencies)
            self.document.zoom.read(&self.zoom, self.allocator).*
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

        var parent_x = if (self.parent_block) |pb|
            (if (self.persistent_dependencies) pb.x.read(&self.x, self.allocator).* else pb.x.get().*) +
                pb.border.left + pb.padding.left
        else if (self.persistent_dependencies)
            self.document.x.read(&self.x, self.allocator).*
        else
            self.document.x.get().*;
        var parent_width = if (self.parent_block) |pb|
            pb.content_width
        else if (self.persistent_dependencies)
            self.document.width.read(&self.width, self.allocator).*
        else
            self.document.width.get().*;
        var containing_width_css = cssPixelsFromLayout(
            parent_width,
            parent_zoom,
            self.document.page_zoom,
        );
        var containing_height_css = if (self.parent_block) |pb| blk: {
            if (pb.height.dirty or !pb.content_height_definite) break :blk null;
            const height = pb.content_height;
            if (height <= 0) break :blk null;
            break :blk cssPixelsFromLayout(height, pb.zoom.get().*, self.document.page_zoom);
        } else null;
        if (fixed_to_viewport) {
            parent_x = 0;
            parent_width = @max(engine.layoutWindowWidth() - engine.layoutScrollbarWidth(), 0);
            containing_width_css = cssPixelsFromLayout(
                parent_width,
                self.document.zoom.get().*,
                self.document.page_zoom,
            );
            containing_height_css = cssPixelsFromLayout(
                engine.layoutWindowHeight(),
                self.document.zoom.get().*,
                self.document.page_zoom,
            );
        } else if (table_box) |box| {
            // A table pass supplies a grid border box. It replaces normal
            // predecessor/float placement, but the child retains its own
            // padding, borders, descendants, effects, and paint cache.
            parent_x = box.x;
            parent_width = box.width;
            containing_width_css = cssPixelsFromLayout(
                box.width,
                self.document.zoom.get().*,
                self.document.page_zoom,
            );
            containing_height_css = if (box.height) |height|
                cssPixelsFromLayout(height, self.document.zoom.get().*, self.document.page_zoom)
            else
                null;
        }

        const edge_values = if (self.embedded_box == null) switch (self.node) {
            .element => |*element| if (element.style) |*style_map|
                resolveBoxEdges(
                    style_map,
                    self.computedFontSizeCss(),
                    containing_width_css,
                    zoom_value,
                    engine.zoom(),
                )
            else
                BoxModelEdges{ .margin = .{}, .padding = .{}, .border = .{} },
            .text => BoxModelEdges{ .margin = .{}, .padding = .{}, .border = .{} },
        } else BoxModelEdges{ .margin = .{}, .padding = .{}, .border = .{} };
        self.margin = edge_values.margin;
        self.padding = edge_values.padding;
        self.border = edge_values.border;
        const auto_margins = if (self.embedded_box == null) switch (self.node) {
            .element => |*element| if (element.style) |*style_map|
                horizontalAutoMargins(style_map)
            else
                box_model.HorizontalAutoMargins{},
            .text => box_model.HorizontalAutoMargins{},
        } else box_model.HorizontalAutoMargins{};

        // A non-first sibling is positioned from the preceding block, so it
        // intentionally has no dependency on the parent's y field. Avoid
        // reading that field here: ProtectedField requires every read target
        // to have been registered during initialization.
        const previous = if (self.persistent_dependencies)
            self.previous.read(&self.y, self.allocator).*
        else
            self.previous.get().*;
        const parent_content_y = if (fixed_to_viewport)
            0
        else if (table_box) |box|
            box.y
        else if (previous == null) blk: {
            if (self.parent_block) |pb| {
                const parent_y = if (self.persistent_dependencies)
                    pb.y.read(&self.y, self.allocator).*
                else
                    pb.y.get().*;
                break :blk parent_y + pb.border.top + pb.padding.top;
            }
            break :blk if (self.persistent_dependencies)
                self.document.y.read(&self.y, self.allocator).*
            else
                self.document.y.get().*;
        } else 0;
        const prev_y = if (fixed_to_viewport)
            self.margin.top
        else if (table_box) |box|
            box.y
        else if (previous) |prev|
            (if (self.persistent_dependencies)
                prev.y.read(&self.y, self.allocator).* + prev.height.read(&self.y, self.allocator).*
            else
                prev.y.get().* + prev.height.get().*) +
                collapseAdjoiningMargins(prev.margin.bottom, self.margin.top)
        else
            parent_content_y + self.margin.top + if (self.parent_block) |pb|
                tableOfContentsHeaderHeight(
                    pb.node,
                    pb.zoom.get().*,
                    engine.zoom(),
                )
            else
                0;

        if (self.tableRole() == .table and table_box == null) {
            // The intrinsic table width depends on its actual DOM-backed
            // descendants. Build that child tree before the outer box picks a
            // shrink-to-fit used width; ordinary blocks remain lazy below.
            try self.rebuildChildrenIfNeeded();
        }
        const width_context = parser.CssLengthResolutionContext{
            .font_size = self.computedFontSizeCss(),
            .percentage_base = containing_width_css,
        };
        const unconstrained_width = if (self.embedded_box == null)
            if (self.specifiedPixelDimension("width", &self.width, width_context)) |width|
                scaleCssPixel(width, zoom_value, engine.zoom())
            else
                null
        else
            null;
        const min_width = if (self.embedded_box == null)
            if (self.specifiedPixelDimension("min-width", &self.width, width_context)) |width|
                scaleCssPixel(width, zoom_value, engine.zoom())
            else
                null
        else
            null;
        const max_width = if (self.embedded_box == null)
            if (self.specifiedPixelDimension("max-width", &self.width, width_context)) |width|
                scaleCssPixel(width, zoom_value, engine.zoom())
            else
                null
        else
            null;
        const style_specified_width = if (unconstrained_width) |width|
            constrainDimension(width, min_width, max_width)
        else
            null;
        const specified_width = style_specified_width orelse
            if (self.tableRole() == .table and table_box == null)
                try self.preferredTableWidth(zoom_value, engine.zoom(), containing_width_css)
            else
                null;
        const base_content_bounds = if (self.embedded_box) |embedded|
            ContentBounds{ .x = embedded.x, .width = embedded.width }
        else if (fixed_to_viewport)
            ContentBounds{ .x = 0, .width = parent_width }
        else if (table_box) |box|
            ContentBounds{ .x = box.x, .width = box.width }
        else
            contentBoundsForNode(
                self.node,
                parent_x,
                parent_width,
                scaleCssPixel(list_item_indent, zoom_value, engine.zoom()),
            );
        const height_context = parser.CssLengthResolutionContext{
            .font_size = self.computedFontSizeCss(),
            .percentage_base = containing_height_css,
        };
        const unconstrained_height = if (self.embedded_box == null)
            if (self.specifiedPixelDimension("height", &self.height, height_context)) |height|
                scaleCssPixel(height, zoom_value, engine.zoom())
            else
                null
        else
            null;
        const min_height = if (self.embedded_box == null)
            if (self.specifiedPixelDimension("min-height", &self.height, height_context)) |height|
                scaleCssPixel(height, zoom_value, engine.zoom())
            else
                null
        else
            null;
        const max_height = if (self.embedded_box == null)
            if (self.specifiedPixelDimension("max-height", &self.height, height_context)) |height|
                scaleCssPixel(height, zoom_value, engine.zoom())
            else
                null
        else
            null;
        const style_specified_height = if (unconstrained_height) |height|
            constrainDimension(height, min_height, max_height)
        else
            null;
        const specified_height = if (table_box) |box|
            if (box.height) |height|
                @max(height -| self.padding.vertical() -| self.border.vertical(), 0)
            else
                style_specified_height
        else
            style_specified_height;
        const horizontal_insets = self.padding.horizontal() + self.border.horizontal();
        // Table grid placement supplies the border box directly. A cell or
        // row must not independently enter the surrounding float context.
        const float_side: FloatSide = if (table_box == null) self.floatSide() else .none;
        const normal_flow_placement = if (table_box == null and
            !isOutOfFlowPosition(position_mode) and float_side == .none)
            self.normal_flow_placement
        else
            null;
        const shrink_to_fit_width = if (specified_width == null and
            (isOutOfFlowPosition(position_mode) or float_side != .none))
        shrink: {
            const element = switch (self.node) {
                .element => |*value| value,
                .text => break :shrink null,
            };
            const css_width = shrinkToFitSpecifiedContentWidth(
                element,
                containing_width_css,
                self.computedFontSizeCss(),
            ) orelse break :shrink null;
            break :shrink scaleCssPixel(css_width, zoom_value, engine.zoom());
        } else null;
        var layout_y = prev_y;
        if (normal_flow_placement) |placement| {
            var adjoining = placement.preceding_margin;
            adjoining.append(self.margin.top);
            layout_y = placement.origin_y +| adjoining.used();
        }
        var float_x: ?i32 = null;
        var clearance_applied = false;

        if (table_box == null) {
            if (self.parent_block) |parent| {
                if (!isOutOfFlowPosition(position_mode)) {
                    const float_context = parent.floatContextForChildren();
                    const clear_side = self.clearSide();
                    if (clear_side != .none) {
                        const clear_origin = if (normal_flow_placement) |placement|
                            placement.origin_y
                        else
                            layout_y;
                        const cleared_y = float_context.clearBottom(clear_origin, clear_side);
                        if (normal_flow_placement) |placement| {
                            // Clearance creates a real separator. If it moves
                            // this box, do not let an adjoining predecessor
                            // margin pull its border back through the cleared
                            // float; retain only this box's own top margin.
                            if (cleared_y > layout_y) {
                                layout_y = @max(
                                    cleared_y,
                                    placement.origin_y +| self.margin.top,
                                );
                                clearance_applied = true;
                            }
                        } else {
                            layout_y = cleared_y;
                        }
                    }

                    if (float_side != .none) {
                        // A specified float width is enough to place the common CSS
                        // case precisely. Auto floats use the available line width,
                        // which keeps them deterministic until shrink-to-fit sizing
                        // is added to the replaced/content measurement path.
                        var candidate_width = if (specified_width) |width|
                            @max(width + horizontal_insets, 0)
                        else if (shrink_to_fit_width) |width|
                            @max(width + horizontal_insets, 0)
                        else
                            @max(base_content_bounds.width - self.margin.horizontal(), 0);

                        while (true) {
                            const available = float_context.floatBoundsAt(
                                layout_y,
                                base_content_bounds.x,
                                base_content_bounds.width,
                            );
                            const outer_width = candidate_width + self.margin.horizontal();
                            if (available.width >= outer_width) {
                                float_x = if (float_side == .left)
                                    available.x + self.margin.left
                                else
                                    available.x + available.width - self.margin.right - candidate_width;
                                break;
                            }
                            const next_y = float_context.nextFloatBottom(layout_y) orelse break;
                            if (next_y <= layout_y) break;
                            layout_y = next_y;
                            if (specified_width == null and shrink_to_fit_width == null) {
                                candidate_width = @max(
                                    float_context.floatBoundsAt(
                                        layout_y,
                                        base_content_bounds.x,
                                        base_content_bounds.width,
                                    ).width - self.margin.horizontal(),
                                    0,
                                );
                            }
                        }
                    }
                }
            }
        }

        // A float narrows its own available width, and a new formatting
        // context (for example overflow:hidden or display:table) keeps its
        // border box clear of external floats. An ordinary in-flow block does
        // neither: its background spans the containing block underneath the
        // float while inlineContentBounds narrows only its line boxes.
        const content_bounds = if (table_box != null)
            base_content_bounds
        else if (self.parent_block) |parent|
            if (!isOutOfFlowPosition(position_mode) and
                (float_side != .none or blockAvoidsExternalFloats(self)))
                parent.floatContextForChildren().floatBoundsAt(
                    layout_y,
                    base_content_bounds.x,
                    base_content_bounds.width,
                )
            else
                base_content_bounds
        else
            base_content_bounds;
        const auto_content_width = @max(
            content_bounds.width - self.margin.horizontal() - horizontal_insets,
            0,
        );
        const auto_width = if (shrink_to_fit_width) |width|
            @min(width, auto_content_width)
        else
            auto_content_width;
        const used_content_width = specified_width orelse
            constrainDimension(auto_width, min_width, max_width);
        const border_box_width = @max(used_content_width + horizontal_insets, 0);
        // Horizontal auto margins absorb the remaining inline space only for
        // normal-flow block boxes. Floats and absolutely positioned boxes use
        // separate CSS sizing rules and keep auto margins at their resolved
        // zero value here.
        if (specified_width != null and
            !isOutOfFlowPosition(position_mode) and
            float_side == .none and
            table_box == null and
            self.isBlockContainer() and
            (auto_margins.left or auto_margins.right))
        {
            const remaining = @max(
                content_bounds.width -| border_box_width -| self.margin.horizontal(),
                0,
            );
            if (auto_margins.left and auto_margins.right) {
                self.margin.left = @divFloor(remaining, 2);
                self.margin.right = remaining -| self.margin.left;
            } else if (auto_margins.left) {
                self.margin.left = remaining;
            } else {
                self.margin.right = remaining;
            }
        }
        self.x.set(if (self.embedded_box) |embedded|
            embedded.x
        else if (table_box) |box|
            box.x
        else if (float_x) |x|
            x
        else
            content_bounds.x + self.margin.left);
        self.y.set(if (self.embedded_box) |embedded|
            embedded.y
        else if (table_box) |box|
            box.y
        else
            layout_y);
        self.width.set(if (self.embedded_box) |embedded|
            embedded.width
        else if (table_box) |box|
            box.width
        else
            border_box_width);
        self.content_width = if (self.embedded_box) |embedded|
            embedded.width
        else
            @max(self.width.get().* - horizontal_insets, 0);
        if (engine.collect_hit_test_bounds) {
            if (self.node_ptr) |ptr| try engine.recordFragmentTargets(ptr, layout_y);
        }

        var is_block = self.isBlockContainer();
        if (self.node == .element) {
            const element = &self.node.element;
            const tag = element.tag;
            if (std.ascii.eqlIgnoreCase(tag, "input") or
                (std.ascii.eqlIgnoreCase(tag, "button") and !self.rich_button_root) or
                elementUsesImageLayout(element) or
                std.ascii.eqlIgnoreCase(tag, "canvas") or
                std.ascii.eqlIgnoreCase(tag, "iframe"))
            {
                is_block = false;
            }
        }

        // Publish a definite block height before laying out descendants so a
        // percentage height can resolve against this containing block. Auto
        // heights remain unavailable until children have been measured.
        if (is_block) {
            self.content_height_definite = specified_height != null;
            if (specified_height) |height| {
                self.content_height = height;
                self.height.set(@max(height + self.padding.vertical() + self.border.vertical(), 0));
            } else {
                self.content_height = 0;
            }
        }

        // Reset any cached inline commands
        DisplayItem.freeItems(self.allocator, self.display_list.items);
        self.display_list.clearRetainingCapacity();

        const owns_float_context = self.establishesFloatContext();
        if (owns_float_context) {
            self.floats.clearRetainingCapacity();
            self.rebuilding_floats = true;
        }
        defer {
            if (owns_float_context) self.rebuilding_floats = false;
        }

        var natural_height: i32 = 0;
        var normal_flow_ending: ?NormalFlowResult = null;
        var normal_flow_bottom_collapses = false;
        if (is_block) {
            self.used_inline_layout = false;
            self.inline_paint_dirty = false;
            try self.rebuildChildrenIfNeeded();

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
                    self.height.addDependency(dep, self.allocator);
                }
                self.height.addDependency(&self.children_version, self.allocator);
                self.height.frozen_dependencies = true;
            }

            const table_role = self.tableRole();
            if (table_role == .table) {
                const auto_height = try self.layoutTableChildren(engine);
                natural_height = auto_height;
                self.content_height = specified_height orelse
                    constrainDimension(auto_height, min_height, max_height);
                self.height.set(@max(
                    self.content_height + self.padding.vertical() + self.border.vertical(),
                    0,
                ));
            } else if (self.table_row_columns) |columns| {
                const natural_content_height = try self.layoutTableRowChildren(
                    engine,
                    columns,
                    0,
                );
                self.content_height = specified_height orelse
                    constrainDimension(natural_content_height, min_height, max_height);
                if (self.content_height != natural_content_height) {
                    _ = try self.layoutTableRowChildren(
                        engine,
                        columns,
                        self.content_height,
                    );
                }
                natural_height = natural_content_height;
                self.height.set(@max(
                    self.content_height + self.padding.vertical() + self.border.vertical(),
                    0,
                ));
            } else {
                // Layout all children and compute height.
                var computed_height: i32 = 0;
                const float_context = self.floatContextForChildren();
                const flow_origin = self.y.get().* + self.border.top + self.padding.top +
                    tableOfContentsHeaderHeight(self.node, zoom_value, engine.zoom());
                var flow_cursor = NormalFlowResult{ .cursor_y = flow_origin };
                var has_flow_barrier = false;
                _ = self.children_version.read(&self.height, self.allocator);
                for (self.children.items) |child| {
                    switch (child) {
                        .block => |b| {
                            // A sibling float can change a later block's line
                            // ranges or force a new formatting context beside
                            // it, even when that block's own style is clean.
                            // Mark it before layout so those exclusions are
                            // recomputed without incorrectly narrowing ordinary
                            // block backgrounds.
                            if (!isOutOfFlowPosition(b.positionMode()) and
                                (float_context.floats.items.len > 0 or b.clearSide() != .none))
                            {
                                b.mark();
                            }
                            const child_is_out_of_flow = isOutOfFlowPosition(b.positionMode());
                            const child_is_float = b.floatSide() != .none;
                            if (!child_is_out_of_flow and !child_is_float) {
                                b.setNormalFlowPlacement(.{
                                    .origin_y = flow_cursor.cursor_y,
                                    .preceding_margin = flow_cursor.trailing_margin,
                                });
                            } else {
                                b.clearNormalFlowPlacement();
                                has_flow_barrier = true;
                            }
                            try b.layout(engine);
                            const child_height = b.height.read(&self.height, self.allocator).*;
                            if (child_is_out_of_flow) {
                                // Absolutely positioned descendants paint in this
                                // subtree but contribute no normal-flow height.
                            } else if (child_is_float) {
                                try float_context.floats.append(float_context.allocator, .{
                                    .side = b.floatSide(),
                                    .x = b.x.get().*,
                                    .y = b.y.get().*,
                                    .width = b.width.get().*,
                                    .height = child_height,
                                    .margin = b.margin,
                                });
                            } else {
                                const child_flow = b.normal_flow_result orelse NormalFlowResult{
                                    .cursor_y = b.y.get().* +| child_height,
                                    .trailing_margin = MarginStrut.init(b.margin.bottom),
                                };
                                flow_cursor = child_flow;
                                computed_height = @max(
                                    computed_height,
                                    flow_cursor.cursor_y -| flow_origin,
                                );
                            }
                        },
                        .line => |l| {
                            has_flow_barrier = true;
                            try l.layout(engine);
                            computed_height += l.height.read(&self.height, self.allocator).*;
                        },
                    }
                }
                normal_flow_bottom_collapses = self.canCollapseBottomMargin(
                    is_block,
                    specified_height,
                    min_height,
                    has_flow_barrier,
                );
                if (!normal_flow_bottom_collapses) {
                    const trailing_bottom = flow_cursor.cursor_y +|
                        flow_cursor.trailing_margin.used();
                    computed_height = @max(computed_height, trailing_bottom -| flow_origin);
                }
                normal_flow_ending = flow_cursor;
                if (owns_float_context) {
                    for (self.floats.items) |float_box| {
                        computed_height = @max(float_box.bottom() -| flow_origin, computed_height);
                    }
                }
                const auto_height = computed_height + tableOfContentsHeaderHeight(
                    self.node,
                    zoom_value,
                    engine.zoom(),
                );
                natural_height = auto_height;
                self.content_height = specified_height orelse
                    constrainDimension(auto_height, min_height, max_height);
                self.height.set(@max(
                    self.content_height + self.padding.vertical() + self.border.vertical(),
                    0,
                ));
            }
        } else {
            // Inline layout mode - use the old approach for now
            // TODO: Refactor to populate LineLayout and TextLayout objects
            self.height.frozen_dependencies = false;
            self.content_height_definite = specified_height != null;
            try engine.layoutInlineBlock(self, true);
            self.used_inline_layout = true;
            self.inline_paint_dirty = false;

            if (self.children.items.len > 0) {
                for (self.children.items) |child| {
                    child.deinit(self.allocator);
                }
                self.children.clearRetainingCapacity();
            }
            self.children_epoch += 1;
            self.children_version.set(self.children_epoch);
            if (self.node_ptr) |node| switch (node.*) {
                .element => |*element| {
                    self.laid_out_dom_children = element.children.items.len;
                    element.clearChildrenDirty();
                },
                .text => self.laid_out_dom_children = 0,
            } else self.laid_out_dom_children = 0;

            natural_height = self.content_height;
            if (specified_height) |height| {
                self.content_height = height;
                self.content_height_definite = true;
            } else {
                self.content_height = constrainDimension(
                    self.content_height,
                    min_height,
                    max_height,
                );
            }
            self.height.set(@max(
                self.content_height + self.padding.vertical() + self.border.vertical(),
                0,
            ));

            // Height is set by layoutInlineBlock - need to ensure it uses .set()
        }

        const position_containing_height = if (fixed_to_viewport)
            engine.layoutWindowHeight()
        else if (self.parent_block) |parent|
            if (parent.content_height_definite) parent.content_height else null
        else
            null;
        self.updatePositionOffset(
            parent_x,
            parent_content_y,
            parent_width,
            position_containing_height,
            containing_width_css,
            containing_height_css,
            engine.zoom(),
        );

        if (normal_flow_placement) |placement| {
            if (self.canCollapseThrough(
                is_block,
                specified_height,
                min_height,
                natural_height,
                clearance_applied,
            )) {
                var collapsed = placement.preceding_margin;
                collapsed.append(self.margin.top);
                if (normal_flow_ending) |ending| {
                    collapsed.appendStrut(ending.trailing_margin);
                }
                collapsed.append(self.margin.bottom);
                self.normal_flow_result = .{
                    .cursor_y = placement.origin_y,
                    .trailing_margin = collapsed,
                    .collapses_through = true,
                };
            } else {
                var trailing = MarginStrut.init(self.margin.bottom);
                if (normal_flow_bottom_collapses) {
                    if (normal_flow_ending) |ending| {
                        trailing = ending.trailing_margin;
                        trailing.append(self.margin.bottom);
                    }
                }
                self.normal_flow_result = .{
                    .cursor_y = self.y.get().* +| self.height.get().*,
                    .trailing_margin = trailing,
                };
            }
        } else {
            self.normal_flow_result = null;
        }

        try recordElementFocusBounds(engine, self);

        self.updateScrollGeometry(specified_height, natural_height + self.padding.vertical() + self.border.vertical());

        // Clear descendant flags after layout pass
        self.has_dirty_descendants = false;
    }

    /// Reconcile direct DOM children with retained layout children. Table
    /// planning calls this before measuring a real row, but the conservative
    /// DOM-mutation path remains the only owner of child-array lifetime and
    /// layout-owner rebinding.
    fn rebuildChildrenIfNeeded(self: *BlockLayout) !void {
        var children_dirty = false;
        var insertions_only = false;
        var live_element: ?*parser.Element = null;
        if (self.node_ptr) |node| {
            switch (node.*) {
                .element => |*el| {
                    live_element = el;
                    if (el.children_dirty) {
                        children_dirty = true;
                        insertions_only = el.children_insertions_only;
                    }
                },
                else => {},
            }
        }

        if (!children_dirty and !self.children_version.dirty and self.children.items.len != 0) {
            return;
        }

        // Table contexts synthesize only ephemeral row/cell records, not DOM
        // nodes. Their direct-child topology can therefore change meaning when
        // a display value changes, so retain-insertion is deliberately kept to
        // ordinary block formatting contexts.
        const preserves_table_topology = self.tableRole() == .ordinary;
        var reused_children = false;
        if (insertions_only and preserves_table_topology) {
            // The host normally performs this rebind synchronously after child
            // storage moves. Repeat it defensively for direct DOM users that
            // honor the same insert marker.
            insertions_only = if (self.node_ptr) |node| self.rebindAfterInsert(node) else false;
        }

        if (insertions_only and preserves_table_topology and self.children.items.len > 0) {
            const element = live_element.?;
            if (try self.rebuildInsertedChildren(element)) {
                self.laid_out_dom_children = element.children.items.len;
                reused_children = true;
            }
        }

        if (!reused_children) {
            for (self.children.items) |child| {
                child.deinit(self.allocator);
            }
            self.children.clearRetainingCapacity();
            self.laid_out_dom_children = 0;

            if (live_element) |element| {
                try self.appendBlockChildren(element.children.items);
                self.laid_out_dom_children = element.children.items.len;
            }
        }

        self.children_epoch += 1;
        self.children_version.set(self.children_epoch);
        if (live_element) |element| element.clearChildrenDirty();
    }

    fn isIgnorableTableWhitespace(self: *const BlockLayout) bool {
        const nodes = self.inline_nodes orelse return false;
        for (nodes) |node| switch (node.*) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n\x0c").len != 0) return false;
            },
            .element => return false,
        };
        return true;
    }

    /// Build the temporary logical grid inputs for this table. A direct real
    /// row remains the owner of its own box; every other non-whitespace direct
    /// child participates in one anonymous row, which is sufficient for the
    /// CSS anonymous-table-box cases this bounded context supports.
    fn buildTablePlan(self: *BlockLayout) !TablePlan {
        std.debug.assert(self.tableRole() == .table);
        try self.rebuildChildrenIfNeeded();

        var plan = TablePlan.init(self.allocator);
        errdefer plan.deinit();
        var anonymous_row: ?usize = null;

        for (self.children.items) |child| {
            const block = switch (child) {
                .block => |value| value,
                .line => continue,
            };
            if (block.isIgnorableTableWhitespace()) continue;

            if (block.tableRole() == .row) {
                anonymous_row = null;
                try block.rebuildChildrenIfNeeded();
                const first_cell = plan.cells.items.len;
                for (block.children.items) |row_child| {
                    const cell = switch (row_child) {
                        .block => |value| value,
                        .line => continue,
                    };
                    if (cell.isIgnorableTableWhitespace()) continue;
                    try plan.cells.append(plan.allocator, cell);
                }
                try plan.rows.append(plan.allocator, .{
                    .owner = block,
                    .first_cell = first_cell,
                    .cell_count = plan.cells.items.len - first_cell,
                });
                continue;
            }

            const row_index = anonymous_row orelse row: {
                try plan.rows.append(plan.allocator, .{
                    .owner = null,
                    .first_cell = plan.cells.items.len,
                    .cell_count = 0,
                });
                const index = plan.rows.items.len - 1;
                anonymous_row = index;
                break :row index;
            };
            try plan.cells.append(plan.allocator, block);
            plan.rows.items[row_index].cell_count += 1;
        }
        return plan;
    }

    fn appendTableMetricRows(
        self: *const BlockLayout,
        rows: *std.ArrayList(table_format.Row),
        plan: *const TablePlan,
    ) !void {
        try rows.ensureTotalCapacity(self.allocator, plan.rows.items.len);
        for (plan.rows.items) |row| rows.appendAssumeCapacity(.{
            .first_cell = row.first_cell,
            .cell_count = row.cell_count,
        });
    }

    fn preferredTableCellWidth(
        self: *BlockLayout,
        parent_zoom: f32,
        engine_zoom: f32,
        containing_width_css: f64,
    ) std.mem.Allocator.Error!i32 {
        const element = liveBlockElement(self) orelse return 0;
        const styles = element.style orelse return 0;
        const local_zoom = parseCssZoom(styleValue(&styles, "zoom") orelse "1");
        const effective_zoom = combinedEffectiveZoom(parent_zoom, local_zoom);
        const context = parser.CssLengthResolutionContext{
            .font_size = self.computedFontSizeCss(),
            .percentage_base = containing_width_css,
        };
        const edges = resolveBoxEdges(
            &styles,
            self.computedFontSizeCss(),
            containing_width_css,
            effective_zoom,
            engine_zoom,
        );
        const raw_width = styleValue(&styles, "width") orelse "auto";
        var content_width: i32 = if (resolveCssLength(raw_width, context)) |width|
            scaleCssPixel(width, effective_zoom, engine_zoom)
        else
            0;
        if (self.tableRole() == .table and content_width == 0) {
            content_width = try self.preferredTableWidth(
                effective_zoom,
                engine_zoom,
                containing_width_css,
            );
        }
        return @max(content_width +| edges.padding.horizontal() +| edges.border.horizontal(), 0);
    }

    /// Return the bounded intrinsic table content width. The table format
    /// helper owns track math; this method only maps current DOM-backed boxes
    /// to scalar preferred widths.
    fn preferredTableWidth(
        self: *BlockLayout,
        zoom_value: f32,
        engine_zoom: f32,
        containing_width_css: f64,
    ) std.mem.Allocator.Error!i32 {
        var plan = try self.buildTablePlan();
        defer plan.deinit();
        if (plan.rows.items.len == 0) return 0;

        var rows = std.ArrayList(table_format.Row).empty;
        defer rows.deinit(self.allocator);
        try self.appendTableMetricRows(&rows, &plan);
        const column_count = table_format.columnCount(rows.items);
        if (column_count == 0) return 0;

        const metrics = try self.allocator.alloc(table_format.Cell, plan.cells.items.len);
        defer self.allocator.free(metrics);
        for (plan.cells.items, metrics) |cell, *metric| {
            metric.* = .{
                .preferred_width = try cell.preferredTableCellWidth(
                    zoom_value,
                    engine_zoom,
                    containing_width_css,
                ),
            };
        }
        const columns = try self.allocator.alloc(i32, column_count);
        defer self.allocator.free(columns);
        return table_format.resolveColumnWidths(rows.items, metrics, 0, columns);
    }

    /// Place one logical row in a resolved grid. A first pass measures natural
    /// cell heights; a constrained second pass stretches every shorter cell to
    /// the row height without changing DOM parentage or paint ownership.
    fn layoutTableCells(
        self: *BlockLayout,
        engine: *Layout,
        cells: []const *BlockLayout,
        columns: []const i32,
        x: i32,
        y: i32,
        minimum_height: i32,
    ) !i32 {
        std.debug.assert(cells.len <= columns.len);
        if (cells.len == 0) return @max(minimum_height, 0);

        const metrics = try self.allocator.alloc(table_format.Cell, cells.len);
        defer self.allocator.free(metrics);
        var cursor_x = x;
        for (cells, 0..) |cell, column| {
            try cell.layoutWithTableBox(engine, .{
                .x = cursor_x,
                .y = y,
                .width = columns[column],
            });
            metrics[column].natural_height = cell.height.get().*;
            cursor_x +|= columns[column];
        }

        const row = [_]table_format.Row{.{ .first_cell = 0, .cell_count = cells.len }};
        var heights: [1]i32 = undefined;
        const natural_height = table_format.resolveRowHeights(&row, metrics, &heights);
        const used_height = @max(natural_height, @max(minimum_height, 0));
        cursor_x = x;
        for (cells, 0..) |cell, column| {
            if (cell.height.get().* != used_height) {
                try cell.layoutWithTableBox(engine, .{
                    .x = cursor_x,
                    .y = y,
                    .width = columns[column],
                    .height = used_height,
                });
            }
            cursor_x +|= columns[column];
        }
        return used_height;
    }

    fn layoutWithTableBox(self: *BlockLayout, engine: *Layout, box: TableBox) !void {
        const previous_box = self.table_box;
        self.table_box = box;
        defer self.table_box = previous_box;
        self.mark();
        try self.layout(engine);
    }

    fn layoutWithTableRowBox(
        self: *BlockLayout,
        engine: *Layout,
        box: TableBox,
        columns: []const i32,
    ) !void {
        const previous_box = self.table_box;
        const previous_columns = self.table_row_columns;
        self.table_box = box;
        self.table_row_columns = columns;
        defer {
            self.table_row_columns = previous_columns;
            self.table_box = previous_box;
        }
        self.mark();
        try self.layout(engine);
    }

    fn layoutTableChildren(self: *BlockLayout, engine: *Layout) !i32 {
        var plan = try self.buildTablePlan();
        defer plan.deinit();
        if (plan.rows.items.len == 0) return 0;

        var rows = std.ArrayList(table_format.Row).empty;
        defer rows.deinit(self.allocator);
        try self.appendTableMetricRows(&rows, &plan);
        const column_count = table_format.columnCount(rows.items);
        if (column_count == 0) return 0;

        const metrics = try self.allocator.alloc(table_format.Cell, plan.cells.items.len);
        defer self.allocator.free(metrics);
        const containing_width_css = cssPixelsFromLayout(
            self.content_width,
            self.zoom.get().*,
            self.document.page_zoom,
        );
        for (plan.cells.items, metrics) |cell, *metric| {
            metric.* = .{
                .preferred_width = try cell.preferredTableCellWidth(
                    self.zoom.get().*,
                    engine.zoom(),
                    containing_width_css,
                ),
            };
        }
        const columns = try self.allocator.alloc(i32, column_count);
        defer self.allocator.free(columns);
        _ = table_format.resolveColumnWidths(rows.items, metrics, self.content_width, columns);

        const content_x = self.x.get().* + self.border.left + self.padding.left;
        var row_y = self.y.get().* + self.border.top + self.padding.top;
        const first_y = row_y;
        for (plan.rows.items) |row| {
            const row_cells = plan.cells.items[row.first_cell .. row.first_cell + row.cell_count];
            const row_height = if (row.owner) |owner| row_height: {
                try owner.layoutWithTableRowBox(engine, .{
                    .x = content_x,
                    .y = row_y,
                    .width = self.content_width,
                }, columns);
                break :row_height owner.height.get().*;
            } else try self.layoutTableCells(
                engine,
                row_cells,
                columns,
                content_x,
                row_y,
                0,
            );
            row_y +|= row_height;
        }
        return row_y -| first_y;
    }

    fn layoutTableRowChildren(
        self: *BlockLayout,
        engine: *Layout,
        columns: []const i32,
        minimum_height: i32,
    ) !i32 {
        var cells = std.ArrayList(*BlockLayout).empty;
        defer cells.deinit(self.allocator);
        for (self.children.items) |child| {
            const cell = switch (child) {
                .block => |value| value,
                .line => continue,
            };
            if (cell.isIgnorableTableWhitespace()) continue;
            try cells.append(self.allocator, cell);
        }
        const content_x = self.x.get().* + self.border.left + self.padding.left;
        const content_y = self.y.get().* + self.border.top + self.padding.top;
        return self.layoutTableCells(
            engine,
            cells.items,
            columns,
            content_x,
            content_y,
            minimum_height,
        );
    }

    fn lastInFlowBlock(self: *BlockLayout) ?*BlockLayout {
        var previous: ?*BlockLayout = null;
        for (self.children.items) |child| switch (child) {
            .block => |block| if (block.floatSide() == .none and !isOutOfFlowPosition(block.positionMode())) {
                previous = block;
            },
            .line => {},
        };
        return previous;
    }

    fn appendBlockChildren(self: *BlockLayout, nodes: []Node) !void {
        // Tables and real rows place their direct children in a grid, not in
        // the usual vertical predecessor chain. Cells themselves still use
        // normal block flow for their contents.
        const grid_children = switch (self.tableRole()) {
            .table, .row => true,
            .ordinary, .cell => false,
        };
        var previous: ?*BlockLayout = null;
        var index: usize = 0;
        while (index < nodes.len) {
            // A run-in heading is laid out with the following paragraph rather
            // than as its own block. Once both DOM nodes are in the same
            // anonymous block, normal inline recursion preserves the h6's
            // style while continuing straight into the paragraph text.
            if (isRunInHeadingNode(nodes[index]) and
                !isOutOfFlowPosition(nodePositionMode(nodes[index], if (self.persistent_dependencies) &self.children_version else null)) and
                index + 1 < nodes.len and isContainerNode(
                nodes[index + 1],
                if (self.persistent_dependencies) &self.children_version else null,
            )) {
                const run_in_nodes = try self.allocator.alloc(*Node, 2);
                errdefer self.allocator.free(run_in_nodes);
                run_in_nodes[0] = &nodes[index];
                run_in_nodes[1] = &nodes[index + 1];
                const child = try BlockLayout.initAnonymous(
                    self.allocator,
                    run_in_nodes,
                    self.document,
                    self,
                    if (grid_children) null else previous,
                );
                try self.children.append(self.allocator, .{ .block = child });
                if (!grid_children and child.floatSide() == .none and !isOutOfFlowPosition(child.positionMode())) {
                    previous = child;
                }
                index += 2;
                continue;
            }

            if (isContainerNode(
                nodes[index],
                if (self.persistent_dependencies) &self.children_version else null,
            )) {
                const child_node = &nodes[index];
                const child_position = nodePositionMode(
                    child_node.*,
                    if (self.persistent_dependencies) &self.children_version else null,
                );
                const child = try BlockLayout.init(
                    self.allocator,
                    child_node.*,
                    child_node,
                    self.document,
                    self,
                    if (grid_children or isOutOfFlowPosition(child_position)) null else previous,
                );
                try self.children.append(self.allocator, .{ .block = child });
                if (!grid_children and child.floatSide() == .none and !isOutOfFlowPosition(child.positionMode())) {
                    previous = child;
                }
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
            const child = try BlockLayout.initAnonymous(
                self.allocator,
                inline_nodes,
                self.document,
                self,
                if (grid_children) null else previous,
            );
            try self.children.append(self.allocator, .{ .block = child });
            if (!grid_children and child.floatSide() == .none and !isOutOfFlowPosition(child.positionMode())) {
                previous = child;
            }
        }
    }

    fn layoutNeeded(self: *const BlockLayout) bool {
        if (self.previous.dirty) return true;
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
        const width = self.width.get().*;
        const height = self.height.get().*;
        const effects = resolvedBlockEffects(self);
        const translation = effects.translation orelse paint_effects.Offset{};
        const localized = layout_hit.localizeBlock(parent_point, .{
            .child_origin = .{ .x = self.x.get().*, .y = self.y.get().* },
            .parent_origin = parent_origin,
            .size = .{ .width = width, .height = height },
            .position_offset = .{ .x = self.position_offset.x, .y = self.position_offset.y },
            .transform_translation = .{ .x = translation.x, .y = translation.y },
            .opacity = effects.opacity,
            .clip = .{
                .enabled = effects.border_radius > 0.0 or effects.clips_overflow,
                .radius = effects.border_radius,
            },
            .scroll_y = blockHitScrollY(self),
        }) orelse return null;
        const local = localized.local;
        const content_point = localized.content;
        const origin = HitPoint{ .x = self.x.get().*, .y = self.y.get().* };
        var order = layout_hit.ReverseOrder.init(self.paint_order.items, self.children.items.len);
        while (order.next()) |document_index| {
            if (self.children.items[document_index].hitTest(content_point, origin)) |hit| return hit;
        }

        // Inline-mode blocks still use the legacy inline formatter and do not
        // retain LineLayout/TextLayout children. Their local leaf query uses
        // the cached paint commands, preserving fragment gaps, controls, and
        // rich-button descendants until that TODO is removed.
        if (self.display_list.items.len > 0) {
            const absolute_content_point = layout_hit.addOffset(content_point, .{
                .x = self.x.get().*,
                .y = self.y.get().*,
            });
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

        if (!localized.hits_own_box) return null;
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

const wordNeedsNewLine = inline_format.wordNeedsNewLine;

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

test "position offsets share geometry with layout hit testing" {
    const allocator = std.testing.allocator;

    var root_node = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer root_node.deinit(allocator);
    var relative_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer relative_node.deinit(allocator);
    try setTestStyleValue(allocator, &relative_node, "position", "relative");
    try setTestStyleValue(allocator, &relative_node, "left", "20px");
    try setTestStyleValue(allocator, &relative_node, "top", "-5px");

    const document = try DocumentLayout.init(allocator, &root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    setTestLayoutBox(document, 0, 0, 500, 500);

    const relative = try BlockLayout.init(
        allocator,
        relative_node,
        &relative_node,
        document,
        null,
        null,
    );
    try document.children.append(allocator, relative);
    setTestLayoutBox(relative, 10, 20, 100, 40);
    relative.updatePositionOffset(0, 0, 500, 500, 500, 500, 1.0);
    try std.testing.expectEqual(PositionOffset{ .x = 20, .y = -5 }, relative.position_offset);

    const hit = document.hitTest(35, 20).?;
    try std.testing.expect(hit.node == &relative_node);
    try std.testing.expectEqual(@as(i32, 5), hit.local_x);
    try std.testing.expectEqual(@as(i32, 5), hit.local_y);
    try std.testing.expect(document.hitTest(15, 25).?.node == &root_node);

    var absolute_node = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer absolute_node.deinit(allocator);
    try setTestStyleValue(allocator, &absolute_node, "position", "absolute");
    try setTestStyleValue(allocator, &absolute_node, "right", "15px");
    try setTestStyleValue(allocator, &absolute_node, "bottom", "25px");
    const absolute = try BlockLayout.init(
        allocator,
        absolute_node,
        &absolute_node,
        document,
        relative,
        null,
    );
    defer {
        absolute.deinit();
        allocator.destroy(absolute);
    }
    setTestLayoutBox(absolute, 10, 20, 50, 40);
    absolute.updatePositionOffset(10, 20, 300, 200, 300, 200, 1.0);
    try std.testing.expectEqual(PositionOffset{ .x = 235, .y = 135 }, absolute.position_offset);
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
    if (!usesListItemMarker(element) or block.height.get().* <= 0) return;

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
        .page_zoom = self.zoom(),
        .source = displaySource(block, block.node_ptr),
    } });
}

fn elementUsesBlockFocusBox(element: *const parser.Element) bool {
    const style_map = if (element.style) |*styles| styles else return false;
    const display = styleValue(style_map, "display") orelse return false;
    return isBlockDisplay(display) or
        table_format.establishesFormattingContext(table_format.roleForDisplay(display));
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

fn layoutInlineBlock(self: *Layout, block: *BlockLayout, publish_geometry: bool) !void {
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

    self.cursor_y = block.y.get().* + block.border.top + block.padding.top;
    self.updateInlineBounds();
    self.cursor_x = self.line_left;
    self.line_direction = textDirectionForBlock(block, self.default_direction);
    self.size = self.default_font_size;
    self.font_size_css = @floatFromInt(self.default_font_size);
    self.line_height_css = null;
    self.is_bold = false;
    self.is_italic = false;
    self.font_family = .proportional;
    self.css_small_caps = false;
    // Centering belongs to the complete title block, not one buffered line.
    // Keeping this state stable lets explicit and automatic line breaks center
    // each completed line independently in flushLine().
    self.is_title = isCenteredTitleBlock(block);
    self.line_alignment = lineAlignmentForBlock(block, self.line_direction, self.is_title);
    self.is_superscript = isWithinSuperscriptBlock(block);
    self.is_small_caps = isWithinSmallCapsBlock(block);
    self.text_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }; // Reset to black
    self.is_preformatted = isWithinPreformattedBlock(block);
    self.last_was_collapsible_space = false;
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

                        const color_value = if (block.persistent_dependencies)
                            styleValueRead(style_map, "color", &block.height)
                        else
                            styleValue(style_map, "color");
                        if (color_value) |value| {
                            if (parseColor(value)) |color| self.text_color = color;
                        }

                        const weight_value = if (block.persistent_dependencies)
                            styleValueRead(style_map, "font-weight", &block.height)
                        else
                            styleValue(style_map, "font-weight");
                        if (weight_value) |value| {
                            self.is_bold = fontWeightIsBold(value);
                        }

                        const style_value = if (block.persistent_dependencies)
                            styleValueRead(style_map, "font-style", &block.height)
                        else
                            styleValue(style_map, "font-style");
                        if (style_value) |value| {
                            self.is_italic = std.ascii.eqlIgnoreCase(value, "italic") or
                                std.ascii.eqlIgnoreCase(value, "oblique");
                        }

                        const variant_value = if (block.persistent_dependencies)
                            styleValueRead(style_map, "font-variant", &block.height)
                        else
                            styleValue(style_map, "font-variant");
                        if (variant_value) |value| {
                            self.css_small_caps = std.ascii.eqlIgnoreCase(
                                std.mem.trim(u8, value, " \t\r\n"),
                                "small-caps",
                            );
                        }

                        // The anonymous block has no element of its own on
                        // which applyNodeStyles can establish inherited text
                        // metrics. Seed the computed font size from its
                        // containing element so bare text and replaced
                        // descendants use the same `em` base as inline
                        // elements.
                        const size_value = if (block.persistent_dependencies)
                            styleValueRead(style_map, "font-size", &block.height)
                        else
                            styleValue(style_map, "font-size");
                        if (size_value) |value| {
                            if (parser.resolveCssLength(value, .{
                                .font_size = self.font_size_css,
                                .percentage_base = self.font_size_css,
                            })) |size_css| {
                                self.font_size_css = size_css;
                                self.size = @intFromFloat(size_css * 0.75);
                            }
                        }

                        const line_height_value = if (block.persistent_dependencies)
                            styleValueRead(style_map, "line-height", &block.height)
                        else
                            styleValue(style_map, "line-height");
                        if (line_height_value) |value| {
                            self.line_height_css = resolveLineHeightCss(value, self.font_size_css);
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
            } else if (elementUsesImageLayout(&e)) {
                try self.handleImageElement(block.node, block.node_ptr, &line_buffer);
            } else if (std.ascii.eqlIgnoreCase(e.tag, "canvas")) {
                try self.handleCanvasElement(block.node_ptr, &line_buffer);
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
    if (publish_geometry) {
        const computed_height = self.cursor_y -
            (block.y.get().* + block.border.top + block.padding.top);
        block.content_height = if (computed_height < 0) 0 else computed_height;
        block.height.set(@max(
            block.content_height + block.padding.vertical() + block.border.vertical(),
            0,
        ));
    }
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

fn rootCanvasBackgroundColor(document: *const DocumentLayout) ?browser.Color {
    if (document.children.items.len == 0) return null;
    const element = liveBlockElement(document.children.items[0]) orelse return null;
    if (animatedBackgroundColor(element.*)) |color| return color;
    const styles = if (element.style) |*style_map| style_map else return null;
    const value = styleValue(styles, "background-color") orelse return null;
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "transparent")) return null;
    return parseColor(value);
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

test "root background color propagates to the canvas" {
    const allocator = std.testing.allocator;
    var root_node = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer root_node.deinit(allocator);
    try setTestStyleValue(allocator, &root_node, "background-color", "blue");
    const document = try DocumentLayout.init(allocator, &root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const root = try BlockLayout.init(allocator, root_node, &root_node, document, null, null);
    try document.children.append(allocator, root);

    try std.testing.expectEqual(
        browser.Color{ .r = 0, .g = 0, .b = 255, .a = 255 },
        rootCanvasBackgroundColor(document).?,
    );
}

pub fn buildDocument(self: *Layout, root: *Node) !*DocumentLayout {
    self.color_scheme_dark = self.resolveColorScheme("light dark");
    self.document_color_scheme_dark = self.color_scheme_dark;
    const document = try DocumentLayout.init(self.allocator, root);
    try document.layout(self);
    return document;
}

pub fn paintDocument(self: *Layout, document: *DocumentLayout) ![]DisplayItem {
    const content_height = documentScrollHeight(document.height.get().*);
    self.content_height = content_height;

    if (document.paint_dirty) {
        var commands = std.ArrayList(DisplayItem).empty;
        defer commands.deinit(self.allocator);
        var commands_own_items = true;
        errdefer if (commands_own_items) DisplayItem.freeItems(self.allocator, commands.items);

        const canvas_color: ?browser.Color = if (self.accessibility.forced_colors)
            forced_colors.canvas
        else if (rootCanvasBackgroundColor(document)) |color|
            self.remapColor(color, .background)
        else if (self.document_color_scheme_dark)
            if (self.accessibility.dark_palette) |palette|
                palette.background
            else
                browser.Color{ .r = 18, .g = 18, .b = 18, .a = 255 }
        else
            null;
        if (canvas_color) |bg_color| {
            const width = self.layoutWindowWidth();
            try commands.append(self.allocator, .{ .rect = .{
                .x1 = 0,
                .y1 = 0,
                .x2 = width,
                .y2 = @max(content_height, self.toLayoutPx(self.window_height)),
                .color = bg_color,
                .source = displaySource(document, document.node_ptr),
            } });
        }

        for (document.children.items) |child| {
            try refreshBlockPaintCache(self, child);
            try commands.append(self.allocator, .{ .cached_subtree = .{
                .list = &child.paint_cache,
                .source = displaySource(child, child.node_ptr),
            } });
        }

        const replacement = try commands.toOwnedSlice(self.allocator);
        commands_own_items = false;
        replaceRetainedPaintCache(
            self.allocator,
            &document.paint_cache,
            replacement,
            &document.paint_generation,
        );
        document.paint_dirty = false;
    }

    // Frame display lists retain only this stable root edge plus transient
    // focus/accessibility overlays. Browser-facing composition expands the
    // edge into an independently owned snapshot before crossing threads.
    self.display_list.clearRetainingCapacity();
    try self.display_list.append(self.allocator, .{ .cached_subtree = .{
        .list = &document.paint_cache,
        .source = displaySource(document, document.node_ptr),
    } });
    return try self.display_list.toOwnedSlice(self.allocator);
}

test "retained paint caches repaint one branch and preserve clean siblings" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main style='display:block'>" ++
            "<section id=left style='display:block'>left" ++
            "<div style='display:block'></div></section>" ++
            "<section id=right style='display:block'>right" ++
            "<div style='display:block'></div></section>" ++
            "</main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root_node = try html_parser.parse();
    defer root_node.deinit(allocator);
    parser.fixParentPointers(&root_node, null);
    try parser.style(allocator, &root_node, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    const first_frame = try engine.paintDocument(document);
    DisplayItem.freeList(allocator, first_frame);

    const root_layout = document.children.items[0];
    const left_layout = root_layout.children.items[0].block;
    const right_layout = root_layout.children.items[1].block;
    const left_inline = left_layout.children.items[0].block;
    const right_inline = right_layout.children.items[0].block;
    try std.testing.expect(!document.layoutNeeded());
    try std.testing.expect(left_inline.used_inline_layout);
    try std.testing.expect(right_inline.used_inline_layout);

    const document_generation = document.paint_generation;
    const root_generation = root_layout.paint_generation;
    const left_generation = left_layout.paint_generation;
    const left_inline_generation = left_inline.paint_generation;
    const right_generation = right_layout.paint_generation;
    const right_inline_generation = right_inline.paint_generation;

    // The element-backed section owns its box, while its bare text is held by
    // one anonymous inline cache. Paint invalidation must reach both without
    // turning into layout invalidation or touching the other section.
    parser.markPaintForElement(&root_node.element.children.items[0].element);
    try std.testing.expect(!document.layoutNeeded());
    try std.testing.expect(document.paint_dirty);
    try std.testing.expect(root_layout.paint_dirty);
    try std.testing.expect(left_layout.paint_dirty);
    try std.testing.expect(left_inline.paint_dirty);
    try std.testing.expect(left_inline.inline_paint_dirty);
    try std.testing.expect(!right_layout.paint_dirty);
    try std.testing.expect(!right_inline.paint_dirty);

    const second_frame = try engine.paintDocument(document);
    DisplayItem.freeList(allocator, second_frame);
    try std.testing.expectEqual(document_generation + 1, document.paint_generation);
    try std.testing.expectEqual(root_generation + 1, root_layout.paint_generation);
    try std.testing.expectEqual(left_generation + 1, left_layout.paint_generation);
    try std.testing.expectEqual(left_inline_generation + 1, left_inline.paint_generation);
    try std.testing.expectEqual(right_generation, right_layout.paint_generation);
    try std.testing.expectEqual(right_inline_generation, right_inline.paint_generation);

    // A requested frame with no dirty paint reuses every retained generation.
    const third_frame = try engine.paintDocument(document);
    DisplayItem.freeList(allocator, third_frame);
    try std.testing.expectEqual(document_generation + 1, document.paint_generation);
    try std.testing.expectEqual(root_generation + 1, root_layout.paint_generation);
    try std.testing.expectEqual(left_generation + 1, left_layout.paint_generation);
    try std.testing.expectEqual(left_inline_generation + 1, left_inline.paint_generation);
    try std.testing.expectEqual(right_generation, right_layout.paint_generation);
    try std.testing.expectEqual(right_inline_generation, right_inline.paint_generation);
}

test "paint-only inline refresh preserves fixed zoomed geometry" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main style='display:block'>" ++
            "<section style='display:block;zoom:2'>" ++
            "<div style='display:block;width:120px;height:40px'>fixed</div>" ++
            "<div style='display:block'>following</div>" ++
            "</section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root_node = try html_parser.parse();
    defer root_node.deinit(allocator);
    parser.fixParentPointers(&root_node, null);
    try parser.style(allocator, &root_node, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&root_node);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    const first_frame = try engine.paintDocument(document);
    DisplayItem.freeList(allocator, first_frame);

    const root_layout = document.children.items[0];
    const section = root_layout.children.items[0].block;
    const fixed = section.children.items[0].block;
    const following = section.children.items[1].block;
    try std.testing.expect(fixed.used_inline_layout);
    try std.testing.expect(following.used_inline_layout);
    const fixed_height = fixed.height.get().*;
    const following_y = following.y.get().*;

    // A frame-wide paint request must only replace command buffers. In
    // particular, regenerating the fixed block's inline commands must not
    // publish its content-derived text height and dirty the following block.
    document.markPaintSubtree();
    try std.testing.expect(!document.layoutNeeded());
    const second_frame = try engine.paintDocument(document);
    DisplayItem.freeList(allocator, second_frame);

    try std.testing.expect(!document.layoutNeeded());
    try std.testing.expectEqual(fixed_height, fixed.height.get().*);
    try std.testing.expectEqual(following_y, following.y.get().*);
}

test "document scroll height includes Chapter 5 page padding" {
    try std.testing.expectEqual(@as(i32, 136), documentScrollHeight(100));
    try std.testing.expectEqual(@as(i32, 36), documentScrollHeight(0));
    try std.testing.expectEqual(@as(i32, 36), documentScrollHeight(-100));
    try std.testing.expectEqual(std.math.maxInt(i32), documentScrollHeight(std.math.maxInt(i32)));
}

fn replaceRetainedPaintCache(
    allocator: std.mem.Allocator,
    cache: *std.ArrayList(DisplayItem),
    replacement: []DisplayItem,
    generation: *u64,
) void {
    DisplayItem.freeItems(allocator, cache.items);
    cache.deinit(allocator);
    cache.* = std.ArrayList(DisplayItem).fromOwnedSlice(replacement);
    generation.* +%= 1;
    if (generation.* == 0) generation.* = 1;
}

fn refreshInlinePaintCommands(self: *Layout, block: *BlockLayout) !void {
    if (!block.inline_paint_dirty or !block.used_inline_layout) return;

    const previous_commands = block.display_list;
    block.display_list = .empty;
    errdefer {
        DisplayItem.freeItems(self.allocator, block.display_list.items);
        block.display_list.deinit(self.allocator);
        block.display_list = previous_commands;
    }

    // Paint-only regeneration must not append duplicate geometry records to
    // the frame's retained hit-test collectors.
    const previous_collect = self.collect_hit_test_bounds;
    self.collect_hit_test_bounds = false;
    defer self.collect_hit_test_bounds = previous_collect;

    if (block.node_ptr) |node| block.node = node.*;
    try self.layoutInlineBlock(block, false);

    DisplayItem.freeItems(self.allocator, previous_commands.items);
    var old = previous_commands;
    old.deinit(self.allocator);
    block.inline_paint_dirty = false;
}

fn refreshTextPaintCache(self: *Layout, text: *TextLayout) !void {
    if (!text.paint_dirty) return;

    if (text.node_ptr) |node| {
        text.node = node.*;
        const style_map: ?*parser.StyleMap = switch (node.*) {
            .element => |*element| if (element.style) |*map| map else null,
            .text => |*value| if (value.style) |*map| map else null,
        };
        if (style_map) |map| {
            if (styleValue(map, "color")) |value| {
                if (parseColor(value)) |color| text.color = color;
            }
        }
    }

    var commands = std.ArrayList(DisplayItem).empty;
    defer commands.deinit(self.allocator);
    var commands_own_items = true;
    errdefer if (commands_own_items) DisplayItem.freeItems(self.allocator, commands.items);
    try text.paintToList(&commands, self);
    const replacement = try commands.toOwnedSlice(self.allocator);
    commands_own_items = false;
    replaceRetainedPaintCache(
        self.allocator,
        &text.paint_cache,
        replacement,
        &text.paint_generation,
    );
    text.paint_dirty = false;
}

fn refreshLinePaintCache(self: *Layout, line: *LineLayout) !void {
    if (!line.paint_dirty) return;

    var commands = std.ArrayList(DisplayItem).empty;
    defer commands.deinit(self.allocator);
    var commands_own_items = true;
    errdefer if (commands_own_items) DisplayItem.freeItems(self.allocator, commands.items);
    for (line.children.items) |text| {
        try refreshTextPaintCache(self, text);
        try commands.append(self.allocator, .{ .cached_subtree = .{
            .list = &text.paint_cache,
            .source = displaySource(text, text.node_ptr),
        } });
    }
    const replacement = try commands.toOwnedSlice(self.allocator);
    commands_own_items = false;
    replaceRetainedPaintCache(
        self.allocator,
        &line.paint_cache,
        replacement,
        &line.paint_generation,
    );
    line.paint_dirty = false;
}

/// Refresh one dirty paint-cache path. Clean descendants remain referenced by
/// stable cached_subtree edges; no command tree is cloned merely because a
/// sibling changed.
fn refreshBlockPaintCache(self: *Layout, block: *BlockLayout) !void {
    if (!block.paint_dirty) return;
    try refreshInlinePaintCommands(self, block);
    if (block.node_ptr) |node| block.node = node.*;

    if (!block.shouldPaint()) {
        const empty = try self.allocator.alloc(DisplayItem, 0);
        replaceRetainedPaintCache(
            self.allocator,
            &block.paint_cache,
            empty,
            &block.paint_generation,
        );
        block.paint_dirty = false;
        return;
    }

    // A float paint context needs a flattened, phase-ordered subtree instead
    // of cached child edges. Refresh the children first so this bounded escape
    // hatch still consumes the same current display-list inputs as the normal
    // retained path. Clean descendants retain their own cache generations.
    if (usesFloatPaintPhases(block)) {
        try block.refreshPaintOrder();
        for (block.paint_order.items) |document_index| {
            switch (block.children.items[document_index]) {
                .block => |child| try refreshBlockPaintCache(self, child),
                .line => |line| try refreshLinePaintCache(self, line),
            }
        }

        var phased_commands = std.ArrayList(DisplayItem).empty;
        defer phased_commands.deinit(self.allocator);
        var phased_commands_own_items = true;
        errdefer if (phased_commands_own_items) {
            DisplayItem.freeItems(self.allocator, phased_commands.items);
        };
        try paintBlockTreeRecursive(&phased_commands, self, block);
        const replacement = try phased_commands.toOwnedSlice(self.allocator);
        phased_commands_own_items = false;
        replaceRetainedPaintCache(
            self.allocator,
            &block.paint_cache,
            replacement,
            &block.paint_generation,
        );
        block.paint_dirty = false;
        return;
    }

    var commands = std.ArrayList(DisplayItem).empty;
    defer commands.deinit(self.allocator);
    var commands_own_items = true;
    errdefer if (commands_own_items) DisplayItem.freeItems(self.allocator, commands.items);

    try addBackgroundIfNeededToList(self, &commands, block);
    const content_start = commands.items.len;
    try appendTableOfContentsHeader(self, &commands, block);

    if (block.display_list.items.len > 0) {
        try commands.append(self.allocator, .{ .cached_subtree = .{
            .list = &block.display_list,
            .source = displaySource(block, block.node_ptr),
        } });
    }
    try appendListMarker(self, &commands, block);

    try block.refreshPaintOrder();
    for (block.paint_order.items) |document_index| {
        switch (block.children.items[document_index]) {
            .block => |child| {
                try refreshBlockPaintCache(self, child);
                try commands.append(self.allocator, .{ .cached_subtree = .{
                    .list = &child.paint_cache,
                    .source = displaySource(child, child.node_ptr),
                } });
            },
            .line => |line| {
                try refreshLinePaintCache(self, line);
                try commands.append(self.allocator, .{ .cached_subtree = .{
                    .list = &line.paint_cache,
                    .source = null,
                } });
            },
        }
    }

    try appendContentEditableCursor(self, &commands, block);
    try applyElementScroll(block, &commands, content_start);

    const owned_commands = try commands.toOwnedSlice(self.allocator);
    commands_own_items = false;
    const final_commands = try applyPaintEffects(self, block, owned_commands);
    var final_owned = true;
    errdefer if (final_owned) DisplayItem.freeList(self.allocator, final_commands);
    replaceRetainedPaintCache(
        self.allocator,
        &block.paint_cache,
        final_commands,
        &block.paint_generation,
    );
    final_owned = false;
    block.paint_dirty = false;
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
        if (item == .cached_subtree) {
            try writeDisplayItemsDebug(writer, item.cached_subtree.list.items, indent);
            continue;
        }
        try writeIndent(writer, indent);
        switch (item) {
            .cached_subtree => unreachable,
            .glyph => |glyph| try writer.print("glyph x={d} y={d} width={d} height={d} color=#{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ glyph.x, glyph.y, glyph.glyph.w, glyph.glyph.h, glyph.color.r, glyph.color.g, glyph.color.b, glyph.color.a }),
            .rect => |rect| try writer.print("rect x1={d} y1={d} x2={d} y2={d} color=#{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ rect.x1, rect.y1, rect.x2, rect.y2, rect.color.r, rect.color.g, rect.color.b, rect.color.a }),
            .image => |image| try writer.print("image x1={d} y1={d} x2={d} y2={d} source_width={d} source_height={d} opacity={d}\n", .{ image.x1, image.y1, image.x2, image.y2, image.source_width, image.source_height, image.opacity }),
            .canvas => |canvas| try writer.print("canvas x1={d} y1={d} x2={d} y2={d} source_width={d} source_height={d} opacity={d}\n", .{ canvas.x1, canvas.y1, canvas.x2, canvas.y2, canvas.source_width, canvas.source_height, canvas.opacity }),
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

/// Append the paint commands that belong after a block background but before
/// its descendant subtrees. This is deliberately separate from backgrounds so
/// a simple block can participate in the CSS float paint phases below.
fn appendBlockOwnPaintContent(
    commands: *std.ArrayList(DisplayItem),
    self: *Layout,
    block: *BlockLayout,
) !void {
    try appendTableOfContentsHeader(self, commands, block);
    for (block.display_list.items) |item| {
        try appendClonedDisplayItem(self.allocator, commands, item);
    }
    try appendListMarker(self, commands, block);
}

/// Prepaint the background/border portions of a simple static subtree. A
/// float is intentionally a boundary: it remains an atomic subtree in the
/// float phase, with its effects and descendants preserved by the normal
/// recursive painter.
fn appendStaticFloatPhaseBackgrounds(
    commands: *std.ArrayList(DisplayItem),
    self: *Layout,
    block: *BlockLayout,
) !void {
    if (!block.shouldPaint() or !isFloatPaintPhaseCandidate(block)) return;
    try addBackgroundIfNeededToList(self, commands, block);
    try block.refreshPaintOrder();
    for (block.paint_order.items) |document_index| {
        switch (block.children.items[document_index]) {
            .block => |child| {
                if (child.floatSide() == .none) {
                    try appendStaticFloatPhaseBackgrounds(commands, self, child);
                }
            },
            .line => {},
        }
    }
}

/// Paint the non-background portion of a simple static subtree. Its
/// backgrounds were emitted before the sibling float, so this pass emits
/// inline content and recursively retains atomic paint behavior for any
/// unsupported nested subtree.
fn appendStaticFloatPhaseContent(
    commands: *std.ArrayList(DisplayItem),
    self: *Layout,
    block: *BlockLayout,
) !void {
    if (!block.shouldPaint()) return;
    std.debug.assert(isFloatPaintPhaseCandidate(block));
    const float_phases = usesFloatPaintPhases(block);
    try block.refreshPaintOrder();
    if (float_phases) {
        for (block.paint_order.items) |document_index| {
            switch (block.children.items[document_index]) {
                .block => |child| if (child.floatSide() != .none) {
                    try paintBlockTreeRecursive(commands, self, child);
                },
                .line => {},
            }
        }
    }
    try appendBlockOwnPaintContent(commands, self, block);
    for (block.paint_order.items) |document_index| {
        switch (block.children.items[document_index]) {
            .block => |child| {
                if (float_phases and child.floatSide() != .none) continue;
                if (isFloatPaintPhaseCandidate(child)) {
                    try appendStaticFloatPhaseContent(commands, self, child);
                } else {
                    try paintBlockTreeRecursive(commands, self, child);
                }
            },
            .line => |line| try line.paintToList(commands, self),
        }
    }
    try appendContentEditableCursor(self, commands, block);
}

/// Append a block's descendants in source order, except for a conservative
/// direct-float context. In that case CSS paints simple normal-flow
/// backgrounds first, then floating subtrees, then inline/content paint. The
/// caller has already emitted the block's own background.
fn appendBlockPaintContents(
    commands: *std.ArrayList(DisplayItem),
    self: *Layout,
    block: *BlockLayout,
) !void {
    const float_phases = usesFloatPaintPhases(block);
    if (float_phases) {
        try block.refreshPaintOrder();
        for (block.paint_order.items) |document_index| {
            switch (block.children.items[document_index]) {
                .block => |child| if (child.floatSide() == .none) {
                    std.debug.assert(isFloatPaintPhaseCandidate(child));
                    try appendStaticFloatPhaseBackgrounds(commands, self, child);
                },
                .line => {},
            }
        }
        for (block.paint_order.items) |document_index| {
            switch (block.children.items[document_index]) {
                .block => |child| if (child.floatSide() != .none) {
                    try paintBlockTreeRecursive(commands, self, child);
                },
                .line => {},
            }
        }
    }

    try appendBlockOwnPaintContent(commands, self, block);
    try block.refreshPaintOrder();
    for (block.paint_order.items) |document_index| {
        switch (block.children.items[document_index]) {
            .block => |child| {
                if (float_phases and child.floatSide() != .none) continue;
                if (float_phases) {
                    std.debug.assert(isFloatPaintPhaseCandidate(child));
                    try appendStaticFloatPhaseContent(commands, self, child);
                } else {
                    try paintBlockTreeRecursive(commands, self, child);
                }
            },
            .line => |line| try line.paintToList(commands, self),
        }
    }
    try appendContentEditableCursor(self, commands, block);
}

// Recursively paint a block's subtree into a command list, applying effects
// for each atomic block. Float-phase candidates deliberately bypass only
// their own empty effect wrapper; every other subtree follows this path.
fn paintBlockTreeRecursive(
    commands: *std.ArrayList(DisplayItem),
    self: *Layout,
    block: *BlockLayout,
) anyerror!void {
    if (!block.shouldPaint()) return;

    var block_commands = std.ArrayList(DisplayItem).empty;
    defer block_commands.deinit(self.allocator);
    var block_commands_own_items = true;
    errdefer if (block_commands_own_items) {
        DisplayItem.freeItems(self.allocator, block_commands.items);
    };

    try addBackgroundIfNeededToList(self, &block_commands, block);
    const content_start = block_commands.items.len;
    try appendBlockPaintContents(&block_commands, self, block);
    try applyElementScroll(block, &block_commands, content_start);

    const owned_commands = try block_commands.toOwnedSlice(self.allocator);
    block_commands_own_items = false;
    const final_commands = try applyPaintEffects(self, block, owned_commands);

    // Reserve before transferring any owning command so failure cannot leave
    // a half-moved tree split between the temporary and destination lists.
    commands.ensureUnusedCapacity(self.allocator, final_commands.len) catch |err| {
        DisplayItem.freeList(self.allocator, final_commands);
        return err;
    };
    for (final_commands) |command| commands.appendAssumeCapacity(command);
    self.allocator.free(final_commands);
}

/// Keep the element's own background stationary while moving all of its
/// painted content. The enclosing overflow clip is installed below by
/// applyPaintEffects, so translated descendants cannot escape the box.
fn applyElementScroll(
    block: *BlockLayout,
    commands: *std.ArrayList(DisplayItem),
    content_start: usize,
) !void {
    const element = liveBlockElement(block) orelse return;
    try paint_effects.wrapScrolledSuffix(
        block.allocator,
        commands,
        content_start,
        if (element.scroll_container) @max(element.scroll_y, 0) else 0,
        opaqueElementForNode(block.node_ptr),
        displaySource(block, block.node_ptr),
    );
}

/// Transfer an owned block command list into the command-level effect builder.
/// Cache generations and dirty state remain owned by the calling layout object.
fn applyPaintEffects(
    self: *Layout,
    block: *const BlockLayout,
    commands: []DisplayItem,
) ![]DisplayItem {
    return paint_effects.wrapOwned(
        self.allocator,
        commands,
        resolvedBlockEffects(block),
        .{
            .bounds = .{
                .left = block.x.get().*,
                .top = block.y.get().*,
                .right = block.x.get().* + block.width.get().*,
                .bottom = block.y.get().* + block.height.get().*,
            },
            .position_offset = .{
                .x = block.position_offset.x,
                .y = block.position_offset.y,
            },
            .scroll_attachment = if (block.positionMode() == .fixed)
                .frame_viewport
            else
                .document,
            .identity = opaqueElementForNode(block.node_ptr),
            .source = displaySource(block, block.node_ptr),
        },
    );
}
fn borderColorForSide(
    self: *Layout,
    style_map: *const parser.StyleMap,
    element: *const parser.Element,
    property: []const u8,
) browser.Color {
    const value = styleValue(style_map, property) orelse "currentColor";
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "currentColor")) {
        return self.remapColor(textColorForElement(element), .border);
    }
    return self.remapColor(parseColor(value) orelse textColorForElement(element), .border);
}

fn textColorForElement(element: *const parser.Element) browser.Color {
    if (element.style) |*style_map| {
        if (styleValue(style_map, "color")) |value| {
            if (parseColor(value)) |color| return color;
        }
    }
    return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}

fn appendBorderBoxes(
    self: *Layout,
    commands: *std.ArrayList(DisplayItem),
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    edges: BoxEdges,
    style_map: *const parser.StyleMap,
    element: *const parser.Element,
    source: ?browser.DisplayItemSource,
) !void {
    if (width <= 0 or height <= 0) return;

    const side_data = [_]struct {
        width: i32,
        style_property: []const u8,
        color_property: []const u8,
    }{
        .{ .width = edges.top, .style_property = "border-top-style", .color_property = "border-top-color" },
        .{ .width = edges.right, .style_property = "border-right-style", .color_property = "border-right-color" },
        .{ .width = edges.bottom, .style_property = "border-bottom-style", .color_property = "border-bottom-color" },
        .{ .width = edges.left, .style_property = "border-left-style", .color_property = "border-left-color" },
    };
    for (side_data, 0..) |side, index| {
        if (side.width <= 0) continue;
        const style = styleValue(style_map, side.style_property) orelse "none";
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, style, " \t\r\n"), "none") or
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, style, " \t\r\n"), "hidden")) continue;
        const color = borderColorForSide(self, style_map, element, side.color_property);
        if (color.a == 0) continue;

        const rect = switch (index) {
            0 => browser.Rect{ .left = x, .top = y, .right = x + width, .bottom = y + @min(side.width, height) },
            1 => browser.Rect{ .left = x + @max(width - side.width, 0), .top = y, .right = x + width, .bottom = y + height },
            2 => browser.Rect{ .left = x, .top = y + @max(height - side.width, 0), .right = x + width, .bottom = y + height },
            3 => browser.Rect{ .left = x, .top = y, .right = x + @min(side.width, width), .bottom = y + height },
            else => unreachable,
        };
        if (rect.width() <= 0 or rect.height() <= 0) continue;
        try commands.append(self.allocator, .{ .rect = .{
            .x1 = rect.left,
            .y1 = rect.top,
            .x2 = rect.right,
            .y2 = rect.bottom,
            .color = color,
            .source = source,
        } });
    }
}

// Add an element's color, image background, and border to a command list.
// Keeping them in the subtree means opacity, transforms, scrolling, and
// rounded clips apply to the complete border box in one coherent order.
fn addBackgroundIfNeededToList(self: *Layout, commands: *std.ArrayList(DisplayItem), block: *const BlockLayout) !void {
    if (!block.shouldPaint()) return;
    // Anonymous inline-run blocks copy their first node only as a layout
    // representative; that node's background belongs to its inline payload,
    // not to the full-width wrapper.
    if (block.inline_nodes != null) return;
    const element = liveBlockElement(block) orelse return;
    const block_width = block.width.get().*;
    const block_height = block.height.get().*;
    if (block_width <= 0 or block_height <= 0) return;
    const block_x = block.x.get().*;
    const block_y = block.y.get().*;
    const source = displaySource(block, block.node_ptr);

    const styles = if (element.style) |*style_map| style_map else null;
    const bgcolor_str = if (styles) |style_map| styleValue(style_map, "background-color") else null;
    const border_radius_str = if (styles) |style_map| styleValue(style_map, "border-radius") else null;

    var color: ?browser.Color = null;
    if (animatedBackgroundColor(element.*)) |animated| {
        color = animated;
    } else if (bgcolor_str) |bg| {
        if (!std.ascii.eqlIgnoreCase(bg, "transparent")) color = parseColor(bg);
    } else if (std.mem.eql(u8, element.tag, "pre")) {
        color = .{ .r = 230, .g = 230, .b = 230, .a = 255 };
    }

    // The root element's background is propagated to the document canvas by
    // paintDocument. Avoid painting it a second time over only the root
    // block's content-sized border box.
    if (color != null and
        block.parent_block == null and
        rootCanvasBackgroundColor(block.document) != null)
    {
        color = null;
    }

    if (color) |value| {
        const radius = if (border_radius_str) |radius|
            scaleBlockCssFloat(block, parseCssPixelRadius(radius))
        else
            0;
        try appendBackgroundBox(
            commands,
            self.allocator,
            block_x,
            block_y,
            block_width,
            block_height,
            radius,
            self.remapColor(value, .background),
            source,
        );
    }

    // Forced-colors preserves content images but suppresses decorative author
    // backgrounds so the semantic high-contrast palette remains legible.
    if (!self.accessibility.forced_colors) {
        if (backgroundImagePaint(element)) |paint| {
            try appendBackgroundImageBox(
                commands,
                self.allocator,
                paint,
                block_x,
                block_y,
                block_width,
                block_height,
                scaleBlockCssFloat(block, 1.0),
                source,
            );
        }
    }

    if (styles) |style_map| {
        try appendBorderBoxes(
            self,
            commands,
            block_x,
            block_y,
            block_width,
            block_height,
            block.border,
            style_map,
            element,
            source,
        );
    }
}
