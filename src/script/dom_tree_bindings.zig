//! Read-only native bindings for document lookup and authored DOM topology.
//!
//! The browser owns the active document and its mutable Node storage. This
//! module receives only a callback-scoped `WindowBorrow`, resolves numeric
//! identities synchronously, and returns copied strings or numeric snapshots.
//! It deliberately does not know about `Js`, WindowRealm ownership, layout,
//! or mutation invalidation.

const std = @import("std");
const kiesel = @import("kiesel");
const parser = @import("../document/parser.zig");
const dom_handles = @import("dom_handles.zig");
const dom_mutation = @import("dom_mutation.zig");
const native_bindings = @import("native_bindings.zig");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Value = kiesel.types.Value;
const Node = parser.Node;
const DomHandles = dom_handles.Store;
const IdIssuer = dom_handles.IdIssuer;

/// A synchronous borrow of the document installed in the currently active
/// JavaScript realm. None of these pointers may escape a native callback.
pub const WindowBorrow = struct {
    current_nodes: ?*Node,
    handles: *DomHandles,
    handle_issuer: *IdIssuer,
};

/// Heap-stable host data retained by Kiesel native functions. `allocator` is
/// used only for transient JavaScript argument conversion; returned strings
/// are copied into Kiesel's traced allocator instead.
pub const Host = struct {
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    active_window: *const fn (?*anyopaque) ?WindowBorrow,
    /// Flush computed style for synchronous getComputedStyle readback.
    style_flush: ?*const fn (?*anyopaque) anyerror!void = null,
};

/// Native functions installed on the private `__native` object.
pub const bindings = [_]native_bindings.Binding{
    .{ .name = "getDocumentElement", .length = 0, .function = getDocumentElement },
    .{ .name = "getDocumentBody", .length = 0, .function = getDocumentBody },
    .{ .name = "getElementById", .length = 1, .function = getElementById },
    .{ .name = "getElementsByTagName", .length = 1, .function = getElementsByTagName },
    .{ .name = "getElementsByTagNameFrom", .length = 2, .function = getElementsByTagNameFrom },
    .{ .name = "parentNode", .length = 1, .function = parentNode },
    .{ .name = "firstChild", .length = 1, .function = firstChild },
    .{ .name = "lastChild", .length = 1, .function = lastChild },
    .{ .name = "previousSibling", .length = 1, .function = previousSibling },
    .{ .name = "nextSibling", .length = 1, .function = nextSibling },
    .{ .name = "childNodes", .length = 1, .function = childNodes },
    .{ .name = "nodeType", .length = 1, .function = nodeType },
    .{ .name = "nodeName", .length = 1, .function = nodeName },
    .{ .name = "tagName", .length = 1, .function = tagName },
    .{ .name = "nodeValue", .length = 1, .function = nodeValue },
    .{ .name = "nodeData", .length = 1, .function = nodeData },
    .{ .name = "setNodeData", .length = 2, .function = setNodeData },
    .{ .name = "textContent", .length = 1, .function = textContent },
    .{ .name = "computedStyleValue", .length = 2, .function = computedStyleValue },
};

fn activeHost(agent: *Agent) *Host {
    const function = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction);
    return function.fields.additionalFieldsAs(Host);
}

fn requireWindow(agent: *Agent) Agent.Error!WindowBorrow {
    const host = activeHost(agent);
    return host.active_window(host.context) orelse agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
}

fn requireNode(agent: *Agent, window: WindowBorrow, argument: Value) Agent.Error!*Node {
    if (!argument.isNumber()) {
        return agent.throwException(.type_error, "DOM API requires a Node", .{});
    }
    const raw_handle = argument.asNumber().asFloat();
    const max_handle = @as(f64, @floatFromInt(std.math.maxInt(dom_handles.Id)));
    if (!std.math.isFinite(raw_handle) or raw_handle < 1 or raw_handle > max_handle or
        @trunc(raw_handle) != raw_handle)
    {
        return agent.throwException(.type_error, "Invalid node handle", .{});
    }
    return window.handles.resolve(@intFromFloat(raw_handle)) orelse agent.throwException(
        .type_error,
        "Invalid node handle",
        .{},
    );
}

/// Resolve a numeric DOM handle for host bindings that need to inspect a
/// detached subtree (for example an iframe's synthetic document).
pub fn requireNodeForHost(agent: *Agent, window: WindowBorrow, argument: Value) Agent.Error!*Node {
    return requireNode(agent, window, argument);
}

fn requireString(agent: *Agent, host: *Host, argument: Value, comptime message: []const u8) Agent.Error![]u8 {
    if (!argument.isString()) return agent.throwException(.type_error, message, .{});
    return argument.asString().toUtf8(host.allocator);
}

/// Return a numeric wrapper identity for `node`, or JavaScript null when the
/// requested relationship does not exist.
fn nodeValueFor(window: WindowBorrow, node: ?*Node) Agent.Error!Value {
    const value = node orelse return .null;
    const handle = try window.handles.getOrCreate(value, window.handle_issuer);
    return Value.from(@as(f64, @floatFromInt(handle)));
}

/// Copy native or source-backed DOM bytes before constructing a Kiesel String.
/// Kiesel can retain ASCII input storage, so borrowing a DOM slice here would
/// make a JavaScript string outlive mutation or document retirement.
fn copiedString(agent: *Agent, text: []const u8) Agent.Error!Value {
    const stable_text = try agent.gc_allocator.dupe(u8, text);
    return Value.from(try kiesel.types.String.fromUtf8(agent, stable_text));
}

fn uppercaseString(agent: *Agent, text: []const u8) Agent.Error!Value {
    const stable_text = try agent.gc_allocator.dupe(u8, text);
    for (stable_text) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return Value.from(try kiesel.types.String.fromUtf8(agent, stable_text));
}

fn nodeParent(node: *Node) ?*Node {
    return dom_mutation.nodeParent(node);
}

fn firstChildOf(node: *Node) ?*Node {
    return switch (node.*) {
        .text => null,
        .element => |*element| if (element.children.items.len == 0)
            null
        else
            &element.children.items[0],
    };
}

fn lastChildOf(node: *Node) ?*Node {
    return switch (node.*) {
        .text => null,
        .element => |*element| if (element.children.items.len == 0)
            null
        else
            &element.children.items[element.children.items.len - 1],
    };
}

fn siblingOf(node: *Node, direction: enum { previous, next }) ?*Node {
    const parent = nodeParent(node) orelse return null;
    const index = dom_mutation.directChildIndex(parent, node) orelse return null;
    const children = switch (parent.*) {
        .text => return null,
        .element => |*element| element.children.items,
    };
    return switch (direction) {
        .previous => if (index == 0) null else &children[index - 1],
        .next => if (index + 1 >= children.len) null else &children[index + 1],
    };
}

fn documentElement(root: ?*Node) ?*Node {
    const node = root orelse return null;
    return switch (node.*) {
        .element => node,
        .text => null,
    };
}

fn tagMatches(tag: []const u8, wanted: []const u8) bool {
    return (wanted.len == 1 and wanted[0] == '*') or std.ascii.eqlIgnoreCase(tag, wanted);
}

fn idForElement(element: *const parser.Element) ?[]const u8 {
    const attributes = element.attributes orelse return null;
    var it = attributes.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "id")) return entry.value_ptr.*;
    }
    return null;
}

fn findFirstElementByTag(node: *Node, wanted: []const u8) ?*Node {
    switch (node.*) {
        .text => return null,
        .element => |*element| {
            if (tagMatches(element.tag, wanted)) return node;
            for (element.children.items) |*child| {
                if (findFirstElementByTag(child, wanted)) |found| return found;
            }
        },
    }
    return null;
}

fn findElementById(node: *Node, wanted: []const u8) ?*Node {
    switch (node.*) {
        .text => return null,
        .element => |*element| {
            if (idForElement(element)) |id| {
                if (std.mem.eql(u8, id, wanted)) return node;
            }
            for (element.children.items) |*child| {
                if (findElementById(child, wanted)) |found| return found;
            }
        },
    }
    return null;
}

fn countMatchingElements(node: *Node, wanted: []const u8, include_self: bool) usize {
    return switch (node.*) {
        .text => 0,
        .element => |*element| count: {
            var result: usize = @intFromBool(include_self and tagMatches(element.tag, wanted));
            for (element.children.items) |*child| {
                result += countMatchingElements(child, wanted, true);
            }
            break :count result;
        },
    };
}

fn fillMatchingHandles(
    agent: *Agent,
    result: *kiesel.builtins.Array,
    window: WindowBorrow,
    node: *Node,
    wanted: []const u8,
    include_self: bool,
    index: *usize,
) Agent.Error!void {
    switch (node.*) {
        .text => {},
        .element => |*element| {
            if (include_self and tagMatches(element.tag, wanted)) {
                const handle = try window.handles.getOrCreate(node, window.handle_issuer);
                try result.object.createDataPropertyDirect(
                    agent,
                    kiesel.types.PropertyKey.from(
                        @as(kiesel.types.PropertyKey.IntegerIndex, @intCast(index.*)),
                    ),
                    Value.from(@as(f64, @floatFromInt(handle))),
                );
                index.* += 1;
            }
            for (element.children.items) |*child| {
                try fillMatchingHandles(agent, result, window, child, wanted, true, index);
            }
        },
    }
}

fn elementHandleArray(
    agent: *Agent,
    window: WindowBorrow,
    root: *Node,
    wanted: []const u8,
    include_root: bool,
) Agent.Error!Value {
    const count = countMatchingElements(root, wanted, include_root);
    const result = try kiesel.builtins.arrayCreate(agent, @intCast(count), null);
    var index: usize = 0;
    try fillMatchingHandles(agent, result, window, root, wanted, include_root, &index);
    std.debug.assert(index == count);
    return Value.from(&result.object);
}

fn appendTextContent(node: *const Node, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .text => |text| try output.appendSlice(allocator, text.text),
        .element => |element| {
            for (element.children.items) |*child| {
                try appendTextContent(child, output, allocator);
            }
        },
    }
}

fn getDocumentElement(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    return nodeValueFor(window, documentElement(window.current_nodes));
}

fn getDocumentBody(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const root = window.current_nodes orelse return .null;
    return nodeValueFor(window, findFirstElementByTag(root, "body"));
}

fn getElementById(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const window = host.active_window(host.context) orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const id = try requireString(agent, host, arguments.get(0), "getElementById requires a string");
    defer host.allocator.free(id);
    const root = window.current_nodes orelse return .null;
    return nodeValueFor(window, findElementById(root, id));
}

fn getElementsByTagName(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const window = host.active_window(host.context) orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const tag = try requireString(agent, host, arguments.get(0), "getElementsByTagName requires a string");
    defer host.allocator.free(tag);
    const root = window.current_nodes orelse {
        const empty = try kiesel.builtins.arrayCreate(agent, 0, null);
        return Value.from(&empty.object);
    };
    return elementHandleArray(agent, window, root, tag, true);
}

fn getElementsByTagNameFrom(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const window = host.active_window(host.context) orelse return agent.throwException(
        .internal_error,
        "Missing active window",
        .{},
    );
    const node = try requireNode(agent, window, arguments.get(0));
    const tag = try requireString(agent, host, arguments.get(1), "getElementsByTagName requires a string");
    defer host.allocator.free(tag);
    return elementHandleArray(agent, window, node, tag, false);
}

fn parentNode(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return nodeValueFor(window, nodeParent(node));
}

fn firstChild(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return nodeValueFor(window, firstChildOf(node));
}

fn lastChild(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return nodeValueFor(window, lastChildOf(node));
}

fn previousSibling(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return nodeValueFor(window, siblingOf(node, .previous));
}

fn nextSibling(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return nodeValueFor(window, siblingOf(node, .next));
}

fn childNodes(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    const element = switch (node.*) {
        .text => {
            const empty = try kiesel.builtins.arrayCreate(agent, 0, null);
            return Value.from(&empty.object);
        },
        .element => |*value| value,
    };
    const result = try kiesel.builtins.arrayCreate(agent, @intCast(element.children.items.len), null);
    for (element.children.items, 0..) |*child, index| {
        const handle = try window.handles.getOrCreate(child, window.handle_issuer);
        try result.object.createDataPropertyDirect(
            agent,
            kiesel.types.PropertyKey.from(
                @as(kiesel.types.PropertyKey.IntegerIndex, @intCast(index)),
            ),
            Value.from(@as(f64, @floatFromInt(handle))),
        );
    }
    return Value.from(&result.object);
}

fn nodeType(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return Value.from(@as(f64, switch (node.*) {
        .element => 1,
        .text => 3,
    }));
}

fn nodeName(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return switch (node.*) {
        .element => |element| uppercaseString(agent, element.tag),
        .text => copiedString(agent, "#text"),
    };
}

fn tagName(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return switch (node.*) {
        .element => |element| uppercaseString(agent, element.tag),
        .text => .null,
    };
}

fn nodeValue(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return switch (node.*) {
        .element => .null,
        .text => |text| copiedString(agent, text.text),
    };
}

fn nodeData(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    return switch (node.*) {
        .element => .null,
        .text => |text| copiedString(agent, text.text),
    };
}

/// Replace the bytes of a script-created or parser text node.  Range
/// extraction uses this to split text nodes without rebuilding their parent
/// (which would invalidate every handle in the subtree).
fn setNodeData(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    const value = arguments.get(1);
    if (!value.isString()) return agent.throwException(.type_error, "setNodeData requires a string", .{});
    const bytes = try value.asString().toUtf8(host.allocator);
    defer host.allocator.free(bytes);
    switch (node.*) {
        .element => return agent.throwException(.type_error, "setNodeData requires a text node", .{}),
        .text => |*text| {
            const owned = try host.allocator.dupe(u8, bytes);
            if (text.owned_text) host.allocator.free(text.text);
            text.text = owned;
            text.owned_text = true;
        },
    }
    return .undefined;
}

fn textContent(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    var text = std.ArrayList(u8).empty;
    defer text.deinit(agent.gc_allocator);
    try appendTextContent(node, &text, agent.gc_allocator);
    const owned = try text.toOwnedSlice(agent.gc_allocator);
    return Value.from(try kiesel.types.String.fromUtf8(agent, owned));
}

/// Return the last published CSS value for an element.  The style phase owns
/// the authoritative computed map; this synchronous snapshot deliberately
/// uses `lastValue` so a script cannot crash merely by querying style while a
/// later invalidation is pending.  Defaults cover the properties commonly
/// observable through `getComputedStyle` in the bounded DOM.
fn computedStyleValue(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
    _ = this_value;
    const host = activeHost(agent);
    const window = try requireWindow(agent);
    const node = try requireNode(agent, window, arguments.get(0));
    const property = try requireString(agent, host, arguments.get(1), "computed style property requires a string");
    defer host.allocator.free(property);

    const value: []const u8 = switch (node.*) {
        .text => "",
        .element => |*element| blk: {
            if (element.style) |*styles| {
                var style_dirty = false;
                var style_it = styles.iterator();
                while (style_it.next()) |entry| {
                    if (entry.value_ptr.dirty) {
                        style_dirty = true;
                        break;
                    }
                }
                if (style_dirty) if (host.style_flush) |flush| flush(host.context) catch |err| {
                    std.log.warn("Computed-style flush failed: {}", .{err});
                };
                if (styles.getPtr(property)) |field| break :blk field.lastValue().*;
            }
            break :blk if (std.mem.eql(u8, property, "z-index")) "auto" else if (std.mem.eql(u8, property, "white-space")) "normal" else "";
        },
    };
    return copiedString(agent, value);
}

test "DOM tree helpers preserve authored text topology and document order" {
    const allocator = std.testing.allocator;
    const html =
        "<html><head></head><body>" ++
        "<p id=first>one</p> \n <p id=second name=not-an-id>two</p>" ++
        "<p name=only-name>three</p></body></html>";
    var html_parser = try parser.HTMLParser.init(allocator, html);
    defer html_parser.deinit(allocator);
    html_parser.use_implicit_tags = false;
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    try std.testing.expectEqual(&root, documentElement(&root).?);
    const body = findFirstElementByTag(&root, "BODY").?;
    try std.testing.expect(std.ascii.eqlIgnoreCase(body.element.tag, "body"));

    const first = findElementById(&root, "first").?;
    const second = findElementById(&root, "second").?;
    try std.testing.expect(findElementById(&root, "only-name") == null);
    try std.testing.expectEqual(body, nodeParent(first).?);
    try std.testing.expectEqual(first, firstChildOf(body).?);
    try std.testing.expectEqual(second, siblingOf(siblingOf(second, .previous).?, .next).?);

    const whitespace = siblingOf(second, .previous).?;
    try std.testing.expect(whitespace.* == .text);
    try std.testing.expectEqualStrings(" \n ", whitespace.text.text);
    try std.testing.expectEqual(first, siblingOf(whitespace, .previous).?);
    try std.testing.expectEqual(second, siblingOf(whitespace, .next).?);
    try std.testing.expect(siblingOf(first, .previous) == null);

    try std.testing.expectEqual(@as(usize, 3), countMatchingElements(&root, "P", true));
    try std.testing.expectEqual(@as(usize, 6), countMatchingElements(&root, "*", true));
    try std.testing.expectEqual(@as(usize, 0), countMatchingElements(body, "body", false));
    try std.testing.expectEqual(@as(usize, 3), countMatchingElements(body, "*", false));

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    try appendTextContent(body, &text, allocator);
    try std.testing.expectEqualStrings("one \n twothree", text.items);
}
