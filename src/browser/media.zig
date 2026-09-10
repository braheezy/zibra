//! Tab-worker media-element orchestration. Helpers own URLs, cancellation, and
//! PCM; only copied document/element/revision identities cross back to the tab.
const std = @import("std");
const parser = @import("../document/parser.zig");
const bindings = @import("../script/media_bindings.zig");
const audio = @import("../media/audio.zig");
const controls = @import("../media/controls.zig");
const decoding = @import("../media/decode.zig");
const model = @import("../media/element.zig");
const JsRenderContext = @import("js_context.zig").JsRenderContext;
const Tab = @import("tab.zig").Tab;
const Frame = @import("tab.zig").Frame;
const Url = @import("../network/url.zig").Url;
const Loader = @import("resource_loader.zig").Loader;
const Task = @import("../runtime/task.zig").Task;

fn attr(element: *const parser.Element, name: []const u8) ?[]const u8 {
    return if (element.attributes) |attrs| attrs.get(name) else null;
}
fn sourceFingerprint(element: *const parser.Element) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(attr(element, "src") orelse "\x00");
    hash.update("\x00");
    hash.update(attr(element, "crossorigin") orelse "\x00");
    hash.update("\x00");
    for (element.children.items) |*child| if (child.* == .element and std.ascii.eqlIgnoreCase(child.element.tag, "source")) {
        hash.update(attr(&child.element, "src") orelse "\x00");
        hash.update("\x00");
        hash.update(attr(&child.element, "type") orelse "\x00");
    };
    return hash.final();
}

pub fn Integration(comptime Browser: type) type {
    return struct {
        pub fn command(context: ?*anyopaque, handle: u32, op: bindings.Command, value: f64, allocator: std.mem.Allocator, result: *bindings.Result) anyerror!void {
            const ctx: *JsRenderContext = @ptrCast(@alignCast(context orelse return));
            const browser: *Browser = @ptrCast(@alignCast(ctx.browser_ptr orelse return));
            const tab: *Tab = @ptrCast(@alignCast(ctx.tab_ptr orelse return));
            const frame = tab.frameForWindowId(ctx.window_id) orelse return;
            if (frame.document_generation == 0 or !ctx.matchesGeneration(frame.document_generation)) return;
            const js = ctx.js_context orelse return;
            const node = js.resolveMediaNodeFromNativeCallback(ctx.window_id, handle) orelse return;
            const state = try ensure(browser, frame, node, handle, op == .load);
            switch (op) {
                .snapshot, .source, .poll, .load => {},
                .played => {
                    result.ranges = &.{};
                    if (state.voice) |voice| {
                        const ranges = try state.engine.played(voice, allocator);
                        defer allocator.free(ranges);
                        const values = try allocator.alloc(f64, ranges.len * 2);
                        for (ranges, 0..) |range, i| {
                            values[2 * i] = range.start;
                            values[2 * i + 1] = range.end;
                        }
                        result.ranges = values;
                    }
                },
                .play => {
                    if (!frame.media_user_activated and !state.muted and state.volume != 0) {
                        result.failure = "NotAllowedError";
                    } else {
                        if (state.error_code != 0) result.failure = "NotSupportedError" else {
                            state.start() catch {
                                result.failure = "NotSupportedError";
                            };
                            if (state.network == 0) try begin(browser, frame, handle, state);
                        }
                    }
                },
                .pause => state.pause(),
                .seek => try state.seek(value),
                .seek_complete => {
                    if (@as(f64, @floatFromInt(state.seek_revision)) == value) state.seeking = false;
                },
                .volume => {
                    try state.setVolume(value);
                    if (value > 0 and !state.muted and !frame.media_user_activated) state.pause();
                },
                .muted => {
                    const muted = value != 0;
                    state.setMuted(muted);
                    if (!muted and state.volume > 0 and !frame.media_user_activated) state.pause();
                },
            }
            state.update();
            try snapshot(state, op == .poll, op == .source, allocator, result);
            updateControl(browser, frame, node, state);
        }

        fn snapshot(state: *model.State, take_events: bool, include_source: bool, allocator: std.mem.Allocator, result: *bindings.Result) !void {
            result.revision = state.revision;
            result.seeking = state.seeking;
            result.seek_revision = state.seek_revision;
            result.values = .{ state.duration, state.default_position orelse state.position, @floatFromInt(@intFromBool(state.paused)), @floatFromInt(@intFromBool(state.ended)), @floatFromInt(state.network), @floatFromInt(state.ready), @floatFromInt(state.error_code), state.volume, @floatFromInt(@intFromBool(state.muted)), @floatFromInt(@intFromBool(state.loop)) };
            // Data URLs can be large; polling/time getters need only scalars.
            if (include_source) result.source = try allocator.dupe(u8, state.currentSrc());
            if (take_events) {
                var events = std.ArrayList(u8).empty;
                defer events.deinit(allocator);
                for (state.events[0..state.event_count]) |event| {
                    if (events.items.len != 0) try events.append(allocator, ',');
                    try events.appendSlice(allocator, model.eventName(event));
                }
                result.events = try events.toOwnedSlice(allocator);
                state.event_count = 0;
            }
        }

        fn ensure(browser: *Browser, frame: *Frame, node: *parser.Node, handle: u32, force: bool) !*model.State {
            const element = &node.element;
            const state = frame.audio_elements.get(handle) orelse blk: {
                if (frame.audio_elements.count() >= audio.max_voices) return error.AudioLimitExceeded;
                const created = try frame.allocator.create(model.State);
                errdefer frame.allocator.destroy(created);
                created.* = .init(frame.allocator, &browser.session_state.audio);
                try frame.audio_elements.put(handle, created);
                break :blk created;
            };
            state.loop = attr(element, "loop") != null;
            state.autoplay = attr(element, "autoplay") != null;
            if (!state.muted_set) state.muted = attr(element, "muted") != null;
            state.configure();
            const fingerprint = sourceFingerprint(element);
            if (force or state.fingerprint == null or state.fingerprint.? != fingerprint) {
                state.reset();
                state.fingerprint = fingerprint;
                for (state.sources.items) |source| frame.allocator.free(source);
                state.sources.clearRetainingCapacity();
                if (attr(element, "src")) |src| {
                    try addSource(frame, state, src);
                } else {
                    for (element.children.items) |*child| {
                        if (child.* != .element or !std.ascii.eqlIgnoreCase(child.element.tag, "source")) continue;
                        if (attr(&child.element, "type")) |mime| if (mime.len != 0 and decoding.canPlayType(mime).len == 0) continue;
                        if (attr(&child.element, "src")) |src| try addSource(frame, state, src);
                    }
                }
                // CORS credentials modes need a dedicated transport contract.
                // Until then explicit crossorigin requests fail closed.
                if (attr(element, "crossorigin") != null and state.sources.items.len != 0) {
                    state.fail(4);
                }
            }
            const preload = attr(element, "preload") orelse "metadata";
            if (state.network == 0 and (force or !std.ascii.eqlIgnoreCase(preload, "none") or state.autoplay)) {
                if (state.sources.items.len != 0) {
                    try begin(browser, frame, handle, state);
                } else if (attr(element, "src") != null) state.fail(4);
            }
            if (state.autoplay_pending and state.autoplay and state.sources.items.len != 0 and state.paused and state.error_code == 0 and !state.ended and (frame.media_user_activated or state.muted or state.volume == 0)) {
                state.autoplay_pending = false;
                state.start() catch {};
            }
            return state;
        }

        fn addSource(frame: *Frame, state: *model.State, raw: []const u8) !void {
            const text = std.mem.trim(u8, raw, " \r\n\t");
            if (text.len == 0 or state.sources.items.len >= 16) return;
            const base = frame.current_url orelse return;
            const url = base.resolve(frame.allocator, text) catch |err| {
                if (err == error.OutOfMemory) return err;
                return;
            };
            defer url.free(frame.allocator);
            if (!@import("../media/policy.zig").allows(frame.allocator, null, base.*, url)) return;
            if (!frame.allowedRequest(&url, .media)) return;
            // Web pages cannot use media loading as a local-file read primitive.
            if (std.mem.eql(u8, url.scheme, "file") and !std.mem.eql(u8, base.scheme, "file")) return;
            if (!std.mem.eql(u8, url.scheme, "http") and !std.mem.eql(u8, url.scheme, "https") and !std.mem.eql(u8, url.scheme, "data") and !std.mem.eql(u8, url.scheme, "file")) return;
            const serialized = try url.toOwnedString(frame.allocator);
            errdefer frame.allocator.free(serialized);
            try state.sources.append(frame.allocator, serialized);
        }

        fn begin(browser: *Browser, frame: *Frame, handle: u32, state: *model.State) !void {
            errdefer state.fail(2);
            if (state.sources.items.len == 0 or state.source_index >= state.sources.items.len) {
                state.fail(4);
                return;
            }
            const jobs = &browser.session_state.media_jobs;
            if (jobs.fetchAdd(1, .acq_rel) >= audio.max_voices) {
                _ = jobs.fetchSub(1, .acq_rel);
                state.fail(2);
                return error.AudioLimitExceeded;
            }
            errdefer _ = jobs.fetchSub(1, .acq_rel);
            const allocator = state.engine.allocator;
            const job = try allocator.create(Job);
            errdefer allocator.destroy(job);
            const target = try Url.init(allocator, state.sources.items[state.source_index]);
            errdefer target.free(allocator);
            const referrer = if (frame.current_url) |url| try url.clone(allocator) else null;
            errdefer if (referrer) |url| url.free(allocator);
            var content_security_policy = if (frame.content_security_policy) |*policy|
                try @import("content_security_policy.zig").Policy.init(allocator, policy.serialized, &policy.origin)
            else
                null;
            errdefer if (content_security_policy) |*policy| policy.deinit(allocator);
            const token = try allocator.create(model.Cancellation);
            token.* = .{ .allocator = allocator };
            state.cancel();
            state.token = token;
            token.retain();
            job.* = .{ .allocator = allocator, .browser = browser, .tab = frame.tab, .window = frame.window_id, .generation = frame.document_generation, .handle = handle, .revision = state.revision, .token = token, .target = target, .referrer = referrer, .policy = frame.referrer_policy, .content_security_policy = content_security_policy };
            state.network = 2;
            state.queue(.loadstart);
            errdefer token.release();
            const work = try allocator.create(Work);
            errdefer allocator.destroy(work);
            work.* = .{ .allocator = allocator, .job = job, .tab = frame.tab, .jobs = jobs };
            const runner = browser.session_state.media_runner orelse return error.MediaRunnerNotStarted;
            frame.tab.retainAsyncThread();
            runner.schedule(Task.init(.normal, "task:media_decode", work, Work.run, Work.cleanup)) catch |err| {
                frame.tab.releaseAsyncThread();
                state.fail(2);
                return err;
            };
        }

        // This queue envelope retains the Tab independently of result delivery.
        // The result may be consumed before the loader task returns.
        const Work = struct {
            allocator: std.mem.Allocator,
            job: ?*Job,
            tab: *Tab,
            jobs: *std.atomic.Value(usize),
            fn run(raw: *anyopaque) !void {
                const self: *Work = @ptrCast(@alignCast(raw));
                const job = self.job.?;
                job.load() catch |err| {
                    job.failure = if (err == error.AudioFetchFailed) 2 else 3;
                };
                self.job = null;
                self.tab.task_runner.schedule(Task.init(.javascript, "task:media_ready", job, Job.complete, Job.cleanup)) catch job.destroy();
            }
            fn cleanup(raw: *anyopaque) void {
                const self: *Work = @ptrCast(@alignCast(raw));
                if (self.job) |job| job.destroy();
                _ = self.jobs.fetchSub(1, .acq_rel);
                self.tab.releaseAsyncThread();
                self.allocator.destroy(self);
            }
        };

        const Job = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            window: u32,
            generation: u64,
            handle: u32,
            revision: u64,
            token: *model.Cancellation,
            target: Url,
            referrer: ?Url,
            policy: @import("../network/url.zig").ReferrerPolicy,
            content_security_policy: ?@import("content_security_policy.zig").Policy,
            clip: ?audio.Clip = null,
            failure: u8 = 0,

            fn load(self: *Job) !void {
                if (self.token.cancelled.load(.acquire) or self.tab.isShuttingDown()) return error.Cancelled;
                var loader = Loader.init(self.allocator, self.browser.io, self.browser.session_state);
                const response = loader.fetchBodyLimited(self.target, self.referrer, self.policy, .{ .max_body_bytes = decoding.max_encoded_bytes, .context = self, .allows_url = allowsUrl }) catch return error.AudioFetchFailed;
                defer {
                    if (!std.mem.eql(u8, self.target.scheme, "data") and !std.mem.eql(u8, self.target.scheme, "about")) self.allocator.free(response.body);
                    if (response.csp_header) |header| self.allocator.free(header);
                    if (response.access_control_allow_origin) |header| self.allocator.free(header);
                }
                if (response.status) |status| if (@intFromEnum(status) < 200 or @intFromEnum(status) >= 300) return error.AudioFetchFailed;
                self.clip = try decoding.decode(self.allocator, response.body, &self.token.cancelled, &self.browser.session_state.audio.budget);
            }
            fn allowsUrl(raw: ?*anyopaque, href: []const u8) bool {
                const self: *Job = @ptrCast(@alignCast(raw.?));
                if (self.token.cancelled.load(.acquire) or self.tab.isShuttingDown()) return false;
                const target = Url.init(self.allocator, href) catch return false;
                defer target.free(self.allocator);
                if (!@import("../media/policy.zig").allows(self.allocator, null, self.referrer orelse return false, target)) return false;
                const policy = if (self.content_security_policy) |*value| value else return true;
                return policy.allows(&target, .media, !self.target.sameDocument(target));
            }
            fn complete(raw: *anyopaque) !void {
                const self: *Job = @ptrCast(@alignCast(raw));
                if (self.token.cancelled.load(.acquire) or self.tab.isShuttingDown()) return;
                const frame = self.tab.frameForWindowId(self.window) orelse return;
                if (frame.document_generation != self.generation) return;
                const state = frame.audio_elements.get(self.handle) orelse return;
                if (state.revision != self.revision) return;
                if (self.clip) |clip| {
                    state.accept(clip) catch {
                        state.fail(3);
                        return;
                    };
                    self.clip = null;
                } else if (state.source_index + 1 < state.sources.items.len) {
                    state.source_index += 1;
                    try begin(self.browser, frame, self.handle, state);
                } else state.fail(if (self.failure == 0) 3 else self.failure);
                self.tab.needs_paint = true;
                self.browser.setNeedsAnimationFrame(self.tab);
                self.browser.scheduleAnimationFrame();
            }
            fn cleanup(raw: *anyopaque) void {
                const self: *Job = @ptrCast(@alignCast(raw));
                self.destroy();
            }
            fn destroy(self: *Job) void {
                if (self.clip) |*clip| clip.deinit(self.allocator);
                self.target.free(self.allocator);
                if (self.referrer) |url| url.free(self.allocator);
                self.token.release();
                if (self.content_security_policy) |*policy| policy.deinit(self.allocator);
                self.allocator.destroy(self);
            }
        };

        fn updateControl(browser: *Browser, frame: *Frame, node: *parser.Node, state: *model.State) void {
            const copy = controls.State{
                .paused = state.paused,
                .failed = state.error_code != 0,
                .loading = state.network == 2,
                .ready = state.ready != 0,
                .muted = state.muted,
                .volume = state.volume,
                .duration = if (std.math.isFinite(state.duration)) state.duration else 0,
                .position = @floor(state.position * 20) / 20,
            };
            if (!std.meta.eql(node.element.audio_state, copy)) {
                node.element.audio_state = copy;
                if (node.element.isHiddenAudio()) return;
                parser.markPaintForNode(node);
                frame.tab.needs_paint = true;
                browser.setNeedsAnimationFrame(frame.tab);
                browser.scheduleAnimationFrame();
            }
        }

        /// Runs after parser/DOM mutations have settled, never under JsLock.
        pub fn refresh(browser: *Browser, frame: *Frame) !void {
            const js = frame.js_context orelse return;
            const root = if (frame.current_node) |*node| node else return;
            var nodes = std.ArrayList(*parser.Node).empty;
            defer nodes.deinit(frame.allocator);
            try collect(root, frame.allocator, &nodes);
            var watches = std.ArrayList(u32).empty;
            defer watches.deinit(frame.allocator);
            for (nodes.items) |node| {
                const handle = try js.captureNodeHandle(frame.window_id, node);
                const state = ensure(browser, frame, node, handle, false) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    continue;
                };
                state.attached_seen = true;
                state.detached = false;
                state.update();
                updateControl(browser, frame, node, state);
                if (state.event_count != 0 or state.network == 2 or !state.paused) try watches.append(frame.allocator, handle);
            }
            var it = frame.audio_elements.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*.attached_seen and !entry.value_ptr.*.detached and js.resolveAttachedNode(frame.window_id, entry.key_ptr.*) == null) {
                    entry.value_ptr.*.pause();
                    entry.value_ptr.*.detached = true;
                }
            }
            // Handles survive author listeners and DOM relocation; no Node borrow
            // is consulted after entering JavaScript to install event polling.
            for (watches.items) |handle| {
                var buffer: [80]u8 = undefined;
                const script = try std.fmt.bufPrint(&buffer, "__mediaWatch({d});", .{handle});
                _ = js.evaluate(frame.window_id, script) catch {};
            }
        }
        fn collect(node: *parser.Node, allocator: std.mem.Allocator, out: *std.ArrayList(*parser.Node)) !void {
            if (node.* != .element) return;
            if (std.ascii.eqlIgnoreCase(node.element.tag, "audio")) try out.append(allocator, node);
            for (node.element.children.items) |*child| try collect(child, allocator, out);
        }
        /// Native UI actions run on the Tab worker, consume no author click
        /// event, and use the same media state transitions as the DOM API.
        pub fn control(browser: *Browser, frame: *Frame, node: *parser.Node, part: controls.Part, value: ?f64) !void {
            if (node.* != .element or !std.ascii.eqlIgnoreCase(node.element.tag, "audio") or node.element.isHiddenAudio()) return;
            const js = frame.js_context orelse return;
            const handle = try js.captureNodeHandle(frame.window_id, node);
            const state = try ensure(browser, frame, node, handle, false);
            frame.media_user_activated = true;
            state.update();
            switch (part) {
                .play => if (state.paused) {
                    if (state.error_code == 0) {
                        try state.start();
                        if (state.network == 0) try begin(browser, frame, handle, state);
                    }
                } else state.pause(),
                .seek => if (state.ready != 0 and value != null) try state.seek(std.math.clamp(value.?, 0, 1) * state.duration),
                .mute => state.setMuted(!state.muted),
                .volume => if (value) |volume| try state.setVolume(std.math.clamp(volume, 0, 1)),
            }
            updateControl(browser, frame, node, state);
            // No Node or state borrow is consulted after entering JavaScript.
            var buffer: [80]u8 = undefined;
            _ = try js.evaluate(frame.window_id, try std.fmt.bufPrint(&buffer, "__mediaWatch({d});", .{handle}));
        }

        /// Consumes native media keys on the Tab worker. Relative adjustments
        /// read the current voice position, independent of painted progress.
        pub fn key(browser: *Browser, tab: *Tab, keycode: controls.Key) !bool {
            const frame = tab.focused_frame orelse tab.root_frame orelse return false;
            const node = frame.focus orelse return false;
            if (node.* != .element or !std.ascii.eqlIgnoreCase(node.element.tag, "audio") or node.element.isHiddenAudio()) return false;
            tab.noteKeyboardInteraction();
            const part = node.element.audio_part;
            const js = frame.js_context orelse return false;
            const state = try ensure(browser, frame, node, try js.captureNodeHandle(frame.window_id, node), false);
            state.update();
            switch (keycode) {
                .activate => if (part == .play or part == .mute) try control(browser, frame, node, part, null),
                .mute => try control(browser, frame, node, .mute, null),
                .left, .right, .up, .down, .home, .end => {
                    const volume = part == .volume or keycode == .up or keycode == .down;
                    const old = if (volume) state.volume else if (state.duration > 0) state.position / state.duration else 0;
                    const step = if (volume) @as(f64, 0.05) else if (state.duration > 0) 5 / state.duration else 0;
                    const value = switch (keycode) {
                        .home => @as(f64, 0),
                        .end => @as(f64, 1),
                        .left, .down => old - step,
                        else => old + step,
                    };
                    try control(browser, frame, node, if (volume) .volume else .seek, value);
                },
            }
            return true;
        }

        /// Re-resolve capture identity on each motion; detached/replaced media
        /// and zoom changes cancel capture without touching an old Node.
        pub fn pointer(browser: *Browser, tab: *Tab, pointer_x: ?i32, release: bool) !bool {
            const drag = tab.audio_drag orelse return false;
            if (release or pointer_x == null) tab.audio_drag = null;
            const x = pointer_x orelse return false;
            const frame = tab.frameForWindowId(drag.window) orelse {
                tab.audio_drag = null;
                return false;
            };
            if (frame.document_generation != drag.generation or tab.accessibility.zoom != drag.zoom) {
                tab.audio_drag = null;
                return false;
            }
            const js = frame.js_context orelse {
                tab.audio_drag = null;
                return false;
            };
            const node = js.resolveAttachedNode(drag.window, drag.handle) orelse {
                tab.audio_drag = null;
                return false;
            };
            const state = frame.audio_elements.get(drag.handle) orelse {
                tab.audio_drag = null;
                return false;
            };
            // DOM source mutation can precede reconciliation of its revision.
            if (state.revision != drag.revision or node.* != .element or node.element.isHiddenAudio() or state.fingerprint != sourceFingerprint(&node.element)) {
                tab.audio_drag = null;
                return false;
            }
            const value = drag.value + @as(f64, @floatFromInt(@as(i64, x) - drag.pointer_x)) / @as(f64, @floatFromInt(@max(1, drag.width)));
            try control(browser, frame, node, drag.part, value);
            return true;
        }
    };
}
