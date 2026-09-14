//! Parsing and geometry for Zibra's supported CSS background-image subset.

const std = @import("std");
const length = @import("length.zig");

pub const SizeComponent = union(enum) {
    auto,
    pixels: f64,
    percentage: f64,
};

pub const Size = union(enum) {
    dimensions: struct {
        width: SizeComponent,
        height: SizeComponent,
    },
    contain,
    cover,

    pub fn automatic() Size {
        return .{ .dimensions = .{ .width = .auto, .height = .auto } };
    }
};

pub const ResolvedSize = struct {
    width: i32,
    height: i32,
};

pub const Repeat = struct {
    x: bool,
    y: bool,
};

pub const ResolvedPosition = struct {
    x: i32,
    y: i32,
};

/// Borrow encoded contents of one valid CSS URL, including an empty URL.
/// Escapes belong to CSS, not URL syntax: consumers decode these contents before
/// resolving a resource. Empty URLs are valid declarations but load no image.
pub fn parseUrl(input: []const u8) ?[]const u8 {
    const tokens = @import("css_tokenizer.zig");
    var iterator = tokens.Iterator{ .input = input };
    var token = iterator.next() orelse return null;
    while (token.isTrivia()) token = iterator.next() orelse return null;
    const encoded = if (token.kind == .url) token.encodedValue(input) else blk: {
        if (token.kind != .function or !tokens.identifierEquals(token.encodedValue(input), "url")) return null;
        var string = iterator.next() orelse return null;
        while (string.isTrivia()) string = iterator.next() orelse return null;
        if (string.kind != .string) return null;
        var close = iterator.next();
        while (close != null and close.?.isTrivia()) close = iterator.next();
        if (close != null and close.?.kind != .close_paren) return null;
        break :blk string.encodedValue(input);
    };
    while (iterator.next()) |extra| if (!extra.isTrivia()) {
        return null;
    };
    return encoded;
}

fn parseComponent(input: []const u8) ?SizeComponent {
    if (std.ascii.eqlIgnoreCase(input, "auto")) return .auto;
    if (std.mem.eql(u8, input, "0")) return .{ .pixels = 0 };
    if (length.parsePixel(input)) |pixels| return .{ .pixels = pixels };
    if (length.parse(input)) |parsed| switch (parsed.unit) {
        .mm, .rem => return .{ .pixels = length.resolveLength(parsed, .{}) orelse return null },
        .px, .em, .percent => {},
    };

    if (input.len > 1 and input[input.len - 1] == '%') {
        const number = input[0 .. input.len - 1];
        const percentage = std.fmt.parseFloat(f64, number) catch return null;
        if (!std.math.isFinite(percentage) or percentage < 0) return null;
        return .{ .percentage = percentage };
    }
    return null;
}

/// Parse `auto`, one or two px/percentage dimensions, and the common
/// `contain`/`cover` keywords. A single dimension preserves intrinsic aspect
/// ratio by treating the omitted height as `auto`.
pub fn parseSize(input: []const u8) ?Size {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "contain")) return .contain;
    if (std.ascii.eqlIgnoreCase(value, "cover")) return .cover;

    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    const width = parseComponent(tokens.next() orelse return null) orelse return null;
    const height = if (tokens.next()) |token|
        parseComponent(token) orelse return null
    else
        SizeComponent.auto;
    if (tokens.next() != null) return null;
    return .{ .dimensions = .{ .width = width, .height = height } };
}

/// Parse the non-space/round background repeat modes used by the renderer.
pub fn parseRepeat(input: []const u8) ?Repeat {
    const value = std.mem.trim(u8, input, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(value, "repeat")) return .{ .x = true, .y = true };
    if (std.ascii.eqlIgnoreCase(value, "no-repeat")) return .{ .x = false, .y = false };
    if (std.ascii.eqlIgnoreCase(value, "repeat-x")) return .{ .x = true, .y = false };
    if (std.ascii.eqlIgnoreCase(value, "repeat-y")) return .{ .x = false, .y = true };
    return null;
}

/// Resolve the shared one-to-four-value position grammar using actual image
/// dimensions and the element's unscaled font size. Invalid input uses 0 0.
pub fn resolvePosition(
    input: []const u8,
    box_width: i32,
    box_height: i32,
    image_width: i32,
    image_height: i32,
    css_scale: f64,
    font_size: f64,
) ResolvedPosition {
    const position = @import("css_position.zig").parse(input) orelse return .{ .x = 0, .y = 0 };
    const point = position.resolve(box_width - image_width, box_height - image_height, font_size, css_scale);
    return .{ .x = point.x, .y = point.y };
}

fn componentPixels(component: SizeComponent, box: f64, css_scale: f64) ?f64 {
    return switch (component) {
        .auto => null,
        .pixels => |pixels| pixels * css_scale,
        .percentage => |percentage| box * percentage / 100.0,
    };
}

fn boundedDimension(value: f64) i32 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    return @intFromFloat(std.math.clamp(value, 1.0, maximum));
}

/// Generated gradients have no intrinsic dimensions or aspect ratio. Each
/// automatic axis fills the positioning area independently; contain/cover do too.
pub fn resolveGeneratedSize(size: Size, box_width: i32, box_height: i32, css_scale: f64) ResolvedSize {
    if (box_width <= 0 or box_height <= 0) return .{ .width = 0, .height = 0 };
    return switch (size) {
        .contain, .cover => .{ .width = box_width, .height = box_height },
        .dimensions => |dimensions| .{
            .width = boundedDimension(componentPixels(dimensions.width, @floatFromInt(box_width), css_scale) orelse @as(f64, @floatFromInt(box_width))),
            .height = boundedDimension(componentPixels(dimensions.height, @floatFromInt(box_height), css_scale) orelse @as(f64, @floatFromInt(box_height))),
        },
    };
}

test "gradient sizing fills automatic axes without inventing an intrinsic ratio" {
    try std.testing.expectEqual(ResolvedSize{ .width = 80, .height = 60 }, resolveGeneratedSize(parseSize("40px auto").?, 200, 60, 2));
    try std.testing.expectEqual(ResolvedSize{ .width = 200, .height = 30 }, resolveGeneratedSize(parseSize("auto 50%").?, 200, 60, 2));
    try std.testing.expectEqual(ResolvedSize{ .width = 200, .height = 60 }, resolveGeneratedSize(.cover, 200, 60, 2));
    try std.testing.expectEqual(ResolvedSize{ .width = 200, .height = 60 }, resolveGeneratedSize(.contain, 200, 60, 2));
}

/// Resolve a parsed size into layout pixels. Intrinsic dimensions are CSS
/// pixels; `css_scale` applies authored subtree zoom but not accessibility
/// zoom, which is applied later while rastering the display list.
pub fn resolveSize(
    size: Size,
    box_width: i32,
    box_height: i32,
    intrinsic_width: i32,
    intrinsic_height: i32,
    css_scale_value: f64,
) ResolvedSize {
    if (box_width <= 0 or box_height <= 0 or intrinsic_width <= 0 or intrinsic_height <= 0) {
        return .{ .width = 0, .height = 0 };
    }

    const css_scale = if (std.math.isFinite(css_scale_value) and css_scale_value > 0)
        css_scale_value
    else
        1.0;
    const box_w: f64 = @floatFromInt(box_width);
    const box_h: f64 = @floatFromInt(box_height);
    const intrinsic_w = @as(f64, @floatFromInt(intrinsic_width)) * css_scale;
    const intrinsic_h = @as(f64, @floatFromInt(intrinsic_height)) * css_scale;

    const resolved: struct { width: f64, height: f64 } = switch (size) {
        .contain => blk: {
            const width_scale = box_w / intrinsic_w;
            const height_scale = box_h / intrinsic_h;
            const ratio = @min(width_scale, height_scale);
            break :blk .{ .width = intrinsic_w * ratio, .height = intrinsic_h * ratio };
        },
        .cover => blk: {
            const width_scale = box_w / intrinsic_w;
            const height_scale = box_h / intrinsic_h;
            const ratio = @max(width_scale, height_scale);
            break :blk .{ .width = intrinsic_w * ratio, .height = intrinsic_h * ratio };
        },
        .dimensions => |dimensions| blk: {
            const explicit_width = componentPixels(dimensions.width, box_w, css_scale);
            const explicit_height = componentPixels(dimensions.height, box_h, css_scale);
            if (explicit_width) |width| {
                if (explicit_height) |height| break :blk .{ .width = width, .height = height };
                break :blk .{ .width = width, .height = width * intrinsic_h / intrinsic_w };
            }
            if (explicit_height) |height| {
                break :blk .{ .width = height * intrinsic_w / intrinsic_h, .height = height };
            }
            break :blk .{ .width = intrinsic_w, .height = intrinsic_h };
        },
    };
    return .{
        .width = boundedDimension(resolved.width),
        .height = boundedDimension(resolved.height),
    };
}

test "background image URL parser accepts quoted and unquoted basic values" {
    try std.testing.expectEqualStrings("images/tile.ppm", parseUrl("url(images/tile.ppm)").?);
    try std.testing.expectEqualStrings("tile with spaces.ppm", parseUrl(" URL( 'tile with spaces.ppm' ) ").?);
    try std.testing.expect(parseUrl("none") == null);
    try std.testing.expect(parseUrl("linear-gradient(red, blue)") == null);
    try std.testing.expect(parseUrl("url(unquoted space.ppm)") == null);
    try std.testing.expectEqualStrings("", parseUrl("url()").?);
}

test "background size resolves intrinsic explicit percentage contain and cover forms" {
    const automatic = resolveSize(parseSize("auto").?, 300, 200, 100, 50, 1.0);
    try std.testing.expectEqual(ResolvedSize{ .width = 100, .height = 50 }, automatic);

    const one_length = resolveSize(parseSize("200px").?, 300, 200, 100, 50, 1.0);
    try std.testing.expectEqual(ResolvedSize{ .width = 200, .height = 100 }, one_length);

    const percentages = resolveSize(parseSize("50% 25%").?, 300, 200, 100, 50, 1.0);
    try std.testing.expectEqual(ResolvedSize{ .width = 150, .height = 50 }, percentages);

    const contained = resolveSize(parseSize("contain").?, 300, 200, 100, 50, 1.0);
    try std.testing.expectEqual(ResolvedSize{ .width = 300, .height = 150 }, contained);

    const covered = resolveSize(parseSize("cover").?, 300, 200, 100, 50, 1.0);
    try std.testing.expectEqual(ResolvedSize{ .width = 400, .height = 200 }, covered);

    const zoomed = resolveSize(parseSize("25px auto").?, 300, 200, 100, 50, 2.0);
    try std.testing.expectEqual(ResolvedSize{ .width = 50, .height = 25 }, zoomed);

    const millimeters = resolveSize(parseSize("25.4mm auto").?, 300, 200, 100, 50, 1.0);
    try std.testing.expectEqual(ResolvedSize{ .width = 96, .height = 48 }, millimeters);

    try std.testing.expect(parseSize("10em") == null);
    try std.testing.expect(parseSize("cover auto") == null);
}

test "background repeat and position resolve the supported single layer" {
    try std.testing.expectEqual(Repeat{ .x = true, .y = true }, parseRepeat("repeat").?);
    try std.testing.expectEqual(Repeat{ .x = true, .y = false }, parseRepeat("REPEAT-X").?);
    try std.testing.expectEqual(Repeat{ .x = false, .y = false }, parseRepeat("no-repeat").?);
    try std.testing.expect(parseRepeat("space") == null);

    try std.testing.expectEqual(
        ResolvedPosition{ .x = 1, .y = 0 },
        resolvePosition("1px 0", 120, 40, 2, 2, 1.0, 16),
    );
    try std.testing.expectEqual(
        ResolvedPosition{ .x = 50, .y = 25 },
        resolvePosition("50% 50%", 120, 60, 20, 10, 1.0, 16),
    );
    try std.testing.expectEqual(
        ResolvedPosition{ .x = 96, .y = 0 },
        resolvePosition("25.4mm 0", 200, 40, 2, 2, 1.0, 16),
    );
}
