//! Live SVG cascade, retained-paint, and independent snapshot regressions.
const std = @import("std");
const dom = @import("../document/parser.zig");
const CSSParser = @import("../document/css_parser.zig");
const svg = @import("../browser/render/svg.zig");
const svg_inline = @import("../browser/render/svg_inline.zig");
const svg_animation = @import("../document/svg_animation.zig");
const tab_animation = @import("../browser/tab_animation.zig");
const Layout = @import("../browser/render/layout.zig");
const display = @import("../browser/render/display_list.zig");
const retained = @import("../browser/render/retained_commands.zig");
const allocator = std.testing.allocator;

fn find(node: *dom.Node, id: []const u8) ?*dom.Node {
    if (node.* != .element) return null;
    if (node.element.attributes) |attrs| if (attrs.get("id")) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.element.children.items) |*child| if (find(child, id)) |result| return result;
    return null;
}

fn canvas(items: []const display.DisplayItem) ?display.CanvasDisplayItem {
    for (items) |item| switch (item) {
        .canvas => |value| return value,
        .cached_subtree => |cached| if (canvas(cached.list.items)) |value| return value,
        .blend => |group| if (canvas(group.children)) |value| return value,
        .transform => |group| if (canvas(group.children)) |value| return value,
        else => {},
    };
    return null;
}

fn canvasAlpha(items: []const display.DisplayItem, multiplier: f64) ?f64 {
    for (items) |item| switch (item) {
        .canvas => |value| return multiplier * @as(f64, @floatFromInt(value.pixels[3])) / 255,
        .cached_subtree => |cached| if (canvasAlpha(cached.list.items, multiplier)) |value| return value,
        .blend => |group| if (canvasAlpha(group.children, multiplier * group.opacity)) |value| return value,
        .transform => |group| if (canvasAlpha(group.children, multiplier)) |value| return value,
        else => {},
    };
    return null;
}

test "SVG intrinsic measurement preserves constrained image siblings and derived SVG width" {
    var html = try dom.HTMLParser.init(allocator, "<main id='row'><img width='200' height='100' style='max-width:40px'>" ++
        "<svg id='icon' height='20' viewBox='0 0 60 20'><rect width='60' height='20'/></svg></main>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    dom.fixParentPointers(&root, null);
    try dom.style(allocator, &root, &.{});
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const intrinsic = @import("../browser/render/intrinsic_width.zig");
    for ([_]f64{ 1, 1.5 }) |scale| {
        const icon = try intrinsic.measure(find(&root, "icon").?, &engine.font_manager, scale);
        try std.testing.expectEqual(60 * scale, icon.min);
        try std.testing.expectEqual(60 * scale, icon.max);
        const row = try intrinsic.measureContent(find(&root, "row").?, &engine.font_manager, scale);
        try std.testing.expectEqual(60 * scale, row.min);
        try std.testing.expectEqual(100 * scale, row.max);
    }
}

test "SVG inline and block roots apply sampled opacity exactly once" {
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    for ([_][]const u8{ "inline", "block" }) |mode| {
        const source = try std.fmt.allocPrint(allocator, "<main><svg id='icon' width='20' height='20' style='display:{s};opacity:.25'>" ++
            "<animate attributeName='opacity' from='.25' to='.75' dur='1s'/><rect width='20' height='20' fill='red'/></svg></main>", .{mode});
        defer allocator.free(source);
        var html = try dom.HTMLParser.init(allocator, source);
        defer html.deinit(allocator);
        var root = try html.parse();
        defer root.deinit(allocator);
        dom.fixParentPointers(&root, null);
        try dom.style(allocator, &root, &.{});
        try svg_animation.sample(allocator, &find(&root, "icon").?.element, 0.5);
        const document = try engine.buildDocument(&root);
        defer {
            document.deinit();
            allocator.destroy(document);
        }
        const commands = try engine.paintDocument(document);
        defer display.DisplayItem.freeList(allocator, commands);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), canvasAlpha(commands, 1).?, 0.003);
    }
}

test "SVG inline CSS cascade, symbol inheritance and DOM repaint preserve old snapshots" {
    var html = try dom.HTMLParser.init(allocator, "<main><svg id='icon' width='40' height='20' viewBox='0 0 40 20'>" ++
        "<defs><symbol id='tile' viewBox='0 0 10 10'><rect width='10' height='10'/></symbol></defs>" ++
        "<use href='#tile' width='20' height='20' fill='red'/>" ++
        "<rect id='shape' x='20' width='20' height='20' fill='red'/></svg></main>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    dom.fixParentPointers(&root, null);
    var css = try CSSParser.init(allocator, "#shape { fill: blue; }", false);
    defer css.deinit(allocator);
    const rules = try css.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try dom.style(allocator, &root, rules);
    const icon = &find(&root, "icon").?.element;
    var raster = try svg.render(allocator, std.testing.io, icon, .{});
    defer raster.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, raster.rawBytes()[(10 * 40 + 5) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, raster.rawBytes()[(10 * 40 + 25) * 4 ..][0..4]);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&root);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const commands = try engine.paintDocument(document);
    defer display.DisplayItem.freeList(allocator, commands);
    const old = try retained.cloneList(allocator, commands);
    defer display.DisplayItem.freeList(allocator, old);
    const painted = canvas(old).?;
    try std.testing.expectEqual(@as(i32, 40), painted.x2 - painted.x1);
    try std.testing.expectEqual(@as(i32, 20), painted.y2 - painted.y1);
    const shape = &find(&root, "shape").?.element;
    try shape.attributes.?.put("style", "fill: green");
    dom.dirtyStyleForElement(shape);
    try dom.style(allocator, &root, rules);
    try document.layout(engine);
    const updated = try engine.paintDocument(document);
    defer display.DisplayItem.freeList(allocator, updated);
    const fresh = canvas(updated).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 255 }, fresh.pixels[(10 * 40 + 25) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, painted.pixels[(10 * 40 + 25) * 4 ..][0..4]);
}

test "SVG percentage width resolves the omitted height through its viewBox ratio" {
    var html = try dom.HTMLParser.init(allocator, "<svg id='icon' width='100%' viewBox='0 0 40 20'></svg>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    dom.fixParentPointers(&root, null);
    try dom.style(allocator, &root, &.{});
    const icon = &find(&root, "icon").?.element;
    const dimensions = svg_inline.size(icon, .{ .percentage_width = 600 });
    try std.testing.expectEqual(@as(i32, 600), dimensions.width);
    try std.testing.expectEqual(@as(i32, 300), dimensions.height);
}

test "SVG timeline shares nested time, invalidates viewport size and clears removed tracks" {
    var html = try dom.HTMLParser.init(allocator, "<svg id='icon' width='40' height='20'>" ++
        "<animate id='grow' attributeName='width' from='40' to='80' dur='2s' fill='freeze'/>" ++
        "<animate attributeName='fill' from='red' to='blue' dur='2s' fill='freeze'/>" ++
        "<svg id='nested'><circle id='circle' cx='0' cy='10' r='2'><animate attributeName='cx' from='0' to='10' dur='2s' fill='freeze'/></circle></svg></svg>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    dom.fixParentPointers(&root, null);
    try dom.style(allocator, &root, &.{});
    const Effects = struct {
        layouts: usize = 0,
        paints: usize = 0,
        fn publish(_: *anyopaque, _: tab_animation.CompositedUpdate) void {}
        fn layout(context: *anyopaque, _: *dom.Element) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.layouts += 1;
        }
        fn paint(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.paints += 1;
        }
    };
    var effects = Effects{};
    var sink = tab_animation.Sink{ .now_seconds = 100, .allocator = allocator, .context = &effects, .publish_composited = Effects.publish, .mark_layout = Effects.layout, .request_paint = Effects.paint };
    try std.testing.expect(tab_animation.advance(sink, &root));
    sink.now_seconds = 101;
    try std.testing.expect(tab_animation.advance(sink, &root));
    const icon = &find(&root, "icon").?.element;
    try std.testing.expectEqual(@as(i32, 60), svg_inline.size(icon, .{}).width);
    try std.testing.expect(find(&root, "nested").?.element.svg_epoch_seconds == null);
    try std.testing.expectEqualStrings("5", find(&root, "circle").?.element.svg_animation.?.values.get("cx").?);
    sink.now_seconds = 102;
    try std.testing.expect(!tab_animation.advance(sink, &root));
    try std.testing.expect(!tab_animation.hasActive(&root));
    try std.testing.expectEqual(@as(i32, 80), svg_inline.size(icon, .{}).width);
    var raster = try svg.render(allocator, std.testing.io, icon, .{});
    defer raster.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, raster.rawBytes()[(10 * 80 + 10) * 4 ..][0..4]);
    try std.testing.expect(find(&root, "grow").?.element.attributes.?.orderedRemove("attributename"));
    try std.testing.expect(!tab_animation.advance(sink, &root));
    try std.testing.expectEqual(@as(i32, 40), svg_inline.size(icon, .{}).width);
    try std.testing.expectEqual(@as(usize, 4), effects.layouts);
    try std.testing.expectEqual(@as(usize, 4), effects.paints);
}

fn animationAllocationFailures(failing_allocator: std.mem.Allocator) !void {
    // Fail allocations in the sample owner; the existing HTML tree is input.
    var html = try dom.HTMLParser.init(allocator, "<svg><rect fill='red'><animate attributeName='fill' from='red' to='blue' dur='1s' fill='freeze'/><animateTransform attributeName='transform' type='translate' from='0 0' to='20 10' dur='1s'/></rect></svg>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    try svg_animation.sample(failing_allocator, &root.element, 0.5);
    try svg_animation.sample(failing_allocator, &root.element, 1);
}

test "SVG animation sample replacement releases strings on every allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, animationAllocationFailures, .{});
}

test "SVG discrete animations allocate equal intervals including the last value" {
    var html = try dom.HTMLParser.init(allocator, "<svg><rect id='shape'>" ++
        "<animate attributeName='fill' values='red;green;blue' calcMode='discrete' dur='3s' fill='freeze'/>" ++
        "<animate attributeName='visibility' from='hidden' to='visible' dur='3s' fill='freeze'/></rect></svg>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    const shape = &find(&root, "shape").?.element;
    for ([_]f64{ 0.5, 1.25, 2.5, 3 }, [_][]const u8{ "red", "green", "blue", "blue" }, [_][]const u8{ "hidden", "hidden", "visible", "visible" }) |seconds, fill, visibility| {
        try svg_animation.sample(allocator, &root.element, seconds);
        try std.testing.expectEqualStrings(fill, shape.svg_animation.?.values.get("fill").?);
        try std.testing.expectEqualStrings(visibility, shape.svg_animation.?.values.get("visibility").?);
    }
}
