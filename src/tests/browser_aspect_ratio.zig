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
