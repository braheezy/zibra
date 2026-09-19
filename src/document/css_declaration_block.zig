//! Heap-stable ordered declaration owner for inline CSSOM and native style.
//! The arena owns source/value strings and the longhand index. Published blocks
//! are replaced transactionally; no source borrow survives their retirement.
const std = @import("std");
const declarations = @import("css_declarations.zig");
const syntax = @import("css_rule_syntax.zig");
const properties = @import("css_properties.zig");
const Declaration = declarations.Declaration;
const Block = @This();
const Storage = std.array_hash_map.String(Declaration);

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
entries: Storage = .empty,

test "value normalization shares typed primitives escapes and invalid declaration recovery" {
    const block = try create(std.testing.allocator, "width:+001.2500P\\58; padding:0 .50EM; color:RGB(100%,0%,0%);" ++
        "--\\54 one: +01.00PX  A/**/B; --bad:url(a b);" ++
        "height:10px;height:var(no-name); height:url(a b); color:'bad\n; display:block;" ++
        "font-family:'Mixed Case'; --space\\ name:var(--\\54 one);background-image:url(A\\20 B.png");
    defer block.destroy();
    try std.testing.expectEqualStrings("1.25px", block.get("width").?.value);
    try std.testing.expectEqualStrings("0px", block.get("padding-top").?.value);
    try std.testing.expectEqualStrings("0.5em", block.get("padding-left").?.value);
    try std.testing.expectEqualStrings("rgb(255, 0, 0)", block.get("color").?.value);
    try std.testing.expectEqualStrings("+01.00PX  A/**/B", block.get("--Tone").?.value);
    try std.testing.expect(block.get("--bad") == null);
    try std.testing.expectEqualStrings("10px", block.get("height").?.value);
    try std.testing.expectEqualStrings("block", block.get("display").?.value);
    try std.testing.expectEqualStrings("\"Mixed Case\"", block.get("font-family").?.value);
    try std.testing.expectEqualStrings("url(\"A B.png\")", block.get("background-image").?.value);
    const text = try block.serialize(std.testing.allocator);
    defer std.testing.allocator.free(text);
    const reparsed = try create(std.testing.allocator, text);
    defer reparsed.destroy();
    try std.testing.expectEqualStrings("var(--\\54 one)", reparsed.get("--space name").?.value);
    try std.testing.expect(!try block.setProperty("width", "1/**/px", ""));
    try std.testing.expect(!try block.setProperty("z-index", "1.0", ""));
    try std.testing.expect(!try block.setProperty("z-index", "1e2", ""));
    try std.testing.expect(try block.setProperty("border-color", "#\\31 23", ""));
    try std.testing.expectEqualStrings("rgb(17, 34, 51)", block.get("border-top-color").?.value);
    try std.testing.expect(try block.setProperty("content", "'EOF\\", ""));
    try std.testing.expectEqualStrings("\"EOF\"", block.get("content").?.value);
}

test "alignment declarations canonicalize first baseline after shorthand expansion" {
    const allocator = std.testing.allocator;
    const block = try create(allocator, "align-items:first baseline;align-self:first baseline;justify-items:first baseline;justify-self:first baseline;align-content:first baseline;--alignment:first baseline");
    defer block.destroy();
    for ([_][]const u8{ "align-items", "align-self", "justify-items", "justify-self", "align-content" }) |name| {
        try std.testing.expectEqualStrings("baseline", block.get(name).?.value);
        const text = try block.propertyValue(allocator, name);
        defer allocator.free(text);
        try std.testing.expectEqualStrings("baseline", text);
    }
    try std.testing.expectEqualStrings("first baseline", block.get("--alignment").?.value);
    try std.testing.expect(!try block.setProperty("align-items", "FIRST  BASELINE", ""));
    try std.testing.expect(try block.setProperty("align-self", "last baseline", ""));
    try std.testing.expect(!try block.setProperty("align-self", "safe first baseline", ""));
    try std.testing.expectEqualStrings("last baseline", block.get("align-self").?.value);

    try std.testing.expect(try block.setProperty("place-items", "first baseline", "important"));
    const pair = try block.propertyValue(allocator, "place-items");
    defer allocator.free(pair);
    try std.testing.expectEqualStrings("baseline", pair);
    try std.testing.expect(block.get("align-items").?.important);
    try std.testing.expect(block.get("justify-items").?.important);
    try std.testing.expect(try block.setProperty("place-items", "first baseline last baseline", "important"));
    const mixed = try block.propertyValue(allocator, "place-items");
    defer allocator.free(mixed);
    try std.testing.expectEqualStrings("baseline last baseline", mixed);

    try std.testing.expect(try block.setProperty("place-content", "first baseline", ""));
    const content = try block.propertyValue(allocator, "place-content");
    defer allocator.free(content);
    try std.testing.expectEqualStrings("baseline start", content);
    try std.testing.expect(try block.setProperty("place-items", "var(--alignment)", ""));
    const pending = try block.propertyValue(allocator, "place-items");
    defer allocator.free(pending);
    try std.testing.expectEqualStrings("var(--alignment)", pending);
}

test "normalized declaration owners clone and retire independently including allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var map = declarations.Map.init(allocator);
            var alive = true;
            defer if (alive) map.deinit();
            const source = try allocator.dupe(u8, "--\\54 one:+01PX; width:var(--Tone); color:#1234; padding:0 .25EM");
            var iterator = syntax.DeclarationIterator{ .input = source };
            declarations.parseInto(&map, &iterator) catch |err| {
                allocator.free(source);
                return err;
            };
            allocator.free(source);
            var copy = try map.clone();
            defer copy.deinit();
            map.deinit();
            alive = false;
            try std.testing.expectEqualStrings("+01PX", copy.get("--Tone").?.value);
            try std.testing.expectEqualStrings("0.25em", copy.get("padding-right").?.value);
            try std.testing.expectEqualStrings("rgba(17, 34, 51, 0.267)", copy.get("color").?.value);
        }
    }.run, .{});
}

test "mix CSSOM presentation and cloning preserve independently retained color precision" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const block = try create(allocator, "border-color:color-mix(hsl(120 10% 20%), hsl(30 30% 40%))");
            defer block.destroy();
            const before = block.get("border-top-color").?.value;
            try std.testing.expect(std.mem.indexOf(u8, before, "45.9") != null);
            const value = try block.propertyValue(allocator, "border-top-color");
            defer allocator.free(value);
            try std.testing.expectEqualStrings("color-mix(rgb(46, 56, 46), rgb(133, 102, 71))", value);
            const shorthand = try block.propertyValue(allocator, "border-color");
            defer allocator.free(shorthand);
            try std.testing.expectEqualStrings(value, shorthand);
            const text = try block.serialize(allocator);
            defer allocator.free(text);
            try std.testing.expect(std.mem.indexOf(u8, text, value) != null);
            const copy = try block.clone(allocator);
            defer copy.destroy();
            try std.testing.expectEqualStrings(before, copy.get("border-top-color").?.value);
            try std.testing.expectEqualStrings(before, block.get("border-top-color").?.value);
        }
    }.run, .{});
}

test "CSS background grammar and serialization preserve full position groups and trailing components" {
    const block = try create(std.testing.allocator, "background: url(tile.png) top 5px right -10% / 20px 30px no-repeat fixed rgb(0 100 0 / 75%);");
    defer block.destroy();
    try std.testing.expectEqualStrings("right -10% top 5px", block.get("background-position").?.value);
    try std.testing.expectEqualStrings("20px 30px", block.get("background-size").?.value);
    try std.testing.expectEqualStrings("rgba(0, 100, 0, 0.75)", block.get("background-color").?.value);
    const text = try block.serialize(std.testing.allocator);
    defer std.testing.allocator.free(text);
    const copy = try create(std.testing.allocator, text);
    defer copy.destroy();
    for (shorthandFor("background").?.longhands) |name|
        try std.testing.expectEqualStrings(block.get(name).?.value, copy.get(name).?.value);
    for ([_][]const u8{ "red / 10px", "left right", "left red top", "left / 10px 20px 30px", "right 2px 4px" }) |invalid|
        try std.testing.expect(!try block.setProperty("background", invalid, ""));
    try std.testing.expect(!try block.setProperty("color", "rgb(20%, 30%, 40)", ""));
    try std.testing.expect(try block.setProperty("background-position", "-2% -3%", ""));
    try std.testing.expectEqualStrings("-2% -3%", block.get("background-position").?.value);
    try std.testing.expect(try block.setProperty("background", "green", ""));
    try std.testing.expectEqualStrings("0% 0%", block.get("background-position").?.value);
    try std.testing.expect(try block.setProperty("background-position", "0 0", ""));
    try std.testing.expectEqualStrings("0px 0px", block.get("background-position").?.value);
}

/// Returns an owned, heap-stable block. Source is copied before parsing.
pub fn create(allocator: std.mem.Allocator, source: []const u8) !*Block {
    const self = try allocator.create(Block);
    self.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer self.destroy();
    const owned = try self.arena.allocator().dupe(u8, source);
    var iterator = syntax.DeclarationIterator{ .input = owned };
    try declarations.parseInto(self, &iterator);
    return self;
}

pub fn destroy(self: *Block) void {
    const allocator = self.allocator;
    self.arena.deinit();
    allocator.destroy(self);
}

/// Deep copy including pending shorthand substitutions. Re-serializing and
/// parsing cannot clone a partially overridden var() shorthand faithfully.
pub fn clone(self: *const Block, allocator: std.mem.Allocator) !*Block {
    const result = try create(allocator, "");
    errdefer result.destroy();
    try result.entries.ensureTotalCapacity(result.arena.allocator(), self.entries.count());
    for (self.entries.keys(), self.entries.values()) |name, value| {
        const copy = try result.copyEntry(name, value);
        result.entries.putAssumeCapacity(copy.name, copy.declaration);
    }
    return result;
}

pub fn count(self: *const Block) usize {
    return self.entries.count();
}

/// Borrows a canonical longhand/custom name until block retirement.
pub fn item(self: *const Block, index: usize) []const u8 {
    return if (index < self.count()) self.entries.keys()[index] else "";
}

/// Declaration sink lookup; values are borrows, including pending substitutions.
pub fn get(self: *const Block, name: []const u8) ?Declaration {
    return self.entries.get(name);
}

/// Stable strings for semantic declaration emission; borrow until retirement.
pub fn valueAllocator(self: *Block) std.mem.Allocator {
    return self.arena.allocator();
}

/// Parser sink insertion. parseInto has already checked priority: the winning
/// declaration takes its last authored position, unlike a CSSOM setter.
/// Names and declaration strings must come from valueAllocator or static
/// storage; this sink retains them until the block is destroyed.
pub fn put(self: *Block, name: []const u8, declaration: Declaration) !void {
    _ = self.entries.orderedRemove(name);
    try self.entries.put(self.arena.allocator(), name, declaration);
}

const Entry = struct { name: []const u8, declaration: Declaration };

fn copyEntry(self: *Block, name: []const u8, value: Declaration) !Entry {
    const allocator = self.arena.allocator();
    return .{ .name = try allocator.dupe(u8, name), .declaration = .{
        .value = try allocator.dupe(u8, value.value),
        .important = value.important,
        .pending_shorthand = if (value.pending_shorthand) |pending| try allocator.dupe(u8, pending) else null,
    } };
}

/// Mutate an unpublished block. Invalid/identical assignments return false.
/// Stage/clone the published block first: OOM requires discarding this candidate.
/// A setter replaces priority and keeps existing positions; new names append.
pub fn setProperty(self: *Block, raw_name: []const u8, value: []const u8, priority: []const u8) !bool {
    const name = declarations.canonicalDecodedPropertyName(raw_name) orelse return false;
    if (value.len == 0) return self.removeProperty(name);
    if (priority.len != 0 and !std.ascii.eqlIgnoreCase(priority, "important")) return false;
    if (!declarations.validSetterValue(value)) return false;
    const staged = try create(self.allocator, "");
    defer staged.destroy();
    try declarations.putParsed(staged, name, value, priority.len != 0);
    var changed = false;
    try self.entries.ensureUnusedCapacity(self.arena.allocator(), staged.count());
    for (staged.entries.keys(), staged.entries.values()) |key, declaration| {
        if (self.get(key)) |old| {
            if (equalDeclaration(old, declaration)) continue;
        }
        const copy = try self.copyEntry(key, declaration);
        self.entries.putAssumeCapacity(copy.name, copy.declaration);
        changed = true;
    }
    return changed;
}

/// Remove a property or all of a shorthand's longhands, preserving other order.
pub fn removeProperty(self: *Block, raw_name: []const u8) bool {
    const name = declarations.canonicalDecodedPropertyName(raw_name) orelse return false;
    if (shorthandFor(name)) |shorthand| {
        var changed = false;
        for (shorthand.longhands) |longhand| changed = self.entries.orderedRemove(longhand) or changed;
        return changed;
    }
    return self.entries.orderedRemove(name);
}

pub fn propertyImportant(self: *const Block, raw_name: []const u8) bool {
    const name = declarations.canonicalDecodedPropertyName(raw_name) orelse return false;
    if (shorthandFor(name)) |shorthand| {
        for (shorthand.longhands) |longhand| {
            if (!(self.get(longhand) orelse return false).important) return false;
        }
        return true;
    }
    return if (self.get(name)) |value| value.important else false;
}

/// Caller owns the returned CSSOM string. Pending longhands serialize empty;
/// their original shorthand can serialize only when all its components agree.
pub fn propertyValue(self: *const Block, allocator: std.mem.Allocator, raw_name: []const u8) ![]u8 {
    const name = declarations.canonicalDecodedPropertyName(raw_name) orelse return allocator.dupe(u8, "");
    if (shorthandFor(name)) |shorthand| return self.shorthandValue(allocator, shorthand);
    const value = self.get(name) orelse return allocator.dupe(u8, "");
    if (value.pending_shorthand == null) if (try valuePresentation(allocator, name, value.value)) |text| return text;
    return allocator.dupe(u8, if (value.pending_shorthand != null) "" else value.value);
}

// Retained color operands have more precision than legacy CSSOM presentation.
// Custom values and pending substitutions remain opaque to this boundary.
fn valuePresentation(allocator: std.mem.Allocator, name: []const u8, source: []const u8) !?[]u8 {
    const property = properties.get(name) orelse return null;
    if (@import("css_value_tokens.zig").hasVariable(source)) return null;
    if (property.serialization == .image) return @import("css_gradient.zig").serialize(allocator, source, .{}, .specified);
    if (property.serialization != .color) return null;
    const colors = @import("color.zig");
    return if (colors.isMix(source)) try colors.serializeSpecified(allocator, source) else null;
}

test "gradient declaration clones preserve fractional operands beyond CSSOM presentation" {
    const allocator = std.testing.allocator;
    const block = try create(allocator, "background: l\\69 near-gradient(r\\65 d, rgb(10.25 20.5 30.75)) no-repeat");
    defer block.destroy();
    try std.testing.expectEqualStrings("linear-gradient(red, rgb(10.25, 20.5, 30.75))", block.get("background-image").?.value);
    const text = try block.propertyValue(allocator, "background-image");
    defer allocator.free(text);
    try std.testing.expectEqualStrings("linear-gradient(red, rgb(10, 21, 31))", text);
    const copy = try block.clone(allocator);
    defer copy.destroy();
    try std.testing.expectEqualStrings(block.get("background-image").?.value, copy.get("background-image").?.value);
}

fn shorthandFor(name: []const u8) ?properties.Shorthand {
    for (properties.shorthands) |candidate| if (std.mem.eql(u8, name, candidate.name)) return candidate;
    return null;
}

fn equalDeclaration(a: Declaration, b: Declaration) bool {
    return a.important == b.important and std.mem.eql(u8, a.value, b.value) and
        std.mem.eql(u8, a.pending_shorthand orelse "", b.pending_shorthand orelse "");
}

fn cssWide(value: []const u8) bool {
    for ([_][]const u8{ "initial", "inherit", "unset", "revert", "revert-layer" }) |keyword| {
        if (std.ascii.eqlIgnoreCase(value, keyword)) return true;
    }
    return false;
}

fn shorthandValue(self: *const Block, allocator: std.mem.Allocator, shorthand: properties.Shorthand) ![]u8 {
    var values: [12][]const u8 = undefined;
    const first = self.get(shorthand.longhands[0]) orelse return allocator.dupe(u8, "");
    var same = true;
    var pending = false;
    var wide = false;
    for (shorthand.longhands, 0..) |name, i| {
        const value = self.get(name) orelse return allocator.dupe(u8, "");
        if (value.important != first.important) return allocator.dupe(u8, "");
        values[i] = value.value;
        same = same and equalDeclaration(first, value);
        pending = pending or value.pending_shorthand != null;
        wide = wide or cssWide(value.value);
    }
    if (pending) return allocator.dupe(u8, if (same and std.mem.eql(u8, first.pending_shorthand orelse "", shorthand.name)) first.value else "");
    if (wide) return allocator.dupe(u8, if (same) first.value else "");
    var color_text = [_]?[]u8{null} ** 12;
    defer for (color_text) |owned| if (owned) |text| allocator.free(text);
    for (shorthand.longhands, 0..) |longhand, i| {
        color_text[i] = try valuePresentation(allocator, longhand, values[i]);
        if (color_text[i]) |text| values[i] = text;
    }
    const name = shorthand.name;
    const parts = values[0..shorthand.longhands.len];
    if (std.mem.eql(u8, name, "animation")) {
        // A single-name engine may retain unused extra longhand list items.
        // Such lists cannot be losslessly represented by its shorthand.
        for (parts) |part| if (@import("css_syntax.zig").scanToTopLevel(part, 0, ",").delimiter != null) return allocator.dupe(u8, "");
        return std.mem.join(allocator, " ", parts);
    }
    if (parts.len == 4) {
        var n: usize = 4;
        if (std.mem.eql(u8, parts[1], parts[3])) {
            n = 3;
            if (std.mem.eql(u8, parts[0], parts[2])) {
                n = 2;
                if (std.mem.eql(u8, parts[0], parts[1])) n = 1;
            }
        }
        return std.mem.join(allocator, " ", parts[0..n]);
    }
    if (std.mem.eql(u8, name, "border")) {
        for (0..3) |group| {
            for (1..4) |side| if (!std.mem.eql(u8, parts[group * 4], parts[group * 4 + side])) return allocator.dupe(u8, "");
        }
        return std.mem.join(allocator, " ", &.{ parts[0], parts[4], parts[8] });
    }
    if (std.mem.eql(u8, name, "font")) {
        var components: std.ArrayList([]const u8) = .empty;
        defer components.deinit(allocator);
        for (parts[0..4]) |part| if (!std.ascii.eqlIgnoreCase(part, "normal")) try components.append(allocator, part);
        const size = if (std.ascii.eqlIgnoreCase(parts[5], "normal")) try allocator.dupe(u8, parts[4]) else try std.fmt.allocPrint(allocator, "{s} / {s}", .{ parts[4], parts[5] });
        defer allocator.free(size);
        try components.appendSlice(allocator, &.{ size, parts[6] });
        return std.mem.join(allocator, " ", components.items);
    }
    if (std.mem.eql(u8, name, "background")) {
        // Box keywords in the shorthand also set background-clip, which is not
        // supported yet. Preserve a nondefault origin as separate longhands.
        if (!std.mem.eql(u8, parts[6], "padding-box")) return allocator.dupe(u8, "");
        return std.fmt.allocPrint(allocator, "{s} {s} / {s} {s} {s} {s}", .{ parts[1], parts[4], parts[2], parts[3], parts[5], parts[0] });
    }
    if (parts.len == 2 and !std.mem.eql(u8, name, "flex-flow") and std.mem.eql(u8, parts[0], parts[1])) return allocator.dupe(u8, parts[0]);
    return std.mem.join(allocator, " ", parts);
}

/// Serialize supported shorthands and normalized values; caller owns text.
/// Custom values and pending substitutions retain their authored spelling.
/// Partial pending substitutions have empty CSSOM longhand text. Keep the block
/// itself when publishing an attribute; parsing this serialization loses them.
pub fn serialize(self: *const Block, allocator: std.mem.Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const done = try allocator.alloc(bool, self.count());
    defer allocator.free(done);
    @memset(done, false);
    for (self.entries.keys(), self.entries.values(), 0..) |key, declaration, index| {
        if (done[index]) continue;
        var best: ?properties.Shorthand = null;
        var best_value: ?[]u8 = null;
        defer if (best_value) |value| allocator.free(value);
        for (properties.shorthands) |candidate| {
            if (best != null and candidate.longhands.len <= best.?.longhands.len) continue;
            var contains = false;
            var available = true;
            for (candidate.longhands) |longhand| {
                contains = contains or std.mem.eql(u8, longhand, key);
                if (self.entries.getIndex(longhand)) |i| {
                    available = available and !done[i];
                } else available = false;
            }
            if (!contains or !available) continue;
            const value = try self.shorthandValue(allocator, candidate);
            if (value.len == 0) {
                allocator.free(value);
                continue;
            }
            if (best_value) |old| allocator.free(old);
            best = candidate;
            best_value = value;
        }
        if (best) |shorthand| {
            for (shorthand.longhands) |longhand| done[self.entries.getIndex(longhand).?] = true;
        } else done[index] = true;
        if (output.items.len > 0) try output.append(allocator, ' ');
        const serialized_name = try @import("css_values.zig").serializeIdentifier(allocator, if (best) |shorthand| shorthand.name else key);
        defer allocator.free(serialized_name);
        try output.appendSlice(allocator, serialized_name);
        try output.appendSlice(allocator, ": ");
        const presented = if (best_value == null and declaration.pending_shorthand == null) try valuePresentation(allocator, key, declaration.value) else null;
        defer if (presented) |text| allocator.free(text);
        try output.appendSlice(allocator, best_value orelse presented orelse if (declaration.pending_shorthand == null) declaration.value else "");
        if (declaration.important) try output.appendSlice(allocator, " !important");
        try output.append(allocator, ';');
    }
    return output.toOwnedSlice(allocator);
}

test "ordered declarations share grammar, recovery, and component-aware priority" {
    const block = try create(std.testing.allocator, "color:red; width:10px; color:blue !/**/\\69mportant /**/; color:green;" ++
        "width:garbage; unknown:foo; @future {color: red;} --Text:'a;!important';" ++
        "--url:url(a!important); --nested:[!important]; --bad:x !other; height:20px; --empty:!important;");
    defer block.destroy();
    try std.testing.expectEqual(7, block.count());
    try std.testing.expectEqualStrings("width", block.item(0));
    try std.testing.expectEqualStrings("color", block.item(1));
    try std.testing.expectEqualStrings("blue", block.get("color").?.value);
    try std.testing.expect(block.propertyImportant("COLOR"));
    try std.testing.expectEqualStrings("'a;!important'", block.get("--Text").?.value);
    try std.testing.expect(!block.propertyImportant("--Text"));
    try std.testing.expectEqualStrings("[!important]", block.get("--nested").?.value);
    try std.testing.expect(block.get("--bad") == null);
    try std.testing.expectEqualStrings("", block.get("--empty").?.value);
}

test "CSSOM setters preserve positions, override importance and reject declaration injection" {
    const allocator = std.testing.allocator;
    const block = try create(allocator, "color:red!important; width:10px; margin:1px 2px; --Tone:blue");
    defer block.destroy();
    try std.testing.expect(try block.setProperty("color", "green", ""));
    try std.testing.expectEqualStrings("color", block.item(0));
    try std.testing.expect(!block.propertyImportant("color"));
    try std.testing.expect(try block.setProperty("padding", "3px", "important"));
    try std.testing.expectEqualStrings("padding-top", block.item(7));
    try std.testing.expect(!(try block.setProperty("padding", "3px -1px", "")));
    try std.testing.expect(!(try block.setProperty("width", "20px; color:red", "")));
    try std.testing.expect(!(try block.setProperty("--Tone", "red !important", "")));
    try std.testing.expect(!(try block.setProperty("width", "20px", " important")));
    try std.testing.expect(try block.setProperty("--tone", "green", ""));
    try std.testing.expect(block.get("--Tone") != null and block.get("--tone") != null);
    const margin = try block.propertyValue(allocator, "margin");
    defer allocator.free(margin);
    try std.testing.expectEqualStrings("1px 2px", margin);
    try std.testing.expect(try block.setProperty("margin", "", "invalid-priority"));
    try std.testing.expect(!block.removeProperty("margin"));
    try std.testing.expect(block.get("margin-top") == null);
    try std.testing.expectEqualStrings("padding-top", block.item(3));
}

test "CSSOM serializes priority winners and retains partial pending shorthand data" {
    const allocator = std.testing.allocator;
    const block = try create(allocator, "padding:10px!important; padding-left:20px; margin:var(--space)");
    defer block.destroy();
    const initial = try block.serialize(allocator);
    defer allocator.free(initial);
    try std.testing.expectEqualStrings("padding: 10px !important; margin: var(--space);", initial);
    try std.testing.expect(try block.setProperty("margin-left", "2px", ""));
    const value = try block.propertyValue(allocator, "margin-right");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("", value);
    const copy = try block.clone(allocator);
    defer copy.destroy();
    try std.testing.expect(copy.removeProperty("margin-top"));
    try std.testing.expectEqualStrings("margin", copy.get("margin-right").?.pending_shorthand.?);
    try std.testing.expectEqualStrings("var(--space)", copy.get("margin-right").?.value);
    try std.testing.expect(block.get("margin-top") != null);
    try std.testing.expectEqualStrings("2px", copy.get("margin-left").?.value);
}

fn allocationTrial(allocator: std.mem.Allocator) !void {
    const block = try create(allocator, "color:green; margin:var(--space); --space:1px 2px;");
    defer block.destroy();
    const replacement = try block.clone(allocator);
    defer replacement.destroy();
    _ = try replacement.setProperty("margin-left", "3px", "important");
    const source = try replacement.serialize(allocator);
    defer allocator.free(source);
    const value = try replacement.propertyValue(allocator, "margin");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("var(--space)", block.get("margin-left").?.value);
}

test "declaration owners release all allocations when staging fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrial, .{});
}

test "supported shorthand serialization preserves native declarations when reparsed" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "background:green",                                         "background:url(a.png) no-repeat fixed left top / 20px 30px",
        "font:italic bold 20px / 2 sans-serif",                     "flex:2; flex-flow:column wrap",
        "gap:2px 4px; place-items:center; place-content:end start", "margin:1px 2px 3px 4px; padding:var(--space)",
        "border:1px solid red",                                     "border-top:2px dotted blue; border-left:3px dashed green",
        "list-style:disc",
    }) |source| {
        errdefer std.debug.print("Shorthand source: {s}\n", .{source});
        const before = try create(allocator, source);
        defer before.destroy();
        try std.testing.expect(before.count() != 0);
        const serialized = try before.serialize(allocator);
        defer allocator.free(serialized);
        errdefer std.debug.print("Serialized shorthand: {s}\n", .{serialized});
        const after = try create(allocator, serialized);
        defer after.destroy();
        try std.testing.expectEqual(before.count(), after.count());
        for (before.entries.keys(), before.entries.values()) |name, value| {
            errdefer std.debug.print("Longhand: {s}\n", .{name});
            try std.testing.expectEqualStrings(value.value, after.get(name).?.value);
            try std.testing.expect(equalDeclaration(value, after.get(name).?));
        }
    }
}

test "background origin normalization precedence resets and CSSOM round trips" {
    const allocator = std.testing.allocator;
    const block = try create(allocator, "background:green; background-origin: C\\6f NTENT-box");
    defer block.destroy();
    try std.testing.expectEqualStrings("content-box", block.get("background-origin").?.value);
    const text = try block.serialize(allocator);
    defer allocator.free(text);
    const copy = try create(allocator, text);
    defer copy.destroy();
    try std.testing.expectEqualStrings("content-box", copy.get("background-origin").?.value);
    for ([_][]const u8{ "text", "margin-box", "content-box border-box", "border-box,", ",content-box", "border-box,,content-box" }) |invalid|
        try std.testing.expect(!try block.setProperty("background-origin", invalid, ""));
    try std.testing.expect(try block.setProperty("background", "red", ""));
    try std.testing.expectEqualStrings("padding-box", block.get("background-origin").?.value);
    try std.testing.expect(try block.setProperty("background-origin", "BORDER-BOX,content-box", ""));
    try std.testing.expectEqualStrings("border-box, content-box", block.get("background-origin").?.value);
    const important = try create(allocator, "background-origin:border-box!important; background:green");
    defer important.destroy();
    try std.testing.expectEqualStrings("border-box", important.get("background-origin").?.value);
    const reversed = try create(allocator, "background:green!important; background-origin:content-box");
    defer reversed.destroy();
    try std.testing.expectEqualStrings("padding-box", reversed.get("background-origin").?.value);
    try std.testing.expect(try block.setProperty("background", "inherit", ""));
    try std.testing.expectEqualStrings("inherit", block.get("background-origin").?.value);
}
