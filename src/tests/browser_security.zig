//! Focused certificate-warning and committed-address security tests.

const std = @import("std");
const browser = @import("../browser/root.zig");
const navigation = @import("../browser/navigation.zig");
const Chrome = @import("../browser/chrome.zig");
const url_module = @import("../network/url.zig");
const Url = url_module.Url;

test "TLS initialization failures are the certificate-error boundary" {
    try std.testing.expect(Url.isCertificateError(error.TlsInitializationFailed));
    try std.testing.expect(!Url.isCertificateError(error.ConnectionRefused));
    try std.testing.expect(!Url.isCertificateError(error.OutOfMemory));
}

test "certificate warning is owned escaped browser HTML without a bypass" {
    const allocator = std.testing.allocator;
    var requested = try Url.init(allocator, "https://example.com/search?a=1&b=2");
    defer requested.free(allocator);

    const warning = try browser.certificateWarningHtml(
        allocator,
        &requested,
        error.TlsInitializationFailed,
    );
    defer allocator.free(warning);

    try std.testing.expect(std.mem.indexOf(u8, warning, "<title>Certificate error</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "https://example.com/search?a=1&amp;b=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "TlsInitializationFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "<a") == null);
}

test "X-Frame-Options denies framing and checks the complete ancestor chain" {
    const allocator = std.testing.allocator;
    var response_url = try Url.init(allocator, "https://protected.example/document");
    defer response_url.free(allocator);
    var same_parent = try Url.init(allocator, "https://protected.example/embedder");
    defer same_parent.free(allocator);
    var same_top = try Url.init(allocator, "https://protected.example/top");
    defer same_top.free(allocator);
    var cross_origin = try Url.init(allocator, "https://attacker.example/top");
    defer cross_origin.free(allocator);

    const same_chain = [_]*const Url{ &same_parent, &same_top };
    const mixed_chain = [_]*const Url{ &same_parent, &cross_origin };

    try std.testing.expect(navigation.xFrameOptionsAllowsEmbedding(
        .none,
        &response_url,
        &mixed_chain,
    ));
    try std.testing.expect(!navigation.xFrameOptionsAllowsEmbedding(
        .deny,
        &response_url,
        &same_chain,
    ));
    try std.testing.expect(navigation.xFrameOptionsAllowsEmbedding(
        .same_origin,
        &response_url,
        &same_chain,
    ));
    try std.testing.expect(!navigation.xFrameOptionsAllowsEmbedding(
        .same_origin,
        &response_url,
        &mixed_chain,
    ));
    try std.testing.expect(!navigation.xFrameOptionsAllowsEmbedding(
        .same_origin,
        &response_url,
        &.{},
    ));
}

test "padlock requires a verified committed HTTPS URL matching chrome" {
    const allocator = std.testing.allocator;
    var https = try Url.init(allocator, "https://example.com/secure");
    defer https.free(allocator);
    var http = try Url.init(allocator, "http://example.com/plain");
    defer http.free(allocator);

    try std.testing.expectEqual(
        browser.NavigationSecurity.secure,
        browser.navigationSecurity(&https, false),
    );
    try std.testing.expectEqual(
        browser.NavigationSecurity.none,
        browser.navigationSecurity(&http, false),
    );
    try std.testing.expectEqual(
        browser.NavigationSecurity.certificate_error,
        browser.navigationSecurity(&https, true),
    );

    const committed = "https://example.com/secure";
    try std.testing.expect(Chrome.shouldShowPadlock(committed, committed, .secure));
    try std.testing.expect(!Chrome.shouldShowPadlock(
        "https://example.com/pending",
        committed,
        .secure,
    ));
    try std.testing.expect(!Chrome.shouldShowPadlock(committed, committed, .certificate_error));
    try std.testing.expect(!Chrome.shouldShowPadlock(committed, committed, .none));
    try std.testing.expectEqualStrings("🔒 ", Chrome.secure_address_prefix);
}
