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

fn gradientImage(items: []const display.DisplayItem) ?display.ImageDisplayItem {
    for (items) |item| {
        const found = switch (item) {
            .cached_subtree => |cache| gradientImage(cache.list.items),
            .blend => |group| gradientImage(group.children),
            .transform => |group| gradientImage(group.children),
            .image => |image| if (image.gradient != null) image else null,
            else => null,
        };
        if (found != null) return found;
    }
    return null;
}

test "CSS gradient currentcolor repaints retained geometry while old snapshots stay independent" {
    var page = try inspection.Page.fromHtml(allocator, "<body><section id=parent style='color:red'>" ++
        "<div id=target style='display:block;width:100px;height:20px;border:2px solid black;background:linear-gradient(to right,currentcolor,blue)'></div>" ++
        "</section></body>", .{});
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&page.root);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    var snapshot = blk: {
        const commands = try engine.paintDocument(document);
        defer display.DisplayItem.freeList(allocator, commands);
        const image = gradientImage(commands) orelse return error.MissingGradientPaint;
        try std.testing.expectEqual(@as(i32, 100), image.tiling.?.width);
        try std.testing.expectEqual(@as(i32, 2), image.tiling.?.offset_x);
        try std.testing.expectEqual(@as(u8, 255), image.gradient.?.sample(0, 0, 1).r);
        break :blk try @import("../browser/render/raster_snapshot.zig").RasterSnapshot.clone(allocator, commands);
    };
    defer snapshot.deinit();
    const parent = &findById(&page.root, "parent").?.element;
    const block = try @import("../document/css_declaration_block.zig").create(allocator, "color:lime");
    parent.replaceInlineStyle(allocator, block) catch |err| {
        block.destroy();
        return err;
    };
    dom.dirtyStyleForElement(parent);
    try page.restyle();
    try std.testing.expect(!document.layoutNeeded());
    const commands = try engine.paintDocument(document);
    defer display.DisplayItem.freeList(allocator, commands);
    const current = gradientImage(commands).?.gradient.?;
    try std.testing.expectEqual(@as(u8, 255), current.sample(0, 0, 1).g);
    const old = gradientImage(snapshot.items).?;
    try std.testing.expect(old.source == null);
    try std.testing.expectEqual(@as(u8, 255), old.gradient.?.sample(0, 0, 1).r);
}

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

test "CSS modern color spaces reach currentcolor paint and software pixels after source replacement" {
    var page = try inspection.Page.fromHtml(
        allocator,
        "<style>@supports (color:oklch(60% .2 30)){#target{width:40px;height:20px;" ++
            "--tone:oklch(51.975% .17686 142.495);color:var(--tone);background-color:currentcolor}}</style><div id=target></div>",
        .{},
    );
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 600, false);
    defer engine.deinit();
    try expectRenderedBox(&page, engine, 40, 20, .{ .r = 0, .g = 128, .b = 0 });

    try page.replaceStylesheet(1, "#target{width:40px;height:20px;background-color:color(display-p3 .21604 .49418 .13151)}");
    try page.restyle();
    try expectRenderedBox(&page, engine, 40, 20, .{ .r = 0, .g = 128, .b = 0 });
    try page.replaceStylesheet(1, "#target{width:40px;height:20px;font-size:20px;color:oklab(calc(1em / 40px) 0 0);background-color:currentcolor}");
    try page.restyle();
    try expectRenderedBox(&page, engine, 40, 20, .{ .r = 99, .g = 99, .b = 99 });
    try page.replaceStylesheet(1, "#target{width:40px;height:20px;font-size:10px;color:oklab(calc(1em / 40px) 0 0);background-color:currentcolor}");
    try page.restyle();
    try expectRenderedBox(&page, engine, 40, 20, .{ .r = 34, .g = 34, .b = 34 });
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

test "CSS supports activation reaches geometry and pixels across media and source replacement" {
    var page = try inspection.Page.fromHtml(allocator, "<style>#target{display:block;width:20px;height:20px;background:red}" ++
        "@supports (display:block) and selector(.card) {#target{width:40px;background:green}" ++
        "@media (min-width:600px){#target{width:80px;background:blue}}}" ++
        "@supports (unknown:1) {#target{width:999px;background:red}}" ++
        "@supports (color:red) or garbage {#target{background:red}}" ++
        "</style><div id=target class=card></div>", .{ .media = .{ .viewport_width_css = 400 } });
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 600, false);
    defer engine.deinit();
    try expectRenderedBox(&page, engine, 40, 20, .{ .r = 0, .g = 128, .b = 0 });
    try page.reselectMedia(.{ .viewport_width_css = 800 });
    try page.restyle();
    engine.window_width = 800;
    try expectRenderedBox(&page, engine, 80, 20, .{ .r = 0, .g = 0, .b = 255 });
    try page.replaceStylesheet(1, "#target{display:block;width:55px;height:25px;background:green}" ++
        "@supports selector(:is(.card, :unknown)){#target{width:999px;background:red}}" ++
        "@supports not (display:block){#target{width:999px;background:red}}");
    try page.restyle();
    try expectRenderedBox(&page, engine, 55, 25, .{ .r = 0, .g = 128, .b = 0 });
}

test "CSS escaped selectors and modern colors reach layout and software pixels after replacement" {
    var page = try inspection.Page.fromHtml(allocator, "<style>\\64 iv.sm\\:card[data-\\78='a\\20 b'] {display:block;width:40px;height:20px;background-color:rgb(0 50% 0);}</style>" ++
        "<div id=target class='sm:card' data-x='a b'></div>", .{});
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 600, false);
    defer engine.deinit();
    try expectRenderedBox(&page, engine, 40, 20, .{ .r = 0, .g = 128, .b = 0 });
    try page.replaceStylesheet(1, ".sm\\:card {display:block;width:50px;height:25px;background-color:hsl(.5turn 100% 50%);}");
    try page.restyle();
    try expectRenderedBox(&page, engine, 50, 25, .{ .r = 0, .g = 255, .b = 255 });
}

test "logical selector specificity reaches geometry and pixels across stylesheet replacement" {
    var page = try inspection.Page.fromHtml(allocator, "<style>.card {display:block;width:40px;height:20px;background:green}" ++
        ":where(#target) {width:99px;background:red}</style><div id=target class=card></div>", .{});
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 600, false);
    defer engine.deinit();
    try expectRenderedBox(&page, engine, 40, 20, .{ .r = 0, .g = 128, .b = 0 });
    try page.replaceStylesheet(1, ":is(#absent, body > .card):not(aside, .hidden) {display:block;width:60px;height:25px;background:blue}" ++
        ".card.card.card {width:99px;background:red}");
    try page.restyle();
    try expectRenderedBox(&page, engine, 60, 25, .{ .r = 0, .g = 0, .b = 255 });
}

test "CSS currentcolor repaints retained backgrounds after ancestor mutation" {
    var page = try inspection.Page.fromHtml(allocator, "<body><section id=parent style='color:green'>" ++
        "<div id=target style='display:block;width:40px;height:20px;color:currentcolor;background:currentcolor'></div>" ++
        "</section></body>", .{});
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&page.root);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const green = display.Color{ .r = 0, .g = 128, .b = 0 };
    const blue = display.Color{ .r = 0, .g = 0, .b = 255 };
    const first = blk: {
        const commands = try engine.paintDocument(document);
        defer display.DisplayItem.freeList(allocator, commands);
        break :blk coloredBox(commands, green, 0, 0) orelse return error.MissingBoxPaint;
    };
    try std.testing.expectEqual(@as(i32, 40), first.width());
    const parent = &findById(&page.root, "parent").?.element;
    const block = try @import("../document/css_declaration_block.zig").create(allocator, "color:blue");
    // Replacement takes ownership only after successful publication.
    parent.replaceInlineStyle(allocator, block) catch |err| {
        block.destroy();
        return err;
    };
    dom.dirtyStyleForElement(parent);
    try page.restyle();
    try std.testing.expect(!document.layoutNeeded());
    const commands = try engine.paintDocument(document);
    defer display.DisplayItem.freeList(allocator, commands);
    const second = coloredBox(commands, blue, 0, 0) orelse return error.MissingBoxPaint;
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expect(coloredBox(commands, green, 0, 0) == null);
}

test "CSS nested mixes repaint inherited currentcolor without rebuilding geometry" {
    var page = try inspection.Page.fromHtml(allocator, "<body><section id=parent style='color:red'>" ++
        "<div id=target style='display:block;width:40px;height:20px;background:color-mix(in srgb,currentcolor,color-mix(in srgb,white,black))'></div>" ++
        "</section></body>", .{});
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 600, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&page.root);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const red = display.Color{ .r = 191, .g = 64, .b = 64 };
    const blue = display.Color{ .r = 64, .g = 64, .b = 191 };
    const first = blk: {
        const commands = try engine.paintDocument(document);
        defer display.DisplayItem.freeList(allocator, commands);
        break :blk coloredBox(commands, red, 0, 0) orelse return error.MissingBoxPaint;
    };
    const parent = &findById(&page.root, "parent").?.element;
    const block = try @import("../document/css_declaration_block.zig").create(allocator, "color:blue");
    parent.replaceInlineStyle(allocator, block) catch |err| {
        block.destroy();
        return err;
    };
    dom.dirtyStyleForElement(parent);
    try page.restyle();
    try std.testing.expect(!document.layoutNeeded());
    const commands = try engine.paintDocument(document);
    defer display.DisplayItem.freeList(allocator, commands);
    try std.testing.expectEqualDeep(first, coloredBox(commands, blue, 0, 0) orelse return error.MissingBoxPaint);
    try std.testing.expect(coloredBox(commands, red, 0, 0) == null);
}

test "CSS background origin restyles retained paint without changing geometry" {
    var page = try inspection.Page.fromHtml(allocator, "<style>#target{display:block;width:100px;height:40px;padding:10px;border:4px solid transparent;" ++
        "background-image:linear-gradient(lime,lime);background-repeat:no-repeat}</style><div id=target></div>", .{});
    defer page.deinit();
    page.repairParentPointers();
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 400, 300, false);
    defer engine.deinit();
    const document = try engine.buildDocument(&page.root);
    defer {
        document.deinit();
        allocator.destroy(document);
    }
    const target = &findById(&page.root, "target").?.element;
    const Case = struct { origin: []const u8, width: i32, offset: i32 };
    for ([_]Case{
        .{ .origin = "padding-box", .width = 120, .offset = 4 },
        .{ .origin = "content-box", .width = 100, .offset = 14 },
        .{ .origin = "border-box", .width = 128, .offset = 0 },
    }) |case| {
        const inline_text = try std.fmt.allocPrint(allocator, "background-origin:{s}", .{case.origin});
        defer allocator.free(inline_text);
        const block = try @import("../document/css_declaration_block.zig").create(allocator, inline_text);
        target.replaceInlineStyle(allocator, block) catch |err| {
            block.destroy();
            return err;
        };
        dom.dirtyStyleForElement(target);
        try page.restyle();
        try std.testing.expect(!document.layoutNeeded());
        const commands = try engine.paintDocument(document);
        defer display.DisplayItem.freeList(allocator, commands);
        const image = gradientImage(commands) orelse return error.MissingGradientPaint;
        try std.testing.expectEqual(128, image.x2 - image.x1);
        try std.testing.expectEqual(68, image.y2 - image.y1);
        try std.testing.expectEqual(case.width, image.tiling.?.width);
        try std.testing.expectEqual(case.offset, image.tiling.?.offset_x);
        try std.testing.expectEqual(case.offset, image.tiling.?.offset_y);
        var bounds = Compositor.init(allocator);
        defer bounds.deinit();
        var renderer = Renderer.init(allocator, allocator, std.testing.io, &bounds);
        var surface = try z2d.Surface.init(.image_surface_rgba, allocator, 200, 120);
        defer surface.deinit(allocator);
        const pixels = surface.image_surface_rgba.buf;
        @memset(pixels, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
        var context = z2d.Context.init(std.testing.io, allocator, &surface);
        defer context.deinit();
        // This leaf uses absolute block coordinates and includes the complete
        // tile geometry; clipping/tiling are exercised by the actual rasterizer.
        try renderer.drawDisplayItemZ2dContext(&context, .{ .image = image }, 0, 1);
        const row: usize = @intCast(image.y1 + 30);
        const left: usize = @intCast(image.x1);
        try std.testing.expectEqual(@as(u8, 0), pixels[row * 200 + left + @as(usize, @intCast(case.offset))].r);
        if (case.offset > 0) try std.testing.expectEqual(@as(u8, 255), pixels[row * 200 + left + @as(usize, @intCast(case.offset - 1))].r);
    }
}
