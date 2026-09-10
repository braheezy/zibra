//! Native CSS inspection through retained layout, display commands and software
//! raster, retiring rendering borrowers before each stylesheet publication.

const std = @import("std");
const z2d = @import("z2d");
const inspection = @import("../document/inspection.zig");
const dom = @import("../document/dom.zig");
const Layout = @import("../browser/render/layout.zig");
const geometry = @import("../browser/render/element_geometry.zig");
const display = @import("../browser/render/display_list.zig");
const Renderer = @import("../browser/software_renderer.zig").Renderer;
const Compositor = @import("../browser/display_compositor.zig").Compositor;
const allocator = std.testing.allocator;

fn findById(node: *dom.Node, id: []const u8) ?*dom.Node {
    switch (node.*) {
        .text => return null,
        .element => |*element| {
            if (element.attributes) |attributes| {
                if (attributes.get("id")) |actual| {
                    if (std.mem.eql(u8, actual, id)) return node;
                }
            }
            for (element.children.items) |*child| {
                if (findById(child, id)) |match| return match;
            }
        },
    }
    return null;
}

fn coloredBox(items: []const display.DisplayItem, color: display.Color, dx: i32, dy: i32) ?display.Rect {
    for (items) |item| {
        const found: ?display.Rect = switch (item) {
            .cached_subtree => |cached| coloredBox(cached.list.items, color, dx, dy),
            .blend => |group| coloredBox(group.children, color, dx, dy),
            .transform => |group| coloredBox(group.children, color, dx + group.translate_x, dy + group.translate_y),
            inline .rect, .rounded_rect => |rect| if (std.meta.eql(rect.color, color)) .{
                .left = rect.x1 + dx,
                .top = rect.y1 + dy,
                .right = rect.x2 + dx,
                .bottom = rect.y2 + dy,
            } else null,
            else => null,
        };
        if (found) |bounds| return bounds;
    }
    return null;
}

/// All source-bearing commands and layout objects retire before this returns.
/// The caller can then replace rules/source and rebuild a fresh render tree.
fn expectRenderedBox(page: *inspection.Page, engine: *Layout, width: i32, height: i32, color: display.Color) !void {
    const document = try engine.buildDocument(&page.root);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const target = findById(&page.root, "target").?;
    var rects = std.ArrayList(geometry.Rect).empty;
    defer rects.deinit(allocator);
    try geometry.collect(document, target, 1, 0, false, allocator, &rects);
    try std.testing.expectEqual(@as(usize, 1), rects.items.len);
    try std.testing.expectEqual(@as(f64, @floatFromInt(width)), rects.items[0].width);
    try std.testing.expectEqual(@as(f64, @floatFromInt(height)), rects.items[0].height);

    const commands = try engine.paintDocument(document);
    defer display.DisplayItem.freeList(allocator, commands);
    const painted = coloredBox(commands, color, 0, 0) orelse return error.MissingBoxPaint;
    try std.testing.expectEqual(width, painted.width());
    try std.testing.expectEqual(height, painted.height());
    try std.testing.expectEqual(rects.items[0].x, @as(f64, @floatFromInt(painted.left)));
    try std.testing.expectEqual(rects.items[0].y, @as(f64, @floatFromInt(painted.top)));

    var bounds = Compositor.init(allocator);
    defer bounds.deinit();
    var renderer = Renderer.init(allocator, allocator, std.testing.io, &bounds);
    var surface = try z2d.Surface.init(.image_surface_rgba, allocator, 1024, 128);
    defer surface.deinit(allocator);
    const pixels = switch (surface) {
        .image_surface_rgba => |*rgba| rgba.buf,
        else => unreachable,
    };
    @memset(pixels, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    var context = z2d.Context.init(std.testing.io, allocator, &surface);
    defer context.deinit();
    for (commands) |command| try renderer.drawDisplayItemZ2dContext(&context, command, 0, 1);
    const x = painted.left + @divTrunc(width, 2);
    const y = painted.top + @divTrunc(height, 2);
    try std.testing.expect(x >= 0 and x < 1024 and y >= 0 and y < 128);
    const center: usize = @intCast(y * 1024 + x);
    try std.testing.expectEqual(color.toZ2dRgba(), pixels[center]);
    try std.testing.expect(!document.layoutNeeded());
}

test "Native CSS inspection repaints real geometry and pixels after responsive selection and source replacement" {
    const html = "<style>#target { display:block; width:40px; height:20px; background-color:green; }" ++
        "@media (min-width:600px) { #target { width:80px; height:30px; background-color:blue; } }</style>" ++
        "<div id=target></div>";
    var page = try inspection.Page.fromHtml(allocator, html, .{
        .media = .{ .viewport_width_css = 400, .viewport_height_css = 600 },
    });
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 600, false);
    defer engine.deinit();
    const retained_source = page.sheetSource(1);
    try expectRenderedBox(&page, engine, 40, 20, .{ .r = 0, .g = 128, .b = 0 });

    try page.reselectMedia(.{ .viewport_width_css = 800, .viewport_height_css = 600 });
    try std.testing.expectEqual(retained_source.ptr, page.sheetSource(1).ptr);
    try page.restyle();
    engine.window_width = 800;
    try expectRenderedBox(&page, engine, 80, 30, .{ .r = 0, .g = 0, .b = 255 });

    try page.replaceStylesheet(1, "#target { display:block; width:55px; height:25px; background-color:red; }");
    try page.restyle();
    try expectRenderedBox(&page, engine, 55, 25, .{ .r = 255, .g = 0, .b = 0 });
}
