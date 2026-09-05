//! Shared parsing and resolution for the supported CSS length subset.

const std = @import("std");

pub const Unit = enum {
    px,
    mm,
    em,
    rem,
    percent,
};

pub const Length = struct {
    value: f64,
    unit: Unit,
};

/// Context needed to turn a parsed relative length into CSS pixels.
///
/// `font_size` is the computed font size of the element using the length.
/// `percentage_base` is the containing-block dimension for the property being
/// resolved. It is intentionally optional: percentage heights in an
/// auto-sized containing block do not have a definite used value.
pub const ResolutionContext = struct {
    font_size: f64 = 16.0,
    /// Root element's computed font size; the initial size when resolving
    /// `font-size` on the root itself (including in a separate iframe).
    root_font_size: f64 = 16.0,
    percentage_base: ?f64 = null,
};

/// Parse a finite, non-negative CSS length in the supported `px`, `mm`, `em`,
/// `rem`, or percentage units. CSS permits a unitless zero anywhere a length is
/// expected; it canonicalizes to `0px`. Other unitless numbers and `auto`
/// remain invalid lengths.
pub fn parse(input: []const u8) ?Length {
    const value = std.mem.trim(u8, input, " \t\r\n\x0c");
    if (value.len == 0) return null;

    // Keep parsing and used-value resolution aligned with declaration
    // validation: `width: 0` is a real zero length, not an auto width.
    if (std.fmt.parseFloat(f64, value)) |unitless| {
        if (std.math.isFinite(unitless) and unitless == 0) {
            return .{ .value = 0, .unit = .px };
        }
    } else |_| {}

    const suffix: struct { unit: Unit, number_end: usize } = if (value[value.len - 1] == '%')
        .{ .unit = .percent, .number_end = value.len - 1 }
    else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px"))
        .{ .unit = .px, .number_end = value.len - 2 }
    else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "mm"))
        .{ .unit = .mm, .number_end = value.len - 2 }
    else if (value.len >= 3 and std.ascii.eqlIgnoreCase(value[value.len - 3 ..], "rem"))
        .{ .unit = .rem, .number_end = value.len - 3 }
    else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "em"))
        .{ .unit = .em, .number_end = value.len - 2 }
    else
        return null;

    // A dimension is one token: whitespace between number and unit is not
    // permitted (notably after var(--number)px substitution).
    const number = value[0..suffix.number_end];
    for (number) |byte| if (std.ascii.isWhitespace(byte)) return null;
    if (number.len == 0) return null;
    const numeric = std.fmt.parseFloat(f64, number) catch return null;
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(numeric) or numeric < 0 or numeric > maximum) return null;
    return .{ .value = numeric, .unit = suffix.unit };
}

/// Resolve a parsed CSS length to unscaled CSS pixels.
pub fn resolveLength(length: Length, context: ResolutionContext) ?f64 {
    if (!std.math.isFinite(context.font_size) or context.font_size < 0) return null;
    return switch (length.unit) {
        .px => length.value,
        // CSS defines one inch as 96 CSS pixels, and an inch as 25.4 mm.
        .mm => length.value / 25.4 * 96.0,
        .em => length.value * context.font_size,
        .rem => if (std.math.isFinite(context.root_font_size) and context.root_font_size >= 0)
            length.value * context.root_font_size
        else
            null,
        .percent => blk: {
            const base = context.percentage_base orelse return null;
            if (!std.math.isFinite(base) or base < 0) return null;
            break :blk length.value * base / 100.0;
        },
    };
}

/// Parse and resolve a supported CSS length directly to CSS pixels.
pub fn resolve(input: []const u8, context: ResolutionContext) ?f64 {
    if (parse(input)) |length| return resolveLength(length, context);
    return if (resolveMath(input, context)) |value| @max(value, 0) else null;
}

pub fn isMath(input: []const u8) bool {
    const text = std.mem.trim(u8, input, " \t\r\n");
    for ([_][]const u8{ "calc(", "min(", "max(", "clamp(" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(text, prefix)) return true;
    }
    return false;
}

/// Resolve typed CSS math without range clamping, for signed offsets/margins.
/// Multiplication/division only permit a scalar operand; incompatible sums,
/// division by zero, non-finite values and excessively nested input fail.
pub fn resolveMath(input: []const u8, context: ResolutionContext) ?f64 {
    if (!isMath(input)) return null;
    var math = Math{ .input = input, .context = context };
    const result = math.atom() orelse return null;
    math.space();
    if (math.cursor != input.len or !result.dimension or !std.math.isFinite(result.value)) return null;
    return result.value;
}

const Math = struct {
    input: []const u8,
    context: ResolutionContext,
    cursor: usize = 0,
    depth: usize = 0,
    const Value = struct { value: f64, dimension: bool };

    fn space(self: *Math) void {
        @import("css_syntax.zig").skipWhitespaceAndComments(self.input, &self.cursor);
    }
    fn consume(self: *Math, c: u8) bool {
        self.space();
        if (self.cursor == self.input.len or self.input[self.cursor] != c) return false;
        self.cursor += 1;
        return true;
    }
    fn sum(self: *Math) ?Value {
        var result = self.product() orelse return null;
        while (true) {
            const before_space = self.cursor;
            self.space();
            if (self.cursor == self.input.len or (self.input[self.cursor] != '+' and self.input[self.cursor] != '-')) return result;
            const operation = self.input[self.cursor];
            // CSS binary +/- require whitespace on both sides.
            if (before_space == self.cursor) return null;
            self.cursor += 1;
            const after_operator = self.cursor;
            self.space();
            if (after_operator == self.cursor) return null;
            const rhs = self.product() orelse return null;
            if (result.dimension != rhs.dimension) return null;
            result.value += if (operation == '+') rhs.value else -rhs.value;
        }
    }
    fn product(self: *Math) ?Value {
        var result = self.atom() orelse return null;
        while (true) {
            const before_space = self.cursor;
            self.space();
            if (self.cursor == self.input.len or (self.input[self.cursor] != '*' and self.input[self.cursor] != '/')) {
                self.cursor = before_space;
                return result;
            }
            const operation = self.input[self.cursor];
            self.cursor += 1;
            const rhs = self.atom() orelse return null;
            if (operation == '*') {
                if (result.dimension and rhs.dimension) return null;
                result.value *= rhs.value;
                result.dimension = result.dimension or rhs.dimension;
            } else {
                if (rhs.dimension or rhs.value == 0) return null;
                result.value /= rhs.value;
            }
        }
    }
    fn atom(self: *Math) ?Value {
        if (self.depth >= 64) return null;
        self.depth += 1;
        defer self.depth -= 1;
        self.space();
        if (self.cursor >= self.input.len) return null;
        const start = self.cursor;
        if (self.consume('(')) {
            const inner = self.sum() orelse return null;
            return if (self.consume(')')) inner else null;
        }
        while (self.cursor < self.input.len and std.ascii.isAlphabetic(self.input[self.cursor])) : (self.cursor += 1) {}
        if (self.cursor > start) {
            const function = self.input[start..self.cursor];
            if (!self.consume('(')) return null;
            var values: [3]Value = undefined;
            var count: usize = 0;
            var result = self.sum() orelse return null;
            values[0] = result;
            count = 1;
            while (self.consume(',')) {
                const next = self.sum() orelse return null;
                if (next.dimension != result.dimension) return null;
                if (count < values.len) values[count] = next;
                count += 1;
                if (std.ascii.eqlIgnoreCase(function, "min")) result.value = @min(result.value, next.value);
                if (std.ascii.eqlIgnoreCase(function, "max")) result.value = @max(result.value, next.value);
            }
            if (!self.consume(')')) return null;
            if (std.ascii.eqlIgnoreCase(function, "calc")) return if (count == 1) result else null;
            if (std.ascii.eqlIgnoreCase(function, "min") or std.ascii.eqlIgnoreCase(function, "max")) return result;
            if (std.ascii.eqlIgnoreCase(function, "clamp") and count == 3) return .{ .value = @max(values[0].value, @min(values[1].value, values[2].value)), .dimension = result.dimension };
            return null;
        }
        var iterator = @import("css_value_tokens.zig").Iterator{ .input = self.input, .cursor = start };
        const token = iterator.next() orelse return null;
        self.cursor = token.end;
        if (token.kind == .dimension or (self.cursor < self.input.len and self.input[self.cursor] == '%')) {
            if (self.cursor < self.input.len and self.input[self.cursor] == '%') self.cursor += 1;
            const raw = self.input[start..self.cursor];
            const negative = raw[0] == '-';
            const magnitude = if (negative or raw[0] == '+') raw[1..] else raw;
            const parsed = parse(magnitude) orelse return null;
            const size = resolveLength(parsed, self.context) orelse return null;
            return .{ .value = if (negative) -size else size, .dimension = true };
        }
        const scalar = std.fmt.parseFloat(f64, self.input[start..self.cursor]) catch return null;
        return .{ .value = scalar, .dimension = false };
    }
};

test "CSS math preserves root and percentage context and validates dimensions" {
    try std.testing.expectEqual(@as(?f64, 360), resolve("calc(100% - 2rem)", .{ .percentage_base = 400, .root_font_size = 20 }));
    try std.testing.expectEqual(@as(?f64, 30), resolve("clamp(1rem, calc(4rem / 2), 30px)", .{ .root_font_size = 20 }));
    try std.testing.expectEqual(@as(?f64, -20), resolveMath("calc(1rem - 40px)", .{ .root_font_size = 20 }));
    try std.testing.expect(resolve("calc(1px + 2)", .{}) == null);
    try std.testing.expect(resolve("calc(1rem / 0)", .{}) == null);
    try std.testing.expect(resolve("calc(1rem +2px)", .{}) == null);
    try std.testing.expect(resolve("calc(100% - 2rem)", .{}) == null);
}

/// Parse a finite, non-negative `<number>px` value. Relative units are kept
/// out of this compatibility helper for callers such as pixel animations.
pub fn parsePixel(input: []const u8) ?f64 {
    const length = parse(input) orelse return null;
    if (length.unit != .px) return null;
    return length.value;
}

pub fn toLayoutPixels(value: f64) i32 {
    const maximum: f64 = @floatFromInt(std.math.maxInt(i32));
    return @intFromFloat(std.math.clamp(value, 0.0, maximum));
}

pub fn formatPixel(buffer: []u8, value: f64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d:.3}px", .{value});
}

test "pixel lengths parse and serialize the supported dimension grammar" {
    try std.testing.expectApproxEqAbs(@as(f64, 12.75), parsePixel(" 12.75PX ").?, 0.000001);
    try std.testing.expectEqual(@as(?f64, 0), parsePixel("0"));
    try std.testing.expectEqual(@as(?f64, 0), parsePixel("-0"));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.750px", try formatPixel(&buffer, 12.75));
    try std.testing.expect(parsePixel("auto") == null);
    try std.testing.expect(parsePixel("50%") == null);
    try std.testing.expect(parsePixel("-1px") == null);
}

test "relative lengths resolve against explicit CSS context" {
    const em = parse("1.5em").?;
    try std.testing.expectEqual(Unit.em, em.unit);
    try std.testing.expectApproxEqAbs(
        @as(f64, 18.0),
        resolveLength(em, .{ .font_size = 12.0 }).?,
        0.000001,
    );

    const percentage = parse(" 41.17% ").?;
    try std.testing.expectEqual(Unit.percent, percentage.unit);
    try std.testing.expectApproxEqAbs(
        @as(f64, 98.808),
        resolveLength(percentage, .{ .percentage_base = 240.0 }).?,
        0.000001,
    );
    try std.testing.expect(resolve("50%", .{}) == null);
    try std.testing.expectEqual(@as(?f64, 24.0), resolve("2em", .{ .font_size = 12.0 }));
    try std.testing.expectEqual(@as(?f64, 0), resolve("0", .{}));
    try std.testing.expect(parsePixel("2em") == null);
    try std.testing.expect(parse("1") == null);
    try std.testing.expect(parse("2EX") == null);
}

test "millimeter lengths use the CSS 96dpi absolute-unit conversion" {
    const millimeters = parse("25.4MM").?;
    try std.testing.expectEqual(Unit.mm, millimeters.unit);
    try std.testing.expectApproxEqAbs(
        @as(f64, 96.0),
        resolveLength(millimeters, .{}).?,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 96.0 / 25.4),
        resolve("1mm", .{}).?,
        0.000001,
    );
    try std.testing.expect(parsePixel("1mm") == null);
}
