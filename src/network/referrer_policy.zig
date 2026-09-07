//! Referrer Policy parsing and disclosure decisions. All values are scalar;
//! URL arguments are synchronous borrows and serialization returns an owner.

const std = @import("std");

pub const Policy = enum {
    default,
    no_referrer,
    no_referrer_when_downgrade,
    same_origin,
    origin,
    strict_origin,
    origin_when_cross_origin,
    strict_origin_when_cross_origin,
    unsafe_url,

    pub fn token(self: Policy) []const u8 {
        return switch (self) {
            .default => "",
            .no_referrer => "no-referrer",
            .no_referrer_when_downgrade => "no-referrer-when-downgrade",
            .same_origin => "same-origin",
            .origin => "origin",
            .strict_origin => "strict-origin",
            .origin_when_cross_origin => "origin-when-cross-origin",
            .strict_origin_when_cross_origin => "strict-origin-when-cross-origin",
            .unsafe_url => "unsafe-url",
        };
    }
};

/// Ordered by disclosure, so redirect hops can only reduce information.
pub const Disclosure = enum(u8) { none, origin, full };

/// HTML enumerated attributes use ASCII-insensitive, single-token matching.
/// Whitespace and comma lists are invalid (unlike HTTP header lists).
pub fn parseAttribute(value: []const u8) ?Policy {
    inline for (std.meta.tags(Policy)) |policy| {
        if (policy != .default and std.ascii.eqlIgnoreCase(value, policy.token())) return policy;
    }
    return null;
}

pub fn parseMeta(value: []const u8) ?Policy {
    if (std.ascii.eqlIgnoreCase(value, "never")) return .no_referrer;
    if (std.ascii.eqlIgnoreCase(value, "always")) return .unsafe_url;
    if (std.ascii.eqlIgnoreCase(value, "default")) return .strict_origin_when_cross_origin;
    if (std.ascii.eqlIgnoreCase(value, "origin-when-crossorigin")) return .origin_when_cross_origin;
    return parseAttribute(value);
}

/// HTTP policy tokens are case-sensitive. Last recognized list member wins;
/// callers retain a recognized earlier field when a later field is invalid.
pub fn parseHeader(value: []const u8) ?Policy {
    var result: ?Policy = null;
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (parseAttribute(token)) |policy| {
            if (std.mem.eql(u8, token, policy.token())) result = policy;
        }
    }
    return result;
}

fn isHttp(url: anytype) bool {
    return std.mem.eql(u8, url.scheme, "http") or std.mem.eql(u8, url.scheme, "https");
}

fn trustworthy(url: anytype) bool {
    if (std.mem.eql(u8, url.scheme, "https")) return true;
    const hostname = url.ada_url.getHostname() orelse return false;
    const host = std.mem.trimEnd(u8, hostname, ".");
    if (std.mem.eql(u8, host, "localhost") or std.mem.endsWith(u8, host, ".localhost") or
        std.mem.eql(u8, host, "[::1]")) return true;
    const address = std.Io.net.Ip4Address.parse(host, 0) catch return false;
    return address.bytes[0] == 127;
}

/// Determine disclosure from an original source and cap it by earlier hops.
/// The source remains intact for cookie selection and document provenance.
pub fn determine(source_optional: anytype, target: anytype, policy: Policy, previous: Disclosure) Disclosure {
    const source = source_optional orelse return .none;
    if (!isHttp(source) or !isHttp(target) or previous == .none) return .none;
    const same_origin = source.sameOrigin(target);
    const downgrade = trustworthy(source) and !trustworthy(target);
    var result: Disclosure = switch (policy) {
        .no_referrer => .none,
        .same_origin => if (same_origin) .full else .none,
        .origin => .origin,
        .strict_origin => if (downgrade) .none else .origin,
        .origin_when_cross_origin => if (same_origin) .full else .origin,
        .default, .strict_origin_when_cross_origin => if (same_origin) .full else if (downgrade) .none else .origin,
        .no_referrer_when_downgrade => if (downgrade) .none else .full,
        .unsafe_url => .full,
    };
    const host: []const u8 = source.ada_url.getHost() orelse "";
    const search: []const u8 = source.ada_url.getSearch() orelse "";
    const length = source.scheme.len + 3 + host.len + source.ada_url.getPathname().len + search.len;
    if (result == .full and length > 4096) result = .origin;
    return @enumFromInt(@min(@intFromEnum(result), @intFromEnum(previous)));
}

/// Caller owns the returned value. Credentials and fragments never appear;
/// origins include the trailing slash, including canonical ports/IPv6 hosts.
pub fn serialize(allocator: std.mem.Allocator, source_optional: anytype, disclosure: Disclosure) !?[]u8 {
    const source = source_optional orelse return null;
    if (disclosure == .none or !isHttp(source)) return null;
    return try std.fmt.allocPrint(allocator, "{s}://{s}{s}{s}", .{
        source.scheme,
        source.ada_url.getHost() orelse return null,
        if (disclosure == .origin) "/" else source.ada_url.getPathname(),
        if (disclosure == .origin) "" else source.ada_url.getSearch() orelse "",
    });
}
