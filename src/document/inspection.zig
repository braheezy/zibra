//! Document pipeline used by Zibra's non-interactive inspection commands.
//!
//! It deliberately stops after parsing and styling. Layout and paint callers
//! can build on its DOM, but it never starts Browser, JavaScript, or SDL.

const std = @import("std");
const parser = @import("parser.zig");
const CSSParser = @import("css_parser.zig").CSSParser;
const stylesheet = @import("css_stylesheet.zig");
const style = @import("style.zig");
const url_module = @import("../network/url.zig");
const Url = url_module.Url;

const default_html = @embedFile("../assets/default.html");
const default_style_sheet = @embedFile("../browser/browser.css");

pub const Options = struct {
    media: CSSParser.MediaEnvironment = .{ .viewport_width_css = 800, .viewport_height_css = 600 },
};

const SelectedRules = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(CSSParser.CSSRule) = .empty,
    keyframes: std.ArrayList(CSSParser.KeyframesRule) = .empty,

    fn deinit(self: *SelectedRules) void {
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        for (self.keyframes.items) |*rule| rule.deinit(self.allocator);
        self.keyframes.deinit(self.allocator);
    }
};

pub const Page = struct {
    allocator: std.mem.Allocator,
    body: []u8,
    root: parser.Node,
    rules: std.ArrayList(CSSParser.CSSRule),
    keyframes: std.ArrayList(CSSParser.KeyframesRule),
    sheets: std.ArrayList(stylesheet.Sheet) = .empty,
    media: CSSParser.MediaEnvironment = .{ .viewport_width_css = 800, .viewport_height_css = 600 },

    pub fn load(init: std.process.Init, allocator: std.mem.Allocator, source_url: ?Url) !Page {
        return loadWithMedia(init, allocator, source_url, .{ .viewport_width_css = 800, .viewport_height_css = 600 });
    }

    /// Load a browser-free inspection generation using the caller's viewport
    /// for conditional stylesheet selection. The returned root moves by value.
    pub fn loadWithMedia(init: std.process.Init, allocator: std.mem.Allocator, source_url: ?Url, media: CSSParser.MediaEnvironment) !Page {
        return loadWithOptions(init, allocator, source_url, .{ .media = media });
    }

    /// Owns one inspection generation using the native CSS parser.
    /// The caller repairs the returned root move.
    pub fn loadWithOptions(init: std.process.Init, allocator: std.mem.Allocator, source_url: ?Url, options: Options) !Page {
        const body = if (source_url) |url|
            try fetchDecoded(init, allocator, url, null, null)
        else
            try allocator.dupe(u8, default_html);
        var page = try initOwned(allocator, body, options);
        errdefer page.deinit();
        page.repairParentPointers();
        try page.appendRules(default_style_sheet, false, .{ .origin = .user_agent });
        try page.loadDocumentStylesheets(init, source_url);
        try page.finish();
        return page;
    }

    /// Copies HTML and loads embedded style elements/attributes without any
    /// network or native state. Link resources require loadWithOptions instead.
    pub fn fromHtml(allocator: std.mem.Allocator, html: []const u8, options: Options) !Page {
        var page = try initOwned(allocator, try allocator.dupe(u8, html), options);
        errdefer page.deinit();
        page.repairParentPointers();
        try page.appendRules(default_style_sheet, false, .{ .origin = .user_agent });
        var nodes = std.ArrayList(*parser.Node).empty;
        defer nodes.deinit(allocator);
        try parser.treeToList(allocator, &page.root, &nodes);
        for (nodes.items) |node| {
            if (node.* != .element or !std.mem.eql(u8, node.element.tag, "style")) continue;
            const css_text = (try parser.collectInlineStyleText(allocator, node)) orelse continue;
            errdefer allocator.free(css_text);
            try page.appendRules(css_text, true, .{
                .media = if (node.element.attributes) |attrs| attrs.get("media") else null,
            });
        }
        try page.finish();
        return page;
    }

    // Consumes body on success and failure. The Page owns root/body together
    // after this return, avoiding overlapping cleanup of moved HTML owners.
    fn initOwned(allocator: std.mem.Allocator, body: []u8, options: Options) !Page {
        errdefer allocator.free(body);

        var html_parser = try parser.HTMLParser.init(allocator, body);
        defer html_parser.deinit(allocator);
        return Page{
            .allocator = allocator,
            .body = body,
            .root = try html_parser.parse(),
            .rules = std.ArrayList(CSSParser.CSSRule).empty,
            .keyframes = std.ArrayList(CSSParser.KeyframesRule).empty,
            .media = options.media,
        };
    }

    fn finish(self: *Page) !void {
        const selection = try self.selectSheets(self.media, null, null);
        self.rules = selection.rules;
        self.keyframes = selection.keyframes;
        try self.restyle();
    }

    pub fn deinit(self: *Page) void {
        self.root.deinit(self.allocator);
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        for (self.keyframes.items) |*rule| rule.deinit(self.allocator);
        self.keyframes.deinit(self.allocator);
        for (self.sheets.items) |*sheet| sheet.deinit();
        self.sheets.deinit(self.allocator);
        self.allocator.free(self.body);
    }

    /// `Page` is returned by value, so parser-installed pointers to the root
    /// must be repaired once the caller has placed the page at its final
    /// address and before any ancestry walk.
    pub fn repairParentPointers(self: *Page) void {
        parser.fixParentPointers(&self.root, null);
    }

    pub fn sheetCount(self: *const Page) usize {
        return self.sheets.items.len;
    }

    /// Generation-bound source borrow. Media reselection preserves its identity;
    /// successful replacement invalidates borrows of the replaced sheet.
    /// Requires index < sheetCount().
    pub fn sheetSource(self: *const Page, index: usize) []const u8 {
        return self.sheets.items[index].source();
    }

    /// Requires a final-address DOM and retired layout/display consumers.
    /// Stages all fallible selections before invalidating the styled tree;
    /// failure leaves the installed generation unchanged. Call restyle afterward.
    pub fn reselectMedia(self: *Page, media: CSSParser.MediaEnvironment) !void {
        const selection = try self.selectSheets(media, null, null);
        self.installSelection(selection);
        self.media = media;
    }

    /// Requires retired layout/display consumers. Parse and selection failures
    /// publish nothing. Success installs a dirty generation, retires old rule
    /// owners before their source, and requires restyle before layout/paint.
    pub fn replaceStylesheet(self: *Page, index: usize, source: []const u8) !void {
        if (index >= self.sheets.items.len) return error.InvalidStylesheetIndex;
        var replacement = try stylesheet.Sheet.init(self.allocator, source, self.sheets.items[index].options());
        errdefer replacement.deinit();
        const selection = try self.selectSheets(self.media, index, replacement);
        self.installSelection(selection);
        self.sheets.items[index].deinit();
        self.sheets.items[index] = replacement;
    }

    /// Styling is a separate fallible phase: on OOM the installed generation
    /// remains valid and dirty work can be retried. Current inline attributes
    /// are parsed during styling; this is not a live CSSOM mutation API.
    pub fn restyle(self: *Page) !void {
        try style.styleWithKeyframes(self.allocator, &self.root, self.rules.items, self.keyframes.items);
    }

    fn selectSheets(self: *Page, media: CSSParser.MediaEnvironment, replacement_index: ?usize, replacement: ?stylesheet.Sheet) !SelectedRules {
        var selected = SelectedRules{ .allocator = self.allocator };
        errdefer selected.deinit();
        var builder = stylesheet.SelectionBuilder.init(self.allocator);
        defer builder.deinit();
        for (self.sheets.items, 0..) |sheet, index| {
            const current = if (replacement_index != null and replacement_index.? == index) replacement.? else sheet;
            try builder.append(current, media, current.metadata.media);
        }
        var selection = try builder.finish();
        defer selection.deinit();
        try selection.appendTo(&selected.rules, &selected.keyframes);
        return selected;
    }

    fn installSelection(self: *Page, selection: SelectedRules) void {
        parser.clearStyleInvalidations(&self.root);
        parser.dirtyStyleSubtree(&self.root);
        var previous = SelectedRules{ .allocator = self.allocator, .rules = self.rules, .keyframes = self.keyframes };
        self.rules = selection.rules;
        self.keyframes = selection.keyframes;
        previous.deinit();
    }

    fn appendRules(self: *Page, source: []const u8, keep_text: bool, options: stylesheet.Options) !void {
        var sheet = try stylesheet.Sheet.init(self.allocator, source, options);
        errdefer sheet.deinit();
        try self.sheets.append(self.allocator, sheet);
        if (keep_text) self.allocator.free(source);
    }

    fn loadDocumentStylesheets(self: *Page, init: std.process.Init, page_url: ?Url) !void {
        const document_base = if (page_url) |url| try url.toOwnedString(self.allocator) else null;
        defer if (document_base) |base| self.allocator.free(base);
        var nodes = std.ArrayList(*parser.Node).empty;
        defer nodes.deinit(self.allocator);
        try parser.treeToList(self.allocator, &self.root, &nodes);

        var http_client: std.http.Client = .{ .allocator = self.allocator, .io = init.io };
        defer http_client.deinit();
        var cookie_jar = std.StringHashMap(url_module.CookieEntry).init(self.allocator);
        defer deinitCookieJar(self.allocator, &cookie_jar);

        for (nodes.items) |node| {
            const element = switch (node.*) {
                .element => |*value| value,
                .text => continue,
            };

            if (std.mem.eql(u8, element.tag, "style")) {
                const css_text = (try parser.collectInlineStyleText(self.allocator, node)) orelse continue;
                var text_owned = true;
                errdefer if (text_owned) self.allocator.free(css_text);
                try self.appendRules(css_text, true, .{
                    .base_url = document_base,
                    .media = if (element.attributes) |attrs| attrs.get("media") else null,
                });
                text_owned = false;
                continue;
            }

            if (!std.mem.eql(u8, element.tag, "link")) continue;
            const base_url = page_url orelse continue;
            const attrs = element.attributes orelse continue;
            const href = attrs.get("href") orelse continue;
            if (!element.attributeHasToken("rel", "stylesheet")) continue;

            const stylesheet_url = base_url.resolve(self.allocator, href) catch |err| {
                std.log.warn("Ignoring stylesheet {s}: {}", .{ href, err });
                continue;
            };
            defer stylesheet_url.free(self.allocator);
            const fetched = fetchDecodedSheet(init, self.allocator, stylesheet_url, &http_client, &cookie_jar) catch |err| {
                std.log.warn("Ignoring stylesheet {s}: {}", .{ href, err });
                continue;
            };
            defer self.allocator.free(fetched.source_url);
            var text_owned = true;
            errdefer if (text_owned) self.allocator.free(fetched.text);
            try self.appendRules(fetched.text, true, .{
                .base_url = fetched.source_url,
                .referrer_policy = fetched.referrer_policy,
                .media = attrs.get("media"),
            });
            text_owned = false;
        }
    }
};

const FetchedSheet = struct {
    text: []u8,
    source_url: []u8,
    referrer_policy: url_module.ReferrerPolicy,
};

// Owns both returned strings. Sheet construction clones the source URL and
// consumes text only after all fallible publication work has succeeded.
fn fetchDecodedSheet(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: Url,
    client: *std.http.Client,
    cookie_jar: *std.StringHashMap(url_module.CookieEntry),
) !FetchedSheet {
    var final_url: ?Url = null;
    defer if (final_url) |resolved| resolved.free(allocator);
    const response = try Url.fetchBodyWithFinalUrl(allocator, init.io, client, cookie_jar, null, url, null, null, &final_url);
    defer if (response.csp_header) |header| allocator.free(header);
    defer if (!std.mem.eql(u8, url.scheme, "data") and !std.mem.eql(u8, url.scheme, "about")) allocator.free(response.body);
    const source_url = if (final_url) |resolved| try resolved.toOwnedString(allocator) else try url.toOwnedString(allocator);
    errdefer allocator.free(source_url);
    return .{
        .text = try url_module.decodeUtf8Replace(allocator, response.body),
        .source_url = source_url,
        .referrer_policy = response.referrer_policy,
    };
}

fn deinitCookieJar(allocator: std.mem.Allocator, cookie_jar: *std.StringHashMap(url_module.CookieEntry)) void {
    var it = cookie_jar.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.value);
        allocator.free(entry.key_ptr.*);
    }
    cookie_jar.deinit();
}

fn fetchDecoded(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: Url,
    client: ?*std.http.Client,
    cookie_jar: ?*std.StringHashMap(url_module.CookieEntry),
) ![]u8 {
    var local_client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    var local_jar = std.StringHashMap(url_module.CookieEntry).init(allocator);
    const actual_client = client orelse &local_client;
    const actual_jar = cookie_jar orelse &local_jar;
    defer if (client == null) local_client.deinit();
    defer if (cookie_jar == null) deinitCookieJar(allocator, &local_jar);

    const response = try Url.fetchBody(allocator, init.io, actual_client, actual_jar, null, url, null, null);
    defer if (response.csp_header) |header| allocator.free(header);
    defer if (!std.mem.eql(u8, url.scheme, "data") and !std.mem.eql(u8, url.scheme, "about")) allocator.free(response.body);
    return url_module.decodeUtf8Replace(allocator, response.body);
}
