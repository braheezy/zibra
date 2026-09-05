//! Owned adapters for work transferred from a Browser/UI thread to a Tab.
//!
//! The factory takes the Browser type at comptime, avoiding an import cycle
//! while keeping task payload ownership and opaque cleanup out of root.zig.

const std = @import("std");
const Url = @import("../network/url.zig").Url;
const parser = @import("../document/parser.zig");
const document_lifecycle = @import("document_lifecycle.zig");
const js_module = @import("../script/js.zig");
const tab_module = @import("tab.zig");

const Tab = tab_module.Tab;
const Frame = tab_module.Frame;
const ClickButton = tab_module.ClickButton;
const HoverPosition = tab_module.HoverPosition;
const HistoryDirection = tab_module.HistoryDirection;

/// Locate the document's first body Element without retaining a Node beyond
/// the synchronous lifecycle dispatch that uses it. The parser guarantees a
/// body by EOF, but this stays defensive for an interrupted/partially built
/// document generation.
fn documentBody(root: *parser.Node) ?*parser.Node {
    return switch (root.*) {
        .text => null,
        .element => |*element| {
            if (std.ascii.eqlIgnoreCase(element.tag, "body")) return root;
            for (element.children.items) |*child| {
                if (documentBody(child)) |body| return body;
            }
            return null;
        },
    };
}

pub fn Contexts(comptime Browser: type) type {
    return struct {
        pub const DocumentHandle = struct {
            window_id: u32,
            generation: u64,

            pub fn fromFrame(frame: *const Frame) DocumentHandle {
                return .{
                    .window_id = frame.window_id,
                    .generation = frame.document_generation,
                };
            }

            pub fn resolve(self: DocumentHandle, tab: *Tab) ?*Frame {
                const frame = tab.frameForWindowId(self.window_id) orelse return null;
                if (frame.document_generation != self.generation) return null;
                return frame;
            }
        };

        pub const LoadTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            url: ?*Url,
            payload: ?[]const u8,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                url: *Url,
                payload: ?[]const u8,
            ) !*@This() {
                const context = try allocator.create(@This());
                context.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .url = url,
                    .payload = payload,
                };
                return context;
            }

            pub fn destroy(self: *@This()) void {
                self.consumePayload();
                if (self.url) |url| {
                    url.free(self.allocator);
                    self.allocator.destroy(url);
                }
                self.allocator.destroy(self);
            }

            fn consumePayload(self: *@This()) void {
                if (self.payload) |payload| {
                    self.allocator.free(payload);
                    self.payload = null;
                }
            }

            fn run(self: *@This()) !void {
                defer self.consumePayload();
                try self.browser.loadInTab(self.tab, self.url.?, self.payload, .push);
                self.url = null;
            }

            pub fn toOpaque(self: *@This()) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(raw: *anyopaque) *@This() {
                const unaligned: *align(1) @This() = @ptrCast(raw);
                return @alignCast(unaligned);
            }

            pub fn runOpaque(raw: *anyopaque) anyerror!void {
                try fromOpaque(raw).run();
            }

            pub fn cleanupOpaque(raw: *anyopaque) void {
                fromOpaque(raw).destroy();
            }
        };

        pub const FrameLoadTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            document: DocumentHandle,
            url: ?*Url,
            payload: ?[]const u8,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                frame: *Frame,
                url: *Url,
                payload: ?[]const u8,
            ) !*@This() {
                const context = try allocator.create(@This());
                context.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = frame.tab,
                    .document = DocumentHandle.fromFrame(frame),
                    .url = url,
                    .payload = payload,
                };
                return context;
            }

            pub fn destroy(self: *@This()) void {
                self.consumePayload();
                if (self.url) |url| {
                    url.free(self.allocator);
                    self.allocator.destroy(url);
                }
                self.allocator.destroy(self);
            }

            fn consumePayload(self: *@This()) void {
                if (self.payload) |payload| {
                    self.allocator.free(payload);
                    self.payload = null;
                }
            }

            fn run(self: *@This()) !void {
                defer self.consumePayload();
                const frame = self.document.resolve(self.tab) orelse return;
                try self.browser.loadInFrame(frame, self.url.?, self.payload, .push);
            }

            pub fn toOpaque(self: *@This()) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(raw: *anyopaque) *@This() {
                const unaligned: *align(1) @This() = @ptrCast(raw);
                return @alignCast(unaligned);
            }

            pub fn runOpaque(raw: *anyopaque) anyerror!void {
                try fromOpaque(raw).run();
            }

            pub fn cleanupOpaque(raw: *anyopaque) void {
                fromOpaque(raw).destroy();
            }
        };

        pub const TabActionTaskContext = struct {
            pub const Action = union(enum) {
                click: struct {
                    x: i32,
                    y: i32,
                    button: ClickButton,
                    zoom: f32,
                },
                hover: ?HoverPosition,
                keypress: u8,
                backspace,
                scroll: i32,
                immediate_scroll: i32,
                blur,
                history: union(enum) {
                    direction: HistoryDirection,
                    resubmit: struct {
                        target: usize,
                        history_generation: u64,
                    },
                },
                // A wake-up only; dimensions live in the Tab's atomic mailbox.
                resize,
            };

            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            action: Action,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                action: Action,
            ) !*@This() {
                const context = try allocator.create(@This());
                context.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .action = action,
                };
                return context;
            }

            pub fn destroy(self: *@This()) void {
                self.allocator.destroy(self);
            }

            fn run(self: *@This()) !void {
                switch (self.action) {
                    .click => |click| try self.tab.clickDevice(
                        self.browser,
                        click.x,
                        click.y,
                        click.button,
                        click.zoom,
                    ),
                    .hover => |position| self.tab.hover(position),
                    .keypress => |char| try self.tab.keypress(self.browser, char),
                    .backspace => try self.tab.backspace(self.browser),
                    .scroll => |delta| self.tab.scrollFocused(self.browser, delta),
                    .immediate_scroll => |delta| self.tab.scrollImmediate(self.browser, delta),
                    .blur => if (self.tab.blur()) {
                        self.tab.updateAccessibilityFocus(self.browser);
                        self.tab.setNeedsRender();
                    },
                    .history => |history| switch (history) {
                        .direction => |direction| try self.tab.traverseHistory(
                            self.browser,
                            direction,
                        ),
                        .resubmit => |request| try self.tab.resubmitHistoryEntry(
                            self.browser,
                            request.target,
                            request.history_generation,
                        ),
                    },
                    .resize => {
                        if (self.tab.isShuttingDown()) return;
                        if (!self.tab.applyRequestedViewport()) return;
                        self.browser.setNeedsAnimationFrame(self.tab);
                        self.browser.scheduleAnimationFrame();
                    },
                }
            }

            pub fn toOpaque(self: *@This()) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(raw: *anyopaque) *@This() {
                const unaligned: *align(1) @This() = @ptrCast(raw);
                return @alignCast(unaligned);
            }

            pub fn runOpaque(raw: *anyopaque) anyerror!void {
                try fromOpaque(raw).run();
            }

            pub fn cleanupOpaque(raw: *anyopaque) void {
                fromOpaque(raw).destroy();
            }
        };

        pub const ScriptTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            document: DocumentHandle,
            script_label: []const u8,
            script_url: Url,
            script_body: []const u8,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                document: DocumentHandle,
                script_label: []const u8,
                script_url: Url,
                script_body: []const u8,
            ) !*@This() {
                const context = try allocator.create(@This());
                context.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .document = document,
                    .script_label = script_label,
                    .script_url = script_url,
                    .script_body = script_body,
                };
                return context;
            }

            pub fn destroy(self: *@This()) void {
                self.script_url.free(self.allocator);
                self.allocator.free(self.script_body);
                self.allocator.free(self.script_label);
                self.allocator.destroy(self);
            }

            pub fn toOpaque(self: *@This()) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(raw: *anyopaque) *@This() {
                const unaligned: *align(1) @This() = @ptrCast(raw);
                return @alignCast(unaligned);
            }

            pub fn runOpaque(raw: *anyopaque) anyerror!void {
                try fromOpaque(raw).run();
            }

            pub fn cleanupOpaque(raw: *anyopaque) void {
                fromOpaque(raw).destroy();
            }

            fn run(self: *@This()) !void {
                const frame = self.document.resolve(self.tab) orelse return;
                const js_context = frame.js_context orelse return;

                std.log.info("Executing script for window_id={d}", .{self.document.window_id});
                std.log.info("========== Executing script ==========", .{});
                const trace_eval = self.browser.measure.begin("evaljs");
                defer if (trace_eval) self.browser.measure.end("evaljs");
                _ = js_context.evaluate(
                    self.document.window_id,
                    self.script_body,
                ) catch |err| {
                    std.log.err("Script {s} crashed: {}", .{ self.script_label, err });
                    return;
                };
                std.log.info("======================================", .{});
            }
        };

        /// Runs after the document's already queued static scripts and moves
        /// its lifecycle from loading to event eligibility. It has no claim to
        /// release: navigation simply makes its DocumentHandle stale.
        pub const LifecycleReadyTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            document: DocumentHandle,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                document: DocumentHandle,
            ) !*@This() {
                const context = try allocator.create(@This());
                context.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .document = document,
                };
                return context;
            }

            pub fn destroy(self: *@This()) void {
                self.allocator.destroy(self);
            }

            pub fn toOpaque(self: *@This()) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(raw: *anyopaque) *@This() {
                const unaligned: *align(1) @This() = @ptrCast(raw);
                return @alignCast(unaligned);
            }

            pub fn runOpaque(raw: *anyopaque) anyerror!void {
                try fromOpaque(raw).run();
            }

            pub fn cleanupOpaque(raw: *anyopaque) void {
                fromOpaque(raw).destroy();
            }

            fn run(self: *@This()) !void {
                const frame = self.document.resolve(self.tab) orelse return;
                self.browser.markDocumentLifecycleEligible(frame);
            }
        };

        /// Owns one already-claimed document lifecycle delivery. The claim is
        /// released if the task is discarded before it can run, while a
        /// successfully reached generation always finishes the event even if
        /// page JavaScript throws.
        pub const LifecycleTaskContext = struct {
            allocator: std.mem.Allocator,
            browser: *Browser,
            tab: *Tab,
            document: DocumentHandle,
            dispatch: document_lifecycle.Dispatch,
            claim_pending: bool = true,

            pub fn create(
                allocator: std.mem.Allocator,
                browser: *Browser,
                tab: *Tab,
                document: DocumentHandle,
                dispatch: document_lifecycle.Dispatch,
            ) !*@This() {
                const context = try allocator.create(@This());
                context.* = .{
                    .allocator = allocator,
                    .browser = browser,
                    .tab = tab,
                    .document = document,
                    .dispatch = dispatch,
                };
                return context;
            }

            pub fn destroy(self: *@This()) void {
                if (self.claim_pending) {
                    if (self.document.resolve(self.tab)) |frame| {
                        _ = frame.lifecycle.releaseDispatch(self.dispatch);
                    }
                }
                self.allocator.destroy(self);
            }

            pub fn toOpaque(self: *@This()) *anyopaque {
                return @ptrCast(self);
            }

            fn fromOpaque(raw: *anyopaque) *@This() {
                const unaligned: *align(1) @This() = @ptrCast(raw);
                return @alignCast(unaligned);
            }

            pub fn runOpaque(raw: *anyopaque) anyerror!void {
                try fromOpaque(raw).run();
            }

            pub fn cleanupOpaque(raw: *anyopaque) void {
                fromOpaque(raw).destroy();
            }

            fn run(self: *@This()) !void {
                const frame = self.document.resolve(self.tab) orelse {
                    self.claim_pending = false;
                    return;
                };
                if (!frame.lifecycle.isCurrent(self.dispatch.generation)) {
                    self.claim_pending = false;
                    return;
                }

                if (frame.js_context) |js_context| {
                    const event: js_module.LifecycleEvent = switch (self.dispatch.event) {
                        .dom_content_loaded => .dom_content_loaded,
                        .load => .load,
                    };
                    js_context.dispatchLifecycleEvent(self.document.window_id, event) catch |err| {
                        // Browser lifecycle events are exactly once. A listener
                        // exception is reported by the JS host but does not
                        // make this document eligible for a second delivery.
                        std.log.warn("Lifecycle event delivery failed: {}", .{err});
                    };

                    // HTML maps an authored body onload handler onto document
                    // load completion. Keep it as a target-only Element event
                    // in this bounded DOM API, after the window load delivery;
                    // the native entry point neither retains `body` nor revives
                    // a stale/missing Realm.
                    if (self.dispatch.event == .load) {
                        if (frame.current_node) |*root| {
                            if (documentBody(root)) |body| {
                                _ = js_context.dispatchInlineEvent(
                                    self.document.window_id,
                                    "load",
                                    body,
                                    false,
                                ) catch |err| {
                                    std.log.warn("Inline body load handler failed: {}", .{err});
                                };
                            }
                        }
                        // Completing a child browsing context also fires the
                        // load event on its embedding iframe element. This
                        // lets script-assigned `iframe.onload` handlers see
                        // resource completion in the parent Realm.
                        if (frame.parent) |parent| {
                            // Parent child arrays are by-value and may have
                            // relocated the iframe element while this child
                            // was loading. Rebind the scalar frame marker
                            // before borrowing it for event dispatch.
                            parent.reconcileAttachedChildFrames();
                            if (frame.frame_element) |iframe_element| {
                                if (parent.js_context) |parent_js| {
                                    _ = parent_js.dispatchEvent(
                                        parent.window_id,
                                        "load",
                                        iframe_element,
                                    ) catch |err| {
                                        std.log.warn("Iframe load event delivery failed: {}", .{err});
                                    };
                                }
                            }
                        }
                    }
                }

                _ = frame.lifecycle.finishDispatch(self.dispatch);
                self.claim_pending = false;
                self.browser.scheduleNextDocumentLifecycleEvent(frame) catch |err| {
                    // The current event is already complete. Leaving the next
                    // one eligible lets a later explicit scheduling point retry
                    // after a transient allocation failure.
                    std.log.warn("Failed to queue next lifecycle event: {}", .{err});
                };
            }
        };
    };
}
