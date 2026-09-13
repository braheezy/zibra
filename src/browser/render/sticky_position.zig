//! Pointer-free sticky constraints in one shared viewport coordinate space.
//! Layout owns the containing/scroll boxes and publishes the resulting visual
//! offset without changing the box's normal-flow geometry.
const std = @import("std");

pub const Axis = struct {
    start: f64,
    size: f64,
    containing_start: f64,
    containing_end: f64,
    margin_start: f64 = 0,
    margin_end: f64 = 0,
    port_start: f64,
    port_size: f64,
    inset_start: ?f64 = null,
    inset_end: ?f64 = null,

    pub fn offsetPixels(self: Axis) i32 {
        return @intFromFloat(std.math.clamp(self.offset(), std.math.minInt(i32), std.math.maxInt(i32)));
    }

    pub fn offset(self: Axis) f64 {
        if (self.inset_start == null and self.inset_end == null) return 0;
        const start_inset = self.inset_start orelse 0;
        // The end inset can become negative for a box taller/wider than the
        // scrollport. The start edge wins in horizontal-tb, ltr layout.
        const end_inset = @min(self.inset_end orelse 0, self.port_size - start_inset - self.size);
        const minimum = self.port_start + start_inset;
        const maximum = self.port_start + self.port_size - end_inset - self.size;
        // Margins only consume the space actually available in the original
        // containing block; overflowing margins must not move an unstuck box.
        const before = @min(self.margin_start, self.start - self.containing_start);
        const after = @min(self.margin_end, self.containing_end - self.start - self.size);
        var target = self.start;
        if (self.inset_end != null and target > maximum)
            target = @max(maximum, self.containing_start + before);
        if (self.inset_start != null and target < minimum)
            target = @min(minimum, self.containing_end - after - self.size);
        return target - self.start;
    }
};

test "sticky constraints preserve flow, stick, and stop at containing edges" {
    var axis = Axis{ .start = 100, .size = 50, .containing_start = -100, .containing_end = 400, .port_start = 0, .port_size = 200, .inset_start = 20 };
    try std.testing.expectEqual(@as(f64, 0), axis.offset());
    axis.start = -50;
    try std.testing.expectEqual(@as(f64, 70), axis.offset());
    axis.containing_end = 40;
    try std.testing.expectEqual(@as(f64, 40), axis.offset());
    axis.inset_start = null;
    axis.inset_end = 20;
    axis.start = 170;
    axis.containing_start = 0;
    axis.containing_end = 500;
    try std.testing.expectEqual(@as(f64, -40), axis.offset());
}

test "sticky oversized boxes, negative insets, margins and auto axes" {
    var axis = Axis{ .start = -100, .size = 300, .containing_start = -200, .containing_end = 500, .port_start = 10, .port_size = 200, .inset_start = 20, .inset_end = 30 };
    try std.testing.expectEqual(@as(f64, 130), axis.offset());
    axis.inset_start = -20;
    try std.testing.expectEqual(@as(f64, 90), axis.offset());
    axis.containing_end = 250;
    axis.margin_end = 30;
    try std.testing.expectEqual(@as(f64, 20), axis.offset());
    axis.inset_start = null;
    axis.inset_end = null;
    try std.testing.expectEqual(@as(f64, 0), axis.offset());
    axis.start = std.math.minInt(i32);
    axis.size = 0;
    axis.containing_start = std.math.minInt(i32);
    axis.containing_end = std.math.maxInt(i32);
    axis.port_start = std.math.maxInt(i32);
    axis.port_size = 100;
    axis.inset_start = 0;
    try std.testing.expectEqual(std.math.maxInt(i32), axis.offsetPixels());
}
