//! Per-tab serialized background task execution.
//!
//! A `Task` borrows its opaque context until its cleanup callback runs. The
//! runner executes and cleans each accepted task exactly once, or cleans it
//! without running when pending work is cleared. `shutdown` rejects new work,
//! cleans pending work, and joins the worker. Once it returns, no worker can
//! access the runner or an active task context. Every executed callback is
//! bracketed by a producer-named `task:*` Chrome trace span. The queue favors
//! rendering and user input over ordinary browser work and JavaScript API
//! callbacks, but periodically runs the oldest lower-priority task so a busy
//! page cannot starve it forever.

const std = @import("std");
const MeasureTime = @import("measure_time.zig").MeasureTime;
const sync = @import("sync.zig");

pub const Task = struct {
    pub const Priority = enum {
        /// requestAnimationFrame and rendering-pipeline work.
        rendering,
        /// Direct keyboard, pointer, history, focus, and resize work.
        user_input,
        /// Navigation, parsing, and document-authored script evaluation.
        normal,
        /// Callbacks originating in asynchronous JavaScript APIs.
        javascript,

        fn rank(self: Priority) u8 {
            return switch (self) {
                .rendering, .user_input => 2,
                .normal => 1,
                .javascript => 0,
            };
        }
    };

    priority: Priority,
    /// Borrowed diagnostic label. The producer must keep it alive until this
    /// task is either executed or discarded; production callers use literals.
    trace_name: []const u8,
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) anyerror!void,
    cleanup_fn: ?*const fn (*anyopaque) void = null,

    pub fn init(
        priority: Priority,
        trace_name: []const u8,
        context: *anyopaque,
        run_fn: *const fn (*anyopaque) anyerror!void,
        cleanup_fn: ?*const fn (*anyopaque) void,
    ) Task {
        return .{
            .priority = priority,
            .trace_name = trace_name,
            .context = context,
            .run_fn = run_fn,
            .cleanup_fn = cleanup_fn,
        };
    }

    fn run(self: Task, measure: *MeasureTime) anyerror!void {
        const tracing = measure.begin(self.trace_name);
        defer if (tracing) measure.end(self.trace_name);
        try self.run_fn(self.context);
    }

    fn cleanup(self: Task) void {
        if (self.cleanup_fn) |cleanup_fn| {
            cleanup_fn(self.context);
        }
    }
};

pub const TaskRunner = struct {
    /// After this many higher-rank selections bypass older lower-priority
    /// work, run exactly one oldest lower-priority task before resuming.
    pub const priority_burst_limit: usize = 8;

    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task),
    mutex: sync.Mutex,
    condition: sync.Condition,
    needs_quit: bool = false,
    shutting_down: bool = false,
    join_in_progress: bool = false,
    active_tasks: usize = 0,
    priority_burst_rank: ?u8 = null,
    priority_burst_count: usize = 0,
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
        self.priority_burst_rank = null;
        self.priority_burst_count = 0;
    }

    /// Select the oldest task at the greatest priority. A bounded burst of
    /// higher-priority work may bypass lower-priority entries; the next pick
    /// is then the oldest bypassed entry, which provides deterministic aging
    /// without wall-clock sleeps or a second owning queue.
    fn takeNextTaskLocked(self: *TaskRunner) Task {
        std.debug.assert(self.tasks.items.len > 0);

        var highest_index: usize = 0;
        var highest_rank = self.tasks.items[0].priority.rank();
        for (self.tasks.items[1..], 1..) |task, index| {
            const rank = task.priority.rank();
            if (rank > highest_rank) {
                highest_index = index;
                highest_rank = rank;
            }
        }

        var oldest_lower_index: ?usize = null;
        for (self.tasks.items, 0..) |task, index| {
            if (task.priority.rank() < highest_rank) {
                oldest_lower_index = index;
                break;
            }
        }

        if (oldest_lower_index) |lower_index| {
            if (self.priority_burst_rank != highest_rank) {
                self.priority_burst_rank = highest_rank;
                self.priority_burst_count = 0;
            }
            if (self.priority_burst_count >= priority_burst_limit) {
                self.priority_burst_rank = null;
                self.priority_burst_count = 0;
                return self.tasks.orderedRemove(lower_index);
            }
            self.priority_burst_count += 1;
        } else {
            self.priority_burst_rank = null;
            self.priority_burst_count = 0;
        }

        return self.tasks.orderedRemove(highest_index);
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

        task_to_run = runner.takeNextTaskLocked();
        runner.active_tasks += 1;
        runner.mutex.unlock();

        if (task_to_run) |task| {
            task.run(runner.measure) catch |err| {
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

const TestTaskRecorder = struct {
    io: std.Io,
    labels: [32]u8 = undefined,
    next_index: std.atomic.Value(usize) = .init(0),
    completed: std.Io.Semaphore = .{},

    fn waitFor(self: *TestTaskRecorder, count: usize) void {
        for (0..count) |_| self.completed.waitUncancelable(self.io);
    }
};

const TestTaskContext = struct {
    recorder: *TestTaskRecorder,
    label: u8,

    fn run(raw_context: *anyopaque) !void {
        const context: *@This() = @ptrCast(@alignCast(raw_context));
        const index = context.recorder.next_index.fetchAdd(1, .monotonic);
        context.recorder.labels[index] = context.label;
        context.recorder.completed.post(context.recorder.io);
    }
};

test "task runner prioritizes rendering and input while preserving priority FIFO" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(std.testing.allocator, std.testing.io, &environ);
    defer measure.finish();

    var runner = TaskRunner.init(std.testing.allocator, &measure);
    defer runner.deinit();
    var recorder = TestTaskRecorder{ .io = std.testing.io };
    var contexts = [_]TestTaskContext{
        .{ .recorder = &recorder, .label = 'j' },
        .{ .recorder = &recorder, .label = 'n' },
        .{ .recorder = &recorder, .label = 'i' },
        .{ .recorder = &recorder, .label = 'r' },
        .{ .recorder = &recorder, .label = 'k' },
    };
    const priorities = [_]Task.Priority{
        .javascript,
        .normal,
        .user_input,
        .rendering,
        .user_input,
    };

    for (&contexts, priorities) |*context, priority| {
        try runner.schedule(.init(priority, "task:test_priority", context, TestTaskContext.run, null));
    }
    try runner.start();
    recorder.waitFor(contexts.len);
    runner.shutdown();

    try std.testing.expectEqualStrings("irknj", recorder.labels[0..contexts.len]);
}

test "task runner gives oldest low-priority work a bounded starvation escape" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var measure = try MeasureTime.init(std.testing.allocator, std.testing.io, &environ);
    defer measure.finish();

    var runner = TaskRunner.init(std.testing.allocator, &measure);
    defer runner.deinit();
    var recorder = TestTaskRecorder{ .io = std.testing.io };
    var contexts: [TaskRunner.priority_burst_limit + 2]TestTaskContext = undefined;
    contexts[0] = .{ .recorder = &recorder, .label = 'j' };
    try runner.schedule(.init(.javascript, "task:test_starved", &contexts[0], TestTaskContext.run, null));
    for (0..TaskRunner.priority_burst_limit + 1) |index| {
        contexts[index + 1] = .{ .recorder = &recorder, .label = @intCast('0' + index) };
        try runner.schedule(.init(
            .rendering,
            "task:test_urgent",
            &contexts[index + 1],
            TestTaskContext.run,
            null,
        ));
    }

    try runner.start();
    recorder.waitFor(contexts.len);
    runner.shutdown();

    try std.testing.expectEqualStrings("01234567j8", recorder.labels[0..contexts.len]);
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
    try runner.schedule(.init(.normal, "task:test_active", &active, ActiveContext.run, ActiveContext.cleanup));
    active.started.waitUncancelable(std.testing.io);

    var pending = PendingContext{};
    try runner.schedule(.init(.normal, "task:test_pending", &pending, PendingContext.run, PendingContext.cleanup));

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
    try runner.schedule(.init(.normal, "task:test_rejected", &rejected, PendingContext.run, PendingContext.cleanup));
    try std.testing.expectEqual(@as(usize, 1), rejected.cleanup_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), rejected.run_count.load(.monotonic));
}
