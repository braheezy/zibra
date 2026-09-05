//! Immutable computed custom-property environments. Each environment owns a
//! flattened copy of its keys/values, so replacing an ancestor cannot retire
//! strings still used by a clean descendant. No DOM or layout pointers live here.

const std = @import("std");
const tokens = @import("css_value_tokens.zig");
const syntax = @import("css_syntax.zig");
const whitespace = " \t\r\n\x0c";
const limit = 1024 * 1024;
const max_depth = 128;

pub fn isName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "--") or name.len == 2) return false;
    var iterator = tokens.Iterator{ .input = name };
    const token = iterator.next() orelse return false;
    return token.kind == .ident and token.end == name.len;
}

const Reference = struct { name: []const u8, fallback: ?[]const u8, end: usize };

fn reference(input: []const u8, start: usize) ?Reference {
    const end = tokens.closeFunction(input, start) orelse return null;
    const comma = syntax.scanToTopLevel(input[0..end], start, ",");
    const name = std.mem.trim(u8, input[start..comma.end], whitespace);
    if (!isName(name)) return null;
    return .{ .name = name, .fallback = if (comma.delimiter != null) input[comma.end + 1 .. end] else null, .end = end };
}

const Entry = struct {
    raw: ?[]const u8,
    value: ?[]const u8 = null,
    state: enum { fresh, visiting, done } = .fresh,
    cyclic: bool = false,
};

pub const Environment = struct {
    backing: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn destroy(self: *Environment, allocator: std.mem.Allocator) void {
        self.backing.deinit();
        allocator.destroy(self);
    }

    /// All authored values are winning cascade values. Only custom names are
    /// imported. Inherited values are already computed, never re-substituted
    /// against a descendant's overrides.
    pub fn create(allocator: std.mem.Allocator, parent: ?*const Environment, authored: *const std.StringHashMap([]const u8)) !*Environment {
        const self = try allocator.create(Environment);
        self.* = .{ .backing = std.heap.ArenaAllocator.init(allocator) };
        errdefer self.destroy(allocator);
        const arena = self.backing.allocator();
        if (parent) |inherited| {
            var it = inherited.entries.iterator();
            while (it.next()) |item| {
                const value = if (item.value_ptr.value) |v| try arena.dupe(u8, v) else null;
                try self.entries.put(arena, try arena.dupe(u8, item.key_ptr.*), .{ .raw = value, .value = value, .state = .done });
            }
        }
        var it = authored.iterator();
        while (it.next()) |item| {
            if (!isName(item.key_ptr.*)) continue;
            const raw = std.mem.trim(u8, item.value_ptr.*, whitespace);
            if (std.ascii.eqlIgnoreCase(raw, "inherit") or std.ascii.eqlIgnoreCase(raw, "unset")) continue;
            const entry: Entry = if (std.ascii.eqlIgnoreCase(raw, "initial"))
                .{ .raw = null, .state = .done }
            else
                .{ .raw = try arena.dupe(u8, raw) };
            try self.entries.put(arena, try arena.dupe(u8, item.key_ptr.*), entry);
        }
        var stack: std.ArrayList([]const u8) = .empty;
        defer stack.deinit(allocator);
        var names = self.entries.keyIterator();
        while (names.next()) |name| _ = try self.resolve(name.*, &stack, allocator);
        return self;
    }

    pub fn get(self: *const Environment, name: []const u8) ?[]const u8 {
        return if (self.entries.get(name)) |entry| entry.value else null;
    }

    pub fn eql(self: *const Environment, other: ?*const Environment) bool {
        const rhs = other orelse return self.entries.count() == 0;
        if (self.entries.count() != rhs.entries.count()) return false;
        var it = self.entries.iterator();
        while (it.next()) |item| {
            const right = rhs.entries.get(item.key_ptr.*) orelse return false;
            const left = item.value_ptr.value;
            if (left == null or right.value == null) {
                if ((left == null) != (right.value == null)) return false;
            } else if (!std.mem.eql(u8, left.?, right.value.?)) return false;
        }
        return true;
    }

    fn resolve(self: *Environment, name: []const u8, stack: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !?[]const u8 {
        const entry = self.entries.getPtr(name) orelse return null;
        if (entry.state == .done) return entry.value;
        if (entry.state == .visiting) {
            var cycle = false;
            for (stack.items) |ancestor| {
                cycle = cycle or std.mem.eql(u8, ancestor, name);
                if (cycle) self.entries.getPtr(ancestor).?.cyclic = true;
            }
            return null;
        }
        if (stack.items.len >= max_depth) return null;
        entry.state = .visiting;
        try stack.append(allocator, name);
        defer _ = stack.pop();
        // All references, including unused fallbacks, form dependency edges.
        var iterator = tokens.Iterator{ .input = entry.raw.? };
        while (iterator.next()) |token| {
            if (token.kind != .function or !syntax.identifierEquals(entry.raw.?[token.start .. token.end - 1], "var")) continue;
            const ref = reference(entry.raw.?, token.end) orelse continue;
            _ = try self.resolve(ref.name, stack, allocator);
        }
        entry.value = if (entry.cyclic) null else try self.substitute(self.backing.allocator(), entry.raw.?);
        entry.state = .done;
        return entry.value;
    }

    /// Returns a caller-owned value, or null for invalid-at-computed-value-time.
    /// Expansion has explicit depth/size limits against exponential CSS input.
    pub fn substitute(self: *const Environment, allocator: std.mem.Allocator, input: []const u8) !?[]const u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        if (!try self.appendSubstituted(allocator, &output, input, 0)) return null;
        const trimmed = std.mem.trim(u8, output.items, whitespace);
        return try allocator.dupe(u8, trimmed);
    }

    fn appendSubstituted(self: *const Environment, allocator: std.mem.Allocator, output: *std.ArrayList(u8), input: []const u8, depth: usize) std.mem.Allocator.Error!bool {
        if (depth >= max_depth or input.len > limit) return false;
        var iterator = tokens.Iterator{ .input = input };
        var copied: usize = 0;
        while (iterator.next()) |token| {
            if (token.kind != .function or !syntax.identifierEquals(input[token.start .. token.end - 1], "var")) continue;
            const ref = reference(input, token.end) orelse return false;
            if (!try append(allocator, output, input[copied..token.start])) return false;
            // Preserve token boundaries: var(--n)px must not become a length.
            if (!try append(allocator, output, " ")) return false;
            if (self.get(ref.name)) |value| {
                if (!try append(allocator, output, value)) return false;
            } else if (ref.fallback) |fallback| {
                if (!try self.appendSubstituted(allocator, output, fallback, depth + 1)) return false;
            } else return false;
            if (!try append(allocator, output, " ")) return false;
            iterator.cursor = ref.end + 1;
            copied = iterator.cursor;
        }
        return append(allocator, output, input[copied..]);
    }
};

fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), input: []const u8) !bool {
    if (input.len > limit - output.items.len) return false;
    try output.appendSlice(allocator, input);
    return true;
}

test "variables resolve forward dependencies fallbacks cycles case and token boundaries" {
    const allocator = std.testing.allocator;
    var authored = std.StringHashMap([]const u8).init(allocator);
    defer authored.deinit();
    try authored.put("--font", "var(--size)");
    try authored.put("--size", "1.6rem");
    try authored.put("--a", "var(--b, red)");
    try authored.put("--b", "var(--a)");
    try authored.put("--unused-cycle", "var(--size, var(--unused-cycle))");
    try authored.put("--n", "10");
    try authored.put("--empty", "");
    const env = try Environment.create(allocator, null, &authored);
    defer env.destroy(allocator);
    try std.testing.expectEqualStrings("1.6rem", env.get("--font").?);
    try std.testing.expect(env.get("--a") == null);
    try std.testing.expect(env.get("--b") == null);
    try std.testing.expect(env.get("--unused-cycle") == null);
    try std.testing.expect(env.get("--Size") == null);
    const result = (try env.substitute(allocator, "var(--a, var(--missing, blue))")).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("blue", result);
    const boundary = (try env.substitute(allocator, "var(--n)px")).?;
    defer allocator.free(boundary);
    try std.testing.expectEqualStrings("10 px", boundary);
    const empty = (try env.substitute(allocator, "var(--empty, red)")).?;
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}
