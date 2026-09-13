//! Bounded CSS feature-query evaluation over borrowed source. Declarations use
//! the shared property grammar; the selector owner supplies strict admission.
//! No DOM, stylesheet, source slice or parsed declaration survives a query.

const std = @import("std");
const tokens = @import("css_tokenizer.zig");
const declarations = @import("css_declarations.zig");
const values = @import("css_values.zig");

pub const max_bytes = 64 * 1024;
pub const max_depth = 64;
pub const Error = std.mem.Allocator.Error || error{LimitExceeded};
pub const SelectorSupport = *const fn (std.mem.Allocator, []const u8) Error!bool;

/// CSS.supports(property, value): property is a literal decoded CSSOM name,
/// with no trimming or escape processing. Embedded priority is invalid. Empty
/// custom values are valid; unresolved var() references need no DOM environment.
pub fn property(allocator: std.mem.Allocator, name: []const u8, value: []const u8) std.mem.Allocator.Error!bool {
    if (name.len > max_bytes or value.len > values.max_bytes or !declarations.validSetterValue(value)) return false;
    var map = declarations.Map.init(allocator);
    defer map.deinit();
    try declarations.putParsed(&map, name, value, false);
    return map.count() != 0;
}

/// Evaluate an @supports prelude. Grammar failures and admission limits fail
/// closed; allocation failure propagates so stylesheet publication can abort.
/// Unknown, well-formed enclosed features are false and may be negated.
pub fn matches(allocator: std.mem.Allocator, source: []const u8, selector: SelectorSupport) std.mem.Allocator.Error!bool {
    return (checked(allocator, source, selector) catch |err| switch (err) {
        error.LimitExceeded => return false,
        error.OutOfMemory => return error.OutOfMemory,
    }) orelse false;
}

/// CSS.supports(conditionText) also tries the source wrapped in parentheses,
/// as required for the single-declaration convenience form. Source is borrowed
/// synchronously and all temporary storage retires before returning.
pub fn conditionText(allocator: std.mem.Allocator, source: []const u8, selector: SelectorSupport) std.mem.Allocator.Error!bool {
    if (try matches(allocator, source, selector)) return true;
    if (source.len > max_bytes - 2) return false;
    const wrapped = try std.fmt.allocPrint(allocator, "({s})", .{source});
    defer allocator.free(wrapped);
    return matches(allocator, wrapped, selector);
}

fn checked(allocator: std.mem.Allocator, source: []const u8, selector: SelectorSupport) Error!?bool {
    if (source.len > max_bytes) return error.LimitExceeded;
    // Validate every component before evaluating any branch. Boolean results
    // must never hide bad tokens, mismatched delimiters or excessive nesting.
    var stack: [max_depth]tokens.Kind = undefined;
    var depth: usize = 0;
    var iterator = tokens.Iterator{ .input = source };
    while (iterator.next()) |token| {
        if (token.kind == .bad_string or token.kind == .bad_url) return null;
        if (token.closer()) |closer| {
            if (depth == stack.len) return error.LimitExceeded;
            stack[depth] = closer;
            depth += 1;
        } else if (token.isClose()) {
            if (depth == 0 or stack[depth - 1] != token.kind) return null;
            depth -= 1;
        }
    }
    // CSS Syntax closes unfinished components at EOF.
    return evaluate(allocator, source, selector, 0);
}

fn next(iterator: *tokens.Iterator) ?tokens.Token {
    while (iterator.next()) |token| if (!token.isTrivia()) return token;
    return null;
}

fn keyword(token: tokens.Token, source: []const u8, name: []const u8) bool {
    return token.kind == .ident and tokens.identifierEquals(token.encodedValue(source), name);
}

fn evaluate(allocator: std.mem.Allocator, source: []const u8, selector: SelectorSupport, depth: usize) Error!?bool {
    if (depth > max_depth) return error.LimitExceeded;
    var iterator = tokens.Iterator{ .input = source };
    var first = next(&iterator) orelse return null;
    const negate = keyword(first, source, "not");
    if (negate) first = next(&iterator) orelse return null;
    var result = (try inParens(allocator, first, &iterator, selector, depth)) orelse return null;
    var conjunction: ?bool = null;
    while (next(&iterator)) |operator| {
        if (negate) return null;
        const is_and = keyword(operator, source, "and");
        if (!is_and and !keyword(operator, source, "or")) return null;
        if (conjunction) |previous| if (previous != is_and) return null;
        conjunction = is_and;
        const operand = next(&iterator) orelse return null;
        // Parse the whole chain even when its result is already determined.
        const value = (try inParens(allocator, operand, &iterator, selector, depth)) orelse return null;
        result = if (is_and) result and value else result or value;
    }
    return if (negate) !result else result;
}

fn inParens(
    allocator: std.mem.Allocator,
    first: tokens.Token,
    iterator: *tokens.Iterator,
    selector: SelectorSupport,
    depth: usize,
) Error!?bool {
    if (first.kind != .open_paren and first.kind != .function) return null;
    const source = iterator.input;
    var end = source.len;
    var nested: usize = 1;
    while (iterator.next()) |token| {
        if (token.closer() != null) nested += 1 else if (token.isClose()) {
            nested -= 1;
            if (nested == 0) {
                end = token.start;
                break;
            }
        }
    }
    const body = source[first.end..end];
    if (first.kind == .function) {
        if (tokens.identifierEquals(first.encodedValue(source), "selector")) {
            // Supply repaired component source to the existing selector parser,
            // which normally requires explicit closers in direct selector APIs.
            const repaired = (try values.normalize(allocator, body, .{ .preserve = true })) orelse return false;
            defer allocator.free(repaired);
            return try selector(allocator, repaired);
        }
        return false;
    }
    if (try evaluate(allocator, body, selector, depth + 1)) |result| return result;

    var declaration = tokens.Iterator{ .input = body };
    const name = next(&declaration) orelse return false;
    if (name.kind != .ident) return false;
    const colon = next(&declaration) orelse return false;
    if (colon.kind != .colon) return false;
    var map = declarations.Map.init(allocator);
    defer map.deinit();
    try declarations.putRaw(&map, name.raw(body), body[colon.end..]);
    return map.count() != 0;
}

fn noSelectors(_: std.mem.Allocator, _: []const u8) Error!bool {
    return false;
}

test "supports property queries share declaration grammar without CSSOM mutation" {
    const allocator = std.testing.allocator;
    const valid = [_][2][]const u8{
        .{ "display", "grid" },              .{ "WIDTH", "calc(10px + 2px)" },
        .{ "color", "rebeccapurple" },       .{ "border", "1px solid green" },
        .{ "margin", "inherit" },            .{ "--theme", "" },
        .{ "--Theme", "{} [a] func(b)" },    .{ "color", "future(var(--theme))" },
        .{ "padding", "var(--unset, 2px)" }, .{ "color", "r\\65 d/**/" },
        .{ "width", "var(--size" },
    };
    for (valid) |pair| try std.testing.expect(try property(allocator, pair[0], pair[1]));
    const invalid = [_][2][]const u8{
        .{ " width", "5px" },                .{ "width ", "5px" },           .{ "w\\69 dth", "5px" },
        .{ "unknown", "inherit" },           .{ "unicode-range", "U+0-7F" }, .{ "color", "red !important" },
        .{ "width", "10px; color:red" },     .{ "--theme", "a !important" }, .{ "--", "a" },
        .{ "--theme", "]" },                 .{ "margin", "1px bad" },       .{ "color", "var(no-dashes)" },
        .{ "color", "var(--x !important)" }, .{ "color", "" },               .{ "padding", "-1px" },
    };
    for (invalid) |pair| try std.testing.expect(!try property(allocator, pair[0], pair[1]));
}

test "supports conditions distinguish boolean grammar from future enclosed features" {
    const allocator = std.testing.allocator;
    const valid = [_][]const u8{
        "(color:red)",                                  "((color:red))",                                       "(color:red !IMPORTANT)",
        "not (unknown:value)",                          "not future(!@#% {} [] more())",                       "not ()",
        "(color:red)and/**/(display:block)",            "n\\6ft (unknown: value)",                             "(color:no) or (color:green)",
        "(color:red) and ((color:blue) or (future:0))", "not ((color:red) and (color:blue) or (color:green))", "(c\\6flor : r\\65 d)",
        "(--Theme:)",                                   "(color:var(--missing))",                              "(color:red",
        "((color:red) and (display:block",              "(color:red) /* EOF",
    };
    for (valid) |source| try std.testing.expect(try matches(allocator, source, noSelectors));
    const invalid = [_][]const u8{
        "",                              "color:red",               "(color:no)",                                      "future()",                    "()",                     "([padding])",
        "not(color:no)",                 "not not (color:no)",      "(color:red) and (display:block) or (color:blue)", "(color:red) or garbage",      "(color:no) and garbage", "not (color:no) or (color:red)",
        "(color:red)and(display:block)", "(color:red);",            "(color:red) or (color:blue]",                     "not future(\"bad\nstring\")", "(color:red;) ",          "(color:red !bad)",
        "(color: var(--))",              "(width:10px; color:red)", "not [future]",
    };
    for (invalid) |source| try std.testing.expect(!try matches(allocator, source, noSelectors));
    try std.testing.expect(try conditionText(allocator, "color:red !important", noSelectors));
    try std.testing.expect(try conditionText(allocator, "color:red) or (color:blue", noSelectors));
    try std.testing.expect(!try conditionText(allocator, "color:red;", noSelectors));
}

test "supports limits cannot become a successful negated query" {
    try std.testing.expect(!try matches(std.testing.allocator, "not " ++ "(" ** 65 ++ "color:red" ++ ")" ** 65, noSelectors));
    try std.testing.expect(!try conditionText(std.testing.allocator, " " ** (max_bytes + 1), noSelectors));
}

test "supports rejects unsupported formatting and animation values through shared declaration admission" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "display", "position", "float", "clear", "overflow", "visibility", "text-align", "font-weight", "font-style", "font-variant", "font-stretch", "object-fit", "border-radius", "opacity" }) |name| {
        try std.testing.expect(!try property(allocator, name, "nonsense"));
        try std.testing.expect(try property(allocator, name, "inherit"));
    }
    try std.testing.expect(try property(allocator, "animation", "pulse 1s linear"));
    try std.testing.expect(try property(allocator, "animation", "pulse 1s both"));
    try std.testing.expect(!try property(allocator, "animation", "pulse 1s invalid extra"));
    try std.testing.expect(!try property(allocator, "display", "inline-table"));
    try std.testing.expect(try property(allocator, "position", "sticky"));
    var map = declarations.Map.init(allocator);
    defer map.deinit();
    try declarations.putRaw(&map, "display", "block");
    try declarations.putRaw(&map, "display", "nonsense");
    try std.testing.expectEqualStrings("block", map.get("display").?.value);
    try std.testing.expect(try conditionText(allocator, "not (display:nonsense)", noSelectors));
}

fn allocationQuery(allocator: std.mem.Allocator) !void {
    try std.testing.expect(try conditionText(allocator, "(border:1px solid red) and (--Theme: var(--missing, blue))", noSelectors));
    try std.testing.expect(try conditionText(allocator, "margin:1px 2px", noSelectors));
}

test "supports query temporaries retire on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationQuery, .{});
}
