//! Deterministic clock arithmetic regressions for animation scheduling.

const std = @import("std");
const browser = @import("../browser/root.zig");

test "animation deadlines advance from the prior deadline rather than completion" {
    const first = browser.nextAnimationFrameTiming(null, 1_000_000_000);
    try std.testing.expectEqual(@as(i96, 1_033_000_000), first.deadline_ns);
    try std.testing.expectEqual(@as(u64, 33_000_000), first.delay_ns);

    // Ten milliseconds of work consumed part of the next frame budget. A
    // fixed-delay scheduler would incorrectly wait another complete 33ms.
    const second = browser.nextAnimationFrameTiming(first.deadline_ns, 1_043_000_000);
    try std.testing.expectEqual(@as(i96, 1_066_000_000), second.deadline_ns);
    try std.testing.expectEqual(@as(u64, 23_000_000), second.delay_ns);
}

test "late animation frames use an immediate catch-up deadline" {
    const timing = browser.nextAnimationFrameTiming(1_033_000_000, 1_080_000_000);
    try std.testing.expectEqual(@as(i96, 1_066_000_000), timing.deadline_ns);
    try std.testing.expectEqual(@as(u64, 0), timing.delay_ns);
}
