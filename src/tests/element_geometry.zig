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

test "sticky element scrolling shares paint hit geometry and containing limits" {
    var page = try Page.init("<main style='display:block'><div style='display:block;position:relative;width:100px;height:200px;overflow:hidden;border:2px solid'><div style='display:block;height:500px'><div style='display:block;height:100px'></div><div style='display:block;height:300px'><div style='display:block;height:100px'></div><div style='display:block;position:sticky;top:50px;height:100px;background:green'></div></div></div></div></main>");
    defer page.deinit();
    try page.render();
    const scroller = &page.root.element.children.items[0];
    try std.testing.expect(!scroller.element.scrollBy(10));
    const contents = &scroller.element.children.items[0];
    const container = &contents.element.children.items[1];
    const sticky = &container.element.children.items[1];
    var port = try page.rects(scroller, 0, false);
    defer port.deinit(allocator);
    for ([_]i32{ 100, 200, 300 }, [_]f64{ 100, 50, 0 }) |scroll, expected| {
        try std.testing.expect(scroller.element.scrollTo(0, scroll));
        parser.markPaintForElement(&scroller.element);
        _ = page.document.?.updateSticky(0);
        try std.testing.expect(!page.document.?.layoutNeeded());
        var rects = try page.rects(sticky, 0, false);
        defer rects.deinit(allocator);
        try std.testing.expectEqual(port.items[0].y + 2 + expected, rects.items[0].y);
        const commands = try page.engine.paintDocument(page.document.?);
        defer DisplayItem.freeList(allocator, commands);
        const hit = DisplayItem.hitTest(commands, @intFromFloat(rects.items[0].x + 5), @intFromFloat(rects.items[0].y + 5), 1).?;
        try std.testing.expectEqual(sticky, hit.source.node.?);
    }
    try setStyle(sticky, "display:block;position:static;top:50px;height:100px;background:green");
    try page.render();
    var restored = try page.rects(sticky, 0, false);
    defer restored.deinit(allocator);
    try std.testing.expectEqual(port.items[0].y + 2 - 100, restored.items[0].y);
}

test "sticky viewport scrolling preserves normal flow and resets after resize" {
    var page = try Page.init("<main style='display:block;height:1000px'><div style='display:block;height:600px'><div style='display:block;height:150px'></div><div style='display:block;position:sticky;top:10px;height:50px'></div><div style='display:block;height:20px'></div></div></main>");
    defer page.deinit();
    try page.render();
    const container = &page.root.element.children.items[0];
    const sticky = &container.element.children.items[1];
    const after = &container.element.children.items[2];
    var original = try page.rects(after, 0, true);
    defer original.deinit(allocator);
    try std.testing.expect(page.document.?.updateSticky(200));
    var stuck = try page.rects(sticky, 200, false);
    defer stuck.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 10), stuck.items[0].y);
    var unchanged = try page.rects(after, 0, true);
    defer unchanged.deinit(allocator);
    try std.testing.expectEqualSlices(Rect, original.items, unchanged.items);
    try std.testing.expect(!page.document.?.layoutNeeded());
    try std.testing.expect(page.document.?.updateSticky(0));
    var restored = try page.rects(sticky, 0, false);
    defer restored.deinit(allocator);
    try std.testing.expectEqual(original.items[0].y - 50, restored.items[0].y);
}

test "sticky horizontal block uses its nearest scrollport and zoomed inset" {
    var page = try Page.init("<main style='display:block'><div style='display:block;overflow:auto;width:200px;height:100px;zoom:2'><div style='display:block;width:500px;height:100px'><div style='display:block;position:sticky;left:10%;margin-left:150px;width:50px;height:50px;background:green'></div></div></div></main>");
    defer page.deinit();
    try page.render();
    const port = &page.root.element.children.items[0];
    const sticky = &port.element.children.items[0].element.children.items[0];
    try std.testing.expectEqual(@as(i32, 600), port.element.maxScrollX());
    try std.testing.expect(port.element.scrollTo(400, 0));
    _ = page.document.?.updateSticky(0);
    var outer = try page.rects(port, 0, false);
    defer outer.deinit(allocator);
    var rects = try page.rects(sticky, 0, false);
    defer rects.deinit(allocator);
    try std.testing.expectEqual(outer.items[0].x + 40, rects.items[0].x);
}

fn editorClip(items: []const DisplayItem, node: *parser.Node) ?Rect {
    for (items) |item| switch (item) {
        .blend => |group| {
            if (group.hit_clip) |clip| if (group.source) |source| {
                if (source.node == node and group.needs_compositing) return geometry.box(clip.x1, clip.y1, clip.x2 - clip.x1, clip.y2 - clip.y1);
            };
            if (editorClip(group.children, node)) |clip| return clip;
        },
        .transform => |group| if (editorClip(group.children, node)) |clip| return clip.translated(@floatFromInt(group.translate_x), @floatFromInt(group.translate_y)),
        .cached_subtree => |cached| if (editorClip(cached.list.items, node)) |clip| return clip,
        else => {},
    };
    return null;
}

test "geometry native editor clipping uses the same insets as CSSOM" {
    var page = try Page.init("<main style='display:block'><input value='text overflowing a narrow field' style='width:25px;height:20px;padding:4px;border:3px solid'><textarea style='display:block;width:60px;height:30px;padding:5px;border:2px solid'>one\ntwo\nthree</textarea></main>");
    defer page.deinit();
    try page.render();
    for (page.root.element.children.items) |*node| {
        var rects = try page.rects(node, 0, false);
        defer rects.deinit(allocator);
        const expected = (try page.metrics(node)).client.translated(rects.items[0].x, rects.items[0].y);
        const commands = try page.engine.paintDocument(page.document.?);
        defer DisplayItem.freeList(allocator, commands);
        try std.testing.expectEqual(expected, editorClip(commands, node).?);
    }
    const input = &page.root.element.children.items[0];
    try setStyle(input, "width:0;height:0;padding:0;border:0");
    try page.render();
    var zero = try page.rects(input, 0, false);
    defer zero.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), zero.items.len);
    try std.testing.expectEqual(@as(f64, 0), zero.items[0].width);
    try std.testing.expectEqual(@as(f64, 0), zero.items[0].height);
    try std.testing.expectEqual(Rect{}, (try page.metrics(input)).client);
}

test "geometry an anonymous run beginning with a control keeps the containing width" {
    var page = try Page.init("<main style='display:block;width:600px'><div style='display:block;height:10px'></div><input style='width:250px;height:30px'><input style='width:250px;height:30px'></main>");
    defer page.deinit();
    try page.render();
    var first = try page.rects(&page.root.element.children.items[1], 0, false);
    defer first.deinit(allocator);
    var second = try page.rects(&page.root.element.children.items[2], 0, false);
    defer second.deinit(allocator);
    try std.testing.expectEqual(first.items[0].y, second.items[0].y);
    try std.testing.expectEqual(first.items[0].x + 250, second.items[0].x);
}

test "geometry empty inline anchors preserve phantom lines and collapsed whitespace" {
    var page = try Page.init("<main style='display:block;position:relative'><div style='display:block'><span><i></i> </span></div><div style='display:block'><br><span> </span><span>ref</span><span> </span></div></main>");
    defer page.deinit();
    try page.render();
    const phantom = &page.root.element.children.items[0];
    const empty = &phantom.element.children.items[0];
    var phantom_rects = try page.rects(phantom, 0, false);
    defer phantom_rects.deinit(allocator);
    var empty_rects = try page.rects(empty, 0, false);
    defer empty_rects.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), empty_rects.items.len);
    try std.testing.expectEqual(@as(f64, 0), phantom_rects.items[0].height);
    try std.testing.expectEqual(Rect{ .x = phantom_rects.items[0].x, .y = phantom_rects.items[0].y }, empty_rects.items[0]);
    const line = &page.root.element.children.items[1];
    var before = try page.rects(&line.element.children.items[1], 0, false);
    defer before.deinit(allocator);
    var reference = try page.rects(&line.element.children.items[2], 0, false);
    defer reference.deinit(allocator);
    var after = try page.rects(&line.element.children.items[3], 0, false);
    defer after.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), before.items.len);
    try std.testing.expectEqual(reference.items[0].x, before.items[0].x);
    try std.testing.expectEqual(reference.items[0].y, before.items[0].y);
    try std.testing.expect(reference.items[0].y > phantom_rects.items[0].y);
    try std.testing.expectEqual(reference.items[0].height, before.items[0].height);
    try std.testing.expectEqual(reference.items[0].x + reference.items[0].width, after.items[0].x);
    try std.testing.expectEqual(reference.items[0].y, after.items[0].y);
    try std.testing.expectEqual(@as(f64, 0), after.items[0].width);
    const display = try page.engine.paintDocument(page.document.?);
    DisplayItem.freeList(allocator, display);
    page.document.?.markPaintSubtree();
    const repainted = try page.engine.paintDocument(page.document.?);
    DisplayItem.freeList(allocator, repainted);
    try std.testing.expect(!page.document.?.layoutNeeded());
    var retained = try page.rects(empty, 0, false);
    defer retained.deinit(allocator);
    try std.testing.expectEqualSlices(Rect, empty_rects.items, retained.items);
}

test "geometry native editors share used boxes across inline block and atomic snapshots" {
    for ([_][]const u8{ "input", "textarea" }) |tag| {
        for ([_][]const u8{ "inline", "block" }) |display| {
            const source = try std.fmt.allocPrint(allocator, "<main style='display:block'><div style='display:inline-block;zoom:2;width:500px'><{s} style='display:{s};width:300px;height:200px;border:solid;border-width:10px 20px;padding:2px;box-sizing:content-box'></{s}></div></main>", .{ tag, display, tag });
            defer allocator.free(source);
            var page = try Page.init(source);
            defer page.deinit();
            try page.render();
            const node = &page.root.element.children.items[0].element.children.items[0];
            const single_line = std.mem.eql(u8, tag, "input");
            try std.testing.expectEqual(Rect{ .x = if (single_line) 22 else 20, .y = 10, .width = if (single_line) 300 else 304, .height = 204 }, (try page.metrics(node)).client);
            var rects = try page.rects(node, 0, false);
            defer rects.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 1), rects.items.len);
            try std.testing.expectEqual(@as(f64, 688), rects.items[0].width);
            try std.testing.expectEqual(@as(f64, 448), rects.items[0].height);
            const style = try std.fmt.allocPrint(allocator, "display:{s};width:120px;height:30px;padding:4px;border:2px solid;box-sizing:border-box", .{display});
            defer allocator.free(style);
            try setStyle(node, style);
            try page.render();
            try std.testing.expectEqual(Rect{ .x = if (single_line) 6 else 2, .y = 2, .width = if (single_line) 108 else 116, .height = 26 }, (try page.metrics(node)).client);
        }
    }
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
