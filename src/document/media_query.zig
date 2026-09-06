//! Allocation-free media-query evaluation over a borrowed stylesheet prelude.
//! The caller supplies viewport state and rebuilds conditional rule generations
//! when it changes; this module retains neither source text nor document state.

const std = @import("std");
const syntax = @import("css_syntax.zig");
const tokens = @import("css_value_tokens.zig");

pub const Environment = struct {
    prefers_dark: bool = false,
    forced_colors: bool = false,
    /// Missing viewport dimensions are recognized but inactive.
    viewport_width_css: ?f64 = null,
    viewport_height_css: ?f64 = null,
    color_depth: u8 = 24,
    monochrome_depth: u8 = 0,
};

const Truth = enum {
    yes,
    no,
    unknown,

    fn from(value: bool) Truth {
        return if (value) .yes else .no;
    }
    fn invert(self: Truth) Truth {
        return switch (self) {
            .yes => .no,
            .no => .yes,
            .unknown => .unknown,
        };
    }
    fn both(a: Truth, b: Truth) Truth {
        if (a == .no or b == .no) return .no;
        return if (a == .yes and b == .yes) .yes else .unknown;
    }
    fn either(a: Truth, b: Truth) Truth {
        if (a == .yes or b == .yes) return .yes;
        return if (a == .no and b == .no) .no else .unknown;
    }
};

const Comparison = enum {
    lt,
    le,
    eq,
    ge,
    gt,

    fn compare(self: Comparison, a: f64, b: f64, length: bool) bool {
        // Preserve the established equality boundary for f32 browser zoom.
        // All five operators use the same ordering, so strict/inclusive
        // complements never overlap or leave a gap at a breakpoint.
        const equal = a == b or (length and @abs(a - b) <= @max(@max(@abs(a), @abs(b)), 1.0) * 0.000001);
        return switch (self) {
            .lt => a < b and !equal,
            .le => a < b or equal,
            .eq => equal,
            .ge => a > b or equal,
            .gt => a > b and !equal,
        };
    }
    fn reversed(self: Comparison) Comparison {
        return switch (self) {
            .lt => .gt,
            .le => .ge,
            .eq => .eq,
            .ge => .le,
            .gt => .lt,
        };
    }
    fn direction(self: Comparison) i8 {
        return switch (self) {
            .lt, .le => -1,
            .eq => 0,
            .ge, .gt => 1,
        };
    }
};

const Feature = enum {
    width,
    height,
    color,
    monochrome,

    fn parse(name: []const u8) ?Feature {
        inline for (comptime std.meta.tags(Feature)) |feature| {
            if (syntax.identifierEquals(name, @tagName(feature))) return feature;
        }
        return null;
    }
    fn actual(self: Feature, env: Environment) ?f64 {
        const value: f64 = switch (self) {
            .width => env.viewport_width_css orelse return null,
            .height => env.viewport_height_css orelse return null,
            .color => @floatFromInt(env.color_depth),
            .monochrome => @floatFromInt(env.monochrome_depth),
        };
        return if (std.math.isFinite(value) and value >= 0) value else null;
    }
    fn isLength(self: Feature) bool {
        return self == .width or self == .height;
    }
    fn evaluate(self: Feature, number: Number, op: Comparison, env: Environment) Truth {
        if (self.isLength()) {
            if (!number.length and number.value != 0) return .unknown;
        } else if (number.length or !number.integer) return .unknown;
        const actual_value = self.actual(env) orelse return .no;
        // These features are false in the negative range. A tiny negative
        // limit must not compare equal to zero through zoom normalization.
        if (number.value < 0) return Truth.from(op == .gt or op == .ge);
        return Truth.from(op.compare(actual_value, number.value, self.isLength()));
    }
};

const Number = struct { value: f64, length: bool, integer: bool };
const Operand = union(enum) { name: []const u8, number: Number };

const Scanner = struct {
    input: []const u8,
    cursor: usize = 0,

    fn space(self: *Scanner) void {
        syntax.skipWhitespaceAndComments(self.input, &self.cursor);
    }
    fn done(self: *Scanner) bool {
        self.space();
        return self.cursor == self.input.len;
    }
    fn take(self: *Scanner, byte: u8) bool {
        self.space();
        if (self.cursor == self.input.len or self.input[self.cursor] != byte) return false;
        self.cursor += 1;
        return true;
    }
    fn next(self: *Scanner) ?tokens.Token {
        self.space();
        var iterator = tokens.Iterator{ .input = self.input, .cursor = self.cursor };
        const token = iterator.next() orelse return null;
        self.cursor = iterator.cursor;
        return token;
    }
    fn identifier(self: *Scanner) ?[]const u8 {
        const saved = self.cursor;
        const token = self.next() orelse return null;
        if (token.kind == .ident) return self.input[token.start..token.end];
        self.cursor = saved;
        return null;
    }
    fn keyword(self: *Scanner, word: []const u8) bool {
        const saved = self.cursor;
        if (self.identifier()) |name| {
            if (syntax.identifierEquals(name, word)) return true;
        }
        self.cursor = saved;
        return false;
    }
    fn comparison(self: *Scanner) ?Comparison {
        self.space();
        if (self.cursor == self.input.len) return null;
        const byte = self.input[self.cursor];
        if (byte != '<' and byte != '>' and byte != '=') return null;
        self.cursor += 1;
        if (byte == '=') return .eq;
        // Comments vanish during tokenization, but whitespace between the
        // comparison delimiter and '=' makes a different, invalid expression.
        while (syntax.consumeComment(self.input, &self.cursor)) {}
        const inclusive = self.cursor < self.input.len and self.input[self.cursor] == '=';
        if (inclusive) self.cursor += 1;
        return if (byte == '<') (if (inclusive) .le else .lt) else (if (inclusive) .ge else .gt);
    }
    fn operand(self: *Scanner) ?Operand {
        const token = self.next() orelse return null;
        const raw = self.input[token.start..token.end];
        if (token.kind == .ident) return .{ .name = raw };
        if (token.number_end <= token.start) return null;
        const number_text = self.input[token.start..token.number_end];
        // The shared scanner locates number boundaries; enforce CSS number
        // grammar here instead of accepting Zig's inf, hex, or trailing dot.
        if (!validNumber(number_text)) return null;
        var value = std.fmt.parseFloat(f64, number_text) catch return null;
        if (!std.math.isFinite(value)) return null;
        const unit = self.input[token.number_end..token.end];
        if (unit.len == 0) return .{ .number = .{
            .value = value,
            .length = false,
            .integer = std.mem.indexOfAny(u8, number_text, ".eE") == null,
        } };
        const scales = .{
            .{ "px", 1.0 },         .{ "em", 16.0 },        .{ "rem", 16.0 },
            .{ "in", 96.0 },        .{ "cm", 96.0 / 2.54 }, .{ "mm", 96.0 / 25.4 },
            .{ "q", 96.0 / 101.6 }, .{ "pt", 96.0 / 72.0 }, .{ "pc", 16.0 },
        };
        inline for (scales) |scale| {
            if (syntax.identifierEquals(unit, scale[0])) {
                value *= scale[1];
                if (!std.math.isFinite(value)) return null;
                return .{ .number = .{ .value = value, .length = true, .integer = false } };
            }
        }
        return null;
    }
};

fn validNumber(text: []const u8) bool {
    var i: usize = 0;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    const start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    var digits = i - start;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const fraction = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (i == fraction) return false;
        digits += i - fraction;
    }
    if (digits == 0) return false;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const exponent = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (i == exponent) return false;
    }
    return i == text.len;
}

fn compareOperands(left: Operand, right: Operand, op: Comparison, env: Environment) Truth {
    if (left == .name and right == .number) {
        const feature = Feature.parse(left.name) orelse return .unknown;
        return feature.evaluate(right.number, op, env);
    }
    if (left == .number and right == .name) return compareOperands(right, left, op.reversed(), env);
    return .unknown;
}

fn featureMatches(raw: []const u8, env: Environment) Truth {
    var scan = Scanner{ .input = raw };
    const first = scan.operand() orelse return .unknown;
    if (scan.done()) {
        if (first != .name) return .unknown;
        const feature = Feature.parse(first.name) orelse return .unknown;
        return Truth.from((feature.actual(env) orelse return .no) > 0);
    }
    if (scan.take(':')) {
        if (first != .name) return .unknown;
        const name = first.name;
        const value = scan.operand() orelse return .unknown;
        if (!scan.done()) return .unknown;
        if (value == .name) {
            if (syntax.identifierEquals(name, "prefers-color-scheme")) {
                if (syntax.identifierEquals(value.name, "dark")) return Truth.from(env.prefers_dark);
                if (syntax.identifierEquals(value.name, "light")) return Truth.from(!env.prefers_dark);
            }
            if (syntax.identifierEquals(name, "forced-colors")) {
                if (syntax.identifierEquals(value.name, "active")) return Truth.from(env.forced_colors);
                if (syntax.identifierEquals(value.name, "none")) return Truth.from(!env.forced_colors);
            }
            return .unknown;
        }
        inline for (comptime std.meta.tags(Feature)) |feature| {
            if (syntax.identifierEquals(name, @tagName(feature))) return feature.evaluate(value.number, .eq, env);
            if (syntax.identifierEquals(name, comptime "min-" ++ @tagName(feature))) return feature.evaluate(value.number, .ge, env);
            if (syntax.identifierEquals(name, comptime "max-" ++ @tagName(feature))) return feature.evaluate(value.number, .le, env);
        }
        return .unknown;
    }
    const first_op = scan.comparison() orelse return .unknown;
    const second = scan.operand() orelse return .unknown;
    if (scan.done()) return compareOperands(first, second, first_op, env);
    const second_op = scan.comparison() orelse return .unknown;
    const third = scan.operand() orelse return .unknown;
    if (!scan.done() or first != .number or second != .name or third != .number or
        first_op.direction() == 0 or first_op.direction() != second_op.direction()) return .unknown;
    return Truth.both(compareOperands(first, second, first_op, env), compareOperands(second, third, second_op, env));
}

const Condition = struct {
    scan: Scanner,
    env: Environment,
    depth: usize = 0,

    fn inParens(self: *Condition) ?Truth {
        self.scan.space();
        const start = self.scan.cursor;
        var iterator = tokens.Iterator{ .input = self.scan.input, .cursor = start, .atomic_urls = false };
        const token = iterator.next() orelse return null;
        const function = token.kind == .function;
        if (!function and !std.mem.eql(u8, self.scan.input[token.start..token.end], "(")) return null;
        const close = tokens.closeFunction(self.scan.input, token.end) orelse return null;
        self.scan.cursor = close + 1;
        if (function or self.depth >= 64) return .unknown;
        const inner = self.scan.input[token.end..close];
        var nested = Condition{ .scan = .{ .input = inner }, .env = self.env, .depth = self.depth + 1 };
        if (nested.evaluate(true)) |result| {
            if (nested.scan.done()) return result;
        }
        // General-enclosed syntax is unknown, not false: `not` must not make
        // an unsupported/invalid feature activate a rule.
        return featureMatches(inner, self.env);
    }

    fn evaluate(self: *Condition, allow_or: bool) ?Truth {
        if (self.scan.keyword("not")) return (self.inParens() orelse return null).invert();
        var result = self.inParens() orelse return null;
        var conjunction: ?bool = null;
        while (!self.scan.done()) {
            const is_and = self.scan.keyword("and");
            if (!is_and and !(allow_or and self.scan.keyword("or"))) return null;
            if (conjunction) |previous| {
                if (previous != is_and) return null;
            }
            conjunction = is_and;
            const next_value = self.inParens() orelse return null;
            result = if (is_and) Truth.both(result, next_value) else Truth.either(result, next_value);
        }
        return result;
    }
};

fn singleMatches(input: []const u8, env: Environment) bool {
    var condition = Condition{ .scan = .{ .input = input }, .env = env };
    if (condition.evaluate(true)) |result| {
        if (condition.scan.done()) return result == .yes;
    }
    condition.scan.cursor = 0;
    const negate = condition.scan.keyword("not");
    if (!negate) _ = condition.scan.keyword("only");
    const media_type = condition.scan.identifier() orelse return false;
    inline for (.{ "not", "only", "and", "or", "layer" }) |reserved| {
        if (syntax.identifierEquals(media_type, reserved)) return false;
    }
    var result = Truth.from(syntax.identifierEquals(media_type, "screen") or syntax.identifierEquals(media_type, "all"));
    if (!condition.scan.done()) {
        if (!condition.scan.keyword("and")) return false;
        result = Truth.both(result, condition.evaluate(false) orelse return false);
        if (!condition.scan.done()) return false;
    }
    return (if (negate) result.invert() else result) == .yes;
}

/// Evaluate a comma-separated query list synchronously. Unknown features stay
/// unknown through logical operations, then fail closed at the rule boundary.
pub fn matches(input: []const u8, env: Environment) bool {
    var start: usize = 0;
    var depth: usize = 0;
    var iterator = tokens.Iterator{ .input = input, .atomic_urls = false };
    while (iterator.next()) |token| {
        const text = input[token.start..token.end];
        if (token.kind == .function or std.mem.eql(u8, text, "(")) depth += 1;
        if (std.mem.eql(u8, text, ")")) {
            if (depth > 0) depth -= 1;
        }
        if (depth == 0 and std.mem.eql(u8, text, ",")) {
            if (singleMatches(input[start..token.start], env)) return true;
            start = token.end;
        }
    }
    return depth == 0 and singleMatches(input[start..], env);
}

fn expectQueries(env: Environment, expected: bool, queries: []const []const u8) !void {
    for (queries) |query| {
        errdefer std.debug.print("media query: {s}\n", .{query});
        try std.testing.expectEqual(expected, matches(query, env));
    }
}

test "media range comparisons include reversed operands and chained bounds" {
    const env: Environment = .{ .viewport_width_css = 1012, .viewport_height_css = 600 };
    try expectQueries(env, true, &.{
        "(width>=1012px)",            "(WIDTH <= 1012PX)",                   "(width = 1012px)",
        "(1012px <= width)",          "(1012px >= width)",                   "(1012px = width)",
        "(1000px < width)",           "(1100px > width)",                    "(width > 1000px)",
        "(width < 1100px)",           "(1000px < width <= 1012px)",          "(1012px <= width < 1280px)",
        "(1280px > width >= 1012px)", "(1012px >= width > 1000px)",          "(height = 600px)",
        "(height: 600px)",            "(599px < height < 601px)",            "(width)",
        "(height)",                   "(width>=1012px) and (width<=1279px)",
    });
    try expectQueries(env, false, &.{
        "(width > 1012px)", "(width < 1012px)",           "(1012px > width)",           "(1012px < width)",
        "(width = 1011px)", "(1012px < width <= 1280px)", "(1280px >= width > 1012px)", "(height > 600px)",
        "(height < 600px)", "(1280px < width < 1000px)",
    });
}

test "media range signed CSS numbers dimensions and initial font units" {
    const env: Environment = .{ .viewport_width_css = 96, .viewport_height_css = 0 };
    try expectQueries(env, true, &.{
        "(width = 1in)",          "(width = 2.54cm)",  "(width = 25.4mm)",    "(width = 101.6q)",
        "(width = 72pt)",         "(width = 6pc)",     "(width = 6em)",       "(width = 6rem)",
        "(width = +9.6e1px)",     "(width > -.5px)",   "(min-width: -1px)",   "not (max-width: -1px)",
        "(height = -0)",          "(height >= 0px)",   "(color > -1)",        "(monochrome = 0)",
        "(-1 < monochrome <= 0)", "(min-color: -300)", "(max-color: 100000)", "(color: 24)",
    });
    try expectQueries(env, false, &.{ "(height)", "(width <= -1px)", "(color < -1)", "(max-monochrome: -1)", "(height <= -1e-9px)", "(height = -1e-9px)" });
    try expectQueries(env, true, &.{ "(height > -1e-9px)", "(-1e-9px < height)", "not (max-height: -1e-9px)" });
}

test "media range rejects malformed comparisons and invalid typed values even under not" {
    const env: Environment = .{ .viewport_width_css = 1012 };
    const invalid = [_][]const u8{
        "width 1012px",                "width == 1012px",         "width != 1012px",   "width => 1012px",   "width =< 1012px",
        "width > = 1012px",            "width < = 1012px",        "width >< 1012px",   "width >=",          ">= 1012px",
        "1px < width > 2px",           "1px > width < 2px",       "1px = width = 2px", "width < 1px < 2px", "1px < 2px",
        "width < height",              "1px < width < 2px < 3px", "min-width >= 0px",  "width: >= 0px",     "width: 1012",
        "width > 1",                   "width > 1%",              "width >= 0 px",     "width > 1.px",      "width > 0x10px",
        "width > NaNpx",               "width > 1_000px",         "width > 1e999px",   "width > --1px",     "width > 1ch",
        "width > calc(1px)",           "width > 1px junk",        "color >= 1.0",      "color >= 1e0",      "color >= 1px",
        "prefers-color-scheme = dark", "forced-colors > none",    "unsupported >= 0",  "min-width",
    };
    for (invalid) |feature| {
        const query = try std.fmt.allocPrint(std.testing.allocator, "({s})", .{feature});
        defer std.testing.allocator.free(query);
        const negated = try std.fmt.allocPrint(std.testing.allocator, "not ({s})", .{feature});
        defer std.testing.allocator.free(negated);
        try expectQueries(env, false, &.{ query, negated });
    }
}

test "media range logical conditions retain unknown values and reject mixed operators" {
    const env: Environment = .{ .viewport_width_css = 1012, .prefers_dark = true };
    try expectQueries(env, true, &.{
        "screen and (width >= 1012px)",                         "only screen and (width = 1012px)",
        "print, (width = 1012px)",                              "(width > 1280px) or (width >= 1012px)",
        "((width >= 1012px) and (prefers-color-scheme: dark))", "not ((width < 1012px) or (width > 1279px))",
        "not (not (color))",                                    "(not (monochrome))",
        "(width 500px) or (min-width: 0)",                      "not ((unknown) and (width < 0px))",
        "not print",                                            "not unknown",
        "(unknown) or (width >= 1012px)",                       "screen and ((unknown) or (color))",
        "screen and not (width < 1012px)",                      "not print and (unknown)",
        "(width >= 1012px) garbage, (color)",                   "(width > 1280px), (color)",
    });
    try expectQueries(env, false, &.{
        "not (unknown)",                  "not ((unknown) or (monochrome))", "not (width > 0px) and (color)",
        "(color) and (color) or (color)", "(color) or (color) and (color)",  "(color) and not (monochrome)",
        "only (color)",                   "not not (color)",                 "screen and (color) or (color)",
        "not all and (width >= 1012px)",  "(width >= 0px) and",              "(width >= 0px) or",
        "not (width >= 0px) junk",        "(width >= 0px",                   "(width >= 0px))",
        "",                               "only not screen",                 "or",
        "not layer",                      "(width >= 0px) and(color)",       "not(color)",
    });
}

test "media range comments escapes and query-list delimiters respect token boundaries" {
    const env: Environment = .{ .viewport_width_css = 1012 };
    try expectQueries(env, true, &.{
        "/* (,) */ (width/**/>=/**/1012px)", "(width>/**/=1012px)",
        "(w\\69 dth >= 1012p\\78)",          "(width >= 1012px)/**/and/**/(color)",
        "unknown(\"(,)\"), (color)",         "(unknown: ',') or (color)",
    });
    try expectQueries(env, false, &.{
        "(wid/**/th >= 1012px)", "(width >/**/ = 1012px)", "(width >= 1012/**/px)",
        "not unknown(\"(,)\")",  "not (width: '1012px')",  "(unknown, (color))",
    });
}

test "media range equality and strict complements share the zoom boundary" {
    for ([_]f64{ 1011.99, 1012, 1012.00000001, 1012.01 }) |width| {
        const env: Environment = .{ .viewport_width_css = width };
        try std.testing.expect(matches("(width <= 1012px)", env) != matches("(width > 1012px)", env));
        try std.testing.expect(matches("(width >= 1012px)", env) != matches("(width < 1012px)", env));
        try std.testing.expectEqual(matches("(width: 1012px)", env), matches("(width = 1012px)", env));
        try std.testing.expectEqual(matches("(min-width: 1012px)", env), matches("(width >= 1012px)", env));
    }
    try expectQueries(.{}, false, &.{ "(width >= 0px)", "(height < 1000px)", "(width)", "(height)" });
    try expectQueries(.{ .viewport_width_css = std.math.nan(f64) }, false, &.{"(width >= 0px)"});
}

test "media range nested conditions have bounded stack depth" {
    var input: [1024]u8 = undefined;
    @memset(input[0..500], '(');
    @memcpy(input[500..505], "color");
    @memset(input[505..1005], ')');
    try std.testing.expect(!matches(input[0..1005], .{}));
}
