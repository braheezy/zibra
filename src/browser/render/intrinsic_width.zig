//! Synchronous intrinsic inline-width measurement over a styled DOM borrow.
//! Owns no DOM/layout pointers; glyph resources remain in the FontManager.
const std = @import("std");
const dom = @import("../../document/dom.zig");
const length = @import("../../document/length.zig");
const font = @import("font.zig");
const grapheme = @import("grapheme");

pub const Width = struct {
    min: f64 = 0,
    max: f64 = 0,
    // Collapsible whitespace is resolved across adjacent inline node edges,
    // not independently trimmed out of every DOM text node.
    leading_space: f64 = 0,
    trailing_space: f64 = 0,
};
fn value(styles: ?dom.StyleMap, name: []const u8, default: []const u8) []const u8 {
    if (styles) |map| if (map.get(name)) |field| return field.get().*;
    return default;
}

pub fn measure(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    return switch (node.*) {
        .text => |text| blk: {
            if (text.text.len == 0) break :blk .{};
            const size = length.parsePixel(value(text.style, "font-size", "16px")) orelse 16;
            const weight: font.FontWeight = if (font.isBoldWeight(value(text.style, "font-weight", "normal"))) .Bold else .Normal;
            const style = value(text.style, "font-style", "normal");
            const slant: font.FontSlant = if (std.ascii.eqlIgnoreCase(style, "italic") or std.ascii.eqlIgnoreCase(style, "oblique")) .Italic else .Roman;
            const family = font.familyFromCss(value(text.style, "font-family", "sans-serif"));
            const raster_size = font.rasterSizeForCssPixels(size * scale);
            const space = try fonts.getStyledGlyph(" ", weight, slant, raster_size, family);
            var words = std.mem.tokenizeAny(u8, text.text, " \t\r\n");
            var result: Width = .{};
            if (std.ascii.isWhitespace(text.text[0])) result.leading_space = @floatFromInt(space.w);
            if (std.ascii.isWhitespace(text.text[text.text.len - 1])) result.trailing_space = @floatFromInt(space.w);
            while (words.next()) |word| {
                // Paint currently advances one grapheme at a time. Measuring
                // a kerned whole word here can under-allocate its atomic box.
                var width: f64 = 0;
                var characters = grapheme.iterator(word);
                while (characters.next()) |character| {
                    const glyph = try fonts.getStyledGlyph(character.bytes(word), weight, slant, raster_size, family);
                    width += @floatFromInt(glyph.w);
                }
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
            var pending_space: f64 = 0;
            for (element.children.items) |*child| {
                const measured = try measure(child, fonts, scale);
                const child_display = if (child.* == .element) value(child.element.style, "display", "inline") else "inline";
                const block = !std.ascii.eqlIgnoreCase(child_display, "inline") and
                    !std.ascii.eqlIgnoreCase(child_display, "inline-block") and
                    !std.ascii.eqlIgnoreCase(child_display, "none");
                result.min = @max(result.min, measured.min);
                if (block) {
                    result.max = @max(result.max, @max(inline_run, measured.max));
                    inline_run = 0;
                    pending_space = 0;
                } else {
                    if (inline_run == 0 and result.max == 0) result.leading_space = @max(result.leading_space, measured.leading_space);
                    if (measured.max > 0) {
                        if (inline_run > 0) inline_run += @max(pending_space, measured.leading_space);
                        inline_run += measured.max;
                        pending_space = measured.trailing_space;
                    } else pending_space = @max(pending_space, measured.trailing_space);
                }
            }
            result.max = @max(result.max, inline_run);
            if (std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "inline")) {
                result.trailing_space = pending_space;
            } else {
                result.leading_space = 0;
            }
            if (std.ascii.eqlIgnoreCase(value(element.style, "white-space", "normal"), "nowrap")) result.min = result.max;
            break :blk result;
        },
    };
}
