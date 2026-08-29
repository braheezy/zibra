//! Network-facing JavaScript bindings for cookies, XHR, and postMessage.
//!
//! Request policy and I/O remain browser-owned. Native calls validate and
//! copy JavaScript values synchronously, then invoke a narrow host interface;
//! no temporary string or page pointer is retained by this module.

const std = @import("std");
const kiesel = @import("kiesel");
const native_bindings = @import("native_bindings.zig");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Value = kiesel.types.Value;

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

pub const CookieResult = struct {
    data: []const u8,
    allocator: ?std.mem.Allocator = null,
    should_free: bool = false,
};

pub const CookieGetCallbackFn = *const fn (context: ?*anyopaque) anyerror!CookieResult;
pub const CookieSetCallbackFn = *const fn (context: ?*anyopaque, value: []const u8) anyerror!void;

pub const PostMessageCallbackFn = *const fn (
    context: ?*anyopaque,
    source_window_id: u32,
    target_window_id: u32,
    target_origin: []const u8,
    message: []const u8,
) anyerror!void;

pub const Host = struct {
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    current_window_id: *const fn (?*anyopaque) ?u32,
    parent_window_id: *const fn (?*anyopaque, u32) ?u32,
    cookie_get: *const fn (?*anyopaque) anyerror!CookieResult,
    cookie_set: *const fn (?*anyopaque, []const u8) anyerror!void,
    xhr_send: *const fn (
        ?*anyopaque,
        []const u8,
        []const u8,
        ?[]const u8,
        bool,
        u32,
    ) anyerror!XhrResult,
    post_message: *const fn (
        ?*anyopaque,
        u32,
        u32,
        []const u8,
        []const u8,
    ) anyerror!void,
};

pub const bindings = [_]native_bindings.Binding{
    .{ .name = "cookieGet", .length = 0, .function = cookieGet },
    .{ .name = "cookieSet", .length = 1, .function = cookieSet },
    .{ .name = "xhrSend", .length = 5, .function = xhrSend },
    .{ .name = "getWindowId", .length = 0, .function = getWindowId },
    .{ .name = "getParentWindowId", .length = 1, .function = getParentWindowId },
    .{ .name = "postMessage", .length = 3, .function = postMessage },
};

fn activeHost(agent: *Agent) *Host {
    const function = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction);
    return function.fields.additionalFieldsAs(Host);
}

fn requireWindowId(agent: *Agent, host: *Host) Agent.Error!u32 {
    return host.current_window_id(host.context) orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
}

fn cookieGet(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    _ = try requireWindowId(agent, host);

    const result = host.cookie_get(host.context) catch |err| {
        std.log.err("document.cookie read failed: {}", .{err});
        return agent.throwException(.type_error, "document.cookie read failed", .{});
    };
    defer if (result.should_free) {
        if (result.allocator) |allocator| {
            allocator.free(result.data);
        } else {
            host.allocator.free(result.data);
        }
    };

    // Kiesel may retain ASCII input in its string cache. Move callback-owned
    // bytes into the traced heap before releasing them at the native boundary.
    const stable_data = if (result.data.len == 0)
        result.data
    else
        try agent.gc_allocator.dupe(u8, result.data);
    return Value.from(try kiesel.types.String.fromUtf8(agent, stable_data));
}

fn cookieSet(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    _ = try requireWindowId(agent, host);
    const value_arg = arguments.get(0);
    if (!value_arg.isString()) {
        return agent.throwException(.type_error, "document.cookie value must be a string", .{});
    }
    const value = try value_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(value);
    host.cookie_set(host.context, value) catch |err| {
        std.log.err("document.cookie write failed: {}", .{err});
        return agent.throwException(.type_error, "document.cookie write failed", .{});
    };
    return .undefined;
}

fn xhrSend(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    _ = try requireWindowId(agent, host);

    const method_arg = arguments.get(0);
    if (!method_arg.isString()) {
        return agent.throwException(.type_error, "XMLHttpRequest method must be a string", .{});
    }
    const method = try method_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(method);

    const url_arg = arguments.get(1);
    if (!url_arg.isString()) {
        return agent.throwException(.type_error, "XMLHttpRequest URL must be a string", .{});
    }
    const url = try url_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(url);

    var body: ?[]const u8 = null;
    if (arguments.count() >= 3) {
        const body_arg = arguments.get(2);
        if (!body_arg.isUndefined() and !body_arg.isNull()) {
            if (!body_arg.isString()) {
                return agent.throwException(.type_error, "XMLHttpRequest body must be a string", .{});
            }
            body = try body_arg.asString().toUtf8(host.allocator);
        }
    }
    defer if (body) |owned| host.allocator.free(owned);

    const is_async = arguments.count() >= 4 and arguments.get(3).toBoolean();
    if (arguments.count() < 5) {
        return agent.throwException(.type_error, "XMLHttpRequest handle missing", .{});
    }
    const handle_arg = arguments.get(4);
    if (!handle_arg.isNumber()) {
        return agent.throwException(.type_error, "XMLHttpRequest handle must be numeric", .{});
    }
    const raw_handle = handle_arg.asNumber().asFloat();
    const max_handle = @as(f64, @floatFromInt(std.math.maxInt(u32)));
    if (!std.math.isFinite(raw_handle) or raw_handle < 0 or raw_handle > max_handle) {
        return agent.throwException(.type_error, "Invalid XMLHttpRequest handle", .{});
    }
    const handle: u32 = @intFromFloat(raw_handle);

    const result = host.xhr_send(host.context, method, url, body, is_async, handle) catch |err| {
        if (err == error.XmlHttpRequestUnavailable) {
            return agent.throwException(.type_error, "XMLHttpRequest is not available", .{});
        }
        if (err == error.CrossOriginBlocked) {
            return agent.throwException(.type_error, "Cross-origin XMLHttpRequest not allowed", .{});
        }
        if (err == error.CspViolation) {
            return agent.throwException(.type_error, "XMLHttpRequest blocked by Content-Security-Policy", .{});
        }
        std.log.err("XMLHttpRequest failed: {}", .{err});
        return agent.throwException(.type_error, "XMLHttpRequest failed", .{});
    };

    if (is_async) return .undefined;
    defer if (result.should_free) {
        if (result.allocator) |allocator| {
            allocator.free(result.data);
        } else {
            host.allocator.free(result.data);
        }
    };
    const stable_data = if (result.data.len == 0)
        result.data
    else
        try agent.gc_allocator.dupe(u8, result.data);
    return Value.from(try kiesel.types.String.fromUtf8(agent, stable_data));
}

fn getWindowId(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    return Value.from(@as(f64, @floatFromInt(try requireWindowId(agent, host))));
}

fn getParentWindowId(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const id_arg = arguments.get(0);
    if (!id_arg.isNumber()) {
        return agent.throwException(.type_error, "getParentWindowId requires a numeric window id", .{});
    }
    const raw_id = id_arg.asNumber().asFloat();
    const max_id = @as(f64, @floatFromInt(std.math.maxInt(u32)));
    if (!std.math.isFinite(raw_id) or raw_id < 0 or raw_id > max_id) {
        return agent.throwException(.type_error, "getParentWindowId requires a valid window id", .{});
    }
    const parent_id = host.parent_window_id(host.context, @intFromFloat(raw_id)) orelse return .null;
    // A cross-origin parent intentionally has no DOM realm here. JavaScript
    // receives only an opaque numeric proxy exposing postMessage.
    return Value.from(@as(f64, @floatFromInt(parent_id)));
}

fn postMessage(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const source_window_id = try requireWindowId(agent, host);
    const message_arg = arguments.get(0);
    const target_id_arg = arguments.get(1);
    const target_origin_arg = arguments.get(2);
    if (!target_id_arg.isNumber()) {
        return agent.throwException(.type_error, "postMessage requires a numeric target window id", .{});
    }
    if (!target_origin_arg.isString()) {
        return agent.throwException(.type_error, "postMessage requires a string target origin", .{});
    }

    const message_string = try message_arg.toString(agent);
    const message = try message_string.toUtf8(host.allocator);
    defer host.allocator.free(message);
    const target_origin = try target_origin_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(target_origin);

    const raw_target_id = target_id_arg.asNumber().asFloat();
    const max_id = @as(f64, @floatFromInt(std.math.maxInt(u32)));
    if (!std.math.isFinite(raw_target_id) or raw_target_id < 0 or raw_target_id > max_id) {
        return agent.throwException(.type_error, "postMessage requires a valid target window id", .{});
    }
    host.post_message(
        host.context,
        source_window_id,
        @intFromFloat(raw_target_id),
        target_origin,
        message,
    ) catch |err| {
        if (err == error.InvalidTargetOrigin) {
            return agent.throwException(.syntax_error, "Invalid postMessage target origin", .{});
        }
        return agent.throwException(.internal_error, "postMessage failed: {any}", .{err});
    };
    return .undefined;
}
