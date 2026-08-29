//! Pointer-free geometry and retained-order policy for layout-tree hit tests.
//!
//! Layout objects keep ownership of child arrays and DOM resolution. This
//! module only converts points between local coordinate spaces and iterates a
//! previously committed paint permutation without observing live layout state.

const std = @import("std");
const dom = @import("../../document/dom.zig");

pub const Bounds = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    width: i32,
    height: i32,
};

/// Synchronous borrow into the current DOM/layout generation.
pub const Result = struct {
    node: *dom.Node,
    local_x: i32,
    local_y: i32,
};

pub const Clip = struct {
    enabled: bool = false,
    radius: f64 = 0.0,
};

pub const BlockInput = struct {
    child_origin: Point,
    parent_origin: Point,
    size: Size,
    position_offset: Point = .{ .x = 0, .y = 0 },
    transform_translation: Point = .{ .x = 0, .y = 0 },
    opacity: f64 = 1.0,
    clip: Clip = .{},
    scroll_y: i32 = 0,
};

pub const LocalizedBlock = struct {
    local: Point,
    content: Point,
    hits_own_box: bool,
};

pub fn addOffset(point: Point, offset: Point) Point {
    return .{
        .x = saturatingAdd(point.x, offset.x),
        .y = saturatingAdd(point.y, offset.y),
    };
}

pub fn subtractOffset(point: Point, offset: Point) Point {
    return .{
        .x = saturatingSubtract(point.x, offset.x),
        .y = saturatingSubtract(point.y, offset.y),
    };
}

pub fn childLocalPoint(
    parent_point: Point,
    child_origin: Point,
    parent_origin: Point,
) Point {
    return subtractOffset(parent_point, .{
        .x = saturatingSubtract(child_origin.x, parent_origin.x),
        .y = saturatingSubtract(child_origin.y, parent_origin.y),
    });
}

pub fn containsBox(point: Point, size: Size) bool {
    return size.width > 0 and size.height > 0 and
        point.x >= 0 and point.x < size.width and
        point.y >= 0 and point.y < size.height;
}

pub fn containsRoundedBox(point: Point, size: Size, radius_value: f64) bool {
    if (!containsBox(point, size)) return false;
    const radius = @min(
        @max(radius_value, 0.0),
        @min(
            @as(f64, @floatFromInt(size.width)) / 2.0,
            @as(f64, @floatFromInt(size.height)) / 2.0,
        ),
    );
    if (radius <= 0.0) return true;

    const px: f64 = @floatFromInt(point.x);
    const py: f64 = @floatFromInt(point.y);
    const right: f64 = @floatFromInt(size.width);
    const bottom: f64 = @floatFromInt(size.height);
    if (px >= radius and px < right - radius) return true;
    if (py >= radius and py < bottom - radius) return true;

    const center_x = if (px < radius) radius else right - radius;
    const center_y = if (py < radius) radius else bottom - radius;
    const dx = px - center_x;
    const dy = py - center_y;
    return dx * dx + dy * dy <= radius * radius;
}

/// Invert a block's visual offsets while preserving the distinction between
/// its stationary border box and scrolled content coordinate space.
pub fn localizeBlock(parent_point: Point, input: BlockInput) ?LocalizedBlock {
    if (input.opacity <= 0.0) return null;
    var local = childLocalPoint(parent_point, input.child_origin, input.parent_origin);
    local = subtractOffset(local, input.position_offset);
    local = subtractOffset(local, input.transform_translation);
    if (input.clip.enabled and !containsRoundedBox(local, input.size, input.clip.radius)) return null;
    return .{
        .local = local,
        .content = addOffset(local, .{ .x = 0, .y = @max(input.scroll_y, 0) }),
        .hits_own_box = containsRoundedBox(local, input.size, input.clip.radius),
    };
}

pub const StackingKey = struct {
    z_index: i32,
    document_index: usize,

    pub fn before(left: StackingKey, right: StackingKey) bool {
        if (left.z_index != right.z_index) return left.z_index < right.z_index;
        return left.document_index < right.document_index;
    }
};

/// Reverse iterator over the paint permutation committed with this tree.
/// A missing or length-mismatched permutation falls back to reverse DOM order.
pub const ReverseOrder = struct {
    committed: []const usize,
    child_count: usize,
    cursor: usize,
    use_committed: bool,

    pub fn init(committed: []const usize, child_count: usize) ReverseOrder {
        const use_committed = committed.len == child_count;
        return .{
            .committed = committed,
            .child_count = child_count,
            .cursor = if (use_committed) committed.len else child_count,
            .use_committed = use_committed,
        };
    }

    pub fn next(self: *ReverseOrder) ?usize {
        if (self.cursor == 0) return null;
        self.cursor -= 1;
        return if (self.use_committed) self.committed[self.cursor] else self.cursor;
    }
};

fn saturatingAdd(left: i32, right: i32) i32 {
    return @intCast(std.math.clamp(
        @as(i64, left) + @as(i64, right),
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

fn saturatingSubtract(left: i32, right: i32) i32 {
    return @intCast(std.math.clamp(
        @as(i64, left) - @as(i64, right),
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

test "local offsets saturate and preserve child-relative coordinates" {
    try std.testing.expectEqual(
        Point{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) },
        addOffset(
            .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) },
            .{ .x = 1, .y = -1 },
        ),
    );
    try std.testing.expectEqual(
        Point{ .x = 15, .y = 17 },
        childLocalPoint(
            .{ .x = 25, .y = 30 },
            .{ .x = 20, .y = 33 },
            .{ .x = 10, .y = 20 },
        ),
    );
}

test "box containment is half-open and rounded corners are excluded" {
    const size = Size{ .width = 100, .height = 40 };
    try std.testing.expect(containsBox(.{ .x = 0, .y = 0 }, size));
    try std.testing.expect(!containsBox(.{ .x = 100, .y = 10 }, size));
    try std.testing.expect(!containsBox(.{ .x = 0, .y = 0 }, .{ .width = 0, .height = 40 }));
    try std.testing.expect(containsRoundedBox(.{ .x = 50, .y = 20 }, size, 20));
    try std.testing.expect(!containsRoundedBox(.{ .x = 1, .y = 1 }, size, 20));
    try std.testing.expect(!containsRoundedBox(.{ .x = 1, .y = 1 }, size, 1000));
}

test "block localization separates scroll from visual offsets and clipping" {
    const localized = localizeBlock(.{ .x = 75, .y = 60 }, .{
        .child_origin = .{ .x = 20, .y = 20 },
        .parent_origin = .{ .x = 10, .y = 10 },
        .size = .{ .width = 100, .height = 50 },
        .position_offset = .{ .x = 5, .y = 7 },
        .transform_translation = .{ .x = 10, .y = 3 },
        .scroll_y = 20,
    }).?;
    try std.testing.expectEqual(Point{ .x = 50, .y = 40 }, localized.local);
    try std.testing.expectEqual(Point{ .x = 50, .y = 60 }, localized.content);
    try std.testing.expect(localized.hits_own_box);

    try std.testing.expect(localizeBlock(.{ .x = 200, .y = 20 }, .{
        .child_origin = .{ .x = 0, .y = 0 },
        .parent_origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 100, .height = 50 },
    }) != null);
    try std.testing.expect(localizeBlock(.{ .x = 200, .y = 20 }, .{
        .child_origin = .{ .x = 0, .y = 0 },
        .parent_origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 100, .height = 50 },
        .clip = .{ .enabled = true },
    }) == null);
    try std.testing.expect(localizeBlock(.{ .x = 20, .y = 20 }, .{
        .child_origin = .{ .x = 0, .y = 0 },
        .parent_origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 100, .height = 50 },
        .opacity = 0,
    }) == null);
}

test "stacking keys and reverse committed order remain stable" {
    try std.testing.expect(StackingKey.before(
        .{ .z_index = -1, .document_index = 9 },
        .{ .z_index = 0, .document_index = 0 },
    ));
    try std.testing.expect(StackingKey.before(
        .{ .z_index = 2, .document_index = 1 },
        .{ .z_index = 2, .document_index = 4 },
    ));

    const committed = [_]usize{ 2, 0, 1 };
    var order = ReverseOrder.init(&committed, 3);
    try std.testing.expectEqual(@as(?usize, 1), order.next());
    try std.testing.expectEqual(@as(?usize, 0), order.next());
    try std.testing.expectEqual(@as(?usize, 2), order.next());
    try std.testing.expectEqual(@as(?usize, null), order.next());

    var fallback = ReverseOrder.init(committed[0..2], 3);
    try std.testing.expectEqual(@as(?usize, 2), fallback.next());
    try std.testing.expectEqual(@as(?usize, 1), fallback.next());
    try std.testing.expectEqual(@as(?usize, 0), fallback.next());
}
