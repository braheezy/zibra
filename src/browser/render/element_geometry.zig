//! Synchronous CSSOM box queries over clean layout, independent of paint.
//! Retained inline fragments borrow the same DOM generation as their owning
//! BlockLayout or atomic-inline snapshot. Public query output owns only numbers.
const std = @import("std");
const dom = @import("../../document/dom.zig");
const box_model = @import("box_model.zig");
const effects = @import("paint_effects.zig");
pub const Rect = @import("../../core/rect.zig").Rect;

pub const Fragment = struct { node: *dom.Node, rect: Rect };

pub fn box(x: i32, y: i32, width: i32, height: i32) Rect {
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(width), .height = @floatFromInt(height) };
}

fn parent(node: *dom.Node) ?*dom.Node {
    return switch (node.*) {
        .element => |e| e.parent,
        .text => |t| t.parent,
    };
}

fn style(element: *const dom.Element, name: []const u8) []const u8 {
    const styles = if (element.style) |*s| s else return "";
    const field = styles.get(name) orelse return "";
    return field.get().*;
}

fn hidden(node: *dom.Node) bool {
    var current: ?*dom.Node = node;
    while (current) |value| : (current = parent(value)) {
        if (value.* == .element and std.mem.eql(u8, style(&value.element, "display"), "none")) return true;
    }
    return false;
}

/// Coalesce ordinary inline descendants once per visual line, in content
/// order. The containing block has its own border box and must not be widened
/// by overflowing descendants. Atomic participants keep a separate own box.
pub fn recordInline(
    allocator: std.mem.Allocator,
    fragments: *std.ArrayList(Fragment),
    line_start: usize,
    node: *dom.Node,
    stop: ?*dom.Node,
    own_rect: Rect,
    ancestor_rect: Rect,
    include_self: bool,
) !void {
    var current: ?*dom.Node = node;
    while (current) |value| : (current = parent(value)) {
        if (value == stop) break;
        if (value.* != .element) continue;
        if (value == node and !include_self) continue;
        const rect = if (value == node) own_rect else ancestor_rect;
        var found = false;
        for (fragments.items[line_start..]) |*entry| {
            if (entry.node != value) continue;
            entry.rect = entry.rect.unionWith(rect);
            found = true;
            break;
        }
        if (!found) try fragments.append(allocator, .{ .node = value, .rect = rect });
    }
}

/// Copy a temporary layout's boxes before it retires, or select one element
/// from a persistent tree. No pointer to the layout itself is retained.
pub fn captureBlock(block: anytype, target: ?*dom.Node, dx: f64, dy: f64, allocator: std.mem.Allocator, out: *std.ArrayList(Fragment)) anyerror!void {
    if (block.node_ptr) |node| if (hidden(node)) return;
    const x = dx + @as(f64, @floatFromInt(block.position_offset.x));
    const y = dy + @as(f64, @floatFromInt(block.position_offset.y));
    if (block.node_ptr) |node| {
        if (node.* == .element and (target == null or target == node)) {
            try out.append(allocator, .{ .node = node, .rect = box(block.x.get().*, block.y.get().*, block.width.get().*, block.height.get().*).translated(x, y) });
            if (target != null) return;
        }
    }
    for (block.geometry_fragments.items) |entry| {
        if (target == null or target == entry.node)
            try out.append(allocator, .{ .node = entry.node, .rect = entry.rect.translated(x, y) });
    }
    for (block.children.items) |child| switch (child) {
        .block => |value| try captureBlock(value, target, x, y, allocator, out),
        // The active inline formatter publishes fragments at final line
        // placement. Legacy TextLayout-only trees have no CSSOM fragments.
        .line => {},
    };
}

/// Read current boxes after the caller completes style and layout. The output
/// is a static numeric snapshot in the owning frame's CSS viewport; it never
/// includes native chrome or raster/accessibility scaling.
pub fn collect(document: anytype, target: *dom.Node, frame_zoom: f32, scroll_y: i32, unscaled: bool, allocator: std.mem.Allocator, out: *std.ArrayList(Rect)) !void {
    std.debug.assert(!document.layoutNeeded());
    if (hidden(target)) return;
    var fragments = std.ArrayList(Fragment).empty;
    defer fragments.deinit(allocator);
    for (document.children.items) |child| try captureBlock(child, target, 0, 0, allocator, &fragments);
    const authored_zoom = box_model.effectiveCssZoomForNode(target);
    const scale: f64 = 1.0 / (frame_zoom * (if (unscaled) authored_zoom else @as(f32, 1)));
    var dx: f64 = 0;
    var dy: f64 = 0;
    if (!unscaled) {
        var fixed = false;
        var current: ?*dom.Node = target;
        while (current) |node| : (current = parent(node)) {
            if (node.* != .element) continue;
            const element = &node.element;
            const resolved = effects.resolveElement(element, frame_zoom * box_model.effectiveCssZoomForNode(node), 1);
            if (resolved.translation) |translation| {
                dx += @floatFromInt(translation.x);
                dy += @floatFromInt(translation.y);
            }
            if (node != target and !fixed and element.scroll_container) dy -= @floatFromInt(element.scroll_y);
            if (std.mem.eql(u8, style(element, "position"), "fixed")) fixed = true;
        }
        if (!fixed) dy -= @floatFromInt(scroll_y);
    }
    for (fragments.items) |fragment| try out.append(allocator, fragment.rect.translated(dx, dy).scaled(scale));
}
