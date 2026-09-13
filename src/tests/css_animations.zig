//! Animation cascade and phase publication through real styled Elements.
const std = @import("std");
const dom = @import("../document/parser.zig");
const Sheet = @import("../document/css_stylesheet.zig").Sheet;
const allocator = std.testing.allocator;

test "animation none and CSS-wide identifiers cannot declare keyframes" {
    var sheet = try Sheet.init(allocator, "@keyframes none {to{opacity:0}} @keyframes INITIAL {to{opacity:0}} @keyframes \\6e one {to{opacity:0}} div{animation-fill-mode:forwards}", .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 0), selected.keyframes.len);
    var root = dom.Node{ .element = try dom.Element.init(allocator, "div", null) };
    defer root.deinit(allocator);
    try dom.styleWithKeyframes(allocator, &root, selected.rules, selected.keyframes);
    try std.testing.expect(root.element.css_animation == null);
}

test "animation fill modes publish delay and terminal values without changing underlying style" {
    var sheet = try Sheet.init(allocator, "@keyframes fade {from {opacity:0} to {opacity:1;width:200px}}", .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    const cases = [_]struct { style: []const u8, before: ?f64, after: ?f64 }{
        .{ .style = "opacity:.4;width:100px;animation:fade 2s linear 1s none", .before = null, .after = null },
        .{ .style = "opacity:.4;width:100px;animation:fade 2s linear 1s forwards", .before = null, .after = 1 },
        .{ .style = "opacity:.4;width:100px;animation:fade 2s linear 1s backwards", .before = 0, .after = null },
        .{ .style = "opacity:.4;width:100px;animation:fade 2s linear 1s both", .before = 0, .after = 1 },
        .{ .style = "opacity:.4;width:100px;animation:fade 2s linear 1s reverse both", .before = 1, .after = 0 },
    };
    for (cases) |case| {
        var root = dom.Node{ .element = try dom.Element.init(allocator, "div", null) };
        defer root.deinit(allocator);
        root.element.attributes = @import("../document/attributes.zig").Map.init(allocator);
        try root.element.attributes.?.put("style", case.style);
        try dom.styleWithKeyframes(allocator, &root, selected.rules, selected.keyframes);
        const element = &root.element;
        try std.testing.expectEqual(case.before, element.css_animation.?.progress);
        try std.testing.expectEqualStrings("0.4", element.style.?.getPtr("opacity").?.get().*);
        element.css_animation.?.elapsed_frames = 90;
        element.css_animation.?.publish(&element.animations.?);
        const reverse = element.css_animation.?.timing.direction == .reverse;
        try std.testing.expectEqual(@as(f64, if (reverse) 0.75 else 0.25), element.animations.?.get("opacity").?.numeric.getValue());
        try std.testing.expectEqual(@as(f64, if (reverse) 175 else 125), element.animations.?.get("width").?.pixel.getValue());
        element.css_animation.?.elapsed_frames = 180;
        element.css_animation.?.publish(&element.animations.?);
        try std.testing.expectEqual(case.after, element.css_animation.?.progress);
        try std.testing.expect(!element.css_animation.?.isRunning());
        dom.dirtyStyleForElement(element);
        try dom.styleWithKeyframes(allocator, &root, selected.rules, selected.keyframes);
        try std.testing.expectEqual(@as(f64, 180), element.css_animation.?.elapsed_frames);
        try std.testing.expectEqual(case.after, element.css_animation.?.progress);
        try std.testing.expectEqualStrings("100px", element.style.?.getPtr("width").?.get().*);
    }
}

test "animation longhand edits retain elapsed time and important declarations override effects" {
    var sheet = try Sheet.init(allocator, "@keyframes fade {from {opacity:0;width:0px} to {opacity:1;width:200px}}", .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    var root = dom.Node{ .element = try dom.Element.init(allocator, "div", null) };
    defer root.deinit(allocator);
    root.element.attributes = @import("../document/attributes.zig").Map.init(allocator);
    const element = &root.element;
    try element.attributes.?.put("style", "animation:fade 2s linear -1s both paused;width:80px!important");
    try dom.styleWithKeyframes(allocator, &root, selected.rules, selected.keyframes);
    try std.testing.expectEqual(@as(f64, 0.5), element.animations.?.get("opacity").?.numeric.getValue());
    try std.testing.expect(!element.css_animation.?.isRunning());
    try std.testing.expect(element.animations.?.get("width") == null);
    element.css_animation.?.elapsed_frames = 120;
    element.css_animation.?.publish(&element.animations.?);
    try element.attributes.?.put("style", "animation:fade 2s linear -1s none paused");
    dom.dirtyStyleForElement(element);
    try dom.styleWithKeyframes(allocator, &root, selected.rules, selected.keyframes);
    try std.testing.expectEqual(@as(f64, 120), element.css_animation.?.elapsed_frames);
    try std.testing.expect(element.animations.?.get("opacity") == null);
    try element.attributes.?.put("style", "animation:fade 2s linear -1s forwards paused");
    dom.dirtyStyleForElement(element);
    try dom.styleWithKeyframes(allocator, &root, selected.rules, selected.keyframes);
    try std.testing.expectEqual(@as(f64, 1), element.animations.?.get("opacity").?.numeric.getValue());
    try element.attributes.?.put("style", "animation:none");
    dom.dirtyStyleForElement(element);
    try dom.styleWithKeyframes(allocator, &root, selected.rules, selected.keyframes);
    try std.testing.expect(element.css_animation == null);
    try std.testing.expectEqual(@as(u32, 0), element.animations.?.count());
}
