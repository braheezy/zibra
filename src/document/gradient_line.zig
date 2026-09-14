//! Owning linear gradient paint values without document borrows. Geometry and
//! color stops are copied before source retirement; sampling allocates nothing.
const std = @import("std");
const grammar = @import("css_gradient.zig");
const colors = @import("color.zig");
const spaces = @import("color_space.zig");
const interpolation = @import("color_interpolation.zig");

pub const Stop = struct {
    position: f64,
    color: spaces.Coordinates,
    /// Hint between this stop and the next, normalized to their interval.
    hint: f64 = 0.5,
};

pub const Linear = struct {
    stops: []const Stop,
    method: interpolation.Method,
    repeating: bool,
    width: f64,
    height: f64,
    dx: f64,
    dy: f64,
    length: f64,
    before: colors.Color,
    after: colors.Color,
    average: colors.Color,

    /// Create an independently owned used value from synchronous source/context
    /// borrows. Dimensions and stop lengths are unzoomed CSS pixels.
    pub fn init(allocator: std.mem.Allocator, input: []const u8, context: colors.Context, width: f64, height: f64) !?Linear {
        if (width <= 0 or height <= 0 or !std.math.isFinite(width + height)) return null;
        const parsed = grammar.parse(input) orelse return null;
        var dx: f64 = 0;
        var dy: f64 = 1;
        switch (parsed.direction) {
            .angle => |source| {
                const degrees = grammar.angle(source, .{ .font_size = context.font_size, .root_font_size = context.root_font_size }) orelse return null;
                // Top-level math censors NaN to zero and clamps infinities to
                // the supported range, as for stop lengths below.
                const normalized = @mod(if (std.math.isNan(degrees)) 0 else std.math.clamp(degrees, -1e100, 1e100), 360);
                const radians = normalized * std.math.pi / 180;
                dx = if (@mod(normalized, 180) == 0) 0 else @sin(radians);
                dy = if (@mod(normalized, 180) == 90) 0 else -@cos(radians);
            },
            .sides => |sides| {
                dx = @floatFromInt(sides.x);
                dy = @floatFromInt(sides.y);
                if (sides.x != 0 and sides.y != 0) {
                    // A corner direction is perpendicular to the diagonal
                    // joining its neighboring corners, not aimed at the corner.
                    const diagonal = @sqrt(width * width + height * height);
                    dx *= height / diagonal;
                    dy *= width / diagonal;
                }
            },
        }
        const line_length = @abs(width * dx) + @abs(height * dy);
        var positions: [grammar.max_stops]?f64 = @splat(null);
        var color_count: usize = 0;
        for (parsed.stops[0..parsed.count], 0..) |stop, i| {
            if (stop.color != null) color_count += 1;
            if (stop.position) |source| {
                const value = grammar.position(source, .{
                    .font_size = context.font_size,
                    .root_font_size = context.root_font_size,
                    .percentage = .{ .dimension = .length, .value = line_length },
                }) orelse return null;
                // NaN collapses to zero at the top-level calculation. Bound
                // infinite endpoints before subtraction can produce NaN.
                positions[i] = if (std.math.isNan(value)) 0 else std.math.clamp(value, -1e100, 1e100);
            }
        }
        positions[0] = positions[0] orelse 0;
        positions[parsed.count - 1] = positions[parsed.count - 1] orelse line_length;
        var last = positions[0].?;
        for (positions[0..parsed.count]) |*value| if (value.*) |number| {
            value.* = @max(last, number);
            last = value.*.?;
        };
        var previous: usize = 0;
        for (positions[1..parsed.count], 1..) |value, i| if (value) |number| {
            const start = positions[previous].?;
            for (previous + 1..i) |j| positions[j] = start + (number - start) * @as(f64, @floatFromInt(j - previous)) / @as(f64, @floatFromInt(i - previous));
            previous = i;
        };

        const stops = try allocator.alloc(Stop, color_count);
        errdefer allocator.free(stops);
        var result = Linear{
            .stops = stops,
            .method = parsed.method orelse parsed.defaultMethod(),
            .repeating = parsed.repeating,
            .width = width,
            .height = height,
            .dx = dx,
            .dy = dy,
            .length = line_length,
            .before = undefined,
            .after = undefined,
            .average = undefined,
        };
        var index: usize = 0;
        var hint: ?f64 = null;
        for (parsed.stops[0..parsed.count], 0..) |stop, i| {
            const source = stop.color orelse {
                hint = positions[i];
                continue;
            };
            const color = colors.parseWithContext(source, context) orelse {
                allocator.free(stops);
                return null;
            };
            stops[index] = .{ .position = positions[i].?, .color = interpolation.convert(color.coordinates, result.method.space) };
            if (index == 0) result.before = color.color;
            result.after = color.color;
            if (hint) |point| {
                const span = stops[index].position - stops[index - 1].position;
                stops[index - 1].hint = if (span > 0) (point - stops[index - 1].position) / span else 0.5;
                hint = null;
            }
            index += 1;
        }
        result.average = result.averageColor();
        return result;
    }

    pub fn deinit(self: Linear, allocator: std.mem.Allocator) void {
        allocator.free(self.stops);
    }

    /// Duplicate the only owned slice; the remaining fields are scalars.
    pub fn clone(self: Linear, allocator: std.mem.Allocator) !Linear {
        var copy = self;
        copy.stops = try allocator.dupe(Stop, self.stops);
        return copy;
    }

    fn averageColor(self: Linear) colors.Color {
        if (self.stops.len == 1) return self.before;
        const distance = self.stops[self.stops.len - 1].position - self.stops[0].position;
        var sum: [4]f64 = @splat(0);
        for (0..self.stops.len - 1) |i| {
            const weight = if (distance > 0) (self.stops[i + 1].position - self.stops[i].position) / distance else 1 / @as(f64, @floatFromInt(self.stops.len - 1));
            for (self.stops[i..][0..2]) |stop| {
                const rgb = spaces.toSrgb(stop.color.space, stop.color.values());
                const alpha = stop.color.components[3] orelse 0;
                for (0..3) |channel| sum[channel] += rgb[channel] * alpha * weight / 2;
                sum[3] += alpha * weight / 2;
            }
        }
        if (sum[3] > 0) for (0..3) |i| {
            sum[i] /= sum[3];
        };
        return colors.Absolute.fromCoordinates(.{ .space = .srgb, .components = .{ sum[0], sum[1], sum[2], sum[3] } }, true).color;
    }

    /// Sample normalized tile coordinates at a device pixel's center. The
    /// footprint is a device pixel's width in CSS pixels, for tiny repetitions.
    pub fn sample(self: Linear, x: f64, y: f64, footprint: f64) colors.Color {
        if (self.stops.len == 1) return self.before;
        var point = (x - 0.5) * self.width * self.dx + (y - 0.5) * self.height * self.dy + self.length / 2;
        const first = self.stops[0].position;
        const last = self.stops[self.stops.len - 1].position;
        if (self.repeating) {
            if (last - first < footprint or last == first) return self.average;
            point = first + @mod(point - first, last - first);
        } else {
            if (point < first) return self.before;
            if (point >= last) return self.after;
        }
        // Upper-bound search chooses the last coincident stop at hard edges.
        var low: usize = 0;
        var high = self.stops.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.stops[middle].position <= point) low = middle + 1 else high = middle;
        }
        if (low == 0) return self.before;
        if (low == self.stops.len) return self.after;
        const left = self.stops[low - 1];
        const right = self.stops[low];
        var progress = (point - left.position) / (right.position - left.position);
        if (left.hint <= 0) progress = if (progress > 0) 1 else 0 else if (left.hint >= 1) progress = 0 else if (left.hint != 0.5) {
            progress = std.math.pow(f64, progress, @log(0.5) / @log(left.hint));
        }
        return colors.Absolute.fromCoordinates(interpolation.sample(left.color, right.color, progress, self.method), false).color;
    }
};

test "linear gradient stop fixup hard edges hints alpha and repeated coordinates" {
    const allocator = std.testing.allocator;
    const gradient = (try Linear.init(allocator, "linear-gradient(to right, red 20%, lime 10%, blue)", .{}, 100, 20)).?;
    defer gradient.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 20), gradient.stops[1].position);
    try std.testing.expectEqual(colors.parse("red").?, gradient.sample(0.1, 0.5, 1));
    try std.testing.expectEqual(colors.parse("lime").?, gradient.sample(0.2, 0.5, 1));
    const hint = (try Linear.init(allocator, "linear-gradient(to right in srgb, black, 25%, white)", .{}, 100, 20)).?;
    defer hint.deinit(allocator);
    try std.testing.expectEqual(colors.Color{ .r = 128, .g = 128, .b = 128 }, hint.sample(0.25, 0.5, 1));
    const repeat = (try Linear.init(allocator, "repeating-linear-gradient(to right, red -10px 0px, blue 0px 10px)", .{}, 100, 20)).?;
    defer repeat.deinit(allocator);
    try std.testing.expectEqual(colors.parse("blue").?, repeat.sample(0.05, 0.5, 1));
    try std.testing.expectEqual(colors.parse("red").?, repeat.sample(0.15, 0.5, 1));
    const alpha = (try Linear.init(allocator, "linear-gradient(to right, transparent, red)", .{}, 100, 20)).?;
    defer alpha.deinit(allocator);
    try std.testing.expectEqual(colors.Color{ .r = 255, .g = 0, .b = 0, .a = 128 }, alpha.sample(0.5, 0.5, 1));
}

test "gradient corners depend on aspect ratio and clones outlive source and original" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, "linear-gradient(to right bottom, red, blue)");
    var gradient = (try Linear.init(allocator, source, .{}, 200, 100)).?;
    allocator.free(source);
    const copy = try gradient.clone(allocator);
    gradient.deinit(allocator);
    defer copy.deinit(allocator);
    try std.testing.expectEqual(copy.sample(0, 1, 1), copy.sample(1, 0, 1));
    try std.testing.expectEqual(colors.parse("red").?, copy.sample(0, 0, 1));
    try std.testing.expectEqual(colors.parse("blue").?, copy.sample(1, 1, 1));
}

test "zero and subpixel gradient repetition uses a premultiplied average" {
    for ([_][]const u8{ "repeating-linear-gradient(red 0px, blue 0px)", "repeating-linear-gradient(red 0px, blue .1px)" }) |source| {
        const gradient = (try Linear.init(std.testing.allocator, source, .{}, 100, 100)).?;
        defer gradient.deinit(std.testing.allocator);
        try std.testing.expectEqual(colors.Color{ .r = 128, .g = 0, .b = 128 }, gradient.sample(0.5, 0.5, 1));
    }
}

test "nonfinite gradient math preserves a paintable used value" {
    const allocator = std.testing.allocator;
    const nan = (try Linear.init(allocator, "linear-gradient(calc(NaN * 1deg), red calc(NaN * 1px), blue)", .{}, 100, 100)).?;
    defer nan.deinit(allocator);
    try std.testing.expectEqual(colors.parse("red").?, nan.sample(0.5, 1, 1));
    try std.testing.expectEqual(colors.parse("blue").?, nan.sample(0.5, 0, 1));
    for ([_][]const u8{ "linear-gradient(calc(infinity * 1deg), red, blue)", "linear-gradient(calc(-infinity * 1deg), red, blue)" }) |source| {
        const gradient = (try Linear.init(allocator, source, .{}, 100, 100)).?;
        defer gradient.deinit(allocator);
        try std.testing.expectEqual(colors.Color{ .r = 128, .g = 0, .b = 128 }, gradient.sample(0.5, 0.5, 1));
    }
}
