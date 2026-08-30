//! CSS selector representation, specificity, and DOM matching.
//!
//! Selectors own their normalized tag storage and borrow DOM nodes only for
//! the duration of matching.

const std = @import("std");
const parser = @import("parser.zig");
const pseudo = @import("pseudo.zig");
const Node = parser.Node;

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
fn relationshipAncestors(node: *Node, ancestor_chain: []const *Node) []const *Node {
    const host = generatedPseudoHost(node) orelse return ancestor_chain;
    if (ancestor_chain.len != 0 and ancestor_chain[ancestor_chain.len - 1] == host) {
        return ancestor_chain[0 .. ancestor_chain.len - 1];
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
    not: NotSelector,
    state: StateSelector,
    pseudo_element: PseudoElementSelector,
    sequence: SelectorSequence,
    has: HasSelector,
    descendant: DescendantSelector,
    complex: ComplexSelector,

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
            .universal => |universal| universal.matches(node),
            .tag => |t| t.matches(node),
            .class => |c| c.matches(node),
            .id => |id| id.matches(node),
            .attribute => |attribute| attribute.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
            .structural => |structural| structural.matches(node),
            .not => |not| not.matches(node, context),
            .state => |state| state.matches(node),
            .pseudo_element => |pseudo_element| pseudo_element.matches(node),
            .sequence => |s| s.matches(node),
            .has => |h| h.matches(node, context),
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
            .not => |*not| not.deinit(allocator),
            .state => {},
            .pseudo_element => {},
            .sequence => |*s| s.deinit(allocator),
            .has => |*h| h.deinit(allocator),
            .descendant => |*d| d.deinit(allocator),
            .complex => |*complex| complex.deinit(allocator),
        }
    }

    /// Get the cascade priority of this selector
    /// Used for sorting rules - more specific selectors have higher priority
    pub fn priority(self: Selector) u32 {
        return switch (self) {
            .universal => |universal| universal.priority(),
            .tag => |t| t.priority(),
            .class => |c| c.priority(),
            .id => |id| id.priority(),
            .attribute => |attribute| attribute.priority(),
            .focus_visible => |focus_visible| focus_visible.priority(),
            .hover => |hover| hover.priority(),
            .structural => |structural| structural.priority(),
            .not => |not| not.priority(),
            .state => |state| state.priority(),
            .pseudo_element => |pseudo_element| pseudo_element.priority(),
            .sequence => |s| s.priority(),
            .has => |h| h.priority(),
            .descendant => |d| d.priority(),
            .complex => |complex| complex.priority(),
        };
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
    not: NotSelector,
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
            .not => |not| .{ .not = not },
            .state => |state| .{ .state = state },
            .pseudo_element => |pseudo_element| .{ .pseudo_element = pseudo_element },
            .sequence => |sequence| .{ .sequence = sequence },
            .has => |has| .{ .has = has },
        };
    }

    fn matches(self: SimpleSelector, node: *Node, context: MatchContext) bool {
        return switch (self) {
            .universal => |universal| universal.matches(node),
            .tag => |tag| tag.matches(node),
            .class => |class| class.matches(node),
            .id => |id| id.matches(node),
            .attribute => |attribute| attribute.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
            .structural => |structural| structural.matches(node),
            .not => |not| not.matches(node, context),
            .state => |state| state.matches(node),
            .pseudo_element => |pseudo_element| pseudo_element.matches(node),
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
            .universal => {},
            .tag => |*tag| tag.deinit(allocator),
            .class => |*class| class.deinit(allocator),
            .id => |*id| id.deinit(allocator),
            .attribute => |*attribute| attribute.deinit(allocator),
            .focus_visible => {},
            .hover => {},
            .structural => |*structural| structural.deinit(allocator),
            .not => |*not| not.deinit(allocator),
            .state => {},
            .pseudo_element => {},
            .sequence => |*sequence| sequence.deinit(allocator),
            .has => |*has| has.deinit(allocator),
        }
    }

    fn priority(self: SimpleSelector) u32 {
        return switch (self) {
            .universal => |universal| universal.priority(),
            .tag => |tag| tag.priority(),
            .class => |class| class.priority(),
            .id => |id| id.priority(),
            .attribute => |attribute| attribute.priority(),
            .focus_visible => |focus_visible| focus_visible.priority(),
            .hover => |hover| hover.priority(),
            .structural => |structural| structural.priority(),
            .not => |not| not.priority(),
            .state => |state| state.priority(),
            .pseudo_element => |pseudo_element| pseudo_element.priority(),
            .sequence => |sequence| sequence.priority(),
            .has => |has| has.priority(),
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

    fn priority(self: UniversalSelector) u32 {
        _ = self;
        return 0;
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

    fn priority(self: AttributeSelector) u32 {
        _ = self;
        return 10;
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
        return switch (publicHostNode(node).*) {
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
        return switch (publicHostNode(node).*) {
            .element => |element| element.is_hovered,
            .text => false,
        };
    }

    fn priority(self: HoverSelector) u32 {
        _ = self;
        return 10;
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

    fn priority(self: StateSelector) u32 {
        _ = self;
        return 10;
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
    argument: ?[]const u8 = null,

    fn elementNode(node: *Node) ?*parser.Element {
        return switch (publicHostNode(node).*) {
            .element => |*element| element,
            .text => null,
        };
    }

    fn parentElement(node: *Node) ?*parser.Element {
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
        const expr = std.mem.trim(u8, argument, " \t\r\n\x0c");
        if (std.ascii.eqlIgnoreCase(expr, "odd")) return (index & 1) == 1;
        if (std.ascii.eqlIgnoreCase(expr, "even")) return (index & 1) == 0;
        const n_pos = std.mem.indexOfScalar(u8, expr, 'n') orelse
            std.mem.indexOfScalar(u8, expr, 'N') orelse {
            const value = std.fmt.parseInt(i64, expr, 10) catch return false;
            return value >= 1 and index == @as(usize, @intCast(value));
        };
        const coefficient_text = std.mem.trim(u8, expr[0..n_pos], " \t\r\n\x0c");
        const coefficient: i64 = if (coefficient_text.len == 0 or std.mem.eql(u8, coefficient_text, "+"))
            1
        else if (std.mem.eql(u8, coefficient_text, "-"))
            -1
        else
            std.fmt.parseInt(i64, coefficient_text, 10) catch return false;
        const offset_text = std.mem.trim(u8, expr[n_pos + 1 ..], " \t\r\n\x0c");
        const offset: i64 = if (offset_text.len == 0)
            0
        else
            std.fmt.parseInt(i64, offset_text, 10) catch return false;
        const position: i64 = @intCast(index);
        const delta = position - offset;
        if (coefficient == 0) return delta == 0;
        if ((delta < 0 and coefficient > 0) or (delta > 0 and coefficient < 0)) return false;
        return @mod(delta, coefficient) == 0;
    }

    fn matchesLang(node: *Node, argument: []const u8) bool {
        const requested = std.mem.trim(u8, argument, " \t\r\n\x0c\"'");
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

    fn priority(self: StructuralSelector) u32 {
        _ = self;
        return 10;
    }
};

pub const NotSelector = struct {
    selector: *SimpleSelector,

    fn matches(self: NotSelector, node: *Node, context: MatchContext) bool {
        return !self.selector.matches(node, context);
    }

    fn deinit(self: *NotSelector, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
        allocator.destroy(self.selector);
    }

    fn priority(self: NotSelector) u32 {
        return 10 + self.selector.priority();
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

    /// Tag selectors have a priority of 1
    fn priority(self: TagSelector) u32 {
        _ = self;
        return 1;
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

    fn priority(self: PseudoElementSelector) u32 {
        _ = self;
        return 1;
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
    not: NotSelector,
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
            .not => |not| .{ .not = not },
            .state => |state| .{ .state = state },
            .pseudo_element => |pseudo_element| .{ .pseudo_element = pseudo_element },
        };
    }

    fn matches(self: SequenceSelector, node: *Node) bool {
        return switch (self) {
            .universal => |universal| universal.matches(node),
            .tag => |tag| tag.matches(node),
            .class => |class| class.matches(node),
            .id => |id| id.matches(node),
            .attribute => |attribute| attribute.matches(node),
            .focus_visible => |focus_visible| focus_visible.matches(node),
            .hover => |hover| hover.matches(node),
            .structural => |structural| structural.matches(node),
            .not => |not| not.matches(node, .{}),
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
            .not => |*not| not.deinit(allocator),
            .state => {},
            .pseudo_element => {},
        }
    }

    fn priority(self: SequenceSelector) u32 {
        return switch (self) {
            .universal => |universal| universal.priority(),
            .tag => |tag| tag.priority(),
            .class => |class| class.priority(),
            .id => |id| id.priority(),
            .attribute => |attribute| attribute.priority(),
            .focus_visible => |focus_visible| focus_visible.priority(),
            .hover => |hover| hover.priority(),
            .structural => |structural| structural.priority(),
            .not => |not| not.priority(),
            .state => |state| state.priority(),
            .pseudo_element => |pseudo_element| pseudo_element.priority(),
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

        const ancestors = relationshipAncestors(node, ancestor_chain);
        var ancestor_index = ancestors.len;
        while (selector_index > 0 and ancestor_index > 0) {
            ancestor_index -= 1;
            if (selectors[selector_index - 1].matches(ancestors[ancestor_index], context)) {
                selector_index -= 1;
            }
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

    fn priority(self: ComplexSelector) u32 {
        var total: u32 = 0;
        for (self.selectors.items) |selector| total += selector.priority();
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
        ancestor_chain: []const *Node,
        context: MatchContext,
    ) bool {
        if (!self.selectors.items[selector_index].matches(node, context)) return false;
        if (selector_index == 0) return true;

        const ancestors = relationshipAncestors(node, ancestor_chain);

        return switch (self.combinators.items[selector_index - 1]) {
            .child => if (ancestors.len == 0)
                false
            else
                self.matchesAt(
                    selector_index - 1,
                    ancestors[ancestors.len - 1],
                    ancestors[0 .. ancestors.len - 1],
                    context,
                ),
            .adjacent => if (ancestors.len == 0)
                false
            else if (previousElementSibling(
                publicHostNode(node),
                ancestors[ancestors.len - 1],
            )) |previous|
                self.matchesAt(
                    selector_index - 1,
                    previous,
                    ancestors,
                    context,
                )
            else
                false,
            .descendant => blk: {
                var ancestor_index = ancestors.len;
                while (ancestor_index > 0) {
                    ancestor_index -= 1;
                    if (self.matchesAt(
                        selector_index - 1,
                        ancestors[ancestor_index],
                        ancestors[0..ancestor_index],
                        context,
                    )) break :blk true;
                }
                break :blk false;
            },
        };
    }

    fn matches(
        self: ComplexSelector,
        node: *Node,
        ancestor_chain: []const *Node,
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

test "structural selector matching follows element siblings and inherited language" {
    const allocator = std.testing.allocator;
    var root = Node{ .element = try parser.Element.init(allocator, "html lang=en-GB", null) };
    defer root.deinit(allocator);
    try root.element.children.append(allocator, Node{ .element = try parser.Element.init(allocator, "div", null) });
    try root.element.children.append(allocator, Node{ .element = try parser.Element.init(allocator, "span", null) });
    try root.element.children.append(allocator, Node{ .text = parser.Text.init("", null) });
    parser.fixParentPointers(&root, null);

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
    var root = Node{ .element = try parser.Element.init(allocator, "html", null) };
    defer root.deinit(allocator);
    try root.element.children.append(allocator, Node{ .element = try parser.Element.init(allocator, "a href=/next", null) });
    try root.element.children.append(allocator, Node{ .element = try parser.Element.init(allocator, "input type=checkbox", null) });
    parser.fixParentPointers(&root, null);

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
