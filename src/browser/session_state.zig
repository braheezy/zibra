//! Browser-session navigation state shared independently of any one tab or
//! native window.
//!
//! URL sets own canonical serialized URL strings. A `BrowserSession` may be
//! shared by multiple browser windows; its mutex protects cross-window and
//! tab-worker access. The owner must outlive every Browser/Tab that borrows it.

const std = @import("std");
const Mutex = @import("../runtime/sync.zig").Mutex;
const url_module = @import("../network/url.zig");
const Url = url_module.Url;
const HttpCache = url_module.HttpCache;

pub const BrowserSession = struct {
    allocator: std.mem.Allocator,
    /// Navigation metadata uses `lock`; network transport/cache/cookie state
    /// has an independent lock so fetches never nest with visited/bookmark
    /// publication.
    lock: Mutex,
    network_lock: Mutex,
    http_client: std.http.Client,
    cookie_jar: std.StringHashMap(url_module.CookieEntry),
    http_cache: HttpCache,
    visited_urls: std.StringHashMap(void),
    bookmarked_urls: std.StringHashMap(void),
    visited_generation: std.atomic.Value(u64),
    bookmark_generation: std.atomic.Value(u64),

    pub const BookmarkSnapshot = struct {
        allocator: std.mem.Allocator,
        urls: std.ArrayList([]u8),

        pub fn deinit(self: *BookmarkSnapshot) void {
            for (self.urls.items) |url| self.allocator.free(url);
            self.urls.deinit(self.allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) BrowserSession {
        return .{
            .allocator = allocator,
            .lock = .init(io),
            .network_lock = .init(io),
            .http_client = .{ .allocator = allocator, .io = io },
            .cookie_jar = std.StringHashMap(url_module.CookieEntry).init(allocator),
            .http_cache = HttpCache.init(allocator),
            .visited_urls = std.StringHashMap(void).init(allocator),
            .bookmarked_urls = std.StringHashMap(void).init(allocator),
            .visited_generation = std.atomic.Value(u64).init(0),
            .bookmark_generation = std.atomic.Value(u64).init(0),
        };
    }

    /// The caller must first stop every tab/window that can access this
    /// session. URL keys are owned independently of the Url values that
    /// supplied them.
    pub fn deinit(self: *BrowserSession) void {
        self.http_client.deinit();
        self.http_cache.deinit();
        var cookie_iterator = self.cookie_jar.iterator();
        while (cookie_iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cookie_jar.deinit();

        var iterator = self.visited_urls.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.visited_urls.deinit();

        var bookmark_iterator = self.bookmarked_urls.keyIterator();
        while (bookmark_iterator.next()) |key| self.allocator.free(key.*);
        self.bookmarked_urls.deinit();
    }

    /// Record a canonical URL for this browser session. Returns whether a new
    /// entry was inserted.
    pub fn markVisited(self: *BrowserSession, url: *const Url) !bool {
        const canonical = try url.*.toOwnedString(self.allocator);
        var canonical_owned = true;
        defer if (canonical_owned) self.allocator.free(canonical);

        self.lock.lock();
        defer self.lock.unlock();
        if (self.visited_urls.contains(canonical)) return false;

        try self.visited_urls.put(canonical, {});
        canonical_owned = false;
        _ = self.visited_generation.fetchAdd(1, .release);
        return true;
    }

    pub fn isVisited(self: *BrowserSession, url: *const Url) !bool {
        const canonical = try url.*.toOwnedString(self.allocator);
        defer self.allocator.free(canonical);

        self.lock.lock();
        defer self.lock.unlock();
        return self.visited_urls.contains(canonical);
    }

    pub fn visitedCount(self: *BrowserSession) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.visited_urls.count();
    }

    pub fn currentVisitedGeneration(self: *const BrowserSession) u64 {
        return self.visited_generation.load(.acquire);
    }

    /// Toggle a canonical serialized URL. The returned value is the new
    /// selected state. Keys are copied so chrome and Tab URL snapshots remain
    /// independent owners.
    pub fn toggleBookmarkCanonical(self: *BrowserSession, canonical: []const u8) !bool {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.bookmarked_urls.fetchRemove(canonical)) |removed| {
            self.allocator.free(removed.key);
            _ = self.bookmark_generation.fetchAdd(1, .release);
            return false;
        }

        const owned = try self.allocator.dupe(u8, canonical);
        errdefer self.allocator.free(owned);
        try self.bookmarked_urls.put(owned, {});
        _ = self.bookmark_generation.fetchAdd(1, .release);
        return true;
    }

    pub fn toggleBookmark(self: *BrowserSession, url: *const Url) !bool {
        const canonical = try url.*.toOwnedString(self.allocator);
        defer self.allocator.free(canonical);
        return self.toggleBookmarkCanonical(canonical);
    }

    pub fn isBookmarkedCanonical(self: *BrowserSession, canonical: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.bookmarked_urls.contains(canonical);
    }

    pub fn isBookmarked(self: *BrowserSession, url: *const Url) !bool {
        const canonical = try url.*.toOwnedString(self.allocator);
        defer self.allocator.free(canonical);
        return self.isBookmarkedCanonical(canonical);
    }

    pub fn bookmarkCount(self: *BrowserSession) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.bookmarked_urls.count();
    }

    pub fn currentBookmarkGeneration(self: *const BrowserSession) u64 {
        return self.bookmark_generation.load(.acquire);
    }

    /// Return an independent, lexicographically sorted snapshot. Neither the
    /// outer list nor its strings borrow the session map.
    pub fn bookmarkSnapshot(self: *BrowserSession, allocator: std.mem.Allocator) !BookmarkSnapshot {
        var urls = std.ArrayList([]u8).empty;
        errdefer {
            for (urls.items) |url| allocator.free(url);
            urls.deinit(allocator);
        }

        self.lock.lock();
        {
            defer self.lock.unlock();
            var iterator = self.bookmarked_urls.keyIterator();
            while (iterator.next()) |key| {
                const copy = try allocator.dupe(u8, key.*);
                urls.append(allocator, copy) catch |err| {
                    allocator.free(copy);
                    return err;
                };
            }
        }

        std.mem.sort([]u8, urls.items, {}, struct {
            fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);
        return .{ .allocator = allocator, .urls = urls };
    }

    /// Build an owned browser-internal page from a stable bookmark snapshot.
    /// Both href attributes and visible labels are HTML-escaped.
    pub fn bookmarksPageHtml(self: *BrowserSession, allocator: std.mem.Allocator) ![]u8 {
        var snapshot = try self.bookmarkSnapshot(allocator);
        defer snapshot.deinit();

        var html = std.ArrayList(u8).empty;
        errdefer html.deinit(allocator);
        try html.appendSlice(
            allocator,
            "<!doctype html><html><head><title>Bookmarks</title></head>" ++
                "<body><h1>Bookmarks</h1>",
        );
        if (snapshot.urls.items.len == 0) {
            try html.appendSlice(allocator, "<p>No bookmarks yet.</p>");
        } else {
            try html.appendSlice(allocator, "<ul>");
            for (snapshot.urls.items) |url| {
                try html.appendSlice(allocator, "<li><a href=\"");
                try appendHtmlEscaped(allocator, &html, url);
                try html.appendSlice(allocator, "\">");
                try appendHtmlEscaped(allocator, &html, url);
                try html.appendSlice(allocator, "</a></li>");
            }
            try html.appendSlice(allocator, "</ul>");
        }
        try html.appendSlice(allocator, "</body></html>");
        return html.toOwnedSlice(allocator);
    }
};

fn appendHtmlEscaped(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    input: []const u8,
) !void {
    for (input) |byte| {
        const escaped = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        };
        if (escaped) |text| {
            try output.appendSlice(allocator, text);
        } else {
            try output.append(allocator, byte);
        }
    }
}
