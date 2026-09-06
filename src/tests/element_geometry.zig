//! CSSOM geometry against real retained layout, without Browser presentation.
const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const geometry = @import("../browser/render/element_geometry.zig");
const parser = @import("../document/parser.zig");
const Rect = geometry.Rect;
const DisplayItem = @import("../browser/render/display_list.zig").DisplayItem;
const allocator = std.testing.allocator;

const Page = struct {
    root: parser.Node,
    engine: *Layout,
    document: ?*Layout.DocumentLayout = null,

    fn init(source: []const u8) !Page {
        var html = try parser.HTMLParser.init(allocator, source);
        defer html.deinit(allocator);
        html.use_implicit_tags = false;
        var root = try html.parse();
        errdefer root.deinit(allocator);
        var environ = std.process.Environ.Map.init(allocator);
        defer environ.deinit();
        try environ.put("HOME", "/tmp");
        return .{ .root = root, .engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false) };
    }

    fn deinit(self: *Page) void {
        if (self.document) |document| {
            document.deinit();
            allocator.destroy(document);
        }
        self.engine.deinit();
        self.root.deinit(allocator);
    }

    fn render(self: *Page) !void {
        parser.fixParentPointers(&self.root, null);
        try parser.style(allocator, &self.root, &.{});
        if (self.document) |document| try document.layout(self.engine) else self.document = try self.engine.buildDocument(&self.root);
    }

    fn rects(self: *Page, node: *parser.Node, scroll: i32, unscaled: bool) !std.ArrayList(Rect) {
        var result = std.ArrayList(Rect).empty;
        errdefer result.deinit(allocator);
        try geometry.collect(self.document.?, node, 1, scroll, unscaled, allocator, &result);
        return result;
    }

    fn metrics(self: *Page, node: *parser.Node) !geometry.Metrics {
        return geometry.measureMetrics(self.document.?, node, 1, .{ .width = 790, .height = 600 }, allocator);
    }
};

fn setStyle(node: *parser.Node, value: []const u8) !void {
    try node.element.attributes.?.put("style", value);
    @import("../document/dom.zig").dirtyStyleForElement(&node.element);
}

test "geometry border boxes update after style changes and resize without paint" {
    var page = try Page.init("<main style='display:block;width:400px'><div style='display:block;width:50%;height:40px;padding:5px;border:2px solid black;margin:3px'></div></main>");
    defer page.deinit();
    try page.render();
    const node = &page.root.element.children.items[0];
    var initial = try page.rects(node, 0, false);
    defer initial.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), initial.items.len);
    try std.testing.expectEqual(@as(f64, 214), initial.items[0].width);
    try std.testing.expectEqual(@as(f64, 54), initial.items[0].height);
    try setStyle(&page.root, "display:block;width:600px");
    try page.render();
    var updated = try page.rects(node, 0, false);
    defer updated.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 314), updated.items[0].width);
    try std.testing.expectEqual(@as(f64, 214), initial.items[0].width);
    try setStyle(node, "display:block;width:50%;height:40px;padding:5px;border:2px solid black;box-sizing:border-box");
    try page.render();
    var border_box = try page.rects(node, 0, false);
    defer border_box.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 300), border_box.items[0].width);
    try std.testing.expectEqual(@as(f64, 40), border_box.items[0].height);
    try setStyle(&page.root, "display:block;width:100%");
    page.engine.window_width = 1200;
    page.document.?.mark();
    try page.render();
    var resized = try page.rects(node, 0, false);
    defer resized.deinit(allocator);
    try std.testing.expect(resized.items[0].width > border_box.items[0].width);
}

test "geometry distinguishes hidden boxes transforms scroll and authored zoom" {
    var page = try Page.init("<main style='display:block;zoom:2;transform:translate(5px,7px)'><div style='display:block;width:30px;height:20px;visibility:hidden'></div></main>");
    defer page.deinit();
    try page.render();
    const node = &page.root.element.children.items[0];
    var normal = try page.rects(node, 0, false);
    defer normal.deinit(allocator);
    var scrolled = try page.rects(node, 25, false);
    defer scrolled.deinit(allocator);
    var unscaled = try page.rects(node, 25, true);
    defer unscaled.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 60), normal.items[0].width);
    try std.testing.expectEqual(@as(f64, 30), unscaled.items[0].width);
    try std.testing.expectEqual(normal.items[0].y - 25, scrolled.items[0].y);
    try std.testing.expectEqual(unscaled.items[0].x * 2 + 10, normal.items[0].x);
    try setStyle(&page.root, "display:none");
    try page.render();
    var hidden = try page.rects(node, 0, false);
    defer hidden.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), hidden.items.len);
    try setStyle(&page.root, "display:block");
    try setStyle(node, "display:block;position:fixed;left:10px;top:15px;width:30px;height:20px");
    try page.render();
    var fixed = try page.rects(node, 100, false);
    defer fixed.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 10), fixed.items[0].x);
    try std.testing.expectEqual(@as(f64, 15), fixed.items[0].y);
}

test "geometry retains inline lines and descendants of temporary atomic boxes" {
    var page = try Page.init("<main style='display:block;width:400px'><span>one<br>two</span><span style='display:inline-block;width:80px;height:50px'><div style='display:block;width:30px;height:20px'></div></span></main>");
    defer page.deinit();
    try page.render();
    const inline_node = &page.root.element.children.items[0];
    const atomic = &page.root.element.children.items[1];
    const nested = &atomic.element.children.items[0];
    var lines = try page.rects(inline_node, 0, false);
    defer lines.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expect(lines.items[1].y > lines.items[0].y);
    var atomic_rect = try page.rects(atomic, 0, false);
    defer atomic_rect.deinit(allocator);
    var child_rect = try page.rects(nested, 0, false);
    defer child_rect.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), atomic_rect.items.len);
    try std.testing.expectEqual(@as(usize, 1), child_rect.items.len);
    try std.testing.expectEqual(@as(f64, 80), atomic_rect.items[0].width);
    try std.testing.expectEqual(@as(f64, 30), child_rect.items[0].width);
    try std.testing.expect(child_rect.items[0].x >= atomic_rect.items[0].x);
    try std.testing.expect(child_rect.items[0].y >= atomic_rect.items[0].y);
    const display = try page.engine.paintDocument(page.document.?);
    DisplayItem.freeList(allocator, display);
    page.document.?.markPaintSubtree();
    const repainted = try page.engine.paintDocument(page.document.?);
    DisplayItem.freeList(allocator, repainted);
    try std.testing.expect(!page.document.?.layoutNeeded());
    var after_paint = try page.rects(inline_node, 0, false);
    defer after_paint.deinit(allocator);
    try std.testing.expectEqualSlices(Rect, lines.items, after_paint.items);
    // Numeric query results survive a later complete layout reconstruction.
    try setStyle(nested, "display:block;width:60px;height:20px");
    try page.render();
    var changed = try page.rects(nested, 0, false);
    defer changed.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 60), changed.items[0].width);
    try std.testing.expectEqual(@as(f64, 30), child_rect.items[0].width);
}

test "geometry subtracts nested scroll without clipping the border box" {
    var page = try Page.init("<main style='display:block;width:200px;height:60px;overflow:scroll'><div style='display:block;width:100px;height:300px'></div></main>");
    defer page.deinit();
    try page.render();
    const child = &page.root.element.children.items[0];
    try std.testing.expect(page.root.element.scroll_container);
    var before = try page.rects(child, 0, false);
    defer before.deinit(allocator);
    page.root.element.scroll_y = 40;
    var scrolled = try page.rects(child, 25, false);
    defer scrolled.deinit(allocator);
    try std.testing.expectEqual(before.items[0].y - 65, scrolled.items[0].y);
    try std.testing.expectEqual(@as(f64, 300), scrolled.items[0].height);
    var parent_rect = try page.rects(&page.root, 25, false);
    defer parent_rect.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 60), parent_rect.items[0].height);
}

test "geometry client metrics use used edges and survive atomic snapshot retirement" {
    var page = try Page.init("<main style='display:block'><span style='display:inline-block;zoom:2;width:100px;height:80px;border:3px solid;padding:5px'><div style='display:block;width:50%;height:30px;border:2px solid;padding:4px'></div></span><span>inline</span></main>");
    defer page.deinit();
    try page.render();
    const atomic = &page.root.element.children.items[0];
    const nested = &atomic.element.children.items[0];
    const outer = try page.metrics(atomic);
    try std.testing.expectEqual(Rect{ .x = 3, .y = 3, .width = 110, .height = 90 }, outer.client);
    try std.testing.expectEqual(Rect{ .x = 2, .y = 2, .width = 58, .height = 38 }, (try page.metrics(nested)).client);
    try std.testing.expectEqual(Rect{}, (try page.metrics(&page.root.element.children.items[1])).client);
    try std.testing.expectEqual(@as(f64, 790), (try page.metrics(&page.root)).client.width);
    try setStyle(atomic, "display:inline-block;zoom:2;width:100px;height:80px;border:3px solid;padding:5px;box-sizing:border-box");
    try page.render();
    try std.testing.expectEqual(@as(f64, 94), (try page.metrics(atomic)).client.width);
    try std.testing.expectEqual(@as(f64, 110), outer.client.width);
}

test "geometry offsets use padding origin and ignore transforms and scroll" {
    var page = try Page.init("<main style='display:block;position:relative;zoom:2;border:3px solid;padding:5px;height:100px;overflow:scroll;transform:translate(10px,20px)'><div style='display:block;height:30px'></div><div style='display:block;width:40px;height:50px;margin-left:7px'></div><div style='display:block;position:absolute;left:11px;top:13px;width:10px;height:20px'></div></main>");
    defer page.deinit();
    try page.render();
    const normal = &page.root.element.children.items[1];
    const absolute = &page.root.element.children.items[2];
    const normal_metrics = try page.metrics(normal);
    try std.testing.expectEqual(&page.root, normal_metrics.offset_parent.?);
    try std.testing.expectEqual(@as(f64, 12), normal_metrics.offset_x);
    try std.testing.expectEqual(@as(f64, 35), normal_metrics.offset_y);
    const absolute_metrics = try page.metrics(absolute);
    try std.testing.expectEqual(&page.root, absolute_metrics.offset_parent.?);
    try std.testing.expectEqual(@as(f64, 11), absolute_metrics.offset_x);
    try std.testing.expectEqual(@as(f64, 13), absolute_metrics.offset_y);
    try setStyle(absolute, "display:block;position:absolute;width:10px;height:20px");
    try page.render();
    try std.testing.expectEqual(@as(f64, 5), (try page.metrics(absolute)).offset_x);
    try setStyle(absolute, "display:block;position:absolute;right:10%;bottom:10%;width:10px;height:20px");
    try page.render();
    try std.testing.expectEqual(@as(f64, 79), (try page.metrics(absolute)).offset_y);
    try setStyle(absolute, "display:block;position:absolute;right:20px;bottom:15px;width:10px;height:20px;zoom:2;margin:1px");
    try page.render();
    // Parent height is 100 + 2*5 padding; the child's 2x zoom removes
    // half that span from each returned offset coordinate.
    try std.testing.expectEqual(@as(f64, 19), (try page.metrics(absolute)).offset_y);
    page.root.element.scroll_y = 40;
    const scrolled = try page.metrics(normal);
    try std.testing.expectEqual(normal_metrics.offset_parent, scrolled.offset_parent);
    try std.testing.expectEqual(normal_metrics.offset_x, scrolled.offset_x);
    try std.testing.expectEqual(normal_metrics.offset_y, scrolled.offset_y);
    try setStyle(&page.root, "display:none");
    try page.render();
    try std.testing.expectEqual(geometry.Metrics{}, try page.metrics(normal));
}
