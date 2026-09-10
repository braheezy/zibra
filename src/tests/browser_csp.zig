//! URL-source policy parsing, destination routing, and Frame replacement tests.
const std = @import("std");
const csp = @import("../browser/content_security_policy.zig");
const Frame = @import("../browser/tab.zig").Frame;
const Url = @import("../network/url.zig").Url;

fn expectAllowed(header: []const u8, origin_text: []const u8, target_text: []const u8, destination: csp.Destination, expected: bool) !void {
    const allocator = std.testing.allocator;
    const origin = try Url.init(allocator, origin_text);
    defer origin.free(allocator);
    const target = try Url.init(allocator, target_text);
    defer target.free(allocator);
    var policy = try csp.Policy.init(allocator, header, &origin);
    defer policy.deinit(allocator);
    try std.testing.expectEqual(expected, policy.allows(&target, destination, false));
}

test "CSP GitHub-shaped policy uses explicit destination sources over default none" {
    const header = "default-src 'none'; style-src 'unsafe-inline' github.githubassets.com; " ++
        "script-src github.githubassets.com; img-src 'self' data: *.githubusercontent.com; " ++
        "connect-src 'self' api.github.com; font-src github.githubassets.com; frame-src viewscreen.githubusercontent.com";
    const origin = "https://github.com/user";
    try expectAllowed(header, origin, "https://github.githubassets.com/primer.css", .stylesheet, true);
    try expectAllowed(header, origin, "https://github.githubassets.com/app.js", .script, true);
    try expectAllowed(header, origin, "https://github.githubassets.com/font.woff2", .font, true);
    try expectAllowed(header, origin, "https://avatars.githubusercontent.com/u/123", .image, true);
    try expectAllowed(header, origin, "data:image/png;base64,AA==", .image, true);
    try expectAllowed(header, origin, "https://github.com/image.png", .image, true);
    try expectAllowed(header, origin, "https://api.github.com/user", .connect, true);
    try expectAllowed(header, origin, "https://viewscreen.githubusercontent.com/view", .frame, true);
    try expectAllowed(header, origin, "https://github.com/not-permitted.css", .stylesheet, false);
    try expectAllowed(header, origin, "https://github.githubassets.com/api", .connect, false);
    try expectAllowed(header, origin, "https://other.example/primer.css", .stylesheet, false);
}

test "CSP none empty and missing source lists are distinct even for same origin" {
    const origin = "https://page.example/index";
    for ([_]csp.Destination{ .script, .stylesheet, .image, .connect, .frame, .font, .media }) |destination| {
        try expectAllowed("default-src 'none'", origin, origin, destination, false);
        try expectAllowed("default-src", origin, origin, destination, false);
        try expectAllowed("", origin, origin, destination, true);
    }
    try expectAllowed("img-src 'none'", origin, origin, .stylesheet, true);
    try expectAllowed("default-src *; style-src", origin, origin, .stylesheet, false);
    try expectAllowed("img-src 'none' 'self'", origin, origin, .image, true);
    try expectAllowed("style-src 'unsafe-inline'", origin, origin, .stylesheet, false);
}

test "CSP element and child directive fallback stops at first present directive" {
    const origin = "https://page.example/";
    try expectAllowed("default-src 'none'; style-src 'self'", origin, origin, .stylesheet, true);
    try expectAllowed("style-src 'self'; style-src-elem 'none'", origin, origin, .stylesheet, false);
    try expectAllowed("script-src 'none'; script-src-elem 'self'", origin, origin, .script, true);
    try expectAllowed("default-src 'none'; child-src 'self'", origin, origin, .frame, true);
    try expectAllowed("child-src 'self'; frame-src 'none'", origin, origin, .frame, false);
    try expectAllowed("child-src 'none'", origin, origin, .script, true);
}

test "CSP parser handles whitespace duplicate directives and intersected policies" {
    const origin = "https://page.example/";
    try expectAllowed("\tSTYLE-SRC\n'SeLf'\r; style-src 'none'", origin, origin, .stylesheet, true);
    try expectAllowed("style-src; style-src *", origin, origin, .stylesheet, false);
    try expectAllowed("style-src * , style-src 'none'", origin, origin, .stylesheet, false);
    try expectAllowed("style-src 'self', default-src 'self'", origin, origin, .stylesheet, true);
    try expectAllowed("style-src 'self', img-src 'none'", origin, origin, .stylesheet, true);
}

test "CSP URL matching respects scheme host boundaries ports and local schemes" {
    const origin = "https://page.example/";
    try expectAllowed("img-src *.assets.example", origin, "https://a.assets.example/image", .image, true);
    try expectAllowed("img-src *.assets.example", origin, "https://assets.example/image", .image, false);
    try expectAllowed("img-src *.assets.example", origin, "https://evilassets.example/image", .image, false);
    try expectAllowed("img-src ASSETS.EXAMPLE", origin, "https://assets.example/image", .image, true);
    try expectAllowed("img-src assets.example", origin, "http://assets.example/image", .image, false);
    try expectAllowed("img-src assets.example", "http://page.example/", "https://assets.example/image", .image, true);
    try expectAllowed("img-src assets.example", origin, "https://assets.example:8443/image", .image, false);
    try expectAllowed("img-src assets.example:*", origin, "https://assets.example:8443/image", .image, true);
    try expectAllowed("img-src https://assets.example:8443", origin, "https://assets.example:8443/image", .image, true);
    try expectAllowed("img-src assets.example:443", origin, "https://assets.example/image", .image, true);
    try expectAllowed("img-src http:", origin, "https://assets.example/image", .image, true);
    try expectAllowed("img-src https:", origin, "http://assets.example/image", .image, false);
    try expectAllowed("img-src *", origin, "data:image/png;base64,AA==", .image, false);
    try expectAllowed("img-src *", origin, "file:///tmp/image.png", .image, false);
    try expectAllowed("img-src data:", origin, "data:image/png;base64,AA==", .image, true);
    try expectAllowed("img-src 'none'", origin, "data:image/png;base64,AA==", .image, false);
}

test "CSP self supports safe scheme upgrades but not host or port changes" {
    try expectAllowed("default-src 'self'", "http://page.example/", "https://page.example/", .stylesheet, true);
    try expectAllowed("default-src 'self'", "https://page.example/", "http://page.example/", .stylesheet, false);
    try expectAllowed("default-src 'self'", "https://page.example:8443/", "https://page.example/", .stylesheet, false);
    try expectAllowed("default-src 'self'", "https://page.example/", "https://other.example/", .stylesheet, false);
    try expectAllowed("default-src self", "https://page.example/", "https://page.example/", .stylesheet, false);
}

test "CSP source paths match decoded segments without permitting prefix escapes" {
    const origin = "https://page.example/";
    const header = "style-src assets.example/css/";
    try expectAllowed(header, origin, "https://assets.example/css/main.css?version=2", .stylesheet, true);
    try expectAllowed(header, origin, "https://assets.example/css", .stylesheet, false);
    try expectAllowed(header, origin, "https://assets.example/css-evil/main.css", .stylesheet, false);
    try expectAllowed(header, origin, "https://assets.example/CSS/main.css", .stylesheet, false);
    try expectAllowed(header, origin, "https://assets.example/%63ss/main.css", .stylesheet, true);
    try expectAllowed(header, origin, "https://assets.example/css%2fmain.css", .stylesheet, false);
    try expectAllowed("style-src assets.example/css/main.css", origin, "https://assets.example/css/main.css/other", .stylesheet, false);
    try expectAllowed("style-src assets.example/css/main.css", origin, "https://assets.example/css/main.css", .stylesheet, true);
    try expectAllowed("style-src assets.example/css/%01", origin, "https://assets.example/css/%+1", .stylesheet, false);
    try expectAllowed("style-src assets.example/css/%00", origin, "https://assets.example/css/%-0", .stylesheet, false);
    try expectAllowed("style-src assets.example/css/main.css?x", origin, "https://assets.example/css/main.css", .stylesheet, false);
    try expectAllowed("style-src assets.example:bad", origin, "https://assets.example/", .stylesheet, false);
    try expectAllowed("style-src assets.example@evil.example", origin, "https://evil.example/", .stylesheet, false);
}

test "CSP redirected frames skip paths but still enforce destination origin" {
    const allocator = std.testing.allocator;
    const origin = try Url.init(allocator, "https://page.example/");
    defer origin.free(allocator);
    const target = try Url.init(allocator, "https://child.example/final");
    defer target.free(allocator);
    const forbidden = try Url.init(allocator, "https://other.example/allowed/index");
    defer forbidden.free(allocator);
    var policy = try csp.Policy.init(allocator, "default-src 'none'; frame-src child.example/allowed/", &origin);
    defer policy.deinit(allocator);
    try std.testing.expect(!policy.allows(&target, .frame, false));
    try std.testing.expect(policy.allows(&target, .frame, true));
    try std.testing.expect(!policy.allows(&forbidden, .frame, true));
}

test "CSP strict dynamic cannot be weakened to a script host allowlist" {
    try expectAllowed("script-src * 'strict-dynamic'", "https://page.example/", "https://assets.example/app.js", .script, false);
}

fn policyAllocationTrial(allocator: std.mem.Allocator) !void {
    const origin = try Url.init(allocator, "https://page.example/");
    defer origin.free(allocator);
    var policy = try csp.Policy.init(allocator, "default-src 'none'; style-src 'self', style-src https:", &origin);
    defer policy.deinit(allocator);
    try std.testing.expect(policy.allows(&origin, .stylesheet, false));
}

test "CSP construction reclaims partial owners on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, policyAllocationTrial, .{});
}

test "CSP Frame replacement owns source and origin and resets on navigation" {
    const allocator = std.testing.allocator;
    var frame: Frame = undefined;
    frame.allocator = allocator;
    frame.content_security_policy = null;
    defer frame.clearContentSecurityPolicy();
    const target = try Url.init(allocator, "https://page.example/style.css");
    defer target.free(allocator);
    {
        const origin = try Url.init(allocator, "https://page.example/");
        defer origin.free(allocator);
        const header = try allocator.dupe(u8, "default-src 'none'; style-src 'self'");
        defer allocator.free(header);
        try frame.applyContentSecurityPolicy(header, origin);
    }
    try std.testing.expect(frame.allowedRequest(&target, .stylesheet));
    try std.testing.expect(!frame.allowedRequest(&target, .image));
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    frame.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, frame.applyContentSecurityPolicy("default-src *", target));
    frame.allocator = allocator;
    try std.testing.expect(!frame.allowedRequest(&target, .image));
    try frame.applyContentSecurityPolicy("default-src 'none'", target);
    try std.testing.expect(!frame.allowedRequest(&target, .stylesheet));
    frame.clearContentSecurityPolicy();
    try std.testing.expect(frame.allowedRequest(&target, .stylesheet));
}

test "audio CSP uses media destination fallback and intersected response policies" {
    const origin = "https://page.example/";
    try expectAllowed("default-src 'none'; media-src 'self'", origin, origin, .media, true);
    try expectAllowed("default-src 'self'; media-src 'none'", origin, origin, .media, false);
    try expectAllowed("media-src; media-src *", origin, origin, .media, false);
    try expectAllowed("media-src *, media-src 'none'", origin, origin, .media, false);
    try expectAllowed("media-src data:", origin, "data:audio/wav,1234", .media, true);
}
