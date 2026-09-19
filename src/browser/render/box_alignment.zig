//! Scalar box alignment after sizing. Layout supplies available space, used
//! margin-box metrics and local baselines; no DOM or layout identity is retained.
const std = @import("std");
pub const grammar = @import("../../document/css_alignment.zig");

pub const Distribution = struct { offset: f64 = 0, between: f64 = 0 };

fn start(free: f64, reverse: bool) f64 {
    return if (reverse) free else 0;
}

fn positional(value: grammar.Value, free: f64, reverse: bool) f64 {
    if (free < 0 and value.overflow == .safe) return 0;
    return switch (value.keyword) {
        .center => free / 2,
        .end, .self_end, .right => if (reverse) 0 else free,
        .start, .self_start, .left => start(free, reverse),
        .flex_end => free,
        .baseline => if (free < 0) 0 else start(free, reverse),
        .last_baseline => if (free < 0 or reverse) 0 else free,
        else => 0,
    };
}

/// Map physical left/right to logical start when the alignment axis is
/// vertical, as in a horizontal-writing column flex container. Unchanged
/// values borrow raw; mapped values are static strings and retain safety.
pub fn physicalToLogical(raw: []const u8, vertical: bool) []const u8 {
    if (!vertical) return raw;
    const value = grammar.parse(raw) orelse return raw;
    if (value.keyword != .left and value.keyword != .right) return raw;
    return switch (value.overflow) {
        .default => "start",
        .safe => "safe start",
        .unsafe => "unsafe start",
    };
}

/// Return axis-progression offsets. A reverse-axis caller mirrors the final
/// boxes; logical start/end are therefore mapped independently of flex-start.
pub fn position(raw: []const u8, free: f64, reverse: bool) f64 {
    const value = grammar.parse(raw) orelse return 0;
    return positional(value, free, reverse);
}

/// Distribution fallbacks retain safe overflow behavior, while positional
/// center/end permit negative space unless explicitly made safe.
pub fn distribute(raw: []const u8, free: f64, count: usize, reverse: bool) Distribution {
    if (count == 0) return .{};
    const value = grammar.parse(raw) orelse return .{};
    const n: f64 = @floatFromInt(count);
    switch (value.keyword) {
        .space_between => {
            if (free < 0 or count < 2) return .{};
            return .{ .between = free / (n - 1) };
        },
        .space_around => {
            if (free < 0) return .{};
            return .{ .offset = free / (2 * n), .between = free / n };
        },
        .space_evenly => {
            if (free < 0) return .{};
            return .{ .offset = free / (n + 1), .between = free / (n + 1) };
        },
        else => return .{ .offset = positional(value, free, reverse) },
    }
}

pub const AutoMargins = struct {
    before: f64 = 0,
    after: f64 = 0,
    auto_before: bool = false,
    auto_after: bool = false,
};
pub const MarginPolicy = enum { main, flex_cross, grid };
pub const MarginResolution = struct { before: f64, after: f64, suppressed: bool = false };

/// Resolve margins in the caller's axis progression. Flex cross-axis overflow
/// consumes the opposite margin and suppresses self-alignment; grid overflow
/// zeroes auto margins and allows self-alignment to proceed.
pub fn resolveAutoMargins(available: f64, size: f64, margins: AutoMargins, policy: MarginPolicy) MarginResolution {
    return resolveAutoMarginsReversed(available, size, margins, policy, false);
}

/// Like resolveAutoMargins, with margins supplied in reversed axis progression.
/// Only flex cross-axis overflow distinguishes this from ordinary progression:
/// overflow belongs to the logical end margin, not necessarily cross-end.
pub fn resolveAutoMarginsReversed(available: f64, size: f64, margins: AutoMargins, policy: MarginPolicy, reverse: bool) MarginResolution {
    var result = MarginResolution{
        .before = if (margins.auto_before) 0 else margins.before,
        .after = if (margins.auto_after) 0 else margins.after,
    };
    const count: usize = @as(usize, @intFromBool(margins.auto_before)) + @intFromBool(margins.auto_after);
    if (count == 0) return result;
    const free = available - size - result.before - result.after;
    if (free > 0) {
        const share = free / @as(f64, @floatFromInt(count));
        if (margins.auto_before) result.before = share;
        if (margins.auto_after) result.after = share;
        result.suppressed = true;
    } else if (policy == .flex_cross) {
        if (reverse) result.before = available - size - result.after else result.after = available - size - result.before;
        result.suppressed = true;
    }
    return result;
}

pub const BaselineGroup = struct {
    ascent: f64 = 0,
    descent: f64 = 0,
    populated: bool = false,

    /// Baseline is a local border-box offset. Margins contribute to the group
    /// extent but do not alter that offset when final boxes are positioned.
    pub fn add(self: *BaselineGroup, box_size: f64, baseline: f64, before: f64, after: f64) void {
        const ascent = before + baseline;
        const descent = box_size - baseline + after;
        self.ascent = if (self.populated) @max(self.ascent, ascent) else ascent;
        self.descent = if (self.populated) @max(self.descent, descent) else descent;
        self.populated = true;
    }

    pub fn size(self: BaselineGroup) f64 {
        return if (self.populated) @max(self.ascent + self.descent, 0) else 0;
    }

    pub fn offset(self: BaselineGroup, baseline: f64) f64 {
        return self.ascent - baseline;
    }
};

test "shared alignment retains unsafe overflow and maps reversed logical edges" {
    try std.testing.expectEqual(@as(f64, -30), position("center", -60, false));
    try std.testing.expectEqual(@as(f64, -60), position("end", -60, false));
    try std.testing.expectEqual(@as(f64, 0), position("safe center", -60, false));
    try std.testing.expectEqual(@as(f64, 0), position("safe center", -60, true));
    try std.testing.expectEqual(@as(f64, 40), position("start", 40, true));
    try std.testing.expectEqual(@as(f64, 0), position("flex-start", 40, true));
    try std.testing.expectEqual(@as(f64, 0), position("end", 40, true));
    try std.testing.expectEqual(@as(f64, 40), position("flex-end", 40, true));
    try std.testing.expectEqual(@as(f64, 0), distribute("space-around", -60, 3, false).offset);
    try std.testing.expectEqual(@as(f64, 30), distribute("space-around", 60, 1, false).offset);
    try std.testing.expectEqual(@as(f64, 20), distribute("space-evenly", 60, 2, false).between);
}

test "shared alignment maps column physical edges and baseline fallbacks" {
    try std.testing.expectEqualStrings("start", physicalToLogical("right", true));
    try std.testing.expectEqualStrings("safe start", physicalToLogical("safe left", true));
    try std.testing.expectEqualStrings("unsafe start", physicalToLogical("unsafe right", true));
    try std.testing.expectEqualStrings("right", physicalToLogical("right", false));
    try std.testing.expectEqualStrings("center", physicalToLogical("center", true));
    try std.testing.expectEqual(@as(f64, 40), position(physicalToLogical("right", true), 40, true));
    try std.testing.expectEqual(@as(f64, 40), position("baseline", 40, true));
    try std.testing.expectEqual(@as(f64, 0), position("last baseline", 40, true));
    try std.testing.expectEqual(@as(f64, 40), position("last baseline", 40, false));
    try std.testing.expectEqual(@as(f64, 0), position("last baseline", -40, false));
    try std.testing.expectEqual(@as(f64, 0), position("baseline", -40, true));
}

test "shared auto margins distinguish flex cross overflow from grid alignment" {
    const margins = AutoMargins{ .auto_before = true, .auto_after = true };
    const fits = resolveAutoMargins(100, 40, margins, .grid);
    try std.testing.expectEqual(@as(f64, 30), fits.before);
    try std.testing.expectEqual(@as(f64, 30), fits.after);
    try std.testing.expect(fits.suppressed);
    const flex = resolveAutoMargins(100, 140, margins, .flex_cross);
    try std.testing.expectEqual(@as(f64, 0), flex.before);
    try std.testing.expectEqual(@as(f64, -40), flex.after);
    try std.testing.expect(flex.suppressed);
    const reversed = resolveAutoMarginsReversed(100, 140, margins, .flex_cross, true);
    try std.testing.expectEqual(@as(f64, -40), reversed.before);
    try std.testing.expectEqual(@as(f64, 0), reversed.after);
    try std.testing.expect(reversed.suppressed);
    const grid = resolveAutoMargins(100, 140, margins, .grid);
    try std.testing.expectEqual(@as(f64, 0), grid.before);
    try std.testing.expectEqual(@as(f64, 0), grid.after);
    try std.testing.expect(!grid.suppressed);
}

test "shared baseline group accounts for local baseline offsets and margins" {
    var group = BaselineGroup{};
    group.add(20, 15, 10, 3);
    group.add(40, 30, 0, 2);
    try std.testing.expectEqual(@as(f64, 42), group.size());
    try std.testing.expectEqual(@as(f64, 15), group.offset(15));
    try std.testing.expectEqual(@as(f64, 0), group.offset(30));
}

test "shared baseline group preserves signed distances from negative margins" {
    var group = BaselineGroup{};
    try std.testing.expectEqual(@as(f64, 0), group.size());
    group.add(20, 20, 0, -10);
    try std.testing.expectEqual(@as(f64, 10), group.size());
    try std.testing.expectEqual(@as(f64, -10), group.descent);
    try std.testing.expectEqual(@as(f64, 0), group.offset(20));
    group = .{};
    group.add(20, 15, -20, 0);
    try std.testing.expectEqual(@as(f64, -5), group.ascent);
    try std.testing.expectEqual(@as(f64, 0), group.size());
    try std.testing.expectEqual(@as(f64, -20), group.offset(15));
    group.add(10, 8, -10, -4);
    try std.testing.expectEqual(@as(f64, 3), group.size());
}
