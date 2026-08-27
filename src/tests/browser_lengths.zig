//! CSS relative-length regressions for font inheritance and containing blocks.

const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const document = @import("../document/parser.zig");

fn findNodeById(node: *document.Node, id: []const u8) ?*document.Node {
    return switch (node.*) {
        .text => null,
        .element => |*element| blk: {
            if (element.attributes) |attributes| {
                if (std.mem.eql(u8, attributes.get("id") orelse "", id)) break :blk node;
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

test "font relative sizes become computed pixels before inheritance" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(
        allocator,
        "<div style='font-size: 20px'><span style='font-size: 1.5em'>child</span></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);

    try document.style(allocator, &root, &.{});
    const child = &root.element.children.items[0].element;
    try std.testing.expectEqualStrings(
        "30.0px",
        child.style.?.getPtr("font-size").?.get().*,
    );
}

test "em and percentage dimensions resolve for iframe replaced boxes" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(
        allocator,
        "<main style='width: 400px; height: 200px; font-size: 20px'>" ++
            "<section style='display: block'></section>" ++
            "<iframe id=em-box style='width: 10em; height: 2em'></iframe>" ++
            "<iframe id=percent-box style='width: 50%; height: 25%'></iframe>" ++
            "</main>",
    );
    html_parser.use_implicit_tags = false;
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
    const document_layout = try layout.buildDocument(&root);
    defer {
        document_layout.deinit();
        allocator.destroy(document_layout);
    }

    const em_node = findNodeById(&root, "em-box").?;
    const percent_node = findNodeById(&root, "percent-box").?;
    const em_bounds = iframeBounds(layout, em_node).?;
    try std.testing.expectEqual(@as(i32, 200), em_bounds.width);
    try std.testing.expectEqual(@as(i32, 40), em_bounds.height);

    const percent_bounds = iframeBounds(layout, percent_node).?;
    try std.testing.expectEqual(@as(i32, 200), percent_bounds.width);
    try std.testing.expectEqual(@as(i32, 50), percent_bounds.height);
}
