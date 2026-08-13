//! CSS selector representation, specificity, and DOM matching.
//!
//! Selectors own their normalized tag storage and borrow DOM nodes only for
//! the duration of matching.

const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;

/// CSS Selector types
pub const Selector = union(enum) {
    tag: TagSelector,
    tag_class: TagClassSelector,
    descendant: DescendantSelector,

    /// Check if this selector matches the given node
    /// ancestor_chain is a list of ancestor nodes to check for descendant selectors
    pub fn matches(self: Selector, node: *Node, ancestor_chain: []const *Node) bool {
        return switch (self) {
            .tag => |t| t.matches(node),
            .tag_class => |t| t.matches(node),
            .descendant => |d| d.matches(node, ancestor_chain),
        };
    }

    /// Free allocated memory for this selector
    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |*t| t.deinit(allocator),
            .tag_class => |*t| t.deinit(allocator),
            .descendant => |*d| d.deinit(allocator),
        }
    }

    /// Get the cascade priority of this selector
    /// Used for sorting rules - more specific selectors have higher priority
    pub fn priority(self: Selector) u32 {
        return switch (self) {
            .tag => |t| t.priority(),
            .tag_class => |t| t.priority(),
            .descendant => |d| d.priority(),
        };
    }
};

/// A class selector, optionally constrained to an element tag (for example,
/// `.links` or `nav.links`).
pub const TagClassSelector = struct {
    tag: ?[]const u8,
    class: []const u8,

    pub fn init(tag: ?[]const u8, class: []const u8) TagClassSelector {
        return .{ .tag = tag, .class = class };
    }

    fn matches(self: TagClassSelector, node: *Node) bool {
        const element = switch (node.*) {
            .element => |*value| value,
            .text => return false,
        };
        if (self.tag) |tag| {
            if (!std.mem.eql(u8, tag, element.tag)) return false;
        }
        const attributes = element.attributes orelse return false;
        const class_value = attributes.get("class") orelse return false;
        var classes = std.mem.tokenizeAny(u8, class_value, " \t\r\n\x0c");
        while (classes.next()) |class_name| {
            if (std.mem.eql(u8, self.class, class_name)) return true;
        }
        return false;
    }

    fn deinit(self: TagClassSelector, allocator: std.mem.Allocator) void {
        if (self.tag) |tag| allocator.free(tag);
        allocator.free(self.class);
    }

    fn priority(self: TagClassSelector) u32 {
        return if (self.tag == null) 10 else 11;
    }
};

/// Tag selector - matches elements by tag name (e.g., "p", "div", "ul")
pub const TagSelector = struct {
    tag: []const u8,

    pub fn init(tag: []const u8) TagSelector {
        return TagSelector{ .tag = tag };
    }

    /// Returns true if the node is an Element with matching tag
    fn matches(self: TagSelector, node: *Node) bool {
        return switch (node.*) {
            .element => |e| std.mem.eql(u8, self.tag, e.tag),
            .text => false,
        };
    }

    /// Free the allocated tag string
    fn deinit(self: TagSelector, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
    }

    /// Tag selectors have a priority of 1
    fn priority(self: TagSelector) u32 {
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
        errdefer allocator.destroy(ancestor_ptr);

        const descendant_ptr = try allocator.create(Selector);
        ancestor_ptr.* = ancestor;
        descendant_ptr.* = descendant;

        return DescendantSelector{
            .ancestor = ancestor_ptr,
            .descendant = descendant_ptr,
        };
    }

    fn deinit(self: DescendantSelector, allocator: std.mem.Allocator) void {
        // Recursively free the child selectors
        self.ancestor.deinit(allocator);
        self.descendant.deinit(allocator);
        // Free the pointers themselves
        allocator.destroy(self.ancestor);
        allocator.destroy(self.descendant);
    }

    /// Descendant selectors have a priority equal to the sum of their parts
    /// This makes more specific selectors (like "article div p") have higher priority
    fn priority(self: DescendantSelector) u32 {
        return self.ancestor.priority() + self.descendant.priority();
    }

    /// Returns true if:
    /// 1. The node matches the descendant selector, AND
    /// 2. The node has an ancestor that matches the ancestor selector
    fn matches(self: DescendantSelector, node: *Node, ancestor_chain: []const *Node) bool {
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
