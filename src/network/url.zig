//! Owning URL representation, relative resolution, and resource loading.
//!
//! `Url` is an owning value even though Zig permits copying it: exactly one
//! logical copy must be passed to `free`. Its component slices are backed by
//! the owned Ada URL, except for data-URL storage allocated by `init`; callers
//! must pass the same allocator to `free` for those allocations.

const std = @import("std");

const ada = @import("ada");

const user_agent = "Zibra/0.0.0";

fn requestOptions(
    redirect_behavior: std.http.Client.Request.RedirectBehavior,
    extra_headers: []const std.http.Header,
) std.http.Client.RequestOptions {
    return .{
        .version = .@"HTTP/1.1",
        .keep_alive = false,
        .redirect_behavior = redirect_behavior,
        .headers = .{
            .user_agent = .{ .override = user_agent },
        },
        .extra_headers = extra_headers,
    };
}

pub const SameSiteMode = enum { none, lax };

pub const CookieEntry = struct {
    value: []u8,
    same_site: SameSiteMode = .none,
};

pub const HttpResponse = struct {
    body: []const u8,
    csp_header: ?[]u8 = null,
};

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
            const colon_index = std.mem.indexOfScalar(u8, url, ':') orelse return error.DataUriBadFormat;
            var rest = url[colon_index + 1 ..];

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

    /// Resolve a relative URL against this URL
    /// Handles:
    /// - Normal URLs with "://" (returned as-is)
    /// - Host-relative URLs starting with "/" (reuse scheme and host)
    /// - Path-relative URLs (resolve relative to current path)
    /// - Scheme-relative URLs starting with "//" (reuse scheme)
    /// - Parent directory navigation with "../"
    pub fn resolve(self: Url, allocator: std.mem.Allocator, relative_url: []const u8) !Url {
        // If it's already a full URL, just parse and return it
        if (std.mem.indexOf(u8, relative_url, "://") != null) {
            return try Url.init(allocator, relative_url);
        }

        if (std.mem.startsWith(u8, relative_url, "data:") or
            std.mem.startsWith(u8, relative_url, "about:") or
            std.mem.startsWith(u8, relative_url, "file:"))
        {
            return try Url.init(allocator, relative_url);
        }

        var resolved_url = std.ArrayList(u8).empty;
        defer resolved_url.deinit(allocator);

        // If it starts with "//", it's scheme-relative
        if (std.mem.startsWith(u8, relative_url, "//")) {
            // Use current scheme with the rest of the URL
            try resolved_url.appendSlice(allocator, self.scheme);
            try resolved_url.append(allocator, ':');
            try resolved_url.appendSlice(allocator, relative_url);
            return try Url.init(allocator, resolved_url.items);
        }

        // If it doesn't start with "/", it's path-relative
        if (!std.mem.startsWith(u8, relative_url, "/")) {
            // Get the directory part of the current path
            var dir = self.path;
            if (std.mem.lastIndexOf(u8, dir, "/")) |last_slash| {
                dir = dir[0..last_slash];
            } else {
                dir = "";
            }

            // Handle parent directory navigation (..)
            var working_dir = try allocator.alloc(u8, dir.len);
            defer allocator.free(working_dir);
            @memcpy(working_dir, dir);
            var working_dir_len = dir.len;

            var remaining_url = relative_url;
            while (std.mem.startsWith(u8, remaining_url, "../")) {
                // Remove one "../" from the URL
                remaining_url = remaining_url[3..];

                // Remove one directory level from working_dir
                if (std.mem.lastIndexOf(u8, working_dir[0..working_dir_len], "/")) |last_slash| {
                    working_dir_len = last_slash;
                } else {
                    working_dir_len = 0;
                }
            }

            // Build the resolved path
            try resolved_url.appendSlice(allocator, self.scheme);
            try resolved_url.appendSlice(allocator, "://");

            // For file:// URLs, there's no host
            if (std.mem.eql(u8, self.scheme, "file")) {
                try resolved_url.appendSlice(allocator, working_dir[0..working_dir_len]);
                try resolved_url.append(allocator, '/');
                try resolved_url.appendSlice(allocator, remaining_url);
            } else {
                const host = self.host.?;
                try resolved_url.appendSlice(allocator, host);
                if (!hostHasExplicitPort(host) and self.port != 80 and self.port != 443) {
                    try resolved_url.append(allocator, ':');
                    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{self.port});
                    defer allocator.free(port_str);
                    try resolved_url.appendSlice(allocator, port_str);
                }
                try resolved_url.appendSlice(allocator, working_dir[0..working_dir_len]);
                try resolved_url.append(allocator, '/');
                try resolved_url.appendSlice(allocator, remaining_url);
            }

            return try Url.init(allocator, resolved_url.items);
        }

        // It's host-relative (starts with "/")
        try resolved_url.appendSlice(allocator, self.scheme);
        try resolved_url.appendSlice(allocator, "://");

        // For file:// URLs, there's no host
        if (std.mem.eql(u8, self.scheme, "file")) {
            try resolved_url.appendSlice(allocator, relative_url);
        } else {
            const host = self.host.?;
            try resolved_url.appendSlice(allocator, host);
            if (!hostHasExplicitPort(host) and self.port != 80 and self.port != 443) {
                try resolved_url.append(allocator, ':');
                const port_str = try std.fmt.allocPrint(allocator, "{d}", .{self.port});
                defer allocator.free(port_str);
                try resolved_url.appendSlice(allocator, port_str);
            }
            try resolved_url.appendSlice(allocator, relative_url);
        }

        return try Url.init(allocator, resolved_url.items);
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

    fn hostHasExplicitPort(host: []const u8) bool {
        if (std.mem.startsWith(u8, host, "[")) return false;
        return std.mem.lastIndexOfScalar(u8, host, ':') != null;
    }

    // Old HTTP helper functions removed - std.http.Client handles this now

    pub fn aboutRequest(self: Url) []const u8 {
        // This is a special case for about:blank
        // We might support more about pages eventually
        _ = self;
        return "<html><body></body></html>";
    }

    /// Fetch a URL without imposing browser/window ownership. Callers own the
    /// returned response according to its scheme: file and HTTP bodies are
    /// allocated, while data and about bodies borrow the URL/static storage.
    pub fn fetchBody(
        allocator: std.mem.Allocator,
        io: std.Io,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
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
        return url.httpRequest(allocator, http_client, cookie_jar, referrer, payload);
    }

    pub fn httpRequest(
        self: Url,
        al: std.mem.Allocator,
        http_client: *std.http.Client,
        cookie_jar: *std.StringHashMap(CookieEntry),
        referrer: ?Url,
        payload: ?[]const u8,
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

        if (self.host) |host_slice| {
            if (cookie_jar.get(host_slice)) |entry| {
                var allow_cookie = true;
                if (entry.same_site == .lax and method != .GET) {
                    if (referrer) |ref| {
                        if (ref.host) |ref_host| {
                            allow_cookie = std.ascii.eqlIgnoreCase(host_slice, ref_host);
                        } else {
                            allow_cookie = false;
                        }
                    }
                }

                if (allow_cookie) {
                    try extra_headers.append(al, .{
                        .name = "Cookie",
                        .value = entry.value,
                    });
                }
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
            @enumFromInt(3)
        else
            .unhandled;

        var csp_header: ?[]u8 = null;
        var csp_header_cleanup = true;
        defer if (csp_header_cleanup) if (csp_header) |hdr| al.free(hdr);

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
                        var raw_value = std.mem.trim(u8, header.value, " ");
                        var same_site_mode: SameSiteMode = .none;

                        if (std.mem.indexOfScalar(u8, raw_value, ';')) |semicolon| {
                            const attributes_slice = raw_value[semicolon + 1 ..];
                            raw_value = std.mem.trim(u8, raw_value[0..semicolon], " ");

                            var attr_iter = std.mem.tokenizeScalar(u8, attributes_slice, ';');
                            while (attr_iter.next()) |attr_raw| {
                                const attr_trimmed = std.mem.trim(u8, attr_raw, " ");
                                if (attr_trimmed.len == 0) continue;

                                if (std.mem.indexOfScalar(u8, attr_trimmed, '=')) |eq_index| {
                                    const key = std.mem.trim(u8, attr_trimmed[0..eq_index], " ");
                                    const value = std.mem.trim(u8, attr_trimmed[eq_index + 1 ..], " ");
                                    if (std.ascii.eqlIgnoreCase(key, "samesite")) {
                                        if (std.ascii.eqlIgnoreCase(value, "lax")) {
                                            same_site_mode = .lax;
                                        } else {
                                            same_site_mode = .none;
                                        }
                                    }
                                } else if (std.ascii.eqlIgnoreCase(attr_trimmed, "samesite")) {
                                    same_site_mode = .lax;
                                }
                            }
                        }

                        const cookie_copy = try al.alloc(u8, raw_value.len);
                        @memcpy(cookie_copy, raw_value);

                        if (cookie_jar.getPtr(cookie_host)) |entry_ptr| {
                            al.free(entry_ptr.value);
                            entry_ptr.* = CookieEntry{
                                .value = cookie_copy,
                                .same_site = same_site_mode,
                            };
                        } else {
                            const host_copy = try al.alloc(u8, cookie_host.len);
                            @memcpy(host_copy, cookie_host);
                            const new_entry = CookieEntry{
                                .value = cookie_copy,
                                .same_site = same_site_mode,
                            };
                            cookie_jar.put(host_copy, new_entry) catch |err| {
                                al.free(cookie_copy);
                                al.free(host_copy);
                                return err;
                            };
                        }
                    } else if (std.ascii.eqlIgnoreCase(header.name, "content-security-policy")) {
                        if (csp_header) |existing| {
                            al.free(existing);
                        }
                        const trimmed = std.mem.trim(u8, header.value, " ");
                        const copy = try al.alloc(u8, trimmed.len);
                        @memcpy(copy, trimmed);
                        csp_header = copy;
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
            std.log.info("Received {d} bytes, status: {d}", .{
                body.len,
                @intFromEnum(response.head.status),
            });

            const result = HttpResponse{
                .body = body,
                .csp_header = csp_header,
            };
            csp_header_cleanup = false;
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
        // Handle special schemes
        if (std.mem.eql(u8, self.scheme, "data")) {
            return std.fmt.bufPrint(buffer, "data:{s}", .{self.path});
        }

        if (std.mem.eql(u8, self.scheme, "about")) {
            return std.fmt.bufPrint(buffer, "about:{s}", .{self.path});
        }

        if (std.mem.eql(u8, self.scheme, "file")) {
            return std.fmt.bufPrint(buffer, "file://{s}", .{self.path});
        }

        // For http/https, check if we should show port
        const host_str = self.host orelse return error.NoHost;
        const has_explicit_port = hostHasExplicitPort(host_str);

        const show_port = !has_explicit_port and ((std.mem.eql(u8, self.scheme, "https") and self.port != 443) or
            (std.mem.eql(u8, self.scheme, "http") and self.port != 80));

        if (show_port) {
            return std.fmt.bufPrint(buffer, "{s}://{s}:{d}{s}", .{
                self.scheme,
                host_str,
                self.port,
                self.path,
            });
        } else {
            return std.fmt.bufPrint(buffer, "{s}://{s}{s}", .{
                self.scheme,
                host_str,
                self.path,
            });
        }
    }
};

const expect = std.testing.expect;

test "file request" {
    const url = try Url.init(std.testing.allocator, "file:///test/path.html");
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "file"));
    try expect(std.mem.eql(u8, url.path, "/test/path.html"));
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

test "URL clone preserves view-source metadata" {
    var original = try Url.init(std.testing.allocator, "view-source:https://example.com/path");
    const cloned = try original.clone(std.testing.allocator);
    original.free(std.testing.allocator);
    original = undefined;
    defer cloned.free(std.testing.allocator);

    try expect(cloned.view_source);
    try expect(std.mem.eql(u8, cloned.scheme, "https"));
    try expect(std.mem.eql(u8, cloned.host.?, "example.com"));
    try expect(std.mem.eql(u8, cloned.path, "/path"));
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

test "HTTP requests identify Zibra and close HTTP/1.1 connections" {
    const headers = [_]std.http.Header{
        .{ .name = "X-Zibra-Test", .value = "present" },
    };
    const options = requestOptions(.unhandled, &headers);

    try std.testing.expectEqual(std.http.Version.@"HTTP/1.1", options.version);
    try expect(!options.keep_alive);
    try std.testing.expectEqualStrings(
        user_agent,
        options.headers.user_agent.override,
    );
    try std.testing.expectEqual(@as(usize, 1), options.extra_headers.len);
    try std.testing.expectEqualStrings("X-Zibra-Test", options.extra_headers[0].name);
    try std.testing.expectEqualStrings("present", options.extra_headers[0].value);
}
