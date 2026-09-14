//! Layer precedence through retained stylesheet generations and real styles.
const std = @import("std");
const dom = @import("../document/parser.zig");
const Page = @import("../document/inspection.zig").Page;
const stylesheet = @import("../document/css_stylesheet.zig");
const allocator = std.testing.allocator;

fn target(node: *dom.Node, id: []const u8) ?*dom.Node {
    if (node.* != .element) return null;
    if (node.element.attributes) |attrs| if (attrs.get("id")) |name| {
        if (std.mem.eql(u8, id, name)) return node;
    };
    for (node.element.children.items) |*child| if (target(child, id)) |found| return found;
    return null;
}

fn value(node: *dom.Node, property: []const u8) []const u8 {
    return node.element.style.?.getPtr(property).?.get().*;
}

test "cascade layers order sheets before specificity and preserve important inline and pseudo precedence" {
    var page = try Page.fromHtml(allocator,
        \\<style>@layer reset, components, utilities;</style>
        \\<style>@layer utilities {
        \\ .normal {color:green;--space:7px;margin:var(--space)}
        \\ .important {color:red!important}
        \\ .inline {color:red!important}
        \\ .inline-normal {color:red}
        \\ .inline-loses {color:green!important}
        \\ .pseudo::before {content:'pass';color:green}
        \\}</style>
        \\<style>@layer reset {
        \\ #normal {color:red;--space:19px}
        \\ .important {color:green!important}
        \\ .inline {color:red!important}
        \\ #pseudo::before {content:'fail';color:red}
        \\} @layer components { .important {color:red!important} }
        \\ .outside {color:green} @layer utilities {#outside{color:red}}
        \\ #important {color:red!important}
        \\</style>
        \\<div id=normal class=normal></div><div id=important class=important></div>
        \\<div id=inline class=inline style='color:green!important'></div>
        \\<div id=inline-normal class=inline-normal style='color:green'></div>
        \\<div id=inline-loses class=inline-loses style='color:red'></div>
        \\<div id=inline-important class=inline-normal style='color:green!important'></div>
        \\<div id=outside class=outside></div><div id=pseudo class=pseudo></div>
    , .{});
    defer page.deinit();
    page.repairParentPointers();
    for ([_][]const u8{ "normal", "important", "inline", "inline-normal", "inline-loses", "inline-important", "outside" }) |id| {
        try std.testing.expectEqualStrings("green", value(target(&page.root, id).?, "color"));
    }
    try std.testing.expectEqualStrings("7px", value(target(&page.root, "normal").?, "margin-left"));
    try std.testing.expectEqualStrings("green", value(target(&page.root, "pseudo").?.element.generated_before.?, "color"));
}

test "cascade layer registries are independent for each origin" {
    var ua = try stylesheet.Sheet.init(allocator, "@layer first, last; @layer last{div{color:red!important}} @layer first{div{color:green!important}}", .{ .origin = .user_agent });
    defer ua.deinit();
    var author = try stylesheet.Sheet.init(allocator, "@layer last, first; @layer last{div{color:purple!important}}", .{});
    defer author.deinit();
    var builder = stylesheet.SelectionBuilder.init(allocator);
    defer builder.deinit();
    // Interleave origins deliberately: author naming must not reorder UA.
    try builder.append(author, .{}, null);
    try builder.append(ua, .{}, null);
    var selected = try builder.finish();
    defer selected.deinit();
    var root = dom.Node{ .element = try dom.Element.init(allocator, "div", null) };
    defer root.deinit(allocator);
    try dom.style(allocator, &root, selected.rules);
    try std.testing.expectEqualStrings("green", value(&root, "color"));
}

test "cascade layers in the standalone parser publish resolved ranks and conditional keyframes" {
    const css = @import("../document/css_parser.zig");
    var parser = try css.init(allocator, "@layer base, theme; @layer theme{div{color:green}} " ++
        "@media(min-width:600px){@layer base{div{color:red}@keyframes pulse{from,to{opacity:0.2}}}}", false);
    defer parser.deinit(allocator);
    parser.media.viewport_width_css = 800;
    var keyframes: std.ArrayList(css.KeyframesRule) = .empty;
    defer {
        for (keyframes.items) |*rule| rule.deinit(allocator);
        keyframes.deinit(allocator);
    }
    const rules = try parser.parseWithKeyframes(allocator, &keyframes);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expect(rules[0].layer.order() > rules[1].layer.order());
    try std.testing.expectEqual(rules[1].layer.order(), keyframes.items[0].layer.order());
}

test "cascade layer children added by later sheets stay below their parent and adjacent layers" {
    var page = try Page.fromHtml(allocator,
        \\<style>@layer base, theme;
        \\ @layer base { #normal{color:green} #important{color:red!important} }
        \\ @layer theme { #adjacent{color:green} }
        \\</style>
        \\<style>@layer base.child {div{color:red} #important{color:green!important}}
        \\ @layer base.child.grandchild {#important{color:blue!important}}
        \\ @layer base.child.grandchild {#important{color:green!important}}
        \\</style>
        \\<div id=normal></div><div id=important></div><div id=adjacent></div>
    , .{});
    defer page.deinit();
    page.repairParentPointers();
    for ([_][]const u8{ "normal", "important", "adjacent" }) |id| try std.testing.expectEqualStrings("green", value(target(&page.root, id).?, "color"));
}

test "cascade layer grammar recovery escapes and style nesting preserve the enclosing selector" {
    var page = try Page.fromHtml(allocator,
        \\<style>
        \\ .card { @layer theme, base; }
        \\ @layer theme,; @layer base, theme;
        \\ @layer base {#nested{color:red}}
        \\ .card { @layer theme {color:green; & > .child{color:green}} }
        \\ @layer initial { #nested {color:red!important} }
        \\ @layer foo\2e bar, foo.bar;
        \\ @layer foo.bar {#escaped {color:green}}
        \\ @layer foo\.bar {#escaped {color:red}}
        \\ @layer Case, case;
        \\ @layer case {#case{color:green}} @layer Case{#case{color:red}}
        \\ @layer { #anonymous{color:green!important} }
        \\ @layer { #anonymous{color:red!important} }
        \\</style>
        \\<div id=nested class=card><span id=child class=child></span></div>
        \\<div id=escaped></div><div id=case></div><div id=anonymous></div>
    , .{});
    defer page.deinit();
    page.repairParentPointers();
    for ([_][]const u8{ "nested", "child", "escaped", "case", "anonymous" }) |id| try std.testing.expectEqualStrings("green", value(target(&page.root, id).?, "color"));
}

test "cascade layer ordering is rebuilt from active retained conditions and sheet media" {
    var page = try Page.fromHtml(allocator,
        \\<style media='(min-width:600px)'>@layer theme;</style>
        \\<style>@supports (not-a-property:yes){@layer theme}
        \\ @media (min-width:600px) {@layer motion;}
        \\ @layer base, theme, motion;
        \\ @layer base {#target{color:red} #important{color:green!important}}
        \\ @layer theme {#target{color:green} #important{color:red!important}}
        \\</style><div id=target></div><div id=important></div>
    , .{ .media = .{ .viewport_width_css = 400 } });
    defer page.deinit();
    page.repairParentPointers();
    const compiled = page.sheets.items[2].rules.ptr;
    const declarations = page.sheets.items[2].layer_program.declarations.items.ptr;
    for ([_]f64{ 400, 800, 400 }) |width| {
        try page.reselectMedia(.{ .viewport_width_css = width });
        try page.restyle();
        try std.testing.expectEqualStrings(if (width == 400) "green" else "red", value(target(&page.root, "target").?, "color"));
        try std.testing.expectEqualStrings(if (width == 400) "green" else "red", value(target(&page.root, "important").?, "color"));
        try std.testing.expectEqual(compiled, page.sheets.items[2].rules.ptr);
        try std.testing.expectEqual(declarations, page.sheets.items[2].layer_program.declarations.items.ptr);
    }
    try page.replaceStylesheet(1, "@layer theme, base;");
    try page.restyle();
    // The replaced sheet is still inactive at 400px; metadata is preserved.
    try std.testing.expectEqualStrings("green", value(target(&page.root, "target").?, "color"));
    try page.replaceStylesheet(2, "@layer theme, base; @layer theme{#target{color:red}} @layer base{#target{color:green}}");
    try page.restyle();
    try std.testing.expectEqualStrings("green", value(target(&page.root, "target").?, "color"));
}

test "cascade layer keyframe definitions follow normal layer order across sheets" {
    var page = try Page.fromHtml(allocator,
        \\<style>@layer base, theme;
        \\ div {animation: pulse 1s paused; opacity:1}
        \\ @layer theme {@keyframes pulse{from,to{opacity:0.4}}}
        \\</style>
        \\<style>@layer base {@keyframes pulse{from,to{opacity:0.9}}}</style>
        \\<div id=target></div>
    , .{});
    defer page.deinit();
    page.repairParentPointers();
    const element = &target(&page.root, "target").?.element;
    try std.testing.expectEqual(@as(f64, 0.4), element.animations.?.get("opacity").?.numeric.getValue());
    try page.replaceStylesheet(2, "@keyframes pulse{from,to{opacity:0.7}}");
    try page.restyle();
    try std.testing.expectEqual(@as(f64, 0.7), element.animations.?.get("opacity").?.numeric.getValue());
}

fn allocationTrial(test_allocator: std.mem.Allocator) !void {
    var first = try stylesheet.Sheet.init(test_allocator, "@layer base, theme; @layer theme{div{background-image:url(win.png)}}", .{ .base_url = "https://example.test/theme.css" });
    defer first.deinit();
    var second = try stylesheet.Sheet.init(test_allocator, "@layer base.child { div {background-image:url(lose.png)} @keyframes pulse{from,to{opacity:0.5}} }", .{});
    defer second.deinit();
    var builder = stylesheet.SelectionBuilder.init(test_allocator);
    defer builder.deinit();
    try builder.append(first, .{}, null);
    try builder.append(second, .{}, null);
    var selected = try builder.finish();
    defer selected.deinit();
    var root = dom.Node{ .element = try dom.Element.init(test_allocator, "div", null) };
    defer root.deinit(test_allocator);
    try dom.style(test_allocator, &root, selected.rules);
    try std.testing.expectEqualStrings("https://example.test/theme.css", root.element.background_source_url.?);
    try std.testing.expectEqual(@as(usize, 1), selected.keyframes.len);
}

test "cascade layer stylesheet compilation selection and provenance unwind every allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, allocationTrial, .{});
}
