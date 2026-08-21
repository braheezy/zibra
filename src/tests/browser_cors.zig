//! Cross-origin XMLHttpRequest policy regressions.

const std = @import("std");
const url_module = @import("../network/url.zig");
const Url = url_module.Url;
const Js = @import("../script/js.zig");

test "URL origins omit default ports and retain non-default ports" {
    const allocator = std.testing.allocator;
    const default_http = try Url.init(allocator, "http://Example.com:80/page");
    defer default_http.free(allocator);
    const default_origin = try default_http.toOwnedOrigin(allocator);
    defer allocator.free(default_origin);
    try std.testing.expectEqualStrings("http://example.com", default_origin);

    const custom_https = try Url.init(allocator, "https://example.com:8443/page");
    defer custom_https.free(allocator);
    const custom_origin = try custom_https.toOwnedOrigin(allocator);
    defer allocator.free(custom_origin);
    try std.testing.expectEqualStrings("https://example.com:8443", custom_origin);

    const opaque_url = try Url.init(allocator, "data:text/plain,hello");
    defer opaque_url.free(allocator);
    const opaque_origin = try opaque_url.toOwnedOrigin(allocator);
    defer allocator.free(opaque_origin);
    try std.testing.expectEqualStrings("null", opaque_origin);

    const ipv6 = try Url.init(allocator, "http://[::1]:8080/page");
    defer ipv6.free(allocator);
    const ipv6_origin = try ipv6.toOwnedOrigin(allocator);
    defer allocator.free(ipv6_origin);
    try std.testing.expectEqualStrings("http://[::1]:8080", ipv6_origin);
}

test "CORS accepts exact and wildcard opt-in and rejects missing or mismatched headers" {
    const origin = "http://source.example:8080";
    try std.testing.expect(url_module.corsAllowsResponse(null, null));
    try std.testing.expect(url_module.corsAllowsResponse(origin, origin));
    try std.testing.expect(url_module.corsAllowsResponse(origin, " * \t"));
    try std.testing.expect(!url_module.corsAllowsResponse(origin, null));
    try std.testing.expect(!url_module.corsAllowsResponse(origin, "http://other.example"));
    try std.testing.expect(!url_module.corsAllowsResponse(origin, "HTTP://SOURCE.EXAMPLE:8080"));
}

const MockXhrContext = struct {
    allocator: std.mem.Allocator,

    fn send(
        context: ?*anyopaque,
        method: []const u8,
        url: []const u8,
        body: ?[]const u8,
        is_async: bool,
        handle: u32,
    ) anyerror!Js.XhrResult {
        _ = method;
        _ = url;
        _ = body;
        _ = handle;
        const raw = context orelse return error.MissingXhrContext;
        const unaligned: *align(1) @This() = @ptrCast(raw);
        const self: *@This() = @alignCast(unaligned);
        if (is_async) return .{ .data = "" };
        return .{
            .data = try self.allocator.dupe(u8, "XHR OK"),
            .allocator = self.allocator,
            .should_free = true,
        };
    }
};

test "synchronous XHR retains callback-owned ASCII response text" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var context = MockXhrContext{ .allocator = allocator };
    js.setXhrCallback(0, MockXhrContext.send, &context);
    const result = try js.evaluate(
        0,
        "var request = new XMLHttpRequest();" ++
            "request.open('GET', '/xhr', false);" ++
            "request.send();" ++
            "request.responseText;",
    );
    const text = try result.asString().toUtf8(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("XHR OK", text);
}

test "asynchronous XHR retains task-owned ASCII response text" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var context = MockXhrContext{ .allocator = allocator };
    js.setXhrCallback(0, MockXhrContext.send, &context);
    _ = try js.evaluate(
        0,
        "var asyncText = 'not called';" ++
            "var request = new XMLHttpRequest();" ++
            "request.open('GET', '/xhr', true);" ++
            "request.onload = function() { asyncText = request.responseText; };" ++
            "request.send();" ++
            "undefined;",
    );

    const temporary = try allocator.dupe(u8, "XHR OK");
    try js.runXhrOnload(0, 0, temporary);
    allocator.free(temporary);

    const result = try js.evaluate(0, "asyncText;");
    const text = try result.asString().toUtf8(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("XHR OK", text);
}
