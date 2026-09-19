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
const sizing = @import("sizing.zig");

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
    if (std.ascii.eqlIgnoreCase(element.tag, "audio")) return @import("../../media/controls.zig").natural_width * scale;
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

/// Natural content widths ignore the root's width/min/max and its own edges.
/// Descendants contribute constrained outer sizes. Image roots intentionally
/// retain the shared replaced resolver's ratio/constraint policy.
/// The caller registers descendant style reads with a persistent layout owner.
pub fn measureContent(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    return measureImpl(node, fonts, scale, false);
}

/// Intrinsic keyword widths can transfer a definite height through a ratio.
/// `natural` remains the separate raw content suggestion for automatic minima;
/// it and `scale` describe this root, with authored zoom already composed.
pub fn keywordContent(node: *const dom.Node, natural: Width, scale: f64) Width {
    if (node.* != .element) return natural;
    return ratioContent(node.element, scale) orelse natural;
}

/// Constrained root content widths, excluding its padding, borders and margins.
/// `scale` already includes this root's authored zoom; descendants add theirs.
pub fn measure(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    return measureImpl(node, fonts, scale, true);
}

/// Constrained root contribution including padding, borders and margins once.
/// Intrinsic percentage sizes/edges have no containing-block basis here.
pub fn measureOuter(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    if (!participates(node)) return .{};
    var result = try measure(node, fonts, scale);
    if (node.* == .element) {
        const edges = rootEdges(node.element, scale);
        const extra: f64 = @floatFromInt(edges.margin.horizontal() + edges.padding.horizontal() + edges.border.horizontal());
        result.min = @max(result.min + extra, 0);
        result.max = @max(result.max + extra, result.min);
    }
    return result;
}

fn participates(node: *const dom.Node) bool {
    if (node.* != .element) return true;
    const element = &node.element;
    if (element.isHiddenInput() or element.isHiddenAudio() or std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "none")) return false;
    const position = value(element.style, "position", "static");
    return !std.ascii.eqlIgnoreCase(position, "absolute") and !std.ascii.eqlIgnoreCase(position, "fixed");
}

fn rootEdges(element: dom.Element, scale: f64) box_model.BoxModelEdges {
    const size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16;
    return if (element.style) |styles| box_model.resolveBoxEdges(&styles, size, null, @floatCast(scale), 1) else .{ .margin = .{}, .padding = .{}, .border = .{} };
}

fn ratioContent(element: dom.Element, scale: f64) ?Width {
    // Replaced/native boxes retain their dedicated natural-size policies.
    if (element.image_data != null) return null;
    for ([_][]const u8{ "img", "input", "textarea", "audio", "svg", "iframe", "canvas", "select", "button" }) |tag| {
        if (std.ascii.eqlIgnoreCase(element.tag, tag)) return null;
    }
    const aspect = replaced_sizing.parseAspectRatio(value(element.style, "aspect-ratio", "auto")) orelse return null;
    const ratio = aspect.ratio orelse return null;
    const edges = rootEdges(element, scale);
    const x_edges: f64 = @floatFromInt(edges.padding.horizontal() + edges.border.horizontal());
    const y_edges: f64 = @floatFromInt(edges.padding.vertical() + edges.border.vertical());
    const border_box = std.ascii.eqlIgnoreCase(value(element.style, "box-sizing", "content-box"), "border-box");
    const context = sizing.ResolveContext{
        .font_size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16,
        .scale = scale,
        .insets = y_edges,
        .border_box = border_box,
    };
    // No percentage height basis exists during this synchronous traversal.
    const height = sizing.resolve(value(element.style, "height", "auto"), context) orelse return null;
    const limits = sizing.Constraints{
        .min = sizing.resolve(value(element.style, "min-height", "auto"), context) orelse 0,
        .max = sizing.resolve(value(element.style, "max-height", "none"), context) orelse std.math.inf(f64),
    };
    const use_border = border_box and !aspect.use_intrinsic;
    const width = std.math.clamp((limits.clamp(height) + if (use_border) y_edges else @as(f64, 0)) * ratio - if (use_border) x_edges else @as(f64, 0), 0, 16777216);
    return .{ .min = width, .max = width };
}

fn constrainedContent(element: dom.Element, natural: Width, scale: f64) Width {
    // Ordinary inline boxes ignore width/min/max; atomic/replaced boxes and
    // blockified flex/grid roots use their own sizing policy instead.
    if (std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "inline") and
        std.ascii.eqlIgnoreCase(value(element.style, "float", "none"), "none") and
        !std.ascii.eqlIgnoreCase(element.tag, "input") and !std.ascii.eqlIgnoreCase(element.tag, "textarea") and
        !std.ascii.eqlIgnoreCase(element.tag, "audio") and !std.ascii.eqlIgnoreCase(element.tag, "svg")) return natural;
    const transferred = ratioContent(element, scale);
    const intrinsic = transferred orelse natural;
    var result = intrinsic;
    result.min = constrainedValue(element, natural, intrinsic, transferred != null, scale, intrinsic.min);
    result.max = @max(result.min, constrainedValue(element, natural, intrinsic, transferred != null, scale, intrinsic.max));
    return result;
}

fn constrainedValue(element: dom.Element, natural: Width, intrinsic: Width, transferred: bool, scale: f64, available: f64) f64 {
    const edges = rootEdges(element, scale);
    const context = sizing.ResolveContext{
        .font_size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16,
        .scale = scale,
        .insets = @floatFromInt(edges.padding.horizontal() + edges.border.horizontal()),
        .border_box = std.ascii.eqlIgnoreCase(value(element.style, "box-sizing", "content-box"), "border-box"),
        .intrinsic = .{ .min = intrinsic.min, .max = intrinsic.max },
        .available = available,
    };
    const maximum = sizing.resolve(value(element.style, "max-width", "none"), context) orelse std.math.inf(f64);
    const raw_width = value(element.style, "width", "auto");
    const overflow = value(element.style, "overflow", "visible");
    const content_minimum = transferred and length.resolve(raw_width, .{ .font_size = context.font_size }) == null and
        std.ascii.eqlIgnoreCase(value(element.style, "min-width", "auto"), "auto") and
        !std.ascii.eqlIgnoreCase(overflow, "hidden") and !std.ascii.eqlIgnoreCase(overflow, "scroll") and !std.ascii.eqlIgnoreCase(overflow, "auto");
    const limits = sizing.Constraints{
        .min = sizing.resolve(value(element.style, "min-width", "auto"), context) orelse if (content_minimum) @min(natural.min, maximum) else 0,
        .max = maximum,
    };
    const preferred = sizing.resolve(raw_width, context);
    return limits.clamp(preferred orelse available);
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
            const decoded = try text.decoded(fonts.allocator);
            defer if (decoded) |bytes| fonts.allocator.free(bytes);
            const bytes = decoded orelse text.text;
            if (bytes.len == 0) break :blk .{};
            var words = std.mem.tokenizeAny(u8, bytes, " \t\r\n\x0c");
            var result: Width = .{};
            if (std.ascii.isWhitespace(bytes[0])) result.leading_space = @floatFromInt(space.w);
            if (std.ascii.isWhitespace(bytes[bytes.len - 1])) result.trailing_space = @floatFromInt(space.w);
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
            if (!participates(node)) break :blk .{};
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
            if (std.ascii.eqlIgnoreCase(element.tag, "input") or std.ascii.eqlIgnoreCase(element.tag, "textarea") or std.ascii.eqlIgnoreCase(element.tag, "audio")) {
                const width = if (element.isCheckbox() or element.isInputType("radio")) size * scale else try inputNaturalWidth(element, fonts, scale);
                const natural = Width{ .min = width, .max = width };
                break :blk if (include_specified) constrainedContent(element, natural, scale) else natural;
            }
            if (std.ascii.eqlIgnoreCase(element.tag, "svg")) {
                const dimensions = @import("svg_inline.zig").size(&element, .{ .font_size = size });
                const width = @as(f64, @floatFromInt(dimensions.width)) * scale;
                const natural = Width{ .min = width, .max = width };
                break :blk if (include_specified) constrainedContent(element, natural, scale) else natural;
            }
            var result: Width = .{};
            var inline_run: f64 = 0;
            var pending_space: f64 = 0;
            var float_run: f64 = 0;
            for (element.children.items) |*child| {
                if (!participates(child)) continue;
                if (child.* == .element and std.ascii.eqlIgnoreCase(child.element.tag, "br")) {
                    result.max = @max(result.max, inline_run);
                    inline_run = 0;
                    pending_space = 0;
                    continue;
                }
                const child_scale = if (child.* == .element) scale * box_model.parseCssZoom(value(child.element.style, "zoom", "1")) else scale;
                const measured = try measureOuter(child, fonts, child_scale);
                const child_display = if (child.* == .element) value(child.element.style, "display", "inline") else "inline";
                if (child.* == .element and !std.ascii.eqlIgnoreCase(value(child.element.style, "float", "none"), "none")) {
                    if (!std.ascii.eqlIgnoreCase(value(child.element.style, "clear", "none"), "none")) {
                        result.max = @max(result.max, float_run);
                        float_run = 0;
                    }
                    float_run += measured.max;
                    result.min = @max(result.min, measured.min);
                    continue;
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
            result.max = @max(result.max, inline_run + float_run);
            if (std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "inline")) {
                result.trailing_space = pending_space;
            } else {
                result.leading_space = 0;
            }
            if (std.ascii.eqlIgnoreCase(value(element.style, "white-space", "normal"), "nowrap")) result.min = result.max;
            break :blk if (include_specified) constrainedContent(element, result, scale) else result;
        },
    };
}
