//! Synchronous intrinsic inline-width measurement over a styled DOM borrow.
//! Owns no DOM/layout pointers; glyph resources remain in the FontManager.
const std = @import("std");
const dom = @import("../../document/dom.zig");
const length = @import("../../document/length.zig");
const font = @import("font.zig");
const grapheme = @import("grapheme");
const box_model = @import("box_model.zig");
const inline_format = @import("inline_format.zig");
const replaced_sizing = @import("replaced_sizing.zig");

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

/// Native input natural content width, shared with final control layout.
/// CSS preferred/min/max sizes and box edges are applied by the caller.
pub fn inputNaturalWidth(element: dom.Element, fonts: *font.FontManager, scale: f64) !f64 {
    const size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16;
    const weight: font.FontWeight = if (font.isBoldWeight(value(element.style, "font-weight", "normal"))) .Bold else .Normal;
    const slant: font.FontSlant = if (std.ascii.eqlIgnoreCase(value(element.style, "font-style", "normal"), "italic")) .Italic else .Roman;
    const family = font.familyFromCss(value(element.style, "font-family", "sans-serif"));
    const raster_size = font.rasterSizeForCssPixels(size * scale);
    if (element.isInputType("submit") or element.isInputType("reset") or element.isInputType("button")) {
        const fallback: []const u8 = if (element.isInputType("submit")) "Submit" else if (element.isInputType("reset")) "Reset" else "";
        const label = if (element.attributes) |attrs| attrs.get("value") orelse fallback else fallback;
        var width: f64 = 8 * scale;
        var characters = grapheme.iterator(label);
        while (characters.next()) |character| {
            const glyph = try fonts.getStyledGlyph(character.bytes(label), weight, slant, raster_size, family);
            width += @floatFromInt(glyph.w);
        }
        return width;
    }
    if (element.attributes) |attrs| if (attrs.get("size")) |raw| {
        const count = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch 0;
        if (count > 0) {
            const glyph = try fonts.getStyledGlyph("0", weight, slant, raster_size, family);
            return @as(f64, @floatFromInt(glyph.w)) * @as(f64, @floatFromInt(@min(count, 100_000)));
        }
    };
    return 200 * scale;
}

/// Intrinsic widths describe content, not the root's authored width or edges.
/// Descendant boxes contribute their full outer size, including controls.
pub fn measureContent(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    return measureImpl(node, fonts, scale, false);
}

pub fn measure(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    return measureImpl(node, fonts, scale, true);
}

fn measureImpl(node: *const dom.Node, fonts: *font.FontManager, scale: f64, include_specified: bool) anyerror!Width {
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
            const decoded = try inline_format.decodeTextForDisplay(fonts.allocator, text.text);
            defer fonts.allocator.free(decoded);
            var words = std.mem.tokenizeAny(u8, decoded, " \t\r\n\x0c");
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
            if (element.isHiddenInput() or std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "none")) break :blk .{};
            const position = value(element.style, "position", "static");
            if (std.ascii.eqlIgnoreCase(position, "absolute") or std.ascii.eqlIgnoreCase(position, "fixed")) break :blk .{};
            const size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16;
            if (std.ascii.eqlIgnoreCase(element.tag, "img") or element.image_data != null) {
                const edges = if (element.style) |styles| box_model.resolveBoxEdges(&styles, size, null, 1, 1) else box_model.BoxModelEdges{ .margin = .{}, .padding = .{}, .border = .{} };
                const natural: ?replaced_sizing.Size = if (element.image_data) |data| .{ .width = @intCast(data.image.width), .height = @intCast(data.image.height) } else null;
                // Cyclic percentages have no basis during intrinsic sizing.
                // Definite caps on either axis still transfer through the
                // image's ratio before flex/table measure their contents.
                const used = replaced_sizing.imageSizeWithContext(&element, natural, .{
                    .font_size = size,
                    .insets = .{ .width = edges.padding.horizontal() + edges.border.horizontal(), .height = edges.padding.vertical() + edges.border.vertical() },
                });
                const width = @as(f64, @floatFromInt(used.width)) * scale;
                break :blk .{ .min = width, .max = width };
            }
            if (include_specified) if (length.resolve(value(element.style, "width", "auto"), .{ .font_size = size })) |width| break :blk .{ .min = width * scale, .max = width * scale };
            if (std.ascii.eqlIgnoreCase(element.tag, "input") or std.ascii.eqlIgnoreCase(element.tag, "textarea")) {
                const width = if (element.isCheckbox() or element.isInputType("radio")) size * scale else try inputNaturalWidth(element, fonts, scale);
                break :blk .{ .min = width, .max = width };
            }
            var result: Width = .{};
            var inline_run: f64 = 0;
            var pending_space: f64 = 0;
            for (element.children.items) |*child| {
                if (child.* == .element) {
                    const child_position = value(child.element.style, "position", "static");
                    if (std.ascii.eqlIgnoreCase(child_position, "absolute") or std.ascii.eqlIgnoreCase(child_position, "fixed")) continue;
                }
                if (child.* == .element and std.ascii.eqlIgnoreCase(child.element.tag, "br")) {
                    result.max = @max(result.max, inline_run);
                    inline_run = 0;
                    pending_space = 0;
                    continue;
                }
                const child_scale = if (child.* == .element) scale * box_model.parseCssZoom(value(child.element.style, "zoom", "1")) else scale;
                var measured = try measure(child, fonts, child_scale);
                const child_display = if (child.* == .element) value(child.element.style, "display", "inline") else "inline";
                if (child.* == .element and !child.element.isHiddenInput() and !std.ascii.eqlIgnoreCase(child_display, "none")) {
                    if (child.element.style) |styles| {
                        const child_size = length.parsePixel(value(child.element.style, "font-size", "16px")) orelse 16;
                        const edges = box_model.resolveBoxEdges(&styles, child_size, null, @floatCast(child_scale), 1);
                        const border_box = std.ascii.eqlIgnoreCase(value(child.element.style, "box-sizing", "content-box"), "border-box");
                        const specified = length.resolve(value(child.element.style, "width", "auto"), .{ .font_size = child_size }) != null;
                        const replaced = std.ascii.eqlIgnoreCase(child.element.tag, "img") or child.element.image_data != null;
                        const extra: f64 = @floatFromInt(edges.margin.horizontal() + if (border_box and specified and !replaced) @as(i32, 0) else edges.padding.horizontal() + edges.border.horizontal());
                        measured.min = @max(measured.min + extra, 0);
                        measured.max = @max(measured.max + extra, measured.min);
                    }
                }
                const table_row = std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "table-row");
                const block = !table_row and !std.ascii.eqlIgnoreCase(child_display, "inline") and
                    !std.ascii.eqlIgnoreCase(child_display, "inline-block") and
                    !std.ascii.eqlIgnoreCase(child_display, "none");
                if (table_row) result.min += measured.min else result.min = @max(result.min, measured.min);
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
