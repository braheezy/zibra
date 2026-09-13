//! Bounded lowering of nesting selectors to the shared selector grammar.
//! Temporary source belongs to the caller; compiled selectors own their atoms.
const std = @import("std");
const tokens = @import("css_tokenizer.zig");
const syntax = @import("css_syntax.zig");
pub const max_bytes = 64 * 1024;
pub const Error = std.mem.Allocator.Error || error{ SelectorLimitExceeded, InvalidSelector };

pub fn hasParent(input: []const u8) bool {
    var iterator = tokens.Iterator{ .input = input };
    while (iterator.next()) |token| if (token.kind == .delim and token.delim == '&') return true;
    return false;
}

fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), input: []const u8) Error!void {
    if (input.len > max_bytes - output.items.len) return error.SelectorLimitExceeded;
    try output.appendSlice(allocator, input);
}

fn parentSelector(allocator: std.mem.Allocator, output: *std.ArrayList(u8), parent: ?[]const u8) Error!void {
    if (parent) |source| {
        try append(allocator, output, ":is(");
        try append(allocator, output, source);
        try append(allocator, output, ")");
    } else try append(allocator, output, ":where(:root)");
}

/// Replace real & tokens, including within logical selector functions. A
/// nested list member without & receives an implicit descendant/relative
/// prefix. :is() preserves the maximum specificity of the whole parent list.
/// Both input and expansion are bounded, preventing multiplicative growth
/// from repeated & at successive nesting levels.
pub fn lower(allocator: std.mem.Allocator, input: []const u8, parent: ?[]const u8) Error![]u8 {
    if (input.len > max_bytes) return error.SelectorLimitExceeded;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    var count: usize = 0;
    while (true) {
        const end = syntax.scanToTopLevel(input, cursor, ",");
        if (end.exhausted) return error.SelectorLimitExceeded;
        const member = input[cursor..end.end];
        var content_start: usize = 0;
        syntax.skipWhitespaceAndComments(member, &content_start);
        if (content_start == member.len) return error.InvalidSelector;
        if (count != 0) try append(allocator, &output, ",");
        count += 1;
        if (count > 256) return error.SelectorLimitExceeded;
        if (parent != null and !hasParent(member)) {
            try parentSelector(allocator, &output, parent);
            try append(allocator, &output, " ");
        }
        var iterator = tokens.Iterator{ .input = member };
        var copied: usize = 0;
        while (iterator.next()) |token| {
            if (token.kind != .delim or token.delim != '&') continue;
            try append(allocator, &output, member[copied..token.start]);
            try parentSelector(allocator, &output, parent);
            copied = token.end;
        }
        try append(allocator, &output, member[copied..]);
        if (end.delimiter == null) break;
        cursor = end.end + 1;
    }
    return output.toOwnedSlice(allocator);
}

test "nesting lowering preserves lexical ampersands lists and parent specificity" {
    const allocator = std.testing.allocator;
    const source = try lower(allocator, "&.active, > .child, :is(&, .sibling), [data-x='&'] .\\&", ".parent, #id");
    defer allocator.free(source);
    try std.testing.expectEqualStrings(":is(.parent, #id).active,:is(.parent, #id)  > .child, :is(:is(.parent, #id), .sibling),:is(.parent, #id)  [data-x='&'] .\\&", source);
    try std.testing.expectError(error.SelectorLimitExceeded, lower(allocator, "&&", "a" ** (max_bytes / 2)));
}
