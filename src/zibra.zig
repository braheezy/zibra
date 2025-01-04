const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const browser = @import("browser.zig");
const Browser = browser.Browser;
const Url = @import("url.zig").Url;
const show = @import("url.zig").show;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const dbg = std.debug.print;

fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

const default_html = @embedFile("default.html");

pub fn main() void {
    // Catch and print errors to prevent ugly stack traces.
    zibra() catch |err| {
        std.log.err("Error: {any}", .{err});
        std.process.exit(1);
    };
}

fn zibra() !void {
    // Memory allocation setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };

    // Read arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Hold values, if provided
    var rtl_flag = false;
    var url: ?Url = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-rtl")) {
            rtl_flag = true;
            continue;
        }
        if (url) |_| {
            std.log.err("Only one URL is supported at a time.", .{});
            return error.BadArguments;
        }
        url = Url.init(allocator, arg) catch |err| blk: {
            if (err == error.InvalidUrl) {
                break :blk try Url.init(allocator, "about:blank");
            } else {
                return err;
            }
        };
    }

    defer if (url) |u| u.free(allocator);

    // Initialize browser
    var b = try Browser.init(allocator);
    defer b.free();
    b.rtl_text = rtl_flag;

    // Load fonts
    try b.font_manager.loadSystemFont(16);

    if (url) |u| {
        // Request URL and store response in browser.
        try b.load(u);
    } else {
        std.log.info("showing default html", .{});
        const parsed_content = try b.lex(default_html, false);
        defer b.allocator.free(parsed_content);
        try b.layout(parsed_content);
    }

    // Start main exec loop
    try b.run();
}
