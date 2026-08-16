//! Focused ownership and state tests for tab navigation history.

const std = @import("std");
const Chrome = @import("../browser/chrome.zig");
const tab_module = @import("../browser/tab.zig");
const Url = @import("../network/url.zig").Url;

fn commitUrl(
    tab: *tab_module.Tab,
    text: []const u8,
    navigation: tab_module.HistoryNavigation,
) !void {
    const url_ptr = try tab.allocator.create(Url);
    errdefer tab.allocator.destroy(url_ptr);
    url_ptr.* = try Url.init(tab.allocator, text);
    var url_owned = true;
    defer if (url_owned) url_ptr.*.free(tab.allocator);

    try tab.commitHistoryNavigation(url_ptr, navigation);
    url_owned = false;
}

fn deinitHistory(tab: *tab_module.Tab) void {
    for (tab.history.items) |url_ptr| {
        url_ptr.*.free(tab.allocator);
        tab.allocator.destroy(url_ptr);
    }
    tab.history.deinit(tab.allocator);
}

test "indexed history supports back, forward, and forward-branch truncation" {
    const allocator = std.testing.allocator;
    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.history = .empty;
    defer deinitHistory(&tab);
    tab.history_index = null;
    tab.history_can_go_back = std.atomic.Value(bool).init(false);
    tab.history_can_go_forward = std.atomic.Value(bool).init(false);

    try std.testing.expect(!tab.canGoBack());
    try std.testing.expect(!tab.canGoForward());

    try commitUrl(&tab, "https://example.com/a", .push);
    try std.testing.expectEqual(@as(?usize, 0), tab.history_index);
    try std.testing.expect(!tab.canGoBack());
    try std.testing.expect(!tab.canGoForward());

    try commitUrl(&tab, "https://example.com/b", .push);
    try commitUrl(&tab, "https://example.com/c", .push);
    try std.testing.expectEqual(@as(?usize, 2), tab.history_index);
    try std.testing.expect(tab.canGoBack());
    try std.testing.expect(!tab.canGoForward());

    try commitUrl(&tab, "https://example.com/b", .{ .traverse = 1 });
    try std.testing.expectEqual(@as(?usize, 1), tab.history_index);
    try std.testing.expect(tab.canGoBack());
    try std.testing.expect(tab.canGoForward());
    try std.testing.expectEqual(@as(usize, 3), tab.history.items.len);

    // A normal navigation after Back replaces the forward branch.
    try commitUrl(&tab, "https://example.com/d", .push);
    try std.testing.expectEqual(@as(?usize, 2), tab.history_index);
    try std.testing.expectEqual(@as(usize, 3), tab.history.items.len);
    try std.testing.expectEqualStrings("/a", tab.history.items[0].path);
    try std.testing.expectEqualStrings("/b", tab.history.items[1].path);
    try std.testing.expectEqualStrings("/d", tab.history.items[2].path);
    try std.testing.expect(tab.canGoBack());
    try std.testing.expect(!tab.canGoForward());

    try commitUrl(&tab, "https://example.com/a", .{ .traverse = 0 });
    try std.testing.expect(!tab.canGoBack());
    try std.testing.expect(tab.canGoForward());
}

test "disabled navigation buttons use gray instead of active black" {
    const enabled = Chrome.navigationButtonColor(true);
    const disabled = Chrome.navigationButtonColor(false);

    try std.testing.expectEqual(@as(u8, 0), enabled.r);
    try std.testing.expectEqual(@as(u8, 0), enabled.g);
    try std.testing.expectEqual(@as(u8, 0), enabled.b);
    try std.testing.expectEqual(@as(u8, 160), disabled.r);
    try std.testing.expectEqual(disabled.r, disabled.g);
    try std.testing.expectEqual(disabled.g, disabled.b);
}
