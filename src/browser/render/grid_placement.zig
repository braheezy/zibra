//! Bounded numeric grid placement over scalar item records. The returned plan
//! owns only areas; callers retain DOM order, track sizes and layout lifetimes.
const std = @import("std");
const grammar = @import("../../document/css_grid_placement.zig");
pub const Axis = grammar.Axis;
pub const Flow = grammar.Flow;
pub const Item = struct { column: Axis = .{}, row: Axis = .{} };
pub const Area = struct {
    column_start: usize,
    column_span: usize,
    row_start: usize,
    row_span: usize,
};
pub const Plan = struct {
    areas: []Area,
    column_count: usize,
    row_count: usize,
    column_offset: usize,
    row_offset: usize,

    /// Retires the plan's scalar storage using the allocator passed to place.
    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.areas);
        self.* = undefined;
    }
};

// Authored integers remain valid outside these used-layout limits. Clipping
// removes out-of-range tracks, reducing wholly external areas to one edge track.
pub const min_line: i32 = -10000;
pub const max_line: i32 = 10000;
const Range = struct {
    start: ?i32 = null,
    span: i32 = 1,

    fn end(self: Range) i32 {
        return self.start.? + self.span;
    }
};
const Rect = struct {
    minor: Range,
    major: Range,
    placed: bool = false,
    row_locked: bool = false,
};

fn numericLine(value: i32, explicit: usize) i64 {
    return if (value > 0) @as(i64, value) - 1 else @as(i64, @intCast(explicit)) + value + 1;
}

fn clipped(start: i64, end: i64) Range {
    const first = std.math.clamp(start, min_line, max_line - 1);
    const last = std.math.clamp(end, first + 1, max_line);
    return .{ .start = @intCast(first), .span = @intCast(last - first) };
}

fn resolve(axis: Axis, explicit: usize) Range {
    var end = axis.end;
    if (axis.start == .span and end == .span) end = .auto;
    if (axis.start == .line) {
        const first = numericLine(axis.start.line, explicit);
        if (end == .line) {
            const last = numericLine(end.line, explicit);
            return clipped(@min(first, last), if (first == last) first + 1 else @max(first, last));
        }
        return clipped(first, first + if (end == .span) @as(i64, end.span) else 1);
    }
    if (end == .line) {
        const last = numericLine(end.line, explicit);
        return clipped(last - if (axis.start == .span) @as(i64, axis.start.span) else 1, last);
    }
    const span = if (axis.start == .span) axis.start.span else if (end == .span) end.span else 1;
    return .{ .span = @intCast(std.math.clamp(span, 1, max_line - min_line)) };
}

fn overlaps(a: Range, b: Range) bool {
    return a.start.? < b.end() and b.start.? < a.end();
}

fn advanceMinor(rects: []const Rect, minor: Range, major: Range) i32 {
    var next = minor.start.?;
    for (rects) |rect| {
        if (rect.placed and overlaps(major, rect.major) and overlaps(minor, rect.minor)) next = @max(next, rect.minor.end());
    }
    return next;
}

fn advanceMajor(rects: []const Rect, minor: Range, major: Range) i32 {
    var next = major.start.?;
    for (rects) |rect| {
        if (rect.placed and overlaps(major, rect.major) and overlaps(minor, rect.minor)) next = @max(next, rect.major.end());
    }
    return next;
}

/// Places order-modified items without owning or retaining their source boxes.
/// Allocation failure leaves no plan or partial allocation with the caller.
pub fn place(allocator: std.mem.Allocator, items: []const Item, explicit_columns: usize, explicit_rows: usize, flow: Flow) !Plan {
    std.debug.assert(explicit_columns <= max_line and explicit_rows <= max_line);
    const areas = try allocator.alloc(Area, items.len);
    errdefer allocator.free(areas);
    const rects = try allocator.alloc(Rect, items.len);
    defer allocator.free(rects);
    const transpose = flow.axis == .column;
    const explicit_minor = if (transpose) explicit_rows else explicit_columns;
    const explicit_major = if (transpose) explicit_columns else explicit_rows;
    var minor_min: i32 = 0;
    var major_min: i32 = 0;
    var minor_max: i32 = @intCast(explicit_minor);
    var major_max: i32 = @intCast(explicit_major);
    for (items, rects) |item, *rect| {
        rect.* = .{
            .minor = resolve(if (transpose) item.row else item.column, explicit_minor),
            .major = resolve(if (transpose) item.column else item.row, explicit_major),
        };
        rect.placed = rect.minor.start != null and rect.major.start != null;
        if (rect.major.start) |start| {
            major_min = @min(major_min, start);
            major_max = @max(major_max, rect.major.end());
        }
    }

    // Definite rows are handled before the ordinary cursor. Sparse packing
    // advances past earlier row-locked items even if they leave a smaller hole.
    for (rects, 0..) |*rect, index| {
        if (rect.placed or rect.major.start == null) continue;
        var start: i32 = 0;
        if (!flow.dense) for (rects[0..index]) |previous| {
            if (previous.row_locked and overlaps(previous.major, rect.major)) start = @max(start, previous.minor.end());
        };
        while (true) {
            rect.minor = clipped(start, @as(i64, start) + rect.minor.span);
            const next = advanceMinor(rects, rect.minor, rect.major);
            if (next == rect.minor.start.?) break;
            if (next >= max_line) {
                rect.minor = clipped(next, @as(i64, next) + rect.minor.span);
                break;
            }
            start = next;
        }
        rect.placed = true;
        rect.row_locked = true;
    }

    var max_span: i32 = if (items.len > 0) 1 else 0;
    for (rects) |rect| {
        if (rect.minor.start) |start| {
            minor_min = @min(minor_min, start);
            minor_max = @max(minor_max, rect.minor.end());
        } else max_span = @max(max_span, rect.minor.span);
    }
    minor_max = @max(minor_max, @min(max_line, minor_min + max_span));
    var cursor_minor = minor_min;
    var cursor_major = major_min;
    for (rects) |*rect| {
        if (rect.placed) continue;
        if (flow.dense) {
            cursor_minor = minor_min;
            cursor_major = major_min;
        }
        if (rect.minor.start) |start| {
            if (!flow.dense and start < cursor_minor) cursor_major += 1;
            cursor_minor = start;
            while (true) {
                rect.major = clipped(cursor_major, @as(i64, cursor_major) + rect.major.span);
                const next = advanceMajor(rects, rect.minor, rect.major);
                if (next == rect.major.start.?) break;
                if (next >= max_line) {
                    rect.major = clipped(next, @as(i64, next) + rect.major.span);
                    break;
                }
                cursor_major = next;
            }
        } else {
            rect.minor.span = @min(rect.minor.span, minor_max - minor_min);
            while (true) {
                if (cursor_minor + rect.minor.span > minor_max) {
                    cursor_minor = minor_min;
                    cursor_major += 1;
                }
                rect.major = clipped(cursor_major, @as(i64, cursor_major) + rect.major.span);
                rect.minor.start = cursor_minor;
                const next = advanceMinor(rects, rect.minor, rect.major);
                if (next == cursor_minor or cursor_major >= max_line - 1) break;
                cursor_minor = next;
            }
        }
        cursor_major = rect.major.start.?;
        rect.placed = true;
        major_max = @max(major_max, rect.major.end());
    }
    for (rects, areas) |rect, *area| {
        const column = if (transpose) rect.major else rect.minor;
        const row = if (transpose) rect.minor else rect.major;
        area.* = .{
            .column_start = @intCast(column.start.? - if (transpose) major_min else minor_min),
            .column_span = @intCast(column.span),
            .row_start = @intCast(row.start.? - if (transpose) minor_min else major_min),
            .row_span = @intCast(row.span),
        };
    }
    return .{
        .areas = areas,
        .column_count = @intCast(if (transpose) major_max - major_min else minor_max - minor_min),
        .row_count = @intCast(if (transpose) minor_max - minor_min else major_max - major_min),
        .column_offset = @intCast(if (transpose) -major_min else -minor_min),
        .row_offset = @intCast(if (transpose) -minor_min else -major_min),
    };
}

test "grid placement resolves explicit negative lines before implicit tracks" {
    var plan = try place(std.testing.allocator, &.{
        .{ .column = .{ .start = .{ .line = -4 }, .end = .{ .line = -1 } }, .row = .{ .start = .{ .line = 1 } } },
        .{ .column = .{ .start = .{ .line = 1 }, .end = .{ .span = 2 } }, .row = .{ .start = .{ .line = 1 } } },
    }, 2, 1, .{});
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.column_offset);
    try std.testing.expectEqual(@as(usize, 3), plan.column_count);
    try std.testing.expectEqual(@as(usize, 0), plan.areas[0].column_start);
    try std.testing.expectEqual(@as(usize, 3), plan.areas[0].column_span);
    try std.testing.expectEqual(@as(usize, 1), plan.areas[1].column_start);
}

test "grid dense placement fills holes and column flow transposes the algorithm" {
    const items = [_]Item{
        .{ .column = .{ .end = .{ .span = 2 } } },
        .{ .column = .{ .end = .{ .span = 2 } } },
        .{},
    };
    var sparse = try place(std.testing.allocator, &items, 3, 0, .{});
    defer sparse.deinit(std.testing.allocator);
    var dense = try place(std.testing.allocator, &items, 3, 0, .{ .dense = true });
    defer dense.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), sparse.areas[2].row_start);
    try std.testing.expectEqual(@as(usize, 0), dense.areas[2].row_start);
    try std.testing.expectEqual(@as(usize, 2), dense.areas[2].column_start);
    var transposed: [3]Item = undefined;
    for (items, &transposed) |item, *target| target.* = .{ .row = item.column, .column = item.row };
    var column = try place(std.testing.allocator, &transposed, 0, 3, .{ .axis = .column, .dense = true });
    defer column.deinit(std.testing.allocator);
    for (dense.areas, column.areas) |a, b| {
        try std.testing.expectEqual(a.column_start, b.row_start);
        try std.testing.expectEqual(a.row_start, b.column_start);
    }
}

test "grid placement handles conflicting lines spans and bounded external areas" {
    var plan = try place(std.testing.allocator, &.{
        .{ .column = .{ .start = .{ .line = 3 }, .end = .{ .line = 1 } } },
        .{ .column = .{ .start = .{ .line = 2 }, .end = .{ .line = 2 } } },
        .{ .column = .{ .start = .{ .line = std.math.maxInt(i32) }, .end = .{ .span = std.math.maxInt(u32) } } },
        .{ .column = .{ .start = .{ .span = 2 }, .end = .{ .span = 3 } } },
    }, 3, 0, .{});
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.areas[0].column_span);
    try std.testing.expectEqual(@as(usize, 1), plan.areas[1].column_span);
    try std.testing.expectEqual(@as(usize, max_line - 1), plan.areas[2].column_start);
    try std.testing.expectEqual(@as(usize, 1), plan.areas[2].column_span);
    try std.testing.expectEqual(@as(usize, 2), plan.areas[3].column_span);
}

fn allocationFailureCase(allocator: std.mem.Allocator) !void {
    var plan = try place(allocator, &.{ .{}, .{ .row = .{ .start = .{ .line = -10000 } } } }, 2, 2, .{});
    defer plan.deinit(allocator);
}

test "grid placement releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}
