//! Exact text comparator for the isolated DOM-dump fixture.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.BadArguments;

    const expected = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(1024 * 1024),
    );
    const actual = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[2],
        allocator,
        .limited(1024 * 1024),
    );

    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("DOM dump differs:\nexpected:\n{s}actual:\n{s}", .{ expected, actual });
        return error.DomDumpMismatch;
    }
}
