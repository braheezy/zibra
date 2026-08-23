//! Document pipeline used by Zibra's non-interactive inspection commands.
//!
//! It deliberately stops after parsing and styling. Layout and paint callers
//! can build on its DOM, but it never starts Browser, JavaScript, or SDL.

const std = @import("std");
const parser = @import("parser.zig");
const CSSParser = @import("css_parser.zig").CSSParser;
const url_module = @import("../network/url.zig");
const Url = url_module.Url;

const default_html = @embedFile("../assets/default.html");
const default_style_sheet = @embedFile("../browser/browser.css");

pub const Page = struct {
    allocator: std.mem.Allocator,
    body: []u8,
    root: parser.Node,
    rules: std.ArrayList(CSSParser.CSSRule),
    keyframes: std.ArrayList(CSSParser.KeyframesRule),
    css_texts: std.ArrayList([]u8),

    pub fn load(init: std.process.Init, allocator: std.mem.Allocator, source_url: ?Url) !Page {
        const body = if (source_url) |url|
            try fetchDecoded(init, allocator, url, null, null)
        else
            try allocator.dupe(u8, default_html);
        errdefer allocator.free(body);

        var html_parser = try parser.HTMLParser.init(allocator, body);
        defer html_parser.deinit(allocator);
        var root = try html_parser.parse();
        errdefer root.deinit(allocator);

        var page = Page{
            .allocator = allocator,
            .body = body,
            .root = root,
            .rules = std.ArrayList(CSSParser.CSSRule).empty,
            .keyframes = std.ArrayList(CSSParser.KeyframesRule).empty,
            .css_texts = std.ArrayList([]u8).empty,
        };
        errdefer page.deinit();
        // `root` moved into `page.root`; selectors may walk ancestors while
        // Page.load styles below, so repair once at this intermediate stable
        // address. The caller repairs again after the by-value return.
        page.repairParentPointers();

        try page.appendRules(default_style_sheet, false);
        try page.loadDocumentStylesheets(init, source_url);

        std.mem.sort(CSSParser.CSSRule, page.rules.items, {}, struct {
            fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                return a.cascadePriority() < b.cascadePriority();
            }
        }.lessThan);
        try parser.styleWithKeyframes(
            allocator,
            &page.root,
            page.rules.items,
            page.keyframes.items,
        );
        return page;
    }

    pub fn deinit(self: *Page) void {
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        for (self.keyframes.items) |*rule| rule.deinit(self.allocator);
        self.keyframes.deinit(self.allocator);
        for (self.css_texts.items) |text| self.allocator.free(text);
        self.css_texts.deinit(self.allocator);
        self.root.deinit(self.allocator);
        self.allocator.free(self.body);
    }

    /// `Page` is returned by value, so parser-installed pointers to the root
    /// must be repaired once the caller has placed the page at its final
    /// address and before any ancestry walk.
    pub fn repairParentPointers(self: *Page) void {
        parser.fixParentPointers(&self.root, null);
    }

    fn appendRules(self: *Page, stylesheet: []const u8, keep_text: bool) !void {
        var css_parser = try CSSParser.init(self.allocator, stylesheet, false);
        defer css_parser.deinit(self.allocator);
        var keyframes = std.ArrayList(CSSParser.KeyframesRule).empty;
        var keyframes_owned = true;
        defer {
            if (keyframes_owned) {
                for (keyframes.items) |*rule| rule.deinit(self.allocator);
            }
            keyframes.deinit(self.allocator);
        }
        const rules = try css_parser.parseWithKeyframes(self.allocator, &keyframes);
        var rules_owned = true;
        defer if (rules_owned) {
            for (rules) |*rule| rule.deinit(self.allocator);
            self.allocator.free(rules);
        };

        // Reserve both destinations before transferring either the rules or
        // their backing text. After these calls there are no fallible steps in
        // the ownership transfer.
        if (keep_text) try self.css_texts.ensureUnusedCapacity(self.allocator, 1);
        try self.rules.ensureUnusedCapacity(self.allocator, rules.len);
        try self.keyframes.ensureUnusedCapacity(self.allocator, keyframes.items.len);
        if (keep_text) {
            // `stylesheet` is an owned allocation supplied by the caller.
            self.css_texts.appendAssumeCapacity(@constCast(stylesheet));
        }
        for (rules) |rule| self.rules.appendAssumeCapacity(rule);
        for (keyframes.items) |rule| self.keyframes.appendAssumeCapacity(rule);
        rules_owned = false;
        keyframes_owned = false;
        self.allocator.free(rules);
    }

    fn loadDocumentStylesheets(self: *Page, init: std.process.Init, page_url: ?Url) !void {
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
                try self.appendRules(css_text, true);
                text_owned = false;
                continue;
            }

            if (!std.mem.eql(u8, element.tag, "link")) continue;
            const base_url = page_url orelse continue;
            const attrs = element.attributes orelse continue;
            const rel = attrs.get("rel") orelse continue;
            const href = attrs.get("href") orelse continue;
            if (!std.mem.eql(u8, rel, "stylesheet")) continue;

            const stylesheet_url = base_url.resolve(self.allocator, href) catch |err| {
                std.log.warn("Ignoring stylesheet {s}: {}", .{ href, err });
                continue;
            };
            defer stylesheet_url.free(self.allocator);
            const css_text = fetchDecoded(init, self.allocator, stylesheet_url, &http_client, &cookie_jar) catch |err| {
                std.log.warn("Ignoring stylesheet {s}: {}", .{ href, err });
                continue;
            };
            var text_owned = true;
            errdefer if (text_owned) self.allocator.free(css_text);
            try self.appendRules(css_text, true);
            text_owned = false;
        }
    }
};

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
