//! Real DOM/realm/controller/codec tests with deterministic output and explicit
//! task/timer delivery. No native device, arbitrary sleeps, or live network.
const std = @import("std");
const Js = @import("../script/js.zig");
const parser = @import("../document/parser.zig");
const Tab = @import("../browser/tab.zig").Tab;
const Frame = @import("../browser/tab.zig").Frame;
const Session = @import("../browser/session_state.zig").BrowserSession;
const Measure = @import("../runtime/measure_time.zig").MeasureTime;
const Url = @import("../network/url.zig").Url;
const Integration = @import("../browser/media.zig").Integration(Host);
const Host = struct {
    session_state: *Session,
    io: std.Io,
    pub fn setNeedsAnimationFrame(_: *Host, _: *Tab) void {}
    pub fn scheduleAnimationFrame(_: *Host) void {}
};
const Harness = struct {
    environ: std.process.Environ.Map,
    measure: Measure,
    session: Session,
    host: Host,
    tab: Tab,
    js: *Js,
    timers: std.ArrayList(u32) = .empty,
    source: []u8,
    const allocator = std.testing.allocator;

    fn init() !*Harness {
        const self = try allocator.create(Harness);
        self.environ = std.process.Environ.Map.init(allocator);
        self.measure = try Measure.init(allocator, std.testing.io, &self.environ);
        self.session = Session.init(allocator, std.testing.io);
        self.session.audio.output = .manual;
        try self.session.startNetworking(&self.measure);
        self.host = .{ .session_state = &self.session, .io = std.testing.io };
        self.tab = Tab.init(allocator, 800, 600, &self.measure);
        self.js = try Js.init(allocator, std.testing.io, &self.environ);
        self.timers = .empty;
        const frame = try allocator.create(Frame);
        frame.* = Frame.init(allocator, &self.tab, null, null);
        self.tab.root_frame = frame;
        self.tab.registerFrame(frame);
        frame.current_url = try allocator.create(Url);
        frame.current_url.?.* = try Url.init(allocator, "https://example.com/audio.html");
        frame.current_url_owned = true;
        var html = try parser.HTMLParser.init(allocator, "<html><body><audio id=a controls preload=none></audio><div id=host></div></body></html>");
        defer html.deinit(allocator);
        frame.current_node = try html.parse();
        parser.fixParentPointers(&frame.current_node.?, null);
        frame.js_context = self.js;
        _ = self.tab.activateDocumentGeneration(frame);
        frame.js_render_context.setPointers(&self.host, &self.tab, self.js, frame.window_id);
        self.js.setNodes(frame.window_id, &frame.current_node.?);
        self.js.setMediaCallback(frame.window_id, Integration.command, &frame.js_render_context);
        self.js.setSetTimeoutCallback(frame.window_id, timer, self);
        const wav = @embedFile("fixtures/audio.wav");
        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(wav.len));
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, wav);
        self.source = try std.fmt.allocPrint(allocator, "data:audio/wav;base64,{s}", .{encoded});
        return self;
    }
    fn deinit(self: *Harness) void {
        self.tab.deinit();
        self.js.deinit(allocator);
        self.session.deinit();
        self.measure.finish();
        self.environ.deinit();
        self.timers.deinit(allocator);
        allocator.free(self.source);
        allocator.destroy(self);
    }
    fn timer(raw: ?*anyopaque, handle: u32, _: u32, _: bool) !void {
        const self: *Harness = @ptrCast(@alignCast(raw.?));
        try self.timers.append(allocator, handle);
    }
    fn eval(self: *Harness, script: []const u8) !void {
        const result = try self.js.evaluate(self.tab.root_frame.?.window_id, script);
        try std.testing.expect(result.toBoolean());
    }
    fn setSource(self: *Harness) !void {
        const script = try std.fmt.allocPrint(allocator, "var a=document.getElementById('a'); a.src='{s}'; true;", .{self.source});
        defer allocator.free(script);
        try self.eval(script);
    }
    fn waitForLoads(self: *Harness) void {
        self.tab.async_thread_mutex.lock();
        defer self.tab.async_thread_mutex.unlock();
        while (self.tab.async_thread_refs != 0) self.tab.async_thread_condition.wait(&self.tab.async_thread_mutex);
    }
    fn deliverLoads(self: *Harness) !void {
        // The tab runner intentionally stays stopped: test code is its serial
        // owner. Loader completion publishes under the real queue mutex.
        for (0..32) |_| {
            self.waitForLoads();
            self.tab.task_runner.mutex.lock();
            const task = if (self.tab.task_runner.tasks.items.len != 0) self.tab.task_runner.tasks.orderedRemove(0) else null;
            self.tab.task_runner.mutex.unlock();
            const next = task orelse return;
            defer if (next.cleanup_fn) |cleanup| cleanup(next.context);
            try next.run_fn(next.context);
        }
        return error.TooManyMediaTasks;
    }
    fn tick(self: *Harness) !void {
        if (self.timers.items.len == 0) return;
        const handle = self.timers.orderedRemove(0);
        try self.js.runTimeoutCallback(self.tab.root_frame.?.window_id, handle);
    }
};

test "audio DOM exposes shared identity, loading, playback promises, seek and EOF" {
    const h = try Harness.init();
    defer h.deinit();
    try h.eval("var a=document.getElementById('a'); a instanceof HTMLAudioElement && a instanceof HTMLMediaElement && a.paused && a.networkState===0 && a.error===null && isNaN(a.duration) && document.querySelector('audio')===a");
    try h.setSource();
    try h.eval("a.networkState===0 && a.readyState===0 && a.canPlayType('audio/wav')==='maybe' && a.canPlayType('video/mp4')===''");
    try h.eval("var blocked=''; a.play().catch(function(e){blocked=e.name}); true");
    try h.eval("blocked==='NotAllowedError' && a.paused");
    try h.eval("a.muted=true; var resolved=false; var events=[]; a.onloadedmetadata=function(){events.push('metadata')}; a.onplaying=function(){events.push('playing')}; a.onended=function(){events.push('ended')}; a.play().then(function(){resolved=true}); !a.paused && a.networkState===2");
    try h.deliverLoads();
    try h.tick();
    try h.eval("resolved && a.currentSrc.indexOf('data:audio/wav;base64,')===0 && a.readyState===4 && a.duration===0.01 && a.seekable.length===1 && a.buffered.end(0)===a.duration && events.join(',')==='metadata,playing'");
    try h.eval("a.pause(); a.currentTime=0.005; a.paused && a.currentTime===0.005");
    try h.tick();
    try h.eval("!a.seeking");
    try h.eval("a.play(); true");
    var output: [2000]f32 = undefined;
    h.session.audio.mix(&output);
    try h.tick();
    try h.eval("a.ended && a.paused && a.currentTime===a.duration && events.indexOf('ended')>=0");
}

test "audio load replacement discards queued results and document retirement frees PCM" {
    const h = try Harness.init();
    defer h.deinit();
    try h.setSource();
    try h.eval("a.load(); true");
    h.waitForLoads(); // Old PCM now belongs to a queued delivery.
    try std.testing.expect(h.session.audio.budget.used.load(.acquire) > 0);
    try h.eval("a.src='data:audio/wav,invalid'; a.load(); true");
    try h.deliverLoads();
    try h.tick();
    try h.eval("a.error!==null && a.readyState===0 && a.paused");
    try std.testing.expectEqual(@as(usize, 0), h.session.audio.budget.used.load(.acquire));
    try h.setSource();
    try h.eval("a.load(); true");
    h.waitForLoads();
    h.tab.invalidateJsContext();
    try h.deliverLoads();
    try std.testing.expectEqual(@as(usize, 0), h.session.audio.voices.count());
    try std.testing.expectEqual(@as(usize, 0), h.session.audio.budget.used.load(.acquire));
}

test "audio survives DOM relocation and supports detached Audio objects" {
    const h = try Harness.init();
    defer h.deinit();
    try h.setSource();
    try h.eval("a.load(); document.getElementById('host').appendChild(a); a===document.getElementById('a')");
    try h.deliverLoads();
    try h.tick();
    try h.eval("a.readyState===4 && a.duration===0.01");
    try h.eval("var detached=new Audio(); detached instanceof HTMLAudioElement && detached.paused && detached.networkState===0");
    try h.eval("a.volume=0.3; a.muted=true; var bad=false; try {a.volume=2} catch(e) {bad=e.name==='IndexSizeError'}; bad && a.volume===0.3 && a.muted");
}

test "audio native device lifecycle smoke" {
    if (comptime @import("builtin").os.tag != .macos) return error.SkipZigTest;
    if (std.testing.environ.getPosix("ZIBRA_TEST_NATIVE_AUDIO") == null) return error.SkipZigTest;
    // Explicit opt-in opens the real device. Silence exercises consumption and
    // shutdown without making the regular unit suite produce sound.
    for (0..3) |_| {
        const h = try Harness.init();
        defer h.deinit();
        h.session.audio.output = .native;
        try h.setSource();
        try h.eval("a.muted=true; a.play(); true");
        try h.deliverLoads();
        const frame = h.tab.root_frame.?;
        var states = frame.audio_elements.valueIterator();
        const voice = states.next().?.*.voice.?;
        const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 3 * std.time.ns_per_s;
        while (!h.session.audio.snapshot(voice).ended) {
            if (std.Io.Clock.awake.now(std.testing.io).nanoseconds > deadline) return error.AudioDeviceDidNotConsumePCM;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
        }
        try std.testing.expect(h.session.audio.device != null);
    }
}

test "audio source fallback, preload changes and pause while decoding preserve intent" {
    const h = try Harness.init();
    defer h.deinit();
    const script = try std.fmt.allocPrint(std.testing.allocator, "var a=document.getElementById('a'); a.innerHTML=\"<source src='data:audio/wav,broken'><source src='{s}' type='audio/wav'>\"; a.muted=true; var interrupted=''; a.play().catch(function(e){{interrupted=e.name}}); a.pause(); true;", .{h.source});
    defer std.testing.allocator.free(script);
    try h.eval(script);
    try h.deliverLoads();
    try h.tick();
    try h.eval("a.readyState===4 && a.duration===0.01 && a.paused && interrupted==='AbortError' && a.error===null");
    try h.eval("a.removeAttribute('src'); a.innerHTML=''; a.load(); a.preload='none'; true");
    try h.setSource();
    try h.eval("a.readyState===0 && a.networkState===0");
    try h.eval("a.preload='auto'; a.networkState===2");
    try h.deliverLoads();
    try h.eval("a.readyState===4 && a.paused");
    try h.eval("var noSource=new Audio(undefined); noSource.getAttribute('src')===null && noSource.networkState===0");
    try h.eval("a.crossOrigin='anonymous'; a.crossOrigin==='anonymous' && a.error!==null && a.error.code===4 && a.paused");
}
