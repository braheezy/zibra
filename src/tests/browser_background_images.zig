//! Computed-style discovery and CSS background resource loading tests.

const std = @import("std");
const background_images = @import("../browser/background_images.zig");
const CSSParser = @import("../document/css_parser.zig").CSSParser;
const document = @import("../document/parser.zig");
const Url = @import("../network/url.zig").Url;
const url_module = @import("../network/url.zig");

const ppm_image =
    "P3\n" ++
    "2 1\n" ++
    "255\n" ++
    "255 0 0  0 255 0\n";

fn findById(node: *document.Node, id: []const u8) ?*document.Element {
    return switch (node.*) {
        .text => null,
        .element => |*element| blk: {
            if (element.attributes) |attributes| {
                if (attributes.get("id")) |candidate| {
                    if (std.mem.eql(u8, candidate, id)) break :blk element;
                }
            }
            for (element.children.items) |*child| {
                if (findById(child, id)) |found| break :blk found;
            }
            break :blk null;
        },
    };
}

const TestLoadContext = struct {
    allocator: std.mem.Allocator,
    fetch_count: usize = 0,
    allowed_count: usize = 0,
    retire_count: usize = 0,
    allow: bool = true,
    expected_source: ?[]const u8 = null,
    expected_target: ?[]const u8 = null,
    expected_policy: ?url_module.ReferrerPolicy = null,
};

const TestLoadCallbacks = struct {
    pub fn allowed(context: *TestLoadContext, _: Url, _: *const Url) bool {
        context.allowed_count += 1;
        return context.allow;
    }

    pub fn fetch(
        context: *TestLoadContext,
        target: Url,
        source: Url,
        policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        context.fetch_count += 1;
        if (context.expected_source) |expected| try std.testing.expectEqualStrings(expected, source.ada_url.getHref());
        if (context.expected_target) |expected| try std.testing.expectEqualStrings(expected, target.ada_url.getHref());
        if (context.expected_policy) |expected| try std.testing.expectEqual(expected, policy);
        if (std.mem.eql(u8, target.scheme, "data")) return .{ .body = target.path };
        return .{ .body = try context.allocator.dupe(u8, ppm_image) };
    }

    pub fn retire(context: *TestLoadContext) void {
        context.retire_count += 1;
    }
};

fn parseRules(allocator: std.mem.Allocator, css: []const u8) ![]CSSParser.CSSRule {
    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    return css_parser.parse(allocator);
}

test "Referrer background provenance follows cascade and outlives the stylesheet generation" {
    const a = std.testing.allocator;
    var html = try document.HTMLParser.init(a, "<body><div id=target></div></body>");
    defer html.deinit(a);
    var root = try html.parse();
    defer root.deinit(a);
    document.fixParentPointers(&root, null);
    const rules = try parseRules(a, "#target {background-image:url(pixel.ppm);width:20px;height:20px}");
    rules[0].source_url = try a.dupe(u8, "https://cdn.example/assets/site.css");
    rules[0].referrer_policy = .origin;
    document.style(a, &root, rules) catch |err| {
        freeRules(a, rules);
        return err;
    };
    freeRules(a, rules);
    const target = findById(&root, "target").?;
    try std.testing.expectEqualStrings("https://cdn.example/assets/site.css", target.background_source_url.?);
    const page = try Url.init(a, "https://page.example/index.html");
    defer page.free(a);
    var context = TestLoadContext{
        .allocator = a,
        .expected_source = "https://cdn.example/assets/site.css",
        .expected_target = "https://cdn.example/assets/pixel.ppm",
        .expected_policy = .origin,
    };
    try background_images.loadUsed(a, std.testing.io, &root, &page, .no_referrer, true, &context, TestLoadCallbacks);
    try std.testing.expectEqual(@as(usize, 1), context.fetch_count);
}

test "background URL tokens decode CSS escapes before resource resolution" {
    const a = std.testing.allocator;
    const html = try document.HTMLParser.init(a, "<div id=target></div>");
    defer html.deinit(a);
    var root = try html.parse();
    defer root.deinit(a);
    document.fixParentPointers(&root, null);
    const rules = try parseRules(a, "#target {background-image:u\\72 l('pixel\\22 .ppm'); width:20px; height:20px}");
    defer freeRules(a, rules);
    try document.style(a, &root, rules);
    const page = try Url.init(a, "https://example.test/index.html");
    defer page.free(a);
    var context = TestLoadContext{ .allocator = a, .expected_target = "https://example.test/pixel%22.ppm" };
    try background_images.loadUsed(a, std.testing.io, &root, &page, .default, true, &context, TestLoadCallbacks);
    try std.testing.expectEqual(@as(usize, 1), context.fetch_count);
    try background_images.loadUsed(a, std.testing.io, &root, &page, .default, true, &context, TestLoadCallbacks);
    try std.testing.expectEqual(@as(usize, 1), context.fetch_count);
}

test "SVG data URL backgrounds own cached pixels and retire before source replacement" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(allocator, "<main><div id=first></div><div id=second></div></main>");
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    const rules = try parseRules(allocator, "div { background-image: url(\"data:image/svg+xml,%3Csvg%20width='4'%20height='4'%3E%3Crect%20width='4'%20height='4'%20fill='blue'/%3E%3C/svg%3E\"); }");
    defer freeRules(allocator, rules);
    try document.style(allocator, &root, rules);
    var page_url = try Url.init(allocator, "https://example.test/page.html");
    defer page_url.free(allocator);
    var context = TestLoadContext{ .allocator = allocator };
    try background_images.loadUsed(allocator, std.testing.io, &root, &page_url, .default, true, &context, TestLoadCallbacks);
    try std.testing.expectEqual(@as(usize, 1), context.fetch_count);
    try std.testing.expectEqual(@as(usize, 1), context.retire_count);
    const first = findById(&root, "first").?;
    const second = findById(&root, "second").?;
    const first_pixels = first.background_image.?.data.?.image.rawBytes();
    const second_pixels = second.background_image.?.data.?.image.rawBytes();
    try std.testing.expect(first_pixels.ptr != second_pixels.ptr);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, first_pixels[0..4]);
    try std.testing.expectEqualSlices(u8, first_pixels, second_pixels);
    try background_images.loadUsed(allocator, std.testing.io, &root, &page_url, .default, true, &context, TestLoadCallbacks);
    try std.testing.expectEqual(@as(usize, 1), context.fetch_count);
    try background_images.loadUsed(allocator, std.testing.io, &root, &page_url, .default, false, &context, TestLoadCallbacks);
    try std.testing.expectEqual(@as(usize, 2), context.retire_count);
    try std.testing.expect(first.background_image == null);
    try std.testing.expect(second.background_image == null);
}

test "disabled and blocked background images perform no unnecessary fetch" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(allocator, "<div class=used>blocked</div>");
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    const rules = try parseRules(allocator, ".used { background-image: url(blocked.ppm); }");
    defer freeRules(allocator, rules);
    try document.style(allocator, &root, rules);

    var page_url = try Url.init(allocator, "https://example.test/page.html");
    defer page_url.free(allocator);
    var context = TestLoadContext{ .allocator = allocator };
    try background_images.loadUsed(
        allocator,
        std.testing.io,
        &root,
        &page_url,
        .no_referrer,
        false,
        &context,
        TestLoadCallbacks,
    );
    try std.testing.expect(root.element.background_image == null);
    try std.testing.expectEqual(@as(usize, 0), context.allowed_count);
    try std.testing.expectEqual(@as(usize, 0), context.fetch_count);

    context.allow = false;
    try background_images.loadUsed(
        allocator,
        std.testing.io,
        &root,
        &page_url,
        .no_referrer,
        true,
        &context,
        TestLoadCallbacks,
    );
    try std.testing.expectEqualStrings("blocked.ppm", root.element.background_image.?.source);
    try std.testing.expect(root.element.background_image.?.data == null);
    try std.testing.expectEqual(@as(usize, 1), context.allowed_count);
    try std.testing.expectEqual(@as(usize, 0), context.fetch_count);

    try background_images.loadUsed(
        allocator,
        std.testing.io,
        &root,
        &page_url,
        .no_referrer,
        true,
        &context,
        TestLoadCallbacks,
    );
    try std.testing.expectEqual(@as(usize, 1), context.allowed_count);
    try std.testing.expectEqual(@as(usize, 1), context.retire_count);
}

fn freeRules(allocator: std.mem.Allocator, rules: []CSSParser.CSSRule) void {
    for (rules) |*rule| rule.deinit(allocator);
    allocator.free(rules);
}

test "background images load only after final computed style selects them" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<div class=used id=first>first</div>" ++
        "<button class=used id=second>second</button>" ++
        "<div id=overridden>none</div>" ++
        "<div class=not-displayed id=hidden-box>hidden</div>" ++
        "<input type=hidden class=used id=hidden-input>" ++
        "<div class=data-background id=data-image>data</div>" ++
        "</main>";
    const css =
        ".never-matches { background-image: url(never.ppm); }" ++
        ".used { background-image: url(shared.ppm); background-size: 40px 20px; }" ++
        ".not-displayed { display: none; background-image: url(hidden.ppm); }" ++
        ".data-background { background-image: " ++
        "url(data:image/x-portable-pixmap,P3%0A1%201%0A255%0A0%200%20255%0A); }" ++
        "#overridden { background-image: url(loser.ppm); background-image: none; }";

    var html_parser = try document.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);

    const rules = try parseRules(allocator, css);
    defer freeRules(allocator, rules);
    try document.style(allocator, &root, rules);

    var used = std.ArrayList(background_images.UsedImage).empty;
    defer used.deinit(allocator);
    try background_images.collectUsed(allocator, &root, &used);
    try std.testing.expectEqual(@as(usize, 3), used.items.len);
    try std.testing.expectEqualStrings("shared.ppm", used.items[0].source);
    try std.testing.expectEqualStrings("shared.ppm", used.items[1].source);
    try std.testing.expectEqualStrings(
        "40px 20px",
        findById(&root, "first").?.style.?.getPtr("background-size").?.get().*,
    );

    var page_url = try Url.init(allocator, "https://example.test/docs/page.html");
    defer page_url.free(allocator);
    var context = TestLoadContext{ .allocator = allocator };
    try background_images.loadUsed(
        allocator,
        std.testing.io,
        &root,
        &page_url,
        .default,
        true,
        &context,
        TestLoadCallbacks,
    );

    try std.testing.expectEqual(@as(usize, 2), context.fetch_count);
    try std.testing.expectEqual(@as(usize, 3), context.allowed_count);
    try std.testing.expectEqual(@as(usize, 1), context.retire_count);
    try std.testing.expect(findById(&root, "first").?.background_image.?.data != null);
    try std.testing.expect(findById(&root, "second").?.background_image.?.data != null);
    try std.testing.expect(findById(&root, "overridden").?.background_image == null);
    try std.testing.expect(findById(&root, "hidden-box").?.background_image == null);
    try std.testing.expect(findById(&root, "hidden-input").?.background_image == null);
    try std.testing.expect(findById(&root, "data-image").?.background_image.?.data != null);

    // An unchanged computed URL reuses the installed element resources and
    // causes neither another fetch nor another display-list retirement.
    try background_images.loadUsed(
        allocator,
        std.testing.io,
        &root,
        &page_url,
        .default,
        true,
        &context,
        TestLoadCallbacks,
    );
    try std.testing.expectEqual(@as(usize, 2), context.fetch_count);
    try std.testing.expectEqual(@as(usize, 1), context.retire_count);

    const clear_rules = try parseRules(allocator, ".used { background-image: none; }");
    defer freeRules(allocator, clear_rules);
    document.dirtyStyleSubtree(&root);
    try document.style(allocator, &root, clear_rules);
    try background_images.loadUsed(
        allocator,
        std.testing.io,
        &root,
        &page_url,
        .default,
        true,
        &context,
        TestLoadCallbacks,
    );
    try std.testing.expect(findById(&root, "first").?.background_image == null);
    try std.testing.expect(findById(&root, "second").?.background_image == null);
    try std.testing.expect(findById(&root, "data-image").?.background_image == null);
    try std.testing.expectEqual(@as(usize, 2), context.fetch_count);
    try std.testing.expectEqual(@as(usize, 2), context.retire_count);
}
