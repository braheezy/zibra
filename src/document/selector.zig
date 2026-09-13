//! CSS selector representation, specificity, and DOM matching.
//!
//! Selectors own their normalized names, arguments, component trees and
//! combinators. Clones own independent storage. DOM nodes are borrowed only
//! for the duration of matching.

const std = @import("std");
const dom = @import("dom.zig");
const pseudo = @import("pseudo.zig");
const Node = dom.Node;
pub const Specificity = @import("css_cascade.zig").Specificity;

// Matching borrows either the caller's root-to-parent slice or a stack link
// during :has traversal. Links never escape a synchronous recursive call.
const Ancestry = union(enum) {
    slice: []const *Node,
    link: *const Link,

    const Link = struct { node: *Node, parent: Ancestry };

    fn last(self: Ancestry) ?*Node {
        return switch (self) {
            .slice => |nodes| if (nodes.len == 0) null else nodes[nodes.len - 1],
            .link => |link| link.node,
        };
    }

    fn parent(self: Ancestry) Ancestry {
        return switch (self) {
            .slice => |nodes| .{ .slice = nodes[0 .. nodes.len - @intFromBool(nodes.len != 0)] },
            .link => |link| link.parent,
        };
    }
};

fn generatedPseudoHost(node: *Node) ?*Node {
    const element = switch (node.*) {
        .element => |*value| value,
        .text => return null,
    };
    if (element.generated_kind == null) return null;

    const host = element.parent orelse return null;
    return switch (host.*) {
        .element => host,
        .text => null,
    };
}

/// Generated pseudo boxes are private nodes whose `parent` names the authored
/// host element. Ordinary selector atoms inspect that host, while the
/// pseudo-element atom below still distinguishes `::before` from `::after`.
fn publicHostNode(node: *Node) *Node {
    return generatedPseudoHost(node) orelse node;
}

/// Generated pseudo styling receives an ancestor chain ending in its host,
/// but selector combinators conceptually start at that host. Remove the host
/// from relationship traversal so it cannot satisfy its own ancestor, child,
/// or sibling selector.
fn relationshipAncestors(node: *Node, ancestor_chain: Ancestry) Ancestry {
    const host = generatedPseudoHost(node) orelse return ancestor_chain;
    if (ancestor_chain.last() == host) {
        return ancestor_chain.parent();
    }
    return ancestor_chain;
}

/// CSS selector types.
pub const Selector = union(enum) {
    universal: UniversalSelector,
    tag: TagSelector,
    class: ClassSelector,
    id: IdSelector,
    attribute: AttributeSelector,
    focus_visible: FocusVisibleSelector,
    hover: HoverSelector,
    structural: StructuralSelector,
    logical: LogicalSelector,
    state: StateSelector,
    pseudo_element: PseudoElementSelector,
    sequence: SelectorSequence,
    has: HasSelector,
    descendant: DescendantSelector,
    complex: ComplexSelector,

    /// Deep-copy every owned name, argument, component and combinator. The
    /// returned selector owns independent storage; no matching cache or DOM
    /// borrow is retained. On allocation failure the original is unchanged.
    pub fn clone(self: Selector, allocator: std.mem.Allocator) std.mem.Allocator.Error!Selector {
        return cloneSelectorUnion(Selector, self, allocator);
    }

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
        return self.matchesWithin(node, .{ .slice = ancestor_chain }, context);
    }

    fn matchesWithin(self: Selector, node: *Node, ancestor_chain: Ancestry, context: MatchContext) bool {
        return switch (self) {
            .universal => |universal| universal.matches(node),
            .tag => |t| t.matches(node),
            .class => |c| c.matches(node),
            .id => |id| id.matches(node),
            .attribute => |attribute| attribute.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
            .structural => |structural| structural.matches(node),
            .logical => |logical| logical.matches(node, ancestor_chain, context),
            .state => |state| state.matches(node),
            .pseudo_element => |pseudo_element| pseudo_element.matches(node),
            .sequence => |s| s.matches(node, ancestor_chain, context),
            .has => |h| h.matches(node, ancestor_chain, context),
            .descendant => |d| d.matches(node, ancestor_chain, context),
            .complex => |complex| complex.matches(node, ancestor_chain, context),
        };
    }

    /// Populate all relational-selector matches needed by this selector.
    pub fn populateHasMatches(
        self: Selector,
        cache: *HasMatchCache,
        root: *Node,
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .logical => |logical| try logical.populateHasMatches(cache, root),
            .sequence => |sequence| try sequence.populateHasMatches(cache, root),
            .has => |has| try has.populateMatches(cache, root),
            .descendant => |descendant| try descendant.populateHasMatches(cache, root),
            .complex => |complex| try complex.populateHasMatches(cache, root),
            else => {},
        }
    }

    /// Free allocated memory for this selector
    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .universal => {},
            .tag => |*t| t.deinit(allocator),
            .class => |*c| c.deinit(allocator),
            .id => |*id| id.deinit(allocator),
            .attribute => |*attribute| attribute.deinit(allocator),
            .focus_visible => {},
            .hover => {},
            .structural => |*structural| structural.deinit(allocator),
            .logical => |*logical| logical.deinit(allocator),
            .state => {},
            .pseudo_element => {},
            .sequence => |*s| s.deinit(allocator),
            .has => |*h| h.deinit(allocator),
            .descendant => |*d| d.deinit(allocator),
            .complex => |*complex| complex.deinit(allocator),
        }
    }

    /// Count ID, class/attribute/pseudo-class and type/pseudo-element components.
    pub fn specificity(self: Selector) Specificity {
        return switch (self) {
            .universal => |universal| universal.specificity(),
            .tag => |t| t.specificity(),
            .class => |c| c.specificity(),
            .id => |id| id.specificity(),
            .attribute => |attribute| attribute.specificity(),
            .focus_visible => |focus_visible| focus_visible.specificity(),
            .hover => |hover| hover.specificity(),
            .structural => |structural| structural.specificity(),
            .logical => |logical| logical.specificity(),
            .state => |state| state.specificity(),
            .pseudo_element => |pseudo_element| pseudo_element.specificity(),
            .sequence => |s| s.specificity(),
            .has => |h| h.specificity(),
            .descendant => |d| d.specificity(),
            .complex => |complex| complex.specificity(),
        };
    }

    /// Conservative mutation scope for this selector, including unmatched
    /// logical branches. No DOM pointer or allocation enters this summary.
    pub fn dependencies(self: Selector) dom.SelectorDependencies {
        return selectorDependencies(self);
    }

    /// Return the terminal generated pseudo-element selected by this rule.
    /// Callers use this to keep author rules for generated boxes separate from
    /// rules for their real DOM host.
    pub fn pseudoElementKind(self: Selector) ?pseudo.Kind {
        return switch (self) {
            .pseudo_element => |pseudo_element| pseudo_element.kind,
            .sequence => |sequence| sequence.pseudoElementKind(),
            .descendant => |descendant| descendant.pseudoElementKind(),
            .complex => |complex| complex.pseudoElementKind(),
            else => null,
        };
    }
};

/// A non-combinator selector. Descendant selectors store these directly so a
/// selector chain is flat rather than a recursively nested binary tree.
pub const SimpleSelector = union(enum) {
    universal: UniversalSelector,
    tag: TagSelector,
    class: ClassSelector,
    id: IdSelector,
    attribute: AttributeSelector,
    focus_visible: FocusVisibleSelector,
    hover: HoverSelector,
    structural: StructuralSelector,
    logical: LogicalSelector,
    state: StateSelector,
    pseudo_element: PseudoElementSelector,
    sequence: SelectorSequence,
    has: HasSelector,

    pub fn intoSelector(self: SimpleSelector) Selector {
        return switch (self) {
            .universal => |universal| .{ .universal = universal },
            .tag => |tag| .{ .tag = tag },
            .class => |class| .{ .class = class },
            .id => |id| .{ .id = id },
            .attribute => |attribute| .{ .attribute = attribute },
            .focus_visible => |focus_visible| .{ .focus_visible = focus_visible },
            .hover => |hover| .{ .hover = hover },
            .structural => |structural| .{ .structural = structural },
            .logical => |logical| .{ .logical = logical },
            .state => |state| .{ .state = state },
            .pseudo_element => |pseudo_element| .{ .pseudo_element = pseudo_element },
            .sequence => |sequence| .{ .sequence = sequence },
            .has => |has| .{ .has = has },
        };
    }

    fn matches(self: SimpleSelector, node: *Node, ancestor_chain: Ancestry, context: MatchContext) bool {
        return switch (self) {
            .universal => |universal| universal.matches(node),
            .tag => |tag| tag.matches(node),
            .class => |class| class.matches(node),
            .id => |id| id.matches(node),
            .attribute => |attribute| attribute.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
            .structural => |structural| structural.matches(node),
            .logical => |logical| logical.matches(node, ancestor_chain, context),
            .state => |state| state.matches(node),
            .pseudo_element => |pseudo_element| pseudo_element.matches(node),
            .sequence => |sequence| sequence.matches(node, ancestor_chain, context),
            .has => |has| has.matches(node, ancestor_chain, context),
        };
    }

    fn populateHasMatches(
        self: SimpleSelector,
        cache: *HasMatchCache,
        root: *Node,
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .logical => |logical| try logical.populateHasMatches(cache, root),
            .sequence => |sequence| try sequence.populateHasMatches(cache, root),
            .has => |has| try has.populateMatches(cache, root),
            else => {},
        }
    }

    pub fn deinit(self: *SimpleSelector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .universal => {},
            .tag => |*tag| tag.deinit(allocator),
            .class => |*class| class.deinit(allocator),
            .id => |*id| id.deinit(allocator),
            .attribute => |*attribute| attribute.deinit(allocator),
            .focus_visible => {},
            .hover => {},
            .structural => |*structural| structural.deinit(allocator),
            .logical => |*logical| logical.deinit(allocator),
            .state => {},
            .pseudo_element => {},
            .sequence => |*sequence| sequence.deinit(allocator),
            .has => |*has| has.deinit(allocator),
        }
    }

    fn specificity(self: SimpleSelector) Specificity {
        return switch (self) {
            .universal => |universal| universal.specificity(),
            .tag => |tag| tag.specificity(),
            .class => |class| class.specificity(),
            .id => |id| id.specificity(),
            .attribute => |attribute| attribute.specificity(),
            .focus_visible => |focus_visible| focus_visible.specificity(),
            .hover => |hover| hover.specificity(),
            .structural => |structural| structural.specificity(),
            .logical => |logical| logical.specificity(),
            .state => |state| state.specificity(),
            .pseudo_element => |pseudo_element| pseudo_element.specificity(),
            .sequence => |sequence| sequence.specificity(),
            .has => |has| has.specificity(),
        };
    }

    pub fn pseudoElementKind(self: SimpleSelector) ?pseudo.Kind {
        return switch (self) {
            .pseudo_element => |pseudo_element| pseudo_element.kind,
            .sequence => |sequence| sequence.pseudoElementKind(),
            else => null,
        };
    }
};

/// The universal selector matches every element and contributes no
/// specificity.
pub const UniversalSelector = struct {
    fn matches(self: UniversalSelector, node: *Node) bool {
        _ = self;
        return publicHostNode(node).* == .element;
    }

    fn specificity(self: UniversalSelector) Specificity {
        _ = self;
        return .{};
    }
};

pub const AttributeMatch = enum {
    presence,
    exact,
    includes,
    dash_match,
};

/// A supported HTML attribute selector: presence, exact value, or
/// whitespace-token membership.
pub const AttributeSelector = struct {
    name: []const u8,
    value: ?[]const u8,
    matcher: AttributeMatch,

    pub fn init(
        name: []const u8,
        value: ?[]const u8,
        matcher: AttributeMatch,
    ) AttributeSelector {
        return .{ .name = name, .value = value, .matcher = matcher };
    }

    fn matches(self: AttributeSelector, node: *Node) bool {
        const element = switch (publicHostNode(node).*) {
            .element => |*value| value,
            .text => return false,
        };
        const attributes = element.attributes orelse return false;
        const actual = attributes.get(self.name) orelse return false;
        return switch (self.matcher) {
            .presence => true,
            .exact => std.mem.eql(u8, actual, self.value.?),
            .includes => blk: {
                var tokens = std.mem.tokenizeAny(u8, actual, " \t\r\n\x0c");
                while (tokens.next()) |token| {
                    if (std.mem.eql(u8, token, self.value.?)) break :blk true;
                }
                break :blk false;
            },
            .dash_match => std.mem.eql(u8, actual, self.value.?) or
                (actual.len > self.value.?.len and
                    std.mem.startsWith(u8, actual, self.value.?) and
                    actual[self.value.?.len] == '-'),
        };
    }

    fn deinit(self: *AttributeSelector, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.value) |value| allocator.free(value);
    }

    fn specificity(self: AttributeSelector) Specificity {
        _ = self;
        return .{ .classes = 1 };
    }
};

/// A class selector such as `.links`.
pub const ClassSelector = struct {
    class: []const u8,

    pub fn init(class: []const u8) ClassSelector {
        return .{ .class = class };
    }

    fn matches(self: ClassSelector, node: *Node) bool {
        const element = switch (publicHostNode(node).*) {
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

    fn specificity(self: ClassSelector) Specificity {
        _ = self;
        return .{ .classes = 1 };
    }
};

/// An ID selector such as `#main`. HTML ID matching is case-sensitive and an
/// ID contributes to the first specificity component.
pub const IdSelector = struct {
    id: []const u8,

    pub fn init(id: []const u8) IdSelector {
        return .{ .id = id };
    }

    fn matches(self: IdSelector, node: *Node) bool {
        const element = switch (publicHostNode(node).*) {
            .element => |*value| value,
            .text => return false,
        };
        const attributes = element.attributes orelse return false;
        return std.mem.eql(u8, self.id, attributes.get("id") orelse return false);
    }

    fn deinit(self: IdSelector, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }

    fn specificity(self: IdSelector) Specificity {
        _ = self;
        return .{ .ids = 1 };
    }
};

/// The dynamic `:focus-visible` pseudo-class. The Tab installs both focus
/// bits as one serialized DOM transition, and style invalidation rematches
/// this selector before the next paint.
pub const FocusVisibleSelector = struct {
    fn matches(self: FocusVisibleSelector, node: *Node) bool {
        _ = self;
        return switch (publicHostNode(node).*) {
            .element => |element| element.is_focused and element.is_focus_visible,
            .text => false,
        };
    }

    fn specificity(self: FocusVisibleSelector) Specificity {
        _ = self;
        return .{ .classes = 1 };
    }
};

/// The dynamic `:hover` pseudo-class. Pointer hit resolution marks the
/// innermost hovered element and its element ancestors, matching the browser
/// behavior where a parent remains hovered while the pointer is over a child.
pub const HoverSelector = struct {
    fn matches(self: HoverSelector, node: *Node) bool {
        _ = self;
        return switch (publicHostNode(node).*) {
            .element => |element| element.is_hovered,
            .text => false,
        };
    }

    fn specificity(self: HoverSelector) Specificity {
        _ = self;
        return .{ .classes = 1 };
    }
};

/// Form/link state pseudo-classes used by Acid3 and ordinary page styling.
/// State is read from the live Element so attribute and navigation changes are
/// reflected after the normal style invalidation pass.
pub const StateKind = enum { link, visited, enabled, disabled, checked };

pub const StateSelector = struct {
    kind: StateKind,

    fn matches(self: StateSelector, node: *Node) bool {
        const element = switch (publicHostNode(node).*) {
            .element => |*value| value,
            .text => return false,
        };
        const attrs = element.attributes;
        const has_href = if (attrs) |map| map.contains("href") else false;
        const is_link = (std.ascii.eqlIgnoreCase(element.tag, "a") or
            std.ascii.eqlIgnoreCase(element.tag, "area")) and has_href;
        const is_control = std.ascii.eqlIgnoreCase(element.tag, "input") or
            std.ascii.eqlIgnoreCase(element.tag, "button") or
            std.ascii.eqlIgnoreCase(element.tag, "select") or
            std.ascii.eqlIgnoreCase(element.tag, "textarea") or
            std.ascii.eqlIgnoreCase(element.tag, "option");
        const is_disabled = if (attrs) |map| map.contains("disabled") else false;
        return switch (self.kind) {
            .link => is_link and !element.is_visited,
            .visited => is_link and element.is_visited,
            .enabled => is_control and !is_disabled,
            .disabled => is_control and is_disabled,
            .checked => element.isChecked(),
        };
    }

    fn specificity(self: StateSelector) Specificity {
        _ = self;
        return .{ .classes = 1 };
    }
};

/// Structural pseudo-classes whose result is derived from the element's
/// current sibling/ancestor relationship. The argument is owned only for
/// functional forms such as :nth-child() and :lang().
pub const StructuralKind = enum {
    root,
    first_child,
    last_child,
    only_child,
    empty,
    nth_child,
    nth_last_child,
    first_of_type,
    last_of_type,
    only_of_type,
    nth_of_type,
    nth_last_of_type,
    lang,
};

pub const StructuralSelector = struct {
    kind: StructuralKind,
    /// Raw An+B grammar for nth selectors; decoded identifier/string for lang.
    argument: ?[]const u8 = null,

    fn elementNode(node: *Node) ?*dom.Element {
        return switch (publicHostNode(node).*) {
            .element => |*element| element,
            .text => null,
        };
    }

    fn parentElement(node: *Node) ?*dom.Element {
        const element = elementNode(node) orelse return null;
        const parent = element.parent orelse return null;
        return switch (parent.*) {
            .element => |*value| value,
            .text => null,
        };
    }

    fn siblingIndex(node: *Node, from_end: bool, same_type: bool) ?usize {
        const parent = parentElement(node) orelse return null;
        const target = elementNode(node) orelse return null;
        var count: usize = 0;
        if (!from_end) {
            for (parent.children.items) |*child| {
                const child_element = elementNode(child) orelse continue;
                if (same_type and !std.ascii.eqlIgnoreCase(child_element.tag, target.tag)) continue;
                count += 1;
                if (child == publicHostNode(node)) return count;
            }
        } else {
            var i = parent.children.items.len;
            while (i > 0) {
                i -= 1;
                const child = &parent.children.items[i];
                const child_element = elementNode(child) orelse continue;
                if (same_type and !std.ascii.eqlIgnoreCase(child_element.tag, target.tag)) continue;
                count += 1;
                if (child == publicHostNode(node)) return count;
            }
        }
        return null;
    }

    fn nthMatches(index: usize, argument: []const u8) bool {
        const expression = @import("css_anb.zig").parse(argument) orelse return false;
        return expression.matches(index);
    }

    fn matchesLang(node: *Node, argument: []const u8) bool {
        const requested = argument;
        if (requested.len == 0) return false;
        var current: ?*Node = publicHostNode(node);
        while (current) |candidate| {
            switch (candidate.*) {
                .text => |text| current = text.parent,
                .element => |*element| {
                    if (element.attributes) |attributes| {
                        const lang = attributes.get("lang") orelse attributes.get("xml:lang");
                        if (lang) |value| {
                            if (std.ascii.eqlIgnoreCase(value, requested) or
                                (value.len > requested.len and
                                    std.ascii.eqlIgnoreCase(value[0..requested.len], requested) and
                                    value[requested.len] == '-')) return true;
                            return false;
                        }
                    }
                    current = element.parent;
                },
            }
        }
        return false;
    }

    fn matches(self: StructuralSelector, node: *Node) bool {
        const element = elementNode(node) orelse return false;
        return switch (self.kind) {
            .root => element.parent == null,
            .first_child => siblingIndex(node, false, false) == 1,
            .last_child => siblingIndex(node, true, false) == 1,
            .only_child => siblingIndex(node, false, false) == 1 and siblingIndex(node, true, false) == 1,
            .empty => blk: {
                for (element.children.items) |*child| switch (child.*) {
                    .element => break :blk false,
                    .text => |text| if (text.text.len != 0) break :blk false,
                };
                break :blk true;
            },
            .nth_child => siblingIndex(node, false, false) != null and nthMatches(siblingIndex(node, false, false).?, self.argument orelse ""),
            .nth_last_child => siblingIndex(node, true, false) != null and nthMatches(siblingIndex(node, true, false).?, self.argument orelse ""),
            .first_of_type => siblingIndex(node, false, true) == 1,
            .last_of_type => siblingIndex(node, true, true) == 1,
            .only_of_type => siblingIndex(node, false, true) == 1 and siblingIndex(node, true, true) == 1,
            .nth_of_type => siblingIndex(node, false, true) != null and nthMatches(siblingIndex(node, false, true).?, self.argument orelse ""),
            .nth_last_of_type => siblingIndex(node, true, true) != null and nthMatches(siblingIndex(node, true, true).?, self.argument orelse ""),
            .lang => matchesLang(node, self.argument orelse ""),
        };
    }

    fn deinit(self: *StructuralSelector, allocator: std.mem.Allocator) void {
        if (self.argument) |argument| allocator.free(argument);
        self.argument = null;
    }

    fn specificity(self: StructuralSelector) Specificity {
        _ = self;
        return .{ .classes = 1 };
    }
};

/// An owning list of complex selectors. :is/:where accept an empty list
/// after forgiving parsing; :not requires at least one valid member.
pub const LogicalSelector = struct {
    pub const Kind = enum { is, where, not };
    kind: Kind,
    selectors: std.ArrayList(Selector),

    fn matches(self: LogicalSelector, node: *Node, ancestor_chain: Ancestry, context: MatchContext) bool {
        if (publicHostNode(node).* != .element) return false;
        const ancestors = relationshipAncestors(node, ancestor_chain);
        for (self.selectors.items) |selector| {
            if (selector.matchesWithin(publicHostNode(node), ancestors, context)) return self.kind != .not;
        }
        return self.kind == .not;
    }

    pub fn deinit(self: *LogicalSelector, allocator: std.mem.Allocator) void {
        for (self.selectors.items) |*selector| selector.deinit(allocator);
        self.selectors.deinit(allocator);
        self.selectors = .empty;
    }

    fn specificity(self: LogicalSelector) Specificity {
        var result: Specificity = .{};
        if (self.kind != .where) for (self.selectors.items) |selector| {
            result = result.max(selector.specificity());
        };
        return result;
    }

    fn populateHasMatches(self: LogicalSelector, cache: *HasMatchCache, root: *Node) std.mem.Allocator.Error!void {
        for (self.selectors.items) |selector| try selector.populateHasMatches(cache, root);
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
        return switch (publicHostNode(node).*) {
            .element => |e| std.mem.eql(u8, self.tag, e.tag),
            .text => false,
        };
    }

    /// Free the allocated tag string
    fn deinit(self: TagSelector, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
    }

    fn specificity(self: TagSelector) Specificity {
        _ = self;
        return .{ .types = 1 };
    }
};

/// A terminal `::before` or `::after` selector atom. Its specificity is the
/// type-selector component, as required for pseudo-elements.
pub const PseudoElementSelector = struct {
    kind: pseudo.Kind,

    fn matches(self: PseudoElementSelector, node: *Node) bool {
        return switch (node.*) {
            .element => |element| element.generated_kind == self.kind,
            .text => false,
        };
    }

    fn specificity(self: PseudoElementSelector) Specificity {
        _ = self;
        return .{ .types = 1 };
    }
};

/// One atomic member of a selector sequence. A sequence matches only when all
/// of its tag, ID, class, and supported pseudo-class members match the same
/// element.
pub const SequenceSelector = union(enum) {
    universal: UniversalSelector,
    tag: TagSelector,
    class: ClassSelector,
    id: IdSelector,
    attribute: AttributeSelector,
    focus_visible: FocusVisibleSelector,
    hover: HoverSelector,
    structural: StructuralSelector,
    logical: LogicalSelector,
    state: StateSelector,
    pseudo_element: PseudoElementSelector,

    pub fn intoSimpleSelector(self: SequenceSelector) SimpleSelector {
        return switch (self) {
            .universal => |universal| .{ .universal = universal },
            .tag => |tag| .{ .tag = tag },
            .class => |class| .{ .class = class },
            .id => |id| .{ .id = id },
            .attribute => |attribute| .{ .attribute = attribute },
            .focus_visible => |focus_visible| .{ .focus_visible = focus_visible },
            .hover => |hover| .{ .hover = hover },
            .structural => |structural| .{ .structural = structural },
            .logical => |logical| .{ .logical = logical },
            .state => |state| .{ .state = state },
            .pseudo_element => |pseudo_element| .{ .pseudo_element = pseudo_element },
        };
    }

    fn matches(self: SequenceSelector, node: *Node, ancestor_chain: Ancestry, context: MatchContext) bool {
        return switch (self) {
            .universal => |universal| universal.matches(node),
            .tag => |tag| tag.matches(node),
            .class => |class| class.matches(node),
            .id => |id| id.matches(node),
            .attribute => |attribute| attribute.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
            .structural => |structural| structural.matches(node),
            .logical => |logical| logical.matches(node, ancestor_chain, context),
            .state => |state| state.matches(node),
            .pseudo_element => |pseudo_element| pseudo_element.matches(node),
        };
    }

    pub fn deinit(self: *SequenceSelector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .universal => {},
            .tag => |*tag| tag.deinit(allocator),
            .class => |*class| class.deinit(allocator),
            .id => |*id| id.deinit(allocator),
            .attribute => |*attribute| attribute.deinit(allocator),
            .focus_visible => {},
            .hover => {},
            .structural => |*structural| structural.deinit(allocator),
            .logical => |*logical| logical.deinit(allocator),
            .state => {},
            .pseudo_element => {},
        }
    }

    fn specificity(self: SequenceSelector) Specificity {
        return switch (self) {
            .universal => |universal| universal.specificity(),
            .tag => |tag| tag.specificity(),
            .class => |class| class.specificity(),
            .id => |id| id.specificity(),
            .attribute => |attribute| attribute.specificity(),
            .focus_visible => |focus_visible| focus_visible.specificity(),
            .hover => |hover| hover.specificity(),
            .structural => |structural| structural.specificity(),
            .logical => |logical| logical.specificity(),
            .state => |state| state.specificity(),
            .pseudo_element => |pseudo_element| pseudo_element.specificity(),
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

    fn matches(self: SelectorSequence, node: *Node, ancestor_chain: Ancestry, context: MatchContext) bool {
        for (self.selectors.items) |selector| {
            if (!selector.matches(node, ancestor_chain, context)) return false;
        }
        return true;
    }

    fn populateHasMatches(self: SelectorSequence, cache: *HasMatchCache, root: *Node) std.mem.Allocator.Error!void {
        for (self.selectors.items) |selector| switch (selector) {
            .logical => |logical| try logical.populateHasMatches(cache, root),
            else => {},
        };
    }

    /// Sequence specificity is the sum of the member specificities.
    fn specificity(self: SelectorSequence) Specificity {
        var total: Specificity = .{};
        for (self.selectors.items) |selector| total = total.add(selector.specificity());
        return total;
    }

    pub fn pseudoElementKind(self: SelectorSequence) ?pseudo.Kind {
        var result: ?pseudo.Kind = null;
        for (self.selectors.items) |selector| switch (selector) {
            .pseudo_element => |pseudo_element| {
                if (result != null) return null;
                result = pseudo_element.kind;
            },
            else => {},
        };
        return result;
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
        _ = try self.visit(root, .{ .slice = &.{} }, has);
        try self.prepared.put(has.descendant, {});
    }

    /// Return whether `node` or any of its descendants matches the relational
    /// selector's descendant component. Only child results qualify `node`
    /// itself, preserving the strict-descendant semantics of `:has`.
    fn visit(
        self: *HasMatchCache,
        node: *Node,
        ancestors: Ancestry,
        has: HasSelector,
    ) std.mem.Allocator.Error!bool {
        const context = MatchContext{ .has_cache = self };
        var child_contains_match = false;
        const link = Ancestry.Link{ .node = node, .parent = ancestors };
        switch (node.*) {
            .text => {},
            .element => |*element| {
                for (element.children.items) |*child| {
                    if (try self.visit(child, .{ .link = &link }, has)) child_contains_match = true;
                }
            },
        }

        if (child_contains_match and has.ancestor.matches(node, ancestors, context)) {
            try self.matches.put(.{ .selector = has.descendant, .node = node }, {});
        }
        return child_contains_match or has.descendant.matches(node, ancestors, context);
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

    fn specificity(self: HasSelector) Specificity {
        return self.ancestor.specificity().add(self.descendant.specificity());
    }

    fn matches(self: HasSelector, node: *Node, ancestor_chain: Ancestry, context: MatchContext) bool {
        const host = publicHostNode(node);
        const ancestors = relationshipAncestors(node, ancestor_chain);
        if (!self.ancestor.matches(host, ancestors, context)) return false;
        if (context.has_cache) |cache| {
            if (cache.isPrepared(self.descendant)) {
                return cache.contains(self.descendant, host);
            }
        }
        return self.hasMatchingDescendant(host, ancestors, context);
    }

    fn hasMatchingDescendant(self: HasSelector, node: *Node, ancestors: Ancestry, context: MatchContext) bool {
        const element = switch (node.*) {
            .text => return false,
            .element => |*value| value,
        };
        const link = Ancestry.Link{ .node = node, .parent = ancestors };
        for (element.children.items) |*child| {
            if (self.descendant.matches(child, .{ .link = &link }, context) or
                self.hasMatchingDescendant(child, .{ .link = &link }, context))
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

    /// Chain specificity is the sum of its compound selectors.
    fn specificity(self: DescendantSelector) Specificity {
        var total: Specificity = .{};
        for (self.selectors.items) |selector| total = total.add(selector.specificity());
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
        ancestor_chain: Ancestry,
        context: MatchContext,
    ) bool {
        const selectors = self.selectors.items;
        if (selectors.len < 2) return false;

        var selector_index = selectors.len - 1;
        if (!selectors[selector_index].matches(node, ancestor_chain, context)) return false;

        var ancestors = relationshipAncestors(node, ancestor_chain);
        while (selector_index > 0) {
            const ancestor = ancestors.last() orelse break;
            ancestors = ancestors.parent();
            if (selectors[selector_index - 1].matches(ancestor, ancestors, context)) selector_index -= 1;
        }
        return selector_index == 0;
    }

    fn pseudoElementKind(self: DescendantSelector) ?pseudo.Kind {
        if (self.selectors.items.len == 0) return null;
        return self.selectors.items[self.selectors.items.len - 1].pseudoElementKind();
    }
};

pub const Combinator = enum {
    descendant,
    child,
    adjacent,
    general_sibling,
};

/// A selector chain containing at least one explicit child or adjacent-sibling
/// combinator. Descendant-only chains keep the smaller flat representation
/// above for their common linear-time match.
pub const ComplexSelector = struct {
    selectors: std.ArrayList(SimpleSelector),
    combinators: std.ArrayList(Combinator),

    pub fn take(
        selectors: *std.ArrayList(SimpleSelector),
        combinators: *std.ArrayList(Combinator),
    ) ComplexSelector {
        std.debug.assert(selectors.items.len >= 2);
        std.debug.assert(combinators.items.len + 1 == selectors.items.len);
        const owned_selectors = selectors.*;
        const owned_combinators = combinators.*;
        selectors.* = .empty;
        combinators.* = .empty;
        return .{
            .selectors = owned_selectors,
            .combinators = owned_combinators,
        };
    }

    fn deinit(self: *ComplexSelector, allocator: std.mem.Allocator) void {
        for (self.selectors.items) |*selector| selector.deinit(allocator);
        self.selectors.deinit(allocator);
        self.combinators.deinit(allocator);
        self.selectors = .empty;
        self.combinators = .empty;
    }

    fn specificity(self: ComplexSelector) Specificity {
        var total: Specificity = .{};
        for (self.selectors.items) |selector| total = total.add(selector.specificity());
        return total;
    }

    fn populateHasMatches(
        self: ComplexSelector,
        cache: *HasMatchCache,
        root: *Node,
    ) std.mem.Allocator.Error!void {
        for (self.selectors.items) |selector| {
            try selector.populateHasMatches(cache, root);
        }
    }

    fn previousElementSibling(node: *Node, parent: *Node) ?*Node {
        const element = switch (parent.*) {
            .element => |*value| value,
            .text => return null,
        };
        for (element.children.items, 0..) |*child, index| {
            if (child != node) continue;
            var previous_index = index;
            while (previous_index > 0) {
                previous_index -= 1;
                const previous = &element.children.items[previous_index];
                if (previous.* == .element) return previous;
            }
            return null;
        }
        return null;
    }

    fn matchesAt(
        self: ComplexSelector,
        selector_index: usize,
        node: *Node,
        ancestor_chain: Ancestry,
        context: MatchContext,
    ) bool {
        if (!self.selectors.items[selector_index].matches(node, ancestor_chain, context)) return false;
        if (selector_index == 0) return true;

        const ancestors = relationshipAncestors(node, ancestor_chain);

        return switch (self.combinators.items[selector_index - 1]) {
            .child => if (ancestors.last() == null)
                false
            else
                self.matchesAt(
                    selector_index - 1,
                    ancestors.last().?,
                    ancestors.parent(),
                    context,
                ),
            .adjacent => if (ancestors.last() == null)
                false
            else if (previousElementSibling(
                publicHostNode(node),
                ancestors.last().?,
            )) |previous|
                self.matchesAt(
                    selector_index - 1,
                    previous,
                    ancestors,
                    context,
                )
            else
                false,
            .general_sibling => if (ancestors.last() == null)
                false
            else blk: {
                const parent = ancestors.last().?;
                const parent_element = switch (parent.*) {
                    .element => |*element| element,
                    .text => break :blk false,
                };
                for (parent_element.children.items, 0..) |*sibling, sibling_index| {
                    if (sibling != publicHostNode(node)) continue;
                    var previous_index = sibling_index;
                    while (previous_index > 0) {
                        previous_index -= 1;
                        const previous = &parent_element.children.items[previous_index];
                        if (previous.* != .element) continue;
                        if (self.matchesAt(selector_index - 1, previous, ancestors, context)) {
                            break :blk true;
                        }
                    }
                    break;
                }
                break :blk false;
            },
            .descendant => blk: {
                var remaining = ancestors;
                while (remaining.last()) |ancestor| {
                    remaining = remaining.parent();
                    if (self.matchesAt(selector_index - 1, ancestor, remaining, context)) break :blk true;
                }
                break :blk false;
            },
        };
    }

    fn matches(
        self: ComplexSelector,
        node: *Node,
        ancestor_chain: Ancestry,
        context: MatchContext,
    ) bool {
        if (self.selectors.items.len < 2 or
            self.combinators.items.len + 1 != self.selectors.items.len)
        {
            return false;
        }
        return self.matchesAt(
            self.selectors.items.len - 1,
            node,
            ancestor_chain,
            context,
        );
    }

    fn pseudoElementKind(self: ComplexSelector) ?pseudo.Kind {
        if (self.selectors.items.len == 0) return null;
        return self.selectors.items[self.selectors.items.len - 1].pseudoElementKind();
    }
};

fn selectorDependencies(original: anytype) dom.SelectorDependencies {
    return switch (original) {
        inline else => |payload| result: {
            const T = @TypeOf(payload);
            if (T == StructuralSelector) break :result .{ .descendants = payload.kind == .lang };
            if (T == HasSelector) {
                const combined = selectorDependencies(payload.ancestor.*).merge(selectorDependencies(payload.descendant.*));
                break :result combined.merge(.{ .has = true });
            }
            if (T == SelectorSequence or T == DescendantSelector or T == ComplexSelector or T == LogicalSelector) {
                var summary = dom.SelectorDependencies{ .descendants = T == DescendantSelector };
                if (T == ComplexSelector) for (payload.combinators.items) |combinator| {
                    switch (combinator) {
                        .child, .descendant => summary.descendants = true,
                        .adjacent, .general_sibling => summary.siblings = true,
                    }
                };
                for (payload.selectors.items) |part| summary = summary.merge(selectorDependencies(part));
                break :result summary;
            }
            break :result .{};
        },
    };
}

// The three selector unions share payload owners. Keep cloning alongside
// deinitialization so adding an owning payload cannot silently shallow-copy it.
fn cloneSelectorUnion(comptime T: type, original: T, allocator: std.mem.Allocator) std.mem.Allocator.Error!T {
    return switch (original) {
        inline else => |payload, tag| @unionInit(T, @tagName(tag), try cloneSelectorPayload(payload, allocator)),
    };
}

fn cloneSelectorPayload(original: anytype, allocator: std.mem.Allocator) std.mem.Allocator.Error!@TypeOf(original) {
    const T = @TypeOf(original);
    if (T == UniversalSelector or T == FocusVisibleSelector or T == HoverSelector or T == StateSelector or T == PseudoElementSelector) {
        return original;
    } else if (T == TagSelector) {
        return .{ .tag = try allocator.dupe(u8, original.tag) };
    } else if (T == ClassSelector) {
        return .{ .class = try allocator.dupe(u8, original.class) };
    } else if (T == IdSelector) {
        return .{ .id = try allocator.dupe(u8, original.id) };
    } else if (T == AttributeSelector) {
        const name = try allocator.dupe(u8, original.name);
        errdefer allocator.free(name);
        const value = if (original.value) |text| try allocator.dupe(u8, text) else null;
        return .{ .name = name, .value = value, .matcher = original.matcher };
    } else if (T == StructuralSelector) {
        return .{
            .kind = original.kind,
            .argument = if (original.argument) |text| try allocator.dupe(u8, text) else null,
        };
    } else if (T == LogicalSelector) {
        return .{ .kind = original.kind, .selectors = try cloneSelectorComponents(Selector, original.selectors.items, allocator) };
    } else if (T == HasSelector) {
        const ancestor = try cloneSimplePointer(original.ancestor.*, allocator);
        errdefer {
            ancestor.deinit(allocator);
            allocator.destroy(ancestor);
        }
        return .{ .ancestor = ancestor, .descendant = try cloneSimplePointer(original.descendant.*, allocator) };
    } else if (T == SelectorSequence) {
        return .{ .selectors = try cloneSelectorComponents(SequenceSelector, original.selectors.items, allocator) };
    } else if (T == DescendantSelector) {
        return .{ .selectors = try cloneSelectorComponents(SimpleSelector, original.selectors.items, allocator) };
    } else if (T == ComplexSelector) {
        var selectors = try cloneSelectorComponents(SimpleSelector, original.selectors.items, allocator);
        errdefer {
            for (selectors.items) |*selector| selector.deinit(allocator);
            selectors.deinit(allocator);
        }
        var combinators = std.ArrayList(Combinator).empty;
        errdefer combinators.deinit(allocator);
        try combinators.appendSlice(allocator, original.combinators.items);
        return .{ .selectors = selectors, .combinators = combinators };
    } else {
        @compileError("New selector payload needs an explicit ownership-preserving clone: " ++ @typeName(T));
    }
}

fn cloneSimplePointer(original: SimpleSelector, allocator: std.mem.Allocator) std.mem.Allocator.Error!*SimpleSelector {
    const result = try allocator.create(SimpleSelector);
    errdefer allocator.destroy(result);
    result.* = try cloneSelectorUnion(SimpleSelector, original, allocator);
    return result;
}

fn cloneSelectorComponents(comptime T: type, original: []const T, allocator: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(T) {
    var result = std.ArrayList(T).empty;
    errdefer {
        for (result.items) |*part| part.deinit(allocator);
        result.deinit(allocator);
    }
    try result.ensureTotalCapacity(allocator, original.len);
    for (original) |part| result.appendAssumeCapacity(try cloneSelectorUnion(T, part, allocator));
    return result;
}

test "structural selector matching follows element siblings and inherited language" {
    const allocator = std.testing.allocator;
    var root = Node{ .element = try dom.Element.init(allocator, "html lang=en-GB", null) };
    defer root.deinit(allocator);
    try root.element.children.append(allocator, Node{ .element = try dom.Element.init(allocator, "div", null) });
    try root.element.children.append(allocator, Node{ .element = try dom.Element.init(allocator, "span", null) });
    try root.element.children.append(allocator, Node{ .text = dom.Text.init("", null) });
    dom.fixParentPointers(&root, null);

    const first = &root.element.children.items[0];
    const second = &root.element.children.items[1];
    var first_child = StructuralSelector{ .kind = .first_child };
    var last_child = StructuralSelector{ .kind = .last_child };
    var only_child = StructuralSelector{ .kind = .only_child };
    var nth = StructuralSelector{ .kind = .nth_child, .argument = "2n" };
    var lang = StructuralSelector{ .kind = .lang, .argument = "en" };
    try std.testing.expect(first_child.matches(first));
    try std.testing.expect(!last_child.matches(first));
    try std.testing.expect(last_child.matches(second));
    try std.testing.expect(!only_child.matches(first));
    try std.testing.expect(nth.matches(second));
    try std.testing.expect(lang.matches(second));
}

test "state selectors observe live link and form attributes" {
    const allocator = std.testing.allocator;
    var root = Node{ .element = try dom.Element.init(allocator, "html", null) };
    defer root.deinit(allocator);
    try root.element.children.append(allocator, Node{ .element = try dom.Element.init(allocator, "a href=/next", null) });
    try root.element.children.append(allocator, Node{ .element = try dom.Element.init(allocator, "input type=checkbox", null) });
    dom.fixParentPointers(&root, null);

    const link = &root.element.children.items[0];
    const input = &root.element.children.items[1];
    const link_state = StateSelector{ .kind = .link };
    const visited_state = StateSelector{ .kind = .visited };
    const enabled_state = StateSelector{ .kind = .enabled };
    const checked_state = StateSelector{ .kind = .checked };
    try std.testing.expect(link_state.matches(link));
    try std.testing.expect(!visited_state.matches(link));
    try std.testing.expect(enabled_state.matches(input));
    try std.testing.expect(!checked_state.matches(input));
    _ = try input.element.toggleChecked();
    try std.testing.expect(checked_state.matches(input));
    try input.element.attributes.?.put("disabled", "");
    try std.testing.expect(!enabled_state.matches(input));
}

const clone_test_source = "*,div,.a,#id,[data-name='x'],:focus-visible,:hover,:nth-child(2n)," ++
    ":not(.excluded),:enabled,::before,div.a:focus-visible,div:has(span.a),main div.a," ++
    "main > div[data-name='x']:not(:hover)::before";

test "selector clones retain matches and specificity after original owners retire" {
    const allocator = std.testing.allocator;
    var root = Node{ .element = try dom.Element.init(allocator, "div id=id class=a data-name=x", null) };
    defer root.deinit(allocator);
    try root.element.children.append(allocator, .{ .element = try dom.Element.init(allocator, "span class=a", null) });
    dom.fixParentPointers(&root, null);

    const original = try @import("css_parser.zig").parseSelectorList(allocator, clone_test_source);
    var originals_alive = true;
    defer if (originals_alive) {
        for (original) |*selector| selector.deinit(allocator);
        allocator.free(original);
    };
    var clones = std.ArrayList(Selector).empty;
    defer {
        for (clones.items) |*selector| selector.deinit(allocator);
        clones.deinit(allocator);
    }
    try clones.ensureTotalCapacity(allocator, original.len);
    var priorities: [15]Specificity = undefined;
    var matches: [15]bool = undefined;
    try std.testing.expectEqual(priorities.len, original.len);
    for (original, 0..) |selector, index| {
        priorities[index] = selector.specificity();
        matches[index] = selector.matches(&root, &.{});
        clones.appendAssumeCapacity(try selector.clone(allocator));
    }
    try std.testing.expect(original[1].tag.tag.ptr != clones.items[1].tag.tag.ptr);
    try std.testing.expect(original[8].logical.selectors.items.ptr != clones.items[8].logical.selectors.items.ptr);
    try std.testing.expect(original[12].has.descendant != clones.items[12].has.descendant);
    try std.testing.expect(original[14].complex.combinators.items.ptr != clones.items[14].complex.combinators.items.ptr);
    for (original) |*selector| selector.deinit(allocator);
    allocator.free(original);
    originals_alive = false;
    for (clones.items, 0..) |selector, index| {
        try std.testing.expectEqual(priorities[index], selector.specificity());
        try std.testing.expectEqual(matches[index], selector.matches(&root, &.{}));
    }
    try std.testing.expectEqualStrings("x", clones.items[4].attribute.value.?);
    try std.testing.expectEqualStrings("2n", clones.items[7].structural.argument.?);
}

fn selectorCloneAllocationTrial(allocator: std.mem.Allocator, original: []const Selector) !void {
    for (original) |selector| {
        var cloned = try selector.clone(allocator);
        defer cloned.deinit(allocator);
        try std.testing.expectEqual(selector.specificity(), cloned.specificity());
    }
}

test "selector cloning reclaims every partial allocation without changing originals" {
    const allocator = std.testing.allocator;
    const original = try @import("css_parser.zig").parseSelectorList(allocator, clone_test_source);
    defer {
        for (original) |*selector| selector.deinit(allocator);
        allocator.free(original);
    }
    try std.testing.checkAllAllocationFailures(allocator, selectorCloneAllocationTrial, .{original});
}
