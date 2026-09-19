//! Pointer-free flex main-axis sizing, line collection and box alignment.
//! Layout owns intrinsic measurements, dependency edges and child lifetimes.

const std = @import("std");
const alignment = @import("box_alignment.zig");

pub const Item = struct {
    basis: f64,
    /// Inner flex base used only for scaled shrink factors. Basis and min/max
    /// remain border-box quantities; null supports scalar content-box callers.
    inner_basis: ?f64 = null,
    min: f64 = 0,
    max: f64 = std.math.inf(f64),
    grow: f64 = 0,
    shrink: f64 = 1,
    before: f64 = 0,
    after: f64 = 0,
    auto_before: bool = false,
    auto_after: bool = false,
};

pub const Used = struct { size: f64 = 0, offset: f64 = 0, frozen: bool = false };
pub const Distribution = alignment.Distribution;

pub fn distribute(keyword: []const u8, free_space: f64, count: usize) Distribution {
    return alignment.distribute(keyword, free_space, count, false);
}

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, a, " \t\r\n"), b);
}

pub fn clamp(item: Item, size: f64) f64 {
    return @max(item.min, @min(size, item.max));
}

/// Collect one line using outer hypothetical main sizes, before flexing.
pub fn lineEnd(items: []const Item, available: f64, gap: f64, wrap: bool) usize {
    if (!wrap) return items.len;
    var used: f64 = 0;
    for (items, 0..) |item, i| {
        const outer = clamp(item, item.basis) + item.before + item.after;
        const next = used + outer + if (i > 0) gap else @as(f64, 0);
        if (i > 0 and next > available) return i;
        used = next;
    }
    return items.len;
}

/// Iterative freeze/redistribute: min/max violations must not strand free
/// space or shrink a constrained item below its minimum. Rounding is left to
/// the caller at shared edges, not accumulated independently per item.
pub fn resolve(items: []const Item, available: f64, gap: f64, justify: []const u8, reverse: bool, output: []Used) void {
    std.debug.assert(items.len == output.len);
    if (items.len == 0) return;
    var hypothetical = gap * @as(f64, @floatFromInt(items.len - 1));
    for (items) |item| {
        hypothetical += clamp(item, item.basis) + item.before + item.after;
    }
    const growing = hypothetical < available;
    for (items, output) |item, *used| {
        used.* = .{ .size = item.basis };
        if ((if (growing) item.grow else item.shrink) == 0 or
            (growing and item.basis > clamp(item, item.basis)) or
            (!growing and item.basis < clamp(item, item.basis)))
        {
            used.size = clamp(item, item.basis);
            used.frozen = true;
        }
    }
    var initial_free = available - gap * @as(f64, @floatFromInt(items.len - 1));
    for (items, output) |item, used| initial_free -=
        item.before + item.after + if (used.frozen) used.size else item.basis;
    for (0..items.len + 1) |_| {
        var free = available - gap * @as(f64, @floatFromInt(items.len - 1));
        var weight: f64 = 0;
        var factors: f64 = 0;
        var largest_factor: f64 = 0;
        var largest_basis: f64 = 0;
        for (items, output) |item, used| {
            free -= item.before + item.after + if (used.frozen) used.size else item.basis;
            if (!used.frozen) {
                const factor = if (growing) item.grow else item.shrink;
                factors = @min(factors + factor, 1);
                largest_factor = @max(largest_factor, factor);
                largest_basis = @max(largest_basis, @max(item.inner_basis orelse item.basis, 0));
            }
        }
        // Normalize before multiplying: finite authored shrink factors can be
        // enormous, and multiplying by the inner base must not create inf/NaN
        // geometry when the mathematically correct ratio is perfectly finite.
        for (items, output) |item, used| if (!used.frozen) {
            weight += normalizedWeight(item, growing, largest_factor, largest_basis);
        };
        if (factors < 1 and @abs(initial_free * factors) < @abs(free)) free = initial_free * factors;
        var violation: f64 = 0;
        for (items, output) |item, *used| {
            if (used.frozen) continue;
            const factor = normalizedWeight(item, growing, largest_factor, largest_basis);
            const target = item.basis + if (weight > 0) free * (factor / weight) else @as(f64, 0);
            used.size = clamp(item, target);
            used.offset = used.size - target; // transient min/max violation
            violation += used.offset;
        }
        for (output) |*used| {
            if (@abs(violation) < 0.000001 or
                (violation > 0 and used.offset > 0) or
                (violation < 0 and used.offset < 0)) used.frozen = true;
        }
        var done = true;
        for (output) |used| done = done and used.frozen;
        if (done) break;
    }
    var free = available - gap * @as(f64, @floatFromInt(items.len - 1));
    var auto_count: usize = 0;
    for (items, output) |item, used| {
        free -= used.size + item.before + item.after;
        auto_count += @intFromBool(item.auto_before);
        auto_count += @intFromBool(item.auto_after);
    }
    const auto = if (auto_count > 0) @max(free, 0) / @as(f64, @floatFromInt(auto_count)) else 0;
    const distribution = alignment.distribute(justify, if (auto_count > 0 and free > 0) 0 else free, items.len, reverse);
    var cursor = distribution.offset;
    for (items, output) |item, *used| {
        cursor += item.before + if (item.auto_before) auto else @as(f64, 0);
        used.offset = if (reverse) available - cursor - used.size else cursor;
        cursor += used.size + item.after + gap + distribution.between + if (item.auto_after) auto else @as(f64, 0);
    }
}

fn normalizedWeight(item: Item, growing: bool, largest_factor: f64, largest_basis: f64) f64 {
    if (largest_factor == 0) return 0;
    if (growing) return item.grow / largest_factor;
    if (largest_basis == 0) return 0;
    return (item.shrink / largest_factor) * (@max(item.inner_basis orelse item.basis, 0) / largest_basis);
}

test "flex distributes free space after freezing max and min violations" {
    var output: [3]Used = undefined;
    resolve(&.{ .{ .basis = 100, .grow = 1, .max = 120 }, .{ .basis = 100, .grow = 1 }, .{ .basis = 100, .grow = 2 } }, 600, 10, "start", false, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 120), output[0].size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 460), output[1].size + output[2].size, 0.001);
    resolve(&.{ .{ .basis = 200, .min = 190 }, .{ .basis = 200 }, .{ .basis = 100 } }, 300, 0, "start", false, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 190), output[0].size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 110), output[1].size + output[2].size, 0.001);
}

test "flex wraps outer sizes and handles auto margins reverse and fractional grow" {
    const items = [_]Item{ .{ .basis = 100 }, .{ .basis = 100, .auto_before = true } };
    try std.testing.expectEqual(@as(usize, 1), lineEnd(&items, 205, 10, true));
    var output: [2]Used = undefined;
    resolve(&items, 400, 10, "start", true, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 300), output[0].offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), output[1].offset, 0.001);
    resolve(&.{ .{ .basis = 0, .grow = 0.25 }, .{ .basis = 0, .grow = 0.25 } }, 400, 0, "start", false, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 100), output[0].size, 0.001);
}

test "flex shrink weights exclude unequal padding and frozen items use initial free space" {
    var output: [2]Used = undefined;
    resolve(&.{ .{ .basis = 120, .inner_basis = 100, .min = 20 }, .{ .basis = 160, .inner_basis = 100, .min = 60 } }, 200, 0, "start", false, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 80), output[0].size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 120), output[1].size, 0.001);
    resolve(&.{ .{ .basis = 200, .max = 100, .grow = 1 }, .{ .basis = 100, .grow = 0.5 } }, 400, 0, "start", false, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 100), output[0].size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 200), output[1].size, 0.001);
}

test "flex overflowing auto margins preserve justify alignment and reversed logical start" {
    var output: [2]Used = undefined;
    const items = [_]Item{ .{ .basis = 100, .shrink = 0, .auto_before = true }, .{ .basis = 100, .shrink = 0 } };
    resolve(&items, 100, 0, "center", false, &output);
    try std.testing.expectApproxEqAbs(@as(f64, -50), output[0].offset, 0.001);
    resolve(&.{ .{ .basis = 20, .shrink = 0 }, .{ .basis = 20, .shrink = 0 } }, 100, 0, "start", true, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 20), output[0].offset, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), output[1].offset, 0.001);
}

test "flex large finite shrink factors keep ratios and geometry finite" {
    var output: [2]Used = undefined;
    resolve(&.{ .{ .basis = 200, .shrink = 1e308 }, .{ .basis = 100, .shrink = 1e308 } }, 150, 0, "start", false, &output);
    try std.testing.expectApproxEqAbs(@as(f64, 100), output[0].size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50), output[1].size, 0.001);
    try std.testing.expect(std.math.isFinite(output[1].offset));
}
