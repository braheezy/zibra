//! Pure leaf algorithms shared by the inline formatter.
//!
//! This module has no layout-object ownership and registers no invalidation
//! dependencies. Tree traversal, glyph allocation, and retained line objects
//! remain in `layout.zig`; these helpers only normalize text and calculate
//! inline used values.

const std = @import("std");
const grapheme = @import("grapheme");
const parser = @import("../../document/parser.zig");

pub const TextDirection = enum {
    left_to_right,
    right_to_left,
};

pub const LineAlignment = enum {
    start,
    center,
    end,
};

/// The invisible inline formatting "strut" contributed by a block container.
///
/// It carries the container's inherited font metrics and line-height leading
/// even when a line contains only replaced content such as an image. Layout
/// owns the font measurement; this module only performs the CSS-independent
/// leading split.
pub const LineStrut = struct {
    ascent: i32,
    descent: i32,
};

pub const Entity = struct {
    replacement: []const u8,
    len: usize,
};

pub fn textDirectionFromFlag(rtl_text: bool) TextDirection {
    return if (rtl_text) .right_to_left else .left_to_right;
}

pub fn lineAlignmentShift(
    alignment: LineAlignment,
    line_left: i32,
    line_right: i32,
    content_left: i32,
    content_right: i32,
) i32 {
    const content_width = @max(content_right - content_left, 0);
    const target_left = switch (alignment) {
        .start => line_left,
        .center => line_left + @divTrunc((line_right - line_left) - content_width, 2),
        .end => line_right - content_width,
    };
    return target_left - content_left;
}

pub fn textSizeForSuperscript(size: i32, is_superscript: bool) i32 {
    if (!is_superscript) return size;
    return @max(@divTrunc(size, 2), 1);
}

pub fn isSmallCapsLowercaseGrapheme(grapheme_bytes: []const u8) bool {
    return grapheme_bytes.len > 0 and std.ascii.isLower(grapheme_bytes[0]);
}

pub fn textSizeForSmallCaps(size: i32) i32 {
    return @max(@divTrunc(size * 4, 5), 1);
}

pub fn shouldAutomaticallyWrap(
    is_preformatted: bool,
    cursor_x: i32,
    glyph_width: i32,
    line_right: i32,
    line_has_content: bool,
) bool {
    return !is_preformatted and
        line_has_content and
        cursor_x + glyph_width > line_right;
}

pub fn isSoftHyphenGrapheme(gme: []const u8) bool {
    return std.mem.eql(u8, gme, "\u{00AD}");
}

pub fn isNonBreakingSpaceGrapheme(gme: []const u8) bool {
    return std.mem.eql(u8, gme, "\u{00A0}");
}

pub fn isWordSeparatorGrapheme(gme: []const u8) bool {
    return gme.len == 1 and std.ascii.isWhitespace(gme[0]);
}

pub fn lineBreakLengthAt(text: []const u8, position: usize) usize {
    if (position >= text.len) return 0;
    return switch (text[position]) {
        '\n' => 1,
        '\r' => if (position + 1 < text.len and text[position + 1] == '\n') 2 else 1,
        else => 0,
    };
}

pub fn isCollapsibleWhitespaceGrapheme(gme: []const u8) bool {
    return gme.len == 1 and switch (gme[0]) {
        ' ', '\t', '\n', '\r', 0x0c => true,
        else => false,
    };
}

pub fn graphemeCount(text: []const u8) usize {
    var count: usize = 0;
    var iter = grapheme.iterator(text);
    while (iter.next()) |_| count += 1;
    return count;
}

pub fn resolveLineHeightCss(value: []const u8, font_size_css: f64) ?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n\x0c");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "normal")) return null;

    // Unitless line-height inherits as a multiplier, so resolve it against
    // the element's current font size at use time.
    if (std.fmt.parseFloat(f64, trimmed)) |multiplier| {
        if (!std.math.isFinite(multiplier) or multiplier < 0) return null;
        return multiplier * font_size_css;
    } else |_| {}

    return parser.resolveCssLength(trimmed, .{
        .font_size = font_size_css,
        .percentage_base = font_size_css,
    });
}

/// Split signed leading evenly around a font's baseline. An odd pixel of
/// leading stays below the baseline so the resulting line height is exact.
pub fn lineStrut(
    font_ascent: i32,
    font_descent: i32,
    used_line_height: i32,
) LineStrut {
    const ascent: i32 = @max(font_ascent, 0);
    const descent: i32 = @max(font_descent, 0);
    const natural: i32 = ascent +| descent;
    // Keep the subtraction signed: @max's inferred nonnegative integer type
    // would otherwise saturate a shorter requested line-height to zero.
    const leading = @as(i32, @max(used_line_height, 0)) -| natural;
    const leading_above = @divTrunc(leading, 2);
    return .{
        .ascent = ascent +| leading_above,
        .descent = descent +| (leading - leading_above),
    };
}

/// Lex an HTML character reference into caller-provided UTF-8 storage.
pub fn lexEntityAt(text: []const u8, pos: usize, buffer: *[4]u8) ?Entity {
    const reference = parser.characterReferenceAt(text, pos) orelse return null;
    const encoded_len = std.unicode.utf8Encode(reference.codepoint, buffer) catch return null;
    return .{ .replacement = buffer[0..encoded_len], .len = reference.len };
}

/// Decode text exactly as the layout text walkers do. DOM text intentionally
/// remains source-backed and escaped; the returned bytes are allocator-owned.
pub fn decodeTextForDisplay(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var pos: usize = 0;
    while (pos < text.len) {
        var buffer: [4]u8 = undefined;
        if (lexEntityAt(text, pos, &buffer)) |entity| {
            try output.appendSlice(allocator, entity.replacement);
            pos += entity.len;
        } else {
            try output.append(allocator, text[pos]);
            pos += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn wordNeedsNewLine(cursor_x: i32, word_width: i32, line_width: i32) bool {
    return cursor_x > 0 and cursor_x +| word_width > line_width;
}

test "line alignment selects the requested edge" {
    try std.testing.expectEqual(@as(i32, 0), lineAlignmentShift(.start, 13, 777, 13, 76));
    try std.testing.expectEqual(@as(i32, 701), lineAlignmentShift(.end, 13, 777, 13, 76));
    try std.testing.expectEqual(@as(i32, 350), lineAlignmentShift(.center, 13, 777, 13, 76));
}

test "inline font variants use bounded sizes" {
    try std.testing.expectEqual(@as(i32, 8), textSizeForSuperscript(16, true));
    try std.testing.expectEqual(@as(i32, 1), textSizeForSuperscript(1, true));
    try std.testing.expectEqual(@as(i32, 16), textSizeForSuperscript(16, false));
    try std.testing.expectEqual(@as(i32, 12), textSizeForSmallCaps(16));
    try std.testing.expectEqual(@as(i32, 1), textSizeForSmallCaps(1));
    try std.testing.expect(isSmallCapsLowercaseGrapheme("a\u{0301}"));
    try std.testing.expect(!isSmallCapsLowercaseGrapheme("A"));
    try std.testing.expect(!isSmallCapsLowercaseGrapheme("😀"));
}

test "automatic wrapping respects preformatted runs and empty lines" {
    try std.testing.expect(!shouldAutomaticallyWrap(true, 95, 10, 100, true));
    try std.testing.expect(shouldAutomaticallyWrap(false, 95, 10, 100, true));
    try std.testing.expect(!shouldAutomaticallyWrap(false, 95, 10, 100, false));
    try std.testing.expect(wordNeedsNewLine(70, 50, 100));
    try std.testing.expect(!wordNeedsNewLine(0, 101, 100));
}

test "inline separators distinguish soft hyphens and collapsible whitespace" {
    try std.testing.expect(isSoftHyphenGrapheme("\u{00AD}"));
    try std.testing.expect(!isSoftHyphenGrapheme("-"));
    try std.testing.expect(isNonBreakingSpaceGrapheme("\u{00A0}"));
    try std.testing.expect(!isNonBreakingSpaceGrapheme(" "));
    try std.testing.expect(isWordSeparatorGrapheme("\t"));
    try std.testing.expect(!isWordSeparatorGrapheme("a"));

    for ([_][]const u8{ " ", "\t", "\n", "\r", "\x0c" }) |value| {
        try std.testing.expect(isCollapsibleWhitespaceGrapheme(value));
    }
    try std.testing.expect(!isCollapsibleWhitespaceGrapheme("\u{00a0}"));
}

test "line breaks and Unicode grapheme clusters remain intact" {
    try std.testing.expectEqual(@as(usize, 1), lineBreakLengthAt("a\nb", 1));
    try std.testing.expectEqual(@as(usize, 2), lineBreakLengthAt("a\r\nb", 1));
    try std.testing.expectEqual(@as(usize, 1), lineBreakLengthAt("a\rb", 1));
    try std.testing.expectEqual(@as(usize, 0), lineBreakLengthAt("abc", 1));
    try std.testing.expectEqual(@as(usize, 1), graphemeCount("👍🏽"));
    try std.testing.expectEqual(@as(usize, 1), graphemeCount("👨‍👩‍👧‍👦"));
    try std.testing.expectEqual(@as(usize, 1), graphemeCount("🇺🇸"));
}

test "line-height resolves unitless and relative values" {
    try std.testing.expectEqual(@as(?f64, null), resolveLineHeightCss("normal", 16.0));
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), resolveLineHeightCss("1.5", 16.0).?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), resolveLineHeightCss("150%", 16.0).?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), resolveLineHeightCss("1.25em", 16.0).?, 0.000001);
    try std.testing.expect(resolveLineHeightCss("-1", 16.0) == null);
}

test "inline strut splits line-height leading around the baseline" {
    const strut = lineStrut(8, 2, 16);
    try std.testing.expectEqual(@as(i32, 11), strut.ascent);
    try std.testing.expectEqual(@as(i32, 5), strut.descent);

    // Glyph ink can overflow a smaller line box: negative leading still
    // preserves the requested distance between adjacent baselines.
    const natural = lineStrut(8, 2, 4);
    try std.testing.expectEqual(@as(i32, 5), natural.ascent);
    try std.testing.expectEqual(@as(i32, -1), natural.descent);
}

test "entities are decoded with the inline text rules" {
    const allocator = std.testing.allocator;
    const decoded = try decodeTextForDisplay(
        allocator,
        "&lt;div&gt; &amp; &quot;quote&quot; &apos;x&apos; &nbsp; &#x1F642; &unknown;",
    );
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("<div> & \"quote\" 'x' \u{00a0} 🙂 &unknown;", decoded);

    var buffer: [4]u8 = undefined;
    const soft_hyphen = lexEntityAt("&shy;", 0, &buffer).?;
    try std.testing.expectEqualStrings("\u{00AD}", soft_hyphen.replacement);
    try std.testing.expectEqual(@as(usize, 5), soft_hyphen.len);
    try std.testing.expect(lexEntityAt("&lt", 0, &buffer) == null);
}
