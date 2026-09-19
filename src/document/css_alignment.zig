//! Scalar box-alignment grammar shared by declaration admission and layout.
//! Values own no source bytes; shorthand slices borrow the input declaration.
const std = @import("std");
const Components = @import("grid_tracks.zig").Components;

pub const Keyword = enum {
    normal,
    auto,
    start,
    end,
    self_start,
    self_end,
    flex_start,
    flex_end,
    left,
    right,
    center,
    stretch,
    space_between,
    space_around,
    space_evenly,
    baseline,
    last_baseline,
};
pub const Overflow = enum { default, safe, unsafe };
pub const Value = struct { keyword: Keyword, overflow: Overflow = .default };

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn keyword(raw: []const u8) ?Keyword {
    const pairs = .{
        .{ "normal", Keyword.normal },               .{ "auto", Keyword.auto },                 .{ "start", Keyword.start },               .{ "end", Keyword.end },
        .{ "self-start", Keyword.self_start },       .{ "self-end", Keyword.self_end },         .{ "flex-start", Keyword.flex_start },     .{ "flex-end", Keyword.flex_end },
        .{ "left", Keyword.left },                   .{ "right", Keyword.right },               .{ "center", Keyword.center },             .{ "stretch", Keyword.stretch },
        .{ "space-between", Keyword.space_between }, .{ "space-around", Keyword.space_around }, .{ "space-evenly", Keyword.space_evenly }, .{ "baseline", Keyword.baseline },
    };
    inline for (pairs) |pair| if (eq(raw, pair[0])) return pair[1];
    return null;
}

fn positional(value: Keyword) bool {
    return switch (value) {
        .start, .end, .self_start, .self_end, .flex_start, .flex_end, .left, .right, .center => true,
        else => false,
    };
}

pub fn parse(raw: []const u8) ?Value {
    var parts = Components{ .input = raw };
    const first = parts.next() orelse return null;
    const second = parts.next();
    if (parts.next() != null) return null;
    if (second) |last| {
        if (eq(last, "baseline")) {
            if (eq(first, "first")) return .{ .keyword = .baseline };
            if (eq(first, "last")) return .{ .keyword = .last_baseline };
        }
        const safety: Overflow = if (eq(first, "safe")) .safe else if (eq(first, "unsafe")) .unsafe else return null;
        const position = keyword(last) orelse return null;
        return if (positional(position)) .{ .keyword = position, .overflow = safety } else null;
    }
    return .{ .keyword = keyword(first) orelse return null };
}

pub fn validForProperty(property: []const u8, raw: []const u8) bool {
    const value = parse(raw) orelse return false;
    const content = std.mem.endsWith(u8, property, "-content");
    const self = std.mem.endsWith(u8, property, "-self");
    const justify = std.mem.startsWith(u8, property, "justify-");
    return switch (value.keyword) {
        .auto => self,
        .space_between, .space_around, .space_evenly => content,
        .self_start, .self_end => !content,
        .left, .right => justify,
        .baseline, .last_baseline => !(content and justify),
        else => true,
    };
}

pub const Pair = struct { first: []const u8, second: []const u8 };

/// Split place-* values at a valid longhand grammar boundary. A two-token
/// position or baseline stays together; returned slices borrow `raw`.
pub fn parsePair(first_property: []const u8, second_property: []const u8, raw: []const u8) ?Pair {
    const text = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (validForProperty(first_property, text)) {
        if (validForProperty(second_property, text)) return .{ .first = text, .second = text };
        const first = parse(text).?;
        if (std.mem.eql(u8, first_property, "align-content") and (first.keyword == .baseline or first.keyword == .last_baseline)) return .{ .first = text, .second = "start" };
    }
    var parts = Components{ .input = text };
    while (parts.next()) |part| {
        const end = @intFromPtr(part.ptr) - @intFromPtr(text.ptr) + part.len;
        const left = std.mem.trim(u8, text[0..end], " \t\r\n\x0c");
        const right = std.mem.trim(u8, text[end..], " \t\r\n\x0c");
        if (validForProperty(first_property, left) and validForProperty(second_property, right)) return .{ .first = left, .second = right };
    }
    return null;
}

test "alignment grammar distinguishes distribution safety and item positions" {
    try std.testing.expectEqual(Value{ .keyword = .center, .overflow = .safe }, parse("safe center").?);
    try std.testing.expectEqual(Keyword.baseline, parse("first baseline").?.keyword);
    try std.testing.expectEqual(Keyword.last_baseline, parse("last baseline").?.keyword);
    try std.testing.expect(validForProperty("justify-content", "unsafe end"));
    try std.testing.expect(!validForProperty("align-items", "space-between"));
    try std.testing.expect(!validForProperty("justify-content", "baseline"));
    try std.testing.expect(!validForProperty("align-items", "auto"));
    try std.testing.expect(!validForProperty("align-content", "self-start"));
    try std.testing.expect(!validForProperty("align-items", "right"));
    try std.testing.expect(parse("safe stretch") == null);
    try std.testing.expect(parse("unsafe first baseline") == null);
    const pair = parsePair("align-items", "justify-items", "safe center last baseline").?;
    try std.testing.expectEqualStrings("safe center", pair.first);
    try std.testing.expectEqualStrings("last baseline", pair.second);
    try std.testing.expectEqualStrings("start", parsePair("align-content", "justify-content", "first baseline").?.second);
}
