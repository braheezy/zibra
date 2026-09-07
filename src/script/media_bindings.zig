//! Synchronous media commands and copied snapshots. The browser callback owns
//! document state; no DOM pointer or Kiesel value crosses to audio workers.
const std = @import("std");
const kiesel = @import("kiesel");
const native = @import("native_bindings.zig");
const Agent = kiesel.execution.Agent;
const Value = kiesel.types.Value;
pub const Command = enum { snapshot, source, poll, load, play, pause, seek, volume, muted };
pub const Result = struct {
    values: [10]f64 = .{ std.math.nan(f64), 0, 1, 0, 0, 0, 0, 1, 0, 0 },
    source: []const u8 = "",
    events: []const u8 = "",
    failure: []const u8 = "",
    revision: u64 = 0,
};
pub const Callback = *const fn (?*anyopaque, u32, Command, f64, std.mem.Allocator, *Result) anyerror!void;
pub const Host = struct { context: ?*anyopaque, allocator: std.mem.Allocator, call: Callback };
pub const bindings = [_]native.Binding{.{ .name = "media", .length = 3, .function = media }};
fn media(agent: *Agent, _: Value, args: kiesel.types.Arguments) Agent.Error!Value {
    const host = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction).fields.additionalFieldsAs(Host);
    const number = args.get(0);
    if (!number.isNumber()) return agent.throwException(.type_error, "Media requires an element", .{});
    const handle = number.asNumber().asFloat();
    if (!std.math.isFinite(handle) or handle < 1 or handle > std.math.maxInt(u32) or @trunc(handle) != handle) return agent.throwException(.type_error, "Invalid media element", .{});
    const op = args.get(1);
    if (!op.isString()) return agent.throwException(.type_error, "Invalid media operation", .{});
    const text = try op.asString().toUtf8(host.allocator);
    defer host.allocator.free(text);
    const command = std.meta.stringToEnum(Command, text) orelse return agent.throwException(.type_error, "Invalid media operation", .{});
    const value: f64 = if (args.get(2).isNumber()) args.get(2).asNumber().asFloat() else 0;
    var arena = std.heap.ArenaAllocator.init(host.allocator);
    defer arena.deinit();
    var result: Result = .{};
    host.call(host.context, @intFromFloat(handle), command, value, arena.allocator(), &result) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        result.failure = @errorName(err);
    };
    const array = try kiesel.builtins.arrayCreate(agent, 14, null);
    for (result.values, 0..) |item, i| try array.object.createDataPropertyDirect(agent, kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, @intCast(i))), Value.from(item));
    for ([_][]const u8{ result.source, result.events, result.failure }, 10..) |item, i| {
        const string = try kiesel.types.String.fromUtf8(agent, item);
        try array.object.createDataPropertyDirect(agent, kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, @intCast(i))), Value.from(string));
    }
    try array.object.createDataPropertyDirect(agent, kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, 13)), Value.from(@as(f64, @floatFromInt(result.revision))));
    return Value.from(&array.object);
}
