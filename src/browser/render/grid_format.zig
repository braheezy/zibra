//! Scalar grid track sizing for fixed, intrinsic, fractional and minmax tracks.
//! Receives no DOM, retained layout object or dependency-bearing field.
const std = @import("std");
pub const tracks = @import("../../document/grid_tracks.zig");
pub const Track = tracks.Track;

pub fn resolve(input: []const Track, intrinsic: []const f64, available: ?f64, gap: f64, stretch: bool, output: []f64) void {
    std.debug.assert(input.len == output.len and intrinsic.len == input.len);
    if (input.len == 0) return;
    for (input, intrinsic, output) |track, natural, *used| {
        used.* = @max(track.min, if (track.auto_min or track.auto_max) @min(natural, track.max orelse std.math.inf(f64)) else 0);
    }
    const extent = available orelse {
        var unit: f64 = 0;
        for (input, output) |track, used| if (track.fraction > 0) {
            unit = @max(unit, used / @max(track.fraction, 1));
        };
        for (input, output) |track, *used| if (track.fraction > 0) {
            used.* = @max(used.*, unit * track.fraction);
        };
        return;
    };
    var frozen: [tracks.max_tracks]bool = @splat(false);
    std.debug.assert(input.len <= frozen.len);
    for (0..input.len + 1) |_| {
        var free = extent - gap * @as(f64, @floatFromInt(input.len - 1));
        var fractions: f64 = 0;
        for (input, output, frozen[0..input.len]) |track, used, fixed| {
            if (track.fraction > 0 and !fixed) fractions += track.fraction else free -= used;
        }
        if (fractions == 0) break;
        const unit = @max(free, 0) / @max(fractions, 1);
        var changed = false;
        for (input, output, frozen[0..input.len]) |track, used, *fixed| {
            if (!fixed.* and track.fraction > 0 and unit * track.fraction < used) {
                fixed.* = true;
                changed = true;
            }
        }
        if (changed) continue;
        for (input, output, frozen[0..input.len]) |track, *used, fixed| {
            if (!fixed and track.fraction > 0) used.* = @max(used.*, unit * track.fraction);
        }
        break;
    }
    if (stretch) {
        var free = extent - gap * @as(f64, @floatFromInt(input.len - 1));
        var count: usize = 0;
        for (input, output) |track, used| {
            free -= used;
            if (track.auto_max) count += 1;
        }
        if (count > 0 and free > 0) {
            for (input, output) |track, *used| if (track.auto_max) {
                used.* += free / @as(f64, @floatFromInt(count));
            };
        }
    }
}

test "grid fixed and fr tracks subtract gaps and freeze intrinsic minima" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("100px minmax(0, 1fr) 2fr", .{ .percentage_base = 640 }, 20, 3, &parsed).?;
    var sizes: [3]f64 = undefined;
    resolve(parsed[0..count], &.{ 0, 0, 0 }, 640, 20, true, &sizes);
    try std.testing.expectApproxEqAbs(@as(f64, 100), sizes[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 500.0 / 3.0), sizes[1], 0.001);
    resolve(&.{ .{ .fraction = 1, .auto_max = false }, .{ .fraction = 1, .auto_max = false } }, &.{ 400, 20 }, 600, 0, true, sizes[0..2]);
    try std.testing.expectEqual(@as(f64, 400), sizes[0]);
    try std.testing.expectEqual(@as(f64, 200), sizes[1]);
}

test "responsive grid repeat uses available width and auto-fit collapses empty tracks" {
    var parsed: [tracks.max_tracks]Track = undefined;
    try std.testing.expectEqual(@as(?usize, 3), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 700 }, 20, 9, &parsed));
    try std.testing.expectEqual(@as(?usize, 2), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 700 }, 20, 2, &parsed));
    try std.testing.expectEqual(@as(?usize, 1), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 300 }, 20, 9, &parsed));
    try std.testing.expectEqual(@as(?usize, 4), tracks.parse("repeat(2, 20px 1fr)", .{}, 0, 4, &parsed));
    try std.testing.expect(tracks.parse("repeat(0, 1fr)", .{}, 0, 1, &parsed) == null);
}
