//! Timer, animation, XHR, cookie, and postMessage task adapters.
//!
//! Browser is supplied at comptime to keep this module from importing root.zig.

const std = @import("std");
const parser = @import("../document/parser.zig");
const js_module = @import("../script/js.zig");
const url_module = @import("../network/url.zig");
const task_module = @import("../runtime/task.zig");
const Tab = @import("tab.zig").Tab;
const JsRenderContext = @import("js_context.zig").JsRenderContext;

const Url = url_module.Url;
const Task = task_module.Task;

pub fn Contexts(comptime Browser: type, comptime DocumentHandle: type) type {
    return struct {
        pub const SetTimeoutThreadContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            document: DocumentHandle,
            handle: u32,
            delay_ms: u32,
            is_interval: bool,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                document: DocumentHandle,
                handle: u32,
                delay_ms: u32,
                is_interval: bool,
            ) !*SetTimeoutThreadContext {
                const ctx = try allocator.create(SetTimeoutThreadContext);
                ctx.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .document = document,
                    .handle = handle,
                    .delay_ms = delay_ms,
                    .is_interval = is_interval,
                };
                return ctx;
            }

            pub fn destroy(self: *SetTimeoutThreadContext) void {
                self.allocator.destroy(self);
            }
        };

        pub fn runSetTimeoutThread(ctx: *SetTimeoutThreadContext) void {
            const tab = ctx.tab;
            defer {
                ctx.destroy();
                tab.releaseAsyncThread();
            }

            _ = ctx.browser.measure.registerThread("SetTimeout thread") catch |err| {
                std.log.warn("Failed to register setTimeout thread: {}", .{err});
            };

            var remaining_ns = @as(u64, ctx.delay_ms) * std.time.ns_per_ms;
            while (remaining_ns > 0) {
                if (tab.isShuttingDown()) return;
                if (ctx.is_interval and !tab.intervalIsActive(
                    ctx.document.window_id,
                    ctx.document.generation,
                    ctx.handle,
                )) return;
                const sleep_ns = @min(remaining_ns, 10 * std.time.ns_per_ms);
                ctx.browser.io.sleep(.fromNanoseconds(@intCast(sleep_ns)), .awake) catch {
                    if (ctx.is_interval) tab.clearInterval(
                        ctx.document.window_id,
                        ctx.document.generation,
                        ctx.handle,
                    );
                    return;
                };
                remaining_ns -= sleep_ns;
            }
            if (tab.isShuttingDown()) return;
            if (ctx.is_interval and !tab.intervalIsActive(
                ctx.document.window_id,
                ctx.document.generation,
                ctx.handle,
            )) return;

            const task_ctx = SetTimeoutTaskContext.create(
                ctx.browser.allocator,
                ctx.browser,
                tab,
                ctx.document,
                ctx.handle,
                ctx.is_interval,
            ) catch |err| {
                std.log.warn("Failed to allocate setTimeout task: {}", .{err});
                if (ctx.is_interval) tab.clearInterval(
                    ctx.document.window_id,
                    ctx.document.generation,
                    ctx.handle,
                );
                return;
            };
            errdefer task_ctx.destroy();

            const task = Task.init(
                .javascript,
                if (ctx.is_interval) "task:interval" else "task:timeout",
                task_ctx.toOpaque(),
                SetTimeoutTaskContext.runOpaque,
                SetTimeoutTaskContext.cleanupOpaque,
            );

            tab.task_runner.schedule(task) catch |err| {
                std.log.warn("Failed to enqueue setTimeout task: {}", .{err});
                task_ctx.destroy();
                if (ctx.is_interval) tab.clearInterval(
                    ctx.document.window_id,
                    ctx.document.generation,
                    ctx.handle,
                );
            };
        }

        pub const SetTimeoutTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            document: DocumentHandle,
            handle: u32,
            is_interval: bool,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                document: DocumentHandle,
                handle: u32,
                is_interval: bool,
            ) !*SetTimeoutTaskContext {
                const ctx = try allocator.create(SetTimeoutTaskContext);
                ctx.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .document = document,
                    .handle = handle,
                    .is_interval = is_interval,
                };
                return ctx;
            }

            pub fn destroy(self: *SetTimeoutTaskContext) void {
                self.allocator.destroy(self);
            }

            pub fn toOpaque(self: *SetTimeoutTaskContext) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(context: *anyopaque) *SetTimeoutTaskContext {
                const raw: *align(1) SetTimeoutTaskContext = @ptrCast(context);
                return @alignCast(raw);
            }

            pub fn runOpaque(context: *anyopaque) anyerror!void {
                try SetTimeoutTaskContext.fromOpaque(context).run();
            }

            pub fn cleanupOpaque(context: *anyopaque) void {
                SetTimeoutTaskContext.fromOpaque(context).destroy();
            }

            fn run(self: *SetTimeoutTaskContext) !void {
                const frame = self.document.resolve(self.tab) orelse {
                    if (self.is_interval) self.tab.clearInterval(
                        self.document.window_id,
                        self.document.generation,
                        self.handle,
                    );
                    return;
                };
                const trace_eval = self.browser.measure.begin("evaljs");
                defer if (trace_eval) self.browser.measure.end("evaljs");
                const js_context = frame.js_context orelse {
                    if (self.is_interval) self.tab.clearInterval(
                        self.document.window_id,
                        self.document.generation,
                        self.handle,
                    );
                    return;
                };
                js_context.runTimeoutCallback(self.document.window_id, self.handle) catch |err| {
                    std.log.warn("setTimeout callback failed: {}", .{err});
                    if (self.is_interval and !self.tab.intervalIsActive(
                        self.document.window_id,
                        self.document.generation,
                        self.handle,
                    )) return;
                };
            }
        };

        pub const AnimationTimerContext = struct {
            browser: *Browser,
            tab: *Tab,
            generation: u64,
            deadline_ns: i96,

            pub fn create(
                browser: *Browser,
                tab: *Tab,
                generation: u64,
                deadline_ns: i96,
            ) !*AnimationTimerContext {
                const ctx = try browser.allocator.create(AnimationTimerContext);
                ctx.* = .{
                    .browser = browser,
                    .tab = tab,
                    .generation = generation,
                    .deadline_ns = deadline_ns,
                };
                return ctx;
            }

            pub fn destroy(self: *AnimationTimerContext) void {
                self.browser.allocator.destroy(self);
            }
        };

        pub fn runAnimationTimerThread(ctx: *AnimationTimerContext) void {
            const browser = ctx.browser;
            const tab = ctx.tab;
            defer {
                ctx.destroy();
                tab.releaseAsyncThread();
            }

            _ = browser.measure.registerThread("Animation timer thread") catch |err| {
                std.log.warn("Failed to register animation timer thread: {}", .{err});
            };

            const deadline = std.Io.Timestamp{ .nanoseconds = ctx.deadline_ns };
            deadline.withClock(.awake).wait(browser.io) catch {
                browser.recoverAnimationFrameFailure(tab, ctx.generation);
                return;
            };

            browser.lock.lock();
            // A tab switch or forced reset can supersede this detached helper without
            // joining it. Only the captured generation may publish a render task.
            if (!browser.animationTimerMatchesLocked(tab, ctx.generation) or
                browser.shutting_down or tab.isShuttingDown())
            {
                browser.lock.unlock();
                return;
            }
            const scroll = browser.active_tab_scroll;
            browser.lock.unlock();

            const render_ctx = AnimationRenderTaskContext.create(
                browser.allocator,
                browser,
                tab,
                scroll,
                ctx.generation,
            ) catch |err| {
                std.log.warn("Failed to allocate animation task: {}", .{err});
                browser.recoverAnimationFrameFailure(tab, ctx.generation);
                return;
            };

            const task = Task.init(
                .rendering,
                "task:animation_frame",
                render_ctx.toOpaque(),
                AnimationRenderTaskContext.runOpaque,
                AnimationRenderTaskContext.cleanupOpaque,
            );

            tab.task_runner.schedule(task) catch |err| {
                std.log.warn("Failed to schedule animation frame: {}", .{err});
                render_ctx.destroy();
                browser.recoverAnimationFrameFailure(tab, ctx.generation);
                return;
            };
        }

        pub const AnimationRenderTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            scroll: i32,
            generation: u64,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                scroll: i32,
                generation: u64,
            ) !*AnimationRenderTaskContext {
                const ctx = try allocator.create(AnimationRenderTaskContext);
                ctx.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .scroll = scroll,
                    .generation = generation,
                };
                return ctx;
            }

            pub fn destroy(self: *AnimationRenderTaskContext) void {
                self.allocator.destroy(self);
            }

            pub fn toOpaque(self: *AnimationRenderTaskContext) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(context: *anyopaque) *AnimationRenderTaskContext {
                const raw: *align(1) AnimationRenderTaskContext = @ptrCast(context);
                return @alignCast(raw);
            }

            pub fn runOpaque(context: *anyopaque) anyerror!void {
                try AnimationRenderTaskContext.fromOpaque(context).run();
            }

            pub fn cleanupOpaque(context: *anyopaque) void {
                AnimationRenderTaskContext.fromOpaque(context).destroy();
            }

            fn run(self: *AnimationRenderTaskContext) !void {
                self.browser.lock.lock();
                const is_current = !self.browser.shutting_down and
                    !self.tab.isShuttingDown() and
                    self.browser.animationTimerMatchesLocked(self.tab, self.generation);
                self.browser.lock.unlock();

                if (!is_current) return;
                const started_ns = std.Io.Clock.awake.now(self.browser.io).nanoseconds;
                self.tab.runAnimationFrameForGeneration(self.scroll, self.generation);
                const duration_ns = std.Io.Clock.awake.now(self.browser.io).nanoseconds - started_ns;
                self.browser.observeAnimationFrameTabWork(
                    self.tab,
                    self.generation,
                    duration_ns,
                );

                // A commit normally consumes this generation. Frames with no visual
                // commit still have to release it and possibly chain the next request.
                if (self.browser.finishAnimationFrame(self.tab, self.generation)) {
                    self.browser.scheduleAnimationFrame();
                }
            }
        };

        pub const XhrThreadContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            document: DocumentHandle,
            resolved_url: Url,
            referrer: ?Url,
            referrer_policy: url_module.ReferrerPolicy,
            payload: ?[]const u8,
            handle: u32,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                document: DocumentHandle,
                resolved_url: Url,
                referrer: ?Url,
                referrer_policy: url_module.ReferrerPolicy,
                payload: ?[]const u8,
                handle: u32,
            ) !*XhrThreadContext {
                const ctx = try allocator.create(XhrThreadContext);
                errdefer allocator.destroy(ctx);

                const payload_copy = if (payload) |body| blk: {
                    const copy = try allocator.alloc(u8, body.len);
                    @memcpy(copy, body);
                    break :blk copy;
                } else null;
                ctx.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .document = document,
                    .resolved_url = resolved_url,
                    .referrer = referrer,
                    .referrer_policy = referrer_policy,
                    .payload = payload_copy,
                    .handle = handle,
                };

                return ctx;
            }

            pub fn destroy(self: *XhrThreadContext) void {
                if (self.payload) |body| {
                    self.allocator.free(body);
                }
                self.resolved_url.free(self.allocator);
                if (self.referrer) |referrer| referrer.free(self.allocator);
                self.allocator.destroy(self);
            }
        };

        pub fn ownedXhrRequestOrigin(
            allocator: std.mem.Allocator,
            resolved_url: Url,
            referrer: ?Url,
        ) !?[]u8 {
            const source = referrer orelse return null;
            if (source.sameOrigin(resolved_url)) return null;
            return try source.toOwnedOrigin(allocator);
        }

        pub fn freeRawXhrBody(allocator: std.mem.Allocator, url: Url, body: []const u8) void {
            if (!std.mem.eql(u8, url.scheme, "about") and
                !std.mem.eql(u8, url.scheme, "data"))
            {
                allocator.free(body);
            }
        }

        pub fn runXhrThread(ctx: *XhrThreadContext) void {
            const tab = ctx.tab;
            defer {
                ctx.destroy();
                tab.releaseAsyncThread();
            }

            _ = ctx.browser.measure.registerThread("XHR thread") catch |err| {
                std.log.warn("Failed to register XHR thread: {}", .{err});
            };

            const request_origin = ownedXhrRequestOrigin(
                ctx.allocator,
                ctx.resolved_url,
                ctx.referrer,
            ) catch |err| {
                std.log.warn("Failed to serialize async XHR origin: {}", .{err});
                return;
            };
            defer if (request_origin) |origin| ctx.allocator.free(origin);

            const response_result = ctx.browser.fetchBodyForXhr(
                ctx.resolved_url,
                ctx.referrer,
                ctx.payload,
                request_origin,
                ctx.referrer_policy,
            ) catch |err| {
                std.log.warn("Async XHR failed: {}", .{err});
                return;
            };
            defer if (response_result.csp_header) |hdr| ctx.allocator.free(hdr);
            defer if (response_result.access_control_allow_origin) |hdr| ctx.allocator.free(hdr);

            if (!url_module.corsAllowsResponse(
                request_origin,
                response_result.access_control_allow_origin,
            )) {
                freeRawXhrBody(ctx.allocator, ctx.resolved_url, response_result.body);
                std.log.warn("Discarded cross-origin XHR response without matching Access-Control-Allow-Origin", .{});
                return;
            }

            var response_body = response_result.body;
            var should_free_response = true;
            var response_allocator: ?std.mem.Allocator = ctx.allocator;

            if (std.mem.eql(u8, ctx.resolved_url.scheme, "about")) {
                should_free_response = false;
                response_allocator = null;
            } else if (std.mem.eql(u8, ctx.resolved_url.scheme, "data")) {
                const copy = ctx.allocator.alloc(u8, response_body.len) catch {
                    std.log.warn("Failed to copy async XHR data body", .{});
                    return;
                };
                @memcpy(copy, response_body);
                response_body = copy;
                response_allocator = ctx.allocator;
            }

            const decoded_body = url_module.decodeUtf8Replace(ctx.allocator, response_body) catch |err| {
                std.log.warn("Failed to decode XHR body: {}", .{err});
                if (should_free_response) {
                    if (response_allocator) |alloc| {
                        alloc.free(response_body);
                    } else {
                        ctx.allocator.free(response_body);
                    }
                }
                return;
            };

            if (should_free_response) {
                if (response_allocator) |alloc| {
                    alloc.free(response_body);
                } else {
                    ctx.allocator.free(response_body);
                }
            }

            const task_ctx = XhrOnloadTaskContext.create(
                ctx.allocator,
                ctx.browser,
                tab,
                ctx.document,
                ctx.handle,
                decoded_body,
                ctx.allocator,
                true,
            ) catch |err| {
                std.log.warn("Failed to enqueue XHR onload task: {}", .{err});
                ctx.allocator.free(decoded_body);
                return;
            };

            const task = Task.init(
                .javascript,
                "task:xhr_onload",
                task_ctx.toOpaque(),
                XhrOnloadTaskContext.runOpaque,
                XhrOnloadTaskContext.cleanupOpaque,
            );

            tab.task_runner.schedule(task) catch |err| {
                std.log.warn("Failed to schedule XHR onload task: {}", .{err});
                task_ctx.destroy();
            };
        }

        pub const XhrOnloadTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            document: DocumentHandle,
            handle: u32,
            body: []const u8,
            body_allocator: ?std.mem.Allocator,
            should_free_body: bool,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                document: DocumentHandle,
                handle: u32,
                body: []const u8,
                body_allocator: ?std.mem.Allocator,
                should_free_body: bool,
            ) !*XhrOnloadTaskContext {
                const ctx = try allocator.create(XhrOnloadTaskContext);
                ctx.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .document = document,
                    .handle = handle,
                    .body = body,
                    .body_allocator = body_allocator,
                    .should_free_body = should_free_body,
                };
                return ctx;
            }

            pub fn destroy(self: *XhrOnloadTaskContext) void {
                if (self.should_free_body) {
                    if (self.body_allocator) |alloc| {
                        alloc.free(self.body);
                    } else {
                        self.allocator.free(self.body);
                    }
                }
                self.allocator.destroy(self);
            }

            pub fn toOpaque(self: *XhrOnloadTaskContext) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(context: *anyopaque) *XhrOnloadTaskContext {
                const raw: *align(1) XhrOnloadTaskContext = @ptrCast(context);
                return @alignCast(raw);
            }

            pub fn runOpaque(context: *anyopaque) anyerror!void {
                try XhrOnloadTaskContext.fromOpaque(context).run();
            }

            pub fn cleanupOpaque(context: *anyopaque) void {
                XhrOnloadTaskContext.fromOpaque(context).destroy();
            }

            fn run(self: *XhrOnloadTaskContext) !void {
                const frame = self.document.resolve(self.tab) orelse return;
                const js_context = frame.js_context orelse return;
                js_context.runXhrOnload(self.document.window_id, self.handle, self.body) catch |err| {
                    std.log.warn("XHR onload callback failed: {}", .{err});
                };
            }
        };

        pub fn jsRenderCallback(context: ?*anyopaque) anyerror!void {
            const ctx_ptr = context orelse return;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);

            const browser_ptr = ctx.browser_ptr orelse return;
            const tab_ptr = ctx.tab_ptr orelse return;

            const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
            const browser: *Browser = @alignCast(raw_browser);

            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);

            // Mark render work; let the main loop drive rendering to avoid re-entrancy.
            _ = browser;
            tab.setNeedsRender();
        }

        pub fn jsFocusCallback(context: ?*anyopaque, handle: u32) anyerror!void {
            const ctx_ptr = context orelse return;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);

            const browser_ptr = ctx.browser_ptr orelse return;
            const tab_ptr = ctx.tab_ptr orelse return;
            const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
            const browser: *Browser = @alignCast(raw_browser);
            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);

            const frame = tab.frameForWindowId(ctx.window_id) orelse return;
            const generation = frame.document_generation;
            if (generation == 0 or !ctx.matchesGeneration(generation)) return;
            _ = try tab.focusElementFromScript(
                browser,
                ctx.window_id,
                generation,
                handle,
            );
        }

        pub fn jsDomMutationCallback(context: ?*anyopaque, mutation_root: *parser.Node) void {
            const ctx_ptr = context orelse return;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);

            const browser_ptr = ctx.browser_ptr orelse return;
            const tab_ptr = ctx.tab_ptr orelse return;
            const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
            const browser: *Browser = @alignCast(raw_browser);
            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);

            const frame = tab.frameForWindowId(ctx.window_id) orelse return;
            if (frame.document_generation == 0 or
                !ctx.matchesGeneration(frame.document_generation)) return;

            tab.prepareForDomMutation(browser, frame, mutation_root);
        }

        pub fn jsCookieGetCallback(context: ?*anyopaque) anyerror!js_module.CookieResult {
            const ctx_ptr = context orelse return error.MissingJsContext;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);
            const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
            const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;
            const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
            const browser: *Browser = @alignCast(raw_browser);
            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);
            const frame = tab.frameForWindowId(ctx.window_id) orelse return error.MissingJsContext;
            if (frame.document_generation == 0 or
                !ctx.matchesGeneration(frame.document_generation)) return error.StaleDocument;
            const current_url = frame.current_url orelse return .{ .data = "" };
            const host = current_url.host orelse return .{ .data = "" };

            const data = try browser.session_state.readCookieForScript(browser.allocator, host);
            return .{
                .data = data,
                .allocator = browser.allocator,
                .should_free = true,
            };
        }

        pub fn jsCookieSetCallback(context: ?*anyopaque, value: []const u8) anyerror!void {
            const ctx_ptr = context orelse return error.MissingJsContext;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);
            const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
            const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;
            const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
            const browser: *Browser = @alignCast(raw_browser);
            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);
            const frame = tab.frameForWindowId(ctx.window_id) orelse return error.MissingJsContext;
            if (frame.document_generation == 0 or
                !ctx.matchesGeneration(frame.document_generation)) return error.StaleDocument;
            const current_url = frame.current_url orelse return;
            const host = current_url.host orelse return;
            _ = try browser.session_state.writeCookieFromScript(host, value);
        }

        pub fn jsXhrCallback(
            context: ?*anyopaque,
            _: []const u8,
            url_str: []const u8,
            body: ?[]const u8,
            is_async: bool,
            handle: u32,
        ) anyerror!js_module.XhrResult {
            const ctx_ptr = context orelse return error.MissingJsContext;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);

            const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
            const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

            const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
            const browser: *Browser = @alignCast(raw_browser);

            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);
            const frame = tab.frameForWindowId(ctx.window_id) orelse return error.MissingJsContext;

            const allocator = browser.allocator;
            var resolved_url: Url = undefined;
            if (frame.current_url) |current_ptr| {
                resolved_url = current_ptr.*.resolve(allocator, url_str) catch |err| blk: {
                    std.log.warn("Failed to resolve XHR URL {s} relative to page: {}", .{ url_str, err });
                    break :blk try Url.init(allocator, url_str);
                };
            } else {
                resolved_url = try Url.init(allocator, url_str);
            }

            defer resolved_url.free(allocator);

            if (!frame.allowedRequest(resolved_url, frame.current_url)) {
                const target_host = resolved_url.host orelse "";
                std.log.warn(
                    "Blocked XHR to {s}://{s}:{d} due to CSP",
                    .{ resolved_url.scheme, target_host, resolved_url.port },
                );
                return error.CspViolation;
            }

            var current_url_value: ?Url = null;
            if (frame.current_url) |cur_ptr| {
                current_url_value = cur_ptr.*;
            }

            if (is_async) {
                try browser.scheduleAsyncXhr(
                    tab,
                    ctx,
                    resolved_url,
                    current_url_value,
                    frame.referrer_policy,
                    body,
                    handle,
                );
                return .{ .data = "", .allocator = null, .should_free = false };
            }

            const request_origin = try ownedXhrRequestOrigin(allocator, resolved_url, current_url_value);
            defer if (request_origin) |origin| allocator.free(origin);

            const response = try browser.fetchBodyForXhr(
                resolved_url,
                current_url_value,
                body,
                request_origin,
                frame.referrer_policy,
            );
            defer if (response.csp_header) |hdr| allocator.free(hdr);
            defer if (response.access_control_allow_origin) |hdr| allocator.free(hdr);

            if (!url_module.corsAllowsResponse(request_origin, response.access_control_allow_origin)) {
                freeRawXhrBody(allocator, resolved_url, response.body);
                return error.CrossOriginBlocked;
            }

            var response_body = response.body;

            var should_free_response = true;
            var response_allocator: ?std.mem.Allocator = allocator;

            if (std.mem.eql(u8, resolved_url.scheme, "data")) {
                const copy = try allocator.alloc(u8, response_body.len);
                @memcpy(copy, response_body);
                response_body = copy;
            } else if (std.mem.eql(u8, resolved_url.scheme, "about")) {
                should_free_response = false;
                response_allocator = null;
            }

            const decoded_body = url_module.decodeUtf8Replace(allocator, response_body) catch |err| {
                if (should_free_response) {
                    if (response_allocator) |alloc| {
                        alloc.free(response_body);
                    } else {
                        allocator.free(response_body);
                    }
                }
                return err;
            };

            if (should_free_response) {
                if (response_allocator) |alloc| {
                    alloc.free(response_body);
                } else {
                    allocator.free(response_body);
                }
            }

            return .{
                .data = decoded_body,
                .allocator = allocator,
                .should_free = true,
            };
        }

        pub fn jsSetTimeoutCallback(
            context: ?*anyopaque,
            handle: u32,
            delay_ms: u32,
            is_interval: bool,
        ) anyerror!void {
            const ctx_ptr = context orelse return error.MissingJsContext;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);

            const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
            const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

            const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
            const browser: *Browser = @alignCast(raw_browser);

            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);

            try browser.scheduleSetTimeoutTask(tab, ctx, handle, delay_ms, is_interval);
        }

        pub fn jsClearIntervalCallback(
            context: ?*anyopaque,
            handle: u32,
        ) void {
            const ctx_ptr = context orelse return;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);

            const tab_ptr = ctx.tab_ptr orelse return;
            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);

            tab.clearInterval(ctx.window_id, ctx.currentGeneration(), handle);
        }

        pub fn jsRequestAnimationFrameCallback(
            context: ?*anyopaque,
        ) anyerror!void {
            const ctx_ptr = context orelse return error.MissingJsContext;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);

            const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);

            tab.setNeedsRender();
        }

        pub fn originStringForUrl(allocator: std.mem.Allocator, url: Url) ![]u8 {
            if (std.mem.eql(u8, url.scheme, "file")) {
                return allocator.dupe(u8, "file://");
            }
            if (std.mem.eql(u8, url.scheme, "about") or std.mem.eql(u8, url.scheme, "data")) {
                return std.fmt.allocPrint(allocator, "{s}:", .{url.scheme});
            }
            const host = url.host orelse "";
            return std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ url.scheme, host, url.port });
        }

        pub fn normalizeOrigin(allocator: std.mem.Allocator, origin: []const u8) ![]const u8 {
            const trimmed = std.mem.trim(u8, origin, " \t\r\n");
            const lower = try allocator.alloc(u8, trimmed.len);
            for (trimmed, 0..) |ch, idx| {
                lower[idx] = std.ascii.toLower(ch);
            }
            return lower;
        }

        pub fn jsPostMessageCallback(
            context: ?*anyopaque,
            source_window_id: u32,
            target_window_id: u32,
            target_origin: []const u8,
            message: []const u8,
        ) anyerror!void {
            const ctx_ptr = context orelse return error.MissingJsContext;
            const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
            const ctx: *JsRenderContext = @alignCast(raw_ctx);

            const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
            const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

            const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
            const browser: *Browser = @alignCast(raw_browser);

            const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
            const tab: *Tab = @alignCast(raw_tab);

            const source_frame = tab.frameForWindowId(source_window_id) orelse return;
            const target_frame = tab.frameForWindowId(target_window_id) orelse return;

            const allocator = browser.allocator;

            var source_origin = try allocator.dupe(u8, "null");
            defer allocator.free(source_origin);
            if (source_frame.current_url) |url_ptr| {
                allocator.free(source_origin);
                source_origin = try originStringForUrl(allocator, url_ptr.*);
            }

            if (!std.mem.eql(u8, target_origin, "*")) {
                var target_origin_actual = try allocator.dupe(u8, "null");
                defer allocator.free(target_origin_actual);
                if (target_frame.current_url) |url_ptr| {
                    allocator.free(target_origin_actual);
                    target_origin_actual = try originStringForUrl(allocator, url_ptr.*);
                }

                const target_origin_norm = try normalizeOrigin(allocator, target_origin);
                defer allocator.free(target_origin_norm);
                const actual_origin_norm = try normalizeOrigin(allocator, target_origin_actual);
                defer allocator.free(actual_origin_norm);

                if (!std.mem.eql(u8, target_origin_norm, actual_origin_norm)) {
                    std.log.warn("Blocked postMessage due to target origin mismatch", .{});
                    return;
                }
            }

            const task_ctx = try PostMessageTaskContext.create(
                allocator,
                browser,
                tab,
                DocumentHandle.fromFrame(target_frame),
                source_window_id,
                message,
                source_origin,
            );
            const task = Task.init(
                .javascript,
                "task:post_message",
                task_ctx.toOpaque(),
                PostMessageTaskContext.runOpaque,
                PostMessageTaskContext.cleanupOpaque,
            );
            tab.task_runner.schedule(task) catch |err| {
                std.log.warn("Failed to schedule postMessage task: {}", .{err});
                task_ctx.destroy();
            };
        }

        pub const PostMessageTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            target_document: DocumentHandle,
            source_window_id: u32,
            message: []const u8,
            origin: []const u8,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                target_document: DocumentHandle,
                source_window_id: u32,
                message: []const u8,
                origin: []const u8,
            ) !*PostMessageTaskContext {
                const ctx = try allocator.create(PostMessageTaskContext);
                const message_copy = try allocator.dupe(u8, message);
                errdefer allocator.free(message_copy);
                const origin_copy = try allocator.dupe(u8, origin);
                errdefer allocator.free(origin_copy);
                ctx.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .target_document = target_document,
                    .source_window_id = source_window_id,
                    .message = message_copy,
                    .origin = origin_copy,
                };
                return ctx;
            }

            pub fn destroy(self: *PostMessageTaskContext) void {
                self.allocator.free(self.message);
                self.allocator.free(self.origin);
                self.allocator.destroy(self);
            }

            pub fn toOpaque(self: *PostMessageTaskContext) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(context: *anyopaque) *PostMessageTaskContext {
                const raw: *align(1) PostMessageTaskContext = @ptrCast(context);
                return @alignCast(raw);
            }

            pub fn runOpaque(context: *anyopaque) anyerror!void {
                try PostMessageTaskContext.fromOpaque(context).run();
            }

            pub fn cleanupOpaque(context: *anyopaque) void {
                PostMessageTaskContext.fromOpaque(context).destroy();
            }

            fn run(self: *PostMessageTaskContext) !void {
                const target_frame = self.target_document.resolve(self.tab) orelse return;
                const target_context = target_frame.js_context orelse return;
                target_context.dispatchPostMessage(
                    self.target_document.window_id,
                    self.message,
                    self.origin,
                    self.source_window_id,
                ) catch |err| {
                    std.log.warn("Failed to dispatch postMessage: {}", .{err});
                    return;
                };
                // Ensure postMessage-driven DOM updates paint without waiting for input.
                self.tab.setNeedsRender();
                const scroll = if (self.tab.root_frame) |root| root.scroll else 0;
                self.tab.runAnimationFrame(scroll);
            }
        };
    };
}
