const std = @import("std");
const ArrayList = std.ArrayList;

const dbg = std.debug.print;

fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

const stdout = std.io.getStdOut().writer();

// Connection provides a way to handle both TCP and TLS connections
pub const Connection = union(enum) {
    Tcp: std.net.Stream,
    Tls: struct {
        client: std.crypto.tls.Client,
        stream: std.net.Stream,
    },
};

pub const Url = struct {
    scheme: []const u8 = undefined,
    host: ?[]const u8 = null,
    path: []const u8 = undefined,
    port: u16 = 80,
    is_https: bool = false,
    mime_type: ?[]const u8 = null,
    attributes: ?std.ArrayList([]const u8) = null,
    view_source: bool = false,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, debug: bool) !Url {
        // make a copy of the url
        var local_url = ArrayList(u8).init(allocator);
        defer local_url.deinit();
        try local_url.appendSlice(url);

        // check for view-source
        var view_source = false;
        if (url.len >= 12 and std.mem.eql(u8, url[0..12], "view-source:")) {
            local_url.items = local_url.items[12..];
            view_source = true;
        }

        // check for data
        if (url.len >= 5 and std.mem.eql(u8, url[0..5], "data:")) {
            const scheme = url[0..4];
            var rest = url[5..];

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
            var attributes = std.ArrayList([]const u8).init(allocator);
            const has_attributes = !std.mem.eql(u8, mime_type, url);
            if (has_attributes) {
                while (split_iter.next()) |attr| {
                    try attributes.append(attr);
                }
            }

            var u = Url{};

            // Allocate memory for strings.
            const mime_type_alloc = try allocator.alloc(u8, mime_type.len);
            @memcpy(mime_type_alloc, mime_type);

            const data_alloc = try allocator.alloc(u8, data.len);
            @memcpy(data_alloc, data);

            const scheme_alloc = try allocator.alloc(u8, scheme.len);
            @memcpy(scheme_alloc, scheme);

            u.path = data_alloc;
            u.mime_type = mime_type_alloc;
            u.scheme = scheme_alloc;
            u.attributes = attributes;
            u.view_source = view_source;

            return u;
        } else {
            // split the url by "://"
            var split_iter = std.mem.splitSequence(u8, local_url.items, "://");
            const scheme = split_iter.first();

            // delimter not found, bail
            if (std.mem.eql(u8, scheme, local_url.items)) return error.NoSchemeFound;

            if (!std.mem.eql(u8, scheme, "http") and
                !std.mem.eql(u8, scheme, "https") and
                !std.mem.eql(u8, scheme, "file")) return error.UnsupportedScheme;

            // get everything after the scheme
            const rest = split_iter.rest();
            if (rest.len == 0) {
                return error.NoHostFound;
            }

            // allocate memory for the scheme
            const scheme_alloc = try allocator.alloc(u8, scheme.len);
            @memcpy(scheme_alloc, scheme);

            // gather the rest of the url into a dynamic array
            var rest_of_url = ArrayList(u8).init(allocator);
            defer rest_of_url.deinit();
            try rest_of_url.appendSlice(rest);

            // Append a '/' if it doesn't exist
            if (!std.mem.containsAtLeast(u8, rest_of_url.items, 1, "/")) {
                try rest_of_url.append('/');
            }

            // Split on '/' to find host
            split_iter = std.mem.splitSequence(u8, rest_of_url.items, "/");
            var host = split_iter.first();

            // If an optional ':port' is present, parse it
            var port: ?u16 = null;
            if (std.mem.containsAtLeast(u8, host, 1, ":")) {
                var host_iter = std.mem.splitScalar(u8, host, ':');
                host = host_iter.first();
                const p = host_iter.next().?;
                port = try std.fmt.parseInt(u16, p, 10);
            }

            // everything else is the path, allocate memory for it
            // if the path is '/', then this will be an empty string
            const path = split_iter.rest();
            var path_alloc = try allocator.alloc(u8, path.len + 1);

            // Prepend a '/' to the path
            path_alloc[0] = '/';
            @memcpy(path_alloc[1..], path);

            var u = Url{};
            u.scheme = scheme_alloc;
            u.path = path_alloc;
            u.view_source = view_source;

            // handle default port
            if (std.mem.eql(u8, scheme, "https")) {
                u.is_https = true;
                if (port) |p| {
                    u.port = p;
                } else {
                    u.port = 443;
                }
            } else {
                if (port) |p| {
                    u.port = p;
                } else {
                    u.port = 80;
                }
                u.is_https = false;
            }

            // allocate memory for the host, which won't be present in the case of a file scheme
            if (host.len != 0) {
                const host_alloc = try allocator.alloc(u8, host.len);
                @memcpy(host_alloc, host);
                u.host = host_alloc;
            }

            if (debug) {
                dbg("Scheme: {s}\n", .{u.scheme});
                if (u.host) |h| dbg("Host: {s}\n", .{h}) else dbgln("Host: localhost");
                dbg("Path: {s}\n", .{u.path});
                dbg("Port: {d}\n", .{u.port});
                dbg("Is HTTPS: {any}\n", .{u.is_https});
            }
            return u;
        }
    }

    pub fn free(self: Url, allocator: std.mem.Allocator) void {
        allocator.free(self.scheme);
        if (self.host) |_| allocator.free(self.host.?);

        if (self.mime_type) |_| allocator.free(self.mime_type.?);
        if (self.attributes) |_| self.attributes.?.deinit();

        allocator.free(self.path);
    }

    fn httpRequest(
        self: Url,
        al: std.mem.Allocator,
        socket_map: *std.StringHashMap(Connection),
        redirect_count: u8,
        debug: bool,
    ) ![]const u8 {
        // Firefox limits to 20 too.
        if (redirect_count > 20) {
            return error.TooManyRedirects;
        }
        // Create the request text, allocating memory as needed
        const request_content = try std.fmt.allocPrint(
            al,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Connection: keep-alive\r\n" ++
                "User-Agent: zibra/0.1\r\n" ++
                "\r\n",
            .{ self.path, self.host.? },
        );
        defer al.free(request_content);

        if (debug) dbg("Request:\n{s}", .{request_content});

        dbg("Connecting to {s}:{d}\n", .{ self.host.?, self.port });

        // Define socker and connect to it. Use an existing one if available
        var conn = socket_map.get(self.host.?) orelse conn_blk: {
            // Create socket connection
            const tcp_stream = try std.net.tcpConnectToHost(
                al,
                self.host.?,
                self.port,
            );
            const new_connection: Connection = if (self.is_https) blk: {
                // create required certificate bundle
                // ! API changes in zig 0.14.0
                var bundle = std.crypto.Certificate.Bundle{};
                try bundle.rescan(al);
                defer bundle.deinit(al);

                // create the tls client
                const tls_client = try std.crypto.tls.Client.init(tcp_stream, bundle, self.host.?);
                break :blk Connection{ .Tls = .{
                    .client = tls_client,
                    .stream = tcp_stream,
                } };
            } else Connection{ .Tcp = tcp_stream };

            // save the connection for future use
            try socket_map.put(self.host.?, new_connection);
            break :conn_blk new_connection;
        };

        // send the request
        switch (conn) {
            .Tcp => |c| try c.writeAll(request_content),
            .Tls => |*c| try c.client.writeAll(c.stream, request_content),
        }

        // Create dynamic array to store total response
        var response_list = std.ArrayList(u8).init(al);
        defer response_list.deinit();

        // Create buffer for response
        // ! This is a workaround for a bug in the std library
        // ! https://github.com/ziglang/zig/issues/14573
        // ! Make a super large buffer so the std lib doesn't have to refill it
        const buffer_size = 10000;
        var temp_buffer: [buffer_size]u8 = undefined;
        var bytes_read: usize = 0;
        var header_end_index: ?usize = null;

        // Keep reading the response in `buffer_size` chunks, appending
        // each to the response_list
        while (true) {
            bytes_read = switch (conn) {
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

        if (self.is_https) {
            // Remove the connection from the map
            // TODO: Somehow reuse the connection for TLS?
            _ = socket_map.remove(self.host.?);
        }

        // Flatten the response_list into a single slice
        const response = response_list.items[0..response_list.items.len];
        const header_section_len = header_end_index.? + 4;

        if (debug) dbg("Response:\n{s}", .{response});

        // Parse the response line by line
        var response_iter = std.mem.splitSequence(
            u8,
            response,
            "\r\n",
        );

        // The first line has the response status
        const status_line = response_iter.next() orelse return error.NoStatusLineFound;
        const version, const status, const explanation = try parseStatus(status_line);

        dbg("{s} {s} {s}\n", .{ version, status, explanation });

        // Define a hashmap to store the headers
        var headers = std.StringHashMap([]const u8).init(al);
        defer {
            // ensure keys are freed too
            var key_iter = headers.keyIterator();
            while (key_iter.next()) |key| {
                al.free(key.*);
            }

            headers.deinit();
        }

        // Parse the headers
        while (response_iter.next()) |header_line| {
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
            result.value_ptr.* = header_value;
        }

        // verify unsupported headers are not present
        if (headers.contains("transfer-encoding") or headers.contains("content-encoding")) {
            return error.UnsupportedEncoding;
        }

        if (isRedirectStatusCode(status) and headers.contains("location")) {
            dbg("Redirecting to {s}\n", .{headers.get("location").?});
            const location: []const u8 = headers.get("location").?;
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
            const new_url = try Url.init(al, new_url_path, debug);
            defer new_url.free(al);
            return new_url.httpRequest(al, socket_map, redirect_count + 1, debug);
        }

        // Determine content length to know how much to body to read.
        var content_length: usize = 0;
        if (headers.contains("content-length")) {
            const cl_str = headers.get("content-length").?;
            content_length = std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength;
        }

        // The body starts right after the headers
        // Some of the body could have been read from the socket earlier and is in the response_list already
        const already_have_body = response_list.items[header_section_len..response_list.items.len];
        var body_list = std.ArrayList(u8).init(al);
        defer body_list.deinit();
        try body_list.appendSlice(already_have_body);

        // If we haven't got all the body yet, read more
        if (content_length > body_list.items.len) {
            var remaining = content_length - body_list.items.len;
            while (remaining > 0) {
                const to_read = if (remaining < buffer_size) remaining else buffer_size;
                const read_count = switch (conn) {
                    .Tls => |*c| try c.client.read(c.stream, temp_buffer[0..to_read]),
                    .Tcp => |c| try c.read(temp_buffer[0..to_read]),
                };
                // connection closed prematurely?
                if (read_count == 0) break;

                try body_list.appendSlice(temp_buffer[0..read_count]);
                remaining -= read_count;
            }

            if (body_list.items.len != content_length) {
                return error.IncompleteBody;
            }
        }

        // flatten the body_list into a single slice
        const final_body = body_list.items[0..body_list.items.len];
        // allocate memory for the body
        const body = try al.alloc(u8, final_body.len);
        @memcpy(body, final_body);

        return body;
    }

    fn fileRequest(self: Url, al: std.mem.Allocator, debug: bool) ![]const u8 {
        const html_file = std.fs.cwd().openFile(self.path, .{}) catch |err| {
            std.log.err("Failed to open file {s}: {any}", .{ self.path, err });
            // EX_NOINPUT: cannot open input
            std.process.exit(66);
        };

        defer html_file.close();

        const html_content = try html_file.readToEndAlloc(al, 4096);
        if (debug) dbg("File content:\n{s}", .{html_content});
        return html_content;
    }

    pub fn load(self: Url, al: std.mem.Allocator, socket_map: *std.StringHashMap(Connection), debug: bool) !void {
        if (std.mem.eql(u8, self.scheme, "file")) {
            dbg("File request: {s}\n", .{self.path});
            const body = try self.fileRequest(al, debug);
            defer al.free(body);
            try show(body, self.view_source);
        } else if (std.mem.eql(u8, self.scheme, "data")) {
            dbg("Data request: {s}\n", .{self.path});
            try show(self.path, self.view_source);
        } else {
            const body = try self.httpRequest(al, socket_map, 0, debug);
            defer al.free(body);
            try show(body, self.view_source);
        }
    }
};

pub fn loadAll(allocator: std.mem.Allocator, urls: ArrayList(Url), debug: bool) !void {
    var socket_map = std.StringHashMap(Connection).init(allocator);
    defer {
        var sockets_iter = socket_map.valueIterator();
        while (sockets_iter.next()) |socket| {
            switch (socket.*) {
                .Tcp => socket.Tcp.close(),
                .Tls => socket.Tls.stream.close(),
            }
        }
        socket_map.deinit();
    }

    for (urls.items) |url| {
        try url.load(allocator, &socket_map, debug);
    }
}

pub fn isRedirectStatusCode(status: []const u8) bool {
    return std.mem.eql(u8, status, "301") or
        std.mem.eql(u8, status, "302") or
        std.mem.eql(u8, status, "303") or
        std.mem.eql(u8, status, "307") or
        std.mem.eql(u8, status, "308");
}

// Show the body of the response, sans tags
pub fn show(body: []const u8, view_content: bool) !void {
    if (view_content) {
        try stdout.print("{s}", .{body});
        return;
    }
    var in_tag = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '<') {
            in_tag = true;
        } else if (c == '>') {
            in_tag = false;
        } else if (c == '&') {
            i += try showEntity(body[i..]);
        } else if (!in_tag) {
            try stdout.print("{c}", .{c});
        }
    }
}

pub fn showEntity(text: []const u8) !usize {
    // Find the end of the entity
    if (std.mem.indexOf(u8, text, ";")) |entity_end_index| {
        const entity = text[0 .. entity_end_index + 1];
        if (std.mem.eql(u8, entity, "&amp;")) {
            try stdout.print("&", .{});
        } else if (std.mem.eql(u8, entity, "&lt;")) {
            try stdout.print("<", .{});
        } else if (std.mem.eql(u8, entity, "&gt;")) {
            try stdout.print(">", .{});
        } else {
            try stdout.print("{s}", .{entity});
        }
        return entity.len - 1;
    } else {
        return error.EntityNotFound;
    }
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

// Print the headers
fn printHeaders(headers: *std.StringHashMap([]const u8)) void {
    dbgln("Headers:");
    var iter = headers.iterator();
    while (iter.next()) |entry| {
        dbg("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
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
