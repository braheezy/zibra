//! Computed-value operations over the shared borrowed CSS token stream.
//! Strings and URL tokens remain opaque during variable/length rewriting.

const std = @import("std");
const syntax = @import("css_syntax.zig");

pub const Token = @import("css_tokenizer.zig").Token;
pub const Iterator = @import("css_tokenizer.zig").Iterator;

/// Match one decoded keyword token, ignoring edge trivia without joining names.
pub fn isKeyword(input: []const u8, expected: []const u8) bool {
    var iterator = Iterator{ .input = input };
    var first = iterator.next() orelse return false;
    while (first.isTrivia()) first = iterator.next() orelse return false;
    if (first.kind != .ident or !syntax.identifierEquals(first.encodedValue(input), expected)) return false;
    while (iterator.next()) |token| if (!token.isTrivia()) {
        return false;
    };
    return true;
}

/// `start` is immediately after the opening parenthesis. URL tokens and
/// strings are opaque; typed blocks cannot supply a function's closing token.
pub fn closeFunction(input: []const u8, start: usize) ?usize {
    var iterator = Iterator{ .input = input, .cursor = start };
    var stack: [syntax.max_component_depth]@import("css_tokenizer.zig").Kind = undefined;
    var depth: usize = 0;
    while (iterator.next()) |token| {
        if (token.closer()) |closer| {
            if (depth == stack.len) return null;
            stack[depth] = closer;
            depth += 1;
        } else if (token.isClose()) {
            if (depth == 0) return if (token.kind == .close_paren) token.start else null;
            if (stack[depth - 1] != token.kind) return null;
            depth -= 1;
        }
    }
    return null;
}

pub fn hasVariable(input: []const u8) bool {
    var tokens = Iterator{ .input = input };
    while (tokens.next()) |token| {
        if (token.kind == .function and syntax.identifierEquals(token.encodedValue(input), "var")) return true;
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
