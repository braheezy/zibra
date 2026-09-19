//! Root-relative lengths and variable cascade/invalidation regressions.
const std = @import("std");
const document = @import("../document/parser.zig");
const dom = @import("../document/dom.zig");
const lengths = @import("../document/length.zig");

fn parsed(html: []const u8) !document.Node {
    var parser = try document.HTMLParser.init(std.testing.allocator, html);
    defer parser.deinit(std.testing.allocator);
    parser.use_implicit_tags = false;
    return parser.parse();
}

fn value(node: *document.Node, property: []const u8) []const u8 {
    return node.element.style.?.getPtr(property).?.get().*;
}

test "numeric grid placement computes substituted shorthands and retained resets" {
    const allocator = std.testing.allocator;
    var root = try parsed("<div style='--area:-2 / +03 / 2 span;grid-area:var(--area);grid-auto-flow:dense column'><span style='grid-area:inherit;grid-auto-flow:inherit'></span></div>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    const child = &root.element.children.items[0];
    try std.testing.expectEqualStrings("-2", value(&root, "grid-row-start"));
    try std.testing.expectEqualStrings("3", value(child, "grid-column-start"));
    try std.testing.expectEqualStrings("span 2", value(child, "grid-row-end"));
    try std.testing.expectEqualStrings("auto", value(child, "grid-column-end"));
    try std.testing.expectEqualStrings("column dense", value(child, "grid-auto-flow"));
    try root.element.putOwnedAttribute(allocator, "style", "--area:1 / span 3;grid-area:var(--area);grid-auto-flow:row dense");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqualStrings("1", value(child, "grid-row-start"));
    try std.testing.expectEqualStrings("span 3", value(child, "grid-column-start"));
    try std.testing.expectEqualStrings("auto", value(child, "grid-row-end"));
    try std.testing.expectEqualStrings("dense", value(child, "grid-auto-flow"));
    try root.element.putOwnedAttribute(allocator, "style", "grid-area:unset;grid-auto-flow:unset");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    for ([_][]const u8{ "grid-row-start", "grid-column-start", "grid-row-end", "grid-column-end" }) |name|
        try std.testing.expectEqualStrings("auto", value(child, name));
    try std.testing.expectEqualStrings("row", value(child, "grid-auto-flow"));
}

test "overflow computed pairs follow current single-axis semantics across retained mutations" {
    const allocator = std.testing.allocator;
    var root = try parsed("<div style='overflow:visible scroll'><span style='overflow:inherit'></span></div>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    const child = &root.element.children.items[0];
    try std.testing.expectEqualStrings("auto", value(&root, "overflow-x"));
    try std.testing.expectEqualStrings("scroll", value(child, "overflow-y"));
    try std.testing.expectEqualStrings("auto", value(child, "overflow-x"));
    const axes = [_][]const u8{ "visible", "hidden", "clip", "scroll", "auto" };
    for (axes) |x| for (axes) |y| {
        const authored = try std.fmt.allocPrint(allocator, "overflow-x:{s};overflow-y:{s}", .{ x, y });
        defer allocator.free(authored);
        try root.element.putOwnedAttribute(allocator, "style", authored);
        dom.dirtyStyleForElement(&root.element);
        try document.style(allocator, &root, &.{});
        const x_scrollable = std.mem.eql(u8, x, "hidden") or std.mem.eql(u8, x, "scroll") or std.mem.eql(u8, x, "auto");
        const y_scrollable = std.mem.eql(u8, y, "hidden") or std.mem.eql(u8, y, "scroll") or std.mem.eql(u8, y, "auto");
        const expected_x = if (std.mem.eql(u8, x, "visible") and y_scrollable) "auto" else x;
        const expected_y = if (std.mem.eql(u8, y, "visible") and x_scrollable) "auto" else y;
        try std.testing.expectEqualStrings(expected_x, value(&root, "overflow-x"));
        try std.testing.expectEqualStrings(expected_y, value(&root, "overflow-y"));
        try std.testing.expectEqualStrings(expected_x, value(child, "overflow-x"));
        try std.testing.expectEqualStrings(expected_y, value(child, "overflow-y"));
    };
    try root.element.putOwnedAttribute(allocator, "style", "overflow:visible");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqualStrings("visible", value(&root, "overflow-x"));
    try std.testing.expectEqualStrings("visible", value(&root, "overflow-y"));
}

test "overflow shorthand substitution CSS-wide values and used policy preserve computed ownership" {
    const allocator = std.testing.allocator;
    var root = try parsed("<div style='--axes:visible hidden;overflow:var(--axes)'><span style='overflow:unset'></span></div>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqualStrings("auto", value(&root, "overflow-x"));
    try std.testing.expectEqualStrings("hidden", value(&root, "overflow-y"));
    try std.testing.expectEqualStrings("visible", value(&root.element.children.items[0], "overflow-x"));
    root.element.setScrollGeometry(.{}, true, .{ .client_width = 20, .content_width = 50 });
    try std.testing.expectEqualStrings("auto", value(&root, "overflow-x"));
    try root.element.putOwnedAttribute(allocator, "style", "--axes:clip scroll;overflow:var(--axes);overflow-y:initial");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqualStrings("clip", value(&root, "overflow-x"));
    try std.testing.expectEqualStrings("visible", value(&root, "overflow-y"));
    try root.element.putOwnedAttribute(allocator, "style", "overflow-x:hidden!important;overflow:clip visible");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqualStrings("hidden", value(&root, "overflow-x"));
    try std.testing.expectEqualStrings("auto", value(&root, "overflow-y"));
}

test "overflow user permission follows paint-only visibility changes without resetting offsets" {
    const allocator = std.testing.allocator;
    var root = try parsed("<div style='overflow:auto;visibility:visible'></div>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    root.element.setScrollGeometry(.{ .x = .auto, .y = .auto }, true, .{ .client_width = 20, .content_width = 100, .client_height = 20, .content_height = 100 });
    try std.testing.expect(root.element.scrollTo(30, 40));
    try root.element.putOwnedAttribute(allocator, "style", "overflow:auto;visibility:hidden");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expect(!root.element.scrollByAxis(.x, 10));
    try std.testing.expect(!root.element.scrollByAxis(.y, 10));
    try std.testing.expectEqual(@as(i32, 30), root.element.scroll_x);
    try std.testing.expectEqual(@as(i32, 40), root.element.scroll_y);
    try std.testing.expect(root.element.scrollTo(35, 45));
    try root.element.putOwnedAttribute(allocator, "style", "overflow:auto;visibility:visible");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expect(root.element.scrollByAxis(.x, 10));
    try std.testing.expect(root.element.scrollByAxis(.y, 10));
    try std.testing.expectEqual(@as(i32, 45), root.element.scroll_x);
    try std.testing.expectEqual(@as(i32, 55), root.element.scroll_y);
}

test "HTML hints cascade between user agent and author rules and survive attribute replacement" {
    const allocator = std.testing.allocator;
    const CSSParser = @import("../document/css_parser.zig").CSSParser;
    var css = try CSSParser.init(allocator, "td { width:999px;text-align:left;white-space:normal } * { width:77px }", false);
    defer css.deinit(allocator);
    const rules = try css.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    rules[0].origin = .user_agent;
    var root = try parsed("<td width='25%' align=center nowrap></td>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, rules[0..1]);
    try std.testing.expectEqual(@as(?f64, 100), lengths.resolve(value(&root, "width"), .{ .percentage_base = 400 }));
    try std.testing.expectEqualStrings("-zibra-center", value(&root, "text-align"));
    try std.testing.expectEqualStrings("nowrap", value(&root, "white-space"));
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("77px", value(&root, "width"));
    try root.element.attributes.?.put("width", "160");
    try root.element.attributes.?.put("style", "width:80px;text-align:left;white-space:normal");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("80px", value(&root, "width"));
    try std.testing.expectEqualStrings("left", value(&root, "text-align"));
    try std.testing.expectEqualStrings("normal", value(&root, "white-space"));
    _ = root.element.attributes.?.orderedRemove("style");
    _ = root.element.attributes.?.orderedRemove("nowrap");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqual(@as(?f64, 160), lengths.parsePixel(value(&root, "width")));
    try std.testing.expectEqualStrings("normal", value(&root, "white-space"));
    try root.element.attributes.?.put("width", "0");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqualStrings("auto", value(&root, "width"));
}

test "computed values survive stylesheet source retirement before geometry restyle" {
    const allocator = std.testing.allocator;
    var root = try parsed("<main><span>inherited</span></main>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    {
        const source = try allocator.dupe(u8, "main { width:137px; color:purple; font-family:Georgia; }");
        defer allocator.free(source);
        var css = try @import("../document/css_parser.zig").CSSParser.init(allocator, source, false);
        defer css.deinit(allocator);
        const rules = try css.parse(allocator);
        defer {
            for (rules) |*rule| rule.deinit(allocator);
            allocator.free(rules);
        }
        try document.style(allocator, &root, rules);
        // Poison the old rule backing before freeing it, making borrowed
        // computed strings fail deterministically even with a retaining heap.
        @memset(source, '?');
    }
    try std.testing.expectEqualStrings("137px", value(&root, "width"));
    try std.testing.expectEqualStrings("purple", value(&root.element.children.items[0], "color"));
    try std.testing.expectEqualStrings("Georgia", value(&root, "font-family"));
    dom.dirtyStyleSubtree(&root);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqualStrings("auto", value(&root, "width"));
    try std.testing.expectEqualStrings("black", value(&root.element.children.items[0], "color"));
}

test "user agent sheet hides closed dialogs and emphasizes strong text" {
    const allocator = std.testing.allocator;
    var css = try @import("../document/css_parser.zig").CSSParser.init(allocator, @embedFile("../browser/browser.css"), false);
    defer css.deinit(allocator);
    const rules = try css.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    var root = try parsed("<main><dialog id='closed'>closed</dialog><dialog open>open</dialog><strong>emphasis</strong></main>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("none", value(&root.element.children.items[0], "display"));
    try std.testing.expectEqualStrings("block", value(&root.element.children.items[1], "display"));
    try std.testing.expectEqualStrings("bold", value(&root.element.children.items[2], "font-weight"));
    try root.element.children.items[0].element.attributes.?.put("open", "");
    dom.dirtyStyleForElement(&root.element.children.items[0].element);
    try document.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("block", value(&root.element.children.items[0], "display"));
}

test "root rem sizes use initial font then compute all descendant dimensions" {
    const allocator = std.testing.allocator;
    var root = try parsed("<html style='font-size:2rem;padding:1rem'><div style='font-size:0.5rem;width:3rem;line-height:1.25rem;transform:translate(-2rem, 1rem)'><span style='font-size:200%;height:2rem'></span></div></html>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    const child = &root.element.children.items[0];
    const grandchild = &child.element.children.items[0];
    try std.testing.expectEqual(@as(?f64, 32), lengths.parsePixel(value(&root, "font-size")));
    try std.testing.expectEqual(@as(?f64, 32), lengths.parsePixel(value(&root, "padding-left")));
    try std.testing.expectEqual(@as(?f64, 16), lengths.parsePixel(value(child, "font-size")));
    try std.testing.expectEqual(@as(?f64, 96), lengths.parsePixel(value(child, "width")));
    try std.testing.expectEqual(@as(?f64, 40), lengths.parsePixel(value(child, "line-height")));
    try std.testing.expectEqual(@as(?f64, 32), lengths.parsePixel(value(grandchild, "font-size")));
    try std.testing.expectEqualStrings("translate(-64.000000px, 32.000000px)", value(child, "transform"));
    try root.element.attributes.?.put("style", "font-size:10px;padding:1rem");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqual(@as(?f64, 30), lengths.parsePixel(value(child, "width")));
    try std.testing.expectEqual(@as(?f64, 20), lengths.parsePixel(value(grandchild, "height")));
    try std.testing.expectEqual(@as(?f64, 10), lengths.parsePixel(value(&root, "padding-left")));
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&root));
}

test "variables inherit computed environments and restyle previously missing names" {
    const allocator = std.testing.allocator;
    var root = try parsed("<html style='--tone:red;--alias:var(--tone);--size:1.6rem;font-size:10px'><div style='--tone:blue;color:var(--alias);font-size:var(--size);background-color:var(--new, green)'><span style='color:var(--tone)'></span></div></html>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    const child = &root.element.children.items[0];
    const grandchild = &child.element.children.items[0];
    try std.testing.expectEqualStrings("red", value(child, "color"));
    try std.testing.expectEqualStrings("blue", value(grandchild, "color"));
    try std.testing.expectEqualStrings("green", value(child, "background-color"));
    try std.testing.expectEqual(@as(?f64, 16), lengths.parsePixel(value(child, "font-size")));
    try root.element.attributes.?.put("style", "--tone:orange;--alias:var(--tone);--size:2rem;--new:purple;font-size:10px");
    dom.dirtyStyleForElement(&root.element);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqualStrings("orange", value(child, "color"));
    try std.testing.expectEqualStrings("purple", value(child, "background-color"));
    try std.testing.expectEqualStrings("blue", value(grandchild, "color"));
    try std.testing.expectEqual(@as(?f64, 20), lengths.parsePixel(value(child, "font-size")));
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&root));
    // The structural retirement path drops custom-environment subscribers too.
    dom.clearStyleInvalidations(&root);
    try std.testing.expectEqual(@as(u32, 0), root.element.custom_version.?.invalidations.count());
    try document.style(allocator, &root, &.{});
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&root));
}

test "pending variable shorthands preserve precedence and invalid winning values unset" {
    const allocator = std.testing.allocator;
    var root = try parsed("<html style='color:purple;--edges:1rem 2rem;--font:italic bold 2rem/1.5 serif;--bad:garbage;--n:10'><div style='font-size:99px;font:var(--font);margin-left:90px;margin:var(--edges)!important;margin-right:7px;color:red;color:var(--bad);width:30px;width:var(--n)px;background-color:var(--missing)'></div></html>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    const child = &root.element.children.items[0];
    try std.testing.expectEqual(@as(?f64, 32), lengths.parsePixel(value(child, "font-size")));
    try std.testing.expectEqualStrings("italic", value(child, "font-style"));
    try std.testing.expectEqualStrings("serif", value(child, "font-family"));
    try std.testing.expectEqual(@as(?f64, 32), lengths.parsePixel(value(child, "margin-right")));
    try std.testing.expectEqual(@as(?f64, 16), lengths.parsePixel(value(child, "margin-top")));
    try std.testing.expectEqualStrings("purple", value(child, "color"));
    try std.testing.expectEqualStrings("auto", value(child, "width"));
    try std.testing.expectEqualStrings("transparent", value(child, "background-color"));
}

test "root rem math and independent document roots use their own font context" {
    const allocator = std.testing.allocator;
    var root = try parsed("<html style='font-size:calc(1rem + 4px)'><div style='font-size:calc(2rem - 4px);line-height:calc(1rem + 50%);padding:calc(1rem / 2)'></div></html>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    const child = &root.element.children.items[0];
    try std.testing.expectEqual(@as(?f64, 20), lengths.parsePixel(value(&root, "font-size")));
    try std.testing.expectEqual(@as(?f64, 36), lengths.parsePixel(value(child, "font-size")));
    try std.testing.expectEqual(@as(?f64, 38), lengths.parsePixel(value(child, "line-height")));
    try std.testing.expectEqual(@as(?f64, 10), lengths.resolve(value(child, "padding-top"), .{}));
    var other = try parsed("<html style='font-size:10px'><div style='font-size:2rem'></div></html>");
    defer other.deinit(allocator);
    document.fixParentPointers(&other, null);
    try document.style(allocator, &other, &.{});
    try std.testing.expectEqual(@as(?f64, 20), lengths.parsePixel(value(&other.element.children.items[0], "font-size")));
}

test "keyframe endpoints resolve variables and rem and refresh their root dependency" {
    const allocator = std.testing.allocator;
    const CSSParser = @import("../document/css_parser.zig");
    var css = try CSSParser.init(allocator, "@keyframes move { from { width:var(--start);transform:translate(1rem,0);background-color:var(--tone); } to { width:calc(4rem + 10px);transform:translate(3rem,0);background-color:blue; } }", false);
    defer css.deinit(allocator);
    var frames: std.ArrayList(CSSParser.KeyframesRule) = .empty;
    defer {
        for (frames.items) |*frame| frame.deinit(allocator);
        frames.deinit(allocator);
    }
    const rules = try css.parseWithKeyframes(allocator, &frames);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    var root = try parsed("<html style='font-size:10px;--start:2rem;--tone:red'><div style='animation:move 1s linear'></div></html>");
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.styleWithKeyframes(allocator, &root, rules, frames.items);
    const child = &root.element.children.items[0].element;
    const width = child.animations.?.get("width").?.pixel.numeric;
    try std.testing.expectEqual(@as(f64, 20), width.start_value);
    try std.testing.expectEqual(@as(f64, 50), width.end_value);
    try std.testing.expectEqual(@as(f64, 10), child.animations.?.get("transform").?.transform.start_value.x);
    try std.testing.expect(child.animations.?.contains("background-color"));
    const signature = child.css_animation.?.signature;
    try root.element.attributes.?.put("style", "font-size:20px;--start:2rem;--tone:green");
    dom.dirtyStyleForElement(&root.element);
    try document.styleWithKeyframes(allocator, &root, rules, frames.items);
    try std.testing.expectEqual(@as(f64, 40), child.animations.?.get("width").?.pixel.numeric.start_value);
    try std.testing.expectEqual(@as(f64, 90), child.animations.?.get("width").?.pixel.numeric.end_value);
    try std.testing.expectEqual(@as(f64, 60), child.animations.?.get("transform").?.transform.end_value.x);
    try std.testing.expect(signature != child.css_animation.?.signature);
}
