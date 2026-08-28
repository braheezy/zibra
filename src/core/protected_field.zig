//! Dependency-tracked fields that propagate style and layout invalidation.
//!
//! Owners and dependents must remain at stable addresses after registration.
//! The current implementation has no unsubscribe operation and is not thread
//! safe; callers must destroy an entire dependency graph in a compatible order.

const std = @import("std");
const builtin = @import("builtin");

// Debug flag: set to true to enable invalidation logging
const DEBUG_PROTECTED_FIELDS = false;

pub fn ProtectedField(comptime T: type) type {
    // The generic is a comptime type factory: values and dirty state live
    // directly in their owner instead of requiring a boxed field object. Keep
    // the remaining dependency collection unmanaged too, so every field does
    // not carry another allocator interface. Callers already know the owning
    // allocator at the graph construction/destruction boundary and pass it to
    // the operations that can allocate.
    const Invalidations = std.AutoHashMapUnmanaged(*anyopaque, *const fn (*anyopaque) void);
    const DebugInfo = if (builtin.mode == .Debug)
        struct {
            obj: []const u8,
            name: []const u8,
        }
    else
        struct {};

    return struct {
        value: T,
        dirty: bool,
        invalidations: Invalidations,
        debug_info: DebugInfo,
        owner_mark: ?*const fn (*anyopaque) void = null,
        owner_ptr: ?*anyopaque = null,
        frozen_dependencies: bool = false,

        pub inline fn init(value: T) @This() {
            return .{
                .value = value,
                .dirty = true,
                .invalidations = .empty,
                .debug_info = if (builtin.mode == .Debug)
                    .{ .obj = "", .name = "" }
                else
                    .{},
                .owner_mark = null,
                .owner_ptr = null,
                .frozen_dependencies = false,
            };
        }

        pub inline fn initNamed(value: T, obj: []const u8, name: []const u8) @This() {
            return .{
                .value = value,
                .dirty = true,
                .invalidations = .empty,
                .debug_info = if (builtin.mode == .Debug)
                    .{ .obj = obj, .name = name }
                else
                    .{},
                .owner_mark = null,
                .owner_ptr = null,
                .frozen_dependencies = false,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.invalidations.deinit(allocator);
        }

        pub inline fn mark(self: *@This()) void {
            if (self.dirty) return;
            self.dirty = true;
            if (self.owner_ptr) |owner| {
                if (self.owner_mark) |mark_fn| {
                    mark_fn(owner);
                }
            }
        }

        pub inline fn markNoOwner(self: *@This()) void {
            self.dirty = true;
        }

        pub inline fn setOwner(self: *@This(), owner: anytype, mark_fn: *const fn (*anyopaque) void) void {
            self.owner_ptr = @ptrCast(@alignCast(owner));
            self.owner_mark = mark_fn;
        }

        pub inline fn addDependency(
            self: *@This(),
            dependency: anytype,
            allocator: std.mem.Allocator,
        ) void {
            dependency.addInvalidation(self, allocator);
        }

        pub inline fn freezeDependencies(self: *@This()) void {
            self.frozen_dependencies = true;
        }

        /// Drop every raw subscriber pointer while their targets are still
        /// alive. Callers that use this coarse structural-mutation boundary
        /// must force a complete recomputation so dependencies are rebuilt.
        pub fn clearInvalidations(self: *@This()) void {
            self.invalidations.clearRetainingCapacity();
        }

        fn notify(self: *@This()) void {
            if (DEBUG_PROTECTED_FIELDS) {
                std.debug.print("  [NOTIFY] notifying {} dependents\n", .{self.invalidations.count()});
            }
            var it = self.invalidations.iterator();
            while (it.next()) |entry| {
                const mark_fn = entry.value_ptr.*;
                mark_fn(entry.key_ptr.*);
            }
        }

        fn addInvalidation(
            self: *@This(),
            target: anytype,
            allocator: std.mem.Allocator,
        ) void {
            const notify_ptr: *anyopaque = @ptrCast(@alignCast(@constCast(target)));
            const self_ptr: *anyopaque = @ptrCast(@alignCast(self));
            if (notify_ptr == self_ptr) return;
            if (self.invalidations.contains(notify_ptr)) return;

            const MarkFn = struct {
                fn mark(ptr: *anyopaque) void {
                    const field: @TypeOf(@constCast(target)) = @ptrCast(@alignCast(@constCast(ptr)));
                    field.mark();
                }
            };

            self.invalidations.put(allocator, notify_ptr, MarkFn.mark) catch {};
        }

        pub inline fn read(
            self: *const @This(),
            target: anytype,
            allocator: std.mem.Allocator,
        ) *const T {
            const self_mut: *@This() = @constCast(self);
            const notify_ptr: *anyopaque = @ptrCast(@alignCast(@constCast(target)));
            if (@hasField(@TypeOf(target.*), "frozen_dependencies") and target.frozen_dependencies) {
                std.debug.assert(self.invalidations.contains(notify_ptr));
            } else {
                self_mut.addInvalidation(target, allocator);
            }
            return self.get();
        }

        pub inline fn get(self: *const @This()) *const T {
            if (self.dirty) {
                if (builtin.mode == .Debug) {
                    std.debug.print("[PROTECTED_FIELD] get() called on dirty field! Type={s} obj={s} name={s}\n", .{ @typeName(T), self.debug_info.obj, self.debug_info.name });
                } else {
                    std.debug.print("[PROTECTED_FIELD] get() called on dirty field! Type={s}\n", .{@typeName(T)});
                }
                // Print stack trace to help identify the caller
                std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
            }
            std.debug.assert(!self.dirty);
            return &self.value;
        }

        /// Return the last published value without requiring the field to be
        /// clean or registering a dependency. This is a historical snapshot,
        /// not permission to use a dirty field as current computed state.
        pub inline fn lastValue(self: *const @This()) *const T {
            return &self.value;
        }

        pub inline fn set(self: *@This(), value: T) void {
            // Only notify dependents if the value actually changed (for comparable types)
            // Check type at comptime and decide whether to compare
            if (comptime T == []const u8) {
                // Computed CSS values are borrowed slices, and the prior
                // stylesheet generation may already be retired when this is
                // called. Comparing bytes could therefore dereference stale
                // storage. Treat only the exact same slice as unchanged;
                // values from new backing storage notify conservatively.
                if (self.value.ptr != value.ptr or self.value.len != value.len) {
                    self.notify();
                }
            } else if (comptime (T == i32 or T == f32 or T == i64 or T == f64 or T == bool or T == u32 or T == u64)) {
                // Simple types: only notify if value changed
                if (self.value != value) {
                    if (DEBUG_PROTECTED_FIELDS) {
                        std.debug.print("[SET] value changed, invalidating\n", .{});
                    }
                    self.notify();
                } else if (DEBUG_PROTECTED_FIELDS) {
                    // Skip logging unchanged values to reduce noise
                }
            } else {
                // Complex types: always notify
                if (DEBUG_PROTECTED_FIELDS) {
                    std.debug.print("[SET] complex type, invalidating\n", .{});
                }
                self.notify();
            }

            self.value = value;
            self.dirty = false;
        }
    };
}

test "clearInvalidations detaches subscribers before their lifetime ends" {
    const Field = ProtectedField(i32);
    var source = Field.init(1);
    defer source.deinit(std.testing.allocator);
    var subscriber = Field.init(2);
    defer subscriber.deinit(std.testing.allocator);
    source.set(1);
    subscriber.set(2);

    subscriber.addDependency(&source, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), source.invalidations.count());
    source.clearInvalidations();
    try std.testing.expectEqual(@as(usize, 0), source.invalidations.count());

    source.set(3);
    try std.testing.expect(!subscriber.dirty);
}

test "last published value remains available while recomputation is pending" {
    const Field = ProtectedField(i32);
    var field = Field.init(4);
    defer field.deinit(std.testing.allocator);
    field.set(9);
    field.mark();

    try std.testing.expect(field.dirty);
    try std.testing.expectEqual(@as(i32, 9), field.lastValue().*);
}

test "identical borrowed slices suppress invalidation without reading storage" {
    const Field = ProtectedField([]const u8);
    var source = Field.init("same");
    defer source.deinit(std.testing.allocator);
    var subscriber = Field.init("child");
    defer subscriber.deinit(std.testing.allocator);
    source.set("same");
    subscriber.set("child");
    subscriber.addDependency(&source, std.testing.allocator);

    const original = source.lastValue().*;
    source.set(original);
    try std.testing.expect(!subscriber.dirty);

    const replacement = try std.testing.allocator.dupe(u8, "same");
    defer std.testing.allocator.free(replacement);
    source.set(replacement);
    try std.testing.expect(subscriber.dirty);
    try std.testing.expect(source.lastValue().*.ptr == replacement.ptr);
}

test "comptime fields use compact unmanaged dependency storage" {
    const Field = ProtectedField(i32);
    const ManagedInvalidations = std.AutoHashMap(*anyopaque, *const fn (*anyopaque) void);
    const UnmanagedInvalidations = std.AutoHashMapUnmanaged(*anyopaque, *const fn (*anyopaque) void);

    try std.testing.expect(@sizeOf(UnmanagedInvalidations) < @sizeOf(ManagedInvalidations));

    var field = Field.init(7);
    defer field.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), field.invalidations.capacity());
}
