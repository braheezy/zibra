//! CSS selector representation, specificity, and DOM matching.
//!
//! Selectors own their normalized tag storage and borrow DOM nodes only for
//! the duration of matching.

const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;

/// CSS selector types.
pub const Selector = union(enum) {
    tag: TagSelector,
    tag_class: TagClassSelector,
    descendant: DescendantSelector,

    /// Check if this selector matches the given node. `ancestor_chain` must be
    /// ordered from the root element to the node's immediate parent.
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

/// A non-combinator selector. Descendant selectors store these directly so a
/// selector chain is flat rather than a recursively nested binary tree.
pub const SimpleSelector = union(enum) {
    tag: TagSelector,
    tag_class: TagClassSelector,

    pub fn intoSelector(self: SimpleSelector) Selector {
        return switch (self) {
            .tag => |tag| .{ .tag = tag },
            .tag_class => |tag_class| .{ .tag_class = tag_class },
        };
    }

    fn matches(self: SimpleSelector, node: *Node) bool {
        return switch (self) {
            .tag => |tag| tag.matches(node),
            .tag_class => |tag_class| tag_class.matches(node),
        };
    }

    pub fn deinit(self: *SimpleSelector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |tag| tag.deinit(allocator),
            .tag_class => |tag_class| tag_class.deinit(allocator),
        }
    }

    fn priority(self: SimpleSelector) u32 {
        return switch (self) {
            .tag => |tag| tag.priority(),
            .tag_class => |tag_class| tag_class.priority(),
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

/// A whitespace-separated chain of simple selectors. For example,
/// `article div p` matches a `p` with a `div` ancestor that in turn has an
/// `article` ancestor. The flat representation permits a single ancestor walk.
pub const DescendantSelector = struct {
    selectors: std.ArrayList(SimpleSelector),

    /// Take ownership of a parser-built chain containing at least two simple
    /// selectors. The caller's list is reset so it cannot free the moved data.
    pub fn take(selectors: *std.ArrayList(SimpleSelector)) DescendantSelector {
        std.debug.assert(selectors.items.len >= 2);
        const owned_selectors = selectors.*;
        selectors.* = .empty;
        return .{ .selectors = owned_selectors };
    }

    fn deinit(self: *DescendantSelector, allocator: std.mem.Allocator) void {
        for (self.selectors.items) |*selector| selector.deinit(allocator);
        self.selectors.deinit(allocator);
        self.selectors = .empty;
    }

    /// Descendant selectors have a priority equal to the sum of their parts.
    fn priority(self: DescendantSelector) u32 {
        var total: u32 = 0;
        for (self.selectors.items) |selector| total += selector.priority();
        return total;
    }

    /// Match the rightmost selector against `node`, then walk both the
    /// selector chain and the root-to-parent ancestor chain backward. Each
    /// selector and ancestor is advanced at most once, making this O(n + d).
    fn matches(self: DescendantSelector, node: *Node, ancestor_chain: []const *Node) bool {
        const selectors = self.selectors.items;
        if (selectors.len < 2) return false;

        var selector_index = selectors.len - 1;
        if (!selectors[selector_index].matches(node)) return false;

        var ancestor_index = ancestor_chain.len;
        while (selector_index > 0 and ancestor_index > 0) {
            ancestor_index -= 1;
            if (selectors[selector_index - 1].matches(ancestor_chain[ancestor_index])) {
                selector_index -= 1;
            }
        }
        return selector_index == 0;
    }
};
