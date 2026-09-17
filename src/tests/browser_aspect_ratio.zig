//! Replaced-element layout regressions for the CSS `aspect-ratio` property.

const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const document = @import("../document/parser.zig");

fn findNodeById(node: *document.Node, id: []const u8) ?*document.Node {
    return switch (node.*) {
        .text => null,
        .element => |*element| blk: {
            if (element.attributes) |attributes| {
                if (attributes.get("id")) |candidate| {
                    if (std.mem.eql(u8, candidate, id)) break :blk node;
                }
            }
            for (element.children.items) |*child| {
                if (findNodeById(child, id)) |found| break :blk found;
            }
            break :blk null;
        },
    };
}

fn iframeBounds(layout: *const Layout, node: *document.Node) ?Layout.Bounds {
    for (layout.iframe_bounds.items) |entry| {
        if (entry.node == node) return entry.bounds;
    }
    return null;
}

test "aspect-ratio supplies missing image and iframe layout dimensions" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(
        allocator,
        "<main>" ++
            "<img id=lazy loading=lazy src=lazy.ppm width=160 style='aspect-ratio: 16 / 9'>" ++
            "<br><iframe id=wide width=100 style='width: 320px; aspect-ratio: 16 / 9'></iframe>" ++
            "<br><iframe id=tall style='height: 180px; aspect-ratio: 16 / 9'></iframe>" ++
            "<br><iframe id=both width=400 height=75 style='aspect-ratio: 1 / 1'></iframe>" ++
            "</main>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});

    const lazy = findNodeById(&root, "lazy").?;
    const wide = findNodeById(&root, "wide").?;
    const tall = findNodeById(&root, "tall").?;
    const both = findNodeById(&root, "both").?;

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const layout = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer layout.deinit();
    const document_layout = try layout.buildDocument(&root);
    defer {
        document_layout.deinit();
        allocator.destroy(document_layout);
    }

    const lazy_box = layout.image_bounds.get(lazy).?;
    try std.testing.expectEqual(@as(i32, 160), lazy_box.width);
    try std.testing.expectEqual(@as(i32, 90), lazy_box.height);

    const wide_box = iframeBounds(layout, wide).?;
    try std.testing.expectEqual(@as(i32, 320), wide_box.width);
    try std.testing.expectEqual(@as(i32, 180), wide_box.height);

    const tall_box = iframeBounds(layout, tall).?;
    try std.testing.expectEqual(@as(i32, 320), tall_box.width);
    try std.testing.expectEqual(@as(i32, 180), tall_box.height);

    // Two specified dimensions override the preferred ratio.
    const both_box = iframeBounds(layout, both).?;
    try std.testing.expectEqual(@as(i32, 400), both_box.width);
    try std.testing.expectEqual(@as(i32, 75), both_box.height);

    // The used ratio participates in the persistent layout dependency graph.
    wide.element.style.?.getPtr("aspect-ratio").?.set("4 / 3");
    try std.testing.expect(document_layout.layoutNeeded());
    try document_layout.layout(layout);
    const updated_wide_box = iframeBounds(layout, wide).?;
    try std.testing.expectEqual(@as(i32, 320), updated_wide_box.width);
    try std.testing.expectEqual(@as(i32, 240), updated_wide_box.height);
}

fn blockById(block: anytype, id: []const u8) ?@TypeOf(block) {
    if (block.node_ptr) |node| if (node.* == .element) {
        if (node.element.attributes) |attributes| if (attributes.get("id")) |value| {
            if (std.mem.eql(u8, value, id)) return block;
        };
    };
    for (block.children.items) |child| switch (child) {
        .block => |nested| if (blockById(nested, id)) |found| return found,
        .line => {},
    };
    return null;
}

test "aspect-ratio ordinary blocks size both axes, honor edges and invalidate" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(allocator, "<main style='display:block;width:320px'>" ++
        "<div id=fraction style='display:block;width:100px;aspect-ratio:.00025/.0001'></div>" ++
        "<div id=auto style='display:block;aspect-ratio:1.6'><div id=percent style='display:block;height:50%'></div></div>" ++
        "<div id=reverse style='display:block;height:50px;aspect-ratio:2;box-sizing:border-box;padding-top:25px'></div>" ++
        "<div id=border style='display:block;width:100px;aspect-ratio:2;box-sizing:border-box;padding-left:50px'></div>" ++
        "<div id=fallback style='display:block;width:100px;aspect-ratio:auto 1;box-sizing:border-box;padding-left:50px'></div>" ++
        "<div id=both style='display:block;width:90px;height:30px;aspect-ratio:1'></div>" ++
        "<div id=limited style='display:block;width:100px;aspect-ratio:1;max-height:60px'></div>" ++
        "<div id=content style='display:block;width:50px;aspect-ratio:1'><div style='display:block;height:90px'></div></div>" ++
        "<div id=overflow style='display:block;width:50px;aspect-ratio:1;overflow:auto'><div style='display:block;height:90px'></div></div>" ++
        "<div id=zero style='display:block;width:50px;aspect-ratio:1;min-height:0'><div style='display:block;height:90px'></div></div>" ++
        "</main>");
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const layout = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer layout.deinit();
    const doc = try layout.buildDocument(&root);
    defer {
        doc.deinit();
        allocator.destroy(doc);
    }
    for ([_]struct { id: []const u8, width: i32, height: i32 }{
        .{ .id = "fraction", .width = 100, .height = 40 },
        .{ .id = "auto", .width = 320, .height = 200 },
        .{ .id = "percent", .width = 320, .height = 100 },
        .{ .id = "reverse", .width = 100, .height = 50 },
        .{ .id = "border", .width = 100, .height = 50 },
        .{ .id = "fallback", .width = 100, .height = 50 },
        .{ .id = "both", .width = 90, .height = 30 },
        .{ .id = "limited", .width = 100, .height = 60 },
        .{ .id = "content", .width = 50, .height = 90 },
        .{ .id = "overflow", .width = 50, .height = 50 },
        .{ .id = "zero", .width = 50, .height = 50 },
    }) |case| {
        const block = blockById(doc.children.items[0], case.id) orelse {
            std.debug.print("missing block: {s}\n", .{case.id});
            return error.MissingBlock;
        };
        try std.testing.expectEqual(case.width, block.width.get().*);
        try std.testing.expectEqual(case.height, block.height.get().*);
    }
    const fraction = findNodeById(&root, "fraction").?;
    fraction.element.style.?.getPtr("aspect-ratio").?.set("1 / 1");
    try std.testing.expect(doc.layoutNeeded());
    try doc.layout(layout);
    try std.testing.expectEqual(@as(i32, 100), blockById(doc.children.items[0], "fraction").?.height.get().*);
}
