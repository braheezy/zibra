//! Borrowed display classification shared by declaration admission and layout.
//! Inner flex/grid formatting is independent from outer atomic participation.
const std = @import("std");

pub const FormattingKind = enum { flex, grid };

fn eq(raw: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\r\n\x0c"), expected);
}

/// Inner formatting kind, including containers participating in an inline line.
pub fn formattingKind(raw: []const u8) ?FormattingKind {
    if (eq(raw, "flex") or eq(raw, "inline-flex")) return .flex;
    if (eq(raw, "grid") or eq(raw, "inline-grid")) return .grid;
    return null;
}

/// Atomic inline boxes own their descendants instead of flattening their runs.
pub fn isAtomicInline(raw: []const u8) bool {
    return eq(raw, "inline-block") or eq(raw, "inline-flex") or eq(raw, "inline-grid");
}

/// Ordinary block-level display vocabulary; table roles have a separate owner.
pub fn isBlock(raw: []const u8) bool {
    return eq(raw, "block") or eq(raw, "flex") or eq(raw, "grid") or eq(raw, "list-item");
}

/// Admit the implemented single-keyword vocabulary. The declaration owner
/// handles CSS-wide values; multi-keyword display syntax remains unsupported.
pub fn valid(raw: []const u8) bool {
    if (isBlock(raw) or isAtomicInline(raw)) return true;
    for ([_][]const u8{ "none", "inline", "table", "table-row-group", "table-header-group", "table-footer-group", "table-row", "table-cell" }) |name| {
        if (eq(raw, name)) return true;
    }
    return false;
}

test "display separates inner formatting from outer atomic and block participation" {
    try std.testing.expectEqual(@as(?FormattingKind, .flex), formattingKind(" INLINE-FLEX "));
    try std.testing.expectEqual(@as(?FormattingKind, .grid), formattingKind("inline-grid"));
    for ([_][]const u8{ "inline-block", "inline-flex", "inline-grid" }) |name| {
        try std.testing.expect(valid(name));
        try std.testing.expect(isAtomicInline(name));
        try std.testing.expect(!isBlock(name));
    }
    for ([_][]const u8{ "block", "flex", "grid", "list-item" }) |name| {
        try std.testing.expect(valid(name));
        try std.testing.expect(isBlock(name));
        try std.testing.expect(!isAtomicInline(name));
    }
    for ([_][]const u8{ "none", "inline", "table", "table-row-group", "table-header-group", "table-footer-group", "table-row", "table-cell" }) |name| {
        try std.testing.expect(valid(name));
        try std.testing.expect(formattingKind(name) == null);
        try std.testing.expect(!isAtomicInline(name));
    }
    for ([_][]const u8{ "inline flex", "block grid", "inline-table", "contents", "flow-root", "flex grid", "" }) |name| try std.testing.expect(!valid(name));
}
