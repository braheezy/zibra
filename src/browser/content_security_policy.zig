//! Frame-owned response CSP lists and allocation-free subresource request checks.
//! This is the URL-source subset, not inline script/style or nonce enforcement.

const std = @import("std");
const Url = @import("../network/url.zig").Url;
const whitespace = " \t\n\r\x0c";

pub const Destination = enum { script, stylesheet, image, connect, frame, font };

const Directive = enum {
    @"default-src",
    @"script-src",
    @"script-src-elem",
    @"style-src",
    @"style-src-elem",
    @"img-src",
    @"connect-src",
    @"frame-src",
    @"child-src",
    @"font-src",
};

const Parsed = struct {
    sources: std.EnumArray(Directive, ?[]const u8) = .initFill(null),

    fn parse(text: []const u8) Parsed {
        var result: Parsed = .{};
        var directives = std.mem.tokenizeScalar(u8, text, ';');
        while (directives.next()) |raw| {
            var tokens = std.mem.tokenizeAny(u8, raw, whitespace);
            const name = tokens.next() orelse continue;
            inline for (std.meta.fields(Directive)) |field| {
                if (std.ascii.eqlIgnoreCase(name, field.name)) {
                    const directive: Directive = @enumFromInt(field.value);
                    // Duplicate directives do not replace the first occurrence,
                    // including an explicitly empty (deny-all) source list.
                    if (result.sources.get(directive) == null)
                        result.sources.set(directive, std.mem.trim(u8, tokens.rest(), whitespace));
                }
            }
        }
        return result;
    }

    fn list(self: *const Parsed, destination: Destination) ?[]const u8 {
        const fallback: []const Directive = switch (destination) {
            .script => &.{ .@"script-src-elem", .@"script-src", .@"default-src" },
            .stylesheet => &.{ .@"style-src-elem", .@"style-src", .@"default-src" },
            .frame => &.{ .@"frame-src", .@"child-src", .@"default-src" },
            .image => &.{ .@"img-src", .@"default-src" },
            .connect => &.{ .@"connect-src", .@"default-src" },
            .font => &.{ .@"font-src", .@"default-src" },
        };
        for (fallback) |directive| if (self.sources.get(directive)) |value| return value;
        return null;
    }
};

pub const Policy = struct {
    serialized: []u8,
    origin: Url,
    policies: std.ArrayList(Parsed),

    /// Copies both inputs. Parsed slices borrow only this owner's serialization;
    /// the protected origin never follows a document's later base-URL changes.
    pub fn init(allocator: std.mem.Allocator, header: []const u8, origin: *const Url) !Policy {
        const copy = try allocator.dupe(u8, header);
        errdefer allocator.free(copy);
        const owned_origin = try origin.clone(allocator);
        errdefer owned_origin.free(allocator);
        var policies = std.ArrayList(Parsed).empty;
        errdefer policies.deinit(allocator);
        var parts = std.mem.tokenizeScalar(u8, copy, ',');
        while (parts.next()) |part| try policies.append(allocator, Parsed.parse(part));
        return .{ .serialized = copy, .origin = owned_origin, .policies = policies };
    }

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        self.policies.deinit(allocator);
        self.origin.free(allocator);
        allocator.free(self.serialized);
        self.* = undefined;
    }

    /// Synchronous URL borrow. Every policy must allow the request. Redirected
    /// iframe destinations skip path matching, but still check scheme/host/port.
    pub fn allows(self: *const Policy, target: *const Url, destination: Destination, redirected: bool) bool {
        for (self.policies.items) |*policy| {
            const sources = policy.list(destination) orelse continue;
            var tokens = std.mem.tokenizeAny(u8, sources, whitespace);
            var matched = false;
            while (tokens.next()) |source| {
                // No nonce/trust metadata is available at this request seam.
                // Do not turn strict-dynamic into a permissive host allowlist.
                if (destination == .script and std.ascii.eqlIgnoreCase(source, "'strict-dynamic'")) return false;
                matched = matches(source, &self.origin, target, redirected) or matched;
            }
            if (!matched) return false;
        }
        return true;
    }
};

fn schemeMatches(source: []const u8, target: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(source, target)) return true;
    if (std.ascii.eqlIgnoreCase(source, "http")) return std.mem.eql(u8, target, "https");
    if (std.ascii.eqlIgnoreCase(source, "ws"))
        return std.mem.eql(u8, target, "wss") or std.mem.eql(u8, target, "http") or std.mem.eql(u8, target, "https");
    return std.ascii.eqlIgnoreCase(source, "wss") and std.mem.eql(u8, target, "https");
}

fn validScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    return true;
}

fn defaultPort(scheme: []const u8) ?u16 {
    if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "ws")) return 80;
    if (std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "wss")) return 443;
    if (std.mem.eql(u8, scheme, "ftp")) return 21;
    return null;
}

fn urlPort(url: *const Url) ?u16 {
    // Use Ada's port, not the facade's HTTP-centric default for other schemes.
    if (url.ada_url.getPort()) |value| return std.fmt.parseInt(u16, value, 10) catch null;
    return defaultPort(url.scheme);
}

fn matches(source: []const u8, origin: *const Url, target: *const Url, redirected: bool) bool {
    if (std.mem.eql(u8, source, "*"))
        return std.mem.eql(u8, target.scheme, "http") or std.mem.eql(u8, target.scheme, "https") or
            std.mem.eql(u8, target.scheme, origin.scheme);
    if (std.ascii.eqlIgnoreCase(source, "'self'")) {
        const origin_host = origin.ada_url.getHostname() orelse return false;
        const target_host = target.ada_url.getHostname() orelse return false;
        if (origin_host.len == 0 or !std.ascii.eqlIgnoreCase(origin_host, target_host)) return false;
        const same_port = urlPort(origin) == urlPort(target);
        if (same_port and std.mem.eql(u8, origin.scheme, target.scheme)) return true;
        if (!same_port and !(urlPort(origin) == defaultPort(origin.scheme) and urlPort(target) == defaultPort(target.scheme))) return false;
        return std.mem.eql(u8, target.scheme, "https") or std.mem.eql(u8, target.scheme, "wss") or
            (std.mem.eql(u8, origin.scheme, "http") and
                (std.mem.eql(u8, target.scheme, "http") or std.mem.eql(u8, target.scheme, "ws")));
    }
    // Keywords (including 'none' and 'unsafe-inline'), nonces and hashes do not
    // grant URL permissions. Invalid source expressions cannot broaden a list.
    if (source.len == 0 or source[0] == '\'') return false;
    if (std.mem.endsWith(u8, source, ":")) {
        const scheme = source[0 .. source.len - 1];
        return validScheme(scheme) and schemeMatches(scheme, target.scheme);
    }
    var remainder = source;
    var scheme = origin.scheme;
    if (std.mem.indexOf(u8, source, "://")) |separator| {
        scheme = source[0..separator];
        if (!validScheme(scheme)) return false;
        remainder = source[separator + 3 ..];
    }
    if (!schemeMatches(scheme, target.scheme)) return false;
    const slash = std.mem.indexOfScalar(u8, remainder, '/') orelse remainder.len;
    const authority = remainder[0..slash];
    const path = remainder[slash..];
    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..colon];
    const target_host = target.ada_url.getHostname() orelse return false;
    if (!hostMatches(host, target_host)) return false;
    if (colon < authority.len) {
        const port = authority[colon + 1 ..];
        if (!std.mem.eql(u8, port, "*")) {
            if (port.len == 0) return false;
            for (port) |ch| if (!std.ascii.isDigit(ch)) return false;
            const parsed_port = std.fmt.parseInt(u16, port, 10) catch return false;
            if (urlPort(target) != parsed_port) return false;
        }
    } else if (target.ada_url.getPort() != null) return false;
    // Query/fragment are not part of the CSP host-source grammar.
    if (std.mem.indexOfAny(u8, path, "?#\\") != null) return false;
    return redirected or pathMatches(path, target.path);
}

fn hostMatches(pattern: []const u8, host: []const u8) bool {
    if (host.len == 0 or pattern.len == 0) return false;
    const suffix = if (std.mem.startsWith(u8, pattern, "*.")) pattern[2..] else pattern;
    if (!std.mem.eql(u8, pattern, "*")) {
        if (suffix.len == 0) return false;
        for (suffix) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '.') return false;
    }
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.startsWith(u8, pattern, "*.")) {
        return host.len > suffix.len + 1 and host[host.len - suffix.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(suffix, host[host.len - suffix.len ..]);
    }
    return std.ascii.eqlIgnoreCase(pattern, host);
}

fn nextDecoded(text: []const u8, index: *usize) ?u8 {
    if (index.* == text.len) return null;
    const ch = text[index.*];
    if (ch == '%' and index.* + 2 < text.len and
        std.ascii.isHex(text[index.* + 1]) and std.ascii.isHex(text[index.* + 2]))
    {
        // parseInt accepts signs; URL percent escapes require two hex digits.
        const byte = std.fmt.parseInt(u8, text[index.* + 1 .. index.* + 3], 16) catch unreachable;
        index.* += 3;
        return byte;
    }
    index.* += 1;
    return ch;
}

fn decodedEqual(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (nextDecoded(a, &ai)) |byte| if (nextDecoded(b, &bi) != byte) return false;
    return bi == b.len;
}

fn pathMatches(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return true;
    const prefix = std.mem.endsWith(u8, pattern, "/");
    var source_parts = std.mem.splitScalar(u8, pattern, '/');
    var target_parts = std.mem.splitScalar(u8, path, '/');
    while (source_parts.next()) |part| {
        const target_part = target_parts.next() orelse return false;
        if (prefix and source_parts.peek() == null) return true;
        if (!decodedEqual(part, target_part)) return false;
    }
    return target_parts.next() == null;
}
