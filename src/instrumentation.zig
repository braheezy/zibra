const std = @import("std");

pub const Timing = struct {
    name: []const u8,
    total_time: i128,
    calls: usize,
};

pub const Instrumentation = struct {
    timings: std.StringHashMap(Timing),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Instrumentation {
        const inst = try allocator.create(Instrumentation);
        inst.* = .{
            .timings = std.StringHashMap(Timing).init(allocator),
            .allocator = allocator,
        };
        return inst;
    }

    pub fn deinit(self: *Instrumentation) void {
        self.timings.deinit();
        self.allocator.destroy(self);
    }

    pub fn startTiming(self: *Instrumentation, name: []const u8) !i128 {
        const start = std.time.nanoTimestamp();
        if (!self.timings.contains(name)) {
            try self.timings.put(name, .{
                .name = name,
                .total_time = 0,
                .calls = 0,
            });
        }
        return start;
    }

    pub fn endTiming(self: *Instrumentation, name: []const u8, start_time: i128) void {
        const end = std.time.nanoTimestamp();
        const duration = end - start_time;

        if (self.timings.getPtr(name)) |timing| {
            timing.total_time += duration;
            timing.calls += 1;
        }
    }

    pub fn printStats(self: *Instrumentation) void {
        std.debug.print("\n=== Performance Statistics ===\n", .{});
        var it = self.timings.iterator();
        while (it.next()) |entry| {
            const timing = entry.value_ptr.*;
            const avg_time = @as(f64, @floatFromInt(timing.total_time)) / @as(f64, @floatFromInt(timing.calls));
            std.debug.print("{s}:\n", .{timing.name});
            std.debug.print("  Total time: {d:.2}ms\n", .{@as(f64, @floatFromInt(timing.total_time)) / 1_000_000.0});
            std.debug.print("  Calls: {d}\n", .{timing.calls});
            std.debug.print("  Avg time: {d:.2}µs\n\n", .{avg_time / 1_000.0});
        }
    }
};
