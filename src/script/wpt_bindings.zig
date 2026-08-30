//! Synchronous WPT testharness reporting bindings.
//!
//! This domain only exposes whether the active document has an installed WPT
//! result sink and forwards one already-serialized result. Result bytes borrow
//! temporary binding storage; a receiver that retains them must copy them
//! before returning.

const std = @import("std");
const kiesel = @import("kiesel");
const native_bindings = @import("native_bindings.zig");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Value = kiesel.types.Value;

/// Consume one serialized testharness result synchronously. The byte slice is
/// callback-scoped and must be copied by any owner that retains it.
pub const ReportCallbackFn = *const fn (
    context: ?*anyopaque,
    report_json: []const u8,
) anyerror!void;

pub const EnabledFn = *const fn (context: ?*anyopaque) bool;

/// Heap-stable narrow interface retained by Kiesel native functions.
pub const Host = struct {
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    enabled: EnabledFn,
    report: ReportCallbackFn,
};

pub const bindings = [_]native_bindings.Binding{
    .{ .name = "wptEnabled", .length = 0, .function = wptEnabled },
    .{ .name = "wptReport", .length = 1, .function = wptReport },
};

fn activeHost(agent: *Agent) *Host {
    const function = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction);
    return function.fields.additionalFieldsAs(Host);
}

fn wptEnabled(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    return Value.from(host.enabled(host.context));
}

fn wptReport(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const value = arguments.get(0);
    if (!value.isString()) {
        return agent.throwException(.type_error, "WPT report requires a JSON string", .{});
    }

    const host = activeHost(agent);
    const report_json = try value.asString().toUtf8(host.allocator);
    defer host.allocator.free(report_json);
    host.report(host.context, report_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return agent.throwException(.internal_error, "WPT report callback failed", .{}),
    };
    return .undefined;
}

test "WPT binding exposes enablement and one serialized report operation" {
    try std.testing.expectEqual(@as(usize, 2), bindings.len);
    try std.testing.expectEqualStrings("wptEnabled", bindings[0].name);
    try std.testing.expectEqualStrings("wptReport", bindings[1].name);
}
