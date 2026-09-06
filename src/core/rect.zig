//! Pointer-free floating-point rectangles shared by layout and host snapshots.
const std = @import("std");

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn translated(self: Rect, dx: f64, dy: f64) Rect {
        var result = self;
        result.x += dx;
        result.y += dy;
        return result;
    }

    pub fn scaled(self: Rect, factor: f64) Rect {
        return .{ .x = self.x * factor, .y = self.y * factor, .width = self.width * factor, .height = self.height * factor };
    }

    pub fn unionWith(self: Rect, other: Rect) Rect {
        const x = @min(self.x, other.x);
        const y = @min(self.y, other.y);
        return .{
            .x = x,
            .y = y,
            .width = @max(self.x + self.width, other.x + other.width) - x,
            .height = @max(self.y + self.height, other.y + other.height) - y,
        };
    }
};

test "geometry rectangles preserve fractional union and translation" {
    const a = Rect{ .x = 0.5, .y = -2, .width = 2.25, .height = 5 };
    const result = a.unionWith(a.translated(3, 2)).scaled(0.5);
    try std.testing.expectEqual(Rect{ .x = 0.25, .y = -1, .width = 2.625, .height = 3.5 }, result);
}
