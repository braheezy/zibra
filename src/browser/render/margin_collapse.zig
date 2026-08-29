//! Pure vertical-margin collapsing primitives for normal block flow.
//!
//! A collapsed margin is not a pairwise sum: an adjoining chain retains its
//! largest positive and most-negative members, then adds those two extrema.
//! Keeping that state separate lets layout carry a chain through arbitrarily
//! nested empty blocks without losing a margin that a later sibling exposes.

const std = @import("std");

/// Accumulates the used value of one chain of adjoining vertical margins.
///
/// The representation is associative, so callers may append values or merge
/// already-accumulated chains in any tree-walk order. It owns no memory.
pub const MarginStrut = struct {
    largest_positive: i32 = 0,
    most_negative: i32 = 0,

    pub fn init(margin: i32) MarginStrut {
        var strut = MarginStrut{};
        strut.append(margin);
        return strut;
    }

    pub fn append(self: *MarginStrut, margin: i32) void {
        if (margin >= 0) {
            self.largest_positive = @max(self.largest_positive, margin);
        } else {
            self.most_negative = @min(self.most_negative, margin);
        }
    }

    pub fn appendStrut(self: *MarginStrut, other: MarginStrut) void {
        self.largest_positive = @max(self.largest_positive, other.largest_positive);
        self.most_negative = @min(self.most_negative, other.most_negative);
    }

    pub fn used(self: MarginStrut) i32 {
        return self.largest_positive +| self.most_negative;
    }

    pub fn eql(self: MarginStrut, other: MarginStrut) bool {
        return self.largest_positive == other.largest_positive and
            self.most_negative == other.most_negative;
    }
};

test "margin strut preserves positive and negative extrema across a chain" {
    var strut = MarginStrut.init(8);
    strut.append(-3);
    strut.append(12);
    strut.append(-10);

    try std.testing.expectEqual(@as(i32, 12), strut.largest_positive);
    try std.testing.expectEqual(@as(i32, -10), strut.most_negative);
    try std.testing.expectEqual(@as(i32, 2), strut.used());
}

test "margin struts merge without losing nested empty-block margins" {
    var outer = MarginStrut.init(100);
    var inner = MarginStrut.init(0);
    inner.append(-96);
    outer.appendStrut(inner);

    try std.testing.expectEqual(@as(i32, 4), outer.used());
}
