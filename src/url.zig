const std = @import("std");

const ada = @import("ada");

const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Cache = @import("cache.zig").Cache;
const CacheEntry = @import("cache.zig").CacheEntry;

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

// Connection provides a way to handle both TCP and TLS connections
pub const Connection = union(enum) {
    Tcp: std.net.Stream,
    Tls: struct {
        client: std.crypto.tls.Client,
        stream: std.net.Stream,
    },

    pub fn sendRequest(self: *Connection, request_content: []const u8) !void {
        switch (self.*) {
            .Tcp => |c| try c.writeAll(request_content),
            .Tls => |*c| {
                try c.client.writeAll(c.stream, request_content);
            },
        }
    }

    pub fn readHeaderResponse(self: *Connection, al: std.mem.Allocator) !*Response {
        // Create dynamic array to store total response
        var response_list = std.ArrayList(u8).init(al);
        defer response_list.deinit();

        // Create buffer for response
        // ! This is a workaround for a bug in the std library
        // ! https://github.com/ziglang/zig/issues/14573
        // ! Make a super large buffer so the std lib doesn't have to refill it
        const buffer_size = 20000;
        var temp_buffer: [buffer_size]u8 = undefined;
        var header_end_index: ?usize = null;

        // Keep reading the response in `buffer_size` chunks, appending
        // each to the response_list
        while (true) {
            const bytes_read = switch (self.*) {
                .Tcp => |c| try c.read(&temp_buffer),
                .Tls => |*c| try c.client.read(c.stream, &temp_buffer),
            };
            // Connection closed prematurely?
            if (bytes_read == 0) break;

            try response_list.appendSlice(temp_buffer[0..bytes_read]);

            // see if end of headers is near
            header_end_index = std.mem.indexOf(u8, response_list.items, "\r\n\r\n");
            if (header_end_index != null) {
                break;
            }
        }

        if (header_end_index == null) {
            return error.NoCompleteHeaders;
        }
        // Slice to separate headers and body
        const header_section_len = header_end_index.? + 4;
        const headers_data = response_list.items[0..header_end_index.?];
        const body_start = response_list.items[header_section_len..];

        // Parse the headers
        const status = try parseStatusLine(headers_data);
        const headers = try parseHeaders(headers_data, al);

        // Return the `Response` struct
        const response = try al.create(Response);
        response.status = status;
        response.headers = headers;

        response.body = if (body_start.len > 0) blk: {
            const body_copy = try al.alloc(u8, body_start.len);
            @memcpy(body_copy, body_start);
            break :blk body_copy;
        } else null;

        return response;
    }

    fn readRemainingBody(
        self: *Connection,
        body_list: *std.ArrayList(u8),
        remaining: usize,
    ) !void {

        // ! This is a workaround for a bug in the std library
        // ! https://github.com/ziglang/zig/issues/14573
        // ! Make a super large buffer so the std lib doesn't have to refill it
        const buffer_size = 30000;
        var temp_buffer: [buffer_size]u8 = undefined;

        var to_read = remaining;
        while (to_read > 0) {
            const chunk_size = @min(to_read, buffer_size);
            const bytes_read = switch (self.*) {
                .Tls => |*c| try c.client.read(c.stream, temp_buffer[0..chunk_size]),
                .Tcp => |c| try c.read(temp_buffer[0..chunk_size]),
            };

            // If bytes_read is 0, the connection was closed unexpectedly
            if (bytes_read == 0) {
                return error.IncompleteBody;
            }

            try body_list.appendSlice(temp_buffer[0..bytes_read]);
            to_read -= bytes_read;
        }

        // Final Validation: Ensure we actually read the expected number of bytes
        if (to_read > 0) {
            return error.IncompleteBody;
        }
    }

    pub fn readBody(
        self: *Connection,
        al: std.mem.Allocator,
        content_length: usize,
        already_received: ?[]const u8,
    ) ![]const u8 {
        // Initialize a list to store the full body
        var body_list = std.ArrayList(u8).init(al);
        defer body_list.deinit();

        if (already_received) |data| {
            // Append the already-received portion of the body
            try body_list.appendSlice(data);
        }

        // If there's more body to read, do it in chunks
        if (content_length > body_list.items.len) {
            const remaining_to_read = content_length - body_list.items.len;
            try self.readRemainingBody(&body_list, remaining_to_read);
        }

        // Validate that we have the full body
        if (body_list.items.len != content_length) {
            return error.IncompleteBody;
        }

        // Flatten the body into a single allocated slice for the final return
        const final_body = body_list.items[0..body_list.items.len];
        const body = try al.alloc(u8, final_body.len);
        @memcpy(body, final_body);

        return body;
    }

    fn readChunkedBody(self: *Connection, al: std.mem.Allocator) ![]u8 {
        var body_list = std.ArrayList(u8).init(al);
        defer body_list.deinit();

        while (true) {
            // Read the chunk size line
            const chunk_size_str = try self.readLine(al);
            defer al.free(chunk_size_str);
            const chunk_size = std.fmt.parseInt(usize, std.mem.trimRight(u8, chunk_size_str, " \r\n"), 16) catch return error.InvalidChunkSize;
            if (chunk_size == 0) break;

            // Allocate memory for the chunk and read it
            const chunk = try al.alloc(u8, chunk_size);
            defer al.free(chunk);
            try self.readExact(chunk);

            // Append the chunk to the body list
            try body_list.appendSlice(chunk);

            // Consume trailing CRLF
            const end = try self.readLine(al);
            al.free(end);
        }

        // Flatten the body into a single slice
        return body_list.toOwnedSlice();
    }

    fn readLine(self: *Connection, al: std.mem.Allocator) ![]u8 {
        var line = std.ArrayList(u8).init(al);

        const buffer_size = 1;
        var temp_buffer: [buffer_size]u8 = undefined;

        while (true) {
            const bytes_read = switch (self.*) {
                .Tcp => |c| try c.read(&temp_buffer),
                .Tls => |*c| try c.client.read(c.stream, &temp_buffer),
            };

            // Connection closed prematurely
            if (bytes_read == 0) break;

            // Append character to line
            try line.append(temp_buffer[0]);

            // Check for line termination
            if (line.items.len >= 2 and std.mem.eql(u8, line.items[line.items.len - 2 ..], "\r\n")) {
                const f = try line.toOwnedSlice();
                // Return without CRLF
                return f;
            }
        }

        return error.IncompleteLine;
    }
    fn readExact(self: *Connection, buffer: []u8) !void {
        var total_read: usize = 0;

        while (total_read < buffer.len) {
            const bytes_read = switch (self.*) {
                .Tcp => |c| try c.read(buffer[total_read..]),
                .Tls => |*c| try c.client.read(c.stream, buffer[total_read..]),
            };

            if (bytes_read == 0) {
                // Connection closed prematurely
                return error.IncompleteBody;
            }

            total_read += bytes_read;
        }
    }
};

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

        var u = Url{};

        u.scheme = ada_url.getProtocol();
        u.host = ada_url.getHost();
        u.path = ada_url.getPathname();

        if (std.mem.eql(u8, u.scheme, "view-source:")) {
            u.view_source = true;
        }

        if (std.mem.eql(u8, u.scheme, "data:")) {
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
            var attributes = std.ArrayList([]const u8).init(allocator);
            const has_attributes = !std.mem.eql(u8, mime_type, url);
            if (has_attributes) {
                while (split_iter.next()) |attr| {
                    try attributes.append(attr);
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

        // make a copy of the url
        // var local_url = ArrayList(u8).init(allocator);
        // defer local_url.deinit();
        // try local_url.appendSlice(url);

        // check for view-source
        // var view_source = false;
        // if (url.len >= 12 and std.mem.eql(u8, url[0..12], "view-source:")) {
        //     local_url.items = local_url.items[12..];
        //     view_source = true;
        // }

        // // check for data
        // if (url.len >= 5 and std.mem.eql(u8, url[0..5], "data:")) {
        //     const scheme = url[0..4];
        //     var rest = url[5..];

        //     // find the first comma, everything after is the data
        //     var data: []const u8 = undefined;
        //     if (std.mem.indexOf(u8, rest, ",")) |comma_index| {
        //         data = rest[comma_index + 1 ..];
        //         rest = rest[0..comma_index];
        //     } else {
        //         return error.DataUriBadFormat;
        //     }
        //     // split on ';' to find the mime type and attributes
        //     var split_iter = std.mem.splitSequence(u8, rest, ";");
        //     const mime_type = split_iter.first();
        //     var attributes = std.ArrayList([]const u8).init(allocator);
        //     const has_attributes = !std.mem.eql(u8, mime_type, url);
        //     if (has_attributes) {
        //         while (split_iter.next()) |attr| {
        //             try attributes.append(attr);
        //         }
        //     }

        //     var u = Url{};

        //     // Allocate memory for strings.
        //     const mime_type_alloc = try allocator.alloc(u8, mime_type.len);
        //     @memcpy(mime_type_alloc, mime_type);

        //     const data_alloc = try allocator.alloc(u8, data.len);
        //     @memcpy(data_alloc, data);

        //     const scheme_alloc = try allocator.alloc(u8, scheme.len);
        //     @memcpy(scheme_alloc, scheme);

        //     u.path = data_alloc;
        //     u.mime_type = mime_type_alloc;
        //     u.scheme = scheme_alloc;
        //     u.attributes = attributes;
        //     u.view_source = view_source;

        //     return u;
        // } else {
        //     // split the url by "://"
        //     var split_iter = std.mem.splitSequence(u8, local_url.items, "://");
        //     const scheme = split_iter.first();

        //     // delimter not found, bail
        //     if (std.mem.eql(u8, scheme, local_url.items)) return error.NoSchemeFound;

        //     if (!std.mem.eql(u8, scheme, "http") and
        //         !std.mem.eql(u8, scheme, "https") and
        //         !std.mem.eql(u8, scheme, "file")) return error.UnsupportedScheme;

        //     // get everything after the scheme
        //     const rest = split_iter.rest();
        //     if (rest.len == 0) {
        //         return error.NoHostFound;
        //     }

        //     // allocate memory for the scheme
        //     const scheme_alloc = try allocator.alloc(u8, scheme.len);
        //     @memcpy(scheme_alloc, scheme);

        //     // gather the rest of the url into a dynamic array
        //     var rest_of_url = ArrayList(u8).init(allocator);
        //     defer rest_of_url.deinit();
        //     try rest_of_url.appendSlice(rest);

        //     // Append a '/' if it doesn't exist
        //     if (!std.mem.containsAtLeast(u8, rest_of_url.items, 1, "/")) {
        //         try rest_of_url.append('/');
        //     }

        //     // Split on '/' to find host
        //     split_iter = std.mem.splitSequence(u8, rest_of_url.items, "/");
        //     var host = split_iter.first();

        //     // If an optional ':port' is present, parse it
        //     var port: ?u16 = null;
        //     if (std.mem.containsAtLeast(u8, host, 1, ":")) {
        //         var host_iter = std.mem.splitScalar(u8, host, ':');
        //         host = host_iter.first();
        //         const p = host_iter.next().?;
        //         port = try std.fmt.parseInt(u16, p, 10);
        //     }

        //     // everything else is the path, allocate memory for it
        //     // if the path is '/', then this will be an empty string
        //     const path = split_iter.rest();
        //     var path_alloc = try allocator.alloc(u8, path.len + 1);

        //     // Prepend a '/' to the path
        //     path_alloc[0] = '/';
        //     @memcpy(path_alloc[1..], path);

        //     var u = Url{};
        //     u.scheme = scheme_alloc;
        //     u.path = path_alloc;
        //     u.view_source = view_source;

        //     // handle default port
        //     if (std.mem.eql(u8, scheme, "https")) {
        //         u.is_https = true;
        //         if (port) |p| {
        //             u.port = p;
        //         } else {
        //             u.port = 443;
        //         }
        //     } else {
        //         if (port) |p| {
        //             u.port = p;
        //         } else {
        //             u.port = 80;
        //         }
        //         u.is_https = false;
        //     }

        //     // allocate memory for the host, which won't be present in the case of a file scheme
        //     if (host.len != 0) {
        //         const host_alloc = try allocator.alloc(u8, host.len);
        //         @memcpy(host_alloc, host);
        //         u.host = host_alloc;
        //     }

        //     std.log.debug("\nScheme: {s}\nHost: {s}\nPath: {s}\nPort: {d}\nIs HTTPS: {any}", .{
        //         u.scheme,
        //         u.host orelse "null",
        //         u.path,
        //         u.port,
        //         u.is_https,
        //     });

        //     return u;
        // }
    }

    pub fn free(self: Url, allocator: std.mem.Allocator) void {
        allocator.free(self.scheme);
        if (self.host) |_| allocator.free(self.host.?);

        if (self.mime_type) |_| allocator.free(self.mime_type.?);
        if (self.attributes) |_| self.attributes.?.deinit();

        allocator.free(self.path);
    }

    // Helper function to create the HTTP request content.
    fn createRequestContent(self: Url, al: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            al,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Connection: keep-alive\r\n" ++
                "User-Agent: zibra/0.1\r\n" ++
                "\r\n",
            .{ self.path, self.host.? },
        );
    }

    // Helper function to retrieve or create a connection.
    fn getOrCreateConnection(
        self: Url,
        al: std.mem.Allocator,
        socket_map: *std.StringHashMap(Connection),
    ) !Connection {
        return socket_map.get(self.host.?) orelse blk: {
            // Create socket connection
            const tcp_stream = try std.net.tcpConnectToHost(
                al,
                self.host.?,
                self.port,
            );

            const new_connection: Connection = if (self.is_https) conn_blk: {
                // create required certificate bundle
                // ! API changes in zig 0.14.0
                var bundle = std.crypto.Certificate.Bundle{};
                try bundle.rescan(al);
                defer bundle.deinit(al);

                // create the tls client
                const tls_client = try std.crypto.tls.Client.init(tcp_stream, bundle, self.host.?);
                break :conn_blk Connection{ .Tls = .{
                    .client = tls_client,
                    .stream = tcp_stream,
                } };
            } else Connection{ .Tcp = tcp_stream };

            // save the connection for future use
            try socket_map.put(self.host.?, new_connection);
            break :blk new_connection;
        };
    }

    fn newRedirectUrl(
        self: Url,
        al: std.mem.Allocator,
        response: *Response,
    ) !Url {
        std.log.info("Redirecting to {s}", .{response.headers.get("location").?});
        const location: []const u8 = response.headers.get("location").?;
        // In case we need to build up the string, allocate memory for it
        var new_url_path = try al.alloc(u8, location.len);
        defer al.free(new_url_path);
        @memcpy(new_url_path, location);

        // Check if location is relative
        if (!std.mem.containsAtLeast(u8, location, 1, "://")) {
            // Free the old path or it will leak!
            al.free(new_url_path);
            // build up location reusing current scheme and host
            new_url_path = try std.fmt.allocPrint(al, "{s}://{s}{s}", .{ self.scheme, self.host.?, location });
        }
        const new_url = try Url.init(al, new_url_path);
        return new_url;
    }

    pub fn httpRequest(
        self: Url,
        al: std.mem.Allocator,
        socket_map: *StringHashMap(Connection),
        cache: *Cache,
        redirect_count: u8,
    ) ![]const u8 {
        // Firefox limits to 20 too.
        if (redirect_count > 20) {
            return error.TooManyRedirects;
        }

        // Check the cache
        if (cache.get(self.path)) |entry| {
            const now: u64 = @intCast(std.time.milliTimestamp());
            if (entry.max_age) |max_age| {
                if ((now - entry.timestampe) / 1000 <= max_age) {
                    return entry.body;
                }
            }
        }

        const request_content = try createRequestContent(self, al);
        defer al.free(request_content);

        std.log.debug("Request:\n{s}", .{request_content});
        std.log.info("Connecting to {s}:{d}", .{ self.host.?, self.port });

        // Define socker and connect to it. Use an existing one if available
        var conn = try self.getOrCreateConnection(al, socket_map);
        try conn.sendRequest(request_content);

        var response = try conn.readHeaderResponse(al);
        defer response.free(al);

        if (response.headers.contains("transfer-encoding")) {
            const transfer_encoding = response.headers.get("transfer-encoding").?;

            // check for chunked
            if (std.mem.indexOf(u8, transfer_encoding, "chunked")) |_| {
                const body = try conn.readChunkedBody(al);
                // check for gzip
                if (response.headers.get("content-encoding")) |enc| {
                    if (std.mem.indexOf(u8, enc, "gzip")) |_| {
                        defer al.free(body);
                        // Create a reader for the gzip-compressed body
                        var input_stream = std.io.fixedBufferStream(body);

                        // Initialize the gzip decompressor
                        var decompressor = std.compress.gzip.decompressor(input_stream.reader());

                        // Create an ArrayList to hold the decompressed output
                        var output = std.ArrayList(u8).init(al);
                        defer output.deinit();

                        const buffer_size = 1024;
                        var buffer = try al.alloc(u8, buffer_size);
                        defer al.free(buffer);

                        while (true) {
                            const bytes_read = try decompressor.read(buffer);
                            if (bytes_read == 0) break;
                            try output.appendSlice(buffer[0..bytes_read]);
                        }

                        // Return the decompressed data as a slice
                        return output.toOwnedSlice();
                    }
                }
                return body;
            }
        }

        if (self.is_https) {
            // Remove the connection from the map
            // Do this before redirect, which might use TLS again
            // TODO: Somehow reuse the connection for TLS?
            _ = socket_map.remove(self.host.?);
        }

        var cache_entry: ?CacheEntry = if (isCacheableStatusCode(response.status) and response.headers.contains("cache-control")) blk: {
            const cc = response.headers.get("cache-control").?;
            if (std.mem.indexOf(u8, cc, "no-store")) |_| {
                // Don't cache this response
                break :blk null;
            } else {
                var max_age: ?u64 = null;
                if (std.mem.indexOf(u8, cc, "max-age")) |start| {
                    // skip max-age=
                    const max_age_str = cc[start + 8 ..];
                    max_age = try std.fmt.parseInt(u64, max_age_str, 10);
                }
                break :blk .{
                    .body = "",
                    .timestampe = @intCast(std.time.milliTimestamp()),
                    .max_age = max_age,
                };
            }
        } else null;

        if (isRedirectStatusCode(response.status) and response.headers.contains("location")) {
            const new_url = try self.newRedirectUrl(
                al,
                response,
            );
            defer new_url.free(al);
            return new_url.httpRequest(
                al,
                socket_map,
                cache,
                redirect_count + 1,
            );
        }

        // Determine content length to know how much to body to read.
        var content_length: usize = 0;
        if (response.headers.contains("content-length")) {
            const cl_str: []const u8 = response.headers.get("content-length").?;
            content_length = std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength;
        }

        const body = try conn.readBody(
            al,
            content_length,
            response.body,
        );

        if (cache_entry) |*c| {
            const body_alloc = try al.alloc(u8, body.len);
            defer al.free(body_alloc);
            @memcpy(body_alloc, body);
            c.*.body = body_alloc;
            try cache.set(self.path, c.*);
            cache.evict_if_needed(100);
        }

        try printHeaders(al, response.headers);

        return body;
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

fn parseHeaders(data: []const u8, al: std.mem.Allocator) !StringHashMap([]const u8) {
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
    var parts = std.mem.split(u8, status_line, " ");
    // Skip "HTTP/1.1"
    _ = parts.next();
    const status_str = parts.next() orelse return error.NoStatusCodeFound;

    return std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidStatusCode;
}

// Print the headers
fn printHeaders(al: std.mem.Allocator, headers: std.StringHashMap([]const u8)) !void {
    var headers_list = std.ArrayList(u8).init(al);
    defer headers_list.deinit();

    try headers_list.appendSlice("Headers:\n");

    var iter = headers.iterator();
    while (iter.next()) |entry| {
        const header_line = try std.fmt.allocPrint(al, "{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer al.free(header_line);
        try headers_list.appendSlice(header_line);
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
