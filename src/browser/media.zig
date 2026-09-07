//! Tab-worker media-element orchestration. Helpers own URLs, cancellation, and
//! PCM; only copied document/element/revision identities cross back to the tab.
const std = @import("std");
const parser = @import("../document/parser.zig");
const bindings = @import("../script/media_bindings.zig");
const audio = @import("../media/audio.zig");
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
                .volume => {
                    if (!std.math.isFinite(value) or value < 0 or value > 1) return error.IndexSizeError;
                    if (state.volume != value) {
                        state.volume = value;
                        state.queue(.volumechange);
                    }
                    state.configure();
                    if (value > 0 and !state.muted and !frame.media_user_activated) state.pause();
                },
                .muted => {
                    const muted = value != 0;
                    state.muted_set = true;
                    if (state.muted != muted) {
                        state.muted = muted;
                        state.queue(.volumechange);
                    }
                    state.configure();
                    if (!muted and state.volume > 0 and !frame.media_user_activated) state.pause();
                },
            }
            state.update();
            try snapshot(state, op == .poll, op == .source, allocator, result);
            updateControl(browser, frame, node, state);
        }

        fn snapshot(state: *model.State, take_events: bool, include_source: bool, allocator: std.mem.Allocator, result: *bindings.Result) !void {
            result.revision = state.revision;
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
            if (!@import("../media/policy.zig").allows(frame.allocator, frame.media_source_list, base.*, url)) return;
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
            const source_list = if (frame.media_source_list) |list| try allocator.dupe(u8, list) else null;
            errdefer if (source_list) |list| allocator.free(list);
            const token = try allocator.create(model.Cancellation);
            token.* = .{ .allocator = allocator };
            state.cancel();
            state.token = token;
            token.retain();
            job.* = .{ .allocator = allocator, .browser = browser, .tab = frame.tab, .window = frame.window_id, .generation = frame.document_generation, .handle = handle, .revision = state.revision, .token = token, .target = target, .referrer = referrer, .policy = frame.referrer_policy, .source_list = source_list };
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
            source_list: ?[]u8,
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
                return @import("../media/policy.zig").allows(self.allocator, self.source_list, self.referrer orelse return false, target);
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
                if (self.source_list) |list| self.allocator.free(list);
                self.allocator.destroy(self);
            }
        };

        fn updateControl(browser: *Browser, frame: *Frame, node: *parser.Node, state: *model.State) void {
            if (node.element.audio_paused != state.paused or node.element.audio_error != (state.error_code != 0)) {
                node.element.audio_paused = state.paused;
                node.element.audio_error = state.error_code != 0;
                parser.markLayoutForNode(node);
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
        pub fn toggle(browser: *Browser, frame: *Frame, node: *parser.Node) !void {
            const js = frame.js_context orelse return;
            const handle = try js.captureNodeHandle(frame.window_id, node);
            const state = try ensure(browser, frame, node, handle, false);
            frame.media_user_activated = true;
            if (state.paused) {
                try state.start();
                if (state.network == 0) try begin(browser, frame, handle, state);
            } else state.pause();
            updateControl(browser, frame, node, state);
        }
    };
}
