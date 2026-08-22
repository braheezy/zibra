//! Pure touch-coordinate, gesture, and multi-contact regressions.

const std = @import("std");
const touch = @import("../browser/touch.zig");

test "normalized touch coordinates clamp to native window pixels" {
    try std.testing.expectEqual(@as(i32, 0), touch.normalizedCoordinate(-0.25, 800));
    try std.testing.expectEqual(@as(i32, 0), touch.normalizedCoordinate(0.0, 800));
    try std.testing.expectEqual(@as(i32, 400), touch.normalizedCoordinate(0.5, 800));
    try std.testing.expectEqual(@as(i32, 799), touch.normalizedCoordinate(1.0, 800));
    try std.testing.expectEqual(@as(i32, 799), touch.normalizedCoordinate(2.0, 800));
    try std.testing.expectEqual(@as(i32, 0), touch.normalizedCoordinate(std.math.nan(f32), 800));
    try std.testing.expectEqual(@as(i32, 0), touch.normalizedCoordinate(0.5, 0));
}

test "touch release within slop becomes one click at the release point" {
    var tracker = touch.Tracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.begin(10, 20, 0.25, 0.5, 1024, 512);
    tracker.motion(10, 20, 0.2578125, 0.51171875, 1024, 512);
    const point = tracker.end(10, 20, 0.2578125, 0.51171875, 1024, 512).?;
    try std.testing.expectEqual(touch.Point{ .x = 264, .y = 262 }, point);
    try std.testing.expectEqual(@as(usize, 0), tracker.count());
    try std.testing.expect(tracker.end(10, 20, 0.25, 0.5, 1024, 512) == null);
}

test "touch drag remains canceled even if the finger returns before release" {
    var tracker = touch.Tracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.begin(1, 2, 0.25, 0.25, 800, 600);
    tracker.motion(1, 2, 0.5, 0.5, 800, 600);
    try std.testing.expect(tracker.end(1, 2, 0.25, 0.25, 800, 600) == null);

    // A release can cross the slop without an intermediate motion event.
    try tracker.begin(1, 2, 0.25, 0.25, 800, 600);
    try std.testing.expect(tracker.end(1, 2, 0.5, 0.25, 800, 600) == null);
}

test "simultaneous fingers and touch devices retain independent contacts" {
    var tracker = touch.Tracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.begin(1, 7, 0.1, 0.1, 1000, 500);
    try tracker.begin(1, 8, 0.2, 0.2, 1000, 500);
    try tracker.begin(2, 7, 0.3, 0.3, 1000, 500);
    try std.testing.expectEqual(@as(usize, 3), tracker.count());

    try std.testing.expectEqual(
        touch.Point{ .x = 200, .y = 100 },
        tracker.end(1, 8, 0.2, 0.2, 1000, 500).?,
    );
    try std.testing.expectEqual(
        touch.Point{ .x = 300, .y = 150 },
        tracker.end(2, 7, 0.3, 0.3, 1000, 500).?,
    );
    try std.testing.expectEqual(@as(usize, 1), tracker.count());

    // A repeated down for the same identity replaces stale gesture state.
    tracker.motion(1, 7, 0.9, 0.9, 1000, 500);
    try tracker.begin(1, 7, 0.4, 0.4, 1000, 500);
    try std.testing.expectEqual(@as(usize, 1), tracker.count());
    try std.testing.expect(tracker.end(1, 7, 0.4, 0.4, 1000, 500) != null);

    try tracker.begin(3, 9, 0.5, 0.5, 1000, 500);
    tracker.clear();
    try std.testing.expectEqual(@as(usize, 0), tracker.count());
}

test "synthetic touch mouse sentinel is filtered" {
    try std.testing.expect(touch.isSyntheticMouse(std.math.maxInt(u32)));
    try std.testing.expect(!touch.isSyntheticMouse(0));
    try std.testing.expect(!touch.isSyntheticMouse(42));

    try std.testing.expect(touch.isSyntheticTouch(-1));
    try std.testing.expect(!touch.isSyntheticTouch(0));
    try std.testing.expect(!touch.isSyntheticTouch(42));
}
