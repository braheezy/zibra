//! Zibra executable entry point and command-line interface.
//!
//! The process arena owns application allocations. This module parses the
//! command line, runs isolated document-inspection modes, or creates the
//! process-wide `Browser` for interactive or windowless screenshot runs.

const std = @import("std");

const browser = @import("browser/root.zig");
const Browser = browser.Browser;
const url_module = @import("network/url.zig");
const Url = url_module.Url;
const parser = @import("document/parser.zig");
const HTMLParser = parser.HTMLParser;
const inspection = @import("document/inspection.zig");
const Layout = @import("browser/render/layout.zig").Layout;
const DisplayItem = browser.DisplayItem;
const sdl2 = @import("sdl");

const default_html = @embedFile("assets/default.html");

pub fn main(init: std.process.Init) !void {
    // Catch and print errors to prevent ugly stack traces.
    zibra(init) catch |err| {
        std.log.err("Error: {any}", .{err});
        std.process.exit(1);
    };
}

fn deinitCookieJar(allocator: std.mem.Allocator, cookie_jar: *std.StringHashMap(url_module.CookieEntry)) void {
    var it = cookie_jar.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.value);
        allocator.free(entry.key_ptr.*);
    }
    cookie_jar.deinit();
}

fn fetchDecodedDocument(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: Url,
) ![]u8 {
    var http_client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer http_client.deinit();

    var cookie_jar = std.StringHashMap(url_module.CookieEntry).init(allocator);
    defer deinitCookieJar(allocator, &cookie_jar);

    const response = try Url.fetchBody(
        allocator,
        init.io,
        &http_client,
        &cookie_jar,
        null,
        url,
        null,
        null,
    );
    defer if (response.csp_header) |header| allocator.free(header);

    const raw_body = response.body;
    const body_owned = !std.mem.eql(u8, url.scheme, "data") and !std.mem.eql(u8, url.scheme, "about");
    defer if (body_owned) allocator.free(raw_body);
    return url_module.decodeUtf8Replace(allocator, raw_body);
}

/// Parse and print a DOM without constructing Browser, SDL, layout, or JS.
fn dumpDom(init: std.process.Init, allocator: std.mem.Allocator, url: ?Url) !void {
    const body = if (url) |source_url|
        try fetchDecodedDocument(init, allocator, source_url)
    else
        try allocator.dupe(u8, default_html);
    defer allocator.free(body);

    var html_parser = try HTMLParser.init(allocator, body);
    defer html_parser.deinit(allocator);

    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try html_parser.writePretty(stdout, root, 0);
    try stdout.flush();
}

const DumpMode = enum { dom, style, layout, display_list };

fn dumpPipeline(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: ?Url,
    mode: DumpMode,
    rtl_text: bool,
) !void {
    var page = try inspection.Page.load(init, allocator, url);
    defer page.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (mode == .style) {
        try parser.writeStyledPretty(allocator, stdout, page.root, 0);
        try stdout.flush();
        return;
    }

    // SDL_ttf needs SDL's video subsystem for glyph surfaces on macOS, but the
    // inspection path deliberately creates neither a window nor a renderer.
    try sdl2.init(.{ .video = true });
    defer sdl2.quit();
    const layout = try Layout.init(allocator, init.io, init.environ_map, 800, 600, rtl_text);
    defer layout.deinit();
    layout.collect_hit_test_bounds = false;
    const document = try layout.buildDocument(&page.root);
    defer {
        document.deinit();
        allocator.destroy(document);
    }

    if (mode == .layout) {
        try document.writeDebug(stdout);
        try stdout.flush();
        return;
    }

    const display_list = try layout.paintDocument(document);
    defer DisplayItem.freeList(allocator, display_list);
    try Layout.writeDisplayListDebug(stdout, display_list);
    try stdout.flush();
}

fn zibra(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    // Read arguments
    const args = try init.minimal.args.toSlice(allocator);

    // Hold values, if provided
    var rtl_flag = false;
    var url: ?Url = null;
    var dump_mode: ?DumpMode = null;
    var screenshot_path: ?[]const u8 = null;

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "-rtl")) {
            rtl_flag = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--dump-dom")) {
            dump_mode = .dom;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-style")) {
            dump_mode = .style;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-layout")) {
            dump_mode = .layout;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-display-list")) {
            dump_mode = .display_list;
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
        if (Url.hasExplicitScheme(arg)) {
            url = try Url.initForNavigation(allocator, arg);
            continue;
        }

        url = Url.init(allocator, arg) catch |err| blk: {
            if (err == error.OutOfMemory) return err;

            // Preserve the CLI convenience of accepting an ordinary path.
            const absolute_path = if (std.Io.Dir.path.isAbsolute(arg))
                try allocator.dupe(u8, arg)
            else absolute_path: {
                const cwd = try std.process.currentPathAlloc(init.io, allocator);
                defer allocator.free(cwd);
                break :absolute_path try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, arg });
            };
            defer allocator.free(absolute_path);

            std.Io.Dir.cwd().access(init.io, arg, .{}) catch |access_err| {
                std.log.warn("File '{s}' does not exist or is not accessible: {any}", .{ arg, access_err });
                break :blk try Url.blank(allocator);
            };

            const file_url = try std.fmt.allocPrint(allocator, "file://{s}", .{absolute_path});
            defer allocator.free(file_url);

            break :blk Url.init(allocator, file_url) catch |file_err| {
                if (file_err == error.OutOfMemory) return file_err;
                std.log.warn("Failed to create URL from file path: {any}", .{file_err});
                break :blk try Url.blank(allocator);
            };
        };
    }

    defer if (url) |u| u.free(allocator);

    if (dump_mode != null and screenshot_path != null) {
        std.log.err("Dump commands and --screenshot cannot be used together.", .{});
        return error.BadArguments;
    }

    if (dump_mode) |mode| {
        if (mode == .dom) {
            try dumpDom(init, allocator, url);
        } else {
            try dumpPipeline(init, allocator, url, mode, rtl_flag);
        }
        return;
    }

    // Initialize browser
    const b = try Browser.init(allocator, init.io, init.environ_map, rtl_flag, screenshot_path != null);
    defer {
        b.deinit();
        allocator.destroy(b);
    }

    if (url) |u| {
        // Create a new tab and load the URL
        try b.newTab(u);
        url = null;
    } else {
        // Create a new tab with the default HTML
        const about_url = try Url.blank(allocator);
        try b.newTab(about_url);
    }

    // Start main exec loop
    if (screenshot_path) |path| {
        try b.runToScreenshot(path);
    } else {
        try b.run();
    }
}
