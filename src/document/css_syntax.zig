//! CSS syntax primitives shared by stylesheet parsing helpers.
//!
//! This module owns only source-buffer scanning. All returned ranges borrow
//! the stylesheet input; property grammar and computed-style ownership remain
//! with their respective callers. Comments are retained token trivia, and
//! delimiters inside strings, escapes, or balanced blocks/functions are never
//! reported as structural separators.

const std = @import("std");
const tokenizer = @import("css_tokenizer.zig");

pub const TopLevelMatch = struct {
    /// Source index immediately before `delimiter`, or input length.
    end: usize,
    /// The unconsumed top-level delimiter, if one was found.
    delimiter: ?u8,
    /// The remaining input was quarantined after exceeding max_component_depth.
    exhausted: bool = false,
};

/// Return whether `byte` is CSS whitespace in the supported source subset.
pub fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

/// Return whether `byte` is an ASCII hexadecimal digit.
pub fn isHexDigit(byte: u8) bool {
    return std.ascii.isHex(byte);
}

/// Consume a CSS comment at `cursor`, if one starts there. Unterminated
/// comments consume the rest of the buffer, as required by CSS tokenization.
pub fn consumeComment(input: []const u8, cursor: *usize) bool {
    if (cursor.* + 1 >= input.len or input[cursor.*] != '/' or input[cursor.* + 1] != '*') {
        return false;
    }
    const close = std.mem.indexOfPos(u8, input, cursor.* + 2, "*/") orelse {
        cursor.* = input.len;
        return true;
    };
    cursor.* = close + 2;
    return true;
}

/// Consume spaces and comments, both of which are CSS whitespace trivia.
pub fn skipWhitespaceAndComments(input: []const u8, cursor: *usize) void {
    while (cursor.* < input.len) {
        if (isWhitespace(input[cursor.*])) {
            cursor.* += 1;
            continue;
        }
        if (consumeComment(input, cursor)) continue;
        break;
    }
}

/// Consume one CSS escape sequence. This is deliberately a source scanner,
/// not a value decoder: it only advances across the sequence so its escaped
/// byte cannot accidentally become syntax. It accepts a non-hex escaped byte
/// or a one-to-six-digit hexadecimal escape plus its optional trailing space.
pub fn consumeEscape(input: []const u8, cursor: *usize) bool {
    if (cursor.* >= input.len or input[cursor.*] != '\\') return false;
    cursor.* += 1;
    if (cursor.* >= input.len) return false;
    if (input[cursor.*] == '\n' or input[cursor.*] == '\r' or input[cursor.*] == '\x0c') {
        return false;
    }

    if (!isHexDigit(input[cursor.*])) {
        cursor.* += 1;
        return true;
    }

    var digits: usize = 0;
    while (cursor.* < input.len and digits < 6 and isHexDigit(input[cursor.*])) {
        cursor.* += 1;
        digits += 1;
    }
    if (cursor.* < input.len and isWhitespace(input[cursor.*])) {
        if (input[cursor.*] == '\r' and cursor.* + 1 < input.len and input[cursor.* + 1] == '\n') cursor.* += 1;
        cursor.* += 1;
    }
    return true;
}

/// Maximum simultaneously open component blocks/functions. This bounds stack
/// use independently of input size; over-limit input is quarantined to EOF.
pub const max_component_depth = 64;

/// Scan balanced (), [] and {} components, ignoring separators in strings,
/// comments and escapes. A delimiter is returned only at depth zero, without
/// consuming it. On excessive nesting, return EOF with exhausted set: callers
/// must discard the incomplete construct, not publish its truncated contents.
pub fn scanToTopLevel(input: []const u8, start: usize, delimiters: []const u8) TopLevelMatch {
    var iterator = tokenizer.Iterator{ .input = input, .cursor = start };
    var stack: [max_component_depth]tokenizer.Kind = undefined;
    var depth: usize = 0;
    while (iterator.next()) |token| {
        const raw = token.raw(input);
        if (depth == 0 and raw.len == 1 and std.mem.indexOfScalar(u8, delimiters, raw[0]) != null)
            return .{ .end = token.start, .delimiter = raw[0] };
        if (token.closer()) |closer| {
            if (depth == stack.len) return .{ .end = input.len, .delimiter = null, .exhausted = true };
            stack[depth] = closer;
            depth += 1;
        } else if (depth > 0 and token.kind == stack[depth - 1]) depth -= 1;
    }
    return .{ .end = input.len, .delimiter = null };
}

/// Find an explicit closing brace. EOF recovery is a caller's grammar choice;
/// structural rule parsing may accept an unfinished block where this returns null.
pub fn findMatchingBrace(input: []const u8, open: usize) ?usize {
    if (open >= input.len or input[open] != '{') return null;
    const found = scanToTopLevel(input, open + 1, "}");
    return if (found.delimiter != null) found.end else null;
}

/// Consume the source spelling of an identifier. Returns null without moving
/// the cursor when it does not start an ident token. Strings remain borrowed.
pub fn consumeIdentifier(input: []const u8, cursor: *usize) ?[]const u8 {
    const start = cursor.*;
    if (!tokenizer.startsIdentifier(input, start)) return null;
    tokenizer.consumeName(input, cursor);
    return input[start..cursor.*];
}

/// Compare decoded CSS names with ASCII case folding, without allocating.
pub const identifierEquals = tokenizer.identifierEquals;

test "scanner ignores escaped and quoted declaration delimiters" {
    const escaped = scanToTopLevel("\\}; background: yellow; }", 0, ";}");
    try std.testing.expectEqual(@as(?u8, ';'), escaped.delimiter);
    try std.testing.expectEqual(@as(usize, 2), escaped.end);

    const quoted = scanToTopLevel("url(data:text/plain;still-value); color: red", 0, ";}");
    try std.testing.expectEqual(@as(?u8, ';'), quoted.delimiter);
    try std.testing.expectEqualStrings("url(data:text/plain;still-value)", "url(data:text/plain;still-value)"[0..quoted.end]);
}

test "identifier comparison decodes CSS escapes without treating hex as text" {
    try std.testing.expect(identifierEquals("MARGIN", "margin"));
    try std.testing.expect(identifierEquals("m\\61rgin", "margin"));
    // `\\a` is a hexadecimal newline escape, not the letter `a`.
    try std.testing.expect(!identifierEquals("m\\argin", "margin"));
}

test "component scanner matches typed brackets and ignores escaped delimiters" {
    const input = "[x;{y:z;}](a;}b);width:12px";
    const end = scanToTopLevel(input, 0, ";}");
    try std.testing.expectEqualStrings("[x;{y:z;}](a;}b)", input[0..end.end]);
    try std.testing.expectEqual(@as(?u8, ';'), end.delimiter);
    try std.testing.expect(!end.exhausted);
}

test "component scanner recovers bad strings and preserves line continuations" {
    const bad = "\"bad\n;width:12px";
    const end = scanToTopLevel(bad, 0, ";}");
    try std.testing.expectEqual(@as(usize, 5), end.end);
    const continued = "\"a\\\r\n;}b\";width:12px";
    const good = scanToTopLevel(continued, 0, ";}");
    try std.testing.expectEqualStrings("\"a\\\r\n;}b\"", continued[0..good.end]);
    try std.testing.expect(identifierEquals("w\\69\r\ndth", "width"));
    try std.testing.expect(!isWhitespace('\x0b'));
}

test "component scanner keeps unquoted URL punctuation opaque" {
    const source = "url(data:text/plain,{[;); color:green";
    const end = scanToTopLevel(source, 0, ";}");
    try std.testing.expectEqualStrings("url(data:text/plain,{[;)", source[0..end.end]);
    const escaped = "u\\72l(data:text/plain,}]); width:120px";
    const escaped_end = scanToTopLevel(escaped, 0, ";}");
    try std.testing.expectEqualStrings("u\\72l(data:text/plain,}])", escaped[0..escaped_end.end]);
}

test "URL names inside other tokens do not hide bracket structure" {
    for ([_][]const u8{ "#url", "@url", "1url", "-.5e+2url" }) |prefix| {
        var buffer: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}([);]); color:green", .{prefix});
        const end = scanToTopLevel(source, 0, ";}");
        try std.testing.expectEqual(prefix.len + 6, end.end);
        try std.testing.expectEqual(@as(?u8, ';'), end.delimiter);
    }
}
