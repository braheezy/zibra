const std = @import("std");

const kiesel = @import("kiesel");
const Agent = kiesel.execution.Agent;
const Script = kiesel.language.Script;
const Realm = kiesel.execution.Realm;
const Value = kiesel.types.Value;
const parser = @import("parser.zig");
const Node = parser.Node;
const CSSParser = @import("cssParser.zig").CSSParser;
const Selector = @import("selector.zig").Selector;
const NumericAnimation = parser.NumericAnimation;

const Js = @This();

// Assume 60 fps for frame calculations
const FRAMES_PER_SECOND: u32 = 60;

/// Parse a simple inline style string like "opacity: 0.5; transition: opacity 2s"
fn parseInlineStyle(allocator: std.mem.Allocator, style_str: []const u8) !std.StringHashMap([]const u8) {
    var result = std.StringHashMap([]const u8).init(allocator);
    errdefer result.deinit();

    var parts = std.mem.tokenizeAny(u8, style_str, ";");
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
            const property = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
            const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");
            try result.put(property, value);
        }
    }
    return result;
}

/// Parse a transition value like "opacity 2s" into property name and frame count
fn parseTransitionValue(value: []const u8) ?struct { property: []const u8, frames: u32 } {
    var parts = std.mem.tokenizeAny(u8, value, " \t");
    const property = parts.next() orelse return null;
    const duration_str = parts.next() orelse return null;

    var frames: u32 = 0;
    if (std.mem.endsWith(u8, duration_str, "ms")) {
        const ms_str = duration_str[0 .. duration_str.len - 2];
        const ms = std.fmt.parseFloat(f64, ms_str) catch return null;
        frames = @intFromFloat(ms / 1000.0 * @as(f64, FRAMES_PER_SECOND));
    } else if (std.mem.endsWith(u8, duration_str, "s")) {
        const s_str = duration_str[0 .. duration_str.len - 1];
        const s = std.fmt.parseFloat(f64, s_str) catch return null;
        frames = @intFromFloat(s * @as(f64, FRAMES_PER_SECOND));
    } else {
        return null;
    }

    return .{ .property = property, .frames = @max(1, frames) };
}

/// Start an opacity animation on an element
fn startOpacityAnimation(allocator: std.mem.Allocator, elem: *parser.Element, start: f64, end: f64, frames: u32) !void {
    if (elem.animations == null) {
        elem.animations = std.StringHashMap(NumericAnimation).init(allocator);
    }
    const animation = NumericAnimation.init(start, end, frames);
    try elem.animations.?.put("opacity", animation);
}

pub const RenderCallbackFn = *const fn (context: ?*anyopaque) anyerror!void;

const RenderCallback = struct {
    function: ?RenderCallbackFn = null,
    context: ?*anyopaque = null,
};

pub const AnimationFrameCallbackFn = *const fn (context: ?*anyopaque) anyerror!void;

const AnimationFrameCallback = struct {
    function: ?AnimationFrameCallbackFn = null,
    context: ?*anyopaque = null,
};

pub const SetTimeoutCallbackFn = *const fn (
    context: ?*anyopaque,
    handle: u32,
    delay_ms: u32,
) anyerror!void;

const SetTimeoutCallback = struct {
    function: ?SetTimeoutCallbackFn = null,
    context: ?*anyopaque = null,
};

const JsLock = struct {
    mutex: std.Thread.Mutex = .{},
    owner: ?std.Thread.Id = null,
    depth: usize = 0,

    fn lock(self: *JsLock) void {
        const tid = std.Thread.getCurrentId();
        if (self.owner != null and self.owner.? == tid) {
            self.depth += 1;
            return;
        }
        self.mutex.lock();
        self.owner = tid;
        self.depth = 1;
    }

    fn unlock(self: *JsLock) void {
        const tid = std.Thread.getCurrentId();
        if (self.owner == null or self.owner.? != tid) return;
        if (self.depth > 1) {
            self.depth -= 1;
            return;
        }
        self.depth = 0;
        self.owner = null;
        self.mutex.unlock();
    }
};

pub const PostMessageCallbackFn = *const fn (
    context: ?*anyopaque,
    source_window_id: u32,
    target_window_id: u32,
    target_origin: []const u8,
    message: []const u8,
) anyerror!void;

const PostMessageCallback = struct {
    function: ?PostMessageCallbackFn = null,
    context: ?*anyopaque = null,
};

pub const XhrResult = struct {
    data: []const u8,
    allocator: ?std.mem.Allocator = null,
    should_free: bool = false,
};

pub const XhrCallbackFn = *const fn (
    context: ?*anyopaque,
    method: []const u8,
    url: []const u8,
    body: ?[]const u8,
    is_async: bool,
    handle: u32,
) anyerror!XhrResult;

const XhrCallback = struct {
    function: ?XhrCallbackFn = null,
    context: ?*anyopaque = null,
};

const PendingMessage = struct {
    message: []u8,
    origin: []u8,
    source_window_id: u32,
};

const WindowContext = struct {
    realm: *Realm,
    node_to_handle: std.AutoHashMap(*Node, u32),
    handle_to_node: std.AutoHashMap(u32, *Node),
    next_handle: u32,
    current_nodes: ?*Node,
    pending_messages: std.ArrayList(PendingMessage),
    render_callback: RenderCallback,
    set_timeout_callback: SetTimeoutCallback,
    post_message_callback: PostMessageCallback,
    xhr_callback: XhrCallback,
    animation_frame_callback: AnimationFrameCallback,
};

platform: Agent.Platform,
agent: Agent,
allocator: std.mem.Allocator,
windows: std.AutoHashMap(u32, WindowContext),
parent_window_ids: std.AutoHashMap(u32, u32),
current_window_id: ?u32 = null,
lock: JsLock = .{},
realm: ?*Realm = null,
runtime_initialized: bool = false,

pub fn init(allocator: std.mem.Allocator) !*Js {
    const self = try allocator.create(Js);
    errdefer allocator.destroy(self);

    // Initialize platform first
    self.platform = Agent.Platform.default();

    // Then initialize agent with a pointer to the platform that's now in the struct
    self.agent = try Agent.init(&self.platform, .{});
    errdefer self.agent.deinit();

    self.allocator = allocator;
    self.windows = std.AutoHashMap(u32, WindowContext).init(allocator);
    self.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    self.current_window_id = null;
    self.lock = .{};
    self.realm = null;
    self.runtime_initialized = false;

    return self;
}

fn ensureWindow(self: *Js, window_id: u32) !void {
    if (self.windows.contains(window_id)) return;

    if (self.realm == null) {
        try Realm.initializeHostDefinedRealm(&self.agent, .{});
        self.realm = self.agent.currentRealm();
        try self.setupConsole(self.realm.?);
        try self.setupDocument(self.realm.?);
    }

    const ctx = WindowContext{
        .realm = self.realm.?,
        .node_to_handle = std.AutoHashMap(*Node, u32).init(self.allocator),
        .handle_to_node = std.AutoHashMap(u32, *Node).init(self.allocator),
        .next_handle = 0,
        .current_nodes = null,
        .pending_messages = std.ArrayList(PendingMessage).empty,
        .render_callback = .{},
        .set_timeout_callback = .{},
        .post_message_callback = .{},
        .xhr_callback = .{},
        .animation_frame_callback = .{},
    };

    try self.windows.put(window_id, ctx);
}

fn getWindowContext(self: *Js, window_id: u32) !*WindowContext {
    if (!self.windows.contains(window_id)) {
        try self.ensureWindow(window_id);
    }
    return self.windows.getPtr(window_id).?;
}

fn setCurrentWindow(self: *Js, window_id: u32) !*WindowContext {
    self.current_window_id = window_id;
    return self.getWindowContext(window_id);
}

/// Set up the console object with log function
fn setupConsole(self: *Js, realm: *Realm) !void {
    const builtins = kiesel.builtins;
    const PropertyKey = kiesel.types.PropertyKey;

    // Create console object
    const console_obj = try builtins.ordinaryObjectCreate(&self.agent, null);

    // Add log function to console
    try console_obj.defineBuiltinFunction(
        &self.agent,
        "log",
        consoleLog,
        1,
        realm,
    );

    // Add console to global object
    try realm.global_object.definePropertyDirect(
        &self.agent,
        PropertyKey.from("console"),
        .{
            .value_or_accessor = .{ .value = Value.from(console_obj) },
            .attributes = .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            },
        },
    );
}

/// console.log implementation
fn consoleLog(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    _ = agent;

    // Print each argument
    var i: usize = 0;
    while (i < arguments.count()) : (i += 1) {
        const arg = arguments.get(i);

        // Format the value to a buffer
        var buf: [4096]u8 = undefined;
        const formatted = formatValue(arg, &buf) catch |err| {
            // If formatting fails, print an error message
            std.debug.print("(error formatting value: {})", .{err});
            if (i < arguments.count() - 1) {
                std.debug.print(" ", .{});
            }
            continue;
        };

        // Print to stdout
        std.debug.print("{s}", .{formatted});

        // Add space between arguments
        if (i < arguments.count() - 1) {
            std.debug.print(" ", .{});
        }
    }
    std.debug.print("\n", .{});

    return .undefined;
}

pub fn deinit(self: *Js, allocator: std.mem.Allocator) void {
    self.lock.lock();
    defer self.lock.unlock();
    var it = self.windows.valueIterator();
    while (it.next()) |window| {
        window.node_to_handle.deinit();
        window.handle_to_node.deinit();
        for (window.pending_messages.items) |msg| {
            self.allocator.free(msg.message);
            self.allocator.free(msg.origin);
        }
        window.pending_messages.deinit(self.allocator);
    }
    self.windows.deinit();
    self.parent_window_ids.deinit();
    self.platform.deinit();
    self.agent.deinit();
    allocator.destroy(self);
}

pub fn evaluate(self: *Js, window_id: u32, code: []const u8) !Value {
    self.lock.lock();
    defer self.lock.unlock();
    const window = try self.setCurrentWindow(window_id);
    // Inject runtime code to wrap handles in Node objects
    const runtime_code =
        \\// Node constructor that wraps a handle
        \\function Node(handle) {
        \\  this.handle = handle;
        \\}
        \\
        \\var XHR_REQUESTS = {};
        \\
        \\function XMLHttpRequest() {
        \\  this.handle = Object.keys(XHR_REQUESTS).length;
        \\  XHR_REQUESTS[this.handle] = this;
        \\  this.is_async = true;
        \\  this.__method = "GET";
        \\  this.__url = "";
        \\}
        \\
        \\XMLHttpRequest.prototype.open = function(method, url, is_async) {
        \\  var flag = (is_async === undefined) ? true : !!is_async;
        \\  this.is_async = flag;
        \\  this.__method = method;
        \\  this.__url = url;
        \\};
        \\
        \\XMLHttpRequest.prototype.send = function(body) {
        \\  var payload = body == null ? null : body.toString();
        \\  var response = __native.xhrSend(
        \\    this.__method || "GET",
        \\    this.__url,
        \\    payload,
        \\    !!this.is_async,
        \\    this.handle
        \\  );
        \\  if (!this.is_async) {
        \\    this.responseText = response;
        \\  }
        \\};
        \\
        \\function Event(type) {
        \\  this.type = type;
        \\  this.do_default = true;
        \\}
        \\
        \\Event.prototype.preventDefault = function() {
        \\  this.do_default = false;
        \\};
        \\
        \\var LISTENERS = {};
        \\
        \\Node.prototype.addEventListener = function(type, listener) {
        \\  if (!LISTENERS[this.handle]) LISTENERS[this.handle] = {};
        \\  var dict = LISTENERS[this.handle];
        \\  if (!dict[type]) dict[type] = [];
        \\  var list = dict[type];
        \\  list.push(listener);
        \\};
        \\
        \\Node.prototype.dispatchEvent = function(evt) {
        \\  var event = typeof evt === "string" ? new Event(evt) : evt;
        \\  var handle = this.handle;
        \\  var list = (LISTENERS[handle] && LISTENERS[handle][event.type]) || [];
        \\  for (var i = 0; i < list.length; i++) {
        \\    list[i].call(this, event);
        \\  }
        \\  return event.do_default;
        \\};
        \\
        \\// Add getAttribute method to Node prototype
        \\Node.prototype.getAttribute = function(name) {
        \\  return __native.getAttribute(this.handle, name);
        \\};
        \\
        \\// Add setAttribute method to Node prototype
        \\Node.prototype.setAttribute = function(name, value) {
        \\  var text = value == null ? "" : value.toString();
        \\  __native.setAttribute(this.handle, name, text);
        \\};
        \\
        \\// Add innerHTML setter to Node prototype
        \\Object.defineProperty(Node.prototype, "innerHTML", {
        \\  set: function(value) {
        \\    var text = value == null ? "" : value.toString();
        \\    __native.innerHTML(this.handle, text);
        \\  }
        \\});
        \\
        \\// Add style setter to Node prototype
        \\Object.defineProperty(Node.prototype, "style", {
        \\  set: function(value) {
        \\    var text = value == null ? "" : value.toString();
        \\    __native.style_set(this.handle, text);
        \\  }
        \\});
        \\
        \\__native.dispatchEvent = function(handle, type) {
        \\  return new Node(handle).dispatchEvent(new Event(type));
        \\};
        \\
        \\globalThis.Event = Event;
        \\globalThis.XMLHttpRequest = XMLHttpRequest;
        \\
        \\globalThis.__resetEventListeners = function(windowId) {
        \\  LISTENERS = {};
        \\  var targetId = (windowId === undefined || windowId === null) ? window.__id : windowId;
        \\  delete WINDOW_MESSAGE_LISTENERS[targetId];
        \\  delete WINDOW_ONMESSAGE[targetId];
        \\};
        \\
        \\var SET_TIMEOUT_REQUESTS = {};
        \\var NEXT_TIMEOUT_HANDLE = 0;
        \\
        \\globalThis.__runSetTimeout = function(handle) {
        \\  var callback = SET_TIMEOUT_REQUESTS[handle];
        \\  if (callback) callback();
        \\};
        \\
        \\globalThis.setTimeout = function(callback, timeout) {
        \\  var handle = NEXT_TIMEOUT_HANDLE++;
        \\  SET_TIMEOUT_REQUESTS[handle] = callback;
        \\  __native.setTimeout(handle, timeout || 0);
        \\  return handle;
        \\};
        \\
        \\var RAF_LISTENERS = [];
        \\
        \\function __runRAFHandlers() {
        \\  var handlers_copy = RAF_LISTENERS;
        \\  RAF_LISTENERS = [];
        \\  for (var i = 0; i < handlers_copy.length; i++) {
        \\    handlers_copy[i]();
        \\  }
        \\}
        \\
        \\globalThis.requestAnimationFrame = function(fn) {
        \\  RAF_LISTENERS.push(fn);
        \\  __native.requestAnimationFrame();
        \\};
        \\
        \\var WINDOW_MESSAGE_LISTENERS = {};
        \\var WINDOW_ONMESSAGE = {};
        \\
        \\globalThis.window = globalThis;
        \\window.__id = __native.getWindowId();
        \\Object.defineProperty(window, "onmessage", {
        \\  get: function() { return WINDOW_ONMESSAGE[window.__id] || null; },
        \\  set: function(fn) { WINDOW_ONMESSAGE[window.__id] = fn; }
        \\});
        \\window.addEventListener = function(type, listener) {
        \\  if (type !== "message") return;
        \\  if (!WINDOW_MESSAGE_LISTENERS[window.__id]) WINDOW_MESSAGE_LISTENERS[window.__id] = [];
        \\  WINDOW_MESSAGE_LISTENERS[window.__id].push(listener);
        \\};
        \\window.postMessage = function(message, targetWindowId, targetOrigin) {
        \\  var payload = message == null ? "null" : message.toString();
        \\  var origin = targetOrigin === undefined ? "*" : targetOrigin.toString();
        \\  __native.postMessage(payload, targetWindowId, origin);
        \\};
        \\Object.defineProperty(window, "parent", {
        \\  get: function() {
        \\    var parentId = __native.getParentWindowId(window.__id);
        \\    if (parentId === null || parentId === undefined) return null;
        \\    return { __id: parentId, postMessage: function(message, targetOrigin) { var payload = message == null ? "null" : message.toString(); var origin = targetOrigin === undefined ? "*" : targetOrigin.toString(); __native.postMessage(payload, parentId, origin); } };
        \\  }
        \\});
        \\globalThis.__setActiveWindow = function(id) {
        \\  window.__id = id;
        \\};
        \\globalThis.__dispatchMessageEvent = function(message, origin, sourceId, targetId) {
        \\  var evt = { type: 'message', data: message, origin: origin, source: { __id: sourceId } };
        \\  var list = WINDOW_MESSAGE_LISTENERS[targetId] || [];
        \\  for (var i = 0; i < list.length; i++) {
        \\    list[i].call(window, evt);
        \\  }
        \\  var handler = WINDOW_ONMESSAGE[targetId];
        \\  if (handler) {
        \\    handler(evt);
        \\  }
        \\};
        \\
        \\globalThis.__runXHROnload = function(body, handle) {
        \\  var obj = XHR_REQUESTS[handle];
        \\  if (!obj) return;
        \\  var evt = new Event('load');
        \\  obj.responseText = body;
        \\  if (obj.onload) {
        \\    obj.onload(evt);
        \\  }
        \\};
        \\
        \\// Wrap document.querySelectorAll to return Node objects
        \\(function() {
        \\  var originalQuerySelectorAll = document.querySelectorAll;
        \\  document.querySelectorAll = function(selector) {
        \\    var handles = originalQuerySelectorAll.call(this, selector);
        \\    return handles.map(function(h) { return new Node(h); });
        \\  };
        \\})();
    ;

    if (!self.runtime_initialized) {
        const runtime_script = try Script.parse(
            runtime_code,
            window.realm,
            null,
            .{},
        );
        _ = try runtime_script.evaluate();
        self.runtime_initialized = true;
        if (window.pending_messages.items.len > 0) {
            for (window.pending_messages.items) |msg| {
                self.dispatchMessageImpl(window, msg.message, msg.origin, msg.source_window_id, window_id) catch |err| {
                    std.log.warn("Failed to dispatch queued postMessage: {}", .{err});
                };
                self.allocator.free(msg.message);
                self.allocator.free(msg.origin);
            }
            window.pending_messages.clearRetainingCapacity();
        }
    }
    try self.setActiveWindow(window_id, window);

    // Now evaluate the user's code
    const script = try Script.parse(
        code,
        window.realm,
        null,
        .{},
    );
    const result = try script.evaluate();
    return result;
}

/// Format a JavaScript value to a string buffer
/// Returns a slice of the provided buffer containing the formatted value
pub fn formatValue(value: Value, buf: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const w: *std.Io.Writer = &writer;

    try value.format(w);

    return buf[0..writer.end];
}

/// Set the current nodes for DOM operations
pub fn setNodes(self: *Js, window_id: u32, nodes: ?*Node) void {
    self.lock.lock();
    defer self.lock.unlock();
    const window = self.setCurrentWindow(window_id) catch return;
    window.current_nodes = nodes;
    // Clear handle mappings when nodes change
    window.node_to_handle.clearRetainingCapacity();
    window.handle_to_node.clearRetainingCapacity();
    window.next_handle = 0;
    if (nodes == null) {
        window.render_callback = .{};
        window.xhr_callback = .{};
        window.set_timeout_callback = .{};
        window.post_message_callback = .{};
        window.animation_frame_callback = .{};
    } else {
        // Reset JavaScript-side listener state when the DOM changes.
        self.resetEventListenersImpl(window, window_id);
    }
}

pub fn setRenderCallback(self: *Js, window_id: u32, callback: ?RenderCallbackFn, context: ?*anyopaque) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.render_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setXhrCallback(self: *Js, window_id: u32, callback: ?XhrCallbackFn, context: ?*anyopaque) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.xhr_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setSetTimeoutCallback(self: *Js, window_id: u32, callback: ?SetTimeoutCallbackFn, context: ?*anyopaque) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.set_timeout_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setAnimationFrameCallback(self: *Js, window_id: u32, callback: ?AnimationFrameCallbackFn, context: ?*anyopaque) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.animation_frame_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setPostMessageCallback(self: *Js, window_id: u32, callback: ?PostMessageCallbackFn, context: ?*anyopaque) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.post_message_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setParentWindow(self: *Js, child_window_id: u32, parent_window_id: ?u32) void {
    if (parent_window_id) |parent_id| {
        self.parent_window_ids.put(child_window_id, parent_id) catch {};
    } else {
        _ = self.parent_window_ids.fetchRemove(child_window_id);
    }
}

/// Get or create a handle for a node
fn getHandle(self: *Js, window: *WindowContext, node: *Node) !u32 {
    _ = self;
    if (window.node_to_handle.get(node)) |handle| {
        return handle;
    }

    const handle = window.next_handle;
    window.next_handle += 1;

    try window.node_to_handle.put(node, handle);
    try window.handle_to_node.put(handle, node);

    return handle;
}

/// Get a node from a handle
fn getNode(self: *Js, window: *WindowContext, handle: u32) ?*Node {
    _ = self;
    return window.handle_to_node.get(handle);
}

fn requestRender(self: *Js) void {
    const window_id = self.current_window_id orelse return;
    const window = self.windows.getPtr(window_id) orelse return;
    if (window.render_callback.function) |callback| {
        const context = window.render_callback.context orelse return;
        callback(context) catch |err| {
            std.log.warn("Render callback failed: {}", .{err});
        };
    }
}

/// Dispatch an event to the JavaScript environment for the given node
/// Returns true if the default action should proceed.
pub fn dispatchEvent(self: *Js, window_id: u32, event_type: []const u8, node: *Node) !bool {
    self.lock.lock();
    defer self.lock.unlock();
    const window = try self.setCurrentWindow(window_id);
    try self.setActiveWindow(window_id, window);
    if (window.current_nodes == null) return true;

    const handle = try self.getHandle(window, node);

    const type_value = try kiesel.types.String.fromUtf8(&self.agent, event_type);
    const type_js_value = Value.from(type_value);
    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));

    const dispatch_key = kiesel.types.PropertyKey.from("__native");
    const native_value = try window.realm.global_object.get(&self.agent, dispatch_key);
    if (!native_value.isObject()) return true;
    const native_obj = native_value.asObject();
    const dispatch_property = kiesel.types.PropertyKey.from("dispatchEvent");
    const dispatch_value = try native_obj.internal_methods.get(
        &self.agent,
        native_obj,
        dispatch_property,
        native_value,
    );

    if (!dispatch_value.isCallable()) return true;

    const result = try dispatch_value.call(&self.agent, .undefined, &.{ handle_value, type_js_value });
    const do_default = result.toBoolean();
    return do_default;
}

pub fn dispatchPostMessage(
    self: *Js,
    window_id: u32,
    message: []const u8,
    origin: []const u8,
    source_window_id: u32,
) !void {
    self.lock.lock();
    defer self.lock.unlock();
    const window = try self.setCurrentWindow(window_id);
    try self.setActiveWindow(window_id, window);
    if (!self.runtime_initialized) {
        const message_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(message_copy);
        const origin_copy = try self.allocator.dupe(u8, origin);
        errdefer self.allocator.free(origin_copy);
        try window.pending_messages.append(self.allocator, .{
            .message = message_copy,
            .origin = origin_copy,
            .source_window_id = source_window_id,
        });
        return;
    }

    try self.dispatchMessageImpl(window, message, origin, source_window_id, window_id);
}

fn dispatchMessageImpl(
    self: *Js,
    window: *WindowContext,
    message: []const u8,
    origin: []const u8,
    source_window_id: u32,
    target_window_id: u32,
) !void {
    const key = kiesel.types.PropertyKey.from("__dispatchMessageEvent");
    const fn_value = try window.realm.global_object.get(&self.agent, key);
    if (!fn_value.isCallable()) return error.MissingMessageHandler;

    const message_value = try self.stringToJsValue(message);
    const origin_value = try self.stringToJsValue(origin);
    const source_value = Value.from(@as(f64, @floatFromInt(source_window_id)));
    const target_value = Value.from(@as(f64, @floatFromInt(target_window_id)));

    _ = try fn_value.call(&self.agent, .undefined, &.{ message_value, origin_value, source_value, target_value });
    self.requestRender();
}

pub fn runTimeoutCallback(self: *Js, window_id: u32, handle: u32) !void {
    self.lock.lock();
    defer self.lock.unlock();
    const window = try self.setCurrentWindow(window_id);
    try self.setActiveWindow(window_id, window);
    const key = kiesel.types.PropertyKey.from("__runSetTimeout");
    const fn_value = window.realm.global_object.get(&self.agent, key) catch {
        return error.MissingSetTimeout;
    };
    if (!fn_value.isCallable()) {
        return error.MissingSetTimeout;
    }
    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
    _ = try fn_value.call(&self.agent, .undefined, &.{ handle_value });
}

pub fn runAnimationFrameHandlers(self: *Js, window_id: u32) void {
    self.lock.lock();
    defer self.lock.unlock();
    const window = self.setCurrentWindow(window_id) catch return;
    self.setActiveWindow(window_id, window) catch return;
    const key = kiesel.types.PropertyKey.from("__runRAFHandlers");
    const fn_value = window.realm.global_object.get(&self.agent, key) catch return;
    if (!fn_value.isCallable()) return;
    _ = fn_value.call(&self.agent, .undefined, &.{}) catch |err| {
        std.log.warn("requestAnimationFrame handler failed: {}", .{err});
    };
}

fn resetEventListenersImpl(self: *Js, window: *WindowContext, window_id: u32) void {
    self.setActiveWindow(window_id, window) catch return;
    const reset_key = kiesel.types.PropertyKey.from("__resetEventListeners");
    const reset_value = window.realm.global_object.get(&self.agent, reset_key) catch return;
    if (!reset_value.isCallable()) return;
    const window_id_value = Value.from(@as(f64, @floatFromInt(window_id)));
    _ = reset_value.call(&self.agent, .undefined, &.{window_id_value}) catch return;
}

fn stringToJsValue(self: *Js, text: []const u8) !Value {
    const js_string = try kiesel.types.String.fromUtf8(&self.agent, text);
    return Value.from(js_string);
}

fn setActiveWindow(self: *Js, window_id: u32, window: *WindowContext) !void {
    if (!self.runtime_initialized) return;
    const key = kiesel.types.PropertyKey.from("__setActiveWindow");
    const fn_value = try window.realm.global_object.get(&self.agent, key);
    if (!fn_value.isCallable()) return;
    const window_value = Value.from(@as(f64, @floatFromInt(window_id)));
    _ = try fn_value.call(&self.agent, .undefined, &.{ window_value });
}

pub fn runXhrOnload(self: *Js, window_id: u32, handle: u32, body: []const u8) !void {
    self.lock.lock();
    defer self.lock.unlock();
    const window = try self.setCurrentWindow(window_id);
    try self.setActiveWindow(window_id, window);
    const key = kiesel.types.PropertyKey.from("__runXHROnload");
    const fn_value = try window.realm.global_object.get(&self.agent, key);
    if (!fn_value.isCallable()) return error.MissingXhrCallback;

    const body_value = try self.stringToJsValue(body);
    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
    _ = try fn_value.call(&self.agent, .undefined, &.{ body_value, handle_value });
}

test "Node.prototype.style setter is defined" {
    var js = try Js.init(std.testing.allocator);
    defer js.deinit(std.testing.allocator);

    const result = try js.evaluate(0, "Object.getOwnPropertyDescriptor(Node.prototype, 'style') !== undefined");
    try std.testing.expect(result.toBoolean());
}

test "__native.style_set is exposed" {
    var js = try Js.init(std.testing.allocator);
    defer js.deinit(std.testing.allocator);

    const result = try js.evaluate(0, "typeof __native.style_set === 'function'");
    try std.testing.expect(result.toBoolean());
}

test "native style_set updates element style attribute" {
    var js = try Js.init(std.testing.allocator);
    defer js.deinit(std.testing.allocator);

    const element = try parser.Element.init(std.testing.allocator, "div", null);
    var node = Node{ .element = element };
    defer node.deinit(std.testing.allocator);

    const window = try js.setCurrentWindow(0);
    const handle = try js.getHandle(window, &node);

    const SafePointer = kiesel.types.SafePointer;
    const builtins = kiesel.builtins;
    const self_ptr = SafePointer.make(*Js, js);
    const style_fn = try builtins.createBuiltinFunction(
        &js.agent,
        .{ .function = styleSet },
        2,
        "style_set",
        .{
            .realm = window.realm,
            .additional_fields = self_ptr,
        },
    );

    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
    const style_js = try kiesel.types.String.fromUtf8(&js.agent, "opacity: 0.5");
    const style_value = Value.from(&style_fn.object);
    _ = try style_value.call(&js.agent, .undefined, &.{ handle_value, Value.from(style_js) });

    switch (node) {
        .element => |e| {
            const attrs = e.attributes orelse {
                try std.testing.expect(false);
                return;
            };
            const style_attr = attrs.get("style") orelse {
                try std.testing.expect(false);
                return;
            };
            try std.testing.expectEqualStrings("opacity: 0.5", style_attr);
        },
        else => try std.testing.expect(false),
    }
}

const RenderTestContext = struct {
    called: *bool,
};

fn renderTestCallback(context: ?*anyopaque) anyerror!void {
    const ctx_ptr = context orelse return;
    const raw_ctx: *align(1) RenderTestContext = @ptrCast(ctx_ptr);
    const ctx: *RenderTestContext = @alignCast(raw_ctx);
    ctx.called.* = true;
}

test "native style_set requests render" {
    var js = try Js.init(std.testing.allocator);
    defer js.deinit(std.testing.allocator);

    const element = try parser.Element.init(std.testing.allocator, "div", null);
    var node = Node{ .element = element };
    defer node.deinit(std.testing.allocator);

    const window = try js.setCurrentWindow(0);
    const handle = try js.getHandle(window, &node);

    var called = false;
    var ctx = RenderTestContext{ .called = &called };
    js.setRenderCallback(0, renderTestCallback, @ptrCast(&ctx));

    const SafePointer = kiesel.types.SafePointer;
    const builtins = kiesel.builtins;
    const self_ptr = SafePointer.make(*Js, js);
    const style_fn = try builtins.createBuiltinFunction(
        &js.agent,
        .{ .function = styleSet },
        2,
        "style_set",
        .{
            .realm = window.realm,
            .additional_fields = self_ptr,
        },
    );

    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
    const style_js = try kiesel.types.String.fromUtf8(&js.agent, "opacity: 0.5");
    const style_value = Value.from(&style_fn.object);
    _ = try style_value.call(&js.agent, .undefined, &.{ handle_value, Value.from(style_js) });

    try std.testing.expect(called);
}

/// Set up the document object with DOM API
fn setupDocument(self: *Js, realm: *Realm) !void {
    const builtins = kiesel.builtins;
    const PropertyKey = kiesel.types.PropertyKey;
    const SafePointer = kiesel.types.SafePointer;
    // Store self pointer in a SafePointer for passing to builtin functions
    const self_ptr = SafePointer.make(*Js, self);

    // Create document object
    const document_obj = try builtins.ordinaryObjectCreate(&self.agent, null);

    // Create querySelectorAll function with self pointer
    const query_selector_all_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = querySelectorAll },
        1,
        "querySelectorAll",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    // Add querySelectorAll to document
    try document_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("querySelectorAll"),
        .{
            .value_or_accessor = .{ .value = Value.from(&query_selector_all_fn.object) },
            .attributes = .builtin_default,
        },
    );

    // Add document to global object
    try realm.global_object.definePropertyDirect(
        &self.agent,
        PropertyKey.from("document"),
        .{
            .value_or_accessor = .{ .value = Value.from(document_obj) },
            .attributes = .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            },
        },
    );

    // Create __native object to hold native DOM methods
    const native_obj = try builtins.ordinaryObjectCreate(&self.agent, null);

    // Create getAttribute function with self pointer
    const get_attribute_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = getAttribute },
        2,
        "getAttribute",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    // Add getAttribute to __native
    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("getAttribute"),
        .{
            .value_or_accessor = .{ .value = Value.from(&get_attribute_fn.object) },
            .attributes = .builtin_default,
        },
    );

    // Create setAttribute function with self pointer
    const set_attribute_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = setAttribute },
        3,
        "setAttribute",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    // Add setAttribute to __native
    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("setAttribute"),
        .{
            .value_or_accessor = .{ .value = Value.from(&set_attribute_fn.object) },
            .attributes = .builtin_default,
        },
    );

    // Create innerHTML function with self pointer
    const inner_html_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = innerHTML },
        2,
        "innerHTML",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    // Create style_set function with self pointer
    const style_set_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = styleSet },
        2,
        "style_set",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    // Add innerHTML to __native
    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("innerHTML"),
        .{
            .value_or_accessor = .{ .value = Value.from(&inner_html_fn.object) },
            .attributes = .builtin_default,
        },
    );

    // Add style_set to __native
    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("style_set"),
        .{
            .value_or_accessor = .{ .value = Value.from(&style_set_fn.object) },
            .attributes = .builtin_default,
        },
    );

    // Create xhrSend function with self pointer
    const xhr_send_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = xhrSend },
        5,
        "xhrSend",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("xhrSend"),
        .{
            .value_or_accessor = .{ .value = Value.from(&xhr_send_fn.object) },
            .attributes = .builtin_default,
        },
    );

    const set_timeout_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = setTimeoutNative },
        2,
        "setTimeout",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("setTimeout"),
        .{
            .value_or_accessor = .{ .value = Value.from(&set_timeout_fn.object) },
            .attributes = .builtin_default,
        },
    );

    const request_animation_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = requestAnimationFrameNative },
        0,
        "requestAnimationFrame",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("requestAnimationFrame"),
        .{
            .value_or_accessor = .{ .value = Value.from(&request_animation_fn.object) },
            .attributes = .builtin_default,
        },
    );

    const get_window_id_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = getWindowIdNative },
        0,
        "getWindowId",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("getWindowId"),
        .{
            .value_or_accessor = .{ .value = Value.from(&get_window_id_fn.object) },
            .attributes = .builtin_default,
        },
    );

    const get_parent_window_id_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = getParentWindowIdNative },
        1,
        "getParentWindowId",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("getParentWindowId"),
        .{
            .value_or_accessor = .{ .value = Value.from(&get_parent_window_id_fn.object) },
            .attributes = .builtin_default,
        },
    );

    const post_message_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = postMessageNative },
        3,
        "postMessage",
        .{
            .realm = realm,
            .additional_fields = self_ptr,
        },
    );

    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("postMessage"),
        .{
            .value_or_accessor = .{ .value = Value.from(&post_message_fn.object) },
            .attributes = .builtin_default,
        },
    );

    // Add __native to global
    try realm.global_object.definePropertyDirect(
        &self.agent,
        PropertyKey.from("__native"),
        .{
            .value_or_accessor = .{ .value = Value.from(native_obj) },
            .attributes = .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        },
    );
}

/// document.querySelectorAll implementation
fn querySelectorAll(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    _ = this_value;
    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    const selector_arg = arguments.get(0);
    if (!selector_arg.isString()) {
        return agent.throwException(
            .type_error,
            "querySelectorAll requires a string argument",
            .{},
        );
    }

    const selector_str = try selector_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(selector_str);

    var css_parser = CSSParser.init(js_instance.allocator, selector_str, false) catch {
        return agent.throwException(.syntax_error, "Invalid selector", .{});
    };
    defer css_parser.deinit(js_instance.allocator);

    var selector = css_parser.selector(js_instance.allocator) catch {
        return agent.throwException(.syntax_error, "Invalid selector", .{});
    };

    if (window.current_nodes == null) {
        const empty_array = try kiesel.builtins.arrayCreate(agent, 0, null);
        return Value.from(&empty_array.object);
    }

    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(js_instance.allocator);
    try parser.treeToList(js_instance.allocator, window.current_nodes.?, &node_list);

    var matching_handles = std.ArrayList(u32).empty;
    defer matching_handles.deinit(js_instance.allocator);

    for (node_list.items) |node| {
        var ancestors = std.ArrayList(*Node).empty;

        var current = node;
        while (true) {
            const parent = switch (current.*) {
                .element => |e| e.parent,
                .text => |t| t.parent,
            };
            if (parent) |p| {
                try ancestors.append(js_instance.allocator, p);
                current = p;
            } else {
                break;
            }
        }

        // Check if this node matches the selector
        const matches = selector.matches(node, ancestors.items);
        if (matches) {
            const handle = try js_instance.getHandle(window, node);
            try matching_handles.append(js_instance.allocator, handle);
        }

        ancestors.deinit(js_instance.allocator);
    }

    selector.deinit(js_instance.allocator);

    const result_array = try kiesel.builtins.arrayCreate(agent, @intCast(matching_handles.items.len), null);

    for (matching_handles.items, 0..) |handle, i| {
        const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
        try result_array.object.createDataPropertyDirect(
            agent,
            kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, @intCast(i))),
            handle_value,
        );
    }

    return Value.from(&result_array.object);
}

/// __native.getAttribute implementation
fn getAttribute(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    // Get the Js instance from the function's additional_fields
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    _ = this_value;

    // Get the handle from the first argument
    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(
            .type_error,
            "getAttribute requires a numeric handle as first argument",
            .{},
        );
    }

    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());

    // Get the node from the handle
    const node = js_instance.getNode(window, handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );

    // Get the attribute name argument (second argument)
    const attr_name_arg = arguments.get(1);
    if (!attr_name_arg.isString()) {
        return agent.throwException(
            .type_error,
            "getAttribute requires a string as second argument",
            .{},
        );
    }

    const attr_name = try attr_name_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(attr_name);

    // Get the attribute value from the node
    switch (node.*) {
        .element => |e| {
            if (e.attributes) |attrs| {
                if (attrs.get(attr_name)) |value| {
                    // Convert the attribute value to a JavaScript string
                    const js_string = try kiesel.types.String.fromUtf8(agent, value);
                    return Value.from(js_string);
                }
            }
            // Return null if attribute not found
            return .null;
        },
        .text => {
            // Text nodes don't have attributes
            return .null;
        },
    }
}

/// __native.setAttribute implementation
fn setAttribute(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    _ = this_value;

    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(
            .type_error,
            "setAttribute requires a numeric handle as first argument",
            .{},
        );
    }
    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());

    const node = js_instance.getNode(window, handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );

    const attr_name_arg = arguments.get(1);
    if (!attr_name_arg.isString()) {
        return agent.throwException(
            .type_error,
            "setAttribute requires a string name",
            .{},
        );
    }
    const attr_name = try attr_name_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(attr_name);

    const attr_value_arg = arguments.get(2);
    if (!attr_value_arg.isString()) {
        return agent.throwException(
            .type_error,
            "setAttribute requires a string value",
            .{},
        );
    }
    const attr_value = try attr_value_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(attr_value);

    switch (node.*) {
        .element => |*e| {
            if (e.attributes == null) {
                e.attributes = std.StringHashMap([]const u8).init(js_instance.allocator);
            }
            if (e.owned_strings == null) {
                e.owned_strings = std.ArrayList([]const u8).empty;
            }

            const owned_name = try js_instance.allocator.dupe(u8, attr_name);
            const owned_value = try js_instance.allocator.dupe(u8, attr_value);
            try e.owned_strings.?.append(js_instance.allocator, owned_name);
            try e.owned_strings.?.append(js_instance.allocator, owned_value);
            try e.attributes.?.put(owned_name, owned_value);

            if ((std.mem.eql(u8, e.tag, "img") or std.mem.eql(u8, e.tag, "iframe")) and
                (std.mem.eql(u8, attr_name, "width") or std.mem.eql(u8, attr_name, "height")))
            {
                e.children_dirty = true;
            }

            js_instance.requestRender();
            return .undefined;
        },
        .text => {
            return agent.throwException(
                .type_error,
                "Text nodes do not support setAttribute",
                .{},
            );
        },
    }
}

/// __native.innerHTML implementation (setter only)
fn innerHTML(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    // Get the Js instance from the function's additional_fields
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    _ = this_value;

    // Get the handle from the first argument
    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(
            .type_error,
            "innerHTML requires a numeric handle as first argument",
            .{},
        );
    }

    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());

    // Get the node from the handle
    const node = js_instance.getNode(window, handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );

    // Get the HTML string argument (second argument)
    const html_arg = arguments.get(1);
    if (!html_arg.isString()) {
        return agent.throwException(
            .type_error,
            "innerHTML requires a string as second argument",
            .{},
        );
    }

    const html_str = try html_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(html_str);

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(js_instance.allocator);

    try builder.appendSlice(js_instance.allocator, "<html><body>");
    try builder.appendSlice(js_instance.allocator, html_str);
    try builder.appendSlice(js_instance.allocator, "</body></html>");

    const wrapped_html = try builder.toOwnedSlice(js_instance.allocator);
    var wrapped_cleanup = true;
    defer if (wrapped_cleanup) js_instance.allocator.free(wrapped_html);

    var html_parser = parser.HTMLParser.init(js_instance.allocator, wrapped_html) catch |err| {
        std.log.err("Failed to init HTML parser: {}", .{err});
        return agent.throwException(
            .syntax_error,
            "Invalid HTML",
            .{},
        );
    };
    defer html_parser.deinit(js_instance.allocator);

    html_parser.use_implicit_tags = false;

    var parsed_node = html_parser.parse() catch |err| {
        std.log.err("Failed to parse HTML: {}", .{err});
        return agent.throwException(
            .syntax_error,
            "Invalid HTML",
            .{},
        );
    };
    defer parsed_node.deinit(js_instance.allocator);

    var body_children = std.ArrayList(Node).empty;

    switch (parsed_node) {
        .element => |*html_elem| {
            var idx: usize = 0;
            body_search: while (idx < html_elem.children.items.len) : (idx += 1) {
                const child = &html_elem.children.items[idx];
                switch (child.*) {
                    .element => |*child_elem| {
                        if (std.mem.eql(u8, child_elem.tag, "body")) {
                            body_children = child_elem.children;
                            child_elem.children = std.ArrayList(Node).empty;
                            break :body_search;
                        }
                    },
                    else => {},
                }
            }
        },
        .text => {},
    }
    defer body_children.deinit(js_instance.allocator);

    // Parse the HTML and replace the node's children
    switch (node.*) {
        .element => |*e| {
            // Clear existing children
            for (e.children.items) |*child| {
                child.deinit(js_instance.allocator);
            }
            e.children.clearRetainingCapacity();

                for (body_children.items) |child| {
                    try e.children.append(js_instance.allocator, child);
                }

                e.children_dirty = true;

                if (e.owned_strings == null) {
                    e.owned_strings = std.ArrayList([]const u8).empty;
                }
            try e.owned_strings.?.append(js_instance.allocator, wrapped_html);
            wrapped_cleanup = false;

            parser.fixParentPointers(node, e.parent);

            js_instance.requestRender();

            return .undefined;
        },
        .text => {
            // Text nodes can't have innerHTML
            return agent.throwException(
                .type_error,
                "Text nodes do not support innerHTML",
                .{},
            );
        },
    }
}

/// __native.style_set implementation
fn styleSet(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    _ = this_value;

    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(
            .type_error,
            "style_set requires a numeric handle as first argument",
            .{},
        );
    }

    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());

    const node = js_instance.getNode(window, handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );

    const style_arg = arguments.get(1);
    if (!style_arg.isString()) {
        return agent.throwException(
            .type_error,
            "style_set requires a string as second argument",
            .{},
        );
    }

    const style_str = try style_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(style_str);

    switch (node.*) {
        .element => |*e| {
            if (e.attributes == null) {
                e.attributes = std.StringHashMap([]const u8).init(js_instance.allocator);
            }

            // Get old opacity value for transition detection
            var old_opacity: ?f64 = null;
            if (e.style) |*style_field| {
                if (style_field.get().get("opacity")) |op_str| {
                    old_opacity = std.fmt.parseFloat(f64, op_str) catch null;
                }
            }

            const owned_style = try js_instance.allocator.dupe(u8, style_str);
            if (e.owned_strings == null) {
                e.owned_strings = std.ArrayList([]const u8).empty;
            }
            try e.owned_strings.?.append(js_instance.allocator, owned_style);
            try e.attributes.?.put("style", owned_style);

            // Parse new style to check for opacity changes and transitions
            const style_result = parseInlineStyle(js_instance.allocator, style_str);
            if (style_result) |ns| {
                var new_style = ns;
                defer new_style.deinit();

                // Check for transition definition
                if (new_style.get("transition")) |transition_str| {
                    // Parse transition value (e.g., "opacity 2s")
                    if (parseTransitionValue(transition_str)) |transition| {
                        if (std.mem.eql(u8, transition.property, "opacity")) {
                            // Get new opacity value
                            if (new_style.get("opacity")) |new_op_str| {
                                const new_opacity = std.fmt.parseFloat(f64, new_op_str) catch null;
                                if (new_opacity != null and old_opacity != null and old_opacity.? != new_opacity.?) {
                                    // Start animation from old to new value
                                    startOpacityAnimation(js_instance.allocator, e, old_opacity.?, new_opacity.?, transition.frames) catch |err| {
                                        std.log.warn("Failed to start opacity animation: {}", .{err});
                                    };
                                }
                            }
                        }
                    }
                }
            } else |_| {}

            if (e.style) |*style_field| {
                style_field.mark();
            }

            js_instance.requestRender();

            return .undefined;
        },
        .text => {
            return agent.throwException(
                .type_error,
                "Text nodes do not support style",
                .{},
            );
        },
    }
}

/// __native.xhrSend implementation
fn xhrSend(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    _ = this_value;

    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    const callback = window.xhr_callback.function orelse
        return agent.throwException(.type_error, "XMLHttpRequest is not available", .{});
    const callback_context = window.xhr_callback.context;

    const method_arg = arguments.get(0);
    if (!method_arg.isString()) {
        return agent.throwException(.type_error, "XMLHttpRequest method must be a string", .{});
    }
    const method_slice = try method_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(method_slice);

    const url_arg = arguments.get(1);
    if (!url_arg.isString()) {
        return agent.throwException(.type_error, "XMLHttpRequest URL must be a string", .{});
    }
    const url_slice = try url_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(url_slice);

    var owned_body_slice: ?[]const u8 = null;
    if (arguments.count() >= 3) {
        const body_arg = arguments.get(2);
        if (!body_arg.isUndefined() and !body_arg.isNull()) {
            if (!body_arg.isString()) {
                return agent.throwException(.type_error, "XMLHttpRequest body must be a string", .{});
            }
            owned_body_slice = try body_arg.asString().toUtf8(js_instance.allocator);
        }
    }
    defer if (owned_body_slice) |slice| js_instance.allocator.free(slice);

    const payload = owned_body_slice;

    const is_async = if (arguments.count() >= 4)
        arguments.get(3).toBoolean()
    else
        false;

    if (arguments.count() < 5) {
        return agent.throwException(.type_error, "XMLHttpRequest handle missing", .{});
    }
    const handle_arg = arguments.get(4);
    if (!handle_arg.isNumber()) {
        return agent.throwException(.type_error, "XMLHttpRequest handle must be numeric", .{});
    }
    const raw_handle = handle_arg.asNumber().asFloat();
    if (std.math.isNan(raw_handle)) {
        return agent.throwException(.type_error, "Invalid XMLHttpRequest handle", .{});
    }
    const handle: u32 = @intFromFloat(raw_handle);

    const result = callback(callback_context, method_slice, url_slice, payload, is_async, handle) catch |err| {
        if (err == error.CrossOriginBlocked) {
            return agent.throwException(.type_error, "Cross-origin XMLHttpRequest not allowed", .{});
        }
        if (err == error.CspViolation) {
            return agent.throwException(.type_error, "XMLHttpRequest blocked by Content-Security-Policy", .{});
        }
        std.log.err("XMLHttpRequest failed: {}", .{err});
        return agent.throwException(.type_error, "XMLHttpRequest failed", .{});
    };

    if (is_async) {
        return .undefined;
    }

    const js_string = try kiesel.types.String.fromUtf8(agent, result.data);

    if (result.should_free) {
        if (result.allocator) |alloc| {
            alloc.free(result.data);
        } else {
            js_instance.allocator.free(result.data);
        }
    }

    return Value.from(js_string);
}

fn setTimeoutNative(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    _ = this_value;

    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(
            .type_error,
            "setTimeout requires a numeric handle",
            .{},
        );
    }

    const raw_handle = handle_arg.asNumber().asFloat();
    if (std.math.isNan(raw_handle)) {
        return agent.throwException(
            .type_error,
            "setTimeout handle must be a valid number",
            .{},
        );
    }
    const handle: u32 = @intFromFloat(raw_handle);

    var delay_ms: u32 = 0;
    if (arguments.count() >= 2) {
        const delay_arg = arguments.get(1);
        if (delay_arg.isNumber()) {
            const delay_float = delay_arg.asNumber().asFloat();
            if (!std.math.isNan(delay_float) and delay_float > 0) {
                const max_delay = @as(f64, @floatFromInt(std.math.maxInt(u32)));
                const clamped = @min(delay_float, max_delay);
                delay_ms = @intFromFloat(clamped);
            }
        }
    }

    if (window.set_timeout_callback.function) |callback| {
        const callback_context = window.set_timeout_callback.context;
        callback(callback_context, handle, delay_ms) catch |err| {
            std.log.warn("Failed to schedule setTimeout callback: {}", .{err});
        };
    }

    return .undefined;
}

fn requestAnimationFrameNative(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    _ = this_value;
    _ = arguments;

    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    if (window.animation_frame_callback.function) |callback| {
        const callback_context = window.animation_frame_callback.context;
        callback(callback_context) catch |err| {
            std.log.warn("Failed to schedule animation frame: {}", .{err});
        };
    }

    return .undefined;
}

fn getWindowIdNative(agent: *Agent, this_value: Value, _: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    _ = this_value;

    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    return Value.from(@as(f64, @floatFromInt(window_id)));
}

fn getParentWindowIdNative(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    _ = this_value;

    const id_arg = arguments.get(0);
    if (!id_arg.isNumber()) {
        return agent.throwException(.type_error, "getParentWindowId requires a numeric window id", .{});
    }

    const raw_id = id_arg.asNumber().asFloat();
    if (std.math.isNan(raw_id)) {
        return agent.throwException(.type_error, "getParentWindowId requires a valid window id", .{});
    }
    const window_id = @as(u32, @intFromFloat(raw_id));
    const parent_id = js_instance.parent_window_ids.get(window_id) orelse return .null;
    if (!js_instance.windows.contains(parent_id)) {
        return .null;
    }
    return Value.from(@as(f64, @floatFromInt(parent_id)));
}

fn postMessageNative(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    _ = this_value;

    const window_id = js_instance.current_window_id orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const window = js_instance.windows.getPtr(window_id) orelse return agent.throwException(
        .internal_error,
        "Missing window context",
        .{},
    );

    const message_arg = arguments.get(0);
    const target_id_arg = arguments.get(1);
    const target_origin_arg = arguments.get(2);

    if (!target_id_arg.isNumber()) {
        return agent.throwException(.type_error, "postMessage requires a numeric target window id", .{});
    }
    if (!target_origin_arg.isString()) {
        return agent.throwException(.type_error, "postMessage requires a string target origin", .{});
    }

    const message_str = try message_arg.toString(&js_instance.agent);
    const message = try message_str.toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(message);

    const target_origin = try target_origin_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(target_origin);

    const raw_target_id = target_id_arg.asNumber().asFloat();
    if (std.math.isNan(raw_target_id)) {
        return agent.throwException(.type_error, "postMessage requires a valid target window id", .{});
    }
    const target_window_id = @as(u32, @intFromFloat(raw_target_id));

    if (window.post_message_callback.function) |callback| {
        const ctx = window.post_message_callback.context;
        callback(ctx, window_id, target_window_id, target_origin, message) catch |err| {
            return agent.throwException(.internal_error, "postMessage failed: {any}", .{err});
        };
    }

    return .undefined;
}

/// Escape a string for safe embedding in JavaScript source
fn quoteJsString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try builder.append(allocator, '"');
    for (input) |ch| {
        switch (ch) {
            '\\' => {
                try builder.appendSlice(allocator, "\\\\");
            },
            '"' => {
                try builder.appendSlice(allocator, "\\\"");
            },
            '\n' => {
                try builder.appendSlice(allocator, "\\n");
            },
            '\r' => {
                try builder.appendSlice(allocator, "\\r");
            },
            '\t' => {
                try builder.appendSlice(allocator, "\\t");
            },
            else => try builder.append(allocator, ch),
        }
    }
    try builder.append(allocator, '"');

    return builder.toOwnedSlice();
}
