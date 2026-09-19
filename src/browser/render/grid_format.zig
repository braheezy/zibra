//! Scalar grid track sizing for fixed, intrinsic, fractional and minmax tracks.
//! Receives no DOM, retained layout object or dependency-bearing field.
const std = @import("std");
const sizing = @import("sizing.zig");
pub const tracks = @import("../../document/grid_tracks.zig");
pub const Track = tracks.Track;

pub const Contribution = struct {
    minimum: f64 = 0,
    min_content: f64 = 0,
    max_content: f64 = 0,
};

pub const IntrinsicConstraint = enum { min_content, max_content };

pub const SpanContribution = struct {
    start: usize,
    span: usize = 1,
    contribution: Contribution = .{},
};

pub const AreaPolicy = struct {
    automatic_minimum: bool,
    fixed_maximum: ?f64,
};

/// Summarizes track-dependent item constraints. The caller independently tests
/// the relevant computed overflow axis and subtracts its own margins/insets.
pub fn areaPolicy(input: []const Track, gap: f64) AreaPolicy {
    var automatic = false;
    var flexible = false;
    var fixed = true;
    var maximum: f64 = 0;
    var active: usize = 0;
    for (input) |track| {
        if (track.collapsed) continue;
        active += 1;
        automatic = automatic or track.min_kind == .auto;
        flexible = flexible or track.max_kind == .fraction;
        fixed = fixed and track.max_kind == .fixed;
        maximum += track.max orelse track.min;
    }
    if (active > 1) maximum += gap * @as(f64, @floatFromInt(active - 1));
    return .{
        .automatic_minimum = automatic and (input.len <= 1 or !flexible),
        .fixed_maximum = if (fixed) finiteExtent(maximum) else null,
    };
}

/// Preserves explicit line numbering while marking unused auto-fit tracks.
pub fn collapseEmpty(input: []Track, items: []const SpanContribution) void {
    for (input) |*track| track.collapsed = track.auto_fit;
    for (items) |item| {
        std.debug.assert(item.start <= input.len and item.span <= input.len - item.start);
        for (input[item.start..][0..item.span]) |*track| track.collapsed = false;
    }
}

pub fn activeTrackCount(input: []const Track) usize {
    var result: usize = 0;
    for (input) |track| if (!track.collapsed) {
        result += 1;
    };
    return result;
}

/// Collapsed gutters coincide: a run of collapsed tracks between live tracks
/// leaves one gutter, while collapsed leading/trailing tracks leave none.
pub fn gapAfter(input: []const Track, index: usize, gap: f64) f64 {
    if (input[index].collapsed) return 0;
    for (input[index + 1 ..]) |track| if (!track.collapsed) return gap;
    return 0;
}

pub fn areaSize(input: []const Track, sizes: []const f64, start: usize, span: usize, gap: f64) f64 {
    std.debug.assert(input.len == sizes.len and start <= input.len and span <= input.len - start);
    var total: f64 = 0;
    var active: usize = 0;
    for (input[start..][0..span], sizes[start..][0..span]) |track, size| {
        if (track.collapsed) continue;
        total += size;
        active += 1;
    }
    if (active > 1) total += @as(f64, @floatFromInt(active - 1)) * gap;
    return finiteExtent(total);
}

pub fn totalSize(input: []const Track, sizes: []const f64, gap: f64) f64 {
    return areaSize(input, sizes, 0, input.len, gap);
}

/// Returns an area basis only when every occupied track has one fixed size.
/// Intrinsic or flexible rows need content sizing first and supply no basis.
pub fn fixedAreaSize(input: []const Track, gap: f64) ?f64 {
    var total: f64 = 0;
    var active: usize = 0;
    for (input) |track| {
        if (track.collapsed) continue;
        if (track.min_kind != .fixed or track.max_kind != .fixed or track.min != (track.max orelse track.min)) return null;
        total += track.min;
        active += 1;
    }
    if (active > 1) total += gap * @as(f64, @floatFromInt(active - 1));
    return finiteExtent(total);
}

/// Writes each track's start and the final end. Area widths must use areaSize:
/// a following track's start includes its preceding gutter/distributed space.
pub fn positions(input: []const Track, sizes: []const f64, gap: f64, offset: f64, between: f64, output: []f64) void {
    std.debug.assert(input.len == sizes.len and output.len == input.len + 1);
    var cursor = offset;
    var remaining = activeTrackCount(input);
    for (input, sizes, 0..) |track, size, index| {
        output[index] = cursor;
        if (track.collapsed) continue;
        cursor += size;
        remaining -= 1;
        if (remaining > 0) cursor += gap + between;
    }
    output[input.len] = cursor;
}

fn finiteExtent(value: f64) f64 {
    return std.math.clamp(value, 0, sizing.max_intrinsic_extent);
}

const State = struct {
    base: f64,
    limit: f64,
    infinitely_growable: bool = false,
    has_single: bool = false,
    planned: f64 = 0,
    incurred: f64 = 0,
    touched: bool = false,
};

const Phase = enum {
    minimum,
    content_minimum,
    constrained_maximum,
    max_minimum,
    intrinsic_limit,
    max_limit,

    fn growsLimit(self: Phase) bool {
        return self == .intrinsic_limit or self == .max_limit;
    }
};

fn intrinsicKind(kind: tracks.Kind) bool {
    return kind == .auto or kind == .min_content or kind == .max_content or kind == .fit_content;
}

fn affects(track: Track, phase: Phase, flexible: bool) bool {
    if (track.collapsed or (flexible and track.max_kind != .fraction)) return false;
    return switch (phase) {
        .minimum => intrinsicKind(track.min_kind),
        .content_minimum => track.min_kind == .min_content or track.min_kind == .max_content,
        .constrained_maximum => track.min_kind == .auto or track.min_kind == .max_content,
        .max_minimum => track.min_kind == .max_content,
        .intrinsic_limit => intrinsicKind(track.max_kind),
        .max_limit => track.max_kind == .auto or track.max_kind == .max_content or track.max_kind == .fit_content,
    };
}

fn hasFlexible(input: []const Track) bool {
    for (input) |track| if (!track.collapsed and track.max_kind == .fraction) return true;
    return false;
}

fn limited(value: f64, contribution: Contribution, input: []const Track, gap: f64) f64 {
    const cap = if (input.len == 1 and input[0].max_kind == .fit_content) input[0].max else areaPolicy(input, gap).fixed_maximum;
    return @max(contribution.minimum, @min(value, cap orelse std.math.inf(f64)));
}

fn targetSize(item: SpanContribution, input: []const Track, gap: f64, phase: Phase, constraint: ?IntrinsicConstraint, flexible: bool) f64 {
    const contribution = item.contribution;
    return finiteExtent(switch (phase) {
        .minimum => if (constraint != null and !(flexible and item.span > 1)) limited(contribution.min_content, contribution, input, gap) else contribution.minimum,
        .content_minimum, .intrinsic_limit => contribution.min_content,
        .constrained_maximum => limited(contribution.max_content, contribution, input, gap),
        .max_minimum, .max_limit => contribution.max_content,
    });
}

fn affectedSize(state: State, phase: Phase) f64 {
    return if (phase.growsLimit() and std.math.isFinite(state.limit)) state.limit else state.base;
}

fn distributionCap(track: Track, state: State, phase: Phase, beyond: bool) f64 {
    if (beyond) {
        return if (phase.growsLimit() and track.max_kind == .fit_content) @max(state.base, track.max orelse 0) else sizing.max_intrinsic_extent;
    }
    const cap = if (phase.growsLimit() and state.infinitely_growable) std.math.inf(f64) else state.limit;
    return if (track.max_kind == .fit_content) @max(state.base, @min(cap, track.max orelse std.math.inf(f64))) else cap;
}

fn prefersBeyond(track: Track, state: State, phase: Phase) bool {
    if (track.max_kind == .fit_content and affectedSize(state, phase) + state.incurred >= (track.max orelse std.math.inf(f64))) return false;
    return if (phase == .constrained_maximum or phase == .max_minimum or phase == .max_limit)
        track.max_kind == .auto or track.max_kind == .max_content or track.max_kind == .fit_content
    else
        intrinsicKind(track.max_kind);
}

const Distribution = enum { affected, other, beyond };

fn distribute(input: []const Track, states: []State, phase: Phase, flexible: bool, mode: Distribution, extra: *f64) void {
    for (0..input.len + 2) |_| {
        if (extra.* <= 0.000001) return;
        var preferred = false;
        if (mode == .beyond) for (input, states) |track, state| {
            if (affects(track, phase, flexible) and prefersBeyond(track, state, phase)) preferred = true;
        };
        var count: usize = 0;
        var largest: f64 = 0;
        for (input, states) |track, state| {
            const affected = affects(track, phase, flexible);
            const selected = switch (mode) {
                .affected => affected,
                .other => !affected and !track.collapsed and !flexible,
                .beyond => affected and (!preferred or prefersBeyond(track, state, phase)),
            };
            if (!selected or distributionCap(track, state, phase, mode == .beyond) <= affectedSize(state, phase) + state.incurred + 0.000001) continue;
            count += 1;
            largest = @max(largest, track.fraction);
        }
        if (count == 0) return;
        var weights: f64 = 0;
        if (flexible and largest > 0) for (input, states) |track, state| {
            if (!affects(track, phase, true) or distributionCap(track, state, phase, mode == .beyond) <= affectedSize(state, phase) + state.incurred + 0.000001) continue;
            weights += track.fraction / largest;
        };
        const available = extra.*;
        var consumed: f64 = 0;
        for (input, states) |track, *state| {
            const affected = affects(track, phase, flexible);
            const selected = switch (mode) {
                .affected => affected,
                .other => !affected and !track.collapsed and !flexible,
                .beyond => affected and (!preferred or prefersBeyond(track, state.*, phase)),
            };
            if (!selected) continue;
            const capacity = @max(0, distributionCap(track, state.*, phase, mode == .beyond) - affectedSize(state.*, phase) - state.incurred);
            if (capacity <= 0.000001) continue;
            var weight = 1 / @as(f64, @floatFromInt(count));
            if (flexible and weights > 0) {
                const fraction = track.fraction / largest;
                // Below a total factor of one, the undistributed fraction is
                // shared equally; normalization avoids large-factor overflow.
                const factor_total = largest * weights;
                weight = if (factor_total >= 1) fraction / weights else track.fraction + (1 - factor_total) / @as(f64, @floatFromInt(count));
            }
            const addition = @min(capacity, available * weight);
            state.incurred += addition;
            consumed += addition;
        }
        extra.* = @max(0, extra.* - consumed);
        if (consumed <= 0.000001) return;
    }
}

fn phaseItems(input: []const Track, items: []const SpanContribution, states: []State, gap: f64, phase: Phase, constraint: ?IntrinsicConstraint, span: usize, flexible: bool) void {
    for (states) |*state| {
        state.planned = 0;
        state.touched = false;
    }
    for (items) |item| {
        if (item.span <= 1 or (!flexible and item.span != span)) continue;
        const selected = input[item.start..][0..item.span];
        if (hasFlexible(selected) != flexible) continue;
        const subset = states[item.start..][0..item.span];
        var any = false;
        var current: f64 = 0;
        const active = activeTrackCount(selected);
        if (active > 1) current = gap * @as(f64, @floatFromInt(active - 1));
        for (selected, subset) |track, *state| {
            state.incurred = 0;
            current += affectedSize(state.*, phase);
            if (affects(track, phase, flexible)) {
                any = true;
                state.touched = true;
            }
        }
        if (!any) continue;
        var extra = @max(0, targetSize(item, selected, gap, phase, constraint, flexible) - current);
        distribute(selected, subset, phase, flexible, .affected, &extra);
        distribute(selected, subset, phase, flexible, .other, &extra);
        distribute(selected, subset, phase, flexible, .beyond, &extra);
        for (subset) |*state| state.planned = @max(state.planned, state.incurred);
    }
    // Each item used the unchanged start-of-phase sizes. Commit only maxima
    // after the entire same-span group to keep sibling order irrelevant.
    for (states) |*state| {
        if (phase.growsLimit()) {
            if (state.touched or state.planned > 0) {
                if (phase == .intrinsic_limit and !std.math.isFinite(state.limit)) state.infinitely_growable = true;
                state.limit = finiteExtent(affectedSize(state.*, phase) + state.planned);
            }
        } else {
            state.base = finiteExtent(state.base + state.planned);
            state.limit = @max(state.limit, state.base);
        }
    }
    if (phase == .max_limit) for (states) |*state| {
        state.infinitely_growable = false;
    };
}

fn intrinsicStates(input: []const Track, items: []const SpanContribution, gap: f64, constraint: ?IntrinsicConstraint, states: []State) void {
    for (input, states) |track, *state| state.* = .{
        .base = if (!track.collapsed and track.min_kind == .fixed) finiteExtent(track.min) else 0,
        .limit = if (track.collapsed) 0 else if (track.max_kind == .fixed) finiteExtent(@max(track.min, track.max orelse track.min)) else std.math.inf(f64),
    };
    for (items) |item| {
        std.debug.assert(item.span > 0 and item.start <= input.len and item.span <= input.len - item.start);
        if (item.span != 1) continue;
        const track = input[item.start];
        if (track.collapsed) continue;
        const state = &states[item.start];
        const contribution = item.contribution;
        const minimum = if (track.min_kind == .auto and constraint != null) limited(contribution.min_content, contribution, input[item.start..][0..1], 0) else baseSize(track, contribution);
        state.base = @max(state.base, finiteExtent(minimum));
        if (intrinsicKind(track.max_kind)) {
            const growth = growthLimit(track, contribution, state.base);
            state.limit = if (state.has_single) @max(state.limit, growth) else growth;
        }
        state.has_single = true;
        state.limit = @max(state.base, state.limit);
    }
    var previous_span: usize = 1;
    while (true) {
        var next_span: usize = std.math.maxInt(usize);
        for (items) |item| if (item.span > previous_span and item.span < next_span and !hasFlexible(input[item.start..][0..item.span])) {
            next_span = item.span;
        };
        if (next_span == std.math.maxInt(usize)) break;
        inline for (std.meta.tags(Phase)) |phase| {
            if (phase != .constrained_maximum or constraint == .max_content) phaseItems(input, items, states, gap, phase, constraint, next_span, false);
        }
        previous_span = next_span;
    }
    // Interoperable min-content behavior for multi-track flexible spans uses
    // their actual minimum contribution (often zero), as exercised by WPT
    // grid-flex-spanning-items-001. Explicit intrinsic minima still participate
    // in content_minimum; max-content expansion uses the span's fr requirement.
    inline for (std.meta.tags(Phase)) |phase| {
        if (phase != .constrained_maximum) phaseItems(input, items, states, gap, phase, constraint, 0, true);
    }
    for (states) |*state| if (!std.math.isFinite(state.limit)) {
        state.limit = state.base;
    };
}

fn fractionUnit(input: []const Track, states: []const State, extent: f64, gap: f64, largest: f64) f64 {
    if (largest <= 0) return 0;
    var unit = std.math.inf(f64);
    for (0..input.len + 1) |_| {
        const active = activeTrackCount(input);
        var free = extent - if (active > 1) gap * @as(f64, @floatFromInt(active - 1)) else 0;
        var fractions: f64 = 0;
        for (input, states) |track, state| {
            const factor = track.fraction / largest;
            if (!track.collapsed and track.max_kind == .fraction and factor > 0 and state.base <= unit * factor) fractions += factor else free -= state.base;
        }
        const next = if (fractions > 0) @max(0, free) / @max(fractions, 1 / largest) else 0;
        if (next == unit) break;
        unit = next;
    }
    return unit;
}

fn finishStates(input: []const Track, items: []const SpanContribution, states: []State, available: ?f64, gap: f64, constraint: ?IntrinsicConstraint, stretch: bool, output: []f64) void {
    const active = activeTrackCount(input);
    const gutters = if (active > 1) gap * @as(f64, @floatFromInt(active - 1)) else 0;
    if (constraint != .min_content) {
        if (available) |extent| {
            var free = extent - gutters;
            for (states) |state| free -= state.base;
            for (0..states.len + 1) |_| {
                var count: usize = 0;
                for (input, states) |track, state| if (!track.collapsed and track.max_kind != .fraction and state.limit > state.base + 0.000001) {
                    count += 1;
                };
                if (count == 0 or free <= 0.000001) break;
                const share = free / @as(f64, @floatFromInt(count));
                for (input, states) |track, *state| if (!track.collapsed and track.max_kind != .fraction) {
                    const addition = @min(share, @max(0, state.limit - state.base));
                    state.base += addition;
                    free -= addition;
                };
            }
        } else {
            for (input, states) |track, *state| {
                if (track.max_kind != .fraction) state.base = state.limit;
            }
        }

        var largest: f64 = 0;
        for (input) |track| if (!track.collapsed and track.max_kind == .fraction) {
            largest = @max(largest, track.fraction);
        };
        if (largest > 0) {
            var unit: f64 = 0;
            if (available) |extent| {
                unit = fractionUnit(input, states, extent, gap, largest);
            } else {
                for (input, states) |track, state| if (track.max_kind == .fraction and track.fraction > 0) {
                    unit = @max(unit, state.base / @max(track.fraction / largest, 1 / largest));
                };
                for (items) |item| {
                    const selected = input[item.start..][0..item.span];
                    if (hasFlexible(selected)) unit = @max(unit, fractionUnit(selected, states[item.start..][0..item.span], finiteExtent(item.contribution.max_content), gap, largest));
                }
            }
            for (input, states) |track, *state| if (!track.collapsed and track.max_kind == .fraction and track.fraction > 0) {
                // A representable authored factor ratio can require an fr
                // unit beyond f64. Saturate the used result before conversion
                // to integer layout rather than leaking infinity or NaN.
                const used = if (std.math.isFinite(unit)) finiteExtent(unit * (track.fraction / largest)) else sizing.max_intrinsic_extent;
                state.base = @max(state.base, used);
            };
        }
    }
    if (stretch and available != null) {
        var count: usize = 0;
        var free = available.? - gutters;
        for (input, states) |track, state| {
            free -= state.base;
            if (!track.collapsed and track.max_kind == .auto) count += 1;
        }
        if (count > 0 and free > 0) for (input, states) |track, *state| {
            if (!track.collapsed and track.max_kind == .auto) state.base += free / @as(f64, @floatFromInt(count));
        };
    }
    for (states, output) |state, *used| used.* = finiteExtent(state.base);
}

/// Resolves scalar spans. Temporary state is allocator-owned only for this call;
/// caller-owned output is written after all fallible allocations succeed.
pub fn resolveSpans(allocator: std.mem.Allocator, input: []const Track, items: []const SpanContribution, available: ?f64, gap: f64, stretch: bool, output: []f64) !void {
    std.debug.assert(input.len == output.len);
    const states = try allocator.alloc(State, input.len);
    defer allocator.free(states);
    intrinsicStates(input, items, gap, null, states);
    finishStates(input, items, states, available, gap, null, stretch, output);
}

/// Resolves the same placed spans without a percentage basis. Scratch and the
/// returned total stay in bounded page-space units, independently of CSS zoom.
pub fn intrinsicSpans(allocator: std.mem.Allocator, input: []const Track, items: []const SpanContribution, gap: f64, constraint: IntrinsicConstraint, scratch: []f64) !f64 {
    std.debug.assert(input.len == scratch.len);
    const states = try allocator.alloc(State, input.len);
    defer allocator.free(states);
    intrinsicStates(input, items, gap, constraint, states);
    finishStates(input, items, states, null, gap, constraint, false, scratch);
    return totalSize(input, scratch, gap);
}

// Test adapters retain the pre-span regression vectors while exercising the
// production solver. Allocation-failure behavior is tested through its public API.
fn intrinsicSize(input: []const Track, intrinsic: []const Contribution, gap: f64, constraint: IntrinsicConstraint, scratch: []f64) f64 {
    const items = std.testing.allocator.alloc(SpanContribution, intrinsic.len) catch unreachable;
    defer std.testing.allocator.free(items);
    for (items, intrinsic, 0..) |*item, contribution, index| item.* = .{ .start = index, .contribution = contribution };
    return intrinsicSpans(std.testing.allocator, input, items, gap, constraint, scratch) catch unreachable;
}

fn baseSize(track: Track, intrinsic: Contribution) f64 {
    return @max(0, switch (track.min_kind) {
        .fixed => track.min,
        .auto => intrinsic.minimum,
        .min_content => intrinsic.min_content,
        .max_content => intrinsic.max_content,
        .fraction, .fit_content => unreachable,
    });
}

fn growthLimit(track: Track, intrinsic: Contribution, base: f64) f64 {
    return @max(base, switch (track.max_kind) {
        .fixed => track.max orelse track.min,
        .auto, .max_content => intrinsic.max_content,
        .min_content => intrinsic.min_content,
        .fraction => std.math.inf(f64),
        .fit_content => @min(intrinsic.max_content, track.max orelse std.math.inf(f64)),
    });
}

test "grid intrinsic constraints separate auto minima from zero fractional minima" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("auto minmax(0,1fr) 1fr 30px", .{}, 10, 4, &parsed).?;
    const contributions = [_]Contribution{
        .{ .minimum = 0, .min_content = 40, .max_content = 100 },
        .{ .minimum = 0, .min_content = 50, .max_content = 80 },
        .{ .minimum = 20, .min_content = 60, .max_content = 120 },
        .{},
    };
    var scratch: [4]f64 = undefined;
    try std.testing.expectEqual(@as(f64, 160), intrinsicSize(parsed[0..count], &contributions, 10, .min_content, &scratch));
    try std.testing.expectEqual(@as(f64, 400), intrinsicSize(parsed[0..count], &contributions, 10, .max_content, &scratch));
    try std.testing.expectEqual(@as(f64, 120), scratch[1]);
    try std.testing.expectEqual(@as(f64, 120), scratch[2]);
}

test "grid intrinsic fixed maxima limit auto contributions but preserve explicit minima" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("minmax(auto,50px) fit-content(60px) max-content", .{}, 0, 3, &parsed).?;
    var contributions = [_]Contribution{.{ .minimum = 0, .min_content = 80, .max_content = 120 }} ** 3;
    // The automatic item minimum is a separate contribution; fit-content
    // preserves it even when the function's argument is smaller.
    contributions[1].minimum = 80;
    var scratch: [3]f64 = undefined;
    try std.testing.expectEqual(@as(f64, 250), intrinsicSize(parsed[0..count], &contributions, 0, .min_content, &scratch));
    try std.testing.expectEqual(@as(f64, 250), intrinsicSize(parsed[0..count], &contributions, 0, .max_content, &scratch));
    contributions[0].minimum = 90;
    try std.testing.expectEqual(@as(f64, 290), intrinsicSize(parsed[0..count], &contributions, 0, .min_content, &scratch));
}

test "grid fit content limits intrinsic contributions above a zero item minimum" {
    // CSS Grid §12.5 caps limited min-content by fit-content(), then floors
    // it by the actual minimum contribution. Explicit min-width:0 differs
    // from the automatic min-content floor in the adjacent test.
    const track = Track{ .max_kind = .fit_content, .max = 60 };
    const item = SpanContribution{ .start = 0, .contribution = .{ .minimum = 0, .min_content = 80, .max_content = 120 } };
    var scratch: [1]f64 = undefined;
    try std.testing.expectEqual(@as(f64, 60), try intrinsicSpans(std.testing.allocator, &.{track}, &.{item}, 0, .min_content, &scratch));
    try std.testing.expectEqual(@as(f64, 60), try intrinsicSpans(std.testing.allocator, &.{track}, &.{item}, 0, .max_content, &scratch));
}

fn resolve(input: []const Track, intrinsic: []const Contribution, available: ?f64, gap: f64, stretch: bool, output: []f64) void {
    const items = std.testing.allocator.alloc(SpanContribution, intrinsic.len) catch unreachable;
    defer std.testing.allocator.free(items);
    for (items, intrinsic, 0..) |*item, contribution, index| item.* = .{ .start = index, .contribution = contribution };
    resolveSpans(std.testing.allocator, input, items, available, gap, stretch, output) catch unreachable;
}

test "grid fixed and fr tracks subtract gaps and freeze intrinsic minima" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("100px minmax(0, 1fr) 2fr", .{ .percentage_base = 640 }, 20, 3, &parsed).?;
    var sizes: [3]f64 = undefined;
    resolve(parsed[0..count], &.{ .{}, .{}, .{} }, 640, 20, true, &sizes);
    try std.testing.expectApproxEqAbs(@as(f64, 100), sizes[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 500.0 / 3.0), sizes[1], 0.001);
    resolve(&.{ .{ .fraction = 1, .max_kind = .fraction }, .{ .fraction = 1, .max_kind = .fraction } }, &.{ .{ .minimum = 400 }, .{ .minimum = 20 } }, 600, 0, true, sizes[0..2]);
    try std.testing.expectEqual(@as(f64, 400), sizes[0]);
    try std.testing.expectEqual(@as(f64, 200), sizes[1]);
}

test "grid distinguishes intrinsic track minima growth limits and auto stretch" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("min-content max-content auto", .{}, 0, 3, &parsed).?;
    var output: [3]f64 = undefined;
    const contribution = Contribution{ .minimum = 20, .min_content = 40, .max_content = 100 };
    resolve(parsed[0..count], &.{ contribution, contribution, contribution }, 400, 0, true, &output);
    try std.testing.expectEqual(@as(f64, 40), output[0]);
    try std.testing.expectEqual(@as(f64, 100), output[1]);
    try std.testing.expectEqual(@as(f64, 260), output[2]);
    resolve(parsed[0..count], &.{ contribution, contribution, contribution }, 400, 0, false, &output);
    try std.testing.expectEqual(@as(f64, 100), output[2]);
}

test "grid grows finite tracks then flexes and keeps fit content min floors" {
    var parsed: [tracks.max_tracks]Track = undefined;
    const count = tracks.parse("minmax(20px, 100px) 1fr fit-content(60px)", .{}, 0, 3, &parsed).?;
    var output: [3]f64 = undefined;
    resolve(parsed[0..count], &.{ .{}, .{ .minimum = 20, .min_content = 20, .max_content = 40 }, .{ .minimum = 80, .min_content = 80, .max_content = 120 } }, 300, 0, true, &output);
    try std.testing.expectEqual(@as(f64, 100), output[0]);
    try std.testing.expectEqual(@as(f64, 120), output[1]);
    try std.testing.expectEqual(@as(f64, 80), output[2]);
}

test "grid zero fractions do not stretch and implicit rows need no bounded scratch" {
    var output: [300]f64 = undefined;
    const input = [_]Track{.{ .fraction = 1, .max_kind = .fraction }} ** 300;
    const intrinsic = [_]Contribution{.{ .minimum = 1 }} ** 300;
    resolve(&input, &intrinsic, 600, 0, false, &output);
    try std.testing.expectEqual(@as(f64, 2), output[299]);
    resolve(&.{.{ .min_kind = .fixed, .max_kind = .fraction }}, &.{.{ .max_content = 100 }}, 200, 0, true, output[0..1]);
    try std.testing.expectEqual(@as(f64, 0), output[0]);
}

test "grid large finite fractions preserve normalized allocation" {
    var output: [2]f64 = undefined;
    resolve(&.{ .{ .min_kind = .fixed, .max_kind = .fraction, .fraction = 1e308 }, .{ .min_kind = .fixed, .max_kind = .fraction, .fraction = 1e308 } }, &.{ .{}, .{} }, 100, 0, false, &output);
    try std.testing.expectEqual(@as(f64, 50), output[0]);
    try std.testing.expectEqual(@as(f64, 50), output[1]);
}

test "responsive grid repeat preserves explicit auto-fit lines before placement" {
    var parsed: [tracks.max_tracks]Track = undefined;
    try std.testing.expectEqual(@as(?usize, 3), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 700 }, 20, 9, &parsed));
    try std.testing.expectEqual(@as(?usize, 3), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 700 }, 20, 2, &parsed));
    try std.testing.expect(parsed[2].auto_fit);
    try std.testing.expectEqual(@as(?usize, 1), tracks.parse("repeat(auto-fit, minmax(200px, 1fr))", .{ .percentage_base = 300 }, 20, 9, &parsed));
    try std.testing.expectEqual(@as(?usize, 4), tracks.parse("repeat(2, 20px 1fr)", .{}, 0, 4, &parsed));
    try std.testing.expect(tracks.parse("repeat(0, 1fr)", .{}, 0, 1, &parsed) == null);
}

test "grid spanning auto minima inspect every track and all fixed maximums" {
    const fixed = Track{ .min = 20, .max = 60, .min_kind = .fixed, .max_kind = .fixed };
    const automatic = Track{ .max = 70, .max_kind = .fixed };
    const result = areaPolicy(&.{ fixed, automatic }, 10);
    try std.testing.expect(result.automatic_minimum);
    try std.testing.expectEqual(@as(?f64, 140), result.fixed_maximum);
    try std.testing.expect(!areaPolicy(&.{ automatic, .{ .fraction = 1, .max_kind = .fraction } }, 10).automatic_minimum);
    try std.testing.expect(areaPolicy(&.{.{ .fraction = 1, .max_kind = .fraction }}, 10).automatic_minimum);
    try std.testing.expect(!areaPolicy(&.{fixed}, 10).automatic_minimum);
}

test "grid auto-fit occupancy preserves spans and coincident interior gutters" {
    var input = [_]Track{.{ .auto_fit = true }} ** 5;
    const occupied = [_]SpanContribution{ .{ .start = 1 }, .{ .start = 3 } };
    collapseEmpty(&input, &occupied);
    try std.testing.expect(input[0].collapsed and input[2].collapsed and input[4].collapsed);
    const sizes = [_]f64{ 0, 40, 0, 60, 0 };
    try std.testing.expectEqual(@as(usize, 2), activeTrackCount(&input));
    try std.testing.expectEqual(@as(f64, 110), totalSize(&input, &sizes, 10));
    var starts: [6]f64 = undefined;
    positions(&input, &sizes, 10, 5, 20, &starts);
    try std.testing.expectEqualSlices(f64, &.{ 5, 5, 75, 75, 135, 135 }, &starts);
    try std.testing.expectEqual(@as(f64, 130), areaSize(&input, &sizes, 1, 3, 30));
    collapseEmpty(&input, &.{.{ .start = 0, .span = 4 }});
    try std.testing.expect(!input[2].collapsed and input[4].collapsed);
    var used: [5]f64 = undefined;
    try resolveSpans(std.testing.allocator, &input, &.{.{ .start = 0, .span = 4, .contribution = .{ .minimum = 100, .min_content = 100, .max_content = 100 } }}, 200, 10, true, &used);
    try std.testing.expectEqual(@as(f64, 0), used[4]);
    try std.testing.expectEqual(@as(f64, 200), totalSize(&input, &used, 10));
}

test "grid spanning contributions retain fixed tracks and subtract only interior gaps" {
    const input = [_]Track{
        .{ .min = 40, .max = 40, .min_kind = .fixed, .max_kind = .fixed },
        .{},
        .{},
    };
    const items = [_]SpanContribution{.{ .start = 0, .span = 3, .contribution = .{ .minimum = 140, .min_content = 140, .max_content = 200 } }};
    var used: [3]f64 = undefined;
    try resolveSpans(std.testing.allocator, &input, &items, 140, 10, false, &used);
    try std.testing.expectEqualSlices(f64, &.{ 40, 40, 40 }, &used);
    try std.testing.expectEqual(@as(f64, 140), try intrinsicSpans(std.testing.allocator, &input, &items, 10, .min_content, &used));
    try std.testing.expectEqual(@as(f64, 200), try intrinsicSpans(std.testing.allocator, &input, &items, 10, .max_content, &used));
    try std.testing.expectEqual(@as(f64, 40), used[0]);
}

test "grid equal-span overlapping contributions are independent of item order" {
    const input = [_]Track{.{}} ** 3;
    const first = SpanContribution{ .start = 0, .span = 2, .contribution = .{ .minimum = 100, .min_content = 100, .max_content = 140 } };
    const second = SpanContribution{ .start = 1, .span = 2, .contribution = .{ .minimum = 160, .min_content = 160, .max_content = 200 } };
    var forward: [3]f64 = undefined;
    var reverse: [3]f64 = undefined;
    try resolveSpans(std.testing.allocator, &input, &.{ first, second }, 0, 0, false, &forward);
    try resolveSpans(std.testing.allocator, &input, &.{ second, first }, 0, 0, false, &reverse);
    try std.testing.expectEqualSlices(f64, &.{ 50, 80, 80 }, &forward);
    try std.testing.expectEqualSlices(f64, &forward, &reverse);
    _ = try intrinsicSpans(std.testing.allocator, &input, &.{ first, second }, 10, .max_content, &forward);
    _ = try intrinsicSpans(std.testing.allocator, &input, &.{ second, first }, 10, .max_content, &reverse);
    try std.testing.expectEqualSlices(f64, &forward, &reverse);
}

test "grid spanning growth freezes prior finite limits before empty tracks" {
    const input = [_]Track{.{}} ** 2;
    const items = [_]SpanContribution{
        .{ .start = 0, .contribution = .{ .minimum = 10, .min_content = 10, .max_content = 10 } },
        .{ .start = 0, .span = 2, .contribution = .{ .minimum = 30, .min_content = 30, .max_content = 100 } },
    };
    var used: [2]f64 = undefined;
    try resolveSpans(std.testing.allocator, &input, &items, null, 0, false, &used);
    try std.testing.expectEqualSlices(f64, &.{ 10, 90 }, &used);
}

test "grid flexible spans preserve automatic explicit and intrinsic minima" {
    var input = [_]Track{
        .{ .fraction = 1, .max_kind = .fraction },
        .{ .min = 30, .max = 30, .min_kind = .fixed, .max_kind = .fixed },
    };
    var items = [_]SpanContribution{.{ .start = 0, .span = 2, .contribution = .{ .min_content = 300, .max_content = 300 } }};
    var used: [2]f64 = undefined;
    try std.testing.expectEqual(@as(f64, 30), try intrinsicSpans(std.testing.allocator, &input, &items, 0, .min_content, &used));
    try std.testing.expectEqual(@as(f64, 300), try intrinsicSpans(std.testing.allocator, &input, &items, 0, .max_content, &used));
    items[0].contribution.minimum = 80;
    try std.testing.expectEqual(@as(f64, 80), try intrinsicSpans(std.testing.allocator, &input, &items, 0, .min_content, &used));
    input[0].min_kind = .min_content;
    try std.testing.expectEqual(@as(f64, 300), try intrinsicSpans(std.testing.allocator, &input, &items, 0, .min_content, &used));
    input[0].min_kind = .fixed;
    try resolveSpans(std.testing.allocator, &input, &items, 60, 0, false, &used);
    try std.testing.expectEqualSlices(f64, &.{ 30, 30 }, &used);
}

test "grid span solver keeps intrinsic single track and fractional factors compatible" {
    const input = [_]Track{
        .{ .min = 100, .max = 100, .min_kind = .fixed, .max_kind = .fixed },
        .{ .min_kind = .fixed, .fraction = 1, .max_kind = .fraction },
        .{ .fraction = 2, .max_kind = .fraction },
    };
    var used: [3]f64 = undefined;
    try resolveSpans(std.testing.allocator, &input, &.{}, 640, 20, true, &used);
    try std.testing.expectApproxEqAbs(@as(f64, 100), used[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 500.0 / 3.0), used[1], 0.001);
    const huge = [_]Track{.{ .min_kind = .fixed, .fraction = 1e308, .max_kind = .fraction }} ** 2;
    try resolveSpans(std.testing.allocator, &huge, &.{}, 100, 0, false, used[0..2]);
    try std.testing.expectEqualSlices(f64, &.{ 50, 50 }, used[0..2]);
    const mixed = [_]Track{ .{ .min_kind = .fixed, .fraction = 1, .max_kind = .fraction }, .{ .min_kind = .fixed, .fraction = 1e12, .max_kind = .fraction } };
    _ = try intrinsicSpans(std.testing.allocator, &mixed, &.{.{ .start = 0, .contribution = .{ .max_content = 100 } }}, 0, .max_content, used[0..2]);
    try std.testing.expectApproxEqAbs(@as(f64, 100), used[0], 0.001);
    try std.testing.expectEqual(sizing.max_intrinsic_extent, used[1]);
}

fn spanAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var output: [2]f64 = undefined;
    try resolveSpans(allocator, &.{ .{}, .{} }, &.{.{ .start = 0, .span = 2, .contribution = .{ .minimum = 80 } }}, 100, 10, false, &output);
}

test "grid span sizing cleans temporary allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, spanAllocationFailureCase, .{});
}
