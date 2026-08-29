//! Tutorial cookie-jar parsing, ownership, script visibility, and expiry.
//!
//! The jar owns both normalized host keys and Entry values. HTTP and script
//! assignments share one transactional parser; HttpOnly and SameSite policy
//! are applied only at this boundary.

const std = @import("std");

pub const SameSiteMode = enum { none, lax };

pub const Entry = struct {
    value: []u8,
    // Owned Set-Cookie attributes without the leading semicolon. The tutorial
    // jar stores one cookie per host and exposes these parameters through
    // document.cookie unless the entry is HttpOnly.
    parameters: ?[]u8 = null,
    same_site: SameSiteMode = .none,
    http_only: bool = false,
    /// Absolute Unix time parsed from Expires. Null entries last for the
    /// browser session; expired entries are removed before any read.
    expires_at: ?i64 = null,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        if (self.parameters) |parameters| allocator.free(parameters);
        self.* = undefined;
    }
};

pub const Source = enum {
    http,
    script,
};

const ParsedCookie = struct {
    value: []const u8,
    parameters: ?[]const u8,
    same_site: SameSiteMode,
    http_only: bool,
    expires_at: ?i64,
};

fn cookieMonth(value: []const u8) ?u8 {
    const names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (names, 1..) |name, month| {
        if (std.ascii.eqlIgnoreCase(value, name)) return @intCast(month);
    }
    return null;
}

fn cookieDaysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        else => 0,
    };
}

/// Convert a civil UTC date to days since 1970-01-01. This is the inverse of
/// the standard epoch decomposition and also handles valid pre-epoch dates.
fn daysFromCivil(year_value: i64, month: u8, day: u8) i64 {
    var year = year_value;
    if (month <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const month_shift: i64 = if (month > 2) -3 else 9;
    const shifted_month: i64 = @as(i64, month) + month_shift;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + @as(i64, day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// Parse the IMF-fixdate form emitted by HTTP servers, for example
/// `Wed, 09 Jun 2021 10:18:14 GMT`. Invalid Expires attributes are ignored by
/// the cookie parser rather than rejecting an otherwise usable cookie.
pub fn parseCookieExpiration(value: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const date = if (std.mem.indexOfScalar(u8, trimmed, ',')) |comma|
        std.mem.trim(u8, trimmed[comma + 1 ..], " \t")
    else
        trimmed;

    var parts = std.mem.tokenizeAny(u8, date, " \t");
    const day_text = parts.next() orelse return null;
    const month_text = parts.next() orelse return null;
    const year_text = parts.next() orelse return null;
    const time_text = parts.next() orelse return null;
    const zone = parts.next() orelse return null;
    if (parts.next() != null or !std.ascii.eqlIgnoreCase(zone, "GMT")) return null;

    const day = std.fmt.parseInt(u8, day_text, 10) catch return null;
    const month = cookieMonth(month_text) orelse return null;
    var year = std.fmt.parseInt(i64, year_text, 10) catch return null;
    if (year_text.len == 2) year += if (year >= 70) 1900 else 2000;
    if (year < 1601 or year > 9999 or day == 0 or day > cookieDaysInMonth(year, month)) return null;

    var clock = std.mem.splitScalar(u8, time_text, ':');
    const hour = std.fmt.parseInt(u8, clock.next() orelse return null, 10) catch return null;
    const minute = std.fmt.parseInt(u8, clock.next() orelse return null, 10) catch return null;
    const second = std.fmt.parseInt(u8, clock.next() orelse return null, 10) catch return null;
    if (clock.next() != null or hour > 23 or minute > 59 or second > 59) return null;

    return daysFromCivil(year, month, day) * std.time.s_per_day +
        @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min + second;
}

fn parseSetCookie(value: []const u8) ?ParsedCookie {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    const semicolon = std.mem.indexOfScalar(u8, trimmed, ';');
    const cookie_value = std.mem.trim(
        u8,
        if (semicolon) |index| trimmed[0..index] else trimmed,
        " \t",
    );
    if (cookie_value.len == 0 or std.mem.indexOfScalar(u8, cookie_value, '=') == null) return null;

    const parameters = if (semicolon) |index| blk: {
        const attributes = std.mem.trim(u8, trimmed[index + 1 ..], " \t");
        break :blk if (attributes.len == 0) null else attributes;
    } else null;
    var same_site: SameSiteMode = .none;
    var http_only = false;
    var expires_at: ?i64 = null;
    if (parameters) |attributes| {
        var iterator = std.mem.tokenizeScalar(u8, attributes, ';');
        while (iterator.next()) |raw_attribute| {
            const attribute = std.mem.trim(u8, raw_attribute, " \t");
            if (attribute.len == 0) continue;
            if (std.mem.indexOfScalar(u8, attribute, '=')) |equals| {
                const key = std.mem.trim(u8, attribute[0..equals], " \t");
                const attribute_value = std.mem.trim(u8, attribute[equals + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(key, "samesite")) {
                    same_site = if (std.ascii.eqlIgnoreCase(attribute_value, "lax")) .lax else .none;
                } else if (std.ascii.eqlIgnoreCase(key, "expires")) {
                    expires_at = parseCookieExpiration(attribute_value);
                }
            } else if (std.ascii.eqlIgnoreCase(attribute, "samesite")) {
                same_site = .lax;
            } else if (std.ascii.eqlIgnoreCase(attribute, "httponly")) {
                http_only = true;
            }
        }
    }
    return .{
        .value = cookie_value,
        .parameters = parameters,
        .same_site = same_site,
        .http_only = http_only,
        .expires_at = expires_at,
    };
}

fn removeCookie(
    allocator: std.mem.Allocator,
    cookie_jar: *std.StringHashMap(Entry),
    host: []const u8,
) bool {
    const removed = cookie_jar.fetchRemove(host) orelse return false;
    var value = removed.value;
    value.deinit(allocator);
    allocator.free(removed.key);
    return true;
}

fn removeCookieIfExpired(
    allocator: std.mem.Allocator,
    cookie_jar: *std.StringHashMap(Entry),
    host: []const u8,
    now_seconds: i64,
) bool {
    const entry = cookie_jar.get(host) orelse return false;
    const expires_at = entry.expires_at orelse return false;
    if (expires_at > now_seconds) return false;
    return removeCookie(allocator, cookie_jar, host);
}

/// Parse and atomically install one tutorial-style cookie for a host. HTTP
/// responses may replace any entry. Script cannot create an HttpOnly entry or
/// replace an entry that the server marked HttpOnly.
pub fn applySetCookie(
    allocator: std.mem.Allocator,
    cookie_jar: *std.StringHashMap(Entry),
    host: []const u8,
    raw_value: []const u8,
    source: Source,
    now_seconds: i64,
) !bool {
    if (host.len == 0) return false;
    const parsed = parseSetCookie(raw_value) orelse return false;
    _ = removeCookieIfExpired(allocator, cookie_jar, host, now_seconds);
    if (source == .script and parsed.http_only) return false;
    if (source == .script) {
        if (cookie_jar.get(host)) |existing| {
            if (existing.http_only) return false;
        }
    }
    if (parsed.expires_at) |expires_at| {
        if (expires_at <= now_seconds) {
            _ = removeCookie(allocator, cookie_jar, host);
            return true;
        }
    }

    const value_copy = try allocator.dupe(u8, parsed.value);
    errdefer allocator.free(value_copy);
    const parameters_copy = if (parsed.parameters) |parameters|
        try allocator.dupe(u8, parameters)
    else
        null;
    errdefer if (parameters_copy) |parameters| allocator.free(parameters);

    const replacement = Entry{
        .value = value_copy,
        .parameters = parameters_copy,
        .same_site = parsed.same_site,
        .http_only = parsed.http_only,
        .expires_at = parsed.expires_at,
    };
    if (cookie_jar.getPtr(host)) |existing| {
        existing.deinit(allocator);
        existing.* = replacement;
        return true;
    }

    try cookie_jar.ensureUnusedCapacity(1);
    const host_copy = try allocator.dupe(u8, host);
    cookie_jar.putAssumeCapacity(host_copy, replacement);
    return true;
}

/// Return an independent script-visible serialization. HttpOnly entries are
/// indistinguishable from a missing cookie at this boundary.
pub fn cookieForScript(
    allocator: std.mem.Allocator,
    cookie_jar: *std.StringHashMap(Entry),
    host: []const u8,
    now_seconds: i64,
) ![]u8 {
    _ = removeCookieIfExpired(allocator, cookie_jar, host, now_seconds);
    const entry = cookie_jar.get(host) orelse return allocator.dupe(u8, "");
    if (entry.http_only) return allocator.dupe(u8, "");
    if (entry.parameters) |parameters| {
        return std.fmt.allocPrint(allocator, "{s}; {s}", .{ entry.value, parameters });
    }
    return allocator.dupe(u8, entry.value);
}

/// Select the Cookie request-header value. HttpOnly affects only script
/// visibility; it never prevents the browser from authenticating HTTP or XHR
/// requests. SameSite keeps its existing tutorial behavior.
pub fn cookieForRequest(
    allocator: std.mem.Allocator,
    cookie_jar: *std.StringHashMap(Entry),
    host: []const u8,
    method: std.http.Method,
    referrer_host: ?[]const u8,
    now_seconds: i64,
) ?[]const u8 {
    _ = removeCookieIfExpired(allocator, cookie_jar, host, now_seconds);
    const entry = cookie_jar.get(host) orelse return null;
    if (entry.same_site == .lax and method != .GET) {
        if (referrer_host) |ref_host| {
            if (!std.ascii.eqlIgnoreCase(host, ref_host)) return null;
        }
    }
    return entry.value;
}
