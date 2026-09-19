//! Intrinsic contribution regressions without relying on platform glyph pixels.
const std = @import("std");
const parser = @import("../document/parser.zig");
const intrinsic = @import("../browser/render/intrinsic_width.zig");
const font = @import("../browser/render/font.zig");
const allocator = std.testing.allocator;

const Fixture = struct {
    root: parser.Node,
    environ: std.process.Environ.Map,

    fn init(source: []const u8) !Fixture {
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

    fn prepare(self: *Fixture) !font.FontManager {
        parser.fixParentPointers(&self.root, null);
        try parser.style(allocator, &self.root, &.{});
        return font.FontManager.init(allocator, std.testing.io, &self.environ);
    }

    fn deinit(self: *Fixture) void {
        self.root.deinit(allocator);
        self.environ.deinit();
    }
};

test "shared intrinsic root content constrained content and outer contribution differ" {
    var fixture = try Fixture.init("<div style='display:block;width:100px;min-width:80px;max-width:90px;padding:10px;border:5px solid;margin:7px;box-sizing:border-box'><div style='display:block;width:200px;max-width:40px;padding:3px'></div></div>");
    defer fixture.deinit();
    var fonts = try fixture.prepare();
    defer fonts.deinit();
    for ([_]f64{ 1, 2 }) |scale| {
        const natural = try intrinsic.measureContent(&fixture.root, &fonts, scale);
        const constrained = try intrinsic.measure(&fixture.root, &fonts, scale);
        const outer = try intrinsic.measureOuter(&fixture.root, &fonts, scale);
        try std.testing.expectEqual(46 * scale, natural.min);
        try std.testing.expectEqual(46 * scale, natural.max);
        try std.testing.expectEqual(60 * scale, constrained.min);
        try std.testing.expectEqual(60 * scale, constrained.max);
        try std.testing.expectEqual(104 * scale, outer.min);
        try std.testing.expectEqual(104 * scale, outer.max);
    }
}

test "shared intrinsic contradictory constraints preserve border floor and minimum" {
    var fixture = try Fixture.init("<main style='display:block'><div style='display:block;box-sizing:border-box;width:10px;max-width:20px;min-width:80px;padding:15px;border:5px solid'></div></main>");
    defer fixture.deinit();
    var fonts = try fixture.prepare();
    defer fonts.deinit();
    const node = &fixture.root.element.children.items[0];
    const content = try intrinsic.measure(node, &fonts, 1);
    const outer = try intrinsic.measureContent(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 40), content.min);
    try std.testing.expectEqual(@as(f64, 80), outer.min);
    node.element.style.?.getPtr("min-width").?.set("auto");
    const floor = try intrinsic.measureContent(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 40), floor.min);
}

test "shared intrinsic descendant constraints floats and zoom contribute once" {
    var fixture = try Fixture.init("<main style='display:block'><div style='float:left;display:block;width:100px;max-width:30px;zoom:2;padding:5px;margin:2px'></div><div style='float:right;display:block;width:25px;min-width:40px;padding:5px'></div><div style='display:none;width:900px;padding:50px'></div></main>");
    defer fixture.deinit();
    var fonts = try fixture.prepare();
    defer fonts.deinit();
    const content = try intrinsic.measureContent(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 88), content.min);
    try std.testing.expectEqual(@as(f64, 138), content.max);
    fixture.root.element.children.items[0].element.style.?.getPtr("max-width").?.set("50px");
    const changed = try intrinsic.measureContent(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 128), changed.min);
    try std.testing.expectEqual(@as(f64, 178), changed.max);
}

test "shared intrinsic cyclic percentages stay unresolved during contribution measurement" {
    var fixture = try Fixture.init("<main style='display:block'><div style='display:block;width:100%;min-width:50%;max-width:10%;padding:20%'><div style='display:block;width:40px'></div></div></main>");
    defer fixture.deinit();
    var fonts = try fixture.prepare();
    defer fonts.deinit();
    const content = try intrinsic.measureContent(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 40), content.min);
    try std.testing.expectEqual(@as(f64, 40), content.max);
}

test "shared intrinsic fit content contributions preserve distinct minimum and maximum" {
    var fixture = try Fixture.init("<main style='display:block;width:fit-content'><span style='display:inline-block;width:20px'></span><span style='display:inline-block;width:40px'></span></main>");
    defer fixture.deinit();
    var fonts = try fixture.prepare();
    defer fonts.deinit();
    const fitted = try intrinsic.measure(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 40), fitted.min);
    try std.testing.expectEqual(@as(f64, 60), fitted.max);
    fixture.root.element.style.?.getPtr("width").?.set("min-content");
    const minimum = try intrinsic.measure(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 40), minimum.min);
    try std.testing.expectEqual(@as(f64, 40), minimum.max);
    fixture.root.element.style.?.getPtr("width").?.set("max-content");
    const maximum = try intrinsic.measure(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 60), maximum.min);
    try std.testing.expectEqual(@as(f64, 60), maximum.max);
}

test "shared intrinsic ratio contributions use the selected box and count edges once" {
    var fixture = try Fixture.init("<main style='display:block;width:max-content'><div style='display:block;max-width:max-content;height:500px;aspect-ratio:1;padding:10px 20px;box-sizing:border-box'></div></main>");
    defer fixture.deinit();
    var fonts = try fixture.prepare();
    defer fonts.deinit();
    const node = &fixture.root.element.children.items[0];
    for ([_]f64{ 1, 2 }) |scale| {
        const natural = try intrinsic.measureContent(node, &fonts, scale);
        const keyword = intrinsic.keywordContent(node, natural, scale);
        const outer = try intrinsic.measureOuter(node, &fonts, scale);
        const parent = try intrinsic.measureContent(&fixture.root, &fonts, scale);
        try std.testing.expectEqual(@as(f64, 0), natural.max);
        try std.testing.expectEqual(460 * scale, keyword.max);
        try std.testing.expectEqual(500 * scale, outer.max);
        try std.testing.expectEqual(500 * scale, parent.max);
    }
    node.element.style.?.getPtr("aspect-ratio").?.set("auto 1");
    try std.testing.expectEqual(@as(f64, 520), (try intrinsic.measureOuter(node, &fonts, 1)).max);
    node.element.style.?.getPtr("box-sizing").?.set("content-box");
    try std.testing.expectEqual(@as(f64, 540), (try intrinsic.measureOuter(node, &fonts, 1)).max);
    node.element.style.?.getPtr("max-height").?.set("300px");
    try std.testing.expectEqual(@as(f64, 340), (try intrinsic.measureOuter(node, &fonts, 1)).max);
}

test "shared intrinsic ratio keyword keeps raw content minimum and indefinite height separate" {
    var fixture = try Fixture.init("<main style='display:block;width:min-content;height:50px;aspect-ratio:2'><div style='display:block;width:300px'></div></main>");
    defer fixture.deinit();
    var fonts = try fixture.prepare();
    defer fonts.deinit();
    const natural = try intrinsic.measureContent(&fixture.root, &fonts, 1);
    try std.testing.expectEqual(@as(f64, 300), natural.min);
    try std.testing.expectEqual(@as(f64, 100), intrinsic.keywordContent(&fixture.root, natural, 1).min);
    try std.testing.expectEqual(@as(f64, 300), (try intrinsic.measure(&fixture.root, &fonts, 1)).min);
    fixture.root.element.style.?.getPtr("min-width").?.set("min-content");
    try std.testing.expectEqual(@as(f64, 100), (try intrinsic.measure(&fixture.root, &fonts, 1)).min);
    fixture.root.element.style.?.getPtr("height").?.set("50%");
    try std.testing.expectEqual(@as(f64, 300), intrinsic.keywordContent(&fixture.root, natural, 1).min);
    try std.testing.expectEqual(@as(f64, 300), (try intrinsic.measure(&fixture.root, &fonts, 1)).min);
}
