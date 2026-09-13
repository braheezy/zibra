//! Single-layer CSS position grammar shared by declarations and background paint.
//! Parsed offsets borrow normalized input. Font and image geometry are supplied
//! only at resolution; no DOM, resource or layout object is retained.
const std = @import("std");
const length = @import("length.zig");
const Components = @import("grid_tracks.zig").Components;

const Anchor = enum { start, center, end };
const Axis = struct {
    anchor: Anchor = .center,
    offset: ?[]const u8 = null,

    fn resolve(self: Axis, available: f64, font_size: f64, scale: f64) f64 {
        const origin = switch (self.anchor) {
            .start => 0,
            .center => available / 2,
            .end => available,
        };
        const input = self.offset orelse return origin;
        const pixels = if (signedLength(input)) |parsed| switch (parsed.unit) {
            .percent => available * parsed.value / 100,
            else => (length.resolveLength(parsed, .{ .font_size = font_size }) orelse 0) * scale,
        } else if (length.resolveMath(input, .{
            .font_size = font_size,
            .percentage_base = available / scale,
            .signed_percentage_basis = true,
        })) |value| value * scale else 0;
        return if (self.anchor == .end) origin - pixels else origin + pixels;
    }
};

pub const Position = struct {
    x: Axis,
    y: Axis,
    edge_syntax: bool = false,

    /// Caller owns the specified value. Canonical order is horizontal then
    /// vertical; edge offsets stay explicit and unitless zero becomes 0px.
    pub fn serialize(self: Position, allocator: std.mem.Allocator) ![]u8 {
        var parts: [4][]const u8 = undefined;
        var count: usize = 0;
        for ([_]Axis{ self.x, self.y }, 0..) |axis, i| {
            if (self.edge_syntax or axis.offset == null) {
                parts[count] = switch (axis.anchor) {
                    .start => if (i == 0) "left" else "top",
                    .center => "center",
                    .end => if (i == 0) "right" else "bottom",
                };
                count += 1;
            }
            if (axis.offset) |value| {
                parts[count] = if (std.mem.eql(u8, value, "0")) "0px" else value;
                count += 1;
            }
        }
        return std.mem.join(allocator, " ", parts[0..count]);
    }

    /// Resolve against the difference between positioning-area and image size,
    /// which may be negative. All geometry already contains authored zoom;
    /// font_size is in unscaled CSS pixels. Coordinates saturate to i32.
    pub fn resolve(self: Position, available_x: i32, available_y: i32, font_size: f64, scale: f64) struct { x: i32, y: i32 } {
        const css_scale = if (std.math.isFinite(scale) and scale > 0) scale else 1;
        return .{
            .x = coordinate(self.x.resolve(@floatFromInt(available_x), font_size, css_scale)),
            .y = coordinate(self.y.resolve(@floatFromInt(available_y), font_size, css_scale)),
        };
    }
};

fn coordinate(value: f64) i32 {
    if (std.math.isNan(value)) return 0;
    return @intFromFloat(std.math.clamp(@floor(value), std.math.minInt(i32), std.math.maxInt(i32)));
}

fn signedLength(input: []const u8) ?length.Length {
    if (input.len == 0) return null;
    const negative = input[0] == '-';
    const magnitude = if (negative or input[0] == '+') input[1..] else input;
    var parsed = length.parse(magnitude) orelse return null;
    if (negative) parsed.value = -parsed.value;
    return parsed;
}

const Keyword = enum { left, right, top, bottom, center };
const Component = union(enum) { keyword: Keyword, offset: []const u8 };

fn component(input: []const u8) ?Component {
    inline for (@typeInfo(Keyword).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(input, field.name)) return .{ .keyword = @enumFromInt(field.value) };
    }
    if (signedLength(input) != null or length.resolveMath(input, .{ .percentage_base = 100 }) != null) return .{ .offset = input };
    return null;
}

fn parseAxis(value: Component, horizontal: bool) ?Axis {
    return switch (value) {
        .offset => |offset| .{ .anchor = .start, .offset = offset },
        .keyword => |key| switch (key) {
            .center => .{},
            .left => if (horizontal) .{ .anchor = .start } else null,
            .right => if (horizontal) .{ .anchor = .end } else null,
            .top => if (!horizontal) .{ .anchor = .start } else null,
            .bottom => if (!horizontal) .{ .anchor = .end } else null,
        },
    };
}

/// Parse one to four components with CSS axis restrictions. Unsupported units
/// and multiple image layers fail without publishing a partially valid value.
pub fn parse(input: []const u8) ?Position {
    var components: [4]Component = undefined;
    var count: usize = 0;
    var iterator = Components{ .input = input };
    while (iterator.next()) |raw| {
        if (count == components.len) return null;
        components[count] = component(raw) orelse return null;
        count += 1;
    }
    if (count == 0) return null;
    if (count == 1) {
        if (parseAxis(components[0], true)) |x| return .{ .x = x, .y = .{} };
        return .{ .x = .{}, .y = parseAxis(components[0], false) orelse return null };
    }
    if (count == 2) {
        if (parseAxis(components[0], true)) |x| {
            if (parseAxis(components[1], false)) |y| return .{ .x = x, .y = y };
        }
        // Only keywords may reverse their order. A numeric first component is
        // always horizontal and a numeric second component is always vertical.
        if (components[0] != .keyword or components[1] != .keyword) return null;
        return .{ .x = parseAxis(components[1], true) orelse return null, .y = parseAxis(components[0], false) orelse return null };
    }
    var groups: [2]struct { keyword: Keyword, offset: ?[]const u8 = null } = undefined;
    var cursor: usize = 0;
    for (&groups) |*group| {
        if (cursor == count or components[cursor] != .keyword) return null;
        group.* = .{ .keyword = components[cursor].keyword };
        cursor += 1;
        if (cursor < count and components[cursor] == .offset) {
            if (group.keyword == .center) return null;
            group.offset = components[cursor].offset;
            cursor += 1;
        }
    }
    if (cursor != count) return null;
    var x = parseAxis(.{ .keyword = groups[0].keyword }, true);
    var y = parseAxis(.{ .keyword = groups[1].keyword }, false);
    if (x != null and y != null) {
        x.?.offset = groups[0].offset;
        y.?.offset = groups[1].offset;
    } else {
        x = parseAxis(.{ .keyword = groups[1].keyword }, true);
        y = parseAxis(.{ .keyword = groups[0].keyword }, false);
        if (x == null or y == null) return null;
        x.?.offset = groups[1].offset;
        y.?.offset = groups[0].offset;
    }
    return .{ .x = x.?, .y = y.?, .edge_syntax = true };
}

test "CSS positions share axis grammar specified serialization and signed resolution" {
    const cases = [_]struct { input: []const u8, serialized: []const u8, x: i32, y: i32 }{
        .{ .input = "-20% -10px", .serialized = "-20% -10px", .x = -20, .y = -10 },
        .{ .input = "top left", .serialized = "left top", .x = 0, .y = 0 },
        .{ .input = "top 5px right 20%", .serialized = "right 20% top 5px", .x = 80, .y = 5 },
        .{ .input = "center right -10px", .serialized = "right -10px center", .x = 110, .y = 40 },
        .{ .input = "0", .serialized = "0px center", .x = 0, .y = 40 },
        .{ .input = "-1em bottom", .serialized = "-1em bottom", .x = -20, .y = 80 },
    };
    for (cases) |case| {
        const value = parse(case.input).?;
        const text = try value.serialize(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.serialized, text);
        const point = value.resolve(100, 80, 20, 1);
        try std.testing.expectEqual(case.x, point.x);
        try std.testing.expectEqual(case.y, point.y);
    }
    for ([_][]const u8{ "left right", "top bottom", "top 10px", "20% left", "right 10px 20%", "50% top 8px", "left 10px right", "center 2px bottom", "0, 0" }) |invalid| try std.testing.expect(parse(invalid) == null);
    const oversized = parse("min(0%, 100%) max(0%, 100%)").?.resolve(-50, -50, 16, 1);
    try std.testing.expectEqual(-50, oversized.x);
    try std.testing.expectEqual(0, oversized.y);
    const zoomed = parse("right 1em bottom -2px").?.resolve(200, 80, 20, 2);
    try std.testing.expectEqual(160, zoomed.x);
    try std.testing.expectEqual(84, zoomed.y);
}
