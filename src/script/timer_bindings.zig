//! Native scheduling bindings for timers and animation-frame requests.
//!
//! JavaScript callback registries stay in the embedded runtime. This module
//! only validates scheduling arguments and forwards scalar work through a
//! heap-stable host interface; it never retains a DOM or Frame pointer.

const std = @import("std");
const kiesel = @import("kiesel");
const native_bindings = @import("native_bindings.zig");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Value = kiesel.types.Value;

pub const SetTimeoutCallbackFn = *const fn (
    context: ?*anyopaque,
    handle: u32,
    delay_ms: u32,
    is_interval: bool,
) anyerror!void;

pub const ClearIntervalCallbackFn = *const fn (
    context: ?*anyopaque,
    handle: u32,
) void;

pub const AnimationFrameCallbackFn = *const fn (context: ?*anyopaque) anyerror!void;

pub const Host = struct {
    context: ?*anyopaque,
    schedule: *const fn (?*anyopaque, u32, u32, bool) anyerror!void,
    clear: *const fn (?*anyopaque, u32) void,
    request_animation_frame: *const fn (?*anyopaque) anyerror!void,
};

pub const bindings = [_]native_bindings.Binding{
    .{ .name = "setTimeout", .length = 2, .function = setTimeout },
    .{ .name = "clearInterval", .length = 1, .function = clearInterval },
    .{ .name = "requestAnimationFrame", .length = 0, .function = requestAnimationFrame },
};

fn activeHost(agent: *Agent) *Host {
    const function = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction);
    return function.fields.additionalFieldsAs(Host);
}

fn timerHandle(raw: f64) ?u32 {
    const max_handle = @as(f64, @floatFromInt(std.math.maxInt(u32)));
    if (!std.math.isFinite(raw) or raw < 0 or raw > max_handle) return null;
    return @intFromFloat(raw);
}

fn timerDelay(raw: f64) u32 {
    if (std.math.isNan(raw) or raw <= 0) return 0;
    const max_delay = @as(f64, @floatFromInt(std.math.maxInt(u32)));
    return @intFromFloat(@min(raw, max_delay));
}

fn setTimeout(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(.type_error, "setTimeout requires a numeric handle", .{});
    }

    const handle = timerHandle(handle_arg.asNumber().asFloat()) orelse {
        return agent.throwException(.type_error, "setTimeout handle must be a valid number", .{});
    };

    var delay_ms: u32 = 0;
    if (arguments.count() >= 2) {
        const delay_arg = arguments.get(1);
        if (delay_arg.isNumber()) {
            delay_ms = timerDelay(delay_arg.asNumber().asFloat());
        }
    }

    const is_interval = arguments.count() >= 3 and arguments.get(2).toBoolean();
    const host = activeHost(agent);
    host.schedule(host.context, handle, delay_ms, is_interval) catch |err| {
        if (err == error.MissingActiveWindow or err == error.MissingWindowContext) {
            return agent.throwException(.internal_error, "Missing active window", .{});
        }
        std.log.warn("Failed to schedule setTimeout callback: {}", .{err});
    };
    return .undefined;
}

fn clearInterval(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) return .undefined;
    const handle = timerHandle(handle_arg.asNumber().asFloat()) orelse return .undefined;

    const host = activeHost(agent);
    host.clear(host.context, handle);
    return .undefined;
}

fn requestAnimationFrame(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    _ = arguments;
    const host = activeHost(agent);
    host.request_animation_frame(host.context) catch |err| {
        if (err == error.MissingActiveWindow or err == error.MissingWindowContext) {
            return agent.throwException(.internal_error, "Missing active window", .{});
        }
        std.log.warn("Failed to schedule animation frame: {}", .{err});
    };
    return .undefined;
}

test "native timer scalars reject invalid handles and clamp delays" {
    try std.testing.expectEqual(@as(?u32, 12), timerHandle(12));
    try std.testing.expect(timerHandle(-1) == null);
    try std.testing.expect(timerHandle(std.math.inf(f64)) == null);
    try std.testing.expectEqual(@as(u32, 0), timerDelay(-1));
    try std.testing.expectEqual(@as(u32, 0), timerDelay(std.math.nan(f64)));
    try std.testing.expectEqual(@as(u32, 25), timerDelay(25.9));
    try std.testing.expectEqual(std.math.maxInt(u32), timerDelay(std.math.inf(f64)));
}
