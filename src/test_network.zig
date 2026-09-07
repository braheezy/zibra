//! Focused unit-test root for URLs, HTTP, cookies, caching, and response policy.

comptime {
    _ = @import("network/url.zig");
    _ = @import("tests/browser_referrer.zig");
}
