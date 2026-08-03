//! Uncancelable synchronization wrappers bound to a `std.Io` instance.
//!
//! These types provide the blocking semantics used by Zibra's browser and tab
//! workers. `Condition.wait` atomically releases the supplied mutex while
//! waiting and reacquires it before returning.

const std = @import("std");

pub const Mutex = struct {
    io: std.Io,
    inner: std.Io.Mutex = .init,

    pub fn init(io: std.Io) Mutex {
        return .{ .io = io };
    }

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(self.io);
    }
};

pub const Condition = struct {
    io: std.Io,
    inner: std.Io.Condition = .init,

    pub fn init(io: std.Io) Condition {
        return .{ .io = io };
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(self.io, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(self.io);
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(self.io);
    }
};
