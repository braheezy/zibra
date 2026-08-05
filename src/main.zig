//! Zibra executable entry point and command-line interface.
//!
//! The process arena owns application allocations. This module parses the
//! command line, creates the process-wide `Browser`, and tears it down after
//! the interactive or screenshot run completes.

const std = @import("std");

const browser = @import("browser/root.zig");
const Browser = browser.Browser;
const Url = @import("network/url.zig").Url;
const parser = @import("document/parser.zig");
const HTMLParser = parser.HTMLParser;

const default_html = @embedFile("assets/default.html");

pub fn main(init: std.process.Init) !void {
    // Catch and print errors to prevent ugly stack traces.
    zibra(init) catch |err| {
        std.log.err("Error: {any}", .{err});
        std.process.exit(1);
    };
}

fn zibra(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    // Read arguments
    const args = try init.minimal.args.toSlice(allocator);

    // Hold values, if provided
    var rtl_flag = false;
    var url: ?Url = null;
    var print_tree = false;
    var screenshot_path: ?[]const u8 = null;

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "-rtl")) {
            rtl_flag = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-t")) {
            print_tree = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--screenshot")) {
            if (screenshot_path != null or arg_index + 1 >= args.len) {
                std.log.err("--screenshot requires exactly one output path.", .{});
                return error.BadArguments;
            }
            arg_index += 1;
            screenshot_path = args[arg_index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--screenshot=")) {
            if (screenshot_path != null or arg.len == "--screenshot=".len) {
                std.log.err("--screenshot requires exactly one output path.", .{});
                return error.BadArguments;
            }
            screenshot_path = arg["--screenshot=".len..];
            continue;
        }
        if (url) |_| {
            std.log.err("Only one URL is supported at a time.", .{});
            return error.BadArguments;
        }
        url = Url.init(allocator, arg) catch |err| blk: {
            if (err == error.InvalidUrl) {
                // Attempt to treat the URL as a local file path
                const cwd = try std.process.currentPathAlloc(init.io, allocator);
                defer allocator.free(cwd);

                const absolute_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, arg });
                defer allocator.free(absolute_path);

                // Check if the file exists before creating a file URL
                std.Io.Dir.cwd().access(init.io, arg, .{}) catch |access_err| {
                    std.log.warn("File '{s}' does not exist or is not accessible: {any}", .{ arg, access_err });
                    // Fallback to about:blank if the file doesn't exist
                    break :blk try Url.init(allocator, "about:blank");
                };

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

    if (print_tree and screenshot_path != null) {
        std.log.err("-t and --screenshot cannot be used together.", .{});
        return error.BadArguments;
    }
    // Initialize browser
    const b = try Browser.init(allocator, init.io, init.environ_map, rtl_flag, screenshot_path != null);
    defer {
        b.deinit();
        allocator.destroy(b);
    }

    if (url) |u| {
        if (print_tree) {
            const response = try b.fetchBody(u, null, null);
            defer if (response.csp_header) |hdr| allocator.free(hdr);
            const raw_body = response.body;
            const body_owned = !std.mem.eql(u8, u.scheme, "data") and !std.mem.eql(u8, u.scheme, "about");
            defer if (body_owned) allocator.free(raw_body);
            const body = try browser.decodeUtf8Replace(allocator, raw_body);
            defer allocator.free(body);

            var html_parser = try HTMLParser.init(allocator, body);
            defer html_parser.deinit(allocator);

            var root = try html_parser.parse();
            defer root.deinit(allocator);

            try html_parser.prettyPrint(root, 0);
            return;
        }
        // Create a new tab and load the URL
        try b.newTab(u);
        url = null;
    } else {
        if (print_tree) {
            var html_parser = try HTMLParser.init(allocator, default_html);
            defer html_parser.deinit(allocator);
            var root = try html_parser.parse();
            defer root.deinit(allocator);
            try html_parser.prettyPrint(root, 0);
            return;
        }

        // Create a new tab with the default HTML
        const about_url = try Url.init(allocator, "about:blank");
        try b.newTab(about_url);
    }

    // Start main exec loop
    if (screenshot_path) |path| {
        try b.runToScreenshot(path);
    } else {
        try b.run();
    }
}
