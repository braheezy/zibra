//! Deterministic box-level flex/grid and root-relative sizing regressions.
const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const document = @import("../document/parser.zig");
const display = @import("../browser/render/display_list.zig");

fn coloredGlyphBounds(items: []const display.DisplayItem, color: display.Color, dx: i32, dy: i32) ?display.Rect {
    var result: ?display.Rect = null;
    for (items) |item| {
        const found: ?display.Rect = switch (item) {
            .cached_subtree => |value| coloredGlyphBounds(value.list.items, color, dx, dy),
            .transform => |value| coloredGlyphBounds(value.children, color, dx + value.translate_x, dy + value.translate_y),
            .blend => |value| if (value.opacity > 0) coloredGlyphBounds(value.children, color, dx, dy) else null,
            .glyph => |value| if (std.meta.eql(value.color, color)) .{
                .left = dx + value.x,
                .top = dy + value.y,
                .right = dx + value.x + value.glyph.w,
                .bottom = dy + value.y + value.glyph.h,
            } else null,
            else => null,
        };
        if (found) |rect| result = if (result) |old| old.unionWith(rect) else rect;
    }
    return result;
}

test "atomic inline blocks retain nested text and block line breaks" {
    var page = try Page.init("<main style='display:block;width:600px'><span style='display:inline-block;width:200px;padding:10px;vertical-align:bottom'><span style='display:block;font-size:24px;color:red'>A</span><span style='display:block;color:green'>B</span></span><span style='display:inline-block;width:100px;vertical-align:bottom;color:blue'>C</span></main>");
    defer page.deinit();
    try page.render();
    const commands = try page.engine.?.paintDocument(page.layout.?);
    defer display.DisplayItem.freeList(std.testing.allocator, commands);
    const red = coloredGlyphBounds(commands, .{ .r = 255, .g = 0, .b = 0 }, 0, 0).?;
    const green = coloredGlyphBounds(commands, .{ .r = 0, .g = 128, .b = 0 }, 0, 0).?;
    const blue = coloredGlyphBounds(commands, .{ .r = 0, .g = 0, .b = 255 }, 0, 0).?;
    try std.testing.expect(green.top > red.top);
    try std.testing.expectEqual(red.left, green.left);
    try std.testing.expect(blue.left >= red.left + 210);
    const glyph = try page.engine.?.font_manager.getStyledGlyph("A", .Normal, .Roman, 24, .proportional);
    try std.testing.expectEqual(glyph.h, red.height());
    try std.testing.expectEqual(glyph.w, red.width());
    try std.testing.expect(!page.layout.?.layoutNeeded());
}

test "atomic inline auto width includes adjacent inline boxes and collapsed spaces" {
    var page = try Page.init("<main style='display:block;width:600px;font-size:16px'><small style='display:inline-block'>7,189,000+ <span style='display:inline-block;color:red'>articles</span></small><span style='display:inline-block;width:40px;color:blue'>next</span></main>");
    defer page.deinit();
    try page.render();
    const commands = try page.engine.?.paintDocument(page.layout.?);
    defer display.DisplayItem.freeList(std.testing.allocator, commands);
    const number = coloredGlyphBounds(commands, .{ .r = 0, .g = 0, .b = 0 }, 0, 0).?;
    const articles = coloredGlyphBounds(commands, .{ .r = 255, .g = 0, .b = 0 }, 0, 0).?;
    const next = coloredGlyphBounds(commands, .{ .r = 0, .g = 0, .b = 255 }, 0, 0).?;
    try std.testing.expectEqual(number.top, articles.top);
    try std.testing.expectEqual(number.top, next.top);
    // The black glyph range includes the collapsed trailing space.
    try std.testing.expect(articles.left >= number.right);
    try std.testing.expect(next.left >= articles.right);
}

test "atomic inline footer retains floated columns at wide and narrow viewports" {
    var page = try Page.init("<main style='display:block;width:100%'><aside style='display:block;float:left;width:35%;height:100px'></aside><section style='display:inline-block;width:65%;vertical-align:bottom'><div style='display:block;float:left;width:33%;height:50px;color:red'>A</div><div style='display:block;float:left;width:33%;height:50px;color:green'>B</div><div style='display:block;float:left;width:33%;height:50px;color:blue'>C</div></section></main>");
    defer page.deinit();
    try page.render();
    for ([_]i32{ 2560, 800, 400, 2560 }) |width| {
        page.engine.?.window_width = width;
        page.layout.?.mark();
        try page.layout.?.layout(page.engine.?);
        const commands = try page.engine.?.paintDocument(page.layout.?);
        defer display.DisplayItem.freeList(std.testing.allocator, commands);
        const a = coloredGlyphBounds(commands, .{ .r = 255, .g = 0, .b = 0 }, 0, 0).?;
        const b = coloredGlyphBounds(commands, .{ .r = 0, .g = 128, .b = 0 }, 0, 0).?;
        const c = coloredGlyphBounds(commands, .{ .r = 0, .g = 0, .b = 255 }, 0, 0).?;
        try std.testing.expectEqual(a.top, b.top);
        try std.testing.expectEqual(a.top, c.top);
        try std.testing.expect(a.left < b.left and b.left < c.left);
        try std.testing.expect(a.left > @divTrunc(width, 3));
        try std.testing.expect(c.right < width);
        try std.testing.expect(!page.layout.?.layoutNeeded());
    }
}

test "atomic inline nested controls keep final bounds and persistent invalidation" {
    var page = try Page.init("<main style='display:block;width:600px'><span style='display:inline-block;width:200px'>prefix</span><span style='display:inline-block;width:220px'><span style='display:inline-block;width:200px'><a href='/target' style='color:red'>link</a><input style='width:80px'></span></span></main>");
    defer page.deinit();
    try page.render();
    const outer = &page.root.element.children.items[1];
    const inner = &outer.element.children.items[0];
    const anchor = &inner.element.children.items[0];
    const input = &inner.element.children.items[1];
    for (0..5) |iteration| {
        try anchor.element.attributes.?.put("style", if (iteration % 2 == 0) "color:red;font-size:18px" else "color:blue;font-size:24px");
        @import("../document/dom.zig").dirtyStyleForElement(&anchor.element);
        try page.render();
        const commands = try page.engine.?.paintDocument(page.layout.?);
        defer display.DisplayItem.freeList(std.testing.allocator, commands);
        try std.testing.expect(commands.len > 0);
        const input_box = page.engine.?.input_bounds.get(input).?;
        try std.testing.expect(input_box.x >= 213);
        try std.testing.expect(input_box.x + input_box.width < 600);
        try std.testing.expect(anchor.element.layout_ptr == null);
        try std.testing.expect(!page.layout.?.layoutNeeded());
        var found_link = false;
        for (page.engine.?.link_bounds.items) |link| {
            if (link.node == anchor and link.bounds.x >= 213) found_link = true;
        }
        try std.testing.expect(found_link);
    }
}

test "atomic inline block descendants repaint after an opacity reveal" {
    var page = try Page.init("<main style='display:block;width:600px'><a style='display:block;overflow:hidden;width:300px'><div style='display:inline-block;width:50px;height:40px'></div><div style='display:inline-block;max-width:65%'><span style='display:block;color:blue;opacity:0'>Project name</span><span style='display:block;color:green'>Project description</span></div></a></main>");
    defer page.deinit();
    try page.render();
    const title = &page.root.element.children.items[0].element.children.items[1].element.children.items[0];
    for (0..4) |iteration| {
        const shown = iteration % 2 != 0;
        try title.element.attributes.?.put("style", if (shown) "display:block;color:blue;opacity:1" else "display:block;color:blue;opacity:0");
        @import("../document/dom.zig").dirtyStyleForElement(&title.element);
        try page.render();
        const commands = try page.engine.?.paintDocument(page.layout.?);
        defer display.DisplayItem.freeList(std.testing.allocator, commands);
        try std.testing.expectEqual(shown, coloredGlyphBounds(commands, .{ .r = 0, .g = 0, .b = 255 }, 0, 0) != null);
        try std.testing.expect(coloredGlyphBounds(commands, .{ .r = 0, .g = 128, .b = 0 }, 0, 0) != null);
        try std.testing.expect(!page.layout.?.layoutNeeded());
    }
}

test "responsive max-width auto blocks center after viewport changes" {
    var page = try Page.init("<main style='display:block;max-width:400px;padding:20px;margin:0 auto;height:20px'>Centered text</main>");
    defer page.deinit();
    try page.render();
    for ([_]i32{ 800, 2560, 300, 800 }) |width| {
        page.engine.?.window_width = width;
        page.layout.?.mark();
        try page.render();
        const main = page.layout.?.children.items[0];
        const containing = page.layout.?;
        const center_twice = 2 * containing.x.get().* + containing.width.get().*;
        try std.testing.expect(@abs(2 * main.x.get().* + main.width.get().* - center_twice) <= 1);
        try std.testing.expect(main.width.get().* <= 440);
        try std.testing.expect(!page.layout.?.layoutNeeded());
    }
}

test "responsive display none suppresses blocks inline text and controls across restyles" {
    var page = try Page.init("<main style='display:block;width:600px'><span style='display:none;color:red'><span style='display:block;position:absolute'>Hidden block</span><input style='width:80px'>Hidden text</span><div style='display:block;color:blue'>Visible</div></main>");
    defer page.deinit();
    try page.render();
    const hidden = &page.root.element.children.items[0];
    const input = &hidden.element.children.items[1];
    for (0..5) |iteration| {
        const shown = iteration % 2 != 0;
        try hidden.element.attributes.?.put("style", if (shown) "display:block;color:red" else "display:none;color:red");
        @import("../document/dom.zig").dirtyStyleForElement(&hidden.element);
        try page.render();
        const commands = try page.engine.?.paintDocument(page.layout.?);
        defer display.DisplayItem.freeList(std.testing.allocator, commands);
        try std.testing.expectEqual(shown, coloredGlyphBounds(commands, .{ .r = 255, .g = 0, .b = 0 }, 0, 0) != null);
        try std.testing.expectEqual(shown, page.engine.?.input_bounds.contains(input));
        try std.testing.expect(coloredGlyphBounds(commands, .{ .r = 0, .g = 0, .b = 255 }, 0, 0) != null);
        try std.testing.expect(!page.layout.?.layoutNeeded());
    }
}

test "automatic table live parser row groups share columns and retain centered boxes" {
    const allocator = std.testing.allocator;
    var source = document.HtmlSourceStore.init(allocator);
    defer source.deinit();
    _ = try source.appendCopy("<body><table style='margin:0 auto'><tr><td><div style='width:40px;height:10px'></div></td><td><div style='width:60px;height:10px'></div></td></tr></tbody><tbody><tr><td><div style='width:80px;height:20px'></div></td><td><div style='width:20px;height:20px'></div></td></tr></tbody></table></body>");
    var root: document.Node = undefined;
    var live = try @import("../document/html_live_parser.zig").LiveParser.init(allocator, &source, &root);
    defer root.deinit(allocator);
    defer live.deinit();
    live.finishInput();
    try std.testing.expect((try live.advance()) == .eof);
    var css = try @import("../document/css_parser.zig").CSSParser.init(allocator, @embedFile("../browser/browser.css"), false);
    defer css.deinit(allocator);
    const rules = try css.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    for (rules) |*rule| rule.origin = .user_agent;
    try document.style(allocator, &root, rules);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    var engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const layout = try engine.buildDocument(&root);
    defer {
        layout.deinit();
        allocator.destroy(layout);
    }
    for ([_]i32{ 800, 1600, 600 }) |viewport| {
        engine.window_width = viewport;
        layout.mark();
        try layout.layout(engine);
        const body = layout.children.items[0].children.items[1].block;
        const table = body.children.items[0].block;
        try std.testing.expectEqual(@as(i32, 140), table.width.get().*);
        try std.testing.expect(@abs(2 * table.x.get().* + table.width.get().* - 2 * body.x.get().* - body.width.get().*) <= 1);
        const first_group = table.children.items[0].block;
        const second_group = table.children.items[1].block;
        const first_row = first_group.children.items[0].block;
        const second_row = second_group.children.items[0].block;
        try std.testing.expectEqual(@as(i32, 10), first_group.height.get().*);
        try std.testing.expectEqual(@as(i32, 20), second_group.height.get().*);
        try std.testing.expectEqual(first_group.y.get().* + 10, second_group.y.get().*);
        try std.testing.expectEqual(@as(i32, 80), first_row.children.items[0].block.width.get().*);
        try std.testing.expectEqual(first_row.children.items[1].block.x.get().*, second_row.children.items[1].block.x.get().*);
        try std.testing.expect(!layout.layoutNeeded());
    }
}

test "automatic table search form measures controls and centers through resize and restyle" {
    var page = try Page.init("<div align=center style='display:block'><table style='display:table'><tr style='display:table-row'><td width='25%' style='display:table-cell'>&nbsp;</td><td align=center nowrap style='display:table-cell'><div style='display:inline-block'><input style='width:300px;padding:5px 8px 0 6px'></div><br><span style='display:inline-block'><input type=submit value='Search'></span> <span style='display:inline-block'><input type=submit value='Lucky'></span></td><td width='25%' nowrap style='display:table-cell'><a href='/advanced' style='display:block;color:blue;margin-left:13px'>Advanced search</a></td></tr></table></div>");
    defer page.deinit();
    try page.render();
    const table_node = &page.root.element.children.items[0];
    const cell = &table_node.element.children.items[0].element.children.items[1];
    const input = &cell.element.children.items[0].element.children.items[0];
    for ([_]i32{ 1600, 800, 600, 1600 }, 0..) |viewport, index| {
        page.engine.?.window_width = viewport;
        page.layout.?.mark();
        try input.element.attributes.?.put("style", if (index == 3) "width:420px;padding:5px 8px 0 6px" else "width:300px;padding:5px 8px 0 6px");
        @import("../document/dom.zig").dirtyStyleForElement(&input.element);
        try page.render();
        const container = page.layout.?.children.items[0];
        const table = container.children.items[0].block;
        const input_box = page.engine.?.input_bounds.get(input).?;
        try std.testing.expectEqual(@as(i32, if (index == 3) 434 else 314), input_box.width);
        const first_button = page.engine.?.input_bounds.get(&cell.element.children.items[2].element.children.items[0]).?;
        const last_button = page.engine.?.input_bounds.get(&cell.element.children.items[4].element.children.items[0]).?;
        try std.testing.expectEqual(first_button.y, last_button.y);
        try std.testing.expect(@abs(first_button.x + last_button.x + last_button.width - 2 * input_box.x - input_box.width) <= 1);
        try std.testing.expect(table.width.get().* >= input_box.width + 80);
        try std.testing.expect(table.width.get().* <= container.width.get().*);
        try std.testing.expect(@abs(2 * table.x.get().* + table.width.get().* - 2 * container.x.get().* - container.width.get().*) <= 1);
        const commands = try page.engine.?.paintDocument(page.layout.?);
        defer display.DisplayItem.freeList(std.testing.allocator, commands);
        const advanced = coloredGlyphBounds(commands, .{ .r = 0, .g = 0, .b = 255 }, 0, 0).?;
        try std.testing.expect(advanced.width() > 70 and advanced.height() < 40);
        try std.testing.expect(!page.layout.?.layoutNeeded());
    }
}

test "automatic table width follows text changes without explicit cell widths" {
    var page = try Page.init("<table style='display:table'><tr style='display:table-row'><td style='display:table-cell'><span style='font-size:12px'>Measured words</span></td><td style='display:table-cell'>neighbor</td></tr></table>");
    defer page.deinit();
    try page.render();
    const table = page.layout.?.children.items[0];
    const initial = table.width.get().*;
    try std.testing.expect(initial > 60);
    const label = &page.root.element.children.items[0].element.children.items[0].element.children.items[0];
    try label.element.attributes.?.put("style", "font-size:30px");
    @import("../document/dom.zig").dirtyStyleForElement(&label.element);
    try page.render();
    try std.testing.expect(table.width.get().* > initial);
    try std.testing.expect(!page.layout.?.layoutNeeded());
}

test "automatic table legacy block alignment differs from CSS text alignment" {
    var page = try Page.init("<div align=right style='display:block;width:400px'><div style='display:block;width:100px;height:10px'></div><div align=center style='display:block;width:200px;height:20px;margin:0 auto'></div></div>");
    defer page.deinit();
    try page.render();
    const parent = page.layout.?.children.items[0];
    const child = parent.children.items[0].block;
    const centered = parent.children.items[1].block;
    try std.testing.expectEqual(parent.x.get().* + 300, child.x.get().*);
    try std.testing.expectEqual(parent.x.get().* + 100, centered.x.get().*);
    try page.root.element.attributes.?.put("style", "display:block;width:400px;text-align:center");
    @import("../document/dom.zig").dirtyStyleForElement(&page.root.element);
    try page.render();
    try std.testing.expectEqual(parent.x.get().*, child.x.get().*);
}

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
