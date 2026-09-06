//! Basic SVG text through z2d's TrueType outline renderer. Font buffers and
//! normalized text are temporary owners; no native font handle escapes.
const std = @import("std");
const z2d = @import("z2d");
const dom = @import("../../document/dom.zig");
const v = @import("svg_values.zig");

fn content(allocator: std.mem.Allocator, element: *const dom.Element, output: *std.ArrayList(u8)) anyerror!void {
    for (element.children.items) |*child| switch (child.*) {
        .text => |text| {
            if (output.items.len + text.text.len > 8192) return error.SvgTooComplex;
            for (text.text) |byte| {
                if (std.ascii.isWhitespace(byte)) {
                    if (output.items.len > 0 and output.items[output.items.len - 1] != ' ') try output.append(allocator, ' ');
                } else try output.append(allocator, byte);
            }
        },
        .element => |*nested| if (std.ascii.eqlIgnoreCase(nested.tag, "tspan")) try content(allocator, nested, output),
    };
}

/// Draw a single left-to-right text chunk, with nested textual tspan content.
/// Position is an SVG baseline; z2d supplies kerning and outline rasterization.
pub fn draw(context: *z2d.Context, element: *const dom.Element, viewport: v.Viewport) !void {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(context.alloc);
    try content(context.alloc, element, &text);
    const utf8 = std.mem.trimEnd(u8, text.items, " ");
    if (utf8.len == 0) return;
    var cursor: ?*const dom.Element = element;
    var font_size: ?f64 = null;
    while (cursor) |current| {
        if (v.property(current, "font-size")) |raw| {
            font_size = v.length(raw, 16) catch 16;
            break;
        }
        const parent = current.parent orelse break;
        cursor = if (parent.* == .element) &parent.element else null;
    }
    const size = std.math.clamp(font_size orelse 16, 0, 1024);
    if (size == 0) return;
    const paths: []const []const u8 = switch (@import("builtin").os.tag) {
        .macos => &.{ "/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf" },
        .windows => &.{"C:/Windows/Fonts/arial.ttf"},
        else => &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf" },
    };
    for (paths) |filename| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(context.io, filename, context.alloc, .limited(16 * 1024 * 1024)) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        defer context.alloc.free(bytes);
        context.setFontToBuffer(bytes) catch continue;
        defer context.deinitFont();
        context.setFontSize(size);
        // z2d places outlines within an em box; SVG y specifies its baseline.
        try context.showText(utf8, try v.coordinate(element, "x", viewport.user_width, 0) + try v.coordinate(element, "dx", viewport.user_width, 0), try v.coordinate(element, "y", viewport.user_height, 0) + try v.coordinate(element, "dy", viewport.user_height, 0) - size);
        return;
    }
}
