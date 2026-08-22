//! Deterministic clock arithmetic regressions for animation scheduling.

const std = @import("std");
const browser = @import("../browser/root.zig");

test "animation deadlines advance from the prior deadline rather than completion" {
    const first = browser.nextAnimationFrameTiming(
        null,
        1_000_000_000,
        browser.animation_frame_interval_ns,
    );
    try std.testing.expectEqual(@as(i96, 1_033_000_000), first.deadline_ns);
    try std.testing.expectEqual(@as(u64, 33_000_000), first.delay_ns);

    // Ten milliseconds of work consumed part of the next frame budget. A
    // fixed-delay scheduler would incorrectly wait another complete 33ms.
    const second = browser.nextAnimationFrameTiming(
        first.deadline_ns,
        1_043_000_000,
        browser.animation_frame_interval_ns,
    );
    try std.testing.expectEqual(@as(i96, 1_066_000_000), second.deadline_ns);
    try std.testing.expectEqual(@as(u64, 23_000_000), second.delay_ns);
}

test "late animation frames use an immediate catch-up deadline" {
    const timing = browser.nextAnimationFrameTiming(
        1_033_000_000,
        1_080_000_000,
        browser.animation_frame_interval_ns,
    );
    try std.testing.expectEqual(@as(i96, 1_066_000_000), timing.deadline_ns);
    try std.testing.expectEqual(@as(u64, 0), timing.delay_ns);
}

test "estimated slower cadence turns a missed base frame into a real wait" {
    const timing = browser.nextAnimationFrameTiming(
        1_033_000_000,
        1_080_000_000,
        66_000_000,
    );
    try std.testing.expectEqual(@as(i96, 1_099_000_000), timing.deadline_ns);
    try std.testing.expectEqual(@as(u64, 19_000_000), timing.delay_ns);
}

test "frame estimator uses the slower overlapping pipeline stage" {
    var estimator = browser.FrameTimeEstimator{};
    try std.testing.expectEqual(browser.animation_frame_interval_ns, estimator.intervalNs());

    estimator.observeTabWork(12_000_000);
    estimator.observeBrowserWork(45_000_000);
    try std.testing.expectEqual(@as(i96, 66_000_000), estimator.intervalNs());
    try std.testing.expectEqual(@as(u64, 45_000_000), estimator.estimatedWorkNs());
}

test "frame estimator settles into slower cadence buckets under sustained work" {
    var estimator = browser.FrameTimeEstimator{};
    estimator.observeTabWork(55_000_000);
    try std.testing.expectEqual(@as(i96, 66_000_000), estimator.intervalNs());

    // The upward half-delta reaches the next sustainable bucket quickly.
    estimator.observeTabWork(75_000_000);
    try std.testing.expectEqual(@as(i96, 99_000_000), estimator.intervalNs());

    // Main-thread work can independently keep that slower cadence selected.
    estimator.observeBrowserWork(80_000_000);
    try std.testing.expectEqual(@as(i96, 99_000_000), estimator.intervalNs());
}

test "frame estimator recovers gradually after a transient overload" {
    var estimator = browser.FrameTimeEstimator{};
    estimator.observeTabWork(90_000_000);
    try std.testing.expectEqual(@as(i96, 99_000_000), estimator.intervalNs());

    estimator.observeTabWork(10_000_000);
    try std.testing.expect(estimator.intervalNs() > browser.animation_frame_interval_ns);

    for (0..24) |_| estimator.observeTabWork(10_000_000);
    try std.testing.expectEqual(browser.animation_frame_interval_ns, estimator.intervalNs());

    estimator.reset();
    try std.testing.expectEqual(browser.animation_frame_interval_ns, estimator.intervalNs());
    try std.testing.expectEqual(@as(u64, 0), estimator.estimatedWorkNs());
}
