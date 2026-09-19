//! Pointer-free scrollable-overflow bounds in authored-zoom layout pixels.
//! Layout owns traversal and policy; these operations retain no tree borrows.
const std = @import("std");

pub const Bounds = struct {
    x1: i32 = 0,
    y1: i32 = 0,
    x2: i32 = 0,
    y2: i32 = 0,

    pub fn box(x: i32, y: i32, width: i32, height: i32) Bounds {
        return .{ .x1 = x, .y1 = y, .x2 = x +| width, .y2 = y +| height };
    }

    pub fn translated(self: Bounds, x: i32, y: i32) Bounds {
        return .{ .x1 = self.x1 +| x, .y1 = self.y1 +| y, .x2 = self.x2 +| x, .y2 = self.y2 +| y };
    }

    pub fn unionWith(self: Bounds, other: Bounds) Bounds {
        return .{ .x1 = @min(self.x1, other.x1), .y1 = @min(self.y1, other.y1), .x2 = @max(self.x2, other.x2), .y2 = @max(self.y2, other.y2) };
    }

    /// The child border box participates even when its descendants are clipped.
    pub fn propagated(self: Bounds, width: i32, height: i32, clip_x: bool, clip_y: bool) Bounds {
        return .{
            .x1 = if (clip_x) 0 else @min(0, self.x1),
            .y1 = if (clip_y) 0 else @min(0, self.y1),
            .x2 = if (clip_x) width else @max(width, self.x2),
            .y2 = if (clip_y) height else @max(height, self.y2),
        };
    }
};

test "overflow axes propagate each descendant extent without losing the child box" {
    const content = Bounds{ .x1 = -30, .y1 = -40, .x2 = 200, .y2 = 300 };
    try std.testing.expectEqual(Bounds{ .x1 = 0, .y1 = -40, .x2 = 80, .y2 = 300 }, content.propagated(80, 60, true, false));
    try std.testing.expectEqual(Bounds{ .x1 = -30, .y1 = 0, .x2 = 200, .y2 = 60 }, content.propagated(80, 60, false, true));
    const limit = std.math.maxInt(i32);
    try std.testing.expectEqual(limit, content.translated(limit, 0).x2);
}
