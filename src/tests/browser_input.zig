//! Focused tests for platform input normalization at the browser boundary.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Chrome = @import("../browser/chrome.zig");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const tab_module = @import("../browser/tab.zig");
const parser_module = @import("../document/parser.zig");
const Url = @import("../network/url.zig").Url;

fn initTestChrome(allocator: std.mem.Allocator) Chrome {
    return .{
        .address_bar = std.ArrayList(u8).empty,
        .allocator = allocator,
    };
}

fn enterOnFirstInput(html: []const u8) !bool {
    const allocator = std.testing.allocator;
    var html_parser = try parser_module.HTMLParser.init(allocator, html);
    defer html_parser.deinit(allocator);

    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.root_frame = null;
    tab.focused_frame = null;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    tab.focused_frame = &frame;
    frame.current_node = try html_parser.parse();
    parser_module.fixParentPointers(&frame.current_node.?, null);

    var nodes = std.ArrayList(*parser_module.Node).empty;
    defer nodes.deinit(allocator);
    try parser_module.treeToList(allocator, &frame.current_node.?, &nodes);
    for (nodes.items) |node| {
        switch (node.*) {
            .element => |*element| {
                if (std.ascii.eqlIgnoreCase(element.tag, "input")) {
                    element.is_focused = true;
                    frame.focus = node;
                    break;
                }
            },
            .text => {},
        }
    }
    if (frame.focus == null) return error.TestInputMissing;

    var current_url = try Url.init(allocator, "file:///tmp/form-enter.html");
    defer current_url.free(allocator);
    frame.current_url = &current_url;

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    return tab.enter(&test_browser);
}

test "address bar preserves URLs and turns ordinary text into a search" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .input = "https://example.com/docs?q=one#two",
            .expected = "https://example.com/docs?q=one#two",
        },
        .{
            .input = "example.com/docs",
            .expected = "https://example.com/docs",
        },
        .{
            .input = "localhost:8080/status",
            .expected = "https://localhost:8080/status",
        },
        .{
            .input = "browser engineering",
            .expected = "https://google.com/search?q=browser+engineering",
        },
        .{
            .input = "  zig + browser & fun  ",
            .expected = "https://google.com/search?q=zig+%2B+browser+%26+fun",
        },
        .{
            .input = "hello@example.com",
            .expected = "https://google.com/search?q=hello%40example.com",
        },
    };

    for (cases) |case| {
        const url = try Chrome.addressInputToUrl(allocator, case.input);
        defer url.free(allocator);
        var buffer: [256]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try url.toString(&buffer));
    }
}

test "address cursor movement is focused and clamped to the input boundaries" {
    var chrome = initTestChrome(std.testing.allocator);
    defer chrome.deinit();

    try std.testing.expect(!chrome.isAddressBarFocused());
    try std.testing.expect(!chrome.moveCursorLeft());
    try std.testing.expect(!chrome.moveCursorRight());

    chrome.focusAddressBar();
    try std.testing.expect(chrome.isAddressBarFocused());
    try std.testing.expect(!chrome.moveCursorLeft());
    try std.testing.expect(!chrome.moveCursorRight());

    try std.testing.expect(try chrome.keypress('a'));
    try std.testing.expect(try chrome.keypress('b'));
    try std.testing.expect(try chrome.keypress('c'));
    try std.testing.expectEqual(@as(usize, 3), chrome.address_cursor);
    try std.testing.expect(!chrome.moveCursorRight());

    try std.testing.expect(chrome.moveCursorLeft());
    try std.testing.expect(chrome.moveCursorLeft());
    try std.testing.expect(chrome.moveCursorLeft());
    try std.testing.expectEqual(@as(usize, 0), chrome.address_cursor);
    try std.testing.expect(!chrome.moveCursorLeft());

    try std.testing.expect(chrome.moveCursorRight());
    try std.testing.expect(chrome.moveCursorRight());
    try std.testing.expect(chrome.moveCursorRight());
    try std.testing.expectEqual(chrome.address_bar.items.len, chrome.address_cursor);
    try std.testing.expect(!chrome.moveCursorRight());

    chrome.blur();
    try std.testing.expect(!chrome.isAddressBarFocused());
    try std.testing.expect(!chrome.moveCursorLeft());
    try std.testing.expect(!chrome.moveCursorRight());
}

test "address focus consumes editing keys despite stale document focus" {
    // A DOM input may remain focused after chrome receives focus. Address-bar
    // editing must win even for boundary no-ops such as Backspace at zero.
    try std.testing.expect(!browser.shouldRouteContentEditing(true, null, true));
    try std.testing.expect(!browser.shouldRouteContentEditing(true, "content", true));

    try std.testing.expect(browser.shouldRouteContentEditing(false, "content", false));
    try std.testing.expect(browser.shouldRouteContentEditing(false, null, true));
    try std.testing.expect(!browser.shouldRouteContentEditing(false, null, false));
    try std.testing.expect(!browser.shouldRouteContentEditing(false, "chrome", true));

    var chrome = initTestChrome(std.testing.allocator);
    defer chrome.deinit();
    chrome.focusAddressBar();
    try std.testing.expect(!chrome.backspace());
    try std.testing.expect(!browser.shouldRouteContentEditing(
        chrome.isAddressBarFocused(),
        null,
        true,
    ));
}

test "address input inserts at the cursor and backspace deletes before it" {
    var chrome = initTestChrome(std.testing.allocator);
    defer chrome.deinit();
    chrome.focusAddressBar();

    try std.testing.expect(try chrome.keypress('a'));
    try std.testing.expect(try chrome.keypress('c'));
    try std.testing.expect(chrome.moveCursorLeft());
    try std.testing.expect(try chrome.keypress('b'));
    try std.testing.expectEqualStrings("abc", chrome.address_bar.items);
    try std.testing.expectEqual(@as(usize, 2), chrome.address_cursor);

    try std.testing.expect(chrome.backspace());
    try std.testing.expectEqualStrings("ac", chrome.address_bar.items);
    try std.testing.expectEqual(@as(usize, 1), chrome.address_cursor);

    try std.testing.expect(chrome.moveCursorLeft());
    try std.testing.expect(!chrome.backspace());
    try std.testing.expect(try chrome.keypress('z'));
    try std.testing.expectEqualStrings("zac", chrome.address_bar.items);
    try std.testing.expectEqual(@as(usize, 1), chrome.address_cursor);

    while (chrome.moveCursorRight()) {}
    try std.testing.expect(try chrome.keypress('!'));
    try std.testing.expectEqualStrings("zac!", chrome.address_bar.items);
    try std.testing.expectEqual(chrome.address_bar.items.len, chrome.address_cursor);
}

test "address cursor resets on focus blur and successful enter" {
    const allocator = std.testing.allocator;
    var chrome = initTestChrome(allocator);
    defer chrome.deinit();

    chrome.focusAddressBar();
    try std.testing.expect(try chrome.keypress('a'));
    try std.testing.expect(try chrome.keypress('b'));
    try std.testing.expect(chrome.moveCursorLeft());
    chrome.focusAddressBar();
    try std.testing.expectEqual(@as(usize, 0), chrome.address_cursor);
    try std.testing.expectEqual(@as(usize, 0), chrome.address_bar.items.len);

    try std.testing.expect(try chrome.keypress('x'));
    chrome.blur();
    try std.testing.expectEqual(@as(usize, 0), chrome.address_cursor);
    try std.testing.expectEqual(@as(usize, 0), chrome.address_bar.items.len);
    try std.testing.expect(chrome.focus == null);

    chrome.focusAddressBar();
    for ("example.com") |char| {
        try std.testing.expect(try chrome.keypress(char));
    }
    try std.testing.expect(chrome.moveCursorLeft());

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.tabs = std.ArrayList(*tab_module.Tab).empty;
    defer test_browser.tabs.deinit(allocator);
    test_browser.active_tab_index = null;

    try std.testing.expect(try chrome.enter(&test_browser));
    try std.testing.expectEqual(@as(usize, 0), chrome.address_cursor);
    try std.testing.expectEqual(@as(usize, 0), chrome.address_bar.items.len);
    try std.testing.expect(chrome.focus == null);
}

test "Enter in a focused text entry submits its containing form" {
    try std.testing.expect(try enterOnFirstInput(
        "<html><body><form><input name=q value=zig></form></body></html>",
    ));
    try std.testing.expect(try enterOnFirstInput(
        "<html><body><form action=/search><input type=TeXt name=q></form></body></html>",
    ));
}

test "Enter does not submit from a text entry outside a form or a non-text input" {
    try std.testing.expect(!try enterOnFirstInput(
        "<html><body><input type=text name=q></body></html>",
    ));
    try std.testing.expect(!try enterOnFirstInput(
        "<html><body><form action=/search><input type=checkbox name=q></form></body></html>",
    ));
}

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
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.session_state = &session;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = .empty;
    defer test_browser.tabs.deinit(allocator);
    test_browser.active_tab_index = null;
    test_browser.shutting_down = false;
    test_browser.animation_timer_active = false;
    test_browser.needs_animation_frame = false;
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
    var generating_layout: u8 = 0;
    const display_list = try allocator.alloc(browser.DisplayItem, 1);
    display_list[0] = .{ .rect = .{
        .x1 = 10,
        .y1 = 20,
        .x2 = 110,
        .y2 = 50,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .source = .{
            .layout = @ptrCast(&generating_layout),
            .node = link_node.?,
        },
    } };
    frame.display_list = display_list;

    try std.testing.expect(try frame.click(&test_browser, 25, 25, .middle));
    try std.testing.expectEqual(@as(usize, 1), test_browser.pending_new_tabs.items.len);
    try std.testing.expectEqualStrings(
        "/docs/next.html",
        test_browser.pending_new_tabs.items[0].path,
    );
    try std.testing.expect(try session.isVisited(&test_browser.pending_new_tabs.items[0]));
    try std.testing.expect(test_browser.needs_animation_frame);
    try test_browser.annotateVisitedLinks(&root, &current_url);
    try std.testing.expect(link_node.?.element.is_visited);

    try std.testing.expect(!try frame.click(&test_browser, 200, 200, .middle));
    try std.testing.expectEqual(@as(usize, 1), test_browser.pending_new_tabs.items.len);

    var rejected = try Url.init(allocator, "https://example.com/rejected.html");
    defer rejected.free(allocator);
    test_browser.shutting_down = true;
    try std.testing.expectError(
        error.BrowserShuttingDown,
        test_browser.queueNewTab(rejected),
    );
    try std.testing.expect(!try session.isVisited(&rejected));
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
