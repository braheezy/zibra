//! Borrowing component-token scanner for computed values. Strings, comments,
//! URLs and escaped identifiers remain atomic during variable/length rewriting.

const std = @import("std");
const syntax = @import("css_syntax.zig");

pub const Token = struct {
    kind: enum { other, ident, function, dimension },
    start: usize,
    end: usize,
    number_end: usize = 0,
};

fn nameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 128;
}

pub const Iterator = struct {
    input: []const u8,
    cursor: usize = 0,
    atomic_urls: bool = true,

    pub fn next(self: *Iterator) ?Token {
        if (self.cursor >= self.input.len) return null;
        const start = self.cursor;
        const c = self.input[start];
        if (syntax.consumeComment(self.input, &self.cursor)) return .{ .kind = .other, .start = start, .end = self.cursor };
        if (c == '\'' or c == '"') {
            self.cursor += 1;
            while (self.cursor < self.input.len) {
                if (self.input[self.cursor] == '\\') {
                    _ = syntax.consumeEscape(self.input, &self.cursor);
                } else {
                    self.cursor += 1;
                    if (self.input[self.cursor - 1] == c) break;
                }
            }
            return .{ .kind = .other, .start = start, .end = self.cursor };
        }
        var number_end = start;
        if (c == '+' or c == '-') number_end += 1;
        var digits: usize = 0;
        while (number_end < self.input.len and std.ascii.isDigit(self.input[number_end])) : (number_end += 1) digits += 1;
        if (number_end < self.input.len and self.input[number_end] == '.') {
            number_end += 1;
            while (number_end < self.input.len and std.ascii.isDigit(self.input[number_end])) : (number_end += 1) digits += 1;
        }
        if (digits > 0) {
            if (number_end < self.input.len and (self.input[number_end] == 'e' or self.input[number_end] == 'E')) {
                var exponent = number_end + 1;
                if (exponent < self.input.len and (self.input[exponent] == '+' or self.input[exponent] == '-')) exponent += 1;
                const first = exponent;
                while (exponent < self.input.len and std.ascii.isDigit(self.input[exponent])) : (exponent += 1) {}
                if (exponent > first) number_end = exponent;
            }
            self.cursor = number_end;
            self.consumeName();
            return .{ .kind = if (self.cursor > number_end) .dimension else .other, .start = start, .end = self.cursor, .number_end = number_end };
        }
        if (nameByte(c) or c == '\\') {
            self.consumeName();
            if (self.cursor < self.input.len and self.input[self.cursor] == '(') {
                self.cursor += 1;
                if (self.atomic_urls and syntax.identifierEquals(self.input[start .. self.cursor - 1], "url")) {
                    self.cursor = if (closeFunction(self.input, self.cursor)) |end| end + 1 else self.input.len;
                    return .{ .kind = .other, .start = start, .end = self.cursor };
                }
                return .{ .kind = .function, .start = start, .end = self.cursor };
            }
            return .{ .kind = .ident, .start = start, .end = self.cursor };
        }
        self.cursor += 1;
        return .{ .kind = .other, .start = start, .end = self.cursor };
    }

    fn consumeName(self: *Iterator) void {
        while (self.cursor < self.input.len) {
            if (nameByte(self.input[self.cursor])) self.cursor += 1 else if (self.input[self.cursor] == '\\') {
                _ = syntax.consumeEscape(self.input, &self.cursor);
            } else break;
        }
    }
};

/// `start` is immediately after the opening parenthesis.
pub fn closeFunction(input: []const u8, start: usize) ?usize {
    // Matching parentheses must stay iterative even for nested URL-like input.
    var tokens = Iterator{ .input = input, .cursor = start, .atomic_urls = false };
    var depth: usize = 0;
    while (tokens.next()) |token| {
        const text = input[token.start..token.end];
        if (token.kind == .function or std.mem.eql(u8, text, "(")) depth += 1;
        if (std.mem.eql(u8, text, ")")) {
            if (depth == 0) return token.start;
            depth -= 1;
        }
    }
    return null;
}

pub fn hasVariable(input: []const u8) bool {
    var tokens = Iterator{ .input = input };
    while (tokens.next()) |token| {
        if (token.kind == .function and syntax.identifierEquals(input[token.start .. token.end - 1], "var")) return true;
    }
    return false;
}

pub fn hasRem(input: []const u8) bool {
    var iterator = Iterator{ .input = input };
    while (iterator.next()) |token| {
        if (token.kind == .dimension and syntax.identifierEquals(input[token.number_end..token.end], "rem")) return true;
    }
    return false;
}

/// Return an owned replacement only when a real rem dimension occurs. This
/// computes root-relative tokens before property-specific used-value parsing.
pub fn resolveRem(allocator: std.mem.Allocator, input: []const u8, root_size: f64) !?[]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var copied: usize = 0;
    var changed = false;
    var tokens = Iterator{ .input = input };
    while (tokens.next()) |token| {
        if (token.kind != .dimension or !syntax.identifierEquals(input[token.number_end..token.end], "rem")) continue;
        const number = std.fmt.parseFloat(f64, input[token.start..token.number_end]) catch continue;
        if (!std.math.isFinite(number * root_size)) continue;
        try output.appendSlice(allocator, input[copied..token.start]);
        var buffer: [384]u8 = undefined;
        try output.appendSlice(allocator, try std.fmt.bufPrint(&buffer, "{d:.6}px", .{number * root_size}));
        copied = token.end;
        changed = true;
    }
    if (!changed) return null;
    try output.appendSlice(allocator, input[copied..]);
    return try output.toOwnedSlice(allocator);
}

test "computed token rewriting preserves strings URLs identifiers and numbers" {
    const input = "translate(-2rem, 1e1REM) '3rem' url(4rem.png) foo5rem /* 6rem */";
    const result = (try resolveRem(std.testing.allocator, input, 10)).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("translate(-20.000000px, 100.000000px) '3rem' url(4rem.png) foo5rem /* 6rem */", result);
    try std.testing.expect(!hasVariable("'var(--a)' url(var(--a))"));
    try std.testing.expect(hasVariable("rgb(var(--channels))"));
}

test "computed token scanning bounds stack use for nested URLs and large dimensions" {
    const nested = "url(" ** 2048 ++ "1rem" ++ ")" ** 2048;
    try std.testing.expect(!hasRem(nested));
    const result = (try resolveRem(std.testing.allocator, "1e99rem", 16)).?;
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.endsWith(u8, result, "px"));
}
