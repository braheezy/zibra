//! Zibra executable entry point and command-line interface.
//!
//! The process arena owns application allocations. This module parses the
//! command line, runs isolated document-inspection modes, creates a
//! process-wide `BrowserApp` for interactive windows, or owns one standalone
//! windowless `Browser` for screenshots or one explicit-result WPT session.

const std = @import("std");

const browser = @import("browser/root.zig");
const Browser = browser.Browser;
const BrowserApp = @import("browser/app.zig").BrowserApp;
const wpt_session = @import("browser/wpt_session.zig");
const url_module = @import("network/url.zig");
const Url = url_module.Url;
const parser = @import("document/parser.zig");
const HTMLParser = parser.HTMLParser;
const inspection = @import("document/inspection.zig");
const Layout = @import("browser/render/layout.zig").Layout;
const DisplayItem = browser.DisplayItem;
const sdl2 = @import("sdl");

const default_html = @embedFile("assets/default.html");
const default_wpt_timeout_ms: u64 = 10_000;
const ParsedJsonValue = std.json.Parsed(std.json.Value);

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

fn parseWptUrl(allocator: std.mem.Allocator, input: []const u8) !Url {
    if (!Url.hasExplicitScheme(input)) return error.WptUrlMustBeAbsolute;
    const parsed = try Url.init(allocator, input);
    errdefer parsed.free(allocator);
    if (!std.mem.eql(u8, parsed.scheme, "http") and
        !std.mem.eql(u8, parsed.scheme, "https") and
        !std.mem.eql(u8, parsed.scheme, "file") and
        !std.mem.eql(u8, parsed.scheme, "data"))
    {
        return error.UnsupportedWptUrlScheme;
    }
    return parsed;
}

fn parseWptTimeout(value: []const u8) !u64 {
    const timeout_ms = try std.fmt.parseInt(u64, value, 10);
    if (timeout_ms == 0) return error.InvalidWptTimeout;
    return timeout_ms;
}

fn wptReportObjectValid(
    object: *std.json.ObjectMap,
    expected_status: []const u8,
) bool {
    const status = object.getPtr("status") orelse return false;
    switch (status.*) {
        .string => |name| if (!std.mem.eql(u8, name, expected_status)) return false,
        else => return false,
    }

    const tests = object.getPtr("tests") orelse return false;
    switch (tests.*) {
        .array => {},
        else => return false,
    }
    const harness = object.getPtr("harness") orelse return false;
    switch (harness.*) {
        .object => {},
        else => return false,
    }
    if (object.getPtr("message")) |message| switch (message.*) {
        .string, .null => {},
        else => return false,
    };
    if (object.getPtr("console")) |console| switch (console.*) {
        .array => {},
        else => return false,
    };
    if (object.getPtr("exception")) |exception| switch (exception.*) {
        .object, .null => {},
        else => return false,
    };
    return true;
}

fn wptReportField(
    object: ?*std.json.ObjectMap,
    name: []const u8,
) ?*std.json.Value {
    const report = object orelse return null;
    return report.getPtr(name);
}

fn writeWptResult(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    test_url: []const u8,
    result: *const wpt_session.Result,
) !void {
    var parsed_report: ?ParsedJsonValue = null;
    if (result.payload.len != 0) {
        parsed_report = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            result.payload,
            .{},
        ) catch null;
    }
    defer if (parsed_report) |*parsed| parsed.deinit();

    const report_object: ?*std.json.ObjectMap = if (parsed_report) |*parsed| switch (parsed.value) {
        .object => |*object| object,
        else => null,
    } else null;
    const report_valid = if (result.payload.len == 0)
        result.status == .timeout
    else if (report_object) |object|
        wptReportObjectValid(object, result.status.jsonName())
    else
        false;
    const status = if (report_valid) result.status.jsonName() else "ERROR";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var json: std.json.Stringify = .{ .writer = stdout };

    try json.beginObject();
    try json.objectField("protocol_version");
    try json.write(@as(u32, 1));
    try json.objectField("test");
    try json.write(test_url);
    try json.objectField("status");
    try json.write(status);
    try json.objectField("duration_ms");
    try json.write(result.duration_ms);

    try json.objectField("tests");
    if (report_valid and wptReportField(report_object, "tests") != null) {
        try json.write(wptReportField(report_object, "tests").?.*);
    } else {
        try json.beginArray();
        try json.endArray();
    }

    try json.objectField("harness");
    if (report_valid and wptReportField(report_object, "harness") != null) {
        try json.write(wptReportField(report_object, "harness").?.*);
    } else {
        try json.write(null);
    }
    try json.objectField("message");
    if (!report_valid) {
        try json.write("Invalid harness report JSON");
    } else if (wptReportField(report_object, "message")) |message| {
        try json.write(message.*);
    } else {
        try json.write(null);
    }
    try json.objectField("console");
    if (report_valid and wptReportField(report_object, "console") != null) {
        try json.write(wptReportField(report_object, "console").?.*);
    } else {
        try json.beginArray();
        try json.endArray();
    }
    try json.objectField("exception");
    if (report_valid and wptReportField(report_object, "exception") != null) {
        try json.write(wptReportField(report_object, "exception").?.*);
    } else {
        try json.write(null);
    }
    try json.endObject();
    try stdout.writeByte('\n');
    try stdout.flush();
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

const Viewport = struct { width: i32 = 800, height: i32 = 600 };

fn parseViewport(input: []const u8) !Viewport {
    const separator = std.mem.indexOfScalar(u8, input, 'x') orelse return error.InvalidViewport;
    const width = std.fmt.parseInt(u16, input[0..separator], 10) catch return error.InvalidViewport;
    const height = std.fmt.parseInt(u16, input[separator + 1 ..], 10) catch return error.InvalidViewport;
    // Bound software surface allocation for accidental or hostile CLI input.
    if (width == 0 or height == 0 or width > 8192 or height > 8192) return error.InvalidViewport;
    return .{ .width = width, .height = height };
}

fn dumpPipeline(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: ?Url,
    mode: DumpMode,
    rtl_text: bool,
    viewport: Viewport,
) !void {
    var page = try inspection.Page.loadWithMedia(init, allocator, url, .{
        .viewport_width_css = @floatFromInt(viewport.width),
        .viewport_height_css = @floatFromInt(viewport.height),
    });
    defer page.deinit();
    // Page.load returns the DOM by value. Repair parent pointers after the
    // returned page reaches its stable inspection-stack address before paint
    // provenance or visited-link ancestry walks borrow them.
    page.repairParentPointers();

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
    const layout = try Layout.init(allocator, init.io, init.environ_map, viewport.width, viewport.height, rtl_text);
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
    var screenshot_after_ms: ?u64 = null;
    var viewport: ?Viewport = null;
    var wpt_test = false;
    var wpt_test_url: ?[]const u8 = null;
    var wpt_timeout_ms = default_wpt_timeout_ms;
    var wpt_timeout_set = false;

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--viewport") or std.mem.startsWith(u8, arg, "--viewport=")) {
            if (viewport != null) return error.BadArguments;
            const value = if (std.mem.startsWith(u8, arg, "--viewport=")) arg["--viewport=".len..] else blk: {
                if (arg_index + 1 >= args.len) return error.BadArguments;
                arg_index += 1;
                break :blk args[arg_index];
            };
            viewport = parseViewport(value) catch {
                std.log.err("--viewport requires WIDTHxHEIGHT, each between 1 and 8192.", .{});
                return error.BadArguments;
            };
            continue;
        }
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
        if (std.mem.eql(u8, arg, "--screenshot-after-ms")) {
            if (screenshot_after_ms != null or arg_index + 1 >= args.len) {
                std.log.err("--screenshot-after-ms requires one non-negative integer.", .{});
                return error.BadArguments;
            }
            arg_index += 1;
            screenshot_after_ms = std.fmt.parseInt(u64, args[arg_index], 10) catch {
                std.log.err("--screenshot-after-ms requires one non-negative integer.", .{});
                return error.BadArguments;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--wpt-test")) {
            if (wpt_test or url != null or arg_index + 1 >= args.len) {
                std.log.err("--wpt-test requires exactly one absolute URL.", .{});
                return error.BadArguments;
            }
            arg_index += 1;
            const input = args[arg_index];
            url = parseWptUrl(allocator, input) catch |err| {
                if (err == error.OutOfMemory) return err;
                std.log.err("Invalid WPT test URL '{s}': {}", .{ input, err });
                return error.BadArguments;
            };
            wpt_test = true;
            wpt_test_url = input;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--wpt-test=")) {
            const input = arg["--wpt-test=".len..];
            if (wpt_test or url != null or input.len == 0) {
                std.log.err("--wpt-test requires exactly one absolute URL.", .{});
                return error.BadArguments;
            }
            url = parseWptUrl(allocator, input) catch |err| {
                if (err == error.OutOfMemory) return err;
                std.log.err("Invalid WPT test URL '{s}': {}", .{ input, err });
                return error.BadArguments;
            };
            wpt_test = true;
            wpt_test_url = input;
            continue;
        }
        if (std.mem.eql(u8, arg, "--wpt-timeout-ms")) {
            if (wpt_timeout_set or arg_index + 1 >= args.len) {
                std.log.err("--wpt-timeout-ms requires one positive integer.", .{});
                return error.BadArguments;
            }
            arg_index += 1;
            wpt_timeout_ms = parseWptTimeout(args[arg_index]) catch |err| {
                std.log.err("Invalid WPT timeout '{s}': {}", .{ args[arg_index], err });
                return error.BadArguments;
            };
            wpt_timeout_set = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--wpt-timeout-ms=")) {
            const value = arg["--wpt-timeout-ms=".len..];
            if (wpt_timeout_set or value.len == 0) {
                std.log.err("--wpt-timeout-ms requires one positive integer.", .{});
                return error.BadArguments;
            }
            wpt_timeout_ms = parseWptTimeout(value) catch |err| {
                std.log.err("Invalid WPT timeout '{s}': {}", .{ value, err });
                return error.BadArguments;
            };
            wpt_timeout_set = true;
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

    if ((dump_mode != null and screenshot_path != null) or
        (wpt_test and (dump_mode != null or screenshot_path != null)))
    {
        std.log.err("Dump, screenshot, and WPT test modes cannot be combined.", .{});
        return error.BadArguments;
    }
    if (wpt_timeout_set and !wpt_test) {
        std.log.err("--wpt-timeout-ms requires --wpt-test.", .{});
        return error.BadArguments;
    }
    if (viewport != null and (wpt_test or (dump_mode == null and screenshot_path == null))) {
        std.log.err("--viewport requires a dump or screenshot mode.", .{});
        return error.BadArguments;
    }

    if (wpt_test) {
        const test_url = wpt_test_url orelse return error.BadArguments;
        const owned_url = url orelse return error.BadArguments;
        // Session.init consumes the URL, including on failure.
        url = null;
        const session = try wpt_session.Session.init(
            allocator,
            init.io,
            init.environ_map,
            owned_url,
            .{ .timeout_ms = wpt_timeout_ms, .rtl = rtl_flag },
        );
        var result = session.run() catch |err| {
            session.deinit();
            allocator.destroy(session);
            return err;
        };
        // Stop and join the Browser before exposing its copied terminal result.
        session.deinit();
        allocator.destroy(session);
        defer result.deinit();
        try writeWptResult(init, allocator, test_url, &result);
        return;
    }

    if (dump_mode) |mode| {
        if (mode == .dom) {
            try dumpDom(init, allocator, url);
        } else {
            try dumpPipeline(init, allocator, url, mode, rtl_flag, viewport orelse .{});
        }
        return;
    }

    if (screenshot_path) |path| {
        // Screenshot mode remains a direct, standalone Browser so it creates
        // no native window and retains its deterministic quiescence loop.
        const b = try Browser.init(allocator, init.io, init.environ_map, rtl_flag, true);
        defer {
            b.deinit();
            allocator.destroy(b);
        }

        if (viewport) |size| try b.resizeViewport(size.width, size.height);

        if (url) |u| {
            // Browser.newTab consumes the URL even on failure.
            url = null;
            try b.newTab(u);
        } else {
            try b.newTab(try Url.blank(allocator));
        }
        try b.runToScreenshot(path, screenshot_after_ms);
        return;
    }

    // Interactive mode has one process owner for SDL input and shared session
    // services. BrowserApp.newWindow consumes the initial URL on entry.
    const app = try BrowserApp.init(allocator, init.io, init.environ_map, rtl_flag);
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    if (url) |u| {
        url = null;
        _ = try app.newWindow(u);
    } else {
        _ = try app.newBlankWindow();
    }
    try app.run();
}
