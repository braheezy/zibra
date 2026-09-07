//! CharacterData storage commits under the active Realm's mutation boundary.
//! Staging owns UTF-16 DOM data and its scalar UTF-8 native projection; no
//! Kiesel string or generation-bound Node borrow escapes the callback.
const std = @import("std");
const kiesel = @import("kiesel");
const parser = @import("../document/parser.zig");
const mutation = @import("dom_mutation.zig");
const native = @import("native_bindings.zig");
const Agent = kiesel.execution.Agent;
const Value = kiesel.types.Value;
const String = kiesel.types.String;

pub const Host = struct {
    context: ?*anyopaque,
    active_mutation: *const fn (?*anyopaque) ?mutation.Context,
};

pub const bindings = [_]native.Binding{
    .{ .name = "setNodeData", .length = 2, .function = setNodeData },
};

/// Return independently owned data, with no parent/style or JS-value borrow.
/// The caller transfers the Text or calls deinit on every failure path.
pub fn stageText(allocator: std.mem.Allocator, string: *const String) !parser.Text {
    const bytes = try string.toUtf8(allocator);
    errdefer allocator.free(bytes);
    const units = if (string.isUtf16()) try allocator.dupe(u16, string.asUtf16()) else null;
    return .{ .text = bytes, .owned_text = true, .utf16_data = units };
}

/// Copy native data into traced storage before returning to JavaScript.
pub fn copyText(agent: *Agent, text: parser.Text) Agent.Error!*const String {
    if (text.utf16_data) |units|
        return String.fromUtf16(agent, try agent.gc_allocator.dupe(u16, units));
    const decoded = try text.decoded(agent.gc_allocator);
    return String.fromUtf8(agent, decoded orelse try agent.gc_allocator.dupe(u8, text.text));
}

fn setNodeData(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const function = agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction);
    const host = function.fields.additionalFieldsAs(Host);
    const context = host.active_mutation(host.context) orelse
        return agent.throwException(.internal_error, "Missing active document", .{});
    const handle = try arguments.get(0).toUint32(agent);
    const node = context.handles.resolve(handle) orelse
        return agent.throwException(.type_error, "Invalid text node", .{});
    const value = arguments.get(1);
    if (node.* != .text or !value.isString())
        return agent.throwException(.type_error, "setNodeData requires a text node and string", .{});
    const staged = try stageText(context.allocator, value.asString());
    const parent = mutation.nodeParent(node);
    const attached = mutation.isAttachedToCurrentDocument(context.current_nodes, node);
    // TextLayout can borrow slices of the previous data. Retire it before
    // freeing bytes even though this operation does not relocate any Nodes.
    if (attached) context.hooks.prepare(context.host_context, parent orelse node, .structural);
    node.text.deinitData(context.allocator);
    node.text.text = staged.text;
    node.text.owned_text = true;
    node.text.character_references = false;
    node.text.utf16_data = staged.utf16_data;
    if (parent) |p| {
        parser.dirtyStyleForElement(&p.element);
        mutation.markElementLayoutDirty(&p.element);
    }
    if (attached) {
        context.hooks.complete(context.host_context, parent orelse node);
        context.hooks.request_render(context.host_context);
    }
    return .undefined;
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var text = try stageText(allocator, String.fromLiteral("A🌠&amp;"));
    defer text.deinit(allocator);
    try std.testing.expectEqualStrings("A🌠&amp;", text.text);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("A🌠&amp;"), text.utf16_data.?);
}

test "CharacterData staging owns every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
