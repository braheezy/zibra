//! Unit coverage for the shared page-scroll and scrollbar geometry model.

const std = @import("std");
const browser = @import("../browser/root.zig");
const scroll = @import("../browser/scroll.zig");
const tab_module = @import("../browser/tab.zig");
const parser = @import("../document/parser.zig");

test "short documents hide the scrollbar and clamp to the top" {
    const shorter = scroll.calculate(500, 600, 100, 1.0);
    try std.testing.expect(!shorter.visible);
    try std.testing.expectEqual(@as(i32, 600), shorter.viewport_height_css);
    try std.testing.expectEqual(@as(i32, 0), shorter.max_scroll_css);
    try std.testing.expectEqual(@as(i32, 0), shorter.scroll_css);
    try std.testing.expectEqual(@as(i32, 600), shorter.thumb_height_px);
    try std.testing.expectEqual(@as(i32, 0), shorter.thumb_offset_px);

    const exact_fit = scroll.calculate(600, 600, 0, 1.0);
    try std.testing.expect(!exact_fit.visible);
    try std.testing.expectEqual(@as(i32, 0), exact_fit.max_scroll_css);
}

test "thumb follows the top middle and bottom of a document" {
    const top = scroll.calculate(1200, 600, 0, 1.0);
    try std.testing.expect(top.visible);
    try std.testing.expectEqual(@as(i32, 600), top.max_scroll_css);
    try std.testing.expectEqual(@as(i32, 300), top.thumb_height_px);
    try std.testing.expectEqual(@as(i32, 0), top.thumb_offset_px);

    const middle = scroll.calculate(1200, 600, 300, 1.0);
    try std.testing.expectEqual(@as(i32, 300), middle.scroll_css);
    try std.testing.expectEqual(@as(i32, 150), middle.thumb_offset_px);

    const bottom = scroll.calculate(1200, 600, 999, 1.0);
    try std.testing.expectEqual(@as(i32, 600), bottom.scroll_css);
    try std.testing.expectEqual(@as(i32, 300), bottom.thumb_offset_px);
    try std.testing.expectEqual(bottom.track_height_px, bottom.thumb_offset_px + bottom.thumb_height_px);
}

test "zoom and viewport resize update both range and thumb" {
    const zoomed = scroll.calculate(1000, 600, 350, 2.0);
    try std.testing.expectEqual(@as(i32, 300), zoomed.viewport_height_css);
    try std.testing.expectEqual(@as(i32, 700), zoomed.max_scroll_css);
    try std.testing.expectEqual(@as(i32, 180), zoomed.thumb_height_px);
    try std.testing.expectEqual(@as(i32, 210), zoomed.thumb_offset_px);

    const narrow_viewport = scroll.calculate(1000, 400, 600, 1.0);
    try std.testing.expectEqual(@as(i32, 600), narrow_viewport.max_scroll_css);
    try std.testing.expectEqual(@as(i32, 160), narrow_viewport.thumb_height_px);

    const tall_viewport = scroll.calculate(1000, 800, 600, 1.0);
    try std.testing.expectEqual(@as(i32, 200), tall_viewport.scroll_css);
    try std.testing.expectEqual(@as(i32, 640), tall_viewport.thumb_height_px);
    try std.testing.expectEqual(@as(i32, 160), tall_viewport.thumb_offset_px);
}

test "geometry remains bounded for extreme and invalid inputs" {
    const huge = scroll.calculate(std.math.maxInt(i32), 600, std.math.maxInt(i32), 1.0);
    try std.testing.expect(huge.visible);
    try std.testing.expectEqual(@as(i32, 1), huge.thumb_height_px);
    try std.testing.expect(huge.thumb_offset_px >= 0);
    try std.testing.expect(huge.thumb_offset_px + huge.thumb_height_px <= huge.track_height_px);

    const invalid_zoom = scroll.calculate(1000, 600, -100, 0.0);
    try std.testing.expectEqual(@as(i32, 600), invalid_zoom.viewport_height_css);
    try std.testing.expectEqual(@as(i32, 0), invalid_zoom.scroll_css);

    const empty_track = scroll.calculate(1000, -10, 500, 1.0);
    try std.testing.expect(!empty_track.visible);
    try std.testing.expectEqual(@as(i32, 0), empty_track.track_height_px);
    try std.testing.expectEqual(@as(i32, 0), empty_track.thumb_height_px);
}

test "interest regions bound long pages and reuse nearby pixels" {
    const top = scroll.calculateInterestRegion(10_000, 534, 600, 0);
    try std.testing.expectEqual(@as(i32, 0), top.start_px);
    try std.testing.expectEqual(@as(i32, 2400), top.height_px);
    try std.testing.expect(top.containsViewport(1800, 534));
    try std.testing.expect(!top.containsViewport(1900, 534));

    const middle = scroll.calculateInterestRegion(10_000, 534, 600, 1900);
    try std.testing.expectEqual(@as(i32, 1366), middle.start_px);
    try std.testing.expectEqual(@as(i32, 3766), middle.endPx());
    try std.testing.expect(middle.containsViewport(1900, 534));

    const bottom = scroll.calculateInterestRegion(10_000, 534, 600, 9466);
    try std.testing.expectEqual(@as(i32, 7600), bottom.start_px);
    try std.testing.expectEqual(@as(i32, 10_000), bottom.endPx());
    try std.testing.expect(bottom.containsViewport(9466, 534));
}

test "interest regions use short-page size and saturate extreme geometry" {
    const short = scroll.calculateInterestRegion(300, 534, 600, 100);
    try std.testing.expectEqual(@as(i32, 0), short.start_px);
    try std.testing.expectEqual(@as(i32, 534), short.height_px);
    try std.testing.expect(short.containsViewport(0, 534));

    try std.testing.expectEqual(
        @as(i32, std.math.maxInt(i32)),
        scroll.scaleCssPx(std.math.maxInt(i32), 3.0),
    );
    const huge = scroll.calculateInterestRegion(
        std.math.maxInt(i32),
        520,
        600,
        std.math.maxInt(i32),
    );
    try std.testing.expectEqual(@as(i32, 2400), huge.height_px);
    try std.testing.expect(huge.containsViewport(std.math.maxInt(i32) - 520, 520));
}

test "scroll behavior accepts smooth case-insensitively and defaults to auto" {
    try std.testing.expectEqual(scroll.Behavior.smooth, scroll.parseBehavior(" smooth "));
    try std.testing.expectEqual(scroll.Behavior.smooth, scroll.parseBehavior("SMOOTH"));
    try std.testing.expectEqual(scroll.Behavior.auto, scroll.parseBehavior("auto"));
    try std.testing.expectEqual(scroll.Behavior.auto, scroll.parseBehavior("instant"));
}

test "clock-based smooth scrolling eases in both directions and lands exactly" {
    const duration = scroll.smooth_scroll_duration_ns;
    const down = scroll.ScrollAnimation.init(100, 300, 1_000);
    try std.testing.expectEqual(@as(i32, 100), down.sample(1_000).scroll);

    const down_middle = down.sample(1_000 + @divTrunc(duration, 2));
    try std.testing.expect(!down_middle.complete);
    try std.testing.expect(down_middle.scroll > 200);
    try std.testing.expect(down_middle.scroll < 300);
    const down_end = down.sample(1_000 + duration);
    try std.testing.expect(down_end.complete);
    try std.testing.expectEqual(@as(i32, 300), down_end.scroll);

    const up = scroll.ScrollAnimation.init(300, 100, 2_000);
    const up_middle = up.sample(2_000 + @divTrunc(duration, 2));
    try std.testing.expect(up_middle.scroll < 200);
    try std.testing.expect(up_middle.scroll > 100);
    try std.testing.expectEqual(@as(i32, 100), up.sample(2_000 + duration).scroll);
}

test "only the computed body scroll behavior controls viewport smoothing" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html style=\"scroll-behavior: smooth\"><body style=\"scroll-behavior: smooth\"><main style=\"scroll-behavior: auto\">content</main></body></html>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    try parser.style(allocator, &root, &.{});

    try std.testing.expectEqual(
        scroll.Behavior.smooth,
        tab_module.documentScrollBehavior(&root),
    );

    var auto_parser = try parser.HTMLParser.init(
        allocator,
        "<html style=\"scroll-behavior: smooth\"><body><main style=\"scroll-behavior: smooth\">content</main></body></html>",
    );
    defer auto_parser.deinit(allocator);
    var auto_root = try auto_parser.parse();
    defer auto_root.deinit(allocator);
    parser.fixParentPointers(&auto_root, null);
    try parser.style(allocator, &auto_root, &.{});
    try std.testing.expectEqual(
        scroll.Behavior.auto,
        tab_module.documentScrollBehavior(&auto_root),
    );
}

test "down input starts and retargets a smooth body scroll" {
    const allocator = std.testing.allocator;

    var tab: tab_module.Tab = undefined;
    tab.root_frame = null;
    tab.focused_frame = null;
    tab.tab_height = 500;
    tab.accessibility = .{};
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    frame.viewport_height = 500;
    frame.content_height = 2_000;

    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body style=\"scroll-behavior: smooth\"><main>content</main></body></html>",
    );
    defer html_parser.deinit(allocator);
    frame.current_node = try html_parser.parse();
    parser.fixParentPointers(&frame.current_node.?, null);
    try parser.style(allocator, &frame.current_node.?, &.{});

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = .empty;
    defer test_browser.tabs.deinit(allocator);
    try test_browser.tabs.append(allocator, &tab);
    test_browser.active_tab_index = 0;
    test_browser.shutting_down = true;
    test_browser.needs_animation_frame = false;
    tab.browser = &test_browser;

    tab.scrollFocused(&test_browser, 100);
    try std.testing.expectEqual(@as(i32, 0), frame.scroll);
    try std.testing.expectEqual(@as(i32, 100), frame.scroll_animation.?.target_scroll);
    try std.testing.expect(test_browser.needs_animation_frame);

    tab.scrollFocused(&test_browser, 100);
    try std.testing.expectEqual(@as(i32, 200), frame.scroll_animation.?.target_scroll);
}

test "scroll-only animation frames still commit their scalar offset" {
    try std.testing.expect(tab_module.animationFrameHasCommit(false, false, false, 42));
    try std.testing.expect(!tab_module.animationFrameHasCommit(false, false, false, null));
    try std.testing.expect(tab_module.animationFrameHasCommit(true, false, false, null));
    try std.testing.expect(tab_module.animationFrameHasCommit(false, true, false, null));
    try std.testing.expect(tab_module.animationFrameHasCommit(false, false, true, null));
}
