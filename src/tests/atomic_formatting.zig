//! Atomic flex/grid layout, wrapping and temporary snapshot lifetime regressions.
//! Each fixture owns its DOM, environment and layout until deterministic teardown.
const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const parser = @import("../document/parser.zig");
const geometry = @import("../browser/render/element_geometry.zig");
const DisplayItem = @import("../browser/render/display_list.zig").DisplayItem;
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
        self.environ.deinit();
        self.root.deinit(allocator);
    }

    fn render(self: *Page) !void {
        parser.fixParentPointers(&self.root, null);
        try parser.style(allocator, &self.root, &.{});
        if (self.engine == null) self.engine = try Layout.init(allocator, std.testing.io, &self.environ, 800, 600, false);
        if (self.document) |document| try document.layout(self.engine.?) else self.document = try self.engine.?.buildDocument(&self.root);
    }

    fn node(self: *Page, id: []const u8) *parser.Node {
        return find(&self.root, id).?;
    }

    fn box(self: *Page, id: []const u8) !geometry.Rect {
        var rects = std.ArrayList(geometry.Rect).empty;
        defer rects.deinit(allocator);
        try geometry.collect(self.document.?, self.node(id), 1, 0, false, allocator, &rects);
        try std.testing.expectEqual(@as(usize, 1), rects.items.len);
        return rects.items[0];
    }

    fn size(self: *Page, id: []const u8, width: f64, height: f64) !void {
        const rect = try self.box(id);
        try std.testing.expectEqual(width, rect.width);
        try std.testing.expectEqual(height, rect.height);
    }

    fn offset(self: *Page, id: []const u8, parent: []const u8, x: f64, y: f64) !void {
        const rect = try self.box(id);
        const containing = try self.box(parent);
        try std.testing.expectEqual(x, rect.x - containing.x);
        try std.testing.expectEqual(y, rect.y - containing.y);
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

test "shared atomic flex resolves image percentages from a definite cross size" {
    for ([_][]const u8{ "50px", "100%" }) |image_height| {
        const source = try std.fmt.allocPrint(allocator, "<main id='line' style='display:block;width:300px;font-size:0;line-height:0'><span id='flex' style='display:inline-flex;height:50px'><img id='image' style='display:block;height:{s}'></span></main>", .{image_height});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        const pixels = try @import("zigimg").Image.create(allocator, 1, 1, .rgba32);
        @memset(pixels.pixels.rgba32, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
        page.node("image").element.image_data = .{ .encoded_bytes = null, .image = pixels };
        try page.render();
        try page.size("flex", 50, 50);
        try page.size("image", 50, 50);
        const owner = page.node("line").element.layout_ptr;
        page.set("flex", "height", "100px");
        try page.reflow();
        const expected: f64 = if (std.mem.eql(u8, image_height, "100%")) 100 else 50;
        try page.size("flex", expected, 100);
        try page.size("image", expected, expected);
        try std.testing.expectEqual(owner, page.node("line").element.layout_ptr);
        try std.testing.expect(page.node("flex").element.layout_ptr == null);
        try std.testing.expect(page.node("image").element.layout_ptr == null);
    }
}

test "shared atomic flex percentage ratio respects cross edges zoom and definite zero" {
    var page = try Page.init("<main id='line' style='display:block;width:400px;font-size:0;line-height:0'><span id='flex' style='display:inline-flex;box-sizing:border-box;height:70px;padding:5px;border:5px solid;zoom:2'><img id='image' style='display:block;height:100%'></span></main>");
    defer page.deinit();
    const pixels = try @import("zigimg").Image.create(allocator, 1, 1, .rgba32);
    @memset(pixels.pixels.rgba32, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
    page.node("image").element.image_data = .{ .encoded_bytes = null, .image = pixels };
    try page.render();
    try page.size("flex", 140, 140);
    try page.size("image", 100, 100);
    page.set("flex", "min-height", "90px");
    try page.reflow();
    try page.size("flex", 180, 180);
    try page.size("image", 140, 140);
    page.set("flex", "min-height", "auto");
    page.set("flex", "max-height", "60px");
    try page.reflow();
    try page.size("flex", 120, 120);
    try page.size("image", 80, 80);
    page.set("flex", "height", "20px");
    try page.reflow();
    try page.size("flex", 40, 40);
    try page.size("image", 0, 0);
    const commands = try page.engine.?.paintDocument(page.document.?);
    defer DisplayItem.freeList(allocator, commands);
    try std.testing.expect(!page.document.?.layoutNeeded());
}

test "shared atomic flex and grid keep intrinsic children in one inline box" {
    var page = try Page.init("<main id='line' style='display:block;width:400px;font-size:0;line-height:0'><span id='flex' style='display:inline-flex;gap:10px;align-items:start'><span id='a' style='width:40px;height:10px;flex:none'></span><span id='b' style='width:60px;height:20px;flex:none'></span></span><span id='grid' style='display:inline-grid;grid-template-columns:max-content max-content;gap:10px;align-items:start'><span id='c' style='width:40px;height:10px'></span><span id='d' style='width:60px;height:20px'></span></span></main>");
    defer page.deinit();
    try page.render();
    try page.size("flex", 110, 20);
    try page.size("grid", 110, 20);
    try page.offset("grid", "flex", 110, 0);
    try page.offset("b", "flex", 50, 0);
    try page.offset("d", "grid", 50, 0);
    const owner = page.node("line").element.layout_ptr;
    page.set("flex", "column-gap", "20px");
    try page.reflow();
    try page.size("flex", 120, 20);
    try page.offset("grid", "flex", 120, 0);
    page.set("a", "width", "80px");
    try page.reflow();
    try page.size("flex", 160, 20);
    page.set("grid", "grid-template-columns", "80px 90px");
    try page.reflow();
    try page.size("grid", 180, 20);
    try page.offset("d", "grid", 90, 0);
    page.set("flex", "flex-direction", "column");
    try page.reflow();
    try page.size("flex", 80, 40);
    try page.size("line", 400, 40);
    try std.testing.expectEqual(owner, page.node("line").element.layout_ptr);
    try std.testing.expect(page.node("flex").element.layout_ptr == null);
    try std.testing.expect(page.node("a").element.layout_ptr == null);
}

test "shared atomic outer nowrap is independent from the child's internal white space" {
    for ([_][]const u8{ "inline-block", "inline-flex", "inline-grid" }) |display| {
        const source = try std.fmt.allocPrint(allocator, "<main id='line' style='display:block;width:100px;font-size:0;line-height:0;white-space:normal'><span id='a' style='display:{s};width:60px;height:20px;white-space:normal'></span><span id='b' style='display:{s};width:60px;height:20px;white-space:normal'></span></main>", .{ display, display });
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.size("line", 100, 40);
        try page.offset("b", "a", 0, 20);
        try page.node("line").element.attributes.?.put("style", "display:block;width:100px;font-size:0;line-height:0;white-space:nowrap");
        @import("../document/dom.zig").dirtyStyleForElement(&page.node("line").element);
        try page.render();
        try page.size("line", 100, 20);
        try page.offset("b", "a", 60, 0);
        try page.node("line").element.attributes.?.put("style", "display:block;width:100px;font-size:0;line-height:0;white-space:normal");
        @import("../document/dom.zig").dirtyStyleForElement(&page.node("line").element);
        try page.render();
        try page.size("line", 100, 40);
    }
}

test "shared atomic nested snapshots preserve controls hits and clean geometry after paint" {
    var page = try Page.init("<main id='line' style='display:block;width:400px;font-size:0;line-height:0'><span id='outer' style='display:inline-grid;grid-template-columns:max-content max-content;gap:10px'><span id='inner' style='display:inline-flex;gap:0'><a id='link' href='#target' style='display:block;width:40px;height:20px;flex:none;background:green'></a><input id='input' style='width:40px;height:20px;padding:0;border:0;flex:none'></span><span id='tail' style='width:30px;height:20px;background:blue'></span></span></main>");
    defer page.deinit();
    try page.render();
    try page.size("outer", 120, 20);
    const owner = page.node("line").element.layout_ptr;
    for (0..4) |pass| {
        if (pass > 0) {
            page.set("inner", "column-gap", if (pass % 2 == 1) "10px" else "0px");
            try page.reflow();
        }
        const before = try page.box("input");
        const bounds = page.engine.?.input_bounds.get(page.node("input")).?;
        try std.testing.expectEqual(before.x, @as(f64, @floatFromInt(bounds.x)));
        try std.testing.expectEqual(before.y, @as(f64, @floatFromInt(bounds.y)));
        try std.testing.expectEqual(@as(usize, 1), page.engine.?.input_bounds.count());
        const commands = try page.engine.?.paintDocument(page.document.?);
        const hit = DisplayItem.hitTest(commands, @intFromFloat(before.x + 5), @intFromFloat(before.y + 5), 1).?;
        try std.testing.expectEqual(page.node("input"), hit.source.originatingNode());
        DisplayItem.freeList(allocator, commands);
        page.document.?.markPaintSubtree();
        const repainted = try page.engine.?.paintDocument(page.document.?);
        DisplayItem.freeList(allocator, repainted);
        try std.testing.expect(!page.document.?.layoutNeeded());
        try std.testing.expectEqual(before, try page.box("input"));
        try std.testing.expectEqual(owner, page.node("line").element.layout_ptr);
    }
}

test "shared atomic floated and blockified inline containers retain their inner formatting" {
    var page = try Page.init("<main style='display:block;width:300px;font-size:0;line-height:0'><span id='float' style='display:inline-flex;float:left;gap:10px'><span style='width:40px;height:10px;flex:none'></span><span style='width:60px;height:20px;flex:none'></span></span><div style='display:flex;width:300px;clear:both'><span id='item' style='display:inline-grid;grid-template-columns:max-content max-content;gap:10px;flex:none'><span style='width:40px;height:10px'></span><span style='width:60px;height:20px'></span></span></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("float", 110, 20);
    try page.size("item", 110, 20);
}

test "shared atomic first baseline preserves the below baseline extent of its line" {
    for ([_][]const u8{ "inline-flex", "inline-grid" }) |display| {
        const source = try std.fmt.allocPrint(allocator, "<main style='display:block;font-size:0;line-height:0'><div id='line' style='display:block;width:200px'><span style='display:inline-block;width:10px;height:10px'></span><span id='tall' style='display:{s};flex-direction:column;grid-template-columns:20px'><span style='width:20px;height:20px'></span><span style='width:20px;height:40px'></span></span></div><div id='after' style='display:block;height:10px'></div></main>", .{display});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.size("line", 200, 60);
        try page.offset("after", "line", 0, 60);
        const before = try page.box("after");
        page.document.?.markPaintSubtree();
        const commands = try page.engine.?.paintDocument(page.document.?);
        DisplayItem.freeList(allocator, commands);
        try std.testing.expect(!page.document.?.layoutNeeded());
        try std.testing.expectEqual(before, try page.box("after"));
    }
}
