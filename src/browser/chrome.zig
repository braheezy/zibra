//! Browser-owned chrome UI for tabs, navigation, and address entry.
//!
//! Chrome owns a small internal HTML document and a dedicated layout engine,
//! plus its address-entry buffer. Input methods and internal document rebuilds
//! run on the browser thread.

const std = @import("std");
const browser = @import("root.zig");
const Rect = browser.Rect;
const Color = browser.Color;
const DisplayItem = browser.DisplayItem;
const Layout = @import("render/layout.zig");
const document = @import("../document/parser.zig");
const Node = document.Node;
const HTMLParser = document.HTMLParser;
const CSSParser = @import("../document/css_parser.zig").CSSParser;
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
const chrome_style_sheet =
    \\html { display: block; background-color: white; }
    \\body { display: block; background-color: white; font-size: 16px; }
    \\div { display: block; height: 33px; }
    \\button { width: 32px; height: 24px; background-color: lightgray; font-size: 16px; }
    \\input { height: 24px; background-color: white; font-size: 16px; }
    \\a { color: blue; }
;

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
// The HTML chrome has its own layout/font state because tab layout runs on
// workers while native chrome is rebuilt synchronously on the UI thread.
layout_engine: ?*Layout = null,
rules: ?[]CSSParser.CSSRule = null,
html_source: ?[]u8 = null,
document_root: ?*Node = null,
document_layout: ?*Layout.DocumentLayout = null,
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
    };
    errdefer chrome.deinit();

    chrome.layout_engine = try Layout.init(
        allocator,
        io,
        environ,
        window_width,
        chrome_height,
        rtl_text,
    );
    var css_parser = try CSSParser.init(allocator, chrome_style_sheet, false);
    defer css_parser.deinit(allocator);
    chrome.rules = try css_parser.parse(allocator);

    // Stable fallback geometry remains available before the first raster and
    // in focused unit tests that deliberately construct Chrome without SDL.
    chrome.font_size = 12;
    chrome.font_height = control_height;
    chrome.padding = 4;
    chrome.tabbar_top = 0;
    chrome.tabbar_bottom = chrome_row_height;
    chrome.urlbar_top = chrome.tabbar_bottom;
    chrome.urlbar_bottom = chrome_height;
    chrome.bottom = chrome_height;
    chrome.updateFallbackGeometry(window_width);

    return chrome;
}

fn updateFallbackGeometry(self: *Chrome, window_width: i32) void {
    self.newtab_rect = .{ .left = 0, .top = 0, .right = control_width, .bottom = control_height };
    self.back_rect = .{ .left = 0, .top = chrome_row_height, .right = control_width, .bottom = chrome_row_height + control_height };
    self.forward_rect = .{ .left = control_width, .top = chrome_row_height, .right = 2 * control_width, .bottom = chrome_row_height + control_height };
    self.bookmark_rect = .{ .left = 2 * control_width, .top = chrome_row_height, .right = 3 * control_width, .bottom = chrome_row_height + control_height };
    self.address_rect = .{
        .left = 3 * control_width,
        .top = chrome_row_height,
        .right = @max(3 * control_width, window_width - browser.scrollbar_width - 2 * browser.h_offset),
        .bottom = chrome_row_height + control_height,
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
    self.retireDocument();
    if (self.rules) |rules| {
        for (rules) |*rule| rule.deinit(self.allocator);
        self.allocator.free(rules);
        self.rules = null;
    }
    if (self.layout_engine) |engine| {
        engine.deinit();
        self.layout_engine = null;
    }
    self.address_bar.deinit(self.allocator);
}

/// Update chrome geometry that depends on the native window width.
pub fn resize(self: *Chrome, window_width: i32) void {
    self.address_rect.right = @max(self.address_rect.left, window_width - self.padding);
}

/// Resize the live internal HTML document. Kept separate from resize() so the
/// longstanding geometry-only test seam can use a deliberately partial value.
pub fn resizeDocument(self: *Chrome, window_width: i32) void {
    if (self.layout_engine) |engine| {
        self.retireDocument();
        engine.window_width = window_width;
    }
    self.updateFallbackGeometry(window_width);
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

const ChromeAction = union(enum) {
    new_tab,
    back,
    forward,
    bookmark,
    address,
    tab: usize,
};

fn appendHtmlEscaped(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |byte| {
        const escaped = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        };
        if (escaped) |replacement| {
            try output.appendSlice(allocator, replacement);
        } else {
            try output.append(allocator, byte);
        }
    }
}

fn appendFormatted(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    const fragment = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(fragment);
    try output.appendSlice(allocator, fragment);
}

/// A typed or pending HTTPS target must never inherit the padlock from the
/// document still on screen. The indicator appears only when the displayed
/// and committed snapshots identify the same successfully verified page.
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

fn buildHtml(self: *const Chrome, b: *const Browser) ![]u8 {
    var html = std.ArrayList(u8).empty;
    errdefer html.deinit(self.allocator);

    try html.appendSlice(self.allocator, "<html><body><div><button id=\"new-tab\">+</button>");
    for (b.tabs.items, 0..) |_, index| {
        try appendFormatted(self.allocator, &html, "<a href=\"zibra-tab:{d}\"", .{index});
        if (b.active_tab_index != null and b.active_tab_index.? == index) {
            try html.appendSlice(self.allocator, " style=\"font-weight:bold\"");
        }
        try html.append(self.allocator, '>');
        try appendFormatted(self.allocator, &html, "Tab {d}", .{index});
        try html.appendSlice(self.allocator, "</a>");
    }

    try html.appendSlice(self.allocator, "</div><div><button id=\"back\"");
    if (b.activeTab()) |tab| {
        if (!tab.canGoBack()) try html.appendSlice(self.allocator, " style=\"color:gray\"");
    } else {
        try html.appendSlice(self.allocator, " style=\"color:gray\"");
    }
    try html.appendSlice(self.allocator, ">&lt;</button><button id=\"forward\"");
    if (b.activeTab()) |tab| {
        if (!tab.canGoForward()) try html.appendSlice(self.allocator, " style=\"color:gray\"");
    } else {
        try html.appendSlice(self.allocator, " style=\"color:gray\"");
    }
    try html.appendSlice(self.allocator, ">&gt;</button><button id=\"bookmark\"");
    if (b.activePageIsBookmarked()) {
        try html.appendSlice(self.allocator, " style=\"background-color:yellow\"");
    }
    try html.appendSlice(self.allocator, ">*</button>");

    const layout_width = @max(
        b.window_width - browser.scrollbar_width - 2 * browser.h_offset,
        1,
    );
    const address_width = @max(layout_width - 3 * control_width, 1);
    try appendFormatted(
        self.allocator,
        &html,
        "<input id=\"address\" style=\"width:{d}px;height:{d}px;background-color:white\" value=\"",
        .{ address_width, control_height },
    );
    const address_text = if (self.isAddressBarFocused())
        self.address_bar.items
    else
        b.active_tab_url orelse "";
    if (!self.isAddressBarFocused() and shouldShowPadlock(
        b.active_tab_url,
        b.active_tab_committed_url,
        b.active_tab_committed_security,
    )) {
        try html.appendSlice(self.allocator, secure_address_prefix);
    }
    try appendHtmlEscaped(self.allocator, &html, address_text);
    try html.appendSlice(self.allocator, "\"></div></body></html>");
    return html.toOwnedSlice(self.allocator);
}

fn retireDocument(self: *Chrome) void {
    if (self.display_list) |items| {
        DisplayItem.freeList(self.allocator, items);
        self.display_list = null;
    }
    if (self.document_layout) |layout| {
        layout.deinit();
        self.allocator.destroy(layout);
        self.document_layout = null;
    }
    if (self.document_root) |root| {
        root.deinit(self.allocator);
        self.allocator.destroy(root);
        self.document_root = null;
    }
    if (self.html_source) |source| {
        self.allocator.free(source);
        self.html_source = null;
    }
}

fn nodeAttribute(node: *Node, name: []const u8) ?[]const u8 {
    return switch (node.*) {
        .element => |*element| if (element.attributes) |*attrs| attrs.get(name) else null,
        .text => null,
    };
}

fn actionForNode(start: *Node) ?ChromeAction {
    var current: ?*Node = start;
    while (current) |node| {
        switch (node.*) {
            .text => |*text_node| current = text_node.parent,
            .element => |*element| {
                if (std.ascii.eqlIgnoreCase(element.tag, "input")) {
                    if (nodeAttribute(node, "id")) |id| {
                        if (std.mem.eql(u8, id, "address")) return .address;
                    }
                } else if (std.ascii.eqlIgnoreCase(element.tag, "button")) {
                    if (nodeAttribute(node, "id")) |id| {
                        if (std.mem.eql(u8, id, "new-tab")) return .new_tab;
                        if (std.mem.eql(u8, id, "back")) return .back;
                        if (std.mem.eql(u8, id, "forward")) return .forward;
                        if (std.mem.eql(u8, id, "bookmark")) return .bookmark;
                    }
                } else if (std.ascii.eqlIgnoreCase(element.tag, "a")) {
                    if (nodeAttribute(node, "href")) |href| {
                        const prefix = "zibra-tab:";
                        if (std.mem.startsWith(u8, href, prefix)) {
                            const index = std.fmt.parseInt(usize, href[prefix.len..], 10) catch return null;
                            return .{ .tab = index };
                        }
                    }
                }
                current = element.parent;
            },
        }
    }
    return null;
}

fn findElementById(node: *Node, id: []const u8) ?*Node {
    switch (node.*) {
        .text => return null,
        .element => |*element| {
            if (nodeAttribute(node, "id")) |candidate| {
                if (std.mem.eql(u8, candidate, id)) return node;
            }
            for (element.children.items) |*child| {
                if (findElementById(child, id)) |found| return found;
            }
        },
    }
    return null;
}

fn updateAddressBounds(self: *Chrome) void {
    const root = self.document_root orelse return;
    const engine = self.layout_engine orelse return;
    const input = findElementById(root, "address") orelse return;
    const bounds = engine.input_bounds.get(input) orelse return;
    self.address_rect = .{
        .left = bounds.x - browser.h_offset,
        .top = bounds.y - browser.v_offset,
        .right = bounds.x - browser.h_offset + bounds.width,
        .bottom = bounds.y - browser.v_offset + bounds.height,
    };
}

fn appendAddressCaret(self: *Chrome, commands: *std.ArrayList(DisplayItem)) !void {
    if (!self.isAddressBarFocused()) return;
    std.debug.assert(self.address_cursor <= self.address_bar.items.len);
    const engine = self.layout_engine orelse return;

    var cursor_x = self.address_rect.left + 2;
    var index: usize = 0;
    while (index < self.address_cursor) {
        const advance = std.unicode.utf8ByteSequenceLength(self.address_bar.items[index]) catch 1;
        const next = @min(self.address_cursor, index + advance);
        const glyph = try engine.font_manager.getStyledGlyph(
            self.address_bar.items[index..next],
            .Normal,
            .Roman,
            self.font_size,
            .proportional,
        );
        cursor_x += glyph.w;
        index = next;
    }
    try commands.append(self.allocator, .{ .line = .{
        .x1 = cursor_x,
        .y1 = self.address_rect.top,
        .x2 = cursor_x,
        .y2 = self.address_rect.bottom,
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .thickness = 1,
    } });
}

fn rebuildDocument(self: *Chrome, b: *const Browser) !void {
    const engine = self.layout_engine orelse return error.ChromeLayoutUnavailable;
    const rules = self.rules orelse return error.ChromeStylesUnavailable;
    self.retireDocument();

    self.html_source = try self.buildHtml(b);
    errdefer self.retireDocument();

    var html_parser = try HTMLParser.init(self.allocator, self.html_source.?);
    defer html_parser.deinit(self.allocator);
    const root = try self.allocator.create(Node);
    var root_owned = true;
    errdefer if (root_owned) self.allocator.destroy(root);
    root.* = try html_parser.parse();
    self.document_root = root;
    root_owned = false;
    document.fixParentPointers(root, null);
    try document.style(self.allocator, root, rules);

    const layout = try engine.buildDocument(root);
    self.document_layout = layout;
    const painted = try engine.paintDocument(layout);
    var painted_owned = true;
    errdefer if (painted_owned) DisplayItem.freeList(self.allocator, painted);

    var commands = std.ArrayList(DisplayItem).empty;
    errdefer {
        DisplayItem.freeItems(self.allocator, commands.items);
        commands.deinit(self.allocator);
    }
    try commands.append(self.allocator, .{ .transform = .{
        .translate_x = -browser.h_offset,
        .translate_y = -browser.v_offset,
        .children = painted,
    } });
    painted_owned = false;
    self.updateAddressBounds();
    try commands.append(self.allocator, .{ .line = .{
        .x1 = 0,
        .y1 = self.bottom - 1,
        .x2 = b.window_width,
        .y2 = self.bottom - 1,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .thickness = 1,
    } });
    try self.appendAddressCaret(&commands);
    self.display_list = try commands.toOwnedSlice(self.allocator);
}

/// Rebuild and paint the browser-owned internal HTML document. The returned
/// list is borrowed until the next chrome paint, resize, or deinit.
pub fn paint(self: *Chrome, b: *const Browser) ![]const DisplayItem {
    try self.rebuildDocument(b);
    return self.display_list orelse &.{};
}

fn actionAt(self: *const Chrome, x: i32, y: i32) ?ChromeAction {
    const items = self.display_list orelse return null;
    const hit = DisplayItem.hitTestDevice(items, x, y, 1.0) orelse return null;
    const node = hit.source.originatingNode() orelse return null;
    return actionForNode(node);
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
    const has_html_document = self.display_list != null;
    const html_action = self.actionAt(x, y);
    // Clear focus by default
    self.focus = null;
    self.address_cursor = 0;

    if (html_action) |action| return self.activateAction(b, action);
    if (has_html_document) return false;

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

test "HTML chrome semantic actions resolve through descendant paint sources" {
    const allocator = std.testing.allocator;
    const source =
        "<html><body><button id=\"new-tab\"><b>+</b></button>" ++
        "<input id=\"address\"><a href=\"zibra-tab:7\"><span>Recipes</span></a></body></html>";
    var html_parser = try HTMLParser.init(allocator, source);
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);

    const new_tab = findElementById(&root, "new-tab").?;
    const button_child = &new_tab.element.children.items[0].element.children.items[0];
    try std.testing.expect(actionForNode(button_child).? == .new_tab);

    const address = findElementById(&root, "address").?;
    try std.testing.expect(actionForNode(address).? == .address);

    const link = &new_tab.element.parent.?.element.children.items[2].element.children.items[0];
    const tab_action = actionForNode(link).?;
    try std.testing.expectEqual(@as(usize, 7), tab_action.tab);
}

test "HTML chrome generated values are attribute safe" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try appendHtmlEscaped(allocator, &output, "<&\"'>");
    try std.testing.expectEqualStrings("&lt;&amp;&quot;&apos;&gt;", output.items);
}
