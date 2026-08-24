//! Serialized, non-blocking accessibility speech dispatch.
//!
//! Callers flatten live accessibility/DOM state into an owned utterance before
//! crossing this thread boundary. Queued tasks and backend calls therefore
//! retain no Tab, Node, accessibility-tree, or document-generation pointer;
//! the thread borrows only its owning runner field until shutdown joins it.

const std = @import("std");
const task = @import("../runtime/task.zig");
const MeasureTime = @import("../runtime/measure_time.zig").MeasureTime;

const Task = task.Task;
const TaskRunner = task.TaskRunner;

pub const Backend = struct {
    /// Optional synchronous backend state. Its owner must retain it through
    /// `Worker.shutdown`; production logging uses no context.
    context: ?*anyopaque = null,
    speak_fn: *const fn (?*anyopaque, []const u8, []const u8) void = logSpeech,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    runner: TaskRunner,
    backend: Backend,

    pub fn init(allocator: std.mem.Allocator, measure: *MeasureTime) Worker {
        return initWithBackend(allocator, measure, .{});
    }

    pub fn initWithBackend(
        allocator: std.mem.Allocator,
        measure: *MeasureTime,
        backend: Backend,
    ) Worker {
        return .{
            .allocator = allocator,
            .runner = TaskRunner.initNamed(allocator, measure, "Accessibility thread"),
            .backend = backend,
        };
    }

    /// Start only after the containing Tab has reached its final address.
    pub fn start(self: *Worker) !void {
        try self.runner.start();
    }

    /// Copy and format every borrowed input before returning. The backend may
    /// block for an arbitrary amount of time without retaining live page data.
    pub fn enqueue(
        self: *Worker,
        reason: []const u8,
        role: []const u8,
        name: []const u8,
        value: []const u8,
    ) !void {
        const context = try SpeechTask.create(
            self.allocator,
            self.backend,
            reason,
            role,
            name,
            value,
        );
        const speech_task = Task.init(
            .user_input,
            "task:accessibility_speech",
            context,
            SpeechTask.run,
            SpeechTask.cleanup,
        );
        self.runner.schedule(speech_task) catch |err| {
            context.destroy();
            return err;
        };
    }

    /// Cancel speech that has not started. An active backend call remains
    /// owned by the worker and is joined by `shutdown`.
    pub fn clear(self: *Worker) void {
        self.runner.clear();
    }

    pub fn isIdle(self: *Worker) bool {
        return self.runner.isIdle();
    }

    pub fn shutdown(self: *Worker) void {
        self.runner.shutdown();
    }

    pub fn deinit(self: *Worker) void {
        self.runner.deinit();
    }
};

const SpeechTask = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    reason: []u8,
    utterance: []u8,

    fn create(
        allocator: std.mem.Allocator,
        backend: Backend,
        reason: []const u8,
        role: []const u8,
        name: []const u8,
        value: []const u8,
    ) !*@This() {
        const context = try allocator.create(@This());
        errdefer allocator.destroy(context);

        const reason_copy = try allocator.dupe(u8, reason);
        errdefer allocator.free(reason_copy);

        const utterance = if (value.len > 0)
            try std.fmt.allocPrint(allocator, "{s} {s} value {s}", .{ role, name, value })
        else if (name.len > 0)
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ role, name })
        else
            try allocator.dupe(u8, role);
        errdefer allocator.free(utterance);

        context.* = .{
            .allocator = allocator,
            .backend = backend,
            .reason = reason_copy,
            .utterance = utterance,
        };
        return context;
    }

    fn run(raw_context: *anyopaque) !void {
        const context: *@This() = @ptrCast(@alignCast(raw_context));
        context.backend.speak_fn(
            context.backend.context,
            context.reason,
            context.utterance,
        );
    }

    fn cleanup(raw_context: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(raw_context));
        context.destroy();
    }

    fn destroy(self: *@This()) void {
        const allocator = self.allocator;
        allocator.free(self.reason);
        allocator.free(self.utterance);
        allocator.destroy(self);
    }
};

fn logSpeech(_: ?*anyopaque, reason: []const u8, utterance: []const u8) void {
    std.log.info("screen reader {s}: {s}", .{ reason, utterance });
}

const BlockingBackend = struct {
    io: std.Io,
    caller_id: std.Thread.Id,
    worker_id: std.atomic.Value(usize) = .init(0),
    started: std.Io.Semaphore = .{},
    release: std.Io.Semaphore = .{},
    completed: std.Io.Semaphore = .{},
    call_count: std.atomic.Value(usize) = .init(0),
    reason: [32]u8 = undefined,
    reason_len: usize = 0,
    utterance: [128]u8 = undefined,
    utterance_len: usize = 0,

    fn speak(raw_context: ?*anyopaque, reason: []const u8, utterance: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        self.worker_id.store(@intCast(std.Thread.getCurrentId()), .release);
        self.started.post(self.io);
        self.release.waitUncancelable(self.io);

        self.reason_len = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
        self.utterance_len = @min(utterance.len, self.utterance.len);
        @memcpy(self.utterance[0..self.utterance_len], utterance[0..self.utterance_len]);
        _ = self.call_count.fetchAdd(1, .monotonic);
        self.completed.post(self.io);
    }
};

test "accessibility speech runs off-thread with an owned text snapshot" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(std.testing.allocator, std.testing.io, &environ);
    defer measure.finish();

    var backend = BlockingBackend{
        .io = std.testing.io,
        .caller_id = std.Thread.getCurrentId(),
    };
    var worker = Worker.initWithBackend(std.testing.allocator, &measure, .{
        .context = &backend,
        .speak_fn = BlockingBackend.speak,
    });
    defer worker.deinit();
    try worker.start();

    var source = [_]u8{ 'O', 'r', 'i', 'g', 'i', 'n', 'a', 'l' };
    try worker.enqueue("document", "paragraph", source[0..], "");
    backend.started.waitUncancelable(std.testing.io);

    @memset(source[0..], 'x');
    backend.release.post(std.testing.io);
    backend.completed.waitUncancelable(std.testing.io);
    worker.shutdown();

    try std.testing.expect(backend.worker_id.load(.acquire) != @as(usize, @intCast(backend.caller_id)));
    try std.testing.expectEqualStrings("document", backend.reason[0..backend.reason_len]);
    try std.testing.expectEqualStrings("paragraph Original", backend.utterance[0..backend.utterance_len]);
    try std.testing.expectEqual(@as(usize, 1), backend.call_count.load(.monotonic));
}

test "clearing accessibility speech cancels queued owned utterances" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(std.testing.allocator, std.testing.io, &environ);
    defer measure.finish();

    var backend = BlockingBackend{
        .io = std.testing.io,
        .caller_id = std.Thread.getCurrentId(),
    };
    var worker = Worker.initWithBackend(std.testing.allocator, &measure, .{
        .context = &backend,
        .speak_fn = BlockingBackend.speak,
    });
    defer worker.deinit();
    try worker.start();

    try worker.enqueue("focus", "button", "First", "");
    backend.started.waitUncancelable(std.testing.io);
    try worker.enqueue("hover", "link", "Never spoken", "");
    worker.clear();
    backend.release.post(std.testing.io);
    backend.completed.waitUncancelable(std.testing.io);
    worker.shutdown();

    try std.testing.expectEqual(@as(usize, 1), backend.call_count.load(.monotonic));
    try std.testing.expectEqualStrings("button First", backend.utterance[0..backend.utterance_len]);
}

test "accessibility shutdown cancels pending speech and joins the active backend" {
    const ShutdownContext = struct {
        worker: *Worker,
        returned: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.worker.shutdown();
            self.returned.store(true, .release);
        }
    };

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(std.testing.allocator, std.testing.io, &environ);
    defer measure.finish();

    var backend = BlockingBackend{
        .io = std.testing.io,
        .caller_id = std.Thread.getCurrentId(),
    };
    var worker = Worker.initWithBackend(std.testing.allocator, &measure, .{
        .context = &backend,
        .speak_fn = BlockingBackend.speak,
    });
    defer worker.deinit();
    try worker.start();

    try worker.enqueue("document", "heading", "Active", "");
    backend.started.waitUncancelable(std.testing.io);
    try worker.enqueue("document", "paragraph", "Pending", "");

    var shutdown_context = ShutdownContext{ .worker = &worker };
    const shutdown_thread = try std.Thread.spawn(.{}, ShutdownContext.run, .{&shutdown_context});

    worker.runner.mutex.lock();
    while (!worker.runner.shutting_down) {
        worker.runner.condition.wait(&worker.runner.mutex);
    }
    worker.runner.mutex.unlock();

    try std.testing.expect(!shutdown_context.returned.load(.acquire));
    backend.release.post(std.testing.io);
    backend.completed.waitUncancelable(std.testing.io);
    shutdown_thread.join();

    try std.testing.expect(shutdown_context.returned.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), backend.call_count.load(.monotonic));
    try std.testing.expectEqualStrings("heading Active", backend.utterance[0..backend.utterance_len]);
}
