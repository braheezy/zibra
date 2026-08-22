//! JavaScript timer API regressions with deterministic native scheduling.

const std = @import("std");
const Js = @import("../script/js.zig");
const tab_module = @import("../browser/tab.zig");

const ScheduledTimer = struct {
    handle: u32,
    delay_ms: u32,
    is_interval: bool,
};

const TimerCapture = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(ScheduledTimer) = .empty,
    clears: std.ArrayList(u32) = .empty,

    fn deinit(self: *TimerCapture) void {
        self.calls.deinit(self.allocator);
        self.clears.deinit(self.allocator);
    }

    fn schedule(
        context: ?*anyopaque,
        handle: u32,
        delay_ms: u32,
        is_interval: bool,
    ) anyerror!void {
        const raw = context orelse return error.MissingTimerCapture;
        const unaligned: *align(1) TimerCapture = @ptrCast(raw);
        const self: *TimerCapture = @alignCast(unaligned);
        try self.calls.append(self.allocator, .{
            .handle = handle,
            .delay_ms = delay_ms,
            .is_interval = is_interval,
        });
    }

    fn clear(context: ?*anyopaque, handle: u32) void {
        const raw = context orelse return;
        const unaligned: *align(1) TimerCapture = @ptrCast(raw);
        const self: *TimerCapture = @alignCast(unaligned);
        self.clears.append(self.allocator, handle) catch {};
    }
};

fn numericHandle(value: anytype) u32 {
    return @intFromFloat(value.asNumber().asFloat());
}

test "setInterval repeats at its requested delay until clearInterval in callback" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var capture = TimerCapture{ .allocator = allocator };
    defer capture.deinit();
    js.setSetTimeoutCallback(11, TimerCapture.schedule, &capture);
    js.setClearIntervalCallback(11, TimerCapture.clear, &capture);

    const result = try js.evaluate(11,
        \\var intervalTicks = 0;
        \\var repeatingTimer = setInterval(function() {
        \\  intervalTicks = intervalTicks + 1;
        \\  if (intervalTicks === 3) clearInterval(repeatingTimer);
        \\}, 25);
        \\repeatingTimer;
    );
    const handle = numericHandle(result);

    try std.testing.expectEqual(@as(usize, 1), capture.calls.items.len);
    try std.testing.expectEqual(ScheduledTimer{ .handle = handle, .delay_ms = 25, .is_interval = true }, capture.calls.items[0]);

    try js.runTimeoutCallback(11, handle);
    try std.testing.expectEqual(@as(usize, 2), capture.calls.items.len);
    try std.testing.expectEqual(ScheduledTimer{ .handle = handle, .delay_ms = 25, .is_interval = true }, capture.calls.items[1]);

    try js.runTimeoutCallback(11, handle);
    try std.testing.expectEqual(@as(usize, 3), capture.calls.items.len);
    try std.testing.expectEqual(ScheduledTimer{ .handle = handle, .delay_ms = 25, .is_interval = true }, capture.calls.items[2]);

    try js.runTimeoutCallback(11, handle);
    try std.testing.expectEqual(@as(usize, 3), capture.calls.items.len);
    try std.testing.expectEqualSlices(u32, &.{handle}, capture.clears.items);
    const ticks = try js.evaluate(11, "intervalTicks;");
    try std.testing.expectEqual(@as(u32, 3), numericHandle(ticks));

    // A stale already-queued delivery is harmless after cancellation.
    try js.runTimeoutCallback(11, handle);
    const unchanged_ticks = try js.evaluate(11, "intervalTicks;");
    try std.testing.expectEqual(@as(u32, 3), numericHandle(unchanged_ticks));
}

test "clearInterval before first delivery suppresses callback and reschedule" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var capture = TimerCapture{ .allocator = allocator };
    defer capture.deinit();
    js.setSetTimeoutCallback(12, TimerCapture.schedule, &capture);
    js.setClearIntervalCallback(12, TimerCapture.clear, &capture);

    const result = try js.evaluate(12,
        \\var canceledTicks = 0;
        \\var canceledTimer = setInterval(function() { canceledTicks = canceledTicks + 1; }, 9);
        \\clearInterval(canceledTimer);
        \\clearInterval(999999);
        \\canceledTimer;
    );
    const handle = numericHandle(result);
    try std.testing.expectEqual(@as(usize, 1), capture.calls.items.len);
    try std.testing.expectEqualSlices(u32, &.{ handle, 999999 }, capture.clears.items);

    try js.runTimeoutCallback(12, handle);
    try std.testing.expectEqual(@as(usize, 1), capture.calls.items.len);
    const ticks = try js.evaluate(12, "canceledTicks;");
    try std.testing.expectEqual(@as(u32, 0), numericHandle(ticks));
}

test "timer handles and callback registries are isolated per window" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var first_capture = TimerCapture{ .allocator = allocator };
    defer first_capture.deinit();
    var second_capture = TimerCapture{ .allocator = allocator };
    defer second_capture.deinit();
    js.setSetTimeoutCallback(21, TimerCapture.schedule, &first_capture);
    js.setSetTimeoutCallback(22, TimerCapture.schedule, &second_capture);
    js.setClearIntervalCallback(21, TimerCapture.clear, &first_capture);
    js.setClearIntervalCallback(22, TimerCapture.clear, &second_capture);

    const timeout_handle = numericHandle(try js.evaluate(21,
        \\var firstWindowTicks = 0;
        \\var firstWindowTimer = setTimeout(function() { firstWindowTicks = firstWindowTicks + 1; }, 7);
        \\firstWindowTimer;
    ));
    const interval_handle = numericHandle(try js.evaluate(22,
        \\var secondWindowTicks = 0;
        \\var secondWindowTimer = setInterval(function() { secondWindowTicks = secondWindowTicks + 1; }, 13);
        \\secondWindowTimer;
    ));

    try std.testing.expectEqual(@as(u32, 0), timeout_handle);
    try std.testing.expectEqual(@as(u32, 0), interval_handle);
    try std.testing.expectEqual(@as(usize, 1), first_capture.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), second_capture.calls.items.len);

    try js.runTimeoutCallback(21, timeout_handle);
    try js.runTimeoutCallback(21, timeout_handle);
    try std.testing.expectEqual(@as(usize, 1), first_capture.calls.items.len);
    const first_ticks = try js.evaluate(21, "firstWindowTicks;");
    try std.testing.expectEqual(@as(u32, 1), numericHandle(first_ticks));

    try js.runTimeoutCallback(22, interval_handle);
    try std.testing.expectEqual(@as(usize, 2), second_capture.calls.items.len);
    const second_ticks = try js.evaluate(22, "secondWindowTicks;");
    try std.testing.expectEqual(@as(u32, 1), numericHandle(second_ticks));

    _ = try js.evaluate(22, "clearInterval(secondWindowTimer);");
    try std.testing.expectEqualSlices(u32, &.{interval_handle}, second_capture.clears.items);
    try js.runTimeoutCallback(22, interval_handle);
    try std.testing.expectEqual(@as(usize, 2), second_capture.calls.items.len);
}

test "setInterval preserves zero short and long requested cadences" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var capture = TimerCapture{ .allocator = allocator };
    defer capture.deinit();
    js.setSetTimeoutCallback(31, TimerCapture.schedule, &capture);
    js.setClearIntervalCallback(31, TimerCapture.clear, &capture);

    _ = try js.evaluate(31,
        \\var cadence0 = setInterval(function() {}, 0);
        \\var cadence17 = setInterval(function() {}, 17);
        \\var cadence125 = setInterval(function() {}, 125);
        \\clearInterval(cadence0);
        \\clearInterval(cadence17);
        \\clearInterval(cadence125);
    );

    try std.testing.expectEqual(@as(usize, 3), capture.calls.items.len);
    try std.testing.expectEqual(@as(u32, 0), capture.calls.items[0].delay_ms);
    try std.testing.expectEqual(@as(u32, 17), capture.calls.items[1].delay_ms);
    try std.testing.expectEqual(@as(u32, 125), capture.calls.items[2].delay_ms);
    try std.testing.expect(capture.calls.items[0].is_interval);
    try std.testing.expect(capture.calls.items[1].is_interval);
    try std.testing.expect(capture.calls.items[2].is_interval);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, capture.clears.items);
}

test "native interval cancellation keys include window document and handle" {
    const allocator = std.testing.allocator;
    var tab: tab_module.Tab = undefined;
    tab.shutting_down = std.atomic.Value(bool).init(false);
    tab.intervals = @TypeOf(tab.intervals).init(allocator);
    defer tab.intervals.deinit();
    tab.interval_mutex = .init(std.testing.io);

    try tab.ensureInterval(1, 10, 7);
    try tab.ensureInterval(1, 11, 7);
    try tab.ensureInterval(2, 10, 7);
    try tab.ensureInterval(1, 10, 8);

    tab.clearInterval(1, 10, 7);
    try std.testing.expect(!tab.intervalIsActive(1, 10, 7));
    try std.testing.expect(tab.intervalIsActive(1, 11, 7));
    try std.testing.expect(tab.intervalIsActive(2, 10, 7));
    try std.testing.expect(tab.intervalIsActive(1, 10, 8));

    tab.clearIntervalsForDocument(1, 10);
    try std.testing.expect(!tab.intervalIsActive(1, 10, 8));
    try std.testing.expect(tab.intervalIsActive(1, 11, 7));
    try std.testing.expect(tab.intervalIsActive(2, 10, 7));
}
