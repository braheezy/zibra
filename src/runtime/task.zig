//! Per-tab serialized background task execution.
//!
//! A `Task` borrows its opaque context until its cleanup callback runs. The
//! runner executes and cleans each accepted task exactly once, or cleans it
//! without running when pending work is cleared. `shutdown` rejects new work,
//! cleans pending work, and joins the worker. Once it returns, no worker can
//! access the runner or an active task context.

const std = @import("std");
const MeasureTime = @import("measure_time.zig").MeasureTime;
const sync = @import("sync.zig");

pub const Task = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) anyerror!void,
    cleanup_fn: ?*const fn (*anyopaque) void = null,

    pub fn init(
        context: *anyopaque,
        run_fn: *const fn (*anyopaque) anyerror!void,
        cleanup_fn: ?*const fn (*anyopaque) void,
    ) Task {
        return .{
            .context = context,
            .run_fn = run_fn,
            .cleanup_fn = cleanup_fn,
        };
    }

    fn run(self: Task) anyerror!void {
        try self.run_fn(self.context);
    }

    fn cleanup(self: Task) void {
        if (self.cleanup_fn) |cleanup_fn| {
            cleanup_fn(self.context);
        }
    }
};

pub const TaskRunner = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task),
    mutex: sync.Mutex,
    condition: sync.Condition,
    needs_quit: bool = false,
    shutting_down: bool = false,
    join_in_progress: bool = false,
    active_tasks: usize = 0,
    thread: ?std.Thread = null,
    worker_id: ?std.Thread.Id = null,
    measure: *MeasureTime,

    pub fn init(allocator: std.mem.Allocator, measure: *MeasureTime) TaskRunner {
        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(Task).empty,
            .mutex = .init(measure.io),
            .condition = .init(measure.io),
            .measure = measure,
        };
    }

    pub fn deinit(self: *TaskRunner) void {
        self.shutdown();
        self.tasks.deinit(self.allocator);
    }

    pub fn start(self: *TaskRunner) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutting_down) return error.TaskRunnerShuttingDown;
        if (self.thread != null) return error.TaskRunnerAlreadyStarted;

        const thread = try std.Thread.spawn(.{}, runThread, .{self});
        _ = thread.setName(self.measure.io, "Tab main thread") catch |err| {
            std.log.warn("Failed to name tab thread: {}", .{err});
        };
        self.thread = thread;
    }

    pub fn schedule(self: *TaskRunner, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutting_down) {
            task.cleanup();
            return;
        }

        try self.tasks.append(self.allocator, task);
        self.condition.signal();
    }

    pub fn clear(self: *TaskRunner) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearUnlocked();
    }

    fn clearUnlocked(self: *TaskRunner) void {
        while (self.tasks.pop()) |task| {
            task.cleanup();
        }
    }

    pub fn isIdle(self: *TaskRunner) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.items.len == 0 and self.active_tasks == 0;
    }

    pub fn shutdown(self: *TaskRunner) void {
        self.mutex.lock();

        if (self.worker_id == std.Thread.getCurrentId()) {
            self.mutex.unlock();
            @panic("TaskRunner.shutdown cannot join its own worker thread");
        }

        if (!self.shutting_down) {
            self.shutting_down = true;
            self.needs_quit = true;
            self.clearUnlocked();
            self.condition.broadcast();
        }

        while (self.join_in_progress) {
            self.condition.wait(&self.mutex);
        }

        const thread = self.thread orelse {
            self.mutex.unlock();
            return;
        };
        self.join_in_progress = true;
        self.mutex.unlock();

        thread.join();

        self.mutex.lock();
        self.thread = null;
        self.worker_id = null;
        self.join_in_progress = false;
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

fn runThread(runner: *TaskRunner) void {
    runner.mutex.lock();
    runner.worker_id = std.Thread.getCurrentId();
    runner.condition.broadcast();
    runner.mutex.unlock();

    _ = runner.measure.registerThread("Tab main thread") catch {};

    while (true) {
        var task_to_run: ?Task = null;
        runner.mutex.lock();
        while (!runner.needs_quit and runner.tasks.items.len == 0) {
            runner.condition.wait(&runner.mutex);
        }

        if (runner.needs_quit) {
            runner.mutex.unlock();
            return;
        }

        task_to_run = runner.tasks.orderedRemove(0);
        runner.active_tasks += 1;
        runner.mutex.unlock();

        if (task_to_run) |task| {
            task.run() catch |err| {
                std.log.err("Task failed: {}", .{err});
            };
            task.cleanup();

            runner.mutex.lock();
            std.debug.assert(runner.active_tasks > 0);
            runner.active_tasks -= 1;
            runner.condition.broadcast();
            runner.mutex.unlock();
        }
    }
}

test "shutdown joins an active worker and cleans pending tasks" {
    const ActiveContext = struct {
        io: std.Io,
        started: std.Io.Semaphore = .{},
        release: std.Io.Semaphore = .{},
        finished: std.atomic.Value(bool) = .init(false),
        cleanup_count: std.atomic.Value(usize) = .init(0),

        fn run(raw_context: *anyopaque) !void {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            context.started.post(context.io);
            context.release.waitUncancelable(context.io);
            context.finished.store(true, .release);
        }

        fn cleanup(raw_context: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            _ = context.cleanup_count.fetchAdd(1, .monotonic);
        }
    };

    const PendingContext = struct {
        run_count: std.atomic.Value(usize) = .init(0),
        cleanup_count: std.atomic.Value(usize) = .init(0),

        fn run(raw_context: *anyopaque) !void {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            _ = context.run_count.fetchAdd(1, .monotonic);
        }

        fn cleanup(raw_context: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            _ = context.cleanup_count.fetchAdd(1, .monotonic);
        }
    };

    const ShutdownContext = struct {
        runner: *TaskRunner,
        returned: std.atomic.Value(bool) = .init(false),

        fn run(context: *@This()) void {
            context.runner.shutdown();
            context.returned.store(true, .release);
        }
    };

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(
        std.testing.allocator,
        std.testing.io,
        &environ,
    );
    defer measure.finish();

    var runner = TaskRunner.init(std.testing.allocator, &measure);
    defer runner.deinit();
    try runner.start();

    var active = ActiveContext{ .io = std.testing.io };
    try runner.schedule(.init(&active, ActiveContext.run, ActiveContext.cleanup));
    active.started.waitUncancelable(std.testing.io);

    var pending = PendingContext{};
    try runner.schedule(.init(&pending, PendingContext.run, PendingContext.cleanup));

    var shutdown_context = ShutdownContext{ .runner = &runner };
    const shutdown_thread = try std.Thread.spawn(.{}, ShutdownContext.run, .{&shutdown_context});

    runner.mutex.lock();
    while (!runner.join_in_progress) {
        runner.condition.wait(&runner.mutex);
    }
    runner.mutex.unlock();

    try std.testing.expect(!shutdown_context.returned.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), pending.cleanup_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), pending.run_count.load(.monotonic));

    active.release.post(std.testing.io);
    shutdown_thread.join();

    try std.testing.expect(shutdown_context.returned.load(.acquire));
    try std.testing.expect(active.finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), active.cleanup_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), runner.active_tasks);
    try std.testing.expect(runner.thread == null);

    // Repeated shutdown is a no-op, and rejected work is still cleaned once.
    runner.shutdown();
    var rejected = PendingContext{};
    try runner.schedule(.init(&rejected, PendingContext.run, PendingContext.cleanup));
    try std.testing.expectEqual(@as(usize, 1), rejected.cleanup_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), rejected.run_count.load(.monotonic));
}
