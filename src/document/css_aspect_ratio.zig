//! Shared aspect-ratio grammar and canonical specified/computed serialization.
//! Parsed values are scalars; returned serialization belongs to the caller.
const std = @import("std");
const tokens = @import("css_tokenizer.zig");

pub const Value = struct {
    ratio: ?f64 = null,
    use_intrinsic: bool = true,
    numerator: ?f64 = null,
    denominator: f64 = 1,

    pub const auto = Value{};

    pub fn serialize(self: Value, allocator: std.mem.Allocator) ![]u8 {
        const numerator = self.numerator orelse return allocator.dupe(u8, "auto");
        return std.fmt.allocPrint(allocator, "{s}{d} / {d}", .{
            if (self.use_intrinsic) "auto " else "", numerator, self.denominator,
        });
    }
};

/// Accept nonnegative CSS numbers, including degenerate ratios. A zero axis is
/// valid syntax but supplies no preferred ratio to used-size resolution.
pub fn parse(input: []const u8) ?Value {
    var iterator = tokens.Iterator{ .input = input };
    var parts: [4]tokens.Token = undefined;
    var count: usize = 0;
    while (iterator.next()) |token| {
        if (token.isTrivia()) continue;
        if (count == parts.len) return null;
        parts[count] = token;
        count += 1;
    }
    if (count == 0) return null;
    var start: usize = 0;
    var end = count;
    var result = Value{ .use_intrinsic = false };
    if (isAuto(parts[0], input)) {
        result.use_intrinsic = true;
        start += 1;
    } else if (isAuto(parts[count - 1], input)) {
        result.use_intrinsic = true;
        end -= 1;
    }
    if (start == end) return .auto;
    result.numerator = number(parts[start], input) orelse return null;
    if (end - start == 3) {
        if (parts[start + 1].kind != .delim or parts[start + 1].delim != '/') return null;
        result.denominator = number(parts[start + 2], input) orelse return null;
    } else if (end - start != 1) return null;
    if (result.numerator.? > 0 and result.denominator > 0) {
        const ratio = result.numerator.? / result.denominator;
        if (std.math.isFinite(ratio) and ratio > 0) result.ratio = ratio;
    }
    return result;
}

fn isAuto(token: tokens.Token, input: []const u8) bool {
    return token.kind == .ident and tokens.identifierEquals(token.encodedValue(input), "auto");
}

fn number(token: tokens.Token, input: []const u8) ?f64 {
    if (token.kind != .number) return null;
    const value = std.fmt.parseFloat(f64, token.raw(input)) catch return null;
    return if (std.math.isFinite(value) and value >= 0) (if (value == 0) 0 else value) else null;
}

test "aspect ratios canonicalize order and retain valid degenerate numbers" {
    const allocator = std.testing.allocator;
    const value = parse("16 auto").?;
    const serialized = try value.serialize(allocator);
    defer allocator.free(serialized);
    try std.testing.expectEqualStrings("auto 16 / 1", serialized);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), parse(".00025 / .0001").?.ratio.?, 0.00001);
    try std.testing.expect(parse("0 / 0").?.ratio == null);
    try std.testing.expect(parse("16 / 0").?.ratio == null);
    for ([_][]const u8{ "auto / 5", "16 9", "16px / 9px", "16 / -9", "auto 1 / 1 auto", "1 /", "NaN", "0x1", "1/**/2" }) |invalid| {
        try std.testing.expect(parse(invalid) == null);
    }
}
