//! Bounded codec boundary. Decoding owns all temporary source borrows, returns
//! independently owned PCM, and never knows about documents or native output.
const std = @import("std");
const zigaudio = @import("zigaudio");
const audio = @import("audio.zig");
pub const max_encoded_bytes = 32 * 1024 * 1024;

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, cancelled: ?*const std.atomic.Value(bool), budget: ?*audio.Budget) !audio.Clip {
    if (bytes.len > max_encoded_bytes) return error.AudioLimitExceeded;
    const decoder = try zigaudio.fromMemory(allocator, bytes);
    defer decoder.deinit(allocator);
    const info = decoder.info;
    if (info.channels == 0 or info.channels > 2 or info.sample_rate < 8000 or info.sample_rate > 192000) return error.UnsupportedAudioFormat;
    var reserved: usize = 0;
    errdefer if (budget) |owner| owner.release(reserved);
    var samples = std.ArrayList(f32).empty;
    defer samples.deinit(allocator);
    var chunk: [4096]f32 = undefined;
    while (true) {
        if (cancelled) |flag| if (flag.load(.acquire)) return error.Cancelled;
        const n = try decoder.read(chunk[0 .. chunk.len / info.channels * info.channels]);
        if (n == 0) break;
        if (samples.items.len + n > audio.max_clip_bytes / @sizeOf(f32)) return error.AudioLimitExceeded;
        if (budget) |owner| {
            try owner.reserve(n * @sizeOf(f32));
            reserved += n * @sizeOf(f32);
        }
        try samples.appendSlice(allocator, chunk[0..n]);
    }
    if (samples.items.len == 0 or samples.items.len % info.channels != 0) return error.InvalidAudioData;
    return .{ .samples = try samples.toOwnedSlice(allocator), .sample_rate = info.sample_rate, .channels = info.channels, .budget = budget };
}

/// Conservative hints only: successful decoding remains authoritative.
pub fn canPlayType(mime: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, mime, ';') orelse mime.len;
    const base = std.mem.trim(u8, mime[0..end], " \t\r\n");
    for ([_][]const u8{ "audio/wav", "audio/wave", "audio/x-wav", "audio/mpeg", "audio/mp3", "audio/flac", "audio/x-flac", "audio/ogg", "application/ogg", "audio/aac", "audio/qoa" }) |supported| {
        if (std.ascii.eqlIgnoreCase(base, supported)) return "maybe";
    }
    return "";
}

test "audio decoding owns complete seekable PCM and releases its pending budget" {
    const allocator = std.testing.allocator;
    const bytes = @embedFile("../tests/fixtures/audio.wav");
    var budget: audio.Budget = .{};
    var clip = try decode(allocator, bytes, null, &budget);
    try std.testing.expectEqual(@as(u32, 8000), clip.sample_rate);
    try std.testing.expectEqual(@as(usize, 80), clip.frames());
    try std.testing.expectEqual(@as(usize, 80 * 4), budget.used.load(.acquire));
    clip.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.acquire));
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, decode(allocator, bytes, &cancelled, &budget));
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.acquire));
}

test "audio MP3 decoding seeks through the same PCM voice API as WAV" {
    const allocator = std.testing.allocator;
    var engine = audio.Engine.init(allocator);
    engine.output = .manual;
    defer engine.deinit();
    const clip = try decode(allocator, @embedFile("../tests/fixtures/audio.mp3"), null, &engine.budget);
    try std.testing.expectEqual(@as(u8, 2), clip.channels);
    try std.testing.expectEqual(@as(u32, 44100), clip.sample_rate);
    try std.testing.expect(clip.frames() > 1000);
    const frame = clip.frames() / 2;
    const expected = clip.samples[frame * 2];
    const voice = try engine.add(clip);
    try engine.seek(voice, @as(f64, @floatFromInt(frame)) / 44100.0);
    try engine.play(voice);
    var output: [2]f32 = undefined;
    engine.mix(&output);
    try std.testing.expectApproxEqAbs(expected, output[0], 0.00001);
}
