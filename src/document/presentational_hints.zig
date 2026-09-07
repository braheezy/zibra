//! HTML presentation attributes mapped to low-priority author declarations.
//! Output strings borrow attributes/static storage or the caller's temporary
//! allocator. Style application interns winning values before that arena ends.
const std = @import("std");

pub const legacy_center = "-zibra-center";
pub const legacy_left = "-zibra-left";
pub const legacy_right = "-zibra-right";

fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.ascii.eqlIgnoreCase(value, option)) return true;
    return false;
}

/// Parse an HTML dimension, not a CSS length. Zero table/cell widths mean auto.
pub fn dimension(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    var end: usize = 0;
    while (end < value.len and (std.ascii.isDigit(value[end]) or value[end] == '.')) : (end += 1) {}
    if (end == 0) return null;
    const number = std.fmt.parseFloat(f64, value[0..end]) catch return null;
    if (!std.math.isFinite(number) or number <= 0) return null;
    return try std.fmt.allocPrint(allocator, "{d}{s}", .{ number, if (end < value.len and value[end] == '%') "%" else "px" });
}

/// Populate a temporary declaration map; owns neither the DOM nor attributes.
pub fn collect(allocator: std.mem.Allocator, tag: []const u8, attributes: ?@import("attributes.zig").Map, hints: *std.StringHashMap([]const u8)) !void {
    const attrs = attributes orelse return;
    const cell = oneOf(tag, &.{ "td", "th" });
    const table = std.ascii.eqlIgnoreCase(tag, "table");
    if (cell or table) {
        if (attrs.get("width")) |width| if (try dimension(allocator, width)) |value| try hints.put("width", value);
    }
    if (cell and attrs.contains("nowrap")) try hints.put("white-space", "nowrap");
    if (attrs.get("align")) |raw| {
        const alignment = std.mem.trim(u8, raw, " \t\r\n\x0c");
        if (table) {
            if (std.ascii.eqlIgnoreCase(alignment, "center")) {
                try hints.put("margin-left", "auto");
                try hints.put("margin-right", "auto");
            } else if (oneOf(alignment, &.{ "left", "right" })) {
                try hints.put("float", if (std.ascii.eqlIgnoreCase(alignment, "left")) "left" else "right");
            }
        } else if (oneOf(tag, &.{ "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "td", "th", "tr", "tbody", "thead", "tfoot" })) {
            const value: ?[]const u8 = if (std.ascii.eqlIgnoreCase(alignment, "center")) legacy_center else if (std.ascii.eqlIgnoreCase(alignment, "left")) legacy_left else if (std.ascii.eqlIgnoreCase(alignment, "right")) legacy_right else if (std.ascii.eqlIgnoreCase(alignment, "justify")) "justify" else null;
            if (value) |v| try hints.put("text-align", v);
        }
    }
}
