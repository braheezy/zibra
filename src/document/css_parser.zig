//! Parser for Zibra's intentionally small CSS subset.
//!
//! Property names and declared values in returned rules normally borrow the
//! input stylesheet; shorthand-generated property names and defaults are
//! static slices. Selectors own their normalized names, selector-sequence lists,
//! descendant-chain lists, and relational-selector components. The stylesheet
//! therefore must outlive its rules, and each owned rule must be deinitialized.

const std = @import("std");
const selector_mod = @import("selector.zig");
const Selector = selector_mod.Selector;
const SimpleSelector = selector_mod.SimpleSelector;
const TagSelector = selector_mod.TagSelector;
const ClassSelector = selector_mod.ClassSelector;
const SequenceSelector = selector_mod.SequenceSelector;
const SelectorSequence = selector_mod.SelectorSequence;
const HasSelector = selector_mod.HasSelector;
const DescendantSelector = selector_mod.DescendantSelector;

pub const CSSParser = @This();

pub const IMPORTANT_PRIORITY: u32 = 10_000;
pub const INLINE_STYLE_PRIORITY: u32 = 1_000;
pub const MatchContext = selector_mod.MatchContext;
pub const HasMatchCache = selector_mod.HasMatchCache;

/// One parsed property value. The value borrows the stylesheet or inline-style
/// buffer; `important` is declaration-local cascade metadata.
pub const Declaration = struct {
    value: []const u8,
    important: bool = false,

    pub fn priority(self: Declaration, base_priority: u32) u32 {
        return base_priority + if (self.important) IMPORTANT_PRIORITY else 0;
    }
};

pub const DeclarationMap = std.StringHashMap(Declaration);

/// One declaration block within an `@keyframes` rule. Selectors are normalized
/// to a 0...1 offset; declaration values borrow the stylesheet buffer.
pub const Keyframe = struct {
    offset: f64,
    properties: DeclarationMap,

    pub fn deinit(self: *Keyframe) void {
        self.properties.deinit();
    }
};

/// A named keyframe rule. The name and declaration values borrow the
/// stylesheet; the frame slice and declaration maps are owned.
pub const KeyframesRule = struct {
    name: []const u8,
    frames: []Keyframe,

    pub fn deinit(self: *KeyframesRule, allocator: std.mem.Allocator) void {
        for (self.frames) |*frame| frame.deinit();
        allocator.free(self.frames);
    }

    pub fn frameAt(self: *const KeyframesRule, offset: f64) ?*const Keyframe {
        var result: ?*const Keyframe = null;
        for (self.frames) |*frame| {
            if (frame.offset == offset) result = frame;
        }
        return result;
    }
};

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

fn parseDeclarationValue(raw_value: []const u8) ?Declaration {
    const bang = std.mem.lastIndexOfScalar(u8, raw_value, '!') orelse {
        return .{ .value = raw_value };
    };
    const suffix = std.mem.trim(u8, raw_value[bang + 1 ..], " \t\r\n");
    if (!std.ascii.eqlIgnoreCase(suffix, "important")) {
        return .{ .value = raw_value };
    }

    const value_without_priority = std.mem.trimEnd(u8, raw_value[0..bang], " \t\r\n");
    if (value_without_priority.len == 0) return null;
    return .{ .value = value_without_priority, .important = true };
}

fn putLonghand(map: *DeclarationMap, property: []const u8, declaration: Declaration) !void {
    if (map.get(property)) |existing| {
        // Within one declaration block, an earlier important longhand cannot
        // be reset by a later normal longhand or shorthand expansion.
        if (existing.important and !declaration.important) return;
    }
    try map.put(property, declaration);
}

/// Apply one declaration in source order. Shorthands expand here so inline
/// attributes and stylesheet rules share identical precedence behavior and
/// every generated longhand retains the shorthand's importance.
fn putDeclaration(
    map: *DeclarationMap,
    property: []const u8,
    raw_value: []const u8,
) !void {
    const declaration = parseDeclarationValue(raw_value) orelse return;
    if (std.mem.eql(u8, property, "font")) {
        const font = parseFontShorthand(declaration.value) orelse return;
        try putLonghand(map, "font-style", .{ .value = font.style, .important = declaration.important });
        try putLonghand(map, "font-weight", .{ .value = font.weight, .important = declaration.important });
        try putLonghand(map, "font-size", .{ .value = font.size, .important = declaration.important });
        try putLonghand(map, "font-family", .{ .value = font.family, .important = declaration.important });
        return;
    }
    try putLonghand(map, property, declaration);
}

pub fn body(self: *CSSParser, allocator: std.mem.Allocator) !DeclarationMap {
    var map = DeclarationMap.init(allocator);
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

fn parseKeyframeOffset(raw: []const u8) ?f64 {
    const token = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(token, "from")) return 0;
    if (std.ascii.eqlIgnoreCase(token, "to")) return 1;
    if (!std.mem.endsWith(u8, token, "%")) return null;
    const percentage = std.fmt.parseFloat(f64, token[0 .. token.len - 1]) catch return null;
    if (!std.math.isFinite(percentage) or percentage < 0 or percentage > 100) return null;
    return percentage / 100.0;
}

fn cloneDeclarationMap(allocator: std.mem.Allocator, source: *const DeclarationMap) !DeclarationMap {
    var result = DeclarationMap.init(allocator);
    errdefer result.deinit();
    try result.ensureUnusedCapacity(source.count());
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        result.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }
    return result;
}

fn parseKeyframesRule(self: *CSSParser, allocator: std.mem.Allocator) !KeyframesRule {
    self.pos += "@keyframes".len;
    self.whitespace();
    const name = try self.word();
    self.whitespace();
    try self.literal('{');
    self.whitespace();

    var frames = std.ArrayList(Keyframe).empty;
    errdefer {
        for (frames.items) |*frame| frame.deinit();
        frames.deinit(allocator);
    }

    while (self.pos < self.string.len and self.string[self.pos] != '}') {
        const selector_start = self.pos;
        const brace = std.mem.indexOfScalarPos(u8, self.string, self.pos, '{') orelse
            return error.InvalidKeyframes;
        const selector_text = self.string[selector_start..brace];
        self.pos = brace + 1;
        self.whitespace();

        var declarations = try self.body(allocator);
        var declarations_owned = true;
        defer if (declarations_owned) declarations.deinit();
        try self.literal('}');
        self.whitespace();

        var selectors = std.mem.splitScalar(u8, selector_text, ',');
        var accepted: usize = 0;
        while (selectors.next()) |selector_text_part| {
            const offset = parseKeyframeOffset(selector_text_part) orelse continue;
            const properties = if (accepted == 0)
                declarations
            else
                try cloneDeclarationMap(allocator, &declarations);
            if (accepted == 0) declarations_owned = false;
            var frame = Keyframe{ .offset = offset, .properties = properties };
            frames.append(allocator, frame) catch |err| {
                frame.deinit();
                return err;
            };
            accepted += 1;
        }
    }
    try self.literal('}');
    if (frames.items.len == 0) return error.InvalidKeyframes;
    return .{ .name = name, .frames = try frames.toOwnedSlice(allocator) };
}

fn startsWithKeyframesRule(self: *const CSSParser) bool {
    const keyword = "@keyframes";
    if (self.string.len - self.pos < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(self.string[self.pos .. self.pos + keyword.len], keyword)) return false;
    const next = self.pos + keyword.len;
    return next == self.string.len or std.ascii.isWhitespace(self.string[next]);
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

/// Parse a tag/class selector, `:has(...)` relational selector, or a
/// whitespace-separated descendant selector. ID, attribute, and other
/// combinator selectors are not yet supported.
pub fn selector(self: *CSSParser, allocator: std.mem.Allocator) !Selector {
    var selectors = std.ArrayList(SimpleSelector).empty;
    errdefer {
        for (selectors.items) |*simple| simple.deinit(allocator);
        selectors.deinit(allocator);
    }

    var first = try self.relationalSelector(allocator);
    selectors.append(allocator, first) catch |err| {
        first.deinit(allocator);
        return err;
    };

    // Descendant combinators require whitespace between selector components.
    while (self.pos < self.string.len) {
        const before_whitespace = self.pos;
        self.whitespace();
        if (self.pos >= self.string.len or self.string[self.pos] == '{') break;
        if (self.pos == before_whitespace) return error.InvalidSelector;

        var descendant = try self.relationalSelector(allocator);
        selectors.append(allocator, descendant) catch |err| {
            descendant.deinit(allocator);
            return err;
        };
    }

    if (selectors.items.len == 1) {
        const simple = selectors.items[0];
        selectors.deinit(allocator);
        return simple.intoSelector();
    }

    return .{ .descendant = DescendantSelector.take(&selectors) };
}

/// Parse a selector anchored to the current element and optionally constrained
/// by a matching strict descendant. Zibra's current selector subset accepts a
/// tag/class sequence on each side of `:has`.
fn relationalSelector(self: *CSSParser, allocator: std.mem.Allocator) !SimpleSelector {
    var ancestor = try self.simpleSelector(allocator);
    errdefer ancestor.deinit(allocator);

    if (self.pos >= self.string.len or self.string[self.pos] != ':') return ancestor;

    try self.literal(':');
    const pseudo_class = try self.word();
    if (!std.ascii.eqlIgnoreCase(pseudo_class, "has")) return error.InvalidSelector;
    try self.literal('(');
    self.whitespace();

    var descendant = try self.simpleSelector(allocator);
    errdefer descendant.deinit(allocator);
    self.whitespace();
    try self.literal(')');

    return .{ .has = try HasSelector.init(allocator, ancestor, descendant) };
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
    properties: DeclarationMap,
    owned: bool = true,

    pub fn deinit(self: *CSSRule, allocator: std.mem.Allocator) void {
        // Free the selector's allocated memory (pass pointer since deinit expects *Selector)
        Selector.deinit(&self.selector, allocator);

        // The map owns its table; declaration values borrow the stylesheet or
        // are static shorthand expansion strings.
        self.properties.deinit();
    }

    /// Get the cascade priority of this rule
    /// Used for sorting - more specific selectors override less specific ones
    pub fn cascadePriority(self: CSSRule) u32 {
        return self.selector.priority();
    }
};

/// Parse a full CSS file into a list of selector rules, discarding keyframes.
/// Browser document loading uses `parseWithKeyframes` to retain both products.
pub fn parse(self: *CSSParser, allocator: std.mem.Allocator) ![]CSSRule {
    var keyframes = std.ArrayList(KeyframesRule).empty;
    defer {
        for (keyframes.items) |*rule| rule.deinit(allocator);
        keyframes.deinit(allocator);
    }
    return self.parseWithKeyframes(allocator, &keyframes);
}

/// Parse selector rules and append named keyframes to caller-owned storage.
/// Both products borrow the same stylesheet input buffer.
pub fn parseWithKeyframes(
    self: *CSSParser,
    allocator: std.mem.Allocator,
    keyframes: *std.ArrayList(KeyframesRule),
) ![]CSSRule {
    const keyframes_start = keyframes.items.len;
    errdefer {
        for (keyframes.items[keyframes_start..]) |*rule| rule.deinit(allocator);
        keyframes.shrinkRetainingCapacity(keyframes_start);
    }
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
            if (self.startsWithKeyframesRule()) {
                const brace_idx = std.mem.indexOfScalarPos(u8, self.string, self.pos, '{') orelse break;
                const block_end = self.findMatchingBrace(brace_idx) orelse break;
                var keyframes_rule = self.parseKeyframesRule(allocator) catch {
                    self.pos = block_end + 1;
                    continue;
                };
                keyframes.append(allocator, keyframes_rule) catch |err| {
                    keyframes_rule.deinit(allocator);
                    return err;
                };
                continue;
            }
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

                        const media_rules = try media_parser.parseWithKeyframes(allocator, keyframes);
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

test "keyframes parse beside selector rules and normalize offsets" {
    const allocator = std.testing.allocator;
    const css =
        "@KEYFRAMES pulse {" ++
        " from { opacity: 0.1; width: 100px; }" ++
        " 50%, 75% { opacity: 0.5; }" ++
        " to { opacity: 0.9; width: 300px; }" ++
        "}" ++
        "div { animation: 2s infinite alternate pulse; }";

    var parser = try CSSParser.init(allocator, css, false);
    defer parser.deinit(allocator);
    var keyframes = std.ArrayList(KeyframesRule).empty;
    defer {
        for (keyframes.items) |*rule| rule.deinit(allocator);
        keyframes.deinit(allocator);
    }
    const rules = try parser.parseWithKeyframes(allocator, &keyframes);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqualStrings(
        "2s infinite alternate pulse",
        rules[0].properties.get("animation").?.value,
    );
    try std.testing.expectEqual(@as(usize, 1), keyframes.items.len);
    const pulse = &keyframes.items[0];
    try std.testing.expectEqualStrings("pulse", pulse.name);
    try std.testing.expectEqual(@as(usize, 4), pulse.frames.len);
    try std.testing.expectEqualStrings("0.1", pulse.frameAt(0).?.properties.get("opacity").?.value);
    try std.testing.expectEqualStrings("0.5", pulse.frameAt(0.5).?.properties.get("opacity").?.value);
    try std.testing.expectEqualStrings("0.9", pulse.frameAt(1).?.properties.get("opacity").?.value);
}
