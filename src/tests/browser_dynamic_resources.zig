//! Dynamic script/stylesheet resource generation tests.

const std = @import("std");
const browser = @import("../browser/root.zig");
const tab_module = @import("../browser/tab.zig");
const parser = @import("../document/parser.zig");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const Url = @import("../network/url.zig").Url;

fn findElement(root: *parser.Node, tag: []const u8) ?*parser.Node {
    switch (root.*) {
        .text => return null,
        .element => |*element| {
            if (std.mem.eql(u8, element.tag, tag)) return root;
            for (element.children.items) |*child| {
                if (findElement(child, tag)) |found| return found;
            }
            return null;
        },
    }
}

test "resource refresh adds and removes live linked stylesheet generations" {
    const allocator = std.testing.allocator;

    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.accessibility = .{};
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();

    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><head></head><body><p>dynamic</p></body></html>",
    );
    defer html_parser.deinit(allocator);
    frame.current_node = try html_parser.parse();
    parser.fixParentPointers(&frame.current_node.?, null);

    var page_url = try Url.init(allocator, "https://example.test/page.html");
    defer page_url.free(allocator);
    frame.current_url = &page_url;

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.session_state = &session;
    test_browser.default_style_sheet_rules = &.{};

    // The document starts without author rules.
    frame.resources_dirty = true;
    try test_browser.refreshFrameResources(&frame);
    try std.testing.expectEqual(@as(usize, 0), frame.rules.items.len);
    try std.testing.expectEqual(@as(usize, 0), frame.css_texts.items.len);

    // Model an attached createElement/innerHTML result. A data URL keeps the
    // test deterministic while still exercising the browser's linked-sheet
    // fetch/decode/parser path.
    const head = findElement(&frame.current_node.?, "head") orelse return error.TestHeadMissing;
    var link = try parser.Element.init(
        allocator,
        "link rel=stylesheet href=\"data:text/css,p%7Bcolor%3Agreen%7D\"",
        head,
    );
    var link_owned = true;
    errdefer if (link_owned) link.deinit(allocator);
    try head.element.children.append(allocator, .{ .element = link });
    link_owned = false;
    parser.fixParentPointers(&frame.current_node.?, null);

    frame.resources_dirty = true;
    try test_browser.refreshFrameResources(&frame);
    try std.testing.expectEqual(@as(usize, 1), frame.rules.items.len);
    try std.testing.expectEqual(@as(usize, 1), frame.css_texts.items.len);
    try std.testing.expectEqualStrings("green", frame.rules.items[0].properties.get("color").?.value);

    // A detached link is absent from the next staged generation. Its old
    // rules are destroyed before their stylesheet backing buffer is freed.
    var removed = head.element.children.orderedRemove(0);
    removed.deinit(allocator);
    parser.fixParentPointers(&frame.current_node.?, null);
    frame.resources_dirty = true;
    try test_browser.refreshFrameResources(&frame);
    try std.testing.expectEqual(@as(usize, 0), frame.rules.items.len);
    try std.testing.expectEqual(@as(usize, 0), frame.css_texts.items.len);
}

test "parallel stylesheet fetches are applied in DOM source order" {
    const allocator = std.testing.allocator;

    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.accessibility = .{};
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();

    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><head>" ++
            "<link rel=stylesheet href=\"data:text/css,p%7Bcolor%3Ared%7D\">" ++
            "<link rel=stylesheet href=\"data:text/css,p%7Bcolor%3Agreen%7D\">" ++
            "</head><body><p>ordered</p></body></html>",
    );
    defer html_parser.deinit(allocator);
    frame.current_node = try html_parser.parse();
    parser.fixParentPointers(&frame.current_node.?, null);

    var page_url = try Url.init(allocator, "https://example.test/page.html");
    defer page_url.free(allocator);
    frame.current_url = &page_url;

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.session_state = &session;
    test_browser.default_style_sheet_rules = &.{};

    frame.resources_dirty = true;
    try test_browser.refreshFrameResources(&frame);

    try std.testing.expectEqual(@as(usize, 2), frame.css_texts.items.len);
    try std.testing.expectEqual(@as(usize, 2), frame.rules.items.len);
    try std.testing.expectEqualStrings("red", frame.rules.items[0].properties.get("color").?.value);
    try std.testing.expectEqualStrings("green", frame.rules.items[1].properties.get("color").?.value);
}

test "script execution identity survives detach and reattachment" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><div><script>window.runs = 1</script></div></body></html>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    const container = findElement(&root, "div") orelse return error.TestContainerMissing;
    try std.testing.expectEqual(@as(usize, 1), container.element.children.items.len);
    container.element.children.items[0].element.script_started = true;

    var detached = container.element.children.orderedRemove(0);
    var detached_owned = true;
    errdefer if (detached_owned) detached.deinit(allocator);
    try container.element.children.append(allocator, detached);
    detached_owned = false;
    parser.fixParentPointers(&root, null);
    try std.testing.expect(container.element.children.items[0].element.script_started);
}
