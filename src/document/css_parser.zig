//! Parser for Zibra's intentionally small CSS subset.
//!
//! Property names and declared values in returned rules normally borrow the
//! input stylesheet; shorthand-generated property names and defaults are
//! static slices. Selectors own their normalized names, selector-sequence lists,
//! descendant-chain lists, and relational-selector components. The stylesheet
//! therefore must outlive its rules, and each owned rule must be deinitialized.

const std = @import("std");
const selector_mod = @import("selector.zig");
const pseudo = @import("pseudo.zig");
const css_length = @import("length.zig");
const css_color = @import("color.zig");
const background_image = @import("background_image.zig");
const css_syntax = @import("css_syntax.zig");
const css_properties = @import("css_properties.zig");
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

pub const IMPORTANT_PRIORITY: u32 = 10_000;
pub const INLINE_STYLE_PRIORITY: u32 = 1_000;
pub const MatchContext = selector_mod.MatchContext;
pub const HasMatchCache = selector_mod.HasMatchCache;

/// Values supplied by the browsing context while parsing conditional rules.
/// A null width is used by parser-only consumers that have no viewport; width
/// media features are then recognized but inactive.
pub const MediaEnvironment = struct {
    prefers_dark: bool = false,
    forced_colors: bool = false,
    viewport_width_css: ?f64 = null,
    viewport_height_css: ?f64 = null,
    // Desktop screens are color displays. Keep these explicit rather than
    // deriving them from the viewport so media queries remain deterministic
    // in headless and screenshot modes.
    color_depth: u8 = 24,
    monochrome_depth: u8 = 0,
};

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

/// Remove CSS whitespace and complete comments from the ends of one borrowed
/// value. Interior comments remain in source storage, but the common trailing
/// declaration-comment form becomes the exact authored token slice.
fn trimValueTrivia(input: []const u8) []const u8 {
    var start: usize = 0;
    var end = input.len;
    while (true) {
        while (start < end and std.ascii.isWhitespace(input[start])) start += 1;
        if (start + 1 < end and input[start] == '/' and input[start + 1] == '*') {
            const close = std.mem.indexOfPos(u8, input, start + 2, "*/") orelse return input[start..end];
            start = close + 2;
            continue;
        }
        break;
    }
    while (true) {
        while (end > start and std.ascii.isWhitespace(input[end - 1])) end -= 1;
        if (end >= start + 2 and input[end - 2] == '*' and input[end - 1] == '/') {
            const open = std.mem.lastIndexOf(u8, input[start .. end - 2], "/*") orelse break;
            end = start + open;
            continue;
        }
        break;
    }
    return input[start..end];
}

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
/// class and ID selectors miss their elements.
fn decodeIdentifier(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
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
    const val = try self.value();
    return .{ .property = property, .value = val };
}

const FontShorthand = struct {
    style: []const u8 = "normal",
    variant: []const u8 = "normal",
    weight: []const u8 = "normal",
    stretch: []const u8 = "normal",
    size: []const u8,
    line_height: []const u8 = "normal",
    family: []const u8,
};

fn isSupportedFontSize(font_size: []const u8) bool {
    const length = css_length.parse(font_size) orelse return false;
    return length.unit == .px or length.unit == .mm or length.unit == .em or length.unit == .percent;
}

fn isSupportedFontLineHeight(line_height: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(line_height, "normal")) return true;
    if (css_length.parse(line_height) != null) return true;
    const number = std.fmt.parseFloat(f64, line_height) catch return false;
    return std.math.isFinite(number) and number >= 0;
}

fn isFontWeight(token: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(token, "normal") or
        std.ascii.eqlIgnoreCase(token, "bold") or
        std.ascii.eqlIgnoreCase(token, "bolder") or
        std.ascii.eqlIgnoreCase(token, "lighter")) return true;
    const weight = std.fmt.parseInt(u16, token, 10) catch return false;
    return weight >= 100 and weight <= 900 and weight % 100 == 0;
}

fn isFontStretch(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "normal") or
        std.ascii.eqlIgnoreCase(token, "ultra-condensed") or
        std.ascii.eqlIgnoreCase(token, "extra-condensed") or
        std.ascii.eqlIgnoreCase(token, "condensed") or
        std.ascii.eqlIgnoreCase(token, "semi-condensed") or
        std.ascii.eqlIgnoreCase(token, "semi-expanded") or
        std.ascii.eqlIgnoreCase(token, "expanded") or
        std.ascii.eqlIgnoreCase(token, "extra-expanded") or
        std.ascii.eqlIgnoreCase(token, "ultra-expanded");
}

/// Parse the standard font shorthand ordering: optional style, variant,
/// weight, and stretch; required size with an optional `/line-height`; and a
/// family/fallback list. The family is retained as the original suffix so
/// quoted family names and commas remain intact.
fn parseFontShorthand(declaration_value: []const u8) ?FontShorthand {
    var result = FontShorthand{ .size = undefined, .family = undefined };
    var saw_style = false;
    var saw_variant = false;
    var saw_weight = false;
    var saw_stretch = false;
    var pos: usize = 0;

    while (pos < declaration_value.len) {
        while (pos < declaration_value.len and std.ascii.isWhitespace(declaration_value[pos])) : (pos += 1) {}
        if (pos == declaration_value.len) return null;

        const token_start = pos;
        while (pos < declaration_value.len and !std.ascii.isWhitespace(declaration_value[pos])) : (pos += 1) {}
        const token = declaration_value[token_start..pos];

        var size_token: ?[]const u8 = null;
        var line_height_token: ?[]const u8 = null;
        var family_start = pos;

        if (std.mem.indexOfScalar(u8, token, '/')) |slash| {
            const possible_size = token[0..slash];
            const possible_line_height = token[slash + 1 ..];
            if (!isSupportedFontSize(possible_size)) return null;
            size_token = possible_size;
            if (possible_line_height.len != 0) {
                if (!isSupportedFontLineHeight(possible_line_height)) return null;
                line_height_token = possible_line_height;
            } else {
                var line_start = pos;
                while (line_start < declaration_value.len and
                    std.ascii.isWhitespace(declaration_value[line_start])) : (line_start += 1)
                {}
                const line_end = blk: {
                    var end = line_start;
                    while (end < declaration_value.len and !std.ascii.isWhitespace(declaration_value[end])) : (end += 1) {}
                    break :blk end;
                };
                const separate_line_height = declaration_value[line_start..line_end];
                if (!isSupportedFontLineHeight(separate_line_height)) return null;
                line_height_token = separate_line_height;
                family_start = line_end;
                pos = line_end;
            }
        } else if (isSupportedFontSize(token)) {
            size_token = token;
            var after_size = pos;
            while (after_size < declaration_value.len and std.ascii.isWhitespace(declaration_value[after_size])) : (after_size += 1) {}
            if (after_size < declaration_value.len and declaration_value[after_size] == '/') {
                after_size += 1;
                while (after_size < declaration_value.len and std.ascii.isWhitespace(declaration_value[after_size])) : (after_size += 1) {}
                const line_start = after_size;
                while (after_size < declaration_value.len and !std.ascii.isWhitespace(declaration_value[after_size])) : (after_size += 1) {}
                const possible_line_height = declaration_value[line_start..after_size];
                if (!isSupportedFontLineHeight(possible_line_height)) return null;
                line_height_token = possible_line_height;
                family_start = after_size;
            }
        }

        if (size_token) |size| {
            const family = std.mem.trim(u8, declaration_value[family_start..], " \t\r\n");
            if (family.len == 0) return null;
            result.size = size;
            if (line_height_token) |line_height| result.line_height = line_height;
            result.family = family;
            return result;
        }

        if (std.ascii.eqlIgnoreCase(token, "italic") or
            std.ascii.eqlIgnoreCase(token, "oblique"))
        {
            if (saw_style) return null;
            result.style = if (std.ascii.eqlIgnoreCase(token, "oblique")) "oblique" else "italic";
            saw_style = true;
        } else if (std.ascii.eqlIgnoreCase(token, "small-caps")) {
            if (saw_variant) return null;
            result.variant = "small-caps";
            saw_variant = true;
        } else if (std.ascii.eqlIgnoreCase(token, "normal")) {
            // `normal` is valid for each optional font component. It does
            // not reserve one component, since another optional component may
            // still appear later in the shorthand.
        } else if (isFontWeight(token)) {
            if (saw_weight) return null;
            if (std.ascii.eqlIgnoreCase(token, "normal")) {
                result.weight = "normal";
            } else if (std.ascii.eqlIgnoreCase(token, "bold")) {
                result.weight = "bold";
            } else {
                result.weight = token;
            }
            saw_weight = true;
        } else if (isFontStretch(token)) {
            if (saw_stretch) return null;
            result.stretch = token;
            saw_stretch = true;
        } else {
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

// The style application owns defaults and inheritance, while the parser owns
// the subset of names whose grammar it can validate before cascade. Keeping
// this table here lets escaped identifiers resolve without allocating a
// normalized copy, so rule and inline-style values keep borrowing source.
const supported_shorthand_names = [_][]const u8{
    "font",   "background", "margin",       "padding",       "border-width", "border-style", "border-color",
    "border", "border-top", "border-right", "border-bottom", "border-left",  "list-style",
};

/// Return the canonical static property spelling for a supported CSS name.
/// CSS property identifiers are ASCII-case-insensitive and may contain CSS
/// escapes, but unsupported names intentionally have no effect in Zibra.
fn canonicalPropertyName(raw_property: []const u8) ?[]const u8 {
    for (css_properties.computed) |property| {
        if (css_syntax.identifierEquals(raw_property, property.name)) return property.name;
    }
    for (supported_shorthand_names) |candidate| {
        if (css_syntax.identifierEquals(raw_property, candidate)) return candidate;
    }
    return null;
}

fn isCssWideKeyword(raw_value: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    return std.ascii.eqlIgnoreCase(trimmed, "inherit") or
        std.ascii.eqlIgnoreCase(trimmed, "initial") or
        std.ascii.eqlIgnoreCase(trimmed, "unset");
}

fn isUnitlessZero(raw_value: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    const number = std.fmt.parseFloat(f64, trimmed) catch return false;
    return std.math.isFinite(number) and number == 0;
}

fn isNonnegativeLength(raw_value: []const u8) bool {
    return isUnitlessZero(raw_value) or css_length.parse(raw_value) != null;
}

fn isSignedLength(raw_value: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    if (isNonnegativeLength(trimmed)) return true;
    if (trimmed.len < 2 or (trimmed[0] != '-' and trimmed[0] != '+')) return false;
    return css_length.parse(trimmed[1..]) != null;
}

fn isAutomaticOrNonnegativeLength(raw_value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw_value, " \t\r\n\x0c"), "auto") or
        isNonnegativeLength(raw_value);
}

fn isAutomaticOrSignedLength(raw_value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw_value, " \t\r\n\x0c"), "auto") or
        isSignedLength(raw_value);
}

/// CSS `z-index` accepts `auto` or one signed integer. Keep the authored
/// token in the declaration map—the style and paint phases need to retain the
/// distinction between the initial `auto` value and an explicit `0`.
fn isZIndex(raw_value: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return true;
    _ = std.fmt.parseInt(i32, trimmed, 10) catch return false;
    return true;
}

/// Zibra currently paints only the default square marker. Retain the CSS
/// distinction needed to suppress that marker without claiming support for
/// the full list-style grammar.
fn isSupportedListStyleType(raw_value: []const u8) bool {
    const style_type = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    return std.ascii.eqlIgnoreCase(style_type, "disc") or
        std.ascii.eqlIgnoreCase(style_type, "none");
}

fn isCursorValue(raw_value: []const u8) bool {
    const cursor_value = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    const supported = [_][]const u8{
        "auto",       "default",    "none",      "context-menu", "help",        "pointer",
        "progress",   "wait",       "cell",      "crosshair",    "text",        "vertical-text",
        "alias",      "copy",       "move",      "no-drop",      "not-allowed", "e-resize",
        "n-resize",   "ne-resize",  "nw-resize", "s-resize",     "se-resize",   "sw-resize",
        "w-resize",   "ew-resize",  "ns-resize", "nesw-resize",  "nwse-resize", "col-resize",
        "row-resize", "all-scroll",
    };
    for (supported) |candidate| {
        if (std.ascii.eqlIgnoreCase(cursor_value, candidate)) return true;
    }
    return false;
}

fn splitValueTokens(raw_value: []const u8, tokens: *[4][]const u8) ?usize {
    var count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, raw_value, " \t\r\n\x0c");
    while (iterator.next()) |token| {
        if (count == tokens.len) return null;
        tokens[count] = token;
        count += 1;
    }
    return if (count == 0) null else count;
}

fn isBorderColor(raw_value: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    return std.ascii.eqlIgnoreCase(trimmed, "currentcolor") or css_color.parse(trimmed) != null;
}

fn validBackgroundPosition(raw_value: []const u8) bool {
    var tokens: [4][]const u8 = undefined;
    const count = splitValueTokens(raw_value, &tokens) orelse return false;
    if (count > 2) return false;
    for (tokens[0..count]) |token| if (!isBackgroundPosition(token)) return false;
    return true;
}

/// Accept the bounded generated-content grammar supported by this browser.
/// The parser retains the authored string—including escapes—so later stages
/// can decode it without re-parsing an arbitrary CSS value list.
fn isQuotedContentString(raw_value: []const u8) bool {
    const content_value = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    if (content_value.len < 2) return false;
    const quote = content_value[0];
    if (quote != '\'' and quote != '"') return false;
    if (content_value[content_value.len - 1] != quote) return false;

    var cursor: usize = 1;
    while (cursor + 1 < content_value.len) {
        if (content_value[cursor] == quote) return false;
        if (content_value[cursor] == '\\') {
            cursor += 1;
            if (cursor >= content_value.len - 1) return false;
        }
        cursor += 1;
    }
    return true;
}

/// Validate values whose unsupported grammar would otherwise replace a valid
/// earlier declaration in the cascade. Other supported values stay permissive
/// until a focused feature owns their used-value grammar.
fn isValidLonghandValue(property: []const u8, raw_value: []const u8) bool {
    if (isCssWideKeyword(raw_value)) return true;

    if (std.mem.eql(u8, property, "width") or std.mem.eql(u8, property, "height")) {
        return isAutomaticOrNonnegativeLength(raw_value);
    }
    if (std.mem.eql(u8, property, "min-width") or std.mem.eql(u8, property, "min-height")) {
        return isNonnegativeLength(raw_value);
    }
    if (std.mem.eql(u8, property, "max-width") or std.mem.eql(u8, property, "max-height")) {
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw_value, " \t\r\n\x0c"), "none") or
            isNonnegativeLength(raw_value);
    }
    if (std.mem.eql(u8, property, "top") or std.mem.eql(u8, property, "right") or
        std.mem.eql(u8, property, "bottom") or std.mem.eql(u8, property, "left"))
    {
        return isAutomaticOrSignedLength(raw_value);
    }
    if (std.mem.eql(u8, property, "z-index")) return isZIndex(raw_value);
    if (std.mem.eql(u8, property, "cursor")) return isCursorValue(raw_value);
    if (std.mem.startsWith(u8, property, "margin-")) return isAutomaticOrSignedLength(raw_value);
    if (std.mem.startsWith(u8, property, "padding-")) return isNonnegativeLength(raw_value);
    if (std.mem.endsWith(u8, property, "-width") and std.mem.startsWith(u8, property, "border-")) {
        return isBorderWidth(raw_value);
    }
    if (std.mem.endsWith(u8, property, "-style") and std.mem.startsWith(u8, property, "border-")) {
        return isBorderStyle(raw_value);
    }
    if (std.mem.endsWith(u8, property, "-color") and std.mem.startsWith(u8, property, "border-")) {
        return isBorderColor(raw_value);
    }
    if (std.mem.eql(u8, property, "color") or std.mem.eql(u8, property, "background-color")) {
        return isBorderColor(raw_value);
    }
    if (std.mem.eql(u8, property, "background-image")) {
        const trimmed = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
        return std.ascii.eqlIgnoreCase(trimmed, "none") or background_image.parseUrl(trimmed) != null;
    }
    if (std.mem.eql(u8, property, "background-size")) return background_image.parseSize(raw_value) != null;
    if (std.mem.eql(u8, property, "background-repeat")) return background_image.parseRepeat(raw_value) != null;
    if (std.mem.eql(u8, property, "background-position")) return validBackgroundPosition(raw_value);
    if (std.mem.eql(u8, property, "background-attachment")) return isBackgroundAttachment(raw_value);
    if (std.mem.eql(u8, property, "font-size")) return isNonnegativeLength(raw_value);
    if (std.mem.eql(u8, property, "line-height")) return isSupportedFontLineHeight(raw_value);
    if (std.mem.eql(u8, property, "white-space")) {
        const trimmed_value = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
        return std.ascii.eqlIgnoreCase(trimmed_value, "normal") or
            std.ascii.eqlIgnoreCase(trimmed_value, "pre") or
            std.ascii.eqlIgnoreCase(trimmed_value, "pre-wrap") or
            std.ascii.eqlIgnoreCase(trimmed_value, "pre-line") or
            std.ascii.eqlIgnoreCase(trimmed_value, "nowrap");
    }
    if (std.mem.eql(u8, property, "vertical-align")) {
        const alignment = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
        return std.ascii.eqlIgnoreCase(alignment, "baseline") or
            std.ascii.eqlIgnoreCase(alignment, "bottom") or
            // Inline-level boxes may be shifted by a signed length, which is
            // used by Acid3 to place its bucket blocks relative to the text
            // baseline.
            isSignedLength(alignment);
    }
    if (std.mem.eql(u8, property, "list-style-type")) return isSupportedListStyleType(raw_value);
    if (std.mem.eql(u8, property, "content")) {
        const content_value = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
        return std.ascii.eqlIgnoreCase(content_value, "normal") or
            std.ascii.eqlIgnoreCase(content_value, "none") or
            isQuotedContentString(content_value);
    }
    return std.mem.trim(u8, raw_value, " \t\r\n\x0c").len != 0;
}

fn putLonghand(map: *DeclarationMap, property: []const u8, declaration: Declaration) !void {
    if (map.get(property)) |existing| {
        // Within one declaration block, an earlier important longhand cannot
        // be reset by a later normal longhand or shorthand expansion.
        if (existing.important and !declaration.important) return;
    }
    try map.put(property, declaration);
}

const BoxSide = enum { top, right, bottom, left };

fn boxSideProperty(prefix: []const u8, side: BoxSide) []const u8 {
    return switch (side) {
        .top => if (std.mem.eql(u8, prefix, "margin")) "margin-top" else if (std.mem.eql(u8, prefix, "padding")) "padding-top" else "border-top-width",
        .right => if (std.mem.eql(u8, prefix, "margin")) "margin-right" else if (std.mem.eql(u8, prefix, "padding")) "padding-right" else "border-right-width",
        .bottom => if (std.mem.eql(u8, prefix, "margin")) "margin-bottom" else if (std.mem.eql(u8, prefix, "padding")) "padding-bottom" else "border-bottom-width",
        .left => if (std.mem.eql(u8, prefix, "margin")) "margin-left" else if (std.mem.eql(u8, prefix, "padding")) "padding-left" else "border-left-width",
    };
}

fn splitShorthand(raw_value: []const u8, tokens: *[4][]const u8) ?usize {
    var count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, raw_value, " \t\r\n\x0c");
    while (iterator.next()) |token| {
        if (count == tokens.len) return null;
        tokens[count] = token;
        count += 1;
    }
    return if (count > 0) count else null;
}

fn expandBoxShorthand(
    map: *DeclarationMap,
    prefix: []const u8,
    raw_value: []const u8,
    declaration: Declaration,
) !bool {
    var tokens: [4][]const u8 = undefined;
    const count = splitShorthand(raw_value, &tokens) orelse return false;
    const values = switch (count) {
        1 => [4][]const u8{ tokens[0], tokens[0], tokens[0], tokens[0] },
        2 => [4][]const u8{ tokens[0], tokens[1], tokens[0], tokens[1] },
        3 => [4][]const u8{ tokens[0], tokens[1], tokens[2], tokens[1] },
        4 => [4][]const u8{ tokens[0], tokens[1], tokens[2], tokens[3] },
        else => return false,
    };
    const sides = [_]BoxSide{ .top, .right, .bottom, .left };
    for (sides, values) |side, side_value| {
        try putLonghand(map, boxSideProperty(prefix, side), .{
            .value = side_value,
            .important = declaration.important,
        });
    }
    return true;
}

fn isBorderStyle(raw_value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(raw_value, "none") or
        std.ascii.eqlIgnoreCase(raw_value, "hidden") or
        std.ascii.eqlIgnoreCase(raw_value, "dotted") or
        std.ascii.eqlIgnoreCase(raw_value, "dashed") or
        std.ascii.eqlIgnoreCase(raw_value, "solid") or
        std.ascii.eqlIgnoreCase(raw_value, "double") or
        std.ascii.eqlIgnoreCase(raw_value, "groove") or
        std.ascii.eqlIgnoreCase(raw_value, "ridge") or
        std.ascii.eqlIgnoreCase(raw_value, "inset") or
        std.ascii.eqlIgnoreCase(raw_value, "outset");
}

fn isBorderWidth(raw_value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(raw_value, "thin") or
        std.ascii.eqlIgnoreCase(raw_value, "medium") or
        std.ascii.eqlIgnoreCase(raw_value, "thick") or
        std.mem.eql(u8, std.mem.trim(u8, raw_value, " \t\r\n"), "0")) return true;
    return css_length.parse(raw_value) != null;
}

fn borderSideProperty(kind: []const u8, side: BoxSide) []const u8 {
    if (std.mem.eql(u8, kind, "width")) {
        return switch (side) {
            .top => "border-top-width",
            .right => "border-right-width",
            .bottom => "border-bottom-width",
            .left => "border-left-width",
        };
    }
    if (std.mem.eql(u8, kind, "style")) {
        return switch (side) {
            .top => "border-top-style",
            .right => "border-right-style",
            .bottom => "border-bottom-style",
            .left => "border-left-style",
        };
    }
    return switch (side) {
        .top => "border-top-color",
        .right => "border-right-color",
        .bottom => "border-bottom-color",
        .left => "border-left-color",
    };
}

fn expandBorderWidthOrStyle(
    map: *DeclarationMap,
    kind: []const u8,
    raw_value: []const u8,
    declaration: Declaration,
) !bool {
    var tokens: [4][]const u8 = undefined;
    const count = splitShorthand(raw_value, &tokens) orelse return false;
    const values = switch (count) {
        1 => [4][]const u8{ tokens[0], tokens[0], tokens[0], tokens[0] },
        2 => [4][]const u8{ tokens[0], tokens[1], tokens[0], tokens[1] },
        3 => [4][]const u8{ tokens[0], tokens[1], tokens[2], tokens[1] },
        4 => [4][]const u8{ tokens[0], tokens[1], tokens[2], tokens[3] },
        else => return false,
    };
    const sides = [_]BoxSide{ .top, .right, .bottom, .left };
    for (values) |side_value| {
        if (std.mem.eql(u8, kind, "width")) {
            if (!isBorderWidth(side_value)) return false;
        } else if (!isBorderStyle(side_value)) return false;
    }
    for (sides, values) |side, side_value| {
        try putLonghand(map, borderSideProperty(kind, side), .{
            .value = side_value,
            .important = declaration.important,
        });
    }
    return true;
}

fn expandBorderColor(
    map: *DeclarationMap,
    raw_value: []const u8,
    declaration: Declaration,
) !bool {
    var tokens: [4][]const u8 = undefined;
    const count = splitShorthand(raw_value, &tokens) orelse return false;
    const values = switch (count) {
        1 => [4][]const u8{ tokens[0], tokens[0], tokens[0], tokens[0] },
        2 => [4][]const u8{ tokens[0], tokens[1], tokens[0], tokens[1] },
        3 => [4][]const u8{ tokens[0], tokens[1], tokens[2], tokens[1] },
        4 => [4][]const u8{ tokens[0], tokens[1], tokens[2], tokens[3] },
        else => return false,
    };
    const sides = [_]BoxSide{ .top, .right, .bottom, .left };
    for (sides, values) |side, side_value| {
        try putLonghand(map, borderSideProperty("color", side), .{
            .value = side_value,
            .important = declaration.important,
        });
    }
    return true;
}

fn expandBorder(
    map: *DeclarationMap,
    property: []const u8,
    raw_value: []const u8,
    declaration: Declaration,
) !bool {
    var tokens: [4][]const u8 = undefined;
    const count = splitShorthand(raw_value, &tokens) orelse return false;
    if (count > 3) return false;

    var width: []const u8 = "medium";
    var style: []const u8 = "none";
    var color: []const u8 = "currentColor";
    for (tokens[0..count]) |token| {
        if (isBorderWidth(token)) {
            width = token;
        } else if (isBorderStyle(token)) {
            style = token;
        } else {
            color = token;
        }
    }

    const side: ?BoxSide = if (std.ascii.eqlIgnoreCase(property, "border"))
        null
    else if (std.ascii.eqlIgnoreCase(property, "border-top"))
        .top
    else if (std.ascii.eqlIgnoreCase(property, "border-right"))
        .right
    else if (std.ascii.eqlIgnoreCase(property, "border-bottom"))
        .bottom
    else
        .left;
    const sides = [_]BoxSide{ .top, .right, .bottom, .left };
    for (sides) |candidate| {
        if (side) |selected| if (candidate != selected) continue;
        try putLonghand(map, borderSideProperty("width", candidate), .{ .value = width, .important = declaration.important });
        try putLonghand(map, borderSideProperty("style", candidate), .{ .value = style, .important = declaration.important });
        try putLonghand(map, borderSideProperty("color", candidate), .{ .value = color, .important = declaration.important });
    }
    return true;
}

const BackgroundTokenIterator = struct {
    input: []const u8,
    pos: usize = 0,

    fn next(self: *BackgroundTokenIterator) ?[]const u8 {
        css_syntax.skipWhitespaceAndComments(self.input, &self.pos);
        if (self.pos >= self.input.len) return null;
        if (self.input[self.pos] == '/') {
            self.pos += 1;
            return self.input[self.pos - 1 .. self.pos];
        }

        const start = self.pos;
        var depth: usize = 0;
        var quote: ?u8 = null;
        var escaped = false;
        while (self.pos < self.input.len) {
            const char = self.input[self.pos];
            if (quote) |delimiter| {
                if (escaped) {
                    escaped = false;
                } else if (char == '\\') {
                    escaped = true;
                } else if (char == delimiter) {
                    quote = null;
                }
            } else if (char == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '*') {
                if (depth == 0) break;
                _ = css_syntax.consumeComment(self.input, &self.pos);
                continue;
            } else if (char == '\\') {
                if (!css_syntax.consumeEscape(self.input, &self.pos)) self.pos += 1;
                continue;
            } else switch (char) {
                '\'', '"' => quote = char,
                '(' => depth += 1,
                ')' => if (depth > 0) {
                    depth -= 1;
                },
                '/' => if (depth == 0) break,
                else => if (depth == 0 and std.ascii.isWhitespace(char)) break,
            }
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }
};

fn isBackgroundRepeat(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "repeat") or
        std.ascii.eqlIgnoreCase(token, "no-repeat") or
        std.ascii.eqlIgnoreCase(token, "repeat-x") or
        std.ascii.eqlIgnoreCase(token, "repeat-y");
}

fn isBackgroundAttachment(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "scroll") or
        std.ascii.eqlIgnoreCase(token, "fixed") or
        std.ascii.eqlIgnoreCase(token, "local");
}

fn isBackgroundPosition(token: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(token, "left") or
        std.ascii.eqlIgnoreCase(token, "center") or
        std.ascii.eqlIgnoreCase(token, "right") or
        std.ascii.eqlIgnoreCase(token, "top") or
        std.ascii.eqlIgnoreCase(token, "bottom") or
        std.mem.eql(u8, token, "0"))
    {
        return true;
    }
    return css_length.parse(token) != null;
}

/// Expand the single-layer subset that the renderer can consume. Every value
/// retains a borrowed slice of the declaration source, matching other parsed
/// declarations; omitted components reset to their CSS initial values.
fn expandBackground(
    map: *DeclarationMap,
    raw_value: []const u8,
    declaration: Declaration,
) !bool {
    var color: []const u8 = "transparent";
    var image: []const u8 = "none";
    var size: []const u8 = "auto";
    var repeat: []const u8 = "repeat";
    var attachment: []const u8 = "scroll";
    var position: []const u8 = "0 0";
    var iterator = BackgroundTokenIterator{ .input = raw_value };
    var after_slash = false;
    var size_start: ?usize = null;
    var saw_color = false;
    var saw_image = false;
    var saw_repeat = false;
    var saw_attachment = false;
    var position_count: usize = 0;
    var position_start: ?usize = null;
    var position_end: usize = 0;

    while (iterator.next()) |token| {
        if (std.mem.eql(u8, token, "/")) {
            if (after_slash) return false;
            after_slash = true;
            continue;
        }
        if (after_slash) {
            if (size_start == null) size_start = @intFromPtr(token.ptr) - @intFromPtr(raw_value.ptr);
            continue;
        }
        if (css_color.parse(token) != null) {
            if (saw_color) return false;
            saw_color = true;
            color = token;
        } else if (std.ascii.eqlIgnoreCase(token, "none") or background_image.parseUrl(token) != null) {
            if (saw_image) return false;
            saw_image = true;
            image = token;
        } else if (isBackgroundRepeat(token)) {
            if (saw_repeat) return false;
            saw_repeat = true;
            repeat = token;
        } else if (isBackgroundAttachment(token)) {
            if (saw_attachment) return false;
            saw_attachment = true;
            attachment = token;
        } else if (isBackgroundPosition(token)) {
            if (position_count == 2) return false;
            position_count += 1;
            const token_start = @intFromPtr(token.ptr) - @intFromPtr(raw_value.ptr);
            if (position_start == null) position_start = token_start;
            position_end = token_start + token.len;
        } else return false;
    }

    if (position_start) |start| position = raw_value[start..position_end];

    if (size_start) |start| {
        const candidate = std.mem.trim(u8, raw_value[start..], " \t\r\n");
        if (background_image.parseSize(candidate) == null) return false;
        size = candidate;
    } else if (after_slash) {
        return false;
    }

    try putLonghand(map, "background-color", .{ .value = color, .important = declaration.important });
    try putLonghand(map, "background-image", .{ .value = image, .important = declaration.important });
    try putLonghand(map, "background-size", .{ .value = size, .important = declaration.important });
    try putLonghand(map, "background-repeat", .{ .value = repeat, .important = declaration.important });
    try putLonghand(map, "background-position", .{ .value = position, .important = declaration.important });
    try putLonghand(map, "background-attachment", .{ .value = attachment, .important = declaration.important });
    return true;
}

/// Apply one declaration in source order. Shorthands expand here so inline
/// attributes and stylesheet rules share identical precedence behavior and
/// every generated longhand retains the shorthand's importance.
fn putDeclaration(
    map: *DeclarationMap,
    raw_property: []const u8,
    raw_value: []const u8,
) !void {
    const property = canonicalPropertyName(raw_property) orelse return;
    const declaration = parseDeclarationValue(raw_value) orelse return;
    if (std.ascii.eqlIgnoreCase(property, "font")) {
        const font = parseFontShorthand(declaration.value) orelse return;
        try putLonghand(map, "font-style", .{ .value = font.style, .important = declaration.important });
        try putLonghand(map, "font-variant", .{ .value = font.variant, .important = declaration.important });
        try putLonghand(map, "font-weight", .{ .value = font.weight, .important = declaration.important });
        try putLonghand(map, "font-stretch", .{ .value = font.stretch, .important = declaration.important });
        try putLonghand(map, "font-size", .{ .value = font.size, .important = declaration.important });
        try putLonghand(map, "line-height", .{ .value = font.line_height, .important = declaration.important });
        try putLonghand(map, "font-family", .{ .value = font.family, .important = declaration.important });
        return;
    }

    if (std.ascii.eqlIgnoreCase(property, "background")) {
        if (try expandBackground(map, declaration.value, declaration)) return;
        return;
    }

    if (std.ascii.eqlIgnoreCase(property, "margin") or
        std.ascii.eqlIgnoreCase(property, "padding"))
    {
        const prefix = if (std.ascii.eqlIgnoreCase(property, "margin")) "margin" else "padding";
        if (try expandBoxShorthand(map, prefix, declaration.value, declaration)) return;
        return;
    }
    if (std.ascii.eqlIgnoreCase(property, "border-width") or
        std.ascii.eqlIgnoreCase(property, "border-style"))
    {
        const kind = if (std.ascii.eqlIgnoreCase(property, "border-width")) "width" else "style";
        if (try expandBorderWidthOrStyle(map, kind, declaration.value, declaration)) return;
        return;
    }
    if (std.ascii.eqlIgnoreCase(property, "border-color")) {
        if (try expandBorderColor(map, declaration.value, declaration)) return;
        return;
    }
    if (std.ascii.eqlIgnoreCase(property, "border") or
        std.ascii.eqlIgnoreCase(property, "border-top") or
        std.ascii.eqlIgnoreCase(property, "border-right") or
        std.ascii.eqlIgnoreCase(property, "border-bottom") or
        std.ascii.eqlIgnoreCase(property, "border-left"))
    {
        if (try expandBorder(map, property, declaration.value, declaration)) return;
        return;
    }
    if (std.ascii.eqlIgnoreCase(property, "list-style")) {
        if (isCssWideKeyword(declaration.value) or isSupportedListStyleType(declaration.value)) {
            try putLonghand(map, "list-style-type", .{
                .value = declaration.value,
                .important = declaration.important,
            });
        }
        return;
    }
    if (!isValidLonghandValue(property, declaration.value)) return;
    try putLonghand(map, property, declaration);
}

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

fn mediaIdentifierChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '_';
}

fn skipMediaWhitespace(text: []const u8, cursor: *usize) void {
    while (cursor.* < text.len and std.ascii.isWhitespace(text[cursor.*])) {
        cursor.* += 1;
    }
}

fn consumeMediaKeyword(text: []const u8, cursor: *usize, keyword: []const u8) bool {
    if (text.len - cursor.* < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[cursor.* .. cursor.* + keyword.len], keyword)) return false;
    const end = cursor.* + keyword.len;
    if (end < text.len and mediaIdentifierChar(text[end])) return false;
    cursor.* = end;
    return true;
}

fn mediaIdentifier(text: []const u8, cursor: *usize) ?[]const u8 {
    const start = cursor.*;
    while (cursor.* < text.len and mediaIdentifierChar(text[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* == start) return null;
    return text[start..cursor.*];
}

fn parseMediaPixelLength(raw_value: []const u8) ?f64 {
    const value_text = std.mem.trim(u8, raw_value, " \t\r\n");
    const parsed_length = css_length.parse(value_text) orelse return null;
    return switch (parsed_length.unit) {
        .px, .mm => css_length.resolveLength(parsed_length, .{}),
        // Media-query em units are resolved against the initial font size.
        // The browser's default is 16 CSS px; unlike element em values this
        // does not depend on the matched element's inherited style.
        .em => parsed_length.value * 16.0,
        .percent => null,
    };
}

fn parseMediaInteger(raw_value: []const u8) ?u8 {
    const value_text = std.mem.trim(u8, raw_value, " \t\r\n");
    const parsed = std.fmt.parseInt(u16, value_text, 10) catch return null;
    if (parsed > std.math.maxInt(u8)) return null;
    return @intCast(parsed);
}

fn mediaWidthsEqual(actual: f64, expected: f64) bool {
    const magnitude = @max(@max(@abs(actual), @abs(expected)), 1.0);
    // Viewport zoom is stored as f32, so values such as 800 / 1.6 carry a
    // small representation error. This tolerance is far below one device
    // pixel while preserving the author-visible equality boundary.
    return @abs(actual - expected) <= magnitude * 0.000001;
}

fn mediaFeatureMatches(self: *const CSSParser, raw_feature: []const u8) ?bool {
    const feature = std.mem.trim(u8, raw_feature, " \t\r\n");
    // Boolean media features omit a colon and value entirely.
    if (std.ascii.eqlIgnoreCase(feature, "color")) return self.media.color_depth > 0;
    if (std.ascii.eqlIgnoreCase(feature, "monochrome")) return self.media.monochrome_depth > 0;

    const colon = std.mem.indexOfScalar(u8, feature, ':') orelse return null;
    const name = std.mem.trim(u8, feature[0..colon], " \t\r\n");
    const media_value = std.mem.trim(u8, feature[colon + 1 ..], " \t\r\n");

    if (std.ascii.eqlIgnoreCase(name, "prefers-color-scheme")) {
        if (std.ascii.eqlIgnoreCase(media_value, "dark")) return self.media.prefers_dark;
        if (std.ascii.eqlIgnoreCase(media_value, "light")) return !self.media.prefers_dark;
        return null;
    }

    if (std.ascii.eqlIgnoreCase(name, "forced-colors")) {
        if (std.ascii.eqlIgnoreCase(media_value, "active")) return self.media.forced_colors;
        if (std.ascii.eqlIgnoreCase(media_value, "none")) return !self.media.forced_colors;
        return null;
    }

    if (std.ascii.eqlIgnoreCase(name, "max-width")) {
        const limit = parseMediaPixelLength(media_value) orelse return null;
        const viewport_width = self.media.viewport_width_css orelse return false;
        return viewport_width <= limit;
    }

    if (std.ascii.eqlIgnoreCase(name, "min-width")) {
        const limit = parseMediaPixelLength(media_value) orelse return null;
        const viewport_width = self.media.viewport_width_css orelse return false;
        return viewport_width >= limit;
    }

    if (std.ascii.eqlIgnoreCase(name, "min-height") or
        std.ascii.eqlIgnoreCase(name, "max-height"))
    {
        const limit = parseMediaPixelLength(media_value) orelse return null;
        const viewport_height = self.media.viewport_height_css orelse return false;
        if (std.ascii.eqlIgnoreCase(name, "min-height")) return viewport_height >= limit;
        return viewport_height <= limit;
    }

    if (std.ascii.eqlIgnoreCase(name, "min-color") or
        std.ascii.eqlIgnoreCase(name, "max-color"))
    {
        const limit = parseMediaInteger(media_value) orelse return null;
        const depth = self.media.color_depth;
        if (std.ascii.eqlIgnoreCase(name, "min-color")) return depth >= limit;
        return depth <= limit;
    }

    if (std.ascii.eqlIgnoreCase(name, "min-monochrome") or
        std.ascii.eqlIgnoreCase(name, "max-monochrome"))
    {
        const limit = parseMediaInteger(media_value) orelse return null;
        const depth = self.media.monochrome_depth;
        if (std.ascii.eqlIgnoreCase(name, "min-monochrome")) return depth >= limit;
        return depth <= limit;
    }

    if (std.ascii.eqlIgnoreCase(name, "width")) {
        const expected = parseMediaPixelLength(media_value) orelse return null;
        const viewport_width = self.media.viewport_width_css orelse return false;
        return mediaWidthsEqual(viewport_width, expected);
    }

    return null;
}

fn singleMediaQueryMatches(self: *const CSSParser, raw_query: []const u8) bool {
    const query = std.mem.trim(u8, raw_query, " \t\r\n");
    if (query.len == 0) return false;

    var cursor: usize = 0;
    var negate = false;
    var matches = true;
    var saw_condition = false;

    if (consumeMediaKeyword(query, &cursor, "only")) skipMediaWhitespace(query, &cursor);
    if (consumeMediaKeyword(query, &cursor, "not")) {
        negate = true;
        skipMediaWhitespace(query, &cursor);
    }

    // A media type is optional when the query begins with a parenthesized
    // feature. Zibra is a screen user agent, so `screen` and `all` match.
    if (cursor < query.len and query[cursor] != '(') {
        const media_type = mediaIdentifier(query, &cursor) orelse return false;
        if (std.ascii.eqlIgnoreCase(media_type, "screen") or
            std.ascii.eqlIgnoreCase(media_type, "all"))
        {
            matches = true;
        } else if (std.ascii.eqlIgnoreCase(media_type, "print")) {
            matches = false;
        } else {
            return false;
        }
        skipMediaWhitespace(query, &cursor);
        if (cursor == query.len) return if (negate) !matches else matches;
        if (!consumeMediaKeyword(query, &cursor, "and")) return false;
        skipMediaWhitespace(query, &cursor);
    }

    while (cursor < query.len) {
        if (query[cursor] != '(') return false;
        const feature_start = cursor + 1;
        const close = std.mem.indexOfScalarPos(u8, query, feature_start, ')') orelse return false;
        if (std.mem.indexOfScalar(u8, query[feature_start..close], '(') != null) return false;
        const feature_matches = self.mediaFeatureMatches(query[feature_start..close]) orelse return false;
        matches = matches and feature_matches;
        saw_condition = true;
        cursor = close + 1;
        skipMediaWhitespace(query, &cursor);
        if (cursor == query.len) break;
        if (!consumeMediaKeyword(query, &cursor, "and")) return false;
        skipMediaWhitespace(query, &cursor);
    }

    if (!saw_condition) return false;
    return if (negate) !matches else matches;
}

fn mediaQueryMatches(self: *const CSSParser, prelude: []const u8) bool {
    var depth: usize = 0;
    var query_start: usize = 0;
    for (prelude, 0..) |char, index| {
        switch (char) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            ',' => if (depth == 0) {
                if (self.singleMediaQueryMatches(prelude[query_start..index])) return true;
                query_start = index + 1;
            },
            else => {},
        }
    }
    if (depth != 0) return false;
    return self.singleMediaQueryMatches(prelude[query_start..]);
}

fn startsWithMediaRule(self: *const CSSParser) bool {
    const keyword = "@media";
    if (self.string.len - self.pos < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(self.string[self.pos .. self.pos + keyword.len], keyword)) return false;
    const next = self.pos + keyword.len;
    return next == self.string.len or std.ascii.isWhitespace(self.string[next]) or self.string[next] == '(';
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
        if (self.pos >= self.string.len or self.string[self.pos] == '{') break;

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
            if (self.startsWithMediaRule()) {
                const prelude_start = self.pos + "@media".len;
                const brace_idx = std.mem.indexOfPos(u8, self.string, prelude_start, "{") orelse break;
                const prelude = self.string[prelude_start..brace_idx];
                const block_end = self.findMatchingBrace(brace_idx) orelse break;

                if (self.mediaQueryMatches(prelude)) {
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
