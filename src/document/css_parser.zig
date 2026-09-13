//! Native CSS syntax and shared selector parser for Zibra's supported subset.
//! Declaration validation and shorthand expansion belong to css_declarations.
//!
//! Declaration maps own their normalized property names and values; shorthand
//! defaults may be static. Keyframe names still borrow stylesheet source.
//! Selectors own their normalized names, selector-sequence lists,
//! descendant-chain lists, and relational-selector components. Deinitialize
//! each rule; stylesheet source must outlive keyframes.

const std = @import("std");
const selector_mod = @import("selector.zig");
const pseudo = @import("pseudo.zig");
const css_syntax = @import("css_syntax.zig");
const tokens = @import("css_tokenizer.zig");
const rule_syntax = @import("css_rule_syntax.zig");
const media_query = @import("media_query.zig");
const supports = @import("css_supports.zig");
const nesting = @import("css_nesting.zig");
const css_properties = @import("css_properties.zig");
const css_declarations = @import("css_declarations.zig");
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
const LogicalSelector = selector_mod.LogicalSelector;
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

pub const cascade = @import("css_cascade.zig");
pub const Specificity = cascade.Specificity;
pub const MatchContext = selector_mod.MatchContext;
pub const HasMatchCache = selector_mod.HasMatchCache;

/// Explicit browsing-context values used while parsing conditional rules.
pub const MediaEnvironment = media_query.Environment;

pub const Declaration = css_declarations.Declaration;
pub const DeclarationMap = css_declarations.Map;

/// One declaration block within an `@keyframes` rule. Selectors are normalized
/// to a 0...1 offset; the declaration map owns normalized values.
pub const Keyframe = struct {
    offset: f64,
    properties: DeclarationMap,

    pub fn deinit(self: *Keyframe) void {
        self.properties.deinit();
    }
};

/// A named keyframe rule. Its name borrows the stylesheet; the frame slice,
/// declaration maps and normalized declaration strings are owned.
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
top_level: bool = true,
allow_pseudo_elements: bool = true,
in_has: bool = false,
/// Feature queries reject unsupported members even in forgiving logical lists.
strict_support: bool = false,
group_depth: usize = 0,

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

fn whitespace(self: *CSSParser) void {
    css_syntax.skipWhitespaceAndComments(self.string, &self.pos);
}

/// Consume one encoded identifier without interpreting escaped punctuation as
/// selector syntax. The returned range borrows the current input.
fn identifier(self: *CSSParser) ![]const u8 {
    return css_syntax.consumeIdentifier(self.string, &self.pos) orelse error.InvalidSelector;
}

/// Decode a validated CSS identifier into caller-owned storage.
pub fn decodeIdentifier(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return tokens.decode(allocator, raw, false);
}

fn skipSelectorComments(self: *CSSParser) void {
    while (css_syntax.consumeComment(self.string, &self.pos)) {}
}

fn literal(self: *CSSParser, lit: u8) !void {
    if (self.pos >= self.string.len or self.string[self.pos] != lit) {
        return error.InvalidLiteral;
    }
    self.pos += 1;
}

/// Compatibility entry point for source-spelled declaration insertion.
pub const putDeclaration = css_declarations.putRaw;
pub const isValidLonghandValue = css_declarations.isValidLonghandValue;

/// Parse supported declarations into an owning map, including normalized
/// strings. The caller may retire declaration source afterward. Unknown at-rules
/// and malformed declarations are recovered structurally before validation.
pub fn body(self: *CSSParser, allocator: std.mem.Allocator) !DeclarationMap {
    var map = DeclarationMap.init(allocator);
    errdefer map.deinit();
    var declarations = rule_syntax.DeclarationIterator{ .input = self.string, .pos = self.pos };
    defer self.pos = declarations.pos;
    try css_declarations.parseInto(&map, &declarations);
    return map;
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
    return source.cloneWithAllocator(allocator);
}

fn parseKeyframesRule(allocator: std.mem.Allocator, source: []const u8, rule: rule_syntax.Rule) !KeyframesRule {
    const prelude = rule.prelude.slice(source);
    var cursor: usize = 0;
    css_syntax.skipWhitespaceAndComments(prelude, &cursor);
    const name = css_syntax.consumeIdentifier(prelude, &cursor) orelse return error.InvalidKeyframes;
    if (!@import("css_animation.zig").validKeyframesName(name)) return error.InvalidKeyframes;
    css_syntax.skipWhitespaceAndComments(prelude, &cursor);
    if (cursor != prelude.len) return error.InvalidKeyframes;

    var frames = std.ArrayList(Keyframe).empty;
    errdefer {
        for (frames.items) |*frame| frame.deinit();
        frames.deinit(allocator);
    }
    const block_source = rule.block.?.slice(source);
    var blocks = rule_syntax.RuleIterator{ .input = block_source, .top_level = false };
    while (blocks.next()) |block| {
        if (block.name != null or block.block == null) continue;
        var css = CSSParser{ .string = block.block.?.slice(block_source), .pos = 0, .media = .{} };
        var declarations = try css.body(allocator);
        var declarations_owned = true;
        defer if (declarations_owned) declarations.deinit();
        var selectors = std.mem.splitScalar(u8, block.prelude.slice(block_source), ',');
        var accepted: usize = 0;
        while (selectors.next()) |selector_text| {
            const offset = parseKeyframeOffset(selector_text) orelse continue;
            const properties = if (accepted == 0) declarations else try cloneDeclarationMap(allocator, &declarations);
            if (accepted == 0) declarations_owned = false;
            var frame = Keyframe{ .offset = offset, .properties = properties };
            frames.append(allocator, frame) catch |err| {
                frame.deinit();
                return err;
            };
            accepted += 1;
        }
    }
    if (frames.items.len == 0) return error.InvalidKeyframes;
    return .{ .name = name, .frames = try frames.toOwnedSlice(allocator) };
}

/// Parse one complete unforgiving selector list without a declaration block.
/// Each selector and the returned slice are independently caller-owned. Source
/// is borrowed only during this call. Invalid members reject the whole list.
/// Admission limits are 64 KiB, 256 members and 64 nested brackets/functions;
/// limits fail before recursive parsing or partial selector publication.
pub fn parseSelectorList(allocator: std.mem.Allocator, source: []const u8) ![]Selector {
    if (nesting.hasParent(source)) {
        const lowered = try nesting.lower(allocator, source, null);
        defer allocator.free(lowered);
        return parseSelectorList(allocator, lowered);
    }
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

/// Query support for exactly one complex selector, recursively rejecting any
/// invalid logical-list branch. All temporary selectors retire before return.
/// Syntax is unsupported; allocation/admission failures remain distinguishable.
pub fn supportsSelector(allocator: std.mem.Allocator, source: []const u8) supports.Error!bool {
    if (nesting.hasParent(source)) {
        const lowered = nesting.lower(allocator, source, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SelectorLimitExceeded => return error.LimitExceeded,
            else => return false,
        };
        defer allocator.free(lowered);
        return supportsSelector(allocator, lowered);
    }
    validateSelectorListInput(source) catch |err| switch (err) {
        error.SelectorLimitExceeded => return error.LimitExceeded,
        else => return false,
    };
    var parser = CSSParser{ .string = source, .pos = 0, .media = .{}, .strict_support = true };
    parser.whitespace();
    var parsed = parser.selector(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SelectorLimitExceeded => return error.LimitExceeded,
        else => return false,
    };
    defer parsed.deinit(allocator);
    parser.whitespace();
    return parser.pos == source.len;
}

fn validateSelectorListInput(source: []const u8) !void {
    if (source.len > 64 * 1024) return error.SelectorLimitExceeded;
    var stack: [64]tokens.Kind = undefined;
    var depth: usize = 0;
    var members: usize = 1;
    var iterator = tokens.Iterator{ .input = source };
    while (iterator.next()) |token| {
        if (token.kind == .bad_string or token.kind == .bad_url or
            (token.kind == .string and !token.closed) or
            ((token.kind == .open_curly or token.kind == .close_curly) and depth == 0)) return error.InvalidSelector;
        if (token.closer()) |closer| {
            if (depth == stack.len) return error.SelectorLimitExceeded;
            stack[depth] = closer;
            depth += 1;
        } else if (token.isClose()) {
            if (depth == 0 or stack[depth - 1] != token.kind) return error.InvalidSelector;
            depth -= 1;
        } else if (token.kind == .comma and depth == 0) {
            members += 1;
            if (members > 256) return error.SelectorLimitExceeded;
        }
    }
    if (depth != 0) return error.InvalidSelector;
}

/// Parse supported compound selectors, relational selectors, and descendant,
/// child, or adjacent-sibling combinator chains.
pub fn selector(self: *CSSParser, allocator: std.mem.Allocator) (std.mem.Allocator.Error || error{ InvalidSelector, InvalidLiteral, SelectorLimitExceeded })!Selector {
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
    const pseudo_class = try decodeIdentifier(allocator, try self.identifier());
    defer allocator.free(pseudo_class);
    if (!std.ascii.eqlIgnoreCase(pseudo_class, "has") or self.in_has or ancestor.pseudoElementKind() != null) return error.InvalidSelector;
    const allow_pseudo_elements = self.allow_pseudo_elements;
    self.allow_pseudo_elements = false;
    self.in_has = true;
    defer {
        self.allow_pseudo_elements = allow_pseudo_elements;
        self.in_has = false;
    }
    try self.literal('(');
    self.whitespace();

    var descendant = try self.simpleSelector(allocator);
    errdefer descendant.deinit(allocator);
    self.whitespace();
    try self.literal(')');

    return .{ .has = try HasSelector.init(allocator, ancestor, descendant) };
}

fn attributeSelectorValue(self: *CSSParser, allocator: std.mem.Allocator) ![]u8 {
    var iterator = tokens.Iterator{ .input = self.string, .cursor = self.pos };
    const token = iterator.next() orelse return error.InvalidSelector;
    if (token.kind != .ident and token.kind != .string) return error.InvalidSelector;
    if (!token.closed) return error.InvalidSelector;
    self.pos = token.end;
    return tokens.decode(allocator, token.encodedValue(self.string), token.kind == .string);
}

fn parseAttributeSelector(
    self: *CSSParser,
    allocator: std.mem.Allocator,
) !AttributeSelector {
    try self.literal('[');
    self.whitespace();

    const name = try decodeIdentifier(allocator, try self.identifier());
    _ = std.ascii.lowerString(name, name);
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

fn pseudoElementKind(name: []const u8) ?pseudo.Kind {
    if (std.ascii.eqlIgnoreCase(name, "before")) return .before;
    if (std.ascii.eqlIgnoreCase(name, "after")) return .after;
    return null;
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

    // Comments separate lexical tokens but never create a descendant
    // combinator. Decode each atom only after its token boundary is known.
    while (self.pos < self.string.len) {
        self.skipSelectorComments();
        if (self.pos == self.string.len) break;
        const char = self.string[self.pos];
        if (char == '[') {
            const attribute = try self.parseAttributeSelector(allocator);
            try appendSequenceSelector(allocator, &selectors, .{ .attribute = attribute });
            continue;
        }
        if (char == '*') {
            if (selectors.items.len != 0) return error.InvalidSelector;
            self.pos += 1;
            try appendSequenceSelector(allocator, &selectors, .{ .universal = UniversalSelector{} });
            continue;
        }
        if (char == '.') {
            self.pos += 1;
            self.skipSelectorComments();
            const name = try decodeIdentifier(allocator, try self.identifier());
            try appendSequenceSelector(allocator, &selectors, .{ .class = ClassSelector.init(name) });
            continue;
        }
        if (char == '#') {
            var iterator = tokens.Iterator{ .input = self.string, .cursor = self.pos };
            const token = iterator.next().?;
            if (token.kind != .hash or token.hash_type != .id) return error.InvalidSelector;
            self.pos = token.end;
            const name = try decodeIdentifier(allocator, token.encodedValue(self.string));
            try appendSequenceSelector(allocator, &selectors, .{ .id = IdSelector.init(name) });
            continue;
        }
        if (tokens.startsIdentifier(self.string, self.pos)) {
            if (selectors.items.len != 0) return error.InvalidSelector;
            const tag = try decodeIdentifier(allocator, try self.identifier());
            _ = std.ascii.lowerString(tag, tag);
            try appendSequenceSelector(allocator, &selectors, .{ .tag = TagSelector.init(tag) });
            continue;
        }
        if (char != ':') break;
        const pseudo_start = self.pos;
        self.pos += 1;
        const explicit_pseudo_element = self.pos < self.string.len and self.string[self.pos] == ':';
        if (explicit_pseudo_element) self.pos += 1;
        const pseudo_name = try decodeIdentifier(allocator, try self.identifier());
        defer allocator.free(pseudo_name);
        if (pseudoElementKind(pseudo_name)) |kind| {
            if (!self.allow_pseudo_elements) return error.InvalidSelector;
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
        const logical_kind: ?LogicalSelector.Kind = if (std.ascii.eqlIgnoreCase(pseudo_name, "is")) .is else if (std.ascii.eqlIgnoreCase(pseudo_name, "where")) .where else if (std.ascii.eqlIgnoreCase(pseudo_name, "not")) .not else null;
        if (logical_kind) |kind| {
            const logical = try self.logicalSelector(allocator, kind);
            try appendSequenceSelector(allocator, &selectors, .{ .logical = logical });
            continue;
        }
        if (structuralKind(pseudo_name)) |kind| {
            if (kind == .lang) {
                try self.literal('(');
                self.whitespace();
                const language = try self.attributeSelectorValue(allocator);
                defer allocator.free(language);
                self.whitespace();
                try self.literal(')');
                try appendStructuralSelector(allocator, &selectors, kind, language);
                continue;
            }
            var argument: ?[]const u8 = null;
            const requires_argument = kind == .nth_child or kind == .nth_last_child or
                kind == .nth_of_type or kind == .nth_last_of_type;
            if (self.pos < self.string.len and self.string[self.pos] == '(') {
                if (!requires_argument) return error.InvalidSelector;
                self.pos += 1;
                const start = self.pos;
                const end = css_syntax.scanToTopLevel(self.string, start, ")");
                if (end.exhausted) return error.SelectorLimitExceeded;
                if (end.delimiter == null) return error.InvalidSelector;
                self.pos = end.end + 1;
                argument = self.string[start..end.end];
                if (@import("css_anb.zig").parse(argument.?) == null) return error.InvalidSelector;
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
            // A bare :has() still has the implicit universal anchor.
            if (selectors.items.len == 0 and std.ascii.eqlIgnoreCase(pseudo_name, "has")) {
                try appendSequenceSelector(allocator, &selectors, .{ .universal = .{} });
            }
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

// Each logical member gets a complete selector parser. Its delimiter scan
// keeps commas in strings, attributes and nested functions inside the member.
fn logicalSelector(self: *CSSParser, allocator: std.mem.Allocator, kind: LogicalSelector.Kind) !LogicalSelector {
    try self.literal('(');
    var result = LogicalSelector{ .kind = kind, .selectors = .empty };
    errdefer result.deinit(allocator);
    var stack: [64]tokens.Kind = undefined;
    stack[0] = .close_paren;
    var depth: usize = 1;
    var start = self.pos;
    var members: usize = 0;
    var iterator = tokens.Iterator{ .input = self.string, .cursor = self.pos };
    while (iterator.next()) |token| {
        if ((token.kind == .comma and depth == 1) or (token.kind == .close_paren and depth == 1)) {
            members += 1;
            if (members > 256) return error.SelectorLimitExceeded;
            try self.appendLogicalMember(allocator, &result, self.string[start..token.start]);
            start = token.end;
            if (token.kind == .close_paren) {
                self.pos = token.end;
                return result;
            }
        } else if (token.closer()) |closer| {
            if (depth == stack.len) return error.SelectorLimitExceeded;
            stack[depth] = closer;
            depth += 1;
        } else if (token.isClose()) {
            if (stack[depth - 1] != token.kind) return error.InvalidSelector;
            depth -= 1;
        }
    }
    return error.InvalidSelector;
}

fn appendLogicalMember(self: *CSSParser, allocator: std.mem.Allocator, logical: *LogicalSelector, source: []const u8) !void {
    var parser = CSSParser{
        .string = source,
        .pos = 0,
        .media = self.media,
        .allow_pseudo_elements = false,
        .in_has = self.in_has,
        .strict_support = self.strict_support,
    };
    parser.whitespace();
    var member = parser.selector(allocator) catch |err| switch (err) {
        error.OutOfMemory, error.SelectorLimitExceeded => return err,
        else => return if (logical.kind == .not or self.strict_support) error.InvalidSelector else {},
    };
    errdefer member.deinit(allocator);
    parser.whitespace();
    if (parser.pos != source.len) {
        if (logical.kind == .not or self.strict_support) return error.InvalidSelector;
        member.deinit(allocator);
        return;
    }
    try logical.selectors.append(allocator, member);
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
    origin: cascade.Origin = .author,
    /// Independent source URL owner for external-sheet resource provenance.
    source_url: ?[]u8 = null,
    referrer_policy: @import("referrer.zig").Policy = .default,

    /// Rules must remain in stylesheet source order. The ordinal is local to
    /// the current rule generation and carries no source or DOM ownership.
    pub fn cascadeContext(self: CSSRule, source_order: usize) cascade.Context {
        return .{ .origin = self.origin, .specificity = self.selector.specificity(), .source_order = source_order };
    }

    pub fn deinit(self: *CSSRule, allocator: std.mem.Allocator) void {
        if (self.source_url) |url| allocator.free(url);
        Selector.deinit(&self.selector, allocator);

        self.properties.deinit();
    }

    pub fn specificity(self: CSSRule) Specificity {
        return self.selector.specificity();
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
/// Rules own their data; keyframe names borrow the stylesheet input buffer.
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

    var input = rule_syntax.RuleIterator{ .input = self.string, .pos = self.pos, .top_level = self.top_level };
    defer self.pos = input.pos;
    while (input.next()) |rule| {
        if (rule.block == null) continue;
        if (rule.name != null) {
            try self.appendAtRule(allocator, &rules, keyframes, rule, null, &.{});
        } else self.appendQualifiedRule(allocator, &rules, keyframes, rule, null) catch |err| {
            if (err == error.OutOfMemory) return err;
            // Structural parsing has already retired the complete bad rule.
            // Selector admission cannot consume any subsequent rule's source.
        };
    }
    return rules.toOwnedSlice(allocator);
}

fn appendAtRule(
    self: *CSSParser,
    allocator: std.mem.Allocator,
    rules: *std.ArrayList(CSSRule),
    keyframes: *std.ArrayList(KeyframesRule),
    rule: rule_syntax.Rule,
    parent_source: ?[]const u8,
    parents: []const Selector,
) anyerror!void {
    if (rule.block == null or self.group_depth >= 64) return;
    const name = rule.name.?.slice(self.string);
    if (css_syntax.identifierEquals(name, "keyframes")) {
        var keyframe_rule = parseKeyframesRule(allocator, self.string, rule) catch |err| {
            if (err == error.OutOfMemory) return err;
            return;
        };
        keyframes.append(allocator, keyframe_rule) catch |err| {
            keyframe_rule.deinit(allocator);
            return err;
        };
        return;
    }
    const active = if (css_syntax.identifierEquals(name, "media"))
        media_query.matches(rule.prelude.slice(self.string), self.media)
    else if (css_syntax.identifierEquals(name, "supports"))
        try supports.matches(allocator, rule.prelude.slice(self.string), supportsSelector)
    else
        false;
    if (!active) return;
    var child = CSSParser{ .string = rule.block.?.slice(self.string), .pos = 0, .media = self.media, .top_level = false, .group_depth = self.group_depth + 1 };
    if (parent_source) |source| {
        try child.appendStyleContents(allocator, rules, keyframes, source, parents);
    } else {
        const children = try child.parseWithKeyframes(allocator, keyframes);
        var transferred = false;
        defer {
            if (!transferred) for (children) |*item| item.deinit(allocator);
            allocator.free(children);
        }
        try rules.appendSlice(allocator, children);
        transferred = true;
    }
}

/// Compile one structural rule and its ordered declaration/nested-rule groups.
/// Lowered source is temporary; every compiled selector and map owns its data.
fn appendQualifiedRule(self: *CSSParser, allocator: std.mem.Allocator, rules: *std.ArrayList(CSSRule), keyframes: *std.ArrayList(KeyframesRule), rule: rule_syntax.Rule, parent_source: ?[]const u8) anyerror!void {
    if (rule.block == null or self.group_depth >= 64) return;
    const source = try nesting.lower(allocator, rule.prelude.slice(self.string), parent_source);
    defer allocator.free(source);
    const selectors = try parseSelectorList(allocator, source);
    defer {
        for (selectors) |*sel| sel.deinit(allocator);
        allocator.free(selectors);
    }
    var block = CSSParser{ .string = rule.block.?.slice(self.string), .pos = 0, .media = self.media, .group_depth = self.group_depth + 1 };
    try block.appendStyleContents(allocator, rules, keyframes, source, selectors);
}

fn appendDeclarations(allocator: std.mem.Allocator, rules: *std.ArrayList(CSSRule), parents: []const Selector, properties: *DeclarationMap) !void {
    try rules.ensureUnusedCapacity(allocator, parents.len);
    for (parents) |parent| {
        var selector_copy = try parent.clone(allocator);
        errdefer selector_copy.deinit(allocator);
        const map = try properties.clone();
        rules.appendAssumeCapacity(.{ .selector = selector_copy, .properties = map, .owned = true });
    }
}

fn appendStyleContents(self: *CSSParser, allocator: std.mem.Allocator, rules: *std.ArrayList(CSSRule), keyframes: *std.ArrayList(KeyframesRule), source: []const u8, parents: []const Selector) anyerror!void {
    const rules_start = rules.items.len;
    var iterator = rule_syntax.StyleBlockIterator{ .input = self.string };
    var properties = DeclarationMap.init(allocator);
    defer properties.deinit();
    while (iterator.next()) |item| switch (item) {
        .declaration => |declaration| try css_declarations.putRaw(&properties, declaration.name.slice(self.string), declaration.value.slice(self.string)),
        .rule => |rule| {
            if (rule.name) |name| {
                const keyword = name.slice(self.string);
                if (!css_syntax.identifierEquals(keyword, "media") and !css_syntax.identifierEquals(keyword, "supports") and !css_syntax.identifierEquals(keyword, "keyframes")) continue;
            }
            if (properties.count() != 0) try appendDeclarations(allocator, rules, parents, &properties);
            properties.deinit();
            properties = DeclarationMap.init(allocator);
            if (rule.name != null) {
                try self.appendAtRule(allocator, rules, keyframes, rule, source, parents);
            } else self.appendQualifiedRule(allocator, rules, keyframes, rule, source) catch |err| {
                if (err == error.OutOfMemory) return err;
            };
        },
    };
    if (properties.count() != 0 or rules.items.len == rules_start) try appendDeclarations(allocator, rules, parents, &properties);
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
    try std.testing.expect(rules[2].specificity().order(rules[3].specificity()) == .lt);
    try std.testing.expectEqualStrings("blue", rules[5].properties.get("color").?.value);
    // Removing a declaration cannot retire another rule's copy.
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
        "pulse",
        rules[0].properties.get("animation-name").?.value,
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
        "url(\"data:image/png;base64,AAAA\")",
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
    try std.testing.expectEqual(Specificity{ .classes = 1, .types = 2 }, rules[0].specificity());
    try std.testing.expectEqualStrings("\"legacy\"", rules[0].properties.get("content").?.value);

    try std.testing.expectEqual(pseudo.Kind.after, rules[1].selector.pseudoElementKind().?);
    try std.testing.expectEqual(Specificity{ .ids = 1, .types = 1 }, rules[1].specificity());
    try std.testing.expectEqualStrings("\"modern\"", rules[1].properties.get("content").?.value);

    try std.testing.expectEqual(pseudo.Kind.before, rules[2].selector.pseudoElementKind().?);
    try std.testing.expectEqual(Specificity{ .classes = 1, .types = 3 }, rules[2].specificity());
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
    try std.testing.expectEqualStrings("\"single quoted\"", rules[3].properties.get("content").?.value);
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
    try std.testing.expectEqualStrings("auto", rules[1].properties.get("z-index").?.value);
    try std.testing.expectEqualStrings("0", rules[2].properties.get("z-index").?.value);
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
    for (rules[0..13]) |rule| try std.testing.expectEqual(Specificity{ .classes = 1 }, rule.specificity());
    try std.testing.expectEqual(Specificity{ .classes = 1 }, rules[13].specificity());
    try std.testing.expectEqual(Specificity{ .classes = 1 }, rules[14].specificity());
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
    try std.testing.expectEqual(Specificity{ .classes = 2 }, rules[0].specificity());
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
    try std.testing.expectEqual(Specificity{ .classes = 1, .types = 1 }, selectors[0].specificity());
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

test "CSS escaped selectors retain lexical identity Unicode and compound boundaries" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, "\\64 iv, .a\\.b, #\\31 23, .caf\u{e9}, [da\\74 a-x='a\\20 b'], #a\\>b, :\\6c ang(e\\6e), div/**/.a:\\68 over.b");
    const selectors = parseSelectorList(allocator, source) catch |err| {
        allocator.free(source);
        return err;
    };
    allocator.free(source);
    defer {
        for (selectors) |*sel| sel.deinit(allocator);
        allocator.free(selectors);
    }
    try std.testing.expectEqual(8, selectors.len);
    try std.testing.expectEqualStrings("div", selectors[0].tag.tag);
    try std.testing.expectEqualStrings("a.b", selectors[1].class.class);
    try std.testing.expectEqualStrings("123", selectors[2].id.id);
    try std.testing.expectEqualStrings("caf\u{e9}", selectors[3].class.class);
    try std.testing.expectEqualStrings("data-x", selectors[4].attribute.name);
    try std.testing.expectEqualStrings("a b", selectors[4].attribute.value.?);
    try std.testing.expectEqualStrings("a>b", selectors[5].id.id);
    try std.testing.expectEqualStrings("en", selectors[6].structural.argument.?);
    try std.testing.expectEqual(Specificity{ .classes = 3, .types = 1 }, selectors[7].specificity());
    for ([_][]const u8{ ".123", "#123", "div/**/span", "[attr=123]", "[attr='bad\nstring']", ".a\\\nb", ":hover()", ":first-child()", "div[title=x]span" }) |invalid| {
        if (parseSelectorList(allocator, invalid)) |unexpected| {
            for (unexpected) |*sel| sel.deinit(allocator);
            allocator.free(unexpected);
            return error.ExpectedInvalidSelector;
        } else |err| try std.testing.expect(err != error.OutOfMemory);
    }
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const list = try parseSelectorList(a, "\\64 iv.foo\\:bar[da\\74 a-x='a\\20 b']:\\6e ot(.hi\\#d), .caf\u{e9}");
            defer {
                for (list) |*sel| sel.deinit(a);
                a.free(list);
            }
        }
    }.run, .{});
}
