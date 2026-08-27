//! Focused tests for platform input normalization at the browser boundary.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Chrome = @import("../browser/chrome.zig");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const tab_module = @import("../browser/tab.zig");
const parser_module = @import("../document/parser.zig");
const Js = @import("../script/js.zig");
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
                    element.is_focus_visible = true;
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

test "tab blur clears focused elements across the frame tree" {
    const allocator = std.testing.allocator;

    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.root_frame = null;
    tab.focused_frame = null;
    tab.accessibility_focused = null;
    tab.next_window_id = 1;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var root = tab_module.Frame.init(allocator, &tab, null, null);
    defer root.deinit();
    tab.root_frame = &root;

    const child = try allocator.create(tab_module.Frame);
    var child_owned = true;
    errdefer if (child_owned) {
        child.deinit();
        allocator.destroy(child);
    };
    child.* = tab_module.Frame.init(allocator, &tab, &root, null);
    try root.children.append(allocator, child);
    child_owned = false;

    var root_parser = try parser_module.HTMLParser.init(
        allocator,
        "<html><body><input name=root></body></html>",
    );
    defer root_parser.deinit(allocator);
    root.current_node = try root_parser.parse();
    parser_module.fixParentPointers(&root.current_node.?, null);

    var child_parser = try parser_module.HTMLParser.init(
        allocator,
        "<html><body><input name=child></body></html>",
    );
    defer child_parser.deinit(allocator);
    child.current_node = try child_parser.parse();
    parser_module.fixParentPointers(&child.current_node.?, null);

    const root_input = find_root_input: {
        var nodes = std.ArrayList(*parser_module.Node).empty;
        defer nodes.deinit(allocator);
        try parser_module.treeToList(allocator, &root.current_node.?, &nodes);
        for (nodes.items) |node| {
            if (node.* == .element and std.ascii.eqlIgnoreCase(node.element.tag, "input")) {
                break :find_root_input node;
            }
        }
        return error.TestInputMissing;
    };
    const child_input = find_child_input: {
        var nodes = std.ArrayList(*parser_module.Node).empty;
        defer nodes.deinit(allocator);
        try parser_module.treeToList(allocator, &child.current_node.?, &nodes);
        for (nodes.items) |node| {
            if (node.* == .element and std.ascii.eqlIgnoreCase(node.element.tag, "input")) {
                break :find_child_input node;
            }
        }
        return error.TestInputMissing;
    };

    root_input.element.is_focused = true;
    root_input.element.is_focus_visible = true;
    root.focus = root_input;
    root.scroll_focus = root_input;
    child_input.element.is_focused = true;
    child_input.element.is_focus_visible = true;
    child.focus = child_input;
    child.scroll_focus = child_input;
    tab.focused_frame = child;

    try std.testing.expect(tab.blur());
    try std.testing.expect(root.focus == null);
    try std.testing.expect(child.focus == null);
    try std.testing.expect(root.scroll_focus == null);
    try std.testing.expect(child.scroll_focus == null);
    try std.testing.expect(!root_input.element.is_focused);
    try std.testing.expect(!root_input.element.is_focus_visible);
    try std.testing.expect(!child_input.element.is_focused);
    try std.testing.expect(!child_input.element.is_focus_visible);
    try std.testing.expect(tab.focused_frame == null);
    try std.testing.expect(!tab.blur());
}

fn appendFocusTestFrame(
    allocator: std.mem.Allocator,
    tab: *tab_module.Tab,
    parent: *tab_module.Frame,
) !*tab_module.Frame {
    const child = try allocator.create(tab_module.Frame);
    errdefer allocator.destroy(child);
    child.* = tab_module.Frame.init(allocator, tab, parent, null);
    errdefer child.deinit();
    tab.registerFrame(child);
    try parent.children.append(allocator, child);
    return child;
}

fn installFocusTestDocument(frame: *tab_module.Frame, source: []const u8) !void {
    var html_parser = try parser_module.HTMLParser.init(frame.allocator, source);
    defer html_parser.deinit(frame.allocator);
    frame.current_node = try html_parser.parse();
    parser_module.fixParentPointers(&frame.current_node.?, null);
}

fn findNamedFocusTestElement(frame: *tab_module.Frame, name: []const u8) !*parser_module.Node {
    var nodes = std.ArrayList(*parser_module.Node).empty;
    defer nodes.deinit(frame.allocator);
    try parser_module.treeToList(frame.allocator, &frame.current_node.?, &nodes);
    for (nodes.items) |node| switch (node.*) {
        .element => |element| {
            const attributes = element.attributes orelse continue;
            const candidate = attributes.get("name") orelse continue;
            if (std.mem.eql(u8, candidate, name)) return node;
        },
        .text => {},
    };
    return error.TestElementMissing;
}

fn expectSingleFocus(
    tab: *tab_module.Tab,
    frames: []const *tab_module.Frame,
    expected_frame: *tab_module.Frame,
    expected_node: *parser_module.Node,
) !void {
    try std.testing.expect(tab.focused_frame == expected_frame);
    var focused_elements: usize = 0;
    for (frames) |frame| {
        const expected: ?*parser_module.Node = if (frame == expected_frame) expected_node else null;
        try std.testing.expect(frame.focus == expected);

        var nodes = std.ArrayList(*parser_module.Node).empty;
        defer nodes.deinit(tab.allocator);
        try parser_module.treeToList(tab.allocator, &frame.current_node.?, &nodes);
        for (nodes.items) |node| switch (node.*) {
            .element => |element| {
                if (element.is_focused) {
                    focused_elements += 1;
                    try std.testing.expect(node == expected_node);
                    try std.testing.expect(element.is_focus_visible);
                }
            },
            .text => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 1), focused_elements);
}

test "Tab traversal crosses nested frames in both directions" {
    const allocator = std.testing.allocator;

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = .empty;
    defer test_browser.tabs.deinit(allocator);
    test_browser.active_tab_index = 0;
    // Prevent this focused unit test from creating an animation helper. Focus
    // state and dirty publication still run through the production path.
    test_browser.shutting_down = true;
    test_browser.needs_animation_frame = false;

    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.browser = &test_browser;
    tab.accessibility = .{};
    tab.root_frame = null;
    tab.focused_frame = null;
    tab.focus_modality = .keyboard;
    tab.accessibility_root = null;
    tab.accessibility_focused = null;
    tab.needs_paint = false;
    tab.next_window_id = 1;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();
    try test_browser.tabs.append(allocator, &tab);

    var root = tab_module.Frame.init(allocator, &tab, null, null);
    defer root.deinit();
    tab.registerFrame(&root);
    tab.root_frame = &root;
    try installFocusTestDocument(
        &root,
        "<html><body><input name=root-a><button name=root-b>root</button></body></html>",
    );

    const empty = try appendFocusTestFrame(allocator, &tab, &root);
    try installFocusTestDocument(
        empty,
        "<html><body><input type=hidden name=hidden><button disabled name=disabled>x</button></body></html>",
    );

    const child = try appendFocusTestFrame(allocator, &tab, &root);
    try installFocusTestDocument(
        child,
        "<html><body><a href=/ name=child-a>child</a><input name=child-b></body></html>",
    );
    const nested = try appendFocusTestFrame(allocator, &tab, child);
    try installFocusTestDocument(
        nested,
        "<html><body><button name=nested-a>nested</button></body></html>",
    );

    const last = try appendFocusTestFrame(allocator, &tab, &root);
    try installFocusTestDocument(
        last,
        "<html><body><input name=last-a></body></html>",
    );

    const root_a = try findNamedFocusTestElement(&root, "root-a");
    const root_b = try findNamedFocusTestElement(&root, "root-b");
    const child_a = try findNamedFocusTestElement(child, "child-a");
    const child_b = try findNamedFocusTestElement(child, "child-b");
    const nested_a = try findNamedFocusTestElement(nested, "nested-a");
    const last_a = try findNamedFocusTestElement(last, "last-a");
    const frames = [_]*tab_module.Frame{ &root, empty, child, nested, last };

    // Forward traversal exhausts one document before entering its child
    // frames, skips the empty frame, and wraps after the final sibling.
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, &root, root_a);
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, &root, root_b);
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, child, child_a);
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, child, child_b);
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, nested, nested_a);
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, last, last_a);
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, &root, root_a);

    // Reverse traversal is the exact inverse across frame boundaries.
    try tab.cycleFocus(&test_browser, true);
    try expectSingleFocus(&tab, &frames, last, last_a);
    try tab.cycleFocus(&test_browser, true);
    try expectSingleFocus(&tab, &frames, nested, nested_a);
    try tab.cycleFocus(&test_browser, true);
    try expectSingleFocus(&tab, &frames, child, child_b);

    // A frame focused by clicking its background starts at its own edge; an
    // empty focused frame advances to the nearest non-empty frame.
    _ = tab.blur();
    tab.focused_frame = child;
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, child, child_a);
    _ = tab.blur();
    tab.focused_frame = empty;
    try tab.cycleFocus(&test_browser, false);
    try expectSingleFocus(&tab, &frames, child, child_a);
    _ = tab.blur();
    tab.focused_frame = empty;
    try tab.cycleFocus(&test_browser, true);
    try expectSingleFocus(&tab, &frames, &root, root_b);
}

test "tab blur dispatches a non-bubbling DOM blur event" {
    const allocator = std.testing.allocator;
    var html_parser = try parser_module.HTMLParser.init(
        allocator,
        "<main><section><input id=entry></section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);

    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.root_frame = null;
    tab.focused_frame = null;
    tab.accessibility_focused = null;
    tab.next_window_id = 1;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.registerFrame(&frame);
    tab.root_frame = &frame;
    tab.focused_frame = &frame;
    frame.current_node = try html_parser.parse();
    parser_module.fixParentPointers(&frame.current_node.?, null);

    var nodes = std.ArrayList(*parser_module.Node).empty;
    defer nodes.deinit(allocator);
    try parser_module.treeToList(allocator, &frame.current_node.?, &nodes);
    var input: ?*parser_module.Node = null;
    for (nodes.items) |node| {
        if (node.* == .element and std.ascii.eqlIgnoreCase(node.element.tag, "input")) {
            input = node;
            break;
        }
    }
    const entry = input orelse return error.TestInputMissing;
    entry.element.is_focused = true;
    entry.element.is_focus_visible = true;
    frame.focus = entry;

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(frame.window_id, &frame.current_node.?);
    frame.js_context = js;
    defer frame.js_context = null;

    _ = try js.evaluate(frame.window_id,
        \\var blurLog = [];
        \\var entry = document.querySelectorAll('input')[0];
        \\var parentNode = document.querySelectorAll('section')[0];
        \\entry.addEventListener('blur', function(event) {
        \\  blurLog.push('entry:' + event.bubbles);
        \\});
        \\parentNode.addEventListener('blur', function() { blurLog.push('parent'); });
    );

    try std.testing.expect(tab.blur());
    try std.testing.expect(frame.focus == null);
    try std.testing.expect(!entry.element.is_focus_visible);
    const result = try js.evaluate(
        frame.window_id,
        "blurLog.join(',') === 'entry:false'",
    );
    try std.testing.expect(result.toBoolean());
}

test "nested element scrolling clamps and bubbles at container boundaries" {
    const allocator = std.testing.allocator;
    var html_parser = try parser_module.HTMLParser.init(
        allocator,
        "<div id=outer><div id=inner><span>content</span></div></div>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser_module.fixParentPointers(&root, null);

    var nodes = std.ArrayList(*parser_module.Node).empty;
    defer nodes.deinit(allocator);
    try parser_module.treeToList(allocator, &root, &nodes);

    var outer: ?*parser_module.Node = null;
    var inner: ?*parser_module.Node = null;
    for (nodes.items) |node| switch (node.*) {
        .element => |element| {
            const attributes = element.attributes orelse continue;
            const id = attributes.get("id") orelse continue;
            if (std.mem.eql(u8, id, "outer")) outer = node;
            if (std.mem.eql(u8, id, "inner")) inner = node;
        },
        .text => {},
    };

    const outer_node = outer orelse return error.TestOuterMissing;
    const inner_node = inner orelse return error.TestInnerMissing;
    outer_node.element.setScrollGeometry(true, 200, 600);
    inner_node.element.setScrollGeometry(true, 100, 350);

    try std.testing.expect(tab_module.scrollElementChain(inner_node, 100));
    try std.testing.expectEqual(@as(i32, 100), inner_node.element.scroll_y);
    try std.testing.expectEqual(@as(i32, 0), outer_node.element.scroll_y);

    try std.testing.expect(inner_node.element.scrollBy(std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(i32, 250), inner_node.element.scroll_y);
    // Once the innermost box reaches its bottom, the same direction bubbles
    // to its enclosing scroll box.
    try std.testing.expect(tab_module.scrollElementChain(inner_node, 100));
    try std.testing.expectEqual(@as(i32, 250), inner_node.element.scroll_y);
    try std.testing.expectEqual(@as(i32, 100), outer_node.element.scroll_y);

    inner_node.element.scroll_y = 0;
    try std.testing.expect(tab_module.scrollElementChain(inner_node, -100));
    try std.testing.expectEqual(@as(i32, 0), outer_node.element.scroll_y);
    try std.testing.expect(!tab_module.scrollElementChain(inner_node, -100));

    // A new layout generation preserves but clamps the persistent offset.
    inner_node.element.scroll_y = 200;
    inner_node.element.setScrollGeometry(true, 100, 140);
    try std.testing.expectEqual(@as(i32, 40), inner_node.element.scroll_y);
    inner_node.element.setScrollGeometry(false, 0, 0);
    try std.testing.expect(!inner_node.element.scroll_container);
    try std.testing.expectEqual(@as(i32, 0), inner_node.element.scroll_y);
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
    try std.testing.expect(try enterOnFirstInput(
        "<html><body><form action=/login><input type=PaSsWoRd name=password></form></body></html>",
    ));
}

test "Enter does not submit from a text entry outside a form or a non-text input" {
    try std.testing.expect(!try enterOnFirstInput(
        "<html><body><input type=text name=q></body></html>",
    ));
    try std.testing.expect(!try enterOnFirstInput(
        "<html><body><form action=/search><input type=checkbox name=q></form></body></html>",
    ));
    try std.testing.expect(!try enterOnFirstInput(
        "<html><body><form action=/search><input type=hidden name=token></form></body></html>",
    ));
}

test "hidden and password controls submit their unmasked values" {
    const allocator = std.testing.allocator;
    var html_parser = try parser_module.HTMLParser.init(
        allocator,
        "<form><input type=hidden name=csrf value='a b'>" ++
            "<input type=password name=password value='s&amp;cret'></form>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var form = try html_parser.parse();
    defer form.deinit(allocator);
    parser_module.fixParentPointers(&form, null);

    const encoded = try tab_module.encodeFormData(allocator, &form);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "csrf=a%20b&password=s%26cret",
        encoded,
    );
}

test "form method defaults to GET and recognizes POST case-insensitively" {
    try std.testing.expectEqual(tab_module.FormMethod.get, tab_module.parseFormMethod(null));
    try std.testing.expectEqual(tab_module.FormMethod.get, tab_module.parseFormMethod(""));
    try std.testing.expectEqual(tab_module.FormMethod.get, tab_module.parseFormMethod(" GET "));
    try std.testing.expectEqual(tab_module.FormMethod.get, tab_module.parseFormMethod("invalid"));
    try std.testing.expectEqual(tab_module.FormMethod.post, tab_module.parseFormMethod("post"));
    try std.testing.expectEqual(tab_module.FormMethod.post, tab_module.parseFormMethod("\tPoSt\r\n"));
}

test "GET form plans put encoded data in the action and have no body" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        action: []const u8,
        expected: []const u8,
    }{
        .{ .action = "/search", .expected = "/search?q=hi" },
        .{ .action = "", .expected = "?q=hi" },
        .{ .action = "/search?old=value", .expected = "/search?q=hi" },
        .{ .action = "/search?old=value#results", .expected = "/search?q=hi#results" },
    };

    for (cases) |case| {
        var plan = try tab_module.planFormSubmission(allocator, .get, case.action, "q=hi");
        defer plan.deinit(allocator);
        try std.testing.expectEqualStrings(case.expected, plan.action);
        try std.testing.expect(plan.payload == null);
        try std.testing.expect(plan.owned_action != null);
    }

    var base = try Url.init(allocator, "https://example.test/docs/page?old=1#section");
    defer base.free(allocator);
    var plan = try tab_module.planFormSubmission(allocator, .get, "", "q=hi");
    defer plan.deinit(allocator);
    const resolved = try base.resolveForNavigation(allocator, plan.action);
    defer resolved.free(allocator);
    var url_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://example.test/docs/page?q=hi",
        try resolved.toString(&url_buffer),
    );
}

test "POST form plans preserve the action and carry the encoded body" {
    var plan = try tab_module.planFormSubmission(
        std.testing.allocator,
        .post,
        "/submit?existing=yes",
        "q=hi%20there",
    );
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/submit?existing=yes", plan.action);
    try std.testing.expectEqualStrings("q=hi%20there", plan.payload.?);
    try std.testing.expect(plan.owned_action == null);
}

test "checkbox controls toggle attribute state and encode only when checked" {
    const allocator = std.testing.allocator;
    const html =
        "<html><body><form>" ++
        "<input name=plain value='hi there'>" ++
        "<input type=checkbox name=off value=no>" ++
        "<input type=ChEcKbOx name=default checked>" ++
        "<input type=checkbox name=custom checked=false value='yes &amp; more'>" ++
        "<input type=checkbox checked value=nameless>" ++
        "</form></body></html>";

    var html_parser = try parser_module.HTMLParser.init(allocator, html);
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser_module.fixParentPointers(&root, null);

    var nodes = std.ArrayList(*parser_module.Node).empty;
    defer nodes.deinit(allocator);
    try parser_module.treeToList(allocator, &root, &nodes);

    var form: ?*parser_module.Node = null;
    var unchecked: ?*parser_module.Element = null;
    var default_value: ?*parser_module.Element = null;
    for (nodes.items) |node| {
        switch (node.*) {
            .element => |*element| {
                if (std.ascii.eqlIgnoreCase(element.tag, "form")) form = node;
                if (!element.isCheckbox()) continue;
                const attributes = element.attributes orelse continue;
                const name = attributes.get("name") orelse continue;
                if (std.mem.eql(u8, name, "off")) unchecked = element;
                if (std.mem.eql(u8, name, "default")) default_value = element;
            },
            .text => {},
        }
    }

    try std.testing.expect(form != null);
    try std.testing.expect(unchecked != null);
    try std.testing.expect(default_value != null);
    try std.testing.expect(!unchecked.?.isChecked());
    try std.testing.expect(default_value.?.isChecked());

    const initial = try tab_module.encodeFormData(allocator, form.?);
    defer allocator.free(initial);
    try std.testing.expectEqualStrings(
        "plain=hi%20there&default=on&custom=yes%20%26%20more",
        initial,
    );

    try std.testing.expect(try unchecked.?.toggleChecked());
    try std.testing.expect(!try default_value.?.toggleChecked());
    try std.testing.expect(unchecked.?.isChecked());
    try std.testing.expect(!default_value.?.isChecked());

    const toggled = try tab_module.encodeFormData(allocator, form.?);
    defer allocator.free(toggled);
    try std.testing.expectEqualStrings(
        "plain=hi%20there&off=no&custom=yes%20%26%20more",
        toggled,
    );
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
