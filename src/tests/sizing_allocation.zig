//! Reviewed allocation boundaries: natural image minima, grid area constraints,
//! ratio-derived dimensions and percentage definiteness through nested owners.
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

test "shared allocation image automatic minimum uses natural content before authored width" {
    var page = try Page.init("<main id='container' style='display:flex;width:60px;align-items:flex-start'><img id='image' style='width:200px'></main>");
    defer page.deinit();
    const pixels = try @import("zigimg").Image.create(allocator, 100, 50, .rgba32);
    @memset(pixels.pixels.rgba32, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
    page.node("image").element.image_data = .{ .encoded_bytes = null, .image = pixels };
    try page.render();
    const owner = page.node("image").element.layout_ptr;
    try page.size("image", 100, 50);
    page.set("image", "min-width", "0px");
    try page.reflow();
    try page.size("image", 60, 30);
    page.set("image", "min-width", "auto");
    page.set("container", "width", "140px");
    try page.reflow();
    try page.size("image", 140, 70);
    try std.testing.expectEqual(owner, page.node("image").element.layout_ptr);
}

test "shared allocation fixed grid maxima cap automatic minima on both axes" {
    var page = try Page.init("<main id='grid' style='display:grid;width:50px;height:60px;grid-template-columns:minmax(auto,50px);grid-template-rows:minmax(auto,60px)'><div id='item'><div style='display:block;width:100px;height:120px'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("item", 50, 60);
    page.set("item", "min-width", "80px");
    page.set("item", "min-height", "90px");
    try page.reflow();
    try page.size("item", 80, 90);
    page.set("item", "min-width", "auto");
    page.set("item", "min-height", "auto");
    page.set("grid", "grid-template-columns", "minmax(min-content,50px)");
    page.set("grid", "grid-template-rows", "minmax(min-content,60px)");
    try page.reflow();
    try page.size("item", 100, 120);
}

test "shared allocation grid ratio sizes auto rows and percentage descendants" {
    var page = try Page.init("<main id='grid' style='display:grid;width:200px;grid-template-columns:100px;align-items:start'><div id='item' style='width:100px;aspect-ratio:2'><div id='percent' style='display:block;width:20px;height:50%'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("grid", 200, 50);
    try page.size("item", 100, 50);
    try page.size("percent", 20, 25);
    page.set("item", "width", "80px");
    try page.reflow();
    try page.size("grid", 200, 40);
    try page.size("item", 80, 40);
    try page.size("percent", 20, 20);
    page.set("item", "width", "auto");
    page.set("item", "height", "60px");
    try page.reflow();
    try page.size("grid", 200, 60);
    try page.size("item", 120, 60);
    try page.size("percent", 20, 30);
}

test "shared allocation row flex ratio derives bounded definite cross heights" {
    var page = try Page.init("<main id='row' style='display:flex;width:100px;align-items:flex-start'><div id='item' style='width:100px;flex:none;aspect-ratio:2'><div id='percent' style='display:block;width:20px;height:50%'></div></div></main>");
    defer page.deinit();
    try page.render();
    const owner = page.node("item").element.layout_ptr;
    try page.size("row", 100, 50);
    try page.size("item", 100, 50);
    try page.size("percent", 20, 25);
    page.set("item", "width", "80px");
    try page.reflow();
    try page.size("row", 100, 40);
    try page.size("item", 80, 40);
    try page.size("percent", 20, 20);
    page.set("item", "max-height", "30px");
    try page.reflow();
    try page.size("row", 100, 30);
    try page.size("item", 80, 30);
    try page.size("percent", 20, 15);
    page.set("item", "min-height", "60px");
    try page.reflow();
    try page.size("row", 100, 60);
    try page.size("item", 80, 60);
    try page.size("percent", 20, 30);
    try std.testing.expectEqual(owner, page.node("item").element.layout_ptr);
}

test "shared allocation nested flex preserves indefinite height until stretching" {
    var page = try Page.init("<main id='outer' style='display:flex;width:200px;align-items:flex-start'><div id='middle' style='display:flex;flex-direction:column;width:100px'><div id='percent' style='flex:none;height:50%'><div style='display:block;height:20px'></div></div></div></main>");
    defer page.deinit();
    try page.render();
    const owner = page.node("middle").element.layout_ptr;
    try page.size("middle", 100, 20);
    try page.size("percent", 100, 20);
    page.set("outer", "height", "80px");
    page.set("outer", "align-items", "stretch");
    try page.reflow();
    try page.size("middle", 100, 80);
    try page.size("percent", 100, 40);
    page.set("outer", "height", "auto");
    page.set("outer", "align-items", "flex-start");
    try page.reflow();
    try page.size("middle", 100, 20);
    try page.size("percent", 100, 20);
    try std.testing.expectEqual(owner, page.node("middle").element.layout_ptr);
}

test "shared allocation intrinsic ratio overflow edits invalidate retained ancestors" {
    var page = try Page.init("<main id='wrapper' style='display:block;width:max-content'><div id='ratio' style='display:block;height:50px;aspect-ratio:2'><div style='display:block;width:300px;height:10px'></div></div></main>");
    defer page.deinit();
    try page.render();
    const wrapper_owner = page.node("wrapper").element.layout_ptr;
    const ratio_owner = page.node("ratio").element.layout_ptr;
    try page.size("wrapper", 300, 50);
    page.set("ratio", "overflow", "hidden");
    try page.reflow();
    try page.size("wrapper", 100, 50);
    page.set("ratio", "overflow", "visible");
    try page.reflow();
    try page.size("wrapper", 300, 50);
    page.set("ratio", "height", "200px");
    try page.reflow();
    try page.size("wrapper", 400, 200);
    page.set("ratio", "aspect-ratio", "3");
    try page.reflow();
    try page.size("wrapper", 600, 200);
    try std.testing.expectEqual(wrapper_owner, page.node("wrapper").element.layout_ptr);
    try std.testing.expectEqual(ratio_owner, page.node("ratio").element.layout_ptr);
}

test "shared allocation flex and grid items contain floats through retained width changes" {
    for ([_][]const u8{ "flex", "grid" }) |format| {
        const source = try std.fmt.allocPrint(allocator, "<main id='container' style='display:{s};flex-direction:column;grid-template-columns:1fr;width:75px'><div id='first' style='flex:0 0 content'><div id='float-a' style='display:block;float:left;width:50px;height:50px'></div><div id='float-b' style='display:block;float:left;width:50px;height:50px'></div></div><div id='sibling' style='flex:0 0 content'><div id='sibling-float' style='display:block;float:left;width:25px;height:25px'></div></div></main>", .{format});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        const first_owner = page.node("first").element.layout_ptr;
        const sibling_owner = page.node("sibling").element.layout_ptr;
        for ([_][]const u8{ "75px", "150px", "75px" }, [_]f64{ 75, 150, 75 }, 0..) |width_css, width, index| {
            if (index > 0) {
                page.set("container", "width", width_css);
                try page.reflow();
            }
            const first_height: f64 = if (width == 75) 100 else 50;
            try page.size("container", width, first_height + 25);
            try page.size("first", width, first_height);
            try page.size("sibling", width, 25);
            const first = try page.box("first");
            const a = try page.box("float-a");
            const b = try page.box("float-b");
            const sibling = try page.box("sibling");
            const sibling_float = try page.box("sibling-float");
            try std.testing.expectEqual(first.x, a.x);
            try std.testing.expectEqual(first.y, a.y);
            try std.testing.expectEqual(first.x + if (width == 75) @as(f64, 0) else 50, b.x);
            try std.testing.expectEqual(first.y + if (width == 75) @as(f64, 50) else 0, b.y);
            try std.testing.expectEqual(first.x, sibling.x);
            try std.testing.expectEqual(first.y + first_height, sibling.y);
            try std.testing.expectEqual(sibling.x, sibling_float.x);
            try std.testing.expectEqual(sibling.y, sibling_float.y);
            try std.testing.expectEqual(first_owner, page.node("first").element.layout_ptr);
            try std.testing.expectEqual(sibling_owner, page.node("sibling").element.layout_ptr);
        }
    }
}
