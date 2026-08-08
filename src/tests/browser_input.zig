//! Focused tests for platform input normalization at the browser boundary.

const std = @import("std");
const browser = @import("../browser/root.zig");

test "mouse wheel delta preserves magnitude and normalizes direction" {
    try std.testing.expectEqual(@as(i32, -100), browser.wheelScrollDelta(1, false));
    try std.testing.expectEqual(@as(i32, 300), browser.wheelScrollDelta(-3, false));
    try std.testing.expectEqual(@as(i32, 100), browser.wheelScrollDelta(1, true));
    try std.testing.expectEqual(@as(i32, -200), browser.wheelScrollDelta(-2, true));
    try std.testing.expectEqual(@as(i32, 0), browser.wheelScrollDelta(0, false));
}

test "mouse wheel delta saturates instead of overflowing" {
    try std.testing.expectEqual(std.math.minInt(i32), browser.wheelScrollDelta(std.math.maxInt(i32), false));
    try std.testing.expectEqual(std.math.maxInt(i32), browser.wheelScrollDelta(std.math.minInt(i32), false));
}
