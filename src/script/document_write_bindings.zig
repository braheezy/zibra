//! Parser-active `document.write` native binding.
//!
//! This binding only converts a JavaScript string and forwards it through a
//! synchronous host callback. The browser installs that callback only while a
//! live parser is paused at a parser-inserted classic script; this module never
//! retains source bytes, a DOM pointer, or a parser pointer after the call.

const std = @import("std");
const kiesel = @import("kiesel");
const native_bindings = @import("native_bindings.zig");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Value = kiesel.types.Value;

/// Consume one already-stringified `document.write` payload synchronously.
/// The byte slice borrows the binding's temporary allocator storage and must
/// be copied by a parser/source owner before this callback returns.
pub const CallbackFn = *const fn (context: ?*anyopaque, source: []const u8) anyerror!void;

/// Heap-stable narrow interface retained by Kiesel native functions.
pub const Host = struct {
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    write: CallbackFn,
};

pub const bindings = [_]native_bindings.Binding{
    .{ .name = "documentWrite", .length = 1, .function = documentWrite },
};

fn activeHost(agent: *Agent) *Host {
    const function = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction);
    return function.fields.additionalFieldsAs(Host);
}

/// Forward a pre-stringified payload to the current live parser, if any.
/// Missing parser activity is intentionally a harmless no-op for the bounded
/// first implementation; it does not imply `document.open()` semantics.
fn documentWrite(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const value = arguments.get(0);
    if (!value.isString()) {
        return agent.throwException(.type_error, "document.write requires a string", .{});
    }

    const host = activeHost(agent);
    const source = try value.asString().toUtf8(host.allocator);
    defer host.allocator.free(source);
    host.write(host.context, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return agent.throwException(.internal_error, "document.write failed", .{}),
    };
    return .undefined;
}

test "document write binding exposes a focused one-argument native surface" {
    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqualStrings("documentWrite", bindings[0].name);
}
