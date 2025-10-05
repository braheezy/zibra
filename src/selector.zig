const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;

/// CSS Selector types
pub const Selector = union(enum) {
    tag: TagSelector,
    descendant: DescendantSelector,

    /// Check if this selector matches the given node
    /// ancestor_chain is a list of ancestor nodes to check for descendant selectors
    pub fn matches(self: Selector, node: *Node, ancestor_chain: []const *Node) bool {
        return switch (self) {
            .tag => |t| t.matches(node),
            .descendant => |d| d.matches(node, ancestor_chain),
        };
    }

    /// Free allocated memory for this selector
    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |*t| t.deinit(allocator),
            .descendant => |*d| d.deinit(allocator),
        }
    }

    /// Get the cascade priority of this selector
    /// Used for sorting rules - more specific selectors have higher priority
    pub fn priority(self: Selector) u32 {
        return switch (self) {
            .tag => |t| t.priority(),
            .descendant => |d| d.priority(),
        };
    }
};

/// Tag selector - matches elements by tag name (e.g., "p", "div", "ul")
pub const TagSelector = struct {
    tag: []const u8,

    pub fn init(tag: []const u8) TagSelector {
        return TagSelector{ .tag = tag };
    }

    /// Returns true if the node is an Element with matching tag
    pub fn matches(self: TagSelector, node: *Node) bool {
        return switch (node.*) {
            .element => |e| std.mem.eql(u8, self.tag, e.tag),
            .text => false,
        };
    }

    /// Free the allocated tag string
    pub fn deinit(self: TagSelector, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
    }

    /// Tag selectors have a priority of 1
    pub fn priority(self: TagSelector) u32 {
        _ = self;
        return 1;
    }
};

/// Descendant selector - matches elements with a specific ancestor
/// (e.g., "article div" matches div elements inside article elements)
/// Associates to the left: "a b c" means (a b) c
pub const DescendantSelector = struct {
    ancestor: *Selector,
    descendant: *Selector,

    pub fn init(allocator: std.mem.Allocator, ancestor: Selector, descendant: Selector) !DescendantSelector {
        const ancestor_ptr = try allocator.create(Selector);
        ancestor_ptr.* = ancestor;

        const descendant_ptr = try allocator.create(Selector);
        descendant_ptr.* = descendant;

        return DescendantSelector{
            .ancestor = ancestor_ptr,
            .descendant = descendant_ptr,
        };
    }

    pub fn deinit(self: DescendantSelector, allocator: std.mem.Allocator) void {
        // Recursively free the child selectors
        self.ancestor.deinit(allocator);
        self.descendant.deinit(allocator);
        // Free the pointers themselves
        allocator.destroy(self.ancestor);
        allocator.destroy(self.descendant);
    }

    /// Descendant selectors have a priority equal to the sum of their parts
    /// This makes more specific selectors (like "article div p") have higher priority
    pub fn priority(self: DescendantSelector) u32 {
        return self.ancestor.priority() + self.descendant.priority();
    }

    /// Returns true if:
    /// 1. The node matches the descendant selector, AND
    /// 2. The node has an ancestor that matches the ancestor selector
    pub fn matches(self: DescendantSelector, node: *Node, ancestor_chain: []const *Node) bool {
        // First check if this node matches the descendant part
        if (!self.descendant.matches(node, ancestor_chain)) {
            return false;
        }

        // Then check if any ancestor in the chain matches the ancestor selector
        for (ancestor_chain) |ancestor| {
            if (self.ancestor.matches(ancestor, &[_]*Node{})) {
                return true;
            }
        }

        return false;
    }
};
