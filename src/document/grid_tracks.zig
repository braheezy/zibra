//! Borrowing grid track-list grammar. Resolves scalar lengths with an explicit
//! CSS context; track allocation and intrinsic measurements belong to layout.
const std = @import("std");
const length = @import("length.zig");
const syntax = @import("css_syntax.zig");
const tokens = @import("css_value_tokens.zig");

pub const max_tracks = 256;
pub const Track = struct {
    min: f64 = 0,
    max: ?f64 = null,
    fraction: f64 = 0,
    auto_min: bool = true,
    auto_max: bool = true,
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
            } else if ((token.end == token.start + 1 and syntax.isWhitespace(self.input[token.start])) or
                std.mem.startsWith(u8, self.input[token.start..token.end], "/*"))
            {
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
    if (std.ascii.eqlIgnoreCase(text, "auto") or std.ascii.eqlIgnoreCase(text, "min-content") or std.ascii.eqlIgnoreCase(text, "max-content")) return .{};
    if (length.resolve(text, context)) |size| return .{ .min = size, .max = size, .auto_min = false, .auto_max = false };
    if (fraction(text)) |fr| return .{ .fraction = fr, .auto_max = false };
    if (text.len > 8 and std.ascii.startsWithIgnoreCase(text, "minmax(") and text[text.len - 1] == ')') {
        const inner = text[7 .. text.len - 1];
        const comma = syntax.scanToTopLevel(inner, 0, ",");
        if (comma.delimiter == null) return null;
        const low = std.mem.trim(u8, inner[0..comma.end], " \t\r\n");
        const high = std.mem.trim(u8, inner[comma.end + 1 ..], " \t\r\n");
        var result: Track = .{};
        if (length.resolve(low, context)) |size| {
            result.min = size;
            result.auto_min = false;
        } else if (!std.ascii.eqlIgnoreCase(low, "auto") and !std.ascii.eqlIgnoreCase(low, "min-content") and !std.ascii.eqlIgnoreCase(low, "max-content")) return null;
        if (length.resolve(high, context)) |size| {
            result.max = @max(size, result.min);
            result.auto_max = false;
        } else if (fraction(high)) |fr| {
            result.fraction = fr;
            result.auto_max = false;
        } else if (!std.ascii.eqlIgnoreCase(high, "auto") and !std.ascii.eqlIgnoreCase(high, "max-content") and !std.ascii.eqlIgnoreCase(high, "min-content")) return null;
        return result;
    }
    return null;
}

/// Fills caller storage; null means unsupported/invalid grammar. Auto-repeat
/// supports a single definite-minimum track, the common responsive-card form.
pub fn parse(raw: []const u8, context: length.ResolutionContext, gap: f64, item_count: usize, output: []Track) ?usize {
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\r\n"), "none")) return 0;
    var iterator = Components{ .input = raw };
    var count: usize = 0;
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
                if (pattern_count != 1 or pattern[0].auto_min) return null;
                const breadth = @max(pattern[0].max orelse pattern[0].min, 1);
                const available = context.percentage_base orelse breadth;
                var n: usize = @intFromFloat(std.math.clamp(@floor((available + gap) / (breadth + gap)), 1, max_tracks));
                if (std.ascii.eqlIgnoreCase(repeat, "auto-fit")) n = @min(n, @max(item_count, 1));
                break :blk n;
            } else std.fmt.parseInt(usize, repeat, 10) catch return null;
            if (repetitions == 0 or repetitions > (output.len - count) / pattern_count) return null;
            for (0..repetitions) |_| {
                @memcpy(output[count .. count + pattern_count], pattern[0..pattern_count]);
                count += pattern_count;
            }
        } else {
            if (count == output.len) return null;
            output[count] = parseTrack(component, context) orelse return null;
            count += 1;
        }
    }
    return if (count > 0) count else null;
}
