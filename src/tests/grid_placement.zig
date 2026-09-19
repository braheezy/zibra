//! Numeric grid placement through retained layout and atomic geometry snapshots.
//! Fixtures own their DOM, environment and layout through allocator-checked teardown.
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
        self.engine = try Layout.init(allocator, std.testing.io, &self.environ, 800, 600, false);
        self.document = try self.engine.?.buildDocument(&self.root);
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

    fn setStyle(self: *Page, id: []const u8, value: []const u8) !void {
        const element = &self.node(id).element;
        try element.putOwnedAttribute(allocator, "style", value);
        parser.dirtyStyleForElement(element);
    }

    fn reflow(self: *Page) !void {
        try parser.style(allocator, &self.root, &.{});
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

test "grid placement positive and negative lines resolve against explicit edges" {
    var page = try Page.init("<main id='grid' style='display:grid;width:140px;grid-template-columns:30px 40px 50px;grid-template-rows:20px 30px;gap:10px'><div id='positive' style='grid-column:2 / 4;grid-row:2 / 3'></div><div id='negative' style='grid-column:-4 / -2;grid-row:-3 / -2'></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("positive", 100, 30);
    try page.offset("positive", "grid", 40, 30);
    try page.size("negative", 80, 20);
    try page.offset("negative", "grid", 0, 0);
    try page.size("grid", 140, 60);
}

test "grid placement normalizes reversed equal and competing span ends" {
    var page = try Page.init("<main id='grid' style='display:grid;width:90px;grid-template-columns:20px 30px 40px;grid-template-rows:repeat(5,10px)'><div id='reversed' style='grid-column:3 / 1;grid-row:1'></div><div id='equal' style='grid-column:2 / 2;grid-row:2'></div><div id='both' style='grid-column:span 2 / span 3;grid-row:3'></div><div id='end-only' style='grid-column:auto / span 2;grid-row:4'></div><div id='end-line' style='grid-column:span 2 / 4;grid-row:5'></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("reversed", 50, 10);
    try page.offset("reversed", "grid", 0, 0);
    try page.size("equal", 30, 10);
    try page.offset("equal", "grid", 20, 10);
    try page.size("both", 50, 10);
    try page.offset("both", "grid", 0, 20);
    try page.size("end-only", 50, 10);
    try page.offset("end-only", "grid", 0, 30);
    try page.size("end-line", 70, 10);
    try page.offset("end-line", "grid", 20, 40);
}

test "grid placement prepends implicit tracks without shifting explicit line identity" {
    var page = try Page.init("<main id='grid' style='display:grid;width:120px;grid-template-columns:40px 50px;grid-template-rows:20px;grid-auto-columns:10px;grid-auto-rows:15px'><div id='before' style='grid-column:-4 / -3;grid-row:-3 / -2'></div><div id='anchor' style='grid-column:1;grid-row:1'></div><div id='after' style='grid-column:4;grid-row:3'></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("before", 10, 15);
    try page.offset("before", "grid", 0, 0);
    try page.size("anchor", 40, 20);
    try page.offset("anchor", "grid", 10, 15);
    try page.size("after", 10, 15);
    try page.offset("after", "grid", 110, 50);
    try page.size("grid", 120, 65);
}

test "grid placement sparse and dense cursors differ on both flow axes after mutation" {
    for ([_]bool{ false, true }) |column| {
        const initial_flow = if (column) "column" else "row";
        const source = try std.fmt.allocPrint(allocator, "<main id='grid' style='display:grid;width:140px;grid-template-columns:repeat(3,40px);grid-template-rows:repeat(3,20px);gap:10px;grid-auto-flow:{s}'><div id='anchor' style='grid-column:{s};grid-row:{s}'></div><div id='span' style='{s}:span 2'></div><div id='tail'></div></main>", .{ initial_flow, if (column) "1" else "2", if (column) "2" else "1", if (column) "grid-row" else "grid-column" });
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.offset("span", "grid", if (column) 50 else 0, if (column) 0 else 30);
        try page.size("span", if (column) 40 else 90, if (column) 50 else 20);
        try page.offset("tail", "grid", if (column) 50 else 100, if (column) 60 else 30);
        const owner = page.node("tail").element.layout_ptr;
        try std.testing.expect(owner != null);
        try page.setStyle("grid", if (column)
            "display:grid;width:140px;grid-template-columns:repeat(3,40px);grid-template-rows:repeat(3,20px);gap:10px;grid-auto-flow:column dense"
        else
            "display:grid;width:140px;grid-template-columns:repeat(3,40px);grid-template-rows:repeat(3,20px);gap:10px;grid-auto-flow:row dense");
        try page.reflow();
        try page.offset("tail", "grid", 0, 0);
        try std.testing.expectEqual(owner, page.node("tail").element.layout_ptr);
    }
}

test "grid placement order changes auto placement while preserving authored child order" {
    var page = try Page.init("<main id='grid' style='display:grid;width:140px;grid-template-columns:repeat(3,40px);grid-auto-rows:20px;gap:10px'><div id='a' style='order:2'></div><div id='b' style='order:-1'></div><div id='c'></div></main>");
    defer page.deinit();
    try page.render();
    try page.offset("b", "grid", 0, 0);
    try page.offset("c", "grid", 50, 0);
    try page.offset("a", "grid", 100, 0);
    const owner = page.node("a").element.layout_ptr;
    try page.setStyle("a", "order:-2");
    try page.reflow();
    try page.offset("a", "grid", 0, 0);
    try page.offset("b", "grid", 50, 0);
    try page.offset("c", "grid", 100, 0);
    try std.testing.expectEqual(page.node("a"), &page.node("grid").element.children.items[0]);
    try std.testing.expectEqual(owner, page.node("a").element.layout_ptr);
}

test "grid placement explicit overlap keeps normal DOM paint and hit order" {
    var page = try Page.init("<main id='grid' style='display:grid;width:80px;grid-template-columns:40px 40px;grid-template-rows:30px'><div id='back' style='grid-area:1 / 1 / 2 / 3;background:red'></div><div id='front' style='grid-area:1 / 1 / 2 / 3;background:green'></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("back", 80, 30);
    try page.size("front", 80, 30);
    try page.offset("front", "back", 0, 0);
    const front = try page.box("front");
    const commands = try page.engine.?.paintDocument(page.document.?);
    defer DisplayItem.freeList(allocator, commands);
    const hit = DisplayItem.hitTest(commands, @intFromFloat(front.x + 5), @intFromFloat(front.y + 5), 1).?;
    try std.testing.expectEqual(page.node("front"), hit.source.originatingNode());
}

test "grid placement spanned percentages include gaps and authored zoom exactly once" {
    var page = try Page.init("<main id='grid' style='display:grid;width:200px;grid-template-columns:60px 120px;grid-template-rows:40px 80px;column-gap:20px;row-gap:10px;zoom:2;padding:5px;border:1px solid'><div id='span' style='grid-area:1 / 1 / 3 / 3;width:50%;height:50%;justify-self:start;align-self:start'><div id='child' style='display:block;width:100%;height:100%'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("grid", 424, 284);
    try page.size("span", 200, 130);
    try page.size("child", 200, 130);
    try page.offset("span", "grid", 12, 12);
}

test "grid placement spanning intrinsic width reaches a retained shrinkwrap parent" {
    var page = try Page.init("<main id='outer' style='display:flex;width:max-content'><div id='grid' style='display:grid;grid-template-columns:auto auto;gap:10px'><div id='span' style='grid-column:1 / 3;grid-row:1'><div id='wide' style='display:block;width:120px;height:20px'></div></div><div style='grid-column:1;grid-row:2'><div style='display:block;width:40px;height:10px'></div></div><div style='grid-column:2;grid-row:2'><div style='display:block;width:20px;height:10px'></div></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("outer", 120, 40);
    try page.size("grid", 120, 40);
    try page.size("span", 120, 20);
    const owner = page.node("grid").element.layout_ptr;
    try page.setStyle("wide", "display:block;width:160px;height:20px");
    try page.reflow();
    try page.size("outer", 160, 40);
    try page.size("grid", 160, 40);
    try std.testing.expectEqual(owner, page.node("grid").element.layout_ptr);
}

test "grid placement inline snapshot remeasures implicit columns without retaining temporary owners" {
    var page = try Page.init("<main id='line' style='display:block;width:300px;font-size:0;line-height:0'><span style='display:inline-block;width:10px;height:20px'></span><span id='grid' style='display:inline-grid;grid-template-columns:40px 60px;grid-auto-columns:30px;grid-auto-rows:20px;column-gap:10px'><span id='span' style='grid-column:1 / 3'></span></span></main>");
    defer page.deinit();
    try page.render();
    try page.size("grid", 110, 20);
    try page.offset("grid", "line", 10, 0);
    const owner = page.node("line").element.layout_ptr;
    try page.setStyle("span", "grid-column:1 / 4");
    try page.reflow();
    try page.size("grid", 150, 20);
    try page.size("span", 150, 20);
    try page.offset("grid", "line", 10, 0);
    try std.testing.expectEqual(owner, page.node("line").element.layout_ptr);
    try std.testing.expect(page.node("grid").element.layout_ptr == null);
    try std.testing.expect(page.node("span").element.layout_ptr == null);
}

test "grid placement auto fit keeps every occupied span track and resolves negative ends before collapse" {
    var page = try Page.init("<main id='grid' style='display:grid;width:230px;grid-template-columns:repeat(auto-fit,50px);grid-auto-rows:20px;column-gap:10px;justify-content:start'><div id='span' style='grid-column:2 / 4;grid-row:1'></div><div id='end' style='grid-column:-2 / -1;grid-row:1'></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("span", 110, 20);
    try page.offset("span", "grid", 0, 0);
    try page.size("end", 50, 20);
    try page.offset("end", "grid", 120, 0);
    const owner = page.node("span").element.layout_ptr;
    try page.setStyle("span", "grid-column:2 / -1;grid-row:1");
    try page.reflow();
    try page.size("span", 170, 20);
    try page.offset("end", "grid", 120, 0);
    try std.testing.expectEqual(owner, page.node("span").element.layout_ptr);
}

test "grid placement baseline export follows geometric first and last rows" {
    for ([_]bool{ false, true }) |last| {
        const source = try std.fmt.allocPrint(allocator, "<main id='line' style='display:flex;width:100px;align-items:{s} baseline'><div id='grid' style='display:grid;width:40px;grid-template-columns:40px;grid-template-rows:20px 40px'><div style='grid-row:2;height:40px'></div><div style='grid-row:1;height:20px'></div></div><div id='marker' style='width:10px;height:10px'></div></main>", .{if (last) "last" else "first"});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.size("grid", 40, 60);
        try page.size("line", 100, 60);
        try page.offset("marker", "grid", 40, if (last) 50 else 10);
    }
}

test "grid placement spanning areas include content distribution between tracks" {
    var page = try Page.init("<main id='grid' style='display:grid;width:300px;height:200px;grid-template-columns:50px 50px;grid-template-rows:20px 20px;gap:10px;justify-content:space-between;align-content:space-between'><div id='span' style='grid-area:1 / 1 / 3 / 3;width:50%;height:50%;justify-self:start;align-self:start'></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("span", 150, 100);
    try page.offset("span", "grid", 0, 0);
}

test "grid placement spanning content grows auto rows and out of flow boxes reserve no cells" {
    var page = try Page.init("<main style='display:block'><div id='rows' style='display:grid;width:130px;grid-template-columns:60px 60px;grid-template-rows:auto auto;gap:10px'><div id='span' style='grid-column:1;grid-row:1 / 3'><div style='display:block;height:90px'></div></div><div id='first' style='grid-column:2;grid-row:1'><div style='display:block;height:20px'></div></div><div id='second' style='grid-column:2;grid-row:2'><div style='display:block;height:20px'></div></div></div><div id='flow' style='display:grid;position:relative;width:100px;grid-template-columns:50px 50px;grid-auto-rows:20px'><div style='position:absolute;width:10px;height:10px;grid-column:1 / 3'></div><div id='a'></div><div id='b'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("rows", 130, 90);
    try page.size("span", 60, 90);
    try page.size("first", 60, 40);
    try page.size("second", 60, 40);
    try page.offset("second", "rows", 70, 50);
    try page.size("flow", 100, 20);
    try page.offset("a", "flow", 0, 0);
    try page.offset("b", "flow", 50, 0);
}

test "grid placement inline column flow uses definite height for repeated row topology" {
    var page = try Page.init("<main id='line' style='display:block;width:200px;font-size:0;line-height:0'><span id='grid' style='display:inline-grid;height:100px;grid-auto-flow:column;grid-template-rows:repeat(auto-fill,20px);grid-auto-columns:20px'><span></span><span></span><span></span><span></span><span id='last'></span></span></main>");
    defer page.deinit();
    try page.render();
    try page.size("grid", 20, 100);
    try page.offset("last", "grid", 0, 80);
    const owner = page.node("line").element.layout_ptr;
    try page.setStyle("grid", "display:inline-grid;height:40px;grid-auto-flow:column;grid-template-rows:repeat(auto-fill,20px);grid-auto-columns:20px");
    try page.reflow();
    try page.size("grid", 60, 40);
    try page.offset("last", "grid", 40, 0);
    try std.testing.expectEqual(owner, page.node("line").element.layout_ptr);
    try std.testing.expect(page.node("grid").element.layout_ptr == null);
}

test "grid placement fixed spanning rows transfer percentage height into intrinsic width" {
    for ([_][]const u8{ "", "min-width:0;" }) |minimum| {
        const source = try std.fmt.allocPrint(allocator, "<main id='line' style='display:block;width:400px;font-size:0;line-height:0'><span id='grid' style='display:inline-grid;grid-template-rows:50px 50px'><span id='item' style='{s}aspect-ratio:1;height:100%;grid-row:1 / 3'><span id='child' style='display:block;height:50%'></span></span></span></main>", .{minimum});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.size("grid", 100, 100);
        try page.size("item", 100, 100);
        try page.size("child", 100, 50);
        const owner = page.node("line").element.layout_ptr;
        try page.setStyle("grid", "display:inline-grid;grid-template-rows:20px 30px;row-gap:10px;zoom:2");
        try page.reflow();
        try page.size("grid", 120, 120);
        try page.size("item", 120, 120);
        try page.size("child", 120, 60);
        try page.setStyle("grid", "display:inline-grid;grid-template-rows:0px 0px");
        try page.reflow();
        try page.size("grid", 0, 0);
        try page.size("item", 0, 0);
        try std.testing.expectEqual(owner, page.node("line").element.layout_ptr);
    }
}

test "grid placement baseline export uses the opposite sharing group before fallback" {
    for ([_]bool{ false, true }) |last| {
        const source = try std.fmt.allocPrint(allocator, "<main style='display:flex;width:120px;align-items:{s}baseline'><div id='grid' style='display:grid;width:80px;grid-template-columns:80px;grid-template-rows:100px'><div style='display:flex;flex-direction:column;align-self:{s}baseline'><div style='height:10px;flex:none'></div><div style='height:30px;flex:none'></div></div></div><div id='marker' style='width:10px;height:10px'></div></main>", .{ if (last) "last " else "", if (last) "" else "last " });
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.size("grid", 80, 100);
        try page.offset("marker", "grid", 80, if (last) 0 else 90);
    }
}

test "grid placement last baseline follows grid order rather than farthest span edge" {
    for ([_][]const u8{ "3", "1" }) |column| {
        const source = try std.fmt.allocPrint(allocator, "<main style='display:flex;width:120px;align-items:last baseline'><div id='grid' style='display:grid;width:80px;grid-template-columns:repeat(4,20px);grid-template-rows:60px;align-items:start'><div style='grid-column:1 / 5;grid-row:1;height:40px'></div><div style='grid-column:{s};grid-row:1;height:20px'></div></div><div id='marker' style='width:10px;height:10px'></div></main>", .{column});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.offset("marker", "grid", 80, 10);
    }
}
