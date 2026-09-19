//! Shared sizing and alignment contracts through retained boxes and CSSOM geometry.
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
        if (std.mem.eql(u8, property, "overflow")) {
            self.set(id, "overflow-x", value);
            self.set(id, "overflow-y", value);
            return;
        }
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

test "shared sizing fit content resolves percentage padding and tracks descendant constraints" {
    var page = try Page.init("<main id='main' style='display:block;width:400px'><div id='fit' style='display:block;overflow:hidden;width:fit-content;padding-left:20%'><div id='a' style='display:block;float:left;width:50px;min-width:0px;height:20px'></div><div style='display:block;float:left;width:50px;height:20px'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("fit", 180, 20);
    const owner = page.node("fit").element.layout_ptr;
    page.set("main", "width", "300px");
    try page.reflow();
    try page.size("fit", 160, 20);
    page.set("a", "min-width", "90px");
    try page.reflow();
    try page.size("fit", 200, 20);
    try std.testing.expectEqual(owner, page.node("fit").element.layout_ptr);
    page.set("main", "width", "500px");
    try page.reflow();
    try page.size("fit", 240, 20);
}

test "shared sizing intrinsic border box limits count nested authored zoom once" {
    var page = try Page.init("<main style='display:block;width:400px;zoom:2'><div id='min' style='display:block;zoom:1.5;width:min-content;min-width:80px;max-width:50px;box-sizing:border-box;padding:10px'><div style='display:block;width:40px;height:10px'></div></div><div id='max' style='display:block;width:max-content;box-sizing:border-box;padding:10px'><div style='display:block;width:40px;height:10px'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("min", 240, 90);
    try page.size("max", 120, 60);
}

test "shared sizing flex shrink weights exclude padding and content basis ignores authored width" {
    var page = try Page.init("<main style='display:block'><div id='shrink' style='display:flex;width:150px'><div id='padded' style='flex:0 1 100px;min-width:0;padding:0 20px;height:20px'></div><div id='plain' style='flex:0 1 100px;min-width:0;height:20px'></div></div><div style='display:flex;width:300px'><div id='content' style='flex:0 0 content;width:200px;height:20px'><div style='display:block;width:50px;height:20px'></div></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("padded", 95, 20);
    try page.size("plain", 55, 20);
    try page.offset("plain", "shrink", 95, 0);
    try page.size("content", 50, 20);
}

test "shared sizing ratio flex bases survive explicit zero automatic minima on both axes" {
    var page = try Page.init("<main style='display:block'><div style='display:flex;width:200px'><div id='row' style='flex:none;min-width:0;height:40px;aspect-ratio:2'></div></div><div style='display:flex;flex-direction:column;width:200px;height:100px'><div id='column' style='flex:none;min-height:0;width:80px;aspect-ratio:2'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("row", 80, 40);
    try page.size("column", 80, 40);
}

test "shared sizing automatic content minimum respects ratio transferred cross maximum" {
    var page = try Page.init("<main style='display:flex;width:100px'><div id='item' style='aspect-ratio:2;max-height:30px'><div style='display:block;width:200px;height:20px'></div></div></main>");
    defer page.deinit();
    try page.render();
    try std.testing.expectEqual(@as(f64, 100), (try page.box("item")).width);
}

test "shared sizing wrapping columns stretch within completed lines" {
    var page = try Page.init("<main id='wrap' style='display:flex;flex-flow:column wrap;width:200px;height:60px'><div id='first' style='flex:none;height:40px'><div style='display:block;width:50px;height:20px'></div></div><div id='second' style='flex:none;height:40px'><div style='display:block;width:50px;height:20px'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("first", 100, 40);
    try page.size("second", 100, 40);
    try page.offset("first", "wrap", 0, 0);
    try page.offset("second", "wrap", 100, 0);
}

test "shared sizing flex automatic minima distinguish scrollable and explicit zero" {
    for ([_][]const u8{ "row", "column" }) |direction| {
        const source = try std.fmt.allocPrint(allocator, "<main style='display:flex;flex-direction:{s};width:100px;height:100px'><div id='item' style='flex:1 1 0;min-width:auto;min-height:auto;overflow:visible'><div style='display:block;width:120px;height:120px'></div></div><div style='flex:0 0 20px'></div></main>", .{direction});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        const horizontal = std.mem.eql(u8, direction, "row");
        const initial = try page.box("item");
        try std.testing.expectEqual(@as(f64, 120), if (horizontal) initial.width else initial.height);
        page.set("item", if (horizontal) "min-width" else "min-height", "0px");
        try page.reflow();
        const zero = try page.box("item");
        try std.testing.expectEqual(@as(f64, 80), if (horizontal) zero.width else zero.height);
        page.set("item", if (horizontal) "min-width" else "min-height", "auto");
        page.set("item", "overflow", "hidden");
        try page.reflow();
        const scrolling = try page.box("item");
        try std.testing.expectEqual(@as(f64, 80), if (horizontal) scrolling.width else scrolling.height);
    }
}

test "shared sizing flex percentage descendants distinguish stretch and content allocation" {
    var page = try Page.init("<main style='display:block'><div style='display:flex;width:100px;height:80px;align-items:flex-start'><div id='natural' style='align-self:flex-start'><div id='natural-percent' style='display:block;height:50%'><div style='display:block;width:20px;height:40px'></div></div></div><div id='stretched' style='align-self:stretch'><div id='stretch-percent' style='display:block;height:50%'><div style='display:block;width:20px;height:40px'></div></div></div></div><div style='display:flex;flex-direction:column;width:100px'><div id='content' style='flex:1 1 content;height:100px;min-height:0'><div id='content-percent' style='display:block;height:100%;width:20px'></div></div><div style='flex:1 1 auto;height:100px;min-height:0'><div id='auto-percent' style='display:block;height:100%;width:20px'></div></div></div></main>");
    defer page.deinit();
    try page.render();
    try std.testing.expectEqual(@as(f64, 40), (try page.box("natural-percent")).height);
    try std.testing.expectEqual(@as(f64, 80), (try page.box("stretched")).height);
    try std.testing.expectEqual(@as(f64, 40), (try page.box("stretch-percent")).height);
    try std.testing.expectEqual(@as(f64, 0), (try page.box("content-percent")).height);
    try std.testing.expectEqual(@as(f64, 100), (try page.box("auto-percent")).height);
    page.set("natural", "align-self", "stretch");
    try page.reflow();
    try std.testing.expectEqual(@as(f64, 80), (try page.box("natural")).height);
    page.set("content", "flex-basis", "100px");
    try page.reflow();
    try std.testing.expectEqual(@as(f64, 100), (try page.box("content-percent")).height);
}

test "shared sizing negative alignment and cross auto margins preserve overflow rules" {
    var page = try Page.init("<main style='display:block'><div id='unsafe' style='display:flex;width:50px;height:60px;justify-content:center'><div id='overflow' style='flex:0 0 100px;height:20px;margin-left:auto;margin-right:auto'></div></div><div id='safe' style='display:flex;width:50px;height:60px;justify-content:safe center'><div id='safe-item' style='flex:0 0 100px;height:20px'></div></div><div id='cross' style='display:flex;width:100px;height:100px;align-items:stretch'><div id='center' style='width:20px;height:20px;margin-top:auto;margin-bottom:auto'></div><div id='large' style='width:20px;height:120px;margin-top:auto;margin-bottom:auto'></div></div></main>");
    defer page.deinit();
    try page.render();
    try page.offset("overflow", "unsafe", -25, 0);
    try page.offset("safe-item", "safe", 0, 0);
    try page.offset("center", "cross", 0, 40);
    try page.offset("large", "cross", 20, 0);
    try page.size("center", 20, 20);
}

test "shared sizing grid percentages use areas and nonstretch auto items shrink fit" {
    var page = try Page.init("<main id='grid' style='display:grid;width:400px;grid-template-columns:100px 300px;grid-template-rows:100px 100px'><div id='percent' style='width:50%;height:20px'></div><div id='center' style='justify-self:center;height:20px'><div id='child' style='display:block;width:40px;height:20px'></div></div><div id='large' style='width:150px;height:20px;justify-self:center'></div><div id='auto' style='width:40px;height:20px;margin:auto'></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("percent", 50, 20);
    try page.size("center", 40, 20);
    try page.offset("center", "grid", 230, 0);
    try page.size("large", 150, 20);
    try page.offset("large", "grid", -25, 100);
    try page.offset("auto", "grid", 230, 140);
    const owner = page.node("center").element.layout_ptr;
    page.set("child", "width", "80px");
    try page.reflow();
    try page.size("center", 80, 20);
    try page.offset("center", "grid", 210, 0);
    try std.testing.expectEqual(owner, page.node("center").element.layout_ptr);
}

test "shared sizing grid intrinsic tracks differ from auto and zero minimum fractions" {
    var page = try Page.init("<main style='display:block'><div id='intrinsic' style='display:grid;width:300px;grid-template-columns:min-content max-content'><div id='min'><div style='display:block;float:left;width:40px;height:10px'></div><div style='display:block;float:left;width:60px;height:10px'></div></div><div id='max'><div style='display:block;float:left;width:40px;height:10px'></div><div style='display:block;float:left;width:60px;height:10px'></div></div></div><div style='display:grid;width:80px;grid-template-columns:1fr'><div id='automatic'><div style='display:block;width:120px;height:20px'></div></div></div><div style='display:grid;width:80px;grid-template-columns:minmax(0,1fr)'><div id='zero'><div style='display:block;width:120px;height:20px'></div></div></div></main>");
    defer page.deinit();
    try page.render();
    try std.testing.expectEqual(@as(f64, 60), (try page.box("min")).width);
    try std.testing.expectEqual(@as(f64, 100), (try page.box("max")).width);
    try page.offset("max", "intrinsic", 60, 0);
    try page.size("automatic", 120, 20);
    try page.size("zero", 80, 20);
}

test "shared sizing grid content distribution positions tracks without stretching fixed sizes" {
    var page = try Page.init("<main id='grid' style='display:grid;width:300px;height:200px;grid-template-columns:50px 50px;grid-template-rows:40px 40px;gap:10px;justify-content:space-between;align-content:center'><div id='a'></div><div id='b'></div><div id='c'></div><div id='d'></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("a", 50, 40);
    try page.offset("a", "grid", 0, 55);
    try page.offset("b", "grid", 250, 55);
    try page.offset("c", "grid", 0, 105);
    try page.offset("d", "grid", 250, 105);
}

test "shared sizing synthesized flex and grid baselines survive mutation and paint reuse" {
    for ([_][]const u8{ "flex", "grid" }) |format| {
        const source = try std.fmt.allocPrint(allocator, "<main id='group' style='display:{s};width:200px;grid-template-columns:100px 100px;align-items:baseline'><div id='small' style='width:50px;height:20px;background:green'></div><div id='large' style='width:50px;height:40px;background:blue'></div></main>", .{format});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.offset("small", "group", 0, 20);
        try std.testing.expectEqual((try page.box("small")).y + 20, (try page.box("large")).y + 40);
        page.set("large", "height", "60px");
        try page.reflow();
        try page.offset("small", "group", 0, 40);
        const small = try page.box("small");
        page.set("small", "background-color", "red");
        try std.testing.expect(!page.document.?.layoutNeeded());
        const commands = try page.engine.?.paintDocument(page.document.?);
        defer DisplayItem.freeList(allocator, commands);
        const hit = DisplayItem.hitTest(commands, @intFromFloat(small.x + 5), @intFromFloat(small.y + 5), 1).?;
        try std.testing.expectEqual(page.node("small"), hit.source.originatingNode());
        try std.testing.expectEqual(small, try page.box("small"));
    }
}

test "shared sizing first and last flex baselines use the corresponding in flow line" {
    var page = try Page.init("<main id='group' style='display:flex;width:200px;align-items:first baseline;font-size:0;line-height:0'><div id='two' style='width:50px'><span id='first' style='display:inline-block;width:10px;height:10px'></span><br><span id='last' style='display:inline-block;width:10px;height:20px'></span></div><div id='one' style='width:50px'><span id='only' style='display:inline-block;width:10px;height:30px'></span></div></main>");
    defer page.deinit();
    try page.render();
    const first = try page.box("first");
    const only = try page.box("only");
    try std.testing.expectEqual(first.y + first.height, only.y + only.height);
    try std.testing.expect((try page.box("two")).y > (try page.box("one")).y);
    page.set("group", "align-items", "last baseline");
    try page.reflow();
    const last = try page.box("last");
    const last_only = try page.box("only");
    try std.testing.expectEqual(last.y + last.height, last_only.y + last_only.height);
}

test "shared sizing ordinary float measures the complete styled inline run and retains its owner" {
    var page = try Page.init("<main style='display:block;width:700px;font-size:16px;line-height:32px'><section style='display:block;overflow:hidden'><div id='float' style='display:block;float:left'>alpha beta <span id='float-text' style='font-size:20px;font-weight:bold'>gamma delta</span> epsilon zeta</div></section><div id='reference' style='display:block;width:max-content'>alpha beta <span id='reference-text' style='font-size:20px;font-weight:bold'>gamma delta</span> epsilon zeta</div></main>");
    defer page.deinit();
    try page.render();
    const initial = try page.box("float");
    const reference = try page.box("reference");
    try std.testing.expectEqual(reference.width, initial.width);
    try std.testing.expectEqual(reference.height, initial.height);
    const owner = page.node("float").element.layout_ptr;
    try std.testing.expect(owner != null);

    for ([_][]const u8{ "float-text", "reference-text" }) |id| {
        const element = &page.node(id).element;
        try element.putOwnedAttribute(allocator, "style", "font-size:30px;font-weight:bold");
        parser.dirtyStyleForElement(element);
    }
    // Inherited text styles must be republished before intrinsic measurement.
    try parser.style(allocator, &page.root, &.{});
    try page.reflow();
    const changed = try page.box("float");
    const changed_reference = try page.box("reference");
    try std.testing.expect(changed.width > initial.width);
    try std.testing.expectEqual(changed_reference.width, changed.width);
    try std.testing.expectEqual(changed_reference.height, changed.height);
    try std.testing.expectEqual(owner, page.node("float").element.layout_ptr);
}

test "shared sizing ordinary float counts atomic child zoom and box edges once" {
    var page = try Page.init("<main id='main' style='display:block;overflow:hidden;width:200px;zoom:2;font-size:0;line-height:0'><div id='float' style='display:block;float:left;padding:4px;border:2px solid black;margin:3px'><span id='child' style='display:inline-block;width:60px;height:20px;zoom:1.5'></span></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("child", 180, 60);
    try page.size("float", 204, 84);
    try page.offset("float", "main", 6, 6);
    const owner = page.node("float").element.layout_ptr;
    try std.testing.expect(owner != null);

    page.set("child", "width", "80px");
    try page.reflow();
    try page.size("child", 240, 60);
    try page.size("float", 264, 84);
    try page.offset("float", "main", 6, 6);
    try std.testing.expectEqual(owner, page.node("float").element.layout_ptr);
}

test "shared sizing ordinary float preserves unbreakable minimum until maximum caps its box" {
    var page = try Page.init("<main id='main' style='display:block;overflow:hidden;width:40px;font-size:0;line-height:0'><div id='float' style='display:block;float:left;padding:5px;border:1px solid black;margin:3px'><span id='child' style='display:inline-block;width:100px;height:20px'></span></div></main>");
    defer page.deinit();
    try page.render();
    try page.size("float", 112, 32);
    try page.size("child", 100, 20);
    try page.offset("float", "main", 3, 3);
    const owner = page.node("float").element.layout_ptr;
    try std.testing.expect(owner != null);

    page.set("float", "max-width", "50px");
    try page.reflow();
    try page.size("float", 62, 32);
    try page.size("child", 100, 20);
    try page.offset("float", "main", 3, 3);
    try std.testing.expectEqual(owner, page.node("float").element.layout_ptr);
}
