//! Browser-owned chrome UI for tabs, navigation, and address entry.
//!
//! Chrome borrows the browser's font manager while it is alive and owns its
//! address-entry buffer. Input methods run on the browser thread.

const std = @import("std");
const browser = @import("root.zig");
const Rect = browser.Rect;
const Color = browser.Color;
const DisplayItem = browser.DisplayItem;
const font = @import("render/font.zig");
const Browser = browser.Browser;
const Url = @import("../network/url.zig").Url;

const search_url_prefix = "https://google.com/search?q=";

// Chrome represents the browser UI (tab bar, buttons, etc.)
pub const Chrome = @This();
font_size: i32 = 20,
font_height: i32 = 0,
padding: i32 = 5,
tabbar_top: i32 = 0,
tabbar_bottom: i32 = 0,
urlbar_top: i32 = 0,
urlbar_bottom: i32 = 0,
newtab_rect: Rect = undefined,
back_rect: Rect = undefined,
forward_rect: Rect = undefined,
bookmark_rect: Rect = undefined,
address_rect: Rect = undefined,
bottom: i32 = 0,
// Address bar editing state
focus: ?[]const u8 = null,
address_bar: std.ArrayList(u8) = undefined,
// Byte insertion point in address_bar, always in the inclusive range 0..len.
// Interactive text input is restricted to printable ASCII at the SDL boundary.
address_cursor: usize = 0,
allocator: std.mem.Allocator = undefined,

pub fn init(font_manager: *font.FontManager, window_width: i32, allocator: std.mem.Allocator) !Chrome {
    var chrome = Chrome{
        .address_bar = std.ArrayList(u8).empty,
        .allocator = allocator,
    };

    // Measure font height
    const test_glyph = try font_manager.getStyledGlyph(
        "X",
        .Normal,
        .Roman,
        chrome.font_size,
        .proportional,
    );
    chrome.font_height = test_glyph.ascent + test_glyph.descent;

    // Calculate tabbar bounds
    chrome.tabbar_top = 0;
    chrome.tabbar_bottom = chrome.font_height + 2 * chrome.padding;

    // Calculate URL bar bounds
    chrome.urlbar_top = chrome.tabbar_bottom;
    chrome.urlbar_bottom = chrome.urlbar_top + chrome.font_height + 2 * chrome.padding;
    chrome.bottom = chrome.urlbar_bottom;

    // Calculate new tab button bounds
    const plus_glyph = try font_manager.getStyledGlyph(
        "+",
        .Normal,
        .Roman,
        chrome.font_size,
        .proportional,
    );
    const plus_width = plus_glyph.w + 2 * chrome.padding;
    chrome.newtab_rect = Rect{
        .left = chrome.padding,
        .top = chrome.padding,
        .right = chrome.padding + plus_width,
        .bottom = chrome.padding + chrome.font_height,
    };

    // Calculate back button bounds
    const back_glyph = try font_manager.getStyledGlyph(
        "<",
        .Normal,
        .Roman,
        chrome.font_size,
        .proportional,
    );
    const back_width = back_glyph.w + 2 * chrome.padding;
    chrome.back_rect = Rect{
        .left = chrome.padding,
        .top = chrome.urlbar_top + chrome.padding,
        .right = chrome.padding + back_width,
        .bottom = chrome.urlbar_bottom - chrome.padding,
    };

    // Calculate forward button bounds
    const forward_glyph = try font_manager.getStyledGlyph(
        ">",
        .Normal,
        .Roman,
        chrome.font_size,
        .proportional,
    );
    const forward_width = forward_glyph.w + 2 * chrome.padding;
    chrome.forward_rect = Rect{
        .left = chrome.back_rect.right + chrome.padding,
        .top = chrome.urlbar_top + chrome.padding,
        .right = chrome.back_rect.right + chrome.padding + forward_width,
        .bottom = chrome.urlbar_bottom - chrome.padding,
    };

    // Calculate bookmark button bounds
    const bookmark_glyph = try font_manager.getStyledGlyph(
        "*",
        .Normal,
        .Roman,
        chrome.font_size,
        .proportional,
    );
    const bookmark_width = bookmark_glyph.w + 2 * chrome.padding;
    chrome.bookmark_rect = Rect{
        .left = chrome.forward_rect.right + chrome.padding,
        .top = chrome.urlbar_top + chrome.padding,
        .right = chrome.forward_rect.right + chrome.padding + bookmark_width,
        .bottom = chrome.urlbar_bottom - chrome.padding,
    };

    // Calculate address bar bounds
    chrome.address_rect = Rect{
        .left = chrome.bookmark_rect.right + chrome.padding,
        .top = chrome.urlbar_top + chrome.padding,
        .right = window_width - chrome.padding,
        .bottom = chrome.urlbar_bottom - chrome.padding,
    };

    return chrome;
}

pub fn navigationButtonColor(enabled: bool) Color {
    return if (enabled)
        .{ .r = 0, .g = 0, .b = 0, .a = 255 }
    else
        .{ .r = 160, .g = 160, .b = 160, .a = 255 };
}

pub fn bookmarkButtonFillColor(selected: bool) Color {
    return if (selected)
        .{ .r = 255, .g = 215, .b = 0, .a = 255 }
    else
        .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

/// Interpret address-bar text as an explicit URL, an obvious bare host, or a
/// search query. This policy intentionally belongs to chrome rather than the
/// general URL parser: document links must never become searches.
pub fn addressInputToUrl(allocator: std.mem.Allocator, input: []const u8) !Url {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyAddressInput;

    if (std.mem.startsWith(u8, trimmed, "//")) {
        const absolute = try std.fmt.allocPrint(allocator, "https:{s}", .{trimmed});
        defer allocator.free(absolute);
        return Url.initForNavigation(allocator, absolute);
    }

    // Check bare hosts before generic schemes because `localhost:8000` and
    // `example.com:443` are syntactically scheme-like to a URL parser.
    if (looksLikeBareHost(trimmed)) {
        const absolute = try std.fmt.allocPrint(allocator, "https://{s}", .{trimmed});
        defer allocator.free(absolute);
        return Url.initForNavigation(allocator, absolute);
    }

    if (Url.hasExplicitScheme(trimmed)) {
        return Url.initForNavigation(allocator, trimmed);
    }

    var search_url = std.ArrayList(u8).empty;
    defer search_url.deinit(allocator);
    try search_url.appendSlice(allocator, search_url_prefix);
    try appendSearchQuery(allocator, &search_url, trimmed);
    return Url.initForNavigation(allocator, search_url.items);
}

fn looksLikeBareHost(input: []const u8) bool {
    if (std.mem.indexOfAny(u8, input, " \t\r\n@") != null) return false;

    const authority_end = std.mem.indexOfAny(u8, input, "/?#") orelse input.len;
    const authority = input[0..authority_end];
    if (authority.len == 0) return false;

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (close + 1 == authority.len) return true;
        if (authority[close + 1] != ':') return false;
        return allAsciiDigits(authority[close + 2 ..]);
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |index| authority[0..index] else authority;
    if (host.len == 0) return false;
    if (colon) |index| {
        if (!allAsciiDigits(authority[index + 1 ..])) return false;
    }

    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.indexOfScalar(u8, host, '.') != null;
}

fn allAsciiDigits(input: []const u8) bool {
    if (input.len == 0) return false;
    for (input) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn appendSearchQuery(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    query: []const u8,
) !void {
    const hex = "0123456789ABCDEF";
    for (query) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            try output.append(allocator, '+');
        } else if (std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '_' or byte == '.' or byte == '~')
        {
            try output.append(allocator, byte);
        } else {
            try output.append(allocator, '%');
            try output.append(allocator, hex[byte >> 4]);
            try output.append(allocator, hex[byte & 0x0f]);
        }
    }
}

pub fn deinit(self: *Chrome) void {
    self.address_bar.deinit(self.allocator);
}

/// Update chrome geometry that depends on the native window width.
pub fn resize(self: *Chrome, window_width: i32) void {
    self.address_rect.right = @max(
        self.address_rect.left,
        window_width - self.padding,
    );
}

fn tabRect(self: *const Chrome, i: usize) Rect {
    const tabs_start = self.newtab_rect.right + self.padding;
    const tab_width = 100; // Approximate width for "Tab X"
    const idx: i32 = @intCast(i);
    return Rect{
        .left = tabs_start + tab_width * idx,
        .top = self.tabbar_top,
        .right = tabs_start + tab_width * (idx + 1),
        .bottom = self.tabbar_bottom,
    };
}

pub fn paint(self: *Chrome, allocator: std.mem.Allocator, b: *const Browser) !std.ArrayList(DisplayItem) {
    var cmds = std.ArrayList(DisplayItem).empty;

    // Draw white background for chrome
    try cmds.append(allocator, .{ .rect = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = b.window_width,
        .y2 = self.bottom,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    } });

    // Draw bottom border of chrome
    try cmds.append(allocator, .{ .line = .{
        .x1 = 0,
        .y1 = self.bottom,
        .x2 = b.window_width,
        .y2 = self.bottom,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .thickness = 1,
    } });

    // Draw new tab button outline
    try cmds.append(allocator, .{ .outline = .{
        .rect = self.newtab_rect,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .thickness = 1,
    } });

    // Draw "+" text
    const plus_glyph = try b.layout_engine.font_manager.getStyledGlyph(
        "+",
        .Normal,
        .Roman,
        self.font_size,
        .proportional,
    );
    try cmds.append(allocator, .{ .glyph = .{
        .x = self.newtab_rect.left + self.padding,
        .y = self.newtab_rect.top,
        .glyph = plus_glyph,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    } });

    // Draw tabs
    for (b.tabs.items, 0..) |_, i| {
        const bounds = self.tabRect(i);

        // Draw left border
        try cmds.append(allocator, .{ .line = .{
            .x1 = bounds.left,
            .y1 = 0,
            .x2 = bounds.left,
            .y2 = bounds.bottom,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .thickness = 1,
        } });

        // Draw right border
        try cmds.append(allocator, .{ .line = .{
            .x1 = bounds.right,
            .y1 = 0,
            .x2 = bounds.right,
            .y2 = bounds.bottom,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .thickness = 1,
        } });

        // If this is the active tab, draw the file folder effect
        if (b.active_tab_index) |active_idx| {
            if (i == active_idx) {
                // Draw line from left edge to tab start
                try cmds.append(allocator, .{ .line = .{
                    .x1 = 0,
                    .y1 = bounds.bottom,
                    .x2 = bounds.left,
                    .y2 = bounds.bottom,
                    .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                    .thickness = 1,
                } });

                // Draw line from tab end to right edge
                try cmds.append(allocator, .{ .line = .{
                    .x1 = bounds.right,
                    .y1 = bounds.bottom,
                    .x2 = b.window_width,
                    .y2 = bounds.bottom,
                    .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                    .thickness = 1,
                } });
            }
        }

        // Draw tab label
        var tab_label_buf: [20]u8 = undefined;
        const tab_label = try std.fmt.bufPrint(&tab_label_buf, "Tab {d}", .{i});
        const tab_glyph = try b.layout_engine.font_manager.getStyledGlyph(
            tab_label,
            .Normal,
            .Roman,
            self.font_size,
            .proportional,
        );
        try cmds.append(allocator, .{ .glyph = .{
            .x = bounds.left + self.padding,
            .y = bounds.top + self.padding,
            .glyph = tab_glyph,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        } });
    }

    const active_tab = b.activeTab();
    const back_color = navigationButtonColor(if (active_tab) |tab| tab.canGoBack() else false);
    const forward_color = navigationButtonColor(if (active_tab) |tab| tab.canGoForward() else false);

    // Draw back button
    try cmds.append(allocator, .{ .outline = .{
        .rect = self.back_rect,
        .color = back_color,
        .thickness = 1,
    } });

    const back_glyph = try b.layout_engine.font_manager.getStyledGlyph(
        "<",
        .Normal,
        .Roman,
        self.font_size,
        .proportional,
    );
    try cmds.append(allocator, .{ .glyph = .{
        .x = self.back_rect.left + self.padding,
        .y = self.back_rect.top,
        .glyph = back_glyph,
        .color = back_color,
    } });

    // Draw forward button
    try cmds.append(allocator, .{ .outline = .{
        .rect = self.forward_rect,
        .color = forward_color,
        .thickness = 1,
    } });

    const forward_glyph = try b.layout_engine.font_manager.getStyledGlyph(
        ">",
        .Normal,
        .Roman,
        self.font_size,
        .proportional,
    );
    try cmds.append(allocator, .{ .glyph = .{
        .x = self.forward_rect.left + self.padding,
        .y = self.forward_rect.top,
        .glyph = forward_glyph,
        .color = forward_color,
    } });

    // Draw bookmark toggle. Browser.lock stabilizes active_tab_url for this
    // paint call; BrowserSession independently synchronizes bookmark lookup.
    const page_is_bookmarked = b.activePageIsBookmarked();
    try cmds.append(allocator, .{ .rect = .{
        .x1 = self.bookmark_rect.left,
        .y1 = self.bookmark_rect.top,
        .x2 = self.bookmark_rect.right,
        .y2 = self.bookmark_rect.bottom,
        .color = bookmarkButtonFillColor(page_is_bookmarked),
    } });
    try cmds.append(allocator, .{ .outline = .{
        .rect = self.bookmark_rect,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .thickness = 1,
    } });
    const bookmark_glyph = try b.layout_engine.font_manager.getStyledGlyph(
        "*",
        .Normal,
        .Roman,
        self.font_size,
        .proportional,
    );
    try cmds.append(allocator, .{ .glyph = .{
        .x = self.bookmark_rect.left + self.padding,
        .y = self.bookmark_rect.top,
        .glyph = bookmark_glyph,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    } });

    // Draw address bar
    try cmds.append(allocator, .{ .outline = .{
        .rect = self.address_rect,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .thickness = 1,
    } });

    // Draw address bar content (either typed text or current URL)
    if (self.focus) |focus_str| {
        if (std.mem.eql(u8, focus_str, "address bar")) {
            // Draw the typed text
            std.debug.assert(self.address_cursor <= self.address_bar.items.len);
            var cursor_x = self.address_rect.left + self.padding;
            if (self.address_bar.items.len > 0) {
                const address_text: []const u8 = self.address_bar.items;
                var idx: usize = 0;
                var text_x = cursor_x;
                while (idx < address_text.len) {
                    if (idx == self.address_cursor) cursor_x = text_x;
                    const advance = std.unicode.utf8ByteSequenceLength(address_text[idx]) catch 1;
                    const next_idx = @min(address_text.len, idx + advance);
                    const gme = address_text[idx..next_idx];
                    const addr_glyph = try b.layout_engine.font_manager.getStyledGlyph(
                        gme,
                        .Normal,
                        .Roman,
                        self.font_size,
                        .proportional,
                    );
                    try cmds.append(allocator, .{ .glyph = .{
                        .x = text_x,
                        .y = self.address_rect.top,
                        .glyph = addr_glyph,
                        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                    } });
                    text_x += addr_glyph.w;
                    idx = next_idx;
                }
                if (self.address_cursor == address_text.len) cursor_x = text_x;
            }

            try cmds.append(allocator, .{
                .line = .{
                    .x1 = cursor_x,
                    .y1 = self.address_rect.top,
                    .x2 = cursor_x,
                    .y2 = self.address_rect.bottom,
                    .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 }, // Red cursor
                    .thickness = 1,
                },
            });
        }
    } else {
        if (b.active_tab_url) |url_text| {
            var idx: usize = 0;
            var text_x = self.address_rect.left + self.padding;
            while (idx < url_text.len) {
                const advance = std.unicode.utf8ByteSequenceLength(url_text[idx]) catch 1;
                const next_idx = @min(url_text.len, idx + advance);
                const gme = url_text[idx..next_idx];
                const url_glyph = try b.layout_engine.font_manager.getStyledGlyph(
                    gme,
                    .Normal,
                    .Roman,
                    self.font_size,
                    .proportional,
                );
                try cmds.append(allocator, .{ .glyph = .{
                    .x = text_x,
                    .y = self.address_rect.top,
                    .glyph = url_glyph,
                    .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                } });
                text_x += url_glyph.w;
                idx = next_idx;
            }
        }
    }

    return cmds;
}

pub fn click(self: *Chrome, b: *Browser, x: i32, y: i32) !bool {
    // Clear focus by default
    self.focus = null;
    self.address_cursor = 0;

    // Check if clicked on new tab button
    if (self.newtab_rect.containsPoint(x, y)) {
        const url = try Url.init(b.allocator, "https://browser.engineering/");
        b.newTab(url) catch |err| {
            std.log.err("Failed to create new tab: {any}", .{err});
        };
        return true;
    }

    // Check if clicked on back button
    if (self.back_rect.containsPoint(x, y)) {
        if (b.activeTab()) |tab| {
            if (tab.canGoBack()) tab.requestHistoryTraversal(b, .back);
        }
        return true;
    }

    // Check if clicked on forward button
    if (self.forward_rect.containsPoint(x, y)) {
        if (b.activeTab()) |tab| {
            if (tab.canGoForward()) tab.requestHistoryTraversal(b, .forward);
        }
        return true;
    }

    // Check if clicked on bookmark button
    if (self.bookmark_rect.containsPoint(x, y)) {
        _ = try b.toggleActiveBookmark();
        return true;
    }

    // Check if clicked on address bar
    if (self.address_rect.containsPoint(x, y)) {
        self.focusAddressBar();
        return true;
    }

    // Check if clicked on a tab
    for (0..b.tabs.items.len) |i| {
        if (self.tabRect(i).containsPoint(x, y)) {
            if (b.active_tab_index == null or b.active_tab_index.? != i) {
                b.setActiveTab(b.tabs.items[i]);
                return true;
            }
            return false;
        }
    }

    return false;
}

pub fn focusAddressBar(self: *Chrome) void {
    self.focus = "address bar";
    self.address_bar.clearRetainingCapacity();
    self.address_cursor = 0;
}

pub fn isAddressBarFocused(self: *const Chrome) bool {
    const focus = self.focus orelse return false;
    return std.mem.eql(u8, focus, "address bar");
}

pub fn keypress(self: *Chrome, char: u8) !bool {
    if (!self.isAddressBarFocused()) return false;
    std.debug.assert(self.address_cursor <= self.address_bar.items.len);
    try self.address_bar.insert(self.allocator, self.address_cursor, char);
    self.address_cursor += 1;
    return true;
}

pub fn backspace(self: *Chrome) bool {
    if (!self.isAddressBarFocused()) return false;
    std.debug.assert(self.address_cursor <= self.address_bar.items.len);
    if (self.address_cursor > 0) {
        _ = self.address_bar.orderedRemove(self.address_cursor - 1);
        self.address_cursor -= 1;
        return true;
    }
    return false;
}

pub fn moveCursorLeft(self: *Chrome) bool {
    if (!self.isAddressBarFocused()) return false;
    std.debug.assert(self.address_cursor <= self.address_bar.items.len);
    if (self.address_cursor > 0) {
        self.address_cursor -= 1;
        return true;
    }
    return false;
}

pub fn moveCursorRight(self: *Chrome) bool {
    if (!self.isAddressBarFocused()) return false;
    std.debug.assert(self.address_cursor <= self.address_bar.items.len);
    if (self.address_cursor < self.address_bar.items.len) {
        self.address_cursor += 1;
        return true;
    }
    return false;
}

pub fn blur(self: *Chrome) void {
    self.focus = null;
    self.address_bar.clearAndFree(self.allocator);
    self.address_bar = std.ArrayList(u8).empty;
    self.address_cursor = 0;
}

pub fn enter(self: *Chrome, b: *Browser) !bool {
    if (self.focus) |focus_str| {
        if (std.mem.eql(u8, focus_str, "address bar")) {
            if (self.address_bar.items.len == 0) return false;

            var url = try addressInputToUrl(b.allocator, self.address_bar.items);
            var url_owned = true;
            defer if (url_owned) url.free(b.allocator);

            if (b.activeTab()) |tab| {
                const url_ptr = b.allocator.create(Url) catch |alloc_err| {
                    std.log.err("Failed to allocate URL: {any}", .{alloc_err});
                    return false;
                };
                url_ptr.* = url;
                url_owned = false;

                var url_ptr_owned = true;
                defer if (url_ptr_owned) {
                    url_ptr.*.free(b.allocator);
                    b.allocator.destroy(url_ptr);
                };

                // Copy the optimistic display URL before scheduleLoad can
                // transfer url_ptr to a worker. Bookmarks continue using the
                // Browser's separate committed URL snapshot.
                b.setActiveTabUrl(url_ptr);
                b.scheduleLoad(tab, url_ptr, null) catch |err| {
                    b.restoreDisplayedUrlToCommitted();
                    std.log.err("Failed to load URL: {any}", .{err});
                    return false;
                };
                url_ptr_owned = false;
            }

            self.focus = null;
            self.address_bar.clearAndFree(self.allocator);
            self.address_bar = std.ArrayList(u8).empty;
            self.address_cursor = 0;
            return true;
        }
    }
    return false;
}
