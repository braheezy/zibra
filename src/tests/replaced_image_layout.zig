//! Replaced image constraints across intrinsic measurement, retained layout,
//! display commands and CSSOM geometry. Synthetic pixels are DOM-owned.
const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const parser = @import("../document/parser.zig");
const geometry = @import("../browser/render/element_geometry.zig");
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
        return .{ .root = root, .engine = try Layout.init(allocator, std.testing.io, &environ, 1400, 700, false) };
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

    fn expectBox(self: *Page, node: *parser.Node, width: i32, height: i32) !void {
        const bounds = self.engine.image_bounds.get(node).?;
        try std.testing.expectEqual(width, bounds.width);
        try std.testing.expectEqual(height, bounds.height);
        var rects = std.ArrayList(geometry.Rect).empty;
        defer rects.deinit(allocator);
        try geometry.collect(self.document.?, node, 1, 0, false, allocator, &rects);
        try std.testing.expectEqual(@as(usize, 1), rects.items.len);
        try std.testing.expectEqual(@as(f64, @floatFromInt(width)), rects.items[0].width);
        try std.testing.expectEqual(@as(f64, @floatFromInt(height)), rects.items[0].height);
        try std.testing.expectEqual(@as(f64, @floatFromInt(bounds.x)), rects.items[0].x);
        try std.testing.expectEqual(@as(f64, @floatFromInt(bounds.y)), rects.items[0].y);
        try std.testing.expect(!self.document.?.layoutNeeded());
    }
};

fn load(node: *parser.Node, width: usize, height: usize) !void {
    const pixels = try @import("zigimg").Image.create(allocator, width, height, .rgba32);
    @memset(pixels.pixels.rgba32, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
    node.element.image_data = .{ .encoded_bytes = null, .image = pixels };
}

test "replaced image min max constraints agree for inline and block geometry" {
    for ([_][]const u8{ "inline", "block" }) |display| {
        const html = try std.fmt.allocPrint(allocator, "<main style='display:block;width:200px;height:100px'><img style='display:{s};max-width:50%;max-height:100%;height:1000px'></main>", .{display});
        defer allocator.free(html);
        var page = try Page.init(html);
        defer page.deinit();
        const node = &page.root.element.children.items[0];
        try load(node, 400, 200);
        try page.render();
        try page.expectBox(node, 100, 100);
    }
}

test "replaced image natural size honors both caps and flex centers the painted box" {
    var page = try Page.init("<main style='display:flex;width:1000px;justify-content:center;padding:25px'><img style='max-width:580px;max-height:250px;object-fit:contain'></main>");
    defer page.deinit();
    const node = &page.root.element.children.items[0];
    try load(node, 1920, 461);
    try page.render();
    try page.expectBox(node, 580, 139);
    const parent = page.document.?.children.items[0];
    const box = page.engine.image_bounds.get(node).?;
    try std.testing.expectEqual(parent.x.get().* + 25 + 210, box.x);
    const commands = try page.engine.paintDocument(page.document.?);
    defer DisplayItem.freeList(allocator, commands);
    try std.testing.expect(hasImageBox(commands, node, 580, 139));

    // Reflow follows a height constraint through intrinsic width measurement;
    // this is not merely a repaint or a clamped hit rectangle.
    node.element.style.?.getPtr("max-height").?.set("100px");
    try std.testing.expect(page.document.?.layoutNeeded());
    try page.document.?.layout(page.engine);
    try page.expectBox(node, 416, 100);
    try std.testing.expectEqual(parent.x.get().* + 25 + 292, page.engine.image_bounds.get(node).?.x);
}

fn hasImageBox(items: []const DisplayItem, node: *parser.Node, width: i32, height: i32) bool {
    for (items) |item| switch (item) {
        .image => |image| if (image.source) |source| {
            if (source.node == node) if (image.hit_rect) |rect| {
                if (rect.width() == width and rect.height() == height and image.x1 >= rect.left and image.x2 <= rect.right and image.y1 >= rect.top and image.y2 <= rect.bottom) return true;
            };
        },
        .cached_subtree => |cached| if (hasImageBox(cached.list.items, node, width, height)) return true,
        .transform => |group| if (hasImageBox(group.children, node, width, height)) return true,
        .blend => |group| if (hasImageBox(group.children, node, width, height)) return true,
        else => {},
    };
    return false;
}

test "replaced image border box constraints count edges once under nested zoom" {
    for ([_][]const u8{ "inline", "block" }) |display| {
        const html = try std.fmt.allocPrint(allocator, "<main style='display:block;width:500px;zoom:2'><img style='display:{s};zoom:1.5;padding:5px;border:5px solid;box-sizing:border-box;width:200px;max-width:120px'></main>", .{display});
        defer allocator.free(html);
        var page = try Page.init(html);
        defer page.deinit();
        const node = &page.root.element.children.items[0];
        try load(node, 400, 200);
        try page.render();
        try page.expectBox(node, 360, 210);
    }
}

test "replaced image flex shrink changes the auto height and percentage cap uses the container" {
    var page = try Page.init("<main style='display:flex;width:200px'><img style='min-width:0;max-width:100%'><div style='width:100px;flex-shrink:0'></div></main>");
    defer page.deinit();
    const node = &page.root.element.children.items[0];
    try load(node, 400, 200);
    try page.render();
    try page.expectBox(node, 100, 50);
}

test "replaced image unresolved percentage height keeps its natural ratio" {
    var page = try Page.init("<main style='display:block;width:100px'><img style='height:100%;max-width:100%;max-height:50%'></main>");
    defer page.deinit();
    const node = &page.root.element.children.items[0];
    try load(node, 200, 200);
    try page.render();
    try page.expectBox(node, 100, 100);
}

test "replaced block image percentage padding uses its parent once" {
    var page = try Page.init("<main style='display:block;width:400px'><img style='display:block;width:100px;padding:10%'></main>");
    defer page.deinit();
    const node = &page.root.element.children.items[0];
    try load(node, 400, 200);
    try page.render();
    try page.expectBox(node, 180, 130);
}

test "replaced block image percentage height skips inline wrappers but not auto height blocks" {
    for ([_][]const u8{ "inline", "block" }) |display| {
        const html = try std.fmt.allocPrint(allocator, "<main style='display:block;width:200px;height:100px'><span style='display:{s}'><img style='display:block;max-width:100px;height:1000px;max-height:100%'></span></main>", .{display});
        defer allocator.free(html);
        var page = try Page.init(html);
        defer page.deinit();
        const node = &page.root.element.children.items[0].element.children.items[0];
        try load(node, 1, 1);
        try page.render();
        try page.expectBox(node, 100, if (std.mem.eql(u8, display, "inline")) 100 else 1000);
    }
}
