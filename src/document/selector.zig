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
    class: ClassSelector,
    sequence: SelectorSequence,
    descendant: DescendantSelector,

    /// Check if this selector matches the given node. `ancestor_chain` must be
    /// ordered from the root element to the node's immediate parent.
    pub fn matches(self: Selector, node: *Node, ancestor_chain: []const *Node) bool {
        return switch (self) {
            .tag => |t| t.matches(node),
            .class => |c| c.matches(node),
            .sequence => |s| s.matches(node),
            .descendant => |d| d.matches(node, ancestor_chain),
        };
    }

    /// Free allocated memory for this selector
    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |*t| t.deinit(allocator),
            .class => |*c| c.deinit(allocator),
            .sequence => |*s| s.deinit(allocator),
            .descendant => |*d| d.deinit(allocator),
        }
    }

    /// Get the cascade priority of this selector
    /// Used for sorting rules - more specific selectors have higher priority
    pub fn priority(self: Selector) u32 {
        return switch (self) {
            .tag => |t| t.priority(),
            .class => |c| c.priority(),
            .sequence => |s| s.priority(),
            .descendant => |d| d.priority(),
        };
    }
};

/// A non-combinator selector. Descendant selectors store these directly so a
/// selector chain is flat rather than a recursively nested binary tree.
pub const SimpleSelector = union(enum) {
    tag: TagSelector,
    class: ClassSelector,
    sequence: SelectorSequence,

    pub fn intoSelector(self: SimpleSelector) Selector {
        return switch (self) {
            .tag => |tag| .{ .tag = tag },
            .class => |class| .{ .class = class },
            .sequence => |sequence| .{ .sequence = sequence },
        };
    }

    fn matches(self: SimpleSelector, node: *Node) bool {
        return switch (self) {
            .tag => |tag| tag.matches(node),
            .class => |class| class.matches(node),
            .sequence => |sequence| sequence.matches(node),
        };
    }

    pub fn deinit(self: *SimpleSelector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |*tag| tag.deinit(allocator),
            .class => |*class| class.deinit(allocator),
            .sequence => |*sequence| sequence.deinit(allocator),
        }
    }

    fn priority(self: SimpleSelector) u32 {
        return switch (self) {
            .tag => |tag| tag.priority(),
            .class => |class| class.priority(),
            .sequence => |sequence| sequence.priority(),
        };
    }
};

/// A class selector such as `.links`.
pub const ClassSelector = struct {
    class: []const u8,

    pub fn init(class: []const u8) ClassSelector {
        return .{ .class = class };
    }

    fn matches(self: ClassSelector, node: *Node) bool {
        const element = switch (node.*) {
            .element => |*value| value,
            .text => return false,
        };
        const attributes = element.attributes orelse return false;
        const class_value = attributes.get("class") orelse return false;
        var classes = std.mem.tokenizeAny(u8, class_value, " \t\r\n\x0c");
        while (classes.next()) |class_name| {
            if (std.mem.eql(u8, self.class, class_name)) return true;
        }
        return false;
    }

    fn deinit(self: ClassSelector, allocator: std.mem.Allocator) void {
        allocator.free(self.class);
    }

    fn priority(self: ClassSelector) u32 {
        _ = self;
        return 10;
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

/// One atomic member of a selector sequence. A sequence matches only when all
/// of its tag and class members match the same element.
pub const SequenceSelector = union(enum) {
    tag: TagSelector,
    class: ClassSelector,

    pub fn intoSimpleSelector(self: SequenceSelector) SimpleSelector {
        return switch (self) {
            .tag => |tag| .{ .tag = tag },
            .class => |class| .{ .class = class },
        };
    }

    fn matches(self: SequenceSelector, node: *Node) bool {
        return switch (self) {
            .tag => |tag| tag.matches(node),
            .class => |class| class.matches(node),
        };
    }

    pub fn deinit(self: *SequenceSelector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |*tag| tag.deinit(allocator),
            .class => |*class| class.deinit(allocator),
        }
    }

    fn priority(self: SequenceSelector) u32 {
        return switch (self) {
            .tag => |tag| tag.priority(),
            .class => |class| class.priority(),
        };
    }
};

/// Concatenated tag/class selectors, such as `span.announce.urgent`.
pub const SelectorSequence = struct {
    selectors: std.ArrayList(SequenceSelector),

    /// Take ownership of a parser-built sequence containing at least two
    /// atomic selectors. Single selectors retain their direct representation.
    pub fn take(selectors: *std.ArrayList(SequenceSelector)) SelectorSequence {
        std.debug.assert(selectors.items.len >= 2);
        const owned_selectors = selectors.*;
        selectors.* = .empty;
        return .{ .selectors = owned_selectors };
    }

    fn deinit(self: *SelectorSequence, allocator: std.mem.Allocator) void {
        for (self.selectors.items) |*selector| selector.deinit(allocator);
        self.selectors.deinit(allocator);
        self.selectors = .empty;
    }

    fn matches(self: SelectorSequence, node: *Node) bool {
        for (self.selectors.items) |selector| {
            if (!selector.matches(node)) return false;
        }
        return true;
    }

    /// Sequence specificity is the sum of the member specificities.
    fn priority(self: SelectorSequence) u32 {
        var total: u32 = 0;
        for (self.selectors.items) |selector| total += selector.priority();
        return total;
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
