//! Builds and identifies authored inline DOM event handlers.
//!
//! HTML event attributes (for example, `onload`) borrow their source from the
//! owning Element. This module turns that source into one self-contained
//! runtime invocation while keeping DOM ownership and Kiesel execution in the
//! `Js` coordinator.

const std = @import("std");
const parser = @import("../document/parser.zig");

pub const Dispatch = struct {
    handle: u32,
    event_type: []const u8,
    source: []const u8,
    bubbles: bool = false,
};

/// Return the authored `on<event_type>` source for an Element. Attribute and
/// event names are ASCII-case-insensitive in HTML, while the returned source
/// remains a synchronous borrow of the caller-owned DOM node.
pub fn sourceFor(
    allocator: std.mem.Allocator,
    node: *const parser.Node,
    event_type: []const u8,
) !?[]const u8 {
    const element = switch (node.*) {
        .element => |*value| value,
        .text => return null,
    };
    const attributes = element.attributes orelse return null;

    const name_len = std.math.add(usize, event_type.len, 2) catch return error.OutOfMemory;
    const attribute_name = try allocator.alloc(u8, name_len);
    defer allocator.free(attribute_name);
    attribute_name[0] = 'o';
    attribute_name[1] = 'n';
    for (event_type, attribute_name[2..]) |byte, *destination| {
        destination.* = std.ascii.toLower(byte);
    }
    return attributes.get(attribute_name);
}

/// Build a JavaScript expression that constructs an Event and invokes one
/// authored handler through the runtime-owned dispatcher. The handler source
/// is emitted as a function body, not a quoted JavaScript string, so its
/// ordinary statement syntax and `this` binding are preserved.
///
/// The returned source belongs to `allocator`.
pub fn buildInvocation(allocator: std.mem.Allocator, dispatch: Dispatch) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, "__dispatchInlineEventHandler(");
    const handle_text = try std.fmt.allocPrint(allocator, "{d}", .{dispatch.handle});
    defer allocator.free(handle_text);
    try output.appendSlice(allocator, handle_text);
    try output.append(allocator, ',');
    try appendJavaScriptStringLiteral(allocator, &output, dispatch.event_type);
    try output.appendSlice(allocator, ",function(event) {\n");
    try output.appendSlice(allocator, dispatch.source);
    try output.appendSlice(allocator, "\n},");
    try output.appendSlice(allocator, if (dispatch.bubbles) "true" else "false");
    try output.appendSlice(allocator, ")");
    return output.toOwnedSlice(allocator);
}

fn appendJavaScriptStringLiteral(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) !void {
    const hex = "0123456789abcdef";
    try output.append(allocator, '\"');
    for (value) |byte| {
        switch (byte) {
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\"' => try output.appendSlice(allocator, "\\\""),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            0...8, 0x0b...0x0c, 0x0e...0x1f => {
                try output.appendSlice(allocator, "\\u00");
                try output.append(allocator, hex[byte >> 4]);
                try output.append(allocator, hex[byte & 0x0f]);
            },
            else => try output.append(allocator, byte),
        }
    }
    try output.append(allocator, '\"');
}

test "inline event lookup normalizes the event attribute name" {
    const allocator = std.testing.allocator;
    var element = try parser.Element.init(allocator, "body ONLOAD='ready()'", null);
    defer element.deinit(allocator);
    const node = parser.Node{ .element = element };

    try std.testing.expectEqualStrings("ready()", (try sourceFor(allocator, &node, "LoAd")).?);
    try std.testing.expect((try sourceFor(allocator, &node, "click")) == null);
}

test "inline event invocation preserves handler source and escapes event names" {
    const source = try buildInvocation(std.testing.allocator, .{
        .handle = 42,
        .event_type = "lo\"ad\n",
        .source = "return event.target === this;",
        .bubbles = true,
    });
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(
        "__dispatchInlineEventHandler(42,\"lo\\\"ad\\n\",function(event) {\nreturn event.target === this;\n},true)",
        source,
    );
}
