//! Owned adapters for work transferred from a Browser/UI thread to a Tab.
//!
//! The factory takes the Browser type at comptime, avoiding an import cycle
//! while keeping task payload ownership and opaque cleanup out of root.zig.

const std = @import("std");
const parser = @import("../document/parser.zig");
const js_module = @import("../script/js.zig");
const Url = @import("../network/url.zig").Url;
const tab_module = @import("tab.zig");

const Node = parser.Node;
const Tab = tab_module.Tab;
const Frame = tab_module.Frame;
const ClickButton = tab_module.ClickButton;
const HoverPosition = tab_module.HoverPosition;
const HistoryDirection = tab_module.HistoryDirection;

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
                resize: struct {
                    width: i32,
                    height: i32,
                    generation: u64,
                },
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
                    .resize => |resize| {
                        if (self.tab.isShuttingDown()) return;
                        if (resize.generation != self.browser.resize_generation.load(.seq_cst)) return;
                        self.tab.resizeViewport(resize.width, resize.height);
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
                const result = js_context.evaluate(
                    self.document.window_id,
                    self.script_body,
                ) catch |err| {
                    std.log.err("Script {s} crashed: {}", .{ self.script_label, err });
                    return;
                };

                var result_buf: [4096]u8 = undefined;
                const result_str = js_module.formatValue(result, &result_buf) catch |err| {
                    std.log.err("Failed to format script result: {}", .{err});
                    return;
                };
                std.log.info("Script result: {s}", .{result_str});
                std.log.info("======================================", .{});

                if (!std.mem.eql(u8, result_str, "undefined")) {
                    self.injectResult(result_str) catch |err| {
                        std.log.warn("Failed to inject script result: {}", .{err});
                    };
                }
            }

            fn injectResult(self: *@This(), result_str: []const u8) anyerror!void {
                const frame = self.document.resolve(self.tab) orelse return;
                if (frame.current_node == null) return;

                const allocator = self.browser.allocator;
                const result_text = try allocator.dupe(u8, result_str);
                var nodes = std.ArrayList(*Node).empty;
                defer nodes.deinit(allocator);
                try parser.treeToList(allocator, &frame.current_node.?, &nodes);

                var body_node: ?*Node = null;
                for (nodes.items) |node| switch (node.*) {
                    .element => |element| if (std.mem.eql(u8, element.tag, "body")) {
                        body_node = node;
                        break;
                    },
                    .text => {},
                };

                if (body_node) |body| {
                    const text_node = Node{ .text = .{
                        .text = result_text,
                        .parent = body,
                    } };
                    try body.appendChild(allocator, text_node);
                    try self.tab.dynamic_texts.append(allocator, result_text);
                    parser.fixParentPointers(&frame.current_node.?, null);
                    try self.tab.render(self.browser);
                } else {
                    allocator.free(result_text);
                }
            }
        };
    };
}
