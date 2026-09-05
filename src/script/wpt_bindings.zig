//! Synchronous WPT testharness reporting and bounded diagnostic logging.
//!
//! This domain only exposes whether the active document has an installed WPT
//! result sink and forwards one already-serialized result. Result bytes borrow
//! temporary binding storage; a receiver that retains them must copy them
//! before returning. Each live Realm also owns a byte budget for best-effort
//! stderr observations; those events never decide the semantic result.

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
    diagnostic: ReportCallbackFn,
};

pub const bindings = [_]native_bindings.Binding{
    .{ .name = "wptEnabled", .length = 0, .function = wptEnabled },
    .{ .name = "wptReport", .length = 1, .function = wptReport },
    .{ .name = "wptDiagnostic", .length = 1, .function = wptDiagnostic },
};

/// One live Realm's bounded stderr side channel. It owns no JavaScript values
/// or borrowed source storage and never supplies a terminal harness result.
pub const DiagnosticLog = struct {
    pub const max_bytes = 32 * 1024;
    pub const max_event_bytes = 8192;
    pub const progress_bytes = max_bytes - max_event_bytes;
    bytes: usize = 0,
    truncated: bool = false,

    pub fn emit(self: *DiagnosticLog, json: []const u8) void {
        // Reserve space for an exception even after a long run of subtests.
        self.emitWithin(json, progress_bytes);
    }

    fn emitWithin(self: *DiagnosticLog, json: []const u8, limit: usize) void {
        if (json.len > max_event_bytes or self.bytes + json.len > limit) {
            if (!self.truncated) std.log.info("ZIBRA_WPT_DIAGNOSTIC {{\"kind\":\"truncated\"}}", .{});
            self.truncated = true;
            return;
        }
        self.bytes += json.len;
        std.log.info("ZIBRA_WPT_DIAGNOSTIC {s}", .{json});
    }

    /// Best-effort observation under the caller's JsLock. Allocation or
    /// diagnostic formatting failure must not change page execution semantics.
    pub fn write(self: *DiagnosticLog, allocator: std.mem.Allocator, value: anytype) void {
        const json = std.json.Stringify.valueAlloc(allocator, value, .{}) catch return;
        defer allocator.free(json);
        self.emitWithin(json, max_bytes);
    }

    pub fn scriptError(
        self: *DiagnosticLog,
        allocator: std.mem.Allocator,
        agent: *Agent,
        source: []const u8,
        err: anyerror,
    ) void {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        if (err == error.ExceptionThrown) {
            if (agent.exception) |exception| {
                writer.print("{f}", .{exception.fmtPretty(agent, .no_color)}) catch {};
            }
        }
        self.write(allocator, .{
            .kind = "script-error",
            .source = utf8Prefix(source, 512),
            .error_kind = @errorName(err),
            .detail = utf8Prefix(buffer[0..writer.end], buffer.len),
        });
    }
};

fn utf8Prefix(bytes: []const u8, max_len: usize) []const u8 {
    var end = @min(bytes.len, max_len);
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (end -= 1) {}
    return bytes[0..end];
}

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

fn wptDiagnostic(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    if (!host.enabled(host.context)) return .undefined;
    const value = arguments.get(0);
    if (!value.isString()) return .undefined;
    const json = try value.asString().toUtf8(host.allocator);
    defer host.allocator.free(json);
    host.diagnostic(host.context, json) catch {};
    return .undefined;
}

test "WPT binding exposes enablement and one serialized report operation" {
    try std.testing.expectEqual(@as(usize, 3), bindings.len);
    try std.testing.expectEqualStrings("wptEnabled", bindings[0].name);
    try std.testing.expectEqualStrings("wptReport", bindings[1].name);
    try std.testing.expectEqualStrings("wptDiagnostic", bindings[2].name);
}

test "WPT diagnostics are byte bounded and do not retain source buffers" {
    var log: DiagnosticLog = .{};
    const payload = [_]u8{'x'} ** DiagnosticLog.max_event_bytes;
    for (0..16) |_| log.emit(&payload);
    try std.testing.expect(log.truncated);
    try std.testing.expectEqual(DiagnosticLog.progress_bytes, log.bytes);
    log.emitWithin(&payload, DiagnosticLog.max_bytes);
    try std.testing.expectEqual(DiagnosticLog.max_bytes, log.bytes);
    try std.testing.expectEqualStrings("a", utf8Prefix("a☃", 3));
    try std.testing.expectEqualStrings("a☃", utf8Prefix("a☃", 4));
}
