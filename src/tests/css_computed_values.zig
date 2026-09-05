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
