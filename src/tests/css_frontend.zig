//! Acceptance corpus for the isolated CSS frontend and its reclaiming owner.
//! WPT-derived strings test syntax directly, not browser/CSSOM conformance.

const std = @import("std");
const frontend = @import("../document/css_frontend.zig");
const bounds = @import("../document/css_frontend_limits.zig");
const Syntax = frontend.Syntax;
const NodeId = frontend.NodeId;
const allocator = std.testing.allocator;

fn childAt(tree: Syntax, parent: NodeId, index: usize) !NodeId {
    var children = tree.children(parent);
    var i: usize = 0;
    while (children.next()) |child| : (i += 1) {
        if (i == index) return child;
    }
    return error.MissingChild;
}

fn declarationAt(tree: Syntax, parent: NodeId, index: usize) !frontend.Declaration {
    return tree.declaration(try childAt(tree, parent, index)) orelse error.MissingDeclaration;
}

fn expectDeclaration(tree: Syntax, parent: NodeId, index: usize, name: []const u8, value: []const u8, important: bool) !void {
    const decl = try declarationAt(tree, parent, index);
    try std.testing.expectEqualStrings(name, tree.slice(decl.name));
    try std.testing.expectEqualStrings(value, tree.slice(decl.value));
    try std.testing.expectEqual(important, decl.important);
}

fn checkRanges(tree: Syntax, id: NodeId) !void {
    const node = tree.node(id);
    try std.testing.expect(node.range.start <= node.range.end);
    try std.testing.expect(node.range.end <= tree.source().len);
    var children = tree.children(id);
    var end = node.range.start;
    while (children.next()) |child| {
        const range = tree.node(child).range;
        try std.testing.expect(range.start >= end);
        try std.testing.expect(range.end <= node.range.end);
        end = range.end;
        try checkRanges(tree, child);
    }
}

test "CSS frontend retains declaration order duplicates trivia and priority" {
    var tree = try Syntax.parse(allocator,
        \\c\6flor: red; color: unsupported; color: green ! /*x*/ ImPoRtAnT;
        \\--empty: ; --x: var(--y, calc(1px + 2px));
    , .{ .mode = .declarations });
    defer tree.deinit();
    const list = try childAt(tree, tree.root(), 0);
    try expectDeclaration(tree, list, 0, "c\\6flor", "red", false);
    try expectDeclaration(tree, list, 1, "color", "unsupported", false);
    try expectDeclaration(tree, list, 2, "color", "green", true);
    try expectDeclaration(tree, list, 3, "--empty", "", false);
    try expectDeclaration(tree, list, 4, "--x", "var(--y, calc(1px + 2px))", false);
    try checkRanges(tree, tree.root());
}

test "CSS frontend preserves nested order without granting at-rule semantics" {
    var tree = try Syntax.parse(
        allocator,
        "@media (width > 1px) { a { color: red; @unknown x; & b { color: blue; } color: green; } }",
        .{},
    );
    defer tree.deinit();
    const media = try childAt(tree, tree.root(), 0);
    try std.testing.expectEqual(.at_rule, tree.node(media).kind);
    var media_children = tree.children(media);
    var media_block: NodeId = undefined;
    while (media_children.next()) |child| media_block = child;
    const rule = try childAt(tree, media_block, 0);
    const block = try childAt(tree, rule, 2);
    try std.testing.expectEqual(.block, tree.node(block).kind);
    const expected = [_]frontend.Kind{ .declaration_list, .at_rule, .qualified_rule, .declaration_list };
    for (expected, 0..) |kind, i| try std.testing.expectEqual(kind, tree.node(try childAt(tree, block, i)).kind);
    try checkRanges(tree, tree.root());
}

test "CSS frontend invalid syntax never becomes an executable declaration" {
    var tree = try Syntax.parse(
        allocator,
        "color: green; broken value; color: red; x: url(bad\"url); y: \"bad\n; z: 1px]; color: blue;",
        .{ .mode = .declarations },
    );
    defer tree.deinit();
    var children = tree.children(tree.root());
    var valid: usize = 0;
    var invalid: usize = 0;
    while (children.next()) |child| {
        if (tree.node(child).kind == .invalid) {
            try std.testing.expect(tree.declaration(child) == null);
            invalid += 1;
        }
        var declarations = tree.children(child);
        while (declarations.next()) |decl_id| {
            if (tree.declaration(decl_id)) |decl| {
                try std.testing.expectEqualStrings("color", tree.slice(decl.name));
                valid += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3), valid);
    try std.testing.expect(invalid > 0);
    var lexical: usize = 0;
    for (tree.diagnostics()) |diagnostic| {
        if (diagnostic.stage == .tokenizer) lexical += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), lexical);
}

test "CSS frontend source and provenance survive caller retirement and owner moves" {
    const input = try allocator.dupe(u8, "a { color: green; }");
    const url = try allocator.dupe(u8, "https://example.test/assets/main.css");
    var parsed = Syntax.parse(allocator, input, .{ .base_url = url }) catch |err| {
        allocator.free(input);
        allocator.free(url);
        return err;
    };
    @memset(input, 'x');
    @memset(url, 'x');
    allocator.free(input);
    allocator.free(url);
    var moved = parsed;
    parsed = undefined;
    defer moved.deinit();
    try std.testing.expectEqualStrings("a { color: green; }", moved.source());
    try std.testing.expectEqualStrings("https://example.test/assets/main.css", moved.baseUrl().?);
    try checkRanges(moved, moved.root());
    try moved.replace("b { color: blue; }", .{});
    try std.testing.expectEqualStrings("b { color: blue; }", moved.source());
    try std.testing.expect(moved.baseUrl() == null);
}

fn allocationTrial(failing: std.mem.Allocator) !void {
    var tree = try Syntax.parse(failing, @embedFile("fixtures/css/recovery.css"), .{ .base_url = "https://example.test/a.css" });
    defer tree.deinit();
    const old_source = tree.source();
    tree.replace("@font-face { unicode-range: U+20-7F; } a { --x: fn(1px); }", .{}) catch |err| {
        try std.testing.expectEqualStrings(@embedFile("fixtures/css/recovery.css"), tree.source());
        try std.testing.expectEqual(old_source.ptr, tree.source().ptr);
        try std.testing.expectEqualStrings("https://example.test/a.css", tree.baseUrl().?);
        return err;
    };
}

test "CSS frontend allocation failures clean up and preserve replacement generation" {
    try std.testing.checkAllAllocationFailures(allocator, allocationTrial, .{});
}

fn modeAllocationTrial(failing: std.mem.Allocator, mode: frontend.Mode) !void {
    var tree = try Syntax.parse(failing, "--x: fn([a;b]); bad declaration; color: green", .{ .mode = mode });
    defer tree.deinit();
}

test "CSS frontend allocation failures cover declarations and component values" {
    for ([_]frontend.Mode{ .declarations, .component_values }) |mode| {
        try std.testing.checkAllAllocationFailures(allocator, modeAllocationTrial, .{mode});
    }
}

test "CSS frontend admission limits precede recursive parsing and allocation" {
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const no_alloc = failing.allocator();
    try std.testing.expectError(error.SourceLimitExceeded, Syntax.parse(no_alloc, "a{}", .{ .limits = .{ .source_bytes = 2 } }));
    try std.testing.expectError(error.TokenLimitExceeded, Syntax.parse(no_alloc, "a{}", .{ .limits = .{ .tokens = 2 } }));
    try std.testing.expectError(error.NestingLimitExceeded, Syntax.parse(no_alloc, "a{ f([x]) }", .{ .limits = .{ .nesting = 2 } }));
    try std.testing.expectError(error.RecoveryLimitExceeded, Syntax.parse(no_alloc, "@media all { a{} b{} c{} }", .{ .limits = .{ .recovery_work = 1 } }));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectError(error.NodeLimitExceeded, Syntax.parse(allocator, "a{}", .{ .limits = .{ .nodes = 1 } }));
    try std.testing.expectError(error.MemoryLimitExceeded, Syntax.parse(allocator, "a{}", .{ .limits = .{ .allocated_bytes = 1 } }));
}

test "CSS frontend mismatched closers cannot bypass nesting bound" {
    try std.testing.expectError(error.NestingLimitExceeded, Syntax.parse(allocator, "([)[)[)[)", .{ .mode = .component_values, .limits = .{ .nesting = 3 } }));
    var input = [_]u8{'('} ** 60000;
    try std.testing.expectError(error.NestingLimitExceeded, Syntax.parse(allocator, &input, .{ .mode = .component_values }));
    var tree = try Syntax.parse(allocator, "url(a\\)b) '\"((({{{' /* ((( */ fn(x)", .{ .mode = .component_values, .limits = .{ .nesting = 1 } });
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 1), tree.stats().nesting);
}

test "CSS frontend accepts its nesting boundary and rejects large recovery workloads" {
    const at_limit = "(" ** 64 ++ "x";
    var values = try Syntax.parse(allocator, at_limit, .{ .mode = .component_values });
    defer values.deinit();
    try std.testing.expectEqual(@as(usize, 64), values.stats().nesting);
    try checkRanges(values, values.root());
    // This ordinary sibling shape triggers upstream's repeated suffix scans.
    // The default admission gate rejects it before any frontend allocation.
    const siblings = "@media all {" ++ ".a{}" ** 1024 ++ "}";
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.RecoveryLimitExceeded, Syntax.parse(failing.allocator(), siblings, .{}));
    try std.testing.expect(!failing.has_induced_failure);
}

test "CSS frontend budget accounts allocation resize remap and rejected growth" {
    var budget = bounds.Budget{ .parent = allocator, .limit = 128 };
    const bounded = budget.allocator();
    var bytes = try bounded.alloc(u8, 32);
    try std.testing.expectEqual(@as(usize, 32), budget.live);
    bytes = try bounded.realloc(bytes, 64);
    try std.testing.expectEqual(@as(usize, 64), budget.live);
    try std.testing.expectError(error.OutOfMemory, bounded.realloc(bytes, 129));
    try std.testing.expectEqual(@as(usize, 64), budget.live);
    bytes = try bounded.realloc(bytes, 8);
    try std.testing.expectEqual(@as(usize, 8), budget.live);
    bounded.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.live);
    try std.testing.expect(budget.peak <= budget.limit);
}

test "CSS frontend deterministic reduced sheets and actual user-agent source" {
    for ([_][]const u8{
        @embedFile("fixtures/css/page-reductions.css"),
        @embedFile("fixtures/css/recovery.css"),
        @embedFile("../browser/browser.css"),
    }) |input| {
        var tree = try Syntax.parse(allocator, input, .{});
        defer tree.deinit();
        try std.testing.expect(tree.stats().nodes > 1);
        try std.testing.expect(tree.stats().peak_allocated_bytes <= (frontend.Limits{}).allocated_bytes);
        try std.testing.expectEqualStrings(input, tree.source());
        try checkRanges(tree, tree.root());
    }
}

test "CSS frontend EOF recovery retains original ranges and lexical diagnostics" {
    // Syntax portions of WPT escaped-eof.html and unclosed-url-at-eof.html.
    for ([_][]const u8{ "foo\\", "1foo\\", "url(foo\\", "\"foo\\", "url(foo", "url(" }) |value| {
        const source = try std.fmt.allocPrint(allocator, "--foo:{s}", .{value});
        defer allocator.free(source);
        var tree = try Syntax.parse(allocator, source, .{ .mode = .declarations });
        defer tree.deinit();
        const list = try childAt(tree, tree.root(), 0);
        try expectDeclaration(tree, list, 0, "--foo", value, false);
        try std.testing.expect(tree.diagnostics().len > 0);
        try checkRanges(tree, tree.root());
    }
}

test "CSS frontend at-rules in declaration lists preserve following declarations" {
    // Syntax inputs from WPT at-rule-in-declaration-list.html. This does not
    // implement CSSStyleSheet.insertRule or @page/@font-face property semantics.
    for ([_][]const u8{ "@at {}", "@at at;" }) |at_rule| {
        const source = try std.fmt.allocPrint(allocator, "{s} color: green;", .{at_rule});
        defer allocator.free(source);
        var tree = try Syntax.parse(allocator, source, .{ .mode = .declarations });
        defer tree.deinit();
        try std.testing.expectEqual(.at_rule, tree.node(try childAt(tree, tree.root(), 0)).kind);
        const list = try childAt(tree, tree.root(), 1);
        try expectDeclaration(tree, list, 0, "color", "green", false);
    }
}

test "CSS frontend component values preserve token boundaries and opaque functions" {
    var tree = try Syntax.parse(allocator, "10/**/px var(--x, [a;b]) url(a\\)b)", .{ .mode = .component_values });
    defer tree.deinit();
    const number = try childAt(tree, tree.root(), 0);
    const ident = try childAt(tree, tree.root(), 1);
    try std.testing.expectEqualStrings("10", tree.slice(tree.node(number).range));
    try std.testing.expectEqualStrings("px", tree.slice(tree.node(ident).range));
    try checkRanges(tree, tree.root());
}

test "CSS frontend deterministic malformed corpus terminates with valid source ranges" {
    var random = std.Random.DefaultPrng.init(0xc55);
    const alphabet = "a0:;{}[]()\\\"'/* !@#\n\r\x00\xff";
    var bytes: [96]u8 = undefined;
    for (0..300) |case| {
        const input = bytes[0 .. case % bytes.len];
        for (input) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        for ([_]frontend.Mode{ .stylesheet, .declarations, .component_values }) |mode| {
            var tree = try Syntax.parse(allocator, input, .{ .mode = mode });
            defer tree.deinit();
            try checkRanges(tree, tree.root());
        }
    }
}
