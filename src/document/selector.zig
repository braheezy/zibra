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
    id: IdSelector,
    focus_visible: FocusVisibleSelector,
    hover: HoverSelector,
    sequence: SelectorSequence,
    has: HasSelector,
    descendant: DescendantSelector,

    /// Check if this selector matches the given node. `ancestor_chain` must be
    /// ordered from the root element to the node's immediate parent.
    pub fn matches(self: Selector, node: *Node, ancestor_chain: []const *Node) bool {
        return self.matchesWithContext(node, ancestor_chain, .{});
    }

    pub fn matchesWithContext(
        self: Selector,
        node: *Node,
        ancestor_chain: []const *Node,
        context: MatchContext,
    ) bool {
        return switch (self) {
            .tag => |t| t.matches(node),
            .class => |c| c.matches(node),
            .id => |id| id.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
            .sequence => |s| s.matches(node),
            .has => |h| h.matches(node, context),
            .descendant => |d| d.matches(node, ancestor_chain, context),
        };
    }

    /// Populate all relational-selector matches needed by this selector.
    pub fn populateHasMatches(
        self: Selector,
        cache: *HasMatchCache,
        root: *Node,
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .has => |has| try has.populateMatches(cache, root),
            .descendant => |descendant| try descendant.populateHasMatches(cache, root),
            else => {},
        }
    }

    /// Free allocated memory for this selector
    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |*t| t.deinit(allocator),
            .class => |*c| c.deinit(allocator),
            .id => |*id| id.deinit(allocator),
            .focus_visible => {},
            .hover => {},
            .sequence => |*s| s.deinit(allocator),
            .has => |*h| h.deinit(allocator),
            .descendant => |*d| d.deinit(allocator),
        }
    }

    /// Get the cascade priority of this selector
    /// Used for sorting rules - more specific selectors have higher priority
    pub fn priority(self: Selector) u32 {
        return switch (self) {
            .tag => |t| t.priority(),
            .class => |c| c.priority(),
            .id => |id| id.priority(),
            .focus_visible => |focus_visible| focus_visible.priority(),
            .hover => |hover| hover.priority(),
            .sequence => |s| s.priority(),
            .has => |h| h.priority(),
            .descendant => |d| d.priority(),
        };
    }
};

/// A non-combinator selector. Descendant selectors store these directly so a
/// selector chain is flat rather than a recursively nested binary tree.
pub const SimpleSelector = union(enum) {
    tag: TagSelector,
    class: ClassSelector,
    id: IdSelector,
    focus_visible: FocusVisibleSelector,
    hover: HoverSelector,
    sequence: SelectorSequence,
    has: HasSelector,

    pub fn intoSelector(self: SimpleSelector) Selector {
        return switch (self) {
            .tag => |tag| .{ .tag = tag },
            .class => |class| .{ .class = class },
            .id => |id| .{ .id = id },
            .focus_visible => |focus_visible| .{ .focus_visible = focus_visible },
            .hover => |hover| .{ .hover = hover },
            .sequence => |sequence| .{ .sequence = sequence },
            .has => |has| .{ .has = has },
        };
    }

    fn matches(self: SimpleSelector, node: *Node, context: MatchContext) bool {
        return switch (self) {
            .tag => |tag| tag.matches(node),
            .class => |class| class.matches(node),
            .id => |id| id.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
            .sequence => |sequence| sequence.matches(node),
            .has => |has| has.matches(node, context),
        };
    }

    fn populateHasMatches(
        self: SimpleSelector,
        cache: *HasMatchCache,
        root: *Node,
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .has => |has| try has.populateMatches(cache, root),
            else => {},
        }
    }

    pub fn deinit(self: *SimpleSelector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |*tag| tag.deinit(allocator),
            .class => |*class| class.deinit(allocator),
            .id => |*id| id.deinit(allocator),
            .focus_visible => {},
            .hover => {},
            .sequence => |*sequence| sequence.deinit(allocator),
            .has => |*has| has.deinit(allocator),
        }
    }

    fn priority(self: SimpleSelector) u32 {
        return switch (self) {
            .tag => |tag| tag.priority(),
            .class => |class| class.priority(),
            .id => |id| id.priority(),
            .focus_visible => |focus_visible| focus_visible.priority(),
            .hover => |hover| hover.priority(),
            .sequence => |sequence| sequence.priority(),
            .has => |has| has.priority(),
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

/// An ID selector such as `#main`. HTML ID matching is case-sensitive and an
/// ID contributes the selector specificity's hundreds component.
pub const IdSelector = struct {
    id: []const u8,

    pub fn init(id: []const u8) IdSelector {
        return .{ .id = id };
    }

    fn matches(self: IdSelector, node: *Node) bool {
        const element = switch (node.*) {
            .element => |*value| value,
            .text => return false,
        };
        const attributes = element.attributes orelse return false;
        return std.mem.eql(u8, self.id, attributes.get("id") orelse return false);
    }

    fn deinit(self: IdSelector, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }

    fn priority(self: IdSelector) u32 {
        _ = self;
        return 100;
    }
};

/// The dynamic `:focus-visible` pseudo-class. The Tab installs both focus
/// bits as one serialized DOM transition, and style invalidation rematches
/// this selector before the next paint.
pub const FocusVisibleSelector = struct {
    fn matches(self: FocusVisibleSelector, node: *Node) bool {
        _ = self;
        return switch (node.*) {
            .element => |element| element.is_focused and element.is_focus_visible,
            .text => false,
        };
    }

    fn priority(self: FocusVisibleSelector) u32 {
        _ = self;
        return 10;
    }
};

/// The dynamic `:hover` pseudo-class. Pointer hit resolution marks the
/// innermost hovered element and its element ancestors, matching the browser
/// behavior where a parent remains hovered while the pointer is over a child.
pub const HoverSelector = struct {
    fn matches(self: HoverSelector, node: *Node) bool {
        _ = self;
        return switch (node.*) {
            .element => |element| element.is_hovered,
            .text => false,
        };
    }

    fn priority(self: HoverSelector) u32 {
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
/// of its tag, ID, class, and supported pseudo-class members match the same
/// element.
pub const SequenceSelector = union(enum) {
    tag: TagSelector,
    class: ClassSelector,
    id: IdSelector,
    focus_visible: FocusVisibleSelector,
    hover: HoverSelector,

    pub fn intoSimpleSelector(self: SequenceSelector) SimpleSelector {
        return switch (self) {
            .tag => |tag| .{ .tag = tag },
            .class => |class| .{ .class = class },
            .id => |id| .{ .id = id },
            .focus_visible => |focus_visible| .{ .focus_visible = focus_visible },
            .hover => |hover| .{ .hover = hover },
        };
    }

    fn matches(self: SequenceSelector, node: *Node) bool {
        return switch (self) {
            .tag => |tag| tag.matches(node),
            .class => |class| class.matches(node),
            .id => |id| id.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
        };
    }

    pub fn deinit(self: *SequenceSelector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tag => |*tag| tag.deinit(allocator),
            .class => |*class| class.deinit(allocator),
            .id => |*id| id.deinit(allocator),
            .focus_visible => {},
            .hover => {},
        }
    }

    fn priority(self: SequenceSelector) u32 {
        return switch (self) {
            .tag => |tag| tag.priority(),
            .class => |class| class.priority(),
            .id => |id| id.priority(),
            .focus_visible => |focus_visible| focus_visible.priority(),
            .hover => |hover| hover.priority(),
        };
    }
};

/// Concatenated compound selectors, such as
/// `span.announce.urgent:focus-visible`.
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

pub const MatchContext = struct {
    has_cache: ?*const HasMatchCache = null,
};

const HasMatchKey = struct {
    selector: *const SimpleSelector,
    node: *const Node,
};

/// Ephemeral matches for relational selectors. A post-order pass records each
/// ancestor whose strict subtree contains the requested selector, allowing
/// subsequent `:has` checks to use an average-O(1) hash lookup.
pub const HasMatchCache = struct {
    matches: std.AutoHashMap(HasMatchKey, void),
    prepared: std.AutoHashMap(*const SimpleSelector, void),

    pub fn init(allocator: std.mem.Allocator) HasMatchCache {
        return .{
            .matches = std.AutoHashMap(HasMatchKey, void).init(allocator),
            .prepared = std.AutoHashMap(*const SimpleSelector, void).init(allocator),
        };
    }

    pub fn deinit(self: *HasMatchCache) void {
        self.matches.deinit();
        self.prepared.deinit();
    }

    fn isPrepared(self: *const HasMatchCache, selector: *const SimpleSelector) bool {
        return self.prepared.contains(selector);
    }

    fn contains(self: *const HasMatchCache, selector: *const SimpleSelector, node: *const Node) bool {
        return self.matches.contains(.{ .selector = selector, .node = node });
    }

    fn populate(
        self: *HasMatchCache,
        root: *Node,
        has: HasSelector,
    ) std.mem.Allocator.Error!void {
        if (self.isPrepared(has.descendant)) return;
        _ = try self.visit(root, has);
        try self.prepared.put(has.descendant, {});
    }

    /// Return whether `node` or any of its descendants matches the relational
    /// selector's descendant component. Only child results qualify `node`
    /// itself, preserving the strict-descendant semantics of `:has`.
    fn visit(
        self: *HasMatchCache,
        node: *Node,
        has: HasSelector,
    ) std.mem.Allocator.Error!bool {
        const context = MatchContext{ .has_cache = self };
        var child_contains_match = false;
        switch (node.*) {
            .text => {},
            .element => |*element| {
                for (element.children.items) |*child| {
                    if (try self.visit(child, has)) child_contains_match = true;
                }
            },
        }

        if (child_contains_match and has.ancestor.matches(node, context)) {
            try self.matches.put(.{ .selector = has.descendant, .node = node }, {});
        }
        return child_contains_match or has.descendant.matches(node, context);
    }
};

/// An ancestor selector constrained by the presence of a matching strict
/// descendant, such as `div.card:has(span.badge)`.
pub const HasSelector = struct {
    ancestor: *SimpleSelector,
    descendant: *SimpleSelector,

    pub fn init(
        allocator: std.mem.Allocator,
        ancestor: SimpleSelector,
        descendant: SimpleSelector,
    ) !HasSelector {
        const ancestor_ptr = try allocator.create(SimpleSelector);
        errdefer allocator.destroy(ancestor_ptr);
        const descendant_ptr = try allocator.create(SimpleSelector);

        ancestor_ptr.* = ancestor;
        descendant_ptr.* = descendant;
        return .{ .ancestor = ancestor_ptr, .descendant = descendant_ptr };
    }

    fn deinit(self: *HasSelector, allocator: std.mem.Allocator) void {
        self.ancestor.deinit(allocator);
        self.descendant.deinit(allocator);
        allocator.destroy(self.ancestor);
        allocator.destroy(self.descendant);
    }

    fn priority(self: HasSelector) u32 {
        return self.ancestor.priority() + self.descendant.priority();
    }

    fn matches(self: HasSelector, node: *Node, context: MatchContext) bool {
        if (!self.ancestor.matches(node, context)) return false;
        if (context.has_cache) |cache| {
            if (cache.isPrepared(self.descendant)) {
                return cache.contains(self.descendant, node);
            }
        }
        return self.hasMatchingDescendant(node, context);
    }

    fn hasMatchingDescendant(self: HasSelector, node: *Node, context: MatchContext) bool {
        const element = switch (node.*) {
            .text => return false,
            .element => |*value| value,
        };
        for (element.children.items) |*child| {
            if (self.descendant.matches(child, context) or
                self.hasMatchingDescendant(child, context))
            {
                return true;
            }
        }
        return false;
    }

    fn populateMatches(
        self: HasSelector,
        cache: *HasMatchCache,
        root: *Node,
    ) std.mem.Allocator.Error!void {
        try self.ancestor.populateHasMatches(cache, root);
        try self.descendant.populateHasMatches(cache, root);
        try cache.populate(root, self);
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

    fn populateHasMatches(
        self: DescendantSelector,
        cache: *HasMatchCache,
        root: *Node,
    ) std.mem.Allocator.Error!void {
        for (self.selectors.items) |selector| {
            try selector.populateHasMatches(cache, root);
        }
    }

    /// Match the rightmost selector against `node`, then walk both the
    /// selector chain and the root-to-parent ancestor chain backward. Each
    /// selector and ancestor is advanced at most once, making this O(n + d).
    fn matches(
        self: DescendantSelector,
        node: *Node,
        ancestor_chain: []const *Node,
        context: MatchContext,
    ) bool {
        const selectors = self.selectors.items;
        if (selectors.len < 2) return false;

        var selector_index = selectors.len - 1;
        if (!selectors[selector_index].matches(node, context)) return false;

        var ancestor_index = ancestor_chain.len;
        while (selector_index > 0 and ancestor_index > 0) {
            ancestor_index -= 1;
            if (selectors[selector_index - 1].matches(ancestor_chain[ancestor_index], context)) {
                selector_index -= 1;
            }
        }
        return selector_index == 0;
    }
};
