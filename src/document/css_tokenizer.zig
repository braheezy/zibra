//! Allocation-free CSS Syntax tokenizer over borrowed UTF-8 source ranges.
//! Code points are preprocessed on read; offsets always address original bytes.
//! Comments are retained as trivia, never promoted to whitespace tokens.
const std = @import("std");

pub const Kind = enum {
    ident,
    function,
    at_keyword,
    hash,
    string,
    bad_string,
    url,
    bad_url,
    delim,
    number,
    percentage,
    dimension,
    unicode_range,
    whitespace,
    comment,
    cdo,
    cdc,
    colon,
    semicolon,
    comma,
    open_paren,
    close_paren,
    open_square,
    close_square,
    open_curly,
    close_curly,
};

pub const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
    /// Encoded identifier, string contents, URL contents, or dimension unit.
    value_start: usize = 0,
    value_end: usize = 0,
    number_end: usize = 0,
    number_type: enum { integer, number } = .integer,
    number_sign: ?u8 = null,
    range_start: u32 = 0,
    range_end: u32 = 0,
    hash_type: enum { unrestricted, id } = .unrestricted,
    delim: u21 = 0,
    /// False for strings, URLs and comments terminated by EOF recovery.
    closed: bool = true,

    pub fn raw(self: Token, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }

    pub fn encodedValue(self: Token, input: []const u8) []const u8 {
        return input[self.value_start..self.value_end];
    }

    pub fn isTrivia(self: Token) bool {
        return self.kind == .whitespace or self.kind == .comment;
    }

    pub fn closer(self: Token) ?Kind {
        return switch (self.kind) {
            .function, .open_paren => .close_paren,
            .open_square => .close_square,
            .open_curly => .close_curly,
            else => null,
        };
    }

    pub fn isClose(self: Token) bool {
        return self.kind == .close_paren or self.kind == .close_square or self.kind == .close_curly;
    }
};

const Point = struct { value: u21, end: usize };

/// CSS preprocessing: CRLF/CR/FF become LF; NUL and invalid scalar input become
/// U+FFFD. Byte decoding belongs to the response owner; this accepts UTF-8.
pub fn point(input: []const u8, pos: usize) ?Point {
    if (pos >= input.len) return null;
    const byte = input[pos];
    if (byte == '\r') return .{ .value = '\n', .end = pos + 1 + @as(usize, if (pos + 1 < input.len and input[pos + 1] == '\n') 1 else 0) };
    if (byte == '\x0c') return .{ .value = '\n', .end = pos + 1 };
    if (byte == 0) return .{ .value = 0xfffd, .end = pos + 1 };
    if (byte < 128) return .{ .value = byte, .end = pos + 1 };
    const size = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .value = 0xfffd, .end = pos + 1 };
    if (size > input.len - pos) return .{ .value = 0xfffd, .end = input.len };
    const scalar = std.unicode.utf8Decode(input[pos..][0..size]) catch return .{ .value = 0xfffd, .end = pos + 1 };
    return .{ .value = scalar, .end = pos + size };
}

fn at(input: []const u8, pos: usize) u21 {
    return if (point(input, pos)) |p| p.value else 0x110000;
}

fn whitespace(c: u21) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn digit(c: u21) bool {
    return c >= '0' and c <= '9';
}

fn nameStart(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (c >= 128 and c <= 0x10ffff);
}

fn namePoint(c: u21) bool {
    return nameStart(c) or digit(c) or c == '-';
}

pub fn validEscape(input: []const u8, pos: usize) bool {
    // EOF is a valid escaped code point, yielding U+FFFD.
    return pos < input.len and input[pos] == '\\' and at(input, pos + 1) != '\n';
}

pub fn startsIdentifier(input: []const u8, pos: usize) bool {
    const c = at(input, pos);
    if (nameStart(c) or validEscape(input, pos)) return true;
    return c == '-' and (nameStart(at(input, pos + 1)) or at(input, pos + 1) == '-' or validEscape(input, pos + 1));
}

fn startsNumber(input: []const u8, pos: usize) bool {
    var p = pos;
    if (at(input, p) == '+' or at(input, p) == '-') p += 1;
    return digit(at(input, p)) or (at(input, p) == '.' and digit(at(input, p + 1)));
}

/// Decode an escape, advancing past its optional whitespace terminator.
/// Precondition: cursor addresses a valid escape's backslash.
pub fn escape(input: []const u8, cursor: *usize) u21 {
    cursor.* += 1;
    if (cursor.* == input.len) return 0xfffd;
    // Six hex digits can exceed the Unicode range. Accumulate before checking
    // that range so malformed escapes yield U+FFFD instead of overflowing.
    var value: u32 = 0;
    var digits: usize = 0;
    while (cursor.* < input.len and digits < 6 and std.ascii.isHex(input[cursor.*])) : (digits += 1) {
        const c = input[cursor.*];
        value = value * 16 + if (c <= '9') @as(u32, c - '0') else @as(u32, std.ascii.toLower(c) - 'a' + 10);
        cursor.* += 1;
    }
    if (digits == 0) {
        const p = point(input, cursor.*).?;
        cursor.* = p.end;
        return p.value;
    }
    if (point(input, cursor.*)) |p| if (whitespace(p.value)) {
        cursor.* = p.end;
    };
    return if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) 0xfffd else @intCast(value);
}

pub fn consumeName(input: []const u8, cursor: *usize) void {
    while (point(input, cursor.*)) |p| {
        if (namePoint(p.value)) cursor.* = p.end else if (validEscape(input, cursor.*)) {
            _ = escape(input, cursor);
        } else break;
    }
}

/// Streaming decoded content; string mode removes escaped newlines/EOF.
pub const Decoder = struct {
    input: []const u8,
    cursor: usize = 0,
    string: bool = false,

    pub fn next(self: *Decoder) ?u21 {
        while (point(self.input, self.cursor)) |p| {
            if (p.value != '\\') {
                self.cursor = p.end;
                return p.value;
            }
            if (self.string and p.end == self.input.len) {
                self.cursor = p.end;
                return null;
            }
            if (self.string and at(self.input, p.end) == '\n') {
                self.cursor = point(self.input, p.end).?.end;
                continue;
            }
            if (validEscape(self.input, self.cursor)) return escape(self.input, &self.cursor);
            self.cursor = p.end;
            return '\\';
        }
        return null;
    }
};

pub fn identifierEquals(raw: []const u8, expected: []const u8) bool {
    var decoder = Decoder{ .input = raw };
    for (expected) |c| {
        const scalar = decoder.next() orelse return false;
        if (scalar > 127 or std.ascii.toLower(@intCast(scalar)) != std.ascii.toLower(c)) return false;
    }
    return decoder.next() == null;
}

pub fn decode(allocator: std.mem.Allocator, raw: []const u8, string: bool) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var decoder = Decoder{ .input = raw, .string = string };
    while (decoder.next()) |scalar| try appendPoint(allocator, &output, scalar);
    return output.toOwnedSlice(allocator);
}

pub fn appendPoint(allocator: std.mem.Allocator, output: *std.ArrayList(u8), scalar: u21) !void {
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(scalar, &bytes) catch unreachable;
    try output.appendSlice(allocator, bytes[0..len]);
}

pub const Iterator = struct {
    input: []const u8,
    cursor: usize = 0,
    /// Only unicode-range descriptor parsing opts into this special syntax.
    /// Ordinary values (including custom properties) keep normal CSS tokens.
    unicode_ranges: bool = false,

    /// Returns null only at EOF. Every token advances across original bytes.
    pub fn next(self: *Iterator) ?Token {
        const p = point(self.input, self.cursor) orelse return null;
        const start = self.cursor;
        self.cursor = p.end;
        var token = Token{ .kind = .delim, .start = start, .end = undefined, .delim = p.value };
        if (p.value == '/' and at(self.input, self.cursor) == '*') {
            if (std.mem.indexOfPos(u8, self.input, self.cursor + 1, "*/")) |end| self.cursor = end + 2 else {
                self.cursor = self.input.len;
                token.closed = false;
            }
            token.kind = .comment;
        } else if (whitespace(p.value)) {
            while (point(self.input, self.cursor)) |next_point| {
                if (!whitespace(next_point.value)) break;
                self.cursor = next_point.end;
            }
            token.kind = .whitespace;
        } else if (p.value == '"' or p.value == '\'') {
            token.kind = .string;
            token.value_start = self.cursor;
            token.closed = false;
            while (point(self.input, self.cursor)) |s| {
                if (s.value == p.value) {
                    token.closed = true;
                    break;
                }
                if (s.value == '\n') {
                    token.kind = .bad_string;
                    break;
                }
                if (s.value == '\\') {
                    if (at(self.input, s.end) == '\n') self.cursor = point(self.input, s.end).?.end else {
                        _ = escape(self.input, &self.cursor);
                    }
                } else self.cursor = s.end;
            }
            token.value_end = self.cursor;
            if (token.closed) self.cursor += 1;
        } else if (startsNumber(self.input, start)) {
            self.cursor = start;
            if (at(self.input, self.cursor) == '+' or at(self.input, self.cursor) == '-') {
                token.number_sign = self.input[self.cursor];
                self.cursor += 1;
            }
            while (digit(at(self.input, self.cursor))) self.cursor += 1;
            if (at(self.input, self.cursor) == '.' and digit(at(self.input, self.cursor + 1))) {
                token.number_type = .number;
                self.cursor += 2;
                while (digit(at(self.input, self.cursor))) self.cursor += 1;
            }
            if (at(self.input, self.cursor) == 'e' or at(self.input, self.cursor) == 'E') {
                var exponent = self.cursor + 1;
                if (at(self.input, exponent) == '+' or at(self.input, exponent) == '-') exponent += 1;
                if (digit(at(self.input, exponent))) {
                    token.number_type = .number;
                    self.cursor = exponent + 1;
                    while (digit(at(self.input, self.cursor))) self.cursor += 1;
                }
            }
            token.kind = .number;
            token.number_end = self.cursor;
            token.value_start = self.cursor;
            if (startsIdentifier(self.input, self.cursor)) {
                token.kind = .dimension;
                consumeName(self.input, &self.cursor);
            } else if (at(self.input, self.cursor) == '%') {
                token.kind = .percentage;
                self.cursor += 1;
            }
            token.value_end = self.cursor;
        } else if (p.value == '-' and std.mem.startsWith(u8, self.input[start..], "-->")) {
            token.kind = .cdc;
            self.cursor = start + 3;
        } else if (self.unicode_ranges and (p.value == 'u' or p.value == 'U') and
            at(self.input, self.cursor) == '+' and (hex(at(self.input, self.cursor + 1)) or at(self.input, self.cursor + 1) == '?'))
        {
            token.kind = .unicode_range;
            self.cursor += 1;
            var count: usize = 0;
            while (count < 6 and hex(at(self.input, self.cursor))) : (count += 1) {
                token.range_start = token.range_start * 16 + hexValue(self.input[self.cursor]);
                self.cursor += 1;
            }
            token.range_end = token.range_start;
            var wildcards = false;
            while (count < 6 and at(self.input, self.cursor) == '?') : (count += 1) {
                token.range_start *= 16;
                token.range_end = token.range_end * 16 + 15;
                self.cursor += 1;
                wildcards = true;
            }
            if (!wildcards and at(self.input, self.cursor) == '-' and hex(at(self.input, self.cursor + 1))) {
                self.cursor += 1;
                count = 0;
                token.range_end = 0;
                while (count < 6 and hex(at(self.input, self.cursor))) : (count += 1) {
                    token.range_end = token.range_end * 16 + hexValue(self.input[self.cursor]);
                    self.cursor += 1;
                }
            }
        } else if (startsIdentifier(self.input, start)) {
            self.cursor = start;
            consumeName(self.input, &self.cursor);
            token.kind = .ident;
            token.value_start = start;
            token.value_end = self.cursor;
            if (at(self.input, self.cursor) == '(') {
                self.cursor += 1;
                token.kind = .function;
                if (identifierEquals(token.encodedValue(self.input), "url")) {
                    var content = self.cursor;
                    while (point(self.input, content)) |s| {
                        if (!whitespace(s.value)) break;
                        content = s.end;
                    }
                    if (at(self.input, content) != '"' and at(self.input, content) != '\'') self.consumeUrl(&token, content);
                }
            }
        } else if (p.value == '#' and (namePoint(at(self.input, self.cursor)) or validEscape(self.input, self.cursor))) {
            token.kind = .hash;
            token.hash_type = if (startsIdentifier(self.input, self.cursor)) .id else .unrestricted;
            token.value_start = self.cursor;
            consumeName(self.input, &self.cursor);
            token.value_end = self.cursor;
        } else if (p.value == '@' and startsIdentifier(self.input, self.cursor)) {
            token.kind = .at_keyword;
            token.value_start = self.cursor;
            consumeName(self.input, &self.cursor);
            token.value_end = self.cursor;
        } else if (p.value == '<' and std.mem.startsWith(u8, self.input[start..], "<!--")) {
            token.kind = .cdo;
            self.cursor = start + 4;
        } else token.kind = switch (p.value) {
            ':' => .colon,
            ';' => .semicolon,
            ',' => .comma,
            '(' => .open_paren,
            ')' => .close_paren,
            '[' => .open_square,
            ']' => .close_square,
            '{' => .open_curly,
            '}' => .close_curly,
            else => .delim,
        };
        token.end = self.cursor;
        return token;
    }

    fn consumeUrl(self: *Iterator, token: *Token, start: usize) void {
        self.cursor = start;
        token.kind = .url;
        token.value_start = start;
        token.closed = false;
        while (point(self.input, self.cursor)) |p| {
            if (p.value == ')') {
                token.closed = true;
                break;
            }
            if (whitespace(p.value)) {
                token.value_end = self.cursor;
                while (point(self.input, self.cursor)) |s| {
                    if (!whitespace(s.value)) break;
                    self.cursor = s.end;
                }
                if (self.cursor == self.input.len) return;
                if (at(self.input, self.cursor) == ')') {
                    self.cursor += 1;
                    token.closed = true;
                    return;
                }
                break;
            }
            if (p.value == '"' or p.value == '\'' or p.value == '(' or p.value <= 8 or p.value == 11 or (p.value >= 14 and p.value <= 31) or p.value == 127) break;
            if (p.value == '\\') {
                if (!validEscape(self.input, self.cursor)) break;
                _ = escape(self.input, &self.cursor);
            } else self.cursor = p.end;
        }
        token.value_end = self.cursor;
        if (token.closed) {
            self.cursor += 1;
            return;
        }
        if (self.cursor == self.input.len) return;
        token.kind = .bad_url;
        // Bad-URL remnants are opaque even when they contain braces or quotes.
        while (point(self.input, self.cursor)) |p| {
            if (p.value == ')') {
                self.cursor = p.end;
                return;
            }
            if (validEscape(self.input, self.cursor)) {
                _ = escape(self.input, &self.cursor);
            } else self.cursor = p.end;
        }
    }
};

fn hex(c: u21) bool {
    return c <= 127 and std.ascii.isHex(@intCast(c));
}

fn hexValue(c: u8) u32 {
    return if (c <= '9') c - '0' else std.ascii.toLower(c) - 'a' + 10;
}

test "CSS tokenizer numeric identity and identifier starts" {
    const input = "1. 1e+2 1e- 1-foo .5% + -- --> #123 #a @x @1 1\\65 2 1\\65-2";
    const kinds = [_]Kind{ .number, .delim, .number, .dimension, .dimension, .percentage, .delim, .ident, .cdc, .hash, .hash, .at_keyword, .delim, .number, .dimension, .dimension };
    var iterator = Iterator{ .input = input };
    var count: usize = 0;
    while (iterator.next()) |t| {
        if (t.isTrivia()) continue;
        try std.testing.expectEqual(kinds[count], t.kind);
        if (count == 9) try std.testing.expectEqual(.unrestricted, t.hash_type);
        if (count == 10) try std.testing.expectEqual(.id, t.hash_type);
        count += 1;
    }
    try std.testing.expectEqual(kinds.len, count);
}

test "CSS tokenizer strings URLs comments preprocessing and escaped EOF" {
    var iterator = Iterator{ .input = "'bad\r\nurl(a b;}) x 'ok\\\r\nend' url(\\61 ) /**/ foo\\" };
    const expected = [_]Kind{ .bad_string, .whitespace, .bad_url, .whitespace, .ident, .whitespace, .string, .whitespace, .url, .whitespace, .comment, .whitespace, .ident };
    for (expected) |kind| try std.testing.expectEqual(kind, iterator.next().?.kind);
    try std.testing.expect(iterator.next() == null);
    const decoded = try decode(std.testing.allocator, "a\x00\\0 \\d800 \\110000 \\1f600 \\", false);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a����😀�", decoded);
    const outside_unicode = try decode(std.testing.allocator, "\\ffffff \\200000 \\10ffff", false);
    defer std.testing.allocator.free(outside_unicode);
    try std.testing.expectEqualStrings("��\u{10ffff}", outside_unicode);
}

test "CSS tokenizer exposes every lexical kind and numeric type without losing source ranges" {
    const input = "name fn( @name #123 #id 's' \"bad\n url(a) url(a b) ! 12 1.0 2e3 4% 5px /**/ <!-- --> :;,()[]{}";
    var seen = std.EnumSet(Kind).initEmpty();
    var iterator = Iterator{ .input = input };
    var end: usize = 0;
    while (iterator.next()) |token| {
        try std.testing.expectEqual(end, token.start);
        try std.testing.expect(token.end > token.start);
        end = token.end;
        seen.insert(token.kind);
        if (std.mem.eql(u8, token.raw(input), "1.0") or std.mem.eql(u8, token.raw(input), "2e3"))
            try std.testing.expectEqual(.number, token.number_type);
    }
    try std.testing.expectEqual(input.len, end);
    var expected = std.EnumSet(Kind).initFull();
    expected.remove(.unicode_range);
    try std.testing.expectEqual(expected, seen);
}

test "CSS tokenizer unicode ranges require descriptor context and preserve range limits" {
    var ordinary = Iterator{ .input = "U+1234" };
    try std.testing.expectEqual(.ident, ordinary.next().?.kind);
    try std.testing.expectEqual(.number, ordinary.next().?.kind);
    const cases = [_]struct { input: []const u8, start: u32, end: u32, length: usize }{
        .{ .input = "U+12??", .start = 0x1200, .end = 0x12ff, .length = 6 },
        .{ .input = "u+1234-5678", .start = 0x1234, .end = 0x5678, .length = 11 },
        .{ .input = "U+???????", .start = 0, .end = 0xffffff, .length = 8 },
        .{ .input = "U+1234567", .start = 0x123456, .end = 0x123456, .length = 8 },
    };
    for (cases) |case| {
        var iterator = Iterator{ .input = case.input, .unicode_ranges = true };
        const token = iterator.next().?;
        try std.testing.expectEqual(.unicode_range, token.kind);
        try std.testing.expectEqual(case.start, token.range_start);
        try std.testing.expectEqual(case.end, token.range_end);
        try std.testing.expectEqual(case.length, token.end);
    }
}

test "CSS tokenizer advances across arbitrary bytes and bounds opaque URL scanning" {
    var input: [256]u8 = undefined;
    var state: u32 = 0x582bef;
    for (0..256) |_| {
        for (&input) |*byte| {
            state = state *% 1664525 +% 1013904223;
            byte.* = @truncate(state >> 16);
        }
        var iterator = Iterator{ .input = &input };
        var end: usize = 0;
        while (iterator.next()) |token| {
            try std.testing.expectEqual(end, token.start);
            try std.testing.expect(token.end > token.start and token.end <= input.len);
            end = token.end;
        }
        try std.testing.expectEqual(input.len, end);
    }
    var urls = Iterator{ .input = "url(" ** 2048 ++ "var(--hidden)" ++ ")" ** 2048 };
    try std.testing.expectEqual(.bad_url, urls.next().?.kind);
}
