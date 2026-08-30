//! HTTP response metadata, policy parsing, CORS checks, and text decoding.
//!
//! Transport populates Response; navigation and script consumers receive only
//! copied scalar/owned policy fields from this module.

const std = @import("std");
const cache = @import("cache.zig");

const CacheControl = cache.CacheControl;
pub const ContentType = cache.ContentType;
const ReferrerPolicy = cache.ReferrerPolicy;
const XFrameOptions = cache.XFrameOptions;

/// Coarse response media classes used by document/resource consumers.  The
/// full header value is deliberately not retained: callers only need to know
/// whether a response is HTML, plain text, CSS, or an image when deciding
/// whether to parse or execute it.
pub fn classifyContentType(value: []const u8) ContentType {
    const media_type = std.mem.trim(u8, value, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, media_type, ';') orelse media_type.len;
    const token = std.mem.trim(u8, media_type[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(token, "text/html") or
        std.ascii.eqlIgnoreCase(token, "application/xhtml+xml")) return .html;
    if (std.ascii.eqlIgnoreCase(token, "text/plain")) return .plain;
    if (std.ascii.eqlIgnoreCase(token, "text/css")) return .css;
    if (token.len >= "image/".len and std.ascii.eqlIgnoreCase(token[0.."image/".len], "image/")) return .image;
    return .unknown;
}

test "classify response media types while ignoring parameters" {
    try std.testing.expectEqual(ContentType.html, classifyContentType("text/html; charset=utf-8"));
    try std.testing.expectEqual(ContentType.html, classifyContentType("Application/XHTML+XML"));
    try std.testing.expectEqual(ContentType.plain, classifyContentType(" text/plain "));
    try std.testing.expectEqual(ContentType.css, classifyContentType("text/css; charset=utf-8"));
    try std.testing.expectEqual(ContentType.image, classifyContentType("image/png"));
    try std.testing.expectEqual(ContentType.unknown, classifyContentType("application/xml"));
}

pub const Response = struct {
    body: []const u8,
    content_type: ContentType = .unknown,
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

pub fn mergeXFrameOptions(
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
