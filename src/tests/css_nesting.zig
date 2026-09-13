//! Nested selectors, declaration ordering, invalidation and source ownership.
const std = @import("std");
const document = @import("../document/parser.zig");
const stylesheet = @import("../document/css_stylesheet.zig");
const css = @import("../document/css_parser.zig");

const source = "section, #unused { color:purple; & > .child {color:green; width:20px} " ++
    "@supports (color:red) { @media (min-width:600px) { > .child {width:40px} } } " ++
    "&.active {color:red} color:blue; --blocks:{a:b}; } " ++
    ".ordinary > .child {color:red} .child { & {height:10px} height:30px }";

test "nesting preserves maximum parent specificity source order and media context" {
    const allocator = std.testing.allocator;
    var sheet = try stylesheet.Sheet.init(allocator, source, .{});
    defer sheet.deinit();
    var parser = try document.HTMLParser.init(allocator, "<section class='ordinary active'><span class='child'></span></section>");
    defer parser.deinit(allocator);
    parser.use_implicit_tags = false;
    var root = try parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    for ([_]f64{ 800, 400 }) |width| {
        var selected = try sheet.select(allocator, .{ .viewport_width_css = width });
        defer selected.deinit();
        document.dirtyStyleSubtree(&root);
        try document.style(allocator, &root, selected.rules);
        const child = &root.element.children.items[0].element;
        try std.testing.expectEqualStrings("green", child.style.?.getPtr("color").?.get().*);
        try std.testing.expectEqualStrings(if (width == 800) "40px" else "20px", child.style.?.getPtr("width").?.get().*);
        try std.testing.expectEqualStrings("30px", child.style.?.getPtr("height").?.get().*);
        // &.active has greater specificity than the parent's later declaration.
        try std.testing.expectEqualStrings("red", root.element.style.?.getPtr("color").?.get().*);
    }
    try std.testing.expect(try css.supportsSelector(allocator, "& > .child"));
}

fn allocationTrial(allocator: std.mem.Allocator) !void {
    var sheet = try stylesheet.Sheet.init(allocator, ".parent, #id {width:1px; & > .child {height:2px; @supports (color:red) {color:green}} width:3px}", .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 6), selected.rules.len);
}

test "nesting source expansion and independent selector clones unwind allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrial, .{});
}
