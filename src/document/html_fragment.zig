//! Owned, inert HTML fragments over the shared one-shot HTML tree builder.
//! The source owner must outlive every node transferred out of the result.
const std = @import("std");
const dom = @import("dom.zig");
const Parser = @import("html_parser.zig").Parser(dom.Node, dom.Element, dom.Text, dom.fixParentPointers);

pub const Result = struct {
    source: []u8,
    root: dom.Node,
};

/// Return an owning root and source separately so a Realm can retain the source
/// even after children leave the temporary root. Caller destroys root first.
pub fn parse(allocator: std.mem.Allocator, input: []const u8, context: []const u8) !Result {
    const source = try allocator.dupe(u8, input);
    errdefer allocator.free(source);
    const parser = try Parser.init(allocator, source);
    defer parser.deinit(allocator);
    var root = try parser.parseFragment(context);
    markScriptsInert(&root);
    return .{ .source = source, .root = root };
}

fn markScriptsInert(node: *dom.Node) void {
    switch (node.*) {
        .text => {},
        .element => |*element| {
            if (std.ascii.eqlIgnoreCase(element.tag, "script")) element.script_started = true;
            for (element.children.items) |*child| markScriptsInert(child);
        },
    }
}
