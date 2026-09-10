//! Normalized playback intervals. The control thread reserves storage before
//! a discontinuity; the mixer only merges into that reserved capacity.
const std = @import("std");

pub const Range = struct { start: f64, end: f64 };
pub const Ranges = struct {
    items: std.ArrayList(Range) = .empty,

    pub fn deinit(self: *Ranges, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    /// A new playback position can add at most two intervals, including wrap.
    /// Call under the voice lock before play/seek permits the mixer to advance.
    pub fn reserve(self: *Ranges, allocator: std.mem.Allocator) !void {
        try self.items.ensureUnusedCapacity(allocator, 2);
    }

    /// Merge overlap and adjacency without allocation. reserve() must have
    /// preceded the current uninterrupted playback segment.
    pub fn add(self: *Ranges, start: f64, end: f64) void {
        if (end <= start) return;
        var merged = Range{ .start = start, .end = end };
        var first: usize = 0;
        while (first < self.items.items.len and self.items.items[first].end < start) : (first += 1) {}
        var last = first;
        while (last < self.items.items.len and self.items.items[last].start <= merged.end) : (last += 1) {
            merged.start = @min(merged.start, self.items.items[last].start);
            merged.end = @max(merged.end, self.items.items[last].end);
        }
        if (first == last) {
            self.items.insertAssumeCapacity(first, merged);
        } else {
            self.items.items[first] = merged;
            const tail = self.items.items.len - last;
            std.mem.copyForwards(Range, self.items.items[first + 1 ..][0..tail], self.items.items[last..]);
            self.items.items.len = first + 1 + tail;
        }
    }
};

test "audio played ranges merge overlap and adjacency but preserve seek gaps" {
    var ranges: Ranges = .{};
    defer ranges.deinit(std.testing.allocator);
    for ([_]Range{ .{ .start = 4, .end = 5 }, .{ .start = 0, .end = 1 }, .{ .start = 2, .end = 3 }, .{ .start = 1, .end = 2 } }) |r| {
        try ranges.reserve(std.testing.allocator);
        ranges.add(r.start, r.end);
    }
    try std.testing.expectEqualSlices(Range, &.{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 5 } }, ranges.items.items);
    ranges.add(2, 4);
    try std.testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 5 }}, ranges.items.items);
}
