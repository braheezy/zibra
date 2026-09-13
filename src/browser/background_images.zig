//! Post-cascade discovery and loading for CSS background images.
//!
//! This module deliberately receives browser/frame operations as callbacks so
//! resource coordination stays out of the legacy root coordinator without
//! importing `root.zig` or `tab.zig` and creating an import cycle.

const std = @import("std");
const zigimg = @import("zigimg");
const image_decoder = @import("image_decoder.zig");

const background = @import("../document/background_image.zig");
const parser = @import("../document/parser.zig");
const url_module = @import("../network/url.zig");

const Node = parser.Node;
const Url = url_module.Url;

pub const UsedImage = struct {
    element: *parser.Element,
    /// CSS-encoded contents borrowing the Element computed value.
    source: []const u8,
};

fn computedValue(element: *parser.Element, property: []const u8) ?[]const u8 {
    const styles = if (element.style) |*styles| styles else return null;
    const field = styles.getPtr(property) orelse return null;
    return field.get().*;
}

fn computedSource(element: *parser.Element) ?[]const u8 {
    if (element.isHiddenInput()) return null;
    if (computedValue(element, "display")) |display| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, display, " \t\r\n"), "none")) return null;
    }
    const source = background.parseUrl(computedValue(element, "background-image") orelse return null) orelse return null;
    return if (source.len == 0) null else source;
}

/// Collect only URLs selected by final computed style. A declaration on an
/// unmatched selector or one that loses the cascade never enters this list.
pub fn collectUsed(
    allocator: std.mem.Allocator,
    root: *Node,
    output: *std.ArrayList(UsedImage),
) !void {
    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, root, &nodes);
    for (nodes.items) |node| switch (node.*) {
        .element => |*element| if (computedSource(element)) |source| {
            try output.append(allocator, .{ .element = element, .source = source });
        },
        .text => {},
    };
}

const CacheEntry = struct {
    width: usize,
    height: usize,
    pixels: []const u8,
};

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
    io: std.Io,
    page_url: *const Url,
    source_base: ?[]const u8,
    referrer_policy: url_module.ReferrerPolicy,
    source: []const u8,
    cache: *std.StringHashMap(CacheEntry),
    context: anytype,
    comptime callbacks: type,
) !parser.BackgroundImageData {
    var result = parser.BackgroundImageData{
        .source = try allocator.dupe(u8, source),
    };
    errdefer result.deinit(allocator);
    if (source_base) |base| result.source_base = try allocator.dupe(u8, base);
    var sheet_url: ?Url = if (source_base) |base| try Url.init(allocator, base) else null;
    defer if (sheet_url) |url| url.free(allocator);
    const referrer_url: *const Url = if (sheet_url) |*url| url else page_url;

    const decoded = try @import("../document/css_tokenizer.zig").decode(allocator, source, true);
    defer allocator.free(decoded);
    var image_url = referrer_url.*.resolve(allocator, decoded) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Failed to resolve CSS background image {s}: {}", .{ source, err });
        return result;
    };
    defer image_url.free(allocator);

    if (!callbacks.allowed(context, image_url, page_url)) {
        std.log.warn("Blocked CSS background image {s} due to CSP", .{source});
        return result;
    }

    const cache_key = try image_url.toOwnedString(allocator);
    var cache_key_owned = true;
    defer if (cache_key_owned) allocator.free(cache_key);
    if (cache.get(cache_key)) |entry| {
        result.data = try cloneCachedImage(allocator, entry);
        return result;
    }

    const response = callbacks.fetch(context, image_url, referrer_url.*, referrer_policy) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Failed to load CSS background image {s}: {}", .{ source, err });
        return result;
    };
    defer if (response.csp_header) |header| allocator.free(header);
    defer if (response.access_control_allow_origin) |header| allocator.free(header);

    var encoded_bytes = response.body;
    if (std.mem.eql(u8, image_url.scheme, "data") or std.mem.eql(u8, image_url.scheme, "about")) {
        encoded_bytes = try allocator.dupe(u8, encoded_bytes);
    }
    var encoded_owned = true;
    defer if (encoded_owned) allocator.free(encoded_bytes);

    var image = image_decoder.decode(allocator, io, encoded_bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("Failed to decode CSS background image {s}: {}", .{ source, err });
        return result;
    };
    var image_owned = true;
    defer if (image_owned) image.deinit(allocator);

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

    result.data = .{ .encoded_bytes = encoded_bytes, .image = image };
    encoded_owned = false;
    image_owned = false;
    return result;
}

/// Reconcile the live DOM's installed resources with final computed style.
/// `callbacks` provides `allowed`, `fetch`, and `retire` functions. Retirement
/// is invoked exactly once before the first resource replacement so retained
/// display commands never outlive the pixel buffer they borrow.
pub fn loadUsed(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *Node,
    page_url: *const Url,
    referrer_policy: url_module.ReferrerPolicy,
    backgrounds_enabled: bool,
    context: anytype,
    comptime callbacks: type,
) !void {
    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(allocator);
    try parser.treeToList(allocator, root, &nodes);

    var cache = std.StringHashMap(CacheEntry).init(allocator);
    defer {
        var iterator = cache.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.pixels);
        }
        cache.deinit();
    }

    var retired = false;
    for (nodes.items) |node| switch (node.*) {
        .element => |*element| {
            const source = if (backgrounds_enabled) computedSource(element) else null;
            if (source == null) {
                if (element.background_image) |*installed| {
                    if (!retired) {
                        callbacks.retire(context);
                        retired = true;
                    }
                    installed.deinit(allocator);
                    element.background_image = null;
                }
                continue;
            }

            if (element.background_image) |*installed| {
                if (std.mem.eql(u8, installed.source, source.?) and
                    std.mem.eql(u8, installed.source_base orelse "", element.background_source_url orelse "")) continue;
            }

            var replacement = try loadOne(
                allocator,
                io,
                page_url,
                element.background_source_url,
                element.background_referrer_policy orelse referrer_policy,
                source.?,
                &cache,
                context,
                callbacks,
            );
            var replacement_owned = true;
            errdefer if (replacement_owned) replacement.deinit(allocator);

            if (!retired) {
                callbacks.retire(context);
                retired = true;
            }
            if (element.background_image) |*installed| installed.deinit(allocator);
            element.background_image = replacement;
            replacement_owned = false;
        },
        .text => {},
    };
}
