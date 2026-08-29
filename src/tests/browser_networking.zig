//! Browser-session networking-dispatch tests.

const std = @import("std");
const browser = @import("../browser/root.zig");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const MeasureTime = @import("../runtime/measure_time.zig").MeasureTime;
const Task = @import("../runtime/task.zig").Task;
const Url = @import("../network/url.zig").Url;

const ThreadProbe = struct {
    io: std.Io,
    thread_id: ?std.Thread.Id = null,
    completed: std.Io.Semaphore = .{},

    fn run(raw: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.thread_id = std.Thread.getCurrentId();
    }

    fn cleanup(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.completed.post(self.io);
    }
};

test "network tasks execute on one dedicated session worker" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(std.testing.allocator, std.testing.io, &environ);
    defer measure.finish();

    var session = BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.startNetworking(&measure);

    var first = ThreadProbe{ .io = std.testing.io };
    try session.scheduleNetworkTask(Task.init(
        .normal,
        "task:test_network_first",
        &first,
        ThreadProbe.run,
        ThreadProbe.cleanup,
    ));
    first.completed.waitUncancelable(std.testing.io);

    var second = ThreadProbe{ .io = std.testing.io };
    try session.scheduleNetworkTask(Task.init(
        .normal,
        "task:test_network_second",
        &second,
        ThreadProbe.run,
        ThreadProbe.cleanup,
    ));
    second.completed.waitUncancelable(std.testing.io);

    try std.testing.expect(first.thread_id.? != std.Thread.getCurrentId());
    try std.testing.expectEqual(first.thread_id.?, second.thread_id.?);
}

test "Browser fetch crosses the networking queue and returns its response" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(allocator, std.testing.io, &environ);
    defer measure.finish();

    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();
    try session.startNetworking(&measure);

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.session_state = &session;
    test_browser.resource_loader = .init(allocator, std.testing.io, &session);

    var data_url = try Url.init(allocator, "data:text/plain,networked");
    defer data_url.free(allocator);
    const response = try test_browser.fetchBody(data_url, null, null);
    try std.testing.expectEqualStrings("networked", response.body);
}
