const std = @import("std");

const Url = @import("url.zig").Url;
const show = @import("url.zig").show;
const loadAll = @import("url.zig").loadAll;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const dbg = std.debug.print;

fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

const default_html = @embedFile("default.html");

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

    var debug_flag = false;

    var urls = ArrayList(Url).init(allocator);
    defer {
        for (urls.items) |url| {
            url.free(allocator);
        }
        urls.deinit();
    }

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            debug_flag = true;
            continue;
        }
        const url = try Url.init(allocator, arg, debug_flag);
        try urls.append(url);
    }

    if (urls.items.len == 0) {
        try show(default_html, false);
    } else {
        loadAll(allocator, urls, debug_flag) catch |err| {
            dbg("Error: {any}\n", .{err});
            std.process.exit(1);
        };
    }
}
