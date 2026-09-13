//! Borrowed structural CSS rules and declarations, independent of selectors,
//! properties, DOM and media evaluation. Iterators preserve source ranges and
//! declaration order; semantic consumers decide which constructs to support.

const std = @import("std");
const syntax = @import("css_syntax.zig");

pub const Range = struct {
    start: usize,
    end: usize,

    /// Borrow the range from the exact source used by its originating iterator.
    pub fn slice(self: Range, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Rule = struct {
    source: Range,
    /// Null for a qualified rule; at-rule names exclude the leading @.
    name: ?Range,
    prelude: Range,
    /// Excludes braces. An unfinished block extends to EOF.
    block: ?Range,
    closed: bool,
};

pub const RuleIterator = struct {
    input: []const u8,
    pos: usize = 0,
    /// Only a stylesheet's outermost list ignores HTML CDO/CDC tokens.
    top_level: bool = true,

    /// Returns borrowed structure, including unknown at-rules. No allocations.
    /// Excessive component nesting discards the unfinished rule and remainder
    /// of this input. Previously returned rules remain valid.
    pub fn next(self: *RuleIterator) ?Rule {
        while (true) {
            syntax.skipWhitespaceAndComments(self.input, &self.pos);
            if (self.pos == self.input.len) return null;
            if (self.top_level and std.mem.startsWith(u8, self.input[self.pos..], "<!--")) {
                self.pos += 4;
            } else if (self.top_level and std.mem.startsWith(u8, self.input[self.pos..], "-->")) {
                self.pos += 3;
            } else break;
        }
        const start = self.pos;
        var name: ?Range = null;
        if (self.input[self.pos] == '@') {
            var name_end = self.pos + 1;
            if (syntax.consumeIdentifier(self.input, &name_end) != null) {
                name = .{ .start = self.pos + 1, .end = name_end };
                self.pos = name_end;
            }
        }
        const prelude_start = self.pos;
        const delimiter = syntax.scanToTopLevel(self.input, self.pos, if (name != null) ";{" else "{");
        self.pos = delimiter.end;
        if (delimiter.exhausted) return null;
        var rule = Rule{
            .source = .{ .start = start, .end = self.pos },
            .name = name,
            .prelude = .{ .start = prelude_start, .end = self.pos },
            .block = null,
            .closed = false,
        };
        if (delimiter.delimiter == '{') {
            const block_start = self.pos + 1;
            const end = syntax.scanToTopLevel(self.input, block_start, "}");
            self.pos = end.end + @as(usize, if (end.delimiter != null) 1 else 0);
            if (end.exhausted) return null;
            rule.block = .{ .start = block_start, .end = end.end };
            rule.closed = end.delimiter != null;
        } else if (name == null) {
            return null;
        } else if (delimiter.delimiter == ';') {
            self.pos += 1;
            rule.closed = true;
        }
        rule.source.end = self.pos;
        return rule;
    }
};

pub const Declaration = struct {
    source: Range,
    name: Range,
    /// Source spelling, including priority suffix and edge trivia. Property
    /// validation and !important interpretation belong to css_declarations.
    value: Range,
};

pub const DeclarationIterator = struct {
    input: []const u8,
    pos: usize = 0,

    /// Returns declarations in source order without folding duplicate names.
    /// Ignores unknown at-rules as whole structures and recovers invalid
    /// declarations at balanced separators. A closing brace remains unconsumed
    /// for callers parsing a surrounding block. No returned slice is owned.
    pub fn next(self: *DeclarationIterator) ?Declaration {
        while (self.pos < self.input.len) {
            syntax.skipWhitespaceAndComments(self.input, &self.pos);
            if (self.pos == self.input.len or self.input[self.pos] == '}') return null;
            if (self.input[self.pos] == ';') {
                self.pos += 1;
                continue;
            }
            const start = self.pos;
            if (self.input[self.pos] == '@') {
                var name_end = self.pos + 1;
                if (syntax.consumeIdentifier(self.input, &name_end) != null) {
                    var rules = RuleIterator{ .input = self.input, .pos = self.pos, .top_level = false };
                    const rule = rules.next();
                    self.pos = rules.pos;
                    if (rule == null) return null;
                    continue;
                }
                // Probing bare @ as a qualified rule would repeatedly rescan
                // the remaining input in a declaration list like @;@;@;.
            }
            const name = syntax.consumeIdentifier(self.input, &self.pos);
            const name_end = self.pos;
            syntax.skipWhitespaceAndComments(self.input, &self.pos);
            const valid = name != null and self.pos < self.input.len and self.input[self.pos] == ':';
            if (valid) self.pos += 1;
            const value_start = self.pos;
            const end = syntax.scanToTopLevel(self.input, self.pos, ";}");
            self.pos = end.end + @as(usize, if (end.delimiter == ';') 1 else 0);
            if (end.exhausted) return null;
            if (valid) return .{
                .source = .{ .start = start, .end = end.end },
                .name = .{ .start = start, .end = name_end },
                .value = .{ .start = value_start, .end = end.end },
            };
        }
        return null;
    }
};

pub const StyleItem = union(enum) { declaration: Declaration, rule: Rule };

/// Iterates interleaved declarations and nested rules in an ordinary style
/// block. Custom-property curly blocks remain values; qualified selector
/// preludes such as div:hover are retried as rules at their opening brace.
pub const StyleBlockIterator = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn next(self: *StyleBlockIterator) ?StyleItem {
        while (self.pos < self.input.len) {
            syntax.skipWhitespaceAndComments(self.input, &self.pos);
            if (self.pos == self.input.len or self.input[self.pos] == '}') return null;
            if (self.input[self.pos] == ';') {
                self.pos += 1;
                continue;
            }
            const start = self.pos;
            var cursor = start;
            if (syntax.consumeIdentifier(self.input, &cursor)) |_| {
                const name_end = cursor;
                syntax.skipWhitespaceAndComments(self.input, &cursor);
                if (cursor < self.input.len and self.input[cursor] == ':') {
                    const value_start = cursor + 1;
                    var decoded = @import("css_tokenizer.zig").Decoder{ .input = self.input[start..name_end] };
                    const custom = decoded.next() == '-' and decoded.next() == '-';
                    const end = syntax.scanToTopLevel(self.input, value_start, if (custom) ";}" else ";{}");
                    if (end.exhausted) {
                        self.pos = self.input.len;
                        return null;
                    }
                    if (end.delimiter != '{') {
                        self.pos = end.end + @intFromBool(end.delimiter == ';');
                        return .{ .declaration = .{
                            .source = .{ .start = start, .end = end.end },
                            .name = .{ .start = start, .end = name_end },
                            .value = .{ .start = value_start, .end = end.end },
                        } };
                    }
                }
            }
            var rules = RuleIterator{ .input = self.input, .pos = start, .top_level = false };
            const rule = rules.next();
            self.pos = rules.pos;
            return if (rule) |item| .{ .rule = item } else null;
        }
        return null;
    }
};

test "style block syntax preserves declarations around nested rules and custom blocks" {
    const source = "color:red; div:hover {color:blue} --x:{a:b}; @supports (color:red) {color:green} width:2px";
    var iterator = StyleBlockIterator{ .input = source };
    try std.testing.expectEqualStrings("red", iterator.next().?.declaration.value.slice(source));
    try std.testing.expectEqualStrings("div:hover ", iterator.next().?.rule.prelude.slice(source));
    try std.testing.expectEqualStrings("{a:b}", iterator.next().?.declaration.value.slice(source));
    try std.testing.expectEqualStrings("supports", iterator.next().?.rule.name.?.slice(source));
    try std.testing.expectEqualStrings("2px", iterator.next().?.declaration.value.slice(source));
    try std.testing.expect(iterator.next() == null);
}

test "structural CSS rules retain unknown blocks and EOF ranges" {
    const source = "<!-- @future ([a;{}]) { ignored: '}'; } p { color:green";
    var rules = RuleIterator{ .input = source };
    const unknown = rules.next().?;
    try std.testing.expectEqualStrings("future", unknown.name.?.slice(source));
    try std.testing.expect(unknown.closed);
    try std.testing.expectEqualStrings(" ignored: '}'; ", unknown.block.?.slice(source));
    const qualified = rules.next().?;
    try std.testing.expect(qualified.name == null);
    try std.testing.expectEqualStrings("p ", qualified.prelude.slice(source));
    try std.testing.expectEqualStrings(" color:green", qualified.block.?.slice(source));
    try std.testing.expect(!qualified.closed);
    try std.testing.expect(rules.next() == null);
}

test "structural declarations preserve duplicates and skip entire at-rules" {
    const source = "color:red; @future [a;{}] { nested: { a:b; }; } @;@;@; color:green; --x:[a;{b:c;}]; width:12px";
    var declarations = DeclarationIterator{ .input = source };
    for ([_][]const u8{ "red", "green", "[a;{b:c;}]", "12px" }) |expected| {
        const declaration = declarations.next().?;
        try std.testing.expectEqualStrings(expected, declaration.value.slice(source));
    }
    try std.testing.expect(declarations.next() == null);
}

test "structural syntax quarantines excessive nesting without recursion" {
    var bytes: [syntax.max_component_depth + 4]u8 = undefined;
    @memset(&bytes, '(');
    bytes[0] = 'p';
    bytes[1] = '{';
    var rules = RuleIterator{ .input = &bytes };
    try std.testing.expect(rules.next() == null);
    try std.testing.expectEqual(bytes.len, rules.pos);
}

test "nested style blocks keep escaped custom-property braces inside declarations" {
    const source = "\\2d -data:{a:{b:c}}; div:hover{color:green} color:blue";
    var items = StyleBlockIterator{ .input = source };
    const custom = items.next().?.declaration;
    try std.testing.expectEqualStrings("{a:{b:c}}", custom.value.slice(source));
    const nested = items.next().?.rule;
    try std.testing.expectEqualStrings("div:hover", nested.prelude.slice(source));
    try std.testing.expectEqualStrings("blue", items.next().?.declaration.value.slice(source));
    try std.testing.expect(items.next() == null);
}
