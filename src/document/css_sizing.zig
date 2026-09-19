//! Borrowed preferred/minimum/maximum size grammar shared by CSS and layout.
//! Parsed lengths borrow the declaration; this module owns no style or DOM data.
const std = @import("std");
const length = @import("length.zig");

pub const Value = union(enum) {
    auto,
    none,
    min_content,
    max_content,
    fit_content,
    length: []const u8,
};

/// Parse the supported size grammar without resolving a layout percentage.
/// The length payload remains a synchronous borrow of `raw`.
pub fn parse(raw: []const u8) ?Value {
    const text = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(text, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(text, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(text, "min-content")) return .min_content;
    if (std.ascii.eqlIgnoreCase(text, "max-content")) return .max_content;
    if (std.ascii.eqlIgnoreCase(text, "fit-content")) return .fit_content;
    if (length.parse(text) != null or (length.isMath(text) and length.resolveMath(text, .{ .percentage_base = 100 }) != null)) return .{ .length = text };
    return null;
}

/// Intrinsic keywords currently have used-value support in the inline axis.
/// Flex basis selects that axis at layout time; `content` belongs to css_flex.
pub fn validForProperty(property: []const u8, raw: []const u8) bool {
    const value = parse(raw) orelse return false;
    const maximum = std.mem.startsWith(u8, property, "max-");
    const horizontal = std.mem.endsWith(u8, property, "width") or std.mem.eql(u8, property, "flex-basis");
    return switch (value) {
        .auto => !maximum,
        .none => maximum,
        .min_content, .max_content, .fit_content => horizontal,
        .length => true,
    };
}

test "size grammar preserves intrinsic keywords and unresolved length calculations" {
    try std.testing.expect(parse(" MiN-CoNtEnT ").? == .min_content);
    try std.testing.expectEqualStrings("calc(100% - 2em)", parse("calc(100% - 2em)").?.length);
    try std.testing.expect(validForProperty("max-width", "fit-content"));
    try std.testing.expect(validForProperty("min-width", "auto"));
    try std.testing.expect(!validForProperty("height", "min-content"));
    try std.testing.expect(!validForProperty("max-width", "auto"));
    try std.testing.expect(!validForProperty("width", "none"));
    try std.testing.expect(parse("fit-content(10px)") == null);
    try std.testing.expect(parse("-1px") == null);
    try std.testing.expect(parse("calc(10px + 1)") == null);
}
