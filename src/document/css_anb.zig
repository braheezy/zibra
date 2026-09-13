//! Allocation-free An+B grammar shared by selector admission and matching.
//! Values are bounded to signed 64-bit coefficients; matching widens arithmetic.
const std = @import("std");
const tokens = @import("css_tokenizer.zig");

pub const AnB = struct {
    a: i64,
    b: i64,

    pub fn matches(self: AnB, index: usize) bool {
        if (index == 0) return false;
        const delta = @as(i128, index) - self.b;
        if (self.a == 0) return delta == 0;
        if ((delta < 0 and self.a > 0) or (delta > 0 and self.a < 0)) return false;
        return @rem(delta, self.a) == 0;
    }
};

fn next(iterator: *tokens.Iterator) ?tokens.Token {
    while (iterator.next()) |token| if (!token.isTrivia()) return token;
    return null;
}

fn integer(input: []const u8, token: tokens.Token) ?i64 {
    if (token.number_type != .integer) return null;
    return std.fmt.parseInt(i64, input[token.start..token.number_end], 10) catch null;
}

fn magnitude(input: []const u8, token: tokens.Token, negative: bool) ?i64 {
    if (token.number_type != .integer) return null;
    const number = std.fmt.parseInt(i128, input[token.start..token.number_end], 10) catch return null;
    return std.math.cast(i64, if (negative) -number else number);
}

fn finish(iterator: *tokens.Iterator, a: i64, b: i64) ?AnB {
    return if (next(iterator) == null) .{ .a = a, .b = b } else null;
}

/// Parse CSS integer, odd/even and An+B tokens. Comments never join a number
/// and its unit; an optional '+' before an n-ident permits no whitespace.
/// Unsupported `of <selector-list>` and out-of-range integers return null.
pub fn parse(input: []const u8) ?AnB {
    var iterator = tokens.Iterator{ .input = input };
    var first = next(&iterator) orelse return null;
    if (first.kind == .number) return finish(&iterator, 0, integer(input, first) orelse return null);
    var plus_prefix = false;
    if (first.kind == .delim and first.delim == '+') {
        plus_prefix = true;
        first = iterator.next() orelse return null;
        while (first.kind == .comment) first = iterator.next() orelse return null;
        if (first.kind != .ident) return null;
    }
    if (first.kind != .dimension and first.kind != .ident) return null;
    const raw = first.encodedValue(input);
    if (first.kind == .ident and !plus_prefix) {
        if (tokens.identifierEquals(raw, "odd")) return finish(&iterator, 2, 1);
        if (tokens.identifierEquals(raw, "even")) return finish(&iterator, 2, 0);
    }
    var a: i64 = if (first.kind == .dimension) integer(input, first) orelse return null else 1;
    var decoder = tokens.Decoder{ .input = raw };
    var character = decoder.next() orelse return null;
    if (first.kind == .ident and character == '-') {
        if (plus_prefix) return null;
        a = -1;
        character = decoder.next() orelse return null;
    }
    if (character != 'n' and character != 'N') return null;
    if (decoder.next()) |suffix| {
        if (suffix != '-') return null;
        if (decoder.next()) |digit| {
            var current = digit;
            var b: i64 = 0;
            while (true) {
                if (current < '0' or current > '9') return null;
                // Accumulate negatively so the full i64 minimum is admitted.
                const multiplied = @mulWithOverflow(b, 10);
                const subtracted = @subWithOverflow(multiplied[0], @as(i64, current - '0'));
                if (multiplied[1] != 0 or subtracted[1] != 0) return null;
                b = subtracted[0];
                current = decoder.next() orelse return finish(&iterator, a, b);
            }
        }
        const offset = next(&iterator) orelse return null;
        if (offset.kind != .number or offset.number_sign != null) return null;
        return finish(&iterator, a, magnitude(input, offset, true) orelse return null);
    }
    const offset = next(&iterator) orelse return .{ .a = a, .b = 0 };
    if (offset.kind == .number and offset.number_sign != null) {
        return finish(&iterator, a, integer(input, offset) orelse return null);
    }
    if (offset.kind != .delim or (offset.delim != '+' and offset.delim != '-')) return null;
    const number = next(&iterator) orelse return null;
    if (number.kind != .number or number.number_sign != null) return null;
    return finish(&iterator, a, magnitude(input, number, offset.delim == '-') orelse return null);
}

test "An+B token grammar retains signs escapes whitespace and comment boundaries" {
    for ([_][]const u8{ "odd", "2n+1", "2n + 1", "+2N + 1", "2\\6e +1" }) |input| {
        try std.testing.expectEqual(AnB{ .a = 2, .b = 1 }, parse(input).?);
    }
    for ([_][]const u8{ "-n+ 6", "-n +6", "-n/**/+/**/6" }) |input| {
        try std.testing.expectEqual(AnB{ .a = -1, .b = 6 }, parse(input).?);
    }
    for ([_][]const u8{ "n-2", "+n-2", "+/**/n - 2", "n- 2" }) |input| {
        try std.testing.expectEqual(AnB{ .a = 1, .b = -2 }, parse(input).?);
    }
    try std.testing.expectEqual(AnB{ .a = 0, .b = 5 }, parse("+5").?);
    for ([_][]const u8{ "", "garbage", "2 n", "2/**/n", "+ n", "+ 2n", "n 2", "n + -2", "n- +2", "2.0n", "1e2", "n + 2px", "+odd", "n+1 of .a", "1_0" }) |input| {
        try std.testing.expect(parse(input) == null);
    }
}

test "An+B matching handles finite negative steps and extreme offsets without overflow" {
    const first_six = parse("-n+6").?;
    try std.testing.expect(first_six.matches(1));
    try std.testing.expect(first_six.matches(6));
    try std.testing.expect(!first_six.matches(7));
    try std.testing.expect(!first_six.matches(0));
    try std.testing.expect(parse("2n-1").?.matches(3));
    try std.testing.expect(!parse("2n-1").?.matches(2));
    for ([_][]const u8{ "n-9223372036854775808", "n - 9223372036854775808", "n- 9223372036854775808" }) |input| {
        try std.testing.expect(parse(input).?.matches(1));
    }
    try std.testing.expect(!parse("-9223372036854775808n").?.matches(1));
}
