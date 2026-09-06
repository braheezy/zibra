//! Copies geometry from a synchronous, generation-scoped browser callback.
//! No Node, layout pointer, or result buffer escapes into Kiesel.
const std = @import("std");
const kiesel = @import("kiesel");
const native = @import("native_bindings.zig");
pub const Rect = @import("../core/rect.zig").Rect;
const Agent = kiesel.execution.Agent;
const Value = kiesel.types.Value;

/// Called with JsLock held on the document worker. Append scalar rectangles
/// using the supplied allocator; do not retain the output or re-enter Js.
pub const Callback = *const fn (?*anyopaque, u32, bool, std.mem.Allocator, *std.ArrayList(Rect)) anyerror!void;

pub const Host = struct {
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    measure: Callback,
};

pub const bindings = [_]native.Binding{
    .{ .name = "elementRects", .length = 2, .function = elementRects },
};

fn elementRects(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const host = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction).fields.additionalFieldsAs(Host);
    const handle = arguments.get(0);
    if (!handle.isNumber()) return agent.throwException(.type_error, "Geometry requires an Element handle", .{});
    const number = handle.asNumber().asFloat();
    if (!std.math.isFinite(number) or number < 1 or number > std.math.maxInt(u32) or @trunc(number) != number)
        return agent.throwException(.type_error, "Invalid Element handle", .{});
    var rects = std.ArrayList(Rect).empty;
    defer rects.deinit(host.allocator);
    host.measure(host.context, @intFromFloat(number), arguments.get(1).toBoolean(), host.allocator, &rects) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return agent.throwException(.internal_error, "Geometry update failed: {s}", .{@errorName(err)});
    };
    // Flat numeric snapshots keep allocation/GC ownership entirely in Kiesel.
    const result = try kiesel.builtins.arrayCreate(agent, @intCast(rects.items.len * 4), null);
    for (rects.items, 0..) |rect, index| {
        inline for (.{ "x", "y", "width", "height" }, 0..) |field, component| {
            try result.object.createDataPropertyDirect(agent, kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, @intCast(index * 4 + component))), Value.from(@field(rect, field)));
        }
    }
    return Value.from(&result.object);
}
