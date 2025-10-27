const std = @import("std");

const ada = @import("ada");

const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Cache = @import("cache.zig").Cache;
const CacheEntry = @import("cache.zig").CacheEntry;

pub const SameSiteMode = enum { none, lax };

pub const CookieEntry = struct {
    value: []u8,
    same_site: SameSiteMode = .none,
};

pub const HttpResponse = struct {
    body: []const u8,
    csp_header: ?[]u8 = null,
};

const dbg = std.debug.print;

fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

pub const Response = struct {
    status: u16,
    headers: StringHashMap([]const u8),
    body: ?[]const u8,

    pub fn free(self: *Response, al: std.mem.Allocator) void {
        // Free all keys and values
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            al.free(entry.key_ptr.*);
            al.free(entry.value_ptr.*);
        }

        self.headers.deinit();

        // Free body if it exists
        if (self.body) |_| al.free(self.body.?);

        // Destroy the Response struct itself
        al.destroy(self);
    }
};

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
        std.debug.print("checking url: {s}\n", .{url});
        const ada_url = try ada.Url.init(url);

        var u = Url{ .ada_url = ada_url };

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
        std.debug.print("scheme: {s}\n", .{u.scheme});

        if (std.mem.eql(u8, u.scheme, "view-source")) {
            u.view_source = true;

            // Extract the actual URL after view-source:
            const actual_url = url[std.mem.indexOf(u8, url, ":").? + 1 ..];

            // Create a new URL object for the actual URL
            const actual_ada_url = try ada.Url.init(actual_url);

            // Update the URL properties with the actual URL's properties (strip colon)
            const actual_protocol = actual_ada_url.getProtocol();
            u.scheme = if (std.mem.endsWith(u8, actual_protocol, ":"))
                actual_protocol[0 .. actual_protocol.len - 1]
            else
                actual_protocol;

            u.host = actual_ada_url.getHost();
            u.path = actual_ada_url.getPathname();
            u.is_https = std.mem.eql(u8, u.scheme, "https");
            u.port = if (u.is_https) 443 else 80;

            // Free the temporary ada_url
            ada_url.free();
        }

        if (std.mem.eql(u8, u.scheme, "data")) {
            // ! ada will eventually support parsing data urls
            // ! https://github.com/ada-url/ada/pull/756/
            var rest = u.path;

            // find the first comma, everything after is the data
            var data: []const u8 = undefined;
            if (std.mem.indexOf(u8, rest, ",")) |comma_index| {
                rest = rest[0..comma_index];
                data = rest[comma_index + 1 ..];
            } else {
                return error.DataUriBadFormat;
            }
            // split on ';' to find the mime type and attributes
            var split_iter = std.mem.splitSequence(u8, rest, ";");
            const mime_type = split_iter.first();
            var attributes = std.ArrayList([]const u8).empty;
            const has_attributes = !std.mem.eql(u8, mime_type, url);
            if (has_attributes) {
                while (split_iter.next()) |attr| {
                    try attributes.append(allocator, attr);
                }
            }
            // Allocate memory for strings.
            const mime_type_alloc = try allocator.alloc(u8, mime_type.len);
            @memcpy(mime_type_alloc, mime_type);

            const data_alloc = try allocator.alloc(u8, data.len);
            @memcpy(data_alloc, data);

            u.path = data_alloc;
            u.mime_type = mime_type_alloc;
            u.attributes = attributes;
        }
        return u;
    }

    pub fn free(self: Url, allocator: std.mem.Allocator) void {
        if (self.mime_type) |_| allocator.free(self.mime_type.?);
        if (self.attributes) |attrs| {
            var a = attrs;
            a.deinit(allocator);
        }
        self.ada_url.free();
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

    pub fn httpRequest(
        self: Url,
        al: std.mem.Allocator,
        http_client: *std.http.Client,
        cache: *Cache,
        cookie_jar: *std.StringHashMap(CookieEntry),
        referrer: ?Url,
        payload: ?[]const u8,
    ) !HttpResponse {
        // Check the cache (only for GET requests)
        if (payload == null) {
            if (cache.get(self.path)) |entry| {
                const now: u64 = @intCast(std.time.milliTimestamp());
                if (entry.max_age) |max_age| {
                    if ((now - entry.timestampe) / 1000 <= max_age) {
                        std.log.info("Cache hit for {s}", .{self.path});
                        return HttpResponse{ .body = entry.body, .csp_header = null };
                    }
                }
            }
        }

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

        // Build the outgoing header list (Content-Type + Cookie when available)
        var header_storage: [2]std.http.Header = undefined;
        var header_count: usize = 0;
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
                    header_storage[header_count] = .{
                        .name = "Cookie",
                        .value = entry.value,
                    };
                    header_count += 1;
                }
            }
        }

        if (payload != null) {
            header_storage[header_count] = .{
                .name = "Content-Type",
                .value = "application/x-www-form-urlencoded",
            };
            header_count += 1;
        }

        const extra_headers = if (header_count == 0)
            &[_]std.http.Header{}
        else
            header_storage[0..header_count];

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
            var req = try http_client.request(method, uri, .{
                .redirect_behavior = redirect_behavior,
                .extra_headers = extra_headers,
            });
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
                error.ReadFailed => return response.bodyErr().?,
                else => |e| return e,
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

    pub fn fileRequest(self: Url, al: std.mem.Allocator) ![]const u8 {
        const html_file = std.fs.cwd().openFile(self.path, .{}) catch |err| {
            std.log.err("Failed to open file {s}: {any}", .{ self.path, err });
            // EX_NOINPUT: cannot open input
            std.process.exit(66);
        };

        defer html_file.close();

        const html_content = try html_file.readToEndAlloc(al, 4096);
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

        const show_port = (std.mem.eql(u8, self.scheme, "https") and self.port != 443) or
            (std.mem.eql(u8, self.scheme, "http") and self.port != 80);

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

pub fn isRedirectStatusCode(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

pub fn isCacheableStatusCode(status: u16) bool {
    return status == 200 or status == 203 or status == 204 or status == 206 or status == 300 or status == 301 or status == 404 or status == 405 or status == 410 or status == 414 or status == 501;
}

// Parse the status line
// Returns a tuple of version, status, and explanation
fn parseStatus(line: []const u8) !struct {
    []const u8,
    []const u8,
    []const u8,
} {
    var line_iter = std.mem.splitScalar(u8, line, ' ');
    const version = line_iter.next();
    const status = line_iter.next();
    const explanation = line_iter.rest();

    if (version == null or status == null) {
        return error.InvalidStatusLine;
    }

    return .{ version.?, status.?, explanation };
}

// Old HTTP parsing functions removed - std.http.Client handles headers now

fn oldParseHeaders(data: []const u8, al: std.mem.Allocator) !StringHashMap([]const u8) {
    // Define a hashmap to store the headers
    var headers = StringHashMap([]const u8).init(al);

    var lines = std.mem.splitSequence(
        u8,
        data,
        "\r\n",
    );

    // Parse the headers
    while (lines.next()) |header_line| {
        // Empty line indicates end of headers
        if (std.mem.eql(u8, header_line, "")) {
            break;
        }

        // Split the header line by ':' for the key and value
        var line_iter = std.mem.splitScalar(u8, header_line, ':');

        const header_key = line_iter.next();
        if (header_key == null) {
            return error.NoHeaderNameFound;
        }
        // normalize the key to lowercase
        const lowercase_header_name = try std.ascii.allocLowerString(al, header_key.?);
        const result = try headers.getOrPut(lowercase_header_name);

        // Remove whitespace because it's insignificant
        const header_value = std.mem.trim(u8, line_iter.rest(), " ");

        // If duplicate headers are sent, we need to free the duplicated header name
        // ! If duplicate headers are sent, only the first one will be stored.
        if (result.found_existing) {
            al.free(lowercase_header_name);
        }
        const value_copy = try al.alloc(u8, header_value.len);
        @memcpy(value_copy, header_value);
        result.value_ptr.* = value_copy;
    }
    return headers;
}

fn parseStatusLine(headers_data: []const u8) !u16 {
    var lines = std.mem.splitSequence(u8, headers_data, "\r\n");
    const status_line = lines.next() orelse return error.NoStatusLineFound;

    std.log.info("{s}", .{status_line});

    // Parse "HTTP/1.1 200 OK"
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    // Skip "HTTP/1.1"
    _ = parts.next();
    const status_str = parts.next() orelse return error.NoStatusCodeFound;

    return std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidStatusCode;
}

// Print the headers
fn printHeaders(al: std.mem.Allocator, headers: std.StringHashMap([]const u8)) !void {
    var headers_list = std.ArrayList(u8).empty;
    defer headers_list.deinit(al);

    try headers_list.appendSlice(al, "Headers:\n");

    var iter = headers.iterator();
    while (iter.next()) |entry| {
        const header_line = try std.fmt.allocPrint(al, "{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer al.free(header_line);
        try headers_list.appendSlice(al, header_line);
    }

    std.log.info("{s}", .{headers_list.items});
}

const expect = std.testing.expect;

test "file request" {
    const url = try Url.init(std.testing.allocator, "file:///test/path.html", false);
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "file"));
    try expect(std.mem.eql(u8, url.path, "/test/path.html"));
}

test "data request" {
    const url = try Url.init(std.testing.allocator, "data:text/html,Hello%20World!", false);
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "data"));
    try expect(std.mem.eql(u8, url.path, "Hello%20World!"));
    try expect(std.mem.eql(u8, url.mime_type.?, "text/html"));
}

test "data request with attributes" {
    const url = try Url.init(std.testing.allocator, "data:text/html;charset=utf-8;base64,SGVsbG8gV29ybGQh", false);
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "data"));
    try expect(std.mem.eql(u8, url.path, "SGVsbG8gV29ybGQh"));
    try expect(std.mem.eql(u8, url.mime_type.?, "text/html"));
    try expect(url.attributes.?.items.len == 2);
    try expect(std.mem.eql(u8, url.attributes.?.items[0], "charset=utf-8"));
    try expect(std.mem.eql(u8, url.attributes.?.items[1], "base64"));
}

test "http request" {
    const url = try Url.init(std.testing.allocator, "http://example.com", false);
    defer url.free(std.testing.allocator);
    try expect(std.mem.eql(u8, url.scheme, "http"));
    try expect(std.mem.eql(u8, url.host.?, "example.com"));
    try expect(std.mem.eql(u8, url.path, "/"));
    try expect(url.port == 80);
    try expect(!url.is_https);
}
