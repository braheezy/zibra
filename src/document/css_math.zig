//! Bounded, allocation-free typed CSS calculations over borrowed token source.
//! Callers supply relative-unit bases and apply their property's range policy.
const std = @import("std");
const tokens = @import("css_tokenizer.zig");
const expression = @import("css_math_tree.zig");

pub const Dimension = enum { number, percentage, length, angle, time };
pub const Value = struct {
    value: f64,
    dimension: Dimension,
    // Only populated while the same parser emits a transient specified tree.
    expression: ?expression.Index = null,
};
pub const Context = struct {
    font_size: f64 = 16,
    root_font_size: f64 = 16,
    /// A percentage hint converts percentages to this dimension and basis.
    /// Without one, percentages retain their own type and 0..100 scale.
    percentage: ?Value = null,
};

pub fn isMath(input: []const u8) bool {
    var iterator = tokens.Iterator{ .input = input };
    while (iterator.next()) |token| {
        if (token.isTrivia()) continue;
        if (token.kind != .function) return false;
        for ([_][]const u8{ "calc", "min", "max", "clamp", "abs", "sign" }) |name| {
            if (tokens.identifierEquals(token.encodedValue(input), name)) return true;
        }
        return false;
    }
    return false;
}

/// Evaluate one numeric component. Non-finite calculation results are valid;
/// color and length callers have different clamping/rejection requirements.
pub fn evaluate(input: []const u8, context: Context) ?Value {
    if (input.len > 1024 * 1024) return null;
    var parser = Parser{ .input = input, .context = context };
    const result = parser.atom(false) orelse return null;
    _ = parser.trivia();
    return if (parser.cursor == input.len) result else null;
}

/// Caller owns the canonical specified calculation. Relative units retain
/// their identity; no property range is applied until computed-value time.
/// Excessive trees return null without changing ordinary value evaluation.
pub fn serializeSpecified(allocator: std.mem.Allocator, input: []const u8, context: Context) !?[]u8 {
    if (!isMath(input) or input.len > 1024 * 1024) return null;
    var tree = expression.Tree{};
    var parser = Parser{ .input = input, .context = context, .tree = &tree };
    const result = parser.atom(false) orelse return null;
    _ = parser.trivia();
    if (parser.cursor != input.len) return null;
    return try tree.serialize(allocator, result.expression.?);
}

const Parser = struct {
    input: []const u8,
    context: Context,
    cursor: usize = 0,
    depth: usize = 0,
    tree: ?*expression.Tree = null,

    fn literal(self: *Parser, value: Value, number: f64, unit: expression.Unit) ?Value {
        var result = value;
        if (self.tree) |tree| result.expression = tree.literal(number, unit) orelse return null;
        return result;
    }

    fn function(self: *Parser, value: Value, tag: expression.Tag, arguments: []const expression.Index) ?Value {
        var result = value;
        if (self.tree) |tree| result.expression = tree.function(tag, arguments) orelse return null;
        return result;
    }

    fn trivia(self: *Parser) bool {
        var iterator = tokens.Iterator{ .input = self.input, .cursor = self.cursor };
        var whitespace = false;
        while (iterator.next()) |token| {
            if (!token.isTrivia()) break;
            whitespace = whitespace or token.kind == .whitespace;
            self.cursor = token.end;
        }
        return whitespace;
    }
    fn take(self: *Parser, kind: tokens.Kind) bool {
        _ = self.trivia();
        var iterator = tokens.Iterator{ .input = self.input, .cursor = self.cursor };
        const token = iterator.next() orelse return false;
        if (token.kind != kind) return false;
        self.cursor = token.end;
        return true;
    }
    fn sum(self: *Parser) ?Value {
        var result = self.product() orelse return null;
        while (true) {
            const whitespace = self.trivia();
            var iterator = tokens.Iterator{ .input = self.input, .cursor = self.cursor };
            const operator = iterator.next() orelse return result;
            if (operator.kind != .delim or (operator.delim != '+' and operator.delim != '-')) return result;
            if (!whitespace) return null;
            self.cursor = operator.end;
            if (!self.trivia()) return null;
            const right = self.product() orelse return null;
            if (right.dimension != result.dimension) return null;
            result.value += if (operator.delim == '+') right.value else -right.value;
            if (self.tree) |tree| {
                const rhs = if (operator.delim == '+') right.expression.? else tree.unary(.negate, right.expression.?) orelse return null;
                result.expression = tree.binary(.sum, result.expression.?, rhs) orelse return null;
            }
        }
    }
    fn product(self: *Parser) ?Value {
        var result = self.atom(true) orelse return null;
        while (true) {
            const before_space = self.cursor;
            _ = self.trivia();
            var iterator = tokens.Iterator{ .input = self.input, .cursor = self.cursor };
            const operator = iterator.next() orelse return result;
            if (operator.kind != .delim or (operator.delim != '*' and operator.delim != '/')) {
                self.cursor = before_space;
                return result;
            }
            self.cursor = operator.end;
            const right = self.atom(true) orelse return null;
            if (operator.delim == '*') {
                if (result.dimension != .number and right.dimension != .number) return null;
                result.value *= right.value;
                if (right.dimension != .number) result.dimension = right.dimension;
            } else {
                if (right.dimension != .number) {
                    if (result.dimension != right.dimension) return null;
                    result.dimension = .number;
                }
                result.value /= right.value;
            }
            if (self.tree) |tree| {
                const rhs = if (operator.delim == '*') right.expression.? else tree.unary(.invert, right.expression.?) orelse return null;
                result.expression = tree.binary(.product, result.expression.?, rhs) orelse return null;
            }
        }
    }
    fn atom(self: *Parser, in_math: bool) ?Value {
        if (self.depth >= 64) return null;
        self.depth += 1;
        defer self.depth -= 1;
        _ = self.trivia();
        var iterator = tokens.Iterator{ .input = self.input, .cursor = self.cursor };
        const token = iterator.next() orelse return null;
        self.cursor = token.end;
        if (token.kind == .open_paren and in_math) {
            const inner = self.sum() orelse return null;
            return if (self.take(.close_paren)) inner else null;
        }
        if (token.kind == .function) {
            const name = token.encodedValue(self.input);
            var result = self.sum() orelse return null;
            var first_three: [3]Value = undefined;
            first_three[0] = result;
            var arguments: [expression.max_nodes]expression.Index = undefined;
            if (self.tree != null) arguments[0] = result.expression.?;
            var count: usize = 1;
            while (self.take(.comma)) {
                const item = self.sum() orelse return null;
                if (item.dimension != result.dimension) return null;
                if (count < first_three.len) first_three[count] = item;
                if (self.tree != null) {
                    if (count == arguments.len) return null;
                    arguments[count] = item.expression.?;
                }
                count += 1;
                if (std.math.isNan(item.value) or std.math.isNan(result.value)) {
                    result.value = std.math.nan(f64);
                } else if (tokens.identifierEquals(name, "min")) {
                    result.value = @min(result.value, item.value);
                } else if (tokens.identifierEquals(name, "max")) {
                    result.value = @max(result.value, item.value);
                }
            }
            if (!self.take(.close_paren)) return null;
            if (tokens.identifierEquals(name, "min") or tokens.identifierEquals(name, "max"))
                return self.function(result, if (tokens.identifierEquals(name, "min")) .min else .max, arguments[0..if (self.tree != null) count else 0]);
            if (tokens.identifierEquals(name, "clamp") and count == 3) {
                const a = first_three[0].value;
                const b = first_three[1].value;
                const c = first_three[2].value;
                result.value = if (std.math.isNan(a) or std.math.isNan(b) or std.math.isNan(c)) std.math.nan(f64) else @max(a, @min(b, c));
                return self.function(result, .clamp, arguments[0..if (self.tree != null) count else 0]);
            }
            if (count != 1) return null;
            if (tokens.identifierEquals(name, "calc")) return result;
            if (tokens.identifierEquals(name, "abs")) return self.function(.{ .value = @abs(result.value), .dimension = result.dimension }, .abs, arguments[0..if (self.tree != null) count else 0]);
            if (tokens.identifierEquals(name, "sign")) return self.function(.{ .value = if (result.value == 0 or std.math.isNan(result.value)) result.value else if (result.value < 0) -1 else 1, .dimension = .number }, .sign, arguments[0..if (self.tree != null) count else 0]);
            return null;
        }
        if (token.kind == .ident and in_math) {
            const name = token.encodedValue(self.input);
            const value: f64 = if (tokens.identifierEquals(name, "infinity")) std.math.inf(f64) else if (tokens.identifierEquals(name, "-infinity")) -std.math.inf(f64) else if (tokens.identifierEquals(name, "nan")) std.math.nan(f64) else if (tokens.identifierEquals(name, "pi")) std.math.pi else if (tokens.identifierEquals(name, "e")) std.math.e else return null;
            return self.literal(.{ .value = value, .dimension = .number }, value, .number);
        }
        if (token.kind != .number and token.kind != .dimension and token.kind != .percentage) return null;
        const number = std.fmt.parseFloat(f64, self.input[token.start..token.number_end]) catch return null;
        if (!std.math.isFinite(number)) return null;
        if (token.kind == .number) return self.literal(.{ .value = number, .dimension = .number }, number, .number);
        if (token.kind == .percentage) {
            if (self.context.percentage) |hint| return self.literal(.{ .value = number / 100 * hint.value, .dimension = hint.dimension }, number, .percent);
            return self.literal(.{ .value = number, .dimension = .percentage }, number, .percent);
        }
        const unit = token.encodedValue(self.input);
        if (tokens.identifierEquals(unit, "s") or tokens.identifierEquals(unit, "ms")) {
            const seconds = number * (if (tokens.identifierEquals(unit, "s")) @as(f64, 1) else 0.001);
            return self.literal(.{ .value = seconds, .dimension = .time }, seconds, .s);
        }
        const scale: f64 = if (tokens.identifierEquals(unit, "px")) 1 else if (tokens.identifierEquals(unit, "mm")) 96.0 / 25.4 else if (tokens.identifierEquals(unit, "em")) self.context.font_size else if (tokens.identifierEquals(unit, "rem")) self.context.root_font_size else {
            const degrees: f64 = if (tokens.identifierEquals(unit, "deg")) 1 else if (tokens.identifierEquals(unit, "grad")) 0.9 else if (tokens.identifierEquals(unit, "rad")) 180.0 / std.math.pi else if (tokens.identifierEquals(unit, "turn")) 360 else return null;
            return self.literal(.{ .value = number * degrees, .dimension = .angle }, number * degrees, .deg);
        };
        const relative: expression.Unit = if (tokens.identifierEquals(unit, "em")) .em else if (tokens.identifierEquals(unit, "rem")) .rem else .px;
        return self.literal(.{ .value = number * scale, .dimension = .length }, if (relative == .px) number * scale else number, relative);
    }
};

test "typed CSS math shares relative units functions and percentage hints" {
    const v = evaluate("calc(50% + (sign(1em - 10px) * 10%))", .{ .font_size = 8 }).?;
    try std.testing.expectEqual(Dimension.percentage, v.dimension);
    try std.testing.expectEqual(@as(f64, 40), v.value);
    try std.testing.expectEqual(@as(f64, 60), evaluate("calc(50deg + sign(1em - 10px) * 10deg)", .{}).?.value);
    try std.testing.expectEqual(@as(f64, 360), evaluate("calc(100% - 2rem)", .{ .root_font_size = 20, .percentage = .{ .dimension = .length, .value = 400 } }).?.value);
    try std.testing.expectEqual(@as(f64, 12), evaluate("clamp(5, max(9, 12), 20)", .{}).?.value);
    try std.testing.expect(std.math.isNan(evaluate("calc(0 / 0)", .{}).?.value));
    try std.testing.expect(std.math.isPositiveInf(evaluate("calc(infinity)", .{}).?.value));
    for ([_][]const u8{ "calc(1px + 2)", "calc(1% + 2deg)", "calc(1/**/+/**/2)", "calc(1 +2)", "calc(1 2)", "calc(1px * 2px)", "calc(2 / 1px)", "infinity", "future(1)", "sign(1,2)", "clamp(1,2)" }) |invalid| try std.testing.expect(evaluate(invalid, .{}) == null);
    try std.testing.expect(evaluate("calc(" ** 65 ++ "1" ++ ")" ** 65, .{}) == null);
}

test "specified calculations simplify constants while preserving contextual trees" {
    const cases = .{
        .{ "calc(50 * 3)", "calc(150)" },
        .{ "calc(0 / 0)", "calc(NaN)" },
        .{ "calc(2turn - 180deg)", "calc(540deg)" },
        .{ "min(20%, calc(5% + 5%))", "calc(10%)" },
        .{ "clamp(0, 3, 2)", "calc(2)" },
        .{ "calc(2em / 1em)", "calc(2)" },
        .{ "calc(1em + 2px + 3em - 1px)", "calc(4em + 1px)" },
        .{ "calc(1em / 2px)", "calc(1em / 2px)" },
        .{ "calc(50% * sign(100em - 1px))", "calc(50% * sign(100em - 1px))" },
        .{ "calc(sign(1em - 20px) * 10% + 50%)", "calc(50% + (10% * sign(1em - 20px)))" },
        .{ "max(1em, 20px)", "max(1em, 20px)" },
        .{ "calc(infinity * 1deg)", "calc(infinity * 1deg)" },
    };
    inline for (cases) |case| {
        const specified = (try serializeSpecified(std.testing.allocator, case[0], .{})).?;
        defer std.testing.allocator.free(specified);
        try std.testing.expectEqualStrings(case[1], specified);
        const again = (try serializeSpecified(std.testing.allocator, specified, .{})).?;
        defer std.testing.allocator.free(again);
        try std.testing.expectEqualStrings(specified, again);
        for ([_]f64{ 8, 40 }) |font_size| {
            const context = Context{ .font_size = font_size };
            const before = evaluate(case[0], context).?;
            const after = evaluate(specified, context).?;
            try std.testing.expectEqual(before.dimension, after.dimension);
            if (std.math.isFinite(before.value)) try std.testing.expectApproxEqAbs(before.value, after.value, 0.000001) else try std.testing.expect((std.math.isNan(before.value) and std.math.isNan(after.value)) or before.value == after.value);
        }
    }
}
