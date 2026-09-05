//! Deterministic box-level flex/grid and root-relative sizing regressions.
const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const document = @import("../document/parser.zig");

const Page = struct {
    root: document.Node,
    environ: std.process.Environ.Map,
    engine: ?*Layout = null,
    layout: ?*Layout.DocumentLayout = null,
    fn init(html: []const u8) !Page {
        const allocator = std.testing.allocator;
        var parser = try document.HTMLParser.init(allocator, html);
        defer parser.deinit(allocator);
        parser.use_implicit_tags = false;
        var root = try parser.parse();
        errdefer root.deinit(allocator);
        var environ = std.process.Environ.Map.init(allocator);
        errdefer environ.deinit();
        try environ.put("HOME", "/tmp");
        return .{ .root = root, .environ = environ };
    }
    fn render(self: *Page) !void {
        if (self.engine == null) self.engine = try Layout.init(std.testing.allocator, std.testing.io, &self.environ, 800, 600, false);
        document.fixParentPointers(&self.root, null);
        try document.style(std.testing.allocator, &self.root, &.{});
        if (self.layout) |layout| try layout.layout(self.engine.?) else self.layout = try self.engine.?.buildDocument(&self.root);
    }
    fn deinit(self: *Page) void {
        if (self.layout) |layout| {
            layout.deinit();
            std.testing.allocator.destroy(layout);
        }
        if (self.engine) |engine| engine.deinit();
        self.environ.deinit();
        self.root.deinit(std.testing.allocator);
    }
};

test "responsive flex boxes grow freeze wrap and reflow after width changes" {
    var page = try Page.init("<main style='display:flex;width:600px;gap:20px'><div style='flex:1;max-width:100px;height:40px'></div><div style='flex:2;height:60px'></div><span style='flex:1;height:20px'></span></main>");
    defer page.deinit();
    try page.render();
    const flex = page.layout.?.children.items[0];
    const a = flex.children.items[0].block;
    const b = flex.children.items[1].block;
    const c = flex.children.items[2].block;
    try std.testing.expectEqual(@as(i32, 100), a.width.get().*);
    try std.testing.expectEqual(@as(i32, 560), a.width.get().* + b.width.get().* + c.width.get().*);
    try std.testing.expectEqual(a.x.get().* + 120, b.x.get().*);
    try std.testing.expectEqual(a.y.get().*, c.y.get().*);
    try std.testing.expectEqual(@as(i32, 60), flex.content_height);
    try page.root.element.attributes.?.put("style", "display:flex;width:250px;flex-wrap:wrap;gap:10px");
    for (page.root.element.children.items) |*child| {
        try child.element.attributes.?.put("style", "flex:0 0 120px;height:30px");
        @import("../document/dom.zig").dirtyStyleForElement(&child.element);
    }
    @import("../document/dom.zig").dirtyStyleForElement(&page.root.element);
    try page.render();
    try std.testing.expectEqual(@as(i32, 120), flex.children.items[0].block.width.get().*);
    try std.testing.expectEqual(flex.children.items[0].block.y.get().* + 40, flex.children.items[2].block.y.get().*);
    try std.testing.expectEqual(@as(i32, 70), flex.content_height);
    try std.testing.expect(!page.layout.?.layoutNeeded());
}

test "responsive grid uses fr tracks gaps root units and auto-fit" {
    var page = try Page.init("<main style='font-size:10px;display:grid;width:64rem;grid-template-columns:10rem 1fr 2fr;gap:2rem'><div style='height:20px'></div><span style='height:40px'></span><div style='height:30px'></div></main>");
    defer page.deinit();
    try page.render();
    const grid = page.layout.?.children.items[0];
    try std.testing.expectEqual(@as(i32, 640), grid.width.get().*);
    try std.testing.expectEqual(@as(i32, 100), grid.children.items[0].block.width.get().*);
    try std.testing.expectEqual(@as(i32, 500), grid.children.items[1].block.width.get().* + grid.children.items[2].block.width.get().*);
    try std.testing.expectEqual(@as(i32, 40), grid.content_height);
    try page.root.element.attributes.?.put("style", "display:grid;width:450px;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:20px");
    @import("../document/dom.zig").dirtyStyleForElement(&page.root.element);
    try page.render();
    try std.testing.expectEqual(@as(i32, 215), grid.children.items[0].block.width.get().*);
    try std.testing.expectEqual(grid.children.items[0].block.y.get().* + 60, grid.children.items[2].block.y.get().*);
    try std.testing.expectEqual(@as(i32, 90), grid.content_height);
}

test "responsive flex column stretch and border-box constraints" {
    var page = try Page.init("<main style='display:flex;flex-direction:column;width:300px;height:240px;gap:20px;padding:10px;box-sizing:border-box'><div style='flex:1;padding:10px'></div><div style='flex:1;padding:10px'></div></main>");
    defer page.deinit();
    try page.render();
    const flex = page.layout.?.children.items[0];
    try std.testing.expectEqual(@as(i32, 300), flex.width.get().*);
    try std.testing.expectEqual(@as(i32, 240), flex.height.get().*);
    try std.testing.expectEqual(@as(i32, 280), flex.children.items[0].block.width.get().*);
    try std.testing.expectEqual(@as(i32, 100), flex.children.items[0].block.height.get().*);
    try std.testing.expectEqual(flex.children.items[0].block.y.get().* + 120, flex.children.items[1].block.y.get().*);
}

test "responsive definite height remains a percentage base after sibling measurement" {
    var page = try Page.init("<main style='display:block;position:relative;height:300px;width:400px'><div style='display:block;height:20px'></div><div style='display:block;position:absolute;top:50%;height:10px'></div><div style='display:block;height:50%'></div></main>");
    defer page.deinit();
    try page.render();
    const parent = page.layout.?.children.items[0];
    const positioned = parent.children.items[1].block;
    try std.testing.expectEqual(@as(i32, 150), positioned.y.get().* + positioned.position_offset.y - parent.y.get().*);
    try std.testing.expectEqual(@as(i32, 150), parent.children.items[2].block.height.get().*);
}

test "responsive formatting topology can rebuild repeatedly without retired subscribers" {
    var page = try Page.init("<main style='display:flex;width:600px'><div style='height:20px;flex:1'></div><span style='height:30px;flex:1'></span></main>");
    defer page.deinit();
    try page.render();
    for (0..12) |i| {
        try page.root.element.attributes.?.put("style", if (i % 2 == 0) "display:grid;width:600px;grid-template-columns:1fr 1fr;gap:20px" else "display:flex;width:600px;gap:20px");
        @import("../document/dom.zig").dirtyStyleForElement(&page.root.element);
        try page.render();
        const child = &page.root.element.children.items[1].element;
        try child.attributes.?.put("style", "height:40px;flex:2");
        @import("../document/dom.zig").dirtyStyleForElement(child);
        try page.render();
        const parent = page.layout.?.children.items[0];
        try std.testing.expectEqual(@as(i32, 600), parent.width.get().*);
        try std.testing.expectEqual(@as(i32, 40), parent.content_height);
        try std.testing.expect(!page.layout.?.layoutNeeded());
    }
}

test "responsive measured controls and images survive line-buffer moves and repeated layout" {
    var page = try Page.init("<main style='display:flex;width:640px;gap:20px'><div style='flex:1'><button>Grow text</button><input value='input'><img style='width:40px;height:30px'><canvas width='20' height='20'></canvas></div><div style='flex:1'><a href='#target'>A link</a><button>Second button</button></div></main>");
    defer page.deinit();
    try page.render();
    for (0..3) |_| {
        page.layout.?.mark();
        try page.render();
        try std.testing.expect(page.layout.?.height.get().* > 30);
        try std.testing.expect(!page.layout.?.layoutNeeded());
    }
}

test "responsive direct flex buttons retain visible paint and current hit bounds" {
    var page = try Page.init("<main style='display:flex;width:400px;gap:20px'><button style='flex:1;background-color:green'>First</button><button style='flex:1;background-color:green'>Second</button></main>");
    defer page.deinit();
    try page.render();
    const commands = try page.engine.?.paintDocument(page.layout.?);
    const display = @import("../browser/render/display_list.zig");
    defer display.DisplayItem.freeList(std.testing.allocator, commands);
    const first = page.layout.?.children.items[0].children.items[0].block;
    const hit = display.DisplayItem.hitTest(commands, first.x.get().* + 1, first.y.get().* + 5, 1.0);
    try std.testing.expect(hit != null);
    try std.testing.expect(hit.?.source.originatingNode() == &page.root.element.children.items[0]);
    try std.testing.expectEqual(@as(i32, 190), first.width.get().*);
}

test "responsive viewport and root font changes resize inherited variable grid tracks" {
    var page = try Page.init("<html style='display:block;font-size:10px;--track:20rem;--gap:2rem'><body style='display:block'><main style='display:grid;grid-template-columns:repeat(auto-fit,minmax(var(--track),1fr));gap:var(--gap)'><div style='height:4rem'></div><div style='height:4rem'></div><div style='height:4rem'></div><div style='height:4rem'></div></main></body></html>");
    defer page.deinit();
    try page.render();
    const grid = page.layout.?.children.items[0].children.items[0].block.children.items[0].block;
    const initial_width = grid.children.items[0].block.width.get().*;
    try std.testing.expectEqual(@as(i32, 40), grid.children.items[0].block.height.get().*);
    page.engine.?.window_width = 2560;
    page.layout.?.mark();
    try page.render();
    try std.testing.expect(grid.children.items[0].block.width.get().* > initial_width * 2);
    try std.testing.expectEqual(grid.children.items[0].block.y.get().*, grid.children.items[3].block.y.get().*);

    try page.root.element.attributes.?.put("style", "display:block;font-size:40px;--track:20rem;--gap:2rem");
    @import("../document/dom.zig").dirtyStyleForElement(&page.root.element);
    try page.render();
    // Ancestor font/style changes may rebuild the retained descendants.
    // Resolve current layout borrows only after the new pass completes.
    const resized_grid = page.layout.?.children.items[0].children.items[0].block.children.items[0].block;
    const first = resized_grid.children.items[0].block;
    const third = resized_grid.children.items[2].block;
    try std.testing.expectEqual(@as(i32, 160), first.height.get().*);
    try std.testing.expectEqual(first.y.get().* + 240, third.y.get().*);
    try std.testing.expect(!page.layout.?.layoutNeeded());
}
