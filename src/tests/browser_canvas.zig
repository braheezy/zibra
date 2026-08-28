//! Canvas DOM bindings, backing-store behavior, and render-snapshot ownership.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Layout = @import("../browser/render/layout.zig").Layout;
const RasterSnapshot = @import("../browser/render/raster_snapshot.zig").RasterSnapshot;
const parser = @import("../document/parser.zig");
const Js = @import("../script/js.zig");

fn findElement(node: *parser.Node, tag: []const u8) ?*parser.Node {
    switch (node.*) {
        .text => return null,
        .element => |*element| {
            if (std.ascii.eqlIgnoreCase(element.tag, tag)) return node;
            for (element.children.items) |*child| {
                if (findElement(child, tag)) |match| return match;
            }
            return null;
        },
    }
}

fn findCanvasDisplayItem(items: []const browser.DisplayItem) ?*const browser.CanvasDisplayItem {
    for (items) |*item| {
        switch (item.*) {
            .cached_subtree => |cached| if (findCanvasDisplayItem(cached.list.items)) |found| return found,
            .canvas => |*canvas_item| return canvas_item,
            .blend => |blend| if (findCanvasDisplayItem(blend.children)) |found| return found,
            .transform => |transform| if (findCanvasDisplayItem(transform.children)) |found| return found,
            else => {},
        }
    }
    return null;
}

const RenderCounter = struct {
    count: usize = 0,

    fn callback(context: ?*anyopaque) anyerror!void {
        const raw = context orelse return;
        const unaligned: *align(1) RenderCounter = @ptrCast(raw);
        const self: *RenderCounter = @alignCast(unaligned);
        self.count += 1;
    }
};

test "2d canvas context draws, keeps identity, and tolerates unsupported calls" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><canvas id=board width=8 height=6></canvas><div id=other></div></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    const js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);
    var renders = RenderCounter{};
    js.setRenderCallback(0, RenderCounter.callback, &renders);

    const first = try js.evaluate(0,
        \\var canvas = document.querySelectorAll('canvas')[0];
        \\var other = document.querySelectorAll('div')[0];
        \\var context = canvas.getContext('2d');
        \\var sameContext = context === canvas.getContext('2d');
        \\context.fillStyle = '#ff0000ff';
        \\context.globalAlpha = 0.5;
        \\context.fillRect(1, 1, 5, 4);
        \\context.clearRect(2, 2, 2, 2);
        \\sameContext && context.canvas.handle === canvas.handle &&
        \\canvas.width === 8 && canvas.height === 6 &&
        \\canvas.getContext('webgl') === null && other.getContext('2d') === null
    );
    try std.testing.expect(first.toBoolean());
    try std.testing.expect(renders.count >= 2);

    const canvas_node = findElement(&root, "canvas").?;
    const backing = canvas_node.element.canvas.?;
    const first_pixels = try backing.snapshot(allocator);
    defer allocator.free(first_pixels);
    const painted = (1 * 8 + 1) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, first_pixels[painted..][0..4]);
    const cleared = (2 * 8 + 2) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, first_pixels[cleared..][0..4]);

    const reset = try js.evaluate(0,
        \\context.fillStyle = 'blue';
        \\context.strokeStyle = 'yellow';
        \\context.lineWidth = 9;
        \\context.globalAlpha = 0.25;
        \\canvas.width = canvas.width;
        \\context.fillStyle === '#000000' && context.strokeStyle === '#000000' &&
        \\context.lineWidth === 1 && context.globalAlpha === 1
    );
    try std.testing.expect(reset.toBoolean());
    const reset_pixels = try backing.snapshot(allocator);
    defer allocator.free(reset_pixels);
    try std.testing.expectEqual(@as(usize, 8 * 6 * 4), reset_pixels.len);
    try std.testing.expect(std.mem.allEqual(u8, reset_pixels, 0));

    const second = try js.evaluate(0,
        \\// drawImage is an intentional native error.NotImplemented stub.
        \\context.drawImage(null, 0, 0);
        \\canvas.width = 4;
        \\canvas.height = 3;
        \\context.globalAlpha = 1;
        \\context.fillStyle = 'green';
        \\context.fillRect(0, 0, 4, 3);
        \\canvas.width === 4 && canvas.height === 3
    );
    try std.testing.expect(second.toBoolean());
    try std.testing.expectEqual(@as(i32, 4), backing.width);
    try std.testing.expectEqual(@as(i32, 3), backing.height);
    const resized_pixels = try backing.snapshot(allocator);
    defer allocator.free(resized_pixels);
    try std.testing.expectEqual(@as(usize, 4 * 3 * 4), resized_pixels.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 255 }, resized_pixels[0..4]);
}

test "canvas dimensions use HTML defaults and reject invalid attributes" {
    const allocator = std.testing.allocator;
    var defaults = try parser.Element.init(allocator, "canvas", null);
    defer defaults.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 300), defaults.canvasDimensions().width);
    try std.testing.expectEqual(@as(i32, 150), defaults.canvasDimensions().height);

    var invalid = try parser.Element.init(allocator, "canvas width=-2 height=nope", null);
    defer invalid.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 300), invalid.canvasDimensions().width);
    try std.testing.expectEqual(@as(i32, 150), invalid.canvasDimensions().height);

    var zero = try parser.Element.init(allocator, "canvas width=0 height=0", null);
    defer zero.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 0), zero.canvasDimensions().width);
    try std.testing.expectEqual(@as(i32, 0), zero.canvasDimensions().height);
}

test "an existing layout observes a backing store created by later script" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><canvas width=3 height=2></canvas></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    try parser.style(allocator, &root, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const layout = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer layout.deinit();
    const document = try layout.buildDocument(&root);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    const before = try layout.paintDocument(document);
    const lazy_item = findCanvasDisplayItem(before).?;
    try std.testing.expectEqual(@as(usize, 0), lazy_item.pixels.len);
    browser.DisplayItem.freeList(allocator, before);

    const js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);
    _ = try js.evaluate(0,
        \\var canvas = document.querySelectorAll('canvas')[0];
        \\var context = canvas.getContext('2d');
        \\context.fillStyle = 'red';
        \\context.fillRect(0, 0, 3, 2);
    );

    const after = try layout.paintDocument(document);
    defer browser.DisplayItem.freeList(allocator, after);
    const painted_item = findCanvasDisplayItem(after).?;
    try std.testing.expectEqual(@as(usize, 3 * 2 * 4), painted_item.pixels.len);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, painted_item.pixels[0..4]);
}

test "raster snapshot owns canvas pixels independently" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.dupe(u8, &.{ 10, 20, 30, 255 });
    const items = try allocator.alloc(browser.DisplayItem, 1);
    items[0] = .{ .canvas = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 1,
        .y2 = 1,
        .source_width = 1,
        .source_height = 1,
        .pixels = pixels,
        .owns_pixels = true,
    } };
    defer browser.DisplayItem.freeList(allocator, items);

    var snapshot = try RasterSnapshot.clone(allocator, items);
    defer snapshot.deinit();
    items[0].canvas.pixels[0] = 99;

    try std.testing.expectEqual(@as(u8, 10), snapshot.items[0].canvas.pixels[0]);
    try std.testing.expect(snapshot.items[0].canvas.owns_pixels);
    try std.testing.expect(snapshot.items[0].canvas.source == null);
}
