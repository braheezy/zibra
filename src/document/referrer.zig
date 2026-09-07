//! HTML referrer-policy delivery over synchronous DOM borrows. The caller
//! supplies a live document's policy slot; detached parsing has no such slot.
const std = @import("std");
const rules = @import("../network/referrer_policy.zig");
pub const Policy = rules.Policy;

pub fn applyMeta(node: anytype, policy: *Policy) void {
    if (node.* != .element) return;
    const element = &node.element;
    if (!std.mem.eql(u8, element.tag, "meta")) return;
    // Foreign SVG/MathML descendants are not HTML metadata.
    var ancestor = element.parent;
    while (ancestor) |parent| {
        if (parent.* != .element) break;
        if (std.mem.eql(u8, parent.element.tag, "svg") or std.mem.eql(u8, parent.element.tag, "math") or std.mem.eql(u8, parent.element.tag, "template")) return;
        ancestor = parent.element.parent;
    }
    const attributes = element.attributes orelse return;
    if (!std.ascii.eqlIgnoreCase(attributes.get("name") orelse "", "referrer")) return;
    if (rules.parseMeta(attributes.get("content") orelse "")) |value| policy.* = value;
}

/// Call only for the newly attached subtree, never on removal or a whole-tree
/// rescan: last insertion/change wins even if it precedes older metas in DOM.
pub fn inserted(node: anytype, policy: *Policy) void {
    if (node.* != .element) return;
    applyMeta(node, policy);
    for (node.element.children.items) |*child| inserted(child, policy);
}

pub fn hasRel(element: anytype, wanted: []const u8) bool {
    const attrs = element.attributes orelse return false;
    var tokens = std.mem.tokenizeAny(u8, attrs.get("rel") orelse "", " \t\n\r\x0c");
    while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(token, wanted)) return true;
    return false;
}

pub fn forElement(element: anytype, inherited: Policy) Policy {
    if ((std.mem.eql(u8, element.tag, "a") or std.mem.eql(u8, element.tag, "area") or
        std.mem.eql(u8, element.tag, "form")) and hasRel(element, "noreferrer")) return .no_referrer;
    // Form supports rel=noreferrer, not a referrerpolicy content attribute.
    if (std.mem.eql(u8, element.tag, "form")) return inherited;
    const attrs = element.attributes orelse return inherited;
    return rules.parseAttribute(attrs.get("referrerpolicy") orelse "") orelse inherited;
}

pub fn forResource(element: anytype, inherited: Policy) Policy {
    return element.parser_referrer_policy orelse forElement(element, inherited);
}

/// A changed request source must not reuse a parser-time policy snapshot.
/// Responsive-image candidate changes are fresh requests just like src/href.
pub fn resourceAttributeChanged(element: anytype, name: []const u8) void {
    inline for (.{ "src", "srcset", "sizes", "href", "referrerpolicy" }) |attribute| {
        if (std.mem.eql(u8, name, attribute)) {
            element.parser_referrer_policy = null;
            return;
        }
    }
}

pub fn parserInserted(node: anytype, policy: *Policy) void {
    applyMeta(node, policy);
    if (node.* != .element) return;
    const element = &node.element;
    inline for (.{ "img", "iframe", "link", "script" }) |tag| {
        if (std.mem.eql(u8, element.tag, tag)) {
            element.parser_referrer_policy = forElement(element, policy.*);
            return;
        }
    }
}
