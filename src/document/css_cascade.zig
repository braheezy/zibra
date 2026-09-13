//! Scalar CSS cascade ordering. Selectors supply specificity; stylesheet
//! callers retain source order. This module owns no DOM or declaration data.
const std = @import("std");

/// Independent counts prevent lower-specificity atoms from carrying into a
/// higher category. Saturation applies to each category separately.
pub const Specificity = struct {
    ids: u32 = 0,
    classes: u32 = 0,
    types: u32 = 0,

    pub fn add(self: Specificity, other: Specificity) Specificity {
        return .{ .ids = self.ids +| other.ids, .classes = self.classes +| other.classes, .types = self.types +| other.types };
    }

    pub fn order(self: Specificity, other: Specificity) std.math.Order {
        inline for (.{ "ids", "classes", "types" }) |field| {
            const comparison = std.math.order(@field(self, field), @field(other, field));
            if (comparison != .eq) return comparison;
        }
        return .eq;
    }

    pub fn max(self: Specificity, other: Specificity) Specificity {
        return if (self.order(other) == .lt) other else self;
    }
};

pub const Origin = enum { user_agent, author };

/// The implemented cascade levels. Important UA declarations precede
/// important author declarations; HTML hints remain below authored rules.
pub const Level = enum { user_agent, hint, author, important_author, important_user_agent };

pub const Context = struct {
    origin: Origin = .author,
    inline_style: bool = false,
    specificity: Specificity = .{},
    source_order: usize = 0,
};

/// A declaration's immutable comparison key. Source order is the ordinal in
/// the unsorted stylesheet generation, shared by every declaration in a rule.
pub const Key = struct {
    level: Level,
    inline_style: bool = false,
    specificity: Specificity = .{},
    source_order: usize = 0,

    pub fn from(context: Context, important: bool) Key {
        return .{
            .level = if (important)
                if (context.origin == .user_agent) .important_user_agent else .important_author
            else if (context.origin == .user_agent) .user_agent else .author,
            .inline_style = context.inline_style,
            .specificity = context.specificity,
            .source_order = context.source_order,
        };
    }

    pub fn order(self: Key, other: Key) std.math.Order {
        const level = std.math.order(@intFromEnum(self.level), @intFromEnum(other.level));
        if (level != .eq) return level;
        const inline_style = std.math.order(@intFromBool(self.inline_style), @intFromBool(other.inline_style));
        if (inline_style != .eq) return inline_style;
        const specificity = self.specificity.order(other.specificity);
        if (specificity != .eq) return specificity;
        return std.math.order(self.source_order, other.source_order);
    }

    /// Equal keys are accepted so a caller can replace its own declaration.
    pub fn wins(self: Key, previous: ?Key) bool {
        return if (previous) |key| self.order(key) != .lt else true;
    }
};

test "CSS cascade compares origin importance inline attachment specificity and source independently" {
    const many = Specificity{ .classes = 100_000, .types = 100_000 };
    try std.testing.expectEqual(.gt, (Specificity{ .ids = 1 }).order(many));
    try std.testing.expectEqual(.gt, (Specificity{ .classes = 1 }).order(.{ .types = 100_000 }));
    const saturated = (Specificity{ .classes = std.math.maxInt(u32) }).add(.{ .classes = 1 });
    try std.testing.expectEqual(Specificity{ .classes = std.math.maxInt(u32) }, saturated);
    const keys = [_]Key{
        Key.from(.{ .origin = .user_agent, .specificity = .{ .ids = 100_000 } }, false),
        .{ .level = .hint },
        Key.from(.{}, false),
        Key.from(.{ .specificity = many }, false),
        Key.from(.{ .specificity = .{ .ids = 1 } }, false),
        Key.from(.{ .specificity = .{ .ids = 1 }, .source_order = 1 }, false),
        Key.from(.{ .inline_style = true }, false),
        Key.from(.{}, true),
        Key.from(.{ .inline_style = true }, true),
        Key.from(.{ .origin = .user_agent }, true),
    };
    for (keys[1..], keys[0 .. keys.len - 1]) |winner, loser| try std.testing.expect(winner.order(loser) == .gt);
}
