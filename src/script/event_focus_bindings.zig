//! Native bindings shared by DOM event bubbling and programmatic focus.
//!
//! An active-window borrow is valid only for the duration of one Kiesel
//! callback. Event paths immediately convert raw Nodes to stable numeric
//! handles, and focus forwards only the validated handle to the browser.

const std = @import("std");
const kiesel = @import("kiesel");
const parser = @import("../document/parser.zig");
const dom_focus = @import("../document/focus.zig");
const DomHandles = @import("dom_handles.zig").Store;
const dom_mutation = @import("dom_mutation.zig");
const native_bindings = @import("native_bindings.zig");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Value = kiesel.types.Value;

pub const FocusCallbackFn = *const fn (context: ?*anyopaque, handle: u32) anyerror!void;

pub const WindowBorrow = struct {
    current_nodes: ?*parser.Node,
    handles: *DomHandles,
    focus_context: ?*anyopaque,
    focus: ?FocusCallbackFn,
};

pub const Host = struct {
    context: ?*anyopaque,
    active_window: *const fn (?*anyopaque) ?WindowBorrow,
};

pub const bindings = [_]native_bindings.Binding{
    .{ .name = "eventPath", .length = 1, .function = eventPath },
    .{ .name = "focus", .length = 1, .function = focusNode },
};

fn activeHost(agent: *Agent) *Host {
    const function = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction);
    return function.fields.additionalFieldsAs(Host);
}

/// Snapshot target-to-root handles before any listener can relocate Nodes.
fn eventPath(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const window = host.active_window(host.context) orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(.type_error, "eventPath requires a numeric node handle", .{});
    }
    const raw_handle = handle_arg.asNumber().asFloat();
    const max_handle = @as(f64, @floatFromInt(std.math.maxInt(u32)));
    if (!std.math.isFinite(raw_handle) or raw_handle < 0 or raw_handle > max_handle) {
        return agent.throwException(.internal_error, "Invalid node handle", .{});
    }
    const target = window.handles.resolve(@intFromFloat(raw_handle)) orelse
        return agent.throwException(.internal_error, "Invalid node handle", .{});

    var path_length: usize = 1;
    var ancestor = dom_mutation.nodeParent(target);
    while (ancestor) |node| : (ancestor = dom_mutation.nodeParent(node)) path_length += 1;

    const result = try kiesel.builtins.arrayCreate(agent, @intCast(path_length), null);
    var current: ?*parser.Node = target;
    var index: usize = 0;
    while (current) |node| : (current = dom_mutation.nodeParent(node)) {
        const handle = try window.handles.getOrCreate(node);
        try result.object.createDataPropertyDirect(
            agent,
            kiesel.types.PropertyKey.from(
                @as(kiesel.types.PropertyKey.IntegerIndex, @intCast(index)),
            ),
            Value.from(@as(f64, @floatFromInt(handle))),
        );
        index += 1;
    }
    return Value.from(&result.object);
}

/// Detached, text, hidden, disabled, and otherwise non-focusable Nodes are
/// silent no-ops. Layout-dependent visibility is checked by the browser after
/// its callback synchronously brings style and layout up to date.
fn focusNode(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const window = host.active_window(host.context) orelse return .undefined;
    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) return .undefined;
    const raw_handle = handle_arg.asNumber().asFloat();
    const max_handle = @as(f64, @floatFromInt(std.math.maxInt(u32)));
    if (!std.math.isFinite(raw_handle) or raw_handle < 0 or raw_handle > max_handle) return .undefined;
    const handle: u32 = @intFromFloat(raw_handle);
    const node = window.handles.resolve(handle) orelse return .undefined;
    if (!dom_mutation.isAttachedToCurrentDocument(window.current_nodes, node)) return .undefined;
    const element = switch (node.*) {
        .element => |*value| value,
        .text => return .undefined,
    };
    if (!dom_focus.isProgrammaticallyFocusable(element)) return .undefined;

    if (window.focus) |callback| {
        callback(window.focus_context, handle) catch |err| {
            std.log.warn("Failed to focus DOM element: {}", .{err});
        };
    }
    return .undefined;
}
