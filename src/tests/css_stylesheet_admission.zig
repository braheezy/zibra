//! Resource-error publication and malformed-input coverage for the complete
//! Terence-to-Zibra adapter, including selector and declaration translation.

const std = @import("std");
const stylesheet = @import("../document/css_stylesheet.zig");
const inspection = @import("../document/inspection.zig");
const dom = @import("../document/dom.zig");
const allocator = std.testing.allocator;

const at_member_limit = "p," ** 255 ++ "p { color:green; }";
const beyond_member_limit = "p," ** 256 ++ "p { color:red; }";

test "Terence stylesheet accepts 256 selector members and rejects 257 explicitly" {
    var sheet = try stylesheet.Sheet.parse(allocator, at_member_limit, .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 256), selected.rules.len);
    for (selected.rules) |rule| {
        try std.testing.expectEqualStrings("green", rule.properties.get("color").?.value);
    }

    // An already-translated preceding rule must be reclaimed when the later
    // selector list rejects the generation.
    try std.testing.expectError(error.SelectorLimitExceeded, stylesheet.Sheet.parse(
        allocator,
        "p { width:41px; }" ++ beyond_member_limit,
        .{},
    ));
    try std.testing.expectError(error.SelectorLimitExceeded, stylesheet.Sheet.parse(
        allocator,
        "@media (min-width:9999px) {" ++ beyond_member_limit ++ "}",
        .{},
    ));
}

test "Terence stylesheet still discards complete invalid selector lists" {
    for ([_][]const u8{ "p, :unsupported", "p,", ":", "p:has(.x,.y)" }) |invalid| {
        const source = try std.fmt.allocPrint(allocator, "{s} {{ color:red; }} p {{ color:green; }}", .{invalid});
        defer allocator.free(source);
        var sheet = try stylesheet.Sheet.parse(allocator, source, .{});
        defer sheet.deinit();
        var selected = try sheet.select(allocator, .{});
        defer selected.deinit();
        try std.testing.expectEqual(@as(usize, 1), selected.rules.len);
        try std.testing.expectEqualStrings("green", selected.rules[0].properties.get("color").?.value);
    }
}

fn findById(node: *dom.Node, id: []const u8) ?*dom.Node {
    if (node.* != .element) return null;
    if (node.element.attributes) |attributes| {
        if (attributes.get("id")) |actual| {
            if (std.mem.eql(u8, id, actual)) return node;
        }
    }
    for (node.element.children.items) |*child| {
        if (findById(child, id)) |found| return found;
    }
    return null;
}

test "Terence selector admission failure preserves the installed styled generation" {
    var page = try inspection.Page.fromHtml(
        allocator,
        "<style>#target { width:41px; color:green; }" ++
            "@keyframes pulse { from { opacity:0.2; } to { opacity:0.8; } }</style>" ++
            "<main id=target><span id=child>inherited</span></main>",
        .{ .css_backend = .terence },
    );
    defer page.deinit();
    page.repairParentPointers();
    const target = findById(&page.root, "target").?;
    const child = findById(&page.root, "child").?;
    const source = page.sheetSource(1);
    const rules = page.rules.items;
    const keyframes = page.keyframes.items;
    const media = page.media;

    try std.testing.expectError(error.SelectorLimitExceeded, page.replaceStylesheet(
        1,
        "#target { width:73px; color:purple; }" ++ beyond_member_limit,
    ));
    try std.testing.expectEqual(source.ptr, page.sheetSource(1).ptr);
    try std.testing.expectEqualStrings(source, page.sheetSource(1));
    try std.testing.expectEqual(rules.ptr, page.rules.items.ptr);
    try std.testing.expectEqual(rules.len, page.rules.items.len);
    try std.testing.expectEqual(keyframes.ptr, page.keyframes.items.ptr);
    try std.testing.expectEqual(keyframes.len, page.keyframes.items.len);
    try std.testing.expectEqualDeep(media, page.media);
    try std.testing.expectEqualStrings("41px", target.element.style.?.getPtr("width").?.get().*);
    try std.testing.expectEqualStrings("green", child.element.style.?.getPtr("color").?.get().*);
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&page.root));
}

fn checkAdapterInput(input: []const u8) !void {
    var raw_sheet = try stylesheet.Sheet.parse(allocator, input, .{});
    defer raw_sheet.deinit();
    var raw_selection = try raw_sheet.select(allocator, .{});
    defer raw_selection.deinit();

    // Valid prefixes ensure the corpus reaches normalization, selector clones,
    // media evaluation, and keyframe maps even when random input is discarded.
    const sheet_source = try std.mem.concat(allocator, u8, &.{
        "p, section:has(span), p:not(.hidden) { color:g\\72 een; width:17p\\78; }" ++
            "@media (min-width:600px) { .target { width:31px; } }" ++
            "@keyframes pulse { from { opacity:0.2; } to { opacity:0.8; } }" ++
            ".probe { --value:",
        input,
        "; }",
    });
    defer allocator.free(sheet_source);
    var sheet = try stylesheet.Sheet.parse(allocator, sheet_source, .{});
    defer sheet.deinit();
    const retained_source = sheet.source();
    for ([_]f64{ 400, 800 }) |width| {
        var selected = try sheet.select(allocator, .{ .viewport_width_css = width });
        defer selected.deinit();
        try std.testing.expect(selected.rules.len >= if (width < 600) @as(usize, 3) else 4);
        try std.testing.expectEqualStrings("green", selected.rules[0].properties.get("color").?.value);
        try std.testing.expectEqualStrings("17px", selected.rules[0].properties.get("width").?.value);
        try std.testing.expectEqualStrings("pulse", selected.keyframes[0].name);
        try std.testing.expectEqual(@as(usize, 2), selected.keyframes[0].frames.len);
        try std.testing.expectEqual(retained_source.ptr, sheet.source().ptr);
    }

    const inline_source = try std.mem.concat(allocator, u8, &.{ "color:g\\72 een!important; width:17p\\78!important; --value:", input });
    defer allocator.free(inline_source);
    var block = try stylesheet.DeclarationBlock.parse(allocator, inline_source, .{});
    defer block.deinit();
    try std.testing.expectEqualStrings("green", block.properties.get("color").?.value);
    try std.testing.expectEqualStrings("17px", block.properties.get("width").?.value);
}

test "Terence full adapter malformed corpus exercises retained semantic owners" {
    for ([_][]const u8{
        "",
        "url(foo\\",
        "\"bad\n; color:red;",
        "url(bad\"url); color:blue;",
        "calc(1px + 2px",
        "10/**/px; @unknown { nested:fn([a;b]); }",
        "\\0 \\d800 \\110000 \\31 0px",
        "p:not(.a) > span:has(em) { color:red; }",
        "@media (width>1px) { p { --x:var(--y, [a;b]); }",
        "--text:\"r\\65 d; !important\"; --space:\\ ;",
    }) |input| try checkAdapterInput(input);

    var random = std.Random.DefaultPrng.init(0xc55ad);
    const alphabet = "ap0:;{}[]()\\\"'/* !@#.,>-\n\r\x00\xff";
    var bytes: [96]u8 = undefined;
    for (0..200) |case| {
        const input = bytes[0 .. case % bytes.len];
        for (input) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        try checkAdapterInput(input);
    }
}
