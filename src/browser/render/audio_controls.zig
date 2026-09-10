//! Native audio control paint and hit rectangles. Commands borrow font pixels
//! and synchronous provenance until the ordinary raster snapshot boundary.
const std = @import("std");
const display = @import("display_list.zig");
const font = @import("font.zig");
const controls = @import("../../media/controls.zig");
const Rect = display.Rect;

pub const Geometry = struct {
    parts: [4]Rect,
    time: Rect,

    pub fn init(box: Rect, scale: f64) Geometry {
        const button = @min(@as(i32, @intFromFloat(28 * scale)), @divTrunc(box.width(), 4));
        const gap = @min(@as(i32, @intFromFloat(4 * scale)), @divTrunc(box.width(), 16));
        const left = box.left + button + gap;
        const right = @max(left, box.right - button - gap);
        const middle = box.top + @divTrunc(box.height(), 2);
        const volume_left = right - @divTrunc(right - left, 3);
        return .{
            .parts = .{
                .{ .left = box.left, .top = box.top, .right = box.left + button, .bottom = box.bottom },
                .{ .left = left, .top = box.top, .right = right, .bottom = middle },
                .{ .left = box.right - button, .top = box.top, .right = box.right, .bottom = box.bottom },
                .{ .left = volume_left, .top = middle, .right = right, .bottom = box.bottom },
            },
            .time = .{ .left = left, .top = middle, .right = @max(left, volume_left - gap), .bottom = box.bottom },
        };
    }
};

pub const Painter = struct {
    allocator: std.mem.Allocator,
    fonts: *font.FontManager,
    commands: *std.ArrayList(display.DisplayItem),
    scale: f64,
    page_zoom: f32,
    ink: display.Color,
    background: display.Color,
    accent: display.Color,

    fn rect(self: Painter, box: Rect, color: display.Color, source: ?display.DisplayItemSource) !void {
        if (box.width() == 0 or box.height() == 0) return;
        try self.commands.append(self.allocator, .{ .rect = .{ .x1 = box.left, .y1 = box.top, .x2 = box.right, .y2 = box.bottom, .color = color, .source = source } });
    }
    fn line(self: Painter, x1: i32, y1: i32, x2: i32, y2: i32) !void {
        try self.commands.append(self.allocator, .{ .line = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = self.ink, .thickness = @max(1, @as(i32, @intFromFloat(2 * self.scale))) } });
    }
    fn text(self: Painter, box: Rect, value: []const u8) !void {
        if (box.height() == 0) return;
        const size: i32 = @intFromFloat(@max(1, @min(12 * self.scale, @as(f64, @floatFromInt(box.height()))) * self.page_zoom));
        var x = box.left;
        for (value) |byte| {
            const glyph = try self.fonts.getStyledGlyph(&.{byte}, .Normal, .Roman, size, .monospace);
            const width: i32 = @intFromFloat(@as(f64, @floatFromInt(glyph.w)) / self.page_zoom);
            const height: i32 = @intFromFloat(@as(f64, @floatFromInt(glyph.h)) / self.page_zoom);
            if (x + width > box.right or height > box.height()) break;
            try self.commands.append(self.allocator, .{ .glyph = .{ .x = x, .y = box.top + @divTrunc(box.height() - height, 2), .glyph = glyph, .color = self.ink, .page_zoom = self.page_zoom } });
            x += width;
        }
    }
    fn slider(self: Painter, box: Rect, value: f64, enabled: bool) !void {
        const center = box.top + @divTrunc(box.height(), 2);
        const half = @min(@max(1, @as(i32, @intFromFloat(2 * self.scale))), @divTrunc(box.height(), 2));
        const track = Rect{ .left = box.left, .right = box.right, .top = center - half, .bottom = center + half };
        try self.rect(track, self.ink, null);
        if (enabled) {
            const x = box.left + @as(i32, @intFromFloat(@as(f64, @floatFromInt(box.width())) * std.math.clamp(value, 0, 1)));
            try self.rect(.{ .left = box.left, .right = x, .top = track.top, .bottom = track.bottom }, self.accent, null);
            try self.rect(.{ .left = @max(box.left, x - half), .right = @min(box.right, x + half + 1), .top = @max(box.top, center - half * 2), .bottom = @min(box.bottom, center + half * 2) }, self.accent, null);
        }
    }

    fn speaker(self: Painter, box: Rect, muted: bool) !void {
        const radius = @min(@divTrunc(box.width(), 3), @divTrunc(box.height(), 3));
        if (radius < 2) return;
        const x = box.left + @divTrunc(box.width(), 2);
        const y = box.top + @divTrunc(box.height(), 2);
        const half = @divTrunc(radius, 2);
        try self.rect(.{ .left = x - radius, .top = y - half, .right = x - half, .bottom = y + half }, self.ink, null);
        try self.commands.append(self.allocator, .{ .quad = .{
            .x1 = x - half,
            .y1 = y - half,
            .x2 = x,
            .y2 = y - radius,
            .x3 = x,
            .y3 = y + radius,
            .x4 = x - half,
            .y4 = y + half,
            .color = self.ink,
        } });
        if (muted) {
            try self.line(x + 2, y - half, x + radius, y + half);
            try self.line(x + 2, y + half, x + radius, y - half);
        } else {
            try self.line(x + half, y - half, x + radius, y);
            try self.line(x + radius, y, x + half, y + half);
        }
    }

    /// Hit backgrounds carry the part identity; decorative leaves carry none,
    /// so text/icons never fragment a slider's authoritative hit rectangle.
    pub fn paint(self: Painter, box: Rect, state: controls.State, focused: ?controls.Part, provenance: ?display.DisplayItemSource) !void {
        const geometry = Geometry.init(box, self.scale);
        for (geometry.parts, 0..) |part_box, index| {
            var source = provenance;
            if (source) |*s| s.audio_part = @enumFromInt(index);
            try self.rect(part_box, self.background, source);
            if (focused != null and @intFromEnum(focused.?) == index and part_box.width() > 0 and part_box.height() > 0)
                try self.commands.append(self.allocator, .{ .outline = .{ .rect = part_box, .color = self.accent, .thickness = @max(1, @as(i32, @intFromFloat(self.scale))) } });
        }
        const play = geometry.parts[0];
        const cx = play.left + @divTrunc(play.width(), 2);
        const cy = play.top + @divTrunc(play.height(), 2);
        const radius = @min(@divTrunc(play.width(), 3), @divTrunc(play.height(), 3));
        if (radius > 0) {
            if (state.paused) {
                try self.line(cx - @divTrunc(radius, 2), cy - radius, cx + radius, cy);
                try self.line(cx + radius, cy, cx - @divTrunc(radius, 2), cy + radius);
                try self.line(cx - @divTrunc(radius, 2), cy + radius, cx - @divTrunc(radius, 2), cy - radius);
            } else {
                try self.line(cx - @divTrunc(radius, 2), cy - radius, cx - @divTrunc(radius, 2), cy + radius);
                try self.line(cx + @divTrunc(radius, 2), cy - radius, cx + @divTrunc(radius, 2), cy + radius);
            }
        }
        if (state.failed or state.loading or !state.ready) {
            try self.text(geometry.parts[1], if (state.failed) "Audio unavailable" else if (state.loading) "Loading..." else "Ready to load");
        } else try self.slider(geometry.parts[1], if (state.duration > 0) state.position / state.duration else 0, true);
        try self.slider(geometry.parts[3], state.volume, true);
        try self.speaker(geometry.parts[2], state.muted);
        var current: [24]u8 = undefined;
        var duration: [24]u8 = undefined;
        var text_buffer: [56]u8 = undefined;
        const time = try std.fmt.bufPrint(&text_buffer, "{s} / {s}", .{ controls.time(&current, state.position), if (state.ready) controls.time(&duration, state.duration) else "--:--" });
        try self.text(geometry.time, time);
    }
};

test "audio controls geometry keeps all parts inside narrow and zoomed boxes" {
    for ([_]i32{ 0, 40, 100, 300, 900 }) |width| {
        const box = Rect{ .left = 12, .top = 20, .right = 12 + width, .bottom = 100 };
        const geometry = Geometry.init(box, 2);
        for (geometry.parts) |part| {
            try std.testing.expect(part.left >= box.left and part.right <= box.right);
            try std.testing.expect(part.top >= box.top and part.bottom <= box.bottom);
            try std.testing.expect(part.right >= part.left);
        }
    }
}
