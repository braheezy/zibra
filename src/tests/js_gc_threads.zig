//! Native-thread collector regressions: cold worker initialization, host
//! handoff, and stack-only results retained across another thread's collection.

const std = @import("std");
const kiesel = @import("kiesel");
const gc_threads = @import("../script/gc_threads.zig");
const Js = @import("../script/js.zig");

test "collector thread lifetime registers simultaneous workers and retires them" {
    const StartGate = struct {
        ready: std.Io.Semaphore = .{},
        proceed: std.Io.Semaphore = .{},
    };
    const Worker = struct {
        gate: *StartGate,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.gate.ready.post(std.testing.io);
            self.gate.proceed.waitUncancelable(std.testing.io);
            self.execute() catch |err| {
                self.failure = err;
            };
        }

        fn execute(_: *@This()) !void {
            gc_threads.ensureCurrentThread(std.testing.io);
            const bytes = try kiesel.gc.allocator.alloc(u8, 1024);
            @memset(bytes, 42);
            kiesel.gc.collect();
            for (bytes) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
            std.mem.doNotOptimizeAway(bytes.ptr);
        }
    };

    // With a filter matching only this test, the first GC initialization is
    // deliberately contested by two workers. Later pairs collect after both
    // preceding native threads have exited (including the initial GC caller).
    for (0..8) |_| {
        var gate = StartGate{};
        var workers = [_]Worker{ .{ .gate = &gate }, .{ .gate = &gate } };
        const first = try std.Thread.spawn(.{}, Worker.run, .{&workers[0]});
        const second = std.Thread.spawn(.{}, Worker.run, .{&workers[1]}) catch |err| {
            gate.proceed.post(std.testing.io);
            first.join();
            return err;
        };
        gate.ready.waitUncancelable(std.testing.io);
        gate.ready.waitUncancelable(std.testing.io);
        gate.proceed.post(std.testing.io);
        gate.proceed.post(std.testing.io);
        first.join();
        second.join();
        for (workers) |worker| if (worker.failure) |err| return err;
    }
}

test "collector thread lifetime retires initializing JS workers before later collection" {
    const Worker = struct {
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.execute() catch |err| {
                self.failure = err;
            };
        }

        fn execute(_: *@This()) !void {
            var environ = std.process.Environ.Map.init(std.testing.allocator);
            defer environ.deinit();
            const js = try Js.init(std.testing.allocator, std.testing.io, &environ);
            defer js.deinit(std.testing.allocator);
            try std.testing.expect((try js.evaluate(0, "[1, 2, 3].join('') === '123'")).toBoolean());
            kiesel.gc.collect();
        }
    };
    // Keep parsing sequential: the pinned Kiesel tokenizer has process-global
    // mutable state. This regression is specifically the dead-thread GC bug.
    for (0..8) |_| {
        var worker = Worker{};
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        thread.join();
        if (worker.failure) |err| return err;
    }
}

test "collector thread lifetime permits host retirement on a different thread" {
    const Worker = struct {
        environ: *const std.process.Environ.Map,
        js: ?*Js = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.js = Js.init(std.testing.allocator, std.testing.io, self.environ) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var worker = Worker{ .environ = &environ };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    // deinit's lock-taking boundary must register this thread even though it
    // never constructed or evaluated a host. No creator-thread borrow remains.
    worker.js.?.deinit(std.testing.allocator);
    kiesel.gc.collect();
    kiesel.gc.collect();
}

test "collector thread lifetime retains returned values on an idle caller stack" {
    const Worker = struct {
        js: *Js,
        entered: std.Io.Semaphore = .{},
        proceed: std.Io.Semaphore = .{},
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            // This thread did not call Js.init: evaluate must register it.
            const result = self.js.evaluate(0, "['stack', 'only', 'result'].join('-')") catch |err| {
                self.failure = err;
                self.entered.post(std.testing.io);
                return;
            };
            self.entered.post(std.testing.io);
            self.proceed.waitUncancelable(std.testing.io);
            self.check(result) catch |err| {
                self.failure = err;
            };
        }

        fn check(_: *@This(), result: kiesel.types.Value) !void {
            const text = try result.asString().toUtf8(std.testing.allocator);
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings("stack-only-result", text);
        }
    };
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const js = try Js.init(std.testing.allocator, std.testing.io, &environ);
    defer js.deinit(std.testing.allocator);
    var worker = Worker{ .js = js };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    {
        defer thread.join();
        defer worker.proceed.post(std.testing.io);
        worker.entered.waitUncancelable(std.testing.io);
        // evaluate has returned and released JsLock, but its caller still
        // owns the result. Callback-scoped registrations would be too short.
        kiesel.gc.collect();
        kiesel.gc.collect();
    }
    if (worker.failure) |err| return err;
    // A joined thread must no longer be a suspend/stack-scan target.
    kiesel.gc.collect();
}
