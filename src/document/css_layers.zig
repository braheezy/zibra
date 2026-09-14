//! Compiled layer declarations and a staged per-origin cascade-layer tree.
//! Programs own decoded names. Registries copy names and resolve document-wide
//! order; published cascade keys retain only scalar ranks, never tree pointers.
const std = @import("std");
const tokens = @import("css_tokenizer.zig");

pub const unlayered = std.math.maxInt(usize);
pub const max_depth = 64;

/// Compilation and selection use different index spaces. Only none/ordered
/// references may reach the cascade; this prevents comparing temporary IDs.
pub const Reference = union(enum) {
    none,
    declaration: usize,
    registered: usize,
    ordered: usize,

    pub fn order(self: Reference) usize {
        return switch (self) {
            .none => unlayered,
            .ordered => |rank| rank,
            else => unreachable,
        };
    }
};

pub const Declaration = struct {
    name: ?[]u8,
    parent: ?usize,
    condition: ?usize,
    depth: usize,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    declarations: std.ArrayList(Declaration) = .empty,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Program) void {
        self.truncate(0);
        self.declarations.deinit(self.allocator);
        self.* = undefined;
    }

    /// Roll back declarations appended after a parser checkpoint.
    pub fn truncate(self: *Program, start: usize) void {
        for (self.declarations.items[start..]) |declaration| if (declaration.name) |name| self.allocator.free(name);
        self.declarations.shrinkRetainingCapacity(start);
    }

    fn appendSegment(self: *Program, name: ?[]u8, parent: ?usize, condition: ?usize) !usize {
        errdefer if (name) |value| self.allocator.free(value);
        const depth = if (parent) |index| self.declarations.items[index].depth + 1 else 1;
        if (depth > max_depth) return error.InvalidLayerName;
        const index = self.declarations.items.len;
        try self.declarations.append(self.allocator, .{ .name = name, .parent = parent, .condition = condition, .depth = depth });
        return index;
    }

    /// Parse a whole block/statement prelude transactionally. Anonymous blocks
    /// gain a unique declaration; statements require a nonempty name list.
    /// Names are case-sensitive, escaped dots stay in identifiers, and dots
    /// between segments permit comments but no whitespace.
    pub fn parse(self: *Program, input: []const u8, block: bool, parent: ?usize, condition: ?usize) !?usize {
        const start = self.declarations.items.len;
        errdefer self.truncate(start);
        var iterator = tokens.Iterator{ .input = input };
        var token = next(&iterator, true);
        if (token == null) {
            if (!block) return error.InvalidLayerName;
            return try self.appendSegment(null, parent, condition);
        }
        var current_parent = parent;
        while (true) {
            const ident = token orelse return error.InvalidLayerName;
            if (ident.kind != .ident) return error.InvalidLayerName;
            const name = try tokens.decode(self.allocator, ident.encodedValue(input), false);
            for ([_][]const u8{ "initial", "inherit", "unset", "revert", "revert-layer", "revert-rule" }) |reserved| {
                if (std.ascii.eqlIgnoreCase(name, reserved)) {
                    self.allocator.free(name);
                    return error.InvalidLayerName;
                }
            }
            current_parent = try self.appendSegment(name, current_parent, condition);
            token = next(&iterator, false);
            if (token != null and token.?.kind == .delim and token.?.delim == '.') {
                token = next(&iterator, false);
                continue;
            }
            if (token != null and token.?.kind == .whitespace) token = next(&iterator, true);
            if (token == null) return if (block) current_parent else null;
            if (block or token.?.kind != .comma) return error.InvalidLayerName;
            current_parent = parent;
            token = next(&iterator, true);
        }
    }

    /// Register applicable occurrences in source order. The owned result maps
    /// local declarations to registry IDs; inactive declarations map to null.
    /// Failure leaves both owners at their checkpoints.
    pub fn register(self: Program, allocator: std.mem.Allocator, registry: *Registry, active: []const bool) ![]?usize {
        const start = registry.nodes.items.len;
        errdefer registry.truncate(start);
        const ids = try allocator.alloc(?usize, self.declarations.items.len);
        errdefer allocator.free(ids);
        @memset(ids, null);
        for (self.declarations.items, 0..) |declaration, i| {
            if (declaration.condition) |condition| if (!active[condition]) continue;
            const parent = if (declaration.parent) |index| ids[index] orelse continue else null;
            ids[i] = try registry.declare(declaration.name, parent);
        }
        return ids;
    }
};

fn next(iterator: *tokens.Iterator, whitespace: bool) ?tokens.Token {
    while (iterator.next()) |token| {
        if (token.kind == .comment or (whitespace and token.kind == .whitespace)) continue;
        return token;
    }
    return null;
}

const Name = struct { parent: ?usize, text: []const u8 };
const NameContext = struct {
    pub fn hash(_: @This(), key: Name) u64 {
        var hasher = std.hash.Wyhash.init(@intCast(key.parent orelse unlayered));
        hasher.update(key.text);
        return hasher.final();
    }
    pub fn eql(_: @This(), a: Name, b: Name) bool {
        return a.parent == b.parent and std.mem.eql(u8, a.text, b.text);
    }
};
const Node = struct {
    name: ?[]u8,
    parent: ?usize,
    first_child: ?usize = null,
    last_child: ?usize = null,
    previous: ?usize = null,
    next: ?usize = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    names: std.HashMap(Name, usize, NameContext, std.hash_map.default_max_load_percentage),
    first_root: ?usize = null,
    last_root: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .names = .init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        self.names.deinit();
        for (self.nodes.items) |node| if (node.name) |name| self.allocator.free(name);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Remove appended nodes in reverse order, repairing surviving sibling
    /// links before retiring the copied names borrowed by the lookup table.
    pub fn truncate(self: *Registry, start: usize) void {
        while (self.nodes.items.len > start) {
            const node = self.nodes.pop().?;
            if (node.name) |name| {
                _ = self.names.remove(.{ .parent = node.parent, .text = name });
                self.allocator.free(name);
            }
            if (node.previous) |previous| self.nodes.items[previous].next = null;
            if (node.parent) |parent| {
                self.nodes.items[parent].last_child = node.previous;
                if (node.previous == null) self.nodes.items[parent].first_child = null;
            } else {
                self.last_root = node.previous;
                if (node.previous == null) self.first_root = null;
            }
        }
    }

    fn declare(self: *Registry, name: ?[]const u8, parent: ?usize) !usize {
        if (name) |text| if (self.names.get(.{ .parent = parent, .text = text })) |id| return id;
        const copied = if (name) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (copied) |text| self.allocator.free(text);
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        if (copied != null) try self.names.ensureUnusedCapacity(1);
        const id = self.nodes.items.len;
        const previous = if (parent) |index| self.nodes.items[index].last_child else self.last_root;
        self.nodes.appendAssumeCapacity(.{ .name = copied, .parent = parent, .previous = previous });
        if (copied) |text| self.names.putAssumeCapacity(.{ .parent = parent, .text = text }, id);
        if (previous) |index| self.nodes.items[index].next = id;
        if (parent) |index| {
            if (previous == null) self.nodes.items[index].first_child = id;
            self.nodes.items[index].last_child = id;
        } else {
            if (previous == null) self.first_root = id;
            self.last_root = id;
        }
        return id;
    }

    /// Owns one normal-cascade rank per registered layer. Child layers precede
    /// their parent's implicit outer layer. Resolve only after all sheets have
    /// registered: a later sheet may append children to an earlier layer.
    pub fn orders(self: Registry, allocator: std.mem.Allocator) ![]usize {
        const result = try allocator.alloc(usize, self.nodes.items.len);
        var rank: usize = 0;
        self.assignOrders(self.first_root, result, &rank);
        return result;
    }

    fn assignOrders(self: Registry, first: ?usize, result: []usize, rank: *usize) void {
        var current = first;
        while (current) |id| : (current = self.nodes.items[id].next) {
            self.assignOrders(self.nodes.items[id].first_child, result, rank);
            result[id] = rank.*;
            rank.* += 1;
        }
    }
};

test "layer name grammar decodes identifiers and rejects invalid lists atomically" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    const escaped = (try program.parse("foo\\.bar/**/.b\\61 z", true, null, null)).?;
    try std.testing.expectEqualStrings("baz", program.declarations.items[escaped].name.?);
    try std.testing.expectEqualStrings("foo.bar", program.declarations.items[program.declarations.items[escaped].parent.?].name.?);
    _ = try program.parse("default, Default, --custom, \\31 23", false, null, null);
    const count = program.declarations.items.len;
    for ([_][]const u8{ "", "base,", "base,,theme", "base .theme", "base. theme", "base..theme", "base.initial", "INHERIT", "\\75 nset", "base, revert-layer", "base, theme default", "123", "'quoted'" }) |invalid| {
        try std.testing.expectError(error.InvalidLayerName, program.parse(invalid, false, null, null));
        try std.testing.expectEqual(count, program.declarations.items.len);
    }
    try std.testing.expectError(error.InvalidLayerName, program.parse("base, theme", true, null, null));
    try std.testing.expectEqual(count, program.declarations.items.len);
    const anonymous = (try program.parse("/**/", true, null, null)).?;
    try std.testing.expectEqual(null, program.declarations.items[anonymous].name);
}

test "layer registry groups nested layers across sheets and keeps anonymous occurrences distinct" {
    const allocator = std.testing.allocator;
    var first = Program.init(allocator);
    defer first.deinit();
    const base = (try first.parse("base", true, null, null)).?;
    const theme = (try first.parse("theme", true, null, null)).?;
    const anonymous = (try first.parse("", true, null, null)).?;
    const child = (try first.parse("child", true, anonymous, null)).?;
    const reopened = (try first.parse("child", true, anonymous, null)).?;
    var second = Program.init(allocator);
    defer second.deinit();
    const late_child = (try second.parse("base.later", true, null, null)).?;
    const other_anonymous = (try second.parse("", true, null, null)).?;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    const a = try first.register(allocator, &registry, &.{});
    defer allocator.free(a);
    const b = try second.register(allocator, &registry, &.{});
    defer allocator.free(b);
    const orders = try registry.orders(allocator);
    defer allocator.free(orders);
    try std.testing.expectEqual(a[child], a[reopened]);
    try std.testing.expect(a[anonymous] != b[other_anonymous]);
    try std.testing.expect(orders[b[late_child].?] < orders[a[base].?]);
    try std.testing.expect(orders[a[base].?] < orders[a[theme].?]);
    try std.testing.expect(orders[a[child].?] < orders[a[anonymous].?]);
    try std.testing.expect(orders[a[anonymous].?] < orders[b[other_anonymous].?]);
}

test "layer conditional declarations establish order only when active" {
    const allocator = std.testing.allocator;
    var program = Program.init(allocator);
    defer program.deinit();
    _ = try program.parse("theme", false, null, 0);
    const base = (try program.parse("base", true, null, null)).?;
    const theme = (try program.parse("theme", true, null, null)).?;
    for ([_]bool{ false, true }) |active| {
        var registry = Registry.init(allocator);
        defer registry.deinit();
        const ids = try program.register(allocator, &registry, &.{active});
        defer allocator.free(ids);
        const orders = try registry.orders(allocator);
        defer allocator.free(orders);
        try std.testing.expectEqual(!active, orders[ids[base].?] < orders[ids[theme].?]);
        try std.testing.expectEqual(!active, ids[0] == null);
    }
}

fn layerAllocationTrial(allocator: std.mem.Allocator) !void {
    var program = Program.init(allocator);
    defer program.deinit();
    _ = try program.parse("base.first, base.second, theme, theme.child", false, null, null);
    _ = try program.parse("", true, null, null);
    var registry = Registry.init(allocator);
    defer registry.deinit();
    const root = try registry.declare("existing", null);
    const child = try registry.declare("child", root);
    const start = registry.nodes.items.len;
    const ids = program.register(allocator, &registry, &.{}) catch |err| {
        try std.testing.expectEqual(start, registry.nodes.items.len);
        try std.testing.expectEqual(root, registry.first_root.?);
        try std.testing.expectEqual(root, registry.last_root.?);
        try std.testing.expectEqual(child, registry.nodes.items[root].last_child.?);
        try std.testing.expectEqual(null, registry.nodes.items[root].next);
        return err;
    };
    defer allocator.free(ids);
    const orders = try registry.orders(allocator);
    defer allocator.free(orders);
    try std.testing.expectEqual(@as(usize, 8), orders.len);
    registry.truncate(start);
    try std.testing.expectEqual(@as(usize, 2), registry.names.count());
    try std.testing.expectEqual(null, registry.nodes.items[root].next);
}

test "layer program and registry unwind every allocation failure and repair surviving links" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, layerAllocationTrial, .{});
}

test "layer depth limit rolls back only the rejected declaration" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    var parent: ?usize = null;
    for (0..max_depth) |_| parent = try program.parse("nested", true, parent, null);
    try std.testing.expectError(error.InvalidLayerName, program.parse("one.too-many", true, parent, null));
    try std.testing.expectEqual(max_depth, program.declarations.items.len);
}
