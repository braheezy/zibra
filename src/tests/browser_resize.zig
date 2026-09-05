//! Focused tests for browser resize geometry and tab reflow invalidation.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Chrome = @import("../browser/chrome.zig");
const tab_module = @import("../browser/tab.zig");
const Layout = @import("../browser/render/layout.zig");
const ProtectedField = @import("../core/protected_field.zig").ProtectedField;
const CSSParser = @import("../document/css_parser.zig").CSSParser;
const document_parser = @import("../document/parser.zig");

fn settleBrowser(b: *browser.Browser) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 10 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
        _ = try b.tick();
        b.lock.lock();
        const animation_quiet = !b.needs_animation_frame and !b.animation_timer_active;
        b.lock.unlock();
        const tab = b.activeTab().?;
        if (animation_quiet and b.isIdle() and tab.isQuiescent()) return;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.BrowserDidNotSettle;
}

fn resizeTarget(block: anytype) ?@TypeOf(block) {
    if (block.node_ptr) |node| {
        if (node.* == .element) {
            if (node.element.attributes) |attrs| {
                if (attrs.get("id")) |id| {
                    if (std.mem.eql(u8, id, "resize-target")) return block;
                }
            }
        }
    }
    for (block.children.items) |child| switch (child) {
        .block => |nested| if (resizeTarget(nested)) |found| return found,
        .line => {},
    };
    return null;
}

test "native resize event reflows a loaded browser through the tab worker" {
    // Use the actual Browser scheduling and presentation owners. Quiescence
    // (not a delay) is the barrier before borrowing the worker-owned geometry.
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const b = try browser.Browser.init(allocator, std.testing.io, &environ, false, true);
    defer {
        b.deinit();
        allocator.destroy(b);
    }
    try b.newTab(try @import("../network/url.zig").Url.init(allocator, "data:text/html,<html><body><div id='resize-target' style='width:400px;margin:0 auto;height:40px;background:green'></div></body></html>"));
    try settleBrowser(b);
    const tab = b.activeTab().?;
    const frame = tab.root_frame.?;
    const initial_document = frame.documentLayout().?;
    const initial_width = initial_document.width.get().*;
    const initial_x = resizeTarget(initial_document.children.items[0]).?.x.get().*;
    try b.handleWindowEvent(.{ .window_id = 1, .timestamp = 0, .type = .{ .size_changed = .{ .width = 2560, .height = 1440 } } });
    try settleBrowser(b);
    const wide = frame.documentLayout().?;
    try std.testing.expectEqual(@as(i32, 2560), tab.tab_width);
    try std.testing.expectEqual(initial_width + 1760, wide.width.get().*);
    try std.testing.expectEqual(initial_x + 880, resizeTarget(wide.children.items[0]).?.x.get().*);
    try std.testing.expect(!wide.layoutNeeded());
    try b.handleWindowEvent(.{ .window_id = 1, .timestamp = 0, .type = .{ .resized = .{ .width = 800, .height = 600 } } });
    try settleBrowser(b);
    try std.testing.expectEqual(initial_width, frame.documentLayout().?.width.get().*);

    // A hidden SDL window tests native-size sampling without requiring a GPU
    // renderer or presenting UI. Deliberately do not deliver its size events.
    const sdl = @import("sdl");
    b.window = try sdl.createWindow("resize regression", .default, .default, 800, 600, .{ .vis = .hidden, .resizable = true });
    try b.window.?.setSize(.{ .width = 2560, .height = 1440 });
    try settleBrowser(b);
    try std.testing.expectEqual(@as(i32, 2560), b.window_width);
    try std.testing.expectEqual(@as(i32, 2560), tab.tab_width);
    try std.testing.expectEqual(initial_width + 1760, frame.documentLayout().?.width.get().*);
}

fn createCleanDocument(allocator: std.mem.Allocator) !*Layout.DocumentLayout {
    const document = try allocator.create(Layout.DocumentLayout);
    document.* = .{
        .allocator = allocator,
        .node = undefined,
        .node_ptr = undefined,
        .zoom = ProtectedField(f32).init(1.0),
        .x = ProtectedField(i32).init(0),
        .y = ProtectedField(i32).init(0),
        .width = ProtectedField(i32).init(0),
        .height = ProtectedField(i32).init(0),
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

test "page zoom crosses a max-width media query in CSS pixels" {
    const allocator = std.testing.allocator;
    const css =
        "p { color: red; }" ++
        "@media (max-width: 500px) { p { color: green; } }";

    var normal_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .viewport_width_css = tab_module.viewportWidthInCssPixels(800, 1.0) },
    );
    defer normal_parser.deinit(allocator);
    const normal_rules = try normal_parser.parse(allocator);
    defer {
        for (normal_rules) |*rule| rule.deinit(allocator);
        allocator.free(normal_rules);
    }
    try std.testing.expectEqual(@as(usize, 1), normal_rules.len);

    var zoomed_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .viewport_width_css = tab_module.viewportWidthInCssPixels(800, 2.0) },
    );
    defer zoomed_parser.deinit(allocator);
    const zoomed_rules = try zoomed_parser.parse(allocator);
    defer {
        for (zoomed_rules) |*rule| rule.deinit(allocator);
        allocator.free(zoomed_rules);
    }
    try std.testing.expectEqual(@as(usize, 2), zoomed_rules.len);
    try std.testing.expectEqualStrings("green", zoomed_rules[1].properties.get("color").?.value);

    var html_parser = try document_parser.HTMLParser.init(allocator, "<p>responsive</p>");
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document_parser.fixParentPointers(&root, null);

    try document_parser.style(allocator, &root, normal_rules);
    try std.testing.expectEqualStrings("red", root.element.style.?.getPtr("color").?.get().*);

    document_parser.dirtyStyleSubtree(&root);
    try document_parser.style(allocator, &root, zoomed_rules);
    try std.testing.expectEqualStrings("green", root.element.style.?.getPtr("color").?.get().*);

    document_parser.dirtyStyleSubtree(&root);
    try document_parser.style(allocator, &root, normal_rules);
    try std.testing.expectEqualStrings("red", root.element.style.?.getPtr("color").?.get().*);
}

test "iframe width and height resize queries follow parent-published viewport changes" {
    const allocator = std.testing.allocator;

    var tab: tab_module.Tab = undefined;
    tab.tab_width = 800;
    tab.tab_height = 520;
    tab.accessibility = .{};
    tab.root_frame = null;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var parent = tab_module.Frame.init(allocator, &tab, null, null);
    defer parent.deinit();
    var child = tab_module.Frame.init(allocator, &tab, &parent, null);
    defer child.deinit();
    child.viewport_width = 300;
    child.viewport_height = 150;
    child.inherited_css_zoom = 1.0;
    child.setDocumentLayout(try createCleanDocument(allocator));

    const css =
        "p { color: red; }" ++
        "@media (width: 300px) { p { color: green; } }" ++
        "@media (width: 420px) { p { color: blue; } }" ++
        "@media (min-height: 400px) { p { color: purple; } }";
    var child_parser = try document_parser.HTMLParser.init(allocator, "<p>child</p>");
    child_parser.use_implicit_tags = false;
    defer child_parser.deinit(allocator);
    var child_root = try child_parser.parse();
    defer child_root.deinit(allocator);
    document_parser.fixParentPointers(&child_root, null);

    try std.testing.expectEqual(@as(f64, 300), child.mediaViewportWidthCssPixels());
    var initial_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .viewport_width_css = child.mediaViewportWidthCssPixels() },
    );
    defer initial_parser.deinit(allocator);
    const initial_rules = try initial_parser.parse(allocator);
    defer {
        for (initial_rules) |*rule| rule.deinit(allocator);
        allocator.free(initial_rules);
    }
    try document_parser.style(allocator, &child_root, initial_rules);
    try std.testing.expectEqualStrings(
        "green",
        child_root.element.style.?.getPtr("color").?.get().*,
    );

    const change = child.updateViewportFromParent(420, 180);
    try std.testing.expect(change.width_changed);
    try std.testing.expect(change.height_changed);
    try std.testing.expect(child.documentLayout().?.layoutNeeded());
    try std.testing.expectEqual(@as(f64, 420), child.mediaViewportWidthCssPixels());

    var resized_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .viewport_width_css = child.mediaViewportWidthCssPixels() },
    );
    defer resized_parser.deinit(allocator);
    const resized_rules = try resized_parser.parse(allocator);
    defer {
        for (resized_rules) |*rule| rule.deinit(allocator);
        allocator.free(resized_rules);
    }
    document_parser.dirtyStyleSubtree(&child_root);
    try document_parser.style(allocator, &child_root, resized_rules);
    try std.testing.expectEqualStrings(
        "blue",
        child_root.element.style.?.getPtr("color").?.get().*,
    );

    child.inherited_css_zoom = 1.5;
    _ = child.updateViewportFromParent(450, 180);
    try std.testing.expectEqual(@as(f64, 300), child.mediaViewportWidthCssPixels());
    const taller = child.updateViewportFromParent(450, 750);
    try std.testing.expect(!taller.width_changed and taller.height_changed and taller.any());
    try std.testing.expectEqual(@as(f64, 500), child.mediaViewportHeightCssPixels());
    var height_parser = try CSSParser.initWithMedia(allocator, css, .{
        .viewport_width_css = child.mediaViewportWidthCssPixels(),
        .viewport_height_css = child.mediaViewportHeightCssPixels(),
    });
    defer height_parser.deinit(allocator);
    const height_rules = try height_parser.parse(allocator);
    defer {
        for (height_rules) |*rule| rule.deinit(allocator);
        allocator.free(height_rules);
    }
    document_parser.dirtyStyleSubtree(&child_root);
    try document_parser.style(allocator, &child_root, height_rules);
    try std.testing.expectEqualStrings("purple", child_root.element.style.?.getPtr("color").?.get().*);
}

test "tab resize updates root viewport and invalidates layout" {
    const allocator = std.testing.allocator;

    var tab: tab_module.Tab = undefined;
    tab.tab_width = 800;
    tab.tab_height = 520;
    tab.accessibility = .{};
    tab.root_frame = null;
    tab.needs_paint = false;
    tab.pending_hover = false;
    tab.media_environment_dirty = false;
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
    frame.setDocumentLayout(document);
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
    child.setDocumentLayout(child_document);
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
    try std.testing.expect(tab.needs_paint);
    try std.testing.expect(frame.styleNeeded());
    try std.testing.expect(child.styleNeeded());
    try std.testing.expect(tab.renderPhasesNeeded());
    try std.testing.expectEqual(@as(i32, 200), frame.scroll);
    try std.testing.expect(tab.scroll_changed_in_tab);
    try std.testing.expect(tab.media_environment_dirty);

    tab.media_environment_dirty = false;
    tab.resizeViewport(420, 900);
    try std.testing.expect(tab.media_environment_dirty);
    try std.testing.expectEqual(@as(i32, 900), frame.viewport_height);
}

test "resized viewport actually reflows retained document and centered content" {
    const allocator = std.testing.allocator;
    var html = try document_parser.HTMLParser.init(allocator, "<html style='display:block'><body style='display:block'><div style='display:block;height:20px'></div><section style='display:block;width:400px;margin:0 auto;height:20px'></section></body></html>");
    defer html.deinit(allocator);
    html.use_implicit_tags = false;
    var root = try html.parse();
    defer root.deinit(allocator);
    document_parser.fixParentPointers(&root, null);
    try document_parser.style(allocator, &root, &.{});
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const engine = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer engine.deinit();
    const doc = try engine.buildDocument(&root);
    defer {
        doc.deinit();
        allocator.destroy(doc);
    }
    const initial_width = doc.width.get().*;
    const body = doc.children.items[0].children.items[0].block;
    const full = body.children.items[0].block;
    const centered = body.children.items[1].block;
    const initial_x = centered.x.get().*;
    engine.window_width = 2560;
    engine.window_height = 1374;
    doc.mark();
    try doc.layout(engine);
    try std.testing.expectEqual(initial_width + 1760, doc.width.get().*);
    try std.testing.expectEqual(body.content_width, full.width.get().*);
    try std.testing.expectEqual(initial_x + 880, centered.x.get().*);
    try std.testing.expectEqual(@as(i32, 400), centered.width.get().*);
    engine.window_width = 800;
    doc.mark();
    try doc.layout(engine);
    try std.testing.expectEqual(initial_x, centered.x.get().*);
    try std.testing.expect(!doc.layoutNeeded());
}
