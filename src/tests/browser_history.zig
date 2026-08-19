//! Focused ownership and state tests for tab navigation history.

const std = @import("std");
const Browser = @import("../browser/root.zig").Browser;
const Chrome = @import("../browser/chrome.zig");
const tab_module = @import("../browser/tab.zig");
const Url = @import("../network/url.zig").Url;

fn commitUrl(
    tab: *tab_module.Tab,
    text: []const u8,
    navigation: tab_module.HistoryNavigation,
) !void {
    return commitRequest(tab, text, null, navigation);
}

fn commitRequest(
    tab: *tab_module.Tab,
    text: []const u8,
    payload: ?[]const u8,
    navigation: tab_module.HistoryNavigation,
) !void {
    const url_ptr = try tab.allocator.create(Url);
    errdefer tab.allocator.destroy(url_ptr);
    url_ptr.* = try Url.init(tab.allocator, text);
    var url_owned = true;
    defer if (url_owned) url_ptr.*.free(tab.allocator);

    try tab.commitHistoryNavigation(url_ptr, payload, navigation);
    url_owned = false;
}

fn deinitHistory(tab: *tab_module.Tab) void {
    for (tab.history.items) |entry| entry.deinit(tab.allocator);
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
    tab.history_generation = 0;

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
    try std.testing.expectEqualStrings("/a", tab.history.items[0].url.path);
    try std.testing.expectEqualStrings("/b", tab.history.items[1].url.path);
    try std.testing.expectEqualStrings("/d", tab.history.items[2].url.path);
    try std.testing.expect(tab.canGoBack());
    try std.testing.expect(!tab.canGoForward());

    try commitUrl(&tab, "https://example.com/a", .{ .traverse = 0 });
    try std.testing.expect(!tab.canGoBack());
    try std.testing.expect(tab.canGoForward());
}

test "history owns POST bodies and identifies resubmission targets" {
    const allocator = std.testing.allocator;
    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.history = .empty;
    defer deinitHistory(&tab);
    tab.history_index = null;
    tab.history_can_go_back = std.atomic.Value(bool).init(false);
    tab.history_can_go_forward = std.atomic.Value(bool).init(false);
    tab.history_generation = 0;

    try commitUrl(&tab, "https://example.com/start", .push);
    const submitted = try allocator.dupe(u8, "q=original");
    defer allocator.free(submitted);
    try commitRequest(&tab, "https://example.com/results", submitted, .push);
    submitted[2] = 'X';
    try commitUrl(&tab, "https://example.com/after", .push);

    try std.testing.expectEqual(tab_module.HistoryMethod.get, tab.history.items[0].method);
    try std.testing.expect(tab.history.items[0].post_body == null);
    try std.testing.expectEqual(tab_module.HistoryMethod.post, tab.history.items[1].method);
    try std.testing.expectEqualStrings("q=original", tab.history.items[1].post_body.?);

    const target = tab.historyTraversalTarget(.back).?;
    try std.testing.expectEqual(@as(usize, 1), target.index);
    try std.testing.expectEqual(tab_module.HistoryMethod.post, target.method);
    // Planning or declining a replay does not move history.
    try std.testing.expectEqual(@as(?usize, 2), tab.history_index);

    var test_browser: Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = .empty;
    defer test_browser.tabs.deinit(allocator);
    try test_browser.tabs.append(allocator, &tab);
    test_browser.active_tab_index = 0;
    test_browser.shutting_down = false;
    test_browser.pending_post_resubmission = null;
    test_browser.post_resubmission_dialog_active = false;

    try tab.traverseHistory(&test_browser, .back);
    try std.testing.expect(test_browser.pending_post_resubmission != null);
    try std.testing.expectEqual(target.index, test_browser.pending_post_resubmission.?.target);
    try std.testing.expectEqual(
        target.generation,
        test_browser.pending_post_resubmission.?.history_generation,
    );
    // Simulate Cancel: consuming the request schedules no load.
    test_browser.pending_post_resubmission = null;
    try std.testing.expectEqual(@as(?usize, 2), tab.history_index);

    const retained_body = tab.history.items[target.index].post_body.?;
    try commitRequest(
        &tab,
        "https://example.com/results",
        retained_body,
        .{ .traverse = target.index },
    );
    try std.testing.expectEqual(@as(?usize, 1), tab.history_index);
    try std.testing.expectEqual(tab_module.HistoryMethod.post, tab.history.items[1].method);
    try std.testing.expectEqualStrings("q=original", tab.history.items[1].post_body.?);
    try std.testing.expect(target.generation != tab.history_generation);

    const forward = tab.historyTraversalTarget(.forward).?;
    try std.testing.expectEqual(tab_module.HistoryMethod.get, forward.method);
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
