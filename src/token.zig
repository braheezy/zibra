const std = @import("std");

pub const TokenType = enum {
    text,
    tag,
};

pub const Tag = struct {
    is_closing: bool = false,
    name: []const u8,
    attributes: ?std.StringHashMap([]const u8),

    pub fn init(al: std.mem.Allocator, raw: []const u8) !*Tag {
        const tag = try al.create(Tag);
        tag.is_closing = false;
        tag.attributes = null;
        try tag.parse(al, raw);
        return tag;
    }

    pub fn deinit(self: *Tag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);

        if (self.attributes) |attributes| {
            var it = attributes.iterator();
            while (it.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                allocator.free(kv.value_ptr.*);
            }
            var attr = attributes;
            attr.deinit();
        }
        allocator.destroy(self);
    }

    /// Given a raw tag string (for example, "h1 class="title"") parse out
    /// the tag name and its attributes.
    /// The raw string is assumed to have been duplicated already, owned by this call.
    pub fn parse(self: *Tag, al: std.mem.Allocator, raw: []const u8) !void {
        var idx: usize = 0;
        // Skip any leading whitespace.
        while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}

        if (idx < raw.len and raw[idx] == '/') {
            self.is_closing = true;
            idx += 1;
        }

        // Parse the tag name: read until whitespace.
        const start_name = idx;
        while (idx < raw.len and !std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
        const tag_name_slice = raw[start_name..idx];
        const tag_name = try al.dupe(u8, tag_name_slice);
        self.name = tag_name;

        // Parse attributes (if any)
        while (idx < raw.len) {
            // Skip whitespace.
            while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
            if (idx >= raw.len) break;

            // Capture attribute name.
            const attr_start = idx;
            while (idx < raw.len and raw[idx] != '=' and !std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
            const attr_name_slice = raw[attr_start..idx];

            // Skip whitespace until '='.
            while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
            if (idx >= raw.len or raw[idx] != '=') {
                // If no '=', skip this attribute.
                continue;
            }
            idx += 1; // skip '='
            // Skip whitespace.
            while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
            if (idx >= raw.len) break;

            // Expect a quoted value.
            const quote = raw[idx];
            if (quote != '"' and quote != '\'') {
                // Skip unsupported unquoted attribute value.
                while (idx < raw.len and !std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
                continue;
            }
            idx += 1; // skip opening quote

            const value_start = idx;
            while (idx < raw.len and raw[idx] != quote) : (idx += 1) {}
            if (idx >= raw.len) {
                std.log.info("Invalid attribute format: {s}", .{raw});
                return error.InvalidAttributeFormat;
            }
            const attr_value_slice = raw[value_start..idx];
            idx += 1; // skip closing quote

            if (self.attributes == null) {
                self.attributes = std.StringHashMap([]const u8).init(al);
            }

            // Duplicate keys and values so the Tag assumes ownership.
            const key_dup = try al.dupe(u8, attr_name_slice);
            const value_dup = try al.dupe(u8, attr_value_slice);
            try self.attributes.?.put(key_dup, value_dup);
        }
    }
};

pub const Token = union(TokenType) {
    text: []const u8,
    tag: *Tag,

    pub fn deinit(self: Token, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => allocator.free(self.text),
            .tag => self.tag.deinit(allocator),
        }
    }
};

pub fn printTokens(tokens: []const Token) void {
    for (tokens) |tok| {
        const content = switch (tok) {
            .text => tok.text,
            .tag => tok.tag.name,
        };
        std.log.info("Token type: {s}, text: {s}", .{ @tagName(tok), content });
    }
}
