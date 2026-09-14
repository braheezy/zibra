//! Borrowed color-mix syntax and scalar percentage normalization. The color
//! owner validates and resolves children; no input or allocation escapes a call.
const std = @import("std");
const lexer = @import("css_tokenizer.zig");
const tokens = @import("css_value_tokens.zig");
const math = @import("css_math.zig");
const interpolation = @import("color_interpolation.zig");
pub const max_colors = interpolation.max_colors;
pub const Item = struct { color: []const u8, percentage: ?[]const u8 = null };
pub const Mix = struct {
    method: interpolation.Method = .{},
    items: [max_colors]Item = undefined,
    count: usize = 0,

    /// Missing percentages share the remainder; forced normalization preserves
    /// an under-100% total as an alpha multiplier. Math is range-clamped here.
    pub fn weights(self: Mix, context: math.Context) ?Weights {
        var result = Weights{ .count = self.count };
        var total: f64 = 0;
        var omitted: usize = 0;
        for (self.items[0..self.count], 0..) |item, i| {
            if (item.percentage) |source| {
                result.values[i] = percentage(source, context) orelse return null;
                total += result.values[i];
            } else omitted += 1;
        }
        const remainder = @max(0, 100 - total) / @as(f64, @floatFromInt(@max(1, omitted)));
        for (self.items[0..self.count], 0..) |item, i| if (item.percentage == null) {
            result.values[i] = remainder;
            total += remainder;
        };
        result.alpha = @min(1, total / 100);
        // Zero totals stay zero: each ordered pair then mixes halfway, rather
        // than changing an n-ary transparent mix into equal nonzero weights.
        for (result.values[0..self.count]) |*value| value.* = if (total == 0) 0 else value.* / total;
        return result;
    }
};
pub const Weights = struct { values: [max_colors]f64 = undefined, count: usize, alpha: f64 = 1 };

pub fn percentage(source: []const u8, context: math.Context) ?f64 {
    const value = math.evaluate(source, context) orelse return null;
    if (value.dimension != .percentage) return null;
    if (!math.isMath(source) and (value.value < 0 or value.value > 100)) return null;
    return if (std.math.isNan(value.value)) 0 else std.math.clamp(value.value, 0, 100);
}

fn parseItem(source: []const u8) ?Item {
    var iterator = lexer.Iterator{ .input = source };
    var parts: [2][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |token| {
        if (token.isTrivia()) continue;
        if (count == parts.len) return null;
        var end = token.end;
        if (token.kind == .function) {
            end = (tokens.closeFunction(source, token.end) orelse return null) + 1;
            iterator.cursor = end;
        }
        parts[count] = source[token.start..end];
        count += 1;
    }
    if (count == 0) return null;
    if (count == 1) return .{ .color = parts[0] };
    const leading = percentage(parts[0], .{}) != null;
    const weight = parts[if (leading) @as(usize, 0) else 1];
    if (percentage(weight, .{}) == null) return null;
    return .{ .color = parts[if (leading) @as(usize, 1) else 0], .percentage = weight };
}

/// Parse one complete function with at most 32 colors. Child sources borrow
/// input; callers enforce recursive color depth and the overall byte limit.
pub fn parse(input: []const u8) ?Mix {
    var iterator = lexer.Iterator{ .input = input };
    var function = iterator.next() orelse return null;
    while (function.isTrivia()) function = iterator.next() orelse return null;
    if (function.kind != .function or !lexer.identifierEquals(function.encodedValue(input), "color-mix")) return null;
    const close = tokens.closeFunction(input, function.end) orelse return null;
    iterator.cursor = close + 1;
    while (iterator.next()) |token| if (!token.isTrivia()) return null;
    var result = Mix{};
    var cursor = function.end;
    var first = true;
    while (cursor <= close) {
        const separator = @import("css_syntax.zig").scanToTopLevel(input[0..close], cursor, ",");
        if (separator.exhausted) return null;
        const end = separator.end;
        const part = input[cursor..end];
        var head = lexer.Iterator{ .input = part };
        var token = head.next() orelse return null;
        while (token.isTrivia()) token = head.next() orelse return null;
        if (first and token.kind == .ident and lexer.identifierEquals(token.encodedValue(part), "in")) {
            result.method = interpolation.Method.parse(part) orelse return null;
            if (end == close) return null;
        } else {
            if (result.count == result.items.len) return null;
            result.items[result.count] = parseItem(part) orelse return null;
            result.count += 1;
        }
        first = false;
        if (end == close) break;
        cursor = end + 1;
    }
    return if (result.count == 0) null else result;
}

test "color-mix weights normalize omissions underflow zero totals and math bounds" {
    const cases = .{
        .{ "color-mix(red 25%, blue)", @as(f64, 0.25), @as(f64, 1) },
        .{ "color-mix(in srgb, 20% red, blue 30%)", @as(f64, 0.4), @as(f64, 0.5) },
        .{ "color-mix(red 0%, blue 0%)", @as(f64, 0), @as(f64, 0) },
        .{ "color-mix(red calc(200%), blue)", @as(f64, 1), @as(f64, 1) },
    };
    inline for (cases) |case| {
        const value = parse(case[0]).?.weights(.{}).?;
        try std.testing.expectApproxEqAbs(case[1], value.values[0], 0.000001);
        try std.testing.expectApproxEqAbs(case[2], value.alpha, 0.000001);
    }
    try std.testing.expect(parse("color-mix(in srgb, red -1%, blue)") == null);
    try std.testing.expect(parse("color-mix(red,)") == null);
    try std.testing.expect(parse("color-mix(in srgb longer hue, red, blue)") == null);
}
