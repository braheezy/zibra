//! Legacy CSS syntax and shared selector parser for Zibra's supported subset.
//! Declaration validation and shorthand expansion belong to css_declarations.
//!
//! Property names and declared values in returned rules normally borrow the
//! input stylesheet; shorthand-generated property names and defaults are
//! static slices. Selectors own their normalized names, selector-sequence lists,
//! descendant-chain lists, and relational-selector components. The stylesheet
//! therefore must outlive its rules, and each owned rule must be deinitialized.

const std = @import("std");
const selector_mod = @import("selector.zig");
const pseudo = @import("pseudo.zig");
const css_syntax = @import("css_syntax.zig");
const media_query = @import("media_query.zig");
const css_properties = @import("css_properties.zig");
const css_declarations = @import("css_declarations.zig");
const custom_properties = @import("custom_properties.zig");
const Selector = selector_mod.Selector;
const SimpleSelector = selector_mod.SimpleSelector;
const UniversalSelector = selector_mod.UniversalSelector;
const TagSelector = selector_mod.TagSelector;
const ClassSelector = selector_mod.ClassSelector;
const IdSelector = selector_mod.IdSelector;
const AttributeSelector = selector_mod.AttributeSelector;
const AttributeMatch = selector_mod.AttributeMatch;
const FocusVisibleSelector = selector_mod.FocusVisibleSelector;
const HoverSelector = selector_mod.HoverSelector;
const StructuralSelector = selector_mod.StructuralSelector;
const StructuralKind = selector_mod.StructuralKind;
const NotSelector = selector_mod.NotSelector;
const StateSelector = selector_mod.StateSelector;
const StateKind = selector_mod.StateKind;
const PseudoElementSelector = selector_mod.PseudoElementSelector;
const SequenceSelector = selector_mod.SequenceSelector;
const SelectorSequence = selector_mod.SelectorSequence;
const HasSelector = selector_mod.HasSelector;
const DescendantSelector = selector_mod.DescendantSelector;
const ComplexSelector = selector_mod.ComplexSelector;
const Combinator = selector_mod.Combinator;

pub const CSSParser = @This();

pub const IMPORTANT_PRIORITY = css_declarations.IMPORTANT_PRIORITY;
pub const INLINE_STYLE_PRIORITY: u32 = 1_000;
pub const PRESENTATIONAL_HINT_PRIORITY: u32 = 20_000;
pub const AUTHOR_ORIGIN_PRIORITY: u32 = 40_000;
pub const MatchContext = selector_mod.MatchContext;
pub const HasMatchCache = selector_mod.HasMatchCache;

/// Explicit browsing-context values used while parsing conditional rules.
pub const MediaEnvironment = media_query.Environment;

pub const Declaration = css_declarations.Declaration;
pub const DeclarationMap = css_declarations.Map;

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
media: MediaEnvironment,

pub fn init(allocator: std.mem.Allocator, string: []const u8, prefers_dark: bool) !*CSSParser {
    return initWithMedia(allocator, string, .{ .prefers_dark = prefers_dark });
}

pub fn initWithMedia(
    allocator: std.mem.Allocator,
    string: []const u8,
    media: MediaEnvironment,
) !*CSSParser {
    const parser = try allocator.create(CSSParser);
    parser.* = CSSParser{
        .string = string,
        .pos = 0,
        .media = media,
    };
    return parser;
}

pub fn deinit(self: *CSSParser, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

fn consumeComment(self: *CSSParser) bool {
    return css_syntax.consumeComment(self.string, &self.pos);
}

fn whitespace(self: *CSSParser) void {
    css_syntax.skipWhitespaceAndComments(self.string, &self.pos);
}

const trimValueTrivia = css_declarations.trimValueTrivia;

fn word(self: *CSSParser) ![]const u8 {
    const start = self.pos;
    while (self.pos < self.string.len) {
        const c = self.string[self.pos];
        if (std.ascii.isAlphanumeric(c) or c == '#' or c == '-' or c == '_' or c == '.' or c == '%') {
            self.pos += 1;
        } else if (c == '\\') {
            if (!css_syntax.consumeEscape(self.string, &self.pos)) return error.InvalidWord;
        } else {
            break;
        }
    }
    if (self.pos <= start) {
        return error.InvalidWord;
    }
    return self.string[start..self.pos];
}

/// Decode the CSS escape sequences retained by `word` into the identifier's
/// actual Unicode value. Selectors compare against DOM attribute strings, so
/// retaining the source spelling (for example `\\2003`) would make escaped
/// class and ID selectors miss their elements. The returned bytes are owned
/// by the caller; input must be the source spelling of a validated identifier.
pub fn decodeIdentifier(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var decoded = std.ArrayList(u8).empty;
    errdefer decoded.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < raw.len) {
        if (raw[cursor] != '\\') {
            try decoded.append(allocator, raw[cursor]);
            cursor += 1;
            continue;
        }
        cursor += 1;
        if (cursor >= raw.len) return error.InvalidWord;
        var codepoint: u32 = 0;
        var digits: usize = 0;
        while (cursor < raw.len and digits < 6) {
            const byte = raw[cursor];
            const digit: u32 = if (byte >= '0' and byte <= '9') byte - '0' else if (byte >= 'a' and byte <= 'f') byte - 'a' + 10 else if (byte >= 'A' and byte <= 'F') byte - 'A' + 10 else break;
            codepoint = codepoint * 16 + digit;
            cursor += 1;
            digits += 1;
        }
        if (digits == 0) {
            try decoded.append(allocator, raw[cursor]);
            cursor += 1;
            continue;
        }
        if (cursor < raw.len and std.ascii.isWhitespace(raw[cursor])) cursor += 1;
        if (codepoint == 0 or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) {
            codepoint = 0xfffd;
        }
        var encoded: [4]u8 = undefined;
        const encoded_len = try std.unicode.utf8Encode(@intCast(codepoint), &encoded);
        try decoded.appendSlice(allocator, encoded[0..encoded_len]);
    }
    return decoded.toOwnedSlice(allocator);
}

fn literal(self: *CSSParser, lit: u8) !void {
    if (self.pos >= self.string.len or self.string[self.pos] != lit) {
        return error.InvalidLiteral;
    }
    self.pos += 1;
}

/// Read a CSS value until a top-level `;` or `}`. Quoted strings and function
/// parentheses may contain either byte; this is required for data URLs in
/// `url(...)` and also keeps other supported function values intact.
fn value(self: *CSSParser) ![]const u8 {
    const start = self.pos;
    const terminator = css_syntax.scanToTopLevel(self.string, self.pos, ";}");
    self.pos = terminator.end;
    if (self.pos <= start) {
        return error.InvalidValue;
    }
    const trimmed = trimValueTrivia(self.string[start..self.pos]);
    if (trimmed.len == 0) return error.InvalidValue;
    return trimmed;
}

fn pair(self: *CSSParser) !struct { property: []const u8, value: []const u8 } {
    const property = try self.word();
    self.whitespace();
    try self.literal(':');
    self.whitespace();
    const val = self.value() catch |err| if (custom_properties.isName(property)) "" else return err;
    return .{ .property = property, .value = val };
}

/// Compatibility entry point for source-spelled declaration insertion.
pub const putDeclaration = css_declarations.putRaw;
pub const isValidLonghandValue = css_declarations.isValidLonghandValue;

pub fn body(self: *CSSParser, allocator: std.mem.Allocator) !DeclarationMap {
    var map = DeclarationMap.init(allocator);
    errdefer map.deinit();
    // Stop at closing brace
    while (self.pos < self.string.len and self.string[self.pos] != '}') {
        self.whitespace();
        if (self.pos >= self.string.len or self.string[self.pos] == '}') break;
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
    const match = css_syntax.scanToTopLevel(self.string, self.pos, chars);
    self.pos = match.end;
    return match.delimiter;
}

fn findMatchingBrace(self: *CSSParser, start: usize) ?usize {
    return css_syntax.findMatchingBrace(self.string, start);
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

fn startsWithMediaRule(self: *const CSSParser) bool {
    const keyword = "@media";
    if (self.string.len - self.pos < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(self.string[self.pos .. self.pos + keyword.len], keyword)) return false;
    const next = self.pos + keyword.len;
    return next == self.string.len or css_syntax.isWhitespace(self.string[next]) or self.string[next] == '(' or
        std.mem.startsWith(u8, self.string[next..], "/*");
}

/// Parse one complete unforgiving selector list without a declaration block.
/// Each selector and the returned slice are independently caller-owned. Source
/// is borrowed only during this call. Invalid members reject the whole list.
/// Admission limits are 64 KiB, 256 members and 64 nested brackets/functions;
/// limits fail before recursive parsing or partial selector publication.
pub fn parseSelectorList(allocator: std.mem.Allocator, source: []const u8) ![]Selector {
    try validateSelectorListInput(source);
    var parser = CSSParser{ .string = source, .pos = 0, .media = .{} };
    var selectors = std.ArrayList(Selector).empty;
    errdefer {
        for (selectors.items) |*sel| sel.deinit(allocator);
        selectors.deinit(allocator);
    }
    parser.whitespace();
    while (true) {
        if (selectors.items.len == 256) return error.SelectorLimitExceeded;
        var sel = try parser.selector(allocator);
        selectors.append(allocator, sel) catch |err| {
            sel.deinit(allocator);
            return err;
        };
        parser.whitespace();
        if (parser.pos == source.len) return selectors.toOwnedSlice(allocator);
        if (source[parser.pos] != ',') return error.InvalidSelector;
        parser.pos += 1;
        parser.whitespace();
    }
}

fn validateSelectorListInput(source: []const u8) !void {
    if (source.len > 64 * 1024) return error.SelectorLimitExceeded;
    var stack: [64]u8 = undefined;
    var depth: usize = 0;
    var cursor: usize = 0;
    var quote: ?u8 = null;
    var members: usize = 1;
    while (cursor < source.len) {
        const byte = source[cursor];
        if (byte == '\\') {
            if (!css_syntax.consumeEscape(source, &cursor)) return error.InvalidSelector;
            continue;
        }
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
            cursor += 1;
            continue;
        }
        if (css_syntax.consumeComment(source, &cursor)) continue;
        switch (byte) {
            '\'', '"' => quote = byte,
            '(', '[' => {
                if (depth == stack.len) return error.SelectorLimitExceeded;
                stack[depth] = if (byte == '(') ')' else ']';
                depth += 1;
            },
            ')', ']' => {
                if (depth == 0 or stack[depth - 1] != byte) return error.InvalidSelector;
                depth -= 1;
            },
            '{', '}' => return error.InvalidSelector,
            ',' => if (depth == 0) {
                members += 1;
                if (members > 256) return error.SelectorLimitExceeded;
            },
            else => {},
        }
        cursor += 1;
    }
    if (depth != 0 or quote != null) return error.InvalidSelector;
}

/// Parse supported compound selectors, relational selectors, and descendant,
/// child, or adjacent-sibling combinator chains.
pub fn selector(self: *CSSParser, allocator: std.mem.Allocator) !Selector {
    var selectors = std.ArrayList(SimpleSelector).empty;
    var combinators = std.ArrayList(Combinator).empty;
    errdefer {
        for (selectors.items) |*simple| simple.deinit(allocator);
        selectors.deinit(allocator);
        combinators.deinit(allocator);
    }

    var first = try self.relationalSelector(allocator);
    selectors.append(allocator, first) catch |err| {
        first.deinit(allocator);
        return err;
    };

    var has_explicit_combinator = false;
    while (self.pos < self.string.len) {
        const before_whitespace = self.pos;
        self.whitespace();
        if (self.pos >= self.string.len or self.string[self.pos] == '{' or self.string[self.pos] == ',') break;

        const combinator: Combinator = if (self.string[self.pos] == '>') blk: {
            has_explicit_combinator = true;
            self.pos += 1;
            self.whitespace();
            break :blk .child;
        } else if (self.string[self.pos] == '+') blk: {
            has_explicit_combinator = true;
            self.pos += 1;
            self.whitespace();
            break :blk .adjacent;
        } else if (self.string[self.pos] == '~') blk: {
            has_explicit_combinator = true;
            self.pos += 1;
            self.whitespace();
            break :blk .general_sibling;
        } else if (self.pos != before_whitespace)
            .descendant
        else
            return error.InvalidSelector;
        if (self.pos >= self.string.len or self.string[self.pos] == '{') {
            return error.InvalidSelector;
        }
        try combinators.append(allocator, combinator);

        var descendant = try self.relationalSelector(allocator);
        selectors.append(allocator, descendant) catch |err| {
            descendant.deinit(allocator);
            return err;
        };
    }

    // A pseudo-element selects a generated box at the end of a selector. It
    // cannot be an ancestor/left-hand selector for a later combinator.
    for (selectors.items, 0..) |simple, index| {
        if (simple.pseudoElementKind() != null and index + 1 != selectors.items.len) {
            return error.InvalidSelector;
        }
    }

    if (selectors.items.len == 1) {
        const simple = selectors.items[0];
        selectors.deinit(allocator);
        combinators.deinit(allocator);
        return simple.intoSelector();
    }

    if (has_explicit_combinator) {
        return .{ .complex = ComplexSelector.take(&selectors, &combinators) };
    }
    combinators.deinit(allocator);
    return .{ .descendant = DescendantSelector.take(&selectors) };
}

/// Parse a selector anchored to the current element and optionally constrained
/// by a matching strict descendant. Zibra's current selector subset accepts a
/// tag/class/dynamic-pseudo sequence on each side of `:has`.
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

fn attributeNameChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '_';
}

fn attributeSelectorValue(
    self: *CSSParser,
    allocator: std.mem.Allocator,
) ![]u8 {
    var decoded = std.ArrayList(u8).empty;
    errdefer decoded.deinit(allocator);
    if (self.pos >= self.string.len) return error.InvalidSelector;

    const quote: ?u8 = switch (self.string[self.pos]) {
        '\'', '"' => self.string[self.pos],
        else => null,
    };
    if (quote != null) self.pos += 1;

    while (self.pos < self.string.len) {
        const char = self.string[self.pos];
        if (quote) |delimiter| {
            if (char == delimiter) {
                self.pos += 1;
                return decoded.toOwnedSlice(allocator);
            }
        } else {
            if (char == ']' or std.ascii.isWhitespace(char)) break;
            if (!attributeNameChar(char) and char != '\\') return error.InvalidSelector;
        }

        if (char == '\\') {
            self.pos += 1;
            if (self.pos >= self.string.len) return error.InvalidSelector;
            try decoded.append(allocator, self.string[self.pos]);
            self.pos += 1;
            continue;
        }
        try decoded.append(allocator, char);
        self.pos += 1;
    }

    if (quote != null or decoded.items.len == 0) return error.InvalidSelector;
    return decoded.toOwnedSlice(allocator);
}

fn parseAttributeSelector(
    self: *CSSParser,
    allocator: std.mem.Allocator,
) !AttributeSelector {
    try self.literal('[');
    self.whitespace();

    const name_start = self.pos;
    while (self.pos < self.string.len and attributeNameChar(self.string[self.pos])) {
        self.pos += 1;
    }
    if (self.pos == name_start) return error.InvalidSelector;
    const name = try std.ascii.allocLowerString(allocator, self.string[name_start..self.pos]);
    errdefer allocator.free(name);
    self.whitespace();

    if (self.pos < self.string.len and self.string[self.pos] == ']') {
        self.pos += 1;
        return AttributeSelector.init(name, null, .presence);
    }

    const matcher: AttributeMatch = if (self.pos + 1 < self.string.len and
        self.string[self.pos] == '~' and self.string[self.pos + 1] == '=')
    blk: {
        self.pos += 2;
        break :blk .includes;
    } else if (self.pos + 1 < self.string.len and
        self.string[self.pos] == '|' and self.string[self.pos + 1] == '=')
    blk: {
        self.pos += 2;
        break :blk .dash_match;
    } else if (self.pos < self.string.len and self.string[self.pos] == '=') blk: {
        self.pos += 1;
        break :blk .exact;
    } else return error.InvalidSelector;

    self.whitespace();
    const expected_value = try self.attributeSelectorValue(allocator);
    errdefer allocator.free(expected_value);
    self.whitespace();
    try self.literal(']');
    return AttributeSelector.init(name, expected_value, matcher);
}

fn appendAttributeSelectors(
    self: *CSSParser,
    allocator: std.mem.Allocator,
    selectors: *std.ArrayList(SequenceSelector),
) !void {
    while (self.pos < self.string.len and self.string[self.pos] == '[') {
        const attribute = try self.parseAttributeSelector(allocator);
        try appendSequenceSelector(
            allocator,
            selectors,
            .{ .attribute = attribute },
        );
    }
}

fn pseudoElementKind(name: []const u8) ?pseudo.Kind {
    if (std.ascii.eqlIgnoreCase(name, "before")) return .before;
    if (std.ascii.eqlIgnoreCase(name, "after")) return .after;
    return null;
}

/// Consume the identifier portion of a pseudo selector. `word` intentionally
/// accepts class and ID punctuation for the compact selector syntax, while a
/// pseudo name must stop before a following `.class` or `#id` token.
fn pseudoIdentifier(self: *CSSParser) ![]const u8 {
    const start = self.pos;
    while (self.pos < self.string.len) {
        const char = self.string[self.pos];
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_') {
            self.pos += 1;
        } else if (char == '\\') {
            if (!css_syntax.consumeEscape(self.string, &self.pos)) return error.InvalidWord;
        } else {
            break;
        }
    }
    if (self.pos == start) return error.InvalidWord;
    return self.string[start..self.pos];
}

fn structuralKind(name: []const u8) ?StructuralKind {
    if (std.ascii.eqlIgnoreCase(name, "root")) return .root;
    if (std.ascii.eqlIgnoreCase(name, "first-child")) return .first_child;
    if (std.ascii.eqlIgnoreCase(name, "last-child")) return .last_child;
    if (std.ascii.eqlIgnoreCase(name, "only-child")) return .only_child;
    if (std.ascii.eqlIgnoreCase(name, "empty")) return .empty;
    if (std.ascii.eqlIgnoreCase(name, "nth-child")) return .nth_child;
    if (std.ascii.eqlIgnoreCase(name, "nth-last-child")) return .nth_last_child;
    if (std.ascii.eqlIgnoreCase(name, "first-of-type")) return .first_of_type;
    if (std.ascii.eqlIgnoreCase(name, "last-of-type")) return .last_of_type;
    if (std.ascii.eqlIgnoreCase(name, "only-of-type")) return .only_of_type;
    if (std.ascii.eqlIgnoreCase(name, "nth-of-type")) return .nth_of_type;
    if (std.ascii.eqlIgnoreCase(name, "nth-last-of-type")) return .nth_last_of_type;
    if (std.ascii.eqlIgnoreCase(name, "lang")) return .lang;
    return null;
}

fn stateKind(name: []const u8) ?StateKind {
    if (std.ascii.eqlIgnoreCase(name, "link")) return .link;
    if (std.ascii.eqlIgnoreCase(name, "visited")) return .visited;
    if (std.ascii.eqlIgnoreCase(name, "enabled")) return .enabled;
    if (std.ascii.eqlIgnoreCase(name, "disabled")) return .disabled;
    if (std.ascii.eqlIgnoreCase(name, "checked")) return .checked;
    return null;
}

fn appendStructuralSelector(
    allocator: std.mem.Allocator,
    selectors: *std.ArrayList(SequenceSelector),
    kind: StructuralKind,
    argument: ?[]const u8,
) !void {
    const owned_argument = if (argument) |argument_text| try allocator.dupe(u8, argument_text) else null;
    try appendSequenceSelector(allocator, selectors, .{ .structural = .{
        .kind = kind,
        .argument = owned_argument,
    } });
}

fn simpleSelector(self: *CSSParser, allocator: std.mem.Allocator) !SimpleSelector {
    var selectors = std.ArrayList(SequenceSelector).empty;
    errdefer {
        for (selectors.items) |*part| part.deinit(allocator);
        selectors.deinit(allocator);
    }

    try self.appendAttributeSelectors(allocator, &selectors);
    if (self.pos < self.string.len and self.string[self.pos] == '*') {
        self.pos += 1;
        try appendSequenceSelector(
            allocator,
            &selectors,
            .{ .universal = UniversalSelector{} },
        );
    }

    const can_start_word = if (self.pos < self.string.len) blk: {
        const char = self.string[self.pos];
        break :blk char == '.' or char == '#' or std.ascii.isAlphanumeric(char) or
            char == '-' or char == '_';
    } else false;
    if (can_start_word) {
        const raw = try self.word();
        if (std.mem.indexOfScalar(u8, raw, '%') != null) return error.InvalidSelector;

        var cursor: usize = 0;
        if (raw[0] != '.' and raw[0] != '#') {
            const tag_end = std.mem.indexOfAny(u8, raw, ".#") orelse raw.len;
            const decoded_tag = try decodeIdentifier(allocator, raw[0..tag_end]);
            defer allocator.free(decoded_tag);
            const lower_tag = try std.ascii.allocLowerString(allocator, decoded_tag);
            try appendSequenceSelector(
                allocator,
                &selectors,
                .{ .tag = TagSelector.init(lower_tag) },
            );
            cursor = tag_end;
        }

        while (cursor < raw.len) {
            const marker = raw[cursor];
            if (marker != '.' and marker != '#') return error.InvalidSelector;
            const name_start = cursor + 1;
            if (name_start >= raw.len) return error.InvalidSelector;

            const remaining = raw[name_start..];
            const name_len = std.mem.indexOfAny(u8, remaining, ".#") orelse remaining.len;
            if (name_len == 0) return error.InvalidSelector;

            const name = try decodeIdentifier(allocator, remaining[0..name_len]);
            if (marker == '.') {
                try appendSequenceSelector(
                    allocator,
                    &selectors,
                    .{ .class = ClassSelector.init(name) },
                );
            } else {
                try appendSequenceSelector(
                    allocator,
                    &selectors,
                    .{ .id = IdSelector.init(name) },
                );
            }
            cursor = name_start + name_len;
        }
    }
    try self.appendAttributeSelectors(allocator, &selectors);

    // Consume supported dynamic pseudo-classes and terminal pseudo-elements.
    // Leave an unsupported single colon untouched so relationalSelector can
    // recognize `:has(...)` or report the existing unsupported-pseudo error.
    while (self.pos < self.string.len and self.string[self.pos] == ':') {
        const pseudo_start = self.pos;
        self.pos += 1;
        const explicit_pseudo_element = self.pos < self.string.len and self.string[self.pos] == ':';
        if (explicit_pseudo_element) self.pos += 1;
        const pseudo_name = self.pseudoIdentifier() catch {
            self.pos = pseudo_start;
            break;
        };
        if (pseudoElementKind(pseudo_name)) |kind| {
            try appendSequenceSelector(
                allocator,
                &selectors,
                .{ .pseudo_element = PseudoElementSelector{ .kind = kind } },
            );
            break;
        }
        if (explicit_pseudo_element) {
            self.pos = pseudo_start;
            break;
        }
        if (std.ascii.eqlIgnoreCase(pseudo_name, "not")) {
            if (self.pos >= self.string.len or self.string[self.pos] != '(') {
                self.pos = pseudo_start;
                break;
            }
            self.pos += 1;
            self.whitespace();
            const inner = try self.simpleSelector(allocator);
            var inner_owned = true;
            errdefer {
                if (inner_owned) {
                    var owned_inner = inner;
                    owned_inner.deinit(allocator);
                }
            }
            self.whitespace();
            try self.literal(')');
            const inner_ptr = try allocator.create(SimpleSelector);
            inner_ptr.* = inner;
            inner_owned = false;
            try appendSequenceSelector(allocator, &selectors, .{ .not = NotSelector{ .selector = inner_ptr } });
            continue;
        }
        if (structuralKind(pseudo_name)) |kind| {
            var argument: ?[]const u8 = null;
            const requires_argument = kind == .nth_child or kind == .nth_last_child or
                kind == .nth_of_type or kind == .nth_last_of_type or kind == .lang;
            if (self.pos < self.string.len and self.string[self.pos] == '(') {
                self.pos += 1;
                const start = self.pos;
                var depth: usize = 1;
                while (self.pos < self.string.len and depth != 0) : (self.pos += 1) {
                    if (self.string[self.pos] == '(') depth += 1 else if (self.string[self.pos] == ')') depth -= 1;
                }
                if (depth != 0) return error.InvalidSelector;
                argument = self.string[start .. self.pos - 1];
            } else if (requires_argument) {
                return error.InvalidSelector;
            }
            try appendStructuralSelector(allocator, &selectors, kind, argument);
            continue;
        }
        if (stateKind(pseudo_name)) |kind| {
            try appendSequenceSelector(allocator, &selectors, .{ .state = StateSelector{ .kind = kind } });
            continue;
        }
        const dynamic_selector: SequenceSelector = if (std.ascii.eqlIgnoreCase(
            pseudo_name,
            "focus-visible",
        ))
            .{ .focus_visible = FocusVisibleSelector{} }
        else if (std.ascii.eqlIgnoreCase(pseudo_name, "hover"))
            .{ .hover = HoverSelector{} }
        else {
            self.pos = pseudo_start;
            break;
        };
        try appendSequenceSelector(
            allocator,
            &selectors,
            dynamic_selector,
        );
    }

    if (selectors.items.len == 0) return error.InvalidSelector;
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
    origin: enum { user_agent, author } = .author,
    /// Independent source URL owner for external-sheet resource provenance.
    source_url: ?[]u8 = null,
    referrer_policy: @import("referrer.zig").Policy = .default,

    /// Origin precedes specificity; important UA rules precede author rules.
    pub fn declarationPriorityBase(self: CSSRule, important: bool) u32 {
        return self.cascadePriority() + switch (self.origin) {
            .author => AUTHOR_ORIGIN_PRIORITY,
            .user_agent => if (important) @as(u32, 60_000) else 0,
        };
    }

    pub fn deinit(self: *CSSRule, allocator: std.mem.Allocator) void {
        if (self.source_url) |url| allocator.free(url);
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
            if (self.startsWithMediaRule()) {
                const prelude_start = self.pos + "@media".len;
                const delimiter = css_syntax.scanToTopLevel(self.string, prelude_start, "{;");
                if (delimiter.delimiter != '{') {
                    self.pos = delimiter.end + @as(usize, if (delimiter.delimiter == ';') 1 else 0);
                    continue;
                }
                const brace_idx = delimiter.end;
                const prelude = self.string[prelude_start..brace_idx];
                const block_end = self.findMatchingBrace(brace_idx) orelse break;

                if (media_query.matches(prelude, self.media)) {
                    var media_parser = try CSSParser.initWithMedia(
                        allocator,
                        self.string[brace_idx + 1 .. block_end],
                        self.media,
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

        self.appendQualifiedRule(allocator, &rules) catch |err| {
            if (err == error.OutOfMemory) return err;
            // Ordinary selector lists are unforgiving: one invalid member
            // invalidates the entire declaration block, not just that member.
            _ = self.ignoreUntil("}") orelse break;
            self.pos += 1;
        };
    }

    return rules.toOwnedSlice(allocator);
}

/// Expand a selector list into independently owned rules in source order.
/// Each member retains its own specificity. Declaration strings still borrow
/// the stylesheet, but every rule owns its map and selector storage.
fn appendQualifiedRule(self: *CSSParser, allocator: std.mem.Allocator, rules: *std.ArrayList(CSSRule)) !void {
    var selectors = std.ArrayList(Selector).empty;
    var transferred: usize = 0;
    defer {
        for (selectors.items[transferred..]) |*sel| sel.deinit(allocator);
        selectors.deinit(allocator);
    }
    while (true) {
        var sel = try self.selector(allocator);
        selectors.append(allocator, sel) catch |err| {
            sel.deinit(allocator);
            return err;
        };
        self.whitespace();
        if (self.pos >= self.string.len or self.string[self.pos] != ',') break;
        self.pos += 1;
        self.whitespace();
    }
    try self.literal('{');
    self.whitespace();
    var properties = try self.body(allocator);
    defer properties.deinit();
    try self.literal('}');
    try rules.ensureUnusedCapacity(allocator, selectors.items.len);
    for (selectors.items) |sel| {
        const cloned = try properties.clone();
        rules.appendAssumeCapacity(.{ .selector = sel, .properties = cloned, .owned = true });
        transferred += 1;
    }
}

test "selector lists preserve member specificity declarations and nested commas" {
    const allocator = std.testing.allocator;
    var parser = try CSSParser.init(allocator, ".pair strong, .pair small { display:block; color:red !important }" ++
        "[data-name='a,b'], #selected { color:green }" ++
        "@media (min-width:0px) { b, i { color:blue } }", false);
    defer parser.deinit(allocator);
    parser.media.viewport_width_css = 800;
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try std.testing.expectEqual(@as(usize, 6), rules.len);
    try std.testing.expectEqualStrings("block", rules[0].properties.get("display").?.value);
    try std.testing.expectEqualStrings("block", rules[1].properties.get("display").?.value);
    try std.testing.expect(rules[1].properties.get("color").?.important);
    try std.testing.expect(rules[2].cascadePriority() < rules[3].cascadePriority());
    try std.testing.expectEqualStrings("blue", rules[5].properties.get("color").?.value);
    // Tables are independent owners even though declaration values are borrows.
    _ = rules[0].properties.remove("color");
    try std.testing.expect(rules[1].properties.contains("color"));
}

test "invalid selector list members discard the whole rule and recover" {
    const allocator = std.testing.allocator;
    var parser = try CSSParser.init(allocator, "b, :unknown { color:red }" ++
        "b, { color:red }" ++
        ", b { color:red }" ++
        "b,,i { color:red }" ++
        "b, i { color:green }", false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    for (rules) |rule| try std.testing.expectEqualStrings("green", rule.properties.get("color").?.value);
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

test "media range conditional rules and keyframes retain source order and recover after invalid queries" {
    const allocator = std.testing.allocator;
    const source =
        "p{color:red}" ++
        "@media/* brace { inside comment */(width>=1012px) and (width<=1279px){" ++
        "p{color:green}@media (height>500px){p{width:300px}@keyframes pulse{from{opacity:0}to{opacity:1}}}}" ++
        "@media not (1px < width > 2px){p{color:orange}}" ++
        "@media not ((color) and){p{color:orange}}" ++
        "@media screen; p{height:40px}" ++
        "@media (width>=1280px){p{color:blue}}";
    for ([_]struct { width: f64, height: f64, count: usize, color: []const u8, animation: bool }{
        .{ .width = 1011, .height = 600, .count = 2, .color = "red", .animation = false },
        .{ .width = 1012, .height = 600, .count = 4, .color = "green", .animation = true },
        .{ .width = 1012, .height = 500, .count = 3, .color = "green", .animation = false },
        .{ .width = 1279, .height = 600, .count = 4, .color = "green", .animation = true },
        .{ .width = 1280, .height = 600, .count = 3, .color = "blue", .animation = false },
    }) |case| {
        const parser = try CSSParser.initWithMedia(allocator, source, .{
            .viewport_width_css = case.width,
            .viewport_height_css = case.height,
        });
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
        try std.testing.expectEqual(case.count, rules.len);
        var color: []const u8 = "";
        for (rules) |rule| if (rule.properties.get("color")) |declaration| {
            color = declaration.value;
        };
        try std.testing.expectEqualStrings(case.color, color);
        try std.testing.expectEqual(@as(usize, if (case.animation) 1 else 0), keyframes.items.len);
        if (case.animation) try std.testing.expectEqualStrings("pulse", keyframes.items[0].name);
    }
}

test "max-width media queries use CSS viewport pixels and inclusive bounds" {
    const allocator = std.testing.allocator;
    const css =
        "p { color: red; }" ++
        "@MEDIA screen and (MAX-WIDTH: 600PX) { p { color: green; } }" ++
        "@media print, (max-width: 500px) { p { background-color: blue; } }";

    var wide_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .viewport_width_css = 601 },
    );
    defer wide_parser.deinit(allocator);
    const wide_rules = try wide_parser.parse(allocator);
    defer {
        for (wide_rules) |*rule| rule.deinit(allocator);
        allocator.free(wide_rules);
    }
    try std.testing.expectEqual(@as(usize, 1), wide_rules.len);

    var boundary_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .viewport_width_css = 600 },
    );
    defer boundary_parser.deinit(allocator);
    const boundary_rules = try boundary_parser.parse(allocator);
    defer {
        for (boundary_rules) |*rule| rule.deinit(allocator);
        allocator.free(boundary_rules);
    }
    try std.testing.expectEqual(@as(usize, 2), boundary_rules.len);
    try std.testing.expectEqualStrings("green", boundary_rules[1].properties.get("color").?.value);

    var narrow_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .viewport_width_css = 500 },
    );
    defer narrow_parser.deinit(allocator);
    const narrow_rules = try narrow_parser.parse(allocator);
    defer {
        for (narrow_rules) |*rule| rule.deinit(allocator);
        allocator.free(narrow_rules);
    }
    try std.testing.expectEqual(@as(usize, 3), narrow_rules.len);
    try std.testing.expectEqualStrings("blue", narrow_rules[2].properties.get("background-color").?.value);
}

test "width media queries match the exact CSS viewport width" {
    const allocator = std.testing.allocator;
    const css =
        "p { color: red; }" ++
        "@MEDIA (WIDTH: 300PX) { p { color: green; } }" ++
        "@media (width: 0) { p { background-color: blue; } }";

    const widths = [_]struct {
        value: ?f64,
        rule_count: usize,
    }{
        .{ .value = null, .rule_count = 1 },
        .{ .value = 299, .rule_count = 1 },
        .{ .value = 300, .rule_count = 2 },
        // Permit only floating-point normalization noise from iframe zoom.
        .{ .value = 300.00000001, .rule_count = 2 },
        .{ .value = 300.001, .rule_count = 1 },
        .{ .value = 0, .rule_count = 2 },
    };

    for (widths) |expected| {
        var parser = try CSSParser.initWithMedia(
            allocator,
            css,
            .{ .viewport_width_css = expected.value },
        );
        defer parser.deinit(allocator);
        const rules = try parser.parse(allocator);
        defer {
            for (rules) |*rule| rule.deinit(allocator);
            allocator.free(rules);
        }
        try std.testing.expectEqual(expected.rule_count, rules.len);
    }
}

test "Acid3 color and height media features use iframe viewport values" {
    const allocator = std.testing.allocator;
    const css =
        "@media (min-color: 1) { p { color: red; } }" ++
        "@media (max-color: 0) { p { color: blue; } }" ++
        "@media color { p { background-color: red; } }" ++
        "@media (min-monochrome: 0) { p { border-color: green; } }" ++
        "@media monochrome { p { border-color: blue; } }" ++
        "@media (min-height: 1em) and (min-width: 1em) { p { color: purple; } }";

    var parser = try CSSParser.initWithMedia(allocator, css, .{
        .viewport_width_css = 20,
        .viewport_height_css = 20,
    });
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    // 24-bit color, non-monochrome, and 20px >= the 16px default em.
    try std.testing.expectEqual(@as(usize, 3), rules.len);
}

test "millimeter lengths remain valid CSS dimensions" {
    const allocator = std.testing.allocator;
    const css =
        "div { max-height: 2mm; font: 25.4mm/1em sans-serif; }" ++
        "span { top: -1mm; }";
    var parser = try CSSParser.init(allocator, css, false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expectEqualStrings("2mm", rules[0].properties.get("max-height").?.value);
    try std.testing.expectEqualStrings("25.4mm", rules[0].properties.get("font-size").?.value);
    try std.testing.expectEqualStrings("-1mm", rules[1].properties.get("top").?.value);
}

test "vertical-align accepts bounded inline alignment values" {
    const allocator = std.testing.allocator;
    var parser = try CSSParser.init(
        allocator,
        "img { vertical-align: baseline; vertical-align: middle; vertical-align: bottom; }",
        false,
    );
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqualStrings("bottom", rules[0].properties.get("vertical-align").?.value);

    var length_parser = try CSSParser.init(allocator, "img { vertical-align: 2em; }", false);
    defer length_parser.deinit(allocator);
    const length_rules = try length_parser.parse(allocator);
    defer {
        for (length_rules) |*rule| rule.deinit(allocator);
        allocator.free(length_rules);
    }
    try std.testing.expectEqualStrings("2em", length_rules[0].properties.get("vertical-align").?.value);
}

test "width and color media features compose with relative lengths" {
    const allocator = std.testing.allocator;
    const css =
        "@media (max-width: 640px) and (prefers-color-scheme: dark) { p { color: green; } }" ++
        "@media (max-width: 40em) { p { color: purple; } }" ++
        "@media (min-width: 1px) { p { color: orange; } }";

    var matching_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .prefers_dark = true, .viewport_width_css = 640 },
    );
    defer matching_parser.deinit(allocator);
    const matching_rules = try matching_parser.parse(allocator);
    defer {
        for (matching_rules) |*rule| rule.deinit(allocator);
        allocator.free(matching_rules);
    }
    try std.testing.expectEqual(@as(usize, 3), matching_rules.len);
    try std.testing.expectEqualStrings("green", matching_rules[0].properties.get("color").?.value);

    var light_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .prefers_dark = false, .viewport_width_css = 400 },
    );
    defer light_parser.deinit(allocator);
    const light_rules = try light_parser.parse(allocator);
    defer {
        for (light_rules) |*rule| rule.deinit(allocator);
        allocator.free(light_rules);
    }
    try std.testing.expectEqual(@as(usize, 2), light_rules.len);
}

test "forced-colors media feature selects active and none rules" {
    const allocator = std.testing.allocator;
    const css =
        "@media (forced-colors: active) { p { color: red; } }" ++
        "@media (forced-colors: none) { p { background-color: blue; } }" ++
        "@media (forced-colors: invalid) { p { width: 1px; } }";

    var active_parser = try CSSParser.initWithMedia(
        allocator,
        css,
        .{ .forced_colors = true },
    );
    defer active_parser.deinit(allocator);
    const active_rules = try active_parser.parse(allocator);
    defer {
        for (active_rules) |*rule| rule.deinit(allocator);
        allocator.free(active_rules);
    }
    try std.testing.expectEqual(@as(usize, 1), active_rules.len);
    try std.testing.expectEqualStrings("red", active_rules[0].properties.get("color").?.value);

    var normal_parser = try CSSParser.initWithMedia(allocator, css, .{});
    defer normal_parser.deinit(allocator);
    const normal_rules = try normal_parser.parse(allocator);
    defer {
        for (normal_rules) |*rule| rule.deinit(allocator);
        allocator.free(normal_rules);
    }
    try std.testing.expectEqual(@as(usize, 1), normal_rules.len);
    try std.testing.expectEqualStrings(
        "blue",
        normal_rules[0].properties.get("background-color").?.value,
    );
}

test "declaration values retain semicolons inside URL functions" {
    const allocator = std.testing.allocator;
    const css =
        "div { background-image: url(data:image/png;base64,AAAA); " ++
        "background-size: 50% 25%; color: red; }";
    var parser = try CSSParser.init(allocator, css, false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqualStrings(
        "url(data:image/png;base64,AAAA)",
        rules[0].properties.get("background-image").?.value,
    );
    try std.testing.expectEqualStrings(
        "50% 25%",
        rules[0].properties.get("background-size").?.value,
    );
    try std.testing.expectEqualStrings("red", rules[0].properties.get("color").?.value);
}

test "escaped declaration syntax preserves later values and rejects invalid cascade overrides" {
    const allocator = std.testing.allocator;
    const css =
        "div { width: 2em; error: \\}; background: yellow; width: 200; background: red pink; }" ++
        "span { background: yellow /* comment is whitespace */ no-repeat fixed; }" ++
        "p { m\\61rgin: 2em; m\\argin: 3em; margin-top: 1em; }";
    var parser = try CSSParser.init(allocator, css, false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 3), rules.len);
    const first = &rules[0].properties;
    try std.testing.expectEqualStrings("2em", first.get("width").?.value);
    try std.testing.expectEqualStrings("yellow", first.get("background-color").?.value);
    try std.testing.expect(first.get("error") == null);

    const second = &rules[1].properties;
    try std.testing.expectEqualStrings("yellow", second.get("background-color").?.value);
    try std.testing.expectEqualStrings("no-repeat", second.get("background-repeat").?.value);
    try std.testing.expectEqualStrings("fixed", second.get("background-attachment").?.value);

    const third = &rules[2].properties;
    try std.testing.expectEqualStrings("1em", third.get("margin-top").?.value);
    try std.testing.expectEqualStrings("2em", third.get("margin-right").?.value);
}

test "legacy and modern generated pseudo selectors retain kind and specificity" {
    const allocator = std.testing.allocator;
    const css =
        "article.notice:before { content: 'legacy'; }" ++
        "#message::after { content: \"modern\"; }" ++
        "main > article:hover::BEFORE { content: \"stateful\"; }";
    var parser = try CSSParser.init(allocator, css, false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqual(pseudo.Kind.before, rules[0].selector.pseudoElementKind().?);
    try std.testing.expectEqual(@as(u32, 12), rules[0].cascadePriority());
    try std.testing.expectEqualStrings("'legacy'", rules[0].properties.get("content").?.value);

    try std.testing.expectEqual(pseudo.Kind.after, rules[1].selector.pseudoElementKind().?);
    try std.testing.expectEqual(@as(u32, 101), rules[1].cascadePriority());
    try std.testing.expectEqualStrings("\"modern\"", rules[1].properties.get("content").?.value);

    try std.testing.expectEqual(pseudo.Kind.before, rules[2].selector.pseudoElementKind().?);
    try std.testing.expectEqual(@as(u32, 13), rules[2].cascadePriority());
}

test "generated pseudo-elements are terminal selectors" {
    const allocator = std.testing.allocator;
    const invalid = [_][]const u8{
        "div::before span",
        "div:after > span",
        "div::before:hover",
        "div::before.notice",
    };

    for (invalid) |source| {
        var parser = try CSSParser.init(allocator, source, false);
        defer parser.deinit(allocator);
        try std.testing.expectError(error.InvalidSelector, parser.selector(allocator));
    }
}

test "content keeps the generated-content subset and defaults to normal" {
    var saw_content = false;
    for (css_properties.computed) |property| {
        if (!std.mem.eql(u8, property.name, "content")) continue;
        try std.testing.expectEqualStrings("normal", property.default_value);
        saw_content = true;
    }
    try std.testing.expect(saw_content);

    const allocator = std.testing.allocator;
    const css =
        "a::before { content: normal; }" ++
        "b::after { content: none; }" ++
        "c::before { content: \"quoted ; { braces }\"; }" ++
        "d::after { content: 'single quoted'; }" ++
        "e::before { content: attr(data-label); color: red; }";
    var parser = try CSSParser.init(allocator, css, false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 5), rules.len);
    try std.testing.expectEqualStrings("normal", rules[0].properties.get("content").?.value);
    try std.testing.expectEqualStrings("none", rules[1].properties.get("content").?.value);
    try std.testing.expectEqualStrings(
        "\"quoted ; { braces }\"",
        rules[2].properties.get("content").?.value,
    );
    try std.testing.expectEqualStrings("'single quoted'", rules[3].properties.get("content").?.value);
    try std.testing.expect(rules[4].properties.get("content") == null);
    try std.testing.expectEqualStrings("red", rules[4].properties.get("color").?.value);
}

test "z-index retains auto and signed integers while rejecting invalid values" {
    const allocator = std.testing.allocator;
    const css =
        "a { z-index: -4; z-index: 2.5; }" ++
        "b { z-index: AUTO; z-index: 1px; }" ++
        "c { z-index: +0; }" ++
        "d { z-index: -2147483648; }" ++
        "e { z-index: 2147483648; }";
    var parser = try CSSParser.init(allocator, css, false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 5), rules.len);
    try std.testing.expectEqualStrings("-4", rules[0].properties.get("z-index").?.value);
    try std.testing.expectEqualStrings("AUTO", rules[1].properties.get("z-index").?.value);
    try std.testing.expectEqualStrings("+0", rules[2].properties.get("z-index").?.value);
    try std.testing.expectEqualStrings("-2147483648", rules[3].properties.get("z-index").?.value);
    try std.testing.expect(rules[4].properties.get("z-index") == null);
}

test "structural selectors and dash-match attributes parse as owned selectors" {
    const allocator = std.testing.allocator;
    const css = ":root{} :first-child{} :last-child{} :only-child{} :empty{} " ++
        ":nth-child(-n+3){} :nth-last-child(2n){} :first-of-type{} " ++
        ":last-of-type{} :only-of-type{} :nth-of-type(3n+1){} " ++
        ":nth-last-of-type(-5n+3){} :lang(en){} :not(:root){} [class|=widget]{}";
    var parser = try CSSParser.init(allocator, css, false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try std.testing.expectEqual(@as(usize, 15), rules.len);
    for (rules[0..13]) |rule| try std.testing.expectEqual(@as(u32, 10), rule.cascadePriority());
    try std.testing.expectEqual(@as(u32, 20), rules[13].cascadePriority());
    try std.testing.expectEqual(@as(u32, 10), rules[14].cascadePriority());
}

test "form and link state pseudo-classes parse as compound selectors" {
    const allocator = std.testing.allocator;
    var parser = try CSSParser.init(allocator, ":checked:enabled{} :link{} :visited{} :disabled{}", false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try std.testing.expectEqual(@as(usize, 4), rules.len);
    try std.testing.expectEqual(@as(u32, 20), rules[0].cascadePriority());
}

test "standalone selector lists require complete input and own every member" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, " /*lead*/ div.card, [data-value='a,b'], #selected > span:not(.hidden) /*tail*/ ");
    const selectors = parseSelectorList(allocator, source) catch |err| {
        allocator.free(source);
        return err;
    };
    allocator.free(source);
    defer {
        for (selectors) |*sel| sel.deinit(allocator);
        allocator.free(selectors);
    }
    try std.testing.expectEqual(@as(usize, 3), selectors.len);
    try std.testing.expectEqual(@as(u32, 11), selectors[0].priority());
    try std.testing.expectEqualStrings("a,b", selectors[1].attribute.value.?);
    try std.testing.expectEqual(@as(usize, 2), selectors[2].complex.selectors.items.len);
    for ([_][]const u8{ "", " ", "div,", ",div", "div,,span", "div {color:red}", "div;span", "div, :unsupported", "div:not(.a", "[title='x'", "div >", "div:not(.a])" }) |invalid| {
        if (parseSelectorList(allocator, invalid)) |unexpected| {
            for (unexpected) |*sel| sel.deinit(allocator);
            allocator.free(unexpected);
            return error.ExpectedInvalidSelectorList;
        } else |err| {
            try std.testing.expect(err != error.OutOfMemory);
        }
    }
}

test "standalone selector limits precede allocation and recursive parsing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    const deep = ":not(" ** 65 ++ "div" ++ ")" ** 65;
    const many = "div," ** 256 ++ "span";
    const oversized = " " ** (64 * 1024 + 1);
    try std.testing.expectError(error.SelectorLimitExceeded, parseSelectorList(allocator, deep));
    try std.testing.expectError(error.SelectorLimitExceeded, parseSelectorList(allocator, many));
    try std.testing.expectError(error.SelectorLimitExceeded, parseSelectorList(allocator, oversized));
    try std.testing.expect(!failing.has_induced_failure);
}

fn selectorListAllocationTrial(allocator: std.mem.Allocator) !void {
    const selectors = try parseSelectorList(allocator, "div.card:not(.hidden), [data-name='a,b'], main > span:has(em)");
    defer {
        for (selectors) |*sel| sel.deinit(allocator);
        allocator.free(selectors);
    }
}

test "standalone selector parsing reclaims partial owners on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, selectorListAllocationTrial, .{});
}
