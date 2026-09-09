//! Zibra-owned token spelling bridge for the retained CSS syntax adapter.
//! Returned strings are explicit owners. It normalizes identifiers and units,
//! preserving strings, URL payloads, comments and structural token boundaries.

const std = @import("std");
const frontend = @import("css_frontend.zig");

/// Decode one identifier token into its semantic name. The caller owns the
/// result; it is not a CSS serialization and must not be reparsed as tokens.
pub fn identifier(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < raw.len) {
        if (raw[cursor] != '\\') {
            if (raw[cursor] == 0) {
                try out.appendSlice(allocator, "\xef\xbf\xbd");
            } else {
                try out.append(allocator, raw[cursor]);
            }
            cursor += 1;
            continue;
        }
        cursor += 1;
        var codepoint: u32 = 0;
        var count: usize = 0;
        while (cursor < raw.len and count < 6) {
            const digit = std.fmt.charToDigit(raw[cursor], 16) catch break;
            codepoint = codepoint * 16 + digit;
            cursor += 1;
            count += 1;
        }
        if (count == 0 and cursor < raw.len) {
            if (raw[cursor] == 0) {
                try out.appendSlice(allocator, "\xef\xbf\xbd");
            } else {
                try out.append(allocator, raw[cursor]);
            }
            cursor += 1;
            continue;
        }
        if (count > 0 and cursor < raw.len and std.ascii.isWhitespace(raw[cursor])) {
            const cr = raw[cursor] == '\r';
            cursor += 1;
            if (cr and cursor < raw.len and raw[cursor] == '\n') cursor += 1;
        }
        if (codepoint == 0 or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) codepoint = 0xfffd;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch unreachable;
        try out.appendSlice(allocator, encoded[0..len]);
    }
    return out.toOwnedSlice(allocator);
}

fn appendIdentifier(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8, hash: bool) !void {
    const decoded = try identifier(allocator, raw);
    defer allocator.free(decoded);
    try appendDecodedIdentifier(allocator, out, decoded, hash);
}

fn appendDecodedIdentifier(allocator: std.mem.Allocator, out: *std.ArrayList(u8), decoded: []const u8, hash: bool) !void {
    for (decoded, 0..) |byte, index| {
        const initial_digit = !hash and std.ascii.isDigit(byte) and (index == 0 or (index == 1 and decoded[0] == '-'));
        const lone_hyphen = !hash and byte == '-' and decoded.len == 1;
        if (byte < 0x20 or byte == 0x7f or initial_digit) {
            var hex: [2]u8 = undefined;
            const text = try std.fmt.bufPrint(&hex, "{x}", .{byte});
            try out.append(allocator, '\\');
            try out.appendSlice(allocator, text);
            try out.append(allocator, ' ');
        } else if (!lone_hyphen and (byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '\\');
            try out.append(allocator, byte);
        }
    }
}

fn numberEnd(raw: []const u8) usize {
    var cursor: usize = 0;
    if (cursor < raw.len and (raw[cursor] == '+' or raw[cursor] == '-')) cursor += 1;
    while (cursor < raw.len and std.ascii.isDigit(raw[cursor])) cursor += 1;
    if (cursor + 1 < raw.len and raw[cursor] == '.' and std.ascii.isDigit(raw[cursor + 1])) {
        cursor += 1;
        while (cursor < raw.len and std.ascii.isDigit(raw[cursor])) cursor += 1;
    }
    if (cursor < raw.len and (raw[cursor] == 'e' or raw[cursor] == 'E')) {
        var exponent = cursor + 1;
        if (exponent < raw.len and (raw[exponent] == '+' or raw[exponent] == '-')) exponent += 1;
        if (exponent < raw.len and std.ascii.isDigit(raw[exponent])) {
            cursor = exponent + 1;
            while (cursor < raw.len and std.ascii.isDigit(raw[cursor])) cursor += 1;
        }
    }
    return cursor;
}

fn appendUnit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    const decoded = try identifier(allocator, raw);
    defer allocator.free(decoded);
    var exponent: usize = 1;
    if (decoded.len > exponent and (decoded[exponent] == '+' or decoded[exponent] == '-')) exponent += 1;
    if (decoded.len > exponent and (decoded[0] == 'e' or decoded[0] == 'E') and std.ascii.isDigit(decoded[exponent])) {
        // A unit such as e3px must not merge with its number and become px:
        // 1\\65 3px means dimension(1, e3px), not dimension(1000, px).
        try out.appendSlice(allocator, if (decoded[0] == 'e') "\\65 " else "\\45 ");
        try appendDecodedIdentifier(allocator, out, decoded[1..], true);
        return;
    }
    try appendDecodedIdentifier(allocator, out, decoded, false);
}

/// Produce a property-grammar input from retained tokens, without formatting or
/// reparsing the stylesheet. Decoding cannot turn an identifier into a number,
/// delimiter or a sequence of tokens. Comments remain separators, including
/// between numbers and units. URL/string payload escapes remain unsupported by
/// Zibra's existing property consumers and retain their authored spelling.
pub fn value(allocator: std.mem.Allocator, syntax: frontend.Syntax, range: frontend.Range) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var closers: [64]u8 = undefined;
    var depth: usize = 0;
    var content_start: ?usize = null;
    var content_end: usize = 0;
    var tokens = syntax.tokens(range);
    while (tokens.next()) |token| {
        const raw = syntax.slice(token.range);
        if (token.kind != .whitespace and content_start == null) content_start = out.items.len;
        switch (token.kind) {
            .identifier => try appendIdentifier(allocator, &out, raw, false),
            .function => {
                try appendIdentifier(allocator, &out, raw[0 .. raw.len - 1], false);
                try out.append(allocator, '(');
            },
            .dimension => {
                const split = numberEnd(raw);
                try out.appendSlice(allocator, raw[0..split]);
                try appendUnit(allocator, &out, raw[split..]);
            },
            .hash, .at_keyword => {
                try out.append(allocator, raw[0]);
                try appendIdentifier(allocator, &out, raw[1..], token.kind == .hash);
            },
            .url => {
                // Terence recognizes escaped url() names as URL tokens; the
                // legacy image grammar requires the decoded function spelling.
                const open = std.mem.indexOfScalar(u8, raw, '(') orelse unreachable;
                try out.appendSlice(allocator, "url");
                try out.appendSlice(allocator, raw[open..]);
            },
            else => try out.appendSlice(allocator, raw),
        }
        if (token.kind != .whitespace) content_end = out.items.len;
        const closer: ?u8 = switch (token.kind) {
            .function, .open_paren => ')',
            .open_bracket => ']',
            .open_brace => '}',
            else => null,
        };
        if (closer) |closing| {
            if (depth == closers.len) return error.NestingLimitExceeded;
            closers[depth] = closing;
            depth += 1;
        } else if (depth != 0 and (token.kind == .close_paren or token.kind == .close_bracket or token.kind == .close_brace)) {
            if (raw[0] == closers[depth - 1]) depth -= 1;
        }
    }
    // The syntax frontend accepts implicit EOF block/function closure. Supply
    // those delimiters to string-based property grammars, without changing the
    // source ranges or treating invalid unmatched closers as recoverable.
    while (depth > 0) {
        depth -= 1;
        try out.append(allocator, closers[depth]);
        content_end = out.items.len;
    }
    // Serialized identifier escapes may end with a significant space or a
    // hex-escape terminator. Only original whitespace tokens are edge trivia.
    const trimmed = out.items[content_start orelse 0 .. content_end];
    if (trimmed.ptr != out.items.ptr) std.mem.copyForwards(u8, out.items[0..trimmed.len], trimmed);
    out.shrinkRetainingCapacity(trimmed.len);
    return out.toOwnedSlice(allocator);
}

test "CSS normalization replaces escaped NUL identifier code points" {
    const decoded = try identifier(std.testing.allocator, "\\\x00");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("\xef\xbf\xbd", decoded);
}
