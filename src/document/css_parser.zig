//! Parser for Zibra's intentionally small CSS subset.
//!
//! Property names and declared values in returned rules normally borrow the
//! input stylesheet; shorthand-generated property names and defaults are
//! static slices. Selectors own their normalized names, selector-sequence lists,
//! and descendant-chain lists. The stylesheet therefore must outlive its rules,
//! and each owned rule must be deinitialized.

const std = @import("std");
const selector_mod = @import("selector.zig");
const Selector = selector_mod.Selector;
const SimpleSelector = selector_mod.SimpleSelector;
const TagSelector = selector_mod.TagSelector;
const ClassSelector = selector_mod.ClassSelector;
const SequenceSelector = selector_mod.SequenceSelector;
const SelectorSequence = selector_mod.SelectorSequence;
const DescendantSelector = selector_mod.DescendantSelector;

pub const CSSParser = @This();

string: []const u8,
pos: usize,
prefers_dark: bool,

pub fn init(allocator: std.mem.Allocator, string: []const u8, prefers_dark: bool) !*CSSParser {
    const parser = try allocator.create(CSSParser);
    parser.* = CSSParser{
        .string = string,
        .pos = 0,
        .prefers_dark = prefers_dark,
    };
    return parser;
}

pub fn deinit(self: *CSSParser, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

fn whitespace(self: *CSSParser) void {
    while (self.pos < self.string.len and std.ascii.isWhitespace(self.string[self.pos])) {
        self.pos += 1;
    }
}

fn word(self: *CSSParser) ![]const u8 {
    const start = self.pos;
    while (self.pos < self.string.len) {
        const c = self.string[self.pos];
        if (std.ascii.isAlphanumeric(c) or c == '#' or c == '-' or c == '.' or c == '%') {
            self.pos += 1;
        } else {
            break;
        }
    }
    if (self.pos <= start) {
        return error.InvalidWord;
    }
    return self.string[start..self.pos];
}

fn literal(self: *CSSParser, lit: u8) !void {
    if (self.pos >= self.string.len or self.string[self.pos] != lit) {
        return error.InvalidLiteral;
    }
    self.pos += 1;
}

/// Read a CSS value until `;` or `}`, trimming trailing whitespace
fn value(self: *CSSParser) ![]const u8 {
    const start = self.pos;
    while (self.pos < self.string.len) {
        const c = self.string[self.pos];
        if (c == ';' or c == '}') {
            break;
        }
        self.pos += 1;
    }
    if (self.pos <= start) {
        return error.InvalidValue;
    }
    // Trim trailing whitespace
    var end = self.pos;
    while (end > start and std.ascii.isWhitespace(self.string[end - 1])) {
        end -= 1;
    }
    return self.string[start..end];
}

fn pair(self: *CSSParser) !struct { property: []const u8, value: []const u8 } {
    const property = try self.word();
    self.whitespace();
    try self.literal(':');
    self.whitespace();
    const val = try self.value();
    return .{ .property = property, .value = val };
}

const FontShorthand = struct {
    style: []const u8 = "normal",
    weight: []const u8 = "normal",
    size: []const u8,
    family: []const u8,
};

fn isSupportedFontSize(font_size: []const u8) bool {
    const number = if (std.mem.endsWith(u8, font_size, "px"))
        font_size[0 .. font_size.len - 2]
    else if (std.mem.endsWith(u8, font_size, "%"))
        font_size[0 .. font_size.len - 1]
    else
        return false;
    if (number.len == 0) return false;
    const parsed = std.fmt.parseFloat(f64, number) catch return false;
    return std.math.isFinite(parsed) and parsed >= 0;
}

/// Parse the subset of the `font` shorthand represented by Zibra's computed
/// style: optional `italic` and `bold`, followed by a required px/percentage
/// size and a required family or fallback list. Unsupported syntax invalidates
/// the declaration instead of applying only part of it.
fn parseFontShorthand(declaration_value: []const u8) ?FontShorthand {
    var result = FontShorthand{ .size = undefined, .family = undefined };
    var saw_style = false;
    var saw_weight = false;
    var pos: usize = 0;

    while (pos < declaration_value.len) {
        while (pos < declaration_value.len and std.ascii.isWhitespace(declaration_value[pos])) : (pos += 1) {}
        if (pos == declaration_value.len) return null;

        const token_start = pos;
        while (pos < declaration_value.len and !std.ascii.isWhitespace(declaration_value[pos])) : (pos += 1) {}
        const token = declaration_value[token_start..pos];

        if (isSupportedFontSize(token)) {
            const family = std.mem.trim(u8, declaration_value[pos..], " \t\r\n");
            if (family.len == 0) return null;
            result.size = token;
            result.family = family;
            return result;
        }

        if (std.ascii.eqlIgnoreCase(token, "italic")) {
            if (saw_style) return null;
            result.style = "italic";
            saw_style = true;
        } else if (std.ascii.eqlIgnoreCase(token, "bold")) {
            if (saw_weight) return null;
            result.weight = "bold";
            saw_weight = true;
        } else if (!std.ascii.eqlIgnoreCase(token, "normal")) {
            return null;
        }
    }
    return null;
}

/// Apply one declaration in source order. Shorthands expand here so inline
/// attributes and stylesheet rules share identical precedence behavior.
fn putDeclaration(
    map: *std.StringHashMap([]const u8),
    property: []const u8,
    declaration_value: []const u8,
) !void {
    if (std.mem.eql(u8, property, "font")) {
        const font = parseFontShorthand(declaration_value) orelse return;
        try map.put("font-style", font.style);
        try map.put("font-weight", font.weight);
        try map.put("font-size", font.size);
        try map.put("font-family", font.family);
        return;
    }
    try map.put(property, declaration_value);
}

pub fn body(self: *CSSParser, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer map.deinit();
    // Stop at closing brace
    while (self.pos < self.string.len and self.string[self.pos] != '}') {
        // Try to parse a property-value pair, but catch any errors
        const result = self.pair() catch {
            // If parsing failed, skip to the next semicolon or closing brace
            const why = self.ignoreUntil(";}");
            if (why) |char| {
                if (char == ';') {
                    _ = self.literal(';') catch {};
                    self.whitespace();
                } else {
                    // Hit closing brace, stop parsing
                    break;
                }
            } else {
                // Reached end of string without finding a semicolon or brace
                break;
            }
            continue;
        };

        // Values borrow the parser input; shorthand defaults are static slices.
        try putDeclaration(&map, result.property, result.value);
        self.whitespace();
        _ = self.literal(';') catch {};
        self.whitespace();
    }
    return map;
}

fn ignoreUntil(self: *CSSParser, chars: []const u8) ?u8 {
    while (self.pos < self.string.len) {
        const current_char = self.string[self.pos];
        for (chars) |c| {
            if (current_char == c) {
                return current_char;
            }
        }
        self.pos += 1;
    }
    return null;
}

fn findMatchingBrace(self: *CSSParser, start: usize) ?usize {
    if (start >= self.string.len or self.string[start] != '{') return null;
    var depth: i32 = 0;
    var i = start;
    while (i < self.string.len) : (i += 1) {
        const c = self.string[i];
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn prefersColorSchemeMatch(self: *CSSParser, allocator: std.mem.Allocator, prelude: []const u8) ?bool {
    const lower = std.ascii.allocLowerString(allocator, prelude) catch return null;
    defer allocator.free(lower);

    if (std.mem.indexOf(u8, lower, "prefers-color-scheme") == null) return null;

    const has_dark = std.mem.indexOf(u8, lower, "dark") != null;
    const has_light = std.mem.indexOf(u8, lower, "light") != null;

    if (has_dark and has_light) return self.prefers_dark;
    if (has_dark) return self.prefers_dark;
    if (has_light) return !self.prefers_dark;
    return null;
}

/// Parse a tag/class selector or a whitespace-separated descendant selector.
/// ID, attribute, and combinator selectors are not yet supported.
pub fn selector(self: *CSSParser, allocator: std.mem.Allocator) !Selector {
    var selectors = std.ArrayList(SimpleSelector).empty;
    errdefer {
        for (selectors.items) |*simple| simple.deinit(allocator);
        selectors.deinit(allocator);
    }

    var first = try self.simpleSelector(allocator);
    selectors.append(allocator, first) catch |err| {
        first.deinit(allocator);
        return err;
    };
    self.whitespace();

    // Continue parsing descendant selectors until we hit '{'
    while (self.pos < self.string.len and self.string[self.pos] != '{') {
        var descendant = try self.simpleSelector(allocator);
        selectors.append(allocator, descendant) catch |err| {
            descendant.deinit(allocator);
            return err;
        };

        self.whitespace();
    }

    if (selectors.items.len == 1) {
        const simple = selectors.items[0];
        selectors.deinit(allocator);
        return simple.intoSelector();
    }

    return .{ .descendant = DescendantSelector.take(&selectors) };
}

fn simpleSelector(self: *CSSParser, allocator: std.mem.Allocator) !SimpleSelector {
    const raw = try self.word();
    if (std.mem.indexOfAny(u8, raw, "#%") != null) return error.InvalidSelector;

    var selectors = std.ArrayList(SequenceSelector).empty;
    errdefer {
        for (selectors.items) |*part| part.deinit(allocator);
        selectors.deinit(allocator);
    }

    var cursor: usize = 0;
    if (raw[0] != '.') {
        const tag_end = std.mem.indexOfScalar(u8, raw, '.') orelse raw.len;
        const lower_tag = try std.ascii.allocLowerString(allocator, raw[0..tag_end]);
        try appendSequenceSelector(
            allocator,
            &selectors,
            .{ .tag = TagSelector.init(lower_tag) },
        );
        cursor = tag_end;
    }

    while (cursor < raw.len) {
        if (raw[cursor] != '.') return error.InvalidSelector;
        const class_start = cursor + 1;
        if (class_start >= raw.len) return error.InvalidSelector;

        const remaining = raw[class_start..];
        const class_len = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        if (class_len == 0) return error.InvalidSelector;

        try appendSequenceSelector(
            allocator,
            &selectors,
            .{ .class = ClassSelector.init(try allocator.dupe(u8, remaining[0..class_len])) },
        );
        cursor = class_start + class_len;
    }

    if (selectors.items.len == 1) {
        const part = selectors.items[0];
        selectors.deinit(allocator);
        return part.intoSimpleSelector();
    }
    return .{ .sequence = SelectorSequence.take(&selectors) };
}

fn appendSequenceSelector(
    allocator: std.mem.Allocator,
    selectors: *std.ArrayList(SequenceSelector),
    part: SequenceSelector,
) !void {
    var owned_part = part;
    selectors.append(allocator, owned_part) catch |err| {
        owned_part.deinit(allocator);
        return err;
    };
}

/// CSS Rule - a selector and its associated property-value pairs
pub const CSSRule = struct {
    selector: Selector,
    properties: std.StringHashMap([]const u8),
    owned: bool = true,

    pub fn deinit(self: *CSSRule, allocator: std.mem.Allocator) void {
        // Free the selector's allocated memory (pass pointer since deinit expects *Selector)
        Selector.deinit(&self.selector, allocator);

        // The map owns its table; property/value slices borrow the stylesheet
        // or are static shorthand expansion strings.
        self.properties.deinit();
    }

    /// Get the cascade priority of this rule
    /// Used for sorting - more specific selectors override less specific ones
    pub fn cascadePriority(self: CSSRule) u32 {
        return self.selector.priority();
    }
};

/// Parse a full CSS file into a list of rules
pub fn parse(self: *CSSParser, allocator: std.mem.Allocator) ![]CSSRule {
    var rules = std.ArrayList(CSSRule).empty;
    errdefer {
        for (rules.items) |*rule| {
            rule.deinit(allocator);
        }
        rules.deinit(allocator);
    }

    while (self.pos < self.string.len) {
        self.whitespace();
        if (self.pos >= self.string.len) break;

        if (self.string[self.pos] == '@') {
            if (std.mem.startsWith(u8, self.string[self.pos..], "@media")) {
                const prelude_start = self.pos + "@media".len;
                const brace_idx = std.mem.indexOfPos(u8, self.string, prelude_start, "{") orelse break;
                const prelude = self.string[prelude_start..brace_idx];
                const block_end = self.findMatchingBrace(brace_idx) orelse break;

                if (self.prefersColorSchemeMatch(allocator, prelude)) |matches| {
                    if (matches) {
                        var media_parser = try CSSParser.init(
                            allocator,
                            self.string[brace_idx + 1 .. block_end],
                            self.prefers_dark,
                        );
                        defer media_parser.deinit(allocator);

                        const media_rules = try media_parser.parse(allocator);
                        var media_rules_transferred = false;
                        defer {
                            if (!media_rules_transferred) {
                                for (media_rules) |*rule| {
                                    rule.deinit(allocator);
                                }
                            }
                            allocator.free(media_rules);
                        }

                        try rules.ensureUnusedCapacity(allocator, media_rules.len);
                        for (media_rules) |rule| {
                            rules.appendAssumeCapacity(rule);
                        }
                        media_rules_transferred = true;
                    }
                }

                self.pos = block_end + 1;
                continue;
            }

            const why = self.ignoreUntil(";{") orelse break;
            if (why == ';') {
                _ = self.literal(';') catch {};
                self.whitespace();
                continue;
            }
            if (why == '{') {
                const block_end = self.findMatchingBrace(self.pos) orelse break;
                self.pos = block_end + 1;
                continue;
            }
        }

        // Try to parse a complete rule, but catch errors and skip the rule
        const rule_result = blk: {
            // Parse selector
            const sel = self.selector(allocator) catch {
                // If selector parsing failed, skip to closing brace
                const why = self.ignoreUntil("}");
                if (why) |char| {
                    if (char == '}') {
                        _ = self.literal('}') catch {};
                        self.whitespace();
                    }
                } else {
                    // Reached end of string
                    break;
                }
                continue;
            };

            // Expect '{'
            self.literal('{') catch {
                // Free the selector before skipping
                var sel_mut = sel;
                sel_mut.deinit(allocator);

                // Skip to closing brace
                const why = self.ignoreUntil("}");
                if (why) |char| {
                    if (char == '}') {
                        _ = self.literal('}') catch {};
                        self.whitespace();
                    }
                } else {
                    break;
                }
                continue;
            };
            self.whitespace();

            // Parse properties
            const properties = self.body(allocator) catch {
                // Free the selector before skipping
                var sel_mut = sel;
                sel_mut.deinit(allocator);

                // Skip to closing brace
                const why = self.ignoreUntil("}");
                if (why) |char| {
                    if (char == '}') {
                        _ = self.literal('}') catch {};
                        self.whitespace();
                    }
                } else {
                    break;
                }
                continue;
            };

            // Expect '}'
            self.literal('}') catch {
                // Free the selector and properties before skipping
                var sel_mut = sel;
                sel_mut.deinit(allocator);
                var props = properties;
                props.deinit();

                // Already at end or past it, just continue
                continue;
            };

            break :blk CSSRule{
                .selector = sel,
                .properties = properties,
                .owned = true,
            };
        };

        // Add rule if we successfully parsed one
        rules.append(allocator, rule_result) catch |err| {
            var owned_rule = rule_result;
            owned_rule.deinit(allocator);
            return err;
        };
    }

    return rules.toOwnedSlice(allocator);
}
