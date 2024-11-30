const std = @import("std");

const Url = @import("url.zig").Url;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const dbg = std.debug.print;
fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

pub fn main() !void {
    // Memory allocation setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };

    // Read arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        // not enough args, exit
        std.log.err("Missing input url\n", .{});
        std.process.exit(64);
    }

    var debug_flag = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            debug_flag = true;
            continue;
        }
        const url = try Url.init(allocator, arg, debug_flag);
        defer url.free(allocator);

        try url.load(allocator, debug_flag);
    }
}
