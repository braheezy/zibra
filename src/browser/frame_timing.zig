//! Clock-based cadence estimation for the overlapping tab/raster pipeline.

const std = @import("std");

pub const default_interval_ns: i96 = 33_000_000;
pub const headroom_ns: u64 = 3_000_000;
pub const maximum_estimated_work_ns: u64 = 1_000_000_000;

/// Estimates the sustainable cadence of two overlapping frame stages.
pub const Estimator = struct {
    tab_work_ns: ?u64 = null,
    browser_work_ns: ?u64 = null,

    pub fn reset(self: *Estimator) void {
        self.* = .{};
    }

    pub fn observeTabWork(self: *Estimator, duration_ns: i96) void {
        updateEstimate(&self.tab_work_ns, duration_ns);
    }

    pub fn observeBrowserWork(self: *Estimator, duration_ns: i96) void {
        updateEstimate(&self.browser_work_ns, duration_ns);
    }

    fn updateEstimate(slot: *?u64, duration_ns: i96) void {
        const normalized: u64 = if (duration_ns <= 0)
            0
        else
            @intCast(@min(duration_ns, @as(i96, maximum_estimated_work_ns)));
        const previous = slot.* orelse {
            slot.* = normalized;
            return;
        };

        if (normalized >= previous) {
            slot.* = previous +| @divTrunc(normalized - previous + 1, 2);
        } else {
            slot.* = previous - @divTrunc(previous - normalized + 7, 8);
        }
    }

    pub fn estimatedWorkNs(self: *const Estimator) u64 {
        return @max(self.tab_work_ns orelse 0, self.browser_work_ns orelse 0);
    }

    pub fn intervalNs(self: *const Estimator) i96 {
        const estimated_work = self.estimatedWorkNs();
        if (estimated_work == 0) return default_interval_ns;

        const base: u64 = @intCast(default_interval_ns);
        const required = estimated_work +| headroom_ns;
        const maximum_steps = @divTrunc(
            maximum_estimated_work_ns + headroom_ns + base - 1,
            base,
        );
        const requested_steps = @divTrunc(required +| base - 1, base);
        const steps = std.math.clamp(requested_steps, @as(u64, 1), maximum_steps);
        return @intCast(steps * base);
    }
};

pub const Timing = struct {
    deadline_ns: i96,
    delay_ns: u64,
};

/// Advance from the prior absolute deadline instead of from frame completion.
pub fn next(
    previous_deadline_ns: ?i96,
    now_ns: i96,
    interval_ns: i96,
) Timing {
    std.debug.assert(interval_ns > 0);
    const deadline_ns = if (previous_deadline_ns) |previous|
        previous +| interval_ns
    else
        now_ns +| interval_ns;
    const remaining_ns = deadline_ns -| now_ns;
    const delay_ns: u64 = if (remaining_ns <= 0)
        0
    else
        @intCast(@min(remaining_ns, @as(i96, std.math.maxInt(u64))));
    return .{ .deadline_ns = deadline_ns, .delay_ns = delay_ns };
}
