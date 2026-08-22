//! Bounded thread batches whose callers retain every job/result slot.
//!
//! The caller must finish constructing the `Job` slice before this function
//! starts: worker contexts are synchronous borrows and every spawned thread is
//! joined before `runAndJoin` returns. If a native thread cannot be created,
//! that job runs on the calling thread so resource loading remains correct.

const std = @import("std");

pub const Job = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) void,
    thread: ?std.Thread = null,

    fn run(self: *Job) void {
        self.run_fn(self.context);
    }
};

/// Start every available job before joining any of them. Results remain in
/// the caller-owned contexts, allowing the consumer to process them in a
/// deterministic order unrelated to network completion order.
pub fn runAndJoin(jobs: []Job) void {
    for (jobs) |*job| {
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            std.log.warn("Failed to start resource fetch thread ({}); loading synchronously", .{err});
            job.run();
            continue;
        };
    }

    for (jobs) |*job| {
        if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        }
    }
}

test "thread batch starts all jobs before joining and retains slot order" {
    const Context = struct {
        io: std.Io,
        started: *std.Io.Semaphore,
        release: *std.Io.Semaphore,
        result: *u8,
        value: u8,

        fn run(raw: *anyopaque) void {
            const context: *@This() = @ptrCast(@alignCast(raw));
            context.started.post(context.io);
            context.release.waitUncancelable(context.io);
            context.result.* = context.value;
        }
    };

    const Coordinator = struct {
        jobs: []Job,

        fn run(self: *@This()) void {
            runAndJoin(self.jobs);
        }
    };

    var started: std.Io.Semaphore = .{};
    var releases = [_]std.Io.Semaphore{ .{}, .{}, .{} };
    var results = [_]u8{ 0, 0, 0 };
    var contexts = [_]Context{
        .{ .io = std.testing.io, .started = &started, .release = &releases[0], .result = &results[0], .value = 'a' },
        .{ .io = std.testing.io, .started = &started, .release = &releases[1], .result = &results[1], .value = 'b' },
        .{ .io = std.testing.io, .started = &started, .release = &releases[2], .result = &results[2], .value = 'c' },
    };
    var jobs: [contexts.len]Job = undefined;
    for (&jobs, &contexts) |*job, *context| {
        job.* = .{ .context = context, .run_fn = Context.run };
    }

    var coordinator = Coordinator{ .jobs = &jobs };
    const coordinator_thread = try std.Thread.spawn(.{}, Coordinator.run, .{&coordinator});
    for (contexts) |_| started.waitUncancelable(std.testing.io);

    // Complete out of order. Caller-owned result slots still retain discovery
    // order, which is how stylesheet/script consumers preserve DOM ordering.
    releases[2].post(std.testing.io);
    releases[0].post(std.testing.io);
    releases[1].post(std.testing.io);
    coordinator_thread.join();

    try std.testing.expectEqualStrings("abc", &results);
}
