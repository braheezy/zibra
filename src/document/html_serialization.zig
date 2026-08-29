//! Live DOM HTML serialization.
//!
//! Serializer entry points are generic over the DOM node type to keep this
//! leaf module independent of parser.zig while still traversing the current
//! attributes and children rather than source snapshots.

const std = @import("std");

const void_element_tags = [_][]const u8{
    "area", "base", "br",    "col",    "embed", "hr",  "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
};

pub fn appendEscapedAttributeValue(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |byte| {
        const escaped = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        };
        if (escaped) |text| {
            try output.appendSlice(allocator, text);
        } else {
            try output.append(allocator, byte);
        }
    }
}

pub fn isVoidElementTag(tag: []const u8) bool {
    return for (void_element_tags) |void_tag| {
        if (std.ascii.eqlIgnoreCase(tag, void_tag)) break true;
    } else false;
}

fn appendSerializedAttributes(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    element: anytype,
) !void {
    const attributes = element.attributes orelse return;
    const names = try allocator.alloc([]const u8, attributes.count());
    defer allocator.free(names);

    var index: usize = 0;
    var iterator = attributes.iterator();
    while (iterator.next()) |entry| : (index += 1) names[index] = entry.key_ptr.*;
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (names) |name| {
        try output.append(allocator, ' ');
        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, "=\"");
        try appendEscapedAttributeValue(allocator, output, attributes.get(name).?);
        try output.append(allocator, '"');
    }
}

fn appendSerializedNode(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    node: anytype,
) !void {
    switch (node.*) {
        // DOM text remains source-backed and escaped in this browser; copying
        // it preserves the source spelling without double-escaping entities.
        .text => |text| try output.appendSlice(allocator, text.text),
        .element => |element| {
            try output.append(allocator, '<');
            try output.appendSlice(allocator, element.tag);
            try appendSerializedAttributes(allocator, output, &element);
            try output.append(allocator, '>');

            if (isVoidElementTag(element.tag)) return;
            for (element.children.items) |*child| {
                try appendSerializedNode(allocator, output, child);
            }

            try output.appendSlice(allocator, "</");
            try output.appendSlice(allocator, element.tag);
            try output.append(allocator, '>');
        },
    }
}

/// Serialize an element's current child tree as HTML source. The caller owns
/// the returned allocation.
pub fn serializeInnerHtml(allocator: std.mem.Allocator, node: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    switch (node.*) {
        .text => return error.InnerHtmlRequiresElement,
        .element => |element| {
            for (element.children.items) |*child| {
                try appendSerializedNode(allocator, &output, child);
            }
        },
    }
    return output.toOwnedSlice(allocator);
}

/// Serialize an element and its current descendants as HTML source. The
/// caller owns the returned allocation.
pub fn serializeOuterHtml(allocator: std.mem.Allocator, node: anytype) ![]u8 {
    if (node.* != .element) return error.OuterHtmlRequiresElement;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try appendSerializedNode(allocator, &output, node);
    return output.toOwnedSlice(allocator);
}
