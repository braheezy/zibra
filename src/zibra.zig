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
const parser = @import("parser.zig");
const HTMLParser = parser.HTMLParser;

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

// Dead code eliminates this if not used.
fn zibra() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    // Memory allocation setup
    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        if (debug_allocator.deinit() == .leak) {
            std.process.exit(1);
        }
    };

    // Read arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Hold values, if provided
    var rtl_flag = false;
    var url: ?Url = null;
    var print_tree = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-rtl")) {
            rtl_flag = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-t")) {
            print_tree = true;
            continue;
        }
        if (url) |_| {
            std.log.err("Only one URL is supported at a time.", .{});
            return error.BadArguments;
        }
        url = Url.init(allocator, arg) catch |err| blk: {
            if (err == error.InvalidUrl) {
                // Attempt to treat the URL as a local file path
                const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
                defer allocator.free(cwd);

                const absolute_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, arg });
                defer allocator.free(absolute_path);

                // Check if the file exists before creating a file URL
                const file_exists = std.fs.cwd().access(arg, .{}) catch |access_err| {
                    std.log.warn("File '{s}' does not exist or is not accessible: {any}", .{ arg, access_err });
                    // Fallback to about:blank if the file doesn't exist
                    break :blk try Url.init(allocator, "about:blank");
                };
                _ = file_exists;

                const file_url = try std.fmt.allocPrint(allocator, "file://{s}", .{absolute_path});
                defer allocator.free(file_url);

                // Try to initialize the URL with the file path
                // This should always succeed since file:// URLs are valid,
                // but we'll handle errors just in case
                break :blk Url.init(allocator, file_url) catch |file_err| {
                    std.log.warn("Failed to create URL from file path: {any}", .{file_err});
                    // Fallback to "about:blank" if there's any issue
                    break :blk try Url.init(allocator, "about:blank");
                };
            } else {
                return err;
            }
        };
    }

    defer if (url) |u| u.free(allocator);

    // Initialize browser
    var b = try Browser.init(allocator, rtl_flag);
    defer b.free();

    if (url) |u| {
        if (print_tree) {
            const body = try b.fetchBody(u);
            // TODO: Refactor so a hidden allocation doesn't happen. This happens
            //       fetching a body may involve an HTTP request, and we provide the browser
            //       socket map and cache and those were allocated by the Browser's allocator.
            defer allocator.free(body);

            var html_parser = try HTMLParser.init(allocator, body);
            defer html_parser.deinit(allocator);

            const root = try html_parser.parse();
            defer root.deinit(allocator);

            try html_parser.prettyPrint(root, 0);
            return;
        }
        // Request URL and store response in browser.
        try b.load(u);
    } else {
        if (print_tree) {
            var html_parser = try HTMLParser.init(allocator, default_html);
            defer html_parser.deinit(allocator);
            const root = try html_parser.parse();
            defer root.deinit(allocator);
            try html_parser.prettyPrint(root, 0);
            return;
        }

        std.log.info("showing default html", .{});

        // Parse default HTML into a node tree instead of tokenizing it
        var html_parser = try HTMLParser.init(allocator, default_html);
        defer html_parser.deinit(allocator);

        // Parse the HTML and store the root node in the browser
        b.current_node = try html_parser.parse();

        // Layout using HTML nodes
        try b.layoutWithNodes();
    }

    // Start main exec loop
    try b.run();
}

test {
    _ = @import("parser_test.zig");
}
