//! Pure mitered geometry for CSS solid border sides.
//!
//! The layout owner supplies a border-box rectangle and already-resolved side
//! widths. This module neither parses styles nor owns display commands; it
//! returns the convex quadrilaterals that join at the inner border corners.

const std = @import("std");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Box = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Edges = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
};

pub const Side = enum {
    top,
    right,
    bottom,
    left,
};

/// A clockwise convex side shape. Adjacent sides share their miter edge, so
/// differently colored borders meet without the rectangular corner overlap
/// produced by four independent strips.
pub const Quad = struct {
    points: [4]Point,
};

/// Return the outer-to-inner mitered quadrilateral for one visible border
/// side. A zero-width side has no paint geometry. Opposing widths are scaled
/// down only when a constrained box cannot contain both, preserving a valid
/// non-inverted inner rectangle.
pub fn sideQuad(box: Box, authored_edges: Edges, side: Side) ?Quad {
    const width = @max(box.width, 0);
    const height = @max(box.height, 0);
    if (width == 0 or height == 0) return null;

    var edges = Edges{
        .top = @max(authored_edges.top, 0),
        .right = @max(authored_edges.right, 0),
        .bottom = @max(authored_edges.bottom, 0),
        .left = @max(authored_edges.left, 0),
    };
    fitOpposingEdges(&edges.left, &edges.right, width);
    fitOpposingEdges(&edges.top, &edges.bottom, height);
    const side_width = switch (side) {
        .top => edges.top,
        .right => edges.right,
        .bottom => edges.bottom,
        .left => edges.left,
    };
    if (side_width == 0) return null;

    const outer_left = box.x;
    const outer_top = box.y;
    const outer_right = saturatingAdd(box.x, width);
    const outer_bottom = saturatingAdd(box.y, height);
    const inner_left = saturatingAdd(outer_left, edges.left);
    const inner_top = saturatingAdd(outer_top, edges.top);
    const inner_right = saturatingSubtract(outer_right, edges.right);
    const inner_bottom = saturatingSubtract(outer_bottom, edges.bottom);

    return switch (side) {
        .top => .{ .points = .{
            .{ .x = outer_left, .y = outer_top },
            .{ .x = outer_right, .y = outer_top },
            .{ .x = inner_right, .y = inner_top },
            .{ .x = inner_left, .y = inner_top },
        } },
        .right => .{ .points = .{
            .{ .x = outer_right, .y = outer_top },
            .{ .x = outer_right, .y = outer_bottom },
            .{ .x = inner_right, .y = inner_bottom },
            .{ .x = inner_right, .y = inner_top },
        } },
        .bottom => .{ .points = .{
            .{ .x = outer_right, .y = outer_bottom },
            .{ .x = outer_left, .y = outer_bottom },
            .{ .x = inner_left, .y = inner_bottom },
            .{ .x = inner_right, .y = inner_bottom },
        } },
        .left => .{ .points = .{
            .{ .x = outer_left, .y = outer_bottom },
            .{ .x = outer_left, .y = outer_top },
            .{ .x = inner_left, .y = inner_top },
            .{ .x = inner_left, .y = inner_bottom },
        } },
    };
}

fn fitOpposingEdges(first: *i32, second: *i32, available: i32) void {
    const total: i64 = @as(i64, first.*) + @as(i64, second.*);
    if (total <= available or total == 0) return;
    const scaled_first: i64 = @divFloor(@as(i64, first.*) * available, total);
    first.* = @intCast(scaled_first);
    second.* = available - first.*;
}

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

test "mitered sides share diagonal corner joins" {
    const box = Box{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const edges = Edges{ .top = 6, .right = 8, .bottom = 10, .left = 12 };
    const top = sideQuad(box, edges, .top).?;
    const left = sideQuad(box, edges, .left).?;

    try std.testing.expectEqual(Point{ .x = 10, .y = 20 }, top.points[0]);
    try std.testing.expectEqual(Point{ .x = 102, .y = 26 }, top.points[2]);
    try std.testing.expectEqual(Point{ .x = 22, .y = 26 }, top.points[3]);
    try std.testing.expectEqual(top.points[0], left.points[1]);
    try std.testing.expectEqual(top.points[3], left.points[2]);
}

test "zero-content dimensions preserve triangular border geometry" {
    const box = Box{ .x = 0, .y = 0, .width = 24, .height = 12 };
    const edges = Edges{ .top = 0, .right = 12, .bottom = 12, .left = 12 };
    const bottom = sideQuad(box, edges, .bottom).?;

    // The inner left/right corners meet at the center, yielding the triangle
    // used by common `height: 0` CSS border shapes.
    try std.testing.expectEqual(Point{ .x = 12, .y = 0 }, bottom.points[2]);
    try std.testing.expectEqual(Point{ .x = 12, .y = 0 }, bottom.points[3]);
}

test "zero-width sides do not allocate paint geometry" {
    const box = Box{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try std.testing.expect(sideQuad(box, .{ .top = 0, .right = 2, .bottom = 2, .left = 2 }, .top) == null);
}
