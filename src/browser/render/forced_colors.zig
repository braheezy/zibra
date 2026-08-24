//! Semantic system-color replacement for accessibility forced-colors mode.
//!
//! Layout supplies the role of each CSS color at paint time. Keeping that
//! distinction is important: quantizing an author's foreground and background
//! independently could map both to the same color and preserve poor contrast.

const std = @import("std");
const Color = @import("display_list.zig").Color;

pub const Role = enum {
    background,
    text,
    link,
    visited_link,
    control_background,
    control_text,
    border,
    accent,
};

/// Zibra's deliberately small, dark high-contrast system palette.
pub const canvas = Color{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff };
pub const text = Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };
pub const link = Color{ .r = 0x00, .g = 0xff, .b = 0xff, .a = 0xff };
pub const accent = Color{ .r = 0xff, .g = 0xff, .b = 0x00, .a = 0xff };

/// Replace a CSS color with the system color for its paint role. Fully
/// transparent paint must remain transparent so it does not acquire geometry;
/// partial author alpha is retained for existing group/transition behavior.
pub fn map(author_color: Color, role: Role, enabled: bool) Color {
    if (!enabled or author_color.a == 0) return author_color;

    var system_color = switch (role) {
        .background, .control_background => canvas,
        .text, .control_text, .border => text,
        .link => link,
        .visited_link, .accent => accent,
    };
    system_color.a = author_color.a;
    return system_color;
}

pub fn isSystemRgb(color: Color) bool {
    inline for (.{ canvas, text, link, accent }) |candidate| {
        if (color.r == candidate.r and color.g == candidate.g and color.b == candidate.b) {
            return true;
        }
    }
    return false;
}

test "forced colors use semantic system roles and retain alpha" {
    const arbitrary = Color{ .r = 0x73, .g = 0x81, .b = 0x92, .a = 0x80 };

    try std.testing.expectEqual(arbitrary, map(arbitrary, .text, false));
    try std.testing.expectEqual(
        Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0x80 },
        map(arbitrary, .text, true),
    );
    try std.testing.expectEqual(
        Color{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x80 },
        map(arbitrary, .background, true),
    );
    try std.testing.expectEqual(
        Color{ .r = 0x00, .g = 0xff, .b = 0xff, .a = 0x80 },
        map(arbitrary, .link, true),
    );
    try std.testing.expectEqual(
        Color{ .r = 0xff, .g = 0xff, .b = 0x00, .a = 0x80 },
        map(arbitrary, .visited_link, true),
    );
}

test "transparent paint remains transparent and every replacement uses the small palette" {
    const transparent = Color{ .r = 12, .g = 34, .b = 56, .a = 0 };
    try std.testing.expectEqual(transparent, map(transparent, .background, true));

    const arbitrary = Color{ .r = 12, .g = 34, .b = 56, .a = 255 };
    inline for (std.meta.tags(Role)) |role| {
        try std.testing.expect(isSystemRgb(map(arbitrary, role, true)));
    }
}
