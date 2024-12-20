const std = @import("std");

const debug = @import("config").debug;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const browser = @import("browser.zig");
const Browser = browser.Browser;
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

pub fn main() void {
    // Memory allocation setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };

    const b = Browser.init(allocator) catch |err| {
        dbg("Error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer b.free();

    // Read arguments
    const args = std.process.argsAlloc(allocator) catch |err| {
        dbg("Error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer std.process.argsFree(allocator, args);

    var debug_flag = false;

    // var urls = ArrayList(Url).init(allocator);
    // defer {
    //     for (urls.items) |url| {
    //         url.free(allocator);
    //     }
    //     urls.deinit();
    // }
    var url: ?Url = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            debug_flag = true;
            continue;
        }
        if (url) |_| {
            std.log.err("Only one URL is supported at a time.", .{});
            std.process.exit(1);
        }
        url = Url.init(allocator, arg) catch |err| {
            dbg("Error: {any}\n", .{err});
            std.process.exit(1);
        };
    }

    defer if (url) |u| u.free(allocator);

    if (url) |u| {
        b.load(u) catch |err| {
            dbg("Error: {any}\n", .{err});
            std.process.exit(1);
        };
    } else {
        dbgln("showing default html");
        const parsed_content = b.lex(default_html, false) catch |err| {
            dbg("Error: {any}\n", .{err});
            std.process.exit(1);
        };
        defer b.allocator.free(parsed_content);
        b.layout(allocator, parsed_content) catch |err| {
            dbg("Error: {any}\n", .{err});
            std.process.exit(1);
        };
    }
    b.run() catch |err| {
        dbg("Error: {any}\n", .{err});
        std.process.exit(1);
    };
}
