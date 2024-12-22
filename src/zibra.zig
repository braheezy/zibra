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

const font_name = switch (builtin.target.os.tag) {
    .macos => "Hiragino Sans GB",
    .linux => "NotoSansCJK-VF",
    else => @compileError("Unsupported operating system"),
};

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
    var debug_flag = false;
    var url: ?Url = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            debug_flag = true;
            continue;
        }
        if (url) |_| {
            std.log.err("Only one URL is supported at a time.", .{});
            return error.BadArguments;
        }
        url = try Url.init(allocator, arg);
    }

    defer if (url) |u| u.free(allocator);

    // Initialize browser
    var b = try Browser.init(allocator);
    defer b.free();

    // Load fonts
    try b.font_manager.loadSystemFont(font_name, 16);

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
