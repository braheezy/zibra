//! Session-owned PCM mixer and lazy native output. Voices own their clips;
//! rendering borrows them only under the mixer mutex and never touches DOM/JS.
const std = @import("std");
const builtin = @import("builtin");
const zoto = @import("zoto");

pub const output_rate = 48000;
pub const output_channels = 2;
pub const max_clip_bytes = 128 * 1024 * 1024;
pub const max_session_bytes = 256 * 1024 * 1024;
pub const max_voices = 64;
pub const VoiceId = u64;

// At 48 kHz stereo f32, the native queue holds 32 ms across four buffers.
// The device worker can drain that entire queue before zoto's source worker
// runs again. Reserve two queues (64 ms), including one refill's headroom;
// a 10 ms source buffer inserts silence even though our PCM is already ready.
const device_buffer_bytes = 12288;
const source_buffer_bytes = 2 * device_buffer_bytes;

/// Accounts PCM retained by decoders, pending deliveries, and playing voices.
/// The session outlives every clip carrying this budget.
pub const Budget = struct {
    used: std.atomic.Value(usize) = .init(0),
    pub fn reserve(self: *Budget, bytes: usize) !void {
        var current = self.used.load(.monotonic);
        while (true) {
            if (bytes > max_session_bytes or current > max_session_bytes - bytes) return error.AudioLimitExceeded;
            current = self.used.cmpxchgWeak(current, current + bytes, .acq_rel, .monotonic) orelse return;
        }
    }
    pub fn release(self: *Budget, bytes: usize) void {
        const old = self.used.fetchSub(bytes, .acq_rel);
        std.debug.assert(old >= bytes);
    }
};

pub const Clip = struct {
    samples: []f32,
    sample_rate: u32,
    channels: u8,
    budget: ?*Budget = null,

    pub fn deinit(self: *Clip, allocator: std.mem.Allocator) void {
        if (self.budget) |budget| budget.release(self.samples.len * @sizeOf(f32));
        allocator.free(self.samples);
        self.* = undefined;
    }
    pub fn frames(self: Clip) usize {
        return self.samples.len / self.channels;
    }
    pub fn duration(self: Clip) f64 {
        return @as(f64, @floatFromInt(self.frames())) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

pub const Snapshot = struct {
    position: f64 = 0,
    duration: f64 = 0,
    playing: bool = false,
    ended: bool = false,
    submitted_frames: u64 = 0,
};

const time_ranges = @import("time_ranges.zig");

const Voice = struct {
    clip: Clip,
    played: time_ranges.Ranges = .{},
    submitted_frames: u64 = 0,
    position: f64 = 0,
    playing: bool = false,
    ended: bool = false,
    volume: f64 = 1,
    muted: bool = false,
    loop: bool = false,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    device_mutex: std.Io.Mutex = .init,
    voices: std.AutoHashMap(VoiceId, Voice),
    next_id: VoiceId = 1,
    bytes: usize = 0,
    budget: Budget = .{},
    /// Manual output advances only through mix(); disabled sessions reject play.
    output: enum { disabled, native, manual } = .disabled,
    device: ?*Device = null,
    device_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator, .voices = .init(allocator) };
    }

    /// All external callers must be quiescent. Native consumers join before
    /// voice storage and the owning session can be destroyed.
    pub fn deinit(self: *Engine) void {
        if (self.device) |device| device.deinit(self.allocator);
        var it = self.voices.valueIterator();
        while (it.next()) |voice| {
            voice.played.deinit(self.allocator);
            voice.clip.deinit(self.allocator);
        }
        self.voices.deinit();
        std.debug.assert(self.budget.used.load(.acquire) == 0);
    }

    /// Takes ownership of clip only on success. No device is opened here.
    pub fn add(self: *Engine, clip: Clip) !VoiceId {
        if (clip.channels == 0 or clip.channels > 2 or clip.sample_rate < 8000 or clip.sample_rate > 192000 or clip.samples.len % clip.channels != 0)
            return error.UnsupportedAudioFormat;
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        if (clip.samples.len > max_clip_bytes / @sizeOf(f32)) return error.AudioLimitExceeded;
        const bytes = clip.samples.len * @sizeOf(f32);
        if (bytes > max_clip_bytes or self.bytes + bytes > max_session_bytes or self.voices.count() >= max_voices) return error.AudioLimitExceeded;
        const id = self.next_id;
        self.next_id += 1;
        var owned = clip;
        if (clip.budget == null) {
            try self.budget.reserve(bytes);
            owned.budget = &self.budget;
        } else if (clip.budget != &self.budget) return error.WrongAudioBudget;
        errdefer if (clip.budget == null) self.budget.release(bytes);
        try self.voices.put(id, .{ .clip = owned });
        self.bytes += bytes;
        return id;
    }

    pub fn remove(self: *Engine, id: VoiceId) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        if (self.voices.fetchRemove(id)) |entry| {
            var clip = entry.value.clip;
            var played_ranges = entry.value.played;
            played_ranges.deinit(self.allocator);
            self.bytes -= clip.samples.len * @sizeOf(f32);
            clip.deinit(self.allocator);
        }
    }

    pub fn snapshot(self: *Engine, id: VoiceId) Snapshot {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        const voice = self.voices.get(id) orelse return .{};
        return .{ .position = voice.position / @as(f64, @floatFromInt(voice.clip.sample_rate)), .duration = voice.clip.duration(), .playing = voice.playing, .ended = voice.ended, .submitted_frames = voice.submitted_frames };
    }

    pub fn play(self: *Engine, id: VoiceId) !void {
        try self.ensureDevice();
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        const voice = self.voices.getPtr(id) orelse return error.UnknownVoice;
        try voice.played.reserve(self.allocator);
        if (voice.ended or voice.position >= @as(f64, @floatFromInt(voice.clip.frames()))) voice.position = 0;
        voice.ended = false;
        voice.playing = true;
    }
    pub fn pause(self: *Engine, id: VoiceId) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        if (self.voices.getPtr(id)) |voice| voice.playing = false;
    }
    pub fn seek(self: *Engine, id: VoiceId, seconds: f64) !void {
        if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidSeek;
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        const voice = self.voices.getPtr(id) orelse return error.UnknownVoice;
        try voice.played.reserve(self.allocator);
        voice.position = @min(seconds * @as(f64, @floatFromInt(voice.clip.sample_rate)), @as(f64, @floatFromInt(voice.clip.frames())));
        voice.ended = false;
    }

    /// Returns an independently owned normalized snapshot of submitted media
    /// intervals. Seeking alone never adds an interval; muted playback does.
    pub fn played(self: *Engine, id: VoiceId, allocator: std.mem.Allocator) ![]time_ranges.Range {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        const voice = self.voices.getPtr(id) orelse return allocator.alloc(time_ranges.Range, 0);
        return allocator.dupe(time_ranges.Range, voice.played.items.items);
    }
    pub fn configure(self: *Engine, id: VoiceId, volume: f64, muted: bool, loop: bool) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        if (self.voices.getPtr(id)) |voice| {
            voice.volume = if (std.math.isFinite(volume)) std.math.clamp(volume, 0, 1) else 0;
            voice.muted = muted;
            voice.loop = loop;
        }
    }

    /// Produces stereo f32 at output_rate without allocations. This is also
    /// the deterministic test/output seam. Position measures submitted PCM,
    /// not the hardware presentation clock (native buffering adds latency).
    pub fn mix(self: *Engine, output: []f32) void {
        std.debug.assert(output.len % output_channels == 0);
        @memset(output, 0);
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        var it = self.voices.valueIterator();
        while (it.next()) |voice| {
            if (!voice.playing) continue;
            const frames = voice.clip.frames();
            if (frames == 0) {
                voice.playing = false;
                voice.ended = true;
                continue;
            }
            const end: f64 = @floatFromInt(frames);
            const step = @as(f64, @floatFromInt(voice.clip.sample_rate)) / output_rate;
            const first_position = if (voice.loop) @mod(voice.position, end) else @min(voice.position, end);
            const first_submission = voice.submitted_frames;
            var wrapped = false;
            const gain: f32 = if (voice.muted) 0 else @floatCast(voice.volume);
            for (0..output.len / 2) |out_frame| {
                if (voice.position >= end) {
                    if (voice.loop) {
                        wrapped = true;
                        voice.position = @mod(voice.position, end);
                    } else {
                        voice.position = end;
                        voice.playing = false;
                        voice.ended = true;
                        break;
                    }
                }
                const first: usize = @intFromFloat(voice.position);
                const second = if (first + 1 < frames) first + 1 else if (voice.loop) 0 else first;
                const fraction: f32 = @floatCast(voice.position - @as(f64, @floatFromInt(first)));
                for (0..2) |channel| {
                    const source_channel = if (voice.clip.channels == 1) 0 else channel;
                    const a = voice.clip.samples[first * voice.clip.channels + source_channel];
                    const b = voice.clip.samples[second * voice.clip.channels + source_channel];
                    const value = a + (b - a) * fraction;
                    if (std.math.isFinite(value)) output[out_frame * 2 + channel] += value * gain;
                }
                voice.position += step;
                voice.submitted_frames += 1;
            }
            const advance = @as(f64, @floatFromInt(voice.submitted_frames - first_submission)) * step;
            const rate: f64 = @floatFromInt(voice.clip.sample_rate);
            if (voice.loop and advance >= end) {
                voice.played.add(0, end / rate);
            } else {
                if (voice.loop and (wrapped or voice.position >= end)) {
                    voice.played.add(first_position / rate, end / rate);
                    voice.played.add(0, @mod(voice.position, end) / rate);
                } else voice.played.add(first_position / rate, @min(voice.position, end) / rate);
            }
            if (!voice.loop and voice.position >= end) {
                voice.position = end;
                voice.playing = false;
                voice.ended = true;
            }
        }
        for (output) |*sample| sample.* = std.math.clamp(sample.*, -1, 1);
    }

    /// Reads backend failure without opening a device or holding the mixer lock.
    pub fn outputError(self: *Engine) ?anyerror {
        self.device_mutex.lockUncancelable(std.Options.debug_io);
        defer self.device_mutex.unlock(std.Options.debug_io);
        if (self.device_error) |err| return err;
        return if (self.device) |device| device.getErr() else null;
    }

    fn ensureDevice(self: *Engine) !void {
        switch (self.output) {
            .disabled => return error.AudioOutputDisabled,
            .manual => return,
            .native => {},
        }
        self.device_mutex.lockUncancelable(std.Options.debug_io);
        defer self.device_mutex.unlock(std.Options.debug_io);
        if (self.device_error) |err| return err;
        if (self.device) |device| if (device.getErr()) |err| return err;
        if (self.device == null) self.device = Device.init(self.allocator, self) catch |err| {
            self.device_error = err;
            return err;
        };
    }
};

/// Adapts complete PCM frames to arbitrary byte reads without losing partial
/// samples. Keep this owner stable while zoto retains its reader pointer.
const PcmReader = struct {
    engine: *Engine,
    reader: std.Io.Reader,
    pending: [1024]f32 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn init(engine: *Engine) PcmReader {
        return .{ .engine = engine, .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PcmReader = @fieldParentPtr("reader", r);
        if (limit == .nothing) return 0;
        if (self.start == self.end) {
            self.engine.mix(&self.pending);
            self.start = 0;
            self.end = @sizeOf(@TypeOf(self.pending));
        }
        const bytes = std.mem.sliceAsBytes(&self.pending);
        const n = try w.write(limit.slice(bytes[self.start..self.end]));
        self.start += n;
        return n;
    }
};

// Other zoto drivers still need their own lifecycle/0.16 audit. Keep their
// native output unavailable without preventing portable core/browser tests.
const Device = if (builtin.os.tag == .macos) struct {
    context: *zoto.Context,
    player: *zoto.Player,
    source: PcmReader,

    fn init(allocator: std.mem.Allocator, engine: *Engine) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        // Engine lifetime supplies the single application context. Bypass zoto's
        // process-once constructor so independent standalone sessions can retire.
        const context = try zoto.Context.init(allocator, output_rate, output_channels, .float32_le, device_buffer_bytes);
        errdefer context.deinit();
        context.waitForReady();
        if (context.getErr()) |err| return err;
        self.* = .{ .context = context, .player = undefined, .source = .init(engine) };
        self.player = try context.newPlayer(&self.source.reader);
        errdefer self.player.deinit();
        self.player.setBufferSize(source_buffer_bytes);
        try self.player.play();
        return self;
    }
    fn getErr(self: *@This()) ?anyerror {
        return self.context.getErr();
    }
    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.player.deinit();
        self.context.deinit();
        allocator.destroy(self);
    }
} else struct {
    fn init(_: std.mem.Allocator, _: *Engine) !*@This() {
        return error.AudioOutputUnavailable;
    }
    fn getErr(_: *@This()) ?anyerror {
        return null;
    }
    fn deinit(_: *@This(), _: std.mem.Allocator) void {}
};

fn testClip(allocator: std.mem.Allocator, samples: []const f32, rate: u32, channels: u8) !Clip {
    return .{ .samples = try allocator.dupe(f32, samples), .sample_rate = rate, .channels = channels };
}

test "audio mixer resamples mono and keeps pause, seek and EOF independent" {
    var engine = Engine.init(std.testing.allocator);
    engine.output = .manual;
    defer engine.deinit();
    const id = try engine.add(try testClip(std.testing.allocator, &.{ 0, 1, 0, -1 }, 24000, 1));
    try engine.play(id);
    var output: [8]f32 = undefined;
    engine.mix(&output);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0.5, 0.5, 1, 1, 0.5, 0.5 }, &output);
    engine.pause(id);
    const position = engine.snapshot(id).position;
    engine.mix(&output);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, &output);
    try std.testing.expectEqual(position, engine.snapshot(id).position);
    try engine.seek(id, 3.0 / 24000.0);
    try engine.play(id);
    engine.mix(&output);
    try std.testing.expectEqualSlices(f32, &.{ -1, -1, -1, -1, 0, 0, 0, 0 }, &output);
    try std.testing.expect(engine.snapshot(id).ended);
    try engine.play(id);
    try std.testing.expectEqual(@as(f64, 0), engine.snapshot(id).position);
    engine.remove(id);
    try std.testing.expectEqual(@as(usize, 0), engine.budget.used.load(.acquire));
}

test "audio mixer combines stereo voices, loops and advances muted playback" {
    var engine = Engine.init(std.testing.allocator);
    engine.output = .manual;
    defer engine.deinit();
    const a = try engine.add(try testClip(std.testing.allocator, &.{ 1, -1 }, 48000, 2));
    const b = try engine.add(try testClip(std.testing.allocator, &.{ 1, 1, 1, 1 }, 48000, 2));
    engine.configure(a, 0.5, false, true);
    try engine.play(a);
    try engine.play(b);
    var output: [6]f32 = undefined;
    engine.mix(&output);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0.5, 1, 0.5, 0.5, -0.5 }, &output);
    try std.testing.expect(!engine.snapshot(a).ended);
    try std.testing.expect(engine.snapshot(b).ended);
    engine.configure(a, 1, true, false);
    try engine.seek(a, 0);
    engine.mix(&output);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 0, 0 }, &output);
    try std.testing.expect(engine.snapshot(a).ended);
}

test "audio budget bounds pending PCM and disabled output never opens a device" {
    var budget: Budget = .{};
    try budget.reserve(max_session_bytes);
    try std.testing.expectError(error.AudioLimitExceeded, budget.reserve(1));
    budget.release(max_session_bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.acquire));
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    const id = try engine.add(try testClip(std.testing.allocator, &.{1}, 48000, 1));
    try std.testing.expectError(error.AudioOutputDisabled, engine.play(id));
    try std.testing.expect(engine.device == null);
    try std.testing.expect(!engine.snapshot(id).playing);
    try std.testing.expectError(error.InvalidSeek, engine.seek(id, std.math.nan(f64)));
}

test "audio PCM reader preserves stereo samples across unaligned byte reads" {
    var engine = Engine.init(std.testing.allocator);
    engine.output = .manual;
    defer engine.deinit();
    var expected: [4096]f32 = undefined;
    for (&expected, 0..) |*sample, i| sample.* = @as(f32, @floatFromInt(i % 31 + 1)) / (if (i % 2 == 0) @as(f32, 64) else -64);
    const id = try engine.add(try testClip(std.testing.allocator, &expected, output_rate, output_channels));
    try engine.play(id);
    var source = PcmReader.init(&engine);
    var actual: [@sizeOf(@TypeOf(expected))]u8 = undefined;
    const sizes = [_]usize{ 1, 7, 3840, 3, 4097, 24 };
    var cursor: usize = 0;
    var index: usize = 0;
    while (cursor < actual.len) : (index += 1) {
        const end = @min(actual.len, cursor + sizes[index % sizes.len]);
        try source.reader.readSliceAll(actual[cursor..end]);
        cursor = end;
    }
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), &actual);
}

test "audio played ranges track muted output and preserve disjoint seeks" {
    var engine = Engine.init(std.testing.allocator);
    engine.output = .manual;
    defer engine.deinit();
    const samples = try std.testing.allocator.alloc(f32, 48000);
    @memset(samples, 0);
    const id = try engine.add(.{ .samples = samples, .sample_rate = 48000, .channels = 1 });
    engine.configure(id, 1, true, false);
    try engine.play(id);
    var output: [9600]f32 = undefined;
    engine.mix(&output);
    try engine.seek(id, 0.5);
    engine.mix(&output);
    const first = try engine.played(id, std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), first[0].end, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), first[1].start, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), first[1].end, 1e-9);
    engine.pause(id);
    try engine.seek(id, 0.8);
    engine.mix(&output);
    const paused = try engine.played(id, std.testing.allocator);
    defer std.testing.allocator.free(paused);
    try std.testing.expectEqualSlices(time_ranges.Range, first, paused);
    try engine.play(id);
    engine.mix(&output);
    // Copies held by a caller remain static as the voice advances.
    try std.testing.expectEqual(@as(usize, 2), first.len);
    const later = try engine.played(id, std.testing.allocator);
    defer std.testing.allocator.free(later);
    try std.testing.expectEqual(@as(usize, 3), later.len);
}

test "audio played ranges remain normalized across resampled loop boundaries" {
    var engine = Engine.init(std.testing.allocator);
    engine.output = .manual;
    defer engine.deinit();
    const samples = try std.testing.allocator.alloc(f32, 44100);
    @memset(samples, 0);
    const id = try engine.add(.{ .samples = samples, .sample_rate = 44100, .channels = 1 });
    engine.configure(id, 1, false, true);
    try engine.seek(id, 0.8);
    try engine.play(id);
    var output: [1234]f32 = undefined;
    for (0..300) |_| engine.mix(&output);
    const ranges = try engine.played(id, std.testing.allocator);
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqualSlices(time_ranges.Range, &.{.{ .start = 0, .end = 1 }}, ranges);
}

test "audio zoto buffering survives a full device refill burst" {
    const allocator = std.testing.allocator;
    var engine = Engine.init(allocator);
    engine.output = .manual;
    defer engine.deinit();
    const id = try engine.add(try testClip(allocator, &.{ 0.25, -0.125 }, output_rate, output_channels));
    engine.configure(id, 1, false, true);
    try engine.play(id);
    var source = PcmReader.init(&engine);

    // No producer thread: model a scheduler turn in which the device worker
    // drains all four returned Darwin buffers, plus another queue of refill
    // headroom, before the source worker runs. Check actual output, since zoto
    // pads an underfilled buffer with silence without reporting an error.
    var mux: zoto.mux.Mux = .{
        .sample_rate = output_rate,
        .channel_count = output_channels,
        .format = .float32_le,
        .players = .init(allocator),
        .buffer_pool = try @FieldType(zoto.mux.Mux, "buffer_pool").init(allocator, 1, source_buffer_bytes),
        .allocator = allocator,
    };
    defer {
        mux.players.deinit();
        mux.buffer_pool.deinit();
    }
    const player = try mux.newPlayer(&source.reader);
    defer player.deinit();
    player.setBufferSize(source_buffer_bytes);
    try player.play();
    var output: [device_buffer_bytes / 4 / @sizeOf(f32)]f32 = undefined;
    for (0..8) |_| {
        try mux.readFloat32s(&output);
        for (output, 0..) |sample, i| try std.testing.expectEqual(if (i % 2 == 0) @as(f32, 0.25) else -0.125, sample);
    }
}
