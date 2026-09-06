//! Shared decode boundary for HTML images and CSS backgrounds. SVG is
//! rasterized through z2d; raster formats use zigimg. Output is straight RGBA.

const std = @import("std");
const zigimg = @import("zigimg");
const svg = @import("render/svg.zig");

/// Borrow bytes through decode. The caller owns the returned image and keeps
/// encoded bytes alive until image deinit, as required by raster decoders.
pub fn decode(allocator: std.mem.Allocator, io: std.Io, bytes: []const u8) !zigimg.Image {
    var source = bytes;
    if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) source = source[3..];
    source = std.mem.trimStart(u8, source, " \t\r\n");
    if (std.mem.startsWith(u8, source, "<")) return svg.decode(allocator, io, bytes);
    var image = try zigimg.Image.fromMemory(allocator, bytes);
    errdefer image.deinit(allocator);
    try image.convert(allocator, .rgba32);
    return image;
}
