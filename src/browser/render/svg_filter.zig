//! Bounded SVG filter graph. Intermediate premultiplied surfaces are owned by
//! this synchronous invocation and never become DOM or display-list borrows.
const std = @import("std");
const z2d = @import("z2d");
const dom = @import("../../document/dom.zig");
const colors = @import("../../document/color.zig");
const effects = @import("effects.zig");
const v = @import("svg_values.zig");
const paint = @import("svg_paint.zig");

const Surface = z2d.Surface;

fn copy(allocator: std.mem.Allocator, source: *const Surface) !Surface {
    const result = try Surface.init(.image_surface_rgba, allocator, source.getWidth(), source.getHeight());
    @memcpy(result.image_surface_rgba.buf, source.image_surface_rgba.buf);
    return result;
}

fn input(names: *const std.StringHashMap(usize), surfaces: []const Surface, raw: ?[]const u8, fallback: usize) *const Surface {
    return &surfaces[if (raw) |name| names.get(name) orelse 1 else fallback];
}

/// Replace source pixels after the graph succeeds. Failed allocation leaves
/// the source untouched. Supports at most 16 primitives and 16 Mi pixels total.
pub fn apply(allocator: std.mem.Allocator, source: *Surface, filter: *const dom.Element, matrix: z2d.Transformation, box: paint.Bounds, viewport: v.Viewport) !void {
    var surfaces = std.ArrayList(Surface).empty;
    defer {
        for (surfaces.items) |*surface| surface.deinit(allocator);
        surfaces.deinit(allocator);
    }
    const count = source.image_surface_rgba.buf.len;
    if (count * 3 > 4 * v.max_pixels) return error.SvgTooComplex;
    try surfaces.ensureTotalCapacity(allocator, 19);
    surfaces.appendAssumeCapacity(try copy(allocator, source));
    surfaces.appendAssumeCapacity(try Surface.init(.image_surface_rgba, allocator, source.getWidth(), source.getHeight()));
    surfaces.appendAssumeCapacity(try copy(allocator, source));
    for (surfaces.items[2].image_surface_rgba.buf) |*pixel| {
        pixel.r = 0;
        pixel.g = 0;
        pixel.b = 0;
    }
    var names = std.StringHashMap(usize).init(allocator);
    defer names.deinit();
    try names.put("SourceGraphic", 0);
    try names.put("SourceAlpha", 2);
    var last: usize = 0;
    const scale = @sqrt(@abs(matrix.determinant()));
    for (filter.children.items) |*child| {
        if (child.* != .element) continue;
        const primitive = &child.element;
        const name = v.tag(primitive) orelse continue;
        if (surfaces.items.len == 19 or (surfaces.items.len + 2) * count > 4 * v.max_pixels) return error.SvgTooComplex;
        const src = input(&names, surfaces.items, v.attr(primitive, "in"), last);
        var output = try copy(allocator, src);
        errdefer output.deinit(allocator);
        if (std.ascii.eqlIgnoreCase(name, "feGaussianBlur")) {
            var numbers = @import("svg_path.zig").Numbers{ .source = v.attr(primitive, "stdDeviation") orelse "0" };
            const sigma = @max(0, try numbers.number());
            if (!numbers.done()) {
                const sy = try numbers.number();
                if (sy != sigma or !numbers.done()) return error.UnsupportedSvgFilter;
            }
            try effects.gaussianBlurPixels(allocator, output.image_surface_rgba.buf, @intCast(output.getWidth()), @intCast(output.getHeight()), sigma * scale);
        } else if (std.ascii.eqlIgnoreCase(name, "feOffset")) {
            @memset(output.image_surface_rgba.buf, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
            var dx = try v.coordinate(primitive, "dx", viewport.user_width, 0);
            var dy = try v.coordinate(primitive, "dy", viewport.user_height, 0);
            matrix.userToDeviceDistance(&dx, &dy);
            if (@abs(dx) > 1e6 or @abs(dy) > 1e6) return error.SvgTooComplex;
            Surface.composite(&output, src, .src_over, @intFromFloat(@round(dx)), @intFromFloat(@round(dy)), .{});
        } else if (std.ascii.eqlIgnoreCase(name, "feFlood")) {
            const color = colors.parse(v.property(primitive, "flood-color") orelse "black") orelse colors.Color{ .r = 0, .g = 0, .b = 0 };
            const alpha = try v.opacity(v.property(primitive, "flood-opacity") orelse "1");
            const pixel = z2d.pixel.RGBA{ .r = color.r, .g = color.g, .b = color.b, .a = @intFromFloat(@round(@as(f64, @floatFromInt(color.a)) * alpha)) };
            @memset(output.image_surface_rgba.buf, pixel.multiply());
        } else if (std.ascii.eqlIgnoreCase(name, "feColorMatrix")) {
            try colorMatrix(output.image_surface_rgba.buf, primitive);
        } else if (std.ascii.eqlIgnoreCase(name, "feComposite") or std.ascii.eqlIgnoreCase(name, "feBlend")) {
            const second = input(&names, surfaces.items, v.attr(primitive, "in2"), 1);
            const op_name = v.attr(primitive, "operator") orelse "over";
            const mode = v.attr(primitive, "mode") orelse "normal";
            const op: z2d.compositor.Operator = if (std.ascii.eqlIgnoreCase(name, "feBlend"))
                (if (v.equal(mode, "multiply")) .multiply else if (v.equal(mode, "screen")) .screen else if (v.equal(mode, "darken")) .darken else if (v.equal(mode, "lighten")) .lighten else .src_over)
            else if (v.equal(op_name, "in")) .src_in else if (v.equal(op_name, "out")) .src_out else if (v.equal(op_name, "atop")) .src_atop else if (v.equal(op_name, "xor")) .xor else .src_over;
            @memcpy(output.image_surface_rgba.buf, second.image_surface_rgba.buf);
            Surface.composite(&output, src, op, 0, 0, .{});
        } else if (std.ascii.eqlIgnoreCase(name, "feMerge")) {
            @memset(output.image_surface_rgba.buf, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
            for (primitive.children.items) |*merge| if (merge.* == .element and std.ascii.eqlIgnoreCase(merge.element.tag, "feMergeNode")) {
                Surface.composite(&output, input(&names, surfaces.items, v.attr(&merge.element, "in"), last), .src_over, 0, 0, .{});
            };
        } else {
            output.deinit(allocator);
            continue;
        }
        const next = surfaces.items.len;
        if (v.attr(primitive, "result")) |id| try names.put(id, next);
        surfaces.appendAssumeCapacity(output);
        last = next;
    }
    const region_units = v.attr(filter, "filterUnits") orelse "objectBoundingBox";
    const user = v.equal(region_units, "userSpaceOnUse");
    const w = if (user) viewport.user_width else 1;
    const h = if (user) viewport.user_height else 1;
    const region = paint.Bounds{
        .x = try v.coordinate(filter, "x", w, -0.1 * w),
        .y = try v.coordinate(filter, "y", h, -0.1 * h),
        .width = try v.coordinate(filter, "width", w, 1.2 * w),
        .height = try v.coordinate(filter, "height", h, 1.2 * h),
    };
    const inverse = matrix.mul(if (user) .identity else box.matrix()).inverse() catch {
        @memset(source.image_surface_rgba.buf, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        return;
    };
    const width: usize = @intCast(source.getWidth());
    for (source.image_surface_rgba.buf, surfaces.items[last].image_surface_rgba.buf, 0..) |*out, pixel, i| {
        var x: f64 = @as(f64, @floatFromInt(i % width)) + 0.5;
        var y: f64 = @as(f64, @floatFromInt(i / width)) + 0.5;
        inverse.userToDevice(&x, &y);
        out.* = if (x >= region.x and y >= region.y and x < region.x + region.width and y < region.y + region.height) pixel else .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
}

fn colorMatrix(pixels: []z2d.pixel.RGBA, element: *const dom.Element) !void {
    var m = [20]f64{ 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    const kind = v.attr(element, "type") orelse "matrix";
    var numbers = @import("svg_path.zig").Numbers{ .source = v.attr(element, "values") orelse "" };
    if (v.equal(kind, "matrix")) {
        if (!numbers.done()) {
            for (&m) |*entry| entry.* = try numbers.number();
            if (!numbers.done()) return error.InvalidSvgFilter;
        }
    } else if (v.equal(kind, "saturate")) {
        const s = if (numbers.done()) 1 else std.math.clamp(try numbers.number(), 0, 1);
        m = .{ 0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0, 0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0, 0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0, 0, 0, 0, 1, 0 };
    } else if (v.equal(kind, "luminanceToAlpha")) {
        m = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.2125, 0.7154, 0.0721, 0, 0 };
    } else return error.UnsupportedSvgFilter;
    for (pixels) |*pixel| {
        const straight = pixel.demultiply();
        const channels = [4]u8{ straight.r, straight.g, straight.b, straight.a };
        var out: [4]u8 = undefined;
        for (0..4) |row| {
            var sum = m[row * 5 + 4] * 255;
            for (channels, 0..) |channel, column| sum += m[row * 5 + column] * @as(f64, @floatFromInt(channel));
            out[row] = @intFromFloat(@round(std.math.clamp(sum, 0, 255)));
        }
        pixel.* = (z2d.pixel.RGBA{ .r = out[0], .g = out[1], .b = out[2], .a = out[3] }).multiply();
    }
}
