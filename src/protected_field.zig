const std = @import("std");

// Debug flag: set to true to enable invalidation logging
const DEBUG_PROTECTED_FIELDS = false;

pub fn ProtectedField(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        value: T,
        dirty: bool,
        invalidations: std.AutoHashMap(*anyopaque, *const fn (*anyopaque) void),
        obj: []const u8 = "",
        name: []const u8 = "",
        owner_mark: ?*const fn (*anyopaque) void = null,
        owner_ptr: ?*anyopaque = null,

        pub fn init(allocator: std.mem.Allocator, value: T) @This() {
            return .{
                .allocator = allocator,
                .value = value,
                .dirty = true,
                .invalidations = std.AutoHashMap(*anyopaque, *const fn (*anyopaque) void).init(allocator),
                .obj = "",
                .name = "",
                .owner_mark = null,
                .owner_ptr = null,
            };
        }

        pub fn initNamed(allocator: std.mem.Allocator, value: T, obj: []const u8, name: []const u8) @This() {
            return .{
                .allocator = allocator,
                .value = value,
                .dirty = true,
                .invalidations = std.AutoHashMap(*anyopaque, *const fn (*anyopaque) void).init(allocator),
                .obj = obj,
                .name = name,
                .owner_mark = null,
                .owner_ptr = null,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.invalidations.deinit();
        }

        pub fn mark(self: *@This()) void {
            self.dirty = true;
        }

        pub fn setOwner(self: *@This(), owner: anytype, mark_fn: *const fn (*anyopaque) void) void {
            self.owner_ptr = @ptrCast(@alignCast(owner));
            self.owner_mark = mark_fn;
        }

        pub fn notify(self: *@This()) void {
            if (DEBUG_PROTECTED_FIELDS and self.obj.len > 0) {
                std.debug.print("  [INVALIDATE] {s}.{s} notifying {} dependents\n", .{ self.obj, self.name, self.invalidations.count() });
            }
            var it = self.invalidations.iterator();
            while (it.next()) |entry| {
                const mark_fn = entry.value_ptr.*;
                mark_fn(entry.key_ptr.*);
            }
        }

        fn addInvalidation(self: *@This(), target: anytype) void {
            const notify_ptr: *anyopaque = @ptrCast(@alignCast(target));
            if (self.invalidations.contains(notify_ptr)) return;

            const MarkFn = struct {
                fn mark(ptr: *anyopaque) void {
                    const field: @TypeOf(target) = @ptrCast(@alignCast(ptr));
                    field.mark();
                }
            };

            self.invalidations.put(notify_ptr, MarkFn.mark) catch {};
        }

        pub fn read(self: *const @This(), target: anytype) *const T {
            const self_mut: *@This() = @constCast(self);
            self_mut.addInvalidation(target);
            return self.get();
        }

        pub fn copy(self: *@This(), src: anytype) void {
            const value = src.read(self);
            self.set(value.*);
        }

        pub fn get(self: *const @This()) *const T {
            std.debug.assert(!self.dirty);
            return &self.value;
        }

        pub fn getMut(self: *@This()) *T {
            std.debug.assert(!self.dirty);
            return &self.value;
        }

        pub fn set(self: *@This(), value: T) void {
            // Only notify dependents if the value actually changed (for comparable types)
            // Check type at comptime and decide whether to compare
            var value_changed = false;
            if (comptime (T == i32 or T == f32 or T == i64 or T == f64 or T == bool or T == u32 or T == u64)) {
                // Simple types: only notify if value changed
                if (self.value != value) {
                    if (DEBUG_PROTECTED_FIELDS and self.obj.len > 0) {
                        std.debug.print("[SET] {s}.{s} changed, invalidating\n", .{ self.obj, self.name });
                    }
                    value_changed = true;
                    self.notify();
                } else if (DEBUG_PROTECTED_FIELDS and self.obj.len > 0) {
                    std.debug.print("[SET] {s}.{s} unchanged (no-op), skipping invalidation\n", .{ self.obj, self.name });
                }
            } else {
                // Complex types: always notify
                if (DEBUG_PROTECTED_FIELDS and self.obj.len > 0) {
                    std.debug.print("[SET] {s}.{s} (complex type), invalidating\n", .{ self.obj, self.name });
                }
                value_changed = true;
                self.notify();
            }

            // Notify owner if value changed
            if (value_changed) {
                if (self.owner_ptr) |owner| {
                    if (self.owner_mark) |mark_fn| {
                        mark_fn(owner);
                    }
                }
            }

            self.value = value;
            self.dirty = false;
        }
    };
}
