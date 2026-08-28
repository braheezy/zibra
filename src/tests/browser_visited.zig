//! Focused browser-session and DOM paint tests for visited links.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Layout = @import("../browser/render/layout.zig");
const Tab = @import("../browser/tab.zig");
const parser = @import("../document/parser.zig");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const Url = @import("../network/url.zig").Url;

test "browser session owns and deduplicates canonical visited URLs" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    const first = try Url.init(allocator, "https://example.com:443/docs?q=1#part");
    defer first.free(allocator);
    const equivalent = try Url.init(allocator, "https://EXAMPLE.COM/docs?q=1#part");
    defer equivalent.free(allocator);
    const other_fragment = try Url.init(allocator, "https://example.com/docs?q=1#other");
    defer other_fragment.free(allocator);

    const initial_generation = session.currentVisitedGeneration();
    try std.testing.expect(try session.markVisited(&first));
    const inserted_generation = session.currentVisitedGeneration();
    try std.testing.expect(inserted_generation != initial_generation);
    try std.testing.expect(!try session.markVisited(&equivalent));
    try std.testing.expectEqual(inserted_generation, session.currentVisitedGeneration());
    try std.testing.expect(try session.isVisited(&equivalent));
    try std.testing.expect(!try session.isVisited(&other_fragment));
    try std.testing.expectEqual(@as(usize, 1), session.visitedCount());
}

test "successful redirect records requested and final URLs" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.session_state = &session;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = std.ArrayList(*Tab).empty;
    defer test_browser.tabs.deinit(allocator);
    test_browser.active_tab_index = null;
    test_browser.shutting_down = false;
    test_browser.animation_timer_active = false;
    test_browser.needs_animation_frame = false;

    var requested = try Url.init(allocator, "https://example.com/redirect");
    defer requested.free(allocator);
    var final: ?Url = try Url.init(allocator, "https://example.com/final");
    errdefer if (final) |url| url.free(allocator);

    try test_browser.recordSuccessfulNavigation(&requested, &final);
    try std.testing.expect(final == null);
    try std.testing.expectEqualStrings("/final", requested.path);

    const requested_check = try Url.init(allocator, "https://example.com/redirect");
    defer requested_check.free(allocator);
    try std.testing.expect(try session.isVisited(&requested_check));
    try std.testing.expect(try session.isVisited(&requested));
    try std.testing.expectEqual(@as(usize, 2), session.visitedCount());
}

test "iframe CSP validates requested and final navigation destinations" {
    const allocator = std.testing.allocator;
    const page = try Url.init(allocator, "https://parent.example/page");
    defer page.free(allocator);
    const same_origin = try Url.init(allocator, "https://parent.example/final");
    defer same_origin.free(allocator);
    const cross_origin = try Url.init(allocator, "https://other.example/final");
    defer cross_origin.free(allocator);

    // Only the fields used by CSP parsing/checking are initialized here.
    var parent: Tab.Frame = undefined;
    parent.allocator = allocator;
    parent.current_url = null;
    parent.allowed_origins = null;
    defer parent.clearAllowedOrigins();
    try parent.applyContentSecurityPolicy("default-src 'self'", page);

    try std.testing.expect(browser.Browser.iframeNavigationAllowed(
        &parent,
        &page,
        &same_origin,
        null,
    ));
    try std.testing.expect(browser.Browser.iframeNavigationAllowed(
        &parent,
        &page,
        &same_origin,
        &same_origin,
    ));
    try std.testing.expect(!browser.Browser.iframeNavigationAllowed(
        &parent,
        &page,
        &cross_origin,
        null,
    ));
    try std.testing.expect(!browser.Browser.iframeNavigationAllowed(
        &parent,
        &page,
        &same_origin,
        &cross_origin,
    ));
}

test "visited anchors are annotated and override descendant text at paint" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    const visited_url = try Url.init(allocator, "https://example.com/docs/target.html");
    defer visited_url.free(allocator);
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body>" ++
            "<a href=target.html><strong>visited</strong></a>" ++
            "<a href=other.html>fresh</a>" ++
            "</body></html>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    const base_url = try Url.init(allocator, "https://example.com/docs/index.html");
    defer base_url.free(allocator);

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.session_state = &session;
    test_browser.owns_session = false;
    try test_browser.annotateVisitedLinks(&root, &base_url);

    var nodes = std.ArrayList(*parser.Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &nodes);

    var visited_anchor: ?*parser.Node = null;
    var fresh_anchor: ?*parser.Node = null;
    var visited_text: ?*parser.Node = null;
    var fresh_text: ?*parser.Node = null;
    for (nodes.items) |node| {
        switch (node.*) {
            .element => |element| {
                if (!std.mem.eql(u8, element.tag, "a")) continue;
                const href = element.attributes.?.get("href").?;
                if (std.mem.eql(u8, href, "target.html")) {
                    visited_anchor = node;
                } else if (std.mem.eql(u8, href, "other.html")) {
                    fresh_anchor = node;
                }
            },
            .text => |text_node| {
                if (std.mem.eql(u8, text_node.text, "visited")) {
                    visited_text = node;
                } else if (std.mem.eql(u8, text_node.text, "fresh")) {
                    fresh_text = node;
                }
            },
        }
    }

    // The source page starts with a fresh target, as it would immediately
    // before a middle-click opens that target in another tab.
    try std.testing.expect(!visited_anchor.?.element.is_visited);
    try std.testing.expect(!fresh_anchor.?.element.is_visited);

    const normal = browser.Color{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const initially_painted = Layout.textColorForNode(visited_text, normal);
    try std.testing.expectEqual(normal.r, initially_painted.r);

    const source_generation = session.currentVisitedGeneration();
    test_browser.io = std.testing.io;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = std.ArrayList(*Tab).empty;
    test_browser.pending_new_tabs = std.ArrayList(Url).empty;
    defer {
        for (test_browser.pending_new_tabs.items) |*url| url.free(allocator);
        test_browser.pending_new_tabs.deinit(allocator);
        test_browser.tabs.deinit(allocator);
    }
    test_browser.active_tab_index = null;
    test_browser.shutting_down = false;
    test_browser.animation_timer_active = false;
    test_browser.needs_animation_frame = false;

    // Exercise the actual middle-click handoff: queueNewTab records the visit
    // before the browser thread consumes the owned target URL.
    try test_browser.queueNewTab(try visited_url.clone(allocator));
    const target_generation = session.currentVisitedGeneration();
    try std.testing.expect(target_generation != source_generation);
    try std.testing.expect(test_browser.needs_animation_frame);
    try std.testing.expectEqual(@as(usize, 1), test_browser.pending_new_tabs.items.len);

    var source_tab: Tab = undefined;
    source_tab.visited_generation = source_generation;
    source_tab.root_frame = null;
    source_tab.needs_paint = false;
    source_tab.pending_hover = false;
    try std.testing.expect(source_tab.animationFrameNeedsFullRender(&test_browser));
    try std.testing.expect(source_tab.needs_paint);

    // Activation/render observes the new generation and re-annotates the
    // still-live source DOM before repainting it.
    try test_browser.annotateVisitedLinks(&root, &base_url);
    try std.testing.expect(visited_anchor.?.element.is_visited);
    const painted_visited = Layout.textColorForNode(visited_text, normal);
    try std.testing.expectEqual(@as(u8, 128), painted_visited.r);
    try std.testing.expectEqual(@as(u8, 0), painted_visited.g);
    try std.testing.expectEqual(@as(u8, 128), painted_visited.b);

    const painted_fresh = Layout.textColorForNode(fresh_text, normal);
    try std.testing.expectEqual(normal.r, painted_fresh.r);
    try std.testing.expectEqual(normal.g, painted_fresh.g);
    try std.testing.expectEqual(normal.b, painted_fresh.b);
}

test "visited annotation uses the same invalid-target recovery as link navigation" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    const blank = try Url.blank(allocator);
    defer blank.free(allocator);
    _ = try session.markVisited(&blank);

    const base = try Url.init(allocator, "https://example.com/page.html");
    defer base.free(allocator);
    const recovered = try base.resolveForNavigation(allocator, "mailto:reader@example.com");
    defer recovered.free(allocator);
    try std.testing.expect(recovered.isAboutBlank());

    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><a href=mailto:reader@example.com>unsupported</a></body></html>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.session_state = &session;
    test_browser.owns_session = false;
    try test_browser.annotateVisitedLinks(&root, &base);

    var nodes = std.ArrayList(*parser.Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &nodes);
    for (nodes.items) |node| {
        if (node.* == .element and std.mem.eql(u8, node.element.tag, "a")) {
            // Frame.followLink also calls resolveForNavigation, so both the
            // click target and its annotation intentionally recover to blank.
            try std.testing.expect(node.element.is_visited);
            return;
        }
    }
    return error.MissingAnchor;
}
