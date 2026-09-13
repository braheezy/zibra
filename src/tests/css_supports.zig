//! Feature-query admission and conditional rule/keyframe generation lifetimes.
const std = @import("std");
const css = @import("../document/css_parser.zig");
const supports = @import("../document/css_supports.zig");
const stylesheet = @import("../document/css_stylesheet.zig");
const allocator = std.testing.allocator;

test "supports selector queries use strict recursive admission without changing forgiving stylesheets" {
    const accepted = [_][]const u8{
        "div",                                  "div > .card + [data-mode='a,b']", "::before",           "a:hover",
        ":is(main > .card, #target):not(.off)", ":where(div, :is(.x, .y))",        ":nth-child(2n + 1)", ":has(.card)",
        ":has(:is(.x, .y))",                    ".sm\\:card",
    };
    for (accepted) |source| try std.testing.expect(try css.supportsSelector(allocator, source));
    const rejected = [_][]const u8{
        "div, div",             "> div",                   "div | .c",                "ns|div",       "[ns|href]",   "::-webkit-unknown",
        ":is()",                ":where()",                ":is(.a, :unknown)",       ":is(.a,)",     ":is({}, .a)", ":where(:is(.a, :unknown), .b)",
        ":not(:unknown)",       ":has(:is(.a, :unknown))", ":has(:is(.a, :has(.b)))", ":has(.a, .b)", ":has(> .a)",  ":is(::before, .a)",
        ":nth-child(2n of .a)", ":nth-child(2n 4)",        ":focus-within",
    };
    for (rejected) |source| try std.testing.expect(!try css.supportsSelector(allocator, source));
    const forgiving = try css.parseSelectorList(allocator, ":is(.a, :unknown)");
    defer {
        for (forgiving) |*selector| selector.deinit(allocator);
        allocator.free(forgiving);
    }
    try std.testing.expectEqual(@as(usize, 1), forgiving.len);
    try std.testing.expect(try supports.conditionText(allocator, "selector(:is(.a, .b", css.supportsSelector));
    try std.testing.expect(!try supports.conditionText(allocator, "selector(:is(.a, :unknown", css.supportsSelector));
    try std.testing.expect(!try supports.matches(allocator, "not selector(:is(" ++ ".x," ** 256 ++ ".x))", css.supportsSelector));
}

const nested_source =
    "p {width:10px}" ++
    "@supports (display:block) {" ++
    "p {width:20px} @keyframes pulse {from {opacity:0} to {opacity:1}}" ++
    "@media (min-width:600px) { @supports selector(:is(p, .x)) {p {width:30px}} }" ++
    "@supports (unknown:0) {p {width:999px} @keyframes hidden {from {opacity:0}}}" ++
    "@supports not (color:unknown) {p {color:green!important}}" ++
    "@future { p {width:999px} } p:unknown {color:red} p {height:20px}" ++
    "} p {width:40px}" ++
    "@supports (color:red) and (color:blue) or (color:green) {p {width:999px}}" ++
    "@supports (width:1px; color:red) {p {width:999px}}" ++
    "@\\73upports not future({[]}) {p {background:green}}";

test "supports conditional rules preserve media context authored order keyframes and provenance" {
    var sheet = try stylesheet.Sheet.init(allocator, nested_source, .{ .base_url = "https://example.test/main.css" });
    defer sheet.deinit();
    for ([_]f64{ 400, 800 }) |width| {
        var selected = try sheet.select(allocator, .{ .viewport_width_css = width });
        defer selected.deinit();
        const wide = width >= 600;
        try std.testing.expectEqual(@as(usize, if (wide) 7 else 6), selected.rules.len);
        try std.testing.expectEqualStrings("10px", selected.rules[0].properties.get("width").?.value);
        try std.testing.expectEqualStrings("20px", selected.rules[1].properties.get("width").?.value);
        if (wide) try std.testing.expectEqualStrings("30px", selected.rules[2].properties.get("width").?.value);
        try std.testing.expect(selected.rules[if (wide) 3 else 2].properties.get("color").?.important);
        try std.testing.expectEqualStrings("40px", selected.rules[selected.rules.len - 2].properties.get("width").?.value);
        try std.testing.expectEqualStrings("green", selected.rules[selected.rules.len - 1].properties.get("background-color").?.value);
        for (selected.rules) |rule| try std.testing.expectEqualStrings("https://example.test/main.css", rule.source_url.?);
        try std.testing.expectEqual(@as(usize, 1), selected.keyframes.len);
        try std.testing.expectEqualStrings("pulse", selected.keyframes[0].name);
    }
}

test "supports EOF recovery closes active group rules and discards invalid or unfinished preludes" {
    var sheet = try stylesheet.Sheet.init(allocator, "@supports (unknown:0) {p {color:red}} @supports (color:red) {" ++
        "@media screen {p {color:green} @keyframes pulse {from {opacity:0.5}", .{});
    defer sheet.deinit();
    var selected = try sheet.select(allocator, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.rules.len);
    try std.testing.expectEqualStrings("green", selected.rules[0].properties.get("color").?.value);
    try std.testing.expectEqual(@as(usize, 1), selected.keyframes.len);

    var partial = try stylesheet.Sheet.init(allocator, "p{color:green}@supports (color:red)", .{});
    defer partial.deinit();
    var prefix = try partial.select(allocator, .{});
    defer prefix.deinit();
    try std.testing.expectEqual(@as(usize, 1), prefix.rules.len);
}

fn allocationTrial(trial: std.mem.Allocator) !void {
    var sheet = try stylesheet.Sheet.init(trial, nested_source, .{ .base_url = "https://example.test/main.css" });
    defer sheet.deinit();
    var selected = try sheet.select(trial, .{ .viewport_width_css = 800 });
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 7), selected.rules.len);
    try std.testing.expectEqual(@as(usize, 1), selected.keyframes.len);
}

test "supports stylesheet allocation failures retire selectors queries and appended keyframes" {
    try std.testing.checkAllAllocationFailures(allocator, allocationTrial, .{});
}
