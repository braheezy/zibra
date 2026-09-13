//! CSSOM access to Element-owned declaration blocks. Native values are copied
//! into Kiesel; mutations stage a complete replacement before DOM publication.
const std = @import("std");
const kiesel = @import("kiesel");
const native = @import("native_bindings.zig");
const dom = @import("../document/dom.zig");
const Block = @import("../document/css_declaration_block.zig");
const properties = @import("../document/css_properties.zig");
const supports = @import("../document/css_supports.zig");
const css_parser = @import("../document/css_parser.zig");
const Agent = kiesel.execution.Agent;
const Value = kiesel.types.Value;

pub const Host = struct {
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    /// JsLock is held. The returned Element is a synchronous generation borrow.
    resolve_element: *const fn (?*anyopaque, u32) ?*dom.Element,
    request_render: *const fn (?*anyopaque) void,
};

pub const bindings = [_]native.Binding{
    .{ .name = "cssStyleQuery", .length = 3, .function = query },
    .{ .name = "cssStyleMutate", .length = 5, .function = mutate },
    .{ .name = "cssStyleClone", .length = 2, .function = clone },
    .{ .name = "cssPropertyNames", .length = 0, .function = propertyNames },
    .{ .name = "cssSupports", .length = 1, .function = supportsQuery },
};

fn getHost(agent: *Agent) *Host {
    return agent.activeFunctionObject().as(kiesel.builtins.BuiltinFunction).fields.additionalFieldsAs(Host);
}

fn resolve(agent: *Agent, host: *Host, argument: Value) Agent.Error!*dom.Element {
    if (!argument.isNumber()) return agent.throwException(.type_error, "CSS style requires an Element handle", .{});
    const number = argument.asNumber().asFloat();
    if (!std.math.isFinite(number) or number < 1 or number > std.math.maxInt(u32) or @trunc(number) != number)
        return agent.throwException(.type_error, "Invalid Element handle", .{});
    return host.resolve_element(host.context, @intFromFloat(number)) orelse agent.throwException(.type_error, "Invalid style owner", .{});
}

fn textArgument(agent: *Agent, allocator: std.mem.Allocator, value: Value) Agent.Error![]u8 {
    if (!value.isString()) return agent.throwException(.type_error, "CSS style requires string arguments", .{});
    return value.asString().toUtf8(allocator);
}

fn string(agent: *Agent, value: []const u8) Agent.Error!Value {
    // fromUtf8 retains ASCII bytes in Kiesel's string cache. Native scratch
    // and declaration arenas can be retired before the JavaScript string.
    const stable = try agent.gc_allocator.dupe(u8, value);
    return Value.from(try kiesel.types.String.fromUtf8(agent, stable));
}

fn supportsQuery(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const allocator = getHost(agent).allocator;
    const first = try textArgument(agent, allocator, arguments.get(0));
    defer allocator.free(first);
    if (arguments.count() >= 2) {
        const value = try textArgument(agent, allocator, arguments.get(1));
        defer allocator.free(value);
        return Value.from(try supports.property(allocator, first, value));
    }
    return Value.from(try supports.conditionText(allocator, first, css_parser.supportsSelector));
}

fn query(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const host = getHost(agent);
    const element = try resolve(agent, host, arguments.get(0));
    const operation = try textArgument(agent, host.allocator, arguments.get(1));
    defer host.allocator.free(operation);
    const block = try element.inlineStyle(host.allocator);
    if (std.mem.eql(u8, operation, "length")) return Value.from(@as(u32, @intCast(if (block) |owner| owner.count() else 0)));
    if (std.mem.eql(u8, operation, "item")) {
        const index = arguments.get(2);
        if (!index.isNumber()) return string(agent, "");
        const number = index.asNumber().asFloat();
        if (!std.math.isFinite(number) or number < 0 or number > std.math.maxInt(u32)) return string(agent, "");
        return string(agent, if (block) |owner| owner.item(@intFromFloat(number)) else "");
    }
    if (std.mem.eql(u8, operation, "text")) {
        const owner = block orelse return string(agent, "");
        const source = try owner.serialize(host.allocator);
        defer host.allocator.free(source);
        return string(agent, source);
    }
    const name = try textArgument(agent, host.allocator, arguments.get(2));
    defer host.allocator.free(name);
    const owner = block orelse return string(agent, "");
    if (std.mem.eql(u8, operation, "priority")) return string(agent, if (owner.propertyImportant(name)) "important" else "");
    const value = try owner.propertyValue(host.allocator, name);
    defer host.allocator.free(value);
    return string(agent, value);
}

fn mutate(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const host = getHost(agent);
    const element = try resolve(agent, host, arguments.get(0));
    const operation = try textArgument(agent, host.allocator, arguments.get(1));
    defer host.allocator.free(operation);
    const name = try textArgument(agent, host.allocator, arguments.get(2));
    defer host.allocator.free(name);
    const replacement = if (std.mem.eql(u8, operation, "text"))
        try Block.create(host.allocator, name)
    else if (try element.inlineStyle(host.allocator)) |old|
        try old.clone(host.allocator)
    else
        try Block.create(host.allocator, "");
    var transferred = false;
    defer if (!transferred) replacement.destroy();
    if (std.mem.eql(u8, operation, "set")) {
        const value = try textArgument(agent, host.allocator, arguments.get(3));
        defer host.allocator.free(value);
        const priority = try textArgument(agent, host.allocator, arguments.get(4));
        defer host.allocator.free(priority);
        if (!try replacement.setProperty(name, value, priority)) return Value.from(false);
    } else if (std.mem.eql(u8, operation, "remove")) {
        if (!replacement.removeProperty(name)) return Value.from(false);
    } else if (!std.mem.eql(u8, operation, "text")) {
        return agent.throwException(.type_error, "Invalid CSS style operation", .{});
    }
    try element.replaceInlineStyle(host.allocator, replacement);
    transferred = true;
    dom.dirtyStyleForElement(element);
    if (@import("../document/svg.zig").contains(element)) {
        @import("dom_mutation.zig").markElementLayoutDirty(element);
        dom.markPaintForElement(element);
    }
    host.request_render(host.context);
    return Value.from(true);
}

fn clone(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const host = getHost(agent);
    const source = try resolve(agent, host, arguments.get(0));
    const destination = try resolve(agent, host, arguments.get(1));
    const block = (try source.inlineStyle(host.allocator)) orelse return .undefined;
    const replacement = try block.clone(host.allocator);
    if (destination.inline_declarations) |old| old.destroy();
    destination.inline_declarations = replacement;
    destination.inline_style_revision = if (destination.attributes) |attrs| attrs.style_revision else 0;
    return .undefined;
}

fn propertyNames(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    const longhands_only = arguments.get(0).toBoolean();
    const count: u53 = @intCast(properties.computed.len + if (longhands_only) @as(usize, 0) else properties.shorthands.len);
    const result = try kiesel.builtins.arrayCreate(agent, count, null);
    var index: kiesel.types.PropertyKey.IntegerIndex = 0;
    inline for (.{ properties.computed, properties.shorthands }, 0..) |group, group_index| {
        if (group_index == 0 or !longhands_only) for (group) |property| {
            try result.object.createDataPropertyDirect(agent, kiesel.types.PropertyKey.from(index), try string(agent, property.name));
            index += 1;
        };
    }
    return Value.from(&result.object);
}
