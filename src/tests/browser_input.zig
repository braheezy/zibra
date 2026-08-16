//! Focused tests for platform input normalization at the browser boundary.

const std = @import("std");
const browser = @import("../browser/root.zig");
const tab_module = @import("../browser/tab.zig");
const parser_module = @import("../document/parser.zig");
const Url = @import("../network/url.zig").Url;

test "mouse wheel delta preserves magnitude and normalizes direction" {
    try std.testing.expectEqual(@as(i32, -100), browser.wheelScrollDelta(1, false));
    try std.testing.expectEqual(@as(i32, 300), browser.wheelScrollDelta(-3, false));
    try std.testing.expectEqual(@as(i32, 100), browser.wheelScrollDelta(1, true));
    try std.testing.expectEqual(@as(i32, -200), browser.wheelScrollDelta(-2, true));
    try std.testing.expectEqual(@as(i32, 0), browser.wheelScrollDelta(0, false));
}

test "mouse wheel delta saturates instead of overflowing" {
    try std.testing.expectEqual(std.math.minInt(i32), browser.wheelScrollDelta(std.math.maxInt(i32), false));
    try std.testing.expectEqual(std.math.maxInt(i32), browser.wheelScrollDelta(std.math.minInt(i32), false));
}

test "middle-clicking a link queues its resolved URL for a new tab" {
    const allocator = std.testing.allocator;

    var html_parser = try parser_module.HTMLParser.init(
        allocator,
        "<html><body><a href=next.html>next</a></body></html>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var nodes = std.ArrayList(*parser_module.Node).empty;
    defer nodes.deinit(allocator);
    try parser_module.treeToList(allocator, &root, &nodes);
    var link_node: ?*parser_module.Node = null;
    for (nodes.items) |node| {
        switch (node.*) {
            .element => |element| {
                if (std.mem.eql(u8, element.tag, "a")) link_node = node;
            },
            .text => {},
        }
    }
    try std.testing.expect(link_node != null);

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.lock = .init(std.testing.io);
    test_browser.shutting_down = false;
    test_browser.pending_new_tabs = .empty;
    defer {
        for (test_browser.pending_new_tabs.items) |*url| url.free(allocator);
        test_browser.pending_new_tabs.deinit(allocator);
    }

    var tab: tab_module.Tab = undefined;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    var current_url = try Url.init(allocator, "https://example.com/docs/page.html");
    defer current_url.free(allocator);
    frame.current_url = &current_url;
    try frame.link_bounds.append(allocator, .{
        .node = link_node.?,
        .bounds = .{ .x = 10, .y = 20, .width = 100, .height = 30 },
    });

    try std.testing.expect(try frame.click(&test_browser, 25, 25, .middle));
    try std.testing.expectEqual(@as(usize, 1), test_browser.pending_new_tabs.items.len);
    try std.testing.expectEqualStrings(
        "/docs/next.html",
        test_browser.pending_new_tabs.items[0].path,
    );

    try std.testing.expect(!try frame.click(&test_browser, 200, 200, .middle));
    try std.testing.expectEqual(@as(usize, 1), test_browser.pending_new_tabs.items.len);
}

test "tab title updates own their text and dirty only the active window title" {
    const allocator = std.testing.allocator;

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = .empty;
    defer test_browser.tabs.deinit(allocator);
    test_browser.active_tab_index = 0;
    test_browser.window_title_dirty = false;

    var active_tab: tab_module.Tab = undefined;
    active_tab.title = null;
    defer if (active_tab.title) |title| allocator.free(title);
    var inactive_tab: tab_module.Tab = undefined;
    inactive_tab.title = null;
    defer if (inactive_tab.title) |title| allocator.free(title);
    try test_browser.tabs.append(allocator, &active_tab);
    try test_browser.tabs.append(allocator, &inactive_tab);

    test_browser.updateTabTitle(
        &inactive_tab,
        try allocator.dupeZ(u8, "Background title"),
    );
    try std.testing.expect(!test_browser.window_title_dirty);
    try std.testing.expectEqualStrings("Background title", inactive_tab.title.?);

    test_browser.updateTabTitle(
        &active_tab,
        try allocator.dupeZ(u8, "Active title"),
    );
    try std.testing.expect(test_browser.window_title_dirty);
    try std.testing.expectEqualStrings("Active title", active_tab.title.?);

    test_browser.window_title_dirty = false;
    test_browser.updateTabTitle(&active_tab, try allocator.dupeZ(u8, "Replacement"));
    try std.testing.expect(test_browser.window_title_dirty);
    try std.testing.expectEqualStrings("Replacement", active_tab.title.?);
}
