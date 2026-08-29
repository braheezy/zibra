//! Native CanvasRenderingContext2D bindings.
//!
//! The Kiesel callback stores a pointer to a heap-stable `Host`. Node and
//! Element pointers returned by `resolve_element` are synchronous borrows and
//! must not escape the native call.

const std = @import("std");
const kiesel = @import("kiesel");
const parser = @import("../document/parser.zig");
const native_bindings = @import("native_bindings.zig");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Value = kiesel.types.Value;

pub const Host = struct {
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    resolve_element: *const fn (?*anyopaque, u32) ?*parser.Element,
    request_render: *const fn (?*anyopaque) void,
};

pub const bindings = [_]native_bindings.Binding{
    .{ .name = "canvasGetContext", .length = 2, .function = getContext },
    .{ .name = "canvasDimension", .length = 2, .function = dimension },
    .{ .name = "canvasCommand", .length = 13, .function = command },
};

fn activeHost(agent: *Agent) *Host {
    const function = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction);
    return function.fields.additionalFieldsAs(Host);
}

fn canvasElement(host: *Host, handle: u32) ?*parser.Element {
    const element = host.resolve_element(host.context, handle) orelse return null;
    if (!std.ascii.eqlIgnoreCase(element.tag, "canvas")) return null;
    return element;
}

fn ensureBacking(agent: *Agent, host: *Host, element: *parser.Element) Agent.Error!*parser.Canvas {
    const dimensions = element.canvasDimensions();
    if (element.canvas == null) {
        element.canvas = parser.Canvas.create(
            host.allocator,
            host.io,
            dimensions.width,
            dimensions.height,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return agent.throwException(
                .internal_error,
                "Could not allocate canvas backing store",
                .{},
            ),
        };
    } else {
        element.canvas.?.resize(dimensions.width, dimensions.height) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return agent.throwException(
                .internal_error,
                "Could not resize canvas backing store",
                .{},
            ),
        };
    }
    return element.canvas.?;
}

/// Allocate (or return) the one 2D backing store for a canvas element. The JS
/// runtime owns wrapper identity; this native seam owns only z2d state.
fn getContext(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const handle_arg = arguments.get(0);
    const type_arg = arguments.get(1);
    if (!handle_arg.isNumber() or !type_arg.isString()) return Value.from(@as(f64, 0));
    const raw_handle = handle_arg.asNumber().asFloat();
    if (!std.math.isFinite(raw_handle) or raw_handle < 0 or raw_handle > std.math.maxInt(u32)) {
        return Value.from(@as(f64, 0));
    }
    const context_type = try type_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(context_type);
    if (!std.mem.eql(u8, context_type, "2d")) return Value.from(@as(f64, 0));

    const element = canvasElement(host, @intFromFloat(raw_handle)) orelse
        return Value.from(@as(f64, 0));
    _ = try ensureBacking(agent, host, element);
    return Value.from(@as(f64, 1));
}

/// Width/height IDL-like properties use canvas defaults while retaining a
/// useful numeric reflection for other replaced elements.
fn dimension(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const handle_arg = arguments.get(0);
    const name_arg = arguments.get(1);
    if (!handle_arg.isNumber() or !name_arg.isString()) return Value.from(@as(f64, 0));

    const raw_handle = handle_arg.asNumber().asFloat();
    if (!std.math.isFinite(raw_handle) or raw_handle < 0 or raw_handle > std.math.maxInt(u32)) {
        return Value.from(@as(f64, 0));
    }
    const element = host.resolve_element(host.context, @intFromFloat(raw_handle)) orelse
        return Value.from(@as(f64, 0));
    const name = try name_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(name);
    const is_width = std.mem.eql(u8, name, "width");
    const is_height = std.mem.eql(u8, name, "height");
    if (!is_width and !is_height) return Value.from(@as(f64, 0));

    if (std.ascii.eqlIgnoreCase(element.tag, "canvas")) {
        const dimensions = element.canvasDimensions();
        return Value.from(@as(f64, @floatFromInt(if (is_width) dimensions.width else dimensions.height)));
    }
    const attributes = element.attributes orelse return Value.from(@as(f64, 0));
    const raw = attributes.get(name) orelse return Value.from(@as(f64, 0));
    return Value.from(std.fmt.parseFloat(f64, raw) catch 0);
}

/// Dispatch one CanvasRenderingContext2D call. Unsupported z2d operations and
/// invalid drawing state are non-fatal stubs; allocation failures propagate.
fn command(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const handle_arg = arguments.get(0);
    const name_arg = arguments.get(1);
    const fill_arg = arguments.get(2);
    const stroke_arg = arguments.get(3);
    if (!handle_arg.isNumber() or !name_arg.isString() or
        !fill_arg.isString() or !stroke_arg.isString()) return .undefined;
    const raw_handle = handle_arg.asNumber().asFloat();
    if (!std.math.isFinite(raw_handle) or raw_handle < 0 or raw_handle > std.math.maxInt(u32)) {
        return .undefined;
    }
    const element = canvasElement(host, @intFromFloat(raw_handle)) orelse return .undefined;
    const canvas = try ensureBacking(agent, host, element);

    const name = try name_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(name);
    const fill_style = try fill_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(fill_style);
    const stroke_style = try stroke_arg.asString().toUtf8(host.allocator);
    defer host.allocator.free(stroke_style);

    const line_width_arg = arguments.get(4);
    const global_alpha_arg = arguments.get(5);
    if (!line_width_arg.isNumber() or !global_alpha_arg.isNumber()) return .undefined;
    const line_width = line_width_arg.asNumber().asFloat();
    const global_alpha = global_alpha_arg.asNumber().asFloat();
    if (!std.math.isFinite(line_width) or !std.math.isFinite(global_alpha)) return .undefined;

    var values = [_]f64{0} ** 6;
    for (0..values.len) |index| {
        const value_arg = arguments.get(7 + index);
        if (!value_arg.isNumber()) return .undefined;
        values[index] = value_arg.asNumber().asFloat();
        if (!std.math.isFinite(values[index])) return .undefined;
    }

    const result = canvas.command(
        name,
        values,
        arguments.get(6).toBoolean(),
        .{
            .fill_style = fill_style,
            .stroke_style = stroke_style,
            .line_width = line_width,
            .global_alpha = global_alpha,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotImplemented => {
            std.log.debug("CanvasRenderingContext2D.{s} is not implemented", .{name});
            return .undefined;
        },
        else => {
            std.log.warn("CanvasRenderingContext2D.{s} ignored: {}", .{ name, err });
            return .undefined;
        },
    };
    if (result == .pixels_changed) {
        parser.markPaintForElement(element);
        host.request_render(host.context);
    }
    return .undefined;
}
