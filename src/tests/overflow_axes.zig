//! Retained physical-axis overflow, scalar metrics and formatting-context regressions.
const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const parser = @import("../document/parser.zig");
const geometry = @import("../browser/render/element_geometry.zig");
const allocator = std.testing.allocator;

const Page = struct {
    root: parser.Node,
    environ: std.process.Environ.Map,
    engine: ?*Layout = null,
    document: ?*Layout.DocumentLayout = null,

    fn init(source: []const u8) !Page {
        var html = try parser.HTMLParser.init(allocator, source);
        defer html.deinit(allocator);
        html.use_implicit_tags = false;
        var root = try html.parse();
        errdefer root.deinit(allocator);
        var environ = std.process.Environ.Map.init(allocator);
        errdefer environ.deinit();
        try environ.put("HOME", "/tmp");
        return .{ .root = root, .environ = environ };
    }

    fn deinit(self: *Page) void {
        if (self.document) |document| {
            document.deinit();
            allocator.destroy(document);
        }
        if (self.engine) |engine| engine.deinit();
        self.root.deinit(allocator);
        self.environ.deinit();
    }

    fn render(self: *Page) !void {
        parser.fixParentPointers(&self.root, null);
        try parser.style(allocator, &self.root, &.{});
        if (self.engine == null) self.engine = try Layout.init(allocator, std.testing.io, &self.environ, 800, 600, false);
        self.document = try self.engine.?.buildDocument(&self.root);
    }

    fn node(self: *Page, id: []const u8) *parser.Node {
        return find(&self.root, id).?;
    }

    fn size(self: *Page, id: []const u8, width: f64, height: f64) !void {
        const rect = try self.box(id);
        try std.testing.expectEqual(width, rect.width);
        try std.testing.expectEqual(height, rect.height);
    }

    fn box(self: *Page, id: []const u8) !geometry.Rect {
        var rects = std.ArrayList(geometry.Rect).empty;
        defer rects.deinit(allocator);
        try geometry.collect(self.document.?, self.node(id), 1, 0, false, allocator, &rects);
        try std.testing.expectEqual(@as(usize, 1), rects.items.len);
        return rects.items[0];
    }

    fn set(self: *Page, id: []const u8, property: []const u8, value: []const u8) void {
        self.node(id).element.style.?.getPtr(property).?.set(value);
    }

    fn reflow(self: *Page) !void {
        try std.testing.expect(self.document.?.layoutNeeded());
        try self.document.?.layout(self.engine.?);
        try std.testing.expect(!self.document.?.layoutNeeded());
    }
};

fn find(node: *parser.Node, id: []const u8) ?*parser.Node {
    if (node.* != .element) return null;
    if (node.element.attributes) |attributes| if (attributes.get("id")) |value| {
        if (std.mem.eql(u8, value, id)) return node;
    };
    for (node.element.children.items) |*child| if (find(child, id)) |found| return found;
    return null;
}

test "overflow axes retain dimensions while independently clamping offsets" {
    var page = try Page.init("<main style='display:block'><div id='box' style='display:block;width:80px;height:60px;overflow:clip auto'><div id='content' style='display:block;width:160px;height:120px'></div></div></main>");
    defer page.deinit();
    try page.render();
    const box = &page.node("box").element;
    const owner = box.layout_ptr;
    try std.testing.expectEqual(@as(i32, 160), box.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 120), box.scroll_content_height);
    try std.testing.expect(box.scrollTo(40, 50));
    try std.testing.expectEqual(@as(i32, 0), box.scroll_x);
    try std.testing.expectEqual(@as(i32, 50), box.scroll_y);
    page.set("box", "overflow-x", "hidden");
    try page.reflow();
    try std.testing.expectEqual(@as(i32, 50), box.scroll_y);
    try std.testing.expect(box.scrollTo(40, 50));
    page.set("box", "overflow-y", "clip");
    try page.reflow();
    try std.testing.expectEqual(@as(i32, 40), box.scroll_x);
    try std.testing.expectEqual(@as(i32, 0), box.scroll_y);
    page.set("content", "width", "100px");
    try page.reflow();
    try std.testing.expectEqual(@as(i32, 20), box.scroll_x);
    try std.testing.expectEqual(@as(i32, 100), box.scroll_content_width);
    try std.testing.expectEqual(owner, box.layout_ptr);
}

test "overflow axes propagate nested descendants only through visible axes" {
    var page = try Page.init("<main id='outer' style='display:block;width:100px;height:80px;overflow:auto'><div id='inner' style='display:block;width:40px;height:30px;overflow:clip visible'><div style='display:block;width:200px;height:150px'></div></div></main>");
    defer page.deinit();
    try page.render();
    const outer = &page.node("outer").element;
    const inner = &page.node("inner").element;
    try std.testing.expectEqual(@as(i32, 100), outer.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 150), outer.scroll_content_height);
    try std.testing.expectEqual(@as(i32, 200), inner.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 150), inner.scroll_content_height);
    page.set("inner", "overflow-x", "visible");
    page.set("inner", "overflow-y", "clip");
    try page.reflow();
    try std.testing.expectEqual(@as(i32, 200), outer.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 80), outer.scroll_content_height);
}

test "overflow axes atomic snapshots keep CSSOM descendants separate from propagated extents" {
    var page = try Page.init("<main id='outer' style='display:block;width:100px;height:80px;overflow:auto;font-size:0;line-height:0'><span id='inner' style='display:inline-flex;vertical-align:bottom;width:40px;height:30px;overflow:clip visible'><span id='content' style='display:block;width:200px;height:150px;flex:none'></span></span></main>");
    defer page.deinit();
    try page.render();
    const outer = &page.node("outer").element;
    try std.testing.expectEqual(@as(i32, 100), outer.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 150), outer.scroll_content_height);
    try page.size("content", 200, 150);
    try std.testing.expect(page.node("inner").element.layout_ptr == null);
    page.set("inner", "overflow-x", "visible");
    page.set("inner", "overflow-y", "clip");
    try page.reflow();
    try std.testing.expectEqual(@as(i32, 200), outer.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 80), outer.scroll_content_height);
    try page.size("content", 200, 150);
}

test "overflow axes clip leaves floats in the ancestor formatting context" {
    var page = try Page.init("<main style='display:block;width:100px'><section id='box' style='display:block;width:100px;overflow:clip'><div style='display:block;float:left;width:50px;height:50px'></div></section></main>");
    defer page.deinit();
    try page.render();
    try page.size("box", 100, 0);
    const owner = page.node("box").element.layout_ptr;
    page.set("box", "overflow-y", "hidden");
    try page.reflow();
    try page.size("box", 100, 50);
    page.set("box", "overflow-y", "clip");
    try page.reflow();
    try page.size("box", 100, 0);
    try std.testing.expectEqual(owner, page.node("box").element.layout_ptr);
}

test "overflow axes flex and grid automatic minima use the sizing axis" {
    var page = try Page.init("<main style='display:block'><div style='display:flex;width:50px'><div id='row' style='overflow:hidden clip'><div style='display:block;width:100px;height:80px'></div></div></div><div style='display:flex;flex-direction:column;width:100px;height:50px'><div id='column' style='overflow:clip hidden'><div style='display:block;width:100px;height:80px'></div></div></div><div style='display:grid;width:0px;height:0px;grid-template-columns:auto;grid-template-rows:auto'><div id='grid' style='overflow:hidden clip'><div style='display:block;width:100px;height:80px'></div></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("row", 50, 80);
    try page.size("column", 100, 50);
    try page.size("grid", 0, 80);
    page.set("row", "overflow-x", "clip");
    page.set("column", "overflow-y", "clip");
    page.set("grid", "overflow-x", "clip");
    page.set("grid", "overflow-y", "hidden");
    try page.reflow();
    try page.size("row", 100, 80);
    try page.size("column", 100, 80);
    try page.size("grid", 100, 0);
}

test "overflow axes include padding and exclude borders under authored zoom" {
    var page = try Page.init("<main style='display:block'><div id='box' style='display:block;width:80px;height:60px;padding:10px;border:2px solid;zoom:2;overflow:hidden clip'><div style='display:block;width:160px;height:120px'></div></div></main>");
    defer page.deinit();
    try page.render();
    const box = &page.node("box").element;
    try std.testing.expectEqual(@as(i32, 200), box.scroll_client_width);
    try std.testing.expectEqual(@as(i32, 160), box.scroll_client_height);
    try std.testing.expectEqual(@as(i32, 360), box.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 280), box.scroll_content_height);
    try std.testing.expect(box.scrollTo(500, 500));
    try std.testing.expectEqual(@as(i32, 160), box.scroll_x);
    try std.testing.expectEqual(@as(i32, 0), box.scroll_y);
}

test "overflow axes document extent includes translated positioned descendants and excludes fixed ones" {
    var page = try Page.init("<main style='display:block;width:50px;height:40px'><div id='far' style='display:block;position:absolute;left:1000px;top:900px;width:100px;height:100px;transform:translate(20px,30px)'></div><div style='display:block;position:fixed;left:4000px;top:4000px;width:100px;height:100px'></div></main>");
    defer page.deinit();
    try page.render();
    const box = try page.box("far");
    try std.testing.expectEqual(@as(i32, @intFromFloat(box.x + box.width)) + page.document.?.x.get().*, page.document.?.content_width);
    try std.testing.expectEqual(@as(i32, @intFromFloat(box.y + box.height)) + page.document.?.y.get().*, page.document.?.content_height);
    try std.testing.expectEqual(@as(i32, 790), page.document.?.scrollport_width);
    try std.testing.expectEqual(@as(i32, 600), page.document.?.scrollport_height);
    const old_width = page.document.?.content_width;
    const old_height = page.document.?.content_height;
    page.set("far", "transform", "translate(50px,60px)");
    try page.reflow();
    try std.testing.expectEqual(old_width + 30, page.document.?.content_width);
    try std.testing.expectEqual(old_height + 30, page.document.?.content_height);
}

test "overflow axes root donation selects first body before display eligibility" {
    var page = try Page.init("<html style='display:block'><body id='first' style='display:none;overflow:hidden'></body><body id='second' style='display:block;width:100px;height:60px;overflow:clip'><div style='display:block;width:200px;height:120px'></div></body></html>");
    defer page.deinit();
    try page.render();
    const overflow = @import("../document/css_overflow.zig");
    try std.testing.expectEqual(overflow.Pair{ .x = .auto, .y = .auto }, Layout.rootViewportOverflow(&page.root));
    try std.testing.expectEqual(overflow.Pair{ .x = .clip, .y = .clip }, page.node("second").element.used_overflow.?);
    page.set("first", "display", "block");
    try page.reflow();
    try std.testing.expectEqual(overflow.Pair{ .x = .hidden, .y = .hidden }, Layout.rootViewportOverflow(&page.root));
    try std.testing.expectEqual(overflow.Pair{}, page.node("first").element.used_overflow.?);
    try std.testing.expectEqualStrings("hidden", page.node("first").element.style.?.get("overflow-x").?.get().*);
    try std.testing.expectEqual(@as(i32, 800), page.document.?.scrollport_width);
}

test "overflow axes structural and painted hits preserve the visible axis and own border" {
    const DisplayItem = @import("../browser/render/display_list.zig").DisplayItem;
    var page = try Page.init("<main style='display:block'><div id='box' style='display:block;width:80px;height:60px;border:4px solid black;overflow:clip visible'><a id='content' style='display:block;width:160px;height:120px;background:green'></a></div></main>");
    defer page.deinit();
    try page.render();
    for (0..2) |pass| {
        if (pass == 1) {
            page.set("box", "overflow-x", "visible");
            page.set("box", "overflow-y", "clip");
            try page.reflow();
        }
        const rect = try page.box("box");
        const x: i32 = @intFromFloat(rect.x);
        const y: i32 = @intFromFloat(rect.y);
        const visible_x = x + if (pass == 0) @as(i32, 20) else 120;
        const visible_y = y + if (pass == 0) @as(i32, 90) else 20;
        const clipped_x = x + if (pass == 0) @as(i32, 120) else 20;
        const clipped_y = y + if (pass == 0) @as(i32, 20) else 90;
        try std.testing.expectEqual(page.node("content"), page.document.?.hitTest(visible_x, visible_y).?.node);
        if (page.document.?.hitTest(clipped_x, clipped_y)) |hit| try std.testing.expect(hit.node != page.node("content"));
        try std.testing.expectEqual(page.node("box"), page.document.?.hitTest(x + 1, y + 1).?.node);
        const commands = try page.engine.?.paintDocument(page.document.?);
        defer DisplayItem.freeList(allocator, commands);
        try std.testing.expectEqual(page.node("content"), DisplayItem.hitTest(commands, visible_x, visible_y, 1).?.source.originatingNode());
        if (DisplayItem.hitTest(commands, clipped_x, clipped_y, 1)) |hit| try std.testing.expect(hit.source.originatingNode() != page.node("content"));
        try std.testing.expectEqual(page.node("box"), DisplayItem.hitTest(commands, x + 1, y + 1, 1).?.source.originatingNode());
    }
}

test "overflow axes include a transformed document root and retained transform edits" {
    var page = try Page.init("<main id='root' style='display:block;width:50px;height:40px;transform:translate(1000px,900px)'></main>");
    defer page.deinit();
    try page.render();
    try std.testing.expectEqual(@as(i32, 1076), page.document.?.content_width);
    try std.testing.expectEqual(@as(i32, 976), page.document.?.content_height);
    const owner = page.node("root").element.layout_ptr;
    page.set("root", "transform", "translate(1200px,1000px)");
    try page.reflow();
    try std.testing.expectEqual(@as(i32, 1276), page.document.?.content_width);
    try std.testing.expectEqual(@as(i32, 1076), page.document.?.content_height);
    try std.testing.expectEqual(owner, page.node("root").element.layout_ptr);
}

test "overflow axes atomic transforms extend but never shrink their scrollable area" {
    var page = try Page.init("<main id='outer' style='display:block;width:100px;height:80px;font-size:0;line-height:0;overflow:auto'><span id='inner' style='display:inline-block;vertical-align:bottom;width:200px;height:120px;transform:translate(50px,60px)'></span></main>");
    defer page.deinit();
    try page.render();
    const outer = &page.node("outer").element;
    try std.testing.expectEqual(@as(i32, 250), outer.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 180), outer.scroll_content_height);
    page.set("inner", "transform", "translate(-150px,-80px)");
    try page.reflow();
    try std.testing.expectEqual(@as(i32, 200), outer.scroll_content_width);
    try std.testing.expectEqual(@as(i32, 120), outer.scroll_content_height);
}

test "overflow axes preliminary flex and grid measurements preserve retained offsets" {
    for ([_][]const u8{ "flex", "grid" }) |display| {
        const source = try std.fmt.allocPrint(allocator, "<main id='container' style='display:{s};flex-direction:column;grid-template-columns:auto;grid-template-rows:minmax(0,1fr);width:100px;height:50px'><div id='scroller' style='overflow:auto'><div style='display:block;width:200px;height:150px'></div></div></main>", .{display});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        const scroller = &page.node("scroller").element;
        const owner = scroller.layout_ptr;
        try page.size("scroller", 100, 50);
        try std.testing.expect(scroller.scrollTo(40, 60));
        page.set("container", "width", "110px");
        try page.reflow();
        try page.size("scroller", 110, 50);
        try std.testing.expectEqual(@as(i32, 40), scroller.scroll_x);
        try std.testing.expectEqual(@as(i32, 60), scroller.scroll_y);
        try std.testing.expectEqual(owner, scroller.layout_ptr);
    }
}
