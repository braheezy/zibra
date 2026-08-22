//! Focused tests for browser resize geometry and tab reflow invalidation.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Chrome = @import("../browser/chrome.zig");
const tab_module = @import("../browser/tab.zig");
const Layout = @import("../browser/render/layout.zig");
const ProtectedField = @import("../core/protected_field.zig").ProtectedField;

fn createCleanDocument(allocator: std.mem.Allocator) !*Layout.DocumentLayout {
    const document = try allocator.create(Layout.DocumentLayout);
    document.* = .{
        .allocator = allocator,
        .node = undefined,
        .node_ptr = undefined,
        .zoom = ProtectedField(f32).init(allocator, 1.0),
        .x = ProtectedField(i32).init(allocator, 0),
        .y = ProtectedField(i32).init(allocator, 0),
        .width = ProtectedField(i32).init(allocator, 0),
        .height = ProtectedField(i32).init(allocator, 0),
        .children = .empty,
    };
    document.zoom.dirty = false;
    document.x.dirty = false;
    document.y.dirty = false;
    document.width.dirty = false;
    document.height.dirty = false;
    return document;
}

test "resize geometry validates native sizes and sizes tab targets" {
    try std.testing.expect(browser.resizeGeometry(0, 600, 80, 1000, 1.0, true) == null);
    try std.testing.expect(browser.resizeGeometry(800, -1, 80, 1000, 1.0, true) == null);

    const geometry = browser.resizeGeometry(960, 640, 80, 900, 1.5, true).?;
    try std.testing.expectEqual(@as(i32, 960), geometry.window_width);
    try std.testing.expectEqual(@as(i32, 640), geometry.window_height);
    try std.testing.expectEqual(@as(i32, 560), geometry.tab_viewport_height);
    try std.testing.expectEqual(@as(?i32, 1350), geometry.tab_surface_height);

    const without_tab_target = browser.resizeGeometry(320, 60, 80, 0, 1.0, false).?;
    try std.testing.expectEqual(@as(i32, 0), without_tab_target.tab_viewport_height);
    try std.testing.expectEqual(@as(?i32, null), without_tab_target.tab_surface_height);

    const saturated = browser.resizeGeometry(
        800,
        600,
        80,
        std.math.maxInt(i32),
        3.0,
        true,
    ).?;
    try std.testing.expectEqual(@as(?i32, 2400), saturated.tab_surface_height);

    const long_page = browser.resizeGeometry(800, 600, 80, 100_000, 1.0, true).?;
    try std.testing.expectEqual(@as(?i32, 2400), long_page.tab_surface_height);
}

test "chrome resize tracks the address bar edge and clamps narrow windows" {
    var chrome: Chrome = undefined;
    chrome.padding = 5;
    chrome.address_rect = .{
        .left = 100,
        .top = 20,
        .right = 795,
        .bottom = 40,
    };

    chrome.resize(1000);
    try std.testing.expectEqual(@as(i32, 995), chrome.address_rect.right);

    chrome.resize(80);
    try std.testing.expectEqual(chrome.address_rect.left, chrome.address_rect.right);
}

test "scroll clamping follows the resized visible viewport" {
    try std.testing.expectEqual(@as(i32, 0), tab_module.clampScrollOffset(-20, 1000, 600, 1.0));
    try std.testing.expectEqual(@as(i32, 400), tab_module.clampScrollOffset(900, 1000, 600, 1.0));
    try std.testing.expectEqual(@as(i32, 0), tab_module.clampScrollOffset(400, 500, 600, 1.0));
    try std.testing.expectEqual(@as(i32, 700), tab_module.clampScrollOffset(900, 1000, 600, 2.0));
}

test "tab resize updates root viewport and invalidates layout" {
    const allocator = std.testing.allocator;

    var tab: tab_module.Tab = undefined;
    tab.tab_width = 800;
    tab.tab_height = 520;
    tab.accessibility = .{};
    tab.root_frame = null;
    tab.needs_style = false;
    tab.needs_layout = false;
    tab.needs_paint = false;
    tab.scroll_changed_in_tab = false;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    frame.viewport_width = tab.tab_width;
    frame.viewport_height = tab.tab_height;
    frame.content_height = 900;
    frame.scroll = 500;

    const document = try createCleanDocument(allocator);
    frame.document_layout = document;
    try std.testing.expect(!document.layoutNeeded());

    const child = try allocator.create(tab_module.Frame);
    child.* = tab_module.Frame.init(allocator, &tab, &frame, null);
    frame.children.append(allocator, child) catch |err| {
        child.deinit();
        allocator.destroy(child);
        return err;
    };
    child.viewport_width = 300;
    child.viewport_height = 150;
    const child_document = try createCleanDocument(allocator);
    child.document_layout = child_document;
    try std.testing.expect(!child_document.layoutNeeded());

    tab.resizeViewport(420, 700);

    try std.testing.expectEqual(@as(i32, 420), tab.tab_width);
    try std.testing.expectEqual(@as(i32, 700), tab.tab_height);
    try std.testing.expectEqual(@as(i32, 420), frame.viewport_width);
    try std.testing.expectEqual(@as(i32, 700), frame.viewport_height);
    try std.testing.expect(document.layoutNeeded());
    try std.testing.expect(child_document.layoutNeeded());
    try std.testing.expectEqual(@as(i32, 300), child.viewport_width);
    try std.testing.expectEqual(@as(i32, 150), child.viewport_height);
    try std.testing.expect(tab.needs_layout);
    try std.testing.expect(tab.needs_paint);
    try std.testing.expect(!tab.needs_style);
    try std.testing.expectEqual(@as(i32, 200), frame.scroll);
    try std.testing.expect(tab.scroll_changed_in_tab);
}
