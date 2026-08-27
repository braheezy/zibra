//! Owning URL representation, relative resolution, and resource loading.
//!
//! `Url` is an owning value even though Zig permits copying it: exactly one
//! logical copy must be passed to `free`. Its component slices are backed by
//! the owned Ada URL, except for data-URL storage allocated by `init`; callers
//! must pass the same allocator to `free` for those allocations.

const std = @import("std");

const ada = @import("ada");
const cache_module = @import("cache.zig");
const Mutex = @import("../runtime/sync.zig").Mutex;

pub const CacheControl = cache_module.CacheControl;
pub const HttpCache = cache_module.HttpCache;
pub const ReferrerPolicy = cache_module.ReferrerPolicy;
pub const XFrameOptions = cache_module.XFrameOptions;

const user_agent = "Zibra/0.0.0";
const redirect_limit: u16 = 3;

fn requestOptions(
    redirect_behavior: std.http.Client.Request.RedirectBehavior,
    extra_headers: []const std.http.Header,
) std.http.Client.RequestOptions {
    return .{
        .version = .@"HTTP/1.1",
        // A long-lived Browser owns this client, so fully consumed responses
        // can return their connections to Zig's per-origin pool.
        .keep_alive = true,
        .redirect_behavior = redirect_behavior,
        .headers = .{
            .user_agent = .{ .override = user_agent },
            // Compression support is part of Zibra's HTTP contract rather
            // than an incidental std.http default. Keep negotiation aligned
            // with the encoding handled by the browser-engineering exercise.
            .accept_encoding = .{ .override = "gzip" },
        },
        .extra_headers = extra_headers,
    };
}

pub const SameSiteMode = enum { none, lax };

pub const CookieEntry = struct {
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

    pub fn deinit(self: *CookieEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        if (self.parameters) |parameters| allocator.free(parameters);
        self.* = undefined;
    }
};

pub const CookieSource = enum {
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
    cookie_jar: *std.StringHashMap(CookieEntry),
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
    cookie_jar: *std.StringHashMap(CookieEntry),
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
    cookie_jar: *std.StringHashMap(CookieEntry),
    host: []const u8,
    raw_value: []const u8,
    source: CookieSource,
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

    const replacement = CookieEntry{
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
    cookie_jar: *std.StringHashMap(CookieEntry),
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
    cookie_jar: *std.StringHashMap(CookieEntry),
    host: []const u8,
    method: std.http.Method,
    referrer: ?Url,
    now_seconds: i64,
) ?[]const u8 {
    _ = removeCookieIfExpired(allocator, cookie_jar, host, now_seconds);
    const entry = cookie_jar.get(host) orelse return null;
    if (entry.same_site == .lax and method != .GET) {
        if (referrer) |ref| {
            const ref_host = ref.host orelse return null;
            if (!std.ascii.eqlIgnoreCase(host, ref_host)) return null;
        }
    }
    return entry.value;
}

pub const HttpResponse = struct {
    body: []const u8,
    csp_header: ?[]u8 = null,
    /// Owned only for requests that supplied an Origin header. Ordinary
    /// navigation/subresource responses leave this null.
    access_control_allow_origin: ?[]u8 = null,
    status: ?std.http.Status = null,
    cache_control: CacheControl = .default,
    referrer_policy: ReferrerPolicy = .default,
    x_frame_options: XFrameOptions = .none,
};

/// Parse the two response policy tokens supported by this exercise. Unknown
/// values are ignored so they do not accidentally become more permissive than
/// a recognized policy from another header line.
pub fn parseReferrerPolicy(value: []const u8) ?ReferrerPolicy {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "no-referrer")) return .no_referrer;
    if (std.ascii.eqlIgnoreCase(trimmed, "same-origin")) return .same_origin;
    return null;
}

/// Parse the supported framing directives. Header field values are
/// case-insensitive, and repeated field lines may arrive comma-combined.
/// Recognized policies are merged restrictively; obsolete ALLOW-FROM and
/// unknown tokens are ignored like current browsers do.
pub fn parseXFrameOptions(value: []const u8) ?XFrameOptions {
    var parsed: ?XFrameOptions = null;
    var directives = std.mem.splitScalar(u8, value, ',');
    while (directives.next()) |raw_directive| {
        const directive = std.mem.trim(u8, raw_directive, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(directive, "deny")) return .deny;
        if (std.ascii.eqlIgnoreCase(directive, "sameorigin")) {
            parsed = .same_origin;
        }
    }
    return parsed;
}

fn mergeXFrameOptions(
    current: XFrameOptions,
    incoming: XFrameOptions,
) XFrameOptions {
    if (current == .deny or incoming == .deny) return .deny;
    if (current == .same_origin or incoming == .same_origin) return .same_origin;
    return .none;
}

/// Same-origin XHR needs no response opt-in. Cross-origin XHR exposes its body
/// only when the server returns the caller's exact serialized origin or `*`.
pub fn corsAllowsResponse(
    request_origin: ?[]const u8,
    access_control_allow_origin: ?[]const u8,
) bool {
    const origin = request_origin orelse return true;
    const allowed = access_control_allow_origin orelse return false;
    const trimmed = std.mem.trim(u8, allowed, " \t\r\n");
    return std.mem.eql(u8, trimmed, "*") or std.mem.eql(u8, trimmed, origin);
}

/// Decode bytes as UTF-8, replacing each malformed sequence with U+FFFD.
/// The returned buffer is owned by `allocator`.
pub fn decodeUtf8Replace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const replacement = "\xEF\xBF\xBD";
    var i: usize = 0;
    while (i < input.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(input[i]) catch {
            try output.appendSlice(allocator, replacement);
            i += 1;
            continue;
        };

        if (i + seq_len > input.len) {
            try output.appendSlice(allocator, replacement);
            break;
        }

        const slice = input[i .. i + seq_len];
        if (std.unicode.utf8ValidateSlice(slice)) {
            try output.appendSlice(allocator, slice);
            i += seq_len;
        } else {
            try output.appendSlice(allocator, replacement);
            i += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

fn percentByte(input: []const u8) ?u8 {
    return std.fmt.parseInt(u8, input, 16) catch null;
}

/// Decode valid percent escapes while preserving malformed escapes verbatim.
/// The returned buffer is owned by `allocator`.
fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var decoded_len: usize = 0;
    var input_index: usize = 0;
    while (input_index < input.len) {
        if (input_index + 2 < input.len and input[input_index] == '%' and
            percentByte(input[input_index + 1 .. input_index + 3]) != null)
        {
            input_index += 3;
        } else {
            input_index += 1;
        }
        decoded_len += 1;
    }

    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);

    input_index = 0;
    var output_index: usize = 0;
    while (input_index < input.len) : (output_index += 1) {
        if (input_index + 2 < input.len and input[input_index] == '%') {
            if (percentByte(input[input_index + 1 .. input_index + 3])) |byte| {
                decoded[output_index] = byte;
                input_index += 3;
                continue;
            }
        }

        decoded[output_index] = input[input_index];
        input_index += 1;
    }

    return decoded;
}

// Note: Connection handling is now done by std.http.Client
// which handles both HTTP and HTTPS automatically with TLS support

pub const Url = struct {
    ada_url: ada.Url,
    scheme: []const u8 = undefined,
    host: ?[]const u8 = null,
    path: []const u8 = undefined,
    port: u16 = 80,
    is_https: bool = false,
    mime_type: ?[]const u8 = null,
    attributes: ?std.ArrayList([]const u8) = null,
    view_source: bool = false,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !Url {
        const ada_url = try ada.Url.init(url);

        var u = Url{ .ada_url = ada_url };
        errdefer u.ada_url.free();

        // Get the protocol (e.g., "https:") and strip the trailing colon
        const protocol = ada_url.getProtocol();
        u.scheme = if (std.mem.endsWith(u8, protocol, ":"))
            protocol[0 .. protocol.len - 1]
        else
            protocol;

        u.host = ada_url.getHost();
        u.path = ada_url.getPathname();
        u.is_https = std.mem.eql(u8, u.scheme, "https");
        if (ada_url.getPort()) |port_slice| {
            const parsed = std.fmt.parseInt(u16, port_slice, 10) catch 0;
            if (parsed != 0) {
                u.port = parsed;
            } else {
                u.port = if (u.is_https) 443 else 80;
            }
        } else {
            u.port = if (u.is_https) 443 else 80;
        }
        if (std.mem.eql(u8, u.scheme, "view-source")) {
            u.view_source = true;

            // Extract the actual URL after view-source:
            const actual_url = url[std.mem.indexOf(u8, url, ":").? + 1 ..];

            // Replace the wrapper URL with the URL whose component slices we
            // expose. Keeping the original owner here left all component
            // slices dangling and caused `free` to release it a second time.
            const actual_ada_url = ada.Url.init(actual_url) catch |err| {
                return err;
            };
            u.ada_url.free();
            u.ada_url = actual_ada_url;

            // Update the URL properties with the actual URL's properties (strip colon)
            const actual_protocol = u.ada_url.getProtocol();
            u.scheme = if (std.mem.endsWith(u8, actual_protocol, ":"))
                actual_protocol[0 .. actual_protocol.len - 1]
            else
                actual_protocol;

            u.host = u.ada_url.getHost();
            u.path = u.ada_url.getPathname();
            u.is_https = std.mem.eql(u8, u.scheme, "https");
            u.port = if (u.is_https) 443 else 80;
        }

        if (std.mem.eql(u8, u.scheme, "data")) {
            // ! ada will eventually support parsing data urls
            // ! https://github.com/ada-url/ada/pull/756/
            // Parse the inner Ada URL so `view-source:data:` works, and keep
            // the fragment out of the response body.
            const data_url = hrefWithoutFragment(u.ada_url.getHref());
            const colon_index = std.mem.indexOfScalar(u8, data_url, ':') orelse return error.DataUriBadFormat;
            var rest = data_url[colon_index + 1 ..];

            // find the first comma, everything after is the data
            var data: []const u8 = undefined;
            if (std.mem.indexOf(u8, rest, ",")) |comma_index| {
                data = rest[comma_index + 1 ..];
                rest = rest[0..comma_index];
            } else {
                return error.DataUriBadFormat;
            }
            // split on ';' to find the mime type and attributes
            var split_iter = std.mem.splitSequence(u8, rest, ";");
            const mime_type = split_iter.first();
            var attributes = std.ArrayList([]const u8).empty;
            errdefer {
                for (attributes.items) |attribute| allocator.free(attribute);
                attributes.deinit(allocator);
            }
            var is_base64 = false;
            while (split_iter.next()) |attr| {
                if (std.ascii.eqlIgnoreCase(attr, "base64")) {
                    is_base64 = true;
                }
                {
                    const attribute = try allocator.dupe(u8, attr);
                    errdefer allocator.free(attribute);
                    try attributes.append(allocator, attribute);
                }
            }
            // Allocate memory for strings.
            const mime_type_alloc = try allocator.alloc(u8, mime_type.len);
            errdefer allocator.free(mime_type_alloc);
            @memcpy(mime_type_alloc, mime_type);

            const percent_decoded = try percentDecodeAlloc(allocator, data);
            errdefer allocator.free(percent_decoded);

            const data_alloc = if (is_base64) blk: {
                const decoder = &std.base64.standard.Decoder;
                const decoded_len = try decoder.calcSizeForSlice(percent_decoded);
                const decoded = try allocator.alloc(u8, decoded_len);
                errdefer allocator.free(decoded);
                try decoder.decode(decoded, percent_decoded);
                allocator.free(percent_decoded);
                break :blk decoded;
            } else blk: {
                break :blk percent_decoded;
            };
            errdefer allocator.free(data_alloc);

            u.path = data_alloc;
            u.mime_type = mime_type_alloc;
            if (attributes.items.len > 0) {
                u.attributes = attributes;
            } else {
                attributes.deinit(allocator);
            }
        }
        return u;
    }

    /// Construct the canonical empty document URL.
    pub fn blank(allocator: std.mem.Allocator) !Url {
        return init(allocator, "about:blank");
    }

    pub fn isAboutBlank(self: Url) bool {
        return std.mem.eql(u8, self.scheme, "about") and
            std.mem.eql(u8, self.path, "blank");
    }

    pub fn isAboutBookmarks(self: Url) bool {
        return std.mem.eql(u8, self.scheme, "about") and
            std.mem.eql(u8, self.path, "bookmarks");
    }

    /// Return whether `input` begins with an RFC-style URL scheme.
    pub fn hasExplicitScheme(input: []const u8) bool {
        const colon = std.mem.indexOfScalar(u8, input, ':') orelse return false;
        if (colon == 0 or !std.ascii.isAlphabetic(input[0])) return false;
        for (input[1..colon]) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') {
                return false;
            }
        }
        return true;
    }

    /// Parse a user- or document-initiated navigation target. URL syntax and
    /// payload-format failures recover to `about:blank`; resource exhaustion
    /// remains visible to the caller.
    pub fn initForNavigation(allocator: std.mem.Allocator, input: []const u8) !Url {
        const parsed = init(allocator, input) catch |err| {
            return recoverNavigationError(allocator, err);
        };
        return normalizeNavigation(allocator, parsed);
    }

    fn recoverNavigationError(allocator: std.mem.Allocator, err: anyerror) !Url {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return blank(allocator);
    }

    fn normalizeNavigation(allocator: std.mem.Allocator, parsed: Url) !Url {
        const supported = std.mem.eql(u8, parsed.scheme, "http") or
            std.mem.eql(u8, parsed.scheme, "https") or
            std.mem.eql(u8, parsed.scheme, "file") or
            std.mem.eql(u8, parsed.scheme, "data") or
            parsed.isAboutBlank() or
            parsed.isAboutBookmarks();
        if (!supported) {
            parsed.free(allocator);
            return blank(allocator);
        }
        return parsed;
    }

    pub fn free(self: Url, allocator: std.mem.Allocator) void {
        if (self.mime_type) |_| allocator.free(self.mime_type.?);
        if (std.mem.eql(u8, self.scheme, "data")) {
            allocator.free(self.path);
        }
        if (self.attributes) |attrs| {
            var a = attrs;
            for (a.items) |attribute| allocator.free(attribute);
            a.deinit(allocator);
        }
        self.ada_url.free();
    }

    /// Return an independently owned copy of this URL.
    ///
    /// A plain Zig assignment only copies the Ada handle and therefore must
    /// never be used when both values can outlive the same owner.
    pub fn clone(self: Url, allocator: std.mem.Allocator) !Url {
        var result = try Url.init(allocator, self.ada_url.getHref());
        result.view_source = self.view_source;
        return result;
    }

    /// Return the URL fragment without its leading `#`. An explicitly empty
    /// fragment is returned as an empty slice; a URL with no fragment returns
    /// null. The slice borrows this URL's Ada backing storage.
    pub fn fragment(self: Url) ?[]const u8 {
        if (!self.ada_url.hasHash()) return null;
        const hash = self.ada_url.getHash() orelse return "";
        return if (hash.len > 0 and hash[0] == '#') hash[1..] else hash;
    }

    /// Compare complete URL identity except for the fragment component.
    pub fn sameDocument(self: Url, other: Url) bool {
        if (self.view_source != other.view_source) return false;
        return std.mem.eql(
            u8,
            hrefWithoutFragment(self.ada_url.getHref()),
            hrefWithoutFragment(other.ada_url.getHref()),
        );
    }

    /// Resolve a relative URL against this URL
    /// Handles:
    /// - Absolute URLs with a scheme (returned as-is)
    /// - Host-relative URLs starting with "/" (reuse scheme and host)
    /// - Path-relative URLs (resolve relative to current path)
    /// - Scheme-relative URLs starting with "//" (reuse scheme)
    /// - Parent directory navigation with "../"
    pub fn resolve(self: Url, allocator: std.mem.Allocator, relative_url: []const u8) !Url {
        // If it is already an absolute URL, parse it without combining it
        // with the current path. This includes schemes without `//`, such as
        // data, about, and mailto.
        if (hasExplicitScheme(relative_url)) {
            return try Url.init(allocator, relative_url);
        }

        // Delegate relative-reference semantics to Ada. Besides simplifying
        // path resolution, this preserves the current query for `#fragment`
        // references and replaces only the fragment component.
        const resolved_ada = try ada.Url.initWithBase(relative_url, self.ada_url.getHref());
        defer resolved_ada.free();
        var resolved = try Url.init(allocator, resolved_ada.getHref());
        resolved.view_source = self.view_source;
        return resolved;
    }

    /// Resolve a navigation target, recovering malformed results to the
    /// canonical blank document while preserving allocation failures.
    pub fn resolveForNavigation(self: Url, allocator: std.mem.Allocator, relative_url: []const u8) !Url {
        const resolved = self.resolve(allocator, relative_url) catch |err| {
            return recoverNavigationError(allocator, err);
        };
        return normalizeNavigation(allocator, resolved);
    }

    /// Determine if two URLs share the same origin (scheme, host, and port)
    pub fn sameOrigin(self: Url, other: Url) bool {
        if (!std.mem.eql(u8, self.scheme, other.scheme)) return false;

        const host_self_opt = self.host;
        const host_other_opt = other.host;

        if (host_self_opt) |host_self| {
            const host_other = host_other_opt orelse return false;
            if (!std.ascii.eqlIgnoreCase(host_self, host_other)) return false;
        } else if (host_other_opt != null) {
            return false;
        }

        return self.port == other.port;
    }

    /// Allocate the serialized origin used by the HTTP Origin header and CORS
    /// response comparison. Hostless sources have an opaque `null` origin.
    pub fn toOwnedOrigin(self: Url, allocator: std.mem.Allocator) ![]u8 {
        const host = self.host orelse return allocator.dupe(u8, "null");
        const uses_default_port =
            (std.ascii.eqlIgnoreCase(self.scheme, "http") and self.port == 80) or
            (std.ascii.eqlIgnoreCase(self.scheme, "https") and self.port == 443);
        if (uses_default_port or hostHasExplicitPort(host)) {
            return std.fmt.allocPrint(allocator, "{s}://{s}", .{ self.scheme, host });
        }
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ self.scheme, host, self.port });
    }

    fn hostHasExplicitPort(host: []const u8) bool {
        if (std.mem.startsWith(u8, host, "[")) {
            const close = std.mem.indexOfScalar(u8, host, ']') orelse return false;
            return close + 1 < host.len and host[close + 1] == ':';
        }
        return std.mem.lastIndexOfScalar(u8, host, ':') != null;
    }

    fn hrefWithoutFragment(href: []const u8) []const u8 {
        const index = std.mem.indexOfScalar(u8, href, '#') orelse return href;
        return href[0..index];
    }

    // Old HTTP helper functions removed - std.http.Client handles this now

    pub fn aboutRequest(self: Url) []const u8 {
        _ = self;
        return "";
    }

    /// Fetch a URL without imposing browser/window ownership. Callers own the
    /// returned response according to its scheme: file and HTTP bodies are
    /// allocated, while data and about bodies borrow the URL/static storage.
    pub fn fetchBody(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
    ) !HttpResponse {
        return fetchBodyInternal(allocator, io, http_client, cookie_jar, cache, null, url, referrer, payload, null, null, .default);
    }

    /// Fetch with the source document's policy controlling only the outbound
    /// Referer header. The unsuppressed source URL remains available to cookie
    /// SameSite checks and other request-context decisions.
    pub fn fetchBodyWithReferrerPolicy(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        referrer_policy: ReferrerPolicy,
    ) !HttpResponse {
        return fetchBodyInternal(allocator, io, http_client, cookie_jar, cache, null, url, referrer, payload, null, null, referrer_policy);
    }

    /// Browser-session variant which serializes only shared cookie/cache map
    /// access. `std.http.Client` opens connections thread-safely, so callers
    /// may execute independent requests concurrently through one client.
    pub fn fetchBodyWithReferrerPolicySynchronized(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        network_lock: *Mutex,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        referrer_policy: ReferrerPolicy,
    ) !HttpResponse {
        return fetchBodyInternal(allocator, io, http_client, cookie_jar, cache, network_lock, url, referrer, payload, null, null, referrer_policy);
    }

    /// Fetch an XHR while attaching the caller's serialized origin. CORS
    /// requests intentionally bypass the ordinary response cache so access
    /// permission is decided from the current network response.
    pub fn fetchBodyWithOrigin(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        request_origin: []const u8,
    ) !HttpResponse {
        return fetchBodyWithOriginAndReferrerPolicy(
            allocator,
            io,
            http_client,
            cookie_jar,
            cache,
            url,
            referrer,
            payload,
            request_origin,
            .default,
        );
    }

    pub fn fetchBodyWithOriginAndReferrerPolicySynchronized(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        network_lock: *Mutex,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        request_origin: []const u8,
        referrer_policy: ReferrerPolicy,
    ) !HttpResponse {
        return fetchBodyInternal(
            allocator,
            io,
            http_client,
            cookie_jar,
            cache,
            network_lock,
            url,
            referrer,
            payload,
            null,
            request_origin,
            referrer_policy,
        );
    }

    pub fn fetchBodyWithOriginAndReferrerPolicy(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        request_origin: []const u8,
        referrer_policy: ReferrerPolicy,
    ) !HttpResponse {
        return fetchBodyInternal(
            allocator,
            io,
            http_client,
            cookie_jar,
            cache,
            null,
            url,
            referrer,
            payload,
            null,
            request_origin,
            referrer_policy,
        );
    }

    /// Fetch a URL and, for HTTP(S), return the final URL after redirects.
    /// The caller owns a non-null `final_url` and must free or move it.
    pub fn fetchBodyWithFinalUrl(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: *?Url,
    ) !HttpResponse {
        return fetchBodyWithFinalUrlAndReferrerPolicy(
            allocator,
            io,
            http_client,
            cookie_jar,
            cache,
            url,
            referrer,
            payload,
            final_url,
            .default,
        );
    }

    pub fn fetchBodyWithFinalUrlAndReferrerPolicy(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: *?Url,
        referrer_policy: ReferrerPolicy,
    ) !HttpResponse {
        final_url.* = null;
        return fetchBodyInternal(allocator, io, http_client, cookie_jar, cache, null, url, referrer, payload, final_url, null, referrer_policy);
    }

    pub fn fetchBodyWithFinalUrlAndReferrerPolicySynchronized(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        network_lock: *Mutex,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: *?Url,
        referrer_policy: ReferrerPolicy,
    ) !HttpResponse {
        final_url.* = null;
        return fetchBodyInternal(allocator, io, http_client, cookie_jar, cache, network_lock, url, referrer, payload, final_url, null, referrer_policy);
    }

    /// Zig's HTTP client maps TLS handshake-init failures, including
    /// certificate verification failures, to this public error. Keep that
    /// transport detail here so navigation can distinguish a security warning
    /// from ordinary DNS, connection, and HTTP failures.
    pub fn isCertificateError(err: anyerror) bool {
        return err == error.TlsInitializationFailed;
    }

    fn fetchBodyInternal(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        cache: ?*HttpCache,
        network_lock: ?*Mutex,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: ?*?Url,
        request_origin: ?[]const u8,
        referrer_policy: ReferrerPolicy,
    ) !HttpResponse {
        if (std.mem.eql(u8, url.scheme, "file")) {
            return .{ .body = try url.fileRequest(allocator, io) };
        }
        if (std.mem.eql(u8, url.scheme, "data")) {
            return .{ .body = url.path };
        }
        if (std.mem.eql(u8, url.scheme, "about")) {
            return .{ .body = url.aboutRequest() };
        }

        const is_http = std.mem.eql(u8, url.scheme, "http") or std.mem.eql(u8, url.scheme, "https");
        if (!is_http) return error.UnsupportedScheme;
        const use_cache = is_http and payload == null and cache != null and request_origin == null;
        const href = url.ada_url.getHref();
        const cache_key = if (std.mem.indexOfScalar(u8, href, '#')) |fragment_index| href[0..fragment_index] else href;

        if (use_cache) {
            const cached_response: ?HttpResponse = cache_lookup: {
                if (network_lock) |lock| lock.lock();
                defer if (network_lock) |lock| lock.unlock();

                const lookup_time_ns = std.Io.Clock.awake.now(io).nanoseconds;
                if (cache.?.lookup(cache_key, lookup_time_ns)) |entry| {
                    var cached_final_url: ?Url = null;
                    errdefer if (cached_final_url) |resolved| resolved.free(allocator);
                    if (final_url != null) {
                        if (entry.final_url) |final_url_text| {
                            cached_final_url = try Url.init(allocator, final_url_text);
                            cached_final_url.?.view_source = url.view_source;
                            try inheritFragment(allocator, url, &cached_final_url.?);
                        }
                    }

                    const body = try allocator.dupe(u8, entry.body);
                    errdefer allocator.free(body);
                    const csp_header = if (entry.csp_header) |header| try allocator.dupe(u8, header) else null;
                    errdefer if (csp_header) |header| allocator.free(header);

                    if (final_url) |output| {
                        output.* = cached_final_url;
                        cached_final_url = null;
                    }
                    break :cache_lookup .{
                        .body = body,
                        .csp_header = csp_header,
                        .status = .ok,
                        .cache_control = entry.policy,
                        .referrer_policy = entry.referrer_policy,
                        .x_frame_options = entry.x_frame_options,
                    };
                }
                break :cache_lookup null;
            };
            if (cached_response) |response| return response;
        }

        var fetched_final_url: ?Url = null;
        defer if (fetched_final_url) |resolved| resolved.free(allocator);
        const final_url_output = if (use_cache or final_url != null) &fetched_final_url else null;
        const response = try url.httpRequest(
            allocator,
            http_client,
            cookie_jar,
            network_lock,
            referrer,
            payload,
            final_url_output,
            request_origin,
            referrer_policy,
        );

        if (use_cache and response.status == .ok and response.cache_control.isCacheable()) {
            const final_url_text = if (fetched_final_url) |resolved| resolved.ada_url.getHref() else null;
            if (network_lock) |lock| lock.lock();
            cache.?.store(
                cache_key,
                response.body,
                response.csp_header,
                final_url_text,
                response.cache_control,
                response.referrer_policy,
                response.x_frame_options,
                std.Io.Clock.awake.now(io).nanoseconds,
            ) catch |err| {
                std.log.warn("Failed to cache {s}: {}", .{ cache_key, err });
            };
            if (network_lock) |lock| lock.unlock();
        }

        if (final_url) |output| {
            if (fetched_final_url) |*resolved| try inheritFragment(allocator, url, resolved);
            output.* = fetched_final_url;
            fetched_final_url = null;
        }
        return response;
    }

    pub fn httpRequest(
        self: Url,
        al: std.mem.Allocator,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        network_lock: ?*Mutex,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: ?*?Url,
        request_origin: ?[]const u8,
        referrer_policy: ReferrerPolicy,
    ) !HttpResponse {
        // Build full URL for std.http.Client
        var url_builder = std.ArrayList(u8).empty;
        defer url_builder.deinit(al);
        try url_builder.appendSlice(al, self.scheme);
        try url_builder.appendSlice(al, "://");
        const host_str = self.host.?;
        try url_builder.appendSlice(al, host_str);
        if (!hostHasExplicitPort(host_str) and self.port != 80 and self.port != 443) {
            try url_builder.append(al, ':');
            const port_str = try std.fmt.allocPrint(al, "{d}", .{self.port});
            defer al.free(port_str);
            try url_builder.appendSlice(al, port_str);
        }
        try url_builder.appendSlice(al, self.path);
        if (self.ada_url.getSearch()) |search| {
            try url_builder.appendSlice(al, search);
        }
        const url_str = try url_builder.toOwnedSlice(al);
        defer al.free(url_str);

        const uri = try std.Uri.parse(url_str);

        const method_str = if (payload != null) "POST" else "GET";
        std.log.info("{s} {s}", .{ method_str, url_str });

        // Keep optional headers in a growable list so adding another request
        // header does not require resizing and manually indexing fixed storage.
        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(al);
        const method: std.http.Method = if (payload != null) .POST else .GET;

        if (request_origin) |origin| {
            try extra_headers.append(al, .{
                .name = "Origin",
                .value = origin,
            });
        }

        if (refererHeaderValue(referrer, self, referrer_policy)) |referer| {
            try extra_headers.append(al, .{
                .name = "Referer",
                .value = referer,
            });
        }

        var cookie_header_value: ?[]u8 = null;
        defer if (cookie_header_value) |value| al.free(value);
        if (self.host) |host_slice| {
            cookie_header_value = cookie_snapshot: {
                if (network_lock) |lock| lock.lock();
                defer if (network_lock) |lock| lock.unlock();
                const value = cookieForRequest(
                    al,
                    cookie_jar,
                    host_slice,
                    method,
                    referrer,
                    std.Io.Clock.real.now(http_client.io).toSeconds(),
                ) orelse break :cookie_snapshot null;
                break :cookie_snapshot try al.dupe(u8, value);
            };
            if (cookie_header_value) |cookie_value| {
                try extra_headers.append(al, .{
                    .name = "Cookie",
                    .value = cookie_value,
                });
            }
        }

        if (payload != null) {
            try extra_headers.append(al, .{
                .name = "Content-Type",
                .value = "application/x-www-form-urlencoded",
            });
        }

        const RedirectBehavior = std.http.Client.Request.RedirectBehavior;
        const redirect_behavior: RedirectBehavior = if (payload == null)
            RedirectBehavior.init(redirect_limit)
        else
            .unhandled;

        var csp_header: ?[]u8 = null;
        var csp_header_cleanup = true;
        defer if (csp_header_cleanup) if (csp_header) |hdr| al.free(hdr);
        var access_control_allow_origin: ?[]u8 = null;
        var access_control_allow_origin_cleanup = true;
        defer if (access_control_allow_origin_cleanup) if (access_control_allow_origin) |hdr| al.free(hdr);
        var cache_control: CacheControl = .default;
        var response_referrer_policy: ReferrerPolicy = .default;
        var response_x_frame_options: XFrameOptions = .none;

        const max_attempts: usize = 2;
        var attempt: usize = 0;
        var redirect_buffer: [8 * 1024]u8 = undefined;

        request_loop: while (attempt < max_attempts) : (attempt += 1) {
            var req = try http_client.request(
                method,
                uri,
                requestOptions(redirect_behavior, extra_headers.items),
            );
            defer req.deinit();

            if (payload) |body_payload| {
                req.transfer_encoding = .{ .content_length = body_payload.len };
                var body_writer = req.sendBody(&.{}) catch |err| {
                    if (err == error.WriteFailed and attempt + 1 < max_attempts) {
                        continue :request_loop;
                    }
                    return err;
                };

                body_writer.writer.writeAll(body_payload) catch |err| {
                    if (err == error.WriteFailed and attempt + 1 < max_attempts) {
                        continue :request_loop;
                    }
                    return err;
                };

                body_writer.end() catch |err| {
                    if (err == error.WriteFailed and attempt + 1 < max_attempts) {
                        continue :request_loop;
                    }
                    return err;
                };
            } else {
                req.sendBodiless() catch |err| {
                    if (err == error.WriteFailed and attempt + 1 < max_attempts) {
                        continue :request_loop;
                    }
                    return err;
                };
            }

            var response = req.receiveHead(redirect_buffer[0..]) catch |err| {
                if (err == error.HttpConnectionClosing and attempt + 1 < max_attempts) {
                    continue :request_loop;
                }
                return err;
            };

            if (self.host) |host_slice| {
                const cookie_host = host_slice;
                var header_it = response.head.iterateHeaders();
                while (header_it.next()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) {
                        _ = set_cookie: {
                            if (network_lock) |lock| lock.lock();
                            defer if (network_lock) |lock| lock.unlock();
                            break :set_cookie try applySetCookie(
                                al,
                                cookie_jar,
                                cookie_host,
                                header.value,
                                .http,
                                std.Io.Clock.real.now(http_client.io).toSeconds(),
                            );
                        };
                    } else if (std.ascii.eqlIgnoreCase(header.name, "content-security-policy")) {
                        if (csp_header) |existing| {
                            al.free(existing);
                        }
                        const trimmed = std.mem.trim(u8, header.value, " ");
                        const copy = try al.alloc(u8, trimmed.len);
                        @memcpy(copy, trimmed);
                        csp_header = copy;
                    } else if (request_origin != null and
                        std.ascii.eqlIgnoreCase(header.name, "access-control-allow-origin"))
                    {
                        if (access_control_allow_origin) |existing| al.free(existing);
                        const trimmed = std.mem.trim(u8, header.value, " \t");
                        access_control_allow_origin = try al.dupe(u8, trimmed);
                    } else if (std.ascii.eqlIgnoreCase(header.name, "cache-control")) {
                        cache_control.apply(header.value);
                    } else if (std.ascii.eqlIgnoreCase(header.name, "referrer-policy")) {
                        if (parseReferrerPolicy(header.value)) |parsed| {
                            response_referrer_policy = parsed;
                        }
                    } else if (std.ascii.eqlIgnoreCase(header.name, "x-frame-options")) {
                        if (parseXFrameOptions(header.value)) |parsed| {
                            response_x_frame_options = mergeXFrameOptions(
                                response_x_frame_options,
                                parsed,
                            );
                        }
                    }
                }
            }

            var allocating_writer = std.Io.Writer.Allocating.init(al);
            defer allocating_writer.deinit();

            var owned_decompress_buffer: ?[]u8 = null;
            const decompress_buffer: []u8 = switch (response.head.content_encoding) {
                .identity => &.{},
                .zstd => blk: {
                    const buf = try al.alloc(u8, std.compress.zstd.default_window_len);
                    owned_decompress_buffer = buf;
                    break :blk buf;
                },
                .deflate, .gzip => blk: {
                    const buf = try al.alloc(u8, std.compress.flate.max_window_len);
                    owned_decompress_buffer = buf;
                    break :blk buf;
                },
                .compress => return error.UnsupportedCompressionMethod,
            };
            defer if (owned_decompress_buffer) |buf| al.free(buf);

            var transfer_buffer: [64]u8 = undefined;
            var decompress_state: std.http.Decompress = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress_state, decompress_buffer);

            const response_writer: *std.Io.Writer = &allocating_writer.writer;
            _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
                error.ReadFailed => blk: {
                    if (response.bodyErr()) |inner_err| {
                        std.log.warn("response.bodyErr for {s}: {}", .{ url_str, inner_err });
                        return inner_err;
                    }
                    break :blk;
                },
                else => |e| {
                    std.log.warn("streamRemaining failed for {s}: {}", .{ url_str, e });
                    return e;
                },
            };

            const body = try allocating_writer.toOwnedSlice();
            errdefer al.free(body);
            std.log.info("Received {d} bytes, status: {d}", .{
                body.len,
                @intFromEnum(response.head.status),
            });

            if (final_url) |output| {
                var final_url_writer = std.Io.Writer.Allocating.init(al);
                defer final_url_writer.deinit();
                try req.uri.writeToStream(&final_url_writer.writer, .all);
                const final_url_text = try final_url_writer.toOwnedSlice();
                defer al.free(final_url_text);

                var resolved = try Url.init(al, final_url_text);
                resolved.view_source = self.view_source;
                output.* = resolved;
            }

            const result = HttpResponse{
                .body = body,
                .csp_header = csp_header,
                .access_control_allow_origin = access_control_allow_origin,
                .status = response.head.status,
                .cache_control = cache_control,
                .referrer_policy = response_referrer_policy,
                .x_frame_options = response_x_frame_options,
            };
            csp_header_cleanup = false;
            access_control_allow_origin_cleanup = false;
            return result;
        }

        unreachable;
    }

    pub fn fileRequest(self: Url, al: std.mem.Allocator, io: std.Io) ![]const u8 {
        const html_file = try std.Io.Dir.cwd().openFile(io, self.path, .{});

        defer html_file.close(io);

        var buffer: [8192]u8 = undefined;
        var reader = html_file.reader(io, &buffer);
        const html_content = try reader.interface.allocRemaining(al, .unlimited);
        return html_content;
    }

    /// Convert URL to string representation
    /// Returns a formatted URL string, hiding default ports
    pub fn toString(self: Url, buffer: []u8) ![]const u8 {
        if (self.view_source) {
            const prefix = "view-source:";
            if (buffer.len < prefix.len) return error.NoSpaceLeft;
            @memcpy(buffer[0..prefix.len], prefix);
            const inner_url = try self.toStringInner(buffer[prefix.len..]);
            return buffer[0 .. prefix.len + inner_url.len];
        }
        return self.toStringInner(buffer);
    }

    /// Allocate the complete canonical serialization of this URL. Unlike
    /// `toString`, this has no caller-selected length limit. The returned text
    /// is an independent owner suitable for browser-session sets.
    pub fn toOwnedString(self: Url, allocator: std.mem.Allocator) ![]u8 {
        const href = self.ada_url.getHref();
        const prefix = if (self.view_source) "view-source:" else "";
        const output = try allocator.alloc(u8, prefix.len + href.len);
        @memcpy(output[0..prefix.len], prefix);
        @memcpy(output[prefix.len..], href);
        return output;
    }

    fn toStringInner(self: Url, buffer: []u8) ![]const u8 {
        const href = self.ada_url.getHref();
        if (href.len > buffer.len) return error.NoSpaceLeft;
        @memcpy(buffer[0..href.len], href);
        return buffer[0..href.len];
    }
};

/// Return the borrowed Referer request-header value for an outgoing request.
/// Fragments never cross the network, and policy suppression affects only this
/// header—not the source URL used for SameSite cookie decisions.
pub fn refererHeaderValue(
    referrer: ?Url,
    target: Url,
    policy: ReferrerPolicy,
) ?[]const u8 {
    const source = referrer orelse return null;
    switch (policy) {
        .default => {},
        .no_referrer => return null,
        .same_origin => if (!source.sameOrigin(target)) return null,
    }
    const href = source.ada_url.getHref();
    const fragment = std.mem.indexOfScalar(u8, href, '#') orelse return href;
    return href[0..fragment];
}

fn inheritFragment(allocator: std.mem.Allocator, source: Url, destination: *Url) !void {
    if (destination.ada_url.hasHash()) return;
    const hash = source.ada_url.getHash() orelse return;

    var href = std.ArrayList(u8).empty;
    defer href.deinit(allocator);
    try href.appendSlice(allocator, destination.ada_url.getHref());
    try href.appendSlice(allocator, hash);

    var replacement = try Url.init(allocator, href.items);
    replacement.view_source = destination.view_source;
    destination.*.free(allocator);
    destination.* = replacement;
}

/// Compare an encoded URL fragment with an HTML `id`. Valid percent escapes
/// decode byte-for-byte; malformed escapes remain literal.
pub fn fragmentMatchesId(fragment: []const u8, id: []const u8) bool {
    var fragment_index: usize = 0;
    var id_index: usize = 0;
    while (fragment_index < fragment.len and id_index < id.len) {
        var byte = fragment[fragment_index];
        if (byte == '%' and fragment_index + 2 < fragment.len) {
            if (percentByte(fragment[fragment_index + 1 .. fragment_index + 3])) |decoded| {
                byte = decoded;
                fragment_index += 3;
            } else {
                fragment_index += 1;
            }
        } else {
            fragment_index += 1;
        }
        if (byte != id[id_index]) return false;
        id_index += 1;
    }
    return fragment_index == fragment.len and id_index == id.len;
}

const expect = std.testing.expect;

fn readTestHttpLine(reader: *std.Io.Reader) ![]const u8 {
    const line = try reader.takeDelimiterInclusive('\n');
    return std.mem.trimEnd(u8, line, "\r\n");
}

test "about blank is canonical and fetches an empty document" {
    const url = try Url.blank(std.testing.allocator);
    defer url.free(std.testing.allocator);

    try expect(url.isAboutBlank());
    var url_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("about:blank", try url.toString(&url_buffer));

    var http_client: std.http.Client = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer http_client.deinit();
    var cookie_jar = std.StringHashMap(CookieEntry).init(std.testing.allocator);
    defer cookie_jar.deinit();

    const response = try Url.fetchBody(
        std.testing.allocator,
        std.testing.io,
        &http_client,
        &cookie_jar,
        null,
        url,
        null,
        null,
    );
    try std.testing.expectEqualStrings("", response.body);
}

test "navigation parsing recovers malformed URLs to about blank" {
    const malformed_inputs = [_][]const u8{
        "http://[",
        "data:text/html",
        "view-source:http://[",
        "mailto:test@example.com",
    };
    for (malformed_inputs) |input| {
        const recovered = try Url.initForNavigation(std.testing.allocator, input);
        defer recovered.free(std.testing.allocator);
        try expect(recovered.isAboutBlank());
    }

    const unsupported_about = try Url.initForNavigation(std.testing.allocator, "about:not-implemented");
    defer unsupported_about.free(std.testing.allocator);
    try expect(unsupported_about.isAboutBlank());

    const valid = try Url.initForNavigation(std.testing.allocator, "https://example.com/path");
    defer valid.free(std.testing.allocator);
    try std.testing.expectEqualStrings("https", valid.scheme);
    try std.testing.expectEqualStrings("example.com", valid.host.?);
    try std.testing.expectEqualStrings("/path", valid.path);
}

test "navigation resolution recovers malformed links to about blank" {
    const base = try Url.init(std.testing.allocator, "https://example.com/path/page.html");
    defer base.free(std.testing.allocator);

    const recovered = try base.resolveForNavigation(std.testing.allocator, "data:text/html");
    defer recovered.free(std.testing.allocator);
    try expect(recovered.isAboutBlank());

    const unsupported = try base.resolveForNavigation(std.testing.allocator, "mailto:test@example.com");
    defer unsupported.free(std.testing.allocator);
    try expect(unsupported.isAboutBlank());

    const relative = try base.resolveForNavigation(std.testing.allocator, "next.html");
    defer relative.free(std.testing.allocator);
    try std.testing.expectEqualStrings("/path/next.html", relative.path);
}

test "explicit URL scheme detection leaves file-like inputs alone" {
    try expect(Url.hasExplicitScheme("https://example.com"));
    try expect(Url.hasExplicitScheme("about:blank"));
    try expect(Url.hasExplicitScheme("data:text/plain,hello"));
    try expect(!Url.hasExplicitScheme("example.com"));
    try expect(!Url.hasExplicitScheme("/tmp/page.html"));
    try expect(!Url.hasExplicitScheme("1invalid:value"));
}

test "strict fetch rejects unsupported schemes without panicking" {
    const url = try Url.init(std.testing.allocator, "mailto:test@example.com");
    defer url.free(std.testing.allocator);

    var http_client: std.http.Client = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };
    defer http_client.deinit();
    var cookie_jar = std.StringHashMap(CookieEntry).init(std.testing.allocator);
    defer cookie_jar.deinit();

    try std.testing.expectError(
        error.UnsupportedScheme,
        Url.fetchBody(
            std.testing.allocator,
            std.testing.io,
            &http_client,
            &cookie_jar,
            null,
            url,
            null,
            null,
        ),
    );
}

test "file URLs load local file contents" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "page.html",
        .data = "<p>local fixture</p>",
    });

    var directory_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_path_len = try temp_dir.dir.realPath(std.testing.io, &directory_path_buffer);
    const file_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "file://{s}/page.html",
        .{directory_path_buffer[0..directory_path_len]},
    );
    defer std.testing.allocator.free(file_url);

    const url = try Url.init(std.testing.allocator, file_url);
    defer url.free(std.testing.allocator);
    const body = try url.fileRequest(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(body);

    try expect(std.mem.eql(u8, body, "<p>local fixture</p>"));
}

test "file URLs resolve relative and root-relative resources" {
    const url = try Url.init(std.testing.allocator, "file:///test/path.html");
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "file"));
    try expect(std.mem.eql(u8, url.path, "/test/path.html"));

    const relative = try url.resolve(std.testing.allocator, "assets/site.css");
    defer relative.free(std.testing.allocator);
    try expect(std.mem.eql(u8, relative.path, "/test/assets/site.css"));

    const parent_relative = try url.resolve(std.testing.allocator, "../shared/site.css");
    defer parent_relative.free(std.testing.allocator);
    try expect(std.mem.eql(u8, parent_relative.path, "/shared/site.css"));

    const root_relative = try url.resolve(std.testing.allocator, "/images/logo.png");
    defer root_relative.free(std.testing.allocator);
    try expect(std.mem.eql(u8, root_relative.path, "/images/logo.png"));
}

test "fragment references retain document identity and decode for HTML ids" {
    const base = try Url.init(
        std.testing.allocator,
        "https://example.com/docs/page.html?mode=1#old",
    );
    defer base.free(std.testing.allocator);

    const resolved = try base.resolve(std.testing.allocator, "#section%20two");
    defer resolved.free(std.testing.allocator);

    try std.testing.expect(base.sameDocument(resolved));
    try std.testing.expectEqualStrings("section%20two", resolved.fragment().?);
    try std.testing.expect(fragmentMatchesId(resolved.fragment().?, "section two"));
    try std.testing.expect(!fragmentMatchesId(resolved.fragment().?, "section%20two"));

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://example.com/docs/page.html?mode=1#section%20two",
        try resolved.toString(&buffer),
    );

    const other_query = try base.resolve(std.testing.allocator, "?mode=2#section%20two");
    defer other_query.free(std.testing.allocator);
    try std.testing.expect(!base.sameDocument(other_query));
}

test "final navigation URLs inherit a requested fragment" {
    const requested = try Url.init(std.testing.allocator, "https://example.com/start#target");
    defer requested.free(std.testing.allocator);
    var destination = try Url.init(std.testing.allocator, "https://example.com/final");
    defer destination.free(std.testing.allocator);

    try inheritFragment(std.testing.allocator, requested, &destination);
    try std.testing.expectEqualStrings("target", destination.fragment().?);
}

test "data request" {
    const url = try Url.init(std.testing.allocator, "data:text/html,Hello%20World!");
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "data"));
    try expect(std.mem.eql(u8, url.path, "Hello World!"));
    try expect(std.mem.eql(u8, url.mime_type.?, "text/html"));
}

test "data request supports the literal browser engineering exercise" {
    const url = try Url.init(std.testing.allocator, "data:text/html,Hello world!");
    defer url.free(std.testing.allocator);

    try expect(std.mem.eql(u8, url.scheme, "data"));
    try expect(std.mem.eql(u8, url.mime_type.?, "text/html"));
    try expect(std.mem.eql(u8, url.path, "Hello world!"));
}

test "data URL fragments are not part of the document body" {
    const url = try Url.init(
        std.testing.allocator,
        "data:text/html,<h1 id=target>Target</h1>#target",
    );
    defer url.free(std.testing.allocator);

    try std.testing.expectEqualStrings("<h1 id=target>Target</h1>", url.path);
    try std.testing.expectEqualStrings("target", url.fragment().?);
}

test "data request with attributes" {
    const url = try Url.init(std.testing.allocator, "data:text/html;charset=utf-8;base64,SGVsbG8gV29ybGQh");
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "data"));
    try expect(std.mem.eql(u8, url.path, "Hello World!"));
    try expect(std.mem.eql(u8, url.mime_type.?, "text/html"));
    try expect(url.attributes.?.items.len == 2);
    try expect(std.mem.eql(u8, url.attributes.?.items[0], "charset=utf-8"));
    try expect(std.mem.eql(u8, url.attributes.?.items[1], "base64"));
}

test "data request percent-decodes before base64 decoding" {
    const url = try Url.init(std.testing.allocator, "data:text/plain;base64,SGVsbG8%3D");
    defer url.free(std.testing.allocator);

    try expect(std.mem.eql(u8, url.path, "Hello"));
}

test "fetchBody handles data URLs without Browser state" {
    const url = try Url.init(std.testing.allocator, "data:text/html,isolated%20document");
    defer url.free(std.testing.allocator);

    var http_client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var cookie_jar = std.StringHashMap(CookieEntry).init(std.testing.allocator);
    defer cookie_jar.deinit();

    const response = try Url.fetchBody(
        std.testing.allocator,
        std.testing.io,
        &http_client,
        &cookie_jar,
        null,
        url,
        null,
        null,
    );
    try expect(std.mem.eql(u8, response.body, "isolated document"));
    try expect(response.csp_header == null);
}

test "URL clone owns independent Ada and data URL storage" {
    var original = try Url.init(
        std.testing.allocator,
        "data:text/html;charset=utf-8;base64,SGVsbG8gV29ybGQh",
    );
    const cloned = try original.clone(std.testing.allocator);
    original.free(std.testing.allocator);
    original = undefined;
    defer cloned.free(std.testing.allocator);

    try expect(std.mem.eql(u8, cloned.scheme, "data"));
    try expect(std.mem.eql(u8, cloned.path, "Hello World!"));
    try expect(std.mem.eql(u8, cloned.mime_type.?, "text/html"));
    try expect(std.mem.eql(u8, cloned.attributes.?.items[0], "charset=utf-8"));
    try expect(std.mem.eql(u8, cloned.attributes.?.items[1], "base64"));
}

test "view-source URLs preserve their wrapper when serialized and cloned" {
    var original = try Url.init(std.testing.allocator, "view-source:https://example.com/path");
    var original_buffer: [128]u8 = undefined;
    try expect(std.mem.eql(u8, try original.toString(&original_buffer), "view-source:https://example.com/path"));

    const cloned = try original.clone(std.testing.allocator);
    original.free(std.testing.allocator);
    original = undefined;
    defer cloned.free(std.testing.allocator);

    try expect(cloned.view_source);
    try expect(std.mem.eql(u8, cloned.scheme, "https"));
    try expect(std.mem.eql(u8, cloned.host.?, "example.com"));
    try expect(std.mem.eql(u8, cloned.path, "/path"));

    var cloned_buffer: [128]u8 = undefined;
    try expect(std.mem.eql(u8, try cloned.toString(&cloned_buffer), "view-source:https://example.com/path"));
}

test "X-Frame-Options parsing is case-insensitive and restrictive" {
    try std.testing.expectEqual(XFrameOptions.deny, parseXFrameOptions("  DeNy\t").?);
    try std.testing.expectEqual(
        XFrameOptions.same_origin,
        parseXFrameOptions("SAMEORIGIN").?,
    );
    try std.testing.expectEqual(
        XFrameOptions.deny,
        parseXFrameOptions("sameorigin, DENY").?,
    );
    try std.testing.expect(parseXFrameOptions("ALLOW-FROM https://example.com") == null);
    try std.testing.expect(parseXFrameOptions("unknown") == null);
}

test "http request" {
    const url = try Url.init(std.testing.allocator, "http://example.com");
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "http"));
    try expect(std.mem.eql(u8, url.host.?, "example.com"));
    try expect(std.mem.eql(u8, url.path, "/"));
    try expect(url.port == 80);
    try expect(!url.is_https);
}

test "HTTP requests identify Zibra and keep HTTP/1.1 connections alive" {
    const headers = [_]std.http.Header{
        .{ .name = "X-Zibra-Test", .value = "present" },
    };
    const options = requestOptions(.unhandled, &headers);

    try std.testing.expectEqual(std.http.Version.@"HTTP/1.1", options.version);
    try expect(options.keep_alive);
    try std.testing.expectEqualStrings(
        user_agent,
        options.headers.user_agent.override,
    );
    try std.testing.expectEqualStrings(
        "gzip",
        options.headers.accept_encoding.override,
    );
    try std.testing.expectEqual(@as(usize, 1), options.extra_headers.len);
    try std.testing.expectEqualStrings("X-Zibra-Test", options.extra_headers[0].name);
    try std.testing.expectEqualStrings("present", options.extra_headers[0].value);
}

test "HTTP fetch retains CORS, referrer, and frame response policies" {
    const CorsServer = struct {
        server: std.Io.net.Server,
        io: std.Io,
        saw_origin: bool = false,
        saw_cookie: bool = false,
        saw_referer: bool = false,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            var stream = try self.server.accept(self.io);
            defer stream.socket.close(self.io);

            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            var write_buffer: [1024]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);

            const request_line = try readTestHttpLine(&reader.interface);
            if (!std.mem.startsWith(u8, request_line, "GET /cors ")) return error.InvalidRequest;
            while (true) {
                const header = try readTestHttpLine(&reader.interface);
                if (header.len == 0) break;
                const colon = std.mem.indexOfScalar(u8, header, ':') orelse continue;
                const name = header[0..colon];
                const value = std.mem.trim(u8, header[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(name, "origin")) {
                    self.saw_origin = std.mem.eql(u8, value, "http://source.example:8080");
                } else if (std.ascii.eqlIgnoreCase(name, "cookie")) {
                    self.saw_cookie = std.mem.eql(u8, value, "token=secret");
                } else if (std.ascii.eqlIgnoreCase(name, "referer")) {
                    self.saw_referer = std.mem.eql(u8, value, "http://source.example:8080/page");
                }
            }

            try writer.interface.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Length: 7\r\n" ++
                    "Access-Control-Allow-Origin: http://source.example:8080\r\n" ++
                    "Referrer-Policy: same-origin\r\n" ++
                    "X-Frame-Options: SAMEORIGIN\r\n" ++
                    "Connection: close\r\n\r\n" ++
                    "allowed",
            );
            try writer.interface.flush();
        }
    };

    const allocator = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    var context = CorsServer{ .server = server, .io = std.testing.io };
    const thread = try std.Thread.spawn(.{}, CorsServer.run, .{&context});
    var thread_joined = false;
    defer if (!thread_joined) thread.join();

    var http_client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer http_client.deinit();
    var cookie_jar = std.StringHashMap(CookieEntry).init(allocator);
    defer {
        var iterator = cookie_jar.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        cookie_jar.deinit();
    }
    const target_text = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/cors",
        .{server.socket.address.getPort()},
    );
    defer allocator.free(target_text);
    const target = try Url.init(allocator, target_text);
    defer target.free(allocator);
    try std.testing.expect(try applySetCookie(
        allocator,
        &cookie_jar,
        target.host.?,
        "token=secret",
        .http,
        1_600_000_000,
    ));
    const source = try Url.init(allocator, "http://source.example:8080/page#private");
    defer source.free(allocator);

    const response = try Url.fetchBodyWithOrigin(
        allocator,
        std.testing.io,
        &http_client,
        &cookie_jar,
        null,
        target,
        source,
        null,
        "http://source.example:8080",
    );
    defer allocator.free(response.body);
    defer if (response.csp_header) |header| allocator.free(header);
    defer if (response.access_control_allow_origin) |header| allocator.free(header);

    thread.join();
    thread_joined = true;
    if (context.err) |err| return err;
    try std.testing.expect(context.saw_origin);
    try std.testing.expect(context.saw_cookie);
    try std.testing.expect(context.saw_referer);
    try std.testing.expectEqualStrings("allowed", response.body);
    try std.testing.expectEqual(ReferrerPolicy.same_origin, response.referrer_policy);
    try std.testing.expectEqual(XFrameOptions.same_origin, response.x_frame_options);
    try std.testing.expectEqualStrings(
        "http://source.example:8080",
        response.access_control_allow_origin.?,
    );
}

test "HTTP requests negotiate and decode chunked gzip responses" {
    const CompressionServer = struct {
        server: std.Io.net.Server,
        io: std.Io,
        saw_gzip: bool = false,
        err: ?anyerror = null,

        const compressed_body = [_]u8{
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x02, 0xff, 0x4b, 0xce, 0xcf, 0x2d, 0x28, 0x4a,
            0x2d, 0x2e, 0x4e, 0x4d, 0x51, 0x00, 0x52, 0x05,
            0xf9, 0x79, 0xc5, 0xa9, 0x0a, 0x49, 0xf9, 0x29,
            0x95, 0x00, 0x74, 0x6d, 0x27, 0xcb, 0x18, 0x00,
            0x00, 0x00,
        };

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            var stream = try self.server.accept(self.io);
            defer stream.socket.close(self.io);

            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            var write_buffer: [1024]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);

            const request_line = try readTestHttpLine(&reader.interface);
            if (!std.mem.startsWith(u8, request_line, "GET ")) return error.InvalidRequest;

            while (true) {
                const header = try readTestHttpLine(&reader.interface);
                if (header.len == 0) break;
                const colon = std.mem.indexOfScalar(u8, header, ':') orelse continue;
                const name = header[0..colon];
                const value = std.mem.trim(u8, header[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(name, "accept-encoding")) {
                    self.saw_gzip = std.ascii.eqlIgnoreCase(value, "gzip");
                }
            }

            try writer.interface.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/plain\r\n" ++
                    "Content-Encoding: gzip\r\n" ++
                    "Transfer-Encoding: chunked\r\n" ++
                    "Connection: close\r\n\r\n",
            );

            const chunk_size: usize = 7;
            var offset: usize = 0;
            while (offset < compressed_body.len) {
                const end = @min(offset + chunk_size, compressed_body.len);
                const chunk = compressed_body[offset..end];
                try writer.interface.print("{x}\r\n", .{chunk.len});
                try writer.interface.writeAll(chunk);
                try writer.interface.writeAll("\r\n");
                offset = end;
            }
            try writer.interface.writeAll("0\r\n\r\n");
            try writer.interface.flush();
        }
    };

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    var context = CompressionServer{ .server = server, .io = std.testing.io };
    const thread = try std.Thread.spawn(.{}, CompressionServer.run, .{&context});

    var http_client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var cookie_jar = std.StringHashMap(CookieEntry).init(std.testing.allocator);
    defer cookie_jar.deinit();

    const url_string = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/compressed",
        .{server.socket.address.getPort()},
    );
    defer std.testing.allocator.free(url_string);
    const url = try Url.init(std.testing.allocator, url_string);
    defer url.free(std.testing.allocator);

    const response = try Url.fetchBody(
        std.testing.allocator,
        std.testing.io,
        &http_client,
        &cookie_jar,
        null,
        url,
        null,
        null,
    );
    defer std.testing.allocator.free(response.body);

    thread.join();
    if (context.err) |err| return err;
    try expect(context.saw_gzip);
    try std.testing.expectEqualStrings("compressed response body", response.body);
}

test "HTTP requests reuse a keep-alive connection" {
    const KeepAliveServer = struct {
        server: std.Io.net.Server,
        io: std.Io,
        accepted_connections: usize = 0,
        handled_requests: usize = 0,
        saw_keep_alive: bool = false,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            while (self.handled_requests < 2) {
                var stream = try self.server.accept(self.io);
                defer stream.socket.close(self.io);
                self.accepted_connections += 1;

                var read_buffer: [4096]u8 = undefined;
                var reader = stream.reader(self.io, &read_buffer);
                var write_buffer: [1024]u8 = undefined;
                var writer = stream.writer(self.io, &write_buffer);

                while (self.handled_requests < 2) {
                    const request_line = readTestHttpLine(&reader.interface) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return err,
                    };
                    if (!std.mem.startsWith(u8, request_line, "GET ")) return error.InvalidRequest;

                    var connection_is_keep_alive = false;
                    while (true) {
                        const header = try readTestHttpLine(&reader.interface);
                        if (header.len == 0) break;
                        if (std.mem.indexOfScalar(u8, header, ':')) |colon| {
                            const name = header[0..colon];
                            const value = std.mem.trim(u8, header[colon + 1 ..], " \t");
                            if (std.ascii.eqlIgnoreCase(name, "connection")) {
                                connection_is_keep_alive = std.ascii.eqlIgnoreCase(value, "keep-alive");
                            }
                        }
                    }
                    self.saw_keep_alive = self.saw_keep_alive or connection_is_keep_alive;

                    try writer.interface.writeAll(
                        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok",
                    );
                    try writer.interface.flush();
                    self.handled_requests += 1;
                }
            }
        }
    };

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    var context = KeepAliveServer{ .server = server, .io = std.testing.io };
    const thread = try std.Thread.spawn(.{}, KeepAliveServer.run, .{&context});

    var http_client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var cookie_jar = std.StringHashMap(CookieEntry).init(std.testing.allocator);
    defer cookie_jar.deinit();

    const url_string = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/resource",
        .{server.socket.address.getPort()},
    );
    defer std.testing.allocator.free(url_string);
    const url = try Url.init(std.testing.allocator, url_string);
    defer url.free(std.testing.allocator);

    for (0..2) |_| {
        const response = try Url.fetchBody(
            std.testing.allocator,
            std.testing.io,
            &http_client,
            &cookie_jar,
            null,
            url,
            null,
            null,
        );
        defer std.testing.allocator.free(response.body);
        try expect(std.mem.eql(u8, response.body, "ok"));
    }

    thread.join();
    if (context.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), context.accepted_connections);
    try std.testing.expectEqual(@as(usize, 2), context.handled_requests);
    try expect(context.saw_keep_alive);
}

test "HTTP cache reuses only cacheable GET 200 responses" {
    const CacheServer = struct {
        server: std.Io.net.Server,
        io: std.Io,
        handled_requests: usize = 0,
        default_requests: usize = 0,
        max_age_requests: usize = 0,
        no_store_requests: usize = 0,
        unknown_requests: usize = 0,
        not_found_requests: usize = 0,
        err: ?anyerror = null,

        const Route = enum { default, max_age, no_store, unknown, not_found };

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            var stream = try self.server.accept(self.io);
            defer stream.socket.close(self.io);

            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            var write_buffer: [1024]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);

            while (true) {
                const request_line = readTestHttpLine(&reader.interface) catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => return err,
                };
                var request_parts = std.mem.splitScalar(u8, request_line, ' ');
                if (!std.mem.eql(u8, request_parts.first(), "GET")) return error.InvalidRequest;
                const request_path = request_parts.next() orelse return error.InvalidRequest;

                const route: Route = if (std.mem.eql(u8, request_path, "/default"))
                    .default
                else if (std.mem.eql(u8, request_path, "/max-age"))
                    .max_age
                else if (std.mem.eql(u8, request_path, "/no-store"))
                    .no_store
                else if (std.mem.eql(u8, request_path, "/unknown"))
                    .unknown
                else if (std.mem.eql(u8, request_path, "/not-found"))
                    .not_found
                else
                    return error.UnexpectedRequestTarget;
                switch (route) {
                    .default => self.default_requests += 1,
                    .max_age => self.max_age_requests += 1,
                    .no_store => self.no_store_requests += 1,
                    .unknown => self.unknown_requests += 1,
                    .not_found => self.not_found_requests += 1,
                }

                while (true) {
                    const header = try readTestHttpLine(&reader.interface);
                    if (header.len == 0) break;
                }

                if (route == .not_found) {
                    try writer.interface.writeAll(
                        "HTTP/1.1 404 Not Found\r\n" ++
                            "Content-Length: 9\r\n" ++
                            "Cache-Control: max-age=60\r\n" ++
                            "Connection: keep-alive\r\n\r\n" ++
                            "not-found",
                    );
                } else {
                    const response_path, const cache_control = switch (route) {
                        .default => .{ "/default", "" },
                        .max_age => .{ "/max-age", "Cache-Control: max-age=60\r\n" },
                        .no_store => .{ "/no-store", "Cache-Control: no-store\r\n" },
                        .unknown => .{ "/unknown", "Cache-Control: max-age=60, public\r\n" },
                        .not_found => unreachable,
                    };
                    try writer.interface.print(
                        "HTTP/1.1 200 OK\r\n" ++
                            "Content-Length: {d}\r\n" ++
                            "{s}" ++
                            "Connection: keep-alive\r\n\r\n" ++
                            "{s}",
                        .{ response_path.len, cache_control, response_path },
                    );
                }
                try writer.interface.flush();
                self.handled_requests += 1;
            }
        }
    };

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    var context = CacheServer{ .server = server, .io = std.testing.io };
    const thread = try std.Thread.spawn(.{}, CacheServer.run, .{&context});
    var thread_joined = false;
    defer if (!thread_joined) thread.join();

    var http_client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var http_client_live = true;
    defer if (http_client_live) http_client.deinit();
    var cookie_jar = std.StringHashMap(CookieEntry).init(std.testing.allocator);
    defer cookie_jar.deinit();
    var cache = HttpCache.init(std.testing.allocator);
    defer cache.deinit();

    const paths = [_][]const u8{ "/default", "/max-age", "/no-store", "/unknown", "/not-found" };
    var responses_valid = true;
    for (paths) |path| {
        const url_text = try std.fmt.allocPrint(
            std.testing.allocator,
            "http://127.0.0.1:{d}{s}",
            .{ server.socket.address.getPort(), path },
        );
        defer std.testing.allocator.free(url_text);
        const url = try Url.init(std.testing.allocator, url_text);
        defer url.free(std.testing.allocator);

        for (0..2) |_| {
            const response = try Url.fetchBody(
                std.testing.allocator,
                std.testing.io,
                &http_client,
                &cookie_jar,
                &cache,
                url,
                null,
                null,
            );
            defer if (response.csp_header) |header| std.testing.allocator.free(header);
            if (std.mem.eql(u8, path, "/not-found")) {
                responses_valid = responses_valid and response.status == .not_found;
                responses_valid = responses_valid and std.mem.eql(u8, "not-found", response.body);
            } else {
                responses_valid = responses_valid and response.status == .ok;
                responses_valid = responses_valid and std.mem.eql(u8, path, response.body);
            }
            std.testing.allocator.free(response.body);
        }
    }

    http_client.deinit();
    http_client_live = false;
    thread.join();
    thread_joined = true;
    if (context.err) |err| return err;
    try expect(responses_valid);
    try std.testing.expectEqual(@as(usize, 8), context.handled_requests);
    try std.testing.expectEqual(@as(usize, 1), context.default_requests);
    try std.testing.expectEqual(@as(usize, 1), context.max_age_requests);
    try std.testing.expectEqual(@as(usize, 2), context.no_store_requests);
    try std.testing.expectEqual(@as(usize, 2), context.unknown_requests);
    try std.testing.expectEqual(@as(usize, 2), context.not_found_requests);
}

test "HTTP redirects follow relative and absolute locations and report the final URL" {
    const RedirectServer = struct {
        server: std.Io.net.Server,
        io: std.Io,
        port: u16,
        handled_requests: usize = 0,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            var stream = try self.server.accept(self.io);
            defer stream.socket.close(self.io);

            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            var write_buffer: [1024]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);
            const expected_paths = [_][]const u8{ "/start", "/middle", "/final" };

            for (expected_paths, 0..) |expected_path, index| {
                const request_line = try readTestHttpLine(&reader.interface);
                var request_parts = std.mem.splitScalar(u8, request_line, ' ');
                if (!std.mem.eql(u8, request_parts.first(), "GET")) return error.InvalidRequest;
                const request_path = request_parts.next() orelse return error.InvalidRequest;
                if (!std.mem.eql(u8, request_path, expected_path)) return error.UnexpectedRedirectTarget;

                while (true) {
                    const header = try readTestHttpLine(&reader.interface);
                    if (header.len == 0) break;
                }

                switch (index) {
                    0 => try writer.interface.writeAll(
                        "HTTP/1.1 302 Found\r\nContent-Length: 0\r\nLocation: /middle\r\nConnection: keep-alive\r\n\r\n",
                    ),
                    1 => try writer.interface.print(
                        "HTTP/1.1 301 Moved Permanently\r\nContent-Length: 0\r\nLocation: http://127.0.0.1:{d}/final\r\nConnection: keep-alive\r\n\r\n",
                        .{self.port},
                    ),
                    2 => try writer.interface.writeAll(
                        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nfinal",
                    ),
                    else => unreachable,
                }
                try writer.interface.flush();
                self.handled_requests += 1;
            }
        }
    };

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();
    var context = RedirectServer{
        .server = server,
        .io = std.testing.io,
        .port = port,
    };
    const thread = try std.Thread.spawn(.{}, RedirectServer.run, .{&context});

    var http_client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var cookie_jar = std.StringHashMap(CookieEntry).init(std.testing.allocator);
    defer cookie_jar.deinit();

    const initial_url_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/start#target",
        .{port},
    );
    defer std.testing.allocator.free(initial_url_text);
    const initial_url = try Url.init(std.testing.allocator, initial_url_text);
    defer initial_url.free(std.testing.allocator);

    var final_url: ?Url = null;
    defer if (final_url) |resolved| resolved.free(std.testing.allocator);
    const response = try Url.fetchBodyWithFinalUrl(
        std.testing.allocator,
        std.testing.io,
        &http_client,
        &cookie_jar,
        null,
        initial_url,
        null,
        null,
        &final_url,
    );
    defer std.testing.allocator.free(response.body);

    thread.join();
    if (context.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 3), context.handled_requests);
    try expect(std.mem.eql(u8, response.body, "final"));
    try expect(final_url != null);

    const expected_final_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/final#target",
        .{port},
    );
    defer std.testing.allocator.free(expected_final_url);
    var final_url_buffer: [256]u8 = undefined;
    try expect(std.mem.eql(u8, try final_url.?.toString(&final_url_buffer), expected_final_url));
}
