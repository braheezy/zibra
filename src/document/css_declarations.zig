//! Shared declaration validation, shorthand expansion, and block precedence.
//! Syntax frontends supply names, values and priority; this module owns only
//! map storage, while strings remain static or borrowed from the caller.

const std = @import("std");
const css_length = @import("length.zig");
const css_color = @import("color.zig");
const background_image = @import("background_image.zig");
const css_syntax = @import("css_syntax.zig");
const css_properties = @import("css_properties.zig");
const value_tokens = @import("css_value_tokens.zig");
const custom_properties = @import("custom_properties.zig");
const css_flex = @import("css_flex.zig");
const grid_tracks = @import("grid_tracks.zig");

pub const IMPORTANT_PRIORITY: u32 = 10_000;

/// One parsed property value. The value borrows the stylesheet or inline-style
/// buffer; `important` is declaration-local cascade metadata.
pub const Declaration = struct {
    value: []const u8,
    important: bool = false,
    /// A var()-containing shorthand participates in the longhand cascade now,
    /// but cannot be expanded until the winning custom environment is known.
    pending_shorthand: ?[]const u8 = null,

    pub fn priority(self: Declaration, base_priority: u32) u32 {
        return base_priority + if (self.important) IMPORTANT_PRIORITY else 0;
    }
};

/// Owns the hash table only. Keys/values borrow the caller's source or
/// normalized-string owner; static shorthand names/defaults need no storage.
pub const Map = std.StringHashMap(Declaration);

/// Remove CSS whitespace and complete comments from the ends of one borrowed
/// value. Interior comments remain in source storage, but the common trailing
/// declaration-comment form becomes the exact authored token slice.
pub fn trimValueTrivia(input: []const u8) []const u8 {
    var start: ?usize = null;
    var end: usize = 0;
    var tokens = value_tokens.Iterator{ .input = input };
    while (tokens.next()) |token| {
        const raw = input[token.start..token.end];
        if (raw.len == 1 and css_syntax.isWhitespace(raw[0])) continue;
        // Scan comments forward as whole tokens: a second /* inside one
        // comment does not start a nested comment. Strings, URLs and escaped
        // whitespace remain atomic and cannot masquerade as edge trivia.
        if (raw.len >= 4 and std.mem.startsWith(u8, raw, "/*") and std.mem.endsWith(u8, raw, "*/")) continue;
        if (start == null) start = token.start;
        end = token.end;
    }
    return input[start orelse 0 .. end];
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
    if (css_length.isMath(font_size)) return css_length.resolveMath(font_size, .{ .percentage_base = 16 }) != null;
    const length = css_length.parse(font_size) orelse return false;
    return length.unit == .px or length.unit == .mm or length.unit == .em or length.unit == .rem or length.unit == .percent;
}

fn isSupportedFontLineHeight(line_height: []const u8) bool {
    if (css_length.isMath(line_height)) return css_length.resolveMath(line_height, .{ .percentage_base = 16 }) != null;
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

/// Return the canonical static property spelling for a supported CSS name.
/// CSS property identifiers are ASCII-case-insensitive and may contain CSS
/// escapes, but unsupported names intentionally have no effect in Zibra.
fn canonicalPropertyName(raw_property: []const u8) ?[]const u8 {
    if (custom_properties.isName(raw_property)) return raw_property;
    for (css_properties.computed) |property| {
        if (css_syntax.identifierEquals(raw_property, property.name)) return property.name;
    }
    for (css_properties.shorthands) |candidate| {
        if (css_syntax.identifierEquals(raw_property, candidate.name)) return candidate.name;
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
    if (css_length.isMath(raw_value)) return css_length.resolveMath(raw_value, .{ .percentage_base = 100 }) != null;
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
    var iterator = grid_tracks.Components{ .input = raw_value };
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
pub fn isValidLonghandValue(property: []const u8, raw_value: []const u8) bool {
    if (isCssWideKeyword(raw_value)) return true;
    if (std.mem.eql(u8, property, "flex-grow") or std.mem.eql(u8, property, "flex-shrink")) return css_flex.factor(raw_value) != null;
    if (std.mem.eql(u8, property, "flex-basis")) return css_flex.basis(raw_value);
    if (std.mem.eql(u8, property, "order")) {
        _ = std.fmt.parseInt(i32, raw_value, 10) catch return false;
        return true;
    }
    if (std.mem.eql(u8, property, "row-gap") or std.mem.eql(u8, property, "column-gap")) return std.ascii.eqlIgnoreCase(raw_value, "normal") or isNonnegativeLength(raw_value);
    if (std.mem.startsWith(u8, property, "grid-template-")) {
        var tracks: [grid_tracks.max_tracks]grid_tracks.Track = undefined;
        return grid_tracks.parse(raw_value, .{ .percentage_base = 800 }, 0, 1, &tracks) != null;
    }
    if (std.mem.eql(u8, property, "grid-auto-rows")) return grid_tracks.parseTrack(raw_value, .{ .percentage_base = 600 }) != null;
    if (std.mem.eql(u8, property, "flex-direction")) return keywordIn(raw_value, &.{ "row", "row-reverse", "column", "column-reverse" });
    if (std.mem.eql(u8, property, "flex-wrap")) return keywordIn(raw_value, &.{ "nowrap", "wrap", "wrap-reverse" });
    if (std.mem.eql(u8, property, "box-sizing")) return keywordIn(raw_value, &.{ "content-box", "border-box" });
    if (std.mem.startsWith(u8, property, "align-") or std.mem.startsWith(u8, property, "justify-")) return keywordIn(raw_value, &.{ "normal", "auto", "start", "end", "flex-start", "flex-end", "center", "stretch", "space-between", "space-around", "space-evenly" });

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

fn keywordIn(value_text: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value_text, " \t\r\n"), choice)) return true;
    return false;
}

fn putLonghand(map: *Map, property: []const u8, declaration: Declaration) !void {
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
    var iterator = grid_tracks.Components{ .input = raw_value };
    while (iterator.next()) |token| {
        if (count == tokens.len) return null;
        tokens[count] = token;
        count += 1;
    }
    return if (count > 0) count else null;
}

fn expandBoxShorthand(
    map: *Map,
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
        if (!isValidLonghandValue(boxSideProperty(prefix, side), side_value)) return false;
    }
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
    map: *Map,
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
    map: *Map,
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
    map: *Map,
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
    map: *Map,
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

/// Apply one source-spelled declaration using the legacy priority suffix
/// scanner. Unsupported/invalid values have no effect. Keys and values borrow
/// caller storage or static strings; allocation failure may leave partial
/// shorthand entries, so transactional callers must discard the staged map.
pub fn putRaw(map: *Map, raw_property: []const u8, raw_value: []const u8) !void {
    const property = canonicalPropertyName(raw_property) orelse return;
    const declaration = parseDeclarationValue(raw_value) orelse return;
    try putCanonical(map, property, declaration);
}

/// Apply a syntax frontend's decoded property and value with explicit priority.
/// `value` must exclude the frontend's priority suffix; this function never
/// scans for `!important`. Decoded custom names must fit Zibra's current var()
/// identifier subset. Strings borrow caller storage or static entries through
/// map retirement. Unsupported/invalid values have no effect; allocation
/// failure may leave a partially expanded shorthand in the staged map.
pub fn putParsed(map: *Map, decoded_property: []const u8, value: []const u8, important: bool) !void {
    const property = canonicalDecodedPropertyName(decoded_property) orelse return;
    try putCanonical(map, property, .{ .value = trimValueTrivia(value), .important = important });
}

fn canonicalDecodedPropertyName(decoded_property: []const u8) ?[]const u8 {
    if (custom_properties.isName(decoded_property)) return decoded_property;
    for (css_properties.computed) |property| {
        if (std.ascii.eqlIgnoreCase(decoded_property, property.name)) return property.name;
    }
    for (css_properties.shorthands) |candidate| {
        if (std.ascii.eqlIgnoreCase(decoded_property, candidate.name)) return candidate.name;
    }
    return null;
}

fn putCanonical(map: *Map, property: []const u8, declaration: Declaration) !void {
    if (custom_properties.isName(property)) {
        try putLonghand(map, property, declaration);
        return;
    }
    const pending = value_tokens.hasVariable(declaration.value);
    if (pending or isCssWideKeyword(declaration.value)) {
        for (css_properties.shorthands) |shorthand| {
            if (!std.mem.eql(u8, property, shorthand.name)) continue;
            for (shorthand.longhands) |longhand| {
                try putLonghand(map, longhand, .{
                    .value = declaration.value,
                    .important = declaration.important,
                    .pending_shorthand = if (pending) property else null,
                });
            }
            return;
        }
        if (pending) {
            try putLonghand(map, property, declaration);
            return;
        }
    }
    if (std.mem.eql(u8, property, "flex")) {
        const flex = css_flex.parse(declaration.value) orelse return;
        try putLonghand(map, "flex-grow", .{ .value = flex.grow, .important = declaration.important });
        try putLonghand(map, "flex-shrink", .{ .value = flex.shrink, .important = declaration.important });
        try putLonghand(map, "flex-basis", .{ .value = flex.basis, .important = declaration.important });
        return;
    }
    if (std.mem.eql(u8, property, "gap") or std.mem.eql(u8, property, "place-items") or std.mem.eql(u8, property, "place-content")) {
        var parts = grid_tracks.Components{ .input = declaration.value };
        const first = parts.next() orelse return;
        const second = parts.next() orelse first;
        if (parts.next() != null) return;
        const names: [2][]const u8 = if (std.mem.eql(u8, property, "gap")) .{ "row-gap", "column-gap" } else if (std.mem.eql(u8, property, "place-items")) .{ "align-items", "justify-items" } else .{ "align-content", "justify-content" };
        if (!isValidLonghandValue(names[0], first) or !isValidLonghandValue(names[1], second)) return;
        try putLonghand(map, names[0], .{ .value = first, .important = declaration.important });
        try putLonghand(map, names[1], .{ .value = second, .important = declaration.important });
        return;
    }
    if (std.mem.eql(u8, property, "flex-flow")) {
        var parts = grid_tracks.Components{ .input = declaration.value };
        var direction: []const u8 = "row";
        var wrap: []const u8 = "nowrap";
        var seen_direction = false;
        var seen_wrap = false;
        while (parts.next()) |part| {
            if (!seen_direction and isValidLonghandValue("flex-direction", part)) {
                direction = part;
                seen_direction = true;
            } else if (!seen_wrap and isValidLonghandValue("flex-wrap", part)) {
                wrap = part;
                seen_wrap = true;
            } else return;
        }
        if (!seen_direction and !seen_wrap) return;
        try putLonghand(map, "flex-direction", .{ .value = direction, .important = declaration.important });
        try putLonghand(map, "flex-wrap", .{ .value = wrap, .important = declaration.important });
        return;
    }
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

test "shared declaration frontends retain duplicate fallback and shorthand precedence" {
    const allocator = std.testing.allocator;
    var raw = Map.init(allocator);
    defer raw.deinit();
    var parsed = Map.init(allocator);
    defer parsed.deinit();
    const Case = struct { name: []const u8, value: []const u8, raw_value: []const u8, important: bool = false };
    const cases = [_]Case{
        .{ .name = "color", .value = "green", .raw_value = "green" },
        .{ .name = "color", .value = "unsupported(red)", .raw_value = "unsupported(red)" },
        .{ .name = "margin-left", .value = "5px", .raw_value = "5px !important", .important = true },
        .{ .name = "margin", .value = "1px 2px", .raw_value = "1px 2px" },
        .{ .name = "padding", .value = "3px 4px", .raw_value = "3px 4px !important", .important = true },
        .{ .name = "padding-right", .value = "8px", .raw_value = "8px" },
        .{ .name = "padding-left", .value = "9px", .raw_value = "9px !important", .important = true },
        .{ .name = "border", .value = "2px solid red", .raw_value = "2px solid red" },
        .{ .name = "--Space", .value = "12px", .raw_value = "12px" },
        .{ .name = "gap", .value = "var(--Space)", .raw_value = "var(--Space)" },
    };
    for (cases) |case| {
        try putRaw(&raw, case.name, case.raw_value);
        try putParsed(&parsed, case.name, case.value, case.important);
    }
    try std.testing.expectEqual(raw.count(), parsed.count());
    var entries = raw.iterator();
    while (entries.next()) |entry| {
        const actual = parsed.get(entry.key_ptr.*).?;
        try std.testing.expectEqualStrings(entry.value_ptr.value, actual.value);
        try std.testing.expectEqual(entry.value_ptr.important, actual.important);
        try std.testing.expectEqualStrings(entry.value_ptr.pending_shorthand orelse "", actual.pending_shorthand orelse "");
    }
    try std.testing.expectEqualStrings("green", parsed.get("color").?.value);
    try std.testing.expectEqualStrings("5px", parsed.get("margin-left").?.value);
    try std.testing.expectEqualStrings("2px", parsed.get("margin-right").?.value);
    try std.testing.expectEqualStrings("4px", parsed.get("padding-right").?.value);
    try std.testing.expectEqualStrings("9px", parsed.get("padding-left").?.value);
    try std.testing.expectEqualStrings("gap", parsed.get("row-gap").?.pending_shorthand.?);
}

test "parsed declarations use explicit priority without interpreting retained bangs" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try putParsed(&map, "--label", "value !important", false);
    try std.testing.expectEqualStrings("value !important", map.get("--label").?.value);
    try std.testing.expect(!map.get("--label").?.important);
    try putParsed(&map, "--empty", "", true);
    try std.testing.expectEqualStrings("", map.get("--empty").?.value);
    try std.testing.expect(map.get("--empty").?.important);
    try putParsed(&map, "CONTENT", "'!important'", true);
    try std.testing.expectEqualStrings("'!important'", map.get("content").?.value);
    try std.testing.expect(map.get("content").?.important);
    try putParsed(&map, "color", "red !important", false);
    try std.testing.expect(!map.contains("color"));
}

test "decoded declaration names are canonicalized once and custom names keep case" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try putRaw(&map, "\\63 olor", "green");
    try std.testing.expectEqualStrings("green", map.get("color").?.value);
    try putParsed(&map, "\\63 olor", "red", false);
    try std.testing.expectEqualStrings("green", map.get("color").?.value);
    try putParsed(&map, "COLOR", "blue", false);
    try std.testing.expectEqualStrings("blue", map.get("color").?.value);
    try putParsed(&map, "--Case", "red", false);
    try putParsed(&map, "--case", "green", false);
    try std.testing.expectEqualStrings("red", map.get("--Case").?.value);
    try std.testing.expectEqualStrings("green", map.get("--case").?.value);
}

fn declarationAllocationTrial(allocator: std.mem.Allocator) !void {
    var map = Map.init(allocator);
    defer map.deinit();
    try putParsed(&map, "border", "1px solid green", true);
    try putParsed(&map, "font", "italic bold 12px/16px sans-serif", false);
    try putParsed(&map, "background", "blue", false);
    try putParsed(&map, "margin", "var(--space)", false);
}

test "declaration staging can reclaim every partially expanded allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, declarationAllocationTrial, .{});
}

test "parsed declaration edges discard trivia without changing interior source" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try putParsed(&map, "color", " /* before */ green /* after */ ", false);
    try std.testing.expectEqualStrings("green", map.get("color").?.value);
    try putParsed(&map, "padding", "1px/**/2px/*tail*/", false);
    try std.testing.expectEqualStrings("1px", map.get("padding-top").?.value);
    try std.testing.expectEqualStrings("2px", map.get("padding-right").?.value);
    try putParsed(&map, "--tokens", "a/**/b/*tail*/", false);
    try std.testing.expectEqualStrings("a/**/b", map.get("--tokens").?.value);
}

test "declaration trivia preserves comment boundaries opaque payloads and escapes" {
    try std.testing.expectEqualStrings("green", trimValueTrivia(" /* leading /* marker */ green /* outer /* inner */ "));
    try std.testing.expectEqualStrings("'/* in string */'", trimValueTrivia("'/* in string */' /* outer /* inner */"));
    try std.testing.expectEqualStrings("url(/*payload*/", trimValueTrivia("url(/*payload*/"));
    try std.testing.expectEqualStrings("\\ ", trimValueTrivia("\\  /**/ "));
    try std.testing.expectEqualStrings("\\31 ", trimValueTrivia("\\31  /**/ "));

    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try putParsed(&map, "color", "green /* outer /* inner */", false);
    try std.testing.expectEqualStrings("green", map.get("color").?.value);
    try putParsed(&map, "--space", "\\ ", false);
    try std.testing.expectEqualStrings("\\ ", map.get("--space").?.value);
}
