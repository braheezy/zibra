//! Browser-owned chrome UI for tabs, navigation, and address entry.
//!
//! Chrome owns a small explicit widget surface and its address-entry buffer.
//! Painting, geometry, hit testing, and input methods run on the browser thread.

const std = @import("std");
const browser = @import("root.zig");
const Rect = browser.Rect;
const Color = browser.Color;
const DisplayItem = browser.DisplayItem;
const font = @import("render/font.zig");
const Browser = browser.Browser;
const Url = @import("../network/url.zig").Url;

const search_url_prefix = "https://google.com/search?q=";
pub const secure_address_prefix = "🔒 ";
// Keep the document viewport origin compatible with the former hand-painted
// chrome. Screenshot comparisons intentionally ignore chrome pixels, but page
// content must not move merely because its implementation changed.
const chrome_height: i32 = 66;
const chrome_row_height: i32 = 33;
const control_height: i32 = 24;
const control_width: i32 = 32;
const toolbar_padding_left: i32 = 6;
const control_gap: i32 = 2;
const address_gap: i32 = 8;
const tab_width: i32 = 112;

const palette = struct {
    const tabbar = Color{ .r = 190, .g = 190, .b = 190, .a = 255 };
    const toolbar = Color{ .r = 216, .g = 216, .b = 216, .a = 255 };
    const active_tab = Color{ .r = 248, .g = 247, .b = 242, .a = 255 };
    const inactive_tab = Color{ .r = 190, .g = 190, .b = 190, .a = 255 };
    const control = Color{ .r = 224, .g = 224, .b = 224, .a = 255 };
    const control_disabled = Color{ .r = 196, .g = 196, .b = 196, .a = 255 };
    const address = Color{ .r = 250, .g = 249, .b = 244, .a = 255 };
    const ink = Color{ .r = 42, .g = 42, .b = 42, .a = 255 };
    const muted_ink = Color{ .r = 116, .g = 116, .b = 116, .a = 255 };
    const shadow = Color{ .r = 104, .g = 104, .b = 104, .a = 255 };
    const highlight = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const accent = Color{ .r = 49, .g = 93, .b = 156, .a = 255 };
};

// Chrome represents the browser UI (tab bar, buttons, etc.). Its widget
// geometry is explicit so visual layout and hit testing share one owner.
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
font_manager: font.FontManager = undefined,
display_list: ?[]DisplayItem = null,

pub fn init(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    window_width: i32,
    allocator: std.mem.Allocator,
    rtl_text: bool,
) !Chrome {
    var chrome = Chrome{
        .address_bar = std.ArrayList(u8).empty,
        .allocator = allocator,
        .font_size = 12,
        .font_manager = try font.FontManager.init(allocator, io, environ),
    };
    errdefer chrome.deinit();

    try chrome.font_manager.loadSystemFont(chrome.font_size);
    _ = rtl_text;

    chrome.font_height = control_height;
    chrome.padding = 4;
    chrome.tabbar_top = 0;
    chrome.tabbar_bottom = chrome_row_height;
    chrome.urlbar_top = chrome.tabbar_bottom;
    chrome.urlbar_bottom = chrome_height;
    chrome.bottom = chrome_height;
    chrome.updateGeometry(window_width);

    return chrome;
}

fn updateGeometry(self: *Chrome, window_width: i32) void {
    const toolbar_top = chrome_row_height + @divTrunc(chrome_row_height - control_height, 2);
    const button_step = control_width + control_gap;
    self.newtab_rect = .{ .left = toolbar_padding_left, .top = 4, .right = toolbar_padding_left + control_width, .bottom = 4 + control_height };
    self.back_rect = .{ .left = toolbar_padding_left, .top = toolbar_top, .right = toolbar_padding_left + control_width, .bottom = toolbar_top + control_height };
    self.forward_rect = .{ .left = toolbar_padding_left + button_step, .top = toolbar_top, .right = toolbar_padding_left + button_step + control_width, .bottom = toolbar_top + control_height };
    self.bookmark_rect = .{ .left = toolbar_padding_left + 2 * button_step, .top = toolbar_top, .right = toolbar_padding_left + 2 * button_step + control_width, .bottom = toolbar_top + control_height };
    self.address_rect = .{
        .left = self.bookmark_rect.right + address_gap,
        .top = toolbar_top,
        .right = @max(self.bookmark_rect.right + address_gap, window_width - browser.scrollbar_width - 2 * browser.h_offset),
        .bottom = toolbar_top + control_height,
    };
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
    self.retireDisplayList();
    self.font_manager.deinit();
    self.address_bar.deinit(self.allocator);
}

fn retireDisplayList(self: *Chrome) void {
    if (self.display_list) |items| {
        DisplayItem.freeList(self.allocator, items);
        self.display_list = null;
    }
}

/// Update chrome geometry that depends on the native window width.
pub fn resize(self: *Chrome, window_width: i32) void {
    self.address_rect.right = @max(self.address_rect.left, window_width - self.padding);
}

/// Refresh the explicit widget geometry after a native window resize.
pub fn resizeDocument(self: *Chrome, window_width: i32) void {
    self.retireDisplayList();
    self.updateGeometry(window_width);
}

fn tabRect(self: *const Chrome, i: usize) Rect {
    const tabs_start = self.newtab_rect.right;
    const idx: i32 = @intCast(i);
    return Rect{
        .left = tabs_start + tab_width * idx,
        .top = self.tabbar_top,
        .right = tabs_start + tab_width * (idx + 1),
        .bottom = self.tabbar_bottom,
    };
}

const ChromeAction = union(enum) {
    new_tab,
    back,
    forward,
    bookmark,
    address,
    tab: usize,
};

const ButtonKind = enum {
    plus,
    back,
    forward,
    bookmark,
};

fn appendRect(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(DisplayItem),
    rect: Rect,
    color: Color,
) !void {
    if (rect.width() == 0 or rect.height() == 0) return;
    try commands.append(allocator, .{ .rect = .{
        .x1 = rect.left,
        .y1 = rect.top,
        .x2 = rect.right,
        .y2 = rect.bottom,
        .color = color,
    } });
}

fn appendLine(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(DisplayItem),
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    color: Color,
    thickness: i32,
) !void {
    if (thickness <= 0) return;
    try commands.append(allocator, .{ .line = .{
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
        .color = color,
        .thickness = thickness,
    } });
}

fn appendBeveledBox(
    self: *const Chrome,
    commands: *std.ArrayList(DisplayItem),
    rect: Rect,
    fill: Color,
    raised: bool,
) !void {
    if (rect.width() == 0 or rect.height() == 0) return;
    try appendRect(self.allocator, commands, rect, fill);
    const top_left = if (raised) palette.highlight else palette.shadow;
    const bottom_right = if (raised) palette.shadow else palette.highlight;
    try appendLine(self.allocator, commands, rect.left, rect.top, rect.right - 1, rect.top, top_left, 1);
    try appendLine(self.allocator, commands, rect.left, rect.top, rect.left, rect.bottom - 1, top_left, 1);
    try appendLine(self.allocator, commands, rect.left, rect.bottom - 1, rect.right - 1, rect.bottom - 1, bottom_right, 1);
    try appendLine(self.allocator, commands, rect.right - 1, rect.top, rect.right - 1, rect.bottom - 1, bottom_right, 1);
}

fn appendText(
    self: *Chrome,
    commands: *std.ArrayList(DisplayItem),
    text: []const u8,
    left: i32,
    top: i32,
    right: i32,
    height: i32,
    size: i32,
    family: font.FontFamily,
    weight: font.FontWeight,
    color: Color,
    emit: bool,
) !i32 {
    if (text.len == 0 or right <= left) return left;
    const reference = try self.font_manager.getStyledGlyph("M", weight, .Roman, size, family);
    const reference_height = @max(reference.ascent + reference.descent, 1);
    const baseline = top + @max(@divTrunc(height - reference_height, 2), 0) + reference.ascent;

    var cursor = left;
    var index: usize = 0;
    while (index < text.len) {
        const sequence = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const next = @min(index + sequence, text.len);
        const glyph = try self.font_manager.getStyledGlyph(text[index..next], weight, .Roman, size, family);
        if (cursor + glyph.w > right) break;
        if (emit and glyph.w > 0 and glyph.h > 0) {
            try commands.append(self.allocator, .{ .glyph = .{
                .x = cursor,
                .y = baseline - glyph.ascent,
                .glyph = glyph,
                .color = color,
                .page_zoom = 1.0,
            } });
        }
        cursor += glyph.w;
        index = next;
    }
    return cursor;
}

fn appendPlus(self: *const Chrome, commands: *std.ArrayList(DisplayItem), rect: Rect, color: Color) !void {
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    try appendLine(self.allocator, commands, cx - 6, cy, cx + 6, cy, color, 2);
    try appendLine(self.allocator, commands, cx, cy - 6, cx, cy + 6, color, 2);
}

fn appendChevron(
    self: *const Chrome,
    commands: *std.ArrayList(DisplayItem),
    rect: Rect,
    color: Color,
    forward: bool,
) !void {
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    if (forward) {
        try appendLine(self.allocator, commands, cx - 5, cy - 6, cx + 2, cy, color, 2);
        try appendLine(self.allocator, commands, cx + 2, cy, cx - 5, cy + 6, color, 2);
    } else {
        try appendLine(self.allocator, commands, cx + 5, cy - 6, cx - 2, cy, color, 2);
        try appendLine(self.allocator, commands, cx - 2, cy, cx + 5, cy + 6, color, 2);
    }
}

fn appendBookmark(self: *const Chrome, commands: *std.ArrayList(DisplayItem), rect: Rect, color: Color) !void {
    const left = rect.left + 10;
    const right = rect.right - 10;
    const top = rect.top + 5;
    const bottom = rect.bottom - 5;
    try appendLine(self.allocator, commands, left, top, right, top, color, 2);
    try appendLine(self.allocator, commands, left, top, left, bottom, color, 2);
    try appendLine(self.allocator, commands, right, top, right, bottom, color, 2);
    try appendLine(self.allocator, commands, left, bottom, @divTrunc(left + right, 2), bottom - 4, color, 2);
    try appendLine(self.allocator, commands, right, bottom, @divTrunc(left + right, 2), bottom - 4, color, 2);
}

fn appendLock(self: *const Chrome, commands: *std.ArrayList(DisplayItem), rect: Rect, color: Color) !void {
    const body = Rect{
        .left = rect.left + 2,
        .top = rect.top + 9,
        .right = rect.right - 2,
        .bottom = rect.bottom - 2,
    };
    try appendRect(self.allocator, commands, body, color);
    try appendLine(self.allocator, commands, rect.left + 4, rect.top + 9, rect.left + 4, rect.top + 5, color, 2);
    try appendLine(self.allocator, commands, rect.right - 4, rect.top + 9, rect.right - 4, rect.top + 5, color, 2);
    try appendLine(self.allocator, commands, rect.left + 4, rect.top + 5, rect.right - 4, rect.top + 5, color, 2);
}

fn appendButton(
    self: *Chrome,
    commands: *std.ArrayList(DisplayItem),
    rect: Rect,
    kind: ButtonKind,
    enabled: bool,
    selected: bool,
) !void {
    const fill = if (!enabled) palette.control_disabled else if (selected) palette.accent else palette.control;
    const ink = if (!enabled) palette.muted_ink else if (selected) palette.highlight else palette.ink;
    try appendBeveledBox(self, commands, rect, fill, true);
    switch (kind) {
        .plus => try appendPlus(self, commands, rect, ink),
        .back => try appendChevron(self, commands, rect, ink, false),
        .forward => try appendChevron(self, commands, rect, ink, true),
        .bookmark => try appendBookmark(self, commands, rect, ink),
    }
}

fn paintTab(self: *Chrome, commands: *std.ArrayList(DisplayItem), b: *const Browser, index: usize) !void {
    const rect = self.tabRect(index);
    const active = b.active_tab_index != null and b.active_tab_index.? == index;
    const panel = Rect{
        .left = rect.left,
        .top = rect.top + 2,
        .right = rect.right,
        .bottom = rect.bottom,
    };
    try appendBeveledBox(self, commands, panel, if (active) palette.active_tab else palette.inactive_tab, active);
    var fallback: [32]u8 = undefined;
    const fallback_title = std.fmt.bufPrint(&fallback, "Tab {d}", .{index}) catch "Tab";
    const title = if (b.tabs.items[index].title) |value| if (value.len > 0) value else fallback_title else fallback_title;
    _ = try appendText(
        self,
        commands,
        title,
        rect.left + 9,
        rect.top + 3,
        rect.right - 9,
        rect.height() - 5,
        self.font_size,
        .proportional,
        if (active) .Bold else .Normal,
        if (active) palette.accent else palette.ink,
        true,
    );
}

fn paintAddress(self: *Chrome, commands: *std.ArrayList(DisplayItem), b: *const Browser) !void {
    const focused = self.isAddressBarFocused();
    const fill = if (focused) palette.highlight else palette.address;
    const border = if (focused) palette.accent else palette.shadow;
    try appendBeveledBox(self, commands, self.address_rect, fill, false);
    const text = if (focused) self.address_bar.items else b.active_tab_url orelse "";
    var text_left = self.address_rect.left + 7;
    if (!focused and shouldShowPadlock(
        b.active_tab_url,
        b.active_tab_committed_url,
        b.active_tab_committed_security,
    )) {
        try appendLock(self, commands, .{
            .left = self.address_rect.left + 4,
            .top = self.address_rect.top + 3,
            .right = self.address_rect.left + 16,
            .bottom = self.address_rect.bottom - 3,
        }, palette.accent);
        text_left += 16;
    }
    _ = try appendText(
        self,
        commands,
        text,
        text_left,
        self.address_rect.top,
        self.address_rect.right - 7,
        self.address_rect.height(),
        self.font_size,
        .monospace,
        .Normal,
        palette.ink,
        true,
    );
    if (focused) {
        std.debug.assert(self.address_cursor <= self.address_bar.items.len);
        const prefix = self.address_bar.items[0..self.address_cursor];
        const cursor_x = try appendText(
            self,
            commands,
            prefix,
            text_left,
            self.address_rect.top,
            self.address_rect.right - 7,
            self.address_rect.height(),
            self.font_size,
            .monospace,
            .Normal,
            palette.accent,
            false,
        );
        try appendLine(self.allocator, commands, cursor_x, self.address_rect.top + 3, cursor_x, self.address_rect.bottom - 3, palette.accent, 1);
    }
    const border_thickness: i32 = if (focused) 2 else 1;
    try appendLine(self.allocator, commands, self.address_rect.left, self.address_rect.top, self.address_rect.right - 1, self.address_rect.top, border, border_thickness);
    try appendLine(self.allocator, commands, self.address_rect.left, self.address_rect.top, self.address_rect.left, self.address_rect.bottom - 1, border, border_thickness);
    try appendLine(self.allocator, commands, self.address_rect.left, self.address_rect.bottom - 1, self.address_rect.right - 1, self.address_rect.bottom - 1, border, border_thickness);
    try appendLine(self.allocator, commands, self.address_rect.right - 1, self.address_rect.top, self.address_rect.right - 1, self.address_rect.bottom - 1, border, border_thickness);
}

/// The padlock is shown only for the committed page currently displayed.
pub fn shouldShowPadlock(
    displayed_url: ?[]const u8,
    committed_url: ?[]const u8,
    security: browser.NavigationSecurity,
) bool {
    if (security != .secure) return false;
    const displayed = displayed_url orelse return false;
    const committed = committed_url orelse return false;
    return std.mem.eql(u8, displayed, committed);
}

fn rebuildDisplayList(self: *Chrome, b: *const Browser) !void {
    self.retireDisplayList();
    self.updateGeometry(b.window_width);

    var commands = std.ArrayList(DisplayItem).empty;
    errdefer {
        DisplayItem.freeItems(self.allocator, commands.items);
        commands.deinit(self.allocator);
    }

    try appendRect(self.allocator, &commands, .{
        .left = 0,
        .top = self.tabbar_top,
        .right = b.window_width,
        .bottom = self.tabbar_bottom,
    }, palette.tabbar);
    try appendRect(self.allocator, &commands, .{
        .left = 0,
        .top = self.tabbar_bottom,
        .right = b.window_width,
        .bottom = self.bottom,
    }, palette.toolbar);
    try appendLine(self.allocator, &commands, 0, self.tabbar_bottom - 1, b.window_width, self.tabbar_bottom - 1, palette.shadow, 1);
    try appendLine(self.allocator, &commands, 0, self.bottom - 1, b.window_width, self.bottom - 1, palette.shadow, 1);

    try appendButton(self, &commands, self.newtab_rect, .plus, true, false);
    for (b.tabs.items, 0..) |_, index| {
        try self.paintTab(&commands, b, index);
    }

    const active_tab = b.activeTab();
    try appendButton(
        self,
        &commands,
        self.back_rect,
        .back,
        active_tab != null and active_tab.?.canGoBack(),
        false,
    );
    try appendButton(
        self,
        &commands,
        self.forward_rect,
        .forward,
        active_tab != null and active_tab.?.canGoForward(),
        false,
    );
    try appendButton(self, &commands, self.bookmark_rect, .bookmark, true, b.activePageIsBookmarked());
    try self.paintAddress(&commands, b);

    self.display_list = try commands.toOwnedSlice(self.allocator);
}

/// Paint the private widget surface. The returned list is borrowed until the
/// next paint, resize, or deinit call.
pub fn paint(self: *Chrome, b: *const Browser) ![]const DisplayItem {
    try self.rebuildDisplayList(b);
    return self.display_list orelse &.{};
}

fn actionAt(self: *const Chrome, b: *const Browser, x: i32, y: i32) ?ChromeAction {
    if (self.newtab_rect.containsPoint(x, y)) return .new_tab;
    if (self.back_rect.containsPoint(x, y)) return .back;
    if (self.forward_rect.containsPoint(x, y)) return .forward;
    if (self.bookmark_rect.containsPoint(x, y)) return .bookmark;
    if (self.address_rect.containsPoint(x, y)) return .address;
    for (0..b.tabs.items.len) |index| {
        if (self.tabRect(index).containsPoint(x, y)) return .{ .tab = index };
    }
    return null;
}

fn activateAction(self: *Chrome, b: *Browser, action: ChromeAction) !bool {
    switch (action) {
        .new_tab => {
            const url = try Url.init(b.allocator, "https://browser.engineering/");
            b.newTab(url) catch |err| {
                std.log.err("Failed to create new tab: {any}", .{err});
            };
            return true;
        },
        .back => {
            if (b.activeTab()) |tab| if (tab.canGoBack()) tab.requestHistoryTraversal(b, .back);
            return true;
        },
        .forward => {
            if (b.activeTab()) |tab| if (tab.canGoForward()) tab.requestHistoryTraversal(b, .forward);
            return true;
        },
        .bookmark => {
            _ = try b.toggleActiveBookmark();
            return true;
        },
        .address => {
            self.focusAddressBar();
            return true;
        },
        .tab => |index| {
            if (index >= b.tabs.items.len) return false;
            if (b.active_tab_index == null or b.active_tab_index.? != index) {
                b.setActiveTab(b.tabs.items[index]);
                return true;
            }
            return false;
        },
    }
}

pub fn click(self: *Chrome, b: *Browser, x: i32, y: i32) !bool {
    const action = self.actionAt(b, x, y);
    self.focus = null;
    self.address_cursor = 0;

    if (action) |value| return self.activateAction(b, value);
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

test "custom chrome geometry keeps widget hit regions aligned" {
    var chrome: Chrome = undefined;
    chrome.padding = 4;
    chrome.tabbar_top = 0;
    chrome.tabbar_bottom = chrome_row_height;
    chrome.urlbar_top = chrome_row_height;
    chrome.urlbar_bottom = chrome_height;
    chrome.bottom = chrome_height;
    chrome.updateGeometry(800);

    try std.testing.expect(chrome.newtab_rect.containsPoint(10, 10));
    try std.testing.expect(chrome.back_rect.containsPoint(10, 45));
    try std.testing.expect(chrome.address_rect.left > chrome.bookmark_rect.right);
    try std.testing.expectEqual(chrome.tabRect(0).right, chrome.tabRect(1).left);
}
