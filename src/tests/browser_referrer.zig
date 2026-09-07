//! Referer request-header and Referrer-Policy regressions.

const std = @import("std");
const network = @import("../network/url.zig");
const Url = network.Url;

test "Referrer-Policy controls cross-origin disclosure and strips fragments" {
    const allocator = std.testing.allocator;
    const source = try Url.init(
        allocator,
        "https://example.com/account?token=private#section",
    );
    defer source.free(allocator);
    const same_origin = try Url.init(allocator, "https://example.com/next");
    defer same_origin.free(allocator);
    const cross_origin = try Url.init(allocator, "https://analytics.example/collect");
    defer cross_origin.free(allocator);

    try std.testing.expectEqualStrings(
        "https://example.com/",
        (try referrerForTest(source, cross_origin, .default)).?,
    );
    try std.testing.expect(try referrerForTest(source, cross_origin, .no_referrer) == null);
    try std.testing.expect(try referrerForTest(source, cross_origin, .same_origin) == null);
    try std.testing.expectEqualStrings(
        "https://example.com/account?token=private",
        (try referrerForTest(source, same_origin, .same_origin)).?,
    );
    try std.testing.expect(try referrerForTest(null, same_origin, .default) == null);
}

// Tests consume a bounded copy so every production allocation is reclaimed.
var referrer_buffer: [8192]u8 = undefined;
fn referrerForTest(source: ?Url, target: Url, policy: network.ReferrerPolicy) !?[]const u8 {
    const value = try network.refererHeaderValue(std.testing.allocator, source, target, policy) orelse return null;
    defer std.testing.allocator.free(value);
    @memcpy(referrer_buffer[0..value.len], value);
    return referrer_buffer[0..value.len];
}

test "Referrer-Policy header lists and HTML tokens have distinct parsing rules" {
    try std.testing.expectEqual(
        network.ReferrerPolicy.no_referrer,
        network.parseReferrerPolicy(" no-referrer\t").?,
    );
    try std.testing.expectEqual(
        network.ReferrerPolicy.same_origin,
        network.Referrer.parseAttribute("SAME-ORIGIN").?,
    );
    try std.testing.expectEqual(network.ReferrerPolicy.strict_origin, network.parseReferrerPolicy("origin, strict-origin, future").?);
    try std.testing.expect(network.parseReferrerPolicy("SAME-ORIGIN") == null);
    try std.testing.expect(network.Referrer.parseAttribute(" origin") == null);
    try std.testing.expect(network.Referrer.parseAttribute("no-referrer, origin") == null);
    try std.testing.expect(network.Referrer.parseMeta(" no-referrer") == null);
    try std.testing.expectEqual(network.ReferrerPolicy.unsafe_url, network.Referrer.parseMeta("ALWAYS").?);
    try std.testing.expectEqual(network.ReferrerPolicy.no_referrer, network.Referrer.parseMeta("never").?);
    try std.testing.expectEqual(network.ReferrerPolicy.strict_origin_when_cross_origin, network.Referrer.parseMeta("default").?);
    inline for (std.meta.tags(network.ReferrerPolicy)) |policy| {
        if (policy != .default) try std.testing.expectEqual(policy, network.parseReferrerPolicy(policy.token()).?);
    }
}

test "Referrer-Policy all policies across same origin cross origin and downgrade" {
    const allocator = std.testing.allocator;
    const source = try Url.init(allocator, "https://user:secret@example.com/private?q=secret#hidden");
    defer source.free(allocator);
    const targets = [_][]const u8{ "https://example.com/next", "https://elsewhere.example/", "http://elsewhere.example/" };
    const D = network.Referrer.Disclosure;
    const cases = .{
        .{ network.ReferrerPolicy.default, [3]D{ .full, .origin, .none } },
        .{ network.ReferrerPolicy.no_referrer, [3]D{ .none, .none, .none } },
        .{ network.ReferrerPolicy.same_origin, [3]D{ .full, .none, .none } },
        .{ network.ReferrerPolicy.origin, [3]D{ .origin, .origin, .origin } },
        .{ network.ReferrerPolicy.strict_origin, [3]D{ .origin, .origin, .none } },
        .{ network.ReferrerPolicy.origin_when_cross_origin, [3]D{ .full, .origin, .origin } },
        .{ network.ReferrerPolicy.strict_origin_when_cross_origin, [3]D{ .full, .origin, .none } },
        .{ network.ReferrerPolicy.no_referrer_when_downgrade, [3]D{ .full, .full, .none } },
        .{ network.ReferrerPolicy.unsafe_url, [3]D{ .full, .full, .full } },
    };
    inline for (cases) |case| {
        for (targets, case[1]) |text, expected| {
            const target = try Url.init(allocator, text);
            defer target.free(allocator);
            try std.testing.expectEqual(expected, network.Referrer.determine(@as(?Url, source), target, case[0], .full));
            const value = try network.refererHeaderValue(allocator, source, target, case[0]);
            defer if (value) |v| allocator.free(v);
            switch (expected) {
                .none => try std.testing.expect(value == null),
                .origin => try std.testing.expectEqualStrings("https://example.com/", value.?),
                .full => try std.testing.expectEqualStrings("https://example.com/private?q=secret", value.?),
            }
        }
    }
}

test "Referrer-Policy strips local sources caps long URLs and never restores redirected disclosure" {
    const a = std.testing.allocator;
    const target = try Url.init(a, "https://example.com/");
    defer target.free(a);
    for ([_][]const u8{ "about:blank", "data:text/plain,private", "file:///private/secret" }) |text| {
        const source = try Url.init(a, text);
        defer source.free(a);
        try std.testing.expect(try referrerForTest(source, target, .unsafe_url) == null);
    }
    const prefix = "https://example.com/";
    const text = try a.alloc(u8, 4097);
    defer a.free(text);
    @memcpy(text[0..prefix.len], prefix);
    @memset(text[prefix.len..], 'x');
    for ([_]usize{ 4096, 4097 }) |length| {
        const source = try Url.init(a, text[0..length]);
        defer source.free(a);
        try std.testing.expectEqual(if (length == 4096) network.Referrer.Disclosure.full else .origin, network.Referrer.determine(@as(?Url, source), target, .unsafe_url, .full));
    }
    const source = try Url.init(a, "https://[::1]:8443/private#secret");
    defer source.free(a);
    const loopback = try Url.init(a, "http://localhost:8080/");
    defer loopback.free(a);
    try std.testing.expectEqualStrings("https://[::1]:8443/", (try referrerForTest(source, loopback, .default)).?);
    const lookalike = try Url.init(a, "http://127.evil.example/");
    defer lookalike.free(a);
    try std.testing.expect(try referrerForTest(source, lookalike, .default) == null);
    try std.testing.expectEqual(network.Referrer.Disclosure.origin, network.Referrer.determine(@as(?Url, source), target, .unsafe_url, .origin));
    try std.testing.expectEqual(network.Referrer.Disclosure.none, network.Referrer.determine(@as(?Url, source), target, .unsafe_url, .none));
}

test "Referrer navigation snapshots outlive their initiating URL even when suppressed" {
    const a = std.testing.allocator;
    const source = try Url.init(a, "https://example.com/private#fragment");
    var snapshot = @import("../browser/navigation.zig").ReferrerSource.clone(a, source, .no_referrer) catch |err| {
        source.free(a);
        return err;
    };
    source.free(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqualStrings("https://example.com/private#fragment", snapshot.url.?.ada_url.getHref());
    try std.testing.expectEqual(network.ReferrerPolicy.no_referrer, snapshot.policy);
}
