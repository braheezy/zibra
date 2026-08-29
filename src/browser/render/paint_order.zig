//! Pointer-free CSS-like paint-phase ordering for layout participants.
//!
//! A layout owner supplies one `DirectChild` for each committed direct child
//! or synchronously collected descendant, then retains the resulting
//! permutation beside its paint cache. This module neither observes
//! layout/DOM pointers nor owns the permutation. It deliberately models only
//! the bounded phases needed by the simplified stacking context: negative
//! positioned descendants, static block
//! backgrounds, floats, static inline content, positioned auto/zero, and
//! positive positioned descendants.

const std = @import("std");

/// A computed `z-index` before layout has attached it to a paint phase.
/// `auto` and numeric zero share the positioned auto/zero phase.
pub const ZIndex = union(enum) {
    auto,
    value: i32,
};

/// The normal-flow contribution represented by a direct paint entry.
///
/// A static block entry represents its background/border contribution. Its
/// inline descendants are represented separately as `.inline_content` by the
/// layout owner, allowing a float to paint between the two phases.
pub const NormalFlow = enum {
    block_background,
    float,
    inline_content,
};

/// Pointer-free paint-participant metadata collected by the layout owner.
///
/// `document_index` is the stable source-order position used for CSS ties;
/// it is intentionally separate from the input slice index because a caller
/// may build entries from a filtered or temporary child sequence. `positioned`
/// means that the computed `position` value is non-static. Positioning takes
/// precedence over the normal-flow category, as required by the simplified
/// stacking model.
pub const DirectChild = struct {
    document_index: usize,
    normal_flow: NormalFlow = .block_background,
    positioned: bool = false,
    z_index: ZIndex = .auto,
};

/// CSS-like paint phases, in forward paint order.
pub const Phase = enum(u3) {
    negative_positioned,
    block_background,
    float,
    inline_content,
    positioned_auto_or_zero,
    positive_positioned,
};

/// Classify a child into the phase in which its direct contribution paints.
/// A static child's `z-index` has no effect.
pub fn phaseFor(child: DirectChild) Phase {
    if (child.positioned) {
        return switch (child.z_index) {
            .auto => .positioned_auto_or_zero,
            .value => |value| if (value < 0)
                .negative_positioned
            else if (value > 0)
                .positive_positioned
            else
                .positioned_auto_or_zero,
        };
    }
    return switch (child.normal_flow) {
        .block_background => .block_background,
        .float => .float,
        .inline_content => .inline_content,
    };
}

/// Return the last phase in which a direct child can contribute an
/// interactable part of its subtree.
///
/// A split static block paints its background in `.block_background`, but its
/// text, controls, and descendants paint with inline content. Structural hit
/// testing has one entry per child rather than one per display command, so it
/// uses this latter phase. Exact painted-command hit testing still resolves a
/// click on a background covered by a float in display-list order.
pub fn hitPhaseFor(child: DirectChild) Phase {
    const phase = phaseFor(child);
    return if (phase == .block_background) .inline_content else phase;
}

/// Return the numeric z-index used to order entries within a signed positioned
/// phase. Callers may use this only after `phaseFor` returns a negative or
/// positive positioned phase.
pub fn signedZIndex(child: DirectChild) i32 {
    return switch (child.z_index) {
        .auto => 0,
        .value => |value| value,
    };
}

/// Return whether the entry at `left_index` paints before `right_index`.
///
/// Equal CSS stacking keys break by `document_index`, then by input index.
/// The latter keeps ordering deterministic even if a caller accidentally
/// supplies duplicate source positions, without relying on an unstable sort.
pub fn before(entries: []const DirectChild, left_index: usize, right_index: usize) bool {
    return beforeWithPhase(entries, left_index, right_index, phaseFor);
}

/// Return whether `left_index` is below `right_index` for structural hit
/// traversal. See `hitPhaseFor` for why static block backgrounds map to the
/// inline-content phase here.
pub fn beforeForHit(entries: []const DirectChild, left_index: usize, right_index: usize) bool {
    return beforeWithPhase(entries, left_index, right_index, hitPhaseFor);
}

fn beforeWithPhase(
    entries: []const DirectChild,
    left_index: usize,
    right_index: usize,
    comptime phase_fn: fn (DirectChild) Phase,
) bool {
    std.debug.assert(left_index < entries.len);
    std.debug.assert(right_index < entries.len);

    const left = entries[left_index];
    const right = entries[right_index];
    const left_phase = phase_fn(left);
    const right_phase = phase_fn(right);
    if (left_phase != right_phase) {
        return @intFromEnum(left_phase) < @intFromEnum(right_phase);
    }

    switch (left_phase) {
        .negative_positioned, .positive_positioned => {
            const left_z_index = signedZIndex(left);
            const right_z_index = signedZIndex(right);
            if (left_z_index != right_z_index) return left_z_index < right_z_index;
        },
        .block_background, .float, .inline_content, .positioned_auto_or_zero => {},
    }

    if (left.document_index != right.document_index) {
        return left.document_index < right.document_index;
    }
    return left_index < right_index;
}

/// Fill a caller-owned permutation with entry indices in forward paint order.
/// `permutation` must be exactly as long as `entries`; no allocation or
/// pointer retention occurs.
pub fn fillPermutation(entries: []const DirectChild, permutation: []usize) void {
    fillPermutationWithPhase(entries, permutation, before);
}

/// Fill a caller-owned direct-child permutation for structural hit testing.
/// This remains allocation-free and borrows no layout state.
pub fn fillHitPermutation(entries: []const DirectChild, permutation: []usize) void {
    fillPermutationWithPhase(entries, permutation, beforeForHit);
}

fn fillPermutationWithPhase(
    entries: []const DirectChild,
    permutation: []usize,
    comptime less_than: fn ([]const DirectChild, usize, usize) bool,
) void {
    std.debug.assert(permutation.len == entries.len);
    for (permutation, 0..) |*entry_index, index| entry_index.* = index;
    std.mem.sort(usize, permutation, entries, struct {
        fn lessThan(context: []const DirectChild, left: usize, right: usize) bool {
            return less_than(context, left, right);
        }
    }.lessThan);
}

test "direct children classify into every paint phase" {
    try std.testing.expectEqual(Phase.negative_positioned, phaseFor(.{
        .document_index = 0,
        .positioned = true,
        .z_index = .{ .value = -1 },
    }));
    try std.testing.expectEqual(Phase.block_background, phaseFor(.{
        .document_index = 0,
        // Static z-index values do not establish a stacking phase.
        .z_index = .{ .value = 99 },
    }));
    try std.testing.expectEqual(Phase.float, phaseFor(.{
        .document_index = 0,
        .normal_flow = .float,
    }));
    try std.testing.expectEqual(Phase.inline_content, phaseFor(.{
        .document_index = 0,
        .normal_flow = .inline_content,
    }));
    try std.testing.expectEqual(Phase.positioned_auto_or_zero, phaseFor(.{
        .document_index = 0,
        .positioned = true,
    }));
    try std.testing.expectEqual(Phase.positioned_auto_or_zero, phaseFor(.{
        .document_index = 0,
        .positioned = true,
        .z_index = .{ .value = 0 },
    }));
    try std.testing.expectEqual(Phase.positive_positioned, phaseFor(.{
        .document_index = 0,
        .positioned = true,
        .z_index = .{ .value = 1 },
    }));
}

test "paint permutation orders phases signed z indices and DOM ties" {
    const entries = [_]DirectChild{
        .{ .document_index = 9, .positioned = true, .z_index = .{ .value = 5 } },
        .{ .document_index = 5, .normal_flow = .inline_content },
        // Its negative z-index is ignored because it is static.
        .{ .document_index = 3, .z_index = .{ .value = -100 } },
        .{ .document_index = 8, .positioned = true, .z_index = .{ .value = -1 } },
        .{ .document_index = 4, .normal_flow = .float },
        .{ .document_index = 2, .positioned = true, .z_index = .{ .value = -7 } },
        .{ .document_index = 7, .positioned = true },
        .{ .document_index = 1, .positioned = true, .z_index = .{ .value = 0 } },
        .{ .document_index = 6 },
        .{ .document_index = 0, .positioned = true, .z_index = .{ .value = 1 } },
    };
    var permutation: [entries.len]usize = undefined;
    fillPermutation(&entries, &permutation);

    const expected_document_order = [_]usize{ 2, 8, 3, 6, 4, 5, 1, 7, 0, 9 };
    for (permutation, expected_document_order) |entry_index, document_index| {
        try std.testing.expectEqual(document_index, entries[entry_index].document_index);
    }
}

test "equal DOM ties remain deterministic" {
    const entries = [_]DirectChild{
        .{ .document_index = 4, .positioned = true },
        .{ .document_index = 4, .positioned = true, .z_index = .{ .value = 0 } },
        .{ .document_index = 4, .positioned = true },
    };
    var permutation: [entries.len]usize = undefined;
    fillPermutation(&entries, &permutation);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &permutation);
}

test "structural hit order follows static block content after floats" {
    const entries = [_]DirectChild{
        .{ .document_index = 0 },
        .{ .document_index = 1, .normal_flow = .float },
        .{ .document_index = 2, .normal_flow = .inline_content },
    };
    var paint_permutation: [entries.len]usize = undefined;
    var hit_permutation: [entries.len]usize = undefined;
    fillPermutation(&entries, &paint_permutation);
    fillHitPermutation(&entries, &hit_permutation);

    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &paint_permutation);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, &hit_permutation);
}
