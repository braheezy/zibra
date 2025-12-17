const std = @import("std");
const MeasureTime = @import("measure_time.zig").MeasureTime;

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

    pub fn run(self: Task) anyerror!void {
        try self.run_fn(self.context);
    }

    pub fn cleanup(self: Task) void {
        if (self.cleanup_fn) |cleanup_fn| {
            cleanup_fn(self.context);
        }
    }
};

pub const TaskRunner = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    needs_quit: bool = false,
    shutting_down: bool = false,
    thread: ?std.Thread = null,
    measure: *MeasureTime,

    pub fn init(allocator: std.mem.Allocator, measure: *MeasureTime) TaskRunner {
        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(Task).empty,
            .measure = measure,
        };
    }

    pub fn deinit(self: *TaskRunner) void {
        self.shutdown();
        self.tasks.deinit(self.allocator);
    }

    pub fn start(self: *TaskRunner) !void {
        const thread = try std.Thread.spawn(.{}, runThread, .{self});
        _ = thread.setName("Tab main thread") catch |err| {
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

    pub fn isEmpty(self: *const TaskRunner) bool {
        return self.tasks.items.len == 0;
    }

    pub fn pendingCount(self: *const TaskRunner) usize {
        return self.tasks.items.len;
    }

    pub fn setNeedsQuit(self: *TaskRunner) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.needs_quit = true;
        self.condition.broadcast();
    }

    pub fn shutdown(self: *TaskRunner) void {
        self.mutex.lock();
        if (self.shutting_down) {
            self.mutex.unlock();
            return;
        }

        self.shutting_down = true;
        self.needs_quit = true;
        self.clearUnlocked();
        self.condition.broadcast();
        self.mutex.unlock();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
};

fn runThread(runner: *TaskRunner) void {
    _ = runner.measure.registerThread("Tab main thread") catch |err| {
        std.log.warn("Failed to register tab thread: {}", .{err});
    };

    while (true) {
        var task_to_run: ?Task = null;
        runner.mutex.lock();
        while (!runner.needs_quit and runner.tasks.items.len == 0) {
            runner.condition.wait(&runner.mutex);
        }

        if (runner.needs_quit) {
            runner.mutex.unlock();
            break;
        }

        task_to_run = runner.tasks.orderedRemove(0);
        runner.mutex.unlock();

        if (task_to_run) |task| {
            defer task.cleanup();
            task.run() catch |err| {
                std.log.err("Task failed: {}", .{err});
            };
        }
    }
}
