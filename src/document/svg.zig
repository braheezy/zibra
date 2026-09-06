//! SVG membership and presentation hints for the shared live DOM. Borrowed
//! ancestry is used only synchronously; this module owns no nodes or strings.
const std = @import("std");
pub const instance_properties = [_][]const u8{ "fill", "stroke", "fill-opacity", "stroke-opacity", "stroke-width", "fill-rule", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "color", "visibility" };

pub const inherited = .{
    .{ "fill", "black" },            .{ "stroke", "none" },
    .{ "fill-opacity", "1" },        .{ "stroke-opacity", "1" },
    .{ "stroke-width", "1" },        .{ "fill-rule", "nonzero" },
    .{ "clip-rule", "nonzero" },     .{ "stroke-linecap", "butt" },
    .{ "stroke-linejoin", "miter" }, .{ "stroke-miterlimit", "4" },
    .{ "text-anchor", "start" },
};

pub const local = .{
    .{ "clip-path", "none" },  .{ "stop-color", "black" },
    .{ "stop-opacity", "1" },  .{ "flood-color", "black" },
    .{ "flood-opacity", "1" },
};

/// True for an SVG root or descendants before an HTML foreignObject boundary.
pub fn contains(element: anytype) bool {
    if (std.ascii.eqlIgnoreCase(element.tag, "svg")) return true;
    var parent = element.parent;
    while (parent) |node| {
        if (node.* != .element) return false;
        if (std.ascii.eqlIgnoreCase(node.element.tag, "foreignObject")) return false;
        if (std.ascii.eqlIgnoreCase(node.element.tag, "svg")) return true;
        parent = node.element.parent;
    }
    return false;
}

/// Add presentation attributes below author rules, using borrowed values.
pub fn collect(element: anytype, hints: *std.StringHashMap([]const u8)) !void {
    if (!contains(element)) return;
    const attrs = element.attributes orelse return;
    if (!std.ascii.eqlIgnoreCase(element.tag, "svg")) {
        if (attrs.get("transform")) |value| try hints.put("transform", value);
    }
    inline for (inherited ++ local) |entry| if (attrs.get(entry[0])) |value| try hints.put(entry[0], value);
    inline for (.{ "color", "opacity", "display", "visibility", "font-size", "font-family", "font-weight", "font-style", "filter" }) |name| {
        if (attrs.get(name)) |value| try hints.put(name, value);
    }
}
