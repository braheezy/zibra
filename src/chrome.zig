const std = @import("std");
const browser = @import("browser.zig");
const Rect = browser.Rect;
const DisplayItem = browser.DisplayItem;
const font = @import("font.zig");
const Browser = browser.Browser;
const Url = @import("url.zig").Url;

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
address_rect: Rect = undefined,
bottom: i32 = 0,
// Address bar editing state
focus: ?[]const u8 = null,
address_bar: std.ArrayList(u8) = undefined,
allocator: std.mem.Allocator = undefined,
// Cached display list (owned, must be freed)
cached_display_list: ?[]DisplayItem = null,

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
        false,
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
        false,
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
        false,
    );
    const back_width = back_glyph.w + 2 * chrome.padding;
    chrome.back_rect = Rect{
        .left = chrome.padding,
        .top = chrome.urlbar_top + chrome.padding,
        .right = chrome.padding + back_width,
        .bottom = chrome.urlbar_bottom - chrome.padding,
    };

    // Calculate address bar bounds
    chrome.address_rect = Rect{
        .left = chrome.back_rect.right + chrome.padding,
        .top = chrome.urlbar_top + chrome.padding,
        .right = window_width - chrome.padding,
        .bottom = chrome.urlbar_bottom - chrome.padding,
    };

    return chrome;
}

pub fn deinit(self: *Chrome) void {
    self.address_bar.deinit(self.allocator);
    if (self.cached_display_list) |list| {
        self.allocator.free(list);
    }
}

pub fn tabRect(self: *const Chrome, i: usize) Rect {
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
    // Free the old display list if it exists
    if (self.cached_display_list) |old_list| {
        allocator.free(old_list);
        self.cached_display_list = null;
    }

    // and only freed/reallocated when the URL actually changes

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
        false,
    );
    try cmds.append(allocator, .{ .glyph = .{
        .x = self.newtab_rect.left + self.padding,
        .y = self.newtab_rect.top,
        .glyph = plus_glyph,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    } });

    // Draw tabs
    for (b.tabs.items, 0..) |tab, i| {
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
            false,
        );
        try cmds.append(allocator, .{ .glyph = .{
            .x = bounds.left + self.padding,
            .y = bounds.top + self.padding,
            .glyph = tab_glyph,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        } });

        _ = tab; // Silence unused variable warning
    }

    // Draw back button
    try cmds.append(allocator, .{ .outline = .{
        .rect = self.back_rect,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .thickness = 1,
    } });

    const back_glyph = try b.layout_engine.font_manager.getStyledGlyph(
        "<",
        .Normal,
        .Roman,
        self.font_size,
        false,
    );
    try cmds.append(allocator, .{ .glyph = .{
        .x = self.back_rect.left + self.padding,
        .y = self.back_rect.top,
        .glyph = back_glyph,
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
            var cursor_x = self.address_rect.left + self.padding;
            if (self.address_bar.items.len > 0) {
                const address_text: []const u8 = self.address_bar.items;
                var idx: usize = 0;
                var text_x = cursor_x;
                while (idx < address_text.len) {
                    const advance = std.unicode.utf8ByteSequenceLength(address_text[idx]) catch 1;
                    const next_idx = @min(address_text.len, idx + advance);
                    const gme = address_text[idx..next_idx];
                    const addr_glyph = try b.layout_engine.font_manager.getStyledGlyph(
                        gme,
                        .Normal,
                        .Roman,
                        self.font_size,
                        false,
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
                cursor_x = text_x;
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
                    false,
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
            tab.goBack(b) catch |err| {
                std.log.err("Failed to go back: {any}", .{err});
            };
        }
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
                b.active_tab_index = i;
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
}

pub fn keypress(self: *Chrome, char: u8) !bool {
    if (self.focus) |focus_str| {
        if (std.mem.eql(u8, focus_str, "address bar")) {
            try self.address_bar.append(self.allocator, char);
            return true;
        }
    }
    return false;
}

pub fn backspace(self: *Chrome) bool {
    if (self.focus) |focus_str| {
        if (std.mem.eql(u8, focus_str, "address bar")) {
            if (self.address_bar.items.len > 0) {
                _ = self.address_bar.pop();
                return true;
            }
        }
    }
    return false;
}

pub fn blur(self: *Chrome) void {
    self.focus = null;
    self.address_bar.clearAndFree(self.allocator);
    self.address_bar = std.ArrayList(u8).empty;
}

pub fn enter(self: *Chrome, b: *Browser) !bool {
    if (self.focus) |focus_str| {
        if (std.mem.eql(u8, focus_str, "address bar")) {
            if (self.address_bar.items.len == 0) return false;

            const url = Url.init(b.allocator, self.address_bar.items) catch |err| {
                std.log.err("Invalid URL: {any}", .{err});
                self.focus = null;
                return false;
            };

            if (b.activeTab()) |tab| {
                const url_ptr = b.allocator.create(Url) catch |alloc_err| {
                    std.log.err("Failed to allocate URL: {any}", .{alloc_err});
                    return false;
                };
                url_ptr.* = url;
                var url_owned = true;
                defer if (url_owned) {
                    url_ptr.*.free(b.allocator);
                    b.allocator.destroy(url_ptr);
                };

                b.scheduleLoad(tab, url_ptr, null) catch |err| {
                    std.log.err("Failed to load URL: {any}", .{err});
                    return false;
                };
                // Update the displayed URL immediately so we don't flash the old one
                // while the new page loads.
                b.setActiveTabUrl(url_ptr);
                url_owned = false;
            }

            self.focus = null;
            self.address_bar.clearAndFree(self.allocator);
            self.address_bar = std.ArrayList(u8).empty;
            return true;
        }
    }
    return false;
}
