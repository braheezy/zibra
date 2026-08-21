//! Focused certificate-warning and committed-address security tests.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Chrome = @import("../browser/chrome.zig");
const Url = @import("../network/url.zig").Url;

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
