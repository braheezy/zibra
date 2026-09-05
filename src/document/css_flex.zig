//! Source-borrowing flex shorthand grammar and scalar factor validation.
const std = @import("std");
const length = @import("length.zig");
const Components = @import("grid_tracks.zig").Components;

pub const Flex = struct { grow: []const u8 = "1", shrink: []const u8 = "1", basis: []const u8 = "0%" };
pub fn factor(input: []const u8) ?f64 {
    const n = std.fmt.parseFloat(f64, std.mem.trim(u8, input, " \t\r\n")) catch return null;
    return if (std.math.isFinite(n) and n >= 0) n else null;
}
pub fn basis(input: []const u8) bool {
    return std.ascii.eqlIgnoreCase(input, "auto") or std.ascii.eqlIgnoreCase(input, "content") or length.parse(input) != null;
}
pub fn parse(input: []const u8) ?Flex {
    if (std.ascii.eqlIgnoreCase(input, "none")) return .{ .grow = "0", .shrink = "0", .basis = "auto" };
    if (std.ascii.eqlIgnoreCase(input, "auto")) return .{ .basis = "auto" };
    var iterator = Components{ .input = input };
    var result: Flex = .{};
    var numbers: usize = 0;
    var saw_basis = false;
    while (iterator.next()) |part| {
        if (factor(part) != null and numbers < 2) {
            if (numbers == 0) result.grow = part else result.shrink = part;
            numbers += 1;
        } else if (!saw_basis and basis(part)) {
            result.basis = part;
            saw_basis = true;
        } else return null;
    }
    return if (numbers > 0 or saw_basis) result else null;
}
