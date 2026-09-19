//! Numeric grid placement grammar shared by declarations and layout.
//! Parsed values are scalar; shorthand component slices borrow their input.
const std = @import("std");
const tokens = @import("css_value_tokens.zig");
const syntax = @import("css_syntax.zig");

pub const Line = union(enum) { auto, line: i32, span: u32 };
pub const Axis = struct { start: Line = .auto, end: Line = .auto };
pub const Flow = struct { axis: enum { row, column } = .row, dense: bool = false };

pub fn isLineProperty(property: []const u8) bool {
    return std.mem.eql(u8, property, "grid-column-start") or std.mem.eql(u8, property, "grid-column-end") or
        std.mem.eql(u8, property, "grid-row-start") or std.mem.eql(u8, property, "grid-row-end");
}

pub fn isPlacementProperty(property: []const u8) bool {
    return isLineProperty(property) or std.mem.eql(u8, property, "grid-row") or
        std.mem.eql(u8, property, "grid-column") or std.mem.eql(u8, property, "grid-area");
}

const Number = struct { negative: bool, magnitude: u32 };

fn integer(raw: []const u8) Number {
    var start: usize = 0;
    if (raw[0] == '+' or raw[0] == '-') start = 1;
    var magnitude: u32 = 0;
    for (raw[start..]) |digit| magnitude = magnitude *| 10 +| (digit - '0');
    return .{ .negative = raw[0] == '-', .magnitude = magnitude };
}

/// Accept arbitrarily long nonzero integer tokens. Saturation here only makes
/// used values representable; placement applies its separate grid extent limit.
pub fn parseLine(raw: []const u8) ?Line {
    var iterator = tokens.Iterator{ .input = raw };
    var count: usize = 0;
    var number: ?Number = null;
    var span = false;
    var automatic = false;
    while (iterator.next()) |token| {
        if (token.isTrivia()) continue;
        count += 1;
        if (count > 2) return null;
        if (token.kind == .number and token.number_type == .integer and number == null) {
            number = integer(token.raw(raw));
        } else if (token.kind == .ident and !span and syntax.identifierEquals(token.encodedValue(raw), "span")) {
            span = true;
        } else if (token.kind == .ident and !automatic and syntax.identifierEquals(token.encodedValue(raw), "auto")) {
            automatic = true;
        } else return null;
    }
    if (automatic) return if (count == 1) .auto else null;
    const value = number orelse return null;
    if (value.magnitude == 0) return null;
    if (span) return if (value.negative) null else .{ .span = value.magnitude };
    if (value.negative) return .{ .line = if (value.magnitude >= 2147483648) std.math.minInt(i32) else -@as(i32, @intCast(value.magnitude)) };
    return .{ .line = @intCast(@min(value.magnitude, std.math.maxInt(i32))) };
}

pub fn parseFlow(raw: []const u8) ?Flow {
    var iterator = tokens.Iterator{ .input = raw };
    var value = Flow{};
    var axis_seen = false;
    var count: usize = 0;
    while (iterator.next()) |token| {
        if (token.isTrivia()) continue;
        count += 1;
        if (count > 2 or token.kind != .ident) return null;
        const word = token.encodedValue(raw);
        if (!axis_seen and syntax.identifierEquals(word, "row")) {
            value.axis = .row;
            axis_seen = true;
        } else if (!axis_seen and syntax.identifierEquals(word, "column")) {
            value.axis = .column;
            axis_seen = true;
        } else if (!value.dense and syntax.identifierEquals(word, "dense")) {
            value.dense = true;
        } else return null;
    }
    return if (count != 0) value else null;
}

fn shorthandValues(raw: []const u8, limit: usize) ?[4][]const u8 {
    var values: [4][]const u8 = .{ "auto", "auto", "auto", "auto" };
    var iterator = tokens.Iterator{ .input = raw };
    var start: usize = 0;
    var count: usize = 0;
    while (iterator.next()) |token| {
        if (token.kind != .delim or token.delim != '/') continue;
        if (count + 1 == limit) return null;
        const part = std.mem.trim(u8, raw[start..token.start], " \t\r\n\x0c");
        _ = parseLine(part) orelse return null;
        values[count] = part;
        count += 1;
        start = token.end;
    }
    const part = std.mem.trim(u8, raw[start..], " \t\r\n\x0c");
    _ = parseLine(part) orelse return null;
    values[count] = part;
    return values;
}

/// Return start/end source slices; omitted numeric ends become `auto`.
pub fn axisValues(raw: []const u8) ?[2][]const u8 {
    const values = shorthandValues(raw, 2) orelse return null;
    return .{ values[0], values[1] };
}

/// Return row-start, column-start, row-end, column-end source slices.
/// Named-area replication is excluded from this numeric grammar.
pub fn areaValues(raw: []const u8) ?[4][]const u8 {
    return shorthandValues(raw, 4);
}

/// Canonicalize already normalized placement values without replacing a large
/// authored integer with the saturated scalar used by layout.
pub fn canonicalLine(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const value = parseLine(raw) orelse return raw;
    if (value == .auto) return "auto";
    if (value != .span) return raw;
    var iterator = tokens.Iterator{ .input = raw };
    while (iterator.next()) |token| {
        if (token.kind == .number) return std.fmt.allocPrint(allocator, "span {s}", .{token.raw(raw)});
    }
    unreachable;
}

pub fn canonicalFlow(value: Flow) []const u8 {
    return if (value.axis == .column) (if (value.dense) "column dense" else "column") else if (value.dense) "dense" else "row";
}

test "numeric grid lines preserve grammar and saturate only scalar values" {
    try std.testing.expectEqual(Line{ .line = -3 }, parseLine(" -03 /**/ ").?);
    try std.testing.expectEqual(Line{ .span = 4 }, parseLine("+4 SpAn").?);
    try std.testing.expectEqual(Line{ .span = 2 }, parseLine("s\\70 an/**/2").?);
    try std.testing.expectEqual(Line{ .line = std.math.maxInt(i32) }, parseLine("999999999999999999999999").?);
    try std.testing.expectEqual(Line{ .line = std.math.minInt(i32) }, parseLine("-999999999999999999999999").?);
    try std.testing.expectEqual(Line{ .span = std.math.maxInt(u32) }, parseLine("span 999999999999999999999").?);
    for ([_][]const u8{ "", "0", "-0", "span", "span 0", "span -1", "1.0", "1e2", "foo", "1 foo", "auto 1", "span auto", "span span", "1 2", "span 1 2", "calc(2)" }) |invalid|
        try std.testing.expect(parseLine(invalid) == null);
}

test "numeric grid shorthands use slash boundaries and default missing axes" {
    const axis = axisValues("2/**//span 3").?;
    try std.testing.expectEqual(Line{ .line = 2 }, parseLine(axis[0]).?);
    try std.testing.expectEqualStrings("span 3", axis[1]);
    const area = areaValues("1 / 2 / span 3").?;
    try std.testing.expectEqualStrings("auto", area[3]);
    try std.testing.expectEqualStrings("auto", axisValues("span 2").?[1]);
    for ([_][]const u8{ "/1", "1/", "1//2", "1/2/3/4/5", "1/auto/foo", "1 / inherit" }) |invalid|
        try std.testing.expect(areaValues(invalid) == null);
    try std.testing.expect(axisValues("1/2/3") == null);
    try std.testing.expectEqual(Flow{ .axis = .column, .dense = true }, parseFlow("dense/**/column").?);
    try std.testing.expectEqualStrings("dense", canonicalFlow(parseFlow("row dense").?));
    for ([_][]const u8{ "", "row column", "dense dense", "sparse", "row row", "row dense dense" }) |invalid|
        try std.testing.expect(parseFlow(invalid) == null);
}
