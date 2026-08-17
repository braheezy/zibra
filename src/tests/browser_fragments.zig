//! Focused fragment-target lookup and scroll-range tests.

const std = @import("std");
const Layout = @import("../browser/render/layout.zig");
const tab_module = @import("../browser/tab.zig");
const parser = @import("../document/parser.zig");

test "fragment targets decode ids, clamp to the scroll range, and support page top" {
    const allocator = std.testing.allocator;

    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.accessibility = .{};
    tab.tab_height = 200;
    tab.scroll_changed_in_tab = false;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var target = parser.Node{
        .element = try parser.Element.init(allocator, "h2 id=section-two", null),
    };
    defer target.deinit(allocator);

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    frame.viewport_height = 200;
    frame.content_height = 1000;
    try frame.fragment_targets.append(allocator, Layout.FragmentTarget{
        .node = &target,
        .y = 600,
    });

    try std.testing.expectEqual(@as(?i32, 600), frame.scrollOffsetForFragment("section%2Dtwo"));
    try std.testing.expect(frame.scrollToFragment("section%2Dtwo"));
    try std.testing.expectEqual(@as(i32, 600), frame.scroll);
    try std.testing.expect(tab.scroll_changed_in_tab);

    frame.fragment_targets.items[0].y = 950;
    try std.testing.expectEqual(@as(?i32, 800), frame.scrollOffsetForFragment("section-two"));

    frame.scroll = 400;
    try std.testing.expect(!frame.scrollToFragment("missing"));
    try std.testing.expectEqual(@as(i32, 400), frame.scroll);

    try std.testing.expect(frame.scrollToFragment(""));
    try std.testing.expectEqual(@as(i32, 0), frame.scroll);
}
