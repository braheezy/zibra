//! Discovery, selection, fetch, and decode for HTML image resources.
//!
//! Browser and Frame operations arrive as callbacks so this resource owner
//! remains independent of the oversized root coordinator and its SDL state.

const std = @import("std");
const zigimg = @import("zigimg");

const parser = @import("../document/parser.zig");
const url_module = @import("../network/url.zig");

const Url = url_module.Url;

pub const Bounds = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Viewport = struct {
    scroll: i32,
    height: i32,
    preload_margin: i32,
};

pub const Selection = union(enum) {
    eager,
    lazy_near: Viewport,
};

pub const Candidate = struct {
    element: *parser.Element,
    bounds: ?Bounds = null,
};

fn dataUrlHasImageMediaType(source: []const u8) bool {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "data:")) return false;
    const comma = std.mem.indexOfScalar(u8, trimmed, ',') orelse return false;
    const metadata = std.mem.trim(u8, trimmed[5..comma], " \t\r\n");
    return std.ascii.startsWithIgnoreCase(metadata, "image/");
}

/// Image decoders must not be fed error documents or responses with a
/// non-image MIME type.  Keeping this check here also makes `<object>` fall
/// back to its children when its primary resource fails, as browsers do.
fn responseCanDecodeImage(response: url_module.HttpResponse) bool {
    if (response.status) |status| {
        const code = @intFromEnum(status);
        if (code < 200 or code >= 300) return false;
    }
    return response.content_type == .image or response.content_type == .unknown;
}

/// Return the image source selected by an HTML replaced element. `<object>`
/// participates only when its declared or data-URL media type is image-like;
/// unsupported object resources keep rendering their fallback children.
pub fn resourceSource(element: *const parser.Element) ?[]const u8 {
    const attributes = element.attributes orelse return null;
    if (std.ascii.eqlIgnoreCase(element.tag, "img")) {
        const source = attributes.get("src") orelse return null;
        return if (source.len == 0) null else source;
    }
    if (!std.ascii.eqlIgnoreCase(element.tag, "object")) return null;

    const source = attributes.get("data") orelse return null;
    if (source.len == 0) return null;
    if (attributes.get("type")) |media_type| {
        const normalized = std.mem.trim(u8, media_type, " \t\r\n");
        if (!std.ascii.startsWithIgnoreCase(normalized, "image/")) return null;
        return source;
    }
    if (std.ascii.startsWithIgnoreCase(std.mem.trim(u8, source, " \t\r\n"), "data:") and
        !dataUrlHasImageMediaType(source))
    {
        return null;
    }
    return source;
}

pub fn isImageResourceElement(element: *const parser.Element) bool {
    return resourceSource(element) != null;
}

pub fn isLazy(element: *const parser.Element) bool {
    if (!std.ascii.eqlIgnoreCase(element.tag, "img")) return false;
    const attributes = element.attributes orelse return false;
    const value = attributes.get("loading") orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "lazy");
}

/// A one-viewport margin gives the networking thread time to finish before an
/// ordinary scroll exposes the image without fetching the whole document.
pub fn isNearViewport(bounds: Bounds, viewport: Viewport) bool {
    const viewport_height = @max(viewport.height, 1);
    const margin = @max(viewport.preload_margin, 0);
    const preload_top = @as(i64, viewport.scroll) - @as(i64, margin);
    const preload_bottom = @as(i64, viewport.scroll) +
        @as(i64, viewport_height) + @as(i64, margin);
    const image_top: i64 = bounds.y;
    const image_bottom = image_top + @as(i64, @max(bounds.height, 1));
    return image_bottom >= preload_top and image_top <= preload_bottom;
}

fn selected(candidate: Candidate, selection: Selection) bool {
    if (candidate.element.image_data != null) return false;
    return switch (selection) {
        .eager => !isLazy(candidate.element),
        .lazy_near => |viewport| isLazy(candidate.element) and
            candidate.bounds != null and
            isNearViewport(candidate.bounds.?, viewport),
    };
}

const CacheEntry = struct {
    width: usize,
    height: usize,
    pixels: []const u8,
};

fn brokenImage(allocator: std.mem.Allocator) !parser.ImageData {
    const width: usize = 16;
    const height: usize = 16;
    var pixels = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(pixels);

    var index: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const is_cross = x == y or x + y == width - 1;
            pixels[index + 0] = if (is_cross) 0xcc else 0xee;
            pixels[index + 1] = if (is_cross) 0x33 else 0xee;
            pixels[index + 2] = if (is_cross) 0x33 else 0xee;
            pixels[index + 3] = 0xff;
            index += 4;
        }
    }

    return .{
        .encoded_bytes = null,
        .image = try zigimg.Image.fromRawPixelsOwned(width, height, pixels, .rgba32),
        .is_broken = true,
    };
}

/// Broken fallback pixels are visual only when alternate text says the image
/// carries content. Missing and explicitly empty alt values suppress the icon.
pub fn shouldShowBrokenImage(element: *const parser.Element) bool {
    const data = element.image_data orelse return false;
    if (!data.is_broken) return false;
    const attributes = element.attributes orelse return false;
    return (attributes.get("alt") orelse return false).len > 0;
}

fn cloneCachedImage(allocator: std.mem.Allocator, entry: CacheEntry) !parser.ImageData {
    const pixels = try allocator.dupe(u8, entry.pixels);
    errdefer allocator.free(pixels);
    return .{
        .encoded_bytes = null,
        .image = try zigimg.Image.fromRawPixelsOwned(entry.width, entry.height, pixels, .rgba32),
    };
}

fn loadOne(
    allocator: std.mem.Allocator,
    page_url: *const Url,
    referrer_policy: url_module.ReferrerPolicy,
    source: []const u8,
    cache: *std.StringHashMap(CacheEntry),
    context: anytype,
    comptime callbacks: type,
) !parser.ImageData {
    var image_url = page_url.*.resolve(allocator, source) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Failed to resolve image URL {s}: {}", .{ source, err });
        return brokenImage(allocator);
    };
    defer image_url.free(allocator);

    if (!callbacks.allowed(context, image_url, page_url)) {
        std.log.warn("Blocked image {s} due to CSP", .{source});
        return brokenImage(allocator);
    }

    const cache_key = try image_url.toOwnedString(allocator);
    var cache_key_owned = true;
    defer if (cache_key_owned) allocator.free(cache_key);
    if (cache.get(cache_key)) |entry| return cloneCachedImage(allocator, entry);

    const response = callbacks.fetch(context, image_url, page_url.*, referrer_policy) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Failed to load image {s}: {}", .{ source, err });
        return brokenImage(allocator);
    };
    defer if (response.csp_header) |header| allocator.free(header);
    defer if (response.access_control_allow_origin) |header| allocator.free(header);

    if (!responseCanDecodeImage(response)) {
        // Network responses transfer their body to this loader. Synthetic
        // data/about URLs are borrowed from the URL object and must not be
        // freed here, matching the ownership path below.
        if (!std.mem.eql(u8, image_url.scheme, "data") and
            !std.mem.eql(u8, image_url.scheme, "about"))
        {
            allocator.free(response.body);
        }
        return brokenImage(allocator);
    }

    var encoded_bytes = response.body;
    if (std.mem.eql(u8, image_url.scheme, "data") or std.mem.eql(u8, image_url.scheme, "about")) {
        encoded_bytes = try allocator.dupe(u8, encoded_bytes);
    }
    var encoded_owned = true;
    defer if (encoded_owned) allocator.free(encoded_bytes);

    var image = zigimg.Image.fromMemory(allocator, encoded_bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Failed to decode image {s}: {}", .{ source, err });
        return brokenImage(allocator);
    };
    var image_owned = true;
    defer if (image_owned) image.deinit(allocator);
    image.convert(allocator, .rgba32) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Failed to convert image {s} to RGBA: {}", .{ source, err });
        return brokenImage(allocator);
    };

    const cached_pixels = try allocator.dupe(u8, image.rawBytes());
    var cached_pixels_owned = true;
    errdefer if (cached_pixels_owned) allocator.free(cached_pixels);
    try cache.put(cache_key, .{
        .width = image.width,
        .height = image.height,
        .pixels = cached_pixels,
    });
    cache_key_owned = false;
    cached_pixels_owned = false;

    encoded_owned = false;
    image_owned = false;
    return .{ .encoded_bytes = encoded_bytes, .image = image };
}

/// Load only candidates selected by eager discovery or the current lazy
/// preload window. Each selected element receives either decoded pixels or a
/// stable broken-image resource, so failed requests are not retried on every
/// animation frame. Identical URLs decode once per batch and receive
/// independent ImageData ownership.
pub fn loadCandidates(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    selection: Selection,
    page_url: *const Url,
    referrer_policy: url_module.ReferrerPolicy,
    context: anytype,
    comptime callbacks: type,
) !usize {
    var cache = std.StringHashMap(CacheEntry).init(allocator);
    defer {
        var iterator = cache.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.pixels);
        }
        cache.deinit();
    }

    var loaded: usize = 0;
    for (candidates) |candidate| {
        if (!selected(candidate, selection)) continue;
        const source = resourceSource(candidate.element) orelse continue;

        var data = try loadOne(
            allocator,
            page_url,
            referrer_policy,
            source,
            &cache,
            context,
            callbacks,
        );
        var data_owned = true;
        errdefer if (data_owned) data.deinit(allocator);
        candidate.element.image_data = data;
        data_owned = false;
        loaded += 1;
    }
    return loaded;
}

test "lazy image selection is case-insensitive and uses a viewport margin" {
    const allocator = std.testing.allocator;
    var lazy = try parser.Element.init(allocator, "img loading=LaZy", null);
    defer lazy.deinit(allocator);
    var eager = try parser.Element.init(allocator, "img loading=eager", null);
    defer eager.deinit(allocator);

    try std.testing.expect(isLazy(&lazy));
    try std.testing.expect(!isLazy(&eager));
    const viewport = Viewport{ .scroll = 1000, .height = 600, .preload_margin = 600 };
    try std.testing.expect(isNearViewport(.{ .x = 0, .y = 400, .width = 10, .height = 1 }, viewport));
    try std.testing.expect(isNearViewport(.{ .x = 0, .y = 2200, .width = 10, .height = 1 }, viewport));
    try std.testing.expect(!isNearViewport(.{ .x = 0, .y = 2202, .width = 10, .height = 1 }, viewport));
}

test "object image discovery preserves unsupported fallback subtrees" {
    const allocator = std.testing.allocator;
    var image = try parser.Element.init(
        allocator,
        "object data='data:image/png;base64,AAAA'",
        null,
    );
    defer image.deinit(allocator);
    var typed_image = try parser.Element.init(
        allocator,
        "object data=portrait.bin type=' image/avif '",
        null,
    );
    defer typed_image.deinit(allocator);
    var unsupported_data = try parser.Element.init(
        allocator,
        "object data='data:application/x-unknown,ERROR'",
        null,
    );
    defer unsupported_data.deinit(allocator);
    var document = try parser.Element.init(
        allocator,
        "object data=page.html type=text/html",
        null,
    );
    defer document.deinit(allocator);

    try std.testing.expectEqualStrings(
        "data:image/png;base64,AAAA",
        resourceSource(&image).?,
    );
    try std.testing.expectEqualStrings("portrait.bin", resourceSource(&typed_image).?);
    try std.testing.expect(resourceSource(&unsupported_data) == null);
    try std.testing.expect(resourceSource(&document) == null);
}

test "broken image visibility requires non-empty alternate text" {
    const allocator = std.testing.allocator;
    var missing = try parser.Element.init(allocator, "img", null);
    defer missing.deinit(allocator);
    var empty = try parser.Element.init(allocator, "img alt=''", null);
    defer empty.deinit(allocator);
    var described = try parser.Element.init(allocator, "img alt='Missing portrait'", null);
    defer described.deinit(allocator);

    missing.image_data = try brokenImage(allocator);
    empty.image_data = try brokenImage(allocator);
    described.image_data = try brokenImage(allocator);

    try std.testing.expect(!shouldShowBrokenImage(&missing));
    try std.testing.expect(!shouldShowBrokenImage(&empty));
    try std.testing.expect(shouldShowBrokenImage(&described));
}

test "image responses reject HTTP errors and non-image MIME types" {
    try std.testing.expect(responseCanDecodeImage(.{
        .body = &.{},
        .content_type = .image,
        .status = .ok,
    }));
    try std.testing.expect(!responseCanDecodeImage(.{
        .body = &.{},
        .content_type = .image,
        .status = .not_found,
    }));
    try std.testing.expect(!responseCanDecodeImage(.{
        .body = &.{},
        .content_type = .html,
        .status = .ok,
    }));
    // Synthetic data/about responses have no HTTP status or MIME metadata;
    // the decoder remains the authority for those resources.
    try std.testing.expect(responseCanDecodeImage(.{ .body = &.{} }));
}
