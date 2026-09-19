//! Scalar grid track sizing for fixed, intrinsic, fractional and minmax tracks.
//! Receives no DOM, retained layout object or dependency-bearing field.
const std = @import("std");
pub const tracks = @import("../../document/grid_tracks.zig");
pub const Track = tracks.Track;

pub const Contribution = struct {
    minimum: f64 = 0,
    min_content: f64 = 0,
    max_content: f64 = 0,
};

fn baseSize(track: Track, intrinsic: Contribution) f64 {
    return @max(0, switch (track.min_kind) {
        .fixed => track.min,
        .auto => intrinsic.minimum,
        .min_content => intrinsic.min_content,
        .max_content => intrinsic.max_content,
        .fraction, .fit_content => unreachable,
    });
}

fn growthLimit(track: Track, intrinsic: Contribution, base: f64) f64 {
    return @max(base, switch (track.max_kind) {
        .fixed => track.max orelse track.min,
        .auto, .max_content => intrinsic.max_content,
        .min_content => intrinsic.min_content,
        .fraction => std.math.inf(f64),
        .fit_content => @min(intrinsic.max_content, track.max orelse std.math.inf(f64)),
    });
}

/// Resolve current single-span track contributions. Definite space grows
/// intrinsic tracks to their limits before flexible tracks absorb the rest;
/// only auto maximums receive alignment stretch. Storage remains caller-owned.
pub fn resolve(input: []const Track, intrinsic: []const Contribution, available: ?f64, gap: f64, stretch: bool, output: []f64) void {
    std.debug.assert(input.len == output.len and intrinsic.len == input.len);
    if (input.len == 0) return;
    for (input, intrinsic, output) |track, contribution, *used| used.* = baseSize(track, contribution);
    const extent = available orelse {
        var unit: f64 = 0;
        for (input, intrinsic, output) |track, contribution, *used| {
            if (track.max_kind == .fraction) {
                if (track.fraction > 0) unit = @max(unit, @max(used.*, contribution.max_content) / @max(track.fraction, 1));
            } else used.* = growthLimit(track, contribution, used.*);
        }
        for (input, output) |track, *used| if (track.fraction > 0) {
            used.* = @max(used.*, unit * track.fraction);
        };
        return;
    };

    // Water-fill finite growth limits. Each iteration either consumes all
    // free space or caps another track, so the loop is bounded by track count.
    var free = extent - gap * @as(f64, @floatFromInt(input.len - 1));
    for (output) |used| free -= used;
    for (0..input.len + 1) |_| {
        if (free <= 0.000001) break;
        var count: usize = 0;
        for (input, intrinsic, output) |track, contribution, used| {
            if (track.max_kind != .fraction and growthLimit(track, contribution, baseSize(track, contribution)) > used + 0.000001) count += 1;
        }
        if (count == 0) break;
        const share = free / @as(f64, @floatFromInt(count));
        for (input, intrinsic, output) |track, contribution, *used| {
            if (track.max_kind != .fraction) {
                const addition = @min(share, @max(growthLimit(track, contribution, baseSize(track, contribution)) - used.*, 0));
                used.* += addition;
                free -= addition;
            }
        }
    }

    // The trial fraction decreases when a track freezes at its minimum. This
    // monotone threshold replaces fixed-size scratch and works for any number
    // of implicit rows as well as the bounded parsed column list.
    var largest_fraction: f64 = 0;
    for (input) |track| if (track.max_kind == .fraction) {
        largest_fraction = @max(largest_fraction, track.fraction);
    };
    var unit = std.math.inf(f64);
    for (0..input.len + 1) |_| {
        var flexible_space = extent - gap * @as(f64, @floatFromInt(input.len - 1));
        var fractions: f64 = 0;
        for (input, output) |track, used| {
            const fraction = if (largest_fraction > 0) track.fraction / largest_fraction else 0;
            if (track.max_kind == .fraction and fraction > 0 and used <= unit * fraction) {
                fractions += fraction;
            } else flexible_space -= used;
        }
        const next = if (fractions > 0) @max(flexible_space, 0) / @max(fractions, 1 / largest_fraction) else 0;
        if (next == unit) break;
        unit = next;
    }
    for (input, output) |track, *used| if (track.max_kind == .fraction and track.fraction > 0) {
        used.* = @max(used.*, unit * (track.fraction / largest_fraction));
    };
    if (stretch) {
        free = extent - gap * @as(f64, @floatFromInt(input.len - 1));
        var count: usize = 0;
        for (input, output) |track, used| {
            free -= used;
            if (track.max_kind == .auto) count += 1;
        }
        if (count > 0 and free > 0) {
            for (input, output) |track, *used| if (track.max_kind == .auto) {
                used.* += free / @as(f64, @floatFromInt(count));
            };
        }
    }
}

test "grid fixed and fr tracks subtract gaps and freeze intrinsic minima" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("100px minmax(0, 1fr) 2fr", .{ .percentage_base = 640 }, 20, 3, &parsed).?;
    var sizes: [3]f64 = undefined;
    resolve(parsed[0..count], &.{ .{}, .{}, .{} }, 640, 20, true, &sizes);
    try std.testing.expectApproxEqAbs(@as(f64, 100), sizes[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 500.0 / 3.0), sizes[1], 0.001);
    resolve(&.{ .{ .fraction = 1, .max_kind = .fraction }, .{ .fraction = 1, .max_kind = .fraction } }, &.{ .{ .minimum = 400 }, .{ .minimum = 20 } }, 600, 0, true, sizes[0..2]);
    try std.testing.expectEqual(@as(f64, 400), sizes[0]);
    try std.testing.expectEqual(@as(f64, 200), sizes[1]);
}

test "grid distinguishes intrinsic track minima growth limits and auto stretch" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("min-content max-content auto", .{}, 0, 3, &parsed).?;
    var output: [3]f64 = undefined;
    const contribution = Contribution{ .minimum = 20, .min_content = 40, .max_content = 100 };
    resolve(parsed[0..count], &.{ contribution, contribution, contribution }, 400, 0, true, &output);
    try std.testing.expectEqual(@as(f64, 40), output[0]);
    try std.testing.expectEqual(@as(f64, 100), output[1]);
    try std.testing.expectEqual(@as(f64, 260), output[2]);
    resolve(parsed[0..count], &.{ contribution, contribution, contribution }, 400, 0, false, &output);
    try std.testing.expectEqual(@as(f64, 100), output[2]);
}

test "grid grows finite tracks then flexes and keeps fit content min floors" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("minmax(20px, 100px) 1fr fit-content(60px)", .{}, 0, 3, &parsed).?;
    var output: [3]f64 = undefined;
    resolve(parsed[0..count], &.{ .{}, .{ .minimum = 20, .min_content = 20, .max_content = 40 }, .{ .minimum = 80, .min_content = 80, .max_content = 120 } }, 300, 0, true, &output);
    try std.testing.expectEqual(@as(f64, 100), output[0]);
    try std.testing.expectEqual(@as(f64, 120), output[1]);
    try std.testing.expectEqual(@as(f64, 80), output[2]);
}

test "grid zero fractions do not stretch and implicit rows need no bounded scratch" {
    var output: [300]f64 = undefined;
    const input = [_]Track{.{ .fraction = 1, .max_kind = .fraction }} ** 300;
    const intrinsic = [_]Contribution{.{ .minimum = 1 }} ** 300;
    resolve(&input, &intrinsic, 600, 0, false, &output);
    try std.testing.expectEqual(@as(f64, 2), output[299]);
    resolve(&.{.{ .min_kind = .fixed, .max_kind = .fraction }}, &.{.{ .max_content = 100 }}, 200, 0, true, output[0..1]);
    try std.testing.expectEqual(@as(f64, 0), output[0]);
}

test "grid large finite fractions preserve normalized allocation" {
    var output: [2]f64 = undefined;
    resolve(&.{ .{ .min_kind = .fixed, .max_kind = .fraction, .fraction = 1e308 }, .{ .min_kind = .fixed, .max_kind = .fraction, .fraction = 1e308 } }, &.{ .{}, .{} }, 100, 0, false, &output);
    try std.testing.expectEqual(@as(f64, 50), output[0]);
    try std.testing.expectEqual(@as(f64, 50), output[1]);
}

test "responsive grid repeat uses available width and auto-fit collapses empty tracks" {
    var parsed: [tracks.max_tracks]Track = undefined;
    try std.testing.expectEqual(@as(?usize, 3), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 700 }, 20, 9, &parsed));
    try std.testing.expectEqual(@as(?usize, 2), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 700 }, 20, 2, &parsed));
    try std.testing.expectEqual(@as(?usize, 1), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 300 }, 20, 9, &parsed));
    try std.testing.expectEqual(@as(?usize, 4), tracks.parse("repeat(2, 20px 1fr)", .{}, 0, 4, &parsed));
    try std.testing.expect(tracks.parse("repeat(0, 1fr)", .{}, 0, 1, &parsed) == null);
}
