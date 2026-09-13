//! Pure single-animation grammar and frame-timeline phase calculation.
//! Specs borrow names/tokens only while parsed; Element playback stores scalars.
const std = @import("std");
const easing = @import("easing.zig");
const lexer = @import("css_tokenizer.zig");
const syntax = @import("css_syntax.zig");
const math = @import("css_math.zig");
const components = @import("grid_tracks.zig").Components;

pub const Direction = enum { normal, reverse, alternate, alternate_reverse };
pub const FillMode = enum { none, forwards, backwards, both };
pub const names = [_][]const u8{ "animation-duration", "animation-timing-function", "animation-delay", "animation-iteration-count", "animation-direction", "animation-fill-mode", "animation-play-state", "animation-name" };
pub const defaults = [_][]const u8{ "0s", "ease", "0s", "1", "normal", "none", "running", "none" };

pub const Spec = struct {
    name: []const u8 = "none",
    frames: u32 = 0,
    duration: f64 = 0,
    delay: f64 = 0,
    easing_function: easing.Function = .ease,
    iterations: ?f64 = 1,
    direction: Direction = .normal,
    fill_mode: FillMode = .none,
    paused: bool = false,
    values: [8][]const u8 = defaults,
};

pub fn time(source: []const u8) ?f64 {
    return timeWithContext(source, .{});
}

fn timeWithContext(source: []const u8, context: math.Context) ?f64 {
    const computed = math.evaluate(source, context) orelse return null;
    if (computed.dimension != .time) return null;
    const seconds = computed.value;
    return if (std.math.isFinite(seconds) and @abs(seconds * 60) <= std.math.maxInt(u32)) seconds else null;
}

fn count(source: []const u8) ??f64 {
    if (std.ascii.eqlIgnoreCase(source, "infinite")) return @as(?f64, null);
    const computed = math.evaluate(source, .{}) orelse return null;
    if (computed.dimension != .number) return null;
    const number = computed.value;
    return if (std.math.isFinite(number) and (number >= 0 or math.isMath(source)) and number <= std.math.maxInt(u32)) @as(?f64, @max(0, number)) else null;
}

pub fn direction(source: []const u8) ?Direction {
    if (std.ascii.eqlIgnoreCase(source, "normal")) return .normal;
    if (std.ascii.eqlIgnoreCase(source, "reverse")) return .reverse;
    if (std.ascii.eqlIgnoreCase(source, "alternate")) return .alternate;
    if (std.ascii.eqlIgnoreCase(source, "alternate-reverse")) return .alternate_reverse;
    return null;
}

pub fn fillMode(source: []const u8) ?FillMode {
    inline for (.{ "none", "forwards", "backwards", "both" }) |name| if (std.ascii.eqlIgnoreCase(source, name)) return @field(FillMode, name);
    return null;
}

fn validName(source: []const u8) bool {
    var iterator = lexer.Iterator{ .input = source };
    const token = iterator.next() orelse return false;
    if (token.kind != .ident or token.end != source.len) return false;
    for ([_][]const u8{ "initial", "inherit", "unset", "revert", "revert-layer", "default" }) |keyword| if (lexer.identifierEquals(token.encodedValue(source), keyword)) return false;
    return true;
}

pub fn validKeyframesName(source: []const u8) bool {
    return validName(source) and !lexer.identifierEquals(source, "none");
}

fn first(source: []const u8) []const u8 {
    const end = syntax.scanToTopLevel(source, 0, ",");
    return std.mem.trim(u8, source[0..end.end], " \t\r\n");
}

/// Longhand lists may have extra entries unused by the supported single name.
/// Multiple animation names remain unsupported, rather than silently dropping
/// independently timed effects that would compete for the same property.
pub fn validLonghand(name: []const u8, source: []const u8) bool {
    var index: usize = 0;
    while (index < names.len and !std.mem.eql(u8, name, names[index])) : (index += 1) {}
    if (index == names.len) return false;
    var cursor: usize = 0;
    while (true) {
        const end = syntax.scanToTopLevel(source, cursor, ",");
        if (end.exhausted) return false;
        const value = std.mem.trim(u8, source[cursor..end.end], " \t\r\n");
        const valid = switch (index) {
            0 => if (time(value)) |seconds| seconds >= 0 or math.isMath(value) else false,
            1 => easing.parse(value) != null,
            2 => time(value) != null,
            3 => count(value) != null,
            4 => direction(value) != null,
            5 => fillMode(value) != null,
            6 => std.ascii.eqlIgnoreCase(value, "running") or std.ascii.eqlIgnoreCase(value, "paused"),
            7 => validName(value) and end.delimiter == null,
            else => unreachable,
        };
        if (!valid) return false;
        if (end.delimiter == null) return true;
        cursor = end.end + 1;
    }
}

pub fn fromValues(values: [8][]const u8) ?Spec {
    for (names, values) |name, value| if (!validLonghand(name, value)) return null;
    const duration = @max(0, time(first(values[0])).?);
    return .{
        .name = values[7],
        .frames = @intFromFloat(duration * 60),
        .duration = duration,
        .easing_function = easing.parse(first(values[1])).?,
        .delay = time(first(values[2])).?,
        .iterations = count(first(values[3])).?,
        .direction = direction(first(values[4])).?,
        .fill_mode = fillMode(first(values[5])).?,
        .paused = std.ascii.eqlIgnoreCase(first(values[6]), "paused"),
        .values = values,
    };
}

/// Caller owns the computed list. Specified values retain their authored time
/// units; this conversion runs only once the style owner supplies unit bases.
pub fn serializeComputed(allocator: std.mem.Allocator, name: []const u8, source: []const u8, context: math.Context) ![]u8 {
    const is_time = std.mem.eql(u8, name, "animation-duration") or std.mem.eql(u8, name, "animation-delay");
    if ((!is_time and !std.mem.eql(u8, name, "animation-iteration-count")) or !validLonghand(name, source)) return allocator.dupe(u8, source);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var cursor: usize = 0;
    while (true) {
        const end = syntax.scanToTopLevel(source, cursor, ",");
        const component = std.mem.trim(u8, source[cursor..end.end], " \t\r\n");
        if (cursor != 0) try result.appendSlice(allocator, ", ");
        if (std.ascii.eqlIgnoreCase(component, "infinite")) {
            try result.appendSlice(allocator, "infinite");
        } else {
            var value = if (is_time) timeWithContext(component, context) orelse 0 else (math.evaluate(component, context) orelse math.Value{ .value = 0, .dimension = .number }).value;
            if (!std.math.isFinite(value)) value = 0;
            if (!std.mem.eql(u8, name, "animation-delay")) value = @max(0, value);
            var buffer: [384]u8 = undefined;
            try result.appendSlice(allocator, std.fmt.bufPrint(&buffer, "{d}{s}", .{ if (value == 0) @as(f64, 0) else value, if (is_time) "s" else "" }) catch unreachable);
        }
        if (end.delimiter == null) break;
        cursor = end.end + 1;
    }
    return result.toOwnedSlice(allocator);
}

/// Parse one shorthand, applying the CSS keyword disambiguation order and
/// resetting every omitted longhand. A second time is the signed delay.
pub fn parse(source: []const u8) ?Spec {
    if (syntax.scanToTopLevel(source, 0, ",").delimiter != null) return null;
    var values = defaults;
    var seen = [_]bool{false} ** 8;
    var iterator = components{ .input = source };
    var any = false;
    while (iterator.next()) |token| {
        any = true;
        var selected: ?usize = null;
        if (time(token)) |seconds| {
            if (!seen[0]) {
                if (seconds < 0 and !math.isMath(token)) return null;
                selected = 0;
            } else if (!seen[2]) selected = 2 else return null;
        } else if (!seen[1] and easing.parse(token) != null) {
            selected = 1;
        } else if (!seen[3] and count(token) != null) {
            selected = 3;
        } else if (!seen[4] and direction(token) != null) {
            selected = 4;
        } else if (!seen[5] and fillMode(token) != null) {
            selected = 5;
        } else if (!seen[6] and (std.ascii.eqlIgnoreCase(token, "running") or std.ascii.eqlIgnoreCase(token, "paused"))) {
            selected = 6;
        } else if (!seen[7] and validName(token)) {
            selected = 7;
        } else return null;
        const index = selected.?;
        seen[index] = true;
        values[index] = token;
    }
    return if (any) fromValues(values) else null;
}

/// Pure timing scalars; no name, source, DOM or animation-track borrow survives.
pub const Timing = struct {
    duration_frames: f64,
    delay_frames: f64 = 0,
    iterations: ?f64 = 1,
    direction: Direction = .normal,
    fill_mode: FillMode = .none,
    paused: bool = false,

    pub const Sample = struct { progress: ?f64, finished: bool };

    pub fn fromSpec(spec: Spec) Timing {
        return .{ .duration_frames = spec.duration * 60, .delay_frames = spec.delay * 60, .iterations = spec.iterations, .direction = spec.direction, .fill_mode = spec.fill_mode, .paused = spec.paused };
    }

    pub fn sample(self: Timing, elapsed_frames: f64) Sample {
        const active = elapsed_frames - self.delay_frames;
        const total = self.duration_frames * (self.iterations orelse std.math.inf(f64));
        const before = active < 0;
        const after = !before and (self.duration_frames == 0 or active >= total);
        const fills = if (before) self.fill_mode == .backwards or self.fill_mode == .both else if (after) self.fill_mode == .forwards or self.fill_mode == .both else true;
        if (!fills) return .{ .progress = null, .finished = after };
        const overall = if (before) 0 else if (after) self.iterations orelse 1 else active / self.duration_frames;
        var iteration = @floor(overall);
        var progress = overall - iteration;
        if (after and overall > 0 and progress == 0) {
            iteration -= 1;
            progress = 1;
        }
        const reversed = switch (self.direction) {
            .normal => false,
            .reverse => true,
            .alternate => @mod(iteration, 2) == 1,
            .alternate_reverse => @mod(iteration, 2) == 0,
        };
        return .{ .progress = if (reversed) 1 - progress else progress, .finished = after };
    }
};

test "animation shorthand parses the chapter demo" {
    const spec = parse("2s infinite alternate fade").?;
    try std.testing.expectEqualStrings("fade", spec.name);
    try std.testing.expectEqual(@as(u32, 120), spec.frames);
    try std.testing.expect(spec.iterations == null);
    try std.testing.expectEqual(Direction.alternate, spec.direction);
    try std.testing.expectApproxEqAbs(0.802403, spec.easing_function.apply(0.5), 0.000001);
}

test "animation shorthand supports finite linear animation and rejects unsupported lists" {
    const spec = parse("narrow 500ms linear 3").?;
    try std.testing.expectEqualStrings("narrow", spec.name);
    try std.testing.expectEqual(@as(u32, 30), spec.frames);
    try std.testing.expectEqual(@as(?f64, 3), spec.iterations);
    try std.testing.expectApproxEqAbs(0.5, spec.easing_function.apply(0.5), 0.000001);

    try std.testing.expect(parse("1s fade, 1s pulse") == null);
    try std.testing.expect(parse("1s fade , 1s pulse") == null);
    try std.testing.expectEqual(FillMode.backwards, parse("1s backwards fade").?.fill_mode);
    try std.testing.expect(parse("0s fade") != null);
}

test "animation fill phases cover delays direction fractional endpoints and zero duration" {
    var timing = Timing{ .duration_frames = 4, .delay_frames = 2 };
    try std.testing.expect(timing.sample(0).progress == null);
    try std.testing.expectEqual(@as(?f64, 0), timing.sample(2).progress);
    try std.testing.expectEqual(@as(?f64, 0.5), timing.sample(4).progress);
    try std.testing.expect(timing.sample(6).finished and timing.sample(6).progress == null);
    timing.fill_mode = .forwards;
    try std.testing.expect(timing.sample(0).progress == null);
    try std.testing.expectEqual(@as(?f64, 1), timing.sample(6).progress);
    timing.fill_mode = .backwards;
    try std.testing.expectEqual(@as(?f64, 0), timing.sample(0).progress);
    try std.testing.expect(timing.sample(6).progress == null);
    timing.fill_mode = .both;
    timing.direction = .reverse;
    try std.testing.expectEqual(@as(?f64, 1), timing.sample(0).progress);
    try std.testing.expectEqual(@as(?f64, 0), timing.sample(6).progress);
    timing.direction = .alternate;
    timing.iterations = 2;
    try std.testing.expectEqual(@as(?f64, 0), timing.sample(10).progress);
    timing.iterations = 2.5;
    try std.testing.expectEqual(@as(?f64, 0.5), timing.sample(12).progress);
    timing.delay_frames = -6;
    try std.testing.expectEqual(@as(?f64, 0.5), timing.sample(0).progress);
    timing.iterations = 0;
    try std.testing.expectEqual(@as(?f64, 0), timing.sample(0).progress);
    timing.iterations = 1;
    timing.duration_frames = 0;
    try std.testing.expectEqual(@as(?f64, 1), timing.sample(0).progress);
    try std.testing.expect(timing.sample(0).finished);
    const parsed = parse("pulse 100ms -50ms linear 2.5 alternate-reverse both paused").?;
    try std.testing.expect(parsed.paused);
    try std.testing.expectEqual(@as(f64, -0.05), parsed.delay);
    try std.testing.expectEqual(Direction.alternate_reverse, parsed.direction);
    try std.testing.expectEqual(FillMode.both, parsed.fill_mode);
    try std.testing.expect(parse("pulse -1s") == null);
}
