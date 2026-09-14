//! Borrowed linear-gradient grammar and owned specified/computed serialization.
//! Length percentages remain symbolic until the gradient box is known.
const std = @import("std");
const lexer = @import("css_tokenizer.zig");
const tokens = @import("css_value_tokens.zig");
const syntax = @import("css_syntax.zig");
const math = @import("css_math.zig");
const colors = @import("color.zig");
const interpolation = @import("color_interpolation.zig");

pub const max_stops = 1024;
pub const Stop = struct { color: ?[]const u8, position: ?[]const u8 = null };
pub const Direction = union(enum) {
    angle: []const u8,
    sides: struct { x: i2 = 0, y: i2 = 0 },
};
pub const Linear = struct {
    repeating: bool = false,
    direction: Direction = .{ .sides = .{ .y = 1 } },
    method: ?interpolation.Method = null,
    stops: [max_stops]Stop = undefined,
    count: usize = 0,

    pub fn defaultMethod(self: *const Linear) interpolation.Method {
        return self.defaultMethodWithContext(.{});
    }

    fn defaultMethodWithContext(self: *const Linear, value: colors.Context) interpolation.Method {
        var context = value;
        if (context.current_color == null) context.current_color = colors.parseAbsolute("black");
        for (self.stops[0..self.count]) |stop| if (stop.color) |source| {
            const color = colors.parseWithContext(source, context) orelse continue;
            if (!color.legacy) return .{};
        };
        return .{ .space = .srgb };
    }
};

fn parts(input: []const u8, output: [][]const u8) ?usize {
    var iterator = lexer.Iterator{ .input = input };
    var count: usize = 0;
    while (iterator.next()) |token| {
        if (token.isTrivia()) continue;
        if (count == output.len) return null;
        var end = token.end;
        if (token.kind == .function) {
            end = (tokens.closeFunction(input, end) orelse return null) + 1;
            iterator.cursor = end;
        }
        output[count] = input[token.start..end];
        count += 1;
    }
    return count;
}

/// Resolve signed stop positions in CSS pixels. A supplied percentage basis is
/// the actual gradient-line length, never the containing block's width.
pub fn position(input: []const u8, context: math.Context) ?f64 {
    const value = math.evaluate(input, context) orelse return null;
    return switch (value.dimension) {
        .length => value.value,
        .number => if (value.value == 0 and !math.isMath(input)) 0 else null,
        else => null,
    };
}

pub fn angle(input: []const u8, context: math.Context) ?f64 {
    const value = math.evaluate(input, context) orelse return null;
    return if (value.dimension == .angle or (value.dimension == .number and value.value == 0 and !math.isMath(input))) value.value else null;
}

fn prelude(input: []const u8, result: *Linear) bool {
    var components: [7][]const u8 = undefined;
    const count = parts(input, &components) orelse return false;
    var direction_seen = false;
    var i: usize = 0;
    while (i < count) {
        if (tokens.isKeyword(components[i], "in")) {
            if (result.method != null or i + 1 >= count) return false;
            const end = if (i + 3 < count and tokens.isKeyword(components[i + 3], "hue")) i + 4 else i + 2;
            const first = @intFromPtr(components[i].ptr) - @intFromPtr(input.ptr);
            const last = @intFromPtr(components[end - 1].ptr) - @intFromPtr(input.ptr) + components[end - 1].len;
            result.method = interpolation.Method.parse(input[first..last]) orelse return false;
            i = end;
        } else {
            if (direction_seen) return false;
            direction_seen = true;
            if (tokens.isKeyword(components[i], "to")) {
                i += 1;
                var sides: @FieldType(Direction, "sides") = .{};
                while (i < count and !tokens.isKeyword(components[i], "in")) : (i += 1) {
                    const part = components[i];
                    if (tokens.isKeyword(part, "left") or tokens.isKeyword(part, "right")) {
                        if (sides.x != 0) return false;
                        sides.x = if (tokens.isKeyword(part, "left")) -1 else 1;
                    } else if (tokens.isKeyword(part, "top") or tokens.isKeyword(part, "bottom")) {
                        if (sides.y != 0) return false;
                        sides.y = if (tokens.isKeyword(part, "top")) -1 else 1;
                    } else return false;
                }
                if (sides.x == 0 and sides.y == 0) return false;
                result.direction = .{ .sides = sides };
            } else {
                _ = angle(components[i], .{}) orelse return false;
                result.direction = .{ .angle = components[i] };
                i += 1;
            }
        }
    }
    return count != 0;
}

/// One complete linear or repeating-linear function, bounded by 1 MiB, 64
/// component levels and 1024 expanded stops/hints. All slices borrow input.
pub fn parse(input: []const u8) ?Linear {
    if (input.len > 1024 * 1024) return null;
    var iterator = lexer.Iterator{ .input = input };
    var function = iterator.next() orelse return null;
    while (function.isTrivia()) function = iterator.next() orelse return null;
    if (function.kind != .function) return null;
    const repeating = lexer.identifierEquals(function.encodedValue(input), "repeating-linear-gradient");
    if (!repeating and !lexer.identifierEquals(function.encodedValue(input), "linear-gradient")) return null;
    const close = tokens.closeFunction(input, function.end) orelse return null;
    iterator.cursor = close + 1;
    while (iterator.next()) |extra| if (!extra.isTrivia()) return null;
    var result = Linear{ .repeating = repeating };
    var cursor = function.end;
    var first = true;
    while (cursor <= close) {
        const separator = syntax.scanToTopLevel(input[0..close], cursor, ",");
        if (separator.exhausted) return null;
        const item = input[cursor..separator.end];
        var components: [3][]const u8 = undefined;
        const count = parts(item, &components);
        if (first and (count == null or count.? == 0 or !colors.isValid(components[0]))) {
            if (!prelude(item, &result) or separator.end == close) return null;
        } else {
            const n = count orelse return null;
            if (n == 0) return null;
            const is_color = colors.isValid(components[0]);
            const required = if (is_color) @max(n - 1, 1) else 1;
            if (result.count + required > max_stops) return null;
            if (!is_color) {
                if (n != 1 or result.count == 0 or result.stops[result.count - 1].color == null) return null;
            }
            const start: usize = if (is_color) 1 else 0;
            for (components[start..n]) |component| _ = position(component, .{ .percentage = .{ .dimension = .length, .value = 100 } }) orelse return null;
            for (0..required) |i| {
                result.stops[result.count] = .{
                    .color = if (is_color) components[0] else null,
                    .position = if (is_color and n == 1) null else components[start + i],
                };
                result.count += 1;
            }
        }
        first = false;
        if (separator.end == close) break;
        cursor = separator.end + 1;
    }
    if (result.count == 0 or result.stops[result.count - 1].color == null) return null;
    return result;
}

pub const Serialization = enum { retained, specified, computed, resolved };

fn numericText(allocator: std.mem.Allocator, source: []const u8, context: colors.Context, mode: Serialization, is_angle: bool) ![]const u8 {
    const computed = mode == .computed or mode == .resolved;
    const relative = if (computed) try tokens.resolveFontUnits(allocator, source, context.font_size, context.root_font_size) else null;
    defer if (relative) |owned| allocator.free(owned);
    const input = relative orelse source;
    if (math.isMath(input)) {
        if (computed) if (math.evaluate(input, .{})) |value| {
            if (std.math.isFinite(value.value)) return std.fmt.allocPrint(allocator, "{d}{s}", .{ value.value, if (is_angle) "deg" else if (value.dimension == .percentage) "%" else "px" });
        };
        return try math.serializeSpecified(allocator, input, .{ .percentage = if (is_angle) null else .{ .dimension = .length, .value = 100 } }) orelse try allocator.dupe(u8, input);
    }
    const value = math.evaluate(input, .{}) orelse return allocator.dupe(u8, input);
    if (is_angle or value.dimension == .number or computed) return std.fmt.allocPrint(allocator, "{d}{s}", .{ value.value, if (is_angle) "deg" else if (value.dimension == .percentage) "%" else "px" });
    return allocator.dupe(u8, input);
}

/// Caller owns the result. Computed storage resolves fonts but preserves
/// currentcolor and fractional operands; resolved CSSOM text supplies foreground.
pub fn serialize(allocator: std.mem.Allocator, input: []const u8, context: colors.Context, mode: Serialization) !?[]u8 {
    const parsed = parse(input) orelse return null;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, if (parsed.repeating) "repeating-linear-gradient(" else "linear-gradient(");
    var header = false;
    switch (parsed.direction) {
        .angle => |source| {
            const text = try numericText(allocator, source, context, mode, true);
            defer allocator.free(text);
            if (!std.mem.eql(u8, text, "180deg")) {
                try output.appendSlice(allocator, text);
                header = true;
            }
        },
        .sides => |sides| if (sides.x != 0 or sides.y != 1) {
            try output.appendSlice(allocator, "to");
            if (sides.x != 0) try output.appendSlice(allocator, if (sides.x < 0) " left" else " right");
            if (sides.y != 0) try output.appendSlice(allocator, if (sides.y < 0) " top" else " bottom");
            header = true;
        },
    }
    const method = parsed.method orelse parsed.defaultMethod();
    // Resolving a legacy currentcolor keyword may expose a modern foreground.
    // Preserve the used method if that changes the serialized stops' default.
    const serialized_default = if (mode == .resolved) parsed.defaultMethodWithContext(context) else parsed.defaultMethod();
    if (method.space != serialized_default.space or method.hue != .shorter) {
        if (header) try output.append(allocator, ' ');
        try output.appendSlice(allocator, "in ");
        try output.appendSlice(allocator, method.space.name());
        if (method.hue != .shorter) {
            try output.append(allocator, ' ');
            try output.appendSlice(allocator, @tagName(method.hue));
            try output.appendSlice(allocator, " hue");
        }
        header = true;
    }
    if (header) try output.appendSlice(allocator, ", ");
    for (parsed.stops[0..parsed.count], 0..) |stop, i| {
        if (i != 0) try output.appendSlice(allocator, ", ");
        if (stop.color) |source| {
            const text = (switch (mode) {
                .retained => try colors.normalizeInterpolationOperand(allocator, source, null),
                .specified => try colors.serializeSpecified(allocator, source),
                .computed => try colors.normalizeInterpolationOperand(allocator, source, context),
                .resolved => try colors.serializeComputed(allocator, source, context),
            }) orelse return null;
            defer allocator.free(text);
            try output.appendSlice(allocator, text);
        }
        if (stop.position) |source| {
            if (stop.color != null) try output.append(allocator, ' ');
            const text = try numericText(allocator, source, context, mode, false);
            defer allocator.free(text);
            try output.appendSlice(allocator, text);
        }
    }
    try output.append(allocator, ')');
    return try output.toOwnedSlice(allocator);
}

test "linear gradient grammar shares typed stops hints methods and escaped functions" {
    for ([_][]const u8{
        "linear-gradient(red)",                                       "linear-gradient(red 0 20%, 30%, blue)",
        "linear-gradient(in lch longer hue to right top, red, blue)", "repeating-linear-gradient(calc(.25turn), currentcolor -2em, color-mix(red, blue) calc(50% + 1rem))",
        "l\\69 near-gradient(to right, red, blue)",
    }) |source| {
        if (parse(source) == null) std.debug.print("rejected gradient: {s}\n", .{source});
        try std.testing.expect(parse(source) != null);
    }
    for ([_][]const u8{
        "linear-gradient()",                        "linear-gradient(red,)",                          "linear-gradient(20%, red)",
        "linear-gradient(red, 20%)",                "linear-gradient(red, 20%, 30%, blue)",           "linear-gradient(to right left, red, blue)",
        "linear-gradient(1, red, blue)",            "linear-gradient(in srgb longer hue, red, blue)", "linear-gradient(red 1s, blue)",
        "linear-gradient(red calc(1px + 1), blue)", "linear-gradient(red 0 1% 2%, blue)",
    }) |source| {
        if (parse(source) != null) std.debug.print("accepted invalid gradient: {s}\n", .{source});
        try std.testing.expect(parse(source) == null);
    }
}

test "gradient computed lengths retain a percentage basis and specified relative units" {
    const source = "linear-gradient(to bottom, currentcolor 1em, red calc(50% + 2em), blue)";
    const specified = (try serialize(std.testing.allocator, source, .{}, .specified)).?;
    defer std.testing.allocator.free(specified);
    try std.testing.expectEqualStrings("linear-gradient(currentcolor 1em, red calc(50% + 2em), blue)", specified);
    const computed = (try serialize(std.testing.allocator, source, .{ .font_size = 20 }, .computed)).?;
    defer std.testing.allocator.free(computed);
    try std.testing.expectEqualStrings("linear-gradient(currentcolor 20px, rgb(255, 0, 0) calc(50% + 40px), rgb(0, 0, 255))", computed);
}

test "gradient resolved serialization preserves interpolation when currentcolor exposes a modern foreground" {
    const result = (try serialize(std.testing.allocator, "linear-gradient(currentcolor, blue)", .{
        .current_color = colors.parseAbsolute("oklab(0.5 0 0)"),
    }, .resolved)).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("linear-gradient(in srgb, oklab(0.5 0 0), rgb(0, 0, 255))", result);
}

fn allocationCheck(allocator: std.mem.Allocator) !void {
    const result = (try serialize(allocator, "linear-gradient(in hsl longer hue to right top, color-mix(red, currentcolor) 1em, rgb(10.25 20.5 0) calc(50% + 1rem))", .{ .font_size = 20 }, .computed)).?;
    defer allocator.free(result);
    try std.testing.expect(parse(result) != null);
}

test "gradient serialization cleans up every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCheck, .{});
}
