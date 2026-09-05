//! Synchronous intrinsic inline-width measurement over a styled DOM borrow.
//! Owns no DOM/layout pointers; glyph resources remain in the FontManager.
const std = @import("std");
const dom = @import("../../document/dom.zig");
const length = @import("../../document/length.zig");
const font = @import("font.zig");

pub const Width = struct { min: f64 = 0, max: f64 = 0 };
fn value(styles: ?dom.StyleMap, name: []const u8, default: []const u8) []const u8 {
    if (styles) |map| if (map.get(name)) |field| return field.get().*;
    return default;
}

pub fn measure(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    return switch (node.*) {
        .text => |text| blk: {
            if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) break :blk .{};
            const size = length.parsePixel(value(text.style, "font-size", "16px")) orelse 16;
            const weight: font.FontWeight = if (std.ascii.eqlIgnoreCase(value(text.style, "font-weight", "normal"), "bold")) .Bold else .Normal;
            const slant: font.FontSlant = if (std.ascii.eqlIgnoreCase(value(text.style, "font-style", "normal"), "italic")) .Italic else .Roman;
            const family = font.familyFromCss(value(text.style, "font-family", "sans-serif"));
            const raster_size: i32 = @intFromFloat(std.math.clamp(size * 0.75 * scale, 1, 4096));
            const space = try fonts.getStyledGlyph(" ", weight, slant, raster_size, family);
            var words = std.mem.tokenizeAny(u8, text.text, " \t\r\n");
            var result: Width = .{};
            while (words.next()) |word| {
                const glyph = try fonts.getStyledGlyph(word, weight, slant, raster_size, family);
                const width: f64 = @floatFromInt(glyph.w);
                if (result.max > 0) result.max += @floatFromInt(space.w);
                result.max += width;
                result.min = @max(result.min, width);
            }
            if (std.ascii.eqlIgnoreCase(value(text.style, "white-space", "normal"), "nowrap")) result.min = result.max;
            break :blk result;
        },
        .element => |element| blk: {
            if (std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "none")) break :blk .{};
            const size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16;
            if (length.resolve(value(element.style, "width", "auto"), .{ .font_size = size })) |width| break :blk .{ .min = width * scale, .max = width * scale };
            if (element.image_data) |image| break :blk .{ .min = @as(f64, @floatFromInt(image.image.width)) * scale, .max = @as(f64, @floatFromInt(image.image.width)) * scale };
            var result: Width = .{};
            var inline_run: f64 = 0;
            for (element.children.items) |*child| {
                const measured = try measure(child, fonts, scale);
                const block = child.* == .element and !std.ascii.eqlIgnoreCase(value(child.element.style, "display", "inline"), "inline");
                result.min = @max(result.min, measured.min);
                if (block) {
                    result.max = @max(result.max, @max(inline_run, measured.max));
                    inline_run = 0;
                } else inline_run += measured.max;
            }
            result.max = @max(result.max, inline_run);
            break :blk result;
        },
    };
}
