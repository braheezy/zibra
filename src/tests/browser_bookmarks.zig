//! Focused browser-session, chrome, and internal-page tests for bookmarks.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Chrome = @import("../browser/chrome.zig");
const Layout = @import("../browser/render/layout.zig");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const parser = @import("../document/parser.zig");
const Url = @import("../network/url.zig").Url;

test "bookmark state toggles canonical URLs and publishes generations" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    const first = try Url.init(allocator, "https://EXAMPLE.com:443/docs?q=1#part");
    defer first.free(allocator);
    const equivalent = try Url.init(allocator, "https://example.com/docs?q=1#part");
    defer equivalent.free(allocator);

    const initial_generation = session.currentBookmarkGeneration();
    try std.testing.expect(try session.toggleBookmark(&first));
    try std.testing.expect(try session.isBookmarked(&equivalent));
    try std.testing.expectEqual(@as(usize, 1), session.bookmarkCount());
    const selected_generation = session.currentBookmarkGeneration();
    try std.testing.expect(selected_generation != initial_generation);

    try std.testing.expect(!try session.toggleBookmark(&equivalent));
    try std.testing.expect(!try session.isBookmarked(&first));
    try std.testing.expectEqual(@as(usize, 0), session.bookmarkCount());
    try std.testing.expect(session.currentBookmarkGeneration() != selected_generation);
}

test "bookmark page is sorted, escaped, and owns its snapshot" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    const later = "https://z.example/?q=<tag>&say=\"hello\"'";
    const earlier = "https://a.example/first";
    try std.testing.expect(try session.toggleBookmarkCanonical(later));
    try std.testing.expect(try session.toggleBookmarkCanonical(earlier));

    var snapshot = try session.bookmarkSnapshot(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.urls.items.len);
    try std.testing.expectEqualStrings(earlier, snapshot.urls.items[0]);
    try std.testing.expectEqualStrings(later, snapshot.urls.items[1]);

    // Mutating the session cannot invalidate the independently owned snapshot.
    try std.testing.expect(!try session.toggleBookmarkCanonical(earlier));
    try std.testing.expectEqualStrings(earlier, snapshot.urls.items[0]);

    const html = try session.bookmarksPageHtml(allocator);
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://z.example/") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;tag&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&amp;say=") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;hello&quot;&apos;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<tag>") == null);

    var html_parser = try parser.HTMLParser.init(allocator, html);
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    var nodes = std.ArrayList(*parser.Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &nodes);
    var anchor: ?*parser.Node = null;
    for (nodes.items) |node| {
        if (node.* == .element and std.mem.eql(u8, node.element.tag, "a")) anchor = node;
        if (node.* == .element) try std.testing.expect(!std.mem.eql(u8, node.element.tag, "tag"));
    }
    try std.testing.expectEqualStrings(later, anchor.?.element.attributes.?.get("href").?);
    const displayed = try Layout.decodeTextForDisplay(
        allocator,
        anchor.?.element.children.items[0].text.text,
    );
    defer allocator.free(displayed);
    try std.testing.expectEqualStrings(later, displayed);
}

test "generated bookmark href and visible label round trip through parsing" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    const bookmarked = try Url.init(
        allocator,
        "https://example.com/search?q=one&next=two%20words",
    );
    defer bookmarked.free(allocator);
    try std.testing.expect(try session.toggleBookmark(&bookmarked));
    const canonical = try bookmarked.toOwnedString(allocator);
    defer allocator.free(canonical);

    const html = try session.bookmarksPageHtml(allocator);
    defer allocator.free(html);
    var html_parser = try parser.HTMLParser.init(allocator, html);
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    var nodes = std.ArrayList(*parser.Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &nodes);

    var anchor: ?*parser.Node = null;
    for (nodes.items) |node| {
        if (node.* == .element and std.mem.eql(u8, node.element.tag, "a")) anchor = node;
    }
    const href = anchor.?.element.attributes.?.get("href").?;
    try std.testing.expectEqualStrings(canonical, href);
    const displayed = try Layout.decodeTextForDisplay(
        allocator,
        anchor.?.element.children.items[0].text.text,
    );
    defer allocator.free(displayed);
    try std.testing.expectEqualStrings(canonical, displayed);

    const bookmarks_page = try Url.initForNavigation(allocator, "about:bookmarks");
    defer bookmarks_page.free(allocator);
    const clicked = try bookmarks_page.resolveForNavigation(allocator, href);
    defer clicked.free(allocator);
    const clicked_canonical = try clicked.toOwnedString(allocator);
    defer allocator.free(clicked_canonical);
    try std.testing.expectEqualStrings(canonical, clicked_canonical);
}

test "empty bookmark page has a stable explanation" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    const html = try session.bookmarksPageHtml(allocator);
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<title>Bookmarks</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "No bookmarks yet.") != null);
}

test "navigation document helper owns generated about bookmarks HTML" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();
    try std.testing.expect(try session.toggleBookmarkCanonical("https://example.com/saved"));

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.session_state = &session;

    const url = try Url.initForNavigation(allocator, "about:bookmarks");
    defer url.free(allocator);
    var final_url: ?Url = null;
    var document = try test_browser.fetchNavigationDocument(
        url,
        null,
        null,
        &final_url,
    );
    defer document.deinit(allocator);

    try std.testing.expect(final_url == null);
    try std.testing.expect(document.owned_body != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        document.response.body,
        "https://example.com/saved",
    ) != null);
}

test "about bookmarks is a supported navigation target" {
    const allocator = std.testing.allocator;
    const direct = try Url.initForNavigation(allocator, "about:bookmarks");
    defer direct.free(allocator);
    try std.testing.expect(direct.isAboutBookmarks());

    const base = try Url.init(allocator, "https://example.com/page.html");
    defer base.free(allocator);
    const link = try base.resolveForNavigation(allocator, "about:bookmarks");
    defer link.free(allocator);
    try std.testing.expect(link.isAboutBookmarks());
}

test "bookmark chrome button toggles the active URL and selected color" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.session_state = &session;
    test_browser.lock = .init(std.testing.io);
    test_browser.active_tab_url = try allocator.dupe(u8, "https://example.com/pending");
    defer allocator.free(test_browser.active_tab_url.?);
    test_browser.active_tab_committed_url = try allocator.dupe(u8, "https://example.com/current");
    defer allocator.free(test_browser.active_tab_committed_url.?);

    var chrome = Chrome{
        .address_bar = std.ArrayList(u8).empty,
        .allocator = allocator,
    };
    defer chrome.deinit();
    chrome.newtab_rect = .{ .left = 0, .top = 0, .right = 10, .bottom = 10 };
    chrome.back_rect = .{ .left = 10, .top = 0, .right = 20, .bottom = 10 };
    chrome.forward_rect = .{ .left = 20, .top = 0, .right = 30, .bottom = 10 };
    chrome.bookmark_rect = .{ .left = 30, .top = 0, .right = 40, .bottom = 10 };
    chrome.address_rect = .{ .left = 40, .top = 0, .right = 100, .bottom = 10 };

    try std.testing.expect(try chrome.click(&test_browser, 35, 5));
    try std.testing.expect(session.isBookmarkedCanonical(test_browser.active_tab_committed_url.?));
    try std.testing.expect(!session.isBookmarkedCanonical(test_browser.active_tab_url.?));
    const selected = Chrome.bookmarkButtonFillColor(true);
    try std.testing.expectEqual(@as(u8, 255), selected.r);
    try std.testing.expectEqual(@as(u8, 215), selected.g);
    try std.testing.expectEqual(@as(u8, 0), selected.b);

    try std.testing.expect(try chrome.click(&test_browser, 35, 5));
    try std.testing.expect(!session.isBookmarkedCanonical(test_browser.active_tab_committed_url.?));
}

test "chrome URL snapshot preserves bookmarkable URLs longer than 1024 bytes" {
    const allocator = std.testing.allocator;
    const long_input = try allocator.alloc(u8, 1200);
    defer allocator.free(long_input);
    @memset(long_input, 'a');
    const prefix = "https://example.com/a";
    @memcpy(long_input[0..prefix.len], prefix);

    var url = try Url.init(allocator, long_input);
    defer url.free(allocator);
    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.lock = .init(std.testing.io);
    test_browser.active_tab_url = null;
    test_browser.active_tab_committed_url = null;
    defer if (test_browser.active_tab_url) |cached| allocator.free(cached);

    test_browser.setActiveTabUrl(&url);
    try std.testing.expect(test_browser.active_tab_url != null);
    try std.testing.expect(test_browser.active_tab_url.?.len > 1024);
}
