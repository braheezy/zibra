//! Formatting-container baselines and atomic snapshots across retained reflows.
const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const parser = @import("../document/parser.zig");
const geometry = @import("../browser/render/element_geometry.zig");
const DisplayItem = @import("../browser/render/display_list.zig").DisplayItem;
const allocator = std.testing.allocator;

const Page = struct {
    root: parser.Node,
    environ: std.process.Environ.Map,
    engine: ?*Layout = null,
    document: ?*Layout.DocumentLayout = null,

    fn init(source: []const u8) !Page {
        var html = try parser.HTMLParser.init(allocator, source);
        defer html.deinit(allocator);
        html.use_implicit_tags = false;
        var root = try html.parse();
        errdefer root.deinit(allocator);
        var environ = std.process.Environ.Map.init(allocator);
        errdefer environ.deinit();
        try environ.put("HOME", "/tmp");
        return .{ .root = root, .environ = environ };
    }

    fn deinit(self: *Page) void {
        if (self.document) |document| {
            document.deinit();
            allocator.destroy(document);
        }
        if (self.engine) |engine| engine.deinit();
        self.root.deinit(allocator);
        self.environ.deinit();
    }

    fn render(self: *Page) !void {
        parser.fixParentPointers(&self.root, null);
        try parser.style(allocator, &self.root, &.{});
        self.engine = try Layout.init(allocator, std.testing.io, &self.environ, 800, 600, false);
        self.document = try self.engine.?.buildDocument(&self.root);
    }

    fn node(self: *Page, id: []const u8) *parser.Node {
        return find(&self.root, id).?;
    }

    fn box(self: *Page, id: []const u8) !geometry.Rect {
        var rects = std.ArrayList(geometry.Rect).empty;
        defer rects.deinit(allocator);
        try geometry.collect(self.document.?, self.node(id), 1, 0, false, allocator, &rects);
        try std.testing.expectEqual(@as(usize, 1), rects.items.len);
        return rects.items[0];
    }

    fn set(self: *Page, id: []const u8, property: []const u8, value: []const u8) void {
        self.node(id).element.style.?.getPtr(property).?.set(value);
    }

    fn reflow(self: *Page) !void {
        try std.testing.expect(self.document.?.layoutNeeded());
        try self.document.?.layout(self.engine.?);
        try std.testing.expect(!self.document.?.layoutNeeded());
    }

    fn restyle(self: *Page, id: []const u8, css: []const u8) !void {
        const element = &self.node(id).element;
        try element.attributes.?.put("style", css);
        @import("../document/dom.zig").dirtyStyleForElement(element);
        try parser.style(allocator, &self.root, &.{});
        try self.reflow();
    }

    fn baseline(self: *Page, marker: []const u8, container: []const u8, offset: f64) !void {
        const mark = try self.box(marker);
        const owner = try self.box(container);
        try std.testing.expectEqual(owner.y + offset, mark.y + mark.height);
    }
};

fn find(node: *parser.Node, id: []const u8) ?*parser.Node {
    if (node.* != .element) return null;
    if (node.element.attributes) |attributes| if (attributes.get("id")) |value| {
        if (std.mem.eql(u8, value, id)) return node;
    };
    for (node.element.children.items) |*child| if (find(child, id)) |found| return found;
    return null;
}

test "shared formatting atomic first baselines survive overflow and retained item edits" {
    for ([_][]const u8{ "inline-flex", "inline-grid" }) |format| {
        const source = try std.fmt.allocPrint(allocator, "<main id='line' style='display:block;width:300px;font-size:0;line-height:0'><span id='marker' style='display:inline-block;width:10px;height:10px'></span><span id='atomic' style='display:{s};width:40px;flex-direction:column;grid-template-columns:40px;overflow:hidden'><span id='first' style='height:20px;flex:none'></span><span id='second' style='height:40px;flex:none'></span></span></main>", .{format});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        const owner = page.node("line").element.layout_ptr;
        try page.baseline("marker", "atomic", 20);
        try std.testing.expectEqual(@as(f64, 60), (try page.box("atomic")).height);
        page.set("first", "height", "30px");
        try page.reflow();
        try page.baseline("marker", "atomic", 30);
        try std.testing.expectEqual(@as(f64, 70), (try page.box("atomic")).height);
        page.set("first", "height", "20px");
        page.set("first", "order", "2");
        try page.reflow();
        try page.baseline("marker", "atomic", 40);
        try std.testing.expectEqual(@as(f64, 60), (try page.box("atomic")).height);
        try std.testing.expect(page.node("atomic").element.layout_ptr == null);
        try std.testing.expect(page.node("first").element.layout_ptr == null);
        try std.testing.expectEqual(owner, page.node("line").element.layout_ptr);
    }
}

test "shared formatting atomic ascent and descent reserve the full enclosing line" {
    for ([_][]const u8{ "inline-flex", "inline-grid" }) |format| {
        for ([_]f64{ 1, 2 }) |zoom| {
            const source = try std.fmt.allocPrint(allocator, "<main id='root' style='display:block;width:300px;font-size:0;line-height:0;zoom:{d}'><div id='line' style='display:block'><span style='display:inline-block;width:10px;height:30px'></span><span id='atomic' style='display:{s};width:40px;flex-direction:column;grid-template-columns:40px'><span style='height:20px;flex:none'></span><span style='height:40px;flex:none'></span></span></div><div id='after' style='display:block;height:10px'></div></main>", .{ zoom, format });
            defer allocator.free(source);
            var page = try Page.init(source);
            defer page.deinit();
            try page.render();
            for ([_]f64{ 70, 60, 90 }, 0..) |height, index| {
                if (index > 0) {
                    const css = if (std.mem.eql(u8, format, "inline-flex"))
                        if (index == 1) "display:inline-flex;width:40px;flex-direction:column;vertical-align:20px" else "display:inline-flex;width:40px;flex-direction:column;vertical-align:-20px"
                    else if (index == 1)
                        "display:inline-grid;width:40px;grid-template-columns:40px;vertical-align:20px"
                    else
                        "display:inline-grid;width:40px;grid-template-columns:40px;vertical-align:-20px";
                    try page.restyle("atomic", css);
                }
                const line = try page.box("line");
                const atomic = try page.box("atomic");
                const after = try page.box("after");
                try std.testing.expectEqual(height * zoom, line.height);
                try std.testing.expectEqual(line.y + height * zoom, after.y);
                try std.testing.expectEqual((height + 10) * zoom, (try page.box("root")).height);
                try std.testing.expect(atomic.y >= line.y);
                try std.testing.expect(atomic.y + atomic.height <= after.y);
            }
        }
    }
}

test "shared formatting nested containers export separate first and last baselines" {
    for ([_][]const u8{ "flex", "grid" }) |format| {
        const source = try std.fmt.allocPrint(allocator, "<main id='group' style='display:flex;width:200px;align-items:baseline;font-size:0;line-height:0'><div id='nested' style='display:{s};width:40px;flex-direction:column;grid-template-columns:40px'><div style='height:20px;flex:none'></div><div style='height:40px;flex:none'></div></div><div id='marker' style='width:10px;height:10px'></div></main>", .{format});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        const owner = page.node("nested").element.layout_ptr;
        try page.baseline("marker", "nested", 20);
        page.set("group", "align-items", "last baseline");
        try page.reflow();
        try page.baseline("marker", "nested", 60);
        page.set("group", "align-items", "baseline");
        try page.reflow();
        try page.baseline("marker", "nested", 20);
        try std.testing.expectEqual(owner, page.node("nested").element.layout_ptr);
    }
}

test "shared formatting flex fallback baselines follow physical row edges" {
    var page = try Page.init("<main id='group' style='display:flex;width:200px;align-items:baseline;font-size:0;line-height:0'><div id='nested' style='display:flex;width:40px;align-items:flex-start'><div style='width:20px;height:20px'></div><div style='width:20px;height:40px'></div></div><div id='marker' style='width:10px;height:10px'></div></main>");
    defer page.deinit();
    try page.render();
    try page.baseline("marker", "nested", 20);
    page.set("nested", "flex-direction", "row-reverse");
    try page.reflow();
    try page.baseline("marker", "nested", 40);
    page.set("group", "align-items", "last baseline");
    try page.reflow();
    try page.baseline("marker", "nested", 20);
    page.set("nested", "flex-direction", "row");
    try page.reflow();
    try page.baseline("marker", "nested", 40);
}

test "shared formatting baseline groups take precedence over edge fallback items" {
    for ([_][]const u8{ "flex", "grid" }) |format| {
        const source = try std.fmt.allocPrint(allocator, "<main style='display:flex;width:200px;align-items:baseline;font-size:0;line-height:0'><div id='nested' style='display:{s};width:40px;grid-template-columns:20px 20px;align-items:start'><div style='width:20px;height:20px'></div><div id='aligned' style='width:20px;height:40px;align-self:baseline'></div></div><div id='marker' style='width:10px;height:10px'></div></main>", .{format});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        try page.baseline("marker", "nested", 40);
        page.set("aligned", "align-self", "start");
        try page.reflow();
        try page.baseline("marker", "nested", 20);
    }
}

test "shared formatting wrapped flex baselines follow physical first and last lines" {
    var page = try Page.init("<main id='group' style='display:flex;width:200px;align-items:baseline;font-size:0;line-height:0'><div id='nested' style='display:flex;width:40px;flex-wrap:wrap;align-items:start'><div style='width:40px;height:20px;flex:none'></div><div style='width:40px;height:30px;flex:none'></div><div style='width:40px;height:40px;flex:none'></div></div><div id='marker' style='width:10px;height:10px'></div></main>");
    defer page.deinit();
    try page.render();
    try page.baseline("marker", "nested", 20);
    try std.testing.expectEqual(@as(f64, 90), (try page.box("nested")).height);
    page.set("nested", "flex-wrap", "wrap-reverse");
    try page.reflow();
    try page.baseline("marker", "nested", 40);
    page.set("group", "align-items", "last baseline");
    try page.reflow();
    try page.baseline("marker", "nested", 90);
    page.set("nested", "flex-wrap", "wrap");
    try page.reflow();
    try page.baseline("marker", "nested", 90);
}

test "shared formatting atomic wrap boundaries use surrounding white space" {
    for ([_][]const u8{ "inline-block", "inline-flex", "inline-grid" }) |format| {
        const source = try std.fmt.allocPrint(allocator, "<main id='line' style='display:block;width:100px;white-space:nowrap;font-size:0;line-height:0'><span id='prefix' style='display:inline-block;width:40px;height:20px;vertical-align:top'></span><span id='atomic' style='display:{s};white-space:normal;width:70px;height:20px;vertical-align:top'><span style='display:block;width:70px;height:20px'></span></span></main>", .{format});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        var prefix = try page.box("prefix");
        var atomic = try page.box("atomic");
        try std.testing.expectEqual(prefix.y, atomic.y);
        try std.testing.expectEqual(prefix.x + prefix.width, atomic.x);
        try page.restyle("line", "display:block;width:100px;white-space:normal;font-size:0;line-height:0");
        prefix = try page.box("prefix");
        atomic = try page.box("atomic");
        try std.testing.expect(atomic.y >= prefix.y + prefix.height);
        try page.restyle("line", "display:block;width:100px;white-space:nowrap;font-size:0;line-height:0");
        try std.testing.expectEqual((try page.box("prefix")).y, (try page.box("atomic")).y);
    }
}

test "shared formatting nested atomic snapshots retain current geometry and interaction bounds" {
    for ([_][]const u8{ "inline-flex", "inline-grid" }) |format| {
        const source = try std.fmt.allocPrint(allocator, "<main id='line' style='display:block;width:600px'><span id='prefix' style='display:inline-block;width:100px;height:10px'></span><span id='atomic' style='display:{s};width:180px;grid-template-columns:40px 80px;align-items:start;column-gap:10px'><a id='link' href='/target' style='display:block;width:40px;height:20px;background:green'>go</a><span style='display:inline-grid;width:80px;grid-template-columns:80px'><input id='input' style='width:80px;height:20px;border:0;padding:0'></span></span></main>", .{format});
        defer allocator.free(source);
        var page = try Page.init(source);
        defer page.deinit();
        try page.render();
        const persistent = page.node("line").element.layout_ptr;
        for (0..4) |iteration| {
            const changed = iteration % 2 != 0;
            if (iteration > 0) {
                page.set("prefix", "width", if (changed) "150px" else "100px");
                page.set("atomic", "column-gap", if (changed) "20px" else "10px");
                try page.reflow();
            }
            const prefix = try page.box("prefix");
            const atomic = try page.box("atomic");
            const input = try page.box("input");
            const link = try page.box("link");
            try std.testing.expectEqual(prefix.x + prefix.width, atomic.x);
            try std.testing.expectEqual(atomic.x + 40 + @as(f64, if (changed) 20 else 10), input.x);
            const input_bounds = page.engine.?.input_bounds.get(page.node("input")).?;
            try std.testing.expectEqual(input.x, @as(f64, @floatFromInt(input_bounds.x)));
            try std.testing.expectEqual(input.y, @as(f64, @floatFromInt(input_bounds.y)));
            try std.testing.expectEqual(input.width, @as(f64, @floatFromInt(input_bounds.width)));
            try std.testing.expectEqual(input.height, @as(f64, @floatFromInt(input_bounds.height)));
            var links: usize = 0;
            for (page.engine.?.link_bounds.items) |entry| if (entry.node == page.node("link")) {
                links += 1;
                try std.testing.expect(@as(f64, @floatFromInt(entry.bounds.x)) >= link.x);
                try std.testing.expect(@as(f64, @floatFromInt(entry.bounds.x + entry.bounds.width)) <= link.x + link.width);
            };
            try std.testing.expectEqual(@as(usize, 1), links);
            var focused: usize = 0;
            for (page.engine.?.focus_bounds.items) |entry| if (entry.node == page.node("link")) {
                focused += 1;
                try std.testing.expectEqual(link.x, @as(f64, @floatFromInt(entry.bounds.x)));
                try std.testing.expectEqual(link.y, @as(f64, @floatFromInt(entry.bounds.y)));
                try std.testing.expectEqual(link.width, @as(f64, @floatFromInt(entry.bounds.width)));
            };
            try std.testing.expectEqual(@as(usize, 1), focused);
            const commands = try page.engine.?.paintDocument(page.document.?);
            defer DisplayItem.freeList(allocator, commands);
            try std.testing.expect(commands.len > 0);
            try std.testing.expect(page.node("atomic").element.layout_ptr == null);
            try std.testing.expect(page.node("link").element.layout_ptr == null);
            try std.testing.expect(page.node("input").element.layout_ptr == null);
            try std.testing.expectEqual(persistent, page.node("line").element.layout_ptr);
            try std.testing.expect(!page.document.?.layoutNeeded());
        }
    }
}
