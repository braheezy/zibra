//! Nested formatting contributions and their persistent invalidation owner.
const std = @import("std");
const parser = @import("../document/parser.zig");
const Layout = @import("../browser/render/layout.zig");
const intrinsic = @import("../browser/render/intrinsic_width.zig");
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

    fn prepare(self: *Page, css_source: []const u8) !void {
        parser.fixParentPointers(&self.root, null);
        var css = try @import("../document/css_parser.zig").CSSParser.init(allocator, css_source, false);
        defer css.deinit(allocator);
        const rules = try css.parse(allocator);
        defer {
            for (rules) |*rule| rule.deinit(allocator);
            allocator.free(rules);
        }
        try parser.style(allocator, &self.root, rules);
        self.engine = try Layout.init(allocator, std.testing.io, &self.environ, 800, 600, false);
    }

    fn render(self: *Page) !void {
        self.document = try self.engine.?.buildDocument(&self.root);
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

    fn node(self: *Page, id: []const u8) *parser.Node {
        return find(&self.root, id).?;
    }

    fn measure(self: *Page, id: []const u8, scale: f64, minimum: f64, maximum: f64) !void {
        const result = try intrinsic.measureContent(self.node(id), &self.engine.?.font_manager, scale);
        try std.testing.expectApproxEqAbs(minimum, result.min, 0.001);
        try std.testing.expectApproxEqAbs(maximum, result.max, 0.001);
    }

    fn width(self: *Page, id: []const u8, expected: f64) !void {
        var rects: std.ArrayList(geometry.Rect) = .empty;
        defer rects.deinit(allocator);
        try geometry.collect(self.document.?, self.node(id), 1, 0, false, allocator, &rects);
        try std.testing.expectEqual(@as(usize, 1), rects.items.len);
        try std.testing.expectEqual(expected, rects.items[0].width);
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

test "nested intrinsic flex rows blockify inline children and distinguish wrapping columns" {
    var page = try Page.init("<main id='row' style='display:flex;gap:10px'><span style='width:40px'></span><span style='width:60px'></span></main>");
    defer page.deinit();
    try page.prepare("");
    try page.measure("row", 1, 110, 110);
    page.set("row", "flex-wrap", "wrap");
    try page.measure("row", 1, 60, 110);
    page.set("row", "flex-direction", "column");
    try page.measure("row", 1, 60, 60);
}

test "nested intrinsic formatting applies item constraints edges and zoom once" {
    var page = try Page.init("<main id='row' style='display:flex;gap:10px'><span style='width:90px;max-width:40px;padding:5px;margin:3px;zoom:2'></span><span style='width:60px'></span></main>");
    defer page.deinit();
    try page.prepare("");
    try page.measure("row", 1, 182, 182);
    try page.measure("row", 2, 364, 364);
    page.set("row", "column-gap", "10%");
    try page.measure("row", 1, 172, 172);
}

test "nested intrinsic flex contributions keep preferred size separate from content and basis" {
    var page = try Page.init("<main id='row' style='display:flex'><div style='width:50px;flex:1 1 200px'><div style='display:block;width:100px'></div></div><div style='width:50px;flex:1 2 400px'><div style='display:block;width:100px'></div></div></main>");
    defer page.deinit();
    try page.prepare("");
    try page.measure("row", 1, 200, 200);
    page.root.element.children.items[0].element.style.?.getPtr("flex-shrink").?.set("0");
    try page.measure("row", 1, 300, 300);
}

test "nested intrinsic grid uses independent min max constraints and empty tracks" {
    var page = try Page.init("<main id='grid' style='display:grid;grid-template-columns:auto'><div><span style='display:inline-block;width:20px'></span><span style='display:inline-block;width:40px'></span></div></main>");
    defer page.deinit();
    try page.prepare("");
    try page.measure("grid", 1, 40, 60);
    page.set("grid", "grid-template-columns", "minmax(0,1fr)");
    try page.measure("grid", 1, 0, 60);
    page.set("grid", "grid-template-columns", "1fr");
    try page.measure("grid", 1, 40, 60);
    page.set("grid", "grid-template-columns", "10px 20px 30px");
    page.set("grid", "column-gap", "5px");
    try page.measure("grid", 1, 70, 70);
    page.set("grid", "grid-template-columns", "none");
    page.set("grid", "grid-auto-columns", "80px");
    try page.measure("grid", 1, 80, 80);
}

test "nested intrinsic row major grid ordering changes track contributions" {
    var page = try Page.init("<main id='grid' style='display:grid;grid-template-columns:1fr 100px'><span style='width:40px'></span><span id='middle' style='width:80px'></span><span style='width:120px'></span></main>");
    defer page.deinit();
    try page.prepare("");
    try page.measure("grid", 1, 220, 220);
    page.set("middle", "order", "1");
    try page.measure("grid", 1, 180, 180);
}

test "nested intrinsic grid fixed maximum caps automatic preferred minimum only" {
    var page = try Page.init("<main id='grid' style='display:grid;grid-template-columns:minmax(auto,50px)'><span id='item' style='width:200px'></span></main>");
    defer page.deinit();
    try page.prepare("");
    try page.measure("grid", 1, 50, 50);
    page.set("item", "min-width", "80px");
    try page.measure("grid", 1, 200, 200);
}

test "nested intrinsic anonymous groups preserve hidden and positioned element boundaries" {
    var page = try Page.init("<main id='row' style='display:flex;column-gap:10px'>ab<span style='display:none'></span>cd<span style='position:absolute;width:900px'></span>ef</main>");
    defer page.deinit();
    try page.prepare("");
    var expected: f64 = 20;
    for (page.root.element.children.items) |*node| if (node.* == .text) {
        expected += (try intrinsic.measureContent(node, &page.engine.?.font_manager, 1)).max;
    };
    try page.measure("row", 1, expected, expected);
}

test "nested intrinsic active generated items bracket authored children" {
    var page = try Page.init("<main id='row' style='display:flex;gap:5px'><span style='width:40px'></span></main>");
    defer page.deinit();
    try page.prepare("#row::before{content:'';width:20px}#row::after{content:'';width:30px}");
    try std.testing.expectEqual(@as(usize, 1), page.root.element.children.items.len);
    try page.measure("row", 1, 100, 100);
    page.root.element.generated_before.?.element.style.?.getPtr("content").?.set("none");
    try page.measure("row", 1, 75, 75);
}

test "nested intrinsic retained ancestors follow descendant gaps directions and grid tracks" {
    var page = try Page.init("<main style='display:block;width:300px'><div id='outer' style='display:block;width:max-content'><div id='row' style='display:flex;column-gap:10px'><span style='width:40px;height:20px'></span><span style='width:60px;height:20px'></span></div></div><div id='grid-outer' style='display:block;width:max-content'><div id='grid' style='display:grid;grid-template-columns:40px 60px;column-gap:10px'><span style='height:20px'></span><span style='height:20px'></span></div></div></main>");
    defer page.deinit();
    try page.prepare("");
    try page.render();
    const owner = page.node("outer").element.layout_ptr;
    try page.width("outer", 110);
    try page.width("grid-outer", 110);
    page.set("row", "column-gap", "30px");
    try page.reflow();
    try page.width("outer", 130);
    page.set("row", "flex-direction", "column");
    try page.reflow();
    try page.width("outer", 60);
    page.set("grid", "grid-template-columns", "80px 60px");
    try page.reflow();
    try page.width("grid-outer", 150);
    try std.testing.expectEqual(owner, page.node("outer").element.layout_ptr);
}

test "nested intrinsic atomic parent observes basis and private generated width mutations" {
    var page = try Page.init("<main style='display:block;width:300px'><span id='badge' style='display:inline-flex;gap:5px'><span id='item' style='flex:none;width:40px;height:20px'></span></span></main>");
    defer page.deinit();
    try page.prepare("#badge::before{content:'';width:20px;height:20px}");
    try page.render();
    try page.width("badge", 65);
    page.set("item", "flex-basis", "80px");
    try page.reflow();
    try page.width("badge", 105);
    page.node("badge").element.generated_before.?.element.style.?.getPtr("width").?.set("30px");
    try page.reflow();
    try page.width("badge", 115);
}

test "nested intrinsic mixed huge flex growth remains a bounded used width" {
    var page = try Page.init("<main style='display:block;width:300px'><span id='badge' style='display:inline-flex;width:max-content'><span style='flex:1 0 50px;width:200px;height:1px'></span><span style='flex:1e308 0 100px;width:200px;height:1px'></span></span></main>");
    defer page.deinit();
    try page.prepare("");
    try page.measure("badge", 1, 16777216, 16777216);
    try page.render();
    try page.width("badge", 16777216);
}

test "nested intrinsic percentage flex basis keeps four grid cards within equal tracks" {
    const content = "<span style='display:inline-block;width:80px;height:10px'></span>" ++
        "<span style='display:inline-block;width:80px;height:10px'></span>" ++
        "<span style='display:inline-block;width:80px;height:10px'></span>";
    const card = "<div style='display:flex;width:100%'><div style='flex:1 0 calc(70% - 10.5px)'>" ++ content ++
        "</div><div style='width:50px;height:20px'></div></div>";
    var page = try Page.init("<main style='display:grid;width:800px;grid-template-columns:repeat(4,1fr)'>" ++
        "<div id='card' style='display:flex;width:100%'><div id='heading' style='flex:1 0 calc(70% - 10.5px)'>" ++ content ++
        "</div><div style='width:50px;height:20px'></div></div>" ++ card ++ card ++ card ++ "</main>");
    defer page.deinit();
    try page.prepare("");
    try page.measure("card", 1, 130, 290);
    try page.render();
    try page.width("card", 200);
    page.set("heading", "flex-basis", "240px");
    try page.measure("card", 1, 290, 290);
    try page.reflow();
    try page.width("card", 290);
    page.set("heading", "flex-basis", "calc(70% - 10.5px)");
    try page.reflow();
    try page.width("card", 200);
}
