//! Browser-generated navigation documents, framing policy, and transport
//! security presentation.

const std = @import("std");
const url_module = @import("../network/url.zig");

const Url = url_module.Url;

/// Apply an HTTP response's framing policy to the complete ancestor chain.
/// The URL pointers are synchronous borrows from live Frames; this function
/// does not retain or take ownership of them. Missing ancestor identity is
/// represented by the caller omitting it, which fails closed for SAMEORIGIN.
pub fn xFrameOptionsAllowsEmbedding(
    policy: url_module.XFrameOptions,
    response_url: *const Url,
    ancestor_urls: []const *const Url,
) bool {
    return switch (policy) {
        .none => true,
        .deny => false,
        .same_origin => same_origin: {
            if (ancestor_urls.len == 0) break :same_origin false;
            for (ancestor_urls) |ancestor_url| {
                if (!response_url.*.sameOrigin(ancestor_url.*)) {
                    break :same_origin false;
                }
            }
            break :same_origin true;
        },
    };
}

/// A navigation response plus explicit ownership for generated/fetched bytes.
pub const NavigationDocument = struct {
    response: url_module.HttpResponse,
    owned_body: ?[]const u8,
    certificate_error: bool = false,

    pub fn deinit(self: *NavigationDocument, allocator: std.mem.Allocator) void {
        if (self.response.csp_header) |header| allocator.free(header);
        if (self.owned_body) |body| allocator.free(body);
        self.* = undefined;
    }
};

pub const NavigationSecurity = enum {
    none,
    secure,
    certificate_error,
};

pub fn security(url: ?*const Url, certificate_error: bool) NavigationSecurity {
    if (certificate_error) return .certificate_error;
    const current = url orelse return .none;
    return if (std.ascii.eqlIgnoreCase(current.scheme, "https")) .secure else .none;
}

fn appendHtmlEscaped(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |byte| {
        const replacement: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        };
        if (replacement) |escaped| {
            try output.appendSlice(allocator, escaped);
        } else {
            try output.append(allocator, byte);
        }
    }
}

/// Build a local warning document for an HTTPS certificate validation error.
pub fn certificateWarningHtml(
    allocator: std.mem.Allocator,
    requested_url: *const Url,
    certificate_error: anyerror,
) ![]u8 {
    const target = try requested_url.toOwnedString(allocator);
    defer allocator.free(target);

    var html = std.ArrayList(u8).empty;
    errdefer html.deinit(allocator);
    try html.appendSlice(
        allocator,
        "<html><head><title>Certificate error</title></head>" ++
            "<body><h1>Certificate error</h1>" ++
            "<p>Zibra could not verify the security certificate for <strong>",
    );
    try appendHtmlEscaped(allocator, &html, target);
    try html.appendSlice(
        allocator,
        "</strong>.</p><p>The connection was stopped before any page data was loaded.</p>" ++
            "<p>Error: <code>",
    );
    try appendHtmlEscaped(allocator, &html, @errorName(certificate_error));
    try html.appendSlice(allocator, "</code></p></body></html>");
    return html.toOwnedSlice(allocator);
}
