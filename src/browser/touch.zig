//! Per-window touch contact tracking and normalized SDL coordinate handling.
//!
//! SDL reports finger positions in the inclusive normalized range 0...1.
//! Contacts are keyed by both touch-device and finger identity so simultaneous
//! fingers, including equal finger IDs from different devices, stay distinct.

const std = @import("std");

pub const tap_slop_px: i32 = 10;

pub const Point = struct {
    x: i32,
    y: i32,
};

const Contact = struct {
    touch_id: i64,
    finger_id: i64,
    start: Point,
    moved: bool = false,
};

pub fn normalizedCoordinate(value: f32, extent: i32) i32 {
    if (extent <= 0 or !std.math.isFinite(value)) return 0;
    if (value <= 0.0) return 0;
    if (value >= 1.0) return extent - 1;
    const scaled = @as(f64, value) * @as(f64, @floatFromInt(extent));
    return @intCast(@min(@as(i64, extent - 1), @as(i64, @intFromFloat(scaled))));
}

pub fn normalizedPoint(x: f32, y: f32, width: i32, height: i32) Point {
    return .{
        .x = normalizedCoordinate(x, width),
        .y = normalizedCoordinate(y, height),
    };
}

/// SDL reserves the unsigned representation of -1 for mouse events synthesized
/// from touch. Those events accompany the finger stream and must be ignored or
/// one physical tap can activate two browser clicks.
pub fn isSyntheticMouse(mouse_instance_id: u32) bool {
    return mouse_instance_id == std.math.maxInt(u32);
}

/// SDL also reserves signed -1 for touch events synthesized from an ordinary
/// mouse. Ignore that mirror stream and retain the original mouse click.
pub fn isSyntheticTouch(touch_id: i64) bool {
    return touch_id == -1;
}

fn exceedsTapSlop(start: Point, current: Point) bool {
    const dx = @as(i64, current.x) - @as(i64, start.x);
    const dy = @as(i64, current.y) - @as(i64, start.y);
    return @abs(dx) > tap_slop_px or @abs(dy) > tap_slop_px;
}

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    contacts: std.ArrayList(Contact) = .empty,

    pub fn init(allocator: std.mem.Allocator) Tracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tracker) void {
        self.contacts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Tracker) void {
        self.contacts.clearRetainingCapacity();
    }

    pub fn count(self: *const Tracker) usize {
        return self.contacts.items.len;
    }

    fn indexOf(self: *const Tracker, touch_id: i64, finger_id: i64) ?usize {
        for (self.contacts.items, 0..) |contact, index| {
            if (contact.touch_id == touch_id and contact.finger_id == finger_id) return index;
        }
        return null;
    }

    pub fn begin(
        self: *Tracker,
        touch_id: i64,
        finger_id: i64,
        x: f32,
        y: f32,
        width: i32,
        height: i32,
    ) !void {
        const contact = Contact{
            .touch_id = touch_id,
            .finger_id = finger_id,
            .start = normalizedPoint(x, y, width, height),
        };
        if (self.indexOf(touch_id, finger_id)) |index| {
            self.contacts.items[index] = contact;
            return;
        }
        try self.contacts.append(self.allocator, contact);
    }

    pub fn motion(
        self: *Tracker,
        touch_id: i64,
        finger_id: i64,
        x: f32,
        y: f32,
        width: i32,
        height: i32,
    ) void {
        const index = self.indexOf(touch_id, finger_id) orelse return;
        const contact = &self.contacts.items[index];
        if (exceedsTapSlop(contact.start, normalizedPoint(x, y, width, height))) {
            contact.moved = true;
        }
    }

    /// Finish one contact. A tap returns its release point; a dragged or
    /// unmatched contact returns null. The contact is retired in every case.
    pub fn end(
        self: *Tracker,
        touch_id: i64,
        finger_id: i64,
        x: f32,
        y: f32,
        width: i32,
        height: i32,
    ) ?Point {
        const index = self.indexOf(touch_id, finger_id) orelse return null;
        const contact = self.contacts.swapRemove(index);
        const release = normalizedPoint(x, y, width, height);
        if (contact.moved or exceedsTapSlop(contact.start, release)) return null;
        return release;
    }
};
