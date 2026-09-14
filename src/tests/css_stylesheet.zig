//! Malformed-input coverage for the
//! native stylesheet owner, including selector and declaration parsing.

const std = @import("std");
const parser = @import("../document/css_parser.zig");
const stylesheet = @import("../document/css_stylesheet.zig");
const allocator = std.testing.allocator;

test "Native stylesheet still discards complete invalid selector lists" {
    for ([_][]const u8{ "p, :unsupported", "p,", ":", "p:has(.x,.y)" }) |invalid| {
        const source = try std.fmt.allocPrint(allocator, "{s} {{ color:red; }} p {{ color:green; }}", .{invalid});
        defer allocator.free(source);
        var sheet = try stylesheet.Sheet.init(allocator, source, .{});
        defer sheet.deinit();
        var selected = try sheet.select(allocator, .{});
        defer selected.deinit();
        try std.testing.expectEqual(@as(usize, 1), selected.rules.len);
        try std.testing.expectEqualStrings("green", selected.rules[0].properties.get("color").?.value);
    }
}

fn checkStylesheetInput(input: []const u8) !void {
    var raw_sheet = try stylesheet.Sheet.init(allocator, input, .{});
    defer raw_sheet.deinit();
    var raw_selection = try raw_sheet.select(allocator, .{});
    defer raw_selection.deinit();

    // Valid prefixes ensure the corpus reaches native selectors,
    // media evaluation, and keyframe maps even when random input is discarded.
    const sheet_source = try std.mem.concat(allocator, u8, &.{
        "p, section:has(span), p:not(.hidden) { color:green; width:17px; }" ++
            "@media (min-width:600px) { .target { width:31px; } }" ++
            "@keyframes pulse { from { opacity:0.2; } to { opacity:0.8; } }" ++
            ".probe { --value:",
        input,
        "; }",
    });
    defer allocator.free(sheet_source);
    var sheet = try stylesheet.Sheet.init(allocator, sheet_source, .{});
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

    const inline_source = try std.mem.concat(allocator, u8, &.{ "color:green!important; width:17px!important; --value:", input });
    defer allocator.free(inline_source);
    const css = try parser.init(allocator, inline_source, false);
    defer css.deinit(allocator);
    var block = try css.body(allocator);
    defer block.deinit();
    try std.testing.expectEqualStrings("green", block.get("color").?.value);
    try std.testing.expectEqualStrings("17px", block.get("width").?.value);
}

test "Native stylesheet malformed corpus exercises retained semantic owners" {
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
    }) |input| try checkStylesheetInput(input);

    var random = std.Random.DefaultPrng.init(0xc55ad);
    const alphabet = "ap0:;{}[]()\\\"'/* !@#.,>-\n\r\x00\xff";
    var bytes: [96]u8 = undefined;
    for (0..200) |case| {
        const input = bytes[0 .. case % bytes.len];
        for (input) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        try checkStylesheetInput(input);
    }
}

test "retained CSS source provenance moves independently of caller storage" {
    const input = try allocator.dupe(u8, "p{background-image:url(paint.png)}");
    const url = try allocator.dupe(u8, "https://example.test/assets/main.css");
    var original = stylesheet.Sheet.init(allocator, input, .{ .base_url = url, .origin = .user_agent, .referrer_policy = .no_referrer }) catch |err| {
        allocator.free(input);
        allocator.free(url);
        return err;
    };
    @memset(input, 'x');
    @memset(url, 'x');
    allocator.free(input);
    allocator.free(url);
    var sheet = original;
    original = undefined;
    defer sheet.deinit();
    var first = try sheet.select(allocator, .{});
    defer first.deinit();
    var second = try sheet.select(allocator, .{});
    defer second.deinit();
    try std.testing.expectEqualStrings("p{background-image:url(paint.png)}", sheet.source());
    try std.testing.expectEqualStrings("https://example.test/assets/main.css", sheet.options().base_url.?);
    try std.testing.expectEqualStrings(sheet.options().base_url.?, first.rules[0].source_url.?);
    try std.testing.expect(first.rules[0].source_url.?.ptr != second.rules[0].source_url.?.ptr);
    try std.testing.expectEqual(.user_agent, first.rules[0].origin);
    try std.testing.expectEqual(.no_referrer, first.rules[0].referrer_policy);
}

fn allocationTrial(trial_allocator: std.mem.Allocator) !void {
    var sheet = try stylesheet.Sheet.init(
        trial_allocator,
        "p, #x{color:green!important; margin:1px 2px; --tone:red}" ++
            "@media(min-width:10px){p{color:var(--tone)}@keyframes pulse{from,to{opacity:0.5}}}",
        .{ .base_url = "https://example.test/style.css", .media = "screen" },
    );
    defer sheet.deinit();
    var selection = try sheet.select(trial_allocator, .{ .viewport_width_css = 20 });
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 3), selection.rules.len);
    try std.testing.expectEqual(@as(usize, 1), selection.keyframes.len);
}

test "Native stylesheet allocation failures release source provenance and selections" {
    try std.testing.checkAllAllocationFailures(allocator, allocationTrial, .{});
}

test "Native structural recovery closes media keyframes and rules at EOF" {
    const source = "@media screen { p { color:green; @future { ignored: [a;{b:c;}]; } width:120px; }" ++
        "@keyframes pulse { from { opacity:0.2 } to { opacity:0.8";
    var sheet = try stylesheet.Sheet.init(allocator, source, .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.rules.len);
    try std.testing.expectEqualStrings("120px", selected.rules[0].properties.get("width").?.value);
    try std.testing.expectEqualStrings("green", selected.rules[0].properties.get("color").?.value);
    try std.testing.expectEqual(@as(usize, 1), selected.keyframes.len);
    try std.testing.expectEqual(@as(usize, 2), selected.keyframes[0].frames.len);
    try std.testing.expectEqualStrings("0.8", selected.keyframes[0].frames[1].properties.get("opacity").?.value);
}

test "Native structural recovery keeps following rules outside invalid selectors" {
    const source = "p:unsupported { @future { nested:ignored; } color:red; }" ++
        "@unknown [a;{b:c}] (x;{y:z}) { p {color:red;} } p {color:green}";
    var sheet = try stylesheet.Sheet.init(allocator, source, .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.rules.len);
    try std.testing.expectEqualStrings("green", selected.rules[0].properties.get("color").?.value);
}

test "Native stylesheet applies selector admission before publishing a list" {
    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    for (0..257) |index| try source.appendSlice(allocator, if (index == 0) "p" else ",p");
    try source.appendSlice(allocator, "{color:red} p{color:green}");
    var sheet = try stylesheet.Sheet.init(allocator, source.items, .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.rules.len);
    try std.testing.expectEqualStrings("green", selected.rules[0].properties.get("color").?.value);
}

test "selector escape decoding consumes CRLF as one CSS whitespace" {
    const decoded = try parser.decodeIdentifier(allocator, "a\\62\r\nc");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("abc", decoded);
}

test "retained stylesheet selects nested conditions and keyframes without recompiling" {
    var sheet = try stylesheet.Sheet.init(allocator, "p{color:red}" ++
        "@media(min-width:600px){@supports(color:green){p{color:green}" ++
        "@media(prefers-color-scheme:dark){p{color:blue}" ++
        "@keyframes pulse{from{opacity:0.2}to{opacity:0.8}}}}}" ++
        "@supports(color:unsupported){p{color:black}}" ++
        "@media(max-width:500px){p{color:purple}}p{width:10px}", .{});
    defer sheet.deinit();
    const compiled_rules = sheet.rules.ptr;
    try std.testing.expectEqual(@as(usize, 5), sheet.rules.len);
    try std.testing.expectEqual(@as(usize, 3), sheet.conditions.len);
    try std.testing.expectEqual(@as(?usize, 0), sheet.conditions[1].parent);
    const Case = struct { width: f64, dark: bool, color: []const u8, count: usize, keyframes: usize };
    for ([_]Case{
        .{ .width = 400, .dark = true, .color = "purple", .count = 3, .keyframes = 0 },
        .{ .width = 800, .dark = false, .color = "green", .count = 3, .keyframes = 0 },
        .{ .width = 800, .dark = true, .color = "blue", .count = 4, .keyframes = 1 },
        .{ .width = 400, .dark = false, .color = "purple", .count = 3, .keyframes = 0 },
    }) |case| {
        var selected = try sheet.select(allocator, .{ .viewport_width_css = case.width, .prefers_dark = case.dark });
        defer selected.deinit();
        try std.testing.expectEqual(case.count, selected.rules.len);
        try std.testing.expectEqual(case.keyframes, selected.keyframes.len);
        try std.testing.expectEqualStrings(case.color, selected.rules[case.count - 2].properties.get("color").?.value);
        try std.testing.expectEqual(compiled_rules, sheet.rules.ptr);
        for (selected.rules) |rule| try std.testing.expect(rule.media_condition == null);
        // Selected declarations are independent of both the program and later selections.
        try selected.rules[0].properties.put("color", .{ .value = "orange" });
        try std.testing.expectEqualStrings("red", sheet.rules[0].properties.get("color").?.value);
    }
}

test "stylesheet media attributes gate complete programs including keyframes" {
    var sheet = try stylesheet.Sheet.init(allocator, "p{color:green}@keyframes pulse{from{opacity:0}to{opacity:1}}", .{ .media = "print" });
    defer sheet.deinit();
    var hidden = try sheet.select(allocator, .{});
    defer hidden.deinit();
    try std.testing.expectEqual(@as(usize, 0), hidden.rules.len);
    try std.testing.expectEqual(@as(usize, 0), hidden.keyframes.len);
    for ([_]?[]const u8{ null, "", " \t/**/ ", "all", "print, screen", "(min-width:600px)" }) |query| {
        var selected = try sheet.selectWithMedia(allocator, .{ .viewport_width_css = 800 }, query);
        defer selected.deinit();
        try std.testing.expectEqual(@as(usize, 1), selected.rules.len);
        try std.testing.expectEqual(@as(usize, 1), selected.keyframes.len);
    }
    for ([_][]const u8{ "none", "aural", "not all", "(min-width:900px)", ",", "screen and" }) |query| {
        var selected = try sheet.selectWithMedia(allocator, .{ .viewport_width_css = 800 }, query);
        defer selected.deinit();
        try std.testing.expectEqual(@as(usize, 0), selected.rules.len);
        try std.testing.expectEqual(@as(usize, 0), selected.keyframes.len);
    }
    try std.testing.expectEqualStrings("print", sheet.options().media.?);
}

fn selectionAllocationTrial(trial_allocator: std.mem.Allocator, sheet: *const stylesheet.Sheet) !void {
    var selected = try sheet.select(trial_allocator, .{});
    defer selected.deinit();
    var rules: std.ArrayList(parser.CSSRule) = .empty;
    defer {
        for (rules.items) |*rule| rule.deinit(trial_allocator);
        rules.deinit(trial_allocator);
    }
    var keyframes: std.ArrayList(parser.KeyframesRule) = .empty;
    defer {
        for (keyframes.items) |*rule| rule.deinit(trial_allocator);
        keyframes.deinit(trial_allocator);
    }
    selected.appendTo(&rules, &keyframes) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), selected.rules.len);
        try std.testing.expectEqual(@as(usize, 1), selected.keyframes.len);
        try std.testing.expectEqual(@as(usize, 0), rules.items.len);
        try std.testing.expectEqual(@as(usize, 0), keyframes.items.len);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 0), selected.rules.len);
    try std.testing.expectEqualStrings("pulse", keyframes.items[0].name);
}

test "stylesheet selection uses its destination allocator and moves atomically" {
    var sheet = try stylesheet.Sheet.init(allocator, "p,div{color:green}@media screen{@keyframes pulse{from,to{opacity:0.5}}}", .{ .base_url = "https://example.test/assets/main.css", .media = "screen" });
    defer sheet.deinit();
    try std.testing.checkAllAllocationFailures(allocator, selectionAllocationTrial, .{&sheet});
}
