//! Media's conservative CSP source-list subset. Unknown expressions do not
//! grant access. The same copied policy is checked before every redirect.
const std = @import("std");
const Url = @import("../network/url.zig").Url;

/// Returns a borrowed media-src list, falling back to default-src. First
/// occurrence wins; a missing directive imposes no source-list restriction.
pub fn sourceList(header: []const u8) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    var directives = std.mem.tokenizeScalar(u8, header, ';');
    while (directives.next()) |directive| {
        var words = std.mem.tokenizeAny(u8, directive, " \t\r\n");
        const name = words.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(name, "media-src")) return words.rest();
        if (fallback == null and std.ascii.eqlIgnoreCase(name, "default-src")) fallback = words.rest();
    }
    return fallback;
}

/// Supports 'self', *, scheme sources and exact origins (optional paths).
/// Host wildcards/nonstandard expressions fail closed in this first pass.
pub fn allows(allocator: std.mem.Allocator, list: ?[]const u8, base: Url, target: Url) bool {
    const http = std.mem.eql(u8, target.scheme, "http") or std.mem.eql(u8, target.scheme, "https");
    if (!http and !std.mem.eql(u8, target.scheme, "file") and !std.mem.eql(u8, target.scheme, "data")) return false;
    if (std.mem.eql(u8, target.scheme, "file") and !std.mem.eql(u8, base.scheme, "file")) return false;
    if (std.mem.eql(u8, base.scheme, "https") and std.mem.eql(u8, target.scheme, "http")) return false;
    var words = std.mem.tokenizeAny(u8, list orelse return true, " \t\r\n");
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "'self'") and base.sameOrigin(target)) return true;
        if (std.mem.eql(u8, word, "*") and http) return true;
        if (std.mem.endsWith(u8, word, ":") and std.ascii.eqlIgnoreCase(word[0 .. word.len - 1], target.scheme)) return true;
        if (std.mem.indexOf(u8, word, "://") == null) continue;
        const source = Url.init(allocator, word) catch continue;
        defer source.free(allocator);
        if (!source.sameOrigin(target)) continue;
        if (std.mem.eql(u8, source.path, "/") or std.mem.eql(u8, source.path, target.path) or
            (std.mem.endsWith(u8, source.path, "/") and std.mem.startsWith(u8, target.path, source.path))) return true;
    }
    return false;
}

test "audio policy honors media-src over default-src including same-origin denial" {
    const allocator = std.testing.allocator;
    const base = try Url.init(allocator, "https://example.com/page");
    defer base.free(allocator);
    const same = try Url.init(allocator, "https://example.com/song.wav");
    defer same.free(allocator);
    const other = try Url.init(allocator, "https://cdn.example/song.wav");
    defer other.free(allocator);
    try std.testing.expect(!allows(allocator, sourceList("default-src 'self'; media-src 'none'"), base, same));
    try std.testing.expect(allows(allocator, sourceList("default-src 'none'; media-src https://cdn.example"), base, other));
    try std.testing.expect(!allows(allocator, sourceList("default-src 'self'"), base, other));
    try std.testing.expect(allows(allocator, sourceList("default-src 'self'"), base, same));
    try std.testing.expectEqualStrings("'none'", sourceList("media-src 'none'; media-src *").?);
    const file = try Url.init(allocator, "file:///tmp/song.wav");
    defer file.free(allocator);
    try std.testing.expect(!allows(allocator, null, base, file));
    const insecure = try Url.init(allocator, "http://example.com/song.wav");
    defer insecure.free(allocator);
    try std.testing.expect(!allows(allocator, null, base, insecure));
}
