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
        frozen_dependencies: bool = false,

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
                .frozen_dependencies = false,
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
                .frozen_dependencies = false,
            };
        }


        pub fn deinit(self: *@This()) void {
            self.invalidations.deinit();
        }

        pub fn mark(self: *@This()) void {
            if (self.dirty) return;
            self.dirty = true;
            if (self.owner_ptr) |owner| {
                if (self.owner_mark) |mark_fn| {
                    mark_fn(owner);
                }
            }
        }

        pub fn markNoOwner(self: *@This()) void {
            self.dirty = true;
        }

        pub fn setOwner(self: *@This(), owner: anytype, mark_fn: *const fn (*anyopaque) void) void {
            self.owner_ptr = @ptrCast(@alignCast(owner));
            self.owner_mark = mark_fn;
        }

        pub fn addDependency(self: *@This(), dependency: anytype) void {
            dependency.addInvalidation(self);
        }

        pub fn freezeDependencies(self: *@This()) void {
            self.frozen_dependencies = true;
        }

        pub fn notify(self: *@This()) void {
            if (DEBUG_PROTECTED_FIELDS) {
                std.debug.print("  [NOTIFY] notifying {} dependents\n", .{self.invalidations.count()});
            }
            var it = self.invalidations.iterator();
            while (it.next()) |entry| {
                const mark_fn = entry.value_ptr.*;
                mark_fn(entry.key_ptr.*);
            }
        }

        fn addInvalidation(self: *@This(), target: anytype) void {
            const notify_ptr: *anyopaque = @ptrCast(@alignCast(@constCast(target)));
            const self_ptr: *anyopaque = @ptrCast(@alignCast(self));
            if (notify_ptr == self_ptr) return;
            if (self.invalidations.contains(notify_ptr)) return;

            const MarkFn = struct {
                fn mark(ptr: *anyopaque) void {
                    const field: @TypeOf(@constCast(target)) = @constCast(@ptrCast(@alignCast(ptr)));
                    field.mark();
                }
            };

            self.invalidations.put(notify_ptr, MarkFn.mark) catch {};
        }

        pub fn read(self: *const @This(), target: anytype) *const T {
            const self_mut: *@This() = @constCast(self);
            const notify_ptr: *anyopaque = @ptrCast(@alignCast(@constCast(target)));
            if (@hasField(@TypeOf(target.*), "frozen_dependencies") and target.frozen_dependencies) {
                std.debug.assert(self.invalidations.contains(notify_ptr));
            } else {
                self_mut.addInvalidation(target);
            }
            return self.get();
        }

        pub fn copy(self: *@This(), src: anytype) void {
            const value = src.read(self);
            self.set(value.*);
        }

        pub fn get(self: *const @This()) *const T {
            if (self.dirty) {
                std.debug.print("[PROTECTED_FIELD] get() called on dirty field! Type={s} obj={s} name={s}\n", .{ @typeName(T), self.obj, self.name });
                // Print stack trace to help identify the caller
                std.debug.dumpCurrentStackTrace(@returnAddress());
            }
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
                    if (DEBUG_PROTECTED_FIELDS) {
                        std.debug.print("[SET] value changed, invalidating\n", .{});
                    }
                    value_changed = true;
                    self.notify();
                } else if (DEBUG_PROTECTED_FIELDS) {
                    // Skip logging unchanged values to reduce noise
                }
            } else {
                // Complex types: always notify
                if (DEBUG_PROTECTED_FIELDS) {
                    std.debug.print("[SET] complex type, invalidating\n", .{});
                }
                value_changed = true;
                self.notify();
            }

            self.value = value;
            self.dirty = false;
        }
    };
}
