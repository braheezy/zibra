//! Document-owned media state, independent of DOM layout and JavaScript values.
//! A source revision cancels old work; the result owner must still release it.
const std = @import("std");
const audio = @import("audio.zig");
pub const Event = enum(u8) { emptied, abort, loadstart, loadedmetadata, loadeddata, canplay, canplaythrough, play, playing, pause, seeking, seeked, timeupdate, ended, volumechange, error_event, suspend_event };
pub fn eventName(event: Event) []const u8 {
    return switch (event) {
        .error_event => "error",
        .suspend_event => "suspend",
        else => @tagName(event),
    };
}

pub const Cancellation = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    cancelled: std.atomic.Value(bool) = .init(false),
    pub fn retain(self: *@This()) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *@This()) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    engine: *audio.Engine,
    voice: ?audio.VoiceId = null,
    revision: u64 = 0,
    token: ?*Cancellation = null,
    fingerprint: ?u64 = null,
    sources: std.ArrayList([]u8) = .empty,
    source_index: usize = 0,
    network: u8 = 0,
    ready: u8 = 0,
    error_code: u8 = 0,
    paused: bool = true,
    ended: bool = false,
    wanted: bool = false,
    volume: f64 = 1,
    muted: bool = false,
    muted_set: bool = false,
    loop: bool = false,
    autoplay: bool = false,
    autoplay_pending: bool = true,
    position: f64 = 0,
    duration: f64 = std.math.nan(f64),
    default_position: ?f64 = null,
    attached_seen: bool = false,
    detached: bool = false,
    events: [32]Event = undefined,
    event_count: usize = 0,
    last_time_frame: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, engine: *audio.Engine) State {
        return .{ .allocator = allocator, .engine = engine };
    }
    pub fn deinit(self: *State) void {
        self.cancel();
        for (self.sources.items) |source| self.allocator.free(source);
        self.sources.deinit(self.allocator);
    }
    pub fn currentSrc(self: *const State) []const u8 {
        if (self.network == 0 or self.source_index >= self.sources.items.len) return "";
        return self.sources.items[self.source_index];
    }
    pub fn cancel(self: *State) void {
        self.revision += 1;
        if (self.token) |token| {
            token.cancelled.store(true, .release);
            token.release();
            self.token = null;
        }
        if (self.voice) |voice| self.engine.remove(voice);
        self.voice = null;
    }
    pub fn reset(self: *State) void {
        const had_resource = self.network != 0;
        const was_loading = self.network == 2;
        self.cancel();
        self.event_count = 0;
        if (was_loading) self.queue(.abort);
        if (had_resource) self.queue(.emptied);
        self.network = 0;
        self.ready = 0;
        self.error_code = 0;
        self.paused = true;
        self.ended = false;
        self.wanted = false;
        self.position = 0;
        self.duration = std.math.nan(f64);
        self.default_position = null;
        self.autoplay_pending = true;
        self.source_index = 0;
        self.last_time_frame = 0;
    }
    pub fn queue(self: *State, event: Event) void {
        // Repeated controls can run synchronously; coalesce duplicate pending
        // notifications while retaining transition order and a fixed bound.
        for (self.events[0..self.event_count]) |existing| if (existing == event) return;
        if (self.event_count < self.events.len) {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }
    }
    pub fn fail(self: *State, code: u8) void {
        if (self.voice) |voice| self.engine.remove(voice);
        self.voice = null;
        self.error_code = code;
        self.network = 3;
        self.ready = 0;
        self.paused = true;
        self.wanted = false;
        self.queue(.error_event);
    }
    pub fn configure(self: *State) void {
        if (self.voice) |voice| self.engine.configure(voice, self.volume, self.muted, self.loop);
    }
    pub fn start(self: *State) !void {
        self.wanted = true;
        if (self.paused) {
            self.paused = false;
            self.queue(.play);
        }
        if (self.voice) |voice| {
            self.configure();
            self.engine.play(voice) catch |err| {
                self.fail(4);
                return err;
            };
            self.ended = false;
            self.queue(.playing);
        }
    }
    pub fn pause(self: *State) void {
        self.autoplay_pending = false;
        self.wanted = false;
        if (self.voice) |voice| self.engine.pause(voice);
        if (!self.paused) {
            self.paused = true;
            self.queue(.timeupdate);
            self.queue(.pause);
        }
    }
    pub fn seek(self: *State, seconds: f64) !void {
        if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidSeek;
        if (self.voice) |voice| {
            try self.engine.seek(voice, seconds);
            self.position = @min(seconds, self.duration);
            self.ended = false;
            self.queue(.seeking);
            self.queue(.timeupdate);
            self.queue(.seeked);
        } else self.default_position = seconds;
    }
    /// Takes clip on success; stale results are rejected before calling this.
    pub fn accept(self: *State, clip: audio.Clip) !void {
        self.voice = try self.engine.add(clip);
        self.duration = clip.duration();
        self.ready = 4;
        self.network = 1;
        self.error_code = 0;
        self.configure();
        self.queue(.loadedmetadata);
        self.queue(.loadeddata);
        self.queue(.canplay);
        self.queue(.canplaythrough);
        self.queue(.suspend_event);
        if (self.default_position) |seconds| {
            self.default_position = null;
            self.seek(seconds) catch unreachable;
        }
        if (self.wanted) self.start() catch {};
    }
    pub fn update(self: *State) void {
        if (self.voice) |voice| {
            if (self.wanted and self.engine.outputError() != null) {
                self.fail(4);
                return;
            }
            const snapshot = self.engine.snapshot(voice);
            self.position = snapshot.position;
            if (!self.paused and snapshot.submitted_frames - self.last_time_frame >= audio.output_rate / 4) {
                self.last_time_frame = snapshot.submitted_frames;
                self.queue(.timeupdate);
            }
            if (snapshot.ended and !self.ended) {
                self.ended = true;
                self.paused = true;
                self.wanted = false;
                self.queue(.timeupdate);
                self.queue(.pause);
                self.queue(.ended);
            }
        }
    }
};

test "audio element reset cancels revisions and releases clip ownership" {
    var engine = audio.Engine.init(std.testing.allocator);
    engine.output = .manual;
    defer engine.deinit();
    var state = State.init(std.testing.allocator, &engine);
    defer state.deinit();
    const token = try std.testing.allocator.create(Cancellation);
    token.* = .{ .allocator = std.testing.allocator };
    token.retain();
    defer token.release();
    state.token = token;
    try state.start();
    try state.seek(0.5);
    try state.accept(.{ .samples = try std.testing.allocator.dupe(f32, &.{ 0, 1 }), .sample_rate = 48000, .channels = 1 });
    try std.testing.expect(!state.paused);
    try std.testing.expectEqual(state.duration, state.position);
    const revision = state.revision;
    state.reset();
    try std.testing.expect(state.revision != revision);
    try std.testing.expect(token.cancelled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), engine.voices.count());
    try std.testing.expect(state.paused and state.ready == 0 and state.network == 0);
    try std.testing.expect(std.math.isNan(state.duration));
}

test "audio element pause during loading prevents delayed start and autoplay restart" {
    var engine = audio.Engine.init(std.testing.allocator);
    engine.output = .manual;
    defer engine.deinit();
    var state = State.init(std.testing.allocator, &engine);
    defer state.deinit();
    state.network = 2;
    try state.start();
    state.pause();
    try state.accept(.{ .samples = try std.testing.allocator.dupe(f32, &.{ 0, 1 }), .sample_rate = 48000, .channels = 1 });
    try std.testing.expect(state.paused and !state.wanted and !state.autoplay_pending);
    try std.testing.expect(!engine.snapshot(state.voice.?).playing);
    try std.testing.expectEqual(@as(u8, 4), state.ready);
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(f32)), engine.budget.used.load(.acquire));
}

test "audio timeupdate follows consumed frames even when a short clip loops" {
    var engine = audio.Engine.init(std.testing.allocator);
    engine.output = .manual;
    defer engine.deinit();
    var state = State.init(std.testing.allocator, &engine);
    defer state.deinit();
    state.loop = true;
    try state.accept(.{ .samples = try std.testing.allocator.dupe(f32, &.{ 0, 1 }), .sample_rate = 48000, .channels = 1 });
    try state.start();
    state.event_count = 0;
    var output: [24000]f32 = undefined;
    engine.mix(&output);
    state.update();
    try std.testing.expectEqual(@as(usize, 1), state.event_count);
    try std.testing.expectEqual(Event.timeupdate, state.events[0]);
    try std.testing.expect(!state.ended and !state.paused);
}
