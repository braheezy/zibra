//! Focused ownership and state tests for tab navigation history.

const std = @import("std");
const Browser = @import("../browser/root.zig").Browser;
const Chrome = @import("../browser/chrome.zig");
const tab_module = @import("../browser/tab.zig");
const Url = @import("../network/url.zig").Url;

fn commitUrl(
    tab: *tab_module.Tab,
    text: []const u8,
    target_path: []const usize,
    replaces_document: bool,
) !void {
    return commitRequest(tab, text, null, target_path, replaces_document);
}

fn commitRequest(
    tab: *tab_module.Tab,
    text: []const u8,
    payload: ?[]const u8,
    target_path: []const usize,
    replaces_document: bool,
) !void {
    const url = try Url.init(tab.allocator, text);
    defer url.free(tab.allocator);
    try tab.commitHistoryNavigationForPath(
        &url,
        payload,
        target_path,
        replaces_document,
    );
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

    try commitUrl(&tab, "https://example.com/a", &.{}, true);
    try std.testing.expectEqual(@as(?usize, 0), tab.history_index);
    try std.testing.expect(!tab.canGoBack());
    try std.testing.expect(!tab.canGoForward());

    try commitUrl(&tab, "https://example.com/b", &.{}, true);
    try commitUrl(&tab, "https://example.com/c", &.{}, true);
    try std.testing.expectEqual(@as(?usize, 2), tab.history_index);
    try std.testing.expect(tab.canGoBack());
    try std.testing.expect(!tab.canGoForward());

    const back = tab.historyTraversalTarget(.back).?;
    try std.testing.expect(tab.finishHistoryTraversal(back.index, back.generation));
    try std.testing.expectEqual(@as(?usize, 1), tab.history_index);
    try std.testing.expect(tab.canGoBack());
    try std.testing.expect(tab.canGoForward());
    try std.testing.expectEqual(@as(usize, 3), tab.history.items.len);

    // A normal navigation after Back replaces the forward branch.
    try commitUrl(&tab, "https://example.com/d", &.{}, true);
    try std.testing.expectEqual(@as(?usize, 2), tab.history_index);
    try std.testing.expectEqual(@as(usize, 3), tab.history.items.len);
    try std.testing.expectEqualStrings("/a", tab.history.items[0].url.path);
    try std.testing.expectEqualStrings("/b", tab.history.items[1].url.path);
    try std.testing.expectEqualStrings("/d", tab.history.items[2].url.path);
    try std.testing.expect(tab.canGoBack());
    try std.testing.expect(!tab.canGoForward());

    var target = tab.historyTraversalTarget(.back).?;
    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));
    target = tab.historyTraversalTarget(.back).?;
    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));
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

    try commitUrl(&tab, "https://example.com/start", &.{}, true);
    const submitted = try allocator.dupe(u8, "q=original");
    defer allocator.free(submitted);
    try commitRequest(&tab, "https://example.com/results", submitted, &.{}, true);
    submitted[2] = 'X';
    try commitUrl(&tab, "https://example.com/after", &.{}, true);

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

    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));
    try std.testing.expectEqual(@as(?usize, 1), tab.history_index);
    try std.testing.expectEqual(tab_module.HistoryMethod.post, tab.history.items[1].method);
    try std.testing.expectEqualStrings("q=original", tab.history.items[1].post_body.?);
    try std.testing.expect(target.generation != tab.history_generation);

    const forward = tab.historyTraversalTarget(.forward).?;
    try std.testing.expectEqual(tab_module.HistoryMethod.get, forward.method);
}

test "joint history orders interleaved sibling-frame navigations" {
    const allocator = std.testing.allocator;
    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.history = .empty;
    defer deinitHistory(&tab);
    tab.history_index = null;
    tab.history_can_go_back = std.atomic.Value(bool).init(false);
    tab.history_can_go_forward = std.atomic.Value(bool).init(false);
    tab.history_generation = 0;

    try commitUrl(&tab, "https://example.com/root", &.{}, true);
    var first_frame_path = [_]usize{0};
    try commitUrl(&tab, "https://example.com/frame-a/one", &first_frame_path, true);
    // The entry owns its path; a caller can immediately reuse its buffer.
    first_frame_path[0] = 99;
    try commitUrl(&tab, "https://example.com/frame-b/one", &.{1}, true);

    try std.testing.expectEqualSlices(usize, &.{0}, tab.history.items[1].target_path);
    try std.testing.expectEqualSlices(usize, &.{1}, tab.history.items[2].target_path);
    try std.testing.expect(tab.canGoBack());

    // Back from B reconstructs root + A, leaving B at its authored URL.
    var target = tab.historyTraversalTarget(.back).?;
    try std.testing.expectEqual(@as(usize, 1), target.index);
    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));

    // The next Back reconstructs only the root state, undoing A second.
    target = tab.historyTraversalTarget(.back).?;
    try std.testing.expectEqual(@as(usize, 0), target.index);
    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));

    // Forward restores A, followed by B, in their original chronology.
    target = tab.historyTraversalTarget(.forward).?;
    try std.testing.expectEqual(@as(usize, 1), target.index);
    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));
    target = tab.historyTraversalTarget(.forward).?;
    try std.testing.expectEqual(@as(usize, 2), target.index);
    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));

    // A new iframe navigation after Back truncates the old B forward action.
    target = tab.historyTraversalTarget(.back).?;
    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));
    try commitUrl(&tab, "https://example.com/frame-a/two", &.{0}, true);
    try std.testing.expectEqual(@as(usize, 3), tab.history.items.len);
    try std.testing.expectEqualStrings("/frame-a/two", tab.history.items[2].url.path);
    try std.testing.expectEqualSlices(usize, &.{0}, tab.history.items[2].target_path);
    try std.testing.expect(!tab.canGoForward());
}

test "parent-frame history snapshots retain nested request state" {
    const allocator = std.testing.allocator;
    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.history = .empty;
    defer deinitHistory(&tab);
    tab.history_index = null;
    tab.history_can_go_back = std.atomic.Value(bool).init(false);
    tab.history_can_go_forward = std.atomic.Value(bool).init(false);
    tab.history_generation = 0;
    tab.root_frame = null;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var root = tab_module.Frame.init(allocator, &tab, null, null);
    defer root.deinit();
    tab.root_frame = &root;
    const parent = try allocator.create(tab_module.Frame);
    parent.* = tab_module.Frame.init(allocator, &tab, &root, null);
    try root.children.append(allocator, parent);
    const nested = try allocator.create(tab_module.Frame);
    nested.* = tab_module.Frame.init(allocator, &tab, parent, null);
    try parent.children.append(allocator, nested);

    const root_url = try Url.init(allocator, "https://example.com/root");
    defer root_url.free(allocator);
    root.current_url = @constCast(&root_url);
    const parent_url = try Url.init(allocator, "https://example.com/parent");
    defer parent_url.free(allocator);
    parent.current_url = @constCast(&parent_url);
    const nested_url = try Url.init(allocator, "https://example.com/nested/post");
    defer nested_url.free(allocator);
    nested.current_url = @constCast(&nested_url);

    try commitUrl(&tab, "https://example.com/root", &.{}, true);
    try commitRequest(
        &tab,
        "https://example.com/nested/post",
        "message=old",
        &.{ 0, 0 },
        true,
    );
    const replacement_url = try Url.init(allocator, "https://example.com/parent/replaced");
    defer replacement_url.free(allocator);
    var prepared = try tab.prepareHistoryNavigation(parent, &replacement_url, null, true);
    defer prepared.deinit(allocator);
    tab.commitPreparedHistoryNavigation(&prepared);

    const entry = tab.history.items[2];
    try std.testing.expectEqualSlices(usize, &.{0}, entry.target_path);
    const previous = entry.previous.?;
    try std.testing.expectEqualStrings("/parent", previous.url.path);
    try std.testing.expectEqual(@as(usize, 1), previous.children.items.len);
    try std.testing.expectEqualStrings("/nested/post", previous.children.items[0].url.path);
    try std.testing.expectEqual(tab_module.HistoryMethod.post, previous.children.items[0].method);
    try std.testing.expectEqualStrings("message=old", previous.children.items[0].post_body.?);

    // Going back across the parent replacement must prompt because restoring
    // its exact prior subtree requires replaying the nested POST.
    const target = tab.historyTraversalTarget(.back).?;
    try std.testing.expectEqual(@as(usize, 1), target.index);
    try std.testing.expectEqual(tab_module.HistoryMethod.post, target.method);

    // Once the parent replacement is current, an older nested POST no longer
    // describes the newly created descendant at the same index path.
    const reset_nested_url = try Url.init(allocator, "https://example.com/nested/initial");
    defer reset_nested_url.free(allocator);
    nested.current_url = @constCast(&reset_nested_url);
    const next_nested_url = try Url.init(allocator, "https://example.com/nested/next");
    defer next_nested_url.free(allocator);
    var nested_prepared = try tab.prepareHistoryNavigation(nested, &next_nested_url, null, true);
    defer nested_prepared.deinit(allocator);
    try std.testing.expectEqual(
        tab_module.HistoryMethod.get,
        nested_prepared.entry.?.previous.?.method,
    );
}

test "same-document history never requests POST resubmission" {
    const allocator = std.testing.allocator;
    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.history = .empty;
    defer deinitHistory(&tab);
    tab.history_index = null;
    tab.history_can_go_back = std.atomic.Value(bool).init(false);
    tab.history_can_go_forward = std.atomic.Value(bool).init(false);
    tab.history_generation = 0;

    try commitRequest(
        &tab,
        "https://example.com/results",
        "q=original",
        &.{},
        true,
    );
    try commitRequest(
        &tab,
        "https://example.com/results#details",
        "q=original",
        &.{},
        false,
    );

    var target = tab.historyTraversalTarget(.back).?;
    try std.testing.expectEqual(tab_module.HistoryMethod.get, target.method);
    try std.testing.expect(tab.finishHistoryTraversal(target.index, target.generation));
    target = tab.historyTraversalTarget(.forward).?;
    try std.testing.expectEqual(tab_module.HistoryMethod.get, target.method);
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
