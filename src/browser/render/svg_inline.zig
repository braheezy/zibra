//! Inline SVG used sizing and owned paint snapshots. Layout retains the DOM
//! borrow; the returned pixels are independent and use canvas command cleanup.
const std = @import("std");
const dom = @import("../../document/dom.zig");
const svg = @import("svg.zig");
const v = @import("svg_values.zig");
const sizing = @import("replaced_sizing.zig");

pub fn size(element: *const dom.Element, context: sizing.SizeContext) sizing.Size {
    const viewport = v.Viewport.parse(element) catch return .{ .width = 0, .height = 0 };
    var specified = sizing.specifiedSizeWithContext(element, context);
    // SVG dimension attributes accept percentages and units beyond the HTML
    // replaced-element integer attribute grammar.
    inline for (.{ "width", "height" }) |name| {
        const explicit_css = if (element.style) |styles| if (styles.get(name)) |field| !std.mem.eql(u8, field.get().*, "auto") else false else false;
        const animated = if (element.svg_animation) |state| state.values.contains(name) else false;
        if (animated or !explicit_css) if (v.attr(element, name)) |raw| dimension: {
            const basis = if (std.mem.eql(u8, name, "width")) context.percentage_width orelse 300 else context.percentage_height orelse 150;
            const pixels = v.length(raw, basis) catch break :dimension;
            @field(specified, name) = @intFromFloat(std.math.clamp(@ceil(pixels), 0, 4096));
        };
    }
    return sizing.resolve(.image, specified, .{ .width = @intFromFloat(@ceil(viewport.width)), .height = @intFromFloat(@ceil(viewport.height)) }, sizing.aspectRatio(element));
}

/// Transfers pixels to an owning display command. Invalid SVG paints empty;
/// allocation failure propagates so the retained paint transaction can retry.
pub fn snapshot(allocator: std.mem.Allocator, io: std.Io, element: *const dom.Element, width: i32, height: i32, root_opacity_in_paint: bool) ![]u8 {
    var image = svg.render(allocator, io, element, .{ .size = .{ @floatFromInt(width), @floatFromInt(height) }, .root_opacity_in_paint = root_opacity_in_paint }) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Inline SVG rasterization failed: {}", .{err});
        return allocator.alloc(u8, 0);
    };
    defer image.deinit(allocator);
    return try allocator.dupe(u8, image.rawBytes());
}
