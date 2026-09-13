//! Copies geometry from a synchronous, generation-scoped browser callback.
//! No Node, layout pointer, or result buffer escapes into Kiesel.
const std = @import("std");
const kiesel = @import("kiesel");
const native = @import("native_bindings.zig");
pub const Rect = @import("../core/rect.zig").Rect;
const Agent = kiesel.execution.Agent;
const Value = kiesel.types.Value;

pub const Query = enum { client_rects, offset_rects, box_metrics, scroll_metrics, scroll_set };
/// Caller owns rects and must release its backing storage with the callback
/// allocator. All other fields are values, not DOM or layout borrows.
pub const Result = struct {
    rects: std.ArrayList(Rect) = .empty,
    client: Rect = .{},
    offset_x: f64 = 0,
    offset_y: f64 = 0,
    offset_parent: ?u32 = null,
    scroll: [4]f64 = .{ 0, 0, 0, 0 },
    /// Input for scroll_set; absent axes retain their current position.
    scroll_x: ?f64 = null,
    scroll_y: ?f64 = null,
    scroll_relative: bool = false,
};
/// Called with JsLock held on the document worker. Append rectangles using
/// the supplied allocator or fill scalar metrics; never retain output or
/// re-enter Js. offset_parent must be a handle in the active WindowRealm.
pub const Callback = *const fn (?*anyopaque, u32, Query, std.mem.Allocator, *Result) anyerror!void;

pub const Host = struct {
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    measure: Callback,
};

pub const bindings = [_]native.Binding{
    .{ .name = "elementRects", .length = 2, .function = elementRects },
    .{ .name = "elementMetrics", .length = 1, .function = elementMetrics },
    .{ .name = "elementScroll", .length = 1, .function = elementScroll },
};

fn elementRects(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    return measure(agent, arguments, if (arguments.get(1).toBoolean()) .offset_rects else .client_rects);
}

fn elementMetrics(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    return measure(agent, arguments, .box_metrics);
}

fn elementScroll(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    return measure(agent, arguments, if (arguments.count() > 1) .scroll_set else .scroll_metrics);
}

fn measure(agent: *Agent, arguments: kiesel.types.Arguments, query: Query) Agent.Error!Value {
    const host = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction).fields.additionalFieldsAs(Host);
    const handle = arguments.get(0);
    if (!handle.isNumber()) return agent.throwException(.type_error, "Geometry requires an Element handle", .{});
    const number = handle.asNumber().asFloat();
    if (!std.math.isFinite(number) or number < 1 or number > std.math.maxInt(u32) or @trunc(number) != number)
        return agent.throwException(.type_error, "Invalid Element handle", .{});
    var snapshot = Result{};
    defer snapshot.rects.deinit(host.allocator);
    if (query == .scroll_set) {
        if (!arguments.get(1).isUndefined()) snapshot.scroll_x = (try arguments.get(1).toNumber(agent)).asFloat();
        if (!arguments.get(2).isUndefined()) snapshot.scroll_y = (try arguments.get(2).toNumber(agent)).asFloat();
        snapshot.scroll_relative = arguments.get(3).toBoolean();
    }
    host.measure(host.context, @intFromFloat(number), query, host.allocator, &snapshot) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return agent.throwException(.internal_error, "Geometry update failed: {s}", .{@errorName(err)});
    };
    if (query == .scroll_set) return .undefined;
    if (query == .scroll_metrics) {
        const result = try kiesel.builtins.arrayCreate(agent, snapshot.scroll.len, null);
        for (snapshot.scroll, 0..) |value, index| try result.object.createDataPropertyDirect(agent, kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, @intCast(index))), Value.from(value));
        return Value.from(&result.object);
    }
    // Flat numeric snapshots keep allocation/GC ownership entirely in Kiesel.
    if (query == .box_metrics) {
        const values = [_]f64{ snapshot.client.x, snapshot.client.y, snapshot.client.width, snapshot.client.height, snapshot.offset_x, snapshot.offset_y, @floatFromInt(snapshot.offset_parent orelse 0) };
        const result = try kiesel.builtins.arrayCreate(agent, values.len, null);
        for (values, 0..) |value, index| try result.object.createDataPropertyDirect(agent, kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, @intCast(index))), Value.from(value));
        return Value.from(&result.object);
    }
    const result = try kiesel.builtins.arrayCreate(agent, @intCast(snapshot.rects.items.len * 4), null);
    for (snapshot.rects.items, 0..) |rect, index| {
        inline for (.{ "x", "y", "width", "height" }, 0..) |field, component| {
            try result.object.createDataPropertyDirect(agent, kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, @intCast(index * 4 + component))), Value.from(@field(rect, field)));
        }
    }
    return Value.from(&result.object);
}
