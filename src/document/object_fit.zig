//! Parsing and geometry for replaced-image `object-fit`.

const std = @import("std");

pub const Mode = enum {
    fill,
    contain,
    cover,
    none,
    scale_down,
};

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const SourceRect = struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
};

pub const Geometry = struct {
    /// Visible destination rectangle, relative to the replaced element's
    /// content box.
    destination: Rect,
    /// Optional half-open crop in source pixels. Null samples the full image.
    source: ?SourceRect,
};

pub fn parse(input: []const u8) ?Mode {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(value, "fill")) return .fill;
    if (std.ascii.eqlIgnoreCase(value, "contain")) return .contain;
    if (std.ascii.eqlIgnoreCase(value, "cover")) return .cover;
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "scale-down")) return .scale_down;
    return null;
}

fn boundedDimension(value: f64) i32 {
    if (!std.math.isFinite(value) or value <= 0.0) return 0;
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    return @intFromFloat(@round(std.math.clamp(value, 1.0, maximum)));
}

const Dimensions = struct { width: i32, height: i32 };

fn containDimensions(box_width: i32, box_height: i32, natural_width: i32, natural_height: i32) Dimensions {
    const scale = @min(
        @as(f64, @floatFromInt(box_width)) / @as(f64, @floatFromInt(natural_width)),
        @as(f64, @floatFromInt(box_height)) / @as(f64, @floatFromInt(natural_height)),
    );
    return .{
        .width = boundedDimension(@as(f64, @floatFromInt(natural_width)) * scale),
        .height = boundedDimension(@as(f64, @floatFromInt(natural_height)) * scale),
    };
}

fn coverDimensions(box_width: i32, box_height: i32, natural_width: i32, natural_height: i32) Dimensions {
    const scale = @max(
        @as(f64, @floatFromInt(box_width)) / @as(f64, @floatFromInt(natural_width)),
        @as(f64, @floatFromInt(box_height)) / @as(f64, @floatFromInt(natural_height)),
    );
    return .{
        .width = boundedDimension(@as(f64, @floatFromInt(natural_width)) * scale),
        .height = boundedDimension(@as(f64, @floatFromInt(natural_height)) * scale),
    };
}

fn sourceCoordinate(offset: i64, rendered: i32, source: i32) f64 {
    const coordinate = @as(f64, @floatFromInt(offset)) *
        @as(f64, @floatFromInt(source)) /
        @as(f64, @floatFromInt(rendered));
    return std.math.clamp(coordinate, 0, @as(f64, @floatFromInt(source)));
}

/// Resolve fitted image content inside an element box. The image is centered,
/// matching the initial `object-position: 50% 50%`; object-position itself is
/// intentionally outside this exercise. Returned rectangles are already
/// clipped to the element box, so paint does not spill into adjacent content.
pub fn resolve(
    mode: Mode,
    box_width: i32,
    box_height: i32,
    natural_width: i32,
    natural_height: i32,
    source_width: i32,
    source_height: i32,
) ?Geometry {
    if (box_width <= 0 or box_height <= 0) return null;

    // A broken or not-yet-decoded image still occupies and hit-tests through
    // its specified element box; raster will reject its empty pixel buffer.
    if (natural_width <= 0 or natural_height <= 0 or source_width <= 0 or source_height <= 0) {
        return .{
            .destination = .{ .left = 0, .top = 0, .right = box_width, .bottom = box_height },
            .source = null,
        };
    }

    const rendered: Dimensions = switch (mode) {
        .fill => .{ .width = box_width, .height = box_height },
        .contain => containDimensions(box_width, box_height, natural_width, natural_height),
        .cover => coverDimensions(box_width, box_height, natural_width, natural_height),
        .none => .{ .width = natural_width, .height = natural_height },
        .scale_down => if (natural_width <= box_width and natural_height <= box_height)
            .{ .width = natural_width, .height = natural_height }
        else
            containDimensions(box_width, box_height, natural_width, natural_height),
    };
    if (rendered.width <= 0 or rendered.height <= 0) return null;

    const rendered_left = @divFloor(
        @as(i64, box_width) - @as(i64, rendered.width),
        2,
    );
    const rendered_top = @divFloor(
        @as(i64, box_height) - @as(i64, rendered.height),
        2,
    );
    const rendered_right = rendered_left + @as(i64, rendered.width);
    const rendered_bottom = rendered_top + @as(i64, rendered.height);
    const visible_left = std.math.clamp(rendered_left, 0, @as(i64, box_width));
    const visible_top = std.math.clamp(rendered_top, 0, @as(i64, box_height));
    const visible_right = std.math.clamp(rendered_right, visible_left, @as(i64, box_width));
    const visible_bottom = std.math.clamp(rendered_bottom, visible_top, @as(i64, box_height));
    if (visible_right <= visible_left or visible_bottom <= visible_top) return null;

    const source_left = sourceCoordinate(visible_left - rendered_left, rendered.width, source_width);
    const source_top = sourceCoordinate(visible_top - rendered_top, rendered.height, source_height);
    const source_right = sourceCoordinate(visible_right - rendered_left, rendered.width, source_width);
    const source_bottom = sourceCoordinate(visible_bottom - rendered_top, rendered.height, source_height);
    const source = if (source_left <= 0 and source_top <= 0 and
        source_right >= @as(f64, @floatFromInt(source_width)) and
        source_bottom >= @as(f64, @floatFromInt(source_height)))
        null
    else
        SourceRect{
            .left = source_left,
            .top = source_top,
            .right = source_right,
            .bottom = source_bottom,
        };

    return .{
        .destination = .{
            .left = @intCast(visible_left),
            .top = @intCast(visible_top),
            .right = @intCast(visible_right),
            .bottom = @intCast(visible_bottom),
        },
        .source = source,
    };
}

test "object-fit parser accepts the standard basic modes" {
    try std.testing.expectEqual(Mode.fill, parse(" fill ").?);
    try std.testing.expectEqual(Mode.contain, parse("CONTAIN").?);
    try std.testing.expectEqual(Mode.cover, parse("cover").?);
    try std.testing.expectEqual(Mode.none, parse("none").?);
    try std.testing.expectEqual(Mode.scale_down, parse("scale-down").?);
    try std.testing.expect(parse("auto") == null);
    try std.testing.expect(parse("contain cover") == null);
}

test "object-fit contain centers the full source without cropping" {
    const geometry = resolve(.contain, 100, 100, 200, 100, 200, 100).?;
    try std.testing.expectEqual(Rect{ .left = 0, .top = 25, .right = 100, .bottom = 75 }, geometry.destination);
    try std.testing.expect(geometry.source == null);
}

test "object-fit cover center-crops a mismatched source" {
    const geometry = resolve(.cover, 100, 100, 200, 100, 200, 100).?;
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 100, .bottom = 100 }, geometry.destination);
    try std.testing.expectEqual(SourceRect{ .left = 50, .top = 0, .right = 150, .bottom = 100 }, geometry.source.?);
}

test "object-fit none clips intrinsic content and scale-down never enlarges it" {
    const clipped = resolve(.none, 100, 100, 200, 50, 200, 50).?;
    try std.testing.expectEqual(Rect{ .left = 0, .top = 25, .right = 100, .bottom = 75 }, clipped.destination);
    try std.testing.expectEqual(SourceRect{ .left = 50, .top = 0, .right = 150, .bottom = 50 }, clipped.source.?);

    const small = resolve(.scale_down, 300, 200, 200, 100, 200, 100).?;
    try std.testing.expectEqual(Rect{ .left = 50, .top = 50, .right = 250, .bottom = 150 }, small.destination);
    try std.testing.expect(small.source == null);

    const large = resolve(.scale_down, 100, 100, 200, 100, 200, 100).?;
    try std.testing.expectEqual(Rect{ .left = 0, .top = 25, .right = 100, .bottom = 75 }, large.destination);
    try std.testing.expect(large.source == null);
}

test "object-fit retains fractional crop edges for tiny images" {
    const geometry = resolve(.cover, 160, 100, 4, 2, 4, 2).?;
    try std.testing.expectEqual(
        SourceRect{ .left = 0.4, .top = 0, .right = 3.6, .bottom = 2 },
        geometry.source.?,
    );
}
