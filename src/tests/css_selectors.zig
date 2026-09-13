//! Logical selector, cascade and generated-host integration with an owned DOM.
const std = @import("std");
const document = @import("../document/parser.zig");
const css = @import("../document/css_parser.zig");
const selector = @import("../document/selector.zig");
const allocator = std.testing.allocator;

fn value(node: *document.Node, name: []const u8) []const u8 {
    return node.element.style.?.getPtr(name).?.get().*;
}

test "logical selectors preserve complex ancestry inside compounds and cached has" {
    var html = try document.HTMLParser.init(allocator, "<main><aside class=lead></aside><section class='card sm:card' id=target>" ++
        "<div><span class=badge>text</span></div></section><section class=other></section></main>");
    defer html.deinit(allocator);
    html.use_implicit_tags = false;
    var root = try html.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    const target = &root.element.children.items[1];
    const cases = .{
        .{ ":is(:unknown, main > section.card)", true },
        .{ ":is({bad: syntax}, .card)", true },
        .{ ":is(.card:nth-child(/* ) , */2n), .absent)", true },
        .{ ":is(:nth-child(2 n), .card)", true },
        .{ ":where()", false },
        .{ ":is(, :unknown(), .card, )", true },
        .{ ":is(.card > .badge, aside + .card)", true },
        .{ "section:not(main > aside, .other)", true },
        .{ ":not(main > :is(section.card, section.other))", false },
        .{ ":is(aside:not(.missing) + :where(.card))", true },
        .{ ":is(:not(:where(main > .card)))", false },
        .{ ":not(:is())", true },
        .{ ":is([data-x='a,b'], :where(.sm\\:card))", true },
        .{ ":is(:has(:is(main .badge)), .other)", true },
        .{ ":not(:is(section:has(.missing)))", true },
        .{ ".card:has(:is(main section .badge))", true },
        .{ ".card:is(section:has(:is(div > span.badge)), aside)", true },
        .{ ":where(:has(:not(main .badge, div)))", false },
    };
    inline for (cases) |case| {
        const selectors = try css.parseSelectorList(allocator, case[0]);
        defer {
            for (selectors) |*member| member.deinit(allocator);
            allocator.free(selectors);
        }
        try std.testing.expectEqual(case[1], selectors[0].matches(target, &.{&root}));
        var cache = selector.HasMatchCache.init(allocator);
        defer cache.deinit();
        try selectors[0].populateHasMatches(&cache, &root);
        try std.testing.expectEqual(case[1], selectors[0].matchesWithContext(target, &.{&root}, .{ .has_cache = &cache }));
    }
}

test "logical selector specificity takes the maximum valid branch and zeroes where" {
    const cases = .{
        .{ ":is(#unused, .matched)", css.Specificity{ .ids = 1 } },
        .{ ":is(#unused:nth-child(2 n), .matched)", css.Specificity{ .classes = 1 } },
        .{ ":is(#unused:unknown, .matched)", css.Specificity{ .classes = 1 } },
        .{ ":where(#id.class > p)::before", css.Specificity{ .types = 1 } },
        .{ ":not(.a, main > #id)", css.Specificity{ .ids = 1, .types = 1 } },
        .{ ":not(:not(.a#id), span)", css.Specificity{ .ids = 1, .classes = 1 } },
        .{ ".a:is(:where(#id), :not(.hidden))", css.Specificity{ .classes = 2 } },
        .{ ":is()", css.Specificity{} },
        .{ ":is(::before, #id::after, .a)", css.Specificity{ .classes = 1 } },
    };
    inline for (cases) |case| {
        const selectors = try css.parseSelectorList(allocator, case[0]);
        defer {
            for (selectors) |*member| member.deinit(allocator);
            allocator.free(selectors);
        }
        try std.testing.expectEqual(case[1], selectors[0].specificity());
    }
    for ([_][]const u8{
        ":not()",               ":not(.a,)", ":not(.a, :unknown)", ":not(.a, ::before)",
        ":not(> .a)",           ":is(.a",    ":is(.a), :unknown",  ":has(:has(.a))",
        ":has(:not(:has(.a)))",
    }) |invalid| {
        if (css.parseSelectorList(allocator, invalid)) |unexpected| {
            for (unexpected) |*member| member.deinit(allocator);
            allocator.free(unexpected);
            std.debug.print("accepted invalid selector: {s}\n", .{invalid});
            return error.ExpectedInvalidSelector;
        } else |err| try std.testing.expect(err != error.OutOfMemory);
    }
    try std.testing.expectError(error.SelectorLimitExceeded, css.parseSelectorList(allocator, ":is(" ** 65 ++ ".a" ++ ")" ** 65));
    try std.testing.expectError(error.SelectorLimitExceeded, css.parseSelectorList(allocator, ":where(" ++ ":unknown," ** 256 ++ ".a)"));
}

fn logicalAllocationTrial(failing: std.mem.Allocator) !void {
    const source = try failing.dupe(u8, ":is(:unknown, .card > :where(span, em)), :not(:is(.hidden, #absent)), :where(:has(:is(main .badge)))");
    const members = css.parseSelectorList(failing, source) catch |err| {
        failing.free(source);
        return err;
    };
    failing.free(source);
    defer {
        for (members) |*member| member.deinit(failing);
        failing.free(members);
    }
    for (members) |member| {
        var clone = try member.clone(failing);
        defer clone.deinit(failing);
        try std.testing.expectEqual(member.specificity(), clone.specificity());
    }
}

test "logical selector parsing and cloning propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, logicalAllocationTrial, .{});
}

test "selector cascade separates large specificity origins inline importance and source provenance" {
    var html = try document.HTMLParser.init(allocator, "<div id=target class=a style='width:50px; height:60px!important; border-left-width:8px!important'></div>");
    defer html.deinit(allocator);
    html.use_implicit_tags = false;
    var root = try html.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    var parser = try css.init(allocator, "#target { color:green; background-image:url(winner.png) }" ++
        ".a" ** 110 ++ " { color:red; background-image:url(loser.png) }" ++
        "#target" ** 11 ++ " { width:99px; height:99px }" ++
        ".a { height:40px!important; margin-left:3px!important }" ++
        "* { border-left-width:4px!important }" ++
        "#target" ** 600 ++ " { background-color:red }" ++
        "* { background-color:green }" ++
        ".a { padding-left:10px; padding-right:10px }" ++
        ":is(#absent, .a) { padding-left:20px }" ++
        ":where(#target) { padding-right:30px }" ++
        ".a { padding-bottom:1px } .a { padding-bottom:2px }" ++
        "#target { margin-top:var(--missing) } .a { margin-top:40px }", false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    var rules_alive = true;
    defer if (rules_alive) {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    };
    try std.testing.expectEqual(14, rules.len);
    rules[0].source_url = try allocator.dupe(u8, "https://winner.example/css/main.css");
    rules[0].referrer_policy = .no_referrer;
    rules[1].source_url = try allocator.dupe(u8, "https://loser.example/css/main.css");
    rules[4].origin = .user_agent;
    rules[5].origin = .user_agent;
    try document.style(allocator, &root, rules);
    // Computed strings and provenance survive retirement of the source generation.
    for (rules) |*rule| rule.deinit(allocator);
    allocator.free(rules);
    rules_alive = false;
    const expected = .{
        .{ "color", "green" },           .{ "width", "50px" },                           .{ "height", "60px" },
        .{ "border-left-width", "4px" }, .{ "margin-left", "3px" },                      .{ "background-color", "green" },
        .{ "padding-left", "20px" },     .{ "padding-right", "10px" },                   .{ "padding-bottom", "2px" },
        .{ "margin-top", "0px" },        .{ "background-image", "url(\"winner.png\")" },
    };
    inline for (expected) |pair| try std.testing.expectEqualStrings(pair[1], value(&root, pair[0]));
    try std.testing.expectEqualStrings("https://winner.example/css/main.css", root.element.background_source_url.?);
    try std.testing.expectEqual(@import("../document/referrer.zig").Policy.no_referrer, root.element.background_referrer_policy.?);
}

test "logical selectors style generated boxes using their authored host relationships" {
    var html = try document.HTMLParser.init(allocator, "<main><aside></aside><section class=card></section></main>");
    defer html.deinit(allocator);
    html.use_implicit_tags = false;
    var root = try html.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    var parser = try css.init(allocator, "section { color:blue } :is(main > .card):not(aside)::before { content:''; color:green; width:20px }" ++
        ":where(aside + .card)::after { content:''; color:green; width:30px }" ++
        ":is(.card > .card)::before { width:99px }", false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try document.style(allocator, &root, rules);
    const host = &root.element.children.items[1];
    try std.testing.expectEqualStrings("blue", value(host, "color"));
    const before = host.element.generated_before.?;
    const after = host.element.generated_after.?;
    try std.testing.expectEqualStrings("green", value(before, "color"));
    try std.testing.expectEqualStrings("20px", value(before, "width"));
    try std.testing.expectEqualStrings("30px", value(after, "width"));
}

test "logical selector maximum specificity ties ordinary complex chains in source order" {
    // Core cascade from WPT css/selectors/is-specificity.html, independent of
    // that test's named-window-global prerequisite.
    var html = try document.HTMLParser.init(allocator, "<main><div class='b c'></div><div class='a d e'></div><div class='q r'></div>" ++
        "<div class='p s t'></div><div id=target></div></main>");
    defer html.deinit(allocator);
    html.use_implicit_tags = false;
    var root = try html.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    var parser = try css.init(allocator, ".b.c + .d + .q.r + .s + #target {font-size:10px;height:10px;width:10px}" ++
        ":is(.a, .b.c + .d, .q) + :is(* + .p, .q.r + .s, * + .t) + #target {height:20px;width:20px}" ++
        ".b.c + .d + .q.r + .s + #target {width:30px}", false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try document.style(allocator, &root, rules);
    const target = &root.element.children.items[4];
    try std.testing.expectEqualStrings("30px", value(target, "width"));
    try std.testing.expectEqualStrings("20px", value(target, "height"));
    try std.testing.expectEqualStrings("10px", value(target, "font-size"));
}

test "logical selector invalidation follows has through sibling ancestors and retires generation policy" {
    var html = try document.HTMLParser.init(allocator, "<main><section><span></span></section><section><div class=target></div></section></main>");
    defer html.deinit(allocator);
    html.use_implicit_tags = false;
    var root = try html.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    var parser = try css.init(allocator, ".target {width:10px} :is(section:has(.active) + section) > .target {width:20px}", false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try document.style(allocator, &root, rules);
    const trigger = &root.element.children.items[0].element.children.items[0];
    const target = &root.element.children.items[1].element.children.items[0];
    try std.testing.expectEqualStrings("10px", value(target, "width"));
    if (trigger.element.attributes == null) trigger.element.attributes = @import("../document/attributes.zig").Map.init(allocator);
    try trigger.element.attributes.?.put("class", "active");
    document.dirtyStyleForElement(&trigger.element);
    try document.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("20px", value(target, "width"));
    _ = trigger.element.attributes.?.orderedRemove("class");
    document.dirtyStyleForElement(&trigger.element);
    try document.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("10px", value(target, "width"));
    document.dirtyStyleSubtree(&root);
    try document.style(allocator, &root, &.{});
    try std.testing.expectEqual(@import("../document/dom.zig").SelectorDependencies{}, root.element.selector_dependencies);
}
