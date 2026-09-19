//! Borrowing grid track-list grammar. Resolves scalar lengths with an explicit
//! CSS context; track allocation and intrinsic measurements belong to layout.
const std = @import("std");
const length = @import("length.zig");
const syntax = @import("css_syntax.zig");
const tokens = @import("css_value_tokens.zig");

pub const max_tracks = 256;
pub const Kind = enum { fixed, auto, min_content, max_content, fraction, fit_content };
pub const Track = struct {
    min: f64 = 0,
    max: ?f64 = null,
    fraction: f64 = 0,
    min_kind: Kind = .auto,
    max_kind: Kind = .auto,
    auto_fit: bool = false,
    collapsed: bool = false,
};

pub const Components = struct {
    input: []const u8,
    cursor: usize = 0,
    pub fn next(self: *Components) ?[]const u8 {
        syntax.skipWhitespaceAndComments(self.input, &self.cursor);
        if (self.cursor == self.input.len) return null;
        const start = self.cursor;
        var iterator = tokens.Iterator{ .input = self.input, .cursor = start };
        while (iterator.next()) |token| {
            if (token.kind == .function) {
                iterator.cursor = if (tokens.closeFunction(self.input, token.end)) |end| end + 1 else self.input.len;
            } else if (token.isTrivia()) {
                self.cursor = token.start;
                return self.input[start..self.cursor];
            }
        }
        self.cursor = self.input.len;
        return self.input[start..];
    }
};

fn fraction(raw: []const u8) ?f64 {
    if (raw.len < 3 or !std.ascii.eqlIgnoreCase(raw[raw.len - 2 ..], "fr")) return null;
    const n = std.fmt.parseFloat(f64, raw[0 .. raw.len - 2]) catch return null;
    return if (std.math.isFinite(n) and n >= 0) n else null;
}

pub fn parseTrack(raw: []const u8, context: length.ResolutionContext) ?Track {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(text, "auto")) return .{};
    if (std.ascii.eqlIgnoreCase(text, "min-content")) return .{ .min_kind = .min_content, .max_kind = .min_content };
    if (std.ascii.eqlIgnoreCase(text, "max-content")) return .{ .min_kind = .max_content, .max_kind = .max_content };
    if (length.resolve(text, context)) |size| return .{ .min = size, .max = size, .min_kind = .fixed, .max_kind = .fixed };
    if (unresolvedPercentage(text, context)) return .{};
    if (fraction(text)) |fr| return .{ .fraction = fr, .max_kind = .fraction };
    if (text.len > 13 and std.ascii.startsWithIgnoreCase(text, "fit-content(") and text[text.len - 1] == ')') {
        const limit = std.mem.trim(u8, text[12 .. text.len - 1], " \t\r\n");
        if (length.resolve(limit, context)) |size| return .{ .max = size, .max_kind = .fit_content };
        if (unresolvedPercentage(limit, context)) return .{};
        return null;
    }
    if (text.len > 8 and std.ascii.startsWithIgnoreCase(text, "minmax(") and text[text.len - 1] == ')') {
        const inner = text[7 .. text.len - 1];
        const comma = syntax.scanToTopLevel(inner, 0, ",");
        if (comma.delimiter == null) return null;
        const low = std.mem.trim(u8, inner[0..comma.end], " \t\r\n");
        const high = std.mem.trim(u8, inner[comma.end + 1 ..], " \t\r\n");
        var result: Track = .{};
        if (length.resolve(low, context)) |size| {
            result.min = size;
            result.min_kind = .fixed;
        } else if (std.ascii.eqlIgnoreCase(low, "min-content")) {
            result.min_kind = .min_content;
        } else if (std.ascii.eqlIgnoreCase(low, "max-content")) {
            result.min_kind = .max_content;
        } else if (!std.ascii.eqlIgnoreCase(low, "auto") and !unresolvedPercentage(low, context)) return null;
        if (length.resolve(high, context)) |size| {
            result.max = @max(size, result.min);
            result.max_kind = .fixed;
        } else if (fraction(high)) |fr| {
            result.fraction = fr;
            result.max_kind = .fraction;
        } else if (std.ascii.eqlIgnoreCase(high, "min-content")) {
            result.max_kind = .min_content;
        } else if (std.ascii.eqlIgnoreCase(high, "max-content")) {
            result.max_kind = .max_content;
        } else if (!std.ascii.eqlIgnoreCase(high, "auto") and !unresolvedPercentage(high, context)) return null;
        return result;
    }
    return null;
}

fn unresolvedPercentage(raw: []const u8, context: length.ResolutionContext) bool {
    if (context.percentage_base != null) return false;
    var definite = context;
    definite.percentage_base = 100;
    return length.resolve(raw, definite) != null;
}

/// Fills caller storage; null means unsupported/invalid grammar. Auto-repeat
/// supports a single definite-minimum track, the common responsive-card form.
/// Auto-fit keeps explicit line identities; placement later collapses empty
/// tracks. The legacy item-count argument no longer determines topology.
pub fn parse(raw: []const u8, context: length.ResolutionContext, gap: f64, _: usize, output: []Track) ?usize {
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\r\n"), "none")) return 0;
    var iterator = Components{ .input = raw };
    var count: usize = 0;
    var auto_repeat: ?usize = null;
    while (iterator.next()) |component| {
        if (std.ascii.startsWithIgnoreCase(component, "repeat(") and component[component.len - 1] == ')') {
            const inner = component[7 .. component.len - 1];
            const comma = syntax.scanToTopLevel(inner, 0, ",");
            if (comma.delimiter == null) return null;
            const repeat = std.mem.trim(u8, inner[0..comma.end], " \t\r\n");
            var pattern: [max_tracks]Track = undefined;
            var pattern_count: usize = 0;
            var parts = Components{ .input = inner[comma.end + 1 ..] };
            while (parts.next()) |part| {
                if (pattern_count == pattern.len) return null;
                pattern[pattern_count] = parseTrack(part, context) orelse return null;
                pattern_count += 1;
            }
            if (pattern_count == 0) return null;
            const repetitions = if (std.ascii.eqlIgnoreCase(repeat, "auto-fill") or std.ascii.eqlIgnoreCase(repeat, "auto-fit")) blk: {
                if (auto_repeat != null or pattern_count != 1 or pattern[0].min_kind != .fixed) return null;
                // Leave one placeholder until both leading and trailing fixed
                // siblings have been parsed. They consume the same extent.
                auto_repeat = count;
                pattern[0].auto_fit = std.ascii.eqlIgnoreCase(repeat, "auto-fit");
                break :blk 1;
            } else std.fmt.parseInt(usize, repeat, 10) catch return null;
            if (repetitions == 0 or repetitions > (@min(output.len, max_tracks) - count) / pattern_count) return null;
            for (0..repetitions) |_| {
                @memcpy(output[count .. count + pattern_count], pattern[0..pattern_count]);
                count += pattern_count;
            }
        } else {
            if (count == @min(output.len, max_tracks)) return null;
            output[count] = parseTrack(component, context) orelse return null;
            count += 1;
        }
    }
    if (auto_repeat) |index| {
        var siblings: f64 = 0;
        for (output[0..count], 0..) |track, i| {
            const breadth = if (track.max_kind == .fixed) track.max orelse track.min else if (track.min_kind == .fixed) track.min else return null;
            if (i != index) siblings += @max(breadth, 0);
        }
        const repeated = output[index];
        const breadth = @max(if (repeated.max_kind == .fixed) repeated.max orelse repeated.min else repeated.min, 1);
        const capacity = @min(output.len, max_tracks) - (count - 1);
        const repetitions: usize = if (context.percentage_base) |available|
            @intFromFloat(std.math.clamp(@floor((available + gap - siblings - gap * @as(f64, @floatFromInt(count - 1))) / (breadth + gap)), 1, @as(f64, @floatFromInt(capacity))))
        else
            1;
        const expanded = count + repetitions - 1;
        std.mem.copyBackwards(Track, output[index + repetitions .. expanded], output[index + 1 .. count]);
        @memset(output[index..][0..repetitions], repeated);
        count = expanded;
    }
    return if (count > 0) count else null;
}

test "grid tracks preserve intrinsic functions zero fractions and fit content caps" {
    try std.testing.expectEqual(Kind.auto, parseTrack("auto", .{}).?.min_kind);
    try std.testing.expectEqual(Kind.min_content, parseTrack("min-content", .{}).?.max_kind);
    try std.testing.expectEqual(Kind.max_content, parseTrack("max-content", .{}).?.min_kind);
    const fractional = parseTrack("minmax(0, 0fr)", .{}).?;
    try std.testing.expectEqual(Kind.fixed, fractional.min_kind);
    try std.testing.expectEqual(Kind.fraction, fractional.max_kind);
    try std.testing.expectEqual(@as(f64, 0), fractional.fraction);
    try std.testing.expectEqual(Kind.fit_content, parseTrack("fit-content(80px)", .{}).?.max_kind);
    try std.testing.expectEqual(@as(?f64, 80), parseTrack("fit-content(80px)", .{}).?.max);
    try std.testing.expectEqual(Kind.auto, parseTrack("50%", .{}).?.min_kind);
    try std.testing.expectEqual(@as(f64, 0), parseTrack("50%", .{ .percentage_base = 0 }).?.min);
    try std.testing.expect(parseTrack("minmax(1fr, 20px)", .{}) == null);
}

test "grid auto-repeat reserves fixed siblings and every live gutter" {
    var output: [max_tracks]Track = undefined;
    try std.testing.expectEqual(@as(?usize, 3), parse("100px repeat(auto-fill, 100px)", .{ .percentage_base = 300 }, 0, 0, &output));
    try std.testing.expectEqual(@as(?usize, 3), parse("repeat(auto-fill, 100px) 100px", .{ .percentage_base = 300 }, 0, 0, &output));
    try std.testing.expectEqual(@as(?usize, 4), parse("40px repeat(auto-fit, minmax(50px, 1fr)) 60px", .{ .percentage_base = 230 }, 10, 1, &output));
    try std.testing.expect(!output[0].auto_fit and output[1].auto_fit and output[2].auto_fit and !output[3].auto_fit);
    try std.testing.expectEqual(@as(f64, 60), output[3].min);
    try std.testing.expectEqual(@as(?usize, 3), parse("40px repeat(auto-fit, 50px) 60px", .{}, 10, 0, &output));
    try std.testing.expect(parse("repeat(auto-fill, 20px) repeat(auto-fit, 20px)", .{ .percentage_base = 100 }, 0, 0, &output) == null);
    try std.testing.expect(parse("1fr repeat(auto-fit, 20px)", .{ .percentage_base = 100 }, 0, 0, &output) == null);
}
