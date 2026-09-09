//! Inspection-owned inline declaration cache. Keys and maps borrow retained
//! blocks; the provider is only a synchronous borrow during a style pass.

const std = @import("std");
const dom = @import("dom.zig");
const stylesheet = @import("css_stylesheet.zig");
const style = @import("style.zig");
const CSSParser = @import("css_parser.zig").CSSParser;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(stylesheet.DeclarationBlock) = .empty,
    indices: std.StringHashMap(usize),

    /// Owns parsed copies of all current authored style attributes. Rebuild
    /// before styling after attribute mutation; duplicate text shares a block.
    pub fn init(allocator: std.mem.Allocator, root: *dom.Node) !Cache {
        var cache = Cache{ .allocator = allocator, .indices = std.StringHashMap(usize).init(allocator) };
        errdefer cache.deinit();
        try cache.collect(root);
        return cache;
    }

    pub fn deinit(self: *Cache) void {
        self.indices.deinit();
        for (self.blocks.items) |*block| block.deinit();
        self.blocks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn provider(self: *const Cache) style.InlineStyleProvider {
        return .{ .context = self, .get = lookup };
    }

    fn lookup(context: *const anyopaque, source: []const u8) ?*const CSSParser.DeclarationMap {
        const self: *const Cache = @ptrCast(@alignCast(context));
        const index = self.indices.get(source) orelse return null;
        return &self.blocks.items[index].properties;
    }

    fn collect(self: *Cache, node: *dom.Node) anyerror!void {
        switch (node.*) {
            .text => {},
            .element => |*element| {
                if (element.attributes) |attributes| {
                    if (attributes.get("style")) |source| {
                        if (!self.indices.contains(source)) {
                            var block = try stylesheet.DeclarationBlock.parse(self.allocator, source, .{});
                            errdefer block.deinit();
                            try self.blocks.ensureUnusedCapacity(self.allocator, 1);
                            try self.indices.put(block.source(), self.blocks.items.len);
                            self.blocks.appendAssumeCapacity(block);
                        }
                    }
                }
                for (element.children.items) |*child| try self.collect(child);
            },
        }
    }
};
