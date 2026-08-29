//! Per-window software presentation worker ownership.
//!
//! `Worker` owns the raster task runner, worker-only caches, completed result,
//! and every allocator-matched software surface in that pipeline. It knows
//! nothing about Browser, Tab, or SDL. The Browser coordinates snapshots and
//! validates/takes a result under its own lock before performing native upload.

const std = @import("std");
const z2d = @import("z2d");

const compositor_cache = @import("render/compositor_cache.zig");
const scroll_model = @import("scroll.zig");
const MeasureTime = @import("../runtime/measure_time.zig").MeasureTime;
const TaskRunner = @import("../runtime/task.zig").TaskRunner;

pub const Result = struct {
    allocator: std.mem.Allocator,
    surface: z2d.Surface,
    interest_region: scroll_model.InterestRegion,
    interest_region_valid: bool,
    window_width: i32,
    window_height: i32,
    /// Numeric identity only; the worker result never owns or dereferences a
    /// Tab. Browser revalidates this identity while holding its lock.
    active_identity: ?usize,
    duration_ns: u64,
    sample_animation_work: bool,

    pub fn deinit(self: *Result) void {
        self.surface.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    runner: TaskRunner,
    task_active: bool = false,
    result: ?Result = null,
    chrome_surface: ?z2d.Surface = null,
    tab_surface: ?z2d.Surface = null,
    compositor_cache: compositor_cache.Cache = .{},
    interest_region: scroll_model.InterestRegion = .{ .start_px = 0, .height_px = 0 },
    interest_region_valid: bool = false,

    pub fn init(allocator: std.mem.Allocator, measure: *MeasureTime) Worker {
        return .{
            .allocator = allocator,
            .runner = TaskRunner.initNamed(allocator, measure, "Raster and draw thread"),
        };
    }

    /// Start only after this Worker has reached its final heap-stable Browser
    /// field address; TaskRunner's native thread retains the runner address.
    pub fn start(self: *Worker) !void {
        try self.runner.start();
    }

    /// Stop the sole producer before reclaiming a queued/completed result or
    /// any worker cache it could still be reading or replacing.
    pub fn deinit(self: *Worker) void {
        self.runner.deinit();
        if (self.result) |*result| result.deinit();
        if (self.chrome_surface) |*surface| surface.deinit(self.allocator);
        if (self.tab_surface) |*surface| surface.deinit(self.allocator);
        self.compositor_cache.deinit(self.allocator);
        self.* = undefined;
    }
};

test "presentation result owns its accepted software surface" {
    const allocator = std.testing.allocator;
    const surface = try z2d.Surface.init(.image_surface_rgba, allocator, 4, 3);
    var result = Result{
        .allocator = allocator,
        .surface = surface,
        .interest_region = .{ .start_px = 5, .height_px = 12 },
        .interest_region_valid = true,
        .window_width = 4,
        .window_height = 3,
        .active_identity = 17,
        .duration_ns = 0,
        .sample_animation_work = false,
    };
    result.deinit();
}
