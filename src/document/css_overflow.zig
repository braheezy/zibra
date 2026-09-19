//! Pointer-free overflow grammar and computed-axis policy. Values and pairs
//! borrow no source storage; layout separately publishes their used policy.

const std = @import("std");

pub const Axis = enum { x, y };

pub const Value = enum {
    visible,
    hidden,
    clip,
    scroll,
    auto,

    pub fn text(self: Value) []const u8 {
        return @tagName(self);
    }

    pub fn isScrollable(self: Value) bool {
        return self == .hidden or self == .scroll or self == .auto;
    }

    pub fn allowsUserScroll(self: Value) bool {
        return self == .scroll or self == .auto;
    }

    pub fn clips(self: Value) bool {
        return self != .visible;
    }
};

pub const Pair = struct {
    x: Value = .visible,
    y: Value = .visible,

    pub fn axis(self: Pair, which: Axis) Value {
        return if (which == .x) self.x else self.y;
    }

    pub fn establishesFormattingContext(self: Pair) bool {
        return self.x.isScrollable() or self.y.isScrollable();
    }

    /// Viewport propagation interprets visible and clip independently of the
    /// donor's unchanged computed values.
    pub fn forViewport(self: Pair) Pair {
        return .{ .x = viewportValue(self.x), .y = viewportValue(self.y) };
    }
};

fn viewportValue(value: Value) Value {
    return switch (value) {
        .visible => .auto,
        .clip => .hidden,
        else => value,
    };
}

pub fn parse(raw: []const u8) ?Value {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    inline for (std.meta.fields(Value)) |field| {
        if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
    }
    if (std.ascii.eqlIgnoreCase(value, "overlay")) return .auto;
    return null;
}

pub fn parsePair(raw: []const u8) ?Pair {
    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c");
    const x = parse(tokens.next() orelse return null) orelse return null;
    const y = if (tokens.next()) |token| parse(token) orelse return null else x;
    if (tokens.next() != null) return null;
    return .{ .x = x, .y = y };
}

/// Compute both axes from the same specified pair. The current Overflow draft
/// preserves clip beside scrollable values; only visible becomes auto.
pub fn compute(specified: Pair) Pair {
    return .{
        .x = if (specified.x == .visible and specified.y.isScrollable()) .auto else specified.x,
        .y = if (specified.y == .visible and specified.x.isScrollable()) .auto else specified.y,
    };
}

test "overflow grammar canonicalizes aliases and rejects extra components" {
    try std.testing.expectEqual(Value.auto, parse(" OVERLAY ").?);
    try std.testing.expectEqual(Pair{ .x = .hidden, .y = .clip }, parsePair("hidden clip").?);
    try std.testing.expectEqual(Pair{ .x = .auto, .y = .auto }, parsePair("overlay").?);
    for ([_][]const u8{ "", "none", "auto clip hidden", "initial auto", "auto, clip" }) |raw|
        try std.testing.expect(parsePair(raw) == null);
}

test "overflow computed pairs preserve independent clip axes" {
    const values = [_]Value{ .visible, .hidden, .clip, .scroll, .auto };
    for (values) |x| for (values) |y| {
        const pair = compute(.{ .x = x, .y = y });
        try std.testing.expectEqual(if (x == .visible and y.isScrollable()) Value.auto else x, pair.x);
        try std.testing.expectEqual(if (y == .visible and x.isScrollable()) Value.auto else y, pair.y);
        try std.testing.expectEqual(pair, compute(pair));
    };
    try std.testing.expect(!(Pair{ .x = .clip }).establishesFormattingContext());
    try std.testing.expect((Pair{ .x = .clip, .y = .hidden }).establishesFormattingContext());
    try std.testing.expect(!Value.hidden.allowsUserScroll());
    try std.testing.expect(Value.hidden.isScrollable());
    try std.testing.expect(!Value.clip.isScrollable());
    try std.testing.expectEqual(Pair{ .x = .hidden, .y = .auto }, (Pair{ .x = .clip }).forViewport());
}
