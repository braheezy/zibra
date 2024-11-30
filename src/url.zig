const std = @import("std");
const ArrayList = std.ArrayList;

const dbg = std.debug.print;
fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

const stdout = std.io.getStdOut().writer();

pub const Url = struct {
    scheme: []const u8 = undefined,
    host: []const u8 = undefined,
    path: []const u8 = undefined,
    port: u16 = 80,
    is_https: bool = false,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, debug: bool) !*Url {
        // make a copy of the url
        var local_url = ArrayList(u8).init(allocator);
        defer local_url.deinit();
        try local_url.appendSlice(url);

        // split the url by "://"
        var split_iter = std.mem.splitSequence(u8, local_url.items, "://");
        const scheme = split_iter.first();

        // delimter not found, bail
        if (std.mem.eql(u8, scheme, local_url.items)) return error.NoSchemeFound;

        // we only support http and https
        if (!std.mem.eql(u8, scheme, "http") and
            !std.mem.eql(u8, scheme, "https")) return error.UnsupportedScheme;

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

        // allocate memory for the host
        const host_alloc = try allocator.alloc(u8, host.len);
        @memcpy(host_alloc, host);

        // everything else is the path, allocate memory for it
        // if the path is '/', then this will be an empty string
        const path = split_iter.rest();
        var path_alloc = try allocator.alloc(u8, path.len + 1);

        // Prepend a '/' to the path
        path_alloc[0] = '/';
        @memcpy(path_alloc[1..], path);

        // allocate for the URL struct, populate and return it
        var u = try allocator.create(Url);
        u.scheme = scheme_alloc;
        u.host = host_alloc;
        u.path = path_alloc;
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

        if (debug) {
            dbg("Scheme: {s}\n", .{u.scheme});
            dbg("Host: {s}\n", .{u.host});
            dbg("Path: {s}\n", .{u.path});
            dbg("Port: {d}\n", .{u.port});
            dbg("Is HTTPS: {any}\n", .{u.is_https});
        }

        return u;
    }

    pub fn free(self: *Url, allocator: std.mem.Allocator) void {
        allocator.free(self.scheme);
        allocator.free(self.host);
        allocator.free(self.path);
        allocator.destroy(self);
    }

    fn request(self: *Url, al: std.mem.Allocator, debug: bool) ![]const u8 {
        // Create the request text, allocating memory as needed
        const request_content = try std.fmt.allocPrint(al,
            \\GET {s} HTTP/1.0
            \\
            \\Host: {s}
            \\
        , .{ self.path, self.host });
        defer al.free(request_content);

        if (debug) dbg("Request:\n{s}", .{request_content});

        // Define socker and connect to it.
        dbg("Connecting to {s}:{d}\n", .{ self.host, self.port });
        const tcp_stream = try std.net.tcpConnectToHost(al, self.host, self.port);
        defer tcp_stream.close();

        // Create dynamic array to store total response
        var response_list = std.ArrayList(u8).init(al);
        defer response_list.deinit();

        // if https, create a TLS client to handle the encryption
        var tls_client: std.crypto.tls.Client = undefined;
        if (self.is_https) {
            // create required certificate bundle
            // ! API changes in zig 0.14.0
            var bundle = std.crypto.Certificate.Bundle{};
            try bundle.rescan(al);
            defer bundle.deinit(al);

            // create the tls client
            tls_client = try std.crypto.tls.Client.init(tcp_stream, bundle, self.host);
            // Send the request
            try tls_client.writeAll(tcp_stream, request_content);
        } else {
            // Send the request
            try tcp_stream.writeAll(request_content);
        }

        // Create buffer for response
        // ! If this is a different size, then the response can intermittently fail
        // ! Seems to be a bug in the std library
        // ! https://github.com/ziglang/zig/issues/14573
        const buffer_size = 10000;
        var temp_buffer: [buffer_size]u8 = undefined;

        // Keep reading the response in `buffer_size` chunks, appending
        // each to the response_list
        var bytes_read: usize = 0;
        while (true) {
            if (self.is_https) {
                bytes_read = try tls_client.readAll(tcp_stream, &temp_buffer);
            } else {
                bytes_read = try tcp_stream.readAll(&temp_buffer);
            }
            try response_list.appendSlice(temp_buffer[0..bytes_read]);
            if (bytes_read == 0) {
                // End of stream
                break;
            }
        }
        // Flatten the response_list into a single slice
        const response = response_list.items[0..response_list.items.len];
        if (debug) dbg("Response:\n{s}", .{response});

        // Parse the response line by line
        var response_iter = std.mem.splitSequence(
            u8,
            response,
            "\r\n",
        );

        // The first line has the response status
        if (response_iter.next()) |status_line| {
            const version, const status, const explanation = try parseStatus(status_line);

            dbg("{s} {s} {s}\n", .{ version, status, explanation });
        }

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

        while (response_iter.next()) |header_line| {
            // Empty line indicates end of headers
            if (std.mem.eql(u8, header_line, "")) {
                break;
            }

            // Split the header line by ':' for the key and value
            var line_iter = std.mem.splitScalar(u8, header_line, ':');

            const header_name = line_iter.next();
            if (header_name == null) {
                return error.NoHeaderNameFound;
            }
            // normalize the key to lowercase
            const lowercase_header_name = try std.ascii.allocLowerString(al, header_name.?);
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

        // The rest of the response is the body
        const body = response_iter.rest();
        const b = try al.alloc(u8, body.len);
        @memcpy(b, body);

        return b;
    }

    pub fn load(self: *Url, al: std.mem.Allocator, debug: bool) !void {
        const body = try self.request(al, debug);
        try show(body);
        al.free(body);
    }
};

// Show the body of the response, sans tags
fn show(body: []const u8) !void {
    var in_tag = false;
    for (body) |c| {
        if (c == '<') {
            in_tag = true;
        } else if (c == '>') {
            in_tag = false;
        } else if (!in_tag) {
            try stdout.print("{c}", .{c});
        }
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
