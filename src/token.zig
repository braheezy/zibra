const std = @import("std");

pub const TokenType = enum {
    text,
    tag,
};

pub const Tag = struct {
    is_closing: bool = false,
    name: []const u8,
    attributes: std.StringHashMap([]const u8),

    pub fn init(al: std.mem.Allocator, name: []const u8) !*Tag {
        const attributes = std.StringHashMap([]const u8).init(al);
        const tag = try al.create(Tag);
        tag.* = Tag{ .name = name, .attributes = attributes };
        return tag;
    }

    pub fn deinit(self: *Tag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);

        var it = self.attributes.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        var attributes = self.attributes;
        attributes.deinit();
        allocator.destroy(self);
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
