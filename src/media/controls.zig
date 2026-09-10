//! Pointer-free native audio control presentation and interaction values.
//! The document stores a copied State; the media controller owns playback.
const std = @import("std");
pub const natural_width = 300;
pub const natural_height = 40;
pub const Part = enum { play, seek, mute, volume };
pub const Key = enum { left, right, up, down, home, end, activate, mute };
/// A pointer capture retains only document/source identity and scalar geometry.
pub const Drag = struct {
    window: u32,
    generation: u64,
    handle: u32,
    revision: u64,
    part: Part,
    pointer_x: i32,
    value: f64,
    width: i32,
    zoom: f32,
};
pub const State = struct {
    paused: bool = true,
    loading: bool = false,
    failed: bool = false,
    ready: bool = false,
    muted: bool = false,
    position: f64 = 0,
    duration: f64 = 0,
    volume: f64 = 1,
};

pub fn next(part: Part, reverse: bool) ?Part {
    const i = @intFromEnum(part);
    if (reverse) return if (i == 0) null else @enumFromInt(i - 1);
    return if (i == 3) null else @enumFromInt(i + 1);
}

pub fn fraction(x: i32, left: i32, right: i32) f64 {
    if (right <= left) return 0;
    return std.math.clamp(@as(f64, @floatFromInt(@as(i64, x) - left)) / @as(f64, @floatFromInt(@as(i64, right) - left)), 0, 1);
}

pub fn time(buffer: []u8, seconds: f64) []const u8 {
    const s: u64 = @intFromFloat(std.math.clamp(if (std.math.isFinite(seconds)) seconds else 0, 0, 359999));
    return if (s >= 3600)
        std.fmt.bufPrint(buffer, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) catch "--:--"
    else
        std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "--:--";
}

pub fn label(buffer: []u8, state: State, part: Part) []const u8 {
    return switch (part) {
        .play => if (state.failed) "Audio unavailable" else if (state.loading) "Audio loading" else if (state.paused) "Play audio" else "Pause audio",
        .mute => if (state.muted) "Unmute audio" else "Mute audio",
        .seek => blk: {
            var current: [24]u8 = undefined;
            var duration: [24]u8 = undefined;
            break :blk std.fmt.bufPrint(buffer, "Audio position {s} of {s}", .{ time(&current, state.position), if (state.ready) time(&duration, state.duration) else "unknown" }) catch "Audio position";
        },
        .volume => std.fmt.bufPrint(buffer, "Audio volume {d} percent{s}", .{ @as(u32, @intFromFloat(state.volume * 100)), if (state.muted) " (muted)" else "" }) catch "Audio volume",
    };
}

test "audio controls clamp slider input and navigate all native parts" {
    try std.testing.expectEqual(@as(f64, 0.5), fraction(60, 10, 110));
    try std.testing.expectEqual(@as(f64, 0), fraction(-20, 10, 110));
    try std.testing.expectEqual(@as(f64, 1), fraction(200, 10, 110));
    try std.testing.expectEqual(@as(f64, 0), fraction(10, 10, 10));
    try std.testing.expectEqual(Part.seek, next(.play, false).?);
    try std.testing.expectEqual(Part.mute, next(.volume, true).?);
    try std.testing.expect(next(.volume, false) == null);
    try std.testing.expect(next(.play, true) == null);
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1:02:03", time(&buffer, 3723.9));
}
