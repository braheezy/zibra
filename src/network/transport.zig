//! Browser-independent HTTP transport and cache coordination.
//!
//! URL identity is supplied as a comptime type so this module can fetch,
//! redirect, cache, and apply response/cookie policy without owning URL parsing
//! or importing the public url.zig facade back into itself.

const std = @import("std");
const cache_module = @import("cache.zig");
const cookie = @import("cookie.zig");
const response_module = @import("response.zig");
const Mutex = @import("../runtime/sync.zig").Mutex;

const CacheControl = cache_module.CacheControl;
const HttpCache = cache_module.HttpCache;
const ReferrerPolicy = cache_module.ReferrerPolicy;
const XFrameOptions = cache_module.XFrameOptions;
const HttpResponse = response_module.Response;
const CookieEntry = cookie.Entry;

pub const user_agent = "Zibra/0.0.0";
const redirect_limit: u16 = 3;

pub fn requestOptions(
    redirect_behavior: std.http.Client.Request.RedirectBehavior,
    extra_headers: []const std.http.Header,
) std.http.Client.RequestOptions {
    return .{
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .redirect_behavior = redirect_behavior,
        .headers = .{
            .user_agent = .{ .override = user_agent },
            .accept_encoding = .{ .override = "gzip" },
        },
        .extra_headers = extra_headers,
    };
}

pub fn fetchBodyInternal(
    comptime Url: type,
    comptime inheritFragment: anytype,
    comptime refererHeaderValue: anytype,
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
    const fetched = try httpRequest(
        Url,
        refererHeaderValue,
        url,
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

    if (use_cache and fetched.status == .ok and fetched.cache_control.isCacheable()) {
        const final_url_text = if (fetched_final_url) |resolved| resolved.ada_url.getHref() else null;
        if (network_lock) |lock| lock.lock();
        cache.?.store(
            cache_key,
            fetched.body,
            fetched.csp_header,
            final_url_text,
            fetched.cache_control,
            fetched.referrer_policy,
            fetched.x_frame_options,
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
    return fetched;
}

fn httpRequest(
    comptime Url: type,
    comptime refererHeaderValue: anytype,
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
    if (!Url.hostHasExplicitPort(host_str) and self.port != 80 and self.port != 443) {
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
            const value = cookie.cookieForRequest(
                al,
                cookie_jar,
                host_slice,
                method,
                if (referrer) |source| source.host else null,
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
                        break :set_cookie try cookie.applySetCookie(
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
                    if (response_module.parseReferrerPolicy(header.value)) |parsed| {
                        response_referrer_policy = parsed;
                    }
                } else if (std.ascii.eqlIgnoreCase(header.name, "x-frame-options")) {
                    if (response_module.parseXFrameOptions(header.value)) |parsed| {
                        response_x_frame_options = response_module.mergeXFrameOptions(
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
