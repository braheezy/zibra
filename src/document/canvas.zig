//! Mutable backing storage for one HTML canvas element.
//!
//! A Canvas is heap-stable because z2d.Context retains a pointer to its
//! Surface. JavaScript and layout both run on the owning tab worker; layout
//! copies pixels into an immutable display command before anything crosses to
//! the browser or raster worker.

const std = @import("std");
const z2d = @import("z2d");
const css_color = @import("color.zig");

pub const default_width: i32 = 300;
pub const default_height: i32 = 150;

pub const PaintState = struct {
    fill_style: []const u8 = "#000000",
    stroke_style: []const u8 = "#000000",
    line_width: f64 = 1.0,
    global_alpha: f64 = 1.0,
};

pub const CommandResult = enum {
    state_only,
    pixels_changed,
};

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    width: i32,
    height: i32,
    surface: ?z2d.Surface = null,
    context: ?z2d.Context = null,
    saved_transforms: std.ArrayList(z2d.Transformation) = .empty,

    /// Allocate the Canvas itself before initializing Context: Context keeps a
    /// raw pointer to `surface`, so constructing this object by value would
    /// leave that pointer aimed at a moved temporary.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        width: i32,
        height: i32,
    ) !*Canvas {
        const self = try allocator.create(Canvas);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .width = 0,
            .height = 0,
        };
        try self.resize(width, height);
        return self;
    }

    pub fn destroy(self: *Canvas) void {
        self.releaseDrawingState();
        self.saved_transforms.deinit(self.allocator);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn releaseDrawingState(self: *Canvas) void {
        if (self.context) |*context| {
            context.deinit();
            self.context = null;
        }
        if (self.surface) |*surface| {
            surface.deinit(self.allocator);
            self.surface = null;
        }
    }

    /// Width or height changes reset the bitmap and native drawing state.
    /// Zero-sized canvases retain a valid JavaScript context object but need
    /// no z2d surface until both dimensions become positive.
    pub fn resize(self: *Canvas, width: i32, height: i32) !void {
        try self.resizeInternal(width, height, false);
    }

    /// Assigning either canvas dimension resets bitmap/context state even if
    /// the numeric dimensions do not change.
    pub fn reset(self: *Canvas, width: i32, height: i32) !void {
        try self.resizeInternal(width, height, true);
    }

    fn resizeInternal(self: *Canvas, width: i32, height: i32, force: bool) !void {
        const next_width = @max(0, width);
        const next_height = @max(0, height);
        if (!force and self.width == next_width and self.height == next_height and
            ((next_width == 0 or next_height == 0) == (self.surface == null)))
        {
            return;
        }

        var replacement: ?z2d.Surface = null;
        errdefer if (replacement) |*surface| surface.deinit(self.allocator);
        if (next_width > 0 and next_height > 0) {
            replacement = try z2d.Surface.init(
                .image_surface_rgba,
                self.allocator,
                next_width,
                next_height,
            );
        }

        self.releaseDrawingState();
        self.width = next_width;
        self.height = next_height;
        self.saved_transforms.clearRetainingCapacity();
        self.surface = replacement;
        replacement = null;
        if (self.surface != null) {
            self.context = z2d.Context.init(self.io, self.allocator, &self.surface.?);
        }
    }

    /// Return an independently owned RGBA snapshot for a retained display
    /// command. Even the empty case comes from the supplied allocator so the
    /// command has one uniform ownership rule.
    pub fn snapshot(self: *const Canvas, allocator: std.mem.Allocator) ![]u8 {
        const surface = self.surface orelse return allocator.alloc(u8, 0);
        return switch (surface) {
            .image_surface_rgba => |rgba| blk: {
                const copy = try allocator.alloc(u8, rgba.buf.len * 4);
                for (rgba.buf, 0..) |pixel, index| {
                    const offset = index * 4;
                    copy[offset + 3] = pixel.a;
                    if (pixel.a == 0) {
                        copy[offset + 0] = 0;
                        copy[offset + 1] = 0;
                        copy[offset + 2] = 0;
                    } else {
                        const alpha: u32 = pixel.a;
                        copy[offset + 0] = @intCast(@min(255, (@as(u32, pixel.r) * 255 + alpha / 2) / alpha));
                        copy[offset + 1] = @intCast(@min(255, (@as(u32, pixel.g) * 255 + alpha / 2) / alpha));
                        copy[offset + 2] = @intCast(@min(255, (@as(u32, pixel.b) * 255 + alpha / 2) / alpha));
                    }
                }
                break :blk copy;
            },
            else => unreachable,
        };
    }

    fn sourceColor(style: []const u8, global_alpha: f64) !z2d.pixel.RGBA {
        const parsed = css_color.parse(style) orelse return error.InvalidColor;
        const alpha = std.math.clamp(global_alpha, 0.0, 1.0);
        const output_alpha: u8 = @intFromFloat(@round(@as(f64, @floatFromInt(parsed.a)) * alpha));
        const premultiply = struct {
            fn channel(value: u8, channel_alpha: u8) u8 {
                return @intCast((@as(u32, value) * @as(u32, channel_alpha) + 127) / 255);
            }
        }.channel;
        return .{
            .r = premultiply(parsed.r, output_alpha),
            .g = premultiply(parsed.g, output_alpha),
            .b = premultiply(parsed.b, output_alpha),
            .a = output_alpha,
        };
    }

    fn addRectanglePath(context: *z2d.Context, x: f64, y: f64, width: f64, height: f64) !void {
        if (width == 0 or height == 0) return;
        try context.moveTo(x, y);
        try context.lineTo(x + width, y);
        try context.lineTo(x + width, y + height);
        try context.lineTo(x, y + height);
        try context.closePath();
    }

    fn rectangleCommand(
        self: *Canvas,
        operation: enum { fill, stroke, clear },
        values: [6]f64,
        state: PaintState,
    ) !CommandResult {
        const surface = if (self.surface) |*surface| surface else return .pixels_changed;
        if (values[2] == 0 or values[3] == 0) return .pixels_changed;

        var context = z2d.Context.init(self.io, self.allocator, surface);
        defer context.deinit();
        if (self.context) |*live| context.setTransformation(live.getTransformation());
        context.setLineWidth(if (state.line_width > 0 and std.math.isFinite(state.line_width))
            state.line_width
        else
            1.0);

        switch (operation) {
            .fill => context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = try sourceColor(
                state.fill_style,
                state.global_alpha,
            ) } } }),
            .stroke => context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = try sourceColor(
                state.stroke_style,
                state.global_alpha,
            ) } } }),
            .clear => {
                context.setOperator(.clear);
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = 0,
                    .g = 0,
                    .b = 0,
                    .a = 0,
                } } } });
            },
        }
        try addRectanglePath(&context, values[0], values[1], values[2], values[3]);
        switch (operation) {
            .stroke => try context.stroke(),
            .fill, .clear => try context.fill(),
        }
        return .pixels_changed;
    }

    /// Execute the supported CanvasRenderingContext2D subset. Methods with no
    /// z2d-backed implementation deliberately return error.NotImplemented;
    /// the JavaScript host catches that error and leaves the page running.
    pub fn command(
        self: *Canvas,
        name: []const u8,
        values: [6]f64,
        flag: bool,
        state: PaintState,
    ) !CommandResult {
        if (std.mem.eql(u8, name, "fillRect")) {
            return self.rectangleCommand(.fill, values, state);
        }
        if (std.mem.eql(u8, name, "strokeRect")) {
            return self.rectangleCommand(.stroke, values, state);
        }
        if (std.mem.eql(u8, name, "clearRect")) {
            return self.rectangleCommand(.clear, values, state);
        }

        const context = if (self.context) |*context| context else return .state_only;
        if (std.mem.eql(u8, name, "beginPath")) {
            context.resetPath();
            return .state_only;
        }
        if (std.mem.eql(u8, name, "moveTo")) {
            try context.moveTo(values[0], values[1]);
            return .state_only;
        }
        if (std.mem.eql(u8, name, "lineTo")) {
            try context.lineTo(values[0], values[1]);
            return .state_only;
        }
        if (std.mem.eql(u8, name, "rect")) {
            try addRectanglePath(context, values[0], values[1], values[2], values[3]);
            return .state_only;
        }
        if (std.mem.eql(u8, name, "closePath")) {
            try context.closePath();
            return .state_only;
        }
        if (std.mem.eql(u8, name, "bezierCurveTo")) {
            try context.curveTo(values[0], values[1], values[2], values[3], values[4], values[5]);
            return .state_only;
        }
        if (std.mem.eql(u8, name, "arc")) {
            if (values[2] < 0) return error.InvalidRadius;
            if (flag) {
                try context.arcNegative(values[0], values[1], values[2], values[3], values[4]);
            } else {
                try context.arc(values[0], values[1], values[2], values[3], values[4]);
            }
            return .state_only;
        }
        if (std.mem.eql(u8, name, "fill")) {
            context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = try sourceColor(
                state.fill_style,
                state.global_alpha,
            ) } } });
            try context.fill();
            return .pixels_changed;
        }
        if (std.mem.eql(u8, name, "stroke")) {
            context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = try sourceColor(
                state.stroke_style,
                state.global_alpha,
            ) } } });
            context.setLineWidth(if (state.line_width > 0 and std.math.isFinite(state.line_width))
                state.line_width
            else
                1.0);
            try context.stroke();
            return .pixels_changed;
        }
        if (std.mem.eql(u8, name, "translate")) {
            context.translate(values[0], values[1]);
            return .state_only;
        }
        if (std.mem.eql(u8, name, "rotate")) {
            context.rotate(values[0]);
            return .state_only;
        }
        if (std.mem.eql(u8, name, "scale")) {
            context.scale(values[0], values[1]);
            return .state_only;
        }
        if (std.mem.eql(u8, name, "setTransform")) {
            context.setTransformation(.{
                .ax = values[0],
                .cx = values[1],
                .by = values[2],
                .dy = values[3],
                .tx = values[4],
                .ty = values[5],
            });
            return .state_only;
        }
        if (std.mem.eql(u8, name, "resetTransform")) {
            context.setIdentity();
            return .state_only;
        }
        if (std.mem.eql(u8, name, "save")) {
            try self.saved_transforms.append(self.allocator, context.getTransformation());
            return .state_only;
        }
        if (std.mem.eql(u8, name, "restore")) {
            if (self.saved_transforms.pop()) |transform| context.setTransformation(transform);
            return .state_only;
        }

        return error.NotImplemented;
    }
};

test "canvas rectangle commands draw, clear, snapshot, and resize" {
    const allocator = std.testing.allocator;
    const canvas = try Canvas.create(allocator, std.testing.io, 8, 6);
    defer canvas.destroy();

    _ = try canvas.command("fillRect", .{ 1, 1, 5, 4, 0, 0 }, false, .{
        .fill_style = "#ff0000ff",
    });
    _ = try canvas.command("clearRect", .{ 2, 2, 2, 2, 0, 0 }, false, .{});

    const pixels = try canvas.snapshot(allocator);
    defer allocator.free(pixels);
    const painted = (1 * 8 + 1) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels[painted..][0..4]);
    const cleared = (2 * 8 + 2) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[cleared..][0..4]);

    try canvas.resize(2, 3);
    try std.testing.expectEqual(@as(i32, 2), canvas.width);
    try std.testing.expectEqual(@as(i32, 3), canvas.height);
    const reset = try canvas.snapshot(allocator);
    defer allocator.free(reset);
    try std.testing.expectEqual(@as(usize, 24), reset.len);
    try std.testing.expect(std.mem.allEqual(u8, reset, 0));
}

test "canvas paths and saved transforms affect raster pixels" {
    const allocator = std.testing.allocator;
    const canvas = try Canvas.create(allocator, std.testing.io, 12, 12);
    defer canvas.destroy();
    const zeros = [_]f64{0} ** 6;

    _ = try canvas.command("save", zeros, false, .{});
    _ = try canvas.command("translate", .{ 4, 0, 0, 0, 0, 0 }, false, .{});
    _ = try canvas.command("fillRect", .{ 0, 0, 2, 2, 0, 0 }, false, .{
        .fill_style = "red",
    });
    _ = try canvas.command("restore", zeros, false, .{});
    _ = try canvas.command("fillRect", .{ 0, 4, 2, 2, 0, 0 }, false, .{
        .fill_style = "blue",
    });

    _ = try canvas.command("beginPath", zeros, false, .{});
    _ = try canvas.command("moveTo", .{ 6, 6, 0, 0, 0, 0 }, false, .{});
    _ = try canvas.command("lineTo", .{ 10, 6, 0, 0, 0, 0 }, false, .{});
    _ = try canvas.command("lineTo", .{ 6, 10, 0, 0, 0, 0 }, false, .{});
    _ = try canvas.command("closePath", zeros, false, .{});
    _ = try canvas.command("fill", zeros, false, .{ .fill_style = "green" });

    const pixels = try canvas.snapshot(allocator);
    defer allocator.free(pixels);
    const translated = (0 * 12 + 4) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels[translated..][0..4]);
    const restored = (4 * 12 + 0) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixels[restored..][0..4]);
    const triangle = (7 * 12 + 7) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 255 }, pixels[triangle..][0..4]);
}

test "unsupported canvas commands report NotImplemented without mutating pixels" {
    const allocator = std.testing.allocator;
    const canvas = try Canvas.create(allocator, std.testing.io, 2, 2);
    defer canvas.destroy();
    try std.testing.expectError(
        error.NotImplemented,
        canvas.command("drawImage", .{ 0, 0, 0, 0, 0, 0 }, false, .{}),
    );
    const pixels = try canvas.snapshot(allocator);
    defer allocator.free(pixels);
    try std.testing.expect(std.mem.allEqual(u8, pixels, 0));
}
