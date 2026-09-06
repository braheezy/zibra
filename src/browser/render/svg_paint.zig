//! Per-render SVG reference index and gradient owners. IDs borrow the live or
//! temporary DOM only until render returns; gradient stops own their storage.
const std = @import("std");
const z2d = @import("z2d");
const dom = @import("../../document/dom.zig");
const colors = @import("../../document/color.zig");
const v = @import("svg_values.zig");

pub const References = struct {
    ids: std.StringHashMap(*const dom.Element),
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, root: *const dom.Element) !References {
        var result = References{ .ids = std.StringHashMap(*const dom.Element).init(allocator) };
        errdefer result.deinit();
        try result.collect(root, 0);
        return result;
    }

    pub fn deinit(self: *References) void {
        self.ids.deinit();
    }

    fn collect(self: *References, element: *const dom.Element, depth: usize) anyerror!void {
        self.count += 1;
        if (depth > 128 or self.count > 16384) return error.SvgTooComplex;
        if (v.attr(element, "id")) |id| {
            const entry = try self.ids.getOrPut(id);
            if (!entry.found_existing) entry.value_ptr.* = element;
        }
        for (element.children.items) |*child| if (child.* == .element) try self.collect(&child.element, depth + 1);
    }

    pub fn get(self: *const References, reference: []const u8) ?*const dom.Element {
        const target = url(reference);
        if (target.len < 2 or target[0] != '#') return null;
        if (std.mem.indexOfScalar(u8, target, '%') == null) return self.ids.get(target[1..]);
        var decoded: [4096]u8 = undefined;
        var count: usize = 0;
        var cursor: usize = 1;
        while (cursor < target.len) {
            if (count == decoded.len) return null;
            if (target[cursor] == '%' and cursor + 2 < target.len) {
                const byte = std.fmt.parseInt(u8, target[cursor + 1 ..][0..2], 16) catch return null;
                decoded[count] = byte;
                cursor += 3;
            } else {
                decoded[count] = target[cursor];
                cursor += 1;
            }
            count += 1;
        }
        return self.ids.get(decoded[0..count]);
    }
};

pub fn url(source: []const u8) []const u8 {
    var result = std.mem.trim(u8, source, " \t\r\n");
    if (std.mem.startsWith(u8, result, "url(")) {
        const end = std.mem.indexOfScalar(u8, result, ')') orelse return "";
        result = result[4..end];
    }
    return std.mem.trim(u8, result, " \t\r\n\"'");
}

pub fn href(element: *const dom.Element) ?[]const u8 {
    return v.attr(element, "href") orelse v.attr(element, "xlink:href");
}

pub const Bounds = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn matrix(self: Bounds) z2d.Transformation {
        return z2d.Transformation.identity.translate(self.x, self.y).scale(self.width, self.height);
    }
};

/// Exact cubic extrema in local user coordinates, excluding stroke expansion.
pub fn bounds(context: *const z2d.Context) !Bounds {
    const inverse = try context.transformation.inverse();
    var low = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
    var high = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
    var current = [2]f64{ 0, 0 };
    for (context.path.nodes.items) |node| switch (node) {
        .move_to => |move| {
            current = point(inverse, move.point);
            include(&low, &high, current);
        },
        .line_to => |line| {
            current = point(inverse, line.point);
            include(&low, &high, current);
        },
        .curve_to => |curve| {
            const p1 = point(inverse, curve.p1);
            const p2 = point(inverse, curve.p2);
            const p3 = point(inverse, curve.p3);
            include(&low, &high, p3);
            for (0..2) |axis| {
                const a = -current[axis] + 3 * p1[axis] - 3 * p2[axis] + p3[axis];
                const b = 2 * (current[axis] - 2 * p1[axis] + p2[axis]);
                const c = p1[axis] - current[axis];
                if (@abs(a) < 1e-12) {
                    if (@abs(b) > 1e-12) extremum(&low, &high, current, p1, p2, p3, -c / b);
                } else if (b * b - 4 * a * c >= 0) {
                    const d = @sqrt(b * b - 4 * a * c);
                    extremum(&low, &high, current, p1, p2, p3, (-b + d) / (2 * a));
                    extremum(&low, &high, current, p1, p2, p3, (-b - d) / (2 * a));
                }
            }
            current = p3;
        },
        .close_path => {},
    };
    if (!std.math.isFinite(low[0])) return .{};
    return .{ .x = low[0], .y = low[1], .width = high[0] - low[0], .height = high[1] - low[1] };
}

fn point(matrix: z2d.Transformation, p: anytype) [2]f64 {
    var x = p.x;
    var y = p.y;
    matrix.userToDevice(&x, &y);
    return .{ x, y };
}
fn include(low: *[2]f64, high: *[2]f64, p: [2]f64) void {
    for (0..2) |i| {
        low[i] = @min(low[i], p[i]);
        high[i] = @max(high[i], p[i]);
    }
}
fn extremum(low: *[2]f64, high: *[2]f64, a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64, t: f64) void {
    if (t <= 0 or t >= 1) return;
    const s = 1 - t;
    var p: [2]f64 = undefined;
    for (0..2) |i| p[i] = s * s * s * a[i] + 3 * s * s * t * b[i] + 3 * s * t * t * c[i] + t * t * t * d[i];
    include(low, high, p);
}

fn linkedProperty(references: *const References, element: *const dom.Element, name: []const u8) ?[]const u8 {
    var cursor = element;
    for (0..32) |_| {
        if (v.attr(cursor, name)) |value| return value;
        cursor = references.get(href(cursor) orelse return null) orelse return null;
    }
    return null;
}

fn coord(references: *const References, element: *const dom.Element, name: []const u8, basis: f64, fallback: f64) !f64 {
    return if (linkedProperty(references, element, name)) |value| try v.length(value, basis) else fallback;
}

/// Own the returned gradient through the fill/stroke call. Its matrix maps
/// gradient coordinates all the way to the device surface.
pub fn gradient(allocator: std.mem.Allocator, references: *const References, source: []const u8, box: Bounds, viewport: v.Viewport, matrix: z2d.Transformation, alpha: f64) !?z2d.Gradient {
    const element = references.get(source) orelse return null;
    const name = v.tag(element) orelse return null;
    const radial = std.ascii.eqlIgnoreCase(name, "radialGradient");
    if (!radial and !std.ascii.eqlIgnoreCase(name, "linearGradient")) return null;
    const user = v.equal(linkedProperty(references, element, "gradientUnits") orelse "", "userSpaceOnUse");
    if (!user and (box.width <= 0 or box.height <= 0)) return null;
    const w = if (user) viewport.user_width else 1;
    const h = if (user) viewport.user_height else 1;
    const cx = try coord(references, element, "cx", w, w / 2);
    const cy = try coord(references, element, "cy", h, h / 2);
    const radius = try coord(references, element, "r", @sqrt((w * w + h * h) / 2), @sqrt((w * w + h * h) / 2) / 2);
    if (radial and radius < 0) return null;
    const x1 = try coord(references, element, "x1", w, 0);
    const y1 = try coord(references, element, "y1", h, 0);
    const x2 = try coord(references, element, "x2", w, w);
    const y2 = try coord(references, element, "y2", h, 0);
    const degenerate = if (radial) radius == 0 else x1 == x2 and y1 == y2;
    var result = if (radial) z2d.Gradient.init(.{ .type = .{ .radial = .{
        .inner_x = try coord(references, element, "fx", w, cx),
        .inner_y = try coord(references, element, "fy", h, cy),
        .inner_radius = 0,
        .outer_x = cx,
        .outer_y = cy,
        .outer_radius = if (radius == 0) 1 else radius,
    } } }) else z2d.Gradient.init(.{ .type = .{ .linear = .{
        .x0 = x1,
        .y0 = y1,
        .x1 = if (degenerate) x1 + 1 else x2,
        .y1 = y2,
    } } });
    errdefer result.deinit(allocator);
    var stop_owner = element;
    var found = false;
    for (0..32) |_| {
        var last: f64 = 0;
        for (stop_owner.children.items) |*child| if (child.* == .element and std.ascii.eqlIgnoreCase(child.element.tag, "stop")) {
            const stop = &child.element;
            found = true;
            const offset = @max(last, try v.opacity(v.attr(stop, "offset") orelse "0"));
            last = offset;
            const color = colors.parse(v.property(stop, "stop-color") orelse "black") orelse colors.Color{ .r = 0, .g = 0, .b = 0 };
            const a = try v.opacity(v.property(stop, "stop-opacity") orelse "1");
            try result.addStop(allocator, @floatCast(offset), .{ .rgba = .{
                @as(f32, @floatFromInt(color.r)) / 255, @as(f32, @floatFromInt(color.g)) / 255,
                @as(f32, @floatFromInt(color.b)) / 255, @as(f32, @floatFromInt(color.a)) / 255 * @as(f32, @floatCast(a * alpha)),
            } });
        };
        if (found) break;
        stop_owner = references.get(href(stop_owner) orelse break) orelse break;
    }
    if (!found) {
        result.deinit(allocator);
        return null;
    }
    // SVG paints a degenerate gradient with its final stop. Give z2d a
    // nondegenerate axis and constant stops to avoid undefined offsets.
    if (degenerate) switch (result) {
        inline else => |*g| {
            const color = g.stops.l.items[g.stops.l.items.len - 1].color;
            for (g.stops.l.items) |*stop| stop.color = color;
        },
    };
    const local = if (linkedProperty(references, element, "gradientTransform")) |raw| try v.transform(raw) else z2d.Transformation.identity;
    try result.setTransformation(matrix.mul(if (user) .identity else box.matrix()).mul(local));
    return result;
}
