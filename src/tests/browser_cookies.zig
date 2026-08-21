//! Cookie-jar and document.cookie regressions.

const std = @import("std");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const url_module = @import("../network/url.zig");
const Url = url_module.Url;
const Js = @import("../script/js.zig");

test "script cookies retain parameters and cannot access HttpOnly entries" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    try std.testing.expect(try url_module.applySetCookie(
        allocator,
        &session.cookie_jar,
        "private.example",
        "token=secret; SameSite=Lax; HttpOnly",
        .http,
    ));
    const private_entry = session.cookie_jar.get("private.example").?;
    try std.testing.expectEqualStrings("token=secret", private_entry.value);
    try std.testing.expect(private_entry.http_only);
    try std.testing.expectEqual(url_module.SameSiteMode.lax, private_entry.same_site);

    var same_origin = try Url.init(allocator, "https://private.example/xhr");
    defer same_origin.free(allocator);
    try std.testing.expectEqualStrings(
        "token=secret",
        url_module.cookieForRequest(
            &session.cookie_jar,
            "private.example",
            .POST,
            same_origin,
        ).?,
    );

    const hidden = try session.readCookieForScript(allocator, "private.example");
    defer allocator.free(hidden);
    try std.testing.expectEqualStrings("", hidden);
    try std.testing.expect(!try session.writeCookieFromScript(
        "private.example",
        "token=stolen; SameSite=Lax",
    ));
    try std.testing.expectEqualStrings(
        "token=secret",
        session.cookie_jar.get("private.example").?.value,
    );

    try std.testing.expect(try url_module.applySetCookie(
        allocator,
        &session.cookie_jar,
        "public.example",
        "theme=dark; SameSite=Lax; Path=/",
        .http,
    ));
    const initial = try session.readCookieForScript(allocator, "public.example");
    defer allocator.free(initial);
    try std.testing.expectEqualStrings("theme=dark; SameSite=Lax; Path=/", initial);

    try std.testing.expect(try session.writeCookieFromScript(
        "public.example",
        "theme=light; SameSite=Lax; Path=/settings",
    ));
    const updated = try session.readCookieForScript(allocator, "public.example");
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("theme=light; SameSite=Lax; Path=/settings", updated);

    // Script cannot smuggle the server-only flag onto a new value either.
    try std.testing.expect(!try session.writeCookieFromScript(
        "new.example",
        "admin=yes; HttpOnly",
    ));
    try std.testing.expect(session.cookie_jar.get("new.example") == null);

    const other_host = try session.readCookieForScript(allocator, "other.example");
    defer allocator.free(other_host);
    try std.testing.expectEqualStrings("", other_host);
}

const MockCookieContext = struct {
    allocator: std.mem.Allocator,
    value: []u8,

    fn get(context: ?*anyopaque) anyerror!Js.CookieResult {
        const raw = context orelse return error.MissingCookieContext;
        const unaligned: *align(1) @This() = @ptrCast(raw);
        const self: *@This() = @alignCast(unaligned);
        const copy = try self.allocator.dupe(u8, self.value);
        return .{ .data = copy, .allocator = self.allocator, .should_free = true };
    }

    fn set(context: ?*anyopaque, value: []const u8) anyerror!void {
        const raw = context orelse return error.MissingCookieContext;
        const unaligned: *align(1) @This() = @ptrCast(raw);
        const self: *@This() = @alignCast(unaligned);
        const copy = try self.allocator.dupe(u8, value);
        self.allocator.free(self.value);
        self.value = copy;
    }
};

test "document.cookie is a dynamic native getter and setter" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var context = MockCookieContext{
        .allocator = allocator,
        .value = try allocator.dupe(u8, "theme=dark; SameSite=Lax"),
    };
    defer allocator.free(context.value);
    js.setCookieCallbacks(7, MockCookieContext.get, MockCookieContext.set, &context);

    const result = try js.evaluate(
        7,
        "var before = document.cookie;" ++
            "document.cookie = 'theme=light; Path=/settings';" ++
            "before + '|' + document.cookie",
    );
    const text = try result.asString().toUtf8(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(
        "theme=dark; SameSite=Lax|theme=light; Path=/settings",
        text,
    );
    try std.testing.expectEqualStrings("theme=light; Path=/settings", context.value);
}
