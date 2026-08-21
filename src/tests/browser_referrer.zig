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
        "https://example.com/account?token=private",
        network.refererHeaderValue(source, cross_origin, .default).?,
    );
    try std.testing.expect(network.refererHeaderValue(source, cross_origin, .no_referrer) == null);
    try std.testing.expect(network.refererHeaderValue(source, cross_origin, .same_origin) == null);
    try std.testing.expectEqualStrings(
        "https://example.com/account?token=private",
        network.refererHeaderValue(source, same_origin, .same_origin).?,
    );
    try std.testing.expect(network.refererHeaderValue(null, same_origin, .default) == null);
}

test "Referrer-Policy parser recognizes supported tokens case-insensitively" {
    try std.testing.expectEqual(
        network.ReferrerPolicy.no_referrer,
        network.parseReferrerPolicy(" No-Referrer\t").?,
    );
    try std.testing.expectEqual(
        network.ReferrerPolicy.same_origin,
        network.parseReferrerPolicy("SAME-ORIGIN").?,
    );
    try std.testing.expect(network.parseReferrerPolicy("strict-origin") == null);
}
