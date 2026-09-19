//! Shared declaration validation, shorthand expansion, and block precedence.
//! Emits values owned by each sink's value allocator. Stylesheets and
//! inline CSSOM share the same property grammar and priority interpretation.

const std = @import("std");
const css_length = @import("length.zig");
const css_color = @import("color.zig");
const background_image = @import("background_image.zig");
const css_syntax = @import("css_syntax.zig");
const rule_syntax = @import("css_rule_syntax.zig");
const css_properties = @import("css_properties.zig");
const value_tokens = @import("css_value_tokens.zig");
const css_values = @import("css_values.zig");
const custom_properties = @import("custom_properties.zig");
const css_flex = @import("css_flex.zig");
const css_overflow = @import("css_overflow.zig");
const grid_tracks = @import("grid_tracks.zig");
const grid_placement = @import("css_grid_placement.zig");

const cascade = @import("css_cascade.zig");

/// One parsed property value borrowing its compiled declaration owner.
/// `important` is declaration-local cascade metadata.
pub const Declaration = struct {
    value: []const u8,
    important: bool = false,
    /// A var()-containing shorthand participates in the longhand cascade now,
    /// but cannot be expanded until the winning custom environment is known.
    pending_shorthand: ?[]const u8 = null,

    pub fn key(self: Declaration, context: cascade.Context) cascade.Key {
        return cascade.Key.from(context, self.important);
    }
};

/// Movable owner for compiled declarations and normalized strings. No stored
/// allocator points at the movable arena. Clone deeply before sharing rules.
pub const Map = struct {
    const Table = std.StringHashMap(Declaration);
    table: Table,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Map {
        return .{ .table = Table.init(allocator), .arena = std.heap.ArenaAllocator.init(allocator) };
    }
    pub fn deinit(self: *Map) void {
        self.table.deinit();
        self.arena.deinit();
    }
    pub fn valueAllocator(self: *Map) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn get(self: Map, name: []const u8) ?Declaration {
        return self.table.get(name);
    }
    pub fn contains(self: Map, name: []const u8) bool {
        return self.table.contains(name);
    }
    pub fn count(self: Map) u32 {
        return self.table.count();
    }
    pub fn iterator(self: *const Map) Table.Iterator {
        return self.table.iterator();
    }
    pub fn remove(self: *Map, name: []const u8) bool {
        return self.table.remove(name);
    }
    /// Sink strings must already belong to this map's value allocator or static storage.
    pub fn put(self: *Map, name: []const u8, value: Declaration) !void {
        try self.table.put(name, value);
    }
    pub fn clone(self: *const Map) !Map {
        return self.cloneWithAllocator(self.table.allocator);
    }
    pub fn cloneWithAllocator(self: *const Map, allocator: std.mem.Allocator) !Map {
        var result = Map.init(allocator);
        errdefer result.deinit();
        const arena = result.valueAllocator();
        var it = self.iterator();
        while (it.next()) |entry| try result.put(try arena.dupe(u8, entry.key_ptr.*), .{
            .value = try arena.dupe(u8, entry.value_ptr.value),
            .important = entry.value_ptr.important,
            .pending_shorthand = if (entry.value_ptr.pending_shorthand) |name| try arena.dupe(u8, name) else null,
        });
        return result;
    }
};

/// Remove CSS whitespace and comments (including EOF comments) from a borrowed
/// value. Interior comments remain in source storage, but the common trailing
/// declaration-comment form becomes the exact authored token slice.
pub fn trimValueTrivia(input: []const u8) []const u8 {
    var start: ?usize = null;
    var end: usize = 0;
    var tokens = value_tokens.Iterator{ .input = input };
    while (tokens.next()) |token| {
        if (token.isTrivia()) continue;
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

/// Parse declaration-local priority using component boundaries. A top-level
/// bang is only valid as the final !important suffix; nested/string/URL bangs
/// remain value data. Returned strings borrow input, including empty custom values.
pub fn parseDeclarationValue(raw_value: []const u8) ?Declaration {
    const end = css_syntax.scanToTopLevel(raw_value, 0, "!;})]");
    if (end.exhausted) return null;
    if (end.delimiter == null) return .{ .value = trimValueTrivia(raw_value) };
    if (end.delimiter != '!') return null;
    var cursor = end.end + 1;
    css_syntax.skipWhitespaceAndComments(raw_value, &cursor);
    const name = css_syntax.consumeIdentifier(raw_value, &cursor) orelse return null;
    if (!css_syntax.identifierEquals(name, "important")) return null;
    css_syntax.skipWhitespaceAndComments(raw_value, &cursor);
    if (cursor != raw_value.len) return null;
    return .{ .value = trimValueTrivia(raw_value[0..end.end]), .important = true };
}

/// A CSSOM setter takes one value and a separate priority, never a declaration
/// list or embedded !important. Property grammar is checked by putParsed.
pub fn validSetterValue(value: []const u8) bool {
    const end = css_syntax.scanToTopLevel(value, 0, "!;})]");
    return !end.exhausted and end.delimiter == null;
}

/// Compile structural declarations into a sink exposing get/put/valueAllocator.
/// Both native cascade maps and ordered CSSOM blocks use this grammar. On OOM
/// discard the staged sink; a shorthand may have emitted only some longhands.
pub fn parseInto(sink: anytype, declarations: *rule_syntax.DeclarationIterator) !void {
    while (declarations.next()) |declaration| {
        try putRaw(sink, declaration.name.slice(declarations.input), declaration.value.slice(declarations.input));
    }
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
    return css_color.isValid(trimmed);
}

fn validBackgroundPosition(raw_value: []const u8) bool {
    return @import("css_position.zig").parse(raw_value) != null;
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
    // These values select real formatting/paint behavior. Rejecting arbitrary
    // tokens here keeps declarations, CSSOM edits and feature queries aligned.
    if (std.mem.eql(u8, property, "display")) return @import("css_display.zig").valid(raw_value);
    if (std.mem.eql(u8, property, "position")) return keywordIn(raw_value, &.{ "static", "relative", "absolute", "fixed", "sticky" });
    if (std.mem.eql(u8, property, "float")) return keywordIn(raw_value, &.{ "none", "left", "right" });
    if (std.mem.eql(u8, property, "clear")) return keywordIn(raw_value, &.{ "none", "left", "right", "both" });
    if (std.mem.eql(u8, property, "overflow-x") or std.mem.eql(u8, property, "overflow-y")) return css_overflow.parse(raw_value) != null;
    if (std.mem.eql(u8, property, "visibility")) return keywordIn(raw_value, &.{ "visible", "hidden" });
    // The UA stylesheet uses legacy HTML alignment values to position block
    // children too; ordinary CSS text-align only positions inline content.
    if (std.mem.eql(u8, property, "text-align")) return keywordIn(raw_value, &.{ "start", "end", "left", "right", "center", "-zibra-left", "-zibra-right", "-zibra-center" });
    if (std.mem.eql(u8, property, "font-weight")) return isFontWeight(raw_value);
    if (std.mem.eql(u8, property, "font-style")) return keywordIn(raw_value, &.{ "normal", "italic", "oblique" });
    if (std.mem.eql(u8, property, "font-variant")) return keywordIn(raw_value, &.{ "normal", "small-caps" });
    if (std.mem.eql(u8, property, "font-stretch")) return isFontStretch(raw_value);
    if (std.mem.eql(u8, property, "aspect-ratio")) return @import("css_aspect_ratio.zig").parse(raw_value) != null;
    if (std.mem.eql(u8, property, "object-fit")) return @import("object_fit.zig").parse(raw_value) != null;
    if (std.mem.eql(u8, property, "border-radius")) return isNonnegativeLength(raw_value);
    if (std.mem.eql(u8, property, "opacity")) {
        const number = std.fmt.parseFloat(f64, raw_value) catch return false;
        return std.math.isFinite(number);
    }
    if (std.mem.startsWith(u8, property, "animation-")) return @import("css_animation.zig").validLonghand(property, raw_value);
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
    if (std.mem.eql(u8, property, "grid-auto-rows") or std.mem.eql(u8, property, "grid-auto-columns")) return grid_tracks.parseTrack(raw_value, .{ .percentage_base = 600 }) != null;
    if (grid_placement.isLineProperty(property)) return grid_placement.parseLine(raw_value) != null;
    if (std.mem.eql(u8, property, "grid-auto-flow")) return grid_placement.parseFlow(raw_value) != null;
    if (std.mem.eql(u8, property, "flex-direction")) return keywordIn(raw_value, &.{ "row", "row-reverse", "column", "column-reverse" });
    if (std.mem.eql(u8, property, "flex-wrap")) return keywordIn(raw_value, &.{ "nowrap", "wrap", "wrap-reverse" });
    if (std.mem.eql(u8, property, "box-sizing")) return keywordIn(raw_value, &.{ "content-box", "border-box" });
    if (std.mem.startsWith(u8, property, "align-") or std.mem.startsWith(u8, property, "justify-")) return @import("css_alignment.zig").validForProperty(property, raw_value);

    if (std.mem.eql(u8, property, "width") or std.mem.eql(u8, property, "height") or
        std.mem.eql(u8, property, "min-width") or std.mem.eql(u8, property, "min-height") or
        std.mem.eql(u8, property, "max-width") or std.mem.eql(u8, property, "max-height"))
    {
        return @import("css_sizing.zig").validForProperty(property, raw_value);
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
        return std.ascii.eqlIgnoreCase(trimmed, "none") or background_image.parseUrl(trimmed) != null or @import("css_gradient.zig").parse(trimmed) != null;
    }
    if (std.mem.eql(u8, property, "background-size")) return background_image.parseSize(raw_value) != null;
    if (std.mem.eql(u8, property, "background-repeat")) return background_image.parseRepeat(raw_value) != null;
    if (std.mem.eql(u8, property, "background-position")) return validBackgroundPosition(raw_value);
    if (std.mem.eql(u8, property, "background-origin")) return background_image.parseOrigin(raw_value) != null;
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

fn putLonghand(map: anytype, property: []const u8, declaration: Declaration) !void {
    if (map.get(property)) |existing| {
        // Within one declaration block, an earlier important longhand cannot
        // be reset by a later normal longhand or shorthand expansion.
        if (existing.important and !declaration.important) return;
    }
    var normalized = declaration;
    if (declaration.pending_shorthand == null and !custom_properties.isName(property))
        normalized.value = try css_values.primitive(map.valueAllocator(), property, declaration.value);
    try map.put(property, normalized);
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
    map: anytype,
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
    map: anytype,
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
    map: anytype,
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
    map: anytype,
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
    for ([_][]const u8{ "width", "style", "color" }, [_][]const u8{ width, style, color }) |kind, value| {
        for (sides) |candidate| {
            if (side) |selected| if (candidate != selected) continue;
            try putLonghand(map, borderSideProperty(kind, candidate), .{ .value = value, .important = declaration.important });
        }
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
        var iterator = value_tokens.Iterator{ .input = self.input, .cursor = start };
        while (iterator.next()) |token| {
            if (token.isTrivia() or (token.kind == .delim and token.delim == '/')) {
                self.pos = token.start;
                return self.input[start..self.pos];
            }
            if (token.kind == .function) iterator.cursor = if (value_tokens.closeFunction(self.input, token.end)) |close| close + 1 else self.input.len;
        }
        self.pos = self.input.len;
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
    return @import("css_position.zig").parse(token) != null;
}

fn componentSpan(input: []const u8, first: []const u8, last: []const u8) []const u8 {
    const start = @intFromPtr(first.ptr) - @intFromPtr(input.ptr);
    const end = @intFromPtr(last.ptr) - @intFromPtr(input.ptr) + last.len;
    return input[start..end];
}

/// Expand the single-layer subset that the renderer can consume. Every value
/// retains a slice of the sink-owned normalized value; omitted components reset to their CSS initial values.
fn expandBackground(
    map: anytype,
    raw_value: []const u8,
    declaration: Declaration,
) !bool {
    var color: []const u8 = "transparent";
    var image: []const u8 = "none";
    var size: []const u8 = "auto";
    var repeat: []const u8 = "repeat";
    var attachment: []const u8 = "scroll";
    var position: []const u8 = "0% 0%";
    var components: [12][]const u8 = undefined;
    var count: usize = 0;
    var iterator = BackgroundTokenIterator{ .input = raw_value };
    while (iterator.next()) |token| {
        if (count == components.len) return false;
        components[count] = token;
        count += 1;
    }
    if (count == 0) return false;
    var saw_color = false;
    var saw_image = false;
    var saw_repeat = false;
    var saw_attachment = false;
    var saw_position = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const token = components[i];
        if (isBorderColor(token)) {
            if (saw_color) return false;
            saw_color = true;
            color = token;
        } else if (std.ascii.eqlIgnoreCase(token, "none") or background_image.parseUrl(token) != null or @import("css_gradient.zig").parse(token) != null) {
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
            if (saw_position) return false;
            saw_position = true;
            const start = i;
            while (i + 1 < count and isBackgroundPosition(components[i + 1])) i += 1;
            position = componentSpan(raw_value, components[start], components[i]);
            if (!validBackgroundPosition(position)) return false;
            if (i + 1 < count and std.mem.eql(u8, components[i + 1], "/")) {
                i += 2;
                if (i == count or background_image.parseSize(components[i]) == null) return false;
                size = components[i];
                if (i + 1 < count) {
                    const pair = componentSpan(raw_value, components[i], components[i + 1]);
                    if (background_image.parseSize(pair) != null) {
                        size = pair;
                        i += 1;
                    }
                }
            }
        } else return false;
    }

    try putLonghand(map, "background-color", .{ .value = color, .important = declaration.important });
    try putLonghand(map, "background-image", .{ .value = image, .important = declaration.important });
    try putLonghand(map, "background-size", .{ .value = size, .important = declaration.important });
    try putLonghand(map, "background-repeat", .{ .value = repeat, .important = declaration.important });
    try putLonghand(map, "background-position", .{ .value = position, .important = declaration.important });
    try putLonghand(map, "background-attachment", .{ .value = attachment, .important = declaration.important });
    try putLonghand(map, "background-origin", .{ .value = "padding-box", .important = declaration.important });
    return true;
}

/// Trim edge trivia and apply one source-spelled declaration, including its
/// priority suffix. Strings are normalized into the sink's own value storage.
/// Invalid values have no effect. On allocation failure discard the staged sink;
/// a shorthand may already have emitted some longhands.
pub fn putRaw(map: anytype, raw_property: []const u8, raw_value: []const u8) !void {
    var names = value_tokens.Iterator{ .input = raw_property };
    const name = names.next() orelse return;
    if (name.kind != .ident or name.end != raw_property.len) return;
    const decoded = try css_values.tokenizer.decode(map.valueAllocator(), raw_property, false);
    const property = canonicalDecodedPropertyName(decoded) orelse return;
    const declaration = parseDeclarationValue(trimValueTrivia(raw_value)) orelse return;
    try putCanonical(map, property, declaration);
}

/// Apply a syntax frontend's decoded property and value with explicit priority.
/// `value` must exclude the frontend's priority suffix; this function never
/// scans for `!important`. Custom names are decoded, case-sensitive code points.
/// Strings are normalized into the sink's value storage. Invalid values have no
/// effect; allocation failure requires discarding the staged sink.
pub fn putParsed(map: anytype, decoded_property: []const u8, value: []const u8, important: bool) !void {
    const property = canonicalDecodedPropertyName(decoded_property) orelse return;
    try putCanonical(map, property, .{ .value = trimValueTrivia(value), .important = important });
}

/// CSSOM names are literal strings, with ASCII folding for supported standard
/// names. Custom names remain case-sensitive borrows of the caller's input.
pub fn canonicalDecodedPropertyName(decoded_property: []const u8) ?[]const u8 {
    if (custom_properties.isName(decoded_property)) return decoded_property;
    for (css_properties.computed) |property| {
        if (std.ascii.eqlIgnoreCase(decoded_property, property.name)) return property.name;
    }
    for (css_properties.shorthands) |candidate| {
        if (std.ascii.eqlIgnoreCase(decoded_property, candidate.name)) return candidate.name;
    }
    return null;
}

fn putCanonical(map: anytype, property: []const u8, raw_declaration: Declaration) !void {
    const is_custom = custom_properties.isName(property);
    const pending = value_tokens.hasVariable(raw_declaration.value);
    if (!pending and (std.mem.eql(u8, property, "z-index") or std.mem.eql(u8, property, "order") or grid_placement.isPlacementProperty(property))) {
        var iterator = value_tokens.Iterator{ .input = raw_declaration.value };
        while (iterator.next()) |token| if (token.kind == .number and token.number_type != .integer) {
            return;
        };
    }
    const normalized = (try css_values.normalize(map.valueAllocator(), raw_declaration.value, .{
        .preserve = is_custom or pending,
        .fold_identifiers = !std.mem.eql(u8, property, "font-family") and !std.mem.eql(u8, property, "font") and
            !std.mem.startsWith(u8, property, "animation") and !std.mem.eql(u8, property, "content"),
    })) orelse return;
    const declaration = Declaration{ .value = normalized, .important = raw_declaration.important };
    if (custom_properties.isName(property)) {
        try putLonghand(map, try map.valueAllocator().dupe(u8, property), declaration);
        return;
    }
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
    if (std.mem.eql(u8, property, "overflow")) {
        const pair = css_overflow.parsePair(declaration.value) orelse return;
        try putLonghand(map, "overflow-x", .{ .value = pair.x.text(), .important = declaration.important });
        try putLonghand(map, "overflow-y", .{ .value = pair.y.text(), .important = declaration.important });
        return;
    }
    if (std.mem.eql(u8, property, "grid-row") or std.mem.eql(u8, property, "grid-column")) {
        const values = grid_placement.axisValues(declaration.value) orelse return;
        const names: [2][]const u8 = if (std.mem.eql(u8, property, "grid-row")) .{ "grid-row-start", "grid-row-end" } else .{ "grid-column-start", "grid-column-end" };
        for (names, values) |name, value| try putLonghand(map, name, .{ .value = value, .important = declaration.important });
        return;
    }
    if (std.mem.eql(u8, property, "grid-area")) {
        const values = grid_placement.areaValues(declaration.value) orelse return;
        const names = [_][]const u8{ "grid-row-start", "grid-column-start", "grid-row-end", "grid-column-end" };
        for (names, values) |name, value| try putLonghand(map, name, .{ .value = value, .important = declaration.important });
        return;
    }
    if (std.mem.eql(u8, property, "overflow-x") or std.mem.eql(u8, property, "overflow-y")) {
        if (css_overflow.parse(declaration.value)) |value| {
            try putLonghand(map, property, .{ .value = value.text(), .important = declaration.important });
            return;
        }
    }
    if (std.mem.eql(u8, property, "animation")) {
        const animations = @import("css_animation.zig");
        const spec = animations.parse(declaration.value) orelse return;
        for (animations.names, spec.values) |name, value| try putLonghand(map, name, .{ .value = value, .important = declaration.important });
        return;
    }
    if (std.mem.eql(u8, property, "flex")) {
        const flex = css_flex.parse(declaration.value) orelse return;
        try putLonghand(map, "flex-grow", .{ .value = flex.grow, .important = declaration.important });
        try putLonghand(map, "flex-shrink", .{ .value = flex.shrink, .important = declaration.important });
        try putLonghand(map, "flex-basis", .{ .value = flex.basis, .important = declaration.important });
        return;
    }
    if (std.mem.eql(u8, property, "place-items") or std.mem.eql(u8, property, "place-content")) {
        const names: [2][]const u8 = if (std.mem.eql(u8, property, "place-items")) .{ "align-items", "justify-items" } else .{ "align-content", "justify-content" };
        const pair = @import("css_alignment.zig").parsePair(names[0], names[1], declaration.value) orelse return;
        try putLonghand(map, names[0], .{ .value = pair.first, .important = declaration.important });
        try putLonghand(map, names[1], .{ .value = pair.second, .important = declaration.important });
        return;
    }
    if (std.mem.eql(u8, property, "gap")) {
        var parts = grid_tracks.Components{ .input = declaration.value };
        const first = parts.next() orelse return;
        const second = parts.next() orelse first;
        if (parts.next() != null) return;
        const names: [2][]const u8 = .{ "row-gap", "column-gap" };
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

test "shared sizing declarations preserve multi-token alignment and invalid fallbacks" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try putRaw(&map, "width", "max-content");
    try putRaw(&map, "width", "fit-content(20px)");
    try std.testing.expectEqualStrings("max-content", map.get("width").?.value);
    try putRaw(&map, "min-width", "min-content");
    try putRaw(&map, "max-width", "fit-content");
    try putRaw(&map, "place-items", "safe center last baseline !important");
    try std.testing.expectEqualStrings("safe center", map.get("align-items").?.value);
    try std.testing.expectEqualStrings("last baseline", map.get("justify-items").?.value);
    try std.testing.expect(map.get("align-items").?.important);
    try putRaw(&map, "align-items", "space-between !important");
    try std.testing.expectEqualStrings("safe center", map.get("align-items").?.value);
    try putRaw(&map, "place-content", "first baseline");
    try std.testing.expectEqualStrings("baseline", map.get("align-content").?.value);
    try std.testing.expectEqualStrings("start", map.get("justify-content").?.value);
    try putRaw(&map, "flex", "1 2 min-content");
    try std.testing.expectEqualStrings("min-content", map.get("flex-basis").?.value);
    try putRaw(&map, "flex-basis", "calc(100% - 10px)");
    try std.testing.expectEqualStrings("calc(100% - 10px)", map.get("flex-basis").?.value);
}

test "atomic formatting display declarations preserve canonical values and cascade priority" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try putRaw(&map, "display", "block");
    try putRaw(&map, "display", "INLINE-FLEX");
    try std.testing.expectEqualStrings("inline-flex", map.get("display").?.value);
    try putRaw(&map, "display", "inline flex");
    try std.testing.expectEqualStrings("inline-flex", map.get("display").?.value);
    try putRaw(&map, "display", "inline-gr\\69 d !important");
    try putRaw(&map, "display", "grid");
    try std.testing.expectEqualStrings("inline-grid", map.get("display").?.value);
    try std.testing.expect(map.get("display").?.important);
    try putRaw(&map, "display", "inline-table !important");
    try std.testing.expectEqualStrings("inline-grid", map.get("display").?.value);
}

test "implicit grid columns share single track admission and retain valid fallback" {
    try std.testing.expectEqualStrings("auto", @import("css_properties.zig").get("grid-auto-columns").?.default_value);
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    for ([_][]const u8{ "auto", "40px", "25%", "min-content", "max-content", "1fr", "minmax(0, 1fr)", "fit-content(60px)" }) |track| {
        try putRaw(&map, "grid-auto-columns", track);
        try putRaw(&map, "grid-auto-rows", track);
        try std.testing.expectEqualStrings(map.get("grid-auto-rows").?.value, map.get("grid-auto-columns").?.value);
    }
    try putRaw(&map, "grid-auto-columns", "minmax(20px, 1fr) !important");
    for ([_][]const u8{ "none", "10px 20px", "repeat(2, 20px)", "minmax(1fr, 20px)" }) |invalid| {
        try putParsed(&map, "grid-auto-columns", invalid, true);
        try std.testing.expectEqualStrings("minmax(20px, 1fr)", map.get("grid-auto-columns").?.value);
    }
    try std.testing.expect(map.get("grid-auto-columns").?.important);
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
    try std.testing.expectEqualStrings("\"!important\"", map.get("content").?.value);
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
