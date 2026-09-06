//! Bounded declarative SVG animation sampling. Samples own strings separately
//! from authored attributes; the Tab owns time and repaint scheduling.
const std = @import("std");
const colors = @import("color.zig");

pub const State = struct {
    values: std.StringHashMap([]const u8),
    pub fn deinit(self: *State) void {
        var iterator = self.values.iterator();
        while (iterator.next()) |entry| {
            self.values.allocator.free(entry.key_ptr.*);
            self.values.allocator.free(entry.value_ptr.*);
        }
        self.values.deinit();
    }
};

fn attr(element: anytype, name: []const u8) ?[]const u8 {
    const attributes = element.attributes orelse return null;
    if (attributes.get(name)) |value| return value;
    var iterator = attributes.iterator();
    while (iterator.next()) |entry| if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    return null;
}
fn clock(value: []const u8) ?f64 {
    var raw = std.mem.trim(u8, value, " \t\r\n");
    var scale: f64 = 1;
    if (std.mem.endsWith(u8, raw, "ms")) {
        raw = raw[0 .. raw.len - 2];
        scale = 0.001;
    } else if (std.mem.endsWith(u8, raw, "s")) raw = raw[0 .. raw.len - 1];
    const number = std.fmt.parseFloat(f64, raw) catch return null;
    return if (std.math.isFinite(number)) number * scale else null;
}
const Timing = struct { begin: f64, duration: f64, repeats: f64 };
fn timing(element: anytype) ?Timing {
    if (!std.ascii.eqlIgnoreCase(element.tag, "animate") and !std.ascii.eqlIgnoreCase(element.tag, "animateTransform") and !std.ascii.eqlIgnoreCase(element.tag, "set")) return null;
    const property = attr(element, "attributeName") orelse return null;
    const supported = for ([_][]const u8{ "x", "y", "cx", "cy", "r", "rx", "ry", "width", "height", "x1", "y1", "x2", "y2", "opacity", "fill-opacity", "stroke-opacity", "stroke-width", "fill", "stroke", "color", "transform", "visibility" }) |name| {
        if (std.mem.eql(u8, property, name)) break true;
    } else false;
    if (!supported) return null;
    if (std.ascii.eqlIgnoreCase(element.tag, "animateTransform")) {
        const kind = attr(element, "type") orelse return null;
        const valid = for ([_][]const u8{ "translate", "scale", "rotate", "skewX", "skewY" }) |name| {
            if (std.mem.eql(u8, kind, name)) break true;
        } else false;
        if (!valid) return null;
    }
    const begin = clock(attr(element, "begin") orelse "0") orelse return null;
    const duration = clock(attr(element, "dur") orelse "0") orelse return null;
    if (duration <= 0) return null;
    const repeat = attr(element, "repeatCount") orelse "1";
    const repeats = if (std.mem.eql(u8, repeat, "indefinite")) std.math.inf(f64) else clock(repeat) orelse return null;
    if (repeats <= 0) return null;
    return .{ .begin = begin, .duration = duration, .repeats = repeats };
}

/// Only clock-based supported tracks request frames; event-based starts and
/// unsupported animation kinds remain inert instead of keeping the Tab busy.
pub fn active(element: anytype, seconds: f64) bool {
    if (timing(element)) |t| if (seconds < t.begin + t.duration * t.repeats) return true;
    for (element.children.items) |*child| if (child.* == .element and active(&child.element, seconds)) return true;
    return false;
}

/// A nested SVG shares its outer SVG's timeline and is sampled once with it.
pub fn isRoot(element: anytype) bool {
    if (!std.ascii.eqlIgnoreCase(element.tag, "svg")) return false;
    var parent = element.parent;
    while (parent) |node| {
        if (node.* != .element) return true;
        if (std.ascii.eqlIgnoreCase(node.element.tag, "foreignObject")) return true;
        if (std.ascii.eqlIgnoreCase(node.element.tag, "svg")) return false;
        parent = node.element.parent;
    }
    return true;
}

pub fn hasTracks(element: anytype) bool {
    if (timing(element) != null) return true;
    for (element.children.items) |*child| if (child.* == .element and hasTracks(&child.element)) return true;
    return false;
}

pub fn hasSampledSize(element: anytype) bool {
    const state = element.svg_animation orelse return false;
    return state.values.contains("width") or state.values.contains("height");
}

fn fraction(element: anytype, seconds: f64) ?f64 {
    const t = timing(element) orelse return null;
    if (seconds < t.begin) return null;
    const elapsed = seconds - t.begin;
    if (elapsed >= t.duration * t.repeats) {
        if (!std.mem.eql(u8, attr(element, "fill") orelse "remove", "freeze")) return null;
        const remainder = @mod(t.repeats, 1);
        return if (remainder == 0) 1 else remainder;
    }
    return @mod(elapsed, t.duration) / t.duration;
}

fn interpolate(allocator: std.mem.Allocator, from: []const u8, to: []const u8, t: f64) !?[]const u8 {
    if (colors.parse(from)) |a| if (colors.parse(to)) |b| {
        var channels: [4]u8 = undefined;
        inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| channels[i] = @intFromFloat(@round(@as(f64, @floatFromInt(@field(a, name))) * (1 - t) + @as(f64, @floatFromInt(@field(b, name))) * t));
        return try std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ channels[0], channels[1], channels[2], channels[3] });
    };
    var left = std.mem.tokenizeAny(u8, from, " ,\t\r\n");
    var right = std.mem.tokenizeAny(u8, to, " ,\t\r\n");
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var count: usize = 0;
    while (left.next()) |a_raw| {
        const b_raw = right.next() orelse return null;
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < a_raw.len and (std.ascii.isDigit(a_raw[ai]) or std.mem.indexOfScalar(u8, "+-.eE", a_raw[ai]) != null)) : (ai += 1) {}
        while (bi < b_raw.len and (std.ascii.isDigit(b_raw[bi]) or std.mem.indexOfScalar(u8, "+-.eE", b_raw[bi]) != null)) : (bi += 1) {}
        if (!std.mem.eql(u8, a_raw[ai..], b_raw[bi..])) return null;
        const a = std.fmt.parseFloat(f64, a_raw[0..ai]) catch return null;
        const b = std.fmt.parseFloat(f64, b_raw[0..bi]) catch return null;
        if (!std.math.isFinite(a) or !std.math.isFinite(b) or @abs(a) > 1e6 or @abs(b) > 1e6) return null;
        count += 1;
        if (count > 6) return null;
        output.writer.print("{s}{d}{s}", .{ if (count > 1) " " else "", a * (1 - t) + b * t, a_raw[ai..] }) catch return error.OutOfMemory;
    }
    if (count == 0 or right.next() != null) return null;
    return try output.toOwnedSlice();
}

fn sampleValue(allocator: std.mem.Allocator, animation: anytype, base: anytype, t: f64, name: []const u8) !?[]const u8 {
    var from = attr(animation, "from") orelse attr(base, name) orelse "0";
    var to = attr(animation, "to") orelse if (attr(animation, "values") != null) "" else return null;
    var progress = t;
    const discrete = std.mem.eql(u8, attr(animation, "calcMode") orelse "linear", "discrete") or std.mem.eql(u8, name, "visibility");
    var discrete_value: ?[]const u8 = null;
    if (attr(animation, "values")) |list| {
        var entries: [64][]const u8 = undefined;
        var count: usize = 0;
        var iterator = std.mem.splitScalar(u8, list, ';');
        while (iterator.next()) |entry| {
            if (count == entries.len) return null;
            entries[count] = std.mem.trim(u8, entry, " \t\r\n");
            count += 1;
        }
        if (count == 0) return null;
        if (discrete or count == 1) {
            const index = @min(count - 1, @as(usize, @intFromFloat(@floor(t * @as(f64, @floatFromInt(count))))));
            discrete_value = entries[index];
        } else {
            const position = t * @as(f64, @floatFromInt(count - 1));
            const index: usize = @min(count - 2, @as(usize, @intFromFloat(@floor(position))));
            from = entries[index];
            to = entries[index + 1];
            progress = position - @as(f64, @floatFromInt(index));
        }
    }
    if (std.ascii.eqlIgnoreCase(animation.tag, "set")) return try allocator.dupe(u8, to);
    const sampled = if (discrete_value) |value| try allocator.dupe(u8, value) else if (discrete) try allocator.dupe(u8, if (progress < 0.5) from else to) else (try interpolate(allocator, from, to, progress)) orelse return null;
    if (!std.ascii.eqlIgnoreCase(animation.tag, "animateTransform")) return sampled;
    defer allocator.free(sampled);
    const kind = attr(animation, "type") orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}({s})", .{ kind, sampled });
}

/// Atomically replace sampled values without changing authored attributes.
/// The caller must dirty retained paint after sampling an attached tree.
pub fn sample(allocator: std.mem.Allocator, element: anytype, seconds: f64) anyerror!void {
    var next: ?State = null;
    errdefer if (next) |*state| state.deinit();
    var count: usize = 0;
    for (element.children.items) |*child| {
        if (child.* != .element) continue;
        const animation = &child.element;
        const t = fraction(animation, seconds) orelse continue;
        count += 1;
        if (count > 32) return error.SvgTooComplex;
        const name = attr(animation, "attributeName") orelse continue;
        const sampled = (try sampleValue(allocator, animation, element, t, name)) orelse continue;
        errdefer allocator.free(sampled);
        if (next == null) next = .{ .values = std.StringHashMap([]const u8).init(allocator) };
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        const entry = try next.?.values.getOrPut(key);
        if (entry.found_existing) {
            allocator.free(key);
            allocator.free(entry.value_ptr.*);
        }
        entry.value_ptr.* = sampled;
    }
    if (element.svg_animation) |*previous| previous.deinit();
    element.svg_animation = next;
    next = null;
    for (element.children.items) |*child| if (child.* == .element) try sample(allocator, &child.element, seconds);
}
