//! Dynamic script/stylesheet resource generation tests.

const std = @import("std");
const browser = @import("../browser/root.zig");
const tab_module = @import("../browser/tab.zig");
const parser = @import("../document/parser.zig");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const MeasureTime = @import("../runtime/measure_time.zig").MeasureTime;
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

fn findElementById(root: *parser.Node, id: []const u8) ?*parser.Node {
    switch (root.*) {
        .text => return null,
        .element => |*element| {
            if (element.attributes) |attributes| {
                if (attributes.get("id")) |candidate| {
                    if (std.mem.eql(u8, candidate, id)) return root;
                }
            }
            for (element.children.items) |*child| {
                if (findElementById(child, id)) |found| return found;
            }
            return null;
        },
    }
}

test "iframe bindings survive DOM relocation and removed contexts unload" {
    const allocator = std.testing.allocator;

    var tab: tab_module.Tab = undefined;
    tab.allocator = allocator;
    tab.next_window_id = 0;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();
    tab.focused_frame = null;
    tab.root_frame = null;

    var root = tab_module.Frame.init(allocator, &tab, null, null);
    defer root.deinit();
    tab.root_frame = &root;
    tab.registerFrame(&root);

    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><iframe id=a src=a.html></iframe>" ++
            "<iframe id=b src=b.html></iframe></body></html>",
    );
    defer html_parser.deinit(allocator);
    root.current_node = try html_parser.parse();
    parser.fixParentPointers(&root.current_node.?, null);

    const original_a = findElementById(&root.current_node.?, "a") orelse
        return error.TestIframeMissing;
    const original_b = findElementById(&root.current_node.?, "b") orelse
        return error.TestIframeMissing;

    const child_a = try allocator.create(tab_module.Frame);
    child_a.* = tab_module.Frame.init(allocator, &tab, &root, original_a);
    tab.registerFrame(child_a);
    try root.children.append(allocator, child_a);
    original_a.element.iframe_window_id = child_a.window_id;

    const child_b = try allocator.create(tab_module.Frame);
    child_b.* = tab_module.Frame.init(allocator, &tab, &root, original_b);
    tab.registerFrame(child_b);
    try root.children.append(allocator, child_b);
    original_b.element.iframe_window_id = child_b.window_id;

    // Move every by-value child into a new backing allocation while the old
    // allocation is still live. The scalar markers move; Frame pointers do
    // not update until the completion reconciliation runs.
    const container = original_a.element.parent orelse return error.TestIframeParentMissing;
    try std.testing.expect(original_b.element.parent == container);
    const old_a_address = @intFromPtr(original_a);
    const old_b_address = @intFromPtr(original_b);
    var old_children = container.element.children;
    container.element.children = .empty;
    var moved_children = std.ArrayList(parser.Node).empty;
    try moved_children.ensureTotalCapacity(allocator, old_children.items.len + 1);
    const prefix = try parser.Element.init(allocator, "iframe id=c src=c.html", container);
    moved_children.appendAssumeCapacity(.{ .element = prefix });
    var old_index = old_children.items.len;
    while (old_index > 0) {
        old_index -= 1;
        moved_children.appendAssumeCapacity(old_children.items[old_index]);
    }
    old_children.deinit(allocator);
    container.element.children = moved_children;
    parser.fixParentPointers(&root.current_node.?, null);

    const moved_a = findElementById(&root.current_node.?, "a") orelse
        return error.TestIframeMissing;
    const moved_b = findElementById(&root.current_node.?, "b") orelse
        return error.TestIframeMissing;
    const added_c = findElementById(&root.current_node.?, "c") orelse
        return error.TestIframeMissing;
    try std.testing.expect(old_a_address != @intFromPtr(moved_a));
    try std.testing.expect(old_b_address != @intFromPtr(moved_b));

    root.reconcileAttachedChildFrames();
    try std.testing.expect(child_a.frame_element == moved_a);
    try std.testing.expect(child_b.frame_element == moved_b);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expect(root.children.items[0] == child_b);
    try std.testing.expect(root.children.items[1] == child_a);
    // The marker-free insertion is not mistaken for an old context. Deferred
    // resource refresh will load it at DOM index zero.
    try std.testing.expect(added_c.element.iframe_window_id == null);

    // Removing B destroys its browsing context immediately and retargets the
    // tab's frame focus before the old Frame allocation is released.
    tab.focused_frame = child_b;
    const removed_window_id = child_b.window_id;
    var remove_index: ?usize = null;
    for (container.element.children.items, 0..) |*node, index| {
        if (node == moved_b) {
            remove_index = index;
            break;
        }
    }
    var removed_node = container.element.children.orderedRemove(remove_index.?);
    removed_node.deinit(allocator);
    parser.fixParentPointers(&root.current_node.?, null);

    root.reconcileAttachedChildFrames();
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expect(root.children.items[0] == child_a);
    try std.testing.expect(tab.frames_by_id.get(removed_window_id) == null);
    try std.testing.expect(tab.focused_frame == &root);
}

test "resource refresh adds and removes live linked stylesheet generations" {
    const allocator = std.testing.allocator;

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(allocator, std.testing.io, &environ);
    defer measure.finish();

    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();
    try session.startNetworking(&measure);

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

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(allocator, std.testing.io, &environ);
    defer measure.finish();

    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();
    try session.startNetworking(&measure);

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
