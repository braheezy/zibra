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

const Js = @This();

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

platform: Agent.Platform,
agent: Agent,
realm: *Realm,
allocator: std.mem.Allocator,
// Handle management for DOM nodes
node_to_handle: std.AutoHashMap(*Node, u32),
handle_to_node: std.AutoHashMap(u32, *Node),
next_handle: u32,
// Reference to the current tab's nodes (borrowed, not owned)
current_nodes: ?*Node,
render_callback: RenderCallback,
set_timeout_callback: SetTimeoutCallback,
xhr_callback: XhrCallback,
animation_frame_callback: AnimationFrameCallback,

pub fn init(allocator: std.mem.Allocator) !*Js {
    const self = try allocator.create(Js);
    errdefer allocator.destroy(self);

    // Initialize platform first
    self.platform = Agent.Platform.default();

    // Then initialize agent with a pointer to the platform that's now in the struct
    self.agent = try Agent.init(&self.platform, .{});
    errdefer self.agent.deinit();

    // Initialize the realm
    try Realm.initializeHostDefinedRealm(&self.agent, .{});

    // Get the current realm
    self.realm = self.agent.currentRealm();

    // Initialize handle management
    self.allocator = allocator;
    self.node_to_handle = std.AutoHashMap(*Node, u32).init(allocator);
    self.handle_to_node = std.AutoHashMap(u32, *Node).init(allocator);
    self.next_handle = 0;
    self.current_nodes = null;
    self.render_callback = .{};
    self.set_timeout_callback = .{};
    self.xhr_callback = .{};
    self.animation_frame_callback = .{};

    // Set up console.log
    try self.setupConsole();

    // Set up document object with DOM API
    try self.setupDocument();

    return self;
}

/// Set up the console object with log function
fn setupConsole(self: *Js) !void {
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
        self.realm,
    );

    // Add console to global object
    try self.realm.global_object.definePropertyDirect(
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
    self.node_to_handle.deinit();
    self.handle_to_node.deinit();
    self.platform.deinit();
    self.agent.deinit();
    allocator.destroy(self);
}

pub fn evaluate(self: *Js, code: []const u8) !Value {
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
        \\globalThis.__resetEventListeners = function() {
        \\  LISTENERS = {};
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

    // First evaluate the runtime code if this is the first evaluation
    // We check if Node is already defined to avoid re-injecting
    const check_script = try Script.parse(
        "typeof Node !== 'undefined'",
        self.realm,
        null,
        .{},
    );
    const is_defined = try check_script.evaluate();

    if (!is_defined.toBoolean()) {
        const runtime_script = try Script.parse(
            runtime_code,
            self.realm,
            null,
            .{},
        );
        _ = try runtime_script.evaluate();
    }

    // Now evaluate the user's code
    const script = try Script.parse(
        code,
        self.realm,
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
pub fn setNodes(self: *Js, nodes: ?*Node) void {
    self.current_nodes = nodes;
    // Clear handle mappings when nodes change
    self.node_to_handle.clearRetainingCapacity();
    self.handle_to_node.clearRetainingCapacity();
    self.next_handle = 0;
    // Reset JavaScript-side listener state when the DOM changes
    self.resetEventListenersImpl();
    if (nodes == null) {
        self.render_callback = .{};
        self.xhr_callback = .{};
        self.set_timeout_callback = .{};
        self.animation_frame_callback = .{};
    }
}

pub fn setRenderCallback(self: *Js, callback: ?RenderCallbackFn, context: ?*anyopaque) void {
    self.render_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setXhrCallback(self: *Js, callback: ?XhrCallbackFn, context: ?*anyopaque) void {
    self.xhr_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setSetTimeoutCallback(self: *Js, callback: ?SetTimeoutCallbackFn, context: ?*anyopaque) void {
    self.set_timeout_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setAnimationFrameCallback(self: *Js, callback: ?AnimationFrameCallbackFn, context: ?*anyopaque) void {
    self.animation_frame_callback = .{
        .function = callback,
        .context = context,
    };
}

/// Get or create a handle for a node
fn getHandle(self: *Js, node: *Node) !u32 {
    if (self.node_to_handle.get(node)) |handle| {
        return handle;
    }

    const handle = self.next_handle;
    self.next_handle += 1;

    try self.node_to_handle.put(node, handle);
    try self.handle_to_node.put(handle, node);

    return handle;
}

/// Get a node from a handle
fn getNode(self: *Js, handle: u32) ?*Node {
    return self.handle_to_node.get(handle);
}

fn requestRender(self: *Js) void {
    if (self.render_callback.function) |callback| {
        const context = self.render_callback.context orelse return;
        callback(context) catch |err| {
            std.log.warn("Render callback failed: {}", .{err});
        };
    }
}

/// Dispatch an event to the JavaScript environment for the given node
/// Returns true if the default action was prevented.
pub fn dispatchEvent(self: *Js, event_type: []const u8, node: *Node) !bool {
    if (self.current_nodes == null) return false;

    const handle = try self.getHandle(node);

    const type_value = try kiesel.types.String.fromUtf8(&self.agent, event_type);
    const type_js_value = Value.from(type_value);
    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));

    const dispatch_key = kiesel.types.PropertyKey.from("__native");
    const native_value = try self.realm.global_object.get(&self.agent, dispatch_key);
    if (!native_value.isObject()) return false;
    const native_obj = native_value.asObject();
    const dispatch_property = kiesel.types.PropertyKey.from("dispatchEvent");
    const dispatch_value = try native_obj.internal_methods.get(
        &self.agent,
        native_obj,
        dispatch_property,
        native_value,
    );

    if (!dispatch_value.isCallable()) return false;

    const result = try dispatch_value.call(&self.agent, .undefined, &.{ handle_value, type_js_value });
    const do_default = result.toBoolean();
    return !do_default;
}

pub fn runTimeoutCallback(self: *Js, handle: u32) !void {
    const key = kiesel.types.PropertyKey.from("__runSetTimeout");
    const fn_value = self.realm.global_object.get(&self.agent, key) catch {
        return error.MissingSetTimeout;
    };
    if (!fn_value.isCallable()) {
        return error.MissingSetTimeout;
    }
    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
    _ = try fn_value.call(&self.agent, .undefined, &.{ handle_value });
}

pub fn runAnimationFrameHandlers(self: *Js) void {
    const key = kiesel.types.PropertyKey.from("__runRAFHandlers");
    const fn_value = self.realm.global_object.get(&self.agent, key) catch return;
    if (!fn_value.isCallable()) return;
    _ = fn_value.call(&self.agent, .undefined, &.{}) catch |err| {
        std.log.warn("requestAnimationFrame handler failed: {}", .{err});
    };
}

fn resetEventListenersImpl(self: *Js) void {
    const reset_key = kiesel.types.PropertyKey.from("__resetEventListeners");
    const reset_value = self.realm.global_object.get(&self.agent, reset_key) catch return;
    if (!reset_value.isCallable()) return;
    _ = reset_value.call(&self.agent, .undefined, &.{}) catch return;
}

fn stringToJsValue(self: *Js, text: []const u8) !Value {
    const js_string = try kiesel.types.String.fromUtf8(&self.agent, text);
    return Value.from(js_string);
}

pub fn runXhrOnload(self: *Js, handle: u32, body: []const u8) !void {
    const key = kiesel.types.PropertyKey.from("__runXHROnload");
    const fn_value = try self.realm.global_object.get(&self.agent, key);
    if (!fn_value.isCallable()) return error.MissingXhrCallback;

    const body_value = try self.stringToJsValue(body);
    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
    _ = try fn_value.call(&self.agent, .undefined, &.{ body_value, handle_value });
}

test "Node.prototype.style setter is defined" {
    var js = try Js.init(std.testing.allocator);
    defer js.deinit(std.testing.allocator);

    const result = try js.evaluate("Object.getOwnPropertyDescriptor(Node.prototype, 'style') !== undefined");
    try std.testing.expect(result.toBoolean());
}

test "__native.style_set is exposed" {
    var js = try Js.init(std.testing.allocator);
    defer js.deinit(std.testing.allocator);

    const result = try js.evaluate("typeof __native.style_set === 'function'");
    try std.testing.expect(result.toBoolean());
}

test "native style_set updates element style attribute" {
    var js = try Js.init(std.testing.allocator);
    defer js.deinit(std.testing.allocator);

    const element = try parser.Element.init(std.testing.allocator, "div", null);
    var node = Node{ .element = element };
    defer node.deinit(std.testing.allocator);

    const handle = try js.getHandle(&node);

    const SafePointer = kiesel.types.SafePointer;
    const builtins = kiesel.builtins;
    const self_ptr = SafePointer.make(*Js, js);
    const style_fn = try builtins.createBuiltinFunction(
        &js.agent,
        .{ .function = styleSet },
        2,
        "style_set",
        .{
            .realm = js.realm,
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

    const handle = try js.getHandle(&node);

    var called = false;
    var ctx = RenderTestContext{ .called = &called };
    js.setRenderCallback(renderTestCallback, @ptrCast(&ctx));

    const SafePointer = kiesel.types.SafePointer;
    const builtins = kiesel.builtins;
    const self_ptr = SafePointer.make(*Js, js);
    const style_fn = try builtins.createBuiltinFunction(
        &js.agent,
        .{ .function = styleSet },
        2,
        "style_set",
        .{
            .realm = js.realm,
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
fn setupDocument(self: *Js) !void {
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
            .realm = self.realm,
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
    try self.realm.global_object.definePropertyDirect(
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
            .realm = self.realm,
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

    // Create innerHTML function with self pointer
    const inner_html_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = innerHTML },
        2,
        "innerHTML",
        .{
            .realm = self.realm,
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
            .realm = self.realm,
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
            .realm = self.realm,
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
            .realm = self.realm,
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
            .realm = self.realm,
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

    // Add __native to global
    try self.realm.global_object.definePropertyDirect(
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

    var css_parser = CSSParser.init(js_instance.allocator, selector_str) catch {
        return agent.throwException(.syntax_error, "Invalid selector", .{});
    };
    defer css_parser.deinit(js_instance.allocator);

    var selector = css_parser.selector(js_instance.allocator) catch {
        return agent.throwException(.syntax_error, "Invalid selector", .{});
    };

    if (js_instance.current_nodes == null) {
        const empty_array = try kiesel.builtins.arrayCreate(agent, 0, null);
        return Value.from(&empty_array.object);
    }

    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(js_instance.allocator);
    try parser.treeToList(js_instance.allocator, js_instance.current_nodes.?, &node_list);

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
            const handle = try js_instance.getHandle(node);
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
    const node = js_instance.getNode(handle) orelse return agent.throwException(
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

/// __native.innerHTML implementation (setter only)
fn innerHTML(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    // Get the Js instance from the function's additional_fields
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);

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
    const node = js_instance.getNode(handle) orelse return agent.throwException(
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

    const node = js_instance.getNode(handle) orelse return agent.throwException(
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

            const owned_style = try js_instance.allocator.dupe(u8, style_str);
            if (e.owned_strings == null) {
                e.owned_strings = std.ArrayList([]const u8).empty;
            }
            try e.owned_strings.?.append(js_instance.allocator, owned_style);
            try e.attributes.?.put("style", owned_style);

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

    const callback = js_instance.xhr_callback.function orelse
        return agent.throwException(.type_error, "XMLHttpRequest is not available", .{});
    const callback_context = js_instance.xhr_callback.context;

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

    if (js_instance.set_timeout_callback.function) |callback| {
        const callback_context = js_instance.set_timeout_callback.context;
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

    if (js_instance.animation_frame_callback.function) |callback| {
        const callback_context = js_instance.animation_frame_callback.context;
        callback(callback_context) catch |err| {
            std.log.warn("Failed to schedule animation frame: {}", .{err});
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
