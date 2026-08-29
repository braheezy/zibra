//! Kiesel JavaScript host integration and the minimal DOM-facing Web APIs.
//!
//! A `Js` instance owns Kiesel agent state and per-window handle maps. Kiesel
//! execution is serialized by `JsLock`; DOM pointers and callback contexts are
//! borrowed and must be invalidated before their owning frame is destroyed.

const std = @import("std");
const Mutex = @import("../runtime/sync.zig").Mutex;
const DomHandles = @import("dom_handles.zig").Store;
const dom_mutation = @import("dom_mutation.zig");
const native_bindings = @import("native_bindings.zig");
const canvas_bindings = @import("canvas_bindings.zig");
const event_focus_bindings = @import("event_focus_bindings.zig");
const network_bindings = @import("network_bindings.zig");
const timer_bindings = @import("timer_bindings.zig");

const bdwgc = @import("bdwgc");
const kiesel = @import("kiesel");
const Agent = kiesel.execution.Agent;
const Script = kiesel.language.Script;
const Realm = kiesel.execution.Realm;
const Value = kiesel.types.Value;
const parser = @import("../document/parser.zig");
const Node = parser.Node;
const CSSParser = @import("../document/css_parser.zig").CSSParser;
const PixelAnimation = parser.PixelAnimation;

const Js = @This();

const transitions = @import("transitions.zig");

pub const RenderCallbackFn = *const fn (context: ?*anyopaque) anyerror!void;

const RenderCallback = struct {
    function: ?RenderCallbackFn = null,
    context: ?*anyopaque = null,
};

/// Runs synchronously for an attached, intrinsically focusable element. The
/// numeric handle remains the stable identity if blur listeners relocate DOM
/// children before the browser installs the new focus.
pub const FocusCallbackFn = event_focus_bindings.FocusCallbackFn;

const FocusCallback = struct {
    function: ?FocusCallbackFn = null,
    context: ?*anyopaque = null,
};

/// Runs synchronously before JavaScript changes DOM child storage. Browser
/// embedders use this boundary to retire every snapshot that borrows the
/// current DOM generation before any node can move or be destroyed.
pub const DomMutationKind = dom_mutation.Kind;

pub const DomMutationCallbackFn = *const fn (
    context: ?*anyopaque,
    mutation_root: *Node,
    kind: DomMutationKind,
) void;

const DomMutationCallback = struct {
    function: ?DomMutationCallbackFn = null,
    context: ?*anyopaque = null,
};

/// Runs synchronously after an attached structural mutation has installed its
/// final child storage and repaired parent pointers. Browser embedders use it
/// to rebind or retire native objects whose stable scalar identity moved with
/// a DOM Element; it must not start network work while Kiesel is active.
pub const DomMutationCompleteCallbackFn = *const fn (
    context: ?*anyopaque,
    mutation_root: *Node,
) void;

const DomMutationCompleteCallback = struct {
    function: ?DomMutationCompleteCallbackFn = null,
    context: ?*anyopaque = null,
};

pub const AnimationFrameCallbackFn = timer_bindings.AnimationFrameCallbackFn;

const AnimationFrameCallback = struct {
    function: ?AnimationFrameCallbackFn = null,
    context: ?*anyopaque = null,
};

pub const SetTimeoutCallbackFn = timer_bindings.SetTimeoutCallbackFn;
pub const ClearIntervalCallbackFn = timer_bindings.ClearIntervalCallbackFn;

const SetTimeoutCallback = struct {
    function: ?SetTimeoutCallbackFn = null,
    context: ?*anyopaque = null,
};

const JsLock = struct {
    mutex: Mutex,
    owner: ?std.Thread.Id = null,
    depth: usize = 0,

    fn init(io: std.Io) JsLock {
        return .{ .mutex = .init(io) };
    }

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

pub const PostMessageCallbackFn = network_bindings.PostMessageCallbackFn;

const PostMessageCallback = struct {
    function: ?PostMessageCallbackFn = null,
    context: ?*anyopaque = null,
};

pub const XhrResult = network_bindings.XhrResult;
pub const XhrCallbackFn = network_bindings.XhrCallbackFn;

const XhrCallback = struct {
    function: ?XhrCallbackFn = null,
    context: ?*anyopaque = null,
};

pub const CookieResult = network_bindings.CookieResult;
pub const CookieGetCallbackFn = network_bindings.CookieGetCallbackFn;
pub const CookieSetCallbackFn = network_bindings.CookieSetCallbackFn;

const CookieCallback = struct {
    get_function: ?CookieGetCallbackFn = null,
    set_function: ?CookieSetCallbackFn = null,
    context: ?*anyopaque = null,
};

const PendingMessage = struct {
    message: []u8,
    origin: []u8,
    source_window_id: u32,
};

const WindowContext = struct {
    realm: *Realm,
    handles: DomHandles,
    // Heap-stable owners for createElement results and removeChild subtrees
    // that have not yet been transferred into a DOM child array.
    detached_nodes: std.AutoHashMap(*Node, void),
    current_nodes: ?*Node,
    // The shared Kiesel realm exposes named element globals for only the
    // active window. This records whether the JavaScript-side per-window
    // registry reflects current_nodes.
    named_globals_synced: bool,
    pending_messages: std.ArrayList(PendingMessage),
    render_callback: RenderCallback,
    focus_callback: FocusCallback,
    dom_mutation_callback: DomMutationCallback,
    dom_mutation_complete_callback: DomMutationCompleteCallback,
    set_timeout_callback: SetTimeoutCallback,
    clear_interval_callback: struct {
        function: ?ClearIntervalCallbackFn = null,
        context: ?*anyopaque = null,
    },
    post_message_callback: PostMessageCallback,
    xhr_callback: XhrCallback,
    cookie_callback: CookieCallback,
    animation_frame_callback: AnimationFrameCallback,
};

platform: Agent.Platform,
agent: Agent,
allocator: std.mem.Allocator,
io: std.Io,
storage_allocator: std.mem.Allocator,
// Kiesel retains pointers to these narrow interfaces for the lifetime of the
// shared realm. `Js` itself is heap-stable and outlives every native function.
canvas_host: canvas_bindings.Host,
event_focus_host: event_focus_bindings.Host,
network_host: network_bindings.Host,
timer_host: timer_bindings.Host,
windows: std.AutoHashMap(u32, WindowContext),
parent_window_ids: std.AutoHashMap(u32, u32),
current_window_id: ?u32 = null,
lock: JsLock,
realm: ?*Realm = null,
runtime_initialized: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !*Js {
    // Agent is embedded in Js, so Js must live in memory scanned by Kiesel's
    // collector. The caller's arena is not a GC root and previously allowed
    // Agent-owned realms and string-cache storage to be reclaimed.
    if (kiesel.build_options.enable_libgc) kiesel.gc.init();
    const storage_allocator = if (kiesel.build_options.enable_libgc)
        bdwgc.allocator_uncollectable
    else
        allocator;
    const self = try storage_allocator.create(Js);
    errdefer storage_allocator.destroy(self);

    // Initialize platform first
    self.platform = Agent.Platform.default(io, environ);

    // Then initialize agent with a pointer to the platform that's now in the struct
    self.agent = try Agent.init(allocator, io, &self.platform, .{});
    errdefer self.agent.deinit();

    self.allocator = allocator;
    self.io = io;
    self.storage_allocator = storage_allocator;
    self.canvas_host = .{
        .context = self,
        .allocator = allocator,
        .io = io,
        .resolve_element = resolveCanvasBindingElement,
        .request_render = requestBindingRender,
    };
    self.event_focus_host = .{
        .context = self,
        .active_window = activeEventFocusWindow,
    };
    self.network_host = .{
        .context = self,
        .allocator = allocator,
        .current_window_id = currentBindingWindowId,
        .parent_window_id = parentBindingWindowId,
        .cookie_get = getBindingCookie,
        .cookie_set = setBindingCookie,
        .xhr_send = sendBindingXhr,
        .post_message = sendBindingPostMessage,
    };
    self.timer_host = .{
        .context = self,
        .schedule = scheduleBindingTimer,
        .clear = clearBindingTimer,
        .request_animation_frame = requestBindingAnimationFrame,
    };
    self.windows = std.AutoHashMap(u32, WindowContext).init(allocator);
    self.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    self.current_window_id = null;
    self.lock = .init(io);
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
        .handles = DomHandles.init(self.allocator),
        .detached_nodes = std.AutoHashMap(*Node, void).init(self.allocator),
        .current_nodes = null,
        .named_globals_synced = false,
        .pending_messages = std.ArrayList(PendingMessage).empty,
        .render_callback = .{},
        .focus_callback = .{},
        .dom_mutation_callback = .{},
        .dom_mutation_complete_callback = .{},
        .set_timeout_callback = .{},
        .clear_interval_callback = .{},
        .post_message_callback = .{},
        .xhr_callback = .{},
        .cookie_callback = .{},
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
    _ = allocator;
    self.lock.lock();
    var it = self.windows.valueIterator();
    while (it.next()) |window| {
        self.clearDetachedNodes(window);
        window.handles.deinit();
        window.detached_nodes.deinit();
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
    const storage_allocator = self.storage_allocator;
    self.lock.unlock();
    storage_allocator.destroy(self);
}

/// Install a host callback that can stop long-running JavaScript at Kiesel VM
/// safe points. The callback runs on the JavaScript execution thread.
pub fn setInterruptHandler(
    self: *Js,
    context: ?*anyopaque,
    handler: Agent.InterruptHandler,
) void {
    self.agent.setInterruptHandler(context, handler);
}

fn translateExecutionError(self: *Js, err: Agent.Error) anyerror {
    if (err == error.ExceptionThrown and self.agent.takeExecutionInterrupt()) {
        return error.ExecutionInterrupted;
    }
    return err;
}

pub fn evaluate(self: *Js, window_id: u32, code: []const u8) !Value {
    self.lock.lock();
    defer self.lock.unlock();
    const window = try self.setCurrentWindow(window_id);
    const runtime_code = @embedFile("runtime/bootstrap.js");

    if (!self.runtime_initialized) {
        const runtime_script = try Script.parse(
            runtime_code,
            window.realm,
            null,
            .{},
        );
        _ = runtime_script.evaluate("zibra-runtime") catch |err| {
            return self.translateExecutionError(err);
        };
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
    if (!window.named_globals_synced) try self.syncNamedIdGlobals(window_id, window);

    // Now evaluate the user's code
    const script = try Script.parse(
        code,
        window.realm,
        null,
        .{},
    );
    const result = script.evaluate("zibra-script") catch |err| {
        return self.translateExecutionError(err);
    };
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
    if (nodes != null) {
        self.clearNamedIdGlobals(window_id, window) catch |err| {
            std.log.warn("Failed to clear named element globals: {}", .{err});
        };
    } else {
        // Shutdown/navigation invalidation can run outside the tab worker.
        // Do not re-enter Kiesel here: clearing the native handle maps below
        // makes every retained numeric Node wrapper inert, and a subsequent
        // non-null install clears the JavaScript registry before reuse.
        window.named_globals_synced = false;
    }
    self.clearDetachedNodes(window);
    window.current_nodes = nodes;
    // Clear handle mappings when nodes change
    window.handles.clear();
    if (nodes == null) {
        window.render_callback = .{};
        window.focus_callback = .{};
        window.dom_mutation_callback = .{};
        window.dom_mutation_complete_callback = .{};
        window.xhr_callback = .{};
        window.cookie_callback = .{};
        window.set_timeout_callback = .{};
        window.clear_interval_callback = .{};
        window.post_message_callback = .{};
        window.animation_frame_callback = .{};
    } else {
        // Reset JavaScript-side listener state when the DOM changes.
        self.resetEventListenersImpl(window, window_id);
        self.syncNamedIdGlobals(window_id, window) catch |err| {
            std.log.warn("Failed to publish named element globals: {}", .{err});
        };
    }
}

pub fn setRenderCallback(self: *Js, window_id: u32, callback: ?RenderCallbackFn, context: ?*anyopaque) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.render_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setFocusCallback(self: *Js, window_id: u32, callback: ?FocusCallbackFn, context: ?*anyopaque) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.focus_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setDomMutationCallback(self: *Js, window_id: u32, callback: ?DomMutationCallbackFn, context: ?*anyopaque) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.dom_mutation_callback = .{
        .function = callback,
        .context = context,
    };
}

pub fn setDomMutationCompleteCallback(
    self: *Js,
    window_id: u32,
    callback: ?DomMutationCompleteCallbackFn,
    context: ?*anyopaque,
) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.dom_mutation_complete_callback = .{
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

pub fn setCookieCallbacks(
    self: *Js,
    window_id: u32,
    get_callback: ?CookieGetCallbackFn,
    set_callback: ?CookieSetCallbackFn,
    context: ?*anyopaque,
) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.cookie_callback = .{
        .get_function = get_callback,
        .set_function = set_callback,
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

pub fn setClearIntervalCallback(
    self: *Js,
    window_id: u32,
    callback: ?ClearIntervalCallbackFn,
    context: ?*anyopaque,
) void {
    const window = self.setCurrentWindow(window_id) catch return;
    window.clear_interval_callback = .{
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

/// Publish a stable numeric identity in this window's current DOM generation.
fn getHandle(self: *Js, window: *WindowContext, node: *Node) !u32 {
    _ = self;
    return window.handles.getOrCreate(node);
}

/// Resolve a handle without asserting that its Node remains attached.
fn getNode(self: *Js, window: *WindowContext, handle: u32) ?*Node {
    _ = self;
    return window.handles.resolve(handle);
}

const NamedElement = struct {
    name: []const u8,
    node: *Node,
};

/// Collect the first element for each non-empty ID in document order. HTML
/// permits duplicate IDs even though pages should avoid them; named access
/// follows the same first-match behavior as a document lookup.
fn collectNamedElements(
    self: *Js,
    node: *Node,
    seen: *std.StringHashMap(void),
    named: *std.ArrayList(NamedElement),
) !void {
    switch (node.*) {
        .text => {},
        .element => |*element| {
            if (element.attributes) |attributes| {
                if (attributes.get("id")) |id| {
                    if (id.len != 0 and !seen.contains(id)) {
                        try seen.put(id, {});
                        try named.append(self.allocator, .{ .name = id, .node = node });
                    }
                }
            }
            for (element.children.items) |*child| {
                try self.collectNamedElements(child, seen, named);
            }
        },
    }
}

/// Replace one window's JavaScript-side ID registry with wrappers for its
/// current DOM generation. Only the active window's registry is installed on
/// globalThis; __setActiveWindow swaps registries when realms are activated.
fn syncNamedIdGlobals(self: *Js, window_id: u32, window: *WindowContext) Agent.Error!void {
    if (!self.runtime_initialized) {
        window.named_globals_synced = false;
        return;
    }

    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var named = std.ArrayList(NamedElement).empty;
    defer named.deinit(self.allocator);
    if (window.current_nodes) |root| {
        try self.collectNamedElements(root, &seen, &named);
    }

    const names = try kiesel.builtins.arrayCreate(&self.agent, @intCast(named.items.len), null);
    const handles = try kiesel.builtins.arrayCreate(&self.agent, @intCast(named.items.len), null);
    for (named.items, 0..) |entry, index| {
        const property_key = kiesel.types.PropertyKey.from(
            @as(kiesel.types.PropertyKey.IntegerIndex, @intCast(index)),
        );
        try names.object.createDataPropertyDirect(
            &self.agent,
            property_key,
            try self.stringToJsValue(entry.name),
        );
        const handle = try self.getHandle(window, entry.node);
        try handles.object.createDataPropertyDirect(
            &self.agent,
            property_key,
            Value.from(@as(f64, @floatFromInt(handle))),
        );
    }

    const key = kiesel.types.PropertyKey.from("__setIdGlobals");
    const fn_value = try window.realm.global_object.get(&self.agent, key);
    if (!fn_value.isCallable()) return;
    const window_value = Value.from(@as(f64, @floatFromInt(window_id)));
    _ = try fn_value.call(
        &self.agent,
        .undefined,
        &.{ window_value, Value.from(&names.object), Value.from(&handles.object) },
    );
    window.named_globals_synced = true;
}

fn clearNamedIdGlobals(self: *Js, window_id: u32, window: *WindowContext) Agent.Error!void {
    window.named_globals_synced = false;
    if (!self.runtime_initialized) return;
    const key = kiesel.types.PropertyKey.from("__clearIdGlobals");
    const fn_value = try window.realm.global_object.get(&self.agent, key);
    if (!fn_value.isCallable()) return;
    const window_value = Value.from(@as(f64, @floatFromInt(window_id)));
    _ = try fn_value.call(&self.agent, .undefined, &.{window_value});
}

fn clearDetachedNodes(self: *Js, window: *WindowContext) void {
    var it = window.detached_nodes.keyIterator();
    while (it.next()) |node_ptr| {
        const node = node_ptr.*;
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    window.detached_nodes.clearRetainingCapacity();
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

fn hostFromBindingContext(context: ?*anyopaque) *Js {
    return @ptrCast(@alignCast(context.?));
}

/// Native binding adapters run synchronously with `JsLock` already held. They
/// expose only current-window scalars or short-lived Element borrows to the
/// domain modules and never recursively enter a lock-taking public API.
fn resolveCanvasBindingElement(context: ?*anyopaque, handle: u32) ?*parser.Element {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return null;
    const window = self.windows.getPtr(window_id) orelse return null;
    const node = window.handles.resolve(handle) orelse return null;
    return switch (node.*) {
        .element => |*element| element,
        .text => null,
    };
}

fn activeEventFocusWindow(context: ?*anyopaque) ?event_focus_bindings.WindowBorrow {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return null;
    const window = self.windows.getPtr(window_id) orelse return null;
    return .{
        .current_nodes = window.current_nodes,
        .handles = &window.handles,
        .focus_context = window.focus_callback.context,
        .focus = window.focus_callback.function,
    };
}

fn requestBindingRender(context: ?*anyopaque) void {
    hostFromBindingContext(context).requestRender();
}

fn currentBindingWindowId(context: ?*anyopaque) ?u32 {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return null;
    if (!self.windows.contains(window_id)) return null;
    return window_id;
}

fn parentBindingWindowId(context: ?*anyopaque, window_id: u32) ?u32 {
    return hostFromBindingContext(context).parent_window_ids.get(window_id);
}

fn getBindingCookie(context: ?*anyopaque) anyerror!CookieResult {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return error.MissingActiveWindow;
    const window = self.windows.getPtr(window_id) orelse return error.MissingWindowContext;
    const callback = window.cookie_callback.get_function orelse return .{ .data = "" };
    return callback(window.cookie_callback.context);
}

fn setBindingCookie(context: ?*anyopaque, value: []const u8) anyerror!void {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return error.MissingActiveWindow;
    const window = self.windows.getPtr(window_id) orelse return error.MissingWindowContext;
    const callback = window.cookie_callback.set_function orelse return;
    try callback(window.cookie_callback.context, value);
}

fn sendBindingXhr(
    context: ?*anyopaque,
    method: []const u8,
    url: []const u8,
    body: ?[]const u8,
    is_async: bool,
    handle: u32,
) anyerror!XhrResult {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return error.MissingActiveWindow;
    const window = self.windows.getPtr(window_id) orelse return error.MissingWindowContext;
    const callback = window.xhr_callback.function orelse return error.XmlHttpRequestUnavailable;
    return callback(window.xhr_callback.context, method, url, body, is_async, handle);
}

fn sendBindingPostMessage(
    context: ?*anyopaque,
    source_window_id: u32,
    target_window_id: u32,
    target_origin: []const u8,
    message: []const u8,
) anyerror!void {
    const self = hostFromBindingContext(context);
    const window = self.windows.getPtr(source_window_id) orelse return error.MissingWindowContext;
    const callback = window.post_message_callback.function orelse return;
    try callback(
        window.post_message_callback.context,
        source_window_id,
        target_window_id,
        target_origin,
        message,
    );
}

fn scheduleBindingTimer(
    context: ?*anyopaque,
    handle: u32,
    delay_ms: u32,
    is_interval: bool,
) anyerror!void {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return error.MissingActiveWindow;
    const window = self.windows.getPtr(window_id) orelse return error.MissingWindowContext;
    const callback = window.set_timeout_callback.function orelse return;
    try callback(window.set_timeout_callback.context, handle, delay_ms, is_interval);
}

fn clearBindingTimer(context: ?*anyopaque, handle: u32) void {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return;
    const window = self.windows.getPtr(window_id) orelse return;
    const callback = window.clear_interval_callback.function orelse return;
    callback(window.clear_interval_callback.context, handle);
}

fn requestBindingAnimationFrame(context: ?*anyopaque) anyerror!void {
    const self = hostFromBindingContext(context);
    const window_id = self.current_window_id orelse return error.MissingActiveWindow;
    const window = self.windows.getPtr(window_id) orelse return error.MissingWindowContext;
    const callback = window.animation_frame_callback.function orelse return;
    try callback(window.animation_frame_callback.context);
}

fn domMutationContext(
    self: *Js,
    window_id: u32,
    window: *WindowContext,
) dom_mutation.Context {
    return .{
        .allocator = self.allocator,
        .window_id = window_id,
        .current_nodes = window.current_nodes,
        .handles = &window.handles,
        .detached_nodes = &window.detached_nodes,
        .can_retain_layout_insert = window.dom_mutation_callback.function != null,
        .host_context = self,
        .hooks = .{
            .prepare = prepareDomMutation,
            .complete = completeDomMutation,
            .clear_named = clearDomMutationGlobals,
            .sync_named = syncDomMutationGlobals,
            .request_render = requestDomMutationRender,
        },
    };
}

fn hostFromMutationContext(context: ?*anyopaque) *Js {
    return @ptrCast(@alignCast(context.?));
}

fn prepareDomMutation(context: ?*anyopaque, mutation_root: *Node, kind: DomMutationKind) void {
    const self = hostFromMutationContext(context);
    const window_id = self.current_window_id orelse return;
    const window = self.windows.getPtr(window_id) orelse return;
    if (kind == .structural) {
        if (window.current_nodes) |root| parser.clearStyleInvalidations(root);
    }
    if (window.dom_mutation_callback.function) |callback| {
        callback(window.dom_mutation_callback.context, mutation_root, kind);
    }
}

fn completeDomMutation(context: ?*anyopaque, mutation_root: *Node) void {
    const self = hostFromMutationContext(context);
    const window_id = self.current_window_id orelse return;
    const window = self.windows.getPtr(window_id) orelse return;
    if (window.dom_mutation_complete_callback.function) |callback| {
        // Retiring a same-origin child Frame clears that child's window in the
        // shared Js host and temporarily changes current_window_id. The native
        // DOM call and the remainder of its script still belong to the
        // mutating parent window, so restore it before returning to Kiesel.
        defer self.current_window_id = window_id;
        callback(window.dom_mutation_complete_callback.context, mutation_root);
    }
}

fn clearDomMutationGlobals(context: ?*anyopaque, window_id: u32) Agent.Error!void {
    const self = hostFromMutationContext(context);
    const window = self.windows.getPtr(window_id) orelse return;
    try self.clearNamedIdGlobals(window_id, window);
}

fn syncDomMutationGlobals(context: ?*anyopaque, window_id: u32) Agent.Error!void {
    const self = hostFromMutationContext(context);
    const window = self.windows.getPtr(window_id) orelse return;
    try self.syncNamedIdGlobals(window_id, window);
}

fn requestDomMutationRender(context: ?*anyopaque) void {
    hostFromMutationContext(context).requestRender();
}

/// Dispatch an event to the JavaScript environment for the given node
/// Returns true if the default action should proceed.
pub fn dispatchEvent(self: *Js, window_id: u32, event_type: []const u8, node: *Node) !bool {
    return self.dispatchEventWithBubbles(window_id, event_type, node, true);
}

/// Dispatch a browser-generated DOM event. Click/key/form events bubble;
/// focus and blur use this seam with `bubbles=false`, matching their DOM
/// semantics while retaining the same stable-handle event machinery.
pub fn dispatchEventWithBubbles(
    self: *Js,
    window_id: u32,
    event_type: []const u8,
    node: *Node,
    bubbles: bool,
) !bool {
    self.lock.lock();
    defer self.lock.unlock();
    return self.dispatchEventWithBubblesLocked(
        window_id,
        event_type,
        node,
        bubbles,
        true,
    );
}

/// Dispatch while a native JavaScript host callback is already running under
/// this Js instance's lock. Calling the ordinary public dispatcher from that
/// boundary would recursively acquire the non-recursive mutex and deadlock.
/// The current realm was installed by the outer JavaScript entry point, so a
/// callback may only dispatch into that same window.
pub fn dispatchEventWithBubblesFromNativeCallback(
    self: *Js,
    window_id: u32,
    event_type: []const u8,
    node: *Node,
    bubbles: bool,
) !bool {
    if (self.current_window_id != window_id) return error.InactiveJavaScriptWindow;
    return self.dispatchEventWithBubblesLocked(
        window_id,
        event_type,
        node,
        bubbles,
        false,
    );
}

fn dispatchEventWithBubblesLocked(
    self: *Js,
    window_id: u32,
    event_type: []const u8,
    node: *Node,
    bubbles: bool,
    activate_window: bool,
) !bool {
    const window = try self.setCurrentWindow(window_id);
    if (activate_window) try self.setActiveWindow(window_id, window);
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
    const dispatch_value = try native_obj.get(&self.agent, dispatch_property);

    if (!dispatch_value.isCallable()) return true;

    const bubbles_value = Value.from(bubbles);
    const result = try dispatch_value.call(
        &self.agent,
        .undefined,
        &.{ handle_value, type_js_value, bubbles_value },
    );
    const do_default = result.toBoolean();
    return do_default;
}

/// Capture the stable JavaScript handle for a node before dispatch. Event
/// listeners may relocate by-value DOM children, so browser default actions
/// must resolve this identity again instead of retaining only a raw pointer.
pub fn captureNodeHandle(self: *Js, window_id: u32, node: *Node) !u32 {
    self.lock.lock();
    defer self.lock.unlock();
    return self.captureNodeHandleLocked(window_id, node);
}

/// Capture a handle from a native callback invoked by this Js instance. The
/// caller is the current JavaScript execution thread and already owns `lock`.
pub fn captureNodeHandleFromNativeCallback(self: *Js, window_id: u32, node: *Node) !u32 {
    if (self.current_window_id != window_id) return error.InactiveJavaScriptWindow;
    return self.captureNodeHandleLocked(window_id, node);
}

fn captureNodeHandleLocked(self: *Js, window_id: u32, node: *Node) !u32 {
    const window = try self.setCurrentWindow(window_id);
    if (!dom_mutation.isAttachedToCurrentDocument(window.current_nodes, node)) return error.DetachedNode;
    return self.getHandle(window, node);
}

/// Resolve a previously captured node handle only while it remains attached
/// to this window's current document. Removed nodes retain JavaScript handles
/// for possible reattachment, but they cannot receive browser default actions.
pub fn resolveAttachedNode(self: *Js, window_id: u32, handle: u32) ?*Node {
    self.lock.lock();
    defer self.lock.unlock();
    return self.resolveAttachedNodeLocked(window_id, handle);
}

/// Resolve a handle from the current native callback without recursively
/// acquiring `lock`. This API is invalid outside the synchronous callback.
pub fn resolveAttachedNodeFromNativeCallback(self: *Js, window_id: u32, handle: u32) ?*Node {
    if (self.current_window_id != window_id) return null;
    return self.resolveAttachedNodeLocked(window_id, handle);
}

fn resolveAttachedNodeLocked(self: *Js, window_id: u32, handle: u32) ?*Node {
    const window = self.windows.getPtr(window_id) orelse return null;
    const node = self.getNode(window, handle) orelse return null;
    return if (dom_mutation.isAttachedToCurrentDocument(window.current_nodes, node)) node else null;
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

    // Task and pending-message buffers are released immediately after this
    // call, while Kiesel may retain ASCII input bytes in its string cache.
    const message_value = try self.copiedStringToJsValue(message);
    const origin_value = try self.copiedStringToJsValue(origin);
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
    _ = try fn_value.call(&self.agent, .undefined, &.{handle_value});
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

/// Kiesel may cache ASCII strings by retaining their input bytes. Use this for
/// callback/task-owned buffers that are released after the host call returns.
fn copiedStringToJsValue(self: *Js, text: []const u8) !Value {
    const stable_text = if (text.len == 0)
        text
    else
        try self.agent.gc_allocator.dupe(u8, text);
    return self.stringToJsValue(stable_text);
}

fn setActiveWindow(self: *Js, window_id: u32, window: *WindowContext) !void {
    if (!self.runtime_initialized) return;
    const key = kiesel.types.PropertyKey.from("__setActiveWindow");
    const fn_value = try window.realm.global_object.get(&self.agent, key);
    if (!fn_value.isCallable()) return;
    const window_value = Value.from(@as(f64, @floatFromInt(window_id)));
    _ = try fn_value.call(&self.agent, .undefined, &.{window_value});
}

pub fn runXhrOnload(self: *Js, window_id: u32, handle: u32, body: []const u8) !void {
    self.lock.lock();
    defer self.lock.unlock();
    const window = try self.setCurrentWindow(window_id);
    try self.setActiveWindow(window_id, window);
    const key = kiesel.types.PropertyKey.from("__runXHROnload");
    const fn_value = try window.realm.global_object.get(&self.agent, key);
    if (!fn_value.isCallable()) return error.MissingXhrCallback;

    const body_value = try self.copiedStringToJsValue(body);
    const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
    _ = try fn_value.call(&self.agent, .undefined, &.{ body_value, handle_value });
}

test "Node.prototype.style setter is defined" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var js = try Js.init(std.testing.allocator, std.testing.io, &environ);
    defer js.deinit(std.testing.allocator);

    const result = try js.evaluate(0, "Object.getOwnPropertyDescriptor(Node.prototype, 'style') !== undefined");
    try std.testing.expect(result.toBoolean());
}

test "__native.style_set is exposed" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var js = try Js.init(std.testing.allocator, std.testing.io, &environ);
    defer js.deinit(std.testing.allocator);

    const result = try js.evaluate(0, "typeof __native.style_set === 'function'");
    try std.testing.expect(result.toBoolean());
}

test "host interrupt stops an infinite script" {
    const InterruptAfterPolls = struct {
        remaining: usize,

        fn check(context: ?*anyopaque) bool {
            const raw_context = context orelse return false;
            const unaligned: *align(1) @This() = @ptrCast(raw_context);
            const self: *@This() = @alignCast(unaligned);
            if (self.remaining == 0) return true;
            self.remaining -= 1;
            return false;
        }
    };

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var js = try Js.init(std.testing.allocator, std.testing.io, &environ);
    defer js.deinit(std.testing.allocator);

    // Initialize Zibra's runtime before enabling the deliberately finite
    // execution budget so the test measures the page script itself.
    _ = try js.evaluate(0, "undefined");
    var interrupt = InterruptAfterPolls{ .remaining = 1024 };
    js.setInterruptHandler(&interrupt, InterruptAfterPolls.check);

    try std.testing.expectError(
        error.ExecutionInterrupted,
        js.evaluate(0, "try { while (true) {} } catch (error) {}"),
    );
}

test "Js roots Kiesel Agent state across garbage collections" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var js = try Js.init(std.testing.allocator, std.testing.io, &environ);
    defer js.deinit(std.testing.allocator);

    _ = try js.evaluate(0, "typeof Node === 'function'");
    kiesel.gc.collect();
    kiesel.gc.collect();

    const result = try js.evaluate(
        0,
        "typeof Node === 'function' && typeof __native === 'object'",
    );
    try std.testing.expect(result.toBoolean());
}

fn findTestElementById(root: *Node, id: []const u8) !*Node {
    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(std.testing.allocator);
    try parser.treeToList(std.testing.allocator, root, &nodes);
    for (nodes.items) |node| {
        if (node.* != .element) continue;
        const attributes = node.element.attributes orelse continue;
        if (attributes.get("id")) |candidate| {
            if (std.mem.eql(u8, candidate, id)) return node;
        }
    }
    return error.MissingTestElement;
}

const FocusCallbackTestContext = struct {
    js: *Js,
    handles: [4]u32 = undefined,
    count: usize = 0,

    fn callback(context: ?*anyopaque, handle: u32) anyerror!void {
        const raw = context orelse return;
        const unaligned: *align(1) FocusCallbackTestContext = @ptrCast(raw);
        const self: *FocusCallbackTestContext = @alignCast(unaligned);
        if (self.count < self.handles.len) self.handles[self.count] = handle;
        self.count += 1;

        // The production callback resolves the stable handle and dispatches
        // focus/blur while evaluate() already owns the Js mutex. Exercise the
        // callback-only path so a recursive lock regression hangs this test.
        const node = self.js.resolveAttachedNodeFromNativeCallback(0, handle) orelse return;
        _ = try self.js.dispatchEventWithBubblesFromNativeCallback(
            0,
            "focus",
            node,
            false,
        );
    }
};

test "Node focus calls the host only for attached focusable elements" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<input id=entry>" ++
        "<div id=plain></div>" ++
        "<div id=programmatic tabindex=-1></div>" ++
        "<input id=hidden type=hidden>" ++
        "<button id=disabled disabled>disabled</button>" ++
        "</main>";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var focus_context = FocusCallbackTestContext{ .js = js };
    js.setFocusCallback(0, FocusCallbackTestContext.callback, &focus_context);
    const result = try js.evaluate(0,
        \\var entry = document.querySelectorAll('input')[0];
        \\var hidden = document.querySelectorAll('input')[1];
        \\var plain = document.querySelectorAll('div')[0];
        \\var programmatic = document.querySelectorAll('div')[1];
        \\var disabled = document.querySelectorAll('button')[0];
        \\var detached = document.createElement('input');
        \\var focusDeliveries = 0;
        \\entry.addEventListener('focus', function() { focusDeliveries += 1; });
        \\var entryResult = entry.focus();
        \\plain.focus();
        \\programmatic.focus();
        \\hidden.focus();
        \\disabled.focus();
        \\detached.focus();
        \\document.querySelectorAll('main')[0].appendChild(detached);
        \\detached.focus();
        \\entryResult === undefined && focusDeliveries === 1
    );
    try std.testing.expect(result.toBoolean());
    try std.testing.expectEqual(@as(usize, 3), focus_context.count);
    try std.testing.expect(focus_context.handles[0] != focus_context.handles[1]);
    try std.testing.expect(focus_context.handles[1] != focus_context.handles[2]);
}

test "browser focus and blur events stay on their target" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><section><input id=target></section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    const target = try findTestElementById(&root, "target");

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    _ = try js.evaluate(0,
        \\var focusLog = [];
        \\var target = document.querySelectorAll('input')[0];
        \\var parentNode = document.querySelectorAll('section')[0];
        \\target.addEventListener('focus', function(event) {
        \\  focusLog.push('target-focus:' + event.bubbles);
        \\});
        \\target.addEventListener('blur', function(event) {
        \\  focusLog.push('target-blur:' + event.bubbles);
        \\});
        \\parentNode.addEventListener('focus', function() { focusLog.push('parent-focus'); });
        \\parentNode.addEventListener('blur', function() { focusLog.push('parent-blur'); });
    );

    try std.testing.expect(try js.dispatchEventWithBubbles(0, "focus", target, false));
    try std.testing.expect(try js.dispatchEventWithBubbles(0, "blur", target, false));
    const result = try js.evaluate(
        0,
        "focusLog.join(',') === 'target-focus:false,target-blur:false'",
    );
    try std.testing.expect(result.toBoolean());
}

test "DOM events bubble with stable targets propagation control and cancellation" {
    const allocator = std.testing.allocator;
    const html =
        "<main id=root>" ++
        "<section id=parent><span id=target>ordinary target</span></section>" ++
        "<a id=link href=/next><b id=linkTarget>link target</b></a>" ++
        "<div id=mutationParent><i id=mutationTarget>mutating target</i></div>" ++
        "</main>";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    const target = try findTestElementById(&root, "target");
    const link_target = try findTestElementById(&root, "linkTarget");
    const mutation_target = try findTestElementById(&root, "mutationTarget");

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    _ = try js.evaluate(0,
        \\var bubbleLog = [];
        \\var lastEvent = null;
        \\var targetNode = document.querySelectorAll('span')[0];
        \\var parentNode = document.querySelectorAll('section')[0];
        \\var rootNode = document.querySelectorAll('main')[0];
        \\var linkNode = document.querySelectorAll('a')[0];
        \\var linkTargetNode = document.querySelectorAll('b')[0];
        \\var mutationParentNode = document.querySelectorAll('div')[0];
        \\var mutationTargetNode = document.querySelectorAll('i')[0];
        \\targetNode.addEventListener('click', function(event) {
        \\  lastEvent = event;
        \\  bubbleLog.push('target:' + event.target.getAttribute('id') + ':' +
        \\    event.currentTarget.getAttribute('id') + ':' + this.getAttribute('id'));
        \\});
        \\parentNode.addEventListener('click', function(event) {
        \\  bubbleLog.push('parent-one');
        \\  event.stopPropagation();
        \\});
        \\parentNode.addEventListener('click', function() { bubbleLog.push('parent-two'); });
        \\rootNode.addEventListener('click', function(event) {
        \\  bubbleLog.push('root:' + event.target.getAttribute('id'));
        \\  if (event.target.getAttribute('id') === 'linkTarget') event.preventDefault();
        \\});
        \\linkTargetNode.addEventListener('click', function(event) {
        \\  lastEvent = event;
        \\  bubbleLog.push('link-target');
        \\});
        \\linkNode.addEventListener('click', function(event) {
        \\  bubbleLog.push('link:' + event.target.getAttribute('id'));
        \\});
        \\mutationTargetNode.addEventListener('click', function() {
        \\  bubbleLog.push('mutation-target');
        \\  mutationParentNode.innerHTML = '';
        \\});
        \\mutationParentNode.addEventListener('click', function(event) {
        \\  bubbleLog.push('mutation-parent');
        \\  event.stopPropagation();
        \\});
    );

    try std.testing.expect(try js.dispatchEvent(0, "click", target));
    const stopped = try js.evaluate(0,
        \\bubbleLog.join(',') === 'target:target:target:target,parent-one,parent-two' &&
        \\lastEvent.currentTarget === null && !lastEvent.defaultPrevented
    );
    try std.testing.expect(stopped.toBoolean());

    _ = try js.evaluate(0, "bubbleLog = []");
    try std.testing.expect(!try js.dispatchEvent(0, "click", link_target));
    const cancelled = try js.evaluate(0,
        \\bubbleLog.join(',') === 'link-target,link:linkTarget,root:linkTarget' &&
        \\lastEvent.currentTarget === null && lastEvent.defaultPrevented
    );
    try std.testing.expect(cancelled.toBoolean());

    _ = try js.evaluate(0, "bubbleLog = []");
    try std.testing.expect(try js.dispatchEvent(0, "click", mutation_target));
    const mutated = try js.evaluate(
        0,
        "bubbleLog.join(',') === 'mutation-target,mutation-parent'",
    );
    try std.testing.expect(mutated.toBoolean());
}

test "querySelectorAll matches ordered descendant selector chains" {
    const allocator = std.testing.allocator;
    const html =
        "<main><aside><section><article>" ++
        "<span class=\"target urgent\">Matched</span>" ++
        "</article></section></aside></main>";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\document.querySelectorAll('main section article span.target.urgent').length === 1 &&
        \\document.querySelectorAll('section main article span.target.urgent').length === 0 &&
        \\document.querySelectorAll('main section article span.target.missing').length === 0
    );
    try std.testing.expect(result.toBoolean());
}

test "querySelectorAll matches :has selectors through strict descendants" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<div class=card><section><span class=badge>Matched</span></section></div>" ++
        "<div class=card><section><em class=badge>Also matched</em></section></div>" ++
        "</main>";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\document.querySelectorAll('main div.card:has(span.badge)').length === 1 &&
        \\document.querySelectorAll('main div.card:has(.badge)').length === 2 &&
        \\document.querySelectorAll('span.badge:has(.badge)').length === 0
    );
    try std.testing.expect(result.toBoolean());
}

test "element IDs expose first-match globals without replacing existing names" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<div id=foo></div><span id=duplicate></span><em id=duplicate></em>" ++
        "<p id=dash-id></p><aside id=document></aside>" ++
        "</main>";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\var container = document.querySelectorAll('main')[0];
        \\var firstDuplicate = document.querySelectorAll('span')[0];
        \\var secondDuplicate = document.querySelectorAll('em')[0];
        \\var initial = foo.handle === document.querySelectorAll('div')[0].handle &&
        \\  duplicate.handle === firstDuplicate.handle &&
        \\  window['dash-id'].handle === document.querySelectorAll('p')[0].handle &&
        \\  typeof document.querySelectorAll === 'function' &&
        \\  document.querySelectorAll('aside')[0].handle !== document.handle;
        \\container.removeChild(firstDuplicate);
        \\initial && duplicate.handle === secondDuplicate.handle
    );
    try std.testing.expect(result.toBoolean());
}

test "ID globals follow innerHTML attributes detach and reattachment" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><section id=mount><span id=oldChild></span></section><p id=preserved></p></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    try parser.style(allocator, &root, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\var target = document.querySelectorAll('section')[0];
        \\var oldWasPublished = oldChild.handle === target.children[0].handle;
        \\window.preserved = 17;
        \\target.innerHTML = '<i id="newChild"></i>';
        \\var replacementWorked = typeof oldChild === 'undefined' &&
        \\  newChild.handle === target.children[0].handle;
        \\var created = document.createElement('button');
        \\created.setAttribute('id', 'dynamicChild');
        \\var detachedWasHidden = typeof dynamicChild === 'undefined';
        \\target.appendChild(created);
        \\var appendPublished = dynamicChild.handle === created.handle;
        \\created.setAttribute('id', 'renamedChild');
        \\var renamePublished = typeof dynamicChild === 'undefined' &&
        \\  renamedChild.handle === created.handle;
        \\target.removeChild(created);
        \\var removalCleared = typeof renamedChild === 'undefined';
        \\target.appendChild(created);
        \\oldWasPublished && replacementWorked && detachedWasHidden && appendPublished &&
        \\renamePublished && removalCleared && renamedChild.handle === created.handle &&
        \\window.preserved === 17
    );
    try std.testing.expect(result.toBoolean());
    // Structural mutation clears raw parent/child style subscriptions before
    // removed fields are destroyed; a complete pass then rebuilds live edges.
    try parser.style(allocator, &root, &.{});
}

test "ID globals are isolated between active window documents" {
    const allocator = std.testing.allocator;
    var parser_a = try parser.HTMLParser.init(allocator, "<main><p id=alpha></p></main>");
    parser_a.use_implicit_tags = false;
    defer parser_a.deinit(allocator);
    var root_a = try parser_a.parse();
    defer root_a.deinit(allocator);
    parser.fixParentPointers(&root_a, null);

    var parser_b = try parser.HTMLParser.init(allocator, "<main><p id=beta></p></main>");
    parser_b.use_implicit_tags = false;
    defer parser_b.deinit(allocator);
    var root_b = try parser_b.parse();
    defer root_b.deinit(allocator);
    parser.fixParentPointers(&root_b, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(10, &root_a);
    defer js.setNodes(10, null);
    js.setNodes(20, &root_b);
    defer js.setNodes(20, null);

    const first = try js.evaluate(10, "typeof alpha === 'object' && typeof beta === 'undefined'");
    try std.testing.expect(first.toBoolean());
    const second = try js.evaluate(20, "typeof alpha === 'undefined' && typeof beta === 'object'");
    try std.testing.expect(second.toBoolean());
    const restored = try js.evaluate(10, "typeof alpha === 'object' && typeof beta === 'undefined'");
    try std.testing.expect(restored.toBoolean());
}

test "Node.children returns immediate element children in source order" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<section id=parent>leading text<span id=first>one</span>middle text" ++
        "<em id=second><b id=nested>nested</b></em>trailing text</section>" ++
        "<aside id=empty>text only</aside>" ++
        "</main>";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\var target = document.querySelectorAll('section')[0];
        \\var children = target.children;
        \\var empty = document.querySelectorAll('aside')[0];
        \\typeof children.map === 'function' &&
        \\children !== target.children &&
        \\children.length === 2 &&
        \\children[0].getAttribute('id') === 'first' &&
        \\children[1].getAttribute('id') === 'second' &&
        \\children[0].children.length === 0 &&
        \\children[1].children.length === 1 &&
        \\children[1].children[0].getAttribute('id') === 'nested' &&
        \\empty.children.length === 0
    );
    try std.testing.expect(result.toBoolean());
}

test "Node.children reflects a later innerHTML generation" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<section><span id=old-one></span>text<em id=old-two></em></section>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\var target = document.querySelectorAll('section')[0];
        \\var before = target.children;
        \\target.innerHTML = 'text<i id="replacement">new</i>more text';
        \\var after = target.children;
        \\before.length === 2 &&
        \\after.length === 1 &&
        \\after[0].getAttribute('id') === 'replacement'
    );
    try std.testing.expect(result.toBoolean());
}

test "innerHTML and outerHTML serialize the live DOM" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><div id=holder class=box></div></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    _ = try js.evaluate(0,
        \\var container = holder;
        \\container.innerHTML = '<span id=foo>Chris &amp; company</span><input checked>';
        \\var element = foo;
        \\element.id = 'bar';
        \\element.setAttribute('title', 'A & "quote" <tag>');
        \\var expectedSpan = '<span id="bar" title="A &amp; &quot;quote&quot; &lt;tag&gt;">Chris &amp; company</span>';
        \\var expectedInner = expectedSpan + '<input checked="">';
    );
    try std.testing.expect((try js.evaluate(0, "element.id === 'bar'")).toBoolean());
    try std.testing.expect((try js.evaluate(
        0,
        "typeof foo === 'undefined' && bar.handle === element.handle",
    )).toBoolean());
    try std.testing.expect((try js.evaluate(0, "container.innerHTML === expectedInner")).toBoolean());
    try std.testing.expect((try js.evaluate(0, "element.outerHTML === expectedSpan")).toBoolean());
    const container_outer_value = try js.evaluate(0, "container.outerHTML");
    const container_outer = try container_outer_value.asString().toUtf8(allocator);
    defer allocator.free(container_outer);
    try std.testing.expectEqualStrings(
        "<div class=\"box\" id=\"holder\">" ++
            "<span id=\"bar\" title=\"A &amp; &quot;quote&quot; &lt;tag&gt;\">" ++
            "Chris &amp; company</span><input checked=\"\"></div>",
        container_outer,
    );
    try std.testing.expect((try js.evaluate(
        0,
        "container.children[1].outerHTML === '<input checked=\"\">'",
    )).toBoolean());
    try std.testing.expect((try js.evaluate(0, "container.children[1].innerHTML === ''")).toBoolean());

    const result = try js.evaluate(0,
        \\var tail = document.createElement('EM');
        \\tail.id = 'tail';
        \\container.appendChild(tail);
        \\var appended = container.innerHTML === expectedInner + '<em id="tail"></em>';
        \\var removed = container.removeChild(element);
        \\appended && removed === element &&
        \\  typeof bar === 'undefined' && removed.outerHTML === expectedSpan &&
        \\  container.innerHTML === '<input checked=""><em id="tail"></em>'
    );
    try std.testing.expect(result.toBoolean());
}

const DomMutationTestContext = struct {
    count: usize = 0,
    complete_count: usize = 0,
    prepared_child_count: usize = 0,
    completed_child_count: usize = 0,
    js_to_switch: ?*Js = null,
    window_to_clear: ?u32 = null,

    fn callback(
        context: ?*anyopaque,
        mutation_root: *Node,
        _: DomMutationKind,
    ) void {
        const raw = context orelse return;
        const unaligned: *align(1) DomMutationTestContext = @ptrCast(raw);
        const self: *DomMutationTestContext = @alignCast(unaligned);
        self.count += 1;
        self.prepared_child_count = switch (mutation_root.*) {
            .element => |element| element.children.items.len,
            .text => 0,
        };
    }

    fn completeCallback(context: ?*anyopaque, mutation_root: *Node) void {
        const raw = context orelse return;
        const unaligned: *align(1) DomMutationTestContext = @ptrCast(raw);
        const self: *DomMutationTestContext = @alignCast(unaligned);
        self.complete_count += 1;
        self.completed_child_count = switch (mutation_root.*) {
            .element => |element| element.children.items.len,
            .text => 0,
        };
        if (self.js_to_switch) |js| {
            if (self.window_to_clear) |window_id| js.setNodes(window_id, null);
        }
    }
};

test "retained insertion state accumulates and excludes stylesheet subtrees" {
    const allocator = std.testing.allocator;

    var ordinary = Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer ordinary.deinit(allocator);
    ordinary.element.clearChildrenDirty();
    ordinary.element.markChildInserted();
    ordinary.element.markChildInserted();
    try std.testing.expect(ordinary.element.children_dirty);
    try std.testing.expect(ordinary.element.children_insertions_only);
    ordinary.element.markChildrenDirty();
    try std.testing.expect(!ordinary.element.children_insertions_only);
    try std.testing.expect(!dom_mutation.subtreeCanChangeAuthorStyleRules(&ordinary));

    var run_in = Node{ .element = try parser.Element.init(allocator, "h6", null) };
    defer run_in.deinit(allocator);
    try std.testing.expect(dom_mutation.insertionCanMergeRunIn(&run_in, 0, 1));
    try std.testing.expect(!dom_mutation.insertionCanMergeRunIn(&run_in, 1, 1));

    var wrapper = Node{ .element = try parser.Element.init(allocator, "section", null) };
    defer wrapper.deinit(allocator);
    var nested_link = Node{ .element = try parser.Element.init(
        allocator,
        "link rel=stylesheet href=theme.css",
        null,
    ) };
    var nested_link_owned = true;
    defer if (nested_link_owned) nested_link.deinit(allocator);
    try wrapper.element.children.append(allocator, nested_link);
    nested_link_owned = false;
    parser.fixParentPointers(&wrapper, null);
    try std.testing.expect(dom_mutation.subtreeCanChangeAuthorStyleRules(&wrapper));
}

test "innerHTML completion callback observes installed child generation" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><section id=target><i></i></section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var child_parser = try parser.HTMLParser.init(allocator, "<p>child</p>");
    child_parser.use_implicit_tags = false;
    defer child_parser.deinit(allocator);
    var child_root = try child_parser.parse();
    defer child_root.deinit(allocator);
    parser.fixParentPointers(&child_root, null);
    js.setNodes(1, &child_root);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var mutation_context = DomMutationTestContext{
        .js_to_switch = js,
        .window_to_clear = 1,
    };
    js.setDomMutationCallback(0, DomMutationTestContext.callback, &mutation_context);
    js.setDomMutationCompleteCallback(
        0,
        DomMutationTestContext.completeCallback,
        &mutation_context,
    );

    const result = try js.evaluate(0,
        \\var target = document.querySelectorAll('section')[0];
        \\target.innerHTML = '<iframe src="child.html"></iframe><span></span>';
        \\target.children.length === 2
    );
    try std.testing.expect(result.toBoolean());
    try std.testing.expectEqual(@as(usize, 1), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.complete_count);
    try std.testing.expectEqual(@as(usize, 2), mutation_context.completed_child_count);
    try std.testing.expectEqual(@as(?u32, 0), js.current_window_id);
}

test "replaceChildren empties once, invalidates relational style, and detaches live nodes" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<section class=card id=target>" ++
        "<article id=removed><strong id=nested>saved</strong></article><i>other</i>" ++
        "</section><aside></aside>" ++
        "</main>";
    const css =
        "section.card:has(strong) { color: green; }" ++
        "section.card { color: blue; }";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try parser.style(allocator, &root, rules);
    const target_element = &root.element.children.items[0].element;
    try std.testing.expectEqualStrings(
        "green",
        target_element.style.?.getPtr("color").?.get().*,
    );
    target_element.clearChildrenDirty();

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var mutation_context = DomMutationTestContext{};
    js.setDomMutationCallback(0, DomMutationTestContext.callback, &mutation_context);
    js.setDomMutationCompleteCallback(
        0,
        DomMutationTestContext.completeCallback,
        &mutation_context,
    );

    const emptied = try js.evaluate(0,
        \\var targetNode = document.querySelectorAll('section')[0];
        \\var oldChildren = targetNode.children;
        \\var savedArticle = oldChildren[0];
        \\var savedNested = savedArticle.children[0];
        \\var savedSibling = oldChildren[1];
        \\var emptyResult = targetNode.replaceChildren();
        \\var noopResult = targetNode.replaceChildren();
        \\emptyResult === undefined && noopResult === undefined &&
        \\  targetNode.children.length === 0 && targetNode.innerHTML === '' &&
        \\  typeof removed === 'undefined' && typeof nested === 'undefined' &&
        \\  savedArticle.getAttribute('id') === 'removed' &&
        \\  savedArticle.children[0].handle === savedNested.handle &&
        \\  savedSibling.getAttribute('id') === null
    );
    try std.testing.expect(emptied.toBoolean());
    try std.testing.expect(target_element.children_dirty);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 2), mutation_context.prepared_child_count);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.complete_count);
    try std.testing.expectEqual(@as(usize, 0), mutation_context.completed_child_count);

    // The removed descendant changes the target's :has() match; the mutation
    // must dirty that style even though the target element itself survives.
    try parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings(
        "blue",
        target_element.style.?.getPtr("color").?.get().*,
    );

    const reattached = try js.evaluate(0,
        \\var destination = document.querySelectorAll('aside')[0];
        \\var appendResult = destination.appendChild(savedArticle);
        \\appendResult === savedArticle &&
        \\  destination.children[0].handle === savedArticle.handle &&
        \\  savedArticle.children[0].handle === savedNested.handle
    );
    try std.testing.expect(reattached.toBoolean());
    try std.testing.expectEqual(@as(usize, 2), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 2), mutation_context.complete_count);
}

test "replaceChildren transfers attached and detached elements in argument order" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<section class=target><i id=old><b id=old-nested></b></i></section>" ++
        "<div class=source-a><article id=moving-a><strong id=nested></strong></article><u id=stay-a></u></div>" ++
        "<div class=source-b><button id=moving-b></button><em id=stay-b></em></div>" ++
        "<aside></aside>" ++
        "</main>";
    const css =
        "section.target:has(article) { color: blue; }" ++
        "section.target { color: black; }" ++
        "div.source-a:has(article) { color: red; }" ++
        "div.source-a { color: green; }";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try parser.style(allocator, &root, rules);
    const target_element = &root.element.children.items[0].element;
    const source_a_element = &root.element.children.items[1].element;
    try std.testing.expectEqualStrings("black", target_element.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("red", source_a_element.style.?.getPtr("color").?.get().*);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var mutation_context = DomMutationTestContext{};
    js.setDomMutationCallback(0, DomMutationTestContext.callback, &mutation_context);
    js.setDomMutationCompleteCallback(
        0,
        DomMutationTestContext.completeCallback,
        &mutation_context,
    );

    const result = try js.evaluate(0,
        \\var targetNode = document.querySelectorAll('section')[0];
        \\var sourceA = document.querySelectorAll('.source-a')[0];
        \\var sourceB = document.querySelectorAll('.source-b')[0];
        \\var articleNode = document.querySelectorAll('article')[0];
        \\var nestedNode = articleNode.children[0];
        \\var buttonNode = document.querySelectorAll('button')[0];
        \\var stayA = sourceA.children[1];
        \\var stayB = sourceB.children[1];
        \\var oldNode = targetNode.children[0];
        \\var oldNested = oldNode.children[0];
        \\var detachedNode = document.createElement('small');
        \\detachedNode.id = 'created';
        \\var detachedNested = document.createElement('span');
        \\detachedNested.id = 'created-nested';
        \\detachedNode.appendChild(detachedNested);
        \\var replaceResult = targetNode.replaceChildren(buttonNode, detachedNode, articleNode);
        \\var children = targetNode.children;
        \\replaceResult === undefined && children.length === 3 &&
        \\  children[0].handle === buttonNode.handle &&
        \\  children[1].handle === detachedNode.handle &&
        \\  children[2].handle === articleNode.handle &&
        \\  articleNode.children[0].handle === nestedNode.handle &&
        \\  detachedNode.children[0].handle === detachedNested.handle &&
        \\  sourceA.children.length === 1 && sourceA.children[0].handle === stayA.handle &&
        \\  sourceB.children.length === 1 && sourceB.children[0].handle === stayB.handle &&
        \\  document.querySelectorAll('i').length === 0 &&
        \\  typeof old === 'undefined' && created.handle === detachedNode.handle &&
        \\  oldNode.children[0].handle === oldNested.handle
    );
    try std.testing.expect(result.toBoolean());
    try std.testing.expectEqual(@as(usize, 1), mutation_context.count);
    // The target and both source parents are siblings, so the common-ancestor
    // invalidation boundary is the four-child <main> root.
    try std.testing.expectEqual(@as(usize, 4), mutation_context.prepared_child_count);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.complete_count);
    try std.testing.expectEqual(@as(usize, 3), mutation_context.completed_child_count);
    try std.testing.expectEqual(@as(usize, 1), js.windows.getPtr(0).?.detached_nodes.count());

    try parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("blue", target_element.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("green", source_a_element.style.?.getPtr("color").?.get().*);

    const reattached = try js.evaluate(0,
        \\var parking = document.querySelectorAll('aside')[0];
        \\parking.appendChild(oldNode) === oldNode &&
        \\  parking.children[0].handle === oldNode.handle &&
        \\  oldNode.children[0].handle === oldNested.handle
    );
    try std.testing.expect(reattached.toBoolean());
    try std.testing.expectEqual(@as(usize, 0), js.windows.getPtr(0).?.detached_nodes.count());
    try std.testing.expectEqual(@as(usize, 2), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 2), mutation_context.complete_count);
}

test "replaceChildren handles nested and repeated elements and validates before mutation" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><section><article><strong></strong><em></em></article><i></i></section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var mutation_context = DomMutationTestContext{};
    js.setDomMutationCallback(0, DomMutationTestContext.callback, &mutation_context);
    js.setDomMutationCompleteCallback(
        0,
        DomMutationTestContext.completeCallback,
        &mutation_context,
    );

    const result = try js.evaluate(0,
        \\var mainNode = document.querySelectorAll('main')[0];
        \\var targetNode = document.querySelectorAll('section')[0];
        \\var outerNode = document.querySelectorAll('article')[0];
        \\var innerNode = document.querySelectorAll('strong')[0];
        \\var tailNode = document.querySelectorAll('em')[0];
        \\var discardedNode = document.querySelectorAll('i')[0];
        \\var cycleRejected = false;
        \\var valueRejected = false;
        \\var zeroRejected = false;
        \\try { targetNode.replaceChildren(mainNode); } catch (error) { cycleRejected = true; }
        \\try { targetNode.replaceChildren(42); } catch (error) { valueRejected = true; }
        \\try { targetNode.replaceChildren(0); } catch (error) { zeroRejected = true; }
        \\var unchanged = targetNode.children.length === 2 &&
        \\  targetNode.children[0].handle === outerNode.handle &&
        \\  targetNode.children[1].handle === discardedNode.handle;
        \\var replaceResult = targetNode.replaceChildren(outerNode, innerNode, outerNode);
        \\var children = targetNode.children;
        \\cycleRejected && valueRejected && zeroRejected && unchanged && replaceResult === undefined &&
        \\  children.length === 2 && children[0].handle === innerNode.handle &&
        \\  children[1].handle === outerNode.handle && outerNode.children.length === 1 &&
        \\  outerNode.children[0].handle === tailNode.handle &&
        \\  document.querySelectorAll('strong').length === 1 &&
        \\  document.querySelectorAll('article').length === 1
    );
    try std.testing.expect(result.toBoolean());
    try std.testing.expectEqual(@as(usize, 1), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.complete_count);
    try std.testing.expectEqual(@as(usize, 2), mutation_context.completed_child_count);
}

test "replaceChildren into a detached target invalidates attached source parents" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><section><b></b><i></i></section><aside></aside></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var mutation_context = DomMutationTestContext{};
    js.setDomMutationCallback(0, DomMutationTestContext.callback, &mutation_context);
    js.setDomMutationCompleteCallback(
        0,
        DomMutationTestContext.completeCallback,
        &mutation_context,
    );

    const detached_result = try js.evaluate(0,
        \\var sourceNode = document.querySelectorAll('section')[0];
        \\var destinationNode = document.querySelectorAll('aside')[0];
        \\var firstNode = sourceNode.children[0];
        \\var secondNode = sourceNode.children[1];
        \\var detachedTarget = document.createElement('div');
        \\detachedTarget.replaceChildren(firstNode, secondNode);
        \\sourceNode.children.length === 0 && detachedTarget.children.length === 2 &&
        \\  detachedTarget.children[0].handle === firstNode.handle &&
        \\  detachedTarget.children[1].handle === secondNode.handle &&
        \\  document.querySelectorAll('b').length === 0
    );
    try std.testing.expect(detached_result.toBoolean());
    try std.testing.expectEqual(@as(usize, 1), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.complete_count);

    const mounted_result = try js.evaluate(0,
        \\destinationNode.appendChild(detachedTarget);
        \\destinationNode.children[0].handle === detachedTarget.handle &&
        \\  document.querySelectorAll('b')[0].handle === firstNode.handle &&
        \\  document.querySelectorAll('i')[0].handle === secondNode.handle
    );
    try std.testing.expect(mounted_result.toBoolean());
    try std.testing.expectEqual(@as(usize, 2), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 2), mutation_context.complete_count);
}

test "replaceChildren re-resolves a target shifted by source removal" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><div><b></b><section><i></i></section></div></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var mutation_context = DomMutationTestContext{};
    js.setDomMutationCallback(0, DomMutationTestContext.callback, &mutation_context);
    js.setDomMutationCompleteCallback(
        0,
        DomMutationTestContext.completeCallback,
        &mutation_context,
    );

    const result = try js.evaluate(0,
        \\var sourceNode = document.querySelectorAll('div')[0];
        \\var movingNode = sourceNode.children[0];
        \\var targetNode = sourceNode.children[1];
        \\var oldNode = targetNode.children[0];
        \\var targetHandle = targetNode.handle;
        \\targetNode.replaceChildren(movingNode);
        \\sourceNode.children.length === 1 &&
        \\  sourceNode.children[0].handle === targetHandle &&
        \\  targetNode.handle === targetHandle && targetNode.children.length === 1 &&
        \\  targetNode.children[0].handle === movingNode.handle &&
        \\  oldNode.getAttribute('missing') === null
    );
    try std.testing.expect(result.toBoolean());
    try std.testing.expectEqual(@as(usize, 1), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.complete_count);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.completed_child_count);
}

test "createElement appendChild and insertBefore preserve handles and order" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><section id=target><i id=anchor></i></section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var mutation_context = DomMutationTestContext{};
    js.setDomMutationCallback(0, DomMutationTestContext.callback, &mutation_context);
    js.setDomMutationCompleteCallback(
        0,
        DomMutationTestContext.completeCallback,
        &mutation_context,
    );

    const result = try js.evaluate(0,
        \\var target = document.querySelectorAll('section')[0];
        \\var anchor = target.children[0];
        \\var article = document.createElement('ARTICLE');
        \\article.setAttribute('id', 'created');
        \\var nested = document.createElement('strong');
        \\nested.setAttribute('id', 'nested');
        \\var nestedReturn = article.appendChild(nested);
        \\var appendReturn = target.appendChild(article);
        \\var before = document.createElement('em');
        \\before.setAttribute('id', 'before');
        \\var beforeReturn = target.insertBefore(before, anchor);
        \\var tail = document.createElement('small');
        \\tail.setAttribute('id', 'tail');
        \\var tailReturn = target.insertBefore(tail, null);
        \\var children = target.children;
        \\nestedReturn === nested && appendReturn === article &&
        \\beforeReturn === before && tailReturn === tail &&
        \\children.length === 4 &&
        \\children[0].handle === before.handle &&
        \\children[1].handle === anchor.handle &&
        \\children[2].handle === article.handle &&
        \\children[3].handle === tail.handle &&
        \\anchor.getAttribute('id') === 'anchor' &&
        \\article.getAttribute('id') === 'created' &&
        \\article.children[0].handle === nested.handle &&
        \\document.querySelectorAll('article').length === 1
    );
    try std.testing.expect(result.toBoolean());
    // Building the article subtree while detached does not invalidate the
    // installed document; its three later insertions do.
    try std.testing.expectEqual(@as(usize, 3), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 3), mutation_context.complete_count);
}

test "removeChild detaches a subtree and preserves handles across reattachment" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<section><article><strong>nested</strong></article><i id=stay></i></section>" ++
        "<aside></aside>" ++
        "</main>";
    const css = "section article { color: red; } aside article { color: green; }";

    var html_parser = try parser.HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try parser.style(allocator, &root, rules);
    const initial_article = &root.element.children.items[0].element.children.items[0].element;
    try std.testing.expectEqualStrings("red", initial_article.style.?.getPtr("color").?.get().*);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    var mutation_context = DomMutationTestContext{};
    js.setDomMutationCallback(0, DomMutationTestContext.callback, &mutation_context);
    js.setDomMutationCompleteCallback(
        0,
        DomMutationTestContext.completeCallback,
        &mutation_context,
    );

    const detached_result = try js.evaluate(0,
        \\var source = document.querySelectorAll('section')[0];
        \\var destination = document.querySelectorAll('aside')[0];
        \\var moving = document.querySelectorAll('article')[0];
        \\var nested = moving.children[0];
        \\var stay = source.children[1];
        \\var observed = 0;
        \\moving.addEventListener('probe', function() { observed += 1; });
        \\var descendantRejected = false;
        \\try { source.removeChild(nested); } catch (error) { descendantRejected = true; }
        \\var removed = source.removeChild(moving);
        \\var rejected = false;
        \\try { source.removeChild(moving); } catch (error) { rejected = true; }
        \\removed === moving && descendantRejected && rejected &&
        \\source.children.length === 1 &&
        \\source.children[0].handle === stay.handle &&
        \\moving.children.length === 1 &&
        \\moving.children[0].handle === nested.handle &&
        \\document.querySelectorAll('article').length === 0
    );
    try std.testing.expect(detached_result.toBoolean());
    try std.testing.expectEqual(@as(usize, 1), js.windows.getPtr(0).?.detached_nodes.count());
    try std.testing.expectEqual(@as(usize, 1), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 1), mutation_context.complete_count);

    const reattached_result = try js.evaluate(0,
        \\moving.setAttribute('id', 'moved');
        \\var appendReturn = destination.appendChild(removed);
        \\appendReturn === moving &&
        \\destination.children.length === 1 &&
        \\destination.children[0].handle === moving.handle &&
        \\moving.children[0].handle === nested.handle &&
        \\moving.getAttribute('id') === 'moved' &&
        \\moving.dispatchEvent(new Event('probe')) && observed === 1 &&
        \\document.querySelectorAll('article').length === 1
    );
    try std.testing.expect(reattached_result.toBoolean());
    try std.testing.expectEqual(@as(usize, 0), js.windows.getPtr(0).?.detached_nodes.count());
    try std.testing.expectEqual(@as(usize, 2), mutation_context.count);
    try std.testing.expectEqual(@as(usize, 2), mutation_context.complete_count);

    // Reparenting a previously styled subtree must recompute both selector
    // matches and inherited descendant values against the new parent chain.
    try parser.style(allocator, &root, rules);
    const moved_article = &root.element.children.items[1].element.children.items[0].element;
    const moved_strong = &moved_article.children.items[0].element;
    try std.testing.expectEqualStrings("green", moved_article.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("green", moved_strong.style.?.getPtr("color").?.get().*);
}

test "createElement detached ownership is released with the document" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(allocator, "<main></main>");
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);

    const result = try js.evaluate(0,
        \\var abandoned = document.createElement('DIV');
        \\var nested = document.createElement('span');
        \\abandoned.appendChild(nested);
        \\var removed = abandoned.removeChild(nested);
        \\removed === nested &&
        \\abandoned.children.length === 0 &&
        \\removed.getAttribute('missing') === null
    );
    try std.testing.expect(result.toBoolean());
    try std.testing.expectEqual(@as(usize, 2), js.windows.getPtr(0).?.detached_nodes.count());

    js.setNodes(0, null);
    try std.testing.expectEqual(@as(usize, 0), js.windows.getPtr(0).?.detached_nodes.count());
}

test "native style_set updates element style attribute" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var js = try Js.init(std.testing.allocator, std.testing.io, &environ);
    defer js.deinit(std.testing.allocator);

    const element = try parser.Element.init(std.testing.allocator, "div", null);
    var node = Node{ .element = element };
    defer node.deinit(std.testing.allocator);

    const window = try js.setCurrentWindow(0);
    const handle = try js.getHandle(window, &node);

    const builtins = kiesel.builtins;
    const self_ptr: *anyopaque = js;
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

test "native style_set starts a background-color transition from computed color" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style=\"background-color: #ff000080\"></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    try parser.style(allocator, &root, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\var box = document.querySelectorAll('div')[0];
        \\box.style = 'background-color: #0000ffff; transition: background-color 500ms';
        \\true
    );
    try std.testing.expect(result.toBoolean());

    const animation = root.element.animations.?.get("background-color").?;
    switch (animation) {
        .color => |color| {
            try std.testing.expectEqual(
                parser.CssColor{ .r = 255, .g = 0, .b = 0, .a = 128 },
                color.start_value,
            );
            try std.testing.expectEqual(
                parser.CssColor{ .r = 0, .g = 0, .b = 255, .a = 255 },
                color.end_value,
            );
            try std.testing.expectEqual(@as(u32, 30), color.total_frames);
            try std.testing.expectApproxEqAbs(
                parser.EasingFunction.ease.apply(0.5),
                color.easing_function.apply(0.5),
                0.000001,
            );
        },
        .numeric, .pixel, .transform => try std.testing.expect(false),
    }
}

test "native style_set starts simultaneous transform and opacity transitions" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style=\"opacity: 1; transform: translate(0px, 0px)\"></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    try parser.style(allocator, &root, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\var box = document.querySelectorAll('div')[0];
        \\box.style = 'opacity: 0.25; transform: translate(120px, 30px); transition: transform 1s ease-out, opacity 1s linear';
        \\true
    );
    try std.testing.expect(result.toBoolean());

    const animations = root.element.animations.?;
    switch (animations.get("opacity").?) {
        .numeric => |opacity| {
            try std.testing.expectEqual(@as(f64, 1.0), opacity.start_value);
            try std.testing.expectEqual(@as(f64, 0.25), opacity.end_value);
            try std.testing.expectApproxEqAbs(0.5, opacity.easing_function.apply(0.5), 0.000001);
        },
        .pixel, .color, .transform => try std.testing.expect(false),
    }
    switch (animations.get("transform").?) {
        .transform => |transform| {
            try std.testing.expectEqual(parser.Translation{ .x = 0, .y = 0 }, transform.start_value);
            try std.testing.expectEqual(parser.Translation{ .x = 120, .y = 30 }, transform.end_value);
            try std.testing.expectApproxEqAbs(
                parser.EasingFunction.ease_out.apply(0.5),
                transform.easing_function.apply(0.5),
                0.000001,
            );
        },
        .numeric, .pixel, .color => try std.testing.expect(false),
    }
}

test "native style_set starts width and height pixel transitions" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style=\"width: 120px; height: 40px\"></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    try parser.style(allocator, &root, &.{});

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);

    const result = try js.evaluate(0,
        \\var box = document.querySelectorAll('div')[0];
        \\box.style = 'width: 360px; height: 100px; transition: width 1s linear, height 2s ease-in';
        \\true
    );
    try std.testing.expect(result.toBoolean());

    const animations = root.element.animations.?;
    switch (animations.get("width").?) {
        .pixel => |width| {
            try std.testing.expectEqual(@as(f64, 120), width.numeric.start_value);
            try std.testing.expectEqual(@as(f64, 360), width.numeric.end_value);
            try std.testing.expectEqual(@as(u32, 60), width.numeric.total_frames);
        },
        .numeric, .color, .transform => try std.testing.expect(false),
    }
    switch (animations.get("height").?) {
        .pixel => |height| {
            try std.testing.expectEqual(@as(f64, 40), height.numeric.start_value);
            try std.testing.expectEqual(@as(f64, 100), height.numeric.end_value);
            try std.testing.expectEqual(@as(u32, 120), height.numeric.total_frames);
            try std.testing.expectApproxEqAbs(
                parser.EasingFunction.ease_in.apply(0.5),
                height.numeric.easing_function.apply(0.5),
                0.000001,
            );
        },
        .numeric, .color, .transform => try std.testing.expect(false),
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
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var js = try Js.init(std.testing.allocator, std.testing.io, &environ);
    defer js.deinit(std.testing.allocator);

    const element = try parser.Element.init(std.testing.allocator, "div", null);
    var node = Node{ .element = element };
    defer node.deinit(std.testing.allocator);

    const window = try js.setCurrentWindow(0);
    const handle = try js.getHandle(window, &node);

    var called = false;
    var ctx = RenderTestContext{ .called = &called };
    js.setRenderCallback(0, renderTestCallback, @ptrCast(&ctx));

    const builtins = kiesel.builtins;
    const self_ptr: *anyopaque = js;
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

/// Install document and native DOM bindings for a newly created realm.
fn setupDocument(self: *Js, realm: *Realm) !void {
    const host_context: *anyopaque = self;
    const native = try native_bindings.install(
        &self.agent,
        realm,
        host_context,
        &.{
            .{ .name = "querySelectorAll", .length = 1, .function = querySelectorAll },
        },
        &.{
            .{ .name = "getAttribute", .length = 2, .function = getAttribute },
            .{ .name = "children", .length = 1, .function = getChildren },
            .{ .name = "createElement", .length = 1, .function = createElement },
            .{ .name = "appendChild", .length = 2, .function = appendChild },
            .{ .name = "insertBefore", .length = 3, .function = insertBefore },
            .{ .name = "removeChild", .length = 2, .function = removeChild },
            .{ .name = "replaceChildren", .length = 1, .function = replaceChildren },
            .{ .name = "setAttribute", .length = 3, .function = setAttribute },
            .{ .name = "innerHTML", .length = 2, .function = innerHTML },
            .{ .name = "getInnerHTML", .length = 1, .function = getInnerHTML },
            .{ .name = "getOuterHTML", .length = 1, .function = getOuterHTML },
            .{ .name = "style_set", .length = 2, .function = styleSet },
        },
    );
    try native_bindings.installFunctions(
        &self.agent,
        realm,
        native,
        &self.canvas_host,
        &canvas_bindings.bindings,
    );
    try native_bindings.installFunctions(
        &self.agent,
        realm,
        native,
        &self.event_focus_host,
        &event_focus_bindings.bindings,
    );
    try native_bindings.installFunctions(
        &self.agent,
        realm,
        native,
        &self.network_host,
        &network_bindings.bindings,
    );
    try native_bindings.installFunctions(
        &self.agent,
        realm,
        native,
        &self.timer_host,
        &timer_bindings.bindings,
    );
}

/// document.querySelectorAll implementation
fn querySelectorAll(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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
    defer selector.deinit(js_instance.allocator);

    if (window.current_nodes == null) {
        const empty_array = try kiesel.builtins.arrayCreate(agent, 0, null);
        return Value.from(&empty_array.object);
    }

    var has_cache = CSSParser.HasMatchCache.init(js_instance.allocator);
    defer has_cache.deinit();
    selector.populateHasMatches(&has_cache, window.current_nodes.?) catch {
        return agent.throwException(.internal_error, "Could not match selector", .{});
    };
    const match_context = CSSParser.MatchContext{ .has_cache = &has_cache };

    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(js_instance.allocator);
    try parser.treeToList(js_instance.allocator, window.current_nodes.?, &node_list);

    var matching_handles = std.ArrayList(u32).empty;
    defer matching_handles.deinit(js_instance.allocator);

    for (node_list.items) |node| {
        var ancestors = std.ArrayList(*Node).empty;
        defer ancestors.deinit(js_instance.allocator);

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

        // Selector matching uses the same root-to-parent order as the style
        // traversal. Parent pointers naturally produced the reverse order.
        std.mem.reverse(*Node, ancestors.items);

        // Check if this node matches the selector
        const matches = selector.matchesWithContext(node, ancestors.items, match_context);
        if (matches) {
            const handle = try js_instance.getHandle(window, node);
            try matching_handles.append(js_instance.allocator, handle);
        }
    }

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
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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

/// __native.children implementation. The returned handle array is a snapshot
/// of immediate element children; text nodes and deeper descendants are not
/// exposed by this property.
fn getChildren(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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
            "children requires a numeric node handle",
            .{},
        );
    }
    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());
    const node = js_instance.getNode(window, handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );

    const child_count: usize = switch (node.*) {
        .text => 0,
        .element => |element| count: {
            var count: usize = 0;
            for (element.children.items) |child| {
                if (child == .element) count += 1;
            }
            break :count count;
        },
    };
    const result = try kiesel.builtins.arrayCreate(agent, @intCast(child_count), null);

    if (node.* == .element) {
        var output_index: usize = 0;
        for (node.element.children.items) |*child| {
            if (child.* != .element) continue;
            const child_handle = try js_instance.getHandle(window, child);
            try result.object.createDataPropertyDirect(
                agent,
                kiesel.types.PropertyKey.from(
                    @as(kiesel.types.PropertyKey.IntegerIndex, @intCast(output_index)),
                ),
                Value.from(@as(f64, @floatFromInt(child_handle))),
            );
            output_index += 1;
        }
    }

    return Value.from(&result.object);
}

fn isValidCreatedTagName(tag: []const u8) bool {
    if (tag.len == 0) return false;
    for (tag) |byte| {
        if (std.ascii.isWhitespace(byte) or switch (byte) {
            0, '<', '>', '/', '=', '"', '\'' => true,
            else => false,
        }) return false;
    }
    return true;
}

/// __native.createElement implementation. A created node is owned by its
/// WindowContext until appendChild/insertBefore transfers it into a DOM tree.
fn createElement(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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

    const tag_arg = arguments.get(0);
    if (!tag_arg.isString()) {
        return agent.throwException(.type_error, "createElement requires a tag name", .{});
    }
    const tag = try tag_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(tag);
    if (!isValidCreatedTagName(tag)) {
        return agent.throwException(.syntax_error, "Invalid element tag name", .{});
    }

    const owned_tag = try js_instance.allocator.dupe(u8, tag);
    var tag_owned = true;
    errdefer if (tag_owned) js_instance.allocator.free(owned_tag);
    for (owned_tag) |*byte| byte.* = std.ascii.toLower(byte.*);

    var element = parser.Element.init(js_instance.allocator, owned_tag, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return agent.throwException(.internal_error, "Could not create element", .{}),
    };
    var element_owned = true;
    errdefer if (element_owned) element.deinit(js_instance.allocator);
    if (element.owned_strings == null) {
        element.owned_strings = std.ArrayList([]const u8).empty;
    }
    try element.owned_strings.?.append(js_instance.allocator, owned_tag);
    tag_owned = false;

    const node = try js_instance.allocator.create(Node);
    var node_owned = true;
    errdefer if (node_owned) {
        node.deinit(js_instance.allocator);
        js_instance.allocator.destroy(node);
    };
    node.* = .{ .element = element };
    element_owned = false;

    try window.detached_nodes.ensureUnusedCapacity(1);
    const handle = try js_instance.getHandle(window, node);
    window.detached_nodes.putAssumeCapacity(node, {});
    node_owned = false;

    return Value.from(@as(f64, @floatFromInt(handle)));
}

fn appendChild(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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

    const parent_arg = arguments.get(0);
    const child_arg = arguments.get(1);
    if (!parent_arg.isNumber() or !child_arg.isNumber()) {
        return agent.throwException(.type_error, "appendChild requires two Nodes", .{});
    }
    const parent_handle: u32 = @intFromFloat(parent_arg.asNumber().asFloat());
    const child_handle: u32 = @intFromFloat(child_arg.asNumber().asFloat());
    const parent = js_instance.getNode(window, parent_handle) orelse return agent.throwException(
        .internal_error,
        "Invalid parent node handle",
        .{},
    );
    const child = js_instance.getNode(window, child_handle) orelse return agent.throwException(
        .internal_error,
        "Invalid child node handle",
        .{},
    );
    if (parent.* != .element) {
        return agent.throwException(.type_error, "Text nodes do not support appendChild", .{});
    }
    if (!window.detached_nodes.contains(child)) {
        return agent.throwException(.type_error, "appendChild requires a detached element", .{});
    }
    if (dom_mutation.isInclusiveAncestor(child, parent)) {
        return agent.throwException(.type_error, "appendChild would create a cycle", .{});
    }

    var mutation = js_instance.domMutationContext(window_id, window);
    try dom_mutation.insertDetachedChild(&mutation, parent, child, parent.element.children.items.len);
    return .undefined;
}

fn insertBefore(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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

    const parent_arg = arguments.get(0);
    const child_arg = arguments.get(1);
    if (!parent_arg.isNumber() or !child_arg.isNumber()) {
        return agent.throwException(.type_error, "insertBefore requires parent and child Nodes", .{});
    }
    const parent_handle: u32 = @intFromFloat(parent_arg.asNumber().asFloat());
    const child_handle: u32 = @intFromFloat(child_arg.asNumber().asFloat());
    const parent = js_instance.getNode(window, parent_handle) orelse return agent.throwException(
        .internal_error,
        "Invalid parent node handle",
        .{},
    );
    const child = js_instance.getNode(window, child_handle) orelse return agent.throwException(
        .internal_error,
        "Invalid child node handle",
        .{},
    );
    if (parent.* != .element) {
        return agent.throwException(.type_error, "Text nodes do not support insertBefore", .{});
    }
    if (!window.detached_nodes.contains(child)) {
        return agent.throwException(.type_error, "insertBefore requires a detached element", .{});
    }
    if (dom_mutation.isInclusiveAncestor(child, parent)) {
        return agent.throwException(.type_error, "insertBefore would create a cycle", .{});
    }

    const reference_arg = arguments.get(2);
    const insert_index = if (reference_arg.isNull())
        parent.element.children.items.len
    else index: {
        if (!reference_arg.isNumber()) {
            return agent.throwException(.type_error, "insertBefore reference must be a Node or null", .{});
        }
        const reference_handle: u32 = @intFromFloat(reference_arg.asNumber().asFloat());
        const reference = js_instance.getNode(window, reference_handle) orelse return agent.throwException(
            .internal_error,
            "Invalid reference node handle",
            .{},
        );
        break :index dom_mutation.directChildIndex(parent, reference) orelse return agent.throwException(
            .type_error,
            "insertBefore reference is not a child of this node",
            .{},
        );
    };

    var mutation = js_instance.domMutationContext(window_id, window);
    try dom_mutation.insertDetachedChild(&mutation, parent, child, insert_index);
    return .undefined;
}

fn removeChild(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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

    const parent_arg = arguments.get(0);
    const child_arg = arguments.get(1);
    if (!parent_arg.isNumber() or !child_arg.isNumber()) {
        return agent.throwException(.type_error, "removeChild requires two Nodes", .{});
    }
    const parent_handle: u32 = @intFromFloat(parent_arg.asNumber().asFloat());
    const child_handle: u32 = @intFromFloat(child_arg.asNumber().asFloat());
    const parent = js_instance.getNode(window, parent_handle) orelse return agent.throwException(
        .internal_error,
        "Invalid parent node handle",
        .{},
    );
    const child = js_instance.getNode(window, child_handle) orelse return agent.throwException(
        .internal_error,
        "Invalid child node handle",
        .{},
    );
    if (parent.* != .element) {
        return agent.throwException(.type_error, "Text nodes do not support removeChild", .{});
    }
    const remove_index = dom_mutation.directChildIndex(parent, child) orelse return agent.throwException(
        .type_error,
        "removeChild target is not a child of this node",
        .{},
    );

    var mutation = js_instance.domMutationContext(window_id, window);
    try dom_mutation.detachChild(&mutation, parent, child, remove_index);
    return .undefined;
}

/// __native.replaceChildren implementation. The first argument is the receiver
/// handle and each remaining argument is an Element handle supplied by the
/// variadic JavaScript wrapper.
fn replaceChildren(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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
        return agent.throwException(.type_error, "replaceChildren requires a Node", .{});
    }
    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());
    const node = js_instance.getNode(window, handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );
    if (node.* != .element) {
        return agent.throwException(.type_error, "Text nodes do not support replaceChildren", .{});
    }

    if (arguments.count() == 1) {
        var mutation = js_instance.domMutationContext(window_id, window);
        try dom_mutation.emptyElementChildren(&mutation, node);
        return .undefined;
    }

    var child_nodes = std.ArrayList(*Node).empty;
    defer child_nodes.deinit(js_instance.allocator);
    try child_nodes.ensureTotalCapacity(js_instance.allocator, arguments.count() - 1);
    var argument_index: usize = 1;
    while (argument_index < arguments.count()) : (argument_index += 1) {
        const child_arg = arguments.get(argument_index);
        if (!child_arg.isNumber()) {
            return agent.throwException(.type_error, "replaceChildren arguments must be Elements", .{});
        }
        const child_handle: u32 = @intFromFloat(child_arg.asNumber().asFloat());
        const child = js_instance.getNode(window, child_handle) orelse return agent.throwException(
            .internal_error,
            "Invalid replacement child handle",
            .{},
        );
        if (child.* != .element) {
            return agent.throwException(.type_error, "replaceChildren arguments must be Elements", .{});
        }
        if (dom_mutation.isInclusiveAncestor(child, node)) {
            return agent.throwException(.type_error, "replaceChildren would create a cycle", .{});
        }
        if (!window.detached_nodes.contains(child)) {
            const parent = dom_mutation.nodeParent(child) orelse return agent.throwException(
                .type_error,
                "replaceChildren cannot transfer a document root",
                .{},
            );
            if (dom_mutation.directChildIndex(parent, child) == null) {
                return agent.throwException(.internal_error, "Replacement child has an invalid parent", .{});
            }
        }
        child_nodes.appendAssumeCapacity(child);
    }

    var mutation = js_instance.domMutationContext(window_id, window);
    try dom_mutation.transferElementChildren(&mutation, node, child_nodes.items);
    return .undefined;
}

/// __native.setAttribute implementation
fn setAttribute(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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

            try e.attributes.?.ensureUnusedCapacity(1);
            try e.owned_strings.?.ensureUnusedCapacity(js_instance.allocator, 2);

            const owned_name = try js_instance.allocator.dupe(u8, attr_name);
            var name_owned = true;
            errdefer if (name_owned) js_instance.allocator.free(owned_name);
            const owned_value = try js_instance.allocator.dupe(u8, attr_value);
            var value_owned = true;
            errdefer if (value_owned) js_instance.allocator.free(owned_value);

            const refresh_id_globals = std.mem.eql(u8, attr_name, "id") and
                dom_mutation.isAttachedToCurrentDocument(window.current_nodes, node);
            if (refresh_id_globals) {
                try js_instance.clearNamedIdGlobals(window_id, window);
            }

            e.owned_strings.?.appendAssumeCapacity(owned_name);
            name_owned = false;
            e.owned_strings.?.appendAssumeCapacity(owned_value);
            value_owned = false;
            e.attributes.?.putAssumeCapacity(owned_name, owned_value);
            parser.dirtyStyleForElement(e);

            const canvas_dimension = std.ascii.eqlIgnoreCase(e.tag, "canvas") and
                (std.ascii.eqlIgnoreCase(attr_name, "width") or
                    std.ascii.eqlIgnoreCase(attr_name, "height"));
            if ((std.mem.eql(u8, e.tag, "img") or
                std.mem.eql(u8, e.tag, "iframe") or
                std.mem.eql(u8, e.tag, "canvas")) and
                (std.mem.eql(u8, attr_name, "width") or std.mem.eql(u8, attr_name, "height")))
            {
                e.markChildrenDirty();
                dom_mutation.markElementLayoutDirty(e);
            }
            if (canvas_dimension) {
                if (e.canvas) |canvas| {
                    const dimensions = e.canvasDimensions();
                    canvas.reset(dimensions.width, dimensions.height) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return agent.throwException(
                            .internal_error,
                            "Could not reset canvas backing store",
                            .{},
                        ),
                    };
                }
            }

            // Attribute ownership and dirty state are already committed. A
            // later allocation failure while rebuilding ID wrappers must not
            // suppress the corresponding browser render.
            js_instance.requestRender();
            if (refresh_id_globals) {
                try js_instance.syncNamedIdGlobals(window_id, window);
            }
            return Value.from(canvas_dimension);
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

fn serializeHTMLProperty(
    agent: *Agent,
    arguments: kiesel.types.Arguments,
    include_element: bool,
) Agent.Error!Value {
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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
            "HTML serialization requires a numeric node handle",
            .{},
        );
    }
    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());
    const node = js_instance.getNode(window, handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );
    if (node.* != .element) {
        return agent.throwException(
            .type_error,
            "HTML serialization requires an Element",
            .{},
        );
    }

    // Kiesel's ASCII String constructor takes ownership of a previously
    // unseen input slice. Allocate in the Agent's traced heap and deliberately
    // transfer that buffer instead of freeing it when this host call returns.
    const html = if (include_element)
        parser.serializeOuterHtml(agent.gc_allocator, node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return agent.throwException(.internal_error, "Could not serialize outerHTML", .{}),
        }
    else
        parser.serializeInnerHtml(agent.gc_allocator, node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return agent.throwException(.internal_error, "Could not serialize innerHTML", .{}),
        };
    return Value.from(try kiesel.types.String.fromUtf8(agent, html));
}

/// __native.getInnerHTML serializes the live children instead of replaying the
/// string most recently assigned to the setter.
fn getInnerHTML(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    _ = this_value;
    return serializeHTMLProperty(agent, arguments, false);
}

/// __native.getOuterHTML includes the current element start/end tags.
fn getOuterHTML(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    _ = this_value;
    return serializeHTMLProperty(agent, arguments, true);
}

/// __native.innerHTML setter implementation.
fn innerHTML(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    // Get the Js instance from the function's additional_fields
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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
            // Stage the only allocation needed by the installed replacement
            // before exposing any of its source-backed nodes through the DOM.
            if (e.owned_strings == null) {
                e.owned_strings = std.ArrayList([]const u8).empty;
            }
            try e.owned_strings.?.ensureUnusedCapacity(js_instance.allocator, 1);
            const is_attached = dom_mutation.isAttachedToCurrentDocument(window.current_nodes, node);
            if (is_attached) {
                try js_instance.clearNamedIdGlobals(window_id, window);
            }

            // Child arrays store Nodes by value. Retire every browser-side
            // borrower before destroying the old nodes or replacing their
            // backing array. Dirty state and repaint scheduling are published
            // before this point, so any later failure remains recoverable.
            e.markChildrenDirty();
            dom_mutation.markElementLayoutDirty(e);
            if (is_attached) prepareDomMutation(js_instance, node, .structural);

            for (e.children.items) |*child| {
                dom_mutation.removeHandlesForSubtree(&window.handles, child);
                child.deinit(js_instance.allocator);
            }
            e.children.deinit(js_instance.allocator);
            e.children = body_children;
            body_children = std.ArrayList(Node).empty;

            e.owned_strings.?.appendAssumeCapacity(wrapped_html);
            wrapped_cleanup = false;

            parser.fixParentPointers(node, e.parent);

            if (is_attached) {
                completeDomMutation(js_instance, node);
                try js_instance.syncNamedIdGlobals(window_id, window);
            }
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
    const js_instance = builtin_fn.fields.additionalFieldsAs(Js);
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

            // Capture current computed values before replacing the inline
            // declaration. An interrupted transition therefore starts from
            // its currently painted value rather than its original endpoint.
            var old_opacity = transitions.currentAnimatedOpacity(e);
            var old_background_color = transitions.currentAnimatedBackgroundColor(e);
            var old_transform = transitions.currentAnimatedTransform(e);
            var old_width = transitions.currentAnimatedPixel(e, "width");
            var old_height = transitions.currentAnimatedPixel(e, "height");
            if (e.style) |*style_map| {
                if (old_opacity == null) {
                    if (style_map.getPtr("opacity")) |field| {
                        old_opacity = std.fmt.parseFloat(f64, field.lastValue().*) catch null;
                    }
                }
                if (old_background_color == null) {
                    if (style_map.getPtr("background-color")) |field| {
                        old_background_color = parser.parseCssColor(field.lastValue().*);
                    }
                }
                if (old_transform == null) {
                    if (style_map.getPtr("transform")) |field| {
                        old_transform = parser.parseTranslate(field.lastValue().*);
                    }
                }
                if (old_width == null) {
                    if (style_map.getPtr("width")) |field| {
                        old_width = PixelAnimation.parse(field.lastValue().*);
                    }
                }
                if (old_height == null) {
                    if (style_map.getPtr("height")) |field| {
                        old_height = PixelAnimation.parse(field.lastValue().*);
                    }
                }
            }

            // Replacing the complete inline style cancels transitions that
            // are not explicitly restarted below. Capture their current
            // values first so an interrupted replacement remains continuous.
            if (e.animations) |*animations| {
                for (parser.css_animation_properties) |property| {
                    if (e.css_animation) |state| {
                        if (!state.finished and state.contains(property)) continue;
                    }
                    _ = animations.remove(property);
                }
            }

            const owned_style = try js_instance.allocator.dupe(u8, style_str);
            if (e.owned_strings == null) {
                e.owned_strings = std.ArrayList([]const u8).empty;
            }
            try e.owned_strings.?.append(js_instance.allocator, owned_style);
            try e.attributes.?.put("style", owned_style);

            // Parse new style to check for opacity changes and transitions
            const style_result = transitions.parseInlineStyle(js_instance.allocator, style_str);
            if (style_result) |ns| {
                var new_style = ns;
                defer new_style.deinit();

                // Check for transition definition
                if (new_style.get("transition")) |transition_str| {
                    var transition_list = transitions.TransitionListIterator.init(transition_str);
                    while (transition_list.next()) |transition_part| {
                        const transition = transitions.parseTransitionValue(transition_part) orelse continue;
                        const canonical_property: ?[]const u8 = for (parser.css_animation_properties) |property| {
                            if (std.ascii.eqlIgnoreCase(transition.property, property)) break property;
                        } else null;
                        if (canonical_property) |property| {
                            if (e.css_animation) |state| {
                                if (!state.finished and state.contains(property)) continue;
                            }
                        }
                        if (std.ascii.eqlIgnoreCase(transition.property, "opacity")) {
                            // Get new opacity value
                            if (new_style.get("opacity")) |new_op_str| {
                                const new_opacity = std.fmt.parseFloat(f64, new_op_str) catch null;
                                if (new_opacity != null and old_opacity != null and old_opacity.? != new_opacity.?) {
                                    // Start animation from old to new value
                                    transitions.startOpacityAnimation(
                                        js_instance.allocator,
                                        e,
                                        old_opacity.?,
                                        new_opacity.?,
                                        transition.frames,
                                        transition.easing_function,
                                    ) catch |err| {
                                        std.log.warn("Failed to start opacity animation: {}", .{err});
                                    };
                                }
                            }
                        } else if (std.ascii.eqlIgnoreCase(transition.property, "background-color")) {
                            if (new_style.get("background-color")) |new_color_str| {
                                const new_color = parser.parseCssColor(new_color_str);
                                if (new_color != null and old_background_color != null and
                                    !std.meta.eql(old_background_color.?, new_color.?))
                                {
                                    transitions.startBackgroundColorAnimation(
                                        js_instance.allocator,
                                        e,
                                        old_background_color.?,
                                        new_color.?,
                                        transition.frames,
                                        transition.easing_function,
                                    ) catch |err| {
                                        std.log.warn("Failed to start background-color animation: {}", .{err});
                                    };
                                }
                            }
                        } else if (std.ascii.eqlIgnoreCase(transition.property, "transform")) {
                            if (new_style.get("transform")) |new_transform_str| {
                                const new_transform = parser.parseTranslate(new_transform_str);
                                if (new_transform != null and old_transform != null and
                                    !old_transform.?.eql(new_transform.?))
                                {
                                    transitions.startTransformAnimation(
                                        js_instance.allocator,
                                        e,
                                        old_transform.?,
                                        new_transform.?,
                                        transition.frames,
                                        transition.easing_function,
                                    ) catch |err| {
                                        std.log.warn("Failed to start transform animation: {}", .{err});
                                    };
                                }
                            }
                        } else if (std.ascii.eqlIgnoreCase(transition.property, "width") or
                            std.ascii.eqlIgnoreCase(transition.property, "height"))
                        {
                            const property: []const u8 = if (std.ascii.eqlIgnoreCase(
                                transition.property,
                                "width",
                            )) "width" else "height";
                            const old_value = if (std.mem.eql(u8, property, "width"))
                                old_width
                            else
                                old_height;
                            if (new_style.get(property)) |new_value_str| {
                                const new_value = PixelAnimation.parse(new_value_str);
                                if (new_value != null and old_value != null and
                                    old_value.? != new_value.?)
                                {
                                    transitions.startPixelAnimation(
                                        js_instance.allocator,
                                        e,
                                        property,
                                        old_value.?,
                                        new_value.?,
                                        transition.frames,
                                        transition.easing_function,
                                    ) catch |err| {
                                        std.log.warn("Failed to start {s} animation: {}", .{ property, err });
                                    };
                                }
                            }
                        }
                    }
                }
            } else |_| {}

            parser.dirtyStyleForElement(e);
            dom_mutation.markElementLayoutDirty(e);

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
