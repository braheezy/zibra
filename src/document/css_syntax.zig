//! CSS syntax primitives shared by stylesheet parsing helpers.
//!
//! This module owns only source-buffer scanning. All returned ranges borrow
//! the stylesheet input; property grammar and computed-style ownership remain
//! with their respective callers. Comments are treated as whitespace, and
//! delimiters inside strings, escapes, or parenthesized functions are never
//! reported as structural separators.

const std = @import("std");

pub const TopLevelMatch = struct {
    /// Source index immediately before `delimiter`, or input length.
    end: usize,
    /// The unconsumed top-level delimiter, if one was found.
    delimiter: ?u8,
};

/// Return whether `byte` is CSS whitespace in the supported source subset.
pub fn isWhitespace(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '\x0c';
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
    if (cursor.* < input.len and isWhitespace(input[cursor.*])) cursor.* += 1;
    return true;
}

/// Scan until a delimiter that occurs at the top level. Comments, strings,
/// escapes, and parenthesized function values are skipped as a unit. The
/// matching delimiter is not consumed.
pub fn scanToTopLevel(input: []const u8, start: usize, delimiters: []const u8) TopLevelMatch {
    var cursor = start;
    var parentheses: usize = 0;
    var quote: ?u8 = null;
    while (cursor < input.len) {
        const byte = input[cursor];
        if (quote) |delimiter| {
            if (byte == '\\') {
                if (!consumeEscape(input, &cursor)) {
                    cursor += 1;
                }
                continue;
            }
            cursor += 1;
            if (byte == delimiter) quote = null;
            continue;
        }

        if (byte == '/' and cursor + 1 < input.len and input[cursor + 1] == '*') {
            _ = consumeComment(input, &cursor);
            continue;
        }
        if (byte == '\\') {
            if (!consumeEscape(input, &cursor)) cursor += 1;
            continue;
        }
        switch (byte) {
            '\'', '"' => {
                quote = byte;
                cursor += 1;
            },
            '(' => {
                parentheses += 1;
                cursor += 1;
            },
            ')' => {
                if (parentheses > 0) parentheses -= 1;
                cursor += 1;
            },
            else => {
                if (parentheses == 0 and std.mem.indexOfScalar(u8, delimiters, byte) != null) {
                    return .{ .end = cursor, .delimiter = byte };
                }
                cursor += 1;
            },
        }
    }
    return .{ .end = input.len, .delimiter = null };
}

/// Find the brace that closes a CSS block beginning at `open`. Braces inside
/// quoted strings, comments, escapes, and functions are not structural.
pub fn findMatchingBrace(input: []const u8, open: usize) ?usize {
    if (open >= input.len or input[open] != '{') return null;
    var cursor = open;
    var depth: usize = 0;
    var parentheses: usize = 0;
    var quote: ?u8 = null;
    while (cursor < input.len) {
        const byte = input[cursor];
        if (quote) |delimiter| {
            if (byte == '\\') {
                if (!consumeEscape(input, &cursor)) cursor += 1;
                continue;
            }
            cursor += 1;
            if (byte == delimiter) quote = null;
            continue;
        }
        if (byte == '/' and cursor + 1 < input.len and input[cursor + 1] == '*') {
            _ = consumeComment(input, &cursor);
            continue;
        }
        if (byte == '\\') {
            if (!consumeEscape(input, &cursor)) cursor += 1;
            continue;
        }
        switch (byte) {
            '\'', '"' => {
                quote = byte;
                cursor += 1;
            },
            '(' => {
                parentheses += 1;
                cursor += 1;
            },
            ')' => {
                if (parentheses > 0) parentheses -= 1;
                cursor += 1;
            },
            '{' => {
                if (parentheses == 0) depth += 1;
                cursor += 1;
            },
            '}' => {
                if (parentheses == 0) {
                    if (depth == 0) return null;
                    depth -= 1;
                    if (depth == 0) return cursor;
                }
                cursor += 1;
            },
            else => cursor += 1,
        }
    }
    return null;
}

fn hexValue(byte: u8) u21 {
    return if (byte >= '0' and byte <= '9') byte - '0' else if (byte >= 'a' and byte <= 'f') byte - 'a' + 10 else byte - 'A' + 10;
}

/// Decode one escape for ASCII identifier comparison. Non-ASCII decoded
/// values intentionally fail the comparison, because the currently supported
/// CSS property names are ASCII.
fn escapedAscii(input: []const u8, cursor: *usize) ?u8 {
    if (cursor.* >= input.len or input[cursor.*] != '\\') return null;
    cursor.* += 1;
    if (cursor.* >= input.len) return null;
    if (!isHexDigit(input[cursor.*])) {
        const byte = input[cursor.*];
        cursor.* += 1;
        return byte;
    }

    var value: u21 = 0;
    var digits: usize = 0;
    while (cursor.* < input.len and digits < 6 and isHexDigit(input[cursor.*])) {
        value = value * 16 + hexValue(input[cursor.*]);
        cursor.* += 1;
        digits += 1;
    }
    if (cursor.* < input.len and isWhitespace(input[cursor.*])) cursor.* += 1;
    if (value == 0 or value > 0x7f) return null;
    return @intCast(value);
}

/// Compare a raw CSS identifier with an ASCII name, resolving CSS escapes and
/// applying CSS's ASCII case-insensitivity for property identifiers.
pub fn identifierEquals(raw: []const u8, expected: []const u8) bool {
    var raw_cursor: usize = 0;
    var expected_cursor: usize = 0;
    while (raw_cursor < raw.len and expected_cursor < expected.len) {
        const byte = if (raw[raw_cursor] == '\\') blk: {
            const escaped = escapedAscii(raw, &raw_cursor) orelse return false;
            break :blk escaped;
        } else blk: {
            const literal = raw[raw_cursor];
            raw_cursor += 1;
            break :blk literal;
        };
        if (std.ascii.toLower(byte) != std.ascii.toLower(expected[expected_cursor])) return false;
        expected_cursor += 1;
    }
    return raw_cursor == raw.len and expected_cursor == expected.len;
}

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
